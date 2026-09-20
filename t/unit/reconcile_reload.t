use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use File::Temp qw(tempdir);
use JSON qw(encode_json);
use Test::More;

my $tmp = tempdir(CLEANUP => 1);
$Data::CONFIG = { tmpPath => $tmp, reservationsPath => "$tmp/reservations.json" };
Util::flog({ file => "$tmp/test.log" });
my $stamp = time - 10;

sub write_stage ($stage) {
   open my $fh, '>', $Data::CONFIG->{reservationsPath} or die $!;
   print $fh encode_json({ id => 'review', name => 'review', version => 2,
      data => {}, createStatus => { stage => $stage } }), "\n";
   close $fh;
   # Deterministically reproduce distinct writes sharing a filesystem timestamp.
   utime $stamp, $stamp, $Data::CONFIG->{reservationsPath} or die $!;
}

no warnings 'redefine';
# Container indexes and profile routers are irrelevant to ownership arbitration.
local *Reservation::routers = sub { {} };
local *Reservation::update_container_info = sub {};
my $resumed = 0;
local *Reservation::reconcile_create = sub { $resumed++ };
# Ownership arbitration needs neither primitive; both are present so the entry is admitted.
Reservation::provider( 'timer' => sub (@) { }, 'hold' => sub () { return sub { }; } );

write_stage('pulling');
Data::load('reservations.json');
is($Reservation::BY_ID->{review}{createStatus}{stage}, 'pulling', 'worker has non-terminal candidate');
write_stage('done');
Data::load('reservations.json');
is($Reservation::BY_ID->{review}{createStatus}{stage}, 'pulling', 'timestamp cache still has old candidate');
is(Reservation->reconcile_one('review'), 0, 'reconcile skips a candidate that settled before lock acquisition');
is($resumed, 0, 'no second driver starts');
is($Reservation::BY_ID->{review}{createStatus}{stage}, 'done', 'ownership check refreshes the cached record');
my $lock = Util::tryLockFile(Reservation::_create_lock_path('review'));
ok($lock, 'terminal skip releases lock');
close $lock;

done_testing;
