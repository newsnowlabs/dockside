use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Util qw(once);
use File::Temp qw(tempdir);
use Test::More;

# Util::once wraps a continuation so that its caller learns an outcome exactly once: the first
# call is delivered, every later one is a logged bug. The service log is a temporary file and
# stderr is captured around each call, since a second call is reported to both.
my $tmp = tempdir( CLEANUP => 1 );
Util::flog( { file => "$tmp/test.log" } );

sub read_log {
   open my $fh, '<', "$tmp/test.log" or return '';
   local $/;
   return <$fh> // '';
}

# Runs $code with stderr captured. Returns $code's results followed by the captured text; a
# throw from $code is rethrown once stderr is restored.
sub captured ($code) {
   open( my $saved, '>&', \*STDERR ) or die "stderr: $!";
   open( STDERR, '>', "$tmp/stderr" ) or die "stderr: $!";
   my @out = eval { $code->() };
   my $failed = $@;
   open( STDERR, '>&', $saved ) or die "stderr: $!";
   die $failed if $failed;
   open my $fh, '<', "$tmp/stderr" or die $!;
   local $/;
   my $warnings = <$fh> // '';
   return ( @out, $warnings );
}

# What the wrapped sub sees of its caller's context, as a word.
sub context_word { return wantarray ? 'list' : defined(wantarray) ? 'scalar' : 'void'; }

subtest 'the first call passes its arguments through and returns what the wrapped sub returns' => sub {
   my @received;
   my $guarded = once( 'first call', sub (@args) { push @received, [@args]; return wantarray ? ( 'list', scalar @args ) : 'scalar' } );

   my @list = $guarded->( 'a', undef, 3 );
   my ($scalar) = captured( sub { return scalar $guarded->('ignored') } );

   is_deeply( \@received, [ [ 'a', undef, 3 ] ], 'the wrapped sub sees the first call arguments, undef included' );
   is_deeply( \@list, [ 'list', 3 ], 'and its list return value reaches the caller' );
   ok( !defined($scalar), 'a second call returns nothing, in scalar context too' );
};

subtest 'a first call reaches the wrapped sub in its caller own context' => sub {
   my $inList = once( 'list context', sub (@) { return context_word() } );
   my @list = $inList->();
   is_deeply( \@list, ['list'], 'a first call in list context is delivered in list context' );

   my $inScalar = once( 'scalar context', sub (@) { return context_word() } );
   my $scalar = $inScalar->();
   is( $scalar, 'scalar', 'a first call in scalar context is delivered in scalar context' );

   my $seen;
   my $inVoid = once( 'void context', sub (@) { $seen = defined(wantarray) ? 'not void' : 'void'; return } );
   $inVoid->();
   is( $seen, 'void', 'a first call in void context is delivered in void context' );
};

subtest 'a second call does not reach the wrapped sub and is reported to both logs' => sub {
   my $calls = 0;
   my $guarded = once( 'stage creating for r1', sub (@) { $calls++ } );

   my ($warnings) = captured( sub { $guarded->(1); $guarded->(2); $guarded->(); return } );

   is( $calls, 1, 'the wrapped sub ran once' );
   my @filed = grep { /stage creating for r1: continuation called again; ignored/ } split /\n/, read_log();
   is( scalar @filed, 2, 'each later call is one service log line naming the label' );
   my @warned = grep { /stage creating for r1: continuation called again; ignored/ } split /\n/, $warnings;
   is( scalar @warned, 2, 'and one stderr line' );
};

subtest 'a throw from the wrapped sub reaches the caller, and a later call is still ignored' => sub {
   my $calls = 0;
   my $guarded = once( 'throwing', sub (@) { $calls++; die "consumer failure\n" } );

   my $error;
   eval { $guarded->(); 1 } or $error = $@;
   is( $error, "consumer failure\n", 'the throw is the caller own to handle' );

   my ($warnings) = captured( sub { $guarded->(); return } );
   is( $calls, 1, 'the throw counted as the one call' );
   like( $warnings, qr/throwing: continuation called again; ignored/, 'so the next call is reported and dropped' );
};

subtest 'a call made from inside the wrapped sub is a second call' => sub {
   my $guarded;
   my $calls = 0;
   $guarded = once( 'reentrant', sub (@) { $calls++; $guarded->() } );

   my ($warnings) = captured( sub { $guarded->(); return } );
   is( $calls, 1, 'the wrapped sub is not re-entered' );
   like( $warnings, qr/reentrant: continuation called again; ignored/, 'and the re-entry is reported' );
};

done_testing;
