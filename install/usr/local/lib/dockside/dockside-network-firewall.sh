#!/bin/bash

set -e

# Set to 1 to enable debug output
DEBUG=0

iptables() {
  [ "$DEBUG" = "1" ] && echo iptables "$@" >&2
  $(which iptables) "$@"
}

net_to_chn() {
  local net="$1"
  echo "DOCKSIDE-$net" | sed 's/.*/\U&/' # iptables chain suffix e.g. LTD
}

# Converts internal netname to network device name
net_to_dev() {
  local net="$1"
  
  case "$net" in
    *) echo "$net" | sed 's/.*/\L&/'; ;;
  esac
}

# Converts internal netname to Docker network name
net_to_dnet() {
  local net="$1"

  case "$net" in
    *) echo "$net" | sed 's/.*/\L&/'; ;;
  esac
}

# The network used is persistent, so shouldn't need to be recreated.
create_docker_network() {
  local net="$1" # LTD
  local subnet="$2" # 172.18.0.0/16

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
  
  docker network create --subnet="$subnet" --gateway="$gateway" --opt="com.docker.network.bridge.name=$dev" --opt='com.docker.network.bridge.enable_icc=true' --opt='com.docker.network.bridge.enable_ip_masquerade=true' --opt='com.docker.network.driver.mtu=1500' --opt='com.docker.network.bridge.host_binding_ipv4=0.0.0.0' "$dnet"
}

delete_iptables_chains() {
  local net="$1"
  local dev="$(net_to_dev $net)"
  local chn="$(net_to_chn $net)"

  iptables -D DOCKER-USER -i $dev -o $dev -j $chn-ING 2>/dev/null || true
  iptables -D DOCKER-USER -i $dev ! -o $dev -j $chn-OUT 2>/dev/null || true
  
  iptables -F $chn-ING || true
  iptables -X $chn-ING || true
  iptables -F $chn-OUT || true
  iptables -X $chn-OUT || true
  
  iptables -t nat -D PREROUTING -j $chn-NAT 2>/dev/null || true
  iptables -t nat -F $chn-NAT || true
  iptables -t nat -X $chn-NAT || true
}

create_iptables_chains() {
  local net="$1"
  local dev="$(net_to_dev $net)"
  local chn="$(net_to_chn $net)"
  local subnet="$2"

  echo "Creating chains for '$net': $chn-OUT, $chn-ING, $chn-NAT"

  # Create chains
  iptables -N $chn-ING # Ingress
  iptables -N $chn-OUT # Egress filter
  iptables -t nat -N $chn-NAT # Egress NAT
}

init_iptables_chains() {
  local net="$1"
  local dev="$(net_to_dev $net)"
  local chn="$(net_to_chn $net)"
  local subnet="$2"
  local gateway_ip="$3"
  local gateway_mac="$4"

  if [ -z "$gateway_mac" ] && [ -z "$gateway_ip" ]; then
    echo "Error: No gateway MAC or IP specified for network '$net'. You must provide at least one." >&2
    exit 1
  fi

  # --- Intra-network traffic (Dockside<->Devtainer reverse proxying) ---
  iptables -A DOCKER-USER -i $dev -o $dev -j $chn-ING || true

  # Allow NEW connections from Dockside's MAC to a devtainer on any port
  [ -n "$gateway_mac" ] && iptables -A $chn-ING -m mac --mac-source $gateway_mac -p tcp -m conntrack --ctstate NEW -j RETURN
  # Allow NEW connections from Dockside's IP to a devtainer on any port
  [ -n "$gateway_ip" ] && iptables -A $chn-ING -s $gateway_ip -p tcp -m conntrack --ctstate NEW -j RETURN

  # Drop any other NEW intra-network traffic
  iptables -A $chn-ING -m conntrack --ctstate NEW -j DROP

  # --- Egress traffic filter rules ---
  # Apply these rules only to traffic originating from devtainer containers (and not the Dockside container itself)
  if [ -n "$gateway_mac" ] && [ -n "$gateway_ip" ]; then
    iptables -A DOCKER-USER -i $dev ! -o $dev -m mac ! --mac-source $gateway_mac ! -s $gateway_ip -j $chn-OUT
  elif [ -n "$gateway_mac" ]; then
    iptables -A DOCKER-USER -i $dev ! -o $dev -m mac ! --mac-source $gateway_mac -j $chn-OUT
  elif [ -n "$gateway_ip" ]; then
    iptables -A DOCKER-USER -i $dev ! -o $dev ! -s $gateway_ip -j $chn-OUT
  fi

  # --- Egress traffic NAT rules ---
  iptables -t nat -A PREROUTING -j $chn-NAT
}

