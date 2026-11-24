#!/bin/bash
# Takes the README screenshots from a throwaway copy of the site (scripts/make-sample-site.sh), never the real one.
# Needs Screen Recording permission for the terminal that runs it.
set -euo pipefail
cd "$(dirname "$0")/../.."
CACHE="${INKWELL_BUILD_CACHE:-$HOME/Library/Caches/InkwellBuild}"
APP="$CACHE/DerivedData/Build/Products/Debug/Inkwell.app"
SITE=$(./scripts/make-sample-site.sh "${1:-$HOME/Desktop/leeyenkai.github.io}")
OUT=docs/images
TMP=$(mktemp -d)
swift scripts/readme/dusk.swift "$SITE/assets/images/writing-without-the-terminal-dusk.jpg"
DRAFTS="$HOME/Library/Application Support/Inkwell/Drafts"
rm -rf "$DRAFTS"/sample-site-*

window() {
  cat > "$TMP/win.swift" <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Inkwell" && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    print(w[kCGWindowNumber as String]!, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
    break
}
SWIFT
  swift "$TMP/win.swift"
}

shot() {
  local name="$1" mode="$2"; shift 2
  pkill -x Inkwell 2>/dev/null || true
  sleep 1
  open -n "$APP" --args --site "$SITE" "$@"
  local found=""
  for _ in $(seq 1 20); do
    sleep 1
    found=$(window)
    [ -n "$found" ] && break
  done
  [ -n "$found" ] || { echo "No Inkwell window for $name" >&2; return 1; }
  sleep 3
  read -r id _ < <(window)
  # The front-most window is the sheet when one is open, so "sheet" and "window" capture the same way.
  screencapture -x -o -l"$id" "$TMP/$name.png"
  sips -Z 1600 "$TMP/$name.png" --out "$OUT/$name.png" >/dev/null
  echo "$OUT/$name.png"
}

# The app reads the body from the cache: the project folder may be in a privacy-protected place such as the Desktop.
cp scripts/readme/draft.md "$CACHE/readme-draft.md"
DRAFT_ARGS=(--section notes --new-draft "Writing without the terminal" --draft-body "$CACHE/readme-draft.md")
shot main window --section notes --open _notes/2026-06-20-morality.md --preview
shot draft window "${DRAFT_ARGS[@]}" --preview
DRAFT_PATH="_notes/$(date +%Y-%m-%d)-writing-without-the-terminal.md"
shot publish sheet --section notes --open "$DRAFT_PATH" --publish-sheet
shot sidenotes window --section sidenotes --open _sidenotes/2026-03-28-romney.md --preview
shot source window --section notes --open _notes/2025-12-01-estonia.md --source
pkill -x Inkwell 2>/dev/null || true
rm -rf "$DRAFTS"/sample-site-* "$TMP" "$CACHE/readme-draft.md"
