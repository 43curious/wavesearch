#ifndef WAVESEARCH_H
#define WAVESEARCH_H

#include <stdint.h>

// Process-wide C ABI contract (independent of app/schema/model versions).
// Check equality before ws_init, then require the capability bits your host uses.
// Additive symbols/capabilities keep this version; incompatible changes bump it.
// Existing layouts and signatures remain fixed; new layouts use new entry points.
#define WS_ABI_VERSION 1u
#define WS_CAP_QUERY_CANCELLATION (UINT64_C(1) << 0)
#define WS_CAP_WAVEFORM_V1        (UINT64_C(1) << 1)
#define WS_CAP_EXTERNAL_SEMANTIC  (UINT64_C(1) << 2)
#define WS_CAP_CLAP              (UINT64_C(1) << 3)
#define WS_CAP_EXACT_DUPLICATES  (UINT64_C(1) << 4)
#define WS_CAP_FINGERPRINT_REPACK (UINT64_C(1) << 5)
#define WS_CAP_FILE_METADATA     (UINT64_C(1) << 7)
#define WS_CAP_UCS_CATEGORIES    (UINT64_C(1) << 8)
#define WS_CAP_PORTABLE_SELECTS  (UINT64_C(1) << 9)
#define WS_CAP_FILE_LOOKUP       (UINT64_C(1) << 6)
// Allocation-free, thread-safe, valid before init and after deinit. Capabilities
// describe compiled APIs, not model installation, provider loading or DB state.
// Ignore unknown bits. WS_CAP_CLAP never promises a model/runtime is available.
uint32_t ws_abi_version(void);
uint64_t ws_capabilities(void);

// Host contract (full API-family details: documentation/C_API.md):
// - Calls are synchronous; dispatch filesystem/DB/DSP/inference work off the UI
//   thread. No callbacks or host executors are invoked by this API.
// - One process-global catalog/provider. Serialize init/deinit/restore with ALL
//   catalog/provider work: stop admission, cancel, join actual calls, then close.
//   Cancellation/status are not drain barriers. Internal locks do not replace
//   host lifecycle coordination or bound queued work.
// - Inputs and output storage belong to the caller and must remain valid for
//   the entire call. Inputs are borrowed only for the call; outputs are copies.
//   Never share writable buffers concurrently or free library handles yourself.
// - Query/analyzer/result handles have the explicit destroy functions below.
//   Join users AND cancellers before destruction. Immutable results allow
//   concurrent readers; query/analyzer calls on one handle must be sequential.
// - Zero-initialize structs. Set struct_size to sizeof(the declared type).
//   Status/work/identity outputs accept >= sizeof and write only that type;
//   their version is output. WSExampleResult arrays require exact element size.
//   Waveform config/PCM/info require exact size AND the declared input version.
// - Strings are NUL-terminated UTF-8 byte strings. Fixed output string arrays
//   are copies, may be truncated, and do not provide a long-path guarantee.
//   Read result arrays only through the returned count; discard on failure.

// A single search result
typedef struct {
    int  file_id;
    int  folder_id;
    char path[1024];
    char name[256];
    int  duration_ms;
    int64_t content_hash; // opaque identity; negative values are provisional or sampled, not exact duplicate proof
} WSResult;

// Catalog-only UCS facets; unknown names have no category. Counts do not stat
// physical sources. Entries are ordered by CatID and contain copied strings.
#define WS_CATEGORY_VERSION 1u
typedef struct {
    uint32_t struct_size, version, index, file_count;
    char cat_id[16], category[64], subcategory[64], taxonomy_version[16];
} WSCategory;
// folder_id=-1 means all libraries, max_categories<=753. Exact array element
// sizes required. Returns count, -1 error. Discard output on error.
int ws_category_list_v1(int folder_id, WSCategory *out, int max_categories);
// Returns 1 known, 0 unknown/missing, -1 error; unchanged output on 0/-1.
int ws_file_category_v1(int file_id, WSCategory *out);
// Existing search APIs accept cat:CatID, alone or with text/duration filters.

