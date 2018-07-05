package LetterStream::Client;

use strict;
use warnings;

use URI::Escape;
use MIME::Base64;
use JSON::MaybeXS;
use Carp qw(croak);
use File::Basename;
use LWP::UserAgent;
use Digest::MD5 qw(md5);
use Text::CSV_XS qw(csv);
use File::Temp qw(tempfile);
use HTTP::Request::Common qw(POST);
use Archive::Zip qw(:ERROR_CODES :CONSTANTS);
use IO::Async::Timer::Periodic;
use IO::Async::Loop;

our $api_base_uri = 'https://secure.letterstream.com/apis/index.php';

sub new {
  my ($class, $args) = @_;

  croak "Missing API ID." unless $$args{api_id};
  croak "Missing API key." unless $$args{api_key};
  croak "Missing logger." unless $$args{logger};
  croak "Invalid logger." unless ref $$args{logger} eq 'CODE';

  croak "Invalid debug value."
    if($$args{debug} && $$args{debug} !~ /^1|2|3$/);

  if(ref $$args{mode} eq 'HASH') {
    if(!$$args{mode}->{send_on}) {
      croak "Missing \$mode->{send_on}."
    }
    if($$args{mode}->{send_on} =~ /filesize_limit|filecount_limit|interval/) {
      if(!$$args{mode}->{value}) {
        croak "Missing \$mode->{value}."
      }
      elsif($$args{mode}->{value} !~ /^[0-9]+$/) {
        croak "Invalid \$mode->{value}."
      }
    }
    elsif($$args{mode}->{send_on} ne 'letter_created') {
      croak "Invalid \$mode->{send_on}."
    }
  }
  else {
    $$args{mode} = {
      send_on => 'letter_created'
    }
  }

  my $self = bless {}, $class;

  $$self{args} = { %$args };
  $$self{letter_queue} = [];
  $$self{queue_filesize} = 0;
  $$self{ua} = LWP::UserAgent->new;

  if($$args{mode}->{send_on} eq 'interval') {
    $$self{loop} = IO::Async::Loop->new();
    
    $$self{timer} = IO::Async::Timer::Periodic->new(
      interval => $$args{mode}->{value},
      on_tick => sub {
        $self->send_queue()
      }
    )
  }

  return $self
}

sub create_letter {
  my ($self, $content) = @_;

  foreach my $key (qw(MailType Duplex Ink Affidavit PageCount PDFFileName)) {
    croak "No '$key' provided." unless $$content{$key}
  }

  foreach my $address_type (qw(Recipient Sender)) {
    foreach my $address_key (qw(Name Addr1 City State Zip)) {
      croak "No '$address_type$address_key' provided." unless $$content{$address_type . $address_key}
    }
  }

  $$content{UniqueDocId} = time() . sprintf("%03d", int(rand(1000)));

  return $self->add_to_queue($content)
}

sub add_to_queue {
  my ($self, $letter) = @_;

  push @{ $self->{letter_queue} }, $letter;

  if($self->{args}->{send_on} eq 'letter_created') {
    return $self->send_queue();
  }
  elsif($self->{args}->{send_on} eq 'interval') {
    $self->{timer}->start;
    $self->{loop}->add($self->{timer});
    $self->{loop}->run
  }
  elsif($self->{args}->{mode}->{send_on} eq 'filecount_limit') {
    $self->send_queue() if scalar @{ $self->{letter_queue} } >= $self->{args}->{mode}->{value}
  }
  elsif($self->{args}->{mode}->{send_on} eq 'filesize_limit') {
    $self->{queue_filesize} += -s $$letter{PDFFileName};
    $self->send_queue() if $self->{queue_filesize} > $self->{args}->{mode}->{value};
  }
}

sub send_queue {
  my ($self) = @_;

  my ($csv_fh, $csv_fn) = tempfile();
  my ($zip_fh, $zip_fn) = tempfile();

  my @queue = @{ $self->{letter_queue} };
  $self->{letter_queue} = [];

  csv(in => \@queue, out => $csv_fn);

  my @pdfs = uniq(map {
    $$_{PDFFileName}
  } @queue);

  my $zip = Archive::Zip->new();

  $zip->addFile($csv_fn, basename($csv_fn));

  foreach my $pdf (@pdfs) {
    $zip->addFile($pdf, basename($pdf))
  }

  unless ($zip->writeToFileNamed($zip_fn) == AZ_OK) {
    croak "Error writing temporary zip file."
  }

  my $req = POST 'http://www.perl.org/survey.cgi',
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
  my $hash = md5(encode_base64(substr($uniqid, -6) . $self->{api_key} . substr($uniqid, 0, 6)));

  my $fields = {
    a => $self->{api_id},
    h => $hash,
    u => $uniqid,
    d => $self->{args}->{debug},
    responseformat => 'json'
  };

  $$fields{debug} = $self->{args}->{debug} if $self->{args}->{debug};

  return $fields
}

sub send_request {
  my ($self, $req, $args) = @_;

  my $res = $self->{ua}->request($req);

  if($res->is_success) {
    return decode_json($res->decoded_content), $res
  }

  croak $res->decoded_content
}

1;