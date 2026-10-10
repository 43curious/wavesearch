# Roadmap

## Phase 2 — Semantic hybrid search

### Dependency-free core

- [x] Add a provider-facing, versioned embedding API without bundling inference.
- [x] Persist model identities, resumable failures, and normalized float32 embeddings in transactional SQLite schema v6.
- [x] Invalidate changed-file embeddings atomically while preserving unchanged and root-relocated files.
- [x] Add portable exact SIMD cosine/top-K retrieval with deterministic file-ID ties and shared filters.
- [x] Fuse semantic and lexical candidate sets with deterministic integer reciprocal-rank fusion while keeping exact filename/stem matches first.
- [x] Add generation-keyed compact vector snapshots, C ABI status/search functions, tests, and a dependency-free synthetic vector benchmark.

### Model backend and relevance acceptance

- [x] Integrate real dynamically loaded ONNX Runtime CLAP audio/text inference through a refcounted provider.
- [x] Implement and validate the selected pack's real tokenizer and text preprocessing.
- [x] Implement and validate anti-aliased multi-window WAV and uncompressed AIFF/AIFC preprocessing, pooling, and decoding.
- [x] Provide an explicit opt-in pinned installer with integrity/version metadata; model/runtime binaries remain external and the app performs no downloads.
- [x] Run and document a representative licensed real-audio relevance acceptance set; the pinned opaque-name ESC-50 subset and reproducible harness are documented in `core/models/RELEVANCE.md`.
- [x] **Acceptance:** semantic concepts retrieve relevant sounds without filename overlap; lexical exact matches remain first; indexing and search stay usable offline on supported macOS and Linux targets.

## Phase 3 — Acoustic identity and search by example

- [x] Generate robust, versioned landmark acoustic fingerprints for indexed WAV audio with bounded selector retrieval and full offset-vote verification.
- [x] Add search-by-example using deterministically fused fingerprint and CLAP audio-embedding similarity.
- [x] Replace content hashes as the UI's primary duplicate signal with robust duplicate/near-duplicate family information while retaining the legacy ABI.
- [x] **Acceptance:** resampled, level-shifted, and trimmed variants are identified in fixture-based tests with documented precision/recall, and an example clip retrieves its source family (`ACOUSTIC_SEARCH.md`).

## Phase 4 — Scaling and operations

- [x] Add representative indexing/search/waveform benchmarks and enforced regression budgets.
- [x] Add operation counters/status, integrity checks, online backup/recovery, cooperative cancellation, resumable derived indexing, and an optional full-byte deep re-index that does not trust size/mtime.
- [x] Validate large-library storage, memory, latency, bounded waveform/vector retrieval, concurrent semantic readers, and v7-to-v8 upgrade behavior.
- [x] **Acceptance:** `BENCHMARKS.md` publishes a passing one-million-file run with p50/p95 and memory budgets; interrupted scans preserve the prior atomic snapshot, and `OPERATIONS.md` documents tested upgrade/backup/recovery procedures.
