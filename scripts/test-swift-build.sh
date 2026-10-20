#!/bin/bash
# Compile and link every product source without launching Xcode or the app.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/wavesearch-swift-build.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
KIT="macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework/macos-arm64_x86_64"
CORE_LIBRARY="${WS_CORE_LIBRARY:-$KIT/libwavesearch.a}"
CORE_HEADERS="${WS_CORE_HEADERS:-$KIT/Headers}"
if [[ -n "${WS_CORE_LIBRARY:-}" && -z "${WS_CORE_HEADERS:-}" ]]; then CORE_HEADERS="$PWD/core/include"; fi
swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -strict-concurrency=complete -warnings-as-errors \
    -I "$CORE_HEADERS" "$CORE_LIBRARY" -framework IOKit \
    macos/WaveSearch/WaveSearch/*.swift -o "$BUILD/WaveSearch"
echo "PASS: complete Swift source compilation and core linkage (app bundle not built)"
