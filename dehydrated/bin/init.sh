#!/bin/bash

SCRIPT_PATH=$(dirname $(realpath $0))

# Launch and configure log_do
. $SCRIPT_PATH/log_do-20180301

# Accept list of domains
DOMAINS="$@"

log "Downloading master branch dehydrated ..."

log_do -x -v curl -o $SCRIPT_PATH/dehydrated https://raw.githubusercontent.com/dehydrated-io/dehydrated/master/dehydrated && log_do -x -v chmod 755 $SCRIPT_PATH/dehydrated

log "Configuring SSL for domains: $DOMAINS"

IP=$(curl -sf -m 2 -H "Metadata-flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

if [ -z "$IP" ]; then
  IP=$(curl -sf -m 2 ifconfig.me)
fi

log "Detected public IP: $IP"

log_do -x -v --silent rm -f /etc/bind/named.conf.local

for DOMAIN in $DOMAINS
do

  # Strip any trailing dots
  DOMAIN="$(echo $DOMAIN | sed -r 's/\.+$//g')"
  WILDCARD_DOMAINS+="*.$DOMAIN "

  cat >>/etc/bind/named.conf.local <<_EOE_
zone "$DOMAIN" { type master; file "/var/lib/bind/db.$DOMAIN"; update-policy local ; };
_EOE_

  rm -f /var/lib/bind/db.$DOMAIN.*
  cat >/var/lib/bind/db.$DOMAIN <<_EOE_
\$ORIGIN .
\$TTL 3600       ; 1 hour
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

# Configure dehydrated
echo "$WILDCARD_DOMAINS > sslzone" >$SCRIPT_PATH/domains.txt

# Launch bind
rm -f /etc/service/bind/down
/usr/bin/s6-svc -u /etc/service/bind

log_do -x -v --silent $SCRIPT_PATH/dehydrated --register --accept-terms

log_do -x -v --silent $SCRIPT_PATH/dehydrated -t dns-01 --cron --hook $SCRIPT_PATH/hook.sh
