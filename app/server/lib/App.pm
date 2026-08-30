package App;

use v5.36;

use Digest::SHA qw(sha256_hex);
use URI::Escape;
use Util qw(flog);
use Data qw($CONFIG);

####################################################################################################
# May be used in future to validate git branch references passed into launching containers.
# RegExp rules based on git-check-ref-format
# my $valid_ref_name = qr%^(?!.*/\.)(?!.*\.\.)(?!/)(?!.*//)(?!.*\@\{)(?!\@$)(?!.*\\)[^\000-\037\177 ~^:?*\[]+/[^\000-\037\177 ~^:?*\[]+(?<!\.lock)(?<!/)(?<!\.)$%;

####################################################################################################

flog({ 'service' => "dockside-app" });
Data::load();

####################################################################################################
#
# Asset/HTML-fragment helpers, reused by bin/app-server's own $c-native
# response helpers (_send_branded_page/_render_spa_shell). Every route is
# natively Mojolicious now (bin/app-server), and nginx no longer perl_requires
# this module at all (see Proxy.pm) - only these pure asset/string helpers
# remain here.
#

sub get_asset ($filename) {
   return '' if !defined($filename) || $filename =~ /\.\./;
   open( my $FH, '<', "$CONFIG->{'assetsPath'}/$filename" ) || return '';
   local $/;
   my $contents = <$FH>;
   close $FH;
   return $contents;
}

sub get_client_asset ($filename) {
   return '' if !defined($filename) || $filename =~ /\.\./;
   open( my $FH, '<', "$CONFIG->{'clientDistPath'}/$filename" ) || return '';
   local $/;
   my $contents = <$FH>;
   close $FH;
   return $contents;
}

# A short, opaque cache-buster for a built client asset: a hash of its mtime+size (a cheap
# stat, no file read). It changes on every rebuild — including dev rebuilds with no git
# commit — so an immutable-cached asset URL is refreshed exactly when the file changes.
# Not the git version: that wouldn't change on a dev rebuild and needlessly reveals the
# commit (the version is already in window.dockside.version for traceability). Falls back
# to 'missing' only if the file is absent (a broken deploy — the asset route 404s too, so
# the value is moot); that just avoids an undef-interpolation warning at page render.
sub _asset_version ($filename) {
   my @st = stat("$CONFIG->{'clientDistPath'}/$filename");
   return @st ? substr( sha256_hex("$st[9]-$st[7]"), 0, 12 ) : 'missing';
}

sub get_header ($title = undef) {
   return get_asset('header.html') .
      "   <title>" . ($title // 'Dockside - A dev and staging environment in one - From NewsNow Labs') . "</title>\n" .
      get_asset('gtm.html');
}

####################################################################################################

sub log_status ($sub, $json) {
   flog("$sub: " . $json->{'msg'});

   return $json;
}

####################################################################################################

sub split_args ($queryString) {
   # Defensive: every current caller (bin/app-server's own _get_args/_query) already
   # guards against an empty querystring before calling this, but keep tolerating undef
   # here too, cheaply, rather than depending on every future caller to guard it upstream.
   $queryString //= '';

   # Split querystring-style arguments, and unescape them
   my %hash = map { uri_unescape($_) } split( /[=&]/, $queryString );

   # Map once more to eliminate any hash key mapping to undef
   return { map { $_ // '' } %hash };
}

1;
