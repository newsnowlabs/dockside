use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Data qw($CONFIG);
use Util qw(flog sanitize_sensitive_text);
use Try::Tiny;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Mojo::IOLoop;
use Mojo::Message::Response;
use Test::More;

# Retries of an outcome write that threw are scheduled on the event loop, so anything past the
# first attempt needs the loop run to be observable.
sub pump_until ( $cond, $limit = 5 ) {
   return if $cond->();
   my $deadline = Mojo::IOLoop->timer( $limit => sub { Mojo::IOLoop->stop } );
   my $poll = Mojo::IOLoop->recurring( 0.005 => sub { Mojo::IOLoop->stop if $cond->() } );
   Mojo::IOLoop->start;
   Mojo::IOLoop->remove($_) for $deadline, $poll;
   return;
}

my $tmp = tempdir(CLEANUP => 1);
$CONFIG = { tmpPath => $tmp, reservationsPath => "$tmp/reservations.json", docker => { socket => 'unused' }, hooks => { defaultTimeoutSeconds => 5 } };
flog({ file => "$tmp/log" });
sub seed ($entry, $count = 1) {
   open my $fh, '>', $CONFIG->{reservationsPath} or die $!;
   print $fh encode_json({ id => 'review', name => 'review', data => {
      startCount => $count, hooks => { status => { foo => $entry } },
   } }), "\n";
   close $fh;
}
sub read_record {
   open my $fh, '<', $CONFIG->{reservationsPath} or die $!;
   return decode_json(<$fh>);
}

use EventDaemon::LaunchDispatch;
my $dispatch = \&EventDaemon::LaunchDispatch::_launch_dispatch_exec;

{
   package DispatchReservation;
   our @ISA = ('Reservation');
   sub ide_command { ('/bin/sh', 'launch') }
   sub owner { 'owner' }
   sub unixuser { 'owner' }
   sub _hook_env { () }
   sub ide_command_env { () }
   sub containerId { 'container' }
}

for my $mode ('manual', 'attached', 'detached') {
   for my $race ('none', 'before-created', 'after-created', 'reset') {
      subtest "$mode dispatch / $race" => sub {
         seed({ name => 'foo', state => 'pending' });
         my $r = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
         my ($opts, $settle);
         my $capture = sub ($socket, $container, $args, $options, $cb) {
            ($opts, $settle) = ($options, $cb);
         };
         no warnings qw(redefine once);
         local *User::load = sub { bless {}, 'User' };
         local *EventDaemon::LaunchDispatch::docker_exec = $capture;
         local *Reservation::docker_exec = $capture;
         my $continuations = 0;
         if ($mode eq 'manual') {
            $r->dispatch_hook_exec('foo', 'true', {}, sub {}, sub { $continuations++ });
         }
         else {
            $dispatch->($r, 'foo', 'launch', 'root', {
               detach => ($mode eq 'detached'), increment_start_count => 1,
               pending_fields => ($mode eq 'attached' ? { pendingStartCount => 2 } : {}),
            }, sub { $continuations++ });
         }
         ok($opts && $settle, 'dispatch reached async boundary');
         my $replacement = { name => 'foo', state => 'running', invocationId => 'new', execId => 'new-exec', pendingStartCount => 7 };
         seed($replacement) if $race eq 'before-created';
         is(!!$opts->{on_created}->('original-exec'), $race ne 'before-created' ? 1 : '', 'exec assignment checks captured token');
         seed($replacement) if $race eq 'after-created';
         if ($race eq 'reset') {
            seed({ name => 'foo', state => 'done', invocationId => 'original' });
            Reservation::Mutate::launch_reset_stages_if_idle('review', ['foo'], 100);
         }
         my $before = read_record();
         $settle->({ exitCode => 0, timedOut => 0 }, undef);
         if ($race eq 'none') {
            is($continuations, 1, 'current dispatch continues');
            is(read_record()->{data}{startCount}, $mode eq 'manual' ? 1 : 2, 'current launch commits count');
         }
         else {
            is($continuations, 0, 'superseded dispatch suppresses continuation');
            is_deeply(read_record(), $before, 'superseded dispatch leaves persisted state intact');
         }
      };
   }
}
subtest 'in-flight counter tracks a non-detached dispatch and clears on settle' => sub {
   seed({ name => 'foo', state => 'pending' });
   my $r = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
   my ($opts, $settle);
   my $capture = sub ($socket, $container, $args, $options, $cb) { ($opts, $settle) = ($options, $cb); };
   no warnings qw(redefine once);
   local *User::load = sub { bless {}, 'User' };
   local *EventDaemon::LaunchDispatch::docker_exec = $capture;
   is(EventDaemon::LaunchDispatch::in_flight_count(), 0, 'nothing in flight before dispatch');
   $dispatch->($r, 'foo', 'launch', 'root', {}, sub {});
   is(EventDaemon::LaunchDispatch::in_flight_count(), 1, 'one non-detached dispatch in flight');
   $settle->({ exitCode => 0, timedOut => 0 }, undef);
   is(EventDaemon::LaunchDispatch::in_flight_count(), 0, 'cleared once settled');
};

