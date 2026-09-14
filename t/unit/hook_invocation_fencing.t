use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Exception;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Mojo::Message::Response;
use Test::More;

# Exercise real database mutations and flock with disposable data; no Docker required.
my $tmp = tempdir(CLEANUP => 1);
my $logPath = "$tmp/test.log";
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' },
};
Util::flog({ file => $logPath });

sub write_record ($record) {
   open my $fh, '>', $Data::CONFIG->{reservationsPath} or die $!;
   print $fh encode_json($record), "\n";
   close $fh;
}

sub read_record {
   open my $fh, '<', $Data::CONFIG->{reservationsPath} or die $!;
   local $/;
   my $text = <$fh>;
   return length($text) ? decode_json($text) : undef;
}

sub read_log {
   open my $fh, '<', $logPath or die $!;
   local $/;
   return <$fh> // '';
}

subtest 'resolve_hook_status rejects a completion whose invocationId no longer owns the slot' => sub {
   write_record({ id => 'review', name => 'review', data => {
      startCount => 1, hooks => { status => { 'lifecycle:start' => {
         name => 'lifecycle:start', state => 'running', execId => 'new-exec',
         invocationId => 'new-invocation', pendingStartCount => 2,
      } } },
   } });

   my ( $applied, $entry, $startCount ) = Reservation::Mutate::resolve_hook_status(
      'review', 'lifecycle:start', { 'state' => 'done', 'exitCode' => 0 }, 'old-invocation' );
   is( $applied, 0, 'a stale invocationId is rejected' );
   is( $entry->{'state'}, 'running', 'the entry returned is the current, unresolved one' );
   is( $entry->{'invocationId'}, 'new-invocation', 'ownership is reported as the current invocation' );
   is( $startCount, 1, 'pendingStartCount is not committed by a rejected write' );
   is( read_record()->{'data'}{'startCount'}, 1, 'persisted startCount is untouched' );
   is( read_record()->{'data'}{'hooks'}{'status'}{'lifecycle:start'}{'state'}, 'running',
      'persisted entry is untouched' );

   ( $applied, $entry, $startCount ) = Reservation::Mutate::resolve_hook_status(
      'review', 'lifecycle:start', { 'state' => 'done', 'exitCode' => 0 }, 'new-invocation' );
   is( $applied, 1, 'the current invocationId is accepted' );
   is( $entry->{'state'}, 'done', 'the write is applied' );
   is( $startCount, 2, 'pendingStartCount is committed once the owning invocation resolves it' );
};

subtest 'a delayed hook_is_running self-heal cannot overwrite a reclaimed slot' => sub {
   write_record({ id => 'review', name => 'review', data => {
      startCount => 3, hooks => { status => { 'foo' => {
         name => 'foo', state => 'running', execId => 'new-exec',
         invocationId => 'new-invocation', pendingStartCount => 5,
      } } },
   } });

   # An in-memory Reservation whose own view of 'foo' still shows the invocation that this
   # slot has since been reclaimed from - exactly what a delayed self-heal call would be
   # working from, having read this earlier and only now finished a slow liveness probe.
   my $stale = bless {
      'id' => 'review',
      'data' => { 'startCount' => 3, 'hooks' => { 'status' => { 'foo' => {
         'name' => 'foo', 'state' => 'running', 'execId' => 'old-exec',
         'invocationId' => 'old-invocation', 'startTime' => Util::YYYYMMDDHHMMSS(time),
      } } } },
   }, 'Reservation';

   no warnings 'redefine';
   local *Reservation::call_socket_api_sync = sub {
      return Mojo::Message::Response->new->code(200)->body(
         encode_json({ 'Running' => JSON::false, 'ExitCode' => 0 }));
   };

   is( $stale->hook_is_running('foo'), 0, 'reports not-running, same as any other resolved check' );

   is( read_record()->{'data'}{'hooks'}{'status'}{'foo'}{'state'}, 'running',
      'the reclaiming invocation\'s entry is untouched' );
   is( read_record()->{'data'}{'hooks'}{'status'}{'foo'}{'invocationId'}, 'new-invocation',
      'ownership is unchanged' );
   is( read_record()->{'data'}{'startCount'}, 3, 'pendingStartCount is not stolen by the stale heal' );

   is( $stale->{'data'}{'hooks'}{'status'}{'foo'}{'invocationId'}, 'new-invocation',
      'the caller\'s own in-memory copy is corrected to the genuinely current entry' );
   like( read_log(), qr/resolve rejected.*expected invocationId 'old-invocation'.*current is 'new-invocation'/,
      'the rejected write is logged once, naming both invocations' );
};

