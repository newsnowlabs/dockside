#!/usr/bin/env bash
# Starts, finds, or removes a Dockside server of its own to record against: a new installation
# that has only its administrator, with a certificate browsers trust for *.local.dockside.dev.
# A video that shows the admin screens, or an address bar, needs one: another server may have
# users and a host name that do not belong in a public video. record.sh starts one itself for
# a video whose target is 'child'; this script is for doing it by hand.
#
#   child-server.sh up [--image IMAGE]   make sure it is running, wait until it answers, and
#                                        log the dockside CLI in to it as its administrator.
#                                        One that is already running is kept, unless IMAGE
#                                        names a different image, in which case it is replaced.
#   child-server.sh address              print the address a browser here reaches it at
#   child-server.sh down                 remove it
#
# Its container name, the CLI nickname it is logged in as, and its default image are
# config.json's `childServer`. The image is newsnowlabs/dockside:latest unless --image or the
# VIDEO_CHILD_IMAGE environment variable gives another, such as newsnowlabs/dockside:test to
# record a build that is not yet released. It needs Docker. The administrator's password is
# read from the new server's log and used for the CLI's login only; it is not printed. The
# CLI's current server is left as it was.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
DOMAIN=local.dockside.dev

die() { echo "child-server.sh: $*" >&2; exit 1; }
cfg() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["childServer"][sys.argv[2]])' "$HERE/config.json" "$1"; }

NAME=$(cfg name) NICKNAME=$(cfg nickname) IMAGE=$(cfg image)
EXPLICIT=${VIDEO_CHILD_IMAGE:-}
ACTION=${1:-}
shift || true
while [[ $# -gt 0 ]]; do
  case $1 in
    --image) EXPLICIT=${2:?}; shift 2 ;;
    *)       die "unknown option $1" ;;
  esac
done
IMAGE=${EXPLICIT:-$IMAGE}

running() { [[ $(docker container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null) == true ]]; }

# A browser here reaches the server by its address on a network both containers are on: the
# first network this container is on, when it is a container itself, else Docker's default.
network() {
  local own
  if own=$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "$(hostname)" 2>/dev/null); then
    echo "${own%% *}"
  else
    echo bridge
  fi
}

address() {
  docker inspect -f "{{(index .NetworkSettings.Networks \"$(network)\").IPAddress}}" "$NAME" 2>/dev/null
}

case $ACTION in
  up)
    if docker container inspect "$NAME" >/dev/null 2>&1; then
      if running && [[ -z $EXPLICIT || $(docker container inspect -f '{{.Config.Image}}' "$NAME") == "$IMAGE" ]] && [[ -n $(address) ]]; then
        echo "$NAME is already running at $(address)" >&2
        exit 0
      fi
      docker rm -f "$NAME" >/dev/null
    fi
    docker run -d --name "$NAME" --security-opt apparmor=unconfined -v /var/run/docker.sock:/var/run/docker.sock \
      "$IMAGE" --ssl-builtin --passwd-stdout >/dev/null
    NETWORK=$(network)
    [[ $NETWORK == bridge ]] || docker network connect "$NETWORK" "$NAME"
    ADDRESS=$(address)
    [[ -n $ADDRESS ]] || die "$NAME has no address on the network $NETWORK"

    for _ in $(seq 120); do
      code=$(curl -sk --max-time 3 --resolve "www.$DOMAIN:443:$ADDRESS" -o /dev/null -w '%{http_code}' "https://www.$DOMAIN/" || true)
      [[ $code =~ ^[23] ]] && break
      sleep 1
    done
    [[ $code =~ ^[23] ]] || die "$NAME did not answer at $ADDRESS (see: docker logs $NAME)"

    PASSWORD=$(docker logs "$NAME" 2>&1 | sed -n 's/^admin:\(.*\)$/\1/p' | head -1)
    [[ -n $PASSWORD ]] || die "the administrator's password is not in the log of $NAME"
    # Logging in makes the new server the CLI's current one; the one that was current stays so.
    CURRENT=$(python3 "$REPO/cli/dockside" server list | awk '/✓/ { print $1 }')
    DOCKSIDE_PASSWORD=$PASSWORD python3 "$REPO/cli/dockside" login --connect-to "$ADDRESS" --no-verify \
      --nickname "$NICKNAME" --server "https://www.$DOMAIN/" --username admin >/dev/null
    [[ -z $CURRENT || $CURRENT == "$NICKNAME" ]] || python3 "$REPO/cli/dockside" server use "$CURRENT" >/dev/null
    echo "$NAME ($IMAGE) is up at $ADDRESS, and the dockside CLI is logged in to it as '$NICKNAME'" >&2
    ;;
  address)
    running || die "$NAME is not running: run '$0 up'"
    address
    ;;
  down)
    docker rm -f "$NAME" >/dev/null
    echo "$NAME removed. The dockside CLI still lists '$NICKNAME'; 'up' replaces that entry." >&2
    ;;
  *)
    die "usage: $0 up [--image IMAGE] | address | down"
    ;;
esac
