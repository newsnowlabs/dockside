#!/bin/bash

DATA_DIR=/data
USER=${USER:-dockside}
APP=${APP:-dockside}
APP_HOME=${APP_HOME:-/home/newsnow}
APP_DIR=$APP_HOME/$APP

OPT_SSL_ZONES=()
OPT_PATH="/opt/dockside"

IDE_PATH="$(ls -d $OPT_PATH/ide/*/* | tail -n 1)"

. $APP_DIR/app/scripts/includes/log_do

safe_curl() {
   curl --fail --silent --retry 7 --max-time 5 --location "$@"
}

ide_cmd() {
   local cmd="$1"
   shift

   $IDE_PATH/bin/$cmd "$@"
}

jq_config_set() {
  if jq "$@" $DATA_DIR/config/config.json >/tmp/config.json; then
    mv /tmp/config.json $DATA_DIR/config/config.json
  else
    log "Failed to update config.json; aborting!"
    exit 1
  fi
}

jq_config_get() {
  jq "$@" $DATA_DIR/config/config.json 2>/dev/null
}

init_config() {
  log "  - Initialising config.json with random uidCookie name and salt ..."
  
  # Set unique salt and cookie name
  local salt="$(dd if=/dev/urandom bs=1k count=1 2>/dev/null | sha256sum | cut -d' ' -f1)"
  local name="$RANDOM"

  jq '.uidCookie.salt = $salt | .uidCookie.name += $name' \
    --arg salt "$salt" \
    --arg name "$name" \
    $DATA_DIR/config/config.json >/tmp/config.json && mv /tmp/config.json $DATA_DIR/config/config.json
}

init_admin_credentials() {
  
  # Set unique admin password
  PASSWD=$($APP_DIR/app/server/bin/mkpasswd)
  log "  - Initialising 'admin' password"

  local CRYPT=$(perl -I $APP_DIR/app/server/lib/ -MUtil -e 'print Util::encrypt_password($ARGV[0])' $PASSWD)
  echo "admin:$CRYPT" >$DATA_DIR/config/passwd
}

install_dehydrated() {
  local SCRIPT_PATH="$APP_DIR/dehydrated/bin"
  local DEHYDRATED_URL="https://raw.githubusercontent.com/dehydrated-io/dehydrated/v0.7.0/dehydrated"

  if ! [ -x "$SCRIPT_PATH/dehydrated" ]; then
    log "- Downloading dehydrated from git repo master branch ..."
    safe_curl -o $SCRIPT_PATH/dehydrated $DEHYDRATED_URL && chmod 755 $SCRIPT_PATH/dehydrated
  fi
}

init_dehydrated() {
  log "- Configuring SSL for domains: ${SSL_ZONES[@]}"

  local DOMAIN
  local WILDCARD_DOMAINS=()
  for DOMAIN in "${SSL_ZONES[@]}"
  do
    # Strip any trailing dots
    WILDCARD_DOMAINS+=("*.$(echo $DOMAIN | sed -r 's/\.+$//g')")
  done

  mkdir -p $DATA_DIR/dehydrated
  echo "${WILDCARD_DOMAINS[*]} > sslzone" >$DATA_DIR/dehydrated/domains.txt
}

init_bind9() {
  local DOMAINS=$(cat $DATA_DIR/dehydrated/domains.txt | sed -r 's/>.*$//')

  local IP=$(safe_curl ifconfig.me) # IP=$(curl -sf -m 2 -H "Metadata-flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

  log "- Generating /etc/bind/named.conf.local from /data/dehydrated/domains.txt using IP $IP ..."
  rm -f /etc/bind/named.conf.local

  local DOMAIN
  for DOMAIN in $DOMAINS
  do
    log "  - Generating /etc/bind/named.conf.local entry for zone $DOMAIN with IP $IP"

    # Strip any trailing dots and leading wildcard
    DOMAIN="$(echo $DOMAIN | sed -r 's/^\*\.//; s/\.+$//g')"

    cat >>/etc/bind/named.conf.local <<_EOE_
zone "$DOMAIN" { type master; file "/var/lib/bind/db.$DOMAIN"; update-policy local ; };
_EOE_

    rm -f /var/lib/bind/db.$DOMAIN.*
    cat >/var/lib/bind/db.$DOMAIN <<_EOE_
\$ORIGIN .
\$TTL 300       ; 5 minutes
$DOMAIN IN SOA $DOMAIN. root.$DOMAIN. (
                                528        ; serial
                                604800     ; refresh (1 week)
                                86400      ; retry (1 day)
                                2419200    ; expire (4 weeks)
                                86400      ; minimum (1 day)
                                )
                        NS      $DOMAIN.
                        A       $IP
\$ORIGIN $DOMAIN.
*                       CNAME   $DOMAIN.
_EOE_
done
}

