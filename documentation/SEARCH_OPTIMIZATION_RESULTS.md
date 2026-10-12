# Search optimization results (recommendations 1–9)

## Scope and implementation

The existing Zig/SQLite/FTS/SIMD/CLAP architecture is retained. No ANN dependency, inference download, or build-artifact cleanup was introduced. Canonical Float32 embeddings and fingerprint algorithm v3 remain unchanged.

| Recommendation | Implemented |
|---|---|
| 1. Avoid duplicated search work | One bounded, catalog-revision-aware lexical stage per request; ownership transfer avoids copying the full cached stage. Swift skips refinement without a loaded, matching model with embeddings. Duration filters are removed before text inference. |
| 2. Retrieve exact names independently | Indexed normalized filename/stem keys; compact FTS row-ID/score selection before hydration; deterministic cutoff ties; literal-first retrieval; deduplicated trigrams and bounded vocabulary typo fallback. |
| 3. Make waveform bookkeeping constant-time | Transactional counts/byte totals/failures, indexed batched detailed LRU eviction, and no detailed-eviction work for universal-only stores. |
| 4. Improve SQLite layout and budgets | New databases use 16 KiB pages; existing databases retain their page size. Explicit checked compaction creates a new copy. Main cache is 8 MiB, semantic reader 16 MiB. Temporary disk storage is scoped to index publication, not small waveform operations. |
| 5. Preserve semantic correctness while reducing overhead | Counters replace repeated SQ8 coverage probes; incomplete coverage selects exact. Scored source hashes, connection identity, and active-model checks reject stale hydration without rejecting unrelated embedding updates. Canonical Float32 remains the oracle. |
| 6. Bound acoustic retrieval | Deduplicated rare-first selectors, document frequencies, 32,768-posting/8,192-ID ceilings, bounded result heap, and batches of at most eight validated reference fingerprints. Candidate selection is approximate under these ceilings. |
| 7. Reduce fingerprint scratch memory | Five rolling power rows and delayed peak/landmark emission, with precomputed Hann coefficients. Byte-identical v3 output is tested; no reindex is required. File PCM now streams through bounded overlap buffers; see [schema-14 extraction/storage results](INDEXING_STORAGE_IDENTITIES.md). |
| 8. Bound indexing and browsing | Discardable disk-backed discovery/old identities; sorted atomic publication; incomplete/cancelled walks leave the catalog intact. Swift uses 200-row keyset pages instead of 5,000 rows. Metadata cache: 256 entries, at most 32 inspections, physical/source identity checks. |
| 9. Improve and measure ranking | Ranking revision `ws-ranking-calibration-v2`: exact/prefix/literal protection, calibrated semantic reciprocal-rank contribution, and no unsupported zero-confidence fillers. Graded nDCG harness and controlled imperfect-vector fixture. |

The scan uses a global catalog revision: competing publication fails rather than losing updates. Per-folder revisions remain an option if concurrent scans become important. Live browse pages must restart after catalog changes; complete cursor sort keys are resolved by ID to avoid truncated C display names causing duplicates.

## Indexing and lexical responsiveness follow-up (2026-10-10)

Changed files now share one open descriptor and a reusable prefix: at most 64 KiB
in fast mode, or 2 MiB for normal WAV metadata extraction. Metadata, the existing
WAV/AIFF duration parser, and hashing reuse those bytes. Hash algorithms and
fast/deep semantics are preserved. A final path stat detects replacement of the
opened file as well as size, mtime, and ctime changes.

Manifest copying and publication use short-lived, 8 MiB-cache WAL connections.
They hold a separate lifecycle lock rather than the metadata-query mutex;
close, reopen, and restore wait for them. Publication remains one atomic
transaction with revision validation, derived-data invalidation, and rollback.
Readers can search the previous committed catalog until publication completes.

The app publishes lexical results immediately. Semantic refinement waits until
120 ms from the request's start; lexical execution counts toward that interval.
Replacing the request cancels that wait and suppresses obsolete inference.

Paired disposable runs on the same machine, Zig 0.17.0 `safe`, internal storage:

| Workload | Before | After |
|---|---:|---:|
| 10K-row manifest copy, worst concurrent lexical query | 6.773 ms | 2.170 ms |
| 10K-row changed publication, worst concurrent lexical query | 614.306 ms | 4.260 ms |
| Publication elapsed time with continuously competing queries | 620.336 ms / 5 queries | 915.206 ms / 491 queries |
| 1K tiny-WAV initial scan | 1,552.034 ms | 463.816 ms |
| 1K tiny-WAV unchanged scan | 194.841 ms | 166.301 ms |

