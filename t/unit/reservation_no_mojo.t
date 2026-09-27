use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use B ();
use Reservation;
use Test::More;

# Reservation.pm is domain logic and names the framework nowhere: the create chain's timer and
# recycling hold come from the process that loads the module (Reservation::provider), its clock
# is Perl's own, and its transport is Util.pm, the one place Mojo::UserAgent is used. That
# transport loads Mojo into every process regardless, so this is checked at the source and in
# the package's symbol table, not in %INC.
my $lib = "$FindBin::Bin/../../app/server/lib";

for my $file ( "$lib/Reservation.pm", sort glob("$lib/Reservation/*.pm") ) {
   open my $fh, '<', $file or die "$file: $!";
   my @naming = grep { /Mojo/ } <$fh>;
   close $fh;
   ( my $name = $file ) =~ s{^\Q$lib\E/}{};
   is( scalar @naming, 0, "$name names Mojo nowhere" ) or diag( join '', @naming );
}

# steady_time is Mojo::Util's monotonic clock; the chain's own is Time::HiRes.
ok( !defined &Reservation::steady_time, 'the Reservation package holds no steady_time' );

my @fromMojo;
{
   no strict 'refs';
   for my $symbol ( sort keys %Reservation:: ) {
      my $code = *{"Reservation::$symbol"}{CODE} or next;
      my $origin = eval { B::svref_2object($code)->GV->STASH->NAME } // '';
      push @fromMojo, "$symbol (from $origin)" if $origin =~ /^Mojo/;
   }
}
is( scalar @fromMojo, 0, 'the Reservation package imports nothing defined in a Mojo:: package' )
   or diag( join "\n", @fromMojo );

done_testing;
