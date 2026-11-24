#!/bin/bash
# Launches the app with arguments and captures one of its windows by title, without touching other Inkwell instances.
#   APP=<path to Inkwell.app> scripts/capture-window.sh <out.png> "<window title>" <app arguments…>
# WAIT (seconds, default 8) is how long the app gets before the capture. The app is quit afterwards.
set -uo pipefail
out=$1; title=$2; shift 2
APP=${APP:-$HOME/Library/Caches/InkwellBuild/DerivedData/Build/Products/Debug/Inkwell.app}
"$APP/Contents/MacOS/Inkwell" "$@" >/dev/null 2>&1 &
pid=$!
sleep "${WAIT:-8}"
id=$(PID=$pid TITLE="$title" swift -e 'import CoreGraphics; import Foundation
let env = ProcessInfo.processInfo.environment
let pid = Int(env["PID"]!)!, title = env["TITLE"]!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (title.isEmpty || (w[kCGWindowName as String] as? String) == title) {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    if (b["Width"] as! Double) > 300 { print(w[kCGWindowNumber as String]!); break }
}')
if [ -n "$id" ]; then screencapture -x -o -l"$id" "$out" && echo "$out"; else echo "no window '$title' for pid $pid" >&2; fi
kill "$pid" 2>/dev/null
