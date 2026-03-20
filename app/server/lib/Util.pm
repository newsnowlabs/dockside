package Util;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = ( qw(
   flog wlog
   get_config
   trim is_true
   call_socket_api call_socket_json_api
   get_uri
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

sub flog ($m) {
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
      printf LOG "%05d: %s [%s] %s\n", $$, $dt, $FLOG->{'service'} // 'dockside', $m;
      close LOG;
   };
}

sub wlog ($m) {
   # 2020/01/10 16:29:17.123456
   my @time = gettimeofday();
   my @tm = gmtime($time[0]);
   my $dt = sprintf "%4d/%02d/%02d %02d:%02d:%02d.%06d", $tm[5] + 1900, $tm[4] + 1, @tm[ 3, 2, 1, 0 ], $time[1];
   
   print STDERR $dt . " [dockside] " . $m . "\n";
}

sub get_config ($path) {
   local $_ = $path;

   return undef if /\.\./;
   open( F, '<', "$_" ) || return undef;

   local $/;
   $_ = <F>;
   close F;

   # Remove trailing whitespace
   s/\s+$//s;

   return $_;
}

sub trim ($value) {
   local $_ = $value;
   s/(^\s+|\s$)//g;
   return $_;
}

sub is_true ($value) {
   return $value =~ /^(1|true)$/s;
}

sub call_socket_json_api ($socket, $path) {

   my $result = call_socket_api->($socket, $path);

   unless($result) {
      die Exception->new( 'dbg' => "Unable to execute Docker API call $path" );
   }

   unless($result->is_success) {
      die Exception->new( 'dbg' => "Docker API call '$path' failed, error: " . trim($result->message) );
   }

   my $object;
   try {
      $object = from_json($result->body);
   }
   catch {
      die Exception->new( 'dbg' => "Docker API call '$path' failed to decode from JSON: " . trim($result->body) );
   };

   return $object;
}

sub call_socket_api ($socket, $path) {
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

sub get_uri ($uri) {
   my $ua = Mojo::UserAgent->new();

   flog("get_uri: $uri");

   my $result;
   try {
      $result = $ua->get($uri)->result;
   }
   catch {
      return undef;
   };

   return $result;
}

sub run ($cmd, $unsafe = undef) {
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

sub run_system (@cmd) {
   # Magically prevent nginx from reaping the subprocess running $cmd, before we do.
   # See https://www.perlmonks.org/?node_id=1032725
   # https://stackoverflow.com/questions/5606668/no-child-processes-error-in-perl
   local $SIG{'CHLD'} = 'DEFAULT';

   my $cmd = join(' ', @cmd);

   flog("run_system: $cmd");

   my $exitCode = system(@cmd);

   die Exception->new( 'dbg' => sprintf( "Error running '%s': gave '%s' and exit code %d", $cmd, $!, $? >> 8 )) if( $? == -1 ) || ( $? >> 8 ) != 0;
   die Exception->new( 'dbg' => sprintf( "Error running '%s': died with signal %d, %s coredump", ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without' )) if( $? & 127 );

   return $? >> 8;
}

sub clean_pty ($text) {
   local $_ = $text;

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

sub run_pty ($cmd, $logfile) {
   open( my $fh, ">", $logfile ) || die Exception->new( 'dbg' => "Cannot open logfile '$logfile': $!", 'msg' => 'Cannot create container launch log file' );
   $fh->autoflush(1);
   my $ContainerID;
   my @input;

   my $logger = sub {
      my ($chunk) = @_;

      push(@input, $chunk);

      local $_ = clean_pty($chunk);

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

sub YYYYMMDDHHMMSS ($time) {
   return strftime("%Y-%m-%d %H:%M:%S", gmtime($time));
}

sub TO_JSON ($hashref) { return { %{$hashref} }; }

# Atomically read or update $file:
#
# If $sub given, get exclusive lock on $file, slurp $file, overwrite with return value of &$sub(<file contents>, @args).
# If no $sub given, get shared lock on $file, slurp $file and return.
#
sub cacheReadWrite ($file, $sub = undef, @args) {
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
      my $newData = $sub->($oldData, @args);

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

sub cacheEvery ($file, $cacheTime, $sub = undef, @args) {
   my $FILEPATH = $file;

   my $lastModified = (stat($FILEPATH))[9];

   flog(sprintf("Util::cache: file=$FILEPATH; cacheTime=$cacheTime; sub=%s; lm=%s, age=%d",
      $sub ? 'Yes' : 'No',
      $lastModified, time - $lastModified));

   if($sub && (!defined($lastModified) || (defined($lastModified) && (time - $lastModified) >= $cacheTime))) {
      return cacheReadWrite($FILEPATH, $sub, @args);
   }

   return cacheReadWrite($FILEPATH);
}

# Recursively copy across differing values from source hashref to destination hashref
sub cloneHash ($from, $to) {
   while( my($k, $v) = each %{$from}) {
      if( defined($from->{$k}) ) {
         if( ref($from->{$k}) eq 'HASH' && ref($to->{$k}) eq 'HASH') {
            cloneHash($from->{$k}, $to->{$k});
            next;
         }

         if( 
            (!exists($to->{$k}) && exists($from->{$k})) ||
            ($to->{$k} ne $from->{$k})
            ) {
            $to->{$k} = $from->{$k};
         }
      }
   }
}

sub get_cookie ($cookie, $name) {
   my ($value) = $cookie =~ /(?:^|;\s+)\Q$name\E=(.*?)(?:;|$)/;

   return uri_unescape($value);
}

sub encrypt_password ($p, $salt = undef) {

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

sub hashref_sign ($salt, %l) {
   my $str = $salt . join( '|', map { "$_=$l{$_}" } sort { $a cmp $b } keys %l );

   # Stop wide characters breaking the algorithm
   utf8::encode($str);

   my $orig = $str;
   for( my $i = 0; $i < 64; $i++ ) {
      $str = sha256_hex($str) . $orig;
   }

   return sha256_hex($str);
}

sub hashref_signed ($salt, $protocol, $data) {
   return hashref_sign( 
      ($protocol eq 'http' ? "${salt}_http" : $salt),
      %$data
   );
}

sub pad32 ($text) { return $text . ' ' x (32 - (length($text) % 32)); }

sub generate_auth_cookie_values ($name, $salt, $host, $data) {
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
sub validate_auth_cookie ($options, $name, $salt) { # cookie: <value>; protocol: <http|https>
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

sub unique (@values) {
   my %k = map { $_ => 1 } grep { defined($_) && $_ ne '' } @values;
   return keys %k;
}

1;
