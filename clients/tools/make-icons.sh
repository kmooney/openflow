#!/bin/bash
# Generate the app icon for every client from one drawing.
#
# `icon.swift` owns the mark; this turns it into the three container formats
# Apple and Windows insist on. Re-run it after changing the drawing and commit
# the results -- they are build inputs, not build outputs, because the Windows
# client is built on Windows where none of this tooling exists.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

draw() { swift icon.swift "$1" "$2" "${3:-light}"; }

echo "==> iOS asset catalogue"
IOS="$ROOT/ios/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$IOS"
draw 1024 "$IOS/icon-1024.png"
draw 1024 "$IOS/icon-1024-dark.png" dark
cat > "$ROOT/ios/Assets.xcassets/Contents.json" <<'JSON'
{ "info": { "author": "xcode", "version": 1 } }
JSON
cat > "$IOS/Contents.json" <<'JSON'
{
  "images": [
    { "filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" },
    {
      "appearances": [{ "appearance": "luminosity", "value": "dark" }],
      "filename": "icon-1024-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"
    }
  ],
  "info": { "author": "xcode", "version": 1 }
}
JSON

echo "==> macOS .icns"
SET="$WORK/OpenFlow.iconset"
mkdir -p "$SET"
# The names are load-bearing: iconutil matches on them exactly.
draw 16   "$SET/icon_16x16.png"
draw 32   "$SET/icon_16x16@2x.png"
draw 32   "$SET/icon_32x32.png"
draw 64   "$SET/icon_32x32@2x.png"
draw 128  "$SET/icon_128x128.png"
draw 256  "$SET/icon_128x128@2x.png"
draw 256  "$SET/icon_256x256.png"
draw 512  "$SET/icon_256x256@2x.png"
draw 512  "$SET/icon_512x512.png"
draw 1024 "$SET/icon_512x512@2x.png"
iconutil -c icns "$SET" -o "$ROOT/macos/OpenFlow.icns"

echo "==> Windows .ico"
for n in 16 32 48 64 128 256; do draw "$n" "$WORK/w$n.png"; done
python3 - "$WORK" "$ROOT/windows/openflow.ico" <<'PY'
import struct, sys, pathlib
work, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sizes = [16, 32, 48, 64, 128, 256]
blobs = [(n, (work / f"w{n}.png").read_bytes()) for n in sizes]

# ICO: a 6-byte header, one 16-byte directory entry per image, then the data.
# The images are stored as PNG rather than BMP -- supported since Vista, and it
# keeps the file a tenth the size.
header = struct.pack("<HHH", 0, 1, len(blobs))
offset = 6 + 16 * len(blobs)
entries, data = b"", b""
for n, blob in blobs:
    # 0 means 256 in this field; it is a single byte and 256 does not fit.
    entries += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(blob), offset)
    offset += len(blob)
    data += blob
out.write_bytes(header + entries + data)
print(f"   {out.name}: {len(sizes)} sizes, {out.stat().st_size // 1024} KB")
PY

echo
echo "Done. Committed as build inputs:"
echo "  ios/Assets.xcassets/AppIcon.appiconset"
echo "  macos/OpenFlow.icns"
echo "  windows/openflow.ico"