subtest 'in-flight counter never counts a detached dispatch' => sub {
   seed({ name => 'foo', state => 'pending' });
   my $r = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
   my ($opts, $settle);
   my $capture = sub ($socket, $container, $args, $options, $cb) { ($opts, $settle) = ($options, $cb); };
   no warnings qw(redefine once);
   local *User::load = sub { bless {}, 'User' };
   local *EventDaemon::LaunchDispatch::docker_exec = $capture;
   $dispatch->($r, 'foo', 'launch', 'root', { detach => 1, increment_start_count => 1 }, sub {});
   is(EventDaemon::LaunchDispatch::in_flight_count(), 0, 'a detached dispatch never registers as in flight');
   $settle->({}, undef);
   is(EventDaemon::LaunchDispatch::in_flight_count(), 0, 'still zero after settling');
};

subtest 'in-flight counter clears even when resolving the outcome throws' => sub {
   seed({ name => 'foo', state => 'pending' });
   my $r = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
   my ($opts, $settle);
   my $capture = sub ($socket, $container, $args, $options, $cb) { ($opts, $settle) = ($options, $cb); };
   no warnings qw(redefine once);
   local *User::load = sub { bless {}, 'User' };
   local *EventDaemon::LaunchDispatch::docker_exec = $capture;
   local *DispatchReservation::hook_status_completed = sub { die "boom - resolution blew up\n"; };
   my $continuations = 0;
   $dispatch->($r, 'foo', 'launch', 'root', {}, sub { $continuations++ });
   is(EventDaemon::LaunchDispatch::in_flight_count(), 1, 'in flight while awaiting settle');
   $settle->({ exitCode => 0, timedOut => 0 }, undef);
   is(EventDaemon::LaunchDispatch::in_flight_count(), 0, 'cleared even though resolving the outcome threw');
   is($continuations, 1, "the callback's own catch block still drives the continuation once");
};

subtest 'hook dispatch in-flight counter tracks a manual invocation and clears on settle' => sub {
   seed({ name => 'foo', state => 'pending' });
   my $r = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
   my ($opts, $settle);
   my $capture = sub ($socket, $container, $args, $options, $cb) { ($opts, $settle) = ($options, $cb); };
   no warnings qw(redefine once);
   local *User::load = sub { bless {}, 'User' };
   local *Reservation::docker_exec = $capture;
   is(Reservation->hook_dispatch_in_flight_count(), 0, 'nothing in flight before dispatch');
   $r->dispatch_hook_exec('foo', 'true', {}, sub {}, sub {});
   is(Reservation->hook_dispatch_in_flight_count(), 1, 'one hook dispatch in flight');
   $settle->({ exitCode => 0, timedOut => 0 }, undef);
   is(Reservation->hook_dispatch_in_flight_count(), 0, 'cleared once settled');
};