typedef struct WSQueryRequest WSQueryRequest;

#define WS_SELECTS_FAVOURITE 0u
#define WS_SELECTS_TAG 1u
#define WS_SELECTS_COLLECTION 2u
typedef struct {
    uint32_t struct_size, version, imported, merged, unresolved, conflicts;
} WSSelectsImportReport;
// Owned version-1 UTF-8 JSON snapshot (<=16 MiB); NULL on error. Free exactly
// once with the paired free call. Snapshot remains valid after catalog close.
char *ws_selects_export_v1(void);
void ws_selects_json_free_v1(char *json);
// Merge only: union tags/ranges/favourites, retain unresolved/conflicting refs.
// Input length excludes NUL. Unknown versions/fields or invalid input abort all.
int ws_selects_import_v1(const char *json, uint64_t length, WSSelectsImportReport *out);
// Once per catalog, migrate a JSON array of legacy favourite paths (including
// missing paths). Repeated calls do nothing; catalog backups retain this flag.
int ws_selects_seed_favourites_v1(const char *json, uint64_t length);
// Edit one indexed file. name required for tags/collections (1..128 UTF-8 bytes).
// start/end=-1 means whole file; ranges only for collections, 0<=start<end<=INT32_MAX.
// enabled must be 0/1. All edits return 0 success, -1 error; no source file I/O.
int ws_selects_edit_v1(int file_id, uint32_t kind, const char *name,
                      int64_t start_ms, int64_t end_ms, int enabled);
// Explicitly bind a missing reference to an indexed file, merging annotations.
int ws_selects_relink_v1(const char *source_id, int file_id);
// ID-ordered keyset pages of existing files. Missing refs remain in JSON.
// folder=-1 all, after_id=0 first page, max<=1000; query handle required.
int ws_selects_list_v1(WSQueryRequest *request, uint32_t kind, const char *name,
                      int folder_id, int after_id, WSResult *out, int max_results);

#define WS_SEMANTIC_STATUS_VERSION 2u

// Versioned semantic indexing status. Before calling ws_semantic_status,
// initialize struct_size to sizeof(WSSemanticStatus). The library rejects
// smaller callers instead of writing past their allocation.
typedef struct {
    uint32_t struct_size;
    uint32_t version;
    int      active;
    uint32_t dimension;
    int64_t  model_id;
    int64_t  generation;
    int64_t  embedded_count;
    int64_t  pending_count;
    char     model_key[128];
    int64_t  failed_count;
    int      provider_loaded;
} WSSemanticStatus;

#define WS_ACOUSTIC_STATUS_VERSION 1u
typedef struct {
    uint32_t struct_size;
    uint32_t version;
    int64_t indexed_count;
    int64_t pending_count;
    int64_t failed_count;
} WSAcousticStatus;

#define WS_EXAMPLE_RESULT_VERSION 1u
typedef struct {
    uint32_t struct_size;
    uint32_t version;
    WSResult result;
    uint64_t fused_score;
    uint32_t fingerprint_score_ppm;
    uint32_t fingerprint_votes;
    int32_t offset_ms;
    int32_t embedding_rank; // -1 when CLAP was unavailable/not ranked
    int64_t acoustic_group_id;
} WSExampleResult;

#define WS_ACOUSTIC_GROUP_VERSION 1u
typedef struct {
    uint32_t struct_size;
    uint32_t version;
    int file_id;
    uint32_t member_count;
    int64_t group_id;
    uint32_t confidence_ppm;
    uint32_t reserved;
} WSAcousticGroup;

#define WS_OPERATION_STATUS_VERSION 1u
typedef struct {
    uint32_t struct_size;
    uint32_t version;
    int active;
    int cancel_requested;
    int deep;
    int folder_id;
    uint64_t discovered_count;
    uint64_t completed_operations;
    uint64_t cancelled_operations;
    uint64_t failed_operations;
} WSOperationStatus;

