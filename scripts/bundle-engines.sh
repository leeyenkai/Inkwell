#!/bin/bash
# Xcode build phase: copies the fetched dart-sass into Inkwell.app/Contents/Resources/dart-sass.
set -euo pipefail
CACHE="${INKWELL_BUILD_CACHE:-$HOME/Library/Caches/InkwellBuild}"
SRC=$(ls -d "$CACHE"/engines/dart-sass-*/dart-sass 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$SRC" ]; then
  echo "warning: dart-sass not fetched; run scripts/fetch-engines.sh. SCSS themes will preview without styles."
  exit 0
fi
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/dart-sass"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
