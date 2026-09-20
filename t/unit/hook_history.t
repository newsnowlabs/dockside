use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Reservation::Mutate;
use Util qw(YYYYMMDDHHMMSS);
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Test::More;

# A hook invocation's terminal status entry and its hooks.history row are one locked write, on
# every path that makes an entry terminal. These tests drive the real mutators against a
# disposable database and count the writes each one makes.
my $tmp = tempdir( CLEANUP => 1 );
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' },
};
Util::flog( { file => "$tmp/test.log" } );

my $REAL_MUTATE = \&Reservation::Mutate::mutate;
my $writes = 0;

sub write_record ($data) {
   open my $fh, '>', $Data::CONFIG->{reservationsPath} or die $!;
   print $fh encode_json( { id => 'r1', name => 'devt', data => $data } ), "\n";
   close $fh;
   $writes = 0;
}

sub read_data {
   open my $fh, '<', $Data::CONFIG->{reservationsPath} or die $!;
   local $/;
   return decode_json(<$fh>)->{'data'};
}

sub history { return read_data()->{'hooks'}{'history'} // [] }

# Counts every locked write the code under test makes, so a test can assert that an entry and
# its row went to disk together rather than one after the other.
{
   no warnings qw(redefine once);
   *Reservation::Mutate::mutate = sub (@args) {
      $writes++ if $args[0];
      return $REAL_MUTATE->(@args);
   };
}

my $running = sub ( $invocationId, %more ) {
   return { name => 'h', state => 'running', invocationId => $invocationId, execId => 'e', %more };
};

subtest 'an applied resolution writes the entry and its row together' => sub {
   write_record( { hooks => { status => { h => $running->('i1') } } } );

   my ( $applied, $entry ) = Reservation::Mutate::resolve_hook_status( 'r1', 'h', { state => 'done', exitCode => 0 }, 100, 'i1' );

   ok( $applied, 'the resolution is applied' );
   is( $writes, 1, 'in exactly one locked write' );
   is( read_data()->{'hooks'}{'status'}{'h'}{'state'}, 'done', 'which makes the entry terminal' );
   is( scalar @{ history() }, 1, 'and records its row' );
   is( history()->[0]{'invocationId'}, 'i1', 'for that invocation' );
   is( history()->[0]{'exitCode'}, 0, 'with the resolved fields' );
};

subtest 'a rejected resolution records no row' => sub {
   write_record( { hooks => { status => { h => $running->('i2') } } } );

   my ($applied) = Reservation::Mutate::resolve_hook_status( 'r1', 'h', { state => 'done' }, 100, 'stale' );

   ok( !$applied, 'the resolution is rejected' );
   is( scalar @{ history() }, 0, 'and leaves history untouched' );
};

subtest 'a second resolution of the same invocation replaces its row rather than adding one' => sub {
   write_record( { hooks => { status => { h => $running->('i3') } } } );

   Reservation::Mutate::resolve_hook_status( 'r1', 'h', { state => 'done', exitCode => 0 }, 100, 'i3' );
   Reservation::Mutate::resolve_hook_status( 'r1', 'h', { state => 'done', exitCode => 0, timedOut => 0 }, 100, 'i3' );

   is( scalar @{ history() }, 1, 'one row stands for the invocation' );
   is( history()->[0]{'timedOut'}, 0, 'carrying the later writer\'s fields' );
};

subtest 'rows without an invocation id are only ever appended' => sub {
   write_record( { hooks => { status => { h => { name => 'h', state => 'running' } } } } );

   Reservation::Mutate::resolve_hook_status( 'r1', 'h', { state => 'done' }, 100 );
   Reservation::Mutate::resolve_hook_status( 'r1', 'h', { state => 'done' }, 100 );

   is( scalar @{ history() }, 2, 'two resolutions with no id leave two rows' );
};

subtest 'eviction past the cap never removes a running row' => sub {
   write_record( {
      hooks => {
         status  => { h => $running->('i4') },
         history => [ { name => 'x', state => 'running', invocationId => 'live' }, { name => 'y', state => 'done', invocationId => 'old' } ],
      },
   } );

   Reservation::Mutate::resolve_hook_status( 'r1', 'h', { state => 'done' }, 2, 'i4' );

   my @ids = map { $_->{'invocationId'} } @{ history() };
   is_deeply( \@ids, [ 'live', 'i4' ], 'the oldest terminal row is evicted and the running one kept' );
};

subtest 'a claim that heals a stale entry writes the heal, its row and the claim together' => sub {
   my $stale = YYYYMMDDHHMMSS( time - 2 * $Reservation::HOOK_CLAIM_STALE_SECONDS );
   write_record( { hooks => { status => { h => { name => 'h', state => 'running', invocationId => 'dead', startTime => $stale } } } } );

   my $claimed = Reservation::Mutate::hook_claim_if_not_running( 'r1', 'h', "$tmp/log", 100, 'new' );

   ok( $claimed, 'the stale slot is claimed' );
   is( $writes, 1, 'in exactly one locked write' );
   is( read_data()->{'hooks'}{'status'}{'h'}{'invocationId'}, 'new', 'which the new invocation now owns' );
   is( scalar @{ history() }, 1, 'and which recorded the healed invocation' );
   is( history()->[0]{'invocationId'}, 'dead', 'by its own id' );
   is( history()->[0]{'state'}, 'aborted', 'as aborted, since nothing could account for it' );
};

subtest 'a stage reset that heals a stale entry writes the heal and its row together' => sub {
   my $stale = YYYYMMDDHHMMSS( time - 2 * $Reservation::HOOK_CLAIM_STALE_SECONDS );
   write_record( { hooks => { status => { s => { name => 's', state => 'running', invocationId => 'dead', startTime => $stale } } } } );

   Reservation::Mutate::launch_reset_stages_if_idle( 'r1', ['s'], 100 );

   is( $writes, 1, 'exactly one locked write' );
   is( read_data()->{'hooks'}{'status'}{'s'}{'state'}, 'pending', 'resets the stage' );
   is( scalar @{ history() }, 1, 'and records the healed invocation' );
   is( history()->[0]{'invocationId'}, 'dead', 'by its own id' );
};

done_testing;
