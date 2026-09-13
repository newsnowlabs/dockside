use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use File::Temp qw(tempdir);
use JSON qw(encode_json decode_json);
use Mojo::Message::Response;
use Test::More;

# Exercise real database mutations with disposable data; no Docker required.
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

done_testing;
