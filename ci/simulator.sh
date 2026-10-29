#!/bin/bash
# Simulator checks for CI (run from the repository root after building into build/dd):
#   ci/simulator.sh screenshots   demo screens on the iPhone Duo, an iPhone and an iPad mini -> shots/
#   ci/simulator.sh claude        relay (wrangler dev) + the app: Claude's tools end to end -> shots/claude-*
#   ci/simulator.sh inner         the iPhone Duo's unfolded layouts at the inner screen's size, on a 13-inch iPad -> shots/duo-inner-*
#   ci/simulator.sh unfold        try to unfold the iPhone Duo simulator through Device Hub and shoot its inner screen
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

screens() {  # "id width height" for each built-in screen listed in a saved `simctl io enumerate`, smallest first
  python3 -c '
import re, sys
found = []
for block in re.split(r"\n\s*\(\d+\) ", open(sys.argv[1]).read()):
    i = re.search(r"Screen ID: *(\d+)", block)
    t = re.search(r"Screen Type: *(\w+)", block)
    s = re.search(r"Pixel Size: *\{(\d+), *(\d+)\}", block)
    if i and t and s and t.group(1) == "Integrated":
        found.append((int(s.group(1)) * int(s.group(2)), i.group(1), s.group(1), s.group(2)))
for _, i, w, h in sorted(found):
    print(i, w, h)' "$1"
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
screenshots)
  { limit 30 xcrun simctl help; limit 30 xcrun simctl io help; xcrun simctl list devices available; } > shots/simctl-help.txt 2>&1 || true
  # other devices when SHOTS_DEVICES asks for them (e.g. "iphone ipad-mini"), one at a time, then the iPhone Duo,
  # which stays booted for the Claude end-to-end run
  specs=""
  for extra in ${SHOTS_DEVICES:-}; do
    case $extra in
      iphone) specs="$specs iphone:^iPhone_1[0-9]_Pro$" ;;
      ipad-mini) specs="$specs ipad-mini:^iPad_mini" ;;
    esac
  done
  specs="$specs duo:^iPhone_Duo$"
  for spec in $specs; do
    spec=${spec//_/ }
    label=${spec%%:*}
    udid=$(pick "${spec#*:}")
    if [ -z "$udid" ]; then echo "no simulator for $spec"; continue; fi
    boot "$udid" || continue
    DISPLAYS=""
    if [ "$label" = duo ]; then
      limit 60 xcrun simctl io "$udid" enumerate > shots/duo-screens.txt 2>&1 || true
      # the outer and inner screens (not the TV-out, CarPlay and resizable ports, whose screenshots hang)
      DISPLAYS=$(screens shots/duo-screens.txt | awk '{print $1}' | xargs)
      [ -z "$DISPLAYS" ] && DISPLAYS="1 3"
    fi
    shot "$label" "$udid" plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate
    shot "$label" "$udid" u1-print -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoSlice YES -DuoDemoPanel print
    if [ "$label" = duo ]; then  # the full set on the iPhone Duo
      shot "$label" "$udid" home -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinter bambu-x1c
      shot "$label" "$udid" preview -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoSlice YES -DuoDemoPanel preview
      shot "$label" "$udid" settings -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoPanel settings
    fi
    DISPLAYS=""
    # keep the iPhone Duo running for the Claude end-to-end run
    [ "$label" = duo ] || { limit 60 xcrun simctl shutdown "$udid" 2>/dev/null || true; }
  done
  ;;
inner)
  # The iPhone Duo's unfolded layouts, drawn at the inner screen's size (951 x 669 held wide, 669 x 951 held tall)
  # on the 13-inch iPad, since the Duo simulator boots folded and simctl can't unfold it.
  udid=$(pick "^iPad Pro 13")
  [ -z "$udid" ] && udid=$(pick "^iPad Air 13")
  [ -z "$udid" ] && { echo "no 13-inch iPad simulator"; exit 0; }
  boot "$udid"
  label=duo-inner
  shot "$label" "$udid" wide-plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate -DuoDemoInner wide -DuoDemoShowFold YES
  shot "$label" "$udid" wide-preview -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoSlice YES -DuoDemoPanel preview -DuoDemoInner wide
  shot "$label" "$udid" wide-u1-print -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoSlice YES -DuoDemoPanel print -DuoDemoInner wide
  shot "$label" "$udid" wide-settings -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoPanel settings -DuoDemoInner wide
  shot "$label" "$udid" wide-home -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinter bambu-x1c -DuoDemoInner wide
  shot "$label" "$udid" tall-plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate -DuoDemoInner tall -DuoDemoShowFold YES
  shot "$label" "$udid" tall-preview -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoSlice YES -DuoDemoPanel preview -DuoDemoInner tall
  shot "$label" "$udid" tall-home -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinter snapmaker-u1 -DuoDemoInner tall
  ;;
