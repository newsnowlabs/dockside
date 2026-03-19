#!/bin/bash

set -e

# Set to 1 to enable debug output
DEBUG=0

# Global registry: ipset_name -> space-separated list of hostnames
declare -A IPSET_HOSTS

iptables() {
  [ "$DEBUG" = "1" ] && echo iptables "$@" >&2
  $(which iptables) "$@"
}

net_to_chn() {
  local net="$1"
  echo "DOCKSIDE-$net" | sed 's/.*/\U&/'
}

net_to_dev() {
  local net="$1"
  case "$net" in
    *) echo "$net" | sed 's/.*/\L&/'; ;;
  esac
}

net_to_dnet() {
  local net="$1"
  case "$net" in
    *) echo "$net" | sed 's/.*/\L&/'; ;;
  esac
}

create_docker_network() {
  local net="$1"
  local subnet="$2"

  local dev="$(net_to_dev $net)"
  local dnet="$(net_to_dnet $net)"
  local gateway="$(echo $subnet | sed -r 's!^(.*)\.0/.*!\1.1!')"

  if docker network ls --format='{{.Name}}' | grep -q "^$dnet$"; then
    if [ -n "$RESET" ]; then
      docker network rm "$dnet"
    else
      return 0
    fi
  fi

  docker network create \
    --subnet="$subnet" \
    --gateway="$gateway" \
    --opt="com.docker.network.bridge.name=$dev" \
    --opt='com.docker.network.bridge.enable_icc=true' \
    --opt='com.docker.network.bridge.enable_ip_masquerade=true' \
    --opt='com.docker.network.driver.mtu=1500' \
    --opt='com.docker.network.bridge.host_binding_ipv4=0.0.0.0' \
    "$dnet"
}

delete_iptables_chains() {
  local net="$1"
  local dev="$(net_to_dev $net)"
  local chn="$(net_to_chn $net)"

  iptables -D DOCKER-USER -i $dev -o $dev -j $chn-ING 2>/dev/null || true
  iptables -D DOCKER-USER -i $dev ! -o $dev -j $chn-OUT 2>/dev/null || true

  iptables -F $chn-ING 2>/dev/null || true
  iptables -X $chn-ING 2>/dev/null || true
  iptables -F $chn-OUT 2>/dev/null || true
  iptables -X $chn-OUT 2>/dev/null || true

  iptables -t nat -D PREROUTING -j $chn-NAT 2>/dev/null || true
  iptables -t nat -F $chn-NAT 2>/dev/null || true
  iptables -t nat -X $chn-NAT 2>/dev/null || true
}

create_iptables_chains() {
  local net="$1"
  local dev="$(net_to_dev $net)"
  local chn="$(net_to_chn $net)"

  echo "Creating chains for '$net': $chn-OUT, $chn-ING, $chn-NAT"

  iptables -N $chn-ING
  iptables -N $chn-OUT
  iptables -t nat -N $chn-NAT
}

init_iptables_chains() {
  local net="$1"
  local dev="$(net_to_dev $net)"
  local chn="$(net_to_chn $net)"
  local subnet="$2"
  local gateway_ip="$3"
  local gateway_mac="$4"

  if [ -z "$gateway_mac" ] && [ -z "$gateway_ip" ]; then
    echo "Error: No gateway MAC or IP specified for network '$net'." >&2
    exit 1
  fi

  iptables -A DOCKER-USER -i $dev -o $dev -j $chn-ING || true

  [ -n "$gateway_mac" ] && iptables -A $chn-ING -m mac --mac-source $gateway_mac -p tcp -m conntrack --ctstate NEW -j RETURN
  [ -n "$gateway_ip" ]  && iptables -A $chn-ING -s $gateway_ip -p tcp -m conntrack --ctstate NEW -j RETURN

  iptables -A $chn-ING -m conntrack --ctstate NEW -j DROP

  if [ -n "$gateway_mac" ] && [ -n "$gateway_ip" ]; then
    iptables -A DOCKER-USER -i $dev ! -o $dev -m mac ! --mac-source $gateway_mac ! -s $gateway_ip -j $chn-OUT
  elif [ -n "$gateway_mac" ]; then
    iptables -A DOCKER-USER -i $dev ! -o $dev -m mac ! --mac-source $gateway_mac -j $chn-OUT
  elif [ -n "$gateway_ip" ]; then
    iptables -A DOCKER-USER -i $dev ! -o $dev ! -s $gateway_ip -j $chn-OUT
  fi

  iptables -t nat -A PREROUTING -j $chn-NAT
}

