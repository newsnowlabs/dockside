use v5.36;
use FindBin;
use lib "$FindBin::Bin/../../app/server/lib", "$FindBin::Bin/../stubs";
use Util qw(flog);
use File::Temp qw(tempdir);
use Data;
use Test::More;

# Data::load reads $Data::CONFIG_PATH at call time, so pointing it at a temp directory holding a
# single config.json is all these subtests need to drive the real loader rather than the config
# of the machine the suite runs on. load_fresh bypasses the mtime cache, so every variant written
# to the same path is really parsed.

my $tmp = tempdir( CLEANUP => 1 );
my $logFile = "$tmp/log";
flog( { 'file' => $logFile } );
$Data::CONFIG_PATH = $tmp;

my $stderr = '';

sub slurp ($file) {
   open( my $fh, '<', $file ) or die "$file: $!";
   local $/;
   return scalar <$fh> // '';
}

# Loads one config.json body and returns the warning lines the load filed about the
# shutdown-grace keys. The log file is emptied first so each load is judged on its own lines, and
# wlog's stderr is captured into $stderr both to keep it out of the TAP stream and so a subtest
# can show the same message reached both loggers.
sub load_config ($body) {
   open( my $cfh, '>', "$tmp/config.json" ) or die "config.json: $!";
   print $cfh $body;
   close $cfh;

   open( my $lfh, '>', $logFile ) or die "$logFile: $!";
   close $lfh;

   open( my $saved, '>&', \*STDERR ) or die "stderr: $!";
   open( STDERR, '>', "$tmp/stderr" ) or die "stderr: $!";
   Data::load_fresh('config.json');
   open( STDERR, '>&', $saved ) or die "stderr: $!";

   $stderr = slurp("$tmp/stderr");
   return grep { /shutdownGrace/ } split( /\n/, slurp($logFile) );
}

sub grace_seconds () { return $Data::CONFIG->{'appServer'}{'shutdownGraceSeconds'}; }

subtest 'an accepted value is stored as it stands, and warns about nothing' => sub {
   # A JSON number in any spelling of a whole positive value is that value: the decoder settles
   # 1e3 and 1.0 to 1000 and 1 before the validator sees them.
   my %accepted = (
      '{}'                                => 'unlimited',
      '{"appServer":{"shutdownGraceSeconds":"unlimited"}}' => 'unlimited',
      '{"appServer":{"shutdownGraceSeconds":1}}'           => 1,
      '{"appServer":{"shutdownGraceSeconds":300}}'         => 300,
      '{"appServer":{"shutdownGraceSeconds":1e3}}'         => 1000,
      '{"appServer":{"shutdownGraceSeconds":1.0}}'         => 1,
   );

   for my $body ( sort keys %accepted ) {
      my @warnings = load_config($body);
      is(grace_seconds(), $accepted{$body}, "$body stores $accepted{$body}");
      is(scalar @warnings, 0, "$body warns about nothing");
   }
};

subtest 'every other value falls back to unlimited, with one warning naming the key' => sub {
   # A JSON number and the same digits as a JSON string are deliberately not the same value here:
   # the only string this key takes is 'unlimited', so a quoted "300" is a mistake to report
   # rather than accept. The numbers that are not finite whole positive values: zero, a negative,
   # a fraction, an exponent that overflows to infinity, a magnitude beyond plain digits, and an
   # integer too large for the decoder to hold as a number at all.
   my @rejected = (
      '0', '-1', '1.5', '1e309', '1e20', '1234567890123456789012345',
      '"300"', '"forever"', 'true', 'false', 'null', '{}', '[]',
   );
   for my $json (@rejected) {
      my @warnings = load_config(qq({"appServer":{"shutdownGraceSeconds":$json}}));

      is(grace_seconds(), 'unlimited', "$json leaves the drain unlimited");
      is(scalar @warnings, 1, "$json warns exactly once");
      like($warnings[0], qr/shutdownGraceSeconds/, "the warning for $json names the key");
      like($warnings[0], qr/unlimited/, "the warning for $json names the string form it accepts");
      like($warnings[0], qr/positive integer/i, "the warning for $json names the numeric form it accepts");
   }
};

subtest 'a rejected value is reported to both loggers' => sub {
   my @warnings = load_config('{"appServer":{"shutdownGraceSeconds":"forever"}}');

   is(scalar @warnings, 1, 'one line is filed in the service log');
   like($stderr, qr/shutdownGraceSeconds/,
      'and the same warning reaches stderr, where a supervised service shows it');
};

subtest 'a rejected value costs nothing else in the section' => sub {
   my @warnings =
      load_config('{"appServer":{"shutdownGraceSeconds":"300","reconcileIntervalSeconds":60}}');

   is(grace_seconds(), 'unlimited', 'the rejected key falls back');
   is(scalar @warnings, 1, 'and warns once');
   is($Data::CONFIG->{'appServer'}{'reconcileIntervalSeconds'}, 60,
      'its neighbour keeps the value the file gave it');
};

subtest 'shutdownGracePeriod is not a key the server reads' => sub {
   my @warnings = load_config('{"appServer":{"shutdownGracePeriod":90}}');

   ok(!exists $Data::CONFIG->{'appServer'}{'shutdownGracePeriod'},
      'nothing downstream can read it');
   is(grace_seconds(), 'unlimited', 'and it sets no ceiling of its own');
   is(scalar @warnings, 1, 'exactly one warning is filed for it');
   like($warnings[0], qr/shutdownGraceSeconds/, 'naming the key that does set the ceiling');
};

done_testing;
