# Part of the Reservation:: package, split out for convenience.
package Reservation;

use v5.36;

use JSON;
use Exception;
use Data qw($CONFIG $HOSTNAME $INNER_DOCKERD);

################################################################################
# UTILITY FUNCTIONS/METHODS
# -------------------------

my $PLACEHOLDERS = {
   'unixuser' => 'unixuser',
   'ideuser' => 'unixuser',
   'user' => 'owner',
   'container' => 'container',
   'metadata' => 'metadata_server',
   'giturl' => 'gitURL',
   'option' => 'option_value',
};

sub _placeholders ($self, $value) {
   local $_ = $value;

   # Only ever substitutes when the brace contents are an exact (case-insensitive)
   # match for one of the known prefixes above - anything else is left untouched,
   # rather than treated as a malformed placeholder. Profile-author command/hook
   # scripts routinely contain unrelated curly braces (shell parameter expansion
   # like ${VAR#pattern}, brace command grouping like `{ cmd; }`, embedded JSON,
   # awk/printf blocks, ...); since none of those ever happen to equal one of this
   # short, fixed set of words, requiring an exact match - rather than merely "some
   # {...} was found" - removes the false-positive collisions without needing a
   # different delimiter. Trade-off: a typo'd prefix (e.g. '{usre.name}') silently
   # passes through instead of erroring, since it's indistinguishable from ordinary
   # script text once unrecognized {...} is no longer treated as a mistake.
   s/\{([^\}\.]+)(?:\.([^\}]+))?\}/do {
      my $sub = $PLACEHOLDERS->{lc($1)};
      $sub ? $self->$sub($2) : $&;
   }/egs;

   return $_;
}

################################################################################
# DOCKER COMMAND LINE GENERATION
#

