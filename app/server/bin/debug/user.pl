#!/usr/bin/perl

BEGIN {
   unshift(@INC, "$ENV{'HOME'}/dockside/app/server/lib");
};

use Data qw($CONFIG);
use Request;
use User;

use Data::Dumper;
use Getopt::Long;

sub Usage {
   print STDERR <<'_EOE_'
Usage: $0 --cookie <urlencoded-auth-cookie> --protocol <http|https> --username <username> --password <password>
_EOE_
   ;
   exit(-1);
}

my $Options = {};
&GetOptions( $Options, 'cookie=s', 'protocol=s', 'username=s', 'password=s' );

Data::load();

my $User;

if($Options->{'cookie'}) {
   $User = Request->authenticate( {
      'cookie' => "$CONFIG->{'uidCookie'}{'name'}=" . $Options->{'cookie'},
      'protocol' => $Options->{'protocol'} || 'https'
   });
}
elsif( $Options->{'username'} ) {
   $User = Request->authenticate_by_credentials( $Options->{'username'}, $Options->{'password'} );
}
else {
   Usage();
}

print Data::Dumper->new([$User])->Sortkeys(1)->Indent(1)->Deepcopy(1)->Dump;

my $r = $User->reservations({'client' => 1});
print Data::Dumper->new($r)->Sortkeys(1)->Indent(1)->Deepcopy(1)->Dump;

my $profiles = $User->profiles();
print Data::Dumper->new([$profiles])->Sortkeys(1)->Indent(1)->Deepcopy(1)->Dump;

my $dummy = $User->createClientReservation();
print Data::Dumper->new([$dummy])->Sortkeys(1)->Indent(1)->Deepcopy(1)->Dump;

print STDERR "End.\n";

1;