#define WS_INTEGRITY_REPORT_VERSION 1u
typedef struct {
    uint32_t struct_size;
    uint32_t version;
    uint32_t checks_run;
    uint32_t errors_found;
    uint32_t schema_version;
    uint32_t reserved;
} WSIntegrityReport;

#define WS_INTEGRITY_FULL 1u
#define WS_INDEX_DEEP 1u
// Fast searchable snapshot: bounded content sampling instead of full reads for
// ordinary sound-effect files. Acoustic and semantic refinement remain exact.
#define WS_INDEX_FAST 2u

// Initialize the library. db_path is the path to the SQLite file (created if missing).
int  ws_init(const char *db_path);
void ws_deinit(void);

// Index a folder. folder_id is your integer identifier for this folder.
// Runs synchronously — call from a background thread.
int  ws_index_folder(int folder_id, const char *path);

// Extended index operation. WS_INDEX_DEEP bypasses size/mtime reuse and hashes
// every byte. The live index is published atomically only after a complete scan.
int ws_index_folder_ex(int folder_id, const char *path, uint32_t flags);

// Cooperative cancellation can be requested from another thread without
// waiting for the indexing mutation lock. Returns 1 when an operation was active.
int ws_cancel_indexing(void);
// Cancel only derived acoustic/semantic refinement, leaving a filesystem scan
// active. Returns 1 when derived work was active.
int ws_cancel_refinement(void);
int ws_operation_status(WSOperationStatus *out);

#define WS_REFINEMENT_QUEUE_WAVEFORM 1u
#define WS_REFINEMENT_QUEUE_ACOUSTIC 2u
#define WS_REFINEMENT_QUEUE_SEMANTIC 4u
// Nonblocking, allocation-free 2:1:1 queue selection. Initialize *cursor to 0
// and retain it across admitted steps. ready_mask combines the constants above;
// return one ready queue or 0 if none are ready (unknown bits are ignored).
// A continuously ready queue gets a turn within four selections. Hosts enforce
// admission, backoff, cancellation/draining, and one-file step limits. This is
// a step-count bound, not a wall-clock guarantee. Caller owns/synchronizes cursor.
// Does not require ws_init; a null cursor returns 0.
uint32_t ws_refinement_next_queue(uint32_t *cursor, uint32_t ready_mask);

// Run SQLite, foreign-key, FTS, vector, and fingerprint consistency checks.
int ws_integrity_check(uint32_t flags, WSIntegrityReport *out);

// Online SQLite backup/recovery; safe with WAL and concurrent readers.
int ws_backup_create(const char *destination);
int ws_backup_restore(const char *source);
// Create a checked 16 KiB-page copy at a NEW path. Does not rewrite the live DB.
// Retain the original/backup before restoring this copy (temporary disk needed).
int ws_backup_compact(const char *destination);

// How many files are indexed for this folder.
int  ws_folder_count(int folder_id);

// Remove a folder's files and all derived FTS/semantic/cache rows atomically.
int  ws_remove_folder(int folder_id);

// Search. folder_id = -1 to search all folders.
// Writes up to max_results WSResult structs into out.
// Returns count written, or -1 on error.
int  ws_search(const char *query, int folder_id, WSResult *out, int max_results);

// Request-local cancellation for synchronous worker-thread calls. Create before
// dispatch; cancellation is sticky, thread-safe, and independent of other
// requests, legacy searches, scans, and refinement. Use a fresh handle for each
// logical query (it may be reused sequentially for lexical then hybrid stages).
// Do not execute two calls concurrently on one handle. Destroy only AFTER all
// calls and cancellers finish. NULL cancel/destroy are harmless.
// v2 calls return WS_QUERY_CANCELLED on cancellation; discard the output buffer.
// Native inference/OS calls may finish before cancellation is observed. Copy
// ws_last_error_message() on the calling worker immediately after a failure.
// Drain all calls before ws_deinit(); cancellation is not a drain barrier.
#define WS_QUERY_CANCELLED (-2)
#define WS_SEARCH_HYBRID 0u
#define WS_SEARCH_LEXICAL_ONLY 1u
WSQueryRequest *ws_query_create(void);
void ws_query_cancel(WSQueryRequest *request);
void ws_query_destroy(WSQueryRequest *request);
// Whether optional semantic refinement is currently useful for this query.
// Duration-only/invalid queries and an unloaded provider return 0.
int ws_search_needs_refinement(const char *query);
// The handle retains a bounded lexical stage for reuse by a sequential hybrid
// call with the same query/folder. Catalog mutation invalidates that stage.
int ws_search_v2(WSQueryRequest *request, const char *query, int folder_id,
                 WSResult *out, int max_results, uint32_t flags);
