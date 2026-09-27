use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Reservation;
use Profile;
use Exception;
use File::Temp qw(tempdir);
use Test::More;

# A profile's dockerArgs entries are free-form strings that cmdline_json translates into fields
# of the Create API body, one flag pattern at a time. These tests pin what each accepted pattern
# becomes and that an entry outside the set is refused before any container exists.
my $tmp = tempdir( CLEANUP => 1 );
$Data::CONFIG = {
   tmpPath => $tmp, reservationsPath => "$tmp/reservations.json",
   docker => { socket => 'unused', security => {} },
   ide => { path => '/opt/dockside' }, ssh => { path => '/home/dockside/.ssh' },
   lxcfs => { available => 0 },
};
$Data::INNER_DOCKERD = 1;
Util::flog( { file => "$tmp/test.log" } );

# The smallest reservation cmdline_json can render: no mounts, no IDE volume, no ssh, no init.
sub reservation (@dockerArgs) {
   my $profile = Profile->new( {
      version => Profile::CURRENT_VERSION(), name => 'p',
      mounts => { tmpfs => [], bind => [], volume => [] },
      dockerArgs => \@dockerArgs, command => ['sleep'],
      ssh => 0, mountIDE => 0, runDockerInit => 0, security => {},
   }, 1 );
   return bless {
      id => 'rid', name => 'devt', profile => 'p', profileObject => $profile,
      data => { image => 'img:1' }, owner => {},
   }, 'Reservation';
}

subtest 'a stop timeout becomes the container config StopTimeout' => sub {
   my $body = reservation('--stop-timeout=20')->cmdline_json();
   is( $body->{'StopTimeout'}, 20, 'the number of seconds declared' );
   ok( !exists $body->{'HostConfig'}{'StopTimeout'}, 'and lives at the top level, not in HostConfig' );
};

subtest 'a profile declaring no stop timeout sends none' => sub {
   my $body = reservation('--pids-limit=4000')->cmdline_json();
   ok( !exists $body->{'StopTimeout'}, 'so the container keeps Docker default' );
   is( $body->{'HostConfig'}{'PidsLimit'}, 4000, 'while the other entries still apply' );
};

subtest 'the largest value Docker integer fields hold is accepted as a number' => sub {
   my $body = reservation('--stop-timeout=2147483647')->cmdline_json();
   is( $body->{'StopTimeout'}, 2147483647, 'accepted' );
   like( JSON->new->encode($body), qr/"StopTimeout":2147483647/, 'and encoded as a JSON number' );
};

subtest 'a stop timeout that is not a whole number of seconds Docker can hold is refused' => sub {
   for my $arg ( '--stop-timeout=abc', '--stop-timeout=1.5', '--stop-timeout=-1', '--stop-timeout',
                 '--stop-timeout=2147483648', '--stop-timeout=' . ( '9' x 400 ) ) {
      my $err;
      eval { reservation($arg)->cmdline_json(); 1 } or $err = $@;
      ok( ref($err) eq 'Exception', "'$arg' is refused" );
      like( $err->msg, qr/\Q$arg\E/, 'naming the entry' ) if ref($err) eq 'Exception';
   }
};

done_testing;
