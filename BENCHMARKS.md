# Performance and acceptance benchmarks

See [streaming extraction, lossless storage, and byte verification](documentation/INDEXING_STORAGE_IDENTITIES.md)
for the schema-14 follow-up, reproducible benchmark modes, measured memory/read
bytes/payload/compaction costs, and synthetic-versus-real acceptance limits.

Benchmarks are explicit developer operations. Normal builds and tests never
generate large corpora or download fixtures.

## Audio metadata (schema 16)

The [schema-16 metadata follow-up](documentation/AUDIO_METADATA.md#validation-and-measurements)
records a paired 32-WAV scan with byte counters, catalog/RSS costs and warm-storage
limits. Reproduce with `zig build optimization-bench -Doptimize=safe -- metadata-scan /tmp/ws-metadata.sqlite 32`
from `core/`; the generated corpus and catalog are disposable.

## Refinement queue discovery (schema 13)

`make check-core` measures 16-file queue discovery over 1,600 synthetic files
at 0%, 50%, and 99% completion, including reopen. It reports SQLite VM steps and
mean elapsed time over 30 calls; VM work is the deterministic regression gate.
See [the queue contract, baseline, and limits](documentation/REFINEMENT_QUEUES.md).

## Search optimization comparison (schema 12)

The [compact-staging and filtered-retrieval follow-up](documentation/SEARCH_OPTIMIZATION_RESULTS.md#compact-scan-staging-and-filtered-retrieval-2026-10-11)
records paired local measurements and limits. Reproduce staging separately from
filesystem work, using new disposable paths:

```sh
cd core
zig build optimization-bench -Doptimize=safe -- stage /tmp/ws-stage.sqlite 10000
zig build optimization-bench -Doptimize=safe -- scan /tmp/ws-scan.sqlite 10000
```

`stage` reports allocated SQLite staging pages, staging cache page writes,
publication time, WAL file growth, and process RSS for unchanged and 10%-changed
snapshots. These are distinct from physical storage-device I/O. Semantic
`compare` now measures the automatic planner against exact; optional duration
bounds follow the query-file argument (`-` means generated queries). See the
[semantic harness](documentation/SEMANTIC_RETRIEVAL_BENCHMARK.md#filtered-population-selection-2026-10-11).

[Results and reproduction](documentation/SEARCH_OPTIMIZATION_RESULTS.md) cover
recommendations 1–9: exact-name coverage, request reuse, waveform counters,
SQLite layout, semantic/acoustic retrieval, fingerprint memory, disk-backed
scans, paginated browsing and graded ranking. Includes regressions and unrun gates.

## Million-file metadata benchmark

Run:

```sh
cd core
zig build perf -- 1000000 ../.perf/million.sqlite
```

The harness creates one million deterministic file rows through the production
schema and FTS triggers, then measures 30 warm runs for exact lexical search,
typo/trigram search, first-page folder listing, and streaming waveform extraction
from a generated 60-second 48 kHz WAV. ReleaseSafe budgets are:

| Measurement | Budget |
|---|---:|
| Exact search p95 | <= 100 ms |
| Typo/trigram search p95 | <= 250 ms |
| Folder page p95 | <= 100 ms |
| 60-second WAV waveform p95 | <= 150 ms |
| Process peak RSS | <= 512 MiB |

Reference host: Apple M5 Pro, 24 GiB RAM, macOS 26.5.2 arm64, Zig 0.16.0,
ReleaseSafe, local SSD.

```text
corpus=1000000 schema=10 db_bytes=590340096 peak_rss_bytes=402046976 index_s=45.520
exact_ms p50=56.286 p95=61.978
typo_ms p50=108.861 p95=133.030
folder_ms p50=0.229 p95=2.396
waveform60s_ms p50=33.031 p95=34.701
```

All defined budgets passed. ONNX Runtime/model memory is intentionally excluded
from this dependency-free metadata benchmark. Semantic retrieval now streams
SQLite vector rows through one dimension-sized decode buffer and a K-sized
result set, avoiding the previous all-vector process snapshot.

## macOS waveform latency gate

Run the schema-v10 sparse-overview and SQLite-tier gate against any
AVFoundation-readable fixture:

```sh
./scripts/benchmark-waveforms.sh /path/to/long-recording.wav
```

The harness runs preview/cache paths 30 times and duration-dependent exact paths
`WS_WAVEFORM_BENCH_RUNS` times (default 5). It fails when uncached first waveform
p95 exceeds 50 ms or SQLite tier p95 exceeds 16 ms. It differentially requires
portable Zig and Swift/vDSP to produce identical μ-law tiers, LUFS/sample peak
within `0.000001`, and byte-identical WVT3 against the frozen schema-v10 Swift
reference. It reports both backend timings, exact envelope, loudness refinement,
background universal, and real-time factor. Local warm-storage fixtures measured:

```text
181 s WAV: preview p50=0.256 ms p95=0.334 ms
           exact envelope p50=7.599 ms
           selected Accelerate exact+LUFS p50=33.383 ms
           portable Zig exact+LUFS p50=78.296 ms
           background 512+LUFS p50=33.580 ms
           SQLite p50=0.266 ms p95=0.302 ms
2 s WAV:   exact first display p50≈0.65 ms · selected exact+LUFS p50≈1.0 ms
```

On the same 181-second WAV, the pre-vDSP scalar envelope-plus-loudness baseline
was 68.391 ms p50; the vectorized path is 40.752 ms p50 (40.4% lower). The old
75 ms per-file coordinator delay was also replaced by cooperative eight-file
bursts, which removes the dominant queue overhead for tiny effects.

Set `WS_WAVEFORM_BENCH_RUNS=N` to control duration-dependent repetitions. Set
`WS_WAVEFORM_MAPPED_PARITY=1` to require mapped PCM and AVFoundation outputs to
match; `WS_ENABLE_MAPPED_PCM=1` benchmarks the mapped reader as the active path.
The latter remains opt-in because AVFoundation was faster on current warm-cache
WAV measurements.

This gate measures CPU/warm-storage behavior; a separate real-library cold-drive
run is still required for device seek and contention characterization.

## Portable waveform throughput

Run the dependency-free streaming analyzer gate on macOS or Linux:

```sh
cd core
zig build waveform-bench
```

It streams a deterministic 60-second, 48 kHz stereo Float32 signal in bounded
32,768-frame chunks and fails above 250 ms in ReleaseSafe. `zig build test` also
compiles and runs `core/src/waveform_abi_test.c`, whose static layout assertions
and lifecycle calls verify the public C header against the linked library. The Apple M5 Pro
reference run completed in `38.881 ms` (`1543x` real time). Cross-compilation is
also verified with `zig build lib -Dtarget=x86_64-linux-gnu` and
`-Dtarget=aarch64-linux-gnu`.

## Refinement policy check

```sh
./scripts/test-refinement-policy.sh
```

This dependency-free Swift check verifies the persisted mode fallback and the
Fast only, Balanced idle/AC, Complete, foreground activity, scan, memory
pressure, missing-library, and explicit-pause admission rules. Core tests also
verify that additive `ws_cancel_refinement()` does not cancel an active metadata
scan.

## Vector microbenchmark

```sh
cd core
zig build bench -- 10000
```

This isolates exact SIMD cosine/top-K behavior. It is useful for small regression
checks; the million-file benchmark is the operational acceptance run.

## Semantic relevance

See `core/models/RELEVANCE.md` for the pinned 40-clip opaque-name ESC-50
acceptance set and its top-1/recall@5/MRR results.