// Live keyset pages (<=1000 rows): null/0 starts, last name/ID continues.
// Uses the same NOCASE name + ID order as listing. Restart after catalog changes.
int ws_list_folder_page_v2(WSQueryRequest *request, int folder_id,
                           const char *after_name, int after_id,
                           WSResult *out, int max_results);
int ws_list_folder_v2(WSQueryRequest *request, int folder_id,
                      WSResult *out, int max_results);
int ws_search_by_example_v2(WSQueryRequest *request, const char *path, int folder_id,
                            WSExampleResult *out, int max_results);
int ws_search_by_example_pcm_v2(WSQueryRequest *request, const float *samples,
                                uint64_t frames, uint32_t channels, uint32_t sample_rate,
                                int folder_id, WSExampleResult *out, int max_results);

// Load/unload the verified CLAP model pack and dynamically loaded ONNX Runtime.
// No model or runtime is downloaded by the library.
int  ws_clap_load(const char *runtime_library_path, const char *model_dir,
                  int intra_op_threads);
void ws_clap_unload(void);

// Embed pending WAV files for the loaded provider. folder_id=-1 selects all;
// max_files=0 means all pending files. Returns successful embeddings or -1.
int ws_clap_index_pending(int folder_id, int max_files);
// Race-free scheduler variant: obtain an epoch immediately before dispatch.
// If refinement is cancelled before this call registers, it returns Cancelled.
uint64_t ws_refinement_generation(void);
int ws_clap_index_pending_v2(int folder_id, int max_files,
                             uint64_t expected_generation);

// Register (or select) a versioned external semantic model. model_key is the
// provider-defined model-pack identity. Vectors use normalized f32le-l2-v1.
int ws_semantic_model_set(const char *model_key, int dimension);

// Store a normalized audio embedding for the active model. content_hash must
// match the currently indexed file, preventing stale provider output.
int ws_semantic_embedding_upsert(int file_id, int64_t content_hash,
                                 const float *vector, int dimension);

// Hybrid lexical/semantic search using a normalized text embedding supplied by
// an external provider. If no model is active, this falls back to lexical-only.
int ws_search_with_embedding(const char *query, const float *query_vector,
                             int dimension, int folder_id, WSResult *out,
                             int max_results);

// Read active model identity, generation, embedded/pending/failed counts, and
// whether the built-in CLAP provider is loaded. out->struct_size must be set.
int ws_semantic_status(WSSemanticStatus *out);

// List all files in a folder sorted alphabetically. folder_id must be valid (not -1).
// Writes up to max_results WSResult structs into out.
// Returns count written, or -1 on error.
int  ws_list_folder(int folder_id, WSResult *out, int max_results);

#define WS_FILE_METADATA_CHANNELS (1u << 0)
#define WS_FILE_METADATA_SAMPLE_RATE (1u << 1)
#define WS_FILE_METADATA_BIT_DEPTH (1u << 2)
#define WS_FILE_METADATA_ENCODING (1u << 3)
#define WS_FILE_METADATA_LIMITED (1u << 0)
typedef struct {
    uint32_t struct_size;
    uint32_t version;
    int file_id;
    uint32_t known_fields; // Unset fields are unknown; their output value is zero.
    uint32_t flags;
    uint32_t channels;
    uint32_t sample_rate;
    uint32_t bit_depth;
    uint32_t encoding; // 1 = integer PCM, 3 = IEEE float.
    uint32_t reserved;
    int64_t content_hash;
    int64_t file_size;
    int64_t mtime_ns;
} WSFileMetadata;
// Catalog-only lookup: 1 found, 0 unavailable, -1 invalid/error. Set struct_size.
// Output is unchanged on 0/-1. Check identity against the current source before
// displaying cached data; this function performs no source I/O. LIMITED marks
// budget-limited/malformed descriptive metadata, independently of known fields.
int ws_file_metadata_v1(int file_id, WSFileMetadata *out);

