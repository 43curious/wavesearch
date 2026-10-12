# Long-recording semantic coverage experiment

This is the opt-in experiment for [issue #6](https://github.com/43curious/wavesearch/issues/6).
The application's semantic representation remains five-window normalized mean
pooling. Segment scoring is evaluated separately before changing indexing,
storage, fusion, or the public C API.

## Representations

All methods use the verified CLAP pack and canonical 48 kHz mono, ten-second
waveforms, including short-source repetition/zero padding and the int16
compatibility round-trip. All methods keep one vector for sources up to ten
seconds. Float audio retains whole-file finite-sample validation, including
samples outside selected windows.

| Method | Long-recording windows | Recording score | Localization |
| --- | --- | --- | --- |
| `mean5` | Up to five uniform windows, including beginning/end | Canonical normalized mean cosine | Unavailable |
| `uniform16` | Up to sixteen uniform windows, including beginning/end | Maximum individual window cosine | Earliest best window |
| `events16` | Up to eight uniform anchors, plus up to eight energy-rise windows | Maximum individual window cosine | Earliest best window |

`mean5` calls the same pooling implementation as production indexing. The
experiment performs exact Float32 scoring and returns one hit per recording.
More segments cannot occupy multiple result slots, but taking a maximum can
still increase false positives. The existing 0.05 semantic confidence floor
is fixed for this comparison; the experiment does not tune fusion/confidence.
These are semantic-only comparisons, not end-to-end hybrid ranking results.
Existing hybrid tests continue to protect exact filename/stem matches.

Uniform windows are contiguous or overlapping up to 160 seconds, then have
gaps. Event-aware planning uses at least quarter-second energy bins, capped
at 4096, and a complete mono source pass. It selects the strongest positive
energy rises, centers windows on the selected bins, and excludes starts less
than five seconds from an existing start. Silent/steady sources can retain
only the coverage anchors. Sources up to fifty seconds use uniform planning
without the extra energy pass. Energy rises are an event-selection hypothesis:
quiet events, continuous changes, and noisy backgrounds may defeat it.

Audio decoding stays bounded by native sample rate, the ten-second window,
and fixed decode buffers, rather than recording length. Energy analysis adds
8192 Float32 samples, 64 KiB of source scratch, and at most 4096 Float64 bins.
The evaluator retains at most sixteen vectors per asset and accepts at most
2048 files. Per-file output reports duration, inference count, vector count,
payload bytes, and indexing time. Canonical vectors use 2048 bytes per asset;
timestamped segments use 2064 bytes each, up to 33,024 bytes per asset. These
are vector/timestamp payload sizes, **not measured SQLite disk overhead**.

Each method prints a representation identity derived from the verified pack's
model key and its versioned representation revision. Alternatives stay in
memory; provider registration uses a disposable in-memory database. No
experimental vectors enter a persistent catalog. A future production change
must include its representation revision in the actual model identity and
provide atomic source-validated storage/retrieval and queue integration.

## Input and evaluation

Create a JSON corpus containing `files` and `queries`:

```json
{
  "files": [
    {"id": "a", "path": "audio/a.wav", "group": "recording-a", "split": "held_out"},
    {"id": "b", "path": "audio/b.wav", "group": "recording-b", "split": "held_out"}
  ],
  "queries": [
    {
      "id": "bark",
      "text": "a dog barking",
      "split": "held_out",
      "judgments": [
        {"file_id": "a", "grade": 3, "interval": {"start_ms": 30000, "end_ms": 35000}},
        {"file_id": "b", "grade": 0}
      ]
    }
  ]
}
```

Paths are relative to the supplied audio root. Built-in WAV and uncompressed
AIFF/AIFC decoding is supported. A file's `group` identifies its original
recording and all transforms/near duplicates. Groups cannot cross `tuning`
and `held_out` splits. The evaluator rejects duplicate IDs/paths, unknown
judgments, duplicate judgments, split leakage, and intervals outside decoded
media. At least one held-out query is required.

Every query must explicitly grade every file in its split, from 0 (irrelevant)
to 3 (highly relevant). This prevents unjudged results being counted as known
false positives. A query whose judgments are all zero is negative. Do not
infer absent sounds or professional relevance grades from filenames alone.
Use human judgments for ambiguous descriptions, synonyms, multilingual
metadata/text, short transients, negatives, and near duplicates. The harness
uses query text and audio only; metadata/fusion evaluation remains separate.

Per-query and per-split reports include nDCG@10, recall@10 (fraction of all
positive assets returned, rather than the historical first-hit measure),
false-positive counts/fraction among returned hits, and negative-query hit
rate. Means for nDCG/recall exclude negative queries. Localization reports
the fraction of annotated positive assets returned with an overlapping best
window and mean interval intersection-over-union. Missed assets contribute
zero; annotations without a retrieved timestamp contribute zero. Mean pooling
has no localization output, so its zero localization score means unavailable.
Synonymous queries can repeat annotations; localization totals are over
query/asset judgments, not unique events.

The harness reports actual decode/inference/indexing wall time and process
peak RSS. Query inference is excluded from indexing time. In `all` mode,
methods execute sequentially and peak RSS is cumulative; inference caches,
source caches, and backend initialization can affect later methods. Use
separate processes per method and repeat runs for comparable resource costs.
There is no quality pass/fail threshold for these experimental alternatives.

## Reproduce using installed fixtures

The fixture preparer never downloads or replaces data. It verifies source
SHA-256 values from the installed ESC-50 manifest and preserves the dataset
license and derived-source provenance. Its new destination must not exist.

```sh
python3 scripts/prepare-coverage-fixtures.py \
  .relevance/esc50 .relevance/coverage --folds 1 3

cd core
# Window reachability and planned costs; no models/runtime required.
zig build coverage-relevance -- plan \
  ../.relevance/coverage ../.relevance/coverage/corpus.json

# Actual CLAP inference; requires an explicitly installed model/runtime.
zig build coverage-relevance -- \
  "$WS_ORT_LIBRARY" "$WS_CLAP_MODEL_DIR" \
  ../.relevance/coverage ../.relevance/coverage/corpus.json all
```

Omit `--folds` to use all five installed folds. Folds 1–2 are tuning; folds
3–5 are held out. Each fold produces a five-second dog control, 60/180/300
second rain backgrounds with one five-second dog insertion at 30 seconds,
and a gain-scaled near duplicate of the 300-second recording. Source clips
never cross splits. Generated category grades and English/synonym/Spanish
queries are provisional controlled judgments, not professional-library
acceptance. The helicopter query is a constructed negative.

## Validation and remaining acceptance

On 2026-10-12, planning mode ran on the installed ESC-50 folds 1 and 3,
using ten controlled recordings (about 142 MiB of generated fixture data).
Corpus JSON SHA-256:
`306423cabb561010e4d6efbf6276d50c5fc33ec667effe79ab3d6e3173765244`.

| Method | Annotated window reachability | Planned audio inferences | Vector/timestamp payload | Planning wall time |
| --- | --- | --- | --- | --- |
| `mean5` | 40% | 42 | 20,480 bytes | 11.6 ms |
| `uniform16` | 60% | 110 | 227,040 bytes | 6.3 ms |
| `events16` | 100% | 110 | 227,040 bytes | 639.4 ms |

The 180-second event falls between baseline windows; the 300-second event
also falls between sixteen uniform windows. Energy-rise selection reaches
both on these deliberately constructed cases. This demonstrates the remaining
gap in merely increasing uniform sampling, not a recognition/ranking gain.
The baseline/uniform planning timings mostly measure opening/parsing sources;
they exclude waveform decoding and inference. Event planning includes its
complete source pass. These are one sequential warm run on macOS arm64,
not statistically comparable indexing benchmarks. Peak process RSS across
planning methods was about 2.7 MiB; the model/runtime were not loaded.

Per-recording costs in that fixture are:

| Duration | Mean inferences / payload bytes | Uniform segment inferences / payload bytes | Event segment inferences / payload bytes |
| --- | --- | --- | --- |
| 5 seconds | 1 / 2048 | 1 / 2064 | 1 / 2064 |
| 60 seconds | 5 / 2048 | 6 / 12,384 | 6 / 12,384 |
| 180 seconds | 5 / 2048 | 16 / 33,024 | 16 / 33,024 |
| 300 seconds | 5 / 2048 | 16 / 33,024 | 16 / 33,024 |

All inference counts and payload sizes above are planned, not executed or
persisted; there is no new inference-time or catalog-size measurement.

Dependency-free tests exercise canonical window parity, energy bin averaging,
event selection between baseline windows, bounded plans, mean dilution,
best-window timestamps, split leakage, negative metrics, and interval IoU.
Normal core checks also compile the evaluation executable without loading or
downloading optional artifacts.

Actual CLAP per-query/mean ranking, false-positive changes, and retrieved-time
localization still need a verified installed backend. Window reachability
cannot establish semantic recognition. This controlled corpus also cannot
replace independently judged professional-library evaluation. Before promoting
a representation, report held-out quality and costs by recording length,
compare full hybrid ranking against the existing engine, and calibrate any
fusion/confidence changes using tuning data only. Retain a frozen held-out
report and preserve exact filename protection. Issue #6 remains open until
that real-data acceptance and the production decision are completed.