drop() {
  local net="$1"
  local chn="$(net_to_chn $net)"
  local ip="$2"

  if [ -n "$ip" ]; then
    iptables -A $chn-OUT -d "$ip" -p tcp -m conntrack --ctstate NEW -j REJECT --reject-with tcp-reset
    iptables -A $chn-OUT -d "$ip" -j DROP
  else
    iptables -A $chn-OUT -p tcp -m conntrack --ctstate NEW -j REJECT --reject-with tcp-reset
    iptables -A $chn-OUT -m conntrack --ctstate NEW -j DROP
  fi
}

udp_to_all() {
  local net="$1"
  local chn="$(net_to_chn $net)"
  local ports="$2"

  iptables -A $chn-OUT -p udp -m multiport --dports "$ports" -m conntrack --ctstate NEW -j RETURN
}

tcp_to_all() {
  local net="$1"
  local chn="$(net_to_chn $net)"
  local ports="$2"

  iptables -A $chn-OUT -p tcp -m multiport --dports "$ports" -m conntrack --ctstate NEW -j RETURN
}

tcp() {
  local net="$1"
  local chn="$(net_to_chn $net)"
  local ip="$2"
  local ports="$3"

  iptables -A $chn-OUT -p tcp -d "$ip" -m multiport --dports "$ports" -m conntrack --ctstate NEW -j RETURN
}

icmp() {
  local net="$1"
  local chn="$(net_to_chn $net)"

  iptables -A $chn-OUT -p icmp --icmp-type echo-request -m conntrack --ctstate NEW -j RETURN
}

# ---------------------------------------------------------------------------
# ipset management
# ---------------------------------------------------------------------------

# Sanitise a string to a valid ipset name (max 31 chars, alphanum + hyphen)
_ipset_name() {
  echo "$1" | sed 's/[^a-zA-Z0-9]/-/g' | cut -c1-31
}

# create_ipset <setname> <host> [<host> ...]
#
# Creates the ipset if it doesn't exist, registers the hostnames for
# future refresh cycles, and does an initial population.
create_ipset() {
  local setname="$(_ipset_name "$1")"
  shift
  local hosts="$*"

  # Register for daemon refresh loop
  IPSET_HOSTS["$setname"]="$hosts"

  # Create the set if absent; leave existing entries in place on re-run
  if ! ipset list "$setname" &>/dev/null; then
    ipset create "$setname" hash:ip
  fi

  # Initial population
  _refresh_ipset "$setname"
}

# tcp_to_ipset <net> <setname> <ports>
#
# Allow NEW TCP connections from the network whose destination IP is in
# the named ipset, on the given ports.
tcp_to_ipset() {
  local net="$1"
  local chn="$(net_to_chn $net)"
  local setname="$(_ipset_name "$2")"
  local ports="$3"

  iptables -A $chn-OUT \
    -p tcp \
    -m set --match-set "$setname" dst \
    -m multiport --dports "$ports" \
    -m conntrack --ctstate NEW \
    -j RETURN
}

# udp_to_ipset <net> <setname> <ports>
udp_to_ipset() {
  local net="$1"
  local chn="$(net_to_chn $net)"
  local setname="$(_ipset_name "$2")"
  local ports="$2"

  iptables -A $chn-OUT \
    -p udp \
    -m set --match-set "$setname" dst \
    -m multiport --dports "$ports" \
    -m conntrack --ctstate NEW \
    -j RETURN
}

# ---------------------------------------------------------------------------
# DNS resolution and ipset refresh
# ---------------------------------------------------------------------------