// Copy a committed result by stable ID or exact catalog path. Returns 1 when
// found, 0 when absent, -1 on error; out is unchanged when absent or on error.
int ws_file_lookup_v1(int file_id, WSResult *out);
int ws_file_lookup_path_v1(const char *path, WSResult *out);

// Generate/resume robust WAV acoustic fingerprints. max_files=0 means all.
int ws_acoustic_index_pending(int folder_id, int max_files);
int ws_acoustic_index_pending_v2(int folder_id, int max_files,
                                 uint64_t expected_generation);

// Read fingerprint indexing status. out->struct_size must be set.
int ws_acoustic_status(WSAcousticStatus *out);

// Find near-duplicates and semantic neighbors for a WAV example path.
// Every out[i].struct_size must equal sizeof(WSExampleResult).
int ws_search_by_example(const char *path, int folder_id,
                         WSExampleResult *out, int max_results);

// Search from host-decoded finite interleaved float PCM. This enables optional
// MP3/FLAC/AAC decoders without coupling the portable core to a codec library.
int ws_search_by_example_pcm(const float *samples, uint64_t frames,
                             uint32_t channels, uint32_t sample_rate,
                             int folder_id, WSExampleResult *out,
                             int max_results);

// Resolve robust duplicate-family information for one indexed file.
// out->struct_size must be initialized to sizeof(WSAcousticGroup).
int ws_acoustic_group(int file_id, WSAcousticGroup *out);

// Generate waveform data for a file.
// Writes num_points float32 RMS values (0.0–1.0) into out_samples.
int  ws_waveform(const char *path, float *out_samples, int num_points);

// Opaque versioned waveform-analysis cache. Size returns zero on a miss.
// Blobs are bounded to 64 MiB; their source signature is caller-validated.
int64_t ws_waveform_cache_size(const char *path);
int ws_waveform_cache_load(const char *path, uint8_t *out_bytes, uint64_t capacity);
int ws_waveform_cache_store(const char *path, const uint8_t *bytes, uint64_t size);

#define WS_WAVEFORM_TIER_UNIVERSAL 1u
#define WS_WAVEFORM_TIER_DETAILED 2u

// Versioned streaming Float32 PCM analyzer. Decoding remains a host adapter;
// the portable core owns authoritative extrema, loudness, μ-law tiers and WVT3.
#define WS_WAVEFORM_ANALYZER_ABI_VERSION 1u
#define WS_WAVEFORM_PCM_BUFFER_VERSION 1u
#define WS_WAVEFORM_RESULT_INFO_VERSION 1u
#define WS_WAVEFORM_ANALYZER_VERSION 3u
#define WS_WAVEFORM_CODEC_VERSION 3u
#define WS_WAVEFORM_MAX_CHANNELS 256u
#define WS_WAVEFORM_MAX_PUSH_FRAMES 32768u
#define WS_WAVEFORM_MAX_LEVELS 4u
#define WS_WAVEFORM_MIN_LOUDNESS_SAMPLE_RATE 8000u

#define WS_WAVEFORM_PURPOSE_DETAILED_4096 1u
#define WS_WAVEFORM_PURPOSE_UNIVERSAL_512 2u
#define WS_WAVEFORM_ANALYZE_LOUDNESS 1u

#define WS_WAVEFORM_BACKEND_AUTO 0u
#define WS_WAVEFORM_BACKEND_PORTABLE 1u
#define WS_WAVEFORM_BACKEND_ACCELERATE 2u

