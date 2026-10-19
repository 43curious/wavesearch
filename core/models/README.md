# CLAP model backend

WaveSearch supports the pinned `muzaiten/clap-htsat-base-onnx` pack through a
dynamically loaded ONNX Runtime. Neither models nor ONNX Runtime are committed,
bundled, or downloaded automatically. Normal builds and tests need neither.

## Explicit installation

On Apple silicon Macs, use **Settings → General → Optional semantic search**.
Review the linked model/runtime terms, then choose **Agree and download**.
The native installer shows per-file download progress, verifies the same pinned
SHA-256 values as the CLI, and unpacks only the verified runtime archive.
It runs network, hashing, extraction and filesystem work off-main. Cancel waits
for actual work and staging cleanup; retry starts a fresh download rather than
resuming partial bytes. Startup only checks whether the installation exists.

Model files download directly from the pinned Hugging Face revision and runtime
files from Microsoft's pinned GitHub release. No audio is uploaded. The sandbox
has outgoing-network permission for this explicitly invoked flow. Allow 1.5 GB
of free disk space for staging. The UI does not offer the pinned runtime on Intel
Macs. Linux hosts retain the CLI path below.

**Verify or repair installation** first hashes existing model files, checks the
runtime, and skips downloads when valid. Native installs record the extracted
library's SHA-256 in `runtime.sha256`; CLI installs without this receipt check
runtime presence and defer compatibility validation to provider loading.
Repairs stage a full replacement on the destination filesystem, then atomically
exchange directories. The previous bundle is retained as
`wavesearch-clap.previous-<UUID>` beside the installation; remove it manually
when no longer needed. A failed download/verification leaves the old bundle
untouched. A process crash may leave a hidden `.wavesearch-clap-<UUID>` staging
directory; it is never discovered as an active model pack.

Provider loading continues to follow the background refinement policy; Fast
only leaves it unloaded. **Retry semantic provider** retries a failed load
without redownloading. Configuration through `WS_CLAP_MODEL_DIR` and
`WS_ORT_LIBRARY` still takes precedence over the default installation. Loading
failure is shown in Settings and lexical search remains usable. Shutdown cancels
and drains installation work before closing the core. Catalog/library recovery
does not own or delete installed model bundles.

For terminal installation, review and explicitly run:

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

`bash scripts/test-clap-installer.sh` from the repository root uses tiny local
fixtures and injected downloads; it never downloads models/runtime. It covers
absent/corrupt/partial artifacts, network failure and retry, cancellation/drain,
unsupported platforms, atomic repair with retained backups, CLI pin compatibility,
and lexical search after a real provider-load failure. It is included in
`make check-macos-headless`. Like the lifecycle/policy/watcher scripts, it supports
`WS_CORE_LIBRARY` and `WS_CORE_HEADERS` overrides.

The fixture checks do not establish successful real-model download/inference,
desktop interaction, or runtime loading in a signed hardened release. That last
acceptance depends on the release configuration in
[#11](https://github.com/43curious/wavesearch/issues/11). The current host's Xcode
project build aborts during runtime initialization; direct Swift compilation
and deterministic checks provide partial validation only. No library-validation
bypass or hardened-runtime exception is added by this installer.

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
