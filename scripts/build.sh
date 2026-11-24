#!/bin/bash
# Builds the Debug app outside the iCloud-synced project folder and prints only diagnostics.
set -uo pipefail
cd "$(dirname "$0")/.."
CACHE="${INKWELL_BUILD_CACHE:-$HOME/Library/Caches/InkwellBuild}"
CONFIG="${1:-Debug}"
xcodebuild -project Inkwell.xcodeproj -scheme Inkwell -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$CACHE/DerivedData" build 2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | grep -v "appintentsmetadataprocessor" | sort -u
echo "$CACHE/DerivedData/Build/Products/$CONFIG/Inkwell.app"
