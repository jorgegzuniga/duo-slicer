#!/bin/bash
# Simulator checks for CI (run from the repository root after building into build/dd):
#   ci/simulator.sh screenshots   demo screens on the iPhone Duo, an iPhone and an iPad mini -> shots/
#   ci/simulator.sh claude        relay (wrangler dev) + the app: Claude's tools end to end -> shots/claude-*
set -u
APP="build/dd/Build/Products/Debug-iphonesimulator/Duo Slicer.app"
BUNDLE=Com.jorgegzuniga.duoslicer
mkdir -p shots

# run a command with a time limit (seconds); simulator commands can hang on a device that's still booting
limit() {
  local secs=$1
  shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null; echo "timed out after ${secs}s: $*" >> shots/simctl-errors.txt ) &
  local watcher=$!
  wait "$pid"
  local rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return $rc
}

pick() {  # newest available simulator whose name matches a regex
  xcrun simctl list devices available -j | python3 -c '
import json, sys, re
pat = re.compile(sys.argv[1])
best = None
for rt, devs in json.load(sys.stdin)["devices"].items():
    if "iOS" not in rt: continue
    for d in devs:
        if pat.search(d["name"]) and (best is None or rt > best[0]): best = (rt, d["udid"])
print(best[1] if best else "")' "$1"
}

boot() {
  local udid=$1
  limit 60 xcrun simctl boot "$udid" 2>/dev/null || true
  limit 600 xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1 || true
  limit 60 xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 2>/dev/null || true
  limit 300 xcrun simctl install "$udid" "$APP"
}

shot() {  # label udid name -- launch args...
  local label=$1 udid=$2 name=$3
  shift 3
  limit 30 xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
  limit 60 xcrun simctl launch "$udid" "$BUNDLE" "$@" > /dev/null 2>> shots/simctl-errors.txt || true
  sleep "${WAIT:-14}"
  if [ -n "${DISPLAYS:-}" ]; then  # devices with more than one screen (the iPhone Duo)
    for d in $DISPLAYS; do
      limit 45 xcrun simctl io "$udid" screenshot --display="$d" "shots/$label-$name-screen$d.png" >> shots/simctl-errors.txt 2>&1 && echo "shot $label-$name (screen $d)"
    done
  elif limit 45 xcrun simctl io "$udid" screenshot "shots/$label-$name.png" >> shots/simctl-errors.txt 2>&1; then
    echo "shot $label-$name"
  fi
  return 0
}

case "${1:-screenshots}" in
preboot)  # start the slow first boots while the app builds
  for spec in "^iPhone Duo$" "^iPad mini"; do
    udid=$(pick "$spec")
    [ -n "$udid" ] && { limit 120 xcrun simctl boot "$udid" > /dev/null 2>&1 || true; }
  done
  exit 0
  ;;
screenshots)
  { limit 30 xcrun simctl help; limit 30 xcrun simctl io help; xcrun simctl list devices available; } > shots/simctl-help.txt 2>&1 || true
  for spec in "duo:^iPhone Duo$" "iphone:^iPhone 1[0-9] Pro$" "ipad-mini:^iPad mini"; do
    label=${spec%%:*}
    udid=$(pick "${spec#*:}")
    if [ -z "$udid" ]; then echo "no simulator for $spec"; continue; fi
    boot "$udid" || continue
    DISPLAYS=""
    if [ "$label" = duo ]; then
      limit 60 xcrun simctl io "$udid" enumerate > shots/duo-screens.txt 2>&1 || true
      DISPLAYS=$(grep -oE "Screen ID: *[0-9]+|screenID: *[0-9]+" shots/duo-screens.txt | grep -oE "[0-9]+" | sort -u | xargs)
      [ -z "$DISPLAYS" ] && DISPLAYS="1 2"
    fi
    shot "$label" "$udid" plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate
    shot "$label" "$udid" u1-print -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoSlice YES -DuoDemoPanel print
    if [ "$label" = duo ]; then  # the full set on the iPhone Duo
      shot "$label" "$udid" home -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinter bambu-x1c
      shot "$label" "$udid" preview -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoSlice YES -DuoDemoPanel preview
      shot "$label" "$udid" settings -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoPanel settings
    fi
    if [ "$label" = duo ]; then  # held tall: try the inner screen's other orientation
      inner=$(echo $DISPLAYS | awk '{print $1}')
      limit 30 xcrun simctl io "$udid" screenConfig --display="$inner" geometry 2007x2853 >> shots/simctl-errors.txt 2>&1 \
        && shot "$label" "$udid" tall-plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate
    fi
    DISPLAYS=""
    limit 60 xcrun simctl shutdown "$udid" 2>/dev/null || true
  done
  ;;
claude)
  (cd relay && npm ci --no-audit --no-fund > /dev/null 2>&1 && npx wrangler dev --port 8787 --ip 127.0.0.1 > ../shots/wrangler.log 2>&1) &
  for i in $(seq 1 90); do curl -s http://127.0.0.1:8787/ > /dev/null && break; sleep 1; done
  secret="e2e_$(uuidgen | tr -d '-' | tr 'A-Z' 'a-z')"
  udid=$(pick "^iPhone Duo$")
  [ -z "$udid" ] && udid=$(pick "^iPhone 1[0-9] Pro$")
  boot "$udid"
  limit 30 xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
  limit 60 xcrun simctl launch "$udid" "$BUNDLE" -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoPanel preview \
    -DuoClaudeRelay http://127.0.0.1:8787 -DuoClaudeSecret "$secret" > /dev/null
  limit 600 node relay/test/app-e2e.mjs http://127.0.0.1:8787 "$secret" shots
  rc=$?
  limit 45 xcrun simctl io "$udid" screenshot shots/claude-after.png > /dev/null 2>&1 || true
  exit $rc
  ;;
esac
