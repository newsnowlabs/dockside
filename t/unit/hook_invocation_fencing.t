use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
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

done_testing;
