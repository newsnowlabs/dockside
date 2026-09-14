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
done_testing;
