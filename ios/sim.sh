#!/bin/sh
# usage: ios/sim.sh <shot-name> [launch args...]
# Builds Debug for the Simulator, (re)installs, launches with the args, waits $WAIT s (default 5) and saves
# shots/ios/<shot-name>.png (800 px). SIM defaults to the "Roomwell iPhone" simulator. BUILD=0 skips the build.
set -e
cd "$(dirname "$0")"
SIM=${SIM:-$(xcrun simctl list devices | awk -F '[()]' '/Roomwell iPhone/{print $2; exit}')}
xcrun simctl boot "$SIM" 2>/dev/null || true
[ "${BUILD:-1}" = 0 ] || xcodebuild -quiet -project Roomwell.xcodeproj -scheme Roomwell -destination "id=$SIM" -derivedDataPath build build 2>&1 | tail -20
N=$1; shift
xcrun simctl terminate "$SIM" com.borodutch.roomwell 2>/dev/null || true
xcrun simctl install "$SIM" build/Build/Products/Debug-iphonesimulator/Roomwell.app
xcrun simctl launch "$SIM" com.borodutch.roomwell "$@" >/dev/null
sleep "${WAIT:-5}"
mkdir -p shots
xcrun simctl io "$SIM" screenshot "shots/$N-full.png" >/dev/null 2>&1
sips -Z 800 "shots/$N-full.png" --out "shots/$N.png" >/dev/null && rm "shots/$N-full.png"