These are single before/after runs, not percentile estimates or controlled
cold/external-drive acceptance. Concurrent publication takes longer because
hundreds of searches now run instead of waiting for the writer. Scan timings
include the final path-stat safeguard.

```sh
cd core
zig build optimization-bench -Doptimize=safe -- index-contention /tmp/ws-contention.sqlite 10000
zig build optimization-bench -Doptimize=safe -- scan /tmp/ws-scan.sqlite 1000
```

Each command refuses an existing database and removes its generated corpus.
Focused checks pause an actual SQLite publication transaction and require
lexical search to return its previous snapshot before commit, reject staging
after reopen, and compare scanner metadata/duration/hash output across all
three modes. The app lifecycle check holds the refinement wait open and
requires lexical results to be visible, then replaces the request and verifies
that cancelled refinement never starts.

## Method

Apple M5 Pro, 24 GiB RAM, macOS 26.5.2 arm64, Zig 0.16.0, ReleaseSafe, production SQLite 3.45.2. Before/after use the same generated inputs, counts, queries and K. Baseline source was frozen before optimization; quality uses the same fixture and metric against that engine. Benchmarks use exclusively created disposable databases, never a user catalog. Thirty warm measurements per timed operation unless noted. These are not controlled cold-drive measurements.

Raw baseline/final logs and the baseline source are local artifacts under `/tmp/wavesearch-optimization-review/`; this document preserves the results beyond those disposable artifacts. Peak RSS includes SQLite/process overhead, excludes OS filesystem cache, and is not an allocation-only metric.

## Search, waveform and acoustic measurements

10,000 metadata rows; fingerprint input is 30 seconds of seeded noise.

| Operation | Before p50 / p95 ms | After p50 / p95 ms |
|---|---:|---:|
| Exact filename | 1.616 / 1.695 | 0.890 / 0.982 |
| Typo `impaxt` | 0.876 / 0.964 | 1.291 / 1.366 |
| Lexical then hybrid, no provider | 1.746 / 1.825 | 1.578 / 1.632 |
| Waveform status | 113.447 / 113.791 | 0.004 / 0.007 |
| Acoustic candidate retrieval | 35.072 / 35.284 | 1.205 / 1.286 |
| Fingerprint extraction | 21.500 / 27.074 | 18.330 / 18.464 |

- 10,000 universal waveform stores: **3,798.742 → 530.236 ms** total (86% lower).
- Acoustic benchmark reads **2,928 postings**, retains **2,928 candidates**, and does not hit its ceilings. A separate common-selector regression reaches both hard ceilings deterministically.
- Fingerprint output: **22,404 landmarks**, digest **`4077abbfe9e0262d`**, identical before/after. Peak RSS **10,223,616 → 7,749,632 bytes** (24% lower).
- Initial filesystem scan: **25,814.789 → 26,826.012 ms** (4% slower); unchanged scan **1,534.257 → 1,570.057 ms** (2% slower). Scan-process peak RSS **20,185,088 → 17,924,096 bytes** (11% lower). Staging trades extra SQLite operations/disk space for bounded discovery memory; a larger real-filesystem scan is still needed to establish scaling.
- Catalog-process peak RSS **14,434,304 → 18,169,856 bytes**: normalized-key indexes and request reuse are not a RAM win on this small fixture.
- The typo case is **47% slower**. Literal-first/vocabulary correctness and exact-name coverage improved, but this is a remaining optimization target—not an across-the-board latency improvement.

An attempted global FILE temporary-store policy made waveform writes take roughly 4.1 seconds. Repeating the same workload with MEMORY took 0.51 seconds. The final implementation uses FILE only for the unbounded publication seen-table; small normal operations retain MEMORY.

## Semantic retrieval and storage

100,000 normalized 512-D vectors, 30 held-out queries, K=256. Times include vector retrieval/conservative exact reranking, **not CLAP inference, lexical retrieval, hydration or UI publication**.

| Distribution | Exact before → after p50 ms | SQ8 before → after p50 ms | SQ8 before → after p95 ms | Mean / minimum recall@256 |
|---|---:|---:|---:|---:|
| Uniform | 157.748 → 90.167 | 40.808 → 26.500 | 42.525 → 26.849 | 1.000 / 1.000 |
| Clustered | 157.797 → 89.663 | 40.327 → 26.884 | 41.608 → 27.256 | 1.000 / 1.000 |
| Dense near-duplicates | 156.469 → 90.420 | 73.414 → 49.950 | 75.451 → 52.748 | 1.000 / 1.000 |

