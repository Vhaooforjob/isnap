#!/bin/bash
# Build an ad-hoc signed universal (arm64 + x86_64) release and package it as .dmg and .zip.
# Usage: scripts/release.sh   (writes to dist/)
set -euo pipefail

APP="iSnap"
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "Sources/$APP/Resources/Info.plist")
DERIVED="build/DerivedDataRelease"
OUT="dist"
STAGE="build/release-stage"
NAME="$APP-$VERSION-macOS-universal"

xcodegen generate
rm -rf "$DERIVED" "$STAGE"
xcodebuild -project "$APP.xcodeproj" -scheme "$APP" -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build | tail -n 5

mkdir -p "$OUT" "$STAGE"
ditto "$DERIVED/Build/Products/Release/$APP.app" "$STAGE/$APP.app"
# Ad-hoc sign inside-out: app extensions first, then the app, each with its own entitlements.
for appex in "$STAGE/$APP.app"/Contents/PlugIns/*.appex; do
  [ -e "$appex" ] || continue
  ext=$(basename "$appex" .appex)
  codesign --force --options runtime --sign - --entitlements "Sources/$ext/$ext.entitlements" "$appex"
done
codesign --force --options runtime --sign - --entitlements "Sources/$APP/Resources/$APP.entitlements" "$STAGE/$APP.app"
codesign --verify --deep --strict "$STAGE/$APP.app"
lipo -archs "$STAGE/$APP.app/Contents/MacOS/$APP"

rm -f "$OUT/$NAME.zip" "$OUT/$NAME.dmg"
ditto -c -k --keepParent "$STAGE/$APP.app" "$OUT/$NAME.zip"

ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg" >/dev/null
(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip")
