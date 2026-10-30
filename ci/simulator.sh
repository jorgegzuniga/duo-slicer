#!/bin/bash
# Simulator checks for CI (run from the repository root after building into build/dd):
#   ci/simulator.sh screenshots   demo screens on the iPhone Duo, an iPhone and an iPad mini -> shots/
#   ci/simulator.sh claude        relay (wrangler dev) + the app: Claude's tools end to end -> shots/claude-*
#   ci/simulator.sh inner         the iPhone Duo's unfolded layouts at the inner screen's size, on a 13-inch iPad -> shots/duo-inner-*
#   ci/simulator.sh unfold        try to unfold the iPhone Duo simulator through Device Hub and shoot its inner screen
#   ci/simulator.sh discover      Add printer's Wi-Fi search against stand-in printers on the runner -> shots/discover-*
#   ci/simulator.sh fleet         three stand-in printers: printers list, cameras, the print queue printing -> shots/fleet-*
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
  # the app's CPU use on the host: a busy app at rest means a layout loop
  { echo "$label-$name: $(ps -Ao pcpu=,rss=,command= | grep -i "Duo Slicer.app/Duo Slicer" | grep -v grep | awk '{print $1 "% cpu, " int($2/1024) " MB"}' | xargs)"; } >> shots/app-cpu.txt 2>&1
  if [ -n "${DISPLAYS:-}" ]; then  # devices with more than one screen (the iPhone Duo)
    for d in $DISPLAYS; do
      snap "$udid" "shots/$label-$name-screen$d.png" --display="$d" && echo "shot $label-$name (screen $d)"
    done
  elif snap "$udid" "shots/$label-$name.png"; then
    echo "shot $label-$name"
  fi
  return 0
}

snap() {  # udid file [--display=N]: a screenshot, tried twice (the simulator's capture sometimes stalls)
  local udid=$1 file=$2
  shift 2
  limit 45 xcrun simctl io "$udid" screenshot "$@" "$file" >> shots/simctl-errors.txt 2>&1 && return 0
  sleep 5
  limit 45 xcrun simctl io "$udid" screenshot "$@" "$file" >> shots/simctl-errors.txt 2>&1
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
  shot "$label" "$udid" regular-plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate
  ;;
unfold)
  # The simulator boots the iPhone Duo folded (outer screen on, inner screen dark) and simctl can't unfold it,
  # so press "open" in the posture bar Device Hub shows under the device, then shoot the inner screen.
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
  inner_lit() {  # screenshot the inner screen; true when it isn't dark
    limit 45 xcrun simctl io "$udid" screenshot --display="$INNER" "$1" > /dev/null 2>&1
    local size
    size=$(stat -f%z "$1" 2>/dev/null || echo 0)
    note "  inner screen: $size bytes"
    [ "$size" -gt 130000 ]
  }
  X=$(xcode-select -p)
  XA=${X%/Contents/Developer}
  # Xcode 27's Simulator is DeviceHub.app (Xcode > Open Developer Tool > Device Hub)
  hub=$(find "$XA/Contents" -maxdepth 5 \( -name "DeviceHub.app" -o -name "Device Hub.app" \) -prune 2>/dev/null | head -1)
  note "device app: ${hub:-none}"
  unfolded=""
  if [ -n "$hub" ]; then
    bid=$(defaults read "$hub/Contents/Info" CFBundleIdentifier 2>/dev/null)
    open -a "$hub" >> "$P" 2>&1
    sleep 30
    screencapture -x shots/mac-1.png >> "$P" 2>&1
    { echo "== UI"; limit 240 osascript -l JavaScript ci/device-hub.js dump "$bid"; } >> "$P" 2>&1
    note "menu:"; limit 90 osascript -l JavaScript ci/device-hub.js click-menu "$bid" 2>&1 | tee -a "$P"
    sleep 8
    inner_lit shots/unfold-menu.png && unfolded=menu
    for i in 0 1 2; do
      [ -n "$unfolded" ] && break
      note "control $i:"; limit 120 osascript -l JavaScript ci/device-hub.js click-ui "$bid" $i 2>&1 | tee -a "$P"
      sleep 8
      inner_lit "shots/unfold-ui$i.png" && unfolded=ui$i
    done
    # the posture bar's "open" and "half open" buttons, where they sit on the runner's 1024 x 768 screen
    for xy in "742 682" "709 682"; do
      [ -n "$unfolded" ] && break
      note "click at $xy:"; limit 30 osascript -l JavaScript ci/device-hub.js click-at $xy 2>&1 | tee -a "$P"
      sleep 8
      inner_lit "shots/unfold-at-${xy// /-}.png" && unfolded="click at $xy"
    done
    screencapture -x shots/mac-2.png >> "$P" 2>&1
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
  ishot plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate -DuoDemoShowFold YES
  ishot preview -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoSlice YES -DuoDemoPanel preview
  ishot u1-print -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoSlice YES -DuoDemoPanel print
  ishot home -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinter bambu-x1c
  ishot rotated-plate -DuoDemo YES -DuoDemoPrinter bambu-x1c -DuoDemoPanel plate -DuoDemoOrientation portrait -DuoDemoShowFold YES
  screencapture -x shots/mac-3.png >> "$P" 2>&1
  ;;