Uniform/clustered rerank at most 1,024 originals without a refinement scan. Dense cases retain a second 100,000-code refinement scan and at most 1,562 original reranks. This conservative path is deliberately retained.

| Resource, uniform corpus | Before | After |
|---|---:|---:|
| Original DB including metadata/canonical vectors | 518,082,560 bytes | 301,809,664 bytes |
| Added SQ8 storage | 58,531,840 bytes | 60,719,104 bytes |
| Total final DB | 576,614,400 bytes | 362,528,768 bytes |
| Query-process peak RSS, paired comparison | 87,392,256 bytes | 26,312,704 bytes |
| SQ8 construction | 464.313 ms | 264.470 ms |
| Total fixture construction | 7,097.158 ms | 6,973.948 ms |

Total disk falls **37%**, query RSS **70%**. SQ8 itself grows about 4%; the disk saving comes from canonical Float32 page packing. Folder-filtered retrieval still selects exact: 100 matching rows, p50 **0.827 → 0.130 ms**, p95 **0.878 → 0.146 ms**. Its separate-process RSS increases **5,980,160 → 13,615,104 bytes**; larger pages are not universally smaller in memory.

These storage gains require the new page layout. Schema migration alone does not rewrite an existing 4 KiB WAL catalog. `ws_backup_compact(NEW_PATH)` copies, vacuums to 16 KiB, checks SQLite/FTS/foreign keys/schema/counters, and leaves the live original intact. Restoring different page sizes temporarily leaves WAL after draining the core reader; external readers must also release their locks. Retain the original/backup. Compaction/restore require disk headroom for copies, journals and temporary files.

No ANN was added: the measured 100K global SQ8 p95 is 27–53 ms. The older million-vector measurements in `SEMANTIC_RETRIEVAL_BENCHMARK.md` are not updated by extrapolation. Repeat at representative million-scale latency/recall before choosing IVF/HNSW.

## Ranking quality

The fixed fixture contains 15 professional-style names/descriptors, deliberately imperfect 8-D vectors, and 24 graded cases: literal versus stronger semantic evidence, synonyms, typos without a shared trigram, duration/folder filters, Unicode, near-duplicates and empty results.

| Same controlled fixture | Before | After |
|---|---:|---:|
| Mean nDCG@10 | 0.793313 | 1.000000 |
| Results on queries judged empty | 20 | 0 |

Examples: `metal`, `metal impact`, `studio door` and `metla impact` improve **0.539 → 1.000**; `hit` **0.676 → 1.000**. The controlled gate is mean nDCG ≥0.95. It checks fusion logic, **not actual CLAP quality** or professional catalog acceptance.

The real relevance harness now accepts graded TSV judgments and reports per-query/mean nDCG@10 alongside top1/recall@5/MRR@5. ESC-50 additionally requires top1 ≥0.80, recall@5 ≥0.75, MRR@5 ≥0.50; nDCG ≥0.75 applies to both modes. Runtime/model artifacts were unavailable, so the updated real CLAP gate was **not run**. Optional codec acoustic acceptance was also **not run** because ffmpeg was absent; fingerprint byte parity and budget/correctness tests are not a replacement for real acoustic recall measurements.

## Validation and reproduction

- Core: **88 passed, 2 skipped (90 total)**; public waveform C ABI passed.
- Swift: all app sources except the app entry point compile against freshly built native library/current headers; worker/lifecycle, page append/retry, metadata capacity/eviction/source refresh and real-library smoke checks passed.
- Regression coverage includes exact names outside a 256-hit BM25 cutoff, short/transposed typos, cancelled/stale scan publication, NOCASE/long-Unicode keyset cursors, derived rollback/source-change/restore accounting, checked 4→16 KiB compaction and restore, >256-row detailed eviction, and saturated posting/ID budgets.
- Cross-compilation validated macOS x86_64 (14.0), Linux x86_64 and Linux aarch64 static libraries. Only native macOS execution is claimed. Windows remains outside the existing ONNX bridge support.
- No generated-artifact cleanup; unrelated work remains untouched.

