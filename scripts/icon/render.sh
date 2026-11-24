#!/bin/bash
# Renders AppIcon.icon in every appearance with Icon Composer's ictool and builds a contact sheet.
#   scripts/icon/render.sh [icon] [out dir]
set -euo pipefail
cd "$(dirname "$0")/../.."
ICON="${1:-Inkwell/Resources/AppIcon.icon}"
OUT="${2:-$HOME/Library/Caches/InkwellBuild/icon}"
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
mkdir -p "$OUT"
for r in Default Dark ClearLight ClearDark TintedLight TintedDark; do
  "$IC" "$ICON" --export-image --output-file "$OUT/$r.png" --platform macOS --rendition "$r" --width 1024 --height 1024 --scale 1 >/dev/null
done
swift scripts/icon/contact.swift "$OUT/contact.png" "$OUT"
echo "$OUT/contact.png"
