# CLAP relevance acceptance

WaveSearch's Phase 2 relevance gate uses a pinned subset of the
[ESC-50 dataset](https://github.com/karolpiczak/ESC-50), commit
`33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6`. ESC-50 is distributed under
CC BY-NC 3.0; the fixture installer preserves its license and a manifest with
each original filename and SHA-256 digest. Fixtures are opt-in and are not
included in WaveSearch distributions.

## Method

`scripts/install-relevance-fixtures.sh` selects the first clip from each of the
five official folds for eight sound-effect categories: dog, rain, sea waves,
footsteps, helicopter, chainsaw, clock tick, and crackling fire. It renames all
40 files to opaque `clip-NNN.wav` names before indexing, preventing lexical
filename overlap from satisfying the test.

The `zig build relevance` harness indexes and embeds every clip with the pinned
CLAP model pack, searches each natural-language category, and measures the first
relevant result among the top five, plus graded nDCG@10 over ten results.
ESC-50 acceptance requires top1 >= 0.80, recall@5 >= 0.75, MRR@5 >= 0.50 and
mean nDCG@10 >= 0.75. Existing deterministic tests separately require exact lexical
filename/stem matches to remain ahead of semantic-only results in hybrid search.

## Reproduce

```sh
./scripts/install-relevance-fixtures.sh
cd core
zig build relevance -- \
  "$WS_ORT_LIBRARY" "$WS_CLAP_MODEL_DIR" \
  ../.relevance/esc50/audio ../.relevance/esc50/labels.tsv
```

## Graded catalog judgments

Supply an optional fifth argument after `LABELS_TSV`: a TSV with
`query<TAB>filename<TAB>grade` (integer 0–3), no header. Comment lines start with
`#`; filenames must occur in labels. Unjudged results score zero. This mode
requires mean nDCG@10 >= 0.75 and reports per-query ranks/grades and top1,
recall@5 and MRR@5. Duration filters are excluded from the inferred text.

The dependency-free `zig build optimization-bench -- quality NEW_DB 1` uses
`core/src/fixtures/search-quality.json`: 15 descriptors, 24 graded queries and
imperfect controlled 8-D vectors. Its nDCG >=0.95 gate exercises retrieval and
fusion, not CLAP inference. Measured baseline 0.793313 → schema-12 1.000000;
see [results and limits](../../documentation/SEARCH_OPTIMIZATION_RESULTS.md).
The updated real inference gate was not rerun: runtime/model artifacts were
unavailable. The pinned result below is historical, not a new validation.

## Pinned backend result

On macOS arm64 with ONNX Runtime 1.29.0 and the verified
`muzaiten/clap-htsat-base-onnx` pack:

```text
clips=40
categories=8
top1=1.000
recall@5=1.000
mrr@5=1.000
```

All eight queries returned a correctly labelled opaque clip at rank 1. The
installer and inference are network-independent after artifacts are present;
macOS arm64 and Linux x86_64 library builds are validated separately.
