# Part of the Reservation:: package, split out for convenience.
package Reservation;

use v5.36;

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

   s/\{([^\}\.]+)(?:\.([^\}]+))?\}/do {
      my $sub = $PLACEHOLDERS->{lc($1)};
      $sub ? $self->$sub($2) : die Exception->new( 'msg' => "Unknown placeholder '$&' in '$_'" );
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
      @{$self->profileObject->{'dockerArgs'}} : ();
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

sub ide_command ($self) {
   my @command = @{$self->{'ide'}{'command'} // []};

   return map { $self->_placeholders($_) } @command;
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

   return $dataProp ? $self->data($dataProp) : '';
}

sub gitURL ($self) {
   return $self->data('gitURL');
}

sub option_value ($self, $name = undef) {
   return '' unless defined $name;
   return ($self->data('options') // {})->{$name} // '';
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
