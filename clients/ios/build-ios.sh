#!/bin/bash
# Build the iOS app and its keyboard extension.
#
# Everything the app needs beyond Swift is an XCFramework: whisper.cpp and the
# Rust core. That keeps Package.swift free of platform-specific linker flags --
# SwiftPM refuses `unsafeFlags` in a package consumed as a dependency, which an
# Xcode project's local package reference is.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
WHISPER=$ROOT/m0/whisper.cpp
FRAMEWORKS=$ROOT/clients/Frameworks

echo "==> rust core for iOS"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim >/dev/null 2>&1 || true
for t in "" "--target aarch64-apple-ios" "--target aarch64-apple-ios-sim"; do
  (cd "$ROOT" && cargo build --release -p openflow-ffi $t >/dev/null)
done

echo "==> OpenFlowFFI.xcframework"
rm -rf "$FRAMEWORKS/OpenFlowFFI.xcframework"
mkdir -p "$FRAMEWORKS"
xcodebuild -create-xcframework \
  -library "$ROOT/target/release/libopenflow_ffi.a"                  -headers "$ROOT/crates/openflow-ffi/include" \
  -library "$ROOT/target/aarch64-apple-ios/release/libopenflow_ffi.a" -headers "$ROOT/crates/openflow-ffi/include" \
  -library "$ROOT/target/aarch64-apple-ios-sim/release/libopenflow_ffi.a" -headers "$ROOT/crates/openflow-ffi/include" \
  -output "$FRAMEWORKS/OpenFlowFFI.xcframework" >/dev/null

if [ ! -d "$FRAMEWORKS/whisper.xcframework" ]; then
  echo "==> whisper.xcframework (slow: builds ggml for every slice)"
  (cd "$WHISPER" && ./build-xcframework.sh >/dev/null 2>&1)
  cp -R "$WHISPER/build-apple/whisper.xcframework" "$FRAMEWORKS/" 2>/dev/null \
    || { echo "   whisper.xcframework not produced; see $WHISPER/build-apple"; exit 1; }
fi

# The model is bundled, not downloaded on first run. A dictation app that
# cannot dictate until it has fetched 141 MB is broken on a plane, which is
# exactly where this gets used. base.en rather than small.en: 141 MB against
# 466 MB matters a great deal for a phone download, and vocabulary biasing
# (spec §5.2) recovers most of what base.en gives up on proper nouns.
MODEL=ggml-base.en.bin
mkdir -p Resources
if [ ! -f "Resources/$MODEL" ]; then
  if [ -f "$WHISPER/models/$MODEL" ]; then
    echo "==> bundling $MODEL"
    cp "$WHISPER/models/$MODEL" "Resources/$MODEL"
  else
    echo "==> downloading $MODEL (141 MB, once)"
    (cd "$WHISPER" && sh ./models/download-ggml-model.sh base.en >/dev/null 2>&1)
    cp "$WHISPER/models/$MODEL" "Resources/$MODEL"
  fi
fi

echo "==> generating Xcode project"
xcodegen generate --quiet

# Installing on a phone is a different build from the simulator one: it has to
# be signed, and a signed build needs a team. Everything before this point is
# shared, so the device path only diverges here.
if [ "${1:-}" = "--device" ]; then
  : "${TEAM_ID:?set TEAM_ID to your 10-character Apple Developer team id (Xcode > Settings > Accounts > Manage Certificates, or the Membership page)}"

  # Whichever iPhone is plugged in, unless DEVICE_UDID names one.
  DEVJSON=$(mktemp -t openflow-devices)
  trap 'rm -f "$DEVJSON"' EXIT
  UDID=${DEVICE_UDID:-$(xcrun devicectl list devices -j "$DEVJSON" >/dev/null 2>&1 && python3 -c "
import json,sys
for d in json.load(open(sys.argv[1]))['result']['devices']:
    if d.get('connectionProperties',{}).get('pairingState') == 'paired':
        print(d['hardwareProperties']['udid']); raise SystemExit
" "$DEVJSON")}
  [ -n "$UDID" ] || { echo "no paired device found. Unlock the phone, tap Trust, and enable
Settings > Privacy & Security > Developer Mode."; exit 1; }

  echo "==> building for device $UDID"
  xcodebuild -project OpenFlowIOS.xcodeproj -scheme OpenFlow \
    -destination "generic/platform=iOS" \
    -derivedDataPath build \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates 2>&1 \
    | grep -E "error:|BUILD" | head -30

  APP=build/Build/Products/Debug-iphoneos/OpenFlow.app
  [ -d "$APP" ] || { echo "build produced no app"; exit 1; }

  echo "==> installing"
  xcrun devicectl device install app --device "$UDID" "$APP"
  echo "==> launching"
  xcrun devicectl device process launch --device "$UDID" dev.openflow.ios
  echo
  echo "Installed. For the keyboard: Settings > General > Keyboard > Keyboards >"
  echo "Add New Keyboard > OpenFlow, then tap it and turn on Allow Full Access."
  exit 0
fi

echo "==> building"
xcodebuild -project OpenFlowIOS.xcodeproj -scheme OpenFlow \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|warning: .*deprecated|BUILD" | head -30

if [ "${1:-}" = "--run" ]; then
  DEVICE=${SIM_DEVICE:-iPhone 17 Pro}
  echo "==> booting $DEVICE"
  UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
name = sys.argv[1]
for _, devs in json.load(sys.stdin)['devices'].items():
    for d in devs:
        if d['name'] == name:
            print(d['udid']); raise SystemExit
" "$DEVICE")
  [ -n "$UDID" ] || { echo "no simulator named '$DEVICE'"; exit 1; }
  xcrun simctl boot "$UDID" 2>/dev/null || true
  open -a Simulator
  APP=build/Build/Products/Debug-iphonesimulator/OpenFlow.app
  xcrun simctl uninstall "$UDID" dev.openflow.ios >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl launch "$UDID" dev.openflow.ios
  echo
  echo "Running. The simulator uses your Mac's microphone -- macOS will ask"
  echo "Simulator for permission the first time you record."
  exit 0
fi

echo
echo "Open with:  open $(pwd)/OpenFlowIOS.xcodeproj"
echo "Or run in the simulator:  ./build-ios.sh --run"
echo "Or on a plugged-in iPhone:  TEAM_ID=ABCDE12345 ./build-ios.sh --device"
echo
echo "Before it will run on a device you must set your team in Xcode"
echo "(Signing & Capabilities) for BOTH targets, and keep the App Group"
echo "'group.dev.openflow' enabled on each -- the handoff is a shared"
echo "container, so a mismatch silently breaks it."