sub cmdline_security ($self) {
   my $security = $self->profileObject->{'security'};

   my @opts;

   foreach my $m ('apparmor', 'seccomp') {
      my $profile = ($security->{$m} // $CONFIG->{'docker'}{'security'}{$m}) // 'unspecified';

      if($profile ne 'unspecified') {
         push(@opts, sprintf("--security-opt=%s=%s", $m, $profile));
      }
   }

   if($security->{'no-new-privileges'}) {
      push(@opts, sprintf("--security-opt=no-new-privileges"));
   }

   if($security->{'labels'}) {
      if( ref($security->{'labels'}) eq 'SCALAR' && $security->{'labels'} eq 'disable' ) {
         push(@opts, sprintf("--security-opt=label=disable"));
      }
      elsif( ref($security->{'labels'}) eq 'HASH' ) {
         foreach my $opt ('user', 'role', 'type', 'level') {
            push(@opts, sprintf("--security-opt=label=%s:%s", $opt, $security->{'labels'}{$opt}));
         }
      }
   }

   return @opts;
}

sub cmdline_ports ($self) {
   # We only need to publish ports to the host in gatewayMode.
   return () unless $CONFIG->{'gatewayMode'};
   
   my @ports = $self->profileObject->ports();

   return map { sprintf("-p=%d", $_) } @ports if @ports;

   return ();
}

sub cmdline_runtime ($self) {
   my $runtime = $self->data('runtime');

   return sprintf("--runtime=%s", $runtime) if $runtime;

   return ();
}

sub cmdline_network ($self) {
   my $network = $self->data('network');

   return sprintf("--network=%s", $network) if $network;

   return ();
}

sub cmdline_docker_args ($self) {
   return (ref($self->profileObject->{'dockerArgs'}) eq 'ARRAY') ?
      map { $self->_placeholders($_) } @{$self->profileObject->{'dockerArgs'}} : ();
}

# This function generates mount options for tmpfs mounts.
# The source of a tmpfs mount is always the empty string.
# However, additional options may be specified.
# If any of the options 'tmpfs-uid', 'tmpfs-gid', 'tmpfs-noexec', 'tmpfs-nosuid' or 'tmpfs-nodev'
# are specified, the mount is generated using the --tmpfs option.
# Otherwise, it is generated using the --mount option.
sub cmdline_mounts_tmpfs ($self) {
   return map {
         ($_->{'tmpfs-uid'} || $_->{'tmpfs-gid'} || $_->{'tmpfs-noexec'} || $_->{'tmpfs-nosuid'} || $_->{'tmpfs-nodev'}) ?
         (
            join(':',
               "--tmpfs=" . $self->_placeholders($_->{'dst'}),
               join(',',
                  $_->{'tmpfs-size'} ? "size=$_->{'tmpfs-size'}" : (),
                  $_->{'tmpfs-mode'} ? "mode=$_->{'tmpfs-mode'}" : (),
                  $_->{'tmpfs-uid'} ? "uid=$_->{'tmpfs-uid'}" : (),
                  $_->{'tmpfs-gid'} ? "gid=$_->{'tmpfs-gid'}" : (),
                  $_->{'tmpfs-noexec'} ? "noexec=$_->{'tmpfs-noexec'}" : (),
                  $_->{'tmpfs-nosuid'} ? "nosuid=$_->{'tmpfs-nosuid'}" : (),
                  $_->{'tmpfs-nodev'} ? "nodev=$_->{'tmpfs-nodev'}" : ()
               )
            )
         )
         :
         join(',',
            "--mount=type=tmpfs",
            "dst=" . $self->_placeholders($_->{'dst'}),
            $_->{'tmpfs-size'} ? "tmpfs-size=$_->{'tmpfs-size'}" : (),
            $_->{'tmpfs-mode'} ? "tmpfs-mode=$_->{'tmpfs-mode'}" : ()
         )
   # FIXME: Add profile accessor
   } @{ $self->profileObject->{'mounts'}{'tmpfs'} };
}

# This function generates mount options for bind mounts.
# The source of a bind mount must always be specified.
sub cmdline_mounts_bind ($self) {
   return map {
      join(',',
         "--mount=type=bind",
         "dst=" . $self->_placeholders($_->{'dst'}),
         "src=$_->{'src'}",
         $_->{'readonly'} ? 'readonly=true' : (),
      )
   # FIXME: Add profile accessor
   } @{ $self->profileObject->{'mounts'}{'bind'} };
}

# This function generates mount options for named volumes.
# The source of a volume mount may be omitted, in which case Docker
# will create a new named volume with the specified destination path.
sub cmdline_mounts_volume ($self) {
   return map {
      join(',',
         "--mount=type=volume",
         "dst=" . $self->_placeholders($_->{'dst'}),
         $_->{'src'} ? ("src=" . $self->_placeholders($_->{'src'})) : (),
         $_->{'readonly'} ? 'readonly=true' : (),
      )
   # FIXME: Add profile accessor
   } @{ $self->profileObject->{'mounts'}{'volume'} };
}

sub cmdline_mounts_lxcfs ($self) {
   # Disabled unless lxcfs.mountpoints[] specified in config.json.
   return () unless $self->profileObject->has_lxcfs_enabled;

   my $mountpoint = $CONFIG->{'lxcfs'}{'mountpoint'} // '/var/lib/lxcfs';

   # Remove any trailing '/' as we won't need it.
   $mountpoint =~ s!/+$!!;

   return map {
      m!^/! ?
      join(',',
         "--mount=type=bind",
         "dst=$_",
         "src=$mountpoint$_",
      )
      :
      join(',',
         "--mount=type=bind",
         "dst=/proc/$_",
         "src=$mountpoint/proc/$_",
      )
   } @{$CONFIG->{'lxcfs'}{'mountpoints'}};
}

sub cmdline_mounts ($self) {
   return (
      $self->cmdline_mounts_tmpfs(),
      $self->cmdline_mounts_bind(),
      $self->cmdline_mounts_volume(),
      $self->cmdline_mounts_lxcfs()
   );
}

sub cmdline_image ($self) {
   return $self->data('image');
}

sub cmdline_name ($self) {
   return ('--name', $self->name);
}

sub cmdline_hostname ($self) {
   return ('--hostname', $self->name);
}

sub cmdline_ide_mount ($self) {
   die Exception->new( 'msg' => "Failed to locate IDE and/or host data volumes because expected Dockside container hostname is undefined" )
      unless $HOSTNAME || $INNER_DOCKERD;

   my $idePath = $CONFIG->{'ide'}{'path'};
   my $hostDataPath = $CONFIG->{'ssh'}{'path'};
   my $ide;
   my $hostData;

   my @mounts;

   # When launching a devtainer using an inner dockerd instance, whether using Sysbox, Docker-in-Docker, Podman,
   # RunCVM or some other approach where the docker.sock is not bind-mounted
   # the devtainer cannot mount the Dockside volume (as there is no Dockside container, or volume, accessible to the inner dockerd).
   # In this case we bind-mount $idePath from the Dockside container to the devtainer.
   if( $self->profileObject->should_mount_ide ) {
      $ide = $INNER_DOCKERD ? ['bind', $idePath] : 
         $HOSTNAME ? Containers->containers->{$HOSTNAME}{'inspect'}{'ideVolume'} : undef;

      die Exception->new( 'msg' => "Failed to locate IDE volume for host '$HOSTNAME'" ) unless $ide;

      push(@mounts, "--mount=type=$$ide[0],src=$$ide[1],dst=$idePath,ro");
      flog("Reservation::createContainerReservation: for hostname '$HOSTNAME', discovered ide mount type '$$ide[0]' src/named '$$ide[1]'");
   }

   if( $self->profileObject->ssh ) {
      $hostData = $INNER_DOCKERD ? ['bind', $hostDataPath] :
         $HOSTNAME ? Containers->containers->{$HOSTNAME}{'inspect'}{'hostDataVolume'} : undef;

      # FIXME: Should this throw error?

      if($hostData) {
         push(@mounts, "--mount=type=$$hostData[0],src=$$hostData[1],dst=$hostDataPath,ro");
         flog("Reservation::createContainerReservation: for hostname '$HOSTNAME', discovered host data mount type '$$hostData[0]' src/named '$$hostData[1]'");
      }
   }

   return @mounts;
}

sub cmdline_init ($self) {
   return $self->profileObject->run_docker_init ? ('--init') : ();
}

sub cmdline_command ($self) {
   my @command;
   
   if(ref($self->data('command')) eq 'ARRAY') {
      @command = @{$self->data('command')};
   }
   else {
      @command = $self->profileObject->default_command();
   }

   return map { $self->_placeholders($_) } @command;
}

sub cmdline_entrypoint ($self) {
   my $entrypoint;
   if($self->data('entrypoint')) {
      $entrypoint = $self->data('entrypoint');
   }
   elsif($self->profileObject->entrypoint) {
      $entrypoint = $self->profileObject->entrypoint;
   }
   else {
      return ();
   }

   return ('--entrypoint', $entrypoint);
}

sub cmdline ($self) {
   # networks
   # image
   # mounts
   # dockerArgs

   return (
      $self->cmdline_security(),
      $self->cmdline_runtime(),
      $self->cmdline_ports(),
      $self->cmdline_network(),
      $self->cmdline_docker_args(),
      $self->cmdline_mounts(),
      $self->cmdline_ide_mount(),
      $self->cmdline_init(),
      $self->cmdline_name(),
      $self->cmdline_hostname(),
      $self->cmdline_entrypoint(),
      $self->cmdline_image(),
      $self->cmdline_command()
   );
}

# Docker CLI size-string parsing (--memory=1G, tmpfs-size, ...): digits + an optional
# b/k/kb/m/mb/g/gb unit (case-insensitive), matching Docker CLI's own convention -
# not a general-purpose parser, just what the flags below actually use.
sub _parse_docker_size ($str) {
   return 0 + $str if $str =~ /^\d+$/;
   my ( $num, $unit ) = $str =~ /^([\d.]+)\s*([a-zA-Z]*)$/
      or die Exception->new( 'msg' => "Internal error - cannot parse docker size string '$str'" );
   my %mult = ( '' => 1, 'b' => 1, 'k' => 1024, 'kb' => 1024, 'm' => 1024**2, 'mb' => 1024**2, 'g' => 1024**3, 'gb' => 1024**3 );
   my $m = $mult{ lc($unit) };
   die Exception->new( 'msg' => "Internal error - unknown docker size unit '$unit' in '$str'" ) unless defined $m;
   return int( $num * $m );
}

# Sibling to cmdline() above, emitting a hash for the Docker Engine API's
# POST /containers/create body (see Reservation::create_async) instead of a CLI
# argv list - same specification (the cmdline_* builders' own underlying data),
# a second rendering. Built by reading the *same* structured profile/reservation
# data each cmdline_* builder above reads, not by parsing those builders' own CLI-
# string output back into structured data - that would be the wrong direction,
# fragile by construction (lossy string round-tripping) where this is direct.
#
# --name is deliberately not in this hash: on the CLI it's a flag, but on the
# Create API it's the ?name= query parameter, not part of the body - the caller
# (create_async) already has $self->name directly and supplies it there.
#
# dockerArgs (profile-declared, free-form CLI flags - cmdline_docker_args() above)
# has no generic CLI-flag-to-JSON translation available - unlike every other
# field here, these are arbitrary strings a profile author can put anything into.
# Scoped instead to exactly the flag patterns every profile in this repo actually
# uses today (--memory, --pids-limit, --cpus, --env - verified by grep across
# app/server/example/config/profiles/*.json and the integration test fixtures) -
# anything else fails loudly with a clear message naming the unsupported flag,
# rather than silently dropping it or creating a container that doesn't match
# what the profile declared. Extending this list for a new flag pattern is
# straightforward if/when a profile actually needs one outside this set.
sub cmdline_json ($self) {
   # Mirrors cmdline_security()'s own per-flag logic above, reading $security directly rather
   # than parsing that function's own CLI-flag output back apart - see this function's own
   # header comment on why. Docker's Create API HostConfig.SecurityOpt array wants the same
   # bare "key=value"/"label=disable" strings the --security-opt flag's own value already is,
   # just without the "--security-opt=" prefix a CLI arg needs and a JSON array element doesn't.
   my $security = $self->profileObject->{'security'};
   my @securityOpt;
   foreach my $m ('apparmor', 'seccomp') {
      my $profile = ($security->{$m} // $CONFIG->{'docker'}{'security'}{$m}) // 'unspecified';
      push(@securityOpt, "$m=$profile") if $profile ne 'unspecified';
   }
   if($security->{'no-new-privileges'}) {
      push(@securityOpt, 'no-new-privileges');
   }
   if($security->{'labels'}) {
      if( ref($security->{'labels'}) eq 'SCALAR' && $security->{'labels'} eq 'disable' ) {
         push(@securityOpt, 'label=disable');
      }
      elsif( ref($security->{'labels'}) eq 'HASH' ) {
         foreach my $opt ('user', 'role', 'type', 'level') {
            push(@securityOpt, "label=$opt:$security->{'labels'}{$opt}");
         }
      }
   }

   my $hostConfig = {};
   $hostConfig->{'SecurityOpt'} = \@securityOpt if @securityOpt;

   if ( my $runtime = $self->data('runtime') ) {
      $hostConfig->{'Runtime'} = $runtime;
   }
   if ( my $network = $self->data('network') ) {
      $hostConfig->{'NetworkMode'} = $network;
   }

   my $exposedPorts = {};
   if ( $CONFIG->{'gatewayMode'} ) {
      my $portBindings = {};
      for my $port ( $self->profileObject->ports() ) {
         $exposedPorts->{"$port/tcp"}  = {};
         $portBindings->{"$port/tcp"} = [ {} ];   # empty binding = Docker picks the host port
      }
      $hostConfig->{'PortBindings'} = $portBindings if %$portBindings;
   }

   my @env;
   if ( ref( $self->profileObject->{'dockerArgs'} ) eq 'ARRAY' ) {
      for my $raw ( @{ $self->profileObject->{'dockerArgs'} } ) {
         my $arg = $self->_placeholders($raw);
         if ( $arg =~ /^--memory=(.+)$/ ) {
            $hostConfig->{'Memory'} = _parse_docker_size($1);
         }
         elsif ( $arg =~ /^--pids-limit=(-?\d+)$/ ) {
            $hostConfig->{'PidsLimit'} = 0 + $1;
         }
         elsif ( $arg =~ /^--cpus=([\d.]+)$/ ) {
            $hostConfig->{'NanoCpus'} = int( $1 * 1_000_000_000 );
         }
         elsif ( $arg =~ /^--env=(.+)$/ ) {
            push( @env, $1 );
         }
         else {
            die Exception->new( 'msg' => "Internal error - dockerArgs entry '$arg' has no JSON Create API equivalent implemented" );
         }
      }
   }

   my @mounts;
   for my $m ( @{ $self->profileObject->{'mounts'}{'tmpfs'} } ) {
      die Exception->new( 'msg' => "Internal error - tmpfs mount options beyond size/mode have no JSON Create API equivalent implemented (dst='$m->{'dst'}')" )
         if $m->{'tmpfs-uid'} || $m->{'tmpfs-gid'} || $m->{'tmpfs-noexec'} || $m->{'tmpfs-nosuid'} || $m->{'tmpfs-nodev'};
      my $tmpfsOptions = {};
      $tmpfsOptions->{'SizeBytes'} = _parse_docker_size( $m->{'tmpfs-size'} ) if $m->{'tmpfs-size'};
      $tmpfsOptions->{'Mode'}      = oct( $m->{'tmpfs-mode'} )               if $m->{'tmpfs-mode'};
      push( @mounts, {
         'Type'         => 'tmpfs',
         'Target'       => $self->_placeholders( $m->{'dst'} ),
         'TmpfsOptions' => $tmpfsOptions,
      } );
   }
   for my $m ( @{ $self->profileObject->{'mounts'}{'bind'} } ) {
      push( @mounts, {
         'Type'   => 'bind',
         'Source' => $m->{'src'},
         'Target' => $self->_placeholders( $m->{'dst'} ),
         ( $m->{'readonly'} ? ( 'ReadOnly' => JSON::true ) : () ),
      } );
   }
   for my $m ( @{ $self->profileObject->{'mounts'}{'volume'} } ) {
      push( @mounts, {
         'Type'   => 'volume',
         ( $m->{'src'} ? ( 'Source' => $self->_placeholders( $m->{'src'} ) ) : () ),
         'Target' => $self->_placeholders( $m->{'dst'} ),
         ( $m->{'readonly'} ? ( 'ReadOnly' => JSON::true ) : () ),
      } );
   }
   if ( $self->profileObject->has_lxcfs_enabled ) {
      my $mountpoint = $CONFIG->{'lxcfs'}{'mountpoint'} // '/var/lib/lxcfs';
      $mountpoint =~ s!/+$!!;
      for my $mp ( @{ $CONFIG->{'lxcfs'}{'mountpoints'} } ) {
         my ( $src, $dst ) = $mp =~ m!^/! ? ( "$mountpoint$mp", $mp ) : ( "$mountpoint/proc/$mp", "/proc/$mp" );
         push( @mounts, { 'Type' => 'bind', 'Source' => $src, 'Target' => $dst } );
      }
   }

   # Mirrors cmdline_ide_mount's own logic (see its own comment for the
   # INNER_DOCKERD/HOSTNAME source-discovery reasoning) - unchanged here, just
   # rendered as Mounts entries instead of --mount= strings.
   die Exception->new( 'msg' => "Failed to locate IDE and/or host data volumes because expected Dockside container hostname is undefined" )
      unless $HOSTNAME || $INNER_DOCKERD;
   my $idePath      = $CONFIG->{'ide'}{'path'};
   my $hostDataPath = $CONFIG->{'ssh'}{'path'};
   if ( $self->profileObject->should_mount_ide ) {
      my $ide = $INNER_DOCKERD ? [ 'bind', $idePath ]
              : $HOSTNAME       ? Containers->containers->{$HOSTNAME}{'inspect'}{'ideVolume'}
              : undef;
      die Exception->new( 'msg' => "Failed to locate IDE volume for host '$HOSTNAME'" ) unless $ide;
      push( @mounts, { 'Type' => $$ide[0], 'Source' => $$ide[1], 'Target' => $idePath, 'ReadOnly' => JSON::true } );
   }
   if ( $self->profileObject->ssh ) {
      my $hostData = $INNER_DOCKERD ? [ 'bind', $hostDataPath ]
                   : $HOSTNAME       ? Containers->containers->{$HOSTNAME}{'inspect'}{'hostDataVolume'}
                   : undef;
      if ($hostData) {
         push( @mounts, { 'Type' => $$hostData[0], 'Source' => $$hostData[1], 'Target' => $hostDataPath, 'ReadOnly' => JSON::true } );
      }
   }
   $hostConfig->{'Mounts'} = \@mounts if @mounts;

   $hostConfig->{'Init'} = JSON::true if $self->profileObject->run_docker_init;

   my $entrypoint = $self->data('entrypoint') || $self->profileObject->entrypoint || undef;

   my @command = ref( $self->data('command') ) eq 'ARRAY'
      ? @{ $self->data('command') }
      : $self->profileObject->default_command();
   @command = map { $self->_placeholders($_) } @command;

   return {
      'Image'    => $self->data('image'),
      'Hostname' => $self->name,
      ( defined($entrypoint) ? ( 'Entrypoint' => [$entrypoint] ) : () ),
      'Cmd'      => \@command,
      ( @env             ? ( 'Env'          => \@env )          : () ),
      ( %$exposedPorts    ? ( 'ExposedPorts' => $exposedPorts )  : () ),
      'HostConfig' => $hostConfig,
   };
}

sub ide_command ($self) {
   my @command = @{$self->{'ide'}{'command'} // []};

   return map { $self->_placeholders($_) } @command;
}

sub ide_command_launcher ($self) {
   my @command = $self->ide_command();

   return $command[0];
}

sub ide_command_env ($self) {
   my $env = $self->{'ide'}{'env'} // {};

   return map { "--env=$_=" . $self->_placeholders($env->{$_}) } keys %$env;
}

sub unixuser ($self, $null = undef) {
   return $self->data('unixuser');
}

sub container ($self, $prop = undef) {
   return '' unless defined $prop;

   my $dataProp = {
      'fqdn' => 'FQDN',
      'hostname' => 'FQDN'
   }->{$prop};

   die Exception->new( 'msg' => "Unknown placeholder '{container.$prop}' - '$prop' is not a recognized container property" )
      unless $dataProp;

   return $self->data($dataProp);
}

sub gitURL ($self) {
   return $self->data('gitURL');
}

sub option_value ($self, $name = undef) {
   return '' unless defined $name;

   die Exception->new( 'msg' => "Unknown placeholder '{option.$name}' - '$name' is not declared in this profile's options" )
      unless grep { $_->{'name'} eq $name } @{$self->profileObject->options};

   return ($self->data('options') // {})->{$name} // '';
}

sub hook_script ($self, $name) {
   return $self->profileObject->hooks->{$name}{'script'} // '';
}

# If the dockside container and launched container share the default 
# bridge network at launch time, use the dockside container’s IP.
#
# If the dockside container and launched container share any non-default/custom
# network at launch time, use the container’s name or id.
#
# If the dockside container and launched container do not share any network at
# launch time, throw an exception.
#
# This is not foolproof, as the metadata server won’t be addressable in certain
# post-launch scenarios when the networks a container is connected to changes
#
# e.g.
# - Launch container on default bridge network - it will have access to
#   metadata server on boot, but will lose access if reconnected solely to a
#   custom network.
#
# - Launch container on custom network - it will have access to metadata server
#   on boot, and if reconnected to any other custom network(s) - but will lose
#   access if reconnected solely to the default bridge network.
#
# This should provide sufficient flexibility, though. Docker’s default network
# is provided for backwards compatibility reasons, provides inferior
# capabilities for inter-container communication, and its use is discouraged.
# So if one is going to use one custom network, there is really no need to use
# the default bridge network at all. (We actually do, but could trivially
# change that and probably should).

# N.B. We assume here for now that the default network is called 'bridge'.

sub metadata_server ($self, $prop = undef) {

   my $containers = Containers->containers;

   unless( $HOSTNAME && $containers->{$HOSTNAME} ) {
      die Exception->new( 'msg' => "Cannot identify metadata server hostname/IP for empty hostname" );
   }

   my $name = $containers->{$HOSTNAME}{'docker'}{'Names'};
   my $hostNetworks = $containers->{$HOSTNAME}{'inspect'}{'Networks'};
   my @NonDefaultNetworks = grep { $_ ne 'bridge' } keys %$hostNetworks;
   my $containerNetwork = $self->{'inspect'}{'Networks'}[0] // $self->data('network');

   if( !$hostNetworks->{ $containerNetwork } ) {
      die Exception->new( 'msg' => "Metadata server must be on selected container network '$containerNetwork' to use '{metadata}' placeholder" );
   }

   my $host = ($containerNetwork eq 'bridge') ? $hostNetworks->{'bridge'}{'IPAddress'} : $name;

   if( defined $prop && $prop eq 'uri' ) {
      return "http://$host/computeMetadata/v1/";
   }

   if( defined $prop && $prop eq 'startupScriptUri' ) {
      return "http://$host/computeMetadata/v1/instance/attributes/startup-script";
   }

   return $host;
}

1;
