#!/bin/bash
# Makes a made-up site for screenshots and demos: the theme gallery's sample site ("Field Notes", invented posts and
# photos) with a theme applied, as a git repository whose origin is a local bare repository instead of GitHub.
#   scripts/make-demo-site.sh [theme id]   (default: essayist; build the app first with scripts/build.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${INKWELL_BUILD_CACHE:-$HOME/Library/Caches/InkwellBuild}"
APP="$CACHE/DerivedData/Build/Products/Debug/Inkwell.app"
DEST="$CACHE/demo-site"
REMOTE="$CACHE/demo-remote.git"
rm -rf "$DEST" "$REMOTE"
OUT=$(mktemp)
open -n -W --stdout "$OUT" "$APP" --args --make-demo-site "$DEST" --demo-theme "${1:-essayist}"
[ -d "$DEST" ] || { cat "$OUT" >&2; rm -f "$OUT"; exit 1; }
rm -f "$OUT"
git -C "$DEST" init --quiet -b main
git -C "$DEST" config user.name "Inkwell Demo"
git -C "$DEST" config user.email "demo@example.invalid"
git -C "$DEST" add -A
git -C "$DEST" commit --quiet -m "Field Notes, a made-up site"
git init --quiet --bare -b main "$REMOTE"
git -C "$DEST" remote add origin "$REMOTE"
git -C "$DEST" push --quiet -u origin main
echo "$DEST"