# Following https://developers.google.com/style/code-syntax
usage() {
  cat >&2 <<_EOE_

Usage: docker run {-d|-it} [--name <name>] [-v <host-config-path>:/data] -p 443:443 -p 80:80 [-p 53:53/udp] -v /var/run/docker.sock:/var/run/docker.sock --security-opt=apparmor=unconfined newsnowlabs/dockside [OPTIONS]

  [OPTIONS]

  Generate LetsEncrypt certificate for <zone>:
    --ssl-letsencrypt --ssl-zone <zone1> [[--ssl-zone <zone2>] ...]

  Use self-supplied cert (optionally specify <zone>):
    --ssl-selfsupplied [--ssl-zone <zone>]
  
  Generate self-signed cert (optionally specify <zone>):
   --ssl-selfsigned [--ssl-zone <zone>]

  Use built-in local.dockside.dev cert:
   --ssl-builtin

  Indicate LXCFS is installed on the host and available to be mounted into devtainers:
   --lxcfs-available

  Launch 'inner' dockerd, for running devtainers:
    docker run {-d|-it} [--name <name>] [-v <host-config-path>:/data] -p 443:443 -p 80:80 [-p 53:53/udp] --runtime=sysbox-runc newsnowlabs/dockside --run-dockerd [OPTIONS]
  
  Set arbitrary config.json option, where <expression> is a jq assignment expression:
    --config-set '<expression>'

  Display this help:
    --help

_EOE_
}

log "Initialising Dockside ..." >&2

log "Parsing command line arguments: ${@@Q}"
while true
do
  case "$1" in
      --run-dockerd) shift; OPT_RUN_DOCKERD="1"; continue; ;;
         --ssl-zone) shift; OPT_SSL_ZONES+=("$1"); shift; continue; ;;
      --ssl-builtin) shift; OPT_SSL="builtin"; continue; ;;
   --ssl-selfsigned) shift; OPT_SSL="selfsigned"; continue; ;;
  --ssl-letsencrypt) shift; OPT_SSL="letsencrypt"; continue; ;;
 --ssl-selfsupplied) shift; OPT_SSL="selfsupplied"; continue; ;;
  --lxcfs-available) shift; OPT_LXCFS_AVAILABLE="1"; continue; ;;
          -h|--help) shift; usage; exit 0; ;;
    --passwd-stdout) shift; OPT_PASSWD_STDOUT="1"; continue; ;;
      --passwd-file) shift; OPT_PASSWD_FILE="$1"; shift; continue; ;;
       --config-set) shift; OPT_CONFIG_SET+=("$1"); shift; continue; ;;
                  *) break; ;;
  esac
done

# Validate commandline
if [ "$SSL" == "letsencrypt" ] && [ -z "${SSL_ZONES[0]}" ]; then
  log "- at least one --ssl-zone <zone> must be provided; aborting."
  usage
  exit 1
fi

if [ "$OPT_RUN_DOCKERD" != 1 ]; then

  log "Checking ownership/permissions of /var/run/docker.sock ..."
  if [ -S /var/run/docker.sock ]; then

    if [ "$(stat -c %G /var/run/docker.sock)" != "docker" ]; then

      log "- Group owner of /var/run/docker.sock is not 'docker', fixing ..."

      # Give access to the docker group inside the container (assumes docker.sock outside the container supports File Access Control Lists);
      # failing which, change the group.
      setfacl -m g:docker:rwx /var/run/docker.sock || chgrp docker /var/run/docker.sock
      log "- Changed or added docker group to /var/run/docker.sock."
    else
      log "- Ownership of /var/run/docker.sock is sufficient."
    fi

    # Fix MacOS Docker Desktop docker socket group permissions
    if [[ $(stat -c %A /var/run/docker.sock) =~ ^s....w ]]; then
      log "- Permissions for /var/run/docker.sock are sufficient."
    else
      log "- Adding g+rw permissions to /var/run/docker.sock."
      chmod g+rw /var/run/docker.sock
    fi

    # Test the socket, to confirm it is not stale or access-prohibited by Apparmor
    if ! safe_curl --unix-socket /var/run/docker.sock -H "Content-Type: application/json" -X GET http:/v1.41/info -o /dev/null; then
      log "- Cannot connect to bind-mounted /var/run/docker.sock: please ensure dockerd is running on host and consider adding docker run option --security-opt=apparmor=unconfined; aborting!"
      exit 3
    fi

  else

    log "- Cannot find bind-mounted /var/run/docker.sock: please bind-mount from host or relaunch using runtime supporting Docker-in-Docker and --run-dockerd; aborting!"
    usage
    exit 2
  fi
