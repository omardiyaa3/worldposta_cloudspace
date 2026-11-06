#!/bin/bash
# Direct-download Mac build: build, sign with Developer ID, wrap in a signed
# DMG, notarize and staple.
#   tool/mac_dmg.sh <out-dir>
# Needs the Developer ID Application certificate and the team's API key.
set -euo pipefail
OUT=$1; TEAM=KK574HP56Q; KEY=QNXU3YX684; ISSUER=15936440-2172-498a-b49a-d56a49b6aadc
SIGN="Developer ID Application: WORLDPOSTA CLOUD SERVICE & DATACENTERS PROVIDERS CO. L.L.C ($TEAM)"
mkdir -p "$OUT"
flutter build macos --release > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; exit 1; }
STAGE="$OUT/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
APP="$STAGE/Posta Drive.app"
ditto "build/macos/Build/Products/Release/Posta Drive.app" "$APP"

find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
  xargs -0 -I{} codesign --force --sign "$SIGN" --options runtime --timestamp "{}"
codesign --force --sign "$SIGN" --options runtime --timestamp --entitlements macos/Runner/Release.entitlements "$APP"
codesign --verify --deep --strict "$APP"
ln -s /Applications "$STAGE/Applications"

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$OUT/PostaDrive-$VER.dmg"
rm -f "$DMG"
hdiutil create -volname "Posta Drive" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
codesign --force --sign "$SIGN" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --key ~/.appstoreconnect/private_keys/AuthKey_$KEY.p8 \
  --key-id "$KEY" --issuer "$ISSUER" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "built $DMG"
