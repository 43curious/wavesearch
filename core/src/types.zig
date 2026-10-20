// Internal search rows shared by the catalog and a bounded request-local cache.
pub const SearchCandidate = struct {
    file_id: i32 = 0,
    folder_id: i32 = 0,
    path: [1024]u8 = @splat(0),
    name: [256]u8 = @splat(0),
    search_text: [2048]u8 = @splat(0),
    duration_ms: i32 = 0,
    content_hash: i64 = 0,
    bm25: f64 = 0,
};

pub const WSResult = extern struct {
    file_id: c_int,
    folder_id: c_int,
    path: [1024]u8,
    name: [256]u8,
    duration_ms: c_int,
    content_hash: i64,
};

pub const WSCategory = extern struct {
    struct_size: u32,
    version: u32,
    index: u32,
    file_count: u32,
    cat_id: [16]u8,
    category: [64]u8,
    subcategory: [64]u8,
    taxonomy_version: [16]u8,
};

pub const WSSelectsImportReport = extern struct {
    struct_size: u32,
    version: u32,
    imported: u32,
    merged: u32,
    unresolved: u32,
    conflicts: u32,
};

pub const WSFileMetadata = extern struct {
    struct_size: u32,
    version: u32,
    file_id: c_int,
    known_fields: u32,
    flags: u32,
    channels: u32,
    sample_rate: u32,
    bit_depth: u32,
    encoding: u32,
    reserved: u32,
    content_hash: i64,
    file_size: i64,
    mtime_ns: i64,
};

pub const WSFileIdentity = extern struct {
    struct_size: u32,
    version: u32,
    file_id: c_int,
    kind: u32,
    algorithm: u32,
    reserved: u32,
    content_hash: i64,
    file_size: i64,
    mtime_ns: i64,
};

pub const WSDuplicateVerification = extern struct {
    struct_size: u32,
    version: u32,
    file_id: c_int,
    candidate_count: u32,
    verified_count: u32,
    reserved: u32,
    source_bytes_read: u64,
};

pub const WSFingerprintStorageResult = extern struct {
    struct_size: u32,
    version: u32,
    processed_count: u32,
    reserved: u32,
    bytes_before: u64,
    bytes_after: u64,
};

pub const WS_SEMANTIC_STATUS_VERSION: u32 = 2;
pub const WSSemanticStatus = extern struct {
    struct_size: u32,
    version: u32,
    active: c_int,
    dimension: u32,
    model_id: i64,
    generation: i64,
    embedded_count: i64,
    pending_count: i64,
    model_key: [128]u8,
    failed_count: i64,
    provider_loaded: c_int,
};

pub const WS_ACOUSTIC_STATUS_VERSION: u32 = 1;
pub const WSAcousticStatus = extern struct {
    struct_size: u32,
    version: u32,
    indexed_count: i64,
    pending_count: i64,
    failed_count: i64,
};

pub const WS_EXAMPLE_RESULT_VERSION: u32 = 1;
pub const WSExampleResult = extern struct {
    struct_size: u32,
    version: u32,
    result: WSResult,
    fused_score: u64,
    fingerprint_score_ppm: u32,
    fingerprint_votes: u32,
    offset_ms: i32,
    embedding_rank: i32,
    acoustic_group_id: i64,
};

pub const WS_ACOUSTIC_GROUP_VERSION: u32 = 1;
pub const WSAcousticGroup = extern struct {
    struct_size: u32,
    version: u32,
    file_id: c_int,
    member_count: u32,
    group_id: i64,
    confidence_ppm: u32,
    reserved: u32,
};

pub const WS_OPERATION_STATUS_VERSION: u32 = 1;
pub const WSOperationStatus = extern struct {
    struct_size: u32,
    version: u32,
    active: c_int,
    cancel_requested: c_int,
    deep: c_int,
    folder_id: c_int,
    discovered_count: u64,
    completed_operations: u64,
    cancelled_operations: u64,
    failed_operations: u64,
};

pub const WS_WAVEFORM_WORK_VERSION: u32 = 1;
pub const WSWaveformWorkItem = extern struct {
    struct_size: u32,
    version: u32,
    file_id: c_int,
    reserved: u32,
    content_hash: i64,
    file_size: i64,
    mtime_ns: i64,
    path: [1024]u8,
};

pub const WS_WAVEFORM_WORK_CLAIM_VERSION: u32 = 2;
pub const WSWaveformWorkClaim = extern struct {
    struct_size: u32,
    version: u32,
    file_id: c_int,
    reserved: u32,
    content_hash: i64,
    file_size: i64,
    mtime_ns: i64,
    claim_token: u64,
    claim_until_ns: i64,
    path: [1024]u8,
};

pub const WS_WAVEFORM_CACHE_STATUS_VERSION: u32 = 1;
pub const WSWaveformCacheStatus = extern struct {
    struct_size: u32,
    version: u32,
    universal_count: i64,
    detailed_count: i64,
    pending_count: i64,
    failed_count: i64,
    universal_bytes: i64,
    detailed_bytes: i64,
    detailed_budget_bytes: i64,
};

pub const WS_WAVEFORM_ANALYZER_ABI_VERSION: u32 = 1;
pub const WS_WAVEFORM_PCM_BUFFER_VERSION: u32 = 1;
pub const WS_WAVEFORM_RESULT_INFO_VERSION: u32 = 1;
pub const WS_WAVEFORM_MAX_LEVELS: usize = 4;

pub const WSWaveformAnalyzerConfig = extern struct {
    struct_size: u32,
    version: u32,
    purpose: u32,
    flags: u32,
    backend: u32,
    reserved0: u32,
    sample_rate: f64,
    total_frames: u64,
    channel_count: u32,
    reserved1: u32,
    source_file_size: i64,
    source_mtime_ns: i64,
    source_content_hash: i64,
    reserved: [2]u64,
};

pub const WSWaveformPCMBuffer = extern struct {
    struct_size: u32,
    version: u32,
    layout: u32,
    channel_count: u32,
    frame_count: u64,
    interleaved: ?[*]const f32,
    planes: ?[*]const ?[*]const f32,
    reserved: [2]u64,
};

pub const WSWaveformResultInfo = extern struct {
    struct_size: u32,
    version: u32,
    analyzer_version: u32,
    codec_version: u32,
    purpose: u32,
    resolved_backend: u32,
    flags: u32,
    level_count: u32,
    sample_rate: f64,
    frame_count: u64,
    source_channel_count: u32,
    rendered_channel_count: u32,
    level_bucket_counts: [WS_WAVEFORM_MAX_LEVELS]u32,
    source_file_size: i64,
    source_mtime_ns: i64,
    source_content_hash: i64,
    integrated_lufs: f64,
    sample_peak_dbfs: f64,
    reserved: [2]u64,
};

pub const WSWaveformPeak = extern struct {
    minimum: f32,
    maximum: f32,
};

pub const WS_INTEGRITY_REPORT_VERSION: u32 = 1;
pub const WSIntegrityReport = extern struct {
    struct_size: u32,
    version: u32,
    checks_run: u32,
    errors_found: u32,
    schema_version: u32,
    reserved: u32,
};