fi

if [ "$OPT_RUN_DOCKERD" != "1" ]; then
  log "Identifying container ID ..."

  CGROUP_ID=$(grep -o -P -m1 'docker.*\K[0-9a-f]{64,}' /proc/self/cgroup)

  if [ -n "$CGROUP_ID" ]; then
    # This only works with cgroup v1 OR with cgroup v2 and --cgroupns=host
    CTR_ID="$CGROUP_ID"
    log "- Identified container ID from /proc/self/cgroup as $CTR_ID"
  elif [ -f "/data/ctr-id" ]; then
    # This works when using --cidfile <host-data-mount-path>/ctr-id -v <host-data-mount-path>:/data
    CTR_ID=$(cat /data/ctr-id)
    log "- Identified container ID from /data/ctr-id as $CTR_ID"
  else
    if [[ "$HOSTNAME" =~ ^[0-9a-f]{12}$ ]]; then
      # This works when not using --network=host
      CTR_ID="$HOSTNAME"
      log "- Identified container ID from hex string hostname as $CTR_ID"
    elif [ -S /var/run/docker.sock ]; then
      # This works when using --hostname=<name> --name=<name> even when --network=host
      CTR_ID="$(docker ps -q --filter=Name=$HOSTNAME)"

      if [ -n "$CTR_ID" ]; then
        log "- Identified container ID from non-hex-string hostname '$HOSTNAME' as $CTR_ID"
      else
        log "- Failed to identify container ID from non-hex-string hostname '$HOSTNAME'; aborting!"
        exit 1
      fi
    else
      log "- Failed to identify container ID from non-hex-string hostname '$HOSTNAME' without 'docker ps'; aborting!"
      exit 1
    fi
  fi

  if [ -z "$CTR_ID" ]; then
    log "Can't launch without having identified container ID; aborting!"
    exit 2
  fi
fi

log "Configuring standard services ..."
for s in bind nginx docker-event-daemon logrotate dehydrated
do
  log "- Configuring $s"
  mkdir -p /etc/service/$s /etc/service/$s/data

  # CTR_ID and /data/ctr-id
  # - Store the Dockside container's hostname, when it is running in a container.
  #   This is mostly used to identify the IDE volume.
  #
  # INNER_DOCKERD and /data/inner-dockerd
  # - Set to 1/true when --run-dockerd is used.
  #   Whether Dockside is running in a container or not, devtainers will be launched
  #   using the inner dockerd and the IDE path will be bind mounted.
  #   CTR_ID/ctr-id will not be used.
  #
  cat >/etc/service/$s/data/env <<_EOE_