#define WS_PCM_LAYOUT_PLANAR 1u
#define WS_PCM_LAYOUT_INTERLEAVED 2u

#define WS_WAVEFORM_RESULT_LOUDNESS_COMPLETE 1u
#define WS_WAVEFORM_RESULT_LUFS_VALID 2u
#define WS_WAVEFORM_RESULT_SAMPLE_PEAK_VALID 4u
#define WS_WAVEFORM_RESULT_UNIVERSAL_AVAILABLE 8u
#define WS_WAVEFORM_RESULT_DETAILED_AVAILABLE 16u

#define WS_WAVEFORM_OK 0
#define WS_WAVEFORM_ERROR_INVALID_ARGUMENT -100
#define WS_WAVEFORM_ERROR_UNSUPPORTED_VERSION -101
#define WS_WAVEFORM_ERROR_INVALID_STATE -102
#define WS_WAVEFORM_ERROR_UNSUPPORTED_BACKEND -103
#define WS_WAVEFORM_ERROR_OUT_OF_MEMORY -104
#define WS_WAVEFORM_ERROR_CANCELLED -105
#define WS_WAVEFORM_ERROR_FRAME_COUNT_MISMATCH -106
#define WS_WAVEFORM_ERROR_BUFFER_TOO_SMALL -107
#define WS_WAVEFORM_ERROR_CORRUPT_WVT3 -108

// Opaque handles are allocated and released by libwavesearch.
typedef struct WSWaveformAnalyzer WSWaveformAnalyzer;
typedef struct WSWaveformResult WSWaveformResult;

// Every versioned input must be zero-initialized, then populated with the
// exact struct_size and version constants declared here. sample_rate may be
// 1...768000 Hz for extrema-only analysis; loudness requires at least 8000 Hz.
// total_frames is authoritative and must be completely supplied before finish.
typedef struct {
    uint32_t struct_size;
    uint32_t version;
    uint32_t purpose;
    uint32_t flags;
    uint32_t backend;
    uint32_t reserved0;
    double sample_rate;
    uint64_t total_frames;
    uint32_t channel_count;
    uint32_t reserved1;
    int64_t source_file_size;
    int64_t source_mtime_ns;
    int64_t source_content_hash;
    uint64_t reserved[2];
} WSWaveformAnalyzerConfig;

typedef struct {
    uint32_t struct_size;
    uint32_t version;
    uint32_t layout;
    uint32_t channel_count;
    uint64_t frame_count;
    const float *interleaved;
    const float *const *planes;
    uint64_t reserved[2];
} WSWaveformPCMBuffer;

typedef struct {
    uint32_t struct_size;
    uint32_t version;
    uint32_t analyzer_version;
    uint32_t codec_version;
    uint32_t purpose;
    uint32_t resolved_backend;
    uint32_t flags;
    uint32_t level_count;
    double sample_rate;
    uint64_t frame_count;
    uint32_t source_channel_count;
    uint32_t rendered_channel_count;
    uint32_t level_bucket_counts[WS_WAVEFORM_MAX_LEVELS];
    int64_t source_file_size;
    int64_t source_mtime_ns;
    int64_t source_content_hash;
    double integrated_lufs;
    double sample_peak_dbfs;
    uint64_t reserved[2];
} WSWaveformResultInfo;

typedef struct {
    float minimum;
    float maximum;
} WSWaveformPeak;

// The analyzer copies samples during push; PCM pointers need only remain valid
// for that call. create/push/finish are single-threaded. cancel is safe from a
// second thread; the caller must join that thread before destroy. finish may be
// called once and transfers a separately-owned result through out_result.
int ws_waveform_analyzer_create_v1(const WSWaveformAnalyzerConfig *config,
                                   WSWaveformAnalyzer **out_analyzer);
int ws_waveform_analyzer_push_v1(WSWaveformAnalyzer *analyzer,
                                 const WSWaveformPCMBuffer *buffer);
