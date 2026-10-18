# Embedding libwavesearch

The public contract is [wavesearch.h](../core/include/wavesearch.h). The library
is synchronous and process-global: one catalog and optional provider per process.
The native host owns worker admission, file permissions, playback and shutdown.
No API invokes host callbacks or dispatches onto a host executor.

## Compatibility negotiation

Call `ws_abi_version()` before `ws_init()` and require equality with
`WS_ABI_VERSION`. This integer identifies the C calling/layout contract, separately
from the app version, database schema, model identity and waveform codec.

Use `ws_capabilities()` to check the API families required by the host:

```c
uint64_t required = WS_CAP_QUERY_CANCELLATION | WS_CAP_WAVEFORM_V1;
if (ws_abi_version() != WS_ABI_VERSION ||
    (ws_capabilities() & required) != required) {
    /* Reject this library before opening the catalog. */
    return 1;
}
if (ws_init(database_path) != 0) {
    /* Copy ws_last_error_message() on this thread. */
    return 1;
}
```

Both queries are allocation-free, thread-safe and valid before initialization
and after shutdown. Bits describe compiled API support, are stable throughout
the process, and allow unknown bits to be ignored. They do not describe catalog
contents or runtime readiness. `WS_CAP_CLAP` means the verified provider APIs
exist; it does not imply installed models, a compatible runtime, a loaded
provider or any embeddings. Use `ws_semantic_status` after initialization for
runtime state. The other bits cover external semantic embeddings, query-local
cancellation, streaming waveform v1, exact duplicate verification and fingerprint
storage repacking, as named in the header.

Additive functions and capability bits retain the ABI version. Existing function
signatures, struct layouts, capability-bit assignments and ownership semantics
stay fixed within that version. Incompatible layouts require new types/entry points; an incompatible
global contract requires a new ABI version. A newer optional API needs a capability
check even when the ABI version matches. Static callers must link against a
library providing every symbol they reference. A host loading a library dynamically
must first look up the negotiation symbols; if either is absent, reject it as a
legacy library without this negotiation contract. This repository currently
builds a static library/XCFramework, not a shared-library loader.

## Buffers, strings and errors

All input strings, vectors, PCM, serialized bytes and configuration structs are
borrowed for the duration of the call. Keep them valid and unchanged until the
call returns. The core retains copies/derived state where necessary. Caller-owned
outputs must be sufficiently sized, correctly aligned and exclusively writable.
Result structs contain copied inline strings; there are no borrowed database-row
pointers. Never pass a library handle to `free` or free a diagnostic string.

Strings use NUL-terminated UTF-8 bytes. Fixed path/name arrays can truncate by
bytes, including inside a Unicode sequence; the current API is not a lossless
long-path interface. Buffer capacities count elements for result/peak/float arrays
and bytes for serialized caches. Initialize every `WSExampleResult` element's
`struct_size`, including unused capacity. Read only the count returned by a
successful array call. Discard output on failure/cancellation unless that
function explicitly documents a size-query result.

Zero-initialize versioned structs and set `struct_size = sizeof(the declared
type)`. Status, work, identity, verification and storage outputs accept sizes at
least as large as their current type, write only that type and return its size
and version. Smaller callers are rejected; this is not prefix negotiation for
historically smaller status types. `WSExampleResult` array elements require an
exact size because the core indexes the array using its compiled stride.
Waveform config, PCM and result-info structs require both exact size and the
declared input version. Never pack public structs or repurpose reserved fields.
Changing a size field cannot make a smaller allocation valid.

Most catalog calls return `-1` on failure; successful counts, cache misses,
integrity findings and work claims have function-specific meanings documented
in the header. Request-aware calls additionally return `WS_QUERY_CANCELLED`
(`-2`); streaming waveform APIs use `WS_WAVEFORM_ERROR_*` codes.
`ws_last_error_message()` returns a borrowed, bounded, NUL-terminated thread-local
diagnostic. Copy it immediately on the worker that observed the failure.
Another failure on that thread overwrites it, success may leave it unchanged,
and thread exit invalidates the pointer. Diagnostic text is not a stable error
code protocol.

## API families and concurrency

All potentially blocking filesystem, database, decoding, DSP and inference calls
belong on workers. Internal locks protect shared state but do not provide bounded
host admission, a UI-latency guarantee, or lifecycle isolation between calls.

