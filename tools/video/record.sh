#!/usr/bin/env bash
# Records a take of a video from videos/ against a Dockside server, and builds the video files.
# See README.md for the whole picture.
#
#   record.sh [options] VIDEO
#
# Where it records is the video's `target` (config.json's `target` unless the video sets it):
#
#   current   the Dockside running in this container, which is the dockside CLI's current
#             server, browsed through the Playwright MCP proxy; the proxy maps this
#             container's own host names to its nginx and adds the X-Nest-Level header
#             they need
#   child     a Dockside server of its own (see child-server.sh), started if it is not
#             running, reached directly at its address with its certificate verified
#
#   --target TARGET     current or child, instead of the video's
#   --server NICKNAME   record against another server the dockside CLI is already
#                       logged in to as an admin (see: dockside server list)
#   --any-server        let a video that needs a clean server (its `cleanServer`) record
#                       another: its admin screens list that server's users and roles
#   --proxy URL         browse through this HTTP proxy (default: the proxy named in
#                       the Playwright MCP config, $PLAYWRIGHT_MCP_CONFIG or
#                       ~/.playwright/mcp-config.json)
#   --no-proxy          browse directly
#   --connect-to HOST   browse directly, reaching the server's domain at this address
#                       or host name (the CLI's --connect-to): for a Dockside in a
#                       sibling container, which the proxy does not map
#   --verify-cert       have the browser verify the server's certificate, as a visitor's
#                       would, instead of accepting any; a trusted certificate then
#                       shows as secure in the address bar
#   --header 'N: V'     add a request header to every browser request; repeatable.
#                       A nested Dockside needs X-Nest-Level, as the CLI sends it.
#   --voice NAME        narrate with voices/NAME (default: the video's voice.engine, else config.json's);
#                       only the build uses it, so --build-only can try another voice
#   --formats LIST      comma-separated: mp4,gif,webp (default: all three)
#   --out DIR           where to write (default: tools/video/out/VIDEO)
#   --build-only        skip recording; rebuild the videos from DIR's earlier capture
#                       (in the colour scheme it was recorded in)
#   --no-build          record only, to try a video without waiting for the encode
#   --chrome MODE       the browser window to show above the page: none, tabs (its tab
#                       strip) or full (the toolbar and address bar too); overrides the
#                       video's and config.json's
#   --captions-position POS
#                       where captions go: band (under the page), bottom or top (over it)
#   --color-scheme S    the colour scheme the page is shown in, light or dark: the
#                       client's own theme follows it, and the title cards match;
#                       overrides the video's and config.json's
#   --script            print the video's captions and narration for reading through;
#                       needs no server, browser or recording
#   --check             work out where the video would record, and test that it can be
#                       reached, without recording
#
# Throwaway users, the demo user, a viewer to share with and a colleague to add as a developer, are created for the recording
# and removed afterwards along with every devtainer the demo user launched, whether or not
# it succeeds. The demo user has the role config.json's demo.role gives, or the video's own,
# and only the profiles in demo.resources, so the UI shows what that role sees and none of the
# server's other profiles or devtainers. The demo user's generated password is held in a
# mode-600 temporary file and never printed.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

TARGET='' SERVER='' ANY_SERVER=0 CHECK=0 PROXY='' NO_PROXY=0 CONNECT_TO='' VERIFY_CERT=0 VOICE='' FORMATS='mp4,gif,webp' OUT='' BUILD_ONLY=0 NO_BUILD=0 SCRIPT=0 CHROME='' CAPTIONS_POSITION='' COLOR_SCHEME='' VIDEO=''
HEADERS=()

die() { echo "record.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --target)     TARGET=${2:?}; shift 2 ;;
    --server)     SERVER=${2:?}; shift 2 ;;
    --any-server) ANY_SERVER=1; shift ;;
    --check)      CHECK=1; shift ;;
    --proxy)      PROXY=${2:?}; shift 2 ;;
    --no-proxy)   NO_PROXY=1; shift ;;
    --connect-to) CONNECT_TO=${2:?}; shift 2 ;;
    --verify-cert) VERIFY_CERT=1; shift ;;
    --header)     HEADERS+=("${2:?}"); shift 2 ;;
    --voice)      VOICE=${2:?}; shift 2 ;;
    --formats)    FORMATS=${2:?}; shift 2 ;;
    --out)        OUT=${2:?}; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --no-build)   NO_BUILD=1; shift ;;
    --script)     SCRIPT=1; shift ;;
    --chrome)     CHROME=${2:?}; shift 2 ;;
    --captions-position) CAPTIONS_POSITION=${2:?}; shift 2 ;;
    --color-scheme) COLOR_SCHEME=${2:?}; shift 2 ;;
    -h|--help)    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*)           die "unknown option $1" ;;
    *)            VIDEO=$1; shift ;;
  esac
