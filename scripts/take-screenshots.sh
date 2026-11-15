#!/usr/bin/env bash
# Captures App Store screenshots from the simulators using the Debug-only
# demo mode (see App/Shared/ScreenshotDemo.swift): fixed sample numbers,
# no network test, no real IP address.
#
#   scripts/take-screenshots.sh            # iPhone, iPad and Apple TV
#   scripts/take-screenshots.sh iphone     # just one
#   scripts/take-screenshots.sh mac        # needs Screen Recording permission
#                                          # for your terminal app
#
# Output: AppStore/screenshots/<device>/NN-<scene>-<appearance>.png
# Override simulator names with IPHONE=…, IPAD=…, TV=… if yours differ.
set -euo pipefail
cd "$(dirname "$0")/.."

IPHONE="${IPHONE:-iPhone 18 Pro Max}"   # 6.9" display, 1320 x 2868
IPAD="${IPAD:-iPad Pro 13-inch (M5)}"   # 13" display, 2064 x 2752
TV="${TV:-Apple TV 4K (4th generation)}" # 3840 x 2160
DERIVED=.build/screenshots
OUT=AppStore/screenshots
targets=("${@:-iphone ipad tv}")
targets=(${targets[*]})

udid_for() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in sorted(json.load(sys.stdin)["devices"].items(), reverse=True):
    for d in devices:
        if d["name"] == name:
            print(d["udid"]); sys.exit()
sys.exit(f"No available simulator named {name!r}")' "$1"
}

build() { # scheme platform udid
  xcodegen generate -q
  xcodebuild -quiet -scheme "$1" -configuration Debug \
    -destination "platform=$2 Simulator,id=$3" -derivedDataPath "$DERIVED" build
}

boot() { # udid
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
}

shoot() { # udid bundle-id app-path out-dir index scene appearance
  local udid=$1 bundle=$2 out=$4/$(printf %02d "$5")-$6-$7.png
  xcrun simctl ui "$udid" appearance "$7" 2>/dev/null || true # unsupported on tvOS
  xcrun simctl launch --terminate-running-process "$udid" "$bundle" -demo "$6" >/dev/null
  sleep 6 # map tiles, sheet animation
  xcrun simctl io "$udid" screenshot --type=png "$out" >/dev/null
  echo "  $out"
}

ios_device() { # label simulator-name last-scene
  local udid; udid=$(udid_for "$2")
  echo "$1 ($2)"
  boot "$udid"
  build CFSpeed iOS "$udid"
  xcrun simctl install "$udid" "$DERIVED/Build/Products/Debug-iphonesimulator/Edge Speed.app"
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  mkdir -p "$OUT/$1"; rm -f "$OUT/$1"/*.png
  shoot "$udid" me.aashishvanand.speed - "$OUT/$1" 1 result light
  shoot "$udid" me.aashishvanand.speed - "$OUT/$1" 2 download light
  shoot "$udid" me.aashishvanand.speed - "$OUT/$1" 3 history light
  shoot "$udid" me.aashishvanand.speed - "$OUT/$1" 4 "$3" dark
  xcrun simctl status_bar "$udid" clear
  xcrun simctl ui "$udid" appearance light
}

tv_device() {
  local udid; udid=$(udid_for "$TV")
  echo "appletv ($TV)"
  boot "$udid"
  build CFSpeed-tvOS tvOS "$udid"
  xcrun simctl install "$udid" "$DERIVED/Build/Products/Debug-appletvsimulator/Edge Speed.app"
  mkdir -p "$OUT/appletv"; rm -f "$OUT/appletv"/*.png
  # tvOS is dark-first; the light gradient reads poorly on a TV.
  shoot "$udid" me.aashishvanand.speed - "$OUT/appletv" 1 result dark
  shoot "$udid" me.aashishvanand.speed - "$OUT/appletv" 2 download dark
}

mac() {
  echo "mac"
  xcodegen generate -q
  # Ad-hoc signed: a screenshot build needs no Mac Development certificate.
  xcodebuild -quiet -scheme CFSpeed-macOS -configuration Debug -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
  local app="$DERIVED/Build/Products/Debug/Edge Speed.app" raw
  raw=$(mktemp -d)
  mkdir -p "$OUT/mac"; rm -f "$OUT/mac"/*.png
  local i=1
  for scene in result download history; do
    pkill -x "Edge Speed" 2>/dev/null || true
    open -n "$app" --args -demo "$scene"
    sleep 6
    local id; id=$(swift scripts/window-id.swift "Edge Speed")
    screencapture -o -x -l "$id" "$raw/$scene.png"
    swift scripts/frame-mac-screenshot.swift "$raw/$scene.png" "$OUT/mac/0$i-$scene.png"
    echo "  $OUT/mac/0$i-$scene.png"
    i=$((i + 1))
  done
  pkill -x "Edge Speed" 2>/dev/null || true
}

for t in "${targets[@]}"; do
  case $t in
    iphone) ios_device iphone "$IPHONE" details ;;
    ipad) ios_device ipad "$IPAD" result ;; # two columns: everything fits
    tv) tv_device ;;
    mac) mac ;;
    *) echo "Unknown target $t (iphone, ipad, tv, mac)" >&2; exit 1 ;;
  esac
done
