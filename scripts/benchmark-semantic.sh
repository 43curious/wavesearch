#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../core"
count="${1:-10000}"
queries="${2:-30}"
k="${3:-20}"
work="$(mktemp -d "${TMPDIR:-/tmp}/wavesearch-semantic.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# One disposable corpus at a time; separate processes for query-only peak RSS.
for distribution in uniform clustered dense; do
    zig build semantic-bench -- create "$work/library.sqlite" "$count" "$distribution"
    zig build semantic-bench -- compare "$work/library.sqlite" "$queries" "$k"
    zig build semantic-bench -- exact "$work/library.sqlite" "$queries" "$k"
    zig build semantic-bench -- auto "$work/library.sqlite" "$queries" "$k"
    zig build semantic-bench -- auto "$work/library.sqlite" "$queries" "$k" 0
    rm -f -- "$work/library.sqlite" "$work/library.sqlite-wal" "$work/library.sqlite-shm"
done