done

case $COLOR_SCHEME in ''|light|dark) ;; *) die "--color-scheme is light or dark" ;; esac
[[ -n $VIDEO ]] || die "name a video (one of: $(find "$HERE/videos" -name '*.js' -printf '%f\n' | sed 's/\.js$//' | sort | tr '\n' ' '))"
VIDEO_FILE="$HERE/videos/$VIDEO.js"
[[ -f $VIDEO_FILE ]] || die "no such video: $VIDEO_FILE"
if [[ $SCRIPT -eq 1 ]]; then
  node "$HERE/lib/dry-run.js" "$VIDEO_FILE" | python3 "$HERE/lib/script.py"
  exit
fi
OUT=${OUT:-$HERE/out/$VIDEO}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

if [[ $BUILD_ONLY -eq 1 ]]; then
  [[ -z $COLOR_SCHEME ]] || die "--build-only builds the colour scheme the capture was recorded in: record again with --color-scheme"
  exec python3 "$HERE/lib/build.py" "$OUT" "$VIDEO" --formats "$FORMATS" ${VOICE:+--voice "$VOICE"} ${CHROME:+--chrome "$CHROME"} ${CAPTIONS_POSITION:+--captions-position "$CAPTIONS_POSITION"}
fi

"$HERE/install.sh" >/dev/null || { "$HERE/install.sh" >&2 || true; die "missing dependencies (see above)"; }

ds() { python3 "$REPO/cli/dockside" --server "$SERVER" "$@"; }
cfg() { node "$HERE/lib/settings.js" "$VIDEO_FILE" "$1"; }

# The target: where the video is to record, and how the browser reaches it.
TARGET=${TARGET:-$(cfg target)}
CHILD=$(cfg childServer.nickname)
case $TARGET in
  current) ;;
  child)
    if [[ -z $SERVER || $SERVER == "$CHILD" ]]; then
      SERVER=$CHILD
      "$HERE/child-server.sh" up
      [[ -n $CONNECT_TO ]] || CONNECT_TO=$("$HERE/child-server.sh" address)
      VERIFY_CERT=1
    fi
    ;;
  *) die "the target is current or child, not '$TARGET'" ;;
esac

SERVERS=$(python3 "$REPO/cli/dockside" server list)
[[ -n $SERVER ]] || SERVER=$(awk '/✓/ { print $1 }' <<<"$SERVERS")
[[ -n $SERVER ]] || die "the CLI has no current server: pass --server (see: dockside server list)"
URL=$(awk -v n="$SERVER" '$1 == n { print $2 }' <<<"$SERVERS")
[[ -n $URL ]] || die "the CLI has no server named $SERVER (see: dockside server list)"
if [[ $(cfg cleanServer) == true && $SERVER != "$CHILD" && $ANY_SERVER -eq 0 ]]; then
  die "$VIDEO needs a clean server, since its admin screens list the server's users and roles, and $SERVER is not '$CHILD': use --target child, or --any-server if $SERVER may be shown"
fi

# The proxy to browse through: the one the Playwright MCP is configured with, unless
# the browser is to connect directly.
if [[ -z $PROXY && -z $CONNECT_TO && $NO_PROXY -eq 0 ]]; then
  PROXY=$(python3 - "${PLAYWRIGHT_MCP_CONFIG:-$HOME/.playwright/mcp-config.json}" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1]))['browser']['contextOptions']['proxy']['server'])
except (OSError, KeyError, ValueError):
    pass
PY
)
fi
[[ $NO_PROXY -eq 0 ]] || PROXY=''
route="$URL ($SERVER)"
[[ -z $PROXY ]] || route+=" through $PROXY"
[[ -z $CONNECT_TO ]] || route+=" connecting to $CONNECT_TO"
[[ $VERIFY_CERT -eq 0 ]] || route+=", verifying its certificate"
echo "Recording $route" >&2

