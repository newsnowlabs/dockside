use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Mojo::Message::Response;
use POSIX qw(_exit);
use Test::More;

# Exercise real database mutations and flock with disposable data; no Docker required.
my $tmp = tempdir(CLEANUP => 1);
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused' },
};
Util::flog({ file => "$tmp/test.log" });

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

subtest 'a fresh launch receives the count committed by recovery' => sub {
   no warnings 'redefine';
   local *Reservation::Mutate::call_socket_api_sync = sub {
      return Mojo::Message::Response->new->code(200)->body(
         encode_json({ Running => JSON::false, ExitCode => 0 }));
   };
   write_record({ id => 'review', name => 'review', data => {
      startCount => 0, hooks => { status => { 'launch:prep' => {
         name => 'launch:prep', state => 'running', execId => 'finished-exec',
         pendingStartCount => 1,
      } } },
   } });

   my ($written, $count) = Reservation::Mutate::launch_reset_stages_if_idle(
      'review', ['launch:prep'], 100);
   is($count, 1, 'caller receives the healed count for its next dispatch');
   is($written->{'launch:prep'}{state}, 'pending', 'next launch can dispatch prep');
   is(read_record()->{data}{startCount}, 1, 'healed count is persisted');
   my (undef, $again) = Reservation::Mutate::launch_reset_stages_if_idle(
      'review', ['launch:prep'], 100);
   is($again, 1, 'repeating reset does not count the same exec twice');
};

subtest 'expiry cleanup cannot delete a live create or replace its lock inode' => sub {
   # Terminally failed, so the ownership lock below is the only thing standing between this
   # record and deletion - a record still at a recoverable stage is retained for its own
   # reasons (the next subtest), which would make this one pass without testing the lock.
   write_record({ id => 'review', name => 'review', containerId => 'gone',
      createStatus => { stage => 'failed', failed => 1, error => 'create refused' },
      expiryTime => Util::YYYYMMDDHHMMSS(time - 90),
   });
   my $path = Reservation::_create_lock_path('review');
   my $lock = Util::tryLockFile($path);
   ok($lock, 'create driver acquires lock');
   my $inode = (stat($lock))[1];

   my $pid = fork();
   die "fork: $!" unless defined $pid;
   if (!$pid) {
      close $lock;   # cleaner must not retain the inherited driver descriptor
      Reservation::Mutate->load_clean_map();
      _exit(read_record() && -e $path ? 0 : 1);
   }
   waitpid($pid, 0);
   is($?, 0, 'sibling cleaner retains the active reservation and lock');
   is((stat($path))[1], $inode, 'lock inode is unchanged');
   ok(!Util::tryLockFile($path), 'second driver remains excluded');

   close $lock;
   Reservation::Mutate->load_clean_map();
   ok(!read_record(), 'expired record is deleted after create releases its lock');
   is((stat($path))[1], $inode, 'orphan inode remains until startup cleanup');
   my $next = Util::tryLockFile($path);
   ok($next, 'deletion guard is released after database write');
   close $next;
};

subtest 'expiry cleanup retains a reservation whose create is still recoverable' => sub {
   # No lock is held here: what protects this record is its own stage. A create that could not
   # establish whether its container exists keeps a non-terminal stage precisely so a later
   # reconciliation pass can find out, and deleting the record would discard the only thing that
   # remembers to ask - leaving the container running with nothing referring to it.
   for my $stage ( 'pulling', 'creating', 'starting' ) {
      write_record({ id => 'review', name => 'review', containerId => 'gone',
         createStatus => { stage => $stage, failed => 0, layers => {}, unresolved => {
            reason => 'create reported no usable outcome', attempts => 3,
         } },
         expiryTime => Util::YYYYMMDDHHMMSS(time - 90),
      });

      Reservation::Mutate->load_clean_map();

      my $record = read_record();
      ok( $record, "a reservation at '$stage' survives expiry cleanup" );
      ok( !$record->{'expiryTime'},
         "and its stale expiry is cleared, so nothing counts down against it at '$stage'" );
      is( $record->{'createStatus'}{'unresolved'}{'attempts'}, 3,
         "while its own record of what is unresolved is left intact at '$stage'" );
   }
};

done_testing;