# Resolve all hostnames for a given ipset into a temporary set, then
# atomically swap it into place.
#
# Staleness model:
#   - A temporary set is built from a fresh DNS resolution.
#   - The live set is updated by ADDING any IPs in the new set not already
#     present, and REMOVING IPs that were in the old set but absent from
#     the new set AND have not been seen in the last IPSET_STALE_TTL seconds.
#   - The stale-TTL grace period prevents a briefly-flapping CDN IP from
#     being removed and dropping in-flight connections. Default: 300s (5 min).
#   - IPs are timestamped in a companion hash:ip,timeout set that records
#     last-seen time; entries that expire from that set are eligible for
#     removal from the live set.
#
IPSET_STALE_TTL=${IPSET_STALE_TTL:-300}

_refresh_ipset() {
  local setname="$1"
  local hosts="${IPSET_HOSTS[$setname]}"
  local seen_set="${setname}--seen"
  local tmp_set="${setname}--tmp"

  if [ -z "$hosts" ]; then
    echo "Warning: no hosts registered for ipset '$setname'" >&2
    return
  fi

  # Ensure the seen-timestamp set exists (hash:ip with per-entry timeout)
  if ! ipset list "$seen_set" &>/dev/null; then
    ipset create "$seen_set" hash:ip timeout "$IPSET_STALE_TTL"
  fi

  # Resolve all hostnames into a temporary plain set
  ipset destroy "$tmp_set" 2>/dev/null || true
  ipset create  "$tmp_set" hash:ip

  local host resolved_any
  for host in $hosts; do
    local ips
    ips=$(getent hosts "$host" | awk '{print $1}')
    if [ -z "$ips" ]; then
      echo "Warning: could not resolve '$host' for ipset '$setname'" >&2
      continue
    fi
    resolved_any=1
    local ip
    for ip in $ips; do
      ipset add "$tmp_set" "$ip" 2>/dev/null || true
    done
  done

  if [ -z "$resolved_any" ]; then
    echo "Error: no hostnames resolved for ipset '$setname' — leaving live set unchanged" >&2
    ipset destroy "$tmp_set"
    return
  fi

  # Add any newly-resolved IPs to the live set and refresh their seen timestamp
  ipset list "$tmp_set" | grep -E '^[0-9]' | while read -r ip; do
    ipset add "$setname"  "$ip" 2>/dev/null || true   # no-op if already present
    ipset add "$seen_set" "$ip" timeout "$IPSET_STALE_TTL" 2>/dev/null || \
    ipset update-timeout "$seen_set" "$ip" timeout "$IPSET_STALE_TTL" 2>/dev/null || true
  done

  # Remove IPs that are in the live set but absent from both the new
  # resolution and the seen-timestamp set (i.e. not seen recently)
  ipset list "$setname" | grep -E '^[0-9]' | while read -r ip; do
    local in_tmp in_seen
    ipset test "$tmp_set"  "$ip" 2>/dev/null && in_tmp=1  || in_tmp=0
    ipset test "$seen_set" "$ip" 2>/dev/null && in_seen=1 || in_seen=0

    if [ "$in_tmp" = "0" ] && [ "$in_seen" = "0" ]; then
      echo "Removing stale IP $ip from ipset '$setname'" >&2
      ipset del "$setname" "$ip" 2>/dev/null || true
    fi
  done

  ipset destroy "$tmp_set"
}

# Refresh all registered ipsets
refresh_all_ipsets() {
  local setname
  for setname in "${!IPSET_HOSTS[@]}"; do
    echo "Refreshing ipset '$setname' (hosts: ${IPSET_HOSTS[$setname]})" >&2
    _refresh_ipset "$setname"
  done
}

# ---------------------------------------------------------------------------
# Higher-level helpers (unchanged API)
# ---------------------------------------------------------------------------

reroute_mysql() {
  local net="$1"
  local dev="$(net_to_dev $net)"
  local chn="$(net_to_chn $net)"
  local DST_HOST="$2"
  local DST_PORT="$3"
  local DST_IP=$(getent hosts $DST_HOST | awk '{ print $1 }')

  iptables -t nat -A $chn-NAT -i $dev -p tcp -m tcp --dport 3306 -j DNAT --to-destination $DST_IP:$DST_PORT
  tcp "$net" "$DST_HOST" "$DST_PORT"
}

