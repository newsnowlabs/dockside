use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Exception;
use File::Temp qw(tempdir);
use Test::More;

# run_hook_manual's immediate answer is what `dockside hook run` sizes its own wait from, so the
# run limit it reports must be the one the dispatch is given. Only the dispatch itself is
# stubbed, to capture what it was asked to enforce.
my $tmp = tempdir( CLEANUP => 1 );
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' }, hooks => { defaultTimeoutSeconds => 300 },
};
Util::flog( { file => "$tmp/test.log" } );

# Runs one manual invocation and returns what the caller was answered and what the dispatch was
# asked to enforce. 'claimed' false makes the claim lose, as a concurrent invocation would.
sub invoke (%opt) {
   my $r = bless { id => 'facade', name => 'devt' }, 'Reservation';
   my ( $answer, $dispatched );

   no warnings qw(redefine once);
   local *Reservation::hook_script = sub { return '/hook.sh' };
   local *Reservation::dispatch_hook_exec = sub ( $self, $name, $script, $args, $on_claimed, $on_settled ) {
      $dispatched = { 'name' => $name, 'args' => $args };
      $on_claimed->( ( $opt{'claimed'} // 1 ) ? { 'invocationId' => 'i' } : undef );
   };

   $r->run_hook_manual( $opt{'args'}, sub ( $data, $err = undef ) { $answer = $data } );
   return ( $answer, $dispatched );
}

subtest 'an invocation with no limit of its own reports and enforces the configured default' => sub {
   my ( $answer, $dispatched ) = invoke( 'args' => { 'name' => 'update' } );

   is( $answer->{'started'}, 1, 'the claim was won' );
   is( $answer->{'name'}, 'update', 'for the hook named' );
   is( $answer->{'timeout'}, 300, 'and the answer carries the configured default as its limit' );
   is( $dispatched->{'args'}{'timeout'}, 300, 'which is the limit the dispatch is given' );
};

subtest 'an invocation with its own limit reports and enforces that one' => sub {
   my ( $answer, $dispatched ) = invoke( 'args' => { 'name' => 'update', 'timeout' => 45 } );

   is( $answer->{'timeout'}, 45, 'the answer carries the request\'s own limit' );
   is( $dispatched->{'args'}{'timeout'}, 45, 'and the dispatch enforces it' );
};

subtest 'a limit that is not a positive integer is refused before any dispatch' => sub {
   for my $bad ( 'abc', '-5', '1.5', '0', 0 ) {
      my ( $answer, $dispatched );
      my $died = !eval { ( $answer, $dispatched ) = invoke( 'args' => { 'name' => 'update', 'timeout' => $bad } ); 1 };
      ok( $died, "timeout '$bad' is refused" );
      is( $@->status, 400, "as the caller's error" ) if ref $@;
      ok( !$dispatched, 'with nothing dispatched' );
   }
};

subtest 'a lost claim answers busy and reports no limit' => sub {
   my ( $answer, $dispatched ) = invoke( 'args' => { 'name' => 'update' }, 'claimed' => 0 );

   is( $answer->{'busy'}, 1, 'the caller is told the hook is already running' );
   ok( !exists $answer->{'timeout'}, 'and is given nothing to wait on' );
};

done_testing;