int ws_waveform_analyzer_cancel(WSWaveformAnalyzer *analyzer);
int ws_waveform_analyzer_finish_v1(WSWaveformAnalyzer *analyzer,
                                   WSWaveformResult **out_result);
void ws_waveform_analyzer_destroy(WSWaveformAnalyzer *analyzer);

// Create a canonical core result from one host-accelerated highest level.
// peaks are channel-major and copied during the call. BACKEND_ACCELERATE is a
// host-result identity; analyzer_create itself implements AUTO/PORTABLE only.
// Result handles are immutable and may be read concurrently, but each handle
// must be destroyed exactly once after all readers finish.
int ws_waveform_result_create_v1(const WSWaveformResultInfo *info,
                                 const WSWaveformPeak *peaks,
                                 uint64_t peak_count,
                                 WSWaveformResult **out_result);
int ws_waveform_result_info_v1(const WSWaveformResult *result,
                               WSWaveformResultInfo *out_info);
// For copy/serialize, a NULL output with capacity 0 is a successful size query
// written to required. Otherwise capacity is measured in peaks/bytes.
int ws_waveform_result_copy_level_v1(const WSWaveformResult *result,
                                     uint32_t level_index,
                                     WSWaveformPeak *out_peaks,
                                     uint64_t capacity,
                                     uint64_t *required);
int ws_waveform_result_serialize_wvt3_v1(const WSWaveformResult *result,
                                         uint32_t tier,
                                         uint8_t *out_bytes,
                                         uint64_t capacity,
                                         uint64_t *required);
int ws_waveform_result_deserialize_wvt3_v1(const uint8_t *bytes,
                                           uint64_t size,
                                           WSWaveformResult **out_result);
void ws_waveform_result_destroy(WSWaveformResult *result);
#define WS_WAVEFORM_WORK_VERSION 1u
#define WS_WAVEFORM_WORK_CLAIM_VERSION 2u
#define WS_WAVEFORM_CACHE_STATUS_VERSION 1u

typedef struct {
    uint32_t struct_size;
    uint32_t version;
    int file_id;
    uint32_t reserved;
    int64_t content_hash;
    int64_t file_size;
    int64_t mtime_ns;
    char path[1024];
} WSWaveformWorkItem;

// Lease-bearing v2 claim. Use renew during long analysis and release when a
// cache hit made analysis unnecessary. V1 remains ABI-compatible for callers
// that complete through tier-store or work-fail within the default lease.
typedef struct {
    uint32_t struct_size;
    uint32_t version;
    int file_id;
    uint32_t reserved;
    int64_t content_hash;
    int64_t file_size;
    int64_t mtime_ns;
    uint64_t claim_token;
    int64_t claim_until_ns;
    char path[1024];
} WSWaveformWorkClaim;

typedef struct {
    uint32_t struct_size;
    uint32_t version;
    int64_t universal_count;
    int64_t detailed_count;
    int64_t pending_count;
    int64_t failed_count;
    int64_t universal_bytes;
    int64_t detailed_bytes;
    int64_t detailed_budget_bytes;
} WSWaveformCacheStatus;

// Schema-v10 exact waveform tiers. Blobs are opaque and caller-versioned.
// Refresh fills only unknown legacy (-1) size/mtime identity fields.
int ws_waveform_identity_refresh(int file_id, int64_t content_hash,
                                 int64_t file_size, int64_t mtime_ns);
int64_t ws_waveform_tier_size(int file_id, uint32_t tier);
int ws_waveform_tier_load(int file_id, uint32_t tier,
                          uint8_t *out_bytes, uint64_t capacity);
int ws_waveform_tiers_store(int file_id, int64_t content_hash,
                            int64_t file_size, int64_t mtime_ns,
                            uint32_t codec_version,
                            const uint8_t *universal, uint64_t universal_size,
                            const uint8_t *detailed, uint64_t detailed_size);