subtest 'hook dispatch in-flight counter is held until the outcome is actually written' => sub {
   seed({ name => 'foo', state => 'pending' });
   my $r = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
   my ($opts, $settle);
   my $capture = sub ($socket, $container, $args, $options, $cb) { ($opts, $settle) = ($options, $cb); };
   no warnings qw(redefine once);
   local *User::load = sub { bless {}, 'User' };
   local *Reservation::docker_exec = $capture;

   my ( $failing, $writes ) = ( 1, 0 );
   local *DispatchReservation::hook_status_completed = sub ( $self, @args ) {
      $writes++;
      die "boom - resolution blew up\n" if $failing;
      return Reservation::hook_status_completed( $self, @args );
   };

   my $settled = 0;
   $r->dispatch_hook_exec('foo', 'true', {}, sub {}, sub { $settled++; });
   is(Reservation->hook_dispatch_in_flight_count(), 1, 'in flight while awaiting settle');

   $settle->({ exitCode => 0, timedOut => 0 }, undef);
   is(Reservation->hook_dispatch_in_flight_count(), 1,
      'still in flight while the outcome cannot be written - this count is what a drain reads, '
      . 'and an unrecorded outcome is not a settled one');
   is($settled, 0, 'no settlement is reported for an outcome that was never recorded');

   pump_until(sub { $writes >= 3 }, 3);
   cmp_ok($writes, '>=', 3, 'the write is retried rather than abandoned');

   $failing = 0;
   pump_until(sub { Reservation->hook_dispatch_in_flight_count() == 0 }, 3);
   is(Reservation->hook_dispatch_in_flight_count(), 0, 'cleared once the outcome is finally written');
   is($settled, 1, 'and on_settled is driven exactly once, at that point');
};

subtest 'drain_complete reflects both in-flight counters, not just one' => sub {
   seed({ name => 'foo', state => 'pending' });
   my $rLaunch = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
   my ($opts, $settle);
   my $capture = sub ($socket, $container, $args, $options, $cb) { ($opts, $settle) = ($options, $cb); };
   no warnings qw(redefine once);
   local *User::load = sub { bless {}, 'User' };

   ok(EventDaemon::LaunchDispatch::drain_complete(), 'nothing in flight to begin with');

   local *EventDaemon::LaunchDispatch::docker_exec = $capture;
   $dispatch->($rLaunch, 'foo', 'launch', 'root', {}, sub {});
   ok(!EventDaemon::LaunchDispatch::drain_complete(), 'a non-detached DAG dispatch alone is enough to block drain');
   $settle->({ exitCode => 0, timedOut => 0 }, undef);
   ok(EventDaemon::LaunchDispatch::drain_complete(), 'clears once that dispatch settles');

   seed({ name => 'foo', state => 'pending' });
   my $rHook = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
   local *Reservation::docker_exec = $capture;
   $rHook->dispatch_hook_exec('foo', 'true', {}, sub {}, sub {});
   ok(!EventDaemon::LaunchDispatch::drain_complete(), 'a manual/lifecycle hook dispatch alone is also enough to block drain');
   $settle->({ exitCode => 0, timedOut => 0 }, undef);
   ok(EventDaemon::LaunchDispatch::drain_complete(), 'clears once that dispatch settles too');
};

subtest 'in-flight counter does not leak when the real docker_exec hits a malformed create response' => sub {
   seed({ name => 'foo', state => 'pending' });
   my $r = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
   no warnings qw(redefine once);
   local *User::load = sub { bless {}, 'User' };
   # Deliberately not stubbing docker_exec itself - this exercises the real Util::docker_exec,
   # so a leak from an exception inside its own internals would actually show up here.
   local *Util::call_socket_api = sub ($socket, $path, $args, $cb) {
      $cb->(Mojo::Message::Response->new->code(201)->body('{not valid json'), undef);
   };
   my $continuations = 0;
   $dispatch->($r, 'foo', 'launch', 'root', {}, sub { $continuations++ });
   is(EventDaemon::LaunchDispatch::in_flight_count(), 0, 'a malformed create response does not leak the counter');
   is($continuations, 1, 'the dispatch still settles (as failed) via the real docker_exec');
   is(read_record()->{data}{hooks}{status}{foo}{state}, 'failed', 'the stage itself resolves failed, not stuck running');
};

subtest 'hook dispatch in-flight counter does not leak when the real docker_exec hits a malformed create response' => sub {
   seed({ name => 'foo', state => 'pending' });
   my $r = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
   no warnings qw(redefine once);
   local *User::load = sub { bless {}, 'User' };
   local *Util::call_socket_api = sub ($socket, $path, $args, $cb) {
      $cb->(Mojo::Message::Response->new->code(201)->body('{not valid json'), undef);
   };
   my $settled = 0;
   $r->dispatch_hook_exec('foo', 'true', {}, sub {}, sub { $settled++; });
   is(Reservation->hook_dispatch_in_flight_count(), 0, 'a malformed create response does not leak the counter');
   is($settled, 1, 'on_settled still fires via the real docker_exec');
};

done_testing;