DATA_DIR=/data
USER=${USER:-dockside}
APP=${APP:-dockside}
APP_HOME=${APP_HOME:-/home/newsnow}
APP_DIR=$APP_HOME/$APP
CTR_ID=${CTR_ID:0:12}
INNER_DOCKERD="$OPT_RUN_DOCKERD"
_EOE_

  echo "${CTR_ID:0:12}" >/etc/service/$s/data/ctr-id
  [ "$OPT_RUN_DOCKERD" == "1" ] && echo 'true' >/etc/service/$s/data/inner-dockerd

  # Create symlink for runscript
  ln -sf $APP_DIR/app/scripts/runscripts/$s/run /etc/service/$s/run

  # Copy each immediate child of $APP_DIR/app/scripts/runscripts/$s/data
  # N.B. We can't symlink $APP_DIR/app/scripts/runscripts/logrotate/data because
  #.     for logrotate to run, these files must be root-owned.
  if [ -d "$APP_DIR/app/scripts/runscripts/$s/data" ]; then
    cp -a $APP_DIR/app/scripts/runscripts/$s/data/* /etc/service/$s/data/
    chown -R root.root /etc/service/$s/data/
  fi
done

# Disable bind9 and dehydrated by default (they will be enabled if the ssl source == letsencrypt)
touch /etc/service/bind/down /etc/service/dehydrated/down

# Enable dockerd if needed
if [ "$OPT_RUN_DOCKERD" == "1" ]; then
  log "- Configuring dockerd"
  mkdir -p /etc/service/dockerd
  ln -sf $APP_DIR/app/scripts/runscripts/dockerd/run /etc/service/dockerd/run
fi

# Create log directory
log "Creating /var/log/$APP log directory ..."
mkdir -p /var/log/$APP && chown -R $USER.$USER /var/log/$APP

log "Testing if shared IDE volume '$OPT_PATH' is writeable ..."
if (>$OPT_PATH/.writeable && rm -f $OPT_PATH/.writeable) 2>/dev/null; then
  log "- Shared IDE volume is writeable ..."
else
  log "- Shared IDE volume is not writeable."
fi

log "Testing if shared host data volume '$OPT_PATH/host' is writeable ..."
if (>$OPT_PATH/host/.writeable && rm -f $OPT_PATH/host/.writeable) 2>/dev/null; then
  log "- Shared host data volume is writeable ..."

   if ! [ -f $OPT_PATH/host/ed25519_host_key ]; then
      log "- No host key '$OPT_PATH/host/ed25519_host_key' found; creating it ..."
      ide_cmd dropbearkey -t ed25519 -f $OPT_PATH/host/ed25519_host_key
   fi
else
  log "- Shared host data volume is not writeable."

   if ! [ -f $OPT_PATH/host/ed25519_host_key ]; then
      log "- No host key '$OPT_PATH/host/ed25519_host_key' found in unwriteable host data directory; mount must be read-write or else host key must pre-exist; exiting ..."
      exit 1
   fi
fi

log "Initialising /data, as needed ..."
if ! [ -d $DATA_DIR/cache ]; then
  log "- No cache directory found, creating it ..."
  mkdir -p $DATA_DIR/cache
fi

if ! [ -d $DATA_DIR/db ]; then
  log "- No db (database) directory found, creating it ..."
  mkdir -p $DATA_DIR/db
fi

if ! [ -d $DATA_DIR/certs ]; then
  log "- No certs directory found, creating it ..."
  mkdir -p $DATA_DIR/certs
fi

if ! [ -d $DATA_DIR/config ]; then
  log "- No $DATA_DIR/config directory found, so installing vanilla config, users, roles and profiles ..."
  cp -a $APP_DIR/app/server/example/config $DATA_DIR/
  
  init_config
  init_admin_credentials
fi

if ! [ -f $DATA_DIR/config/config.json ]; then
  log "- No $DATA_DIR/config/config.json, so installing vanilla config ..."
  cp -a $APP_DIR/app/server/example/config/config.json $DATA_DIR/config/
  
  init_config
fi

if [ ${#OPT_CONFIG_SET[@]} -gt 0 ]; then
  log_push "Setting config.json options ..."
  for opt in "${OPT_CONFIG_SET[@]}"
  do
    log "- Setting config.json '$opt'"
    jq_config_set "$opt"
  done
  log_pop
fi

if [ "$OPT_LXCFS_AVAILABLE" == "1" ]; then
  jq_config_set '.lxcfs.available = true'
fi

if ! [ -f $DATA_DIR/config/users.json ]; then
  log "- No $DATA_DIR/config/users.json so installing vanilla users.json ..."
  cp -a $APP_DIR/app/server/example/config/users.json $DATA_DIR/config/
fi

if ! [ -f $DATA_DIR/config/roles.json ]; then
  log "- No $DATA_DIR/config/roles.json so installing vanilla roles.json ..."
  cp -a $APP_DIR/app/server/example/config/roles.json $DATA_DIR/config/
fi

if ! [ -f $DATA_DIR/config/passwd ]; then
  log "- No $DATA_DIR/config/passwd so installing vanilla passwd ..."
  cp -a $APP_DIR/app/server/example/config/passwd $DATA_DIR/config/
  
  init_admin_credentials
fi

if ! [ -d $DATA_DIR/config/profiles ]; then
  log "- No $DATA_DIR/config/profiles directory found, so installing vanilla profiles ..."
  cp -a $APP_DIR/app/server/example/config/profiles $DATA_DIR/config/
fi

log "Checking SSL certificates ..."
CONFIG_SSL=$(jq_config_get -r '.ssl.source')
CONFIG_SSL_ZONES=($(jq_config_get -r '.ssl.domains[]'))

# SSL Setup Step 1:
# Assign SSL according to --ssl-* option, or config.json setting, and abort if invalid
#
if [ "$OPT_SSL" == "builtin" ] || [ "$OPT_SSL" == "selfsigned" ] || [ "$OPT_SSL" == "letsencrypt" ] || [ "$OPT_SSL" == "selfsupplied" ]; then
  SSL="$OPT_SSL"
elif [ -n "$OPT_SSL" ]; then
  log "Unexpected --ssl-$OPT_SSL option; aborting!"
  exit 1
else
  if [ "$CONFIG_SSL" == "builtin" ] || [ "$CONFIG_SSL" == "selfsigned" ] || [ "$CONFIG_SSL" == "letsencrypt" ] || [ "$CONFIG_SSL" == "selfsupplied" ]; then
    SSL="$CONFIG_SSL"
  else
    log "- one of --ssl-builtin, --ssl-selfsigned, --ssl-letsencrypt, --ssl-own must be provided; aborting!"
    usage
    exit 1
  fi
fi

# SSL Setup Step 2:
# Assign SSL_ZONES according to SSL, and abort if invalid
#
if [ "$SSL" == "builtin" ]; then
  SSL_ZONES=("local.dockside.dev")

elif [ "$SSL" == "selfsigned" ]; then
  if [ -n "${OPT_SSL_ZONES[0]}" ]; then
    SSL_ZONES=("${OPT_SSL_ZONES[@]}")
  elif [ -n "${CONFIG_SSL_ZONES[0]}" ]; then
    SSL_ZONES=("${CONFIG_SSL_ZONES[@]}")
  else
    SSL_ZONES=("selfsigned.dockside.cloud")
  fi

elif [ "$SSL" == "letsencrypt" ]; then
  if [ -n "${OPT_SSL_ZONES[0]}" ]; then
    SSL_ZONES=("${OPT_SSL_ZONES[@]}")
  elif [ -n "${CONFIG_SSL_ZONES[0]}" ]; then
    SSL_ZONES=("${CONFIG_SSL_ZONES[@]}")
  else
    log "- at least one --ssl-zone <zone> option must be provided; aborting!"
    usage
    exit 1
  fi

elif [ "$SSL" == "selfsupplied" ]; then
  # --ssl-zone <zone> doesn't do anything with --ssl-own, except display the correct
  # URL to navigate to in the browser.

  if [ -n "${OPT_SSL_ZONES[0]}" ]; then
    SSL_ZONES=("${OPT_SSL_ZONES[@]}")
  elif [ -n "${CONFIG_SSL_ZONES[0]}" ]; then
    SSL_ZONES=("${CONFIG_SSL_ZONES[@]}")
  fi

fi

# SSL Setup Step 3:
# If valid command-line --ssl-* options found, update their values in config.json.
# N.B. We check SSL_ZONES not OPT_SSL_ZONES since by now the former will have been
# set to CONFIG_SSL_ZONES or OPT_SSL_ZONES and we only require one of these.
#
if [ "$SSL" != "$CONFIG_SSL" ] || [ "${SSL_ZONES[*]}" != "${CONFIG_SSL_ZONES[*]}" ]; then
  jq_config_set '.ssl.source = $source | .ssl.domains = ($domains|split(" "))' --arg source "$SSL" --arg domains "${SSL_ZONES[*]}"
fi

# SSL Setup Step 4:
# Process the SSL and SSL_ZONES options, setting up certificates as required, aborting on setup errors.
#
if [ "$SSL" == "builtin" ]; then
  log "- Downloading certificates for ${SSL_ZONES[0]} ..."

  if safe_curl -o $DATA_DIR/certs/fullchain.pem https://storage.googleapis.com/dockside/certs/local.dockside.dev/fullchain.pem && \
     safe_curl -o $DATA_DIR/certs/privkey.pem https://storage.googleapis.com/dockside/certs/local.dockside.dev/privkey.pem && \
     [ -f $DATA_DIR/certs/fullchain.pem ] && [ -f $DATA_DIR/certs/privkey.pem ]; then
    log "  - Certificates installed for ${SSL_ZONES[0]}"
  else
    log "  - Certificates failed to download; please try again or relaunch with --ssl-selfsigned or --ssl-letsencrypt; aborting!"
    exit 1
  fi

elif [ "$SSL" == "letsencrypt" ]; then
  log "- Initialising Dehydrated for LetsEncrypt for zones ${SSL_ZONES[*]}"
  install_dehydrated
  init_dehydrated
  init_bind9

  # Enable bind9 and dehydrated
  rm -f /etc/service/bind/down /etc/service/dehydrated/down

elif [ "$SSL" == "selfsigned" ]; then
  if [[
    ("$CONFIG_SSL" != "selfsigned" || "${SSL_ZONES[*]}" != "${CONFIG_SSL_ZONES[*]}") ||
    (! -f $DATA_DIR/certs/fullchain.pem) || (! -f $DATA_DIR/certs/privkey.pem)
  ]]; then
    CERT_KEYSIZE=4096
    CERT_COUNTRYNAME=GB
    CERT_STATE=England
    CERT_ORGANISATION='Dockside'
    CERT_DOMAIN="${SSL_ZONES[0]}"

    log "- Generating self-signed ${CERT_KEYSIZE}-bit certificate for ${SSL_ZONES[0]} ..."

    # See: https://eengstrom.github.io/musings/self-signed-tls-certs-v.-chrome-on-macos-catalina
    log_do -x -v --silent openssl req \
      -new \
      -x509 \
      -nodes \
      -days 365 \
      -newkey rsa:$CERT_KEYSIZE \
      -sha256 \
      -subj "/C=$CERT_COUNTRYNAME/ST=$CERT_STATE/L=City/O=$CERT_ORGANISATION/CN=$CERT_DOMAIN" \
      -addext "subjectAltName = DNS:$CERT_DOMAIN" \
      -addext "extendedKeyUsage = serverAuth" \
      -keyout $DATA_DIR/certs/privkey.pem -out $DATA_DIR/certs/fullchain.pem
  else
    log "- Using pre-existing (assumed) self-signed certificate"
  fi

elif [ "$SSL" == "selfsupplied" ]; then
  if [[ (-f $DATA_DIR/certs/fullchain.pem) && (-f $DATA_DIR/certs/privkey.pem) ]]; then
    log "- Using own self-supplied certificate"
  else
    log "- Self-supplied certificate files fullchain.pem and/or privkey.pem not found; aborting!"
    exit 1
  fi
fi

log "Fixing ownership for data/db, data/cache, data/certs, data/config ..."
chown -R $USER $DATA_DIR

log "Adding extensions.json ..."
[ -d "$APP_HOME/.vscode" ] || mkdir -p $APP_HOME/.vscode && chown -R $USER.$USER $APP_HOME/.vscode
[ -f "$APP_HOME/.vscode/extensions.json" ] || cp -a $APP_DIR/build/development/extensions.json $APP_HOME/.vscode/

log "Launching s6 service supervisor ..."
mkdir -p /etc/service/.s6-svscan && cat >/etc/service/.s6-svscan/finish <<_EOE_ && chmod 755 /etc/service/.s6-svscan/finish
#!/bin/sh

exit 0
_EOE_

log ">>> If running in a terminal, detach Dockside by typing: CTRL+P CTRL+Q"
log ">>> Navigate to https://www.${SSL_ZONES[0]}/"
# log "    - or, if running Dockside within Dockside, https://www-${SSL_ZONES[0]}/"

if [ -n "$PASSWD" ]; then
  log ">>> Sign in with username 'admin' and password '$PASSWD'"

  if [ -n "$OPT_PASSWD_STDOUT" ]; then
    echo "admin:$PASSWD"
  fi

  if [ -n "$OPT_PASSWD_FILE" ]; then
    echo "admin:$PASSWD" >$OPT_PASSWD_FILE
  fi

  unset PASSWD
fi

exec </dev/null
exec /usr/bin/s6-svscan /etc/service