drop() {
  local net="$1"
  local chn="$(net_to_chn $net)"
  local ip="$2"

  if [ -n "$ip" ]; then
    # Drop traffic to specific IP or subnet: reject TCP new connections with tcp-reset, drop everything else
    iptables -A $chn-OUT -d "$ip" -p tcp -m conntrack --ctstate NEW -j REJECT --reject-with tcp-reset
    iptables -A $chn-OUT -d "$ip" -j DROP
  else
    # Drop all traffic: reject TCP new connections with tcp-reset
    # drop initial packets of other protocols (but allow established connections to continue)
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

  iptables -A $chn-OUT -p tcp -m tcp -m multiport --dports "$ports" -m conntrack --ctstate NEW -j RETURN
}

tcp() {
  local net="$1"
  local chn="$(net_to_chn $net)"
  local ip="$2"
  local ports="$3"

  iptables -A $chn-OUT -p tcp -m tcp -d "$ip" -m multiport --dports "$ports" -m conntrack --ctstate NEW -j RETURN
}

icmp() {
  local net="$1"
  local chn="$(net_to_chn $net)"

  # Allow ICMP echo-request (ping) out
  iptables -A $chn-OUT -p icmp --icmp-type echo-request -m conntrack --ctstate NEW -j RETURN
}

# Reroute MySQL traffic to a specific host:port
reroute_mysql() {
  local net="$1"
  local dev="$(net_to_dev $net)"
  local chn="$(net_to_chn $net)"

  local DST_HOST="$2"
  local DST_PORT="$3"
  local DST_IP=$(getent hosts $DST_HOST | awk '{ print $1 }')
  
  iptables -t nat -A $chn-NAT -i $dev -p tcp -m tcp --dport 3306 -j DNAT --to-destination $DST_IP:$DST_PORT

  # Allow TCP access to host:port
  tcp "$net" "$DST_HOST" "$DST_PORT"
}

dns_and_http() {
  local net="$1"

  # Allow DNS, HTTP, HTTPS out
  udp_to_all "$net" 53
  tcp_to_all "$net" 53,80,443
}

ssh_to_github() {
  local net="$1"

  # Allow SSH to GITHUB
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

# Ensure enough inotify watches and instances for Theia
sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=8192

# Flush existing DOCKER-USER rules
iptables -F DOCKER-USER

# Dockside network: for public ingress to dockside container only
create_network "dockside" "172.15.0.0/16"

# --- Custom networks ---

# ds-prod: ...
create_network "ds-prod" "172.16.0.0/16" "172.16.0.2" "02:00:00:00:00:01"
dns_and_http "ds-prod"
ssh_to_github "ds-prod"
tcp_to_all "ds-prod" 25
tcp "ds-prod" "192.168.0.0/16" 3306
icmp "ds-prod"
drop "ds-prod"

# ds-clone: ...
create_network "ds-clone" "172.17.0.0/16" "172.17.0.2" "02:00:00:00:00:01"
dns_and_http "ds-clone"
ssh_to_github "ds-clone"
tcp_to_all "ds-clone" 25
reroute_mysql "ds-clone" "pascal.dc.lan" 13306
icmp "ds-clone"
drop "ds-clone"

# ds-priv: no private, only public http(s)/DNS/NTP internet access
create_network "ds-priv" "172.18.0.0/16" "172.18.0.2" "02:00:00:00:00:01"
drop "ds-priv" "192.168.0.0/16"
dns_and_http "ds-priv"
ssh_to_github "ds-priv"
icmp "ds-priv"
drop "ds-priv"

# TODO:
# Add ipset functionality
# Add resolver functionality
# Daemonise, and add resolver loop remove/add functionality
# See https://code.claude.com/docs/en/devcontainer and https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh
