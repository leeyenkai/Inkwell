#!/bin/bash
# Makes a throwaway copy of a site for running and testing Inkwell, so the real site is never written to.
# The copy is a fresh clone whose origin is a local bare repository instead of GitHub.
#   scripts/make-sample-site.sh [site folder]   (default: ~/Desktop/leeyenkai.github.io)
set -euo pipefail
SRC="${1:-$HOME/Desktop/leeyenkai.github.io}"
CACHE="${INKWELL_BUILD_CACHE:-$HOME/Library/Caches/InkwellBuild}"
DEST="$CACHE/sample-site"
REMOTE="$CACHE/sample-remote.git"
rm -rf "$DEST" "$REMOTE"
mkdir -p "$CACHE"
git clone --quiet --no-hardlinks "$SRC" "$DEST"
git init --quiet --bare -b main "$REMOTE"
git -C "$DEST" remote set-url origin "$REMOTE"
git -C "$DEST" push --quiet origin HEAD:main
git -C "$DEST" branch --quiet --set-upstream-to=origin/main 2>/dev/null || true
git -C "$DEST" config user.name "Inkwell Sample"
git -C "$DEST" config user.email "sample@example.invalid"
echo "$DEST"
