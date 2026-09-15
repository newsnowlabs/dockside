use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Data qw($CONFIG);
use Util qw(flog sanitize_sensitive_text);
use Try::Tiny;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Test::More;

my $tmp = tempdir(CLEANUP => 1);
$CONFIG = { tmpPath => $tmp, reservationsPath => "$tmp/reservations.json", docker => { socket => 'unused' } };
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

subtest 'hook dispatch in-flight counter clears even when resolving the outcome throws' => sub {
   seed({ name => 'foo', state => 'pending' });
   my $r = bless { id => 'review', data => { startCount => 1 } }, 'DispatchReservation';
   my ($opts, $settle);
   my $capture = sub ($socket, $container, $args, $options, $cb) { ($opts, $settle) = ($options, $cb); };
   no warnings qw(redefine once);
   local *User::load = sub { bless {}, 'User' };
   local *Reservation::docker_exec = $capture;
   local *DispatchReservation::hook_status_completed = sub { die "boom - resolution blew up\n"; };
   my $settled = 0;
   $r->dispatch_hook_exec('foo', 'true', {}, sub {}, sub { $settled++; });
   is(Reservation->hook_dispatch_in_flight_count(), 1, 'in flight while awaiting settle');
   $settle->({ exitCode => 0, timedOut => 0 }, undef);
   is(Reservation->hook_dispatch_in_flight_count(), 0, 'cleared even though resolving the outcome threw');
   is($settled, 1, "the callback's own catch block still drives on_settled once");
};

done_testing;
