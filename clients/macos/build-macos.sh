#!/bin/bash
# Build OpenFlow.app. No Xcode project: SwiftPM plus a hand-assembled bundle,
# which keeps the whole thing scriptable and diffable.
set -euo pipefail
cd "$(dirname "$0")"
PKG=$(cd .. && pwd)          # the Swift package root, clients/
ROOT=$(cd ../.. && pwd)      # the repo root
APP=${1:-build/OpenFlow.app}
WHISPER=$ROOT/m0/whisper.cpp

echo "==> rust core"
(cd "$ROOT" && cargo build --release >/dev/null)

WHISPER_REV=52a939a   # pinned; bump deliberately, re-benchmark after

if [ ! -d "$WHISPER/.git" ]; then
  echo "==> fetching whisper.cpp @ $WHISPER_REV"
  rm -rf "$WHISPER"
  git clone https://github.com/ggml-org/whisper.cpp.git "$WHISPER" >/dev/null 2>&1
  (cd "$WHISPER" && git checkout -q "$WHISPER_REV" 2>/dev/null || \
     echo "   (pinned rev unavailable; using default branch)")
fi

MODELS=$WHISPER/models
if [ ! -f "$MODELS/ggml-small.en.bin" ]; then
  echo "==> downloading ggml-small.en (465 MB, once)"
  (cd "$WHISPER" && sh ./models/download-ggml-model.sh small.en >/dev/null 2>&1)
fi

if [ ! -f "$WHISPER/build-static/src/libwhisper.a" ]; then
  echo "==> whisper.cpp (static)"
  cmake -S "$WHISPER" -B "$WHISPER/build-static" -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_TESTS=OFF -DGGML_METAL=ON >/dev/null
  cmake --build "$WHISPER/build-static" -j8 >/dev/null
fi

echo "==> swift"
(cd "$PKG" && swift build -c release 2>&1 | grep -vE "was built for newer|^$") || true

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PKG/.build/release/OpenFlowMac" "$APP/Contents/MacOS/OpenFlow"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>OpenFlow</string>
  <key>CFBundleDisplayName</key>       <string>OpenFlow</string>
  <key>CFBundleIdentifier</key>        <string>dev.openflow.mac</string>
  <key>CFBundleExecutable</key>        <string>OpenFlow</string>
  <key>CFBundleVersion</key>           <string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <!-- menu-bar only: no Dock icon, no window -->
  <key>LSUIElement</key>               <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>OpenFlow transcribes your speech on this Mac. Audio is never uploaded and is discarded after transcription.</string>
</dict>
</plist>
PLIST

# Signing identity. macOS keys the Accessibility grant to the code signature,
# so an ad-hoc signature -- which changes with every build -- means re-granting
# after each rebuild. Use a stable self-signed certificate if one exists.
#
# To create one once (Keychain Access › Certificate Assistant › Create a
# Certificate…, name "OpenFlow Dev", type "Code Signing", self-signed), then
# every later build keeps the same identity and the grant sticks.
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "OpenFlow Dev"; then
  IDENTITY="OpenFlow Dev"
  echo "   signing with the stable 'OpenFlow Dev' identity"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "   (codesign failed; the app runs but permissions may not persist)"
if [ "$IDENTITY" = "-" ]; then
  echo "   ad-hoc signed: macOS will re-ask for Accessibility after each rebuild."
  echo "   See README ('Permissions') to make that stop."
fi

SUPPORT="$HOME/Library/Application Support/OpenFlow"
mkdir -p "$SUPPORT/models"
for m in ggml-small.en.bin ggml-base.en.bin; do
  if [ -f "$WHISPER/models/$m" ] && [ ! -e "$SUPPORT/models/$m" ]; then
    ln -s "$WHISPER/models/$m" "$SUPPORT/models/$m"
    echo "   linked model $m"
  fi
done
if [ -f "$ROOT/m0/vocab.txt" ] && [ ! -e "$SUPPORT/vocab.txt" ]; then
  cp "$ROOT/m0/vocab.txt" "$SUPPORT/vocab.txt"
  echo "   seeded vocab.txt"
fi

echo
echo "built $APP"
echo "  open $APP"
echo
echo "First launch will ask for Microphone and Accessibility permission."
echo "Accessibility is required twice over: to see the hotkey, and to paste."
