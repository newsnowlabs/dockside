package Util;

use strict;

use Exporter qw(import);
our @EXPORT_OK = ( qw(
   flog wlog
   get_config
   trim is_true
   call_socket_api
   run run_system clean_pty run_pty
   YYYYMMDDHHMMSS TO_JSON
   cache cacheReadWrite cloneHash
   encrypt_password generate_auth_cookie_values validate_auth_cookie
   unique
   ));

use POSIX qw(strftime);
use Fcntl qw(:flock SEEK_SET);
use Time::HiRes qw(stat time gettimeofday);
use Try::Tiny;
use JSON;
use URI::Escape;
use Mojo::UserAgent;
use Digest::SHA qw(sha256_hex);
use Exception;
use Crypt::Rijndael;

####################################################################################################

my $FLOG;

sub flog {
   my $m = shift;

   if(ref($m) eq 'HASH') {
      $FLOG->{'service'} = $m->{'service'};
      $FLOG->{'file'} = $m->{'file'};
      return;
   }

   # 2020/01/10 16:29:17.123456
   my @time = gettimeofday();
   my @tm = gmtime($time[0]);
   my $dt = sprintf "%4d/%02d/%02d %02d:%02d:%02d.%06d", $tm[5] + 1900, $tm[4] + 1, @tm[ 3, 2, 1, 0 ], $time[1];

   open( LOG, ">>", $FLOG->{'file'} || "/var/log/dockside/dockside.log" ) && do {
      printf LOG "%05d: %s [%s] %s\n", $$, $dt, $FLOG->{'service'}, $m;
      close LOG;
   };
}

sub wlog {
   my $m = shift;

   # 2020/01/10 16:29:17.123456
   my @time = gettimeofday();
   my @tm = gmtime($time[0]);
   my $dt = sprintf "%4d/%02d/%02d %02d:%02d:%02d.%06d", $tm[5] + 1900, $tm[4] + 1, @tm[ 3, 2, 1, 0 ], $time[1];
   
   print STDERR $dt . " [dockside] " . $m . "\n";
}

sub get_config {
   local $_ = shift;

   return undef if /\.\./;
   open( F, '<', "$_" ) || return undef;

   local $/;
   $_ = <F>;
   close F;

   # Remove trailing whitespace
   s/\s+$//s;

   return $_;
}

sub trim {
   local $_ = shift;
   s/(^\s+|\s$)//g;
   return $_;
}

sub is_true {
   return $_[0] =~ /^(1|true)$/s;
}

sub call_socket_api {
   my $socket = shift;
   my $path = shift;

   my $ua = Mojo::UserAgent->new();

   my $socketPath = $socket . $path;
   my $uri = 'http+unix://' . uri_escape($socket) . $path;

   flog("call_socket_api: $uri");

   my $result;
   try {
      $result = $ua->get($uri => {'Content-Type' => 'application/json', 'Host' => 'Dockside-1.00'})->result;
   }
   catch {
      return undef;
   };

   return $result;
}

