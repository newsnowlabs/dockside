package Util;

use v5.36;

use Exporter qw(import);
our @EXPORT_OK = ( qw(
   flog wlog
   get_config
   trim is_true
   call_socket_api call_socket_api_async call_socket_json_api docker_container_path_exists docker_exec_async
   get_uri_async
   run run_system clean_pty run_pty
   sanitize_sensitive_text
   YYYYMMDDHHMMSS TO_JSON
   cacheReadWrite cloneHash lockFile
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
use Mojo::Date;
use Mojo::UserAgent;
use Mojo::Util qw(b64_decode);
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

   # Default (20s) is far too short for a held-open exec/start stream that can legitimately
   # go quiet between output lines (e.g. an `npm run build` hook) - callers doing that must
   # pass a generous inactivity_timeout explicitly; everything else keeps Mojo's own default.
   $ua->inactivity_timeout($opts->{'inactivity_timeout'}) if defined $opts->{'inactivity_timeout'};

   # Bounds the *whole* call, active or not - unlike inactivity_timeout. When this fires,
   # $ua->start() returns normally (does not die) with $tx->result undef and $tx->error set,
   # rather than throwing - callers must check for that, not wrap this in a try/catch expecting
   # an exception. This is purely client-side abandonment - the in-container process is *not*
   # killed by it (there is no Docker API endpoint to kill a running exec at all), matching
   # `timeout`'s own caveat in Reservation::dispatch_hook_exec_async.
   $ua->request_timeout($opts->{'request_timeout'}) if defined $opts->{'request_timeout'};

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
      elsif($method eq 'POST') {
         my $body = defined($opts->{'json'}) ? encode_json($opts->{'json'}) : '';

         if( my $onRead = $opts->{'on_read'} ) {
            # Streamed consumption (e.g. `POST /exec/{id}/start` with Detach:false): the
            # response body is a live, held-open stream, frames arriving as the exec
            # produces output - not a normal buffered response. Build the transaction
            # explicitly so a 'read' subscriber on its response content sees each chunk as it
            # arrives, still within this one blocking $ua->start() call.
            my $tx = $ua->build_tx(POST => $uri => $headers => $body);
            $tx->res->content->unsubscribe('read')->on(read => sub ($content, $bytes) {
               $onRead->($bytes);
            });
            $ua->start($tx);
            $result = $tx->result;
         }
         else {
            $result = $ua->post($uri => $headers => $body)->result;
         }
      }
      else {
         die Exception->new( 'dbg' => "Unsupported Docker API method '$method' for $path" );
      }
   }
   catch {
      # Surprising: a request_timeout abort on a blocking $ua->start() does NOT leave
      # $tx->result simply undef here - it actually throws (caught right here), unlike the
      # same call made outside any try/catch at all. Capture the exception text via
      # error_ref, for a caller that wants to distinguish "timed out" from "some other
      # failure" - the generic `return undef` below already matches every other caller's
      # existing contract, this only adds detail for one that asks for it.
      ${ $opts->{'error_ref'} } = { 'message' => "$_" } if $opts->{'error_ref'};
      return undef;
   };

   return $result;
}

# Every in-flight call_socket_api_async's own Mojo::UserAgent, keyed by its transaction's refaddr
# - removed the instant that call's own completion callback fires. Necessary, not optional:
# Perl closures only capture a variable actually *referenced by name* in the closure body: the
# completion callback below takes its own ($ua, $tx) parameters (Mojo's own convention), which
# *shadow* the ones this function creates - so nothing keeps this function's own $ua alive once
# it returns, unless something else holds a reference. This bites for real, not just in theory:
# an earlier version of this without %ASYNC_UA_IN_FLIGHT failed intermittently with "Premature
# connection close" - the request's own Mojo::UserAgent (which owns the connection) was
# garbage-collected mid-flight the instant the enclosing scope exited, sometimes before the
# connection had even finished being established.
my %ASYNC_UA_IN_FLIGHT;

