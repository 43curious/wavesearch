#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/wavesearch-localization.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
CONTENTS="$BUILD/LocalizationCheck.app/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$BUILD/keys"
cp -R macos/WaveSearch/WaveSearch/{en,es}.lproj "$CONTENTS/Resources/"
python3 - "$CONTENTS/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as output:
    plistlib.dump({"CFBundleIdentifier": "dev.wavesearch.localization-check", "CFBundleExecutable": "check",
                  "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en"}, output)
PY
KIT="macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework/macos-arm64_x86_64"
CORE_LIBRARY="${WS_CORE_LIBRARY:-$KIT/libwavesearch.a}"
CORE_HEADERS="${WS_CORE_HEADERS:-$KIT/Headers}"
if [[ -n "${WS_CORE_LIBRARY:-}" && -z "${WS_CORE_HEADERS:-}" ]]; then CORE_HEADERS="$PWD/core/include"; fi
SOURCES=()
for file in macos/WaveSearch/WaveSearch/*.swift; do
    [[ "$file" == */WaveSearchApp.swift ]] || SOURCES+=("$file")
done
swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -strict-concurrency=complete -warnings-as-errors \
    -emit-localized-strings -emit-localized-strings-path "$BUILD/keys" \
    -I "$CORE_HEADERS" "$CORE_LIBRARY" -framework IOKit \
    "${SOURCES[@]}" macos/WaveSearch/Tools/LocalizationCheck.swift -o "$CONTENTS/MacOS/check"
# Include the app's scene/menu source in extraction too; it has a separate @main.
swiftc -parse-as-library -typecheck -swift-version 5 -default-isolation MainActor \
    -emit-localized-strings -emit-localized-strings-path "$BUILD/keys" \
    -I "$CORE_HEADERS" "${SOURCES[@]}" macos/WaveSearch/WaveSearch/WaveSearchApp.swift
python3 scripts/check-localizations.py "$BUILD/keys"
"$CONTENTS/MacOS/check" -AppleLanguages '(en)' -AppleLocale en_US
"$CONTENTS/MacOS/check" --spanish -AppleLanguages '(es)' -AppleLocale es_ES