sub run {
   my $cmd    = shift;
   my $unsafe = shift;

   # Magically prevent nginx from reaping the subprocess running $cmd, before we do.
   # See https://www.perlmonks.org/?node_id=1032725
   # https://stackoverflow.com/questions/5606668/no-child-processes-error-in-perl
   local $SIG{'CHLD'} = 'DEFAULT';

   flog("run: $cmd");

   my $in = `$cmd`;

   unless($unsafe) {
      die Exception->new( 'dbg' => sprintf( "Error running '%s': message '%s', exit code %d", $cmd, $!, $? >> 8 )) if( $? == -1 ) || ( $? >> 8 ) != 0;
      die Exception->new( 'dbg' => sprintf( "Error running '%s': died with signal %d, %s coredump", ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without' )) if( $? & 127 );
   }

   return $in;
}

sub run_system {
   my @cmd    = @_;

   # Magically prevent nginx from reaping the subprocess running $cmd, before we do.
   # See https://www.perlmonks.org/?node_id=1032725
   # https://stackoverflow.com/questions/5606668/no-child-processes-error-in-perl
   local $SIG{'CHLD'} = 'DEFAULT';

   my $cmd = join(' ', @cmd);

   flog("run_system: $cmd");

   my $exitCode = system(@cmd);

   die Exception->new( 'dbg' => sprintf( "Error running '%s': message '%s', exit code %d", $cmd, $!, $? >> 8 )) if( $? == -1 ) || ( $? >> 8 ) != 0;
   die Exception->new( 'dbg' => sprintf( "Error running '%s': died with signal %d, %s coredump", ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without' )) if( $? & 127 );

   return $? >> 8;
}

sub clean_pty {
   local $_ = $_[0];

   # https://unix.stackexchange.com/questions/14684/removing-control-chars-including-console-codes-colours-from-script-output
   if(s/ \e[ #%()*+\-.\/]. |
   \e\[ [ -?]* [@-~] | # CSI ... Cmd
   \e\] .*? (?:\e\\|[\a\x9c]) | # OSC ... (ST|BEL)
   \e[P^_] .*? (?:\e\\|\x9c) | # (DCS|PM|APC) ... ST
   \e. //xgs
   ) {
      return undef unless $_;
   }

   # Replace CRLF with LF
   s/\r+\n/\n/sg;

   # Skip lines consisting only of CR
   return undef if /^\r+$/;

   # Replace CRs at end of line with single LF
   s/\r+$/\n/g;

   # Remove CRs/LFs at beginning of line
   s/^[\r\n]+//s;

   # Remove any remaining CRs
   s/\r+//sg;

   return $_;
}

sub run_pty {
   my $cmd     = shift;
   my $logfile = shift;

   open( my $fh, ">", $logfile ) || die Exception->new( 'dbg' => "Cannot open logfile '$logfile': $!", 'msg' => 'Cannot create container launch log file' );
   $fh->autoflush(1);
   my $ContainerID;
   my @input;

   my $logger = sub {
      print $_[0];

      push(@input, $_[0]);

      local $_ = clean_pty($_[0]);

      return unless defined($_);

      print $fh $_;
      $fh->flush();
   };

   # Magically prevent nginx from reaping the subprocess running $cmd, before we do.
   # See https://www.perlmonks.org/?node_id=1032725
   # https://stackoverflow.com/questions/5606668/no-child-processes-error-in-perl
   local $SIG{'CHLD'} = 'DEFAULT';

   my $cmdString = join(' ', @$cmd);

   flog( "run_pty: RUNNING: " . join( '|', @$cmd ) );

   # create an Expect object by spawning another process
   my $exp = Expect->spawn(@$cmd) or die Exception->new( 'dbg' => "Cannot spawn command '$cmdString': $!", 'msg' => "Cannot spawn command" );

   $exp->log_stdout(0);
   $exp->log_file($logger);
   $exp->expect(undef);
   $exp->soft_close();

   $exp->print_log_file( sprintf( "\n=== EXIT CODE %d ===\n", $exp->exitstatus ) );

   close $fh;

   return $exp->exitstatus();
}

sub YYYYMMDDHHMMSS {
   my $time = shift;
   return strftime("%Y-%m-%d %H:%M:%S", gmtime($time));
}

sub TO_JSON { return { %{ shift() } }; }

# Atomically read or update $file:
#
# If $sub given, get exclusive lock on $file, slurp $file, overwrite with return value of &$sub(<file contents>, @args).
# If no $sub given, get shared lock on $file, slurp $file and return.
#
sub cacheReadWrite {
   my $file = shift;
   my $sub = shift;
   my @args = @_;

   flog("cacheReadWrite: file=$file; sub=" . ($sub ? 'Yes' : 'No'));

   # Or use "+<" here?
   open( my $FH, "+>>", $file ) || die Exception->new( 'dbg' => "Error opening '$file' ($!)" );
   
   flock( $FH, $sub ? LOCK_EX : LOCK_SH ) || do { close $FH; die Exception->new( 'dbg' => "Cannot get lock on '$file' ($!)" ); };

   seek( $FH, 0, SEEK_SET ) || do { close $FH; die Exception->new( 'dbg' => "Cannot seek to start of '$file' ($!)" ); };
   local $/;
   my $oldData = <$FH>;

   if(!$sub) {
      close $FH;
      return $oldData;
   }

   flog("cacheReadWrite: file=$file; sub=Yes; #5");

   return try {
      my $newData = &$sub($oldData, @args);

      if(defined($newData) && $newData ne $oldData) {            
         flog("cacheReadWrite: file=$file; sub=Yes; #7; Updating=Yes");

         truncate( $FH, 0 ) || do { close $FH; die Exception->new( 'dbg' => "Cannot truncate '$file' ($!)" ); };
         seek( $FH, 0, SEEK_SET ) || do { close $FH; die Exception->new( 'dbg' => "Cannot seek to start of '$file' ($!)" ); };

         print $FH $newData;
         close $FH;
         return $newData;
      }

      flog("cacheReadWrite: file=$file; sub=Yes; #8; Updating=No");
      close $FH;
      return $oldData;
   }
   catch {
      flog("cacheReadWrite: sub threw exception: " . (ref($_) ? $_->msg : $_));
      close $FH;

      # Re-throw exception.
      die $_;
   };
}

sub cacheEvery {
   my $file = shift;
   my $cacheTime = shift;
   my $sub = shift;

   my $FILEPATH = $file;

   my $lastModified = (stat($FILEPATH))[9];

   flog(sprintf("Util::cache: file=$FILEPATH; cacheTime=$cacheTime; sub=%s; lm=%s, age=%d",
      $sub ? 'Yes' : 'No',
      $lastModified, time - $lastModified));

   if($sub && !defined($lastModified) || (defined($lastModified) && (time - $lastModified) >= $cacheTime)) {
      return cacheReadWrite($FILEPATH, $sub, @_);
   }

   return cacheReadWrite($FILEPATH);
}

# Recusively copy across all values that are different from deep hashref $_[0] to $_[1]
sub cloneHash {
   while( my($k, $v) = each %{$_[0]}) {
      if( defined($_[0]->{$k}) ) {
         if( ref($_[0]->{$k}) eq 'HASH' && ref($_[1]->{$k}) eq 'HASH') {
            cloneHash($_[0]->{$k}, $_[1]->{$k});
            next;
         }

         if( 
            (!exists($_[1]->{$k}) && exists($_[0]->{$k})) ||
            ($_[1]->{$k} ne $_[0]->{$k})
            ) {
            $_[1]->{$k} = $_[0]->{$k};
         }
      }
   }
}

sub get_cookie {
   my $cookie = shift;
   my $name = shift;

   my ($value) = $cookie =~ /(?:^|;\s+)\Q$name\E=(.*?)(?:;|$)/;

   return uri_unescape($value);
}

sub encrypt_password {
   my $p = shift;
   my $salt = shift;

   my @letters = ( 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '/', '.' );

   if( !defined($salt) || ( $salt eq '' ) ) {

      $salt = '$6$';
      for( my $i = 0; $i < 16; $i++ ) {
         $salt .= $letters[ rand @letters ];
      }
      $salt .= '$';
   }

   return crypt( $p, $salt );
}

sub hashref_sign {
   my $salt = shift;
   my %l = @_;

   my $str = $salt . join( '|', map { "$_=$l{$_}" } sort { $a cmp $b } %l );

   # Stop wide characters breaking the algorithm
   utf8::encode($str);

   my $orig = $str;
   for( my $i = 0; $i < 64; $i++ ) {
      $str = sha256_hex($str) . $orig;
   }

   return sha256_hex($str);
}

sub hashref_signed {
   my $salt = shift;
   my $protocol = shift;
   my $data = shift;

   return hashref_sign( 
      ($protocol eq 'http' ? "${salt}_http" : $salt),
      %$data
   );
}

sub pad32 { return $_[0] . ' ' x (32 - (length($_[0]) % 32)); }

sub generate_auth_cookie_values {
   my $name = shift;
   my $salt = shift;
   my $host  = shift;
   my $data = shift;

   # Extract cookie domain from provided Host header, which we now assume MUST begin with either:
   # www. [root container]
   # www-[^\.]+ [sub-container]
   # N.B. Support for punycode domain names is unverified.
   my ($domain) = $host =~ /^[^\.]*(\.[^\:]+)/;

   my $sign = hashref_signed($salt, 'https', $data);
   my $aeskey = substr($salt, 0, 32);
   my $cipher = Crypt::Rijndael->new($aeskey, Crypt::Rijndael::MODE_CBC());

   return (
      sprintf(
         "%s=%s; Domain=%s; Path=/; Max-Age=315360000; Priority=High; SameSite=Strict; %s; %s;",
         $name,
         uri_escape(
            $cipher->encrypt(
               pad32( encode_json( { 'sign' => hashref_signed($salt, 'https', $data), %$data } ) )
            )
         ),
         $domain,
         'HttpOnly',
         'Secure'
      ),
      sprintf(
         "%s=%s; Domain=%s; Path=/; Max-Age=315360000; Priority=High; SameSite=Strict; %s; %s;",
         "${name}_http",
         uri_escape(
            $cipher->encrypt(
               pad32( encode_json( { 'sign' => hashref_signed($salt, 'http', $data), %$data } ) )
            )
         ),
         $domain,
         'HttpOnly',
         ''
      ),
   );

}

# Returns the auth cookie hash, if the auth cookie is validly signed.
# N.B. This DOESN'T check the user is authorised.
sub validate_auth_cookie {
   my $options = shift; # cookie: <value>; protocol: <http|https>
   my $name = shift;
   my $salt = shift;

   return undef unless $options->{'cookie'};

   my $v = get_cookie($options->{'cookie'}, ($options->{'protocol'} eq 'https') ? $name : "${name}_http");

   # Return if no cookie
   return undef unless $v;

   my $aeskey = substr($salt, 0, 32);
   my $decrypt = eval {
      return Crypt::Rijndael->new(
         $aeskey, Crypt::Rijndael::MODE_CBC()
      )->decrypt($v);
   };

   # Return unless we obtained a decrypted string
   return undef unless defined($decrypt);

   # Decode the auth cookie, trapping any errors.
   my $l = eval { return decode_json($decrypt); };

   # Check if we obtained a valid JSON structure, with a 'sign' property.
   return undef unless defined($l) && $l->{'sign'};

   my $sign    = delete $l->{'sign'};
   my $newsign = hashref_signed($salt, $options->{'protocol'}, $l);

   # Check if the cookie is correctly signed.
   return undef unless $sign eq $newsign;

   # Everything checks out, so return the authentication cookie data structure.
   return $l;
}

sub unique {
   my %k = map { $_ => 1 } grep { defined($_) && $_ ne '' } @_;
   return keys %k;
}

1;
