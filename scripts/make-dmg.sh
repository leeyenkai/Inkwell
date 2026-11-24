#!/bin/bash
# Builds the Release app and packs it into a disk image with an Applications link and first-launch notes.
# Writes Inkwell-<version>.dmg and its .sha256 to ~/Library/Caches/InkwellBuild/release (outside iCloud).
# The app is ad-hoc signed, not notarized: macOS asks people to allow it once (see the README).
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${INKWELL_BUILD_CACHE:-$HOME/Library/Caches/InkwellBuild}"
OUT="$CACHE/release"

scripts/fetch-engines.sh >/dev/null
log=$(scripts/build.sh Release)
echo "$log" | grep -E "error:" && exit 1
APP=$(echo "$log" | tail -1)
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }
[ -x "$APP/Contents/Resources/dart-sass/sass" ] || { echo "dart-sass is missing from the app" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="$OUT/stage"
DMG="$OUT/Inkwell-$VERSION.dmg"
rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Inkwell.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/If Inkwell does not open.txt" <<EOF
Inkwell $VERSION is not notarized by Apple yet, so macOS asks before opening it the first time.

1. Drag Inkwell into Applications.
2. Open it. When macOS says it cannot check the app, click Done.
3. Open System Settings > Privacy & Security, scroll down, and click Open Anyway next to Inkwell.
4. Confirm with Open Anyway.

You only do this once per version.
EOF

hdiutil create -quiet -volname "Inkwell $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
rm -rf "$STAGE"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG"
cat "$DMG.sha256"
