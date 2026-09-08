#!/bin/bash
# Archive and upload to TestFlight.
#
#   TEAM_ID=ABCDE12345 ./release-ios.sh              # archive + export
#   TEAM_ID=... ASC_KEY_ID=... ASC_ISSUER_ID=... ./release-ios.sh --upload
#
# The App Store Connect API key (a .p8) must be in ~/.appstoreconnect/private_keys/
set -euo pipefail
cd "$(dirname "$0")"

: "${TEAM_ID:?set TEAM_ID to your 10-character Apple Developer team id (Membership page)}"
UPLOAD=${1:-}
ARCHIVE=build/OpenFlow.xcarchive
EXPORT=build/export

# TestFlight rejects a build number it has already seen, so bump every time.
BUILD_NUMBER=$(date +%Y%m%d%H%M)

./build-ios.sh >/dev/null

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

echo "==> archiving (build $BUILD_NUMBER)"
xcodebuild archive \
  -project OpenFlowIOS.xcodeproj -scheme OpenFlow \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates 2>&1 | grep -E "error:|ARCHIVE SUCCEEDED|ARCHIVE FAILED" | head -20

echo "==> exporting .ipa"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates 2>&1 | grep -E "error:|EXPORT SUCCEEDED|EXPORT FAILED" | head -20

IPA=$(find "$EXPORT" -name '*.ipa' | head -1)
echo "built: $IPA  ($(du -h "$IPA" | cut -f1))"

if [ "$UPLOAD" = "--upload" ]; then
  : "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect > Users and Access > Integrations)}"
  : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
  echo "==> uploading to TestFlight"
  xcrun altool --upload-app -f "$IPA" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "Uploaded. Processing takes 5-15 minutes before it appears in TestFlight."
else
  echo
  echo "To upload:  TEAM_ID=$TEAM_ID ASC_KEY_ID=... ASC_ISSUER_ID=... ./release-ios.sh --upload"
  echo "Or open $ARCHIVE in Xcode's Organizer and use Distribute App."
fi
