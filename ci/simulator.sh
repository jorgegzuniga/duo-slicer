#!/bin/bash
# Simulator checks for CI (run from the repository root after building into build/dd):
#   ci/simulator.sh screenshots   demo screens on the iPhone Duo, an iPhone and an iPad mini -> shots/
#   ci/simulator.sh claude        relay (wrangler dev) + the app: Claude's tools end to end -> shots/claude-*
set -u
APP="build/dd/Build/Products/Debug-iphonesimulator/Duo Slicer.app"
BUNDLE=Com.jorgegzuniga.duoslicer
mkdir -p shots

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
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1 || true
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 2>/dev/null || true
  xcrun simctl install "$udid" "$APP"
}

shot() {  # label udid name -- launch args...
  local label=$1 udid=$2 name=$3
  shift 3
  xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$udid" "$BUNDLE" "$@" > /dev/null 2>> shots/simctl-errors.txt || true
  sleep "${WAIT:-14}"
  if xcrun simctl io "$udid" screenshot "shots/$label-$name.png" >> shots/simctl-errors.txt 2>&1; then
    echo "shot $label-$name"
  else
    for d in internal external; do
      xcrun simctl io "$udid" screenshot --display=$d "shots/$label-$name-$d.png" >> shots/simctl-errors.txt 2>&1 && echo "shot $label-$name ($d)"
    done
  fi
  return 0
}

case "${1:-screenshots}" in
screenshots)
  { xcrun simctl help; xcrun simctl io help; } > shots/simctl-help.txt 2>&1 || true
  for spec in "duo:^iPhone Duo$" "iphone:^iPhone 1[0-9] Pro$" "ipad-mini:^iPad mini"; do
    label=${spec%%:*}
    udid=$(pick "${spec#*:}")
    if [ -z "$udid" ]; then echo "no simulator for $spec"; continue; fi
    boot "$udid" || continue
    shot "$label" "$udid" home -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinter bambu-x1c
    shot "$label" "$udid" plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate
    shot "$label" "$udid" preview -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoSlice YES -DuoDemoPanel preview
    shot "$label" "$udid" u1-print -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoSlice YES -DuoDemoPanel print
    shot "$label" "$udid" settings -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoPanel settings
    xcrun simctl shutdown "$udid" 2>/dev/null || true
  done
  ;;
claude)
  (cd relay && npm ci --no-audit --no-fund > /dev/null 2>&1 && npx wrangler dev --port 8787 --ip 127.0.0.1 > ../shots/wrangler.log 2>&1) &
  for i in $(seq 1 90); do curl -s http://127.0.0.1:8787/ > /dev/null && break; sleep 1; done
  secret="e2e_$(uuidgen | tr -d '-' | tr 'A-Z' 'a-z')"
  udid=$(pick "^iPhone Duo$")
  [ -z "$udid" ] && udid=$(pick "^iPhone 1[0-9] Pro$")
  boot "$udid"
  xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$udid" "$BUNDLE" -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoPanel preview \
    -DuoClaudeRelay http://127.0.0.1:8787 -DuoClaudeSecret "$secret" > /dev/null
  node relay/test/app-e2e.mjs http://127.0.0.1:8787 "$secret" shots
  rc=$?
  xcrun simctl io "$udid" screenshot shots/claude-after.png > /dev/null 2>&1 || true
  exit $rc
  ;;
esac