# Non-blocking sibling of call_socket_api above - never blocks the caller's own event loop.
# Same $opts/conventions (method/json/on_read/inactivity_timeout/request_timeout/headers/
# http+unix:// transport) - this replicates call_socket_api's own behavior for a non-blocking
# caller, it does not redefine it. $cb->($result, $error) fires exactly once, whenever the call
# settles: $result is the response object (call_socket_api's own return value) whenever one
# exists - including a non-2xx HTTP response, e.g. a 404, exactly as call_socket_api's own
# callers already handle by inspecting ->code/->is_success themselves, not by treating a non-2xx
# as a failure - or undef with $error set to a message string for a genuine transport-level
# failure (connection refused, or request_timeout).
#
# The result/error split below is not "if $tx->error then no result" - that would be wrong.
# Three distinct cases: (1) success - $tx->error undef, $tx->result usable; (2) an HTTP-level
# error status (e.g. 404) - $tx->error IS set (with a real ->{'code'}), but $tx->result is ALSO
# still fully usable, same response object either way; (3) a genuine transport failure (bad
# socket path, or request_timeout firing) - $tx->error is set with ->{'code'} undef, and calling
# $tx->result in that case actually throws, exactly mirroring call_socket_api's own documented
# blocking-mode behavior for the same two cases. So the only correct discriminator for "was
# anything usable returned at all" is $tx->error's own ->{'code'} being defined or not, not
# whether ->error is set at all.
sub call_socket_api_async ($socket, $path, $opts, $cb) {
   my $ua = Mojo::UserAgent->new();
   $ua->inactivity_timeout($opts->{'inactivity_timeout'}) if defined $opts->{'inactivity_timeout'};
   $ua->request_timeout($opts->{'request_timeout'}) if defined $opts->{'request_timeout'};

   my $method = uc($opts->{'method'} // 'GET');
   my $uri = 'http+unix://' . uri_escape($socket) . $path;
   my $headers = {'Content-Type' => 'application/json', 'Host' => 'Dockside-1.00'};

   flog("call_socket_api_async: $method $uri");

   # DELETE added for Reservation::action_async's 'remove' (DELETE /containers/{id}?v=true) -
   # no body, same as GET/HEAD below - Docker's remove-container endpoint takes its options
   # (v/force) as query params, not a body.
   die Exception->new( 'dbg' => "call_socket_api_async: unsupported method '$method' for $path" )
      unless $method eq 'GET' || $method eq 'HEAD' || $method eq 'POST' || $method eq 'DELETE';

   my $body = defined($opts->{'json'}) ? encode_json($opts->{'json'}) : '';
   my $tx = $method eq 'POST'
      ? $ua->build_tx( POST => $uri => $headers => $body )
      : $ua->build_tx( $method => $uri => $headers );

   if( my $onRead = $opts->{'on_read'} ) {
      $tx->res->content->unsubscribe('read')->on(read => sub ($content, $bytes) {
         $onRead->($bytes);
      });
   }

   $ASYNC_UA_IN_FLIGHT{ 0 + $tx } = $ua;   # see %ASYNC_UA_IN_FLIGHT's own comment

   $ua->start( $tx => sub ($ua, $tx) {
      delete $ASYNC_UA_IN_FLIGHT{ 0 + $tx };

      my $err = $tx->error;
      if( $err && !defined($err->{'code'}) ) {
         # Transport-level failure - see this function's own header comment for why ->result
         # would throw here rather than just being undef, and why that's not tested for.
         $cb->( undef, $err->{'message'} );
         return;
      }
      $cb->( $tx->result, undef );
   } );

   return $tx;   # so a caller with a long-held stream (e.g. /events) can retain/abort it later
}

# Returns ($exists, $mtime_epoch) where $mtime_epoch is a whole-second (integer) epoch
# parsed from the X-Docker-Container-Path-Stat header (undef if absent/unparseable).
# Sub-second precision, if present in the header, is discarded.
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

   if ($result->code == 404) {
      return (0, undef);
   }

   unless ($result->is_success) {
      die Exception->new(
         'dbg' => sprintf("Docker API path check '$path' failed, response code %d, error '%s'", $result->code, $result->message),
         'msg' => "Unable to check container path"
      );
   }

   my $mtime;
   if (my $b64 = $result->headers->header('X-Docker-Container-Path-Stat')) {
      try {
         my $stat = decode_json(b64_decode($b64));
         # Mojo::Date parses RFC 3339 including fractional seconds and numeric offsets --
         # Docker reports the stat mtime in the daemon's local timezone (e.g. '+01:00' on
         # a BST host), so the offset must be honoured for a correct UTC epoch; rejecting
         # non-'Z' timestamps would disable staleness detection entirely on any non-UTC
         # host. (A zone-less timestamp would be read as UTC; Docker always sends a zone.)
         my $epoch = Mojo::Date->new($stat->{'mtime'} // '')->epoch;
         if (defined $epoch) {
            $mtime = int($epoch);
         }
         else {
            flog("docker_container_path_exists: could not parse mtime from stat header for $path: '" . ($stat->{'mtime'} // '<missing>') . "'");
         }
      }
      catch {
         flog("docker_container_path_exists: failed to parse X-Docker-Container-Path-Stat header '$b64': $_");
      };
   }
   else {
      # No stat header: staleness detection is unavailable for this Docker API response, so
      # callers comparing against a $since will treat this path as fresh (fail open) -- log
      # it so that silent fail-open isn't invisible to an operator debugging the feature.
      flog("docker_container_path_exists: no X-Docker-Container-Path-Stat header present for $path; staleness check will be skipped");
   }

   return (1, $mtime);
}

# Runs $args->{'Cmd'} inside container $containerId via the Docker exec API directly (create,
# then start) rather than forking the `docker` CLI - never blocks the caller's own event loop
# (Mojo::IOLoop). $args:
#   Cmd  => [...]   required, argv
#   User => "..."   optional, exec as this user (matches `docker exec -u`)
#   Env  => [...]   optional, "KEY=VALUE" strings (matches `docker exec --env`)
# $opts:
#   Detach             => 1   optional. Start detached (fire-and-forget) instead of the default
#      non-detached start-and-stream: no output is ever attached or read (on_output is
#      meaningless here and never called), and $cb fires immediately after creation -
#      { execId, exitCode => undef, timedOut => 0 } - without waiting for the process to finish
#      or inspecting its outcome at all. Needed for a perpetual process (e.g. the IDE launcher):
#      the caller retains execId (via on_created, below) for its own later liveness polling
#      instead - a non-detached dispatch of a perpetual process would hold the connection open
#      for the container's whole life.
#   on_created         => sub ($execId) { ... }  optional, called once the exec exists but
#      *before* it is started - lets a caller persist the exec id (for later abort/liveness
#      detection) right away.
#   on_output          => sub ($stream, $bytes) { ... }  optional, called for each frame of
#      output as it arrives (not buffered/batched) - $stream is 'stdout' or 'stderr'. Omit to
#      discard output entirely (the caller only wants the final exit code).
#   inactivity_timeout => seconds   optional, forwarded to call_socket_api_async - the exec can
#      legitimately go quiet between output lines for longer than Mojo's 20s default.
#   request_timeout    => seconds   optional, forwarded to call_socket_api_async - bounds the
#      whole start-and-stream call regardless of activity. This is purely client-side
#      abandonment: it does not kill the in-container process (see call_socket_api's own
#      comment) - the hook may still be running/finishing in the background after $cb fires.
# $cb->($result, $error) fires exactly once, always, for every path including Detach: $result
# is { execId, exitCode, timedOut } on success (exitCode undef if the start call itself timed
# out - timedOut => 1, the in-container process's real outcome then unknowable from here - or
# if the final inspect call failed after a successful stream, logged not fatal), or undef with
# $error set for a create failure, a non-201 create response, or a start failure other than a
# request_timeout. Every failure path reports via $cb rather than dying: an async caller has no
# surrounding try/catch frame by the time any of this runs, so dying here would be an uncaught
# exception inside a Mojo completion callback, not something any caller could catch.
sub docker_exec_async ($socket, $containerId, $args, $opts, $cb) {
   call_socket_api_async( $socket, "/containers/$containerId/exec", {
      'method' => 'POST',
      'json'   => {
         'AttachStdout' => JSON::true,
         'AttachStderr' => JSON::true,
         'Tty'          => JSON::false,
         ( $args->{'User'} ? ( 'User' => $args->{'User'} ) : () ),
         ( $args->{'Env'}  ? ( 'Env'  => $args->{'Env'}  ) : () ),
         'Cmd' => $args->{'Cmd'},
      },
   }, sub ($createRes, $createErr) {
      unless( $createRes ) {
         $cb->( undef, "docker_exec_async: unable to create exec for containerId=$containerId: $createErr" );
         return;
      }
      unless( $createRes->code == 201 ) {
         $cb->( undef, sprintf( "docker_exec_async: create failed for containerId=%s: %d %s", $containerId, $createRes->code, $createRes->body ) );
         return;
      }

      my $execId = decode_json($createRes->body)->{'Id'};
      $opts->{'on_created'}->($execId) if $opts->{'on_created'};

      if( $opts->{'Detach'} ) {
         call_socket_api_async( $socket, "/exec/$execId/start", {
            'method' => 'POST',
            'json'   => { 'Detach' => JSON::true, 'Tty' => JSON::false },
         }, sub ($startRes, $startErr) {
            unless( $startRes && $startRes->code == 200 ) {
               $cb->( undef, "docker_exec_async: unable to start (detached) execId=$execId" . ( $startErr ? ": $startErr" : '' ) );
               return;
            }
            $cb->( { 'execId' => $execId, 'exitCode' => undef, 'timedOut' => 0 }, undef );
         } );
         return;
      }

      # Demultiplex Docker's own stream-multiplexed frame format directly: byte 0 is the stream
      # type (1=stdout, 2=stderr), bytes 4-7 a big-endian payload length, that many content bytes
      # follow. on_read may deliver a partial frame, or several frames at once, so a running
      # buffer is kept across calls rather than assuming each call aligns with a frame boundary.
      # A fresh $buf/$onRead closure per call, since each dispatch is independent.
      my $onOutput = $opts->{'on_output'};
      my $buf = '';
      my $onRead = sub ($bytes) {
         $buf .= $bytes;
         while( length($buf) >= 8 ) {
            my $type = unpack('C', substr($buf, 0, 1));
            my $len  = unpack('N', substr($buf, 4, 4));
            last if length($buf) < 8 + $len;
            my $payload = substr($buf, 8, $len);
            $buf = substr($buf, 8 + $len);
            $onOutput->( ($type == 2) ? 'stderr' : 'stdout', $payload ) if $onOutput;
         }
      };

      call_socket_api_async( $socket, "/exec/$execId/start", {
         'method'             => 'POST',
         'json'               => { 'Detach' => JSON::false, 'Tty' => JSON::false },
         'inactivity_timeout' => $opts->{'inactivity_timeout'},
         'request_timeout'    => $opts->{'request_timeout'},
         'on_read'            => $onRead,
      }, sub ($startRes, $startErr) {
         unless( $startRes ) {
            if( ($startErr // '') =~ /timeout/i ) {
               flog("docker_exec_async: execId=$execId timed out waiting for it to finish (client-side only - the in-container process is not killed by this)");
               $cb->( { 'execId' => $execId, 'exitCode' => undef, 'timedOut' => 1 }, undef );
               return;
            }
            $cb->( undef, "docker_exec_async: unable to start execId=$execId" . ( $startErr ? ": $startErr" : '' ) );
            return;
         }

         call_socket_api_async( $socket, "/exec/$execId/json", {}, sub ($inspectRes, $inspectErr) {
            my $exitCode;
            if( $inspectRes && $inspectRes->is_success ) {
               $exitCode = decode_json($inspectRes->body)->{'ExitCode'};
            }
            else {
               flog("docker_exec_async: post-run inspect of execId=$execId failed; exitCode unavailable");
            }
            $cb->( { 'execId' => $execId, 'exitCode' => $exitCode, 'timedOut' => 0 }, undef );
         } );
      } );
   } );
}

# Just GET a URI, non-blocking - $cb->($result) fires with the response object, or undef on
# any failure (connection error, timeout, ...). Used by Reservation::getGitDevContainer_async;
# kept as its own function here, not inlined, in case another caller needs the same non-blocking
# fetch later. Manual build_tx/start (not the ->get($uri => $cb) shorthand) and
# %ASYNC_UA_IN_FLIGHT registration, exactly matching call_socket_api_async above - the same
# "Premature connection close" GC hazard applies here (this function's own $ua is otherwise
# unreferenced the instant it returns), same fix.
sub get_uri_async ($uri, $cb) {
   my $ua = Mojo::UserAgent->new();

   flog("get_uri_async: $uri");

   my $tx = $ua->build_tx( GET => $uri );
   $ASYNC_UA_IN_FLIGHT{ 0 + $tx } = $ua;

   $ua->start( $tx => sub ($ua, $tx) {
      delete $ASYNC_UA_IN_FLIGHT{ 0 + $tx };

      my $err = $tx->error;
      if( $err && !defined($err->{'code'}) ) {
         $cb->(undef);
         return;
      }
      $cb->( $tx->result );
   } );

   return;
}

sub run ($cmd, $unsafe = undef) {
   # Locally reset SIG{CHLD} to 'DEFAULT' so this process (not an inherited handler)
   # reaps $cmd's own exit status - a handler installed further up would otherwise race
   # this subprocess's own wait, intermittently losing its exit code. Host-agnostic
   # rationale, not nginx-specific: this code runs both embedded in nginx (via
   # ngx_http_perl_module - nginx's own SIGCHLD handling is the original motivation
   # here, see the links below) and standalone inside bin/app-server (a plain
   # Mojolicious process, no nginx-specific quirk to guard against, but harmless/still
   # correct to reset regardless). No fork sites remain in this codebase whose own
   # handler installation this needs to defend against either way (Reservation::launch's
   # own $SIG{'CHLD'}=sub{...} - the other historical source of an inherited handler -
   # is gone.
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
   # Locally reset SIG{CHLD} to 'DEFAULT' so this process (not an inherited handler)
   # reaps $cmd's own exit status - a handler installed further up would otherwise race
   # this subprocess's own wait, intermittently losing its exit code. Host-agnostic
   # rationale, not nginx-specific: this code runs both embedded in nginx (via
   # ngx_http_perl_module - nginx's own SIGCHLD handling is the original motivation
   # here, see the links below) and standalone inside bin/app-server (a plain
   # Mojolicious process, no nginx-specific quirk to guard against, but harmless/still
   # correct to reset regardless). No fork sites remain in this codebase whose own
   # handler installation this needs to defend against either way (Reservation::launch's
   # own $SIG{'CHLD'}=sub{...} - the other historical source of an inherited handler -
   # is gone.
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

   # Locally reset SIG{CHLD} to 'DEFAULT' so this process (not an inherited handler)
   # reaps $cmd's own exit status - a handler installed further up would otherwise race
   # this subprocess's own wait, intermittently losing its exit code. Host-agnostic
   # rationale, not nginx-specific: this code runs both embedded in nginx (via
   # ngx_http_perl_module - nginx's own SIGCHLD handling is the original motivation
   # here, see the links below) and standalone inside bin/app-server (a plain
   # Mojolicious process, no nginx-specific quirk to guard against, but harmless/still
   # correct to reset regardless). No fork sites remain in this codebase whose own
   # handler installation this needs to defend against either way (Reservation::launch's
   # own $SIG{'CHLD'}=sub{...} - the other historical source of an inherited handler -
   # is gone.
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

# Recursively copy across differing values from source hashref to destination hashref
sub cloneHash ($from, $to) {
   while( my($k, $v) = each %{$from}) {
      if( defined($from->{$k}) ) {
         if( ref($from->{$k}) eq 'HASH' && ref($to->{$k}) eq 'HASH') {
            cloneHash($from->{$k}, $to->{$k});
            next;
         }

         # Always copy - do not gate this on a "only if different" check. That check used to
         # read `($to->{$k} ne $from->{$k})` - `ne` is a *string* comparison, and merely
         # evaluating it stringifies both operands as a side effect of how Perl's
         # string-comparison operators work, regardless of whether the value started life as
         # a clean integer. A scalar that has been through this even once carries Perl's
         # string flag from then on, so JSON::XS later encodes it as a quoted JSON string
         # ("0") rather than a bare number (0) - a real, non-obvious bug found while building
         # the hook-status endpoint: any numeric field written via store()/update() (the only
         # caller of this function) and later
         # read by a type-sensitive JSON consumer (e.g. Python's `if x:`, where the *string*
         # "0" is truthy unlike the *number* 0) was exposed to this, not just hook fields.
         # Dropping the check is safe, not just a workaround: this function's only caller,
         # Reservation::Mutate::update(), already unconditionally returns 1 (always rewrites
         # the reservation db) regardless of what this check decided - so the check was never
         # skipping a real write, only a redundant, already-inert equality test.
         $to->{$k} = $from->{$k};
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
