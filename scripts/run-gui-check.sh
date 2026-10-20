#!/bin/bash
# Bound even failures before SwiftUI's onAppear/task checks can begin.
set -euo pipefail
python3 - "$@" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(sys.argv[1:], timeout=30)
except subprocess.TimeoutExpired:
    print("FAIL: GUI check did not finish within 30 seconds", file=sys.stderr)
    sys.exit(124)
sys.exit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
PY
