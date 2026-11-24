#!/bin/bash
# Downloads the pinned dart-sass (used by the preview to compile SCSS themes) into the build cache and checks its SHA-256.
# The Xcode build copies it into the app (scripts/bundle-engines.sh). No other third-party code is bundled.
set -euo pipefail
CACHE="${INKWELL_BUILD_CACHE:-$HOME/Library/Caches/InkwellBuild}"
SASS_VERSION="1.108.2"
SASS_SHA256="95b1bbb13f0b38ba8aacefae45ef23f11271231d24fb57b1593c9e2adf65481c"
NAME="dart-sass-$SASS_VERSION-macos-arm64.tar.gz"
DEST="$CACHE/engines/dart-sass-$SASS_VERSION"
if [ -x "$DEST/dart-sass/sass" ]; then echo "$DEST"; exit 0; fi
mkdir -p "$CACHE/engines/download"
ARCHIVE="$CACHE/engines/download/$NAME"
if [ ! -f "$ARCHIVE" ] || ! echo "$SASS_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl -fL --retry 3 -o "$ARCHIVE" "https://github.com/sass/dart-sass/releases/download/$SASS_VERSION/$NAME"
fi
echo "$SASS_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null || { echo "dart-sass checksum mismatch" >&2; exit 1; }
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$ARCHIVE" -C "$DEST"
"$DEST/dart-sass/sass" --version >/dev/null
echo "$DEST"