int ws_waveform_tier_touch(int file_id, uint32_t tier);
int ws_waveform_work_claim(WSWaveformWorkItem *out);
int ws_waveform_work_claim_v2(WSWaveformWorkClaim *out);
int ws_waveform_work_renew(int file_id, uint64_t claim_token);
int ws_waveform_work_release(int file_id, uint64_t claim_token);
int ws_waveform_work_pending(void);
int ws_waveform_work_fail(int file_id, int64_t content_hash,
                          int64_t file_size, int64_t mtime_ns,
                          int permanent, const char *detail);
int ws_waveform_work_fail_v2(int file_id, int64_t content_hash,
                             int64_t file_size, int64_t mtime_ns,
                             uint64_t claim_token, int permanent,
                             const char *detail);
int ws_waveform_cache_status(WSWaveformCacheStatus *out);
int ws_waveform_cache_set_detailed_budget(int64_t bytes);
// Delete all waveform tiers, legacy analyses/peaks, and failure state, and reset
// pending work. Drain waveform producers first; clear host memory caches after.
// Keeps indexed files, acoustic/semantic refinements, and the detailed budget.
// Freed SQLite pages are reused; this does not vacuum the database.
int ws_waveform_cache_clear(void);

// Returns the count only for current full-hash identities whose complete bytes
// verify equal. Provisional, sampled, historical/unknown or ambiguous groups
// return 0; source/cancellation/DB failures return -1. Includes the source itself.
// This may read whole files: call off the UI thread and drain before shutdown.
int ws_duplicate_count(int64_t content_hash);

#define WS_FILE_IDENTITY_VERSION 1u
#define WS_IDENTITY_UNKNOWN 0u
#define WS_IDENTITY_FAST_PROVISIONAL 1u
#define WS_IDENTITY_SAMPLED 2u
#define WS_IDENTITY_FULL 3u
#define WS_HASH_UNKNOWN 0u
#define WS_HASH_WYHASH_SIZE_LE64_V1 1u
typedef struct {
    uint32_t struct_size, version;
    int file_id;
    uint32_t kind, algorithm, reserved;
    int64_t content_hash, file_size, mtime_ns;
} WSFileIdentity;
// Indexed hash strength/algorithm; historical rows stay unknown until rescanned.
// Full hashing is a candidate identity, not proof against a hash collision.
int ws_file_identity_v1(int file_id, WSFileIdentity *out);

#define WS_DUPLICATE_VERIFICATION_VERSION 1u
typedef struct {
    uint32_t struct_size, version;
    int file_id;
    uint32_t candidate_count, verified_count, reserved;
    uint64_t source_bytes_read;
} WSDuplicateVerification;
// Request-local complete-byte verification of same hash/kind/algorithm/size
// candidates, including fast/sampled identities. Includes the source itself.
// No catalog mutation or cross-file analysis sharing. Constant scratch memory,
// potentially large I/O; invoke off-main and drain before releasing file access.
// Returns 0, -1 on failure, or WS_QUERY_CANCELLED; discard out on failure/cancel.
int ws_duplicate_verify_v1(WSQueryRequest *request, int file_id,
                            WSDuplicateVerification *out);

#define WS_FINGERPRINT_STORAGE_RESULT_VERSION 1u
typedef struct {
    uint32_t struct_size, version, processed_count, reserved;
    uint64_t bytes_before, bytes_after;
} WSFingerprintStorageResult;
// Explicit resumable lossless repack, max_files=1..1024, one row at a time.
// Completed rows stay committed if a later row fails/cancels. No PCM decoding,
// model/algorithm change, or posting/group rebuild. Freed pages remain reusable;
// ws_backup_compact can create a smaller physical copy at a NEW path.
// Returns 0, -1, or WS_QUERY_CANCELLED; discard out on failure/cancellation.
int ws_fingerprint_storage_repack_v1(WSQueryRequest *request, int max_files,
                                      WSFingerprintStorageResult *out);

// Borrowed thread-local NUL-terminated diagnostic (never free). Copy immediately
// on the failing worker: the next failure on that thread overwrites it; success
// need not clear it. Invalid after the thread exits. Not an error-code protocol.
const char *ws_last_error_message(void);

#endif // WAVESEARCH_H
