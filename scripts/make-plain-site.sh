#!/bin/bash
# Makes a throwaway hand-built website for running and testing Inkwell (SPEC §4.12): a code repository whose site is
# plain HTML in docs/ with .nojekyll, and a local bare repository as its origin instead of GitHub.
#   scripts/make-plain-site.sh   (prints the repository folder; open it with --site)
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${INKWELL_BUILD_CACHE:-$HOME/Library/Caches/InkwellBuild}"
DEST="$CACHE/plain-site"
REMOTE="$CACHE/plain-remote.git"
rm -rf "$DEST" "$REMOTE"
mkdir -p "$DEST/docs"
cp -R InkwellKit/Tests/Fixtures/plain-site/. "$DEST/docs/"
printf '# Plain Product\n\nA program whose website is in docs/.\n' > "$DEST/README.md"
git -C "$DEST" init --quiet -b main
git -C "$DEST" config user.name "Inkwell Sample"
git -C "$DEST" config user.email "sample@example.invalid"
git -C "$DEST" add -A
git -C "$DEST" commit --quiet -m "A program with a hand-built website"
git init --quiet --bare -b main "$REMOTE"
git -C "$DEST" remote add origin "$REMOTE"
git -C "$DEST" push --quiet -u origin main
echo "$DEST"
