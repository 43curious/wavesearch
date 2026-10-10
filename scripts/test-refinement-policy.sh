#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/wavesearch-refinement-policy-check"
cd "$ROOT"
swiftc \
  macos/WaveSearch/WaveSearch/RefinementPolicy.swift \
  macos/WaveSearch/Tools/RefinementPolicyCheck.swift \
  -o "$OUTPUT"
"$OUTPUT"