unfold)
  # The simulator boots the iPhone Duo folded (outer screen on, inner screen dark) and simctl can't unfold it,
  # so try the posture controls in Device Hub through System Events, then shoot the inner screen.
  udid=$(pick "^iPhone Duo$")
  [ -z "$udid" ] && { echo "no iPhone Duo simulator"; exit 0; }
  boot "$udid"
  P=shots/duo-unfold.txt
  : > "$P"
  note() { echo "$*" | tee -a "$P"; }
  limit 60 xcrun simctl io "$udid" enumerate > shots/duo-screens.txt 2>&1 || true
  read -r OUTER INNER <<< "$(screens shots/duo-screens.txt | awk '{print $1}' | xargs)"
  OUTER=${OUTER:-1}; INNER=${INNER:-3}
  note "outer screen $OUTER, inner screen $INNER"
  X=$(xcode-select -p)
  XA=${X%/Contents/Developer}
  {
    echo "== simctl help ui"; limit 30 xcrun simctl help ui
    echo "== apps in Xcode"; find "$XA/Contents" -maxdepth 5 -name "*.app" -prune 2>/dev/null | grep -v "/Frameworks/" | head -40
    echo "== iPhone Duo device type"
    xcrun simctl list devicetypes -j | python3 -c 'import json,sys; [print(t["bundlePath"]) for t in json.load(sys.stdin)["devicetypes"] if "Duo" in t["name"]]' | while IFS= read -r b; do
      echo "-- $b"; find "$b" -maxdepth 3 | head -40
      find "$b" -maxdepth 3 -name "*.plist" | while IFS= read -r f; do echo "--- $f"; plutil -p "$f" 2>&1 | head -250; done
    done
    echo "== posture symbols"
    for bin in "$X/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit" /Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator "$(xcrun -f simctl)"; do
      echo "-- $bin"
      nm -gU "$bin" 2>/dev/null | grep -iE "posture|hinge|fold|crease" | head -80
      strings -a "$bin" 2>/dev/null | grep -iE "posture|hinge|unfold|folded|foldstate" | sort -u | head -80
    done
    echo "== private posture methods"; limit 180 swift ci/sim-posture.swift list
  } >> "$P" 2>&1
  inner_lit() {  # screenshot the inner screen; true when it isn't dark
    limit 45 xcrun simctl io "$udid" screenshot --display="$INNER" "$1" > /dev/null 2>&1
    local size
    size=$(stat -f%z "$1" 2>/dev/null || echo 0)
    note "  inner screen: $size bytes"
    [ "$size" -gt 130000 ]
  }
  unfolded=""
  # Xcode 27's Simulator is DeviceHub.app (Xcode > Open Developer Tool > Device Hub)
  hub=$(find "$XA/Contents" -maxdepth 5 \( -name "DeviceHub.app" -o -name "Device Hub.app" \) -prune 2>/dev/null | head -1)
  [ -z "$hub" ] && hub=$(find "$XA/Contents" -maxdepth 5 -name "Simulator.app" -prune 2>/dev/null | head -1)
  note "device app: ${hub:-none}"
  {
    echo "== guest frameworks named like posture, hinge or fold"
    rt=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; [print(r["bundlePath"]) for r in json.load(sys.stdin)["runtimes"] if r.get("version","").startswith("27.1")]' | head -1)
    root="$rt/Contents/Resources/RuntimeRoot"
    echo "runtime root: $root"
    find "$root/System/Library/PrivateFrameworks" "$root/System/Library/Frameworks" -maxdepth 1 \( -iname "*posture*" -o -iname "*hinge*" -o -iname "*fold*" \) 2>/dev/null | head -20
    find "$root" -maxdepth 6 -iname "*SimulatorBridge*" 2>/dev/null | head -5 | while IFS= read -r f; do
      echo "-- $f"
      b=$f; [ -d "$f" ] && b="$f/$(defaults read "$f/Info" CFBundleExecutable 2>/dev/null)"
      strings -a "$b" 2>/dev/null | grep -iE "posture|hinge|fold" | sort -u | head -40
    done
  } >> "$P" 2>&1
  if [ -n "$hub" ]; then
    bid=$(defaults read "$hub/Contents/Info" CFBundleIdentifier 2>/dev/null)
    {
      echo "== $hub ($bid)"
      find "$hub/Contents" -maxdepth 3 -not -path "*.lproj*" | head -60
      echo "== posture strings and symbols in Device Hub"
      find "$hub/Contents" -type f 2>/dev/null | while IFS= read -r f; do
        file -b "$f" 2>/dev/null | grep -q Mach-O || continue
        hits=$(strings -a "$f" 2>/dev/null | grep -iE "posture|hinge|unfold|folded|foldstate|crease|lidangle|lid angle" | sort -u | head -60)
        syms=$(nm -gU "$f" 2>/dev/null | grep -iE "posture|hinge|fold" | awk '{print $NF}' | xcrun swift-demangle --simplified 2>/dev/null | sort -u | head -40)
        [ -n "$hits$syms" ] && { echo "-- $f"; echo "$hits"; echo "$syms"; }
      done
    } >> "$P" 2>&1
    open -a "$hub" >> "$P" 2>&1
    sleep 30
    screencapture -x shots/mac-1.png >> "$P" 2>&1
    { echo "== UI"; limit 180 osascript -l JavaScript ci/device-hub.js dump "$bid"; } >> "$P" 2>&1
    note "menu:"; limit 60 osascript -l JavaScript ci/device-hub.js click-menu "$bid" 2>&1 | tee -a "$P"
    sleep 8
    inner_lit shots/unfold-menu.png && unfolded=menu
    for i in 0 1 2 3 4 5; do
      [ -n "$unfolded" ] && break
      note "control $i:"; limit 90 osascript -l JavaScript ci/device-hub.js click-ui "$bid" $i 2>&1 | tee -a "$P"
      sleep 8
      inner_lit "shots/unfold-ui$i.png" && unfolded=ui$i
    done
    screencapture -x shots/mac-2.png >> "$P" 2>&1
  fi
  if [ -z "$unfolded" ]; then
    note "outer screen power off:"
    limit 30 xcrun simctl io "$udid" screenConfig --display="$OUTER" power off >> "$P" 2>&1
    sleep 8
    inner_lit shots/unfold-power.png && unfolded=power
  fi
  if [ -z "$unfolded" ]; then note "couldn't unfold the iPhone Duo"; exit 0; fi
  note "unfolded ($unfolded)"
  ishot() {  # name -- launch args
    local name=$1
    shift
    limit 30 xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
    limit 60 xcrun simctl launch "$udid" "$BUNDLE" "$@" > /dev/null 2>> "$P" || true
    sleep 16
    limit 45 xcrun simctl io "$udid" screenshot --display="$INNER" "shots/duo-unfolded-$name.png" >> "$P" 2>&1 && note "shot inner $name"
  }
  ishot tall-plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate -DuoDemoOrientation portrait -DuoDemoShowFold YES
  ishot wide-plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate -DuoDemoOrientation landscape -DuoDemoShowFold YES
  ishot wide-preview -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoSlice YES -DuoDemoPanel preview -DuoDemoOrientation landscape
  ishot wide-u1-print -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoSlice YES -DuoDemoPanel print -DuoDemoOrientation landscape
  ishot tall-settings -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoPanel settings -DuoDemoOrientation portrait
  ishot home -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinter bambu-x1c
  screencapture -x shots/mac-3.png >> "$P" 2>&1
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
