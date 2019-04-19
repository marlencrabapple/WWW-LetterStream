package LetterStream::Client;

use v5.28;

use strict;
use warnings;

our $VERSION = '0.05';

use Path::Tiny;
use URI::Escape;
use MIME::Base64;
use JSON::MaybeXS;
use File::Basename;
use LWP::UserAgent;
use Carp qw(carp croak);
use Text::CSV_XS qw(csv);
use File::Temp qw(tempfile);
use Digest::MD5 qw(md5_hex);
use List::Util qw(uniq any first);
use HTTP::Request::Common qw(POST);
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);

our $api_base_uri = 'https://secure.letterstream.com/apis/index.php';
our $ua = LWP::UserAgent->new;

sub new {
  my ($class, %args) = @_;

  croak "Missing API ID." unless $args{api_id};
  croak "Missing API key." unless $args{api_key};

  croak "Invalid debug value."
    if($args{debug} && $args{debug} !~ /^(?:1|2|3)$/);

  my $self = bless {}, $class;

  $$self{args} = \%args;
  $$self{letter_queue} = [];
  $$self{queue_filesize} = 0;

  return $self
}

sub create_letter {
  my ($self, $content) = @_;

  foreach my $key (qw(UniqueDocId MailType PageCount PDFFileName)) {
    croak "No '$key' provided." unless $$content{$key}
  }

  my $dupe = any {
    $$content{UniqueDocId} == $$_{UniqueDocId} 
  } $$self{letter_queue}->@*;

  if($dupe) {
    carp "Letter already in queue.";
    return ()
  }

  croak "File '$$content{PDFFileName}' not found." unless -e $$content{PDFFileName};

  foreach my $address_type (qw(Recipient Sender)) {
    foreach my $address_key (qw(Name1 Addr1 City State Zip)) {
      croak "No '$address_type$address_key' provided."
        unless $$content{$address_type . $address_key}
    }
  }
  
  $$content{path_to_pdf} = $$content{PDFFileName};
  $$content{PDFFileName} = basename($$content{PDFFileName});

  return $self->add_to_queue($content)
}

sub add_to_queue {
  my ($self, $letter) = @_;

  push $self->{letter_queue}->@*, $letter;
  $self->{queue_filesize} += -s $$letter{path_to_pdf};
  
  return $self->{letter_queue}->@*
}

sub send_queue {
  my ($self) = @_;

  return 0 unless scalar $self->{letter_queue}->@*;

  my ($csv_fh, $csv_fn) = tempfile;
  my ($zip_fh, $zip_fn) = tempfile;

  my @queue = $self->{letter_queue}->@*;
  $self->{letter_queue} = [];

  csv(
    in => \@queue,
    out => $csv_fn,
    headers => [
      'UniqueDocId',
      'PDFFileName',
      'RecipientName1',
      'RecipientName2',
      'RecipientAddr1',
      'RecipientAddr2',
      'RecipientCity',
      'RecipientState',
      'RecipientZip',
      'SenderName1',
      'SenderName2',
      'SenderAddr1',
      'SenderAddr2',
      'SenderCity',
      'SenderState',
      'SenderZip',
      'PageCount',
      'MailType',
      'CoverSheet',
      'Duplex',
      'Ink',
      'Paper',
      'Return Envelope',
      'Affidavit'
    ]);

  my @pdfs = uniq(map {
    $$_{path_to_pdf}
  } @queue);

  my $zip = Archive::Zip->new;

  $zip->addFile($csv_fn, basename($csv_fn) . '.csv');

  foreach my $pdf (@pdfs) {
    $zip->addFile($pdf, basename($pdf))
  }

  unless ($zip->writeToFileNamed($zip_fn) == AZ_OK) {
    croak "Error writing temporary zip file."
  }

  my $req = POST $api_base_uri,
    Content_Type => 'form-data',
    Content => [
      multi_file => [ $zip_fn ],
      $self->get_auth_fields->%*
    ];

  return $self->send_request($req)
}

sub get_batch_status {
  my ($self, @ids) = @_;
  return $self->get_status_for_x('batch', @ids)
}

sub get_job_status {
  my ($self, @ids) = @_;
  return $self->get_status_for_x('job', @ids)
}

sub get_document_status {
  my ($self, @ids) = @_;
  return $self->get_status_for_x('doc', @ids)
}

sub get_account_status {
  my ($self, @ids) = @_;
  return $self->get_status_for_x('account', @ids)
}

sub get_status_for_x {
  my ($self, $type, @ids) = @_;
  
  croak 'Invalid type.' unless any { $type eq $_ } qw(batch job doc account);
  croak "Missing $type ID." unless scalar @ids;

  my $req = POST $api_base_uri, [
    $self->get_auth_fields->%*,
    $type . 'status' => join ',', map { uri_escape_utf8($_) } @ids
  ];

  return $self->send_request($req)
}

sub get_document_proof {
  my ($self, $doc_id, $save_as) = @_;

  croak 'Missing document ID.' unless $doc_id;
  croak 'Missing filename.' unless $save_as;

  my $req = POST $api_base_uri, [
    $self->get_auth_fields->%*,
    doc_id => $doc_id,
    getinfo => 'proof'
  ];

  return $self->send_request($req, save_as => $save_as, decode_base64 => 1, validate_pdf => 1)
}

sub get_signature {
  my ($self, %args) = @_;

  croak 'Missing document or tracking ID.'
    unless any { /^(?:doc_id|cert)$/ } keys %args;

  croak 'Missing filename.' unless $args{save_as};

  my $key = first { /^(?:doc_id|cert)$/ } keys %args;

  my $req = POST $api_base_uri, [
    $self->get_auth_fields->%*,
    $key => $args{$key},
    getinfo => 'sig'
  ];

  return $self->send_request($req, save_as => $args{save_as}, validate_pdf => 1)
}

sub get_auth_fields {
  my ($self) = @_;

  my $uniqid = time . sprintf("%03d", int(rand(1000)));

  my $base64 = encode_base64(substr($uniqid, -6) . $self->{args}{api_key} . substr($uniqid, 0, 6));
  chop($base64);

  my $md5 = md5_hex($base64);

  my $fields = {
    a => $self->{args}{api_id},
    h => $md5,
    t => $uniqid,
    responseformat => 'json'
  };

  $$fields{debug} = $self->{args}{debug} if $self->{args}{debug};

  return $fields
}

sub send_request {
  my ($self, $req, %args) = @_;

  my $res = $ua->request($req);

  if($res->is_success) {
    if($args{save_as}) {
      my $path_obj = path($args{save_as});

      my $data = $args{decode_base64} ? decode_base64($res->content) : $res->content;
      
      croak "Probably not a valid PDF."
        if $args{validate_pdf} && $data !~ /^\%PDF\-1\./;

      $path_obj->spew_raw($data);

      return $path_obj
    }
    else {
      return decode_json($res->decoded_content)
    }
  }
  else {
    croak $res->status_line, $res->decoded_content
  }
}

1

__END__

=encoding utf-8

=head1 NAME

LetterStream::Client - Blah blah blah

=head1 SYNOPSIS

  use LetterStream::Client;

=head1 DESCRIPTION

LetterStream::Client is

=head1 AUTHOR

Ian P Bradley E<lt>ian.bradley@studiocrabapple.comE<gt>

=head1 COPYRIGHT

Copyright 2019- Ian P Bradley

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

=cut