# The profiles the recording depends on must be on the server and active, or it would only fail,
# or come out wrong, once under way. That is every profile config.json gives the demo user, which
# would otherwise see fewer Launch buttons than the video expects, and the video's own `requires`:
# `profiles`, the ids it launches devtainers from, which the demo user must also be given, and
# `firstProfile`, the id the launch form starts on, which is the first the demo user has. A server
# whose image lacks one needs another image: see child-server.sh up --image.
check_profiles() {
  local problems
  problems=$(ds profile list --output json | python3 -c '
import json, sys
profiles = {p["id"]: p.get("active") for p in json.load(sys.stdin)}
granted = json.loads(sys.argv[1]).get("profiles", [])
requires = json.loads(sys.argv[2] or "{}")
problems = []
state = lambda p: "inactive" if p in profiles else "absent"
for p in [g for g in granted if g != "*"]:
    if not profiles.get(p):
        problems.append(f"profile {p}, which demo.resources.profiles gives the demo user, is {state(p)}")
for p in requires.get("profiles", []):
    if not profiles.get(p):
        problems.append(f"profile {p}, which the video launches from, is {state(p)}")
    elif "*" not in granted and p not in granted:
        problems.append(f"profile {p}, which the video launches from, is not in demo.resources.profiles")
first = requires.get("firstProfile")
if first:
    visible = sorted(i for i, active in profiles.items() if active and ("*" in granted or i in granted))
    got = visible[0] if visible else "no profile"
    if got != first:
        problems.append(f"the launch form would start on {got}, not {first}, which the video expects")
print("\n".join(problems))' "$(cfg demo.resources)" "$(cfg requires)") \
    || die "cannot list the profiles of $SERVER"
  [[ -z $problems ]] || die "the recording cannot use $SERVER as it is:"$'\n'"$problems"$'\n'"Record against a server whose image has the profiles (child-server.sh up --image IMAGE), or change config.json."
}

# The recording makes the demo user, the viewer and the colleague, whether beforehand or on screen,
# and removes whatever it finds under those names first, so a user of that name is only safe to
# replace when it is a leftover of an earlier recording: one with the display name config.json
# gives it. Any other user would be removed, with its devtainers, so the recording stops instead.
# Each user's role must exist too, or creating the user fails once recording is under way.
check_accounts() {
  local problems
  problems=$(python3 - "$(ds user list --output json)" "$(ds role list --output json)" \
    "$(cfg demo.user)|$(cfg demo.name)|$(cfg demo.role)" \
    "$(cfg demo.viewer.user)|$(cfg demo.viewer.name)|$(cfg demo.viewer.role)" \
    "$(cfg demo.colleague.user)|$(cfg demo.colleague.name)|$(cfg demo.colleague.role)" <<'PY'
import json, sys
users = {u["username"]: u["name"] for u in json.loads(sys.argv[1])}
roles = {r["name"] for r in json.loads(sys.argv[2])}
for entry in sys.argv[3:]:
    user, name, role = entry.split("|")
    if user in users and users[user] != name:
        print(f"user '{user}' exists and is named '{users[user]}', not '{name}'")
    if role not in roles:
        print(f"role '{role}', for user '{user}', does not exist")
PY
  ) || die "cannot list the users and roles of $SERVER"
  [[ -z $problems ]] || die "the recording cannot use $SERVER as it is:"$'\n'"$problems"$'\n'"Change the user names in config.json's demo, or the server's users and roles."
}

# A narrated video needs its voice, which is not committed (voices/README.md): a recording made
# without it would only fail when the build looked for it.
ENGINE=${VOICE:-$(cfg voice.engine)}
check_voice() {
  [[ $ENGINE == none || -x $HERE/voices/$ENGINE/speak ]] \
    || die "no voice '$ENGINE': $HERE/voices/$ENGINE/speak is missing or not executable (see voices/README.md); --voice none records a silent video"
}

# --check: can the CLI use the server, and can the browser's route reach it?
if [[ $CHECK -eq 1 ]]; then
  ds list >/dev/null || die "the dockside CLI cannot use $SERVER"
  echo "the dockside CLI can use $SERVER" >&2
  host=${URL#https://}; host=${host%%/*}
  curl_args=(-s -o /dev/null -w '%{http_code}' --max-time 15)
  [[ $VERIFY_CERT -eq 1 ]] || curl_args+=(-k)
  if [[ -n $CONNECT_TO ]]; then curl_args+=(--resolve "$host:443:$CONNECT_TO")
  elif [[ -n $PROXY ]]; then curl_args+=(-x "$PROXY"); fi
  code=$(curl "${curl_args[@]}" "$URL/" || true)
  [[ $code =~ ^[23] ]] || die "the browser's route to $URL answers '$code', not a page$([[ $VERIFY_CERT -eq 0 ]] || echo ' (its certificate is verified)')"
  echo "the browser's route to $URL answers $code" >&2
  check_profiles
  check_accounts
  check_voice
  echo "$SERVER has every profile and role the recording needs, and no user it would remove" >&2
  exit 0
fi

check_profiles
check_accounts
check_voice

# With a voice, each caption is given exactly as long as its speech takes, measured now, so
# the recording has no slack for a caption and no caption overruns its slot.
rm -f "$OUT/speech.json"
SPEECH=''
if [[ $ENGINE != none ]]; then
  node "$HERE/lib/dry-run.js" "$VIDEO_FILE" | python3 "$HERE/lib/speech.py" "$OUT" "$ENGINE"
  SPEECH=$OUT/speech.json
fi

DEMO_USER=$(cfg demo.user)
DEMO_ROLE=$(cfg demo.role)
VIEWER_USER=$(cfg demo.viewer.user)
COLLEAGUE_USER=$(cfg demo.colleague.user)
PW_FILE=$(mktemp)
chmod 600 "$PW_FILE"
XVFB_PID='' FFMPEG_PID=''

# Removes every devtainer the demo user owns, which is everything a video launched.
# A running devtainer has to be stopped before it can be removed.
remove_devtainers() {
  local name
  while read -r name; do
    ds stop "$name" >/dev/null 2>&1 || true
    ds rm --force "$name" >/dev/null 2>&1 || true
  done < <(ds list --output json 2>/dev/null | python3 -c '
import json, sys
try:
    for c in json.load(sys.stdin):
        if c.get("meta", {}).get("owner") == sys.argv[1]:
            print(c["name"])
except ValueError:
    pass' "$DEMO_USER")
}

user_exists() {
  ds user list 2>/dev/null | awk -v u="$1" '$1 == u { found = 1 } END { exit !found }'
}

# A removed devtainer is still counted as a reference to its owner until the server has finished
# removing it, which can take a minute after a recording that has just ended, and blocks removing
# or recreating the owner, so both retry.
remove_user() {
  local tries=60
  while user_exists "$1" && ((tries-- > 0)); do
    ds user rm --force "$1" >/dev/null 2>&1 || sleep 2
  done
}

remove_users() {
  remove_user "$DEMO_USER"
  remove_user "$VIEWER_USER"
  remove_user "$COLLEAGUE_USER"
}

create_user() {
  local tries=60 out
  until out=$(ds user create "$@" 2>&1); do
    ((--tries > 0)) || die "cannot create user $1: $out"
    sleep 2
  done
}

cleanup() {
  if [[ -n $FFMPEG_PID ]]; then
    kill -INT "$FFMPEG_PID" 2>/dev/null || true
    wait "$FFMPEG_PID" 2>/dev/null || true
  fi
  if [[ -n $XVFB_PID ]]; then kill "$XVFB_PID" 2>/dev/null || true; fi
  remove_devtainers
  remove_users
  rm -f "$PW_FILE"
}
trap cleanup EXIT

# Start from a clean slate: no leftover demo users or devtainers.
remove_devtainers
remove_users
head -c 18 /dev/urandom | base64 | tr -d '/+=' > "$PW_FILE"

# The demo user's account is filled in beforehand, so the account page shows a lived-in
# account: a GitHub token, an authorized public key, and a keypair, none of them real.
# The keys are made here, kept only until the user is created, and never leave this machine.
KEY_DIR=$(mktemp -d)
for key in laptop github; do
  ssh-keygen -q -t ed25519 -N '' -C "demo@example.com" -f "$KEY_DIR/$key"
done
GH_TOKEN="ghp_$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36)))')"
SSH_JSON=$(python3 - "$KEY_DIR" <<'PY'
import json, sys
read = lambda name: open(f'{sys.argv[1]}/{name}').read().strip()
print(json.dumps({
    'publicKeys': {'laptop': read('laptop.pub')},
    'keypairs': {'github': {'public': read('github.pub'), 'private': open(f'{sys.argv[1]}/github').read()}},
}))
PY
)
create_user "$DEMO_USER" --role "$DEMO_ROLE" --user-password "$(cat "$PW_FILE")" \
  --name "$(cfg demo.name)" --email "$(cfg demo.email)" --gh-token "$GH_TOKEN" --ssh "$SSH_JSON" \
  --resources "$(cfg demo.resources)"
rm -f "$KEY_DIR"/laptop "$KEY_DIR"/laptop.pub "$KEY_DIR"/github "$KEY_DIR"/github.pub
rmdir "$KEY_DIR"
unset GH_TOKEN SSH_JSON
# A viewer to share with, unless the video creates one through the admin screens. It is
# only ever shared with, never signed in as, so its password is never used.
if [[ $(cfg demo.viewer.precreate) == true ]]; then
  create_user "$VIEWER_USER" --role "$(cfg demo.viewer.role)" --name "$(cfg demo.viewer.name)" \
    --user-password "$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
fi
# A colleague to add as a developer, made the same way, for a video that shows a developer
# being added.
if [[ $(cfg demo.colleague.precreate) == true ]]; then
  create_user "$COLLEAGUE_USER" --role "$(cfg demo.colleague.role)" --name "$(cfg demo.colleague.name)" \
    --user-password "$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
fi

# Browser request headers, as JSON.
HEADERS_JSON=$(python3 -c 'import json, sys; print(json.dumps(dict(h.split(": ", 1) for h in sys.argv[1:])))' "${HEADERS[@]}")

# A display to record: the browser window at its device scale fills it.
DISPLAY_NUM=''
for n in $(seq 90 130); do
  [[ -e /tmp/.X11-unix/X$n ]] || { DISPLAY_NUM=$n; break; }
done
[[ -n $DISPLAY_NUM ]] || die "no free X display number"
SCALE=$(cfg scale)
SCREEN_W=$(($(cfg window.width) * SCALE))
SCREEN_H=$(($(cfg window.height) * SCALE))
FPS=$(cfg fps)
Xvfb ":$DISPLAY_NUM" -screen 0 "${SCREEN_W}x${SCREEN_H}x24" -nolisten tcp >"$OUT/xvfb.log" 2>&1 &
XVFB_PID=$!
for _ in $(seq 50); do [[ -e /tmp/.X11-unix/X$DISPLAY_NUM ]] && break; sleep 0.1; done

# The capture is piped through t0tee.py, which notes when the first frame arrives.
rm -f "$OUT/t0" "$OUT/raw.mkv" "$OUT/timeline.json" "$OUT/failure.png"
ffmpeg -v error -f x11grab -framerate "$FPS" -video_size "${SCREEN_W}x${SCREEN_H}" -draw_mouse 0 -i ":$DISPLAY_NUM" \
  -c:v libx264 -preset ultrafast -crf 14 -pix_fmt yuv444p -flush_packets 1 -f matroska pipe:1 \
  > >(python3 "$HERE/lib/t0tee.py" "$OUT/raw.mkv" "$OUT/t0") &
FFMPEG_PID=$!
for _ in $(seq 100); do [[ -s $OUT/t0 ]] && break; sleep 0.1; done
[[ -s $OUT/t0 ]] || die "the capture did not start (see: DISPLAY=:$DISPLAY_NUM)"

status=0
DISPLAY=":$DISPLAY_NUM" DEMO_URL="$URL" DEMO_USER="$DEMO_USER" DEMO_PASSWORD_FILE="$PW_FILE" \
  DEMO_COLOR_SCHEME="$COLOR_SCHEME" DEMO_PROXY="$PROXY" DEMO_CONNECT_TO="$CONNECT_TO" DEMO_VERIFY_CERT="$VERIFY_CERT" DEMO_SPEECH="$SPEECH" DEMO_HEADERS="$HEADERS_JSON" REC_OUT="$OUT" \
  node "$HERE/lib/run-video.js" "$VIDEO_FILE" || status=$?

kill -INT "$FFMPEG_PID" 2>/dev/null || true
wait "$FFMPEG_PID" 2>/dev/null || true
FFMPEG_PID=''
sleep 0.3 # let the tee flush its last chunk

if [[ $status -ne 0 ]]; then
  [[ -f $OUT/failure.png ]] && echo "record.sh: the video failed; its last screen is $OUT/failure.png" >&2
  exit "$status"
fi
if [[ $NO_BUILD -eq 0 ]]; then
  python3 "$HERE/lib/build.py" "$OUT" "$VIDEO" --formats "$FORMATS" ${VOICE:+--voice "$VOICE"} ${CHROME:+--chrome "$CHROME"} ${CAPTIONS_POSITION:+--captions-position "$CAPTIONS_POSITION"}
fi
