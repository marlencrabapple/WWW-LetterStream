package LetterStream::Client;

use strict;
use warnings;

use URI::Escape;
use MIME::Base64;
use JSON::MaybeXS;
use Carp qw(croak);
use File::Basename;
use LWP::UserAgent;
use List::Util qw(uniq);
use Text::CSV_XS qw(csv);
use File::Temp qw(tempfile);
use Digest::MD5 qw(md5_hex);
use HTTP::Request::Common qw(POST);
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);

our $api_base_uri = 'https://secure.letterstream.com/apis/index.php';
our $ua = LWP::UserAgent->new;

sub new {
  my ($class, $args) = @_;

  croak "Missing API ID." unless $$args{api_id};
  croak "Missing API key." unless $$args{api_key};

  croak "Invalid debug value."
    if($$args{debug} && $$args{debug} !~ /^1|2|3$/);

  my $self = bless {}, $class;

  $$self{args} = { %$args };
  $$self{letter_queue} = [];
  $$self{queue_filesize} = 0;

  return $self
}

sub create_letter {
  my ($self, $content) = @_;

  foreach my $key (qw(UniqueDocId MailType PageCount PDFFileName)) {
    croak "No '$key' provided." unless $$content{$key}
  }

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

  push @{ $self->{letter_queue} }, $letter;
  
  return @{ $self->{letter_queue} }
}

sub send_queue {
  my ($self) = @_;

  return 0 unless scalar @{ $self->{letter_queue} };

  my ($csv_fh, $csv_fn) = tempfile();
  my ($zip_fh, $zip_fn) = tempfile();

  my @queue = @{ $self->{letter_queue} };
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

  my $zip = Archive::Zip->new();

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
      %{ $self->get_auth_fields() }
    ];

  return $self->send_request($req)
}

sub get_auth_fields {
  my ($self) = @_;

  my $uniqid = time() . sprintf("%03d", int(rand(1000)));

  my $base64 = encode_base64(substr($uniqid, -6) . $self->{args}->{api_key} . substr($uniqid, 0, 6));
  chop($base64);

  my $md5 = md5_hex($base64);

  my $fields = {
    a => $self->{args}->{api_id},
    h => $md5,
    t => $uniqid,
    responseformat => 'json'
  };

  $$fields{debug} = $self->{args}->{debug} if $self->{args}->{debug};

  return $fields
}

sub send_request {
  my ($self, $req, $args) = @_;

  my $res = $ua->request($req);

  return $res->is_success
    ? decode_json($res->decoded_content)
    : croak $res->status_line, $res->decoded_content
}

1