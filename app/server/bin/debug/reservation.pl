#!/usr/bin/perl

BEGIN {
   unshift(@INC, "$ENV{'HOME'}/dockside/app/server/lib");
};

use Data qw($CONFIG);
use User;

use Data::Dumper;
use Getopt::Long;

my $Options = {};
&GetOptions( $Options, "id=s", 'containerId=s' );

unless($Options->{'id'} || $Options->{'containerId'}) {
   print STDERR <<'_EOE_'
Usage: $0 
_EOE_
   ;
   exit(-1);
}

Data::load();

my $Reservations = Reservation->load( $Options );

print STDERR "Reservations loaded...\n";

print Data::Dumper->new($Reservations)->Sortkeys(1)->Indent(1)->Deepcopy(1)->Dump;

print STDERR "End.\n";

1;
