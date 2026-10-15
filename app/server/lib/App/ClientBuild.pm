package App::ClientBuild;

use v5.36;

use JSON::XS ();
use Time::HiRes ();

####################################################################################################
#
# The built web client's entry files, as named by the manifest the client build writes.
#
# The client build (app/client/vite.config.js) gives every file it emits a name containing a hash
# of its content, under dist/assets/, and writes dist/manifest.json mapping each source module to
# its built files. The page loads the entry module and the entry's stylesheets by those names.
# Lazy-loaded chunks import the entry module by the same name, so the browser loads it once.
#
# This module has no side effects on load and reads no configuration: callers pass the client's
# dist folder. It is loaded by every server process that writes the app's pages.
#

# A file name the manifest may give for the entry module or a stylesheet: a single flat name under
# assets/, with no '/', no bare '..' and nothing that could break out of an HTML attribute.
my $FILE_NAME = qr{\Aassets/[\w\-]+(?:\.[\w\-]+)+\z};

# The last manifest read by this process, and the stat signature of the file it came from.
my %CACHE;

# Returns { 'js' => '/assets/<entry>.js', 'css' => [ '/assets/<entry>.css', ... ] }: the URL paths
# of the entry module and of the stylesheets the entry imports. Dies with a one-line message naming
# the problem if the manifest is missing, is not valid JSON, does not name exactly one entry, or
# names a file outside the expected shape. The result is kept per process and re-read when the
# manifest's inode, size or modification time changes; the modification time is read to
# sub-second precision, since a filesystem may reuse a freed inode and two manifests of a build
# are the same size whenever only their hashed names differ. A manifest that fails these checks is
# never kept, so the next call reads the file again; this covers a request that arrives while a
# build is still writing it.
sub entry ($dist) {
   my $path = "$dist/manifest.json";
   my @st   = Time::HiRes::stat($path) or die "client build manifest missing: $path\n";
   my $sig  = join( '-', $path, @st[ 1, 7, 9 ] );
   return $CACHE{'entry'} if defined $CACHE{'sig'} && $CACHE{'sig'} eq $sig;

   open( my $fh, '<', $path ) or die "client build manifest unreadable: $path: $!\n";
   my $json = do { local $/; <$fh> };
   close($fh);

   my $manifest = eval { JSON::XS->new->decode($json) };
   die "client build manifest is not a JSON object: $path\n" unless ref($manifest) eq 'HASH';

   my @entries = grep { ref($_) eq 'HASH' && $_->{'isEntry'} } values %$manifest;
   die "client build manifest names " . scalar(@entries) . " entry modules, expected 1: $path\n"
      unless @entries == 1;

   my $entry = $entries[0];
   my @css   = ref( $entry->{'css'} ) eq 'ARRAY' ? @{ $entry->{'css'} } : ();
   foreach my $file ( $entry->{'file'}, @css ) {
      die "client build manifest names an unexpected file '" . ( $file // '' ) . "': $path\n"
         unless defined($file) && !ref($file) && $file =~ $FILE_NAME;
   }

   %CACHE = (
      'sig'   => $sig,
      'entry' => { 'js' => "/$entry->{'file'}", 'css' => [ map {"/$_"} @css ] },
   );
   return $CACHE{'entry'};
}

1;
