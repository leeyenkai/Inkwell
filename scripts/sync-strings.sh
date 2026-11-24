#!/bin/bash
# Builds the package and the app, then updates every string catalog from the strings the compiler found.
# Strings that are no longer used are marked stale. Prints counted strings that still need plural forms.
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${INKWELL_BUILD_CACHE:-$HOME/Library/Caches/InkwellBuild}"

(cd InkwellKit && swift build --scratch-path "$CACHE/spm" 2>&1 | grep -E "error:" || true)
SPM="$CACHE/spm/out/Intermediates.noindex/InkwellKit.build/Debug"
for catalog in InkwellKit/Sources/*/Localizable.xcstrings; do
  module=$(basename "$(dirname "$catalog")")
  data=$(find "$SPM/$module-t.build" -name '*.stringsdata' ! -name 'GeneratedStringSymbols_*' ! -name 'resource_bundle_accessor*')
  # shellcheck disable=SC2046
  xcrun xcstringstool sync "$catalog" $(printf -- '--stringsdata %s ' $data)
done

scripts/build.sh >/dev/null
APP="$CACHE/DerivedData/Build/Intermediates.noindex/Inkwell.build/Debug/Inkwell.build"
data=$(find "$APP" -name '*.stringsdata' ! -name 'GeneratedStringSymbols_*')
# shellcheck disable=SC2046
xcrun xcstringstool sync Inkwell/Resources/Localizable.xcstrings $(printf -- '--stringsdata %s ' $data)

python3 - InkwellKit/Sources/*/Localizable.xcstrings Inkwell/Resources/Localizable.xcstrings <<'EOF'
import json, re, sys
for path in sys.argv[1:]:
    strings = json.load(open(path))["strings"]
    for key, entry in strings.items():
        if entry.get("extractionState") == "stale" or not re.search(r"%(\d\$)?lld", key) or "(inflect: true)" in key:
            continue
        english = entry.get("localizations", {}).get("en", {})
        if "variations" not in english and "substitutions" not in english:
            print(f"{path}: no plural forms for: {key}")
EOF