subtest 'late exec assignment preserves a replacement claim and its count' => sub {
   my $old = { name => 'launch:prep', state => 'running', invocationId => 'old', pendingStartCount => 2 };
   my $new = { name => 'launch:prep', state => 'running', invocationId => 'new', execId => 'new-exec', pendingStartCount => 3 };
   write_record({ id => 'review', name => 'review', data => {
      startCount => 1, hooks => { status => { 'launch:prep' => $new } },
   } });
   my $stale = bless { id => 'review', data => { hooks => { status => { 'launch:prep' => $old } } } }, 'Reservation';
   ok(!$stale->hook_status_set_running_details('launch:prep', 'old-exec', 'old'), 'late assignment rejected');
   is_deeply(read_record()->{data}{hooks}{status}{'launch:prep'}, $new, 'replacement entry unchanged');
   ok(!$stale->hook_status_completed('launch:prep', { state => 'done' }, 'old'), 'old completion still rejected after local refresh');
   is(read_record()->{data}{startCount}, 1, 'replacement prospective count uncommitted');
   ok($stale->hook_status_set_running_details('launch:prep', 'current-exec', 'new'), 'owner can assign exec');
   is(read_record()->{data}{hooks}{status}{'launch:prep'}{pendingStartCount}, 3, 'progress write retains pending count');
};

subtest 'reset and legacy entries require the observed identity' => sub {
   write_record({ id => 'review', name => 'review', data => { hooks => { status => {
      foo => { name => 'foo', state => 'done', invocationId => 'old' },
   } } } });
   Reservation::Mutate::launch_reset_stages_if_idle('review', ['foo'], 100);
   my $r = bless { id => 'review' }, 'Reservation';
   ok(!$r->hook_status_completed('foo', { state => 'done' }, 'old'), 'reset pending slot rejects old completion');
   is(read_record()->{data}{hooks}{status}{foo}{state}, 'pending', 'next cycle remains pending');
   ok(!$r->hook_status_completed('foo', { state => 'done' }, ''), 'legacy observer cannot complete a reset slot');
   ok(!$r->hook_status_set_running_details('foo', 'old-exec', 'old'), 'reset slot rejects exec assignment');

   write_record({ id => 'review', name => 'review', data => { hooks => { status => {
      foo => { name => 'foo', state => 'running', invocationId => 'new' },
   } } } });
   my $legacy = bless { id => 'review', data => { hooks => { status => {
      foo => { name => 'foo', state => 'running', startTime => '20000101000000' },
   } } } }, 'Reservation';
   $legacy->hook_is_running('foo');
   is(read_record()->{data}{hooks}{status}{foo}{invocationId}, 'new', 'legacy observer cannot overwrite new claim');
   is(read_record()->{data}{hooks}{status}{foo}{state}, 'running', 'legacy observer leaves winner running');

   write_record({ id => 'review', name => 'review', data => { hooks => { status => {
      foo => { name => 'foo', state => 'running', startTime => '20000101000000' },
   } } } });
   my $current = bless { id => 'review', data => read_record()->{data} }, 'Reservation';
   $current->hook_is_running('foo');
   is(read_record()->{data}{hooks}{status}{foo}{state}, 'aborted', 'current legacy claim can still self-heal');
};

