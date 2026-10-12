#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/wavesearch-refinement-policy-check"
cd "$ROOT"
# Queue selection uses the portable core; allow checks against a fresh library.
KIT="macos/WaveSearch/WaveSearch/WaveSearchKit.xcframework/macos-arm64_x86_64"
CORE_LIBRARY="${WS_CORE_LIBRARY:-$KIT/libwavesearch.a}"
CORE_HEADERS="${WS_CORE_HEADERS:-$KIT/Headers}"
if [[ -n "${WS_CORE_LIBRARY:-}" && -z "${WS_CORE_HEADERS:-}" ]]; then CORE_HEADERS="$ROOT/core/include"; fi
swiftc \
  -I "$CORE_HEADERS" "$CORE_LIBRARY" \
  macos/WaveSearch/WaveSearch/RefinementPolicy.swift \
  macos/WaveSearch/Tools/RefinementPolicyCheck.swift \
  -o "$OUTPUT"
"$OUTPUT"
