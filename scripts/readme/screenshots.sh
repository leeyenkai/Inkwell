#!/bin/bash
# Takes the README screenshots from the made-up demo site (scripts/make-demo-site.sh: invented posts and photos), so no
# real site's words appear. Needs a Debug build and Screen Recording permission for the terminal that runs it.
set -euo pipefail
cd "$(dirname "$0")/../.."
CACHE="${INKWELL_BUILD_CACHE:-$HOME/Library/Caches/InkwellBuild}"
APP="$CACHE/DerivedData/Build/Products/Debug/Inkwell.app"
SITE=$(./scripts/make-demo-site.sh "${1:-essayist}")
OUT=docs/images
TMP=$(mktemp -d)
DRAFTS="$HOME/Library/Application Support/Inkwell/Drafts"
rm -rf "$DRAFTS"/demo-site-*

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
DRAFT_ARGS=(--section posts --new-draft "Writing without the terminal" --draft-body "$CACHE/readme-draft.md")
shot main window --fresh --section posts --open _posts/2026-10-28-the-long-way-round-the-headland.md --preview
# The draft's picture arrives with the draft, so the publish sheet shows it going out with the post.
swift scripts/readme/dusk.swift "$SITE/assets/images/writing-without-the-terminal-dusk.jpg"
shot draft window --fresh "${DRAFT_ARGS[@]}" --preview
DRAFT_PATH="_posts/$(date +%Y-%m-%d)-writing-without-the-terminal.md"
shot publish sheet --fresh --section posts --open "$DRAFT_PATH" --publish-sheet
shot design window --fresh --pane design
shot source window --fresh --section posts --open _posts/2026-09-21-above-the-snow-line.md --source
pkill -x Inkwell 2>/dev/null || true
rm -rf "$DRAFTS"/demo-site-* "$TMP" "$CACHE/readme-draft.md"
