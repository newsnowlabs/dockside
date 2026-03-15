#!/usr/bin/perl

BEGIN {
   unshift(@INC, "$ENV{'HOME'}/dockside/app/server/lib");
};

use Data qw($CONFIG);
use User;

use Data::Dumper;
use Getopt::Long;

my $Options = {};
&GetOptions( $Options, "profile=s" );

unless($Options->{'profile'}) {
   print STDERR <<'_EOE_'
Usage: $0 --profile <profile-id>
_EOE_
   ;
   exit(-1);
}

Data::load();

$Options->{'profile'} =~ s|^.*/([^/]+)$|$1|;
$Options->{'profile'} =~ s/\.json$//;

my $Profile = Profile->load( $Options->{'profile'} );

print STDERR "Profile loaded = '$Profile'\n";

print Data::Dumper->new([$Profile])->Sortkeys(1)->Indent(1)->Deepcopy(1)->Dump;

print STDERR "End.\n";

1;
