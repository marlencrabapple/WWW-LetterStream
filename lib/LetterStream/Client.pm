package LetterStream::Client;

use strict;
use warnings;

use Digest::MD5;
use URI::Escape;
use Archive::Zip;
use Text::CSV_XS;
use JSON::MaybeXS;
use Carp qw(croak);
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use IO::Async::Timer::Periodic;
use IO::Async::Loop;

our $api_base_uri = 'https://print.directmailers.com/api/v1';

sub new {
  my ($class, $args) = @_;

  croak "Missing API ID." unless $$args{api_id};
  croak "Missing API key." unless $$args{api_key};
  croak "Missing logger." unless $$args{logger};
  croak "Invalid logger." unless ref $$args{logger} eq 'CODE';

  if(ref $$args{mode} eq 'HASH') {
    if(!$$mode{send_on}) {
      croak "Missing \$mode->{send_on}."
    }
    if($$mode{send_on} =~ /filesize_limit|filecount_limit|inverval/) {
      if(!$$mode{value}) {
        croak "Missing \$mode->{value}."
      }
      elsif($$mode{value} !~ /^[0-9]+$/) {
        croak "Invalid \$mode->{value}."
      }
    }
    elsif($$mode{send_on} ne 'letter_created') {
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

  foreach my $key (qw(Description Size PostalClass Data)) {
    croak "No '$key' provided." unless $$content{$key}
  }

  foreach my $key (qw(To From)) {
    if(ref $$content{$key} eq 'HASH') {
      foreach my $address_key (qw(Name AddressLine1 AddressLine2 City Zip)) {
        croak "No '$key->{$address_key}' provided." unless $$content{$key}->{$address_key}
      }
    }
    else {
      croak "No '$key' provided."
    }
  }

  #my $req = POST "$api_base_uri/letter/", Content => encode_json($content);

  #return $self->send_request($req)

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
    ...
  }
  elsif($self->{args}->{mode}->{send_on} eq 'filesize_limit') {
    ...
  }
}

sub send_queue {
  my ($self) = @_;

  my @queue = @{ $self->{letter_queue} };
  $self->{letter_queue} = [];

  foreach my $letter (@queue) {
    
  }

  # Create CSV
  # Zip it
  # Send
}

sub send_request {
  my ($self, $req, $args) = @_;

  $req->authorization_basic($$self{attribs}->{api_user}, $$self{attribs}->{api_pass});

  my $res = $self->{ua}->request($req);

  if($res->is_success) {
    return decode_json($res->decoded_content), $res
  }

  croak $res->decoded_content
}

1;