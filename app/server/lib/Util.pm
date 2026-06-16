package Util;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = ( qw(
   flog wlog
   get_config
   trim is_true
   call_socket_api call_socket_json_api docker_container_path_exists
   get_uri
   run run_system clean_pty run_pty
   sanitize_sensitive_text
   YYYYMMDDHHMMSS TO_JSON
   cache cacheReadWrite cloneHash lockFile
   encrypt_password generate_auth_cookie_values validate_auth_cookie
   unique
   apply_args_to_record
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

sub sanitize_sensitive_text ($text) {
   return '' unless defined $text;

   my $out = $text;

   # Redact explicit env payloads that can carry secrets into docker exec calls.
   $out =~ s/--env=(OWNER_DETAILS|SSH_AGENT_KEYS|GH_TOKEN)=[^\n]*/--env=$1=<redacted>/g;

   # Redact PEM private-key blocks if they appear in any other context.
   $out =~ s/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----/<redacted-private-key>/sg;

   # Redact JSON-style gh_token fields.
   $out =~ s/("gh_token"\s*:\s*")[^"]*"/$1<redacted>"/g;
   $out =~ s/('gh_token'\s*=>\s*')[^']*'/$1<redacted>'/g;

   return $out;
}

# Build a short, secret-free command summary (binary + verb, plus the network
# action for docker/podman network commands) for the client-facing error `msg`;
# the full command line goes only to the `dbg` log, never to the client.
# See docs/adr/0003-error-reporting-surface.md.
sub _display_cmd (@cmd) {
   return '' unless @cmd;

   my @summary = ($cmd[0]);
   if( @cmd >= 2 ) {
      push @summary, $cmd[1];
   }
   if( @cmd >= 3 && $cmd[0] =~ m!/(?:docker|podman)$! && $cmd[1] eq 'network' ) {
      push @summary, $cmd[2];
   }
   return join(' ', grep { defined($_) && $_ ne '' } @summary);
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

   my $result = call_socket_api($socket, $path);

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

sub call_socket_api ($socket, $path, $opts = {}) {
   my $ua = Mojo::UserAgent->new();

   my $method = uc($opts->{'method'} // 'GET');
   my $uri = 'http+unix://' . uri_escape($socket) . $path;

   flog("call_socket_api: $method $uri");

   my $result;
   try {
      my $headers = {'Content-Type' => 'application/json', 'Host' => 'Dockside-1.00'};

      if($method eq 'GET') {
         $result = $ua->get($uri => $headers)->result;
      }
      elsif($method eq 'HEAD') {
         $result = $ua->head($uri => $headers)->result;
      }
      else {
         die Exception->new( 'dbg' => "Unsupported Docker API method '$method' for $path" );
      }
   }
   catch {
      return undef;
   };

   return $result;
}

sub docker_container_path_exists ($socket, $containerId, $containerPath) {
   my $path = sprintf(
      '/containers/%s/archive?path=%s',
      uri_escape($containerId),
      uri_escape($containerPath)
   );

   my $result = call_socket_api($socket, $path, { 'method' => 'HEAD' });

   unless($result) {
      die Exception->new( 'dbg' => "Unable to execute Docker API path check: $path", 'msg' => "Unable to check container path" );
   }

   return 1 if $result->is_success;
   return 0 if $result->code == 404;

   die Exception->new(
      'dbg' => sprintf("Docker API path check '$path' failed, response code %d, error '%s'", $result->code, $result->message),
      'msg' => "Unable to check container path"
   );
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
      my $safe_cmd = sanitize_sensitive_text($cmd);
      die Exception->new(
         'msg' => sprintf("Internal error - Error running command: exit code %d", $? >> 8),
         'dbg' => sprintf("Error running '%s': message '%s', exit code %d", $safe_cmd, $!, $? >> 8)
      ) if( $? == -1 ) || ( $? >> 8 ) != 0;
      die Exception->new(
         'msg' => 'Internal error - Command died with signal',
         'dbg' => sprintf("Error running '%s': died with signal %d, %s coredump", $safe_cmd, ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without')
      ) if( $? & 127 );
   }

   return $in;
}

sub run_system (@cmd) {
   # Magically prevent nginx from reaping the subprocess running $cmd, before we do.
   # See https://www.perlmonks.org/?node_id=1032725
   # https://stackoverflow.com/questions/5606668/no-child-processes-error-in-perl
   local $SIG{'CHLD'} = 'DEFAULT';

   my $cmd = join(' ', map { sanitize_sensitive_text($_) } @cmd);
   my $display_cmd = _display_cmd(@cmd);

   flog("run_system: $cmd");

   my $exitCode = system(@cmd);

   die Exception->new(
      'msg' => sprintf("Internal error - Error running '%s': exit code %d", $display_cmd, $? >> 8),
      'dbg' => sprintf( "Error running '%s': gave '%s' and exit code %d", $cmd, $!, $? >> 8 )
   ) if( $? == -1 ) || ( $? >> 8 ) != 0;
   die Exception->new(
      'msg' => sprintf("Internal error - Error running '%s': signal %d", $display_cmd, ( $? & 127 )),
      'dbg' => sprintf( "Error running '%s': died with signal %d, %s coredump", $cmd, ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without' )
   ) if( $? & 127 );

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

# Acquire an exclusive advisory lock on $lockfile and return the open handle.
#
# Release is implicit and there is deliberately no explicit close: the caller
# keeps the returned handle in a lexical, and when that lexical goes out of scope
# Perl drops the last reference and closes the handle, which releases the flock.
# Because Perl frees a scalar the instant its refcount hits zero, this is
# deterministic — it fires on normal return, on die (the stack unwind destroys
# the lexical), and on process/worker exit (the kernel closes the fd). This is
# the standard Perl filehandle-as-scope-guard idiom; cacheReadWrite() above
# releases its own handle the same way.
#
# Two caveats the caller must honour: hold the handle in a lexical scoped to
# exactly the region to serialise, and don't copy it into anything longer-lived
# (a stray copy would keep the lock held past the intended scope).
#
# This serialises multi-step "check-then-act" mutations that a single per-file
# cacheReadWrite lock cannot (an existence check then a write, or a rename
# spanning two files). The lock file is created on demand and must not be
# unlinked (unlinking would let two processes lock different inodes for one path).
sub lockFile ($lockfile) {
   open( my $LK, ">>", $lockfile )
      || die Exception->new( 'dbg' => "Cannot open lock file '$lockfile' ($!)" );
   flock( $LK, LOCK_EX )
      || do { close $LK; die Exception->new( 'dbg' => "Cannot lock '$lockfile' ($!)" ); };
   return $LK;
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

# Apply args into a record hashref in place.
#
# All values in $args must already be decoded Perl structures (not raw JSON
# strings) — parse_body_args() in App.pm normalises both application/json and
# form-encoded request bodies to this shape before dispatch reaches here.
#
# Keys support dot-notation for nested paths (e.g. "permissions.actions.foo").
# Keys in @skip (e.g. 'username', 'password') are silently ignored, allowing
# callers to pass the full $args without allowing modification of protected fields.
# Keys with undef values are also skipped (defensive against malformed input).
# The special key '_unset' is reserved for the delete pass and never written.
#
# Processing order: keys are sorted shallowest-first (fewest dots first) so
# that a bulk-replace of a parent (e.g. permissions={...}) is applied before
# any dotted children of that parent.  This prevents a top-level key from
# silently clobbering a deeper key set in the same call.
#
# Intermediate nodes that don't exist are created as empty hashrefs so a dotted
# path like "a.b.c" works even when "a" or "a.b" is absent from $record.
#
# _unset pass: after all set operations, each key listed in $args->{_unset}
# (an arrayref of dotted-path strings) is deleted from the record.  Traversal
# stops safely if any intermediate node is missing or not a hashref, leaving
# the record unchanged for that path — the final delete is guarded by
# 'if ref $ref eq 'HASH'' to prevent errors when traversal stopped early.
sub apply_args_to_record ($record, $args, @skip) {
   my %skip = map { $_ => 1 } @skip;

   for my $key ( sort { scalar( split /\./, $a ) <=> scalar( split /\./, $b ) } keys %$args ) {
      next if $skip{$key};
      next if $key eq '_unset';
      next unless defined $args->{$key};   # skip undef values (see parse_body_args edge case)

      my @parts = split( /\./, $key );
      my $ref   = $record;
      for my $part ( @parts[ 0 .. $#parts - 1 ] ) {
         # Auto-vivify intermediate nodes so dotted paths work on sparse records.
         $ref->{$part} //= {};
         $ref = $ref->{$part};
      }
      $ref->{ $parts[-1] } = $args->{$key};
   }

   if ( ref $args->{_unset} eq 'ARRAY' ) {
      for my $key ( @{ $args->{_unset} } ) {
         my @parts = split( /\./, $key );
         my $ref   = $record;
         for my $part ( @parts[ 0 .. $#parts - 1 ] ) {
            # Stop traversal if any intermediate node is absent or not a hashref.
            # $ref is left pointing to the last successfully traversed hashref.
            # The final 'if ref $ref eq HASH' guard makes the delete a no-op when
            # traversal stopped before reaching the deepest-level hash.
            last unless ref $ref eq 'HASH' && exists $ref->{$part};
            $ref = $ref->{$part};
         }
         delete $ref->{ $parts[-1] } if ref $ref eq 'HASH';
      }
   }
}

1;
