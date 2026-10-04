#!/usr/bin/env bash
# cloud-sim — run your app on a real iOS Simulator hosted on GitHub's macOS
# runners and drive it with agent-device, from a machine with no Mac.
#
#   ./cloud-sim.sh --from-project ~/Desktop/watchdoor
#   ./cloud-sim.sh --app-url https://expo.dev/artifacts/eas/xxxx.tar.gz
#   ./cloud-sim.sh --from-project ~/Desktop/watchdoor --build-latest
#
# Needs: native-sim (bun add -g native-sim), gh (authenticated), eas-cli.
# Cost: $0. The runner repo is public and standard GitHub-hosted runners —
# macOS included — are free and unlimited on public repositories.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/Desktop/watchdoor-sim}"
MINUTES="${MINUTES:-20}"
DEVICE="${DEVICE:-iPhone 17 Pro}"
APP_URL=""
FROM_PROJECT=""
LIST_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app-url)      APP_URL="$2"; shift 2 ;;
    --from-project) FROM_PROJECT="$2"; shift 2 ;;
    --build-latest) LIST_ONLY=1; shift ;;
    --minutes)      MINUTES="$2"; shift 2 ;;
    --device)       DEVICE="$2"; shift 2 ;;
    -h|--help)      sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Reads `eas build:list --json` on stdin and prints one tab-separated line per
# iOS build:  url  profile  created  status  simulator|device  id
# `isForIosSimulator` is the only trustworthy signal - the profile name is not,
# so a `development` profile that builds for the simulator still reads "device"
# if you grep the name.
dump_builds() {
  python -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("[")
if start < 0:
    sys.exit("no JSON from eas build:list")
for b in json.loads(raw[start:]):
    arts = b.get("artifacts") or {}
    url = arts.get("applicationArchiveUrl") or arts.get("buildUrl") or "-"
    prof = b.get("buildProfile") or "?"
    kind = "simulator" if b.get("isForIosSimulator") else "device"
    print("\t".join([url, prof, (b.get("createdAt") or "")[:10],
                     b.get("status") or "?", kind, (b.get("id") or "")[:8]]))
'
}

# A HEAD request is answered with the 307 to the presigned URL and tells you
# nothing; the object behind that redirect is what may have been purged. So
# follow it and ask the CDN for a single byte.
probe_url() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 30 -L -r 0-0 "$1" 2>/dev/null || echo 000
}

# Newest simulator build's archive URL, or empty.
simulator_url() {
  ( cd "$1" && eas build:list --platform ios --limit 15 --json 2>/dev/null ) \
    | dump_builds \
    | awk -F'\t' '$5=="simulator" && $1!="-" {print $1; exit}'
}

if [ "$LIST_ONLY" = "1" ]; then
  [ -n "$FROM_PROJECT" ] || { echo "--build-latest needs --from-project <expo app dir>" >&2; exit 2; }
  printf '%-20s %-11s %-9s %-9s %-9s %s\n' profile created status kind id downloadable
  printf '%s\n' "---------------------------------------------------------------------------"
  while IFS=$'\t' read -r url prof created status kind id; do
    if [ "$url" = "-" ]; then
      probe="-"
    else
      probe="$(probe_url "$url")"
    fi
    printf '%-20s %-11s %-9s %-9s %-9s HTTP %s\n' "$prof" "$created" "$status" "$kind" "$id" "$probe"
  done < <( ( cd "$FROM_PROJECT" && eas build:list --platform ios --limit 15 --json 2>/dev/null ) | dump_builds )
  echo
  echo "A 'FINISHED' build is not necessarily usable: EAS deletes artifacts after"
  echo "roughly a month, and only an HTTP 200/307 above will download on the runner."
  exit 0
fi

[ -n "$APP_URL" ] || [ -n "$FROM_PROJECT" ] \
  || { echo "pass --app-url <url> or --from-project <expo app dir>" >&2; exit 2; }
[ -n "$APP_URL" ] || APP_URL="$(simulator_url "$FROM_PROJECT")"
[ -n "$APP_URL" ] || {
  echo "no simulator build found. Build one with a profile that sets ios.simulator:true" >&2
  echo "  EAS_NO_VCS=1 eas build --profile <profile> --platform ios --non-interactive" >&2
  exit 1
}

# Never spend a session on an artifact EAS has already purged.
code="$(probe_url "$APP_URL")"
if [ "$code" != "200" ] && [ "$code" != "206" ]; then
  echo "artifact not downloadable (HTTP $code) - it has been purged. Trigger a new build." >&2
  exit 1
fi

cd "$REPO_DIR"
[ -d .github/workflows ] || { echo "$REPO_DIR has no native-sim workflow; run native-sim there first" >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
  echo "warning: $REPO_DIR has uncommitted files. native-sim commits and pushes them ALL to" >&2
  echo "         a PUBLIC repo, so nothing here may be app source or a screenshot." >&2
  sleep 3
fi

# The presigned redirect lives 900 seconds, so resolve and dispatch together.
export NATIVE_SIM_TELEMETRY_DISABLED=1
echo "→ dispatching a $MINUTES-minute session on $DEVICE"
native-sim up --app "$APP_URL" --agent --public --minutes "$MINUTES" --device "$DEVICE" --no-open \
  2>&1 | tee /tmp/cloud-sim.out

URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cloud-sim.out | head -1 || true)"
KEY="$(grep -oE '\?k=[A-Za-z0-9]+' /tmp/cloud-sim.out | head -1 | cut -c4- || true)"
[ -n "$URL" ] || { echo "no tunnel URL returned; inspect the run: gh run list -R $(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | sed 's#.*github.com[:/]##; s#\.git$##')" >&2; exit 1; }

cat <<EOF

Drive it from any shell — the auth token is NOT inherited by agent-device, so
export both variables (a saved `connect proxy` config is not enough):

  export AGENT_DEVICE_DAEMON_BASE_URL="$URL/agent-device"
  export AGENT_DEVICE_DAEMON_AUTH_TOKEN="$KEY"

  agent-device devices --platform ios           # look for booted=true
  agent-device open <bundleId> --platform ios --relaunch
  agent-device snapshot -i                      # accessibility tree
  agent-device screenshot --out /tmp/sim.png    # keep captures OUT of $REPO_DIR
  agent-device close

Watch it in a browser:  $URL/?k=$KEY

Stop the meter when done (a session otherwise runs to its full lifetime):
  agent-device disconnect
  cd "$REPO_DIR" && native-sim down
EOF
