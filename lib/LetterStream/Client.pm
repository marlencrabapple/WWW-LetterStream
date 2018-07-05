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

our $api_base_uri = 'https://print.directmailers.com/api/v1';

sub new {
  my ($class, $args) = @_;

  croak "Missing API username." unless $$args{api_user};
  croak "Missing API password." unless $$args{api_pass};
  croak "Missing mode." unless $$args{mode};

  my $attribs = { %$args };

  my $self = bless {}, $class;

  $$self{attribs} = $attribs;
  $$self{ua} = LWP::UserAgent->new;

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

  my $req = POST "$api_base_uri/letter/", Content => encode_json($content);

  return $self->send_request($req)
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