dns_and_http() {
  local net="$1"

  udp_to_all "$net" 53
  tcp_to_all "$net" 53,80,443
}

ssh_to_github() {
  local net="$1"

  tcp "$net" 140.82.121.3 22
  tcp "$net" 140.82.121.4 22
  tcp "$net" 20.26.156.215 22
}

create_network() {
  local net="$1"
  local subnet="$2"
  local gateway_ip="$3"
  local gateway_mac="$4"

  create_docker_network "$net" "$subnet"
  delete_iptables_chains "$net"
  create_iptables_chains "$net" "$subnet"

  if [ "$net" != "dockside" ]; then
    init_iptables_chains "$net" "$subnet" "$gateway_ip" "$gateway_mac"
  fi
}

# ---------------------------------------------------------------------------
# Setup: networks and firewall rules
# ---------------------------------------------------------------------------

setup() {
  sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=8192

  iptables -F DOCKER-USER

  # Dockside network
  create_network "dockside" "172.15.0.0/16"

  # ds-prod
  create_network "ds-prod" "172.16.0.0/16" "172.16.0.2" "02:00:00:00:00:01"
  dns_and_http "ds-prod"
  ssh_to_github "ds-prod"
  tcp_to_all "ds-prod" 25
  tcp "ds-prod" "192.168.0.0/16" 3306
  icmp "ds-prod"
  drop "ds-prod"

  # ds-clone
  create_network "ds-clone" "172.17.0.0/16" "172.17.0.2" "02:00:00:00:00:01"
  dns_and_http "ds-clone"
  ssh_to_github "ds-clone"
  tcp_to_all "ds-clone" 25
  reroute_mysql "ds-clone" "pascal.dc.lan" 13306
  icmp "ds-clone"
  drop "ds-clone"

  # ds-priv
  create_network "ds-priv" "172.18.0.0/16" "172.18.0.2" "02:00:00:00:00:01"
  drop "ds-priv" "192.168.0.0/16"
  dns_and_http "ds-priv"
  ssh_to_github "ds-priv"
  icmp "ds-priv"
  drop "ds-priv"

  # ds-claude: Anthropic API + npm + GitHub only
  create_ipset "claude-allowlist" \
    api.anthropic.com \
    statsig.anthropic.com \
    statsig.ugc.statsigapi.net \
    sentry.io \
    registry.npmjs.org \
    github.com \
    api.github.com

  create_network "ds-claude" "172.19.0.0/16" "172.19.0.2" "02:00:00:00:00:01"
  udp_to_all     "ds-claude" 53
  tcp_to_all     "ds-claude" 53
  tcp_to_ipset   "ds-claude" "claude-allowlist" 443
  tcp_to_ipset   "ds-claude" "claude-allowlist" 22
  icmp           "ds-claude"
  drop           "ds-claude"
}

# ---------------------------------------------------------------------------
# Daemon mode
# ---------------------------------------------------------------------------

daemon() {
  echo "Daemon mode: refreshing ipsets every ${IPSET_REFRESH_INTERVAL:-60}s" >&2

  local interval="${IPSET_REFRESH_INTERVAL:-60}"

  while true; do
    sleep "$interval"
    echo "$(date -Iseconds) Refreshing ipsets..." >&2
    refresh_all_ipsets
  done
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

case "${1:-}" in
  --daemon)
    # Run setup then enter the refresh loop.
    # IPSET_HOSTS must be populated by setup() before daemon() is called,
    # and both run in the same process so the associative array is shared.
    setup
    daemon
    ;;
  --refresh)
    # One-shot refresh of all ipsets without re-running full setup.
    # Useful for testing or manual intervention.
    setup   # repopulates IPSET_HOSTS without recreating chains (idempotent)
    refresh_all_ipsets
    ;;
  "")
    setup
    ;;
  *)
    echo "Usage: $0 [--daemon|--refresh]" >&2
    exit 1
    ;;
esac