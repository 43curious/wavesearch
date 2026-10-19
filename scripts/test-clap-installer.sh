#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/wavesearch-installer.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
KIT="macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework/macos-arm64_x86_64"
CORE_LIBRARY="${WS_CORE_LIBRARY:-$KIT/libwavesearch.a}"
CORE_HEADERS="${WS_CORE_HEADERS:-$KIT/Headers}"
if [[ -n "${WS_CORE_LIBRARY:-}" && -z "${WS_CORE_HEADERS:-}" ]]; then CORE_HEADERS="$PWD/core/include"; fi
SOURCES=()
for file in macos/WaveSearch/WaveSearch/*.swift; do
    [[ "$file" == */WaveSearchApp.swift ]] || SOURCES+=("$file")
done
swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -I "$CORE_HEADERS" "$CORE_LIBRARY" -framework IOKit \
    "${SOURCES[@]}" macos/WaveSearch/Tools/CLAPInstallerCheck.swift -o "$BUILD/check"
"$BUILD/check" "$@"
