# Selective semantic retrieval: SQ8 versus exact

Measured 2026-09-08 on Apple M5 Pro, 24 GiB RAM, macOS 26.5.2, Zig 0.16.0 ReleaseSafe, vendored SQLite. No ANN dependency was added.

## Schema-12 follow-up

[Current before/after results](SEARCH_OPTIMIZATION_RESULTS.md) measure 100K
vectors with 16 KiB pages and smaller caches: total disk −37%, query RSS −70%,
and retained recall@256 1.0. Existing 4 KiB catalogs require explicit checked
new-copy compaction to receive the layout savings. Tables below remain the
historical schema-11 measurements; million-scale results were not rerun in that
follow-up. The [large-corpus follow-up below](#large-corpus-follow-up-2026-10-30)
records current 500k–2M measurements and additional core stages.

## Decision and implementation

Use the compact SQ8 path automatically for at least 4,096 matching active-model
embeddings with complete model-wide SQ8 coverage and K ≤ 1,024. For folder or
duration filters, an indexed identity probe stops at 4,096 matches without
reading vector blobs. Small matching sets, incomplete coverage, and larger K
retain exact Float32 retrieval. Both filtered paths start from the existing
folder/duration indexes before reading vector/code payloads.

Schema 11 adds `semantic_sq8`: one normalized Int8 code per canonical embedding, plus Float32 inverse norm and a conservative L2 reconstruction-error bound. A 512-D code occupies 520 bytes versus 2,048 bytes for its original vector. SQLite triggers maintain inserts/updates in the same transaction; foreign keys cascade deletions. Existing catalogs are backfilled transactionally on open, without re-running CLAP. Restore rebuilds derived codes before publishing the staged database. Canonical Float32 vectors remain unchanged.

Retrieval streams codes into a `max(128, 4*K)` seed heap, capped at 4,096 entries, then reranks those IDs using original Float32 vectors from the **same read transaction**. If any excluded candidate's conservative upper bound can beat the exact Kth score, a second compact pass scores the ambiguous candidates exactly. The bounds include query normalization tolerance and Float32 reduction roundoff; ties retain file-ID ordering. This avoids the near-duplicate recall failure of a fixed shortlist. Only working memory is bounded by the seed size: the number of exact evaluations may grow to N in a degenerate corpus.

The read connection remains reusable and serialized. Statements finalize before releasing it, cancellation interrupts both code scans and reranking, and interrupted transactions roll back before reuse. Schema 12 retains connection/active-model validation and additionally checks each scored source hash during hydration. Unrelated embedding-generation changes no longer reject unchanged results; catalog changes during lexical/semantic fusion still reject the mixed snapshot.

## Measured retrieval results

Each row uses 30 deterministic held-out queries plus one separately reported first query. Paired runs alternate exact/SQ8 order. Queries are not corpus vectors. All dimensions are 512.

- **Uniform:** independent normalized uniform random vectors.
- **Clustered:** 64 shared centers plus independent noise of amplitude 0.35.
- **Dense:** the same centers with noise amplitude 0.001, stressing near-duplicates and ties.

Times are milliseconds for SQLite vector retrieval through exact reranking, excluding text/audio embedding inference, lexical retrieval, metadata hydration, and UI publication. These are warm/cache-influenced runs, **not controlled cold-storage measurements**. p95 is the nearest-rank percentile of 30 queries.

| Rows / distribution | K | Exact p50 / p95 | SQ8 p50 / p95 | Mean / minimum recall@K | Maximum Float32 reranks |
|---|---:|---:|---:|---:|---:|
| 10,000 uniform | 20 | 14.800 / 15.380 | 2.727 / 3.030 | 1.000 / 1.000 | 128 |
| 10,000 uniform | 256 | 17.190 / 18.432 | 11.619 / 12.614 | 1.000 / 1.000 | 1,024 |
| 100,000 clustered | 20 | 159.911 / 161.732 | 57.695 / 60.548 | 1.000 / 1.000 | 216 |
| 100,000 dense | 20 | 159.390 / 174.123 | 74.335 / 81.505 | 1.000 / 1.000 | 1,562 |
| 1,000,000 uniform | 20 | 1,647.498 / 1,701.679 | 293.438 / 311.271 | 1.000 / 1.000 | 128 |
| 1,000,000 clustered | 20 | 1,625.337 / 1,724.682 | 567.644 / 608.179 | 1.000 / 1.000 | 421 |
| 1,000,000 dense | 20 | 1,700.545 / 1,823.440 | 805.854 / 840.565 | 1.000 / 1.000 | 15,625 |
| 1,000,000 uniform | 256 | 1,667.078 / 1,757.921 | 310.433 / 334.610 | 1.000 / 1.000 | 1,024 |
| 1,000,000 clustered | 256 | 1,717.238 / 2,019.376 | 624.974 / 713.378 | 1.000 / 1.000 | 1,923 |
| 1,000,000 dense | 256 | 1,781.593 / 1,825.997 | 856.652 / 885.852 | 1.000 / 1.000 | 15,625 |

The million-row runs improve median retrieval by **2.08–5.61×**. Uniform runs need one compact pass; clustered/dense million-row runs need two. At K=20 they read original Float32 vectors for 0.0128%, at most 0.0421%, and 1.5625% of the respective corpora.

The automatic folder path over the million-row corpus visited only 1,000 matching vectors: p50 **12.168 ms**, p95 **13.926 ms**, query-process peak RSS **25.14 MiB**. The 1,000-row smoke test confirmed automatic selection stays exact for small collections.

Separate-process uniform million-row measurements, excluding corpus generation:

| Mode | p50 / p95 ms | Peak process RSS |
|---|---:|---:|
| Exact | 1,642.236 / 1,707.061 | 83.33 MiB |
| Auto → SQ8 | 289.449 / 307.457 | 83.34 MiB |

RSS includes SQLite caches and process overhead, not OS filesystem cache or only the algorithm's buffers. RAM does **not** substantially decrease versus the already-streaming exact baseline; it stays bounded rather than loading the 2.048 GB Float32 payload. A separate dense auto run used 83.36 MiB, with p50/p95 780.698/788.507 ms.

A subsequent cache-pressure check reported first exact queries of 8.28–8.74 seconds versus 1.52–2.41 seconds for SQ8. Cache state was not controlled, so these are not cold-I/O acceptance numbers.

## Disk and build costs

Measured with SQLite page counts before and after building the compact table on a vacuumed synthetic database. Sizes include real SQLite storage overhead, not just theoretical vector payloads.

| Rows | Original database bytes | Added SQ8 bytes | Total database bytes | SQ8 build time |
|---|---:|---:|---:|---:|
| 10,000 | 51,871,744 | 5,865,472 | 57,737,216 | 45.607 ms |
| 100,000 | 518,082,560 | 58,531,840 | 576,614,400 | 479–497 ms |
| 1,000,000 | 5,182,980,096 | 585,162,752 | 5,768,142,848 | 7.54–7.98 s |

At one million rows this adds **558.05 MiB / 11.29%** to this database. Code payload is 520 MB; B-tree overhead accounts for the rest. Original database size includes metadata, FTS, and Float32 B-tree/overflow pages. The highest observed generation/build process RSS was **165.94 MiB**; full fixture generation took 106–124 seconds, separately from query timings.

The production migration runs through the existing off-main database-open path and is atomic, but **library readiness waits for this one-time backfill**. WAL/journal and temporary storage require additional headroom; the table above is final disk size, not peak migration disk usage. No automatic vacuum of a user's library is introduced.

## Alternatives rejected by measurement

- An SQLite expression index initially looked simpler, but SQLite performed a canonical `WITHOUT ROWID` table lookup per index entry. At 100,000 clustered vectors it took about **661 ms** versus **160 ms** exact. The compact table avoids those lookups during the coarse scan.
- A fixed SQ8 top-128 shortlist achieved only **0.160 mean / 0.050 minimum recall@20** on the 100,000-row dense fixture, despite exact reranking. Error-bound refinement restores 1.000/1.000; increasing oversampling alone is not a correctness strategy.
- No ANN implementation was benchmarked, and these results do **not** establish that SQ8 beats ANN. SQ8 was chosen as the smallest measured improvement that preserves exact-score ranking without graph training, separate synchronization, or a new dependency.

## Reproduce

```bash
# Small smoke run; all temporary databases are removed automatically.
bash scripts/benchmark-semantic.sh 10000 30 20

# Million-row evaluation; several minutes, roughly 6 GB final data per corpus
# plus temporary/journal headroom. Only one corpus is retained at a time.
bash scripts/benchmark-semantic.sh 1000000 30 20
bash scripts/benchmark-semantic.sh 1000000 30 256
```

The script runs paired recall measurements and separate exact/auto processes for RAM comparisons. `compare` exits nonzero if recall differs from 1.0 or a reranked score differs from the exact Float32 score. Corpus generation refuses to overwrite an existing path.

For representative CLAP embeddings, use consecutive normalized 512-D little-endian Float32 rows, without headers, and an independent held-out query file:

```bash
cd core
zig build semantic-bench -- create /tmp/real-clap-benchmark.sqlite 100000 uniform /path/corpus.f32
zig build semantic-bench -- compare /tmp/real-clap-benchmark.sqlite 100 256 -1 /path/held-out-queries.f32
zig build semantic-bench -- exact /tmp/real-clap-benchmark.sqlite 100 256 -1 /path/held-out-queries.f32
zig build semantic-bench -- auto /tmp/real-clap-benchmark.sqlite 100 256 -1 /path/held-out-queries.f32
```

The supplied distribution label is unused when importing vectors. Evaluation requires a benchmark marker and does not accept a live application database as its corpus. Remove the explicitly created benchmark database after use.

## Validation

- ReleaseSafe core suite: 78 passed, 2 skipped; public C ABI executable passed.
- Regression coverage includes exact scores/ties, selective filters, dense-neighborhood refinement, source/model changes, deletion, v10 backfill, rebuilding corrupted backup codes, and cancellation/reader recovery.
- Scalar error-bound checks cover dimensions 1, 7, 8, 9, 512, and 65,536.
- Universal framework, Debug macOS build, and app lifecycle harness passed.
- Temporary-corpus script and imported-Float32/held-out-query path passed smoke checks. Generated benchmark databases were removed; existing project benchmarks and the live library were not modified.

## Remaining limits

These synthetic measurements are **not real-audio relevance or end-to-end UI latency claims**. Run the imported-CLAP benchmark and controlled cold-SSD/HDD/network tests before establishing broader latency targets. Compact scans remain O(N×dimension), and difficult neighborhoods can require additional Float32 reads. If representative million-vector queries need consistently sub-250 ms retrieval, evaluate IVF/HNSW plus exact reranking against this baseline with the same recall, RSS, disk, build, cancellation, and update-consistency measurements—not an assumption that ANN must win.

## Filtered population selection (2026-10-11)

Automatic selection now uses matching population rather than filter presence.
The identity probe reads no vector blobs and stops at 4,096 matching embeddings;
it can inspect more catalog identities when the active model is sparse. Coverage
remains a conservative model-wide check: missing SQ8 rows anywhere select exact.
No extra persistent index, migration, model inference, or ANN is introduced.

A disposable 100,000-vector, 512-D uniform corpus used 30 held-out queries,
K=256, the existing 16 KiB layout, Zig 0.17.0 `safe`, macOS arm64, and local
storage. The first 50,000 files were assigned to folder 0; another 50 already
belonged to that folder. Paired comparisons alternate exact/automatic order:

| Filter / matching vectors | Exact p50 / p95 ms | Automatic p50 / p95 ms | SQ8 | Mean / minimum recall@256 |
| --- | ---: | ---: | --- | ---: |
| Folder 0 / 50,050 | 58.774 / 65.152 | 26.723 / 29.484 | Yes | 1.000 / 1.000 |
| Folder 1 / 50 | 0.159 / 0.171 | 0.223 / 0.238 | No | 1.000 / 1.000 |
| Duration <= 100,000 ms / 100,000 | 121.250 / 124.864 | 53.637 / 55.781 | Yes | 1.000 / 1.000 |

Broad-folder logical payload reads fell from 102,502,400 to 28,123,152 bytes;
broad-duration reads fell from 204,800,000 to 54,097,152 bytes. These totals
count code scans, refinement passes, and Float32 reranks, excluding metadata,
probe work, B-tree overhead, and page-cache effects; they are not physical disk
I/O. Broad cases reranked 1,024 original vectors without a refinement pass.
Paired-process peak RSS was 26,542,080 bytes for broad cases and 9,207,808 for
selective work; this does not establish a per-backend memory saving.

The selective case adds about 0.067 ms at p95 for the population probe. Separate
first queries were cache-influenced (broad folder exact/auto 216.361/115.215 ms;
broad duration 1,219.897/327.510 ms) and are not controlled cold-storage results.
The previous planner's broad-folder automatic path selected exact, with
57.923/61.255 ms p50/p95 in its standalone baseline.

Reproduce using exclusively created benchmark catalogs:

```sh
cd core
zig build semantic-bench -Doptimize=safe -- create /tmp/ws-filtered.sqlite 100000 uniform
sqlite3 /tmp/ws-filtered.sqlite 'BEGIN; UPDATE files SET folder_id=0 WHERE id<=50000; COMMIT;'
zig build semantic-bench -Doptimize=safe -- compare /tmp/ws-filtered.sqlite 30 256 0
zig build semantic-bench -Doptimize=safe -- compare /tmp/ws-filtered.sqlite 30 256 1
zig build semantic-bench -Doptimize=safe -- compare /tmp/ws-filtered.sqlite 30 256 -1 - 0 100000
```

The optional positional duration bounds follow `queries.f32`, or `-` for
synthetic queries. Imported real vectors and held-out query files remain
supported. `compare` uses the automatic planner; `quantized` still forces the
compact path for diagnostic comparisons. Run `exact` and `auto` separately for
backend-specific RSS, and keep fixture construction/storage costs separate.

Core tests compare exact IDs, order, and scores for broad/selective filters,
partial coverage and dense ties, and interrupt the population probe inside
SQLite. Real CLAP vectors, inference/lexical/hydration/UI end-to-end latency,
million-file filtered workloads, and controlled cold-storage tests were not run.

## Large-corpus follow-up (2026-10-30)

Issue [#30](https://github.com/43curious/wavesearch/issues/30) adds measurement
coverage to the existing exact/SQ8 implementation. Retrieval, ranking, schema
and the C API retain their existing behavior. No ANN or mapped vector store was
added.

### Method and stage boundaries

Apple M5 Pro, 24 GiB RAM, macOS 26.5.2 arm64, Zig 0.17.0 `safe`, vendored
SQLite, internal SSD, schema 18. Each exclusively created disposable catalog
contains deterministic metadata and normalized 512-D **synthetic** vectors.
Uniform, 64-center clustered and dense near-duplicate distributions use the
same generators as the historical measurements above. Thirty generated queries
are disjoint from corpus and update seeds; an additional first query is reported
separately. Warm percentiles use nearest rank. Runs are sequential, with one
catalog retained at a time and separate processes for exact, automatic,
folder-filtered and pipeline peak RSS. Repository HEAD advanced from `5197270`
to `3ef7712` during the campaign. The intervening selects/MP3 metadata changes
retain schema 18 and the timed synthetic generator, retrieval, hydration and
fusion paths; other developer activity was not isolated. These runs therefore
do not establish uncontended latency or a hard budget.

- `compare` alternates exact/automatic order and checks equal result counts,
  exact Float32 scores, IDs and ordering. It reports recall@K and separately
  times `candidatesForSemanticIds`, checking hydrated source hashes.
- `pipeline` alternates lexical and production `searchWithEmbedding` calls,
  cycling the eight synthetic filename categories. It measures the complete
  core call, including lexical work, vector selection, hydration, fusion and
  copying results. K=20 uses the production candidate depth of 80, whereas the
  retrieval table uses K=20. These separate timings cannot be added or subtracted
  to infer individual fusion costs. Lexical calls have no host request cache.
- `startup_ms` separates benchmark-marker/count validation from production
  `db.open`. The semantic reader opens lazily during the first retrieval, so
  `db_open` alone is not time to first search. Both are cache influenced.
- `update` replaces the first 1,000 synthetic embeddings using the production
  per-file transaction, including derived SQ8 codes/counters. Generation is
  outside the timer; each commit is inside. Update p50/p95 include the first
  update. The script reopens and repeats the exact comparison afterward.
- Build/index timings use the existing fixture creation path. Final SQLite
  page bytes exclude transient journals, WAL, temporary space and source audio;
  peak RSS excludes OS filesystem cache. Neither measures physical device I/O.

Text/audio inference, the host's refinement delay and UI publication are
excluded. The pipeline's generated vectors are not inferred from its text;
its timings establish cost, not real sound relevance. First-process queries
and warm percentiles are **not controlled cold-storage measurements**.

### Current latency and correctness results

All nine corpora retain mean/minimum recall@20 **1.000/1.000**, identical IDs,
order and Float32 scores before and after 1,000 embedding replacements and
reopen. Tables use separate-process exact/automatic retrieval; the paired
comparisons establish recall rather than backend-specific RSS. Times are ms.

| Vectors / distribution | Exact p50 / p95 | Automatic p50 / p95 | Lexical p50 / p95 | Hybrid core p50 / p95 |
| --- | ---: | ---: | ---: | ---: |
| 500,000 uniform | 459.0 / 462.6 | 110.8 / 111.7 | 53.6 / 54.4 | 167.8 / 176.6 |
| 500,000 clustered | 444.5 / 456.1 | 215.0 / 218.7 | 56.7 / 60.3 | 290.4 / 314.2 |
| 500,000 dense | 480.2 / 507.8 | 263.6 / 282.2 | 56.0 / 56.9 | 313.5 / 315.5 |
| 1,000,000 uniform | 914.1 / 962.5 | 222.5 / 232.6 | 110.3 / 113.7 | 336.8 / 341.8 |
| 1,000,000 clustered | 887.9 / 892.5 | 422.7 / 428.4 | 110.0 / 119.1 | 544.7 / 596.5 |
| 1,000,000 dense | 883.2 / 888.4 | 480.9 / 489.0 | 109.6 / 110.4 | 601.7 / 603.0 |
| 2,000,000 uniform | 1780.1 / 1799.9 | 441.5 / 444.7 | 223.6 / 225.9 | 673.3 / 675.3 |
| 2,000,000 clustered | 1785.6 / 1799.2 | 839.3 / 855.8 | 221.6 / 228.5 | 1085.8 / 1104.3 |
| 2,000,000 dense | 1784.5 / 1822.6 | 983.0 / 1021.2 | 221.4 / 225.3 | 1209.1 / 1216.4 |

Uniform retrieval needs one compact pass and 128 Float32 reranks. At 2M,
clustered queries need a second compact pass and up to 505 reranks; dense
queries need that pass and up to 31,250 reranks. Conservative refinement keeps
exact ranking. Automatic result hydration stays below **0.4 ms p95** in all nine
standalone global runs.

Selective folder 0 retains exact retrieval, with matching populations below
the 4,096-vector threshold. Uniform-corpus measurements:

| Catalog vectors | Matching vectors | Filtered retrieval p50 / p95 ms |
| ---: | ---: | ---: |
| 500,000 | 500 | 6.0 / 6.2 |
| 1,000,000 | 1,000 | 12.8 / 13.2 |
| 2,000,000 | 2,000 | 26.9 / 27.4 |

### Storage, construction, startup and updates

Final SQLite sizes are identical across distributions at each size. Construction
ranges cover the three independently created corpora; these are single builds,
not build-time percentiles. Fixture construction includes metadata/FTS, vector
generation, VACUUM and SQ8 construction, excluding audio decoding/inference.

| Vectors | Final DB bytes | Added SQ8 bytes | SQ8 build seconds | Complete fixture seconds |
| ---: | ---: | ---: | ---: | ---: |
| 500,000 | 1,818,853,376 | 303,415,296 | 1.33–1.55 | 48.49–53.20 |
| 1,000,000 | 3,636,903,936 | 606,846,976 | 2.61–2.85 | 109.95–132.50 |
| 2,000,000 | 7,273,054,208 | 1,213,644,800 | 6.27–6.54 | 255.68–270.10 |

Ranges below cover the three distributions and their standalone query processes.
Open is measured once per process, after benchmark validation, and has no startup
percentile claim. It excludes loading the semantic reader and the app/model/UI.

| Vectors | Retrieval peak RSS MiB | Hybrid peak RSS MiB | `db.open` ms | 1,000 replacements ms total |
| ---: | ---: | ---: | ---: | ---: |
| 500,000 | 35.95–36.19 | 42.23–42.59 | 2.39–9.53 | 70.19–74.53 |
| 1,000,000 | 36.00–36.17 | 45.31–45.64 | 2.53–4.45 | 70.33–71.20 |
| 2,000,000 | 36.00–36.16 | 53.66–53.86 | 3.32–7.41 | 71.08–72.71 |

Across all sizes, individual replacement p50 is **0.066–0.072 ms**, p95
**0.075–0.085 ms**. This measures existing embeddings replaced in separate
production transactions, with the catalog's normal WAL policy; it is not an
audio reindex, a batch-import measurement or a power-loss durability test.
Fixture-build peak RSS stays below **112 MiB**. Final disk rises from 1.69 GiB
at 500k to 6.77 GiB at 2M; retrieval does not retain a corpus-sized vector array.

The measurements show a global latency cost worth profiling: even uniform 2M
retrieval exceeds 250 ms, and broad lexical work alone approaches 230 ms p95.
They support testing alternatives with representative vectors and queries,
rather than establishing an ANN/mapped-storage choice or a relevance tradeoff.
Selective retrieval remains much cheaper, so file count alone is insufficient.

### Reproduction and remaining acceptance

```sh
# Normal checks compile the harness without creating large catalogs.
make check-core

# All three distributions, one disposable catalog at a time.
# Allow final catalog space plus VACUUM/journal headroom in TMPDIR.
for count in 500000 1000000 2000000; do
    bash scripts/benchmark-semantic.sh "$count" 30 20
done

# Optional fourth argument selects a single distribution; ZIG is honored.
bash scripts/benchmark-semantic.sh 500000 30 20 dense

# Individual commands require an exclusively created benchmark database.
cd core
zig build semantic-bench -Doptimize=safe -- create /tmp/new-semantic.sqlite 10000 uniform
zig build semantic-bench -Doptimize=safe -- pipeline /tmp/new-semantic.sqlite 30 20
zig build semantic-bench -Doptimize=safe -- pipeline /tmp/new-semantic.sqlite 30 20 -1 - 500 30000
zig build semantic-bench -Doptimize=safe -- update /tmp/new-semantic.sqlite 1000
zig build semantic-bench -Doptimize=safe -- compare /tmp/new-semantic.sqlite 30 20
```

The positional folder/query-file/duration arguments match `auto`. Pipeline
translates inclusive duration bounds to the public query parser's strict
`>`/`<` syntax. Imported vectors still require independent held-out query rows;
`update` accepts synthetic catalogs only. The pipeline keeps synthetic metadata
and text categories even with imported vectors, so it is not a representative
real-library query benchmark.

Issue #30 remains open for actual CLAP vectors and held-out queries, inference
and UI publication, controlled cold/removable/network storage, and interrupted
update/recovery measurements at these sizes. Existing core tests cover
source/model changes, cancellation and atomic update/restore behavior; successful
large-corpus updates do not replace crash-recovery acceptance. No measured
quality tradeoff or new latency promise is shipped by this follow-up.

Validation for this follow-up: all nine large campaigns, imported/filtered query
checks, rejected truncated/imported-update inputs, unmarked-catalog preservation,
core/C ABI/fuzz checks, macOS app build and headless checks, and Linux
cross-compilation passed. `make check` stopped at desktop preflight: window and
Settings GUI checks require an active logged-in desktop/display unavailable in
this session. No real-model or controlled cold/removable-storage acceptance ran.
