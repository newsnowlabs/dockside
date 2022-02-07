# Part of the Reservation:: package, split out for convenience.
package Reservation;

use strict;

use Data qw($CONFIG $HOSTNAME $INNER_DOCKERD);

################################################################################
# UTILITY FUNCTIONS/METHODS
# -------------------------

my $PLACEHOLDERS = {
   'unixUser' => 'unixuser',
   'ideUser' => 'unixuser',
   'user' => 'owner',
   'container' => 'container',
   'metadata' => 'metadata_server'
};

sub _placeholders {
   my $self = shift;
   
   local $_ = shift;

   s/\{([^\}\.]+)(?:\.([^\}]+))?\}/do {
      my $sub = $PLACEHOLDERS->{$1};
      $sub ? $self->$sub($2) : die Exception->new( 'msg' => "Unknown placeholder '$&' in '$_'" );
   }/egs;

   return $_;
}

################################################################################
# DOCKER COMMAND LINE GENERATION
#

sub cmdline_security {
   my $self = shift;

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

sub cmdline_ports {
   my $self = shift;

   # We only need to publish ports to the host in gatewayMode.
   return () unless $CONFIG->{'gatewayMode'};
   
   my @ports = $self->profileObject->ports();

   return map { sprintf("-p=%d", $_) } @ports if @ports;

   return ();
}

sub cmdline_runtime {
   my $self = shift;
   
   my $runtime = $self->data('runtime');

   return sprintf("--runtime=%s", $runtime) if $runtime;

   return ();
}

sub cmdline_network {
   my $self = shift;
   
   my $network = $self->data('network');

   return sprintf("--network=%s", $network) if $network;

   return ();
}

sub cmdline_docker_args {
   my $self = shift;
   
   return (ref($self->profileObject->{'dockerArgs'}) eq 'ARRAY') ?
      @{$self->profileObject->{'dockerArgs'}} : ();
}

sub cmdline_mounts_tmpfs {
   my $self = shift;
   
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

sub cmdline_mounts_bind {
   my $self = shift;
   
   return map {
      join(',',
         "--mount=type=bind",
         "dst=" . $self->_placeholders($_->{'dst'}),
         "src=$_->{'src'}",
      )
   # FIXME: Add profile accessor
   } @{ $self->profileObject->{'mounts'}{'bind'} };
}

sub cmdline_mounts_volume {
   my $self = shift;
   
   return map {
      join(',',
         "--mount=type=volume",
         "dst=" . $self->_placeholders($_->{'dst'}),
         $_->{'src'} ? ("src=$_->{'src'}") : (),
      )
   # FIXME: Add profile accessor
   } @{ $self->profileObject->{'mounts'}{'volume'} };
}

sub cmdline_mounts_lxcfs {
   my $self = shift;

   # Disabled unless lxcfs.mountpoints[] specified in config.json.
   return () unless $CONFIG->{'lxcfs'} && ref($CONFIG->{'lxcfs'}{'mountpoints'}) eq 'ARRAY'
      && $CONFIG->{'lxcfs'}{'available'} == 1;

   # If lxcfs.default === true in config.json, disable if profile lxcfs === false
   if( $CONFIG->{'lxcfs'}{'default'} == 1 ) {
      return () if exists($self->profileObject->{'lxcfs'}) && $self->profileObject->{'lxcfs'} == 0;
   }
   # If lxcfs.default === false in config.json, disable unless profile lxcfs === true
   elsif( $CONFIG->{'lxcfs'}{'default'} == 0 ) {
      return () unless exists($self->profileObject->{'lxcfs'}) && $self->profileObject->{'lxcfs'} == 1;
   }

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

sub cmdline_mounts {
   my $self = shift;
   
   return (
      $self->cmdline_mounts_tmpfs(),
      $self->cmdline_mounts_bind(),
      $self->cmdline_mounts_volume(),
      $self->cmdline_mounts_lxcfs()
   );
}

sub cmdline_image {
   my $self = shift;
   
   return $self->data('image');
}

sub cmdline_name {
   my $self = shift;
   
   return ('--name', $self->name);
}

sub cmdline_ide_mount {
   my $self = shift;

   unless( $self->profileObject->should_mount_ide ) {
      return ();
   }

   my $idePath = $CONFIG->{'ide'}{'path'} || '/opt/dockside';
   my $ideVolume;
   my $ideVolumeType;

   # If $HOSTNAME is undefined, try to bind-mount the ideVolume from the 'host',
   # assuming the ide.path provided in config.json. This is appropriate where Dockside
   # is launched in a Sysbox container or other container in which the host docker.sock is not bind-mounted
   # and /opt/dockside from within the Dockside container image should be bind-mounted.
   if($INNER_DOCKERD) {
      # When launching a devtainer using an inner dockerd instance, whether using Sysbox, Docker-in-Docker, or Podman
      # the devtainer cannot mount the Dockside volume (as there is no Dockside container, or volume, accessible to the inner dockerd).
      # Instead, bind-mount $idePath from the Dockside container to the devtainer.
      $ideVolume = $idePath;
      $ideVolumeType = 'bind';
   }
   else {
      # When launching a devtainer within the same dockerd instance as is running Dockside, identify the Docker volume to mount in the devtainer.
      if($HOSTNAME) {
         $ideVolume = Containers->containers->{$HOSTNAME}{'inspect'}{'ideVolume'};
         $ideVolumeType = 'volume';
      }
      else {
         die Exception->new( 'msg' => "Failed to locate IDE volume because expected Dockside container hostname is undefined" );
      }
   }

   if(!$ideVolume) {
      die Exception->new( 'msg' => "Failed to locate IDE volume for hostname '$HOSTNAME'" );
   }

   flog("Reservation::createContainerReservation: for hostname '$HOSTNAME', discovered ideVolume '$ideVolume'");

   return ("--mount=type=$ideVolumeType,src=$ideVolume,dst=$idePath,ro");
}

sub cmdline_init {
   my $self = shift;
   
   return $self->profileObject->run_docker_init ? ('--init') : ();
}

sub cmdline_command {
   my $self = shift;
   
   my @command;
   
   if(ref($self->data('command')) eq 'ARRAY') {
      @command = @{$self->data('command')};
   }
   else {
      @command = $self->profileObject->default_command();
   }

   return map { $self->_placeholders($_) } @command;
}

sub cmdline_entrypoint {
   my $self = shift;

   if(my $entrypoint = $self->profileObject->entrypoint) {
      return ('--entrypoint', $entrypoint);
   }

   return ();
}

sub cmdline {
   my $self = shift;

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
      $self->cmdline_entrypoint(),
      $self->cmdline_image(),
      $self->cmdline_command()
   );
}

sub ide_command {
   my $self = shift;

   my @command = @{$self->{'ide'}{'command'} // []};

   return map { $self->_placeholders($_) } @command;
}

sub unixuser {
   my $self = shift;

   return $self->data('unixuser');
}

sub container {
   my $self = shift;
   my $prop = shift;

   my $dataProp = {
      'fqdn' => 'FQDN',
      'hostname' => 'FQDN'
   }->{$prop};

   return $dataProp ? $self->data($dataProp) : '';
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

sub metadata_server {
   my $self = shift;
   my $prop = shift;

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

   if( $prop eq 'uri' ) {
      return "http://$host/computeMetadata/v1/";
   }

   if( $prop eq 'startupScriptUri' ) {
      return "http://$host/computeMetadata/v1/instance/attributes/startup-script";
   }

   return $host;
}

1;
