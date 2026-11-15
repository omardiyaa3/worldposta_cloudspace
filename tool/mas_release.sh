#!/bin/bash
# Mac App Store package: build, sign for the store, wrap in a signed .pkg and
# (with UPLOAD=1) send it to App Store Connect.
#   tool/mas_release.sh <out-dir>
# Needs the "Posta Drive Mac App Store" profile, the Apple Distribution and
# 3rd Party Mac Developer Installer certificates, and the team's API key.
set -euo pipefail
OUT=$1; TEAM=KK574HP56Q; KEY=QNXU3YX684; ISSUER=15936440-2172-498a-b49a-d56a49b6aadc
ORG="WORLDPOSTA CLOUD SERVICE & DATACENTERS PROVIDERS CO. L.L.C ($TEAM)"
PROFILE=~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/1966d251-133e-4efc-8814-2a977f2a9a0f.provisionprofile
mkdir -p "$OUT"
flutter build macos --release > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; exit 1; }
APP="$OUT/Posta Drive.app"
rm -rf "$APP"; ditto "build/macos/Build/Products/Release/Posta Drive.app" "$APP"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

ENT="$OUT/app.entitlements"
cp macos/Runner/Release.entitlements "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.com.worldposta.cloudspace" "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENT"
# Drive file links open the app (App Store build only: the DMG has no
# provisioning profile, and this entitlement needs one).
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.associated-domains array" \
  -c "Add :com.apple.developer.associated-domains:0 string applinks:drive.worldposta.com" "$ENT"

SIGN="Apple Distribution: $ORG"
find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
  xargs -0 -I{} codesign --force --sign "$SIGN" --timestamp "{}"
codesign --force --sign "$SIGN" --timestamp --entitlements "$ENT" "$APP"
codesign --verify --deep --strict "$APP"

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
PKG="$OUT/PostaDrive-$VER-$BUILD.pkg"
productbuild --component "$APP" /Applications --sign "3rd Party Mac Developer Installer: $ORG" "$PKG"
echo "built $PKG"
[ -n "${UPLOAD:-}" ] && xcrun altool --upload-app -t macos -f "$PKG" --apiKey "$KEY" --apiIssuer "$ISSUER"
