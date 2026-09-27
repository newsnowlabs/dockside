use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Util qw(loop_timer);
use Mojo::IOLoop;
use Time::HiRes qw(time);
use Test::More;

# Util::loop_timer is the timer a process installs for Reservation's create chain: the callback
# runs once, after the delay, with no arguments, so a consumer declaring a zero-argument
# signature is satisfied by it.
my @calls;
my $before = time;
my $id = loop_timer( 0.05, sub (@args) { push @calls, [ time - $before, @args ]; Mojo::IOLoop->stop } );
ok( defined($id) && length($id), 'the loop id for the timer is returned' );

my $timeout = Mojo::IOLoop->timer( 2 => sub { Mojo::IOLoop->stop } );
Mojo::IOLoop->start;
Mojo::IOLoop->remove($timeout);

is( scalar @calls, 1, 'the callback ran once' );
ok( $calls[0][0] >= 0.05, 'after the delay' );
is( scalar @{ $calls[0] }, 1, 'with no arguments' );

my $strict = 0;
loop_timer( 0.01, sub () { $strict++; Mojo::IOLoop->stop } );
$timeout = Mojo::IOLoop->timer( 2 => sub { Mojo::IOLoop->stop } );
Mojo::IOLoop->start;
Mojo::IOLoop->remove($timeout);
is( $strict, 1, 'a callback declaring no parameters is called without error' );

done_testing;