subtest 'detached start confirmation is fenced and counts once' => sub {
   write_record({ id => 'review', name => 'review', data => {
      startCount => 4, hooks => { status => {
         'launch:ide' => { name => 'launch:ide', state => 'running', invocationId => 'new' },
      } },
   } });
   my $r = bless { id => 'review' }, 'Reservation';
   ok(!$r->hook_status_dispatch_started('launch:ide', 'old', 1), 'superseded detached start rejected');
   is(read_record()->{data}{startCount}, 4, 'stale detached start cannot increment count');
   ok($r->hook_status_dispatch_started('launch:ide', 'new', 1), 'current detached start accepted');
   is(read_record()->{data}{startCount}, 5, 'current start increments count');
   ok($r->hook_status_dispatch_started('launch:ide', 'new', 1), 'repeat confirmation accepted');
   is(read_record()->{data}{startCount}, 5, 'confirmation counts once');
};

subtest 'docker_exec does not start an exec whose claim was rejected' => sub {
   for my $detach (0, 1) {
      my (@requests, @settled);
      no warnings 'redefine';
      local *Util::call_socket_api = sub ($socket, $path, $args, $cb) {
         push @requests, $path;
         $cb->(Mojo::Message::Response->new->code(201)->body(encode_json({ Id => 'old-exec' })), undef);
      };
      Util::docker_exec('unused', 'container', { Cmd => ['true'] }, {
         Detach => $detach, on_created => sub { 0 },
      }, sub { push @settled, [@_] });
      is_deeply(\@requests, ['/containers/container/exec'], "rejected exec never starts (detach=$detach)");
      is(scalar @settled, 1, 'failure callback fires once');
      ok(!defined($settled[0][0]), 'failure has no successful result');
   }
};

subtest 'docker_exec starts accepted dispatches and reports callback exceptions' => sub {
   for my $detach (0, 1) {
      for my $authorization ('accept', 'absent', 'exception', 'exception_hash', 'exception_msg_only') {
         my (@requests, @settled);
         no warnings 'redefine';
         local *Util::call_socket_api = sub ($socket, $path, $args, $cb) {
            push @requests, $path;
            my $body = $path =~ m{/containers/} ? { Id => 'exec' } : { ExitCode => 0 };
            $cb->(Mojo::Message::Response->new->code($path =~ m{/containers/} ? 201 : 200)->body(encode_json($body)), undef);
         };
         my $onCreated = sub {
            die "fixture failure" if $authorization eq 'exception';
            die { message => 'fixture hash' } if $authorization eq 'exception_hash';   # unblessed reference
            die Exception->new('msg' => 'fixture msg') if $authorization eq 'exception_msg_only';   # no dbg set
            1;
         };
         Util::docker_exec('unused', 'container', { Cmd => ['true'] }, {
            Detach => $detach,
            ($authorization eq 'absent' ? () : (on_created => $onCreated)),
         }, sub { push @settled, [@_] });
         my $isException = $authorization =~ /^exception/;
         is(scalar @settled, 1, "$authorization callback settles once (detach=$detach)");
         is(scalar @requests, $isException ? 1 : $detach ? 2 : 3, 'only accepted dispatch reaches start');
         is(defined($settled[0][0]) ? 1 : 0, $isException ? 0 : 1, 'result matches authorization');
         if ($authorization eq 'exception') {
            like($settled[0][1], qr/fixture failure/, 'a string exception reaches the caller, not just a fixed string');
         }
         elsif ($authorization eq 'exception_hash') {
            like($settled[0][1], qr/start authorization failed/, 'an unblessed-reference exception still settles, without crashing formatting');
         }
         elsif ($authorization eq 'exception_msg_only') {
            like($settled[0][1], qr/fixture msg/, 'a dbg-less Exception falls back to its own msg');
         }
      }
   }
};

done_testing;
