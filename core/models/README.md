# CLAP model backend

WaveSearch supports the pinned `muzaiten/clap-htsat-base-onnx` pack through a
dynamically loaded ONNX Runtime. Neither models nor ONNX Runtime are committed,
bundled, or downloaded by the app/build/tests.

## Explicit installation

Review and explicitly run:

```sh
./scripts/install-clap-model.sh
# macOS defaults to WaveSearch's sandbox container and is auto-discovered.
# Pass an explicit directory to use environment-variable configuration instead.
```

Supported pinned runtime platforms are macOS arm64 and Linux x86_64. The script
fails clearly on macOS x86_64 because the pinned ONNX Runtime release does not
provide the selected artifact. Downloads use a pinned Hugging Face commit and
ONNX Runtime 1.29.0, verify hardcoded SHA-256 values, stage on the destination
filesystem, and atomically rename the completed installation.

The current model/runtime disk sizes are approximately:

- `audio.onnx`: 285,177,239 bytes (272 MiB)
- `text.onnx`: 501,450,229 bytes (478 MiB)
- `tokenizer.json`: 3,558,642 bytes (3.4 MiB)
- ONNX Runtime macOS arm64 library: 43,184,400 bytes (41 MiB)
- complete model pack: 790,186,924 bytes (about 754 MiB)

See `THIRD_PARTY_NOTICES.md` before installing.

## Runtime contract

`manifest.json` must have `format_version=1`, `vector_dimension=512`, nonempty
model/checkpoint/feature revision fields, and exactly `audio.onnx`, `text.onnx`,
and `tokenizer.json` entries with byte size and lowercase SHA-256. WaveSearch
streams and verifies every artifact before parsing/loading it. The immutable DB
model identity hashes the model/checkpoint/revision and all artifact identities.

The macOS app auto-discovers the installer's default container location. For
custom locations or Linux hosts, set:

```sh
export WS_ORT_LIBRARY=/absolute/path/to/libonnxruntime.dylib # .so on Linux
export WS_CLAP_MODEL_DIR=/absolute/path/to/model
export WS_CLAP_THREADS=2 # optional; defaults to 2 in the app
```

The separately downloaded runtime is supported for local/developer and direct
distribution builds. It is not an App Store-compatible executable-code delivery
mechanism; an App Store release must bundle and sign ONNX Runtime with the app.
If configuration is absent, loading fails, or query inference fails, normal
lexical search remains available. After loading, existing pending files are
indexed resumably in the background. Long recordings use up to five uniformly
spaced 10-second CLAP windows (including start and end); individually normalized
window vectors are mean-pooled and normalized again. The pooling revision is
part of model identity, so older center-window embeddings are never mixed. Semantic indexing currently decodes **WAV and uncompressed AIFF/AIFC**. Other indexed audio extensions are recorded as unsupported failures;
there are no placeholder embeddings. Built-in decoding supports WAV and
uncompressed AIFF/AIFC; optional host decoders can provide finite interleaved
PCM for search-by-example through the additive C ABI.

An opt-in [coverage experiment](../../documentation/SEMANTIC_COVERAGE_EXPERIMENT.md)
compares that baseline with bounded timestamped segments and energy-aware
selection. Experimental vectors stay outside persistent catalogs; the default
representation and its identity remain unchanged.

## C provider flow

- `ws_clap_load(runtime_library_path, model_dir, intra_op_threads)` verifies,
  loads, registers, and activates the pack.
- `ws_clap_index_pending(folder_id, max_files)` resumes pending WAV work in
  bounded batches; `-1` means all folders and `0` means no file limit.
- `ws_search` automatically runs hybrid text retrieval while loaded.
- `ws_clap_unload()` drains active query/audio references safely.
- `ws_semantic_status` reports embedded, pending, failed, and provider state.

The compiled audio and tokenizer implementation revisions are included in the
model identity, so preprocessing changes force a fresh semantic generation.
Only deterministic unsupported/corrupt audio failures are persisted; transient
I/O/runtime/database failures remain pending for retry. Schema 13 uses
[durable pending queues](../../documentation/REFINEMENT_QUEUES.md) across bounded
calls and reopen; registering a new model creates independent pending work.

The lower-level external embedding ABI remains available for compatible custom
providers: `ws_semantic_model_set`, `ws_semantic_embedding_upsert`, and
`ws_search_with_embedding`.
