#!/bin/bash
# Build universal artifacts. Optional Developer ID, notarization and signed Sparkle feed.
# See docs/DISTRIBUTION.md. Existing artifacts are never overwritten.
set -euo pipefail
APP="iSnap"
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "Sources/$APP/Resources/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "Sources/$APP/Resources/Info.plist")
SOURCE_COMMIT=$(git rev-parse HEAD)
DIRTY=$(git status --porcelain | wc -l | tr -d ' ')
IDENTITY=${ISNAP_SIGN_IDENTITY:--}
NOTARY=${ISNAP_NOTARY_PROFILE:-}
PUBLIC_KEY=${ISNAP_UPDATE_PUBLIC_KEY:-}
FEED_URL=${ISNAP_UPDATE_FEED_URL:-https://github.com/Vhaooforjob/isnap/releases/latest/download/appcast.xml}
OUT=${ISNAP_RELEASE_OUTPUT:-dist}
NAME="$APP-$VERSION-macOS-universal"
if [[ -n "$NOTARY" && "$IDENTITY" == "-" ]]; then
  echo "Notarization requires ISNAP_SIGN_IDENTITY (Developer ID Application)." >&2; exit 1
fi
if [[ -n "$PUBLIC_KEY" && ( "$IDENTITY" == "-" || -z "$NOTARY" ) ]]; then
  echo "Automatic updates require Developer ID signing and notarization in this pipeline." >&2; exit 1
fi
for path in "$OUT/$NAME.zip" "$OUT/$NAME.dmg" "$OUT/$NAME-SHA256SUMS.txt" "$OUT/appcast.xml"; do
  if [[ -e "$path" ]]; then echo "Artifact exists: $path. Select a fresh ISNAP_RELEASE_OUTPUT directory." >&2; exit 1; fi
done
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/isnap-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
DERIVED="$WORK/DerivedData"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
xcodegen generate
xcodebuild -project "$APP.xcodeproj" -scheme "$APP" -configuration Release \
  -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > "$WORK/build.log" 2>&1 || { tail -80 "$WORK/build.log"; exit 1; }
ditto "$DERIVED/Build/Products/Release/$APP.app" "$STAGE/$APP.app"
RESOURCES="$STAGE/$APP.app/Contents/Resources"
cp LICENSE THIRD_PARTY_NOTICES.md "$RESOURCES/"
cp "$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/LICENSE" "$RESOURCES/Sparkle-LICENSE"
cat > "$RESOURCES/BUILD_INFO.txt" <<INFO
iSnap $VERSION (build $BUILD)
Source commit: $SOURCE_COMMIT
Uncommitted paths at build start: $DIRTY
Architectures: arm64, x86_64
Signing identity: $IDENTITY
INFO
if [[ -n "$PUBLIC_KEY" ]]; then
  KEY_TOOL="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
  ACTUAL_KEY=$("$KEY_TOOL" -p)
  [[ "$ACTUAL_KEY" == "$PUBLIC_KEY" ]] || { echo "Configured public key does not match the signing keychain." >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$STAGE/$APP.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$STAGE/$APP.app/Contents/Info.plist"
fi
SIGN=(--force --options runtime --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGN+=(--timestamp); fi
# Re-sign nested Sparkle tools and services inside-out, preserving their required entitlements.
FRAMEWORK="$STAGE/$APP.app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FRAMEWORK" ]]; then
  while IFS= read -r -d '' nested; do
    codesign "${SIGN[@]}" --preserve-metadata=entitlements "$nested"
  done < <(find "$FRAMEWORK/Versions" -depth \( -name '*.xpc' -o -name '*.app' -o -name Autoupdate \) -print0)
  codesign "${SIGN[@]}" "$FRAMEWORK"
fi
for appex in "$STAGE/$APP.app"/Contents/PlugIns/*.appex; do
  [[ -e "$appex" ]] || continue
  ext=$(basename "$appex" .appex)
  codesign "${SIGN[@]}" --entitlements "Sources/$ext/$ext.entitlements" "$appex"
done
cp "Sources/$APP/Resources/$APP.entitlements" "$WORK/app.entitlements"
if [[ "$IDENTITY" == "-" ]]; then
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$WORK/app.entitlements"
fi
codesign "${SIGN[@]}" --entitlements "$WORK/app.entitlements" "$STAGE/$APP.app"
codesign --verify --deep --strict "$STAGE/$APP.app"
for binary in "$STAGE/$APP.app/Contents/MacOS/$APP" "$STAGE/$APP.app/Contents/PlugIns/iSnapWidget.appex/Contents/MacOS/iSnapWidget"; do
  ARCHITECTURES=$(lipo -archs "$binary")
  for arch in arm64 x86_64; do
    case " $ARCHITECTURES " in *" $arch "*) ;; *) echo "Missing $arch in $binary" >&2; exit 1 ;; esac
  done
done
if [[ -n "$NOTARY" ]]; then
  ditto -c -k --keepParent "$STAGE/$APP.app" "$WORK/notarize.zip"
  xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$STAGE/$APP.app"
  xcrun stapler validate "$STAGE/$APP.app"
  spctl --assess --type execute --verbose "$STAGE/$APP.app"
fi
ditto -c -k --keepParent "$STAGE/$APP.app" "$OUT/$NAME.zip"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP $VERSION" -srcfolder "$STAGE" -format UDZO "$OUT/$NAME.dmg" >/dev/null
if [[ -n "$NOTARY" ]]; then
  codesign "${SIGN[@]}" "$OUT/$NAME.dmg"
  xcrun notarytool submit "$OUT/$NAME.dmg" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$OUT/$NAME.dmg"
fi
hdiutil verify "$OUT/$NAME.dmg" >/dev/null
unzip -tq "$OUT/$NAME.zip"
if [[ -n "$PUBLIC_KEY" ]]; then
  TOOL="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
  [[ -x "$TOOL" ]] || { echo "Sparkle generate_appcast tool unavailable." >&2; exit 1; }
  mkdir "$WORK/feed"; cp "$OUT/$NAME.zip" "$WORK/feed/"
  "$TOOL" --download-url-prefix "https://github.com/Vhaooforjob/isnap/releases/download/v$VERSION/" "$WORK/feed"
  cp "$WORK/feed/appcast.xml" "$OUT/appcast.xml"
fi
(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > "$NAME-SHA256SUMS.txt" && shasum -a 256 -c "$NAME-SHA256SUMS.txt")
echo "Artifacts prepared in $OUT. Nothing has been published or installed."
