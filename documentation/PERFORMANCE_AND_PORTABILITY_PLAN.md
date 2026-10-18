# WaveSearch performance and portability plan

## Search optimization follow-up

Recommendations 1–9 are implemented; [measured results and remaining acceptance](SEARCH_OPTIMIZATION_RESULTS.md)
include schema-12 storage/counters, bounded retrieval/staging, pagination,
metadata caching and graded ranking. The original inventory below remains
historical; this follow-up does not claim every unchecked portability item done.

Schema 14 adds [bounded fingerprint extraction, lossless repacking, and explicit
source identity verification](INDEXING_STORAGE_IDENTITIES.md), with canonical v3
output retained. Reduced-detail trigrams and on-demand universal waveforms remain
experiments rather than assumed storage improvements.

## Scope and evidence

Keep Zig, SQLite, and native frontends. The largest opportunities are eliminating unnecessary work, bounding concurrency, and keeping blocking operations away from the UI. This plan records the source review; it is not a new profiling report. References name the reviewed functions because line numbers change during implementation.

WaveSearch is a sound-effects indexing application with a Zig core and SwiftUI macOS frontend. The goal is responsive interaction, bounded CPU/RAM/disk use, and a reusable core for macOS, Linux, and Windows—not a rewrite.

**Status:** P0 A and P0 B are implemented and validated. Unchecked items are still an issue inventory, not a claim that the fixes are complete. The findings below describe the reviewed baseline.

### Priorities

| Priority | Area | Main benefit |
| --- | --- | --- |
| P0 | A: UI blocking and lifecycle | Avoid freezes and teardown races |
| P0 | B: cancellation and bounded requests | Prevent obsolete searches/playback preparation from accumulating |
| P1 | C: semantic retrieval | Keep large-library queries responsive |
| P1 | D: refinement queues/status | Avoid repeated work as libraries approach completion |
| P1 | E: filesystem scanning | Bound memory and cold-storage I/O |
| P1 | F: row metadata | Keep scrolling smooth and memory bounded |
| P1 | I: acoustic candidate generation | Bound similarity-search and refinement work |
| P1 | Portability: optional CLAP, engine/API boundaries | Remove concrete platform blockers before adding frontends |
| P2 | G/H: audio preprocessing and rendering | Reduce measured hot-path costs without changing audio semantics |

P0/P1/P2 indicate recommended order, not measured severity. Reprioritize using real-library profiles.

Swift paths below are relative to `macos/WaveSearch/WaveSearch/`; Zig paths are relative to `core/src/`.

## A. Keep blocking operations off the UI thread

### Problem

- `AppStore.bootstrap` synchronously initialized/migrated SQLite and loaded folder counts.
- `AppStore.removeFolder` synchronously waited for the core mutation lock, deleted catalog data, and rebuilt acoustic groups.
- `LibraryFolder.isMissing` probed the filesystem during view evaluation and frequent policy polling, potentially blocking on disconnected/network storage.
- Coordinator stop/canceled-load paths synchronously unloaded CLAP; teardown can wait for active provider references.
- Core mutation, database, and provider lifecycle synchronization used yield-spinning even for long waits (`main_c.zig`, `db.zig`, `clap_provider.zig`). Indexing holds the mutation lock during filesystem traversal, so another mutation can wait on slow storage.
- The legacy `ws_waveform` export holds that mutation lock across cache lookup, decoding/DSP, and cache save. Moving computation outside the lock requires revalidating source identity before publication.
- App teardown must drain active and detached work before `ws_deinit` and before releasing security-scoped resources; cancellation alone is not proof of completion.

### Required fixes

- [x] Initialize/migrate/read catalog counts on a worker; expose readiness and guard operations during startup/shutdown.
- [x] Remove folders asynchronously, reject overlapping mutations, cancel/drain affected foreground work, and release file-access grants only after relevant work finishes.
- [x] Replace render-time availability probes with asynchronously refreshed state. Coalesce probes, refresh after mount/unmount/wake and periodically, and reject stale observations.
- [x] Move provider teardown and filesystem probes off the main actor. Copy thread-local errors on the same worker as the failing call.
- [x] Provide explicit shutdown/drain ordering before closing SQLite or releasing access grants.
- [x] Replace long yield-spin waits with blocking synchronization. Keep slow DSP out of publication locks when cache identity can be preserved safely.

