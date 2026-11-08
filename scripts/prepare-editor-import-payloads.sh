#!/bin/bash
# Opt-in only: creates persistent fixture media in WaveSearch/Exports.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 || ! -f "$1/acceptance.json" || -e "$1/payloads.json" ]]; then
    echo "Usage: $0 FIXTURE_DIRECTORY (prepared fixtures; payloads.json must not exist)" >&2
    exit 64
fi
FIXTURE="$(cd "$1" && pwd -P)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/wavesearch-editor-payloads.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
KIT="macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework/macos-arm64_x86_64"
SOURCES=()
for file in macos/WaveSearch/WaveSearch/*.swift; do
    [[ "$file" == */WaveSearchApp.swift ]] || SOURCES+=("$file")
done
swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -strict-concurrency=complete -warnings-as-errors \
    -I "$KIT/Headers" "$KIT/libwavesearch.a" -framework IOKit \
    "${SOURCES[@]}" macos/WaveSearch/Tools/EditorImportPayloads.swift -o "$BUILD/prepare"
"$BUILD/prepare" "$FIXTURE"