```sh
cd core
zig build test -Doptimize=ReleaseSafe --summary all
# MODE: catalog, waveform, acoustic, scan, quality; choose a NEW temporary path.
zig build optimization-bench -Doptimize=ReleaseSafe -- MODE /tmp/NEW-disposable.sqlite 10000
zig build optimization-bench -Doptimize=ReleaseSafe -- fingerprint /tmp/NEW-fingerprint.sqlite 30
cd ..
./scripts/benchmark-semantic.sh 100000 30 256
(cd core && zig build lib -Doptimize=ReleaseSafe)
WS_CORE_LIBRARY="$PWD/core/zig-out/lib/libwavesearch.a" ./scripts/test-app-lifecycle.sh
```

Remaining acceptance: real CLAP/graded professional judgments, acoustic transformation recall, million-scale final retrieval, large/cold/contended filesystem scans, and end-to-end UI/inference latency. Smaller-cache/layout improvements and synthetic nDCG do not establish those results.

## Compact scan staging and filtered retrieval (2026-10-11)

Issues [#4](https://github.com/43curious/wavesearch/issues/4) and
[#8](https://github.com/43curious/wavesearch/issues/8) retain the existing schema
13 and C ABI. No model or canonical representation changes are required.

### Scan staging

The old-identity manifest stores file IDs and observation flags alongside its
existing relative path, size, mtime, and hash. Normal/fast scans fuse the
size/mtime lookup and unchanged observation in one SQLite operation. Unchanged
files add no full record to the `scanned` table; deep scans still inspect every
file. New/changed files stage their complete records, and observation flags
reject duplicate relative paths.

Publication validates the captured catalog revision, reconstructs retained
absolute paths from the root supplied once, and updates only moved paths.
Unobserved old IDs identify removals, so staged publication needs no second
seen-path table. All retained updates, full records, and removals commit
atomically. Generic array publication retains its existing seen-set behavior.
Cancellation during path updates rolls back moves and removals; cancelled or
incomplete walks, competing publication, and reopen cannot delete prior data.
Memory remains bounded by SQLite caches and a single file/row.

Serial paired runs used the original staging path and the final path, identical
10,000-row long-path fixtures, Zig 0.17.0 `safe`, and local macOS arm64 storage:

| Workload | Before | After |
| --- | ---: | ---: |
| Unchanged staging + publication | 21.044 + 23.377 ms | 30.892 + 9.238 ms |
| Unchanged allocated staging pages | 3,760,128 bytes | 868,352 bytes |
| Unchanged staging cache page writes | 918 | 0 |
| 10%-changed staging + publication | 20.658 + 91.275 ms | 30.510 + 76.649 ms |
| 10%-changed allocated staging pages | 3,756,032 bytes | 1,163,264 bytes |
| 10%-changed WAL file growth | 6,694,464 bytes | 6,694,464 bytes |

Allocated staging space fell 77% for unchanged and 69% for 10%-changed work.
Observation updates cost more than the old staging inserts in this fixture;
publication savings outweigh that difference modestly. The compact manifest
fits the 2 MiB staging cache, with no cache eviction writes observed. Page
allocation is logical SQLite space, not a measurement of physical device bytes;
WAL file growth is also distinct from total bytes written.

The separate production scanner used 10,000 generated tiny WAVs. Initial scan
measured 5,086.770 → 4,277.274 ms; unchanged scan measured
1,619.286 → 1,619.075 ms. These single runs do not establish a first-scan speedup
or a meaningful total unchanged-scan improvement: directory traversal and
per-file open/stat remain. Peak scan-process RSS was 19,185,664 → 18,399,232
bytes. Native watch signals, large professional libraries, controlled cold,
removable, and network storage remain follow-up profiling; normal scans still
perform complete reconciliation.

### Filtered semantic selection

A filter no longer unconditionally selects exact retrieval. With complete
active-model SQ8 coverage, an indexed source/model identity probe counts at most
4,096 matching embeddings. Larger populations use compact codes; smaller ones
use canonical vectors. Both paths apply the filter before payload retrieval,
retain exact-score reranking/error bounds, and share one read snapshot. A
cancelled population probe finalizes and rolls back before reader reuse.

The semantic harness now compares automatic selection against exact, supports
optional duration bounds, and reports logical vector/code payload bytes. See
[paired filtered results and reproduction](SEMANTIC_RETRIEVAL_BENCHMARK.md#filtered-population-selection-2026-10-11).

Focused checks cover broad/selective and combined filters, incomplete coverage,
dense near-duplicates, exact scores/order, cancellation, compact retained
analysis, mixed additions/changes/removals, root relocation, duplicate
observations, and rollback during retained path publication. Optional real-CLAP
and storage-dependent acceptance remain separate from these synthetic checks.