### Acceptance criteria

Blocked storage, database mutation, and provider teardown must not block the main actor. Repeated bootstrap calls must not reopen a live database. Stop/shutdown must not allow canceled workers to restart or publish after teardown. Existing saved library preferences must decode without requiring new persisted availability fields.

### A implementation contract

- `LibraryBackend.swift` contains the blocking open/restore/count, bookmark authorization, removal, availability, and close operations. `AppStore` dispatches them off-main and exposes readiness/library-change/shutdown state.
- `BlockingWorkRegistry.swift` closes admission before draining real detached calls; canceling an outer task cannot make the registry report completion early. Host file work uses generation tickets to reject operations scheduled before a suspend/resume cycle.
- Availability is a cached, non-persisted `LibraryFolder` property. One coalesced worker refreshes it on mount/unmount/wake and every 30 seconds; responses must match both folder ID and path.
- Removal conservatively pauses/drains refinement, playback/analysis, foreground database calls, metadata inspection, and clip exports before deleting catalog data and releasing the removed root's access grant. Other library playback can pause during this barrier; correctness takes precedence over uninterrupted playback during removal.
- Normal application Quit uses `AppLifecycleDelegate` and AppKit's asynchronous termination reply. Callers must await `AppStore.shutdown()` before discarding an initialized store. Shutdown waits for startup/removal, drains workers, closes the core off-main, and then releases remaining access grants. Forced process termination cannot run this barrier.
- These changes track query lifetimes for safe teardown. P0 B adds latest-request scheduling and per-query core cancellation; an already-running native/OS call can still delay completion, without blocking the UI thread.

Validation command: `bash scripts/test-app-lifecycle.sh`. Set `WS_CORE_LIBRARY` to a freshly built native `libwavesearch.a` when testing core changes. The harness compiles production Swift sources and uses gated backend operations plus a temporary real WAV/catalog smoke test; it never opens the user's database. Final test results are recorded in the status section below.

## B. Bound and cancel foreground requests

### Problem

`AppStore.search` canceled the outer Swift task but left detached `ws_search` work running. With CLAP loaded this includes inference and a full matching-vector scan. Rapid changes could accumulate expensive obsolete work. `PlayerController.load` similarly left detached AVAudioPlayer preparation running for obsolete selections.

### Required fixes

- [x] Use latest-request-wins execution: at most one active operation and one replaceable newest pending request per worker, including browse/example requests.
- [x] Cancellation must signal the real core request, not merely suppress UI publication. Cancellation before dispatch remains effective.
- [x] Add an additive, per-query C cancellation interface while preserving legacy exports and independent refinement/scan cancellation.
- [x] Check cancellation during retrieval and preprocessing and before/after inference. Cancellation is not silently turned into lexical fallback success.
- [x] Publish lexical results before optional hybrid refinement; accept later results only for the same current request.
- [x] Bound playback preparation, discard obsolete outputs, and drain it during stop/shutdown. Swift task cancellation is not assumed to interrupt AVFoundation.
- [x] Regression-test replacement, stale-result suppression, cancellation isolation, reentrant completion, and actual draining with deterministic gates.

### Cancellation limits

OS file operations and native runtime calls may be uninterruptible while inside the call. Cooperative cancellation bounds subsequent work; latest-request execution prevents additional obsolete calls from accumulating. Do not describe this as hard real-time cancellation. Keep the request handle alive until all operations and cancellers have finished.

## C. Make semantic retrieval scale beyond exact scans