discover)
  # Add printer's search against stand-in printers on loopback addresses: a Bambu Lab P1S (TLS certificate named
  # with its serial number) and a Snapmaker U1 (Moonraker). The app is told to search those two addresses, since
  # extra addresses on the runner's own network turned out unreachable.
  P=shots/discover.txt
  : > "$P"
  a=127.0.0.2
  b=127.0.0.3
  sudo ifconfig lo0 alias "$a" up >> "$P" 2>&1
  sudo ifconfig lo0 alias "$b" up >> "$P" 2>&1
  sudo pkill -f "[f]ake_printers.py" 2>/dev/null; sleep 1
  # as root: the stand-ins also listen on ports below 1024 (FTPS 990, RTSPS 322)
  sudo python3 ci/fake_printers.py "$a" "$b" > shots/fake-printers.txt 2>&1 &
  sleep 5
  { echo "stand-ins: P1S at $a, U1 at $b"; curl -s -m 3 "http://$b:7125/printer/objects/list"; echo
    echo "== runner network"; ifconfig en0 | grep "inet "; netstat -anv -p tcp | grep LISTEN | grep -E "\.8883|\.7125"
    /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate; } >> "$P" 2>&1
  udid=$(pick "^iPhone Duo$")
  [ -z "$udid" ] && udid=$(pick "^iPhone 1[0-9] Pro$")
  boot "$udid"
  limit 60 xcrun simctl io "$udid" enumerate > shots/duo-screens.txt 2>&1 || true
  DISPLAYS=$(screens shots/duo-screens.txt | awk '{print $1}' | xargs)
  WAIT=30 shot discover "$udid" add-printer -DuoDemo YES -DuoDemoHome YES -DuoDemoAddPrinter YES -DuoDemoScanHosts "$a,$b"
  echo "connections the stand-ins saw: $(grep -c " from " shots/fake-printers.txt)" >> "$P"
  sudo pkill -f "[f]ake_printers.py" 2>/dev/null
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
fleet)
  # Three stand-in printers on loopback addresses (ci/fake_printers.py): a P1S (MQTT, FTPS upload, JPEG camera), a
  # Snapmaker U1 (Moonraker, uploads, camera snapshots) and an X1 Carbon (MQTT, RTSPS H.264 camera). Shots of the
  # printers, each printer's camera, the print queue sending plates to them, and the Print panel while the U1 prints.
  P=shots/fleet.txt
  : > "$P"
  for ip in 127.0.0.2 127.0.0.3 127.0.0.4; do sudo ifconfig lo0 alias "$ip" up >> "$P" 2>&1; done
  sudo pkill -f "[f]ake_printers.py" 2>/dev/null; sleep 1
  sudo python3 ci/fake_printers.py 127.0.0.2 127.0.0.3 127.0.0.4 > shots/fleet-stand-ins.txt 2>&1 &
  sleep 6
  debug() { curl -s -m 5 -X POST "http://127.0.0.3:7125/debug/print?printer=$1&name=$2" >> "$P" 2>&1; echo >> "$P"; }
  udid=$(pick "^iPhone Duo$")
  [ -z "$udid" ] && udid=$(pick "^iPhone 1[0-9] Pro$")
  boot "$udid"
  limit 60 xcrun simctl io "$udid" enumerate > shots/duo-screens.txt 2>&1 || true
  DISPLAYS=$(screens shots/duo-screens.txt | awk '{print $1}' | xargs)
  PR="bambu-p1s@127.0.0.2,snapmaker-u1@127.0.0.3,bambu-x1c@127.0.0.4"
  # stand-in prints take about 50 s; the U1 stays free for the queue run below
  debug P1S Benchy
  WAIT=22 shot fleet "$udid" printers -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinters "$PR" -DuoDemoSheet printers
  debug P1S Benchy
  WAIT=22 shot fleet "$udid" p1s -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinters "$PR" -DuoDemoSheet printers -DuoDemoOpenPrinter bambu-p1s
  debug X1C Gearbox
  WAIT=26 shot fleet "$udid" x1c -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinters "$PR" -DuoDemoSheet printers -DuoDemoOpenPrinter bambu-x1c
  WAIT=22 shot fleet "$udid" u1 -DuoDemo YES -DuoDemoHome YES -DuoDemoPrinters "$PR" -DuoDemoSheet printers -DuoDemoOpenPrinter snapmaker-u1
  sleep 20
  # the queue: filled from the demo project (a plate for the P1S, two for any U1) and started with every bed clear
  WAIT=45 shot fleet "$udid" queue-printing -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoPrinters "$PR" -DuoDemoQueue YES -DuoDemoSheet queue
  sleep 60
  for d in ${DISPLAYS:-1}; do snap "$udid" "shots/fleet-queue-done-screen$d.png" --display="$d" && echo "shot fleet-queue-done (screen $d)"; done
  # the Print panel while the U1 prints: its camera shows on the panel
  debug U1 Coasters
  WAIT=22 shot fleet "$udid" print-panel -DuoDemo YES -DuoDemoPrinter snapmaker-u1 -DuoDemoPrinters "$PR" -DuoDemoPanel print
  { echo "== what the stand-ins saw"; grep -E "listen|login|upload|print |start |RTSP (PLAY|frame)|camera frame" shots/fleet-stand-ins.txt | head -80; } >> "$P"
  sudo pkill -f "[f]ake_printers.py" 2>/dev/null
  ;;
esac
