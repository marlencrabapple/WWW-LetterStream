package LetterStream::Client;

use strict;
use warnings;

use DBI;
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
use IO::Async::Timer::Periodic;
use IO::Async::Loop;

our $api_base_uri = 'https://secure.letterstream.com/apis/index.php';

sub new {
  my ($class, $args) = @_;

  my $attribs = {};

  croak "Missing API ID." unless $$args{api_id};
  croak "Missing API key." unless $$args{api_key};

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

      if(ref $$args{queue} eq 'HASH') {
        croak "No \$queue->{table} provided." unless $$args{queue}->{table};
        croak "No \$queue->{source} provided." unless ref $$args{queue}->{source} eq 'ARRAY';

        $$attribs{dbh} = DBI->connect(@{ $$args{queue}->{source} });

        init_queue($$attribs{dbh}, $$args{queue}->{table})
      }
      else {
        croak "Missing queue options."
      }

      if($$args{mode}->{send_on} eq 'interval') {
        foreach my $cb (qw(success_cb error_cb)) {
          croak "Missing queue $cb." unless $$args{$cb};
          croak "Invalid queue $cb." unless ref $$args{$cb} eq 'CODE'
        }
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

  my $self = bless $attribs, $class;

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

  foreach my $key (qw(MailType PageCount PDFFileName)) {
    croak "No '$key' provided." unless $$content{$key}
  }

  foreach my $address_type (qw(Recipient Sender)) {
    foreach my $address_key (qw(Name1 Addr1 City State Zip)) {
      croak "No '$address_type$address_key' provided." unless $$content{$address_type . $address_key}
    }
  }

  $$content{UniqueDocId} = time() . sprintf("%03d", int(rand(1000)));
  $$content{path_to_pdf} = $$content{PDFFileName};
  $$content{PDFFileName} = basename($$content{PDFFileName});

  return $self->add_to_queue($content)
}

sub add_to_queue {
  my ($self, $letter) = @_;

  push @{ $self->{letter_queue} }, $letter;

  if($self->{args}->{mode}->{send_on} eq 'letter_created') {
    return $self->send_queue();
  }
  elsif($self->{args}->{mode}->{send_on} eq 'interval') {
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
  chomp($base64);

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

  my $res = $self->{ua}->request($req);

  if($res->is_success) {
    return $self->{args}->{mode}->{send_on} eq 'letter_created'
      ? (decode_json($res->decoded_content), $res)
      : $self->{success_cb}->(decode_json($res->decoded_content), $res)
  }

  return $self->{args}->{mode}->{send_on} eq 'letter_created'
    ? croak $res->decoded_content
    : $self->{error_cb}->($res->decoded_content)
}

sub table_exists {
  my ($dbh, $table) = @_;

  my $sth;

  return 0 unless $sth = $self->dbh->prepare("SELECT * FROM " . $table . " LIMIT 1;");
  return 0 unless $sth->execute();

  return 1
}

sub get_sql_autoincrement {
  my $source = shift;

	return 'INTEGER PRIMARY KEY NOT NULL AUTO_INCREMENT' if $source =~ /^DBI:mysql:/i;
	return 'INTEGER PRIMARY KEY' if $source =~ /^DBI:SQLite:/i;
	return 'INTEGER PRIMARY KEY' if $source =~ /^DBI:SQLite2:/i;

  croak "Invalid \$queue->{source}"
}

sub init_queue {
  my ($dbh, $table) = @_;

  if(!table_exists($table)) {
    my $sth = $dbh->prepare(qq/CREATE TABLE $table (
      
      )/)
  }
}

1