#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../core"
count="${1:-10000}"
queries="${2:-30}"
k="${3:-20}"
distribution_arg="${4:-all}"
case "$distribution_arg" in
    all) distributions=(uniform clustered dense) ;;
    uniform|clustered|dense) distributions=("$distribution_arg") ;;
    *) echo "Expected distribution: all, uniform, clustered or dense" >&2; exit 1 ;;
esac
if [[ ! "$count" =~ ^[1-9][0-9]*$ || ! "$queries" =~ ^[1-9][0-9]*$ || ! "$k" =~ ^[1-9][0-9]*$ ]]; then
    echo "Count, queries and K must be positive integers" >&2
    exit 1
fi
updates=1000
if (( count < updates )); then updates="$count"; fi
work="$(mktemp -d "${TMPDIR:-/tmp}/wavesearch-semantic.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# One disposable corpus at a time; separate processes for query-only peak RSS.
for distribution in "${distributions[@]}"; do
    "${ZIG:-zig}" build semantic-bench -Doptimize=safe -- create "$work/library.sqlite" "$count" "$distribution"
    "${ZIG:-zig}" build semantic-bench -Doptimize=safe -- compare "$work/library.sqlite" "$queries" "$k"
    "${ZIG:-zig}" build semantic-bench -Doptimize=safe -- exact "$work/library.sqlite" "$queries" "$k"
    "${ZIG:-zig}" build semantic-bench -Doptimize=safe -- auto "$work/library.sqlite" "$queries" "$k"
    "${ZIG:-zig}" build semantic-bench -Doptimize=safe -- auto "$work/library.sqlite" "$queries" "$k" 0
    "${ZIG:-zig}" build semantic-bench -Doptimize=safe -- pipeline "$work/library.sqlite" "$queries" "$k"
    "${ZIG:-zig}" build semantic-bench -Doptimize=safe -- update "$work/library.sqlite" "$updates"
    # Reopen and recheck exact IDs/order/scores after transactional updates.
    "${ZIG:-zig}" build semantic-bench -Doptimize=safe -- compare "$work/library.sqlite" "$queries" "$k"
    rm -f -- "$work/library.sqlite" "$work/library.sqlite-wal" "$work/library.sqlite-shm"
done