| Family | Initialization and lifetime | Concurrency and blocking |
| --- | --- | --- |
| ABI/capabilities; refinement queue selection | No catalog needed. Caller owns the queue cursor. | Queries are constant; synchronize each cursor in the host. |
| `ws_init`, `ws_deinit`, `ws_backup_restore` | Exclusive host lifecycle transition. `ws_init` opens/creates one SQLite catalog, replacing any previous one; it can migrate schema and unloads the provider. Restore also unloads the provider. | Stop admission and drain all catalog/provider calls before entering. Internal mutation/database locks are not a whole-host drain. |
| Scan, remove, backup-create, CLAP load/unload, model-set, acoustic/semantic refinement, cache-clear | Require the catalog. Retain source permissions until calls finish. Drain waveform producers before cache-clear and clear host memory caches afterward. | These mutations share a core mutation mutex. A scan holds it through walking/staging/publication; old snapshots remain searchable. Host should admit bounded work instead of queueing many blocked calls. |
| Search/list, semantic embeddings/status, acoustic groups/status, file identity, waveform cache/tier/work operations, integrity, backup-compact, fingerprint repack | Require the catalog. Cache/work/source identities must match current rows; work claims are leases, not owning memory handles. | Main SQLite connection has a mutex; semantic retrieval has a serialized reusable reader. Index staging/publication uses a separate connection. Multi-call sequences are not transactions. Compaction and repacking can perform substantial work without the outer mutation mutex. |
| Query handles and request-aware search/list/duplicate/repack | Create/destroy do not require a catalog. Data operations require it. One fresh handle per logical request; sequential lexical/hybrid reuse is allowed. | One operation at a time per handle, with concurrent `ws_query_cancel`. Different handles are independent; catalog/provider locks can still serialize work. Cancellation is sticky. Join calls and cancellers before destroy. NULL cancel/destroy are harmless. |
| Scan/refinement cancellation, operation status, refinement generation | No catalog needed. Generation and operation counters are process-global. | Atomic status/cancel calls do not acquire the mutation mutex. `ws_cancel_indexing` requests cancellation of scans and derived work; `ws_cancel_refinement` affects derived work only. Status snapshots are informational, not admission/drain barriers. |
| Exact duplicate verification/count | Require catalog and readable source files; no source ownership transfers. | May read complete files. Request-aware verification supports local cancellation; the legacy count has no query handle. Keep file access until return. Hash equality alone is not byte identity. |
| Legacy `ws_waveform` | Can decode without an open catalog; uses the catalog as a best-effort cache when open. | Synchronous file/DSP work runs outside the mutation lock; cache publication checks catalog/source identity. Drain it with other source/catalog work. |
| Streaming waveform analyzer | No catalog needed. `create` returns an owned analyzer; `finish` returns a separately owned immutable result. Destroy both exactly once. | Sequential create/push/finish on each analyzer; finish at most once. Concurrent cancel is allowed. Join push/finish and cancellers before destroy. PCM and plane arrays are borrowed only during push. |
| Waveform results | No catalog needed. Create/deserialize copy input into a library-owned handle. Results outlive their analyzer and can survive catalog shutdown. | Immutable handles allow concurrent info/copy/serialize calls with separate output buffers. Join all readers before result-destroy. NULL analyzer/result destroy is harmless. |

Provider loading verifies files and builds sessions outside its publication lock
so lexical search can continue. Unload detaches the provider, prevents new
references and waits for existing provider references before freeing sessions.
Inference is serialized by the ONNX session mutex. This reference drain does
not drain other host filesystem/database work or pending dispatches.

## Cancel and shut down

1. Stop admitting catalog/provider/source work, including deferred preparation.
2. Cancel active query/analyzer handles and scan/refinement work as appropriate.
   Capture `ws_refinement_generation()` before dispatching deferred refinement;
   pass it to a `_v2` indexing call to reject work canceled before registration.
3. Join actual blocking calls and concurrent cancellers. An OS read or native
   inference call may finish before cancellation is observed. Keep request
   handles, input/output buffers and security-scoped file access alive throughout.
4. Destroy query/analyzer handles after their users finish. Call `ws_deinit()`
   exclusively, then release catalog/source resources. Independently owned
   waveform results can be destroyed later, after their own readers finish.

Use the same stop/drain discipline when switching catalogs or restoring a backup.
The macOS host implements it with `BlockingWorkRegistry` and
`LatestRequestWorker`; an external host must provide its own admission and join
barriers. Cancellation requests, an inactive scan status, a canceled task and
provider unload alone do not establish that all actual host work has finished.

## Validation

`make check-core` runs the existing Zig/header layout checks and compiled C ABI
contract, including pre-init negotiation, undersized-output rejection, larger
caller tail preservation, exact waveform size/version checks, handle ownership,
and a separately compiled caller with frozen original catalog declarations.
The focused C contract can also be run with
`cd core && zig build waveform-abi -Doptimize=safe`.