**Evidence:** The exact baseline processes about **2.048 GB of Float32 payload** per unrestricted million-vector, 512-dimensional query, excluding SQLite overhead. Schema 11 now scans 520-byte SQ8 codes and reads original vectors selectively using exact reranking and conservative error-bound refinement. Measured million-row synthetic retrieval improved **2.08–5.61×**, with 1.000 recall@20/@256, approximately 83 MiB query-process peak RSS, and 558 MiB added disk storage. See [measurements, tradeoffs, and reproduction](SEMANTIC_RETRIEVAL_BENCHMARK.md); these are not real-audio or end-to-end UI latency claims.

- [ ] Avoid invalidating coherent snapshot results for unrelated embedding insertions. Connection/model/generation validation is implemented, but every generation change still rejects a completed scan.
- [x] Reuse one bounded read-only connection for semantic scans; cancellation rolls back the read transaction and the next scan reuses the connection safely.
- [x] Avoid an unnecessary vector-row sort and hydrate semantic result metadata in one bounded `IN` query instead of one SQLite query per result.
- [x] Use selective vector retrieval for large collections. Evaluated SQ8 plus exact reranking against the exact baseline at up to one million vectors, measuring recall, latency, process RSS, disk overhead, and build time. Small matching sets remain exact; broad folder/duration filters now select SQ8 using a bounded population probe. Ambiguous candidates receive additional exact scoring rather than sacrificing near-duplicate recall. See [filtered measurements](SEMANTIC_RETRIEVAL_BENCHMARK.md#filtered-population-selection-2026-10-11).

Compact scans still do O(N×dimension) work and may need a second pass; selective Float32 reads do not make this ANN. Migration backfills codes atomically off-main, delaying library readiness once. Representative CLAP and controlled cold-storage benchmarks remain follow-up acceptance work.

## D. Eliminate repeated catalog-wide refinement work

**Evidence:** `db.pendingSemanticFilesLocked` and `db.pendingFingerprintFiles` used to query from the beginning with correlated `NOT EXISTS` checks. Small batches could repeatedly traverse the completed prefix, approaching quadratic candidate checks under ascending-ID traversal; `waveformCacheStatus` runs several catalog-wide aggregates under the DB mutex, and the coordinator refreshed status after each step.

- [x] Use operation-local resumable ID cursors for semantic and acoustic queues; existing source/model identity checks still re-enqueue changed rows.
- [x] Persist pending work across bounded calls and process restarts, with re-enqueueing for changed files/model revisions and cleared failures. Schema 13 uses indexed derived queues; see [publication, recovery, and measured discovery work](REFINEMENT_QUEUES.md).
- [ ] Maintain cheap progress counters and periodically reconcile them instead of recounting the entire catalog per item.
- [x] Use one-file host refinement steps so foreground admission and queue selection occur between files. Caller-selected bounded batches remain available in the core; never hold a write transaction while decoding/inferencing.
- [x] Interleave available queues with portable 2:1:1 weighted turns and independent per-producer folder rotation. See [the step bound, cancellation limits, and checks](REFINEMENT_QUEUES.md#fair-background-scheduling); storage-sensitive tuning remains a profiling task.

## E. Bound real filesystem scan memory and I/O

**Current implementation:** `search.indexFolderWithOptions` stages discovery and old identities in disposable SQLite tables. Changed files share one open descriptor and a bounded cached prefix across metadata, duration and hashing. Manifest copying and atomic publication use a separate WAL connection, allowing metadata searches to read the committed catalog. Default metadata extraction still examines up to 2 MiB; fast extraction skips PCM chunks.

- [x] Stage large scans in disk-backed tables/a staging database while preserving atomic old-or-new publication and cancellation rollback.
- [x] Retain unchanged identities in the copied old manifest and stage full records only for new/changed files; reuse old observation flags for deletion reconciliation instead of a second seen-path table. See [space, timing, and cancellation checks](SEARCH_OPTIMIZATION_RESULTS.md#compact-scan-staging-and-filtered-retrieval-2026-10-11).
- [x] Reuse open descriptors and cached header bytes across metadata/duration/identity extraction, retaining the existing duration parser and path identity checks.
- [ ] Extend sparse metadata extraction where appropriate.
- [ ] Introduce only measured, storage-sensitive concurrency: SSD, HDD, removable, and network storage have different optimal access patterns.

Keep fast/deep indexing and unchanged-file reuse. Fast sampling reduces per-file bytes but total I/O still scales with file count.

## F. Bound row metadata inspection

**Evidence:** `AudioMetadataStore` retains every inspected path indefinitely and starts detached work per unseen file. Visible rows observe the entire dictionary, so each insertion can invalidate multiple rows.

- [ ] Persist sample rate, channel count, bit depth, and related technical metadata during indexing and return it with catalog results.
- [ ] Use a bounded, source-signature-keyed host fallback cache for formats needing AVFoundation.
- [ ] Bound metadata inspection concurrency and stop obsolete work after rows disappear.
- [ ] Narrow observation to relevant values rather than publishing a global dictionary on every insertion.

Opening source audio during scrolling should be a fallback, not the normal path.

## G. Avoid duplicate float-audio validation passes

**Evidence:** `clap_audio.WindowReader.initFile` validates the entire float payload before selected-window reads. `decodeFingerprintFile` performs validation before rejecting unsupported long recordings. `validateFiniteFloatData` originally had no cancellation checks.

- [ ] Move cheap duration/format eligibility checks before validation.
- [ ] Fuse finiteness validation into full-timeline decoding.
- [ ] Decide explicitly whether invalid samples outside sparse semantic windows must reject the file before removing whole-file validation.
- [ ] Keep cancellation checks throughout validation, decoding, and resampling. Cancellation coverage overlaps B; pass elimination remains G.

## H. Profile smaller audio/rendering improvements

- [ ] Cache stationary waveform geometry; update playhead/progress separately (`WaveformView`). Current playback updates every 40 ms rebuild envelope paths.
- [ ] Process portable waveform pushes as bucket-aligned runs rather than wide bucket division per frame; add appropriate vector reductions (`waveform.Analyzer.push`).
- [ ] Reuse bounded resampler coefficient tables and buffers; precompute PCM scales; use incremental rational phase stepping. Preserve preprocessing identity and numerical parity.
- [ ] Reduce redundant peak scans and high-channel-count scratch buffers in Accelerate loudness. Preserve channel weighting and gating semantics.
- [ ] Reuse loudness workspaces/touched histogram bins where tiny-file setup dominates.
- [ ] Address acoustic candidate generation separately under I; this is a library-scaling concern, not merely a small DSP optimization.
- [ ] Replace or migrate legacy `ws_waveform` callers: it uses fingerprint preprocessing, materializes the resampled timeline, and inherits a five-minute limit. Preserve RMS semantics for compatibility; the modern extrema analyzer is not a drop-in numerical replacement.
- [ ] Throttle temporary clip-export cleanup instead of scanning prior exports on every request.

## I. Bound acoustic candidate generation and refinement

**Evidence:** acoustic candidate retrieval in `db.zig` counts the fingerprint corpus, probes up to 96 selectors with 27 neighboring hashes each, accumulates candidate IDs, and sorts before applying the final verification cap. At a million fingerprints, the frequency cutoff can permit roughly 50,000 document IDs per selector before rejection. `acoustic.zig` repeats retrieval per indexed file and can load/compare up to 1,024 references individually.

A cap of 128 full query verifications does **not** bound posting enumeration, candidate-map memory, or refinement reference reads.

- [ ] Maintain selector frequencies rather than repeatedly deriving corpus statistics.
- [ ] Probe rare selectors first, with explicit limits on postings visited, unique candidates retained, and total work per request.
- [ ] Maintain bounded top-K candidates before expensive verification; measure recall against the existing algorithm.
- [ ] Fetch reference fingerprints in batches and reuse statements.
- [ ] Review fingerprint/edge publication, currently separate transactions, for safe bounded batching and recovery. Keep decoding and comparisons outside write transactions.

## J. Treat model and database resources as explicit budgets

### Duplicate inference on concurrent cache misses

`clap_provider.zig` already has a bounded **32-entry query-embedding cache**. Concurrent misses for the same query can nevertheless both infer before insertion deduplicates the entries. `onnx_bridge.c` serializes inference with a session mutex, so duplicated work can become queued latency.

- [ ] Add single-flight inference: concurrent callers share one in-progress computation, with independent cancellation/lifetime rules.
- [ ] Do not propose an unbounded or simply larger embedding cache as the primary fix.
- [ ] Benchmark uncached inference separately from lexical retrieval and vector scanning.

### Session memory and threading

ONNX already uses configured intra-op threads, one inter-op thread, graph optimizations, and the CPU arena. No platform execution provider is currently appended.

- [ ] Measure idle, text-only, audio-only, combined-session, and post-unload resident memory.
- [ ] Evaluate separate text/audio session lifetimes and a bounded retention policy rather than frequent load/unload churn.
- [ ] Benchmark thread settings on representative machines; extra threads can compete with playback, scanning, and rendering.
- [ ] Evaluate accelerated execution providers only with latency, memory, numerical, and packaging tests—not as an assumed improvement.

### SQLite memory and contention

SQLite is built with a 64 MiB default page-cache setting and uses `temp_store=MEMORY`. Actual memory depends on workload and connections. The main connection uses SQLite `FULLMUTEX` plus an application mutex; WAL does not make calls sharing that connection run in parallel.

- [ ] Set explicit connection/cache/temp-work budgets, including independent semantic readers.
- [ ] Measure lock hold time and busy waits before removing any synchronization.
- [ ] Preserve WAL, foreign-key checks, source validation, and atomic publication. `synchronous=NORMAL` means per-file transactions do not necessarily imply a filesystem sync per file.

## K. Make audio semantics an explicit portable contract

The Swift Accelerate path and Zig path implement overlapping loudness behavior. Channel count/index is used to infer LFE and surround weighting; this is not a general channel-layout contract, especially for unusual multichannel files.

- [ ] Define channel layout, LFE exclusion, surround weighting, sample format, and numerical tolerances at the PCM boundary.
- [ ] Extend differential tests across mono, stereo, unusual channel layouts, sample rates, silence, clipped/non-finite input, and chunk boundaries.
- [ ] Preserve borrowed planar PCM buffers and bounded pushes; keep AVFoundation decoding/playback in the macOS adapter.
- [ ] Document backend selection: portable Zig currently rejects an explicit Accelerate backend. Swift computes accelerated results and imports them through the host-result path; core `AUTO` does not independently discover Accelerate.

**Memory opportunities:** the reviewed Swift loudness path allocates per-channel Double scratch. At the supported 256-channel, 32,768-frame extreme, this can be about 64 MiB of scratch plus 32 MiB of Float input; ordinary stereo is much smaller. Two 120,001-bin loudness histograms cost about 1.92 MB per analyzer. Reuse one filtered-channel workspace/shared energy accumulation where semantics permit, and measure setup cost on very short effects.

The resampler builds an approximately 128 KiB coefficient table per conversion; it already shares that table across windows. Cache it only with a bounded key space and preserve the existing Int16 round-trip and preprocessing-version identity.

## Existing optimizations to preserve

- SQLite WAL, atomic publication, unchanged-file reuse, and cancellation rollback.
- Bounded streaming PCM buffers and compact versioned WVT3 waveform tiers.
- Bounded semantic top-K working storage and existing candidate caps.
- Explicit optional model installation, integrity checks, and lexical fallback. Model hashing/session construction already occur outside the provider publication lock, keeping lexical search available during startup.
- The existing 32-entry text-embedding cache, cooperative scan bursts, and generation-aware background cancellation.
- Sparse preview before full selected-file analysis; the second pass is an intentional first-display latency tradeoff, not automatically redundant work.
- Interaction, idle/AC, thermal, memory-pressure and pause admission rules.
- Accelerate/AVFoundation fast paths and differential waveform tests. Recorded 181-second exact+LUFS results are about 33 ms Accelerate versus 78 ms portable Zig; these are historical warm-storage measurements, not new measurements.

Treat CLAP as a separate resource tier. Its approximately 754 MiB installation size is disk size, not measured resident RAM. Measure text/audio session memory independently, consider separate lifetimes, retain integrity verification, and avoid frequent load/unload churn. Keep SQLite/cache/worker budgets explicit and bounded; do not blindly increase thread counts or cache sizes.

## Ghostty-style `libwavesearch` architecture

WaveSearch already builds `libwavesearch.a`, exposes `core/include/wavesearch.h`, and has a portable PCM streaming analyzer. Evolve that foundation rather than rewriting the application.

Ghostty shares Zig behavior across application runtimes; its macOS embedded runtime lets Swift own the app lifecycle. Its internal app embedder interface is distinct from the public `libghostty-vt` terminal-state library:

- <https://github.com/ghostty-org/ghostty/blob/main/src/apprt.zig>
- <https://github.com/ghostty-org/ghostty/blob/main/src/apprt/embedded.zig>
- <https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h>

```text
SwiftUI/AppKit (macOS)    GTK (Linux)    WinUI or Qt (Windows)
          \                  |                  /
                    Thin native adapters
                            |
                  Versioned C interface
                            |
                       libwavesearch
        catalog / search / jobs / analysis / caches
                            |
           SQLite / portable DSP / optional CLAP
```

Keep the library in-process; no daemon, RPC protocol, web frontend, or shared GPU renderer is necessary.

### Shared responsibilities

- [ ] Core owns catalog/schema/migrations, indexing, query interpretation, ranking, pagination, cache identity, analysis semantics, fingerprints, embeddings, and resource budgets.
- [ ] Extract a core request/refinement module owning priorities, cancellation, draining, retry/backoff, and cheap progress snapshots. Moving DSP alone leaves substantial behavior duplicated in every frontend.
- [ ] Native hosts own windowing, menus, accessibility, permissions/bookmarks, file dialogs, OS mount/watch signals, playback-device integration, and native codec/acceleration adapters.
- [ ] Hosts report power/idle/thermal/memory/availability facts; shared policy decides what work is admissible.

### Engine ownership and C interface

- [ ] Replace singleton DB/provider/job state with an opaque engine handle. `db.zig`, `clap_provider.zig`, `operations.zig`, and `cancellation.zig` hold shared process-global state today. Normally one engine serves the application, not one per window; independent engines should not cancel or close each other's work.
- [x] Document current blocking behavior, cancellation/draining, ownership, buffer lifetimes, ABI negotiation and compiled capabilities in the [C API contract](C_API.md). Calls are synchronous and invoke no host callbacks.
- [ ] Prefer submit/result/progress operations over exposing internal scheduler bookkeeping.
- [ ] Replace fixed path buffers in new interfaces with length-bearing strings or immutable result handles. Existing `WSResult.path[1024]` and `name[256]` are limiting; `db.copyText` and waveform work-item/claim copies in `main_c.zig` can silently truncate paths. Define UTF-8 byte lengths, embedded-NUL rejection, and explicit insufficient-buffer errors.
- [ ] Introduce explicitly sized IDs and operation-local errors in future interfaces. Current layouts and ABI negotiation are covered by the C API contract; thread-local errors must be copied immediately on the thread that made the failing call.
- [ ] Add pagination/bulk metadata, C++ linkage guards and shared-library export macros.
- [ ] Retain bounded PCM interfaces with portable WAV/AIFF and optional host/shared compressed decoders; preserve canonical semantics with platform acceleration.

### Windows and packaging

- [ ] Make CLAP optional at build time. `onnx_bridge.c` currently rejects non-macOS/Linux platforms and is always compiled by `core/build.zig`.
- [ ] First make metadata/search/waveform functionality run on Windows without CLAP.
- [ ] Add Windows dynamic loading, synchronization, Unicode/ONNX path handling, and verified runtime installation support. `onnx_bridge.c` unconditionally includes `pthread.h`, uses `dlopen`/`dlsym`/`dlclose`, and passes a narrow `char` model path to `CreateSession`; Windows needs platform-appropriate equivalents.
- [ ] Port benchmark tooling too: `perf.zig` unconditionally imports `sys/resource.h`, which is a separate Windows obstacle from the library.
- [ ] Define runtime distribution per platform. The macOS App Store build must bundle/sign executable runtime code rather than download it; optional model data installation is a separate concern.
- [ ] Package static/shared libraries and headers independently of the macOS XCFramework.
- [ ] Run public C-interface tests on each OS, including lifecycle, cancellation, Unicode/long paths and codec behavior; cross-compilation alone is insufficient.

## Recommended sequence and measurement gates

1. Implement A/B responsiveness and bounded foreground execution.
2. Fix pending queues, expensive status reads, scan staging and metadata retention.
3. Extract engine ownership/shared scheduling beneath the existing frontend.
4. Prove the C interface with headless Linux and Windows clients before adding GUIs.
5. Add native frontends and optional providers.
6. Optimize DSP/rendering only after profiling.

The million-row harness in `core/src/perf.zig` inserts synthetic metadata directly. It does not measure a real million-file walk, SwiftUI, or CLAP. Existing `BENCHMARKS.md` numbers are regression baselines, not proof of end-to-end resource bounds. Its 30 repeated fixed-query runs also do not establish cold-cache or representative query-distribution performance.

**Benchmark safety:** the harness deletes the database at its supplied path and its WAL/SHM files. Use a dedicated disposable location, never a user's live library database.

For context only, the recorded schema-10 million-row ReleaseSafe run on an Apple M5 Pro/24 GiB reported approximately 45.52 s synthetic insertion, 384 MiB peak RSS, 563 MiB database size, 61.98 ms exact-search p95, and 133.03 ms typo-search p95. These exclude ONNX/model memory and are not fresh measurements.

Measure: first real scan and unchanged/changed rescans; cold/removable/network storage; rapid query changes with and without CLAP; cancellation latency and obsolete operation count; refinement throughput near 0%, 50%, and 99% completion; cold startup/migration/removal; idle wakeups/CPU; application plus ONNX peak memory; waveform-cache, embedding, DB and WAL disk growth. Keep release-mode latency/recall gates and deterministic concurrency regressions separate.

## Implementation status and next validation

P0 A and P0 B are complete. Startup, removal, availability probing, metadata/file work, playback/analysis, provider teardown, and shutdown use explicit off-main admission/drain barriers. Core mutex/provider waits block instead of spinning, and legacy waveform DSP publishes outside the mutation lock only when catalog and source identities remain current. Foreground search and playback preparation now use one-active/one-newest-pending workers, request-local native cancellation, stale-publication guards, and real drain barriers. P1 C now adds measured SQ8 retrieval with selective Float32 reranking and error-bound refinement, reusable reader state, snapshot validation, and batched candidate hydration. Compact scans remain linear; unrelated-generation invalidation and representative real-CLAP/cold-storage acceptance remain open, without assuming ANN is preferable. P1 D advances semantic/acoustic refinement through schema-13 durable pending indexes. The host now uses one-file steps, portable 2:1:1 queue selection, and independent producer folder cursors so waveform backlog cannot starve search refinement. Reopen and repeated calls avoid completed-prefix scans; source changes and cleared failures re-enqueue work. Queue publication, migration, and recovery checks are documented in [Durable refinement](REFINEMENT_QUEUES.md).

Validation completed: `bash scripts/test-app-lifecycle.sh`, `bash scripts/test-window-chrome.sh`, `cd core && zig build test -Doptimize=ReleaseSafe --summary all` (75 passed, 2 skipped), and a Debug `xcodebuild` of the `WaveSearch` scheme all pass. The deterministic checks cover latest-request replacement, browse/example bounding, stale-result/error suppression, request-local cancellation, cancellation isolation, lexical-first publication, playback preparation draining, shutdown barriers, and cursor-based pending retrieval.

The remaining cancellation limit is intentional: an OS file operation or native runtime call may finish before cooperative cancellation is observed. The worker slot remains occupied until that call returns, so obsolete work cannot accumulate unboundedly.
