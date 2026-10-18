const std = @import("std");
const db = @import("db.zig");
const search = @import("search.zig");
const audio = @import("audio.zig");
const types = @import("types.zig");
const semantic = @import("semantic.zig");
const vector = @import("vector.zig");
const clap_provider = @import("clap_provider.zig");
const acoustic = @import("acoustic.zig");
const fingerprint = @import("fingerprint.zig");
const clap_audio = @import("clap_audio.zig");
const operations = @import("operations.zig");
const waveform = @import("waveform.zig");
const cancellation = @import("cancellation.zig");
const sync = @import("sync.zig");
const query_cancel = @import("query.zig");
const refinement_schedule = @import("refinement_schedule.zig");

pub const WSResult = types.WSResult;
pub const WSFileIdentity = types.WSFileIdentity;
pub const WSDuplicateVerification = types.WSDuplicateVerification;
pub const WSFingerprintStorageResult = types.WSFingerprintStorageResult;
pub const WSSemanticStatus = types.WSSemanticStatus;
pub const WSAcousticStatus = types.WSAcousticStatus;
pub const WSExampleResult = types.WSExampleResult;
pub const WSAcousticGroup = types.WSAcousticGroup;
pub const WSOperationStatus = types.WSOperationStatus;
pub const WSIntegrityReport = types.WSIntegrityReport;
pub const WSWaveformWorkItem = types.WSWaveformWorkItem;
pub const WSWaveformWorkClaim = types.WSWaveformWorkClaim;
pub const WSWaveformCacheStatus = types.WSWaveformCacheStatus;
pub const WSWaveformAnalyzerConfig = types.WSWaveformAnalyzerConfig;
pub const WSWaveformPCMBuffer = types.WSWaveformPCMBuffer;
pub const WSWaveformResultInfo = types.WSWaveformResultInfo;
pub const WSWaveformPeak = types.WSWaveformPeak;
const allocator = std.heap.c_allocator;
// Indexing and waveform generation can both update waveform state. Serialize
// those mutations, while searches remain available during the filesystem scan.
var mutation_mutex: sync.Mutex = .{};
threadlocal var last_error_buf: [256:0]u8 = @splat(0);

pub export fn ws_abi_version() u32 {
    return 1;
}

pub export fn ws_capabilities() u64 {
    // Compiled API families, independent of mutable catalog/provider state.
    const c = @import("c");
    return c.WS_CAP_QUERY_CANCELLATION | c.WS_CAP_WAVEFORM_V1 |
        c.WS_CAP_EXTERNAL_SEMANTIC | c.WS_CAP_CLAP |
        c.WS_CAP_EXACT_DUPLICATES | c.WS_CAP_FINGERPRINT_REPACK;
}

fn lockMutations() void {
    mutation_mutex.lock();
}
fn setLastError(err: anyerror) void {
    setLastErrorMessage(@errorName(err));
}
fn setLastErrorMessage(message: []const u8) void {
    @memset(last_error_buf[0..], 0);
    const len = @min(message.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..len], message[0..len]);
    last_error_buf[len] = 0;
}

pub export fn ws_init(db_path: ?[*:0]const u8) c_int {
    const path = db_path orelse {
        setLastErrorMessage("NullDatabasePath");
        return -1;
    };
    lockMutations();
    defer mutation_mutex.unlock();
    clap_provider.unload();
    semantic.reset();
    db.open(allocator, std.mem.span(path)) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_deinit() void {
    lockMutations();
    defer mutation_mutex.unlock();
    // Provider references can outlive their initiating API call while ONNX is
    // running; detach and drain them before closing SQLite.
    clap_provider.unload();
    semantic.reset();
    db.close();
}

pub export fn ws_refinement_next_queue(cursor: ?*u32, ready_mask: u32) u32 {
    return refinement_schedule.next(cursor orelse return 0, ready_mask);
}

pub export fn ws_index_folder(folder_id: c_int, path: ?[*:0]const u8) c_int {
    return indexFolderExtended(folder_id, path, 0);
}

pub const WS_INDEX_DEEP: u32 = 1;
pub const WS_INDEX_FAST: u32 = 2;

pub export fn ws_index_folder_ex(folder_id: c_int, path: ?[*:0]const u8, flags: u32) c_int {
    if (flags & ~(WS_INDEX_DEEP | WS_INDEX_FAST) != 0 or flags & (WS_INDEX_DEEP | WS_INDEX_FAST) == (WS_INDEX_DEEP | WS_INDEX_FAST)) {
        setLastErrorMessage("InvalidIndexFlags");
        return -1;
    }
    return indexFolderExtended(folder_id, path, flags);
}

fn indexFolderExtended(folder_id: c_int, path: ?[*:0]const u8, flags: u32) c_int {
    const path_ptr = path orelse {
        setLastErrorMessage("NullFolderPath");
        return -1;
    };
    if (folder_id < 0) {
        setLastErrorMessage("InvalidFolderId");
        return -1;
    }
    lockMutations();
    defer mutation_mutex.unlock();
    operations.begin(folder_id, flags & WS_INDEX_DEEP != 0) catch |err| {
        setLastError(err);
        return -1;
    };
    const operation_result = search.indexFolderWithOptions(allocator, folder_id, std.mem.span(path_ptr), .{
        .deep = flags & WS_INDEX_DEEP != 0,
        .fast = flags & WS_INDEX_FAST != 0,
        .cancel = operations.cancelToken(),
        .discovered = operations.discoveredCounter(),
    });
    operations.finish(operation_result);
    operation_result catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_cancel_indexing() c_int {
    const scan_active = operations.requestCancel();
    const derived_active = cancellation.cancel();
    return if (scan_active or derived_active) 1 else 0;
}

pub export fn ws_cancel_refinement() c_int {
    return if (cancellation.cancel()) 1 else 0;
}

pub export fn ws_operation_status(out: ?*WSOperationStatus) c_int {
    const result = out orelse {
        setLastErrorMessage("NullStatus");
        return -1;
    };
    if (result.struct_size < @sizeOf(WSOperationStatus)) {
        setLastErrorMessage("OperationStatusBufferTooSmall");
        return -1;
    }
    const status = operations.status();
    result.* = .{
        .struct_size = @sizeOf(WSOperationStatus),
        .version = types.WS_OPERATION_STATUS_VERSION,
        .active = if (status.active) 1 else 0,
        .cancel_requested = if (status.cancel_requested) 1 else 0,
        .deep = if (status.deep) 1 else 0,
        .folder_id = status.folder_id,
        .discovered_count = status.discovered,
        .completed_operations = status.completed_operations,
        .cancelled_operations = status.cancelled_operations,
        .failed_operations = status.failed_operations,
    };
    return 0;
}

pub export fn ws_integrity_check(flags: u32, out: ?*WSIntegrityReport) c_int {
    if (flags & ~@as(u32, 1) != 0) {
        setLastErrorMessage("InvalidIntegrityFlags");
        return -1;
    }
    const result = out orelse {
        setLastErrorMessage("NullIntegrityReport");
        return -1;
    };
    if (result.struct_size < @sizeOf(WSIntegrityReport)) {
        setLastErrorMessage("IntegrityReportBufferTooSmall");
        return -1;
    }
    const report = db.integrityCheck(flags & 1 != 0) catch |err| {
        setLastError(err);
        return -1;
    };
    result.* = .{
        .struct_size = @sizeOf(WSIntegrityReport),
        .version = types.WS_INTEGRITY_REPORT_VERSION,
        .checks_run = report.checks_run,
        .errors_found = report.errors_found,
        .schema_version = @intCast(db.schemaVersion() catch db.SCHEMA_VERSION),
        .reserved = 0,
    };
    return if (report.errors_found == 0) 0 else 1;
}

pub export fn ws_backup_create(destination: ?[*:0]const u8) c_int {
    const path = destination orelse {
        setLastErrorMessage("NullBackupPath");
        return -1;
    };
    lockMutations();
    defer mutation_mutex.unlock();
    db.backupTo(std.mem.span(path)) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_backup_compact(destination: ?[*:0]const u8) c_int {
    query_cancel.current = null;
    const path = destination orelse {
        setLastErrorMessage("NullBackupPath");
        return -1;
    };
    db.compactTo(std.mem.span(path)) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_backup_restore(source: ?[*:0]const u8) c_int {
    const path = source orelse {
        setLastErrorMessage("NullBackupPath");
        return -1;
    };
    lockMutations();
    defer mutation_mutex.unlock();
    clap_provider.unload();
    semantic.reset();
    db.restoreFrom(std.mem.span(path)) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_folder_count(folder_id: c_int) c_int {
    return db.countForFolder(folder_id) catch |err| {
        setLastError(err);
        return -1;
    };
}

pub export fn ws_remove_folder(folder_id: c_int) c_int {
    if (folder_id < 0) {
        setLastErrorMessage("InvalidFolderId");
        return -1;
    }
    lockMutations();
    defer mutation_mutex.unlock();
    db.removeFolder(folder_id) catch |err| {
        setLastError(err);
        return -1;
    };
    semantic.reset();
    acoustic.rebuildGroups(allocator) catch |err| setLastError(err);
    return 0;
}

pub export fn ws_duplicate_count(content_hash: i64) c_int {
    return db.duplicateCount(content_hash) catch |err| {
        setLastError(err);
        return -1;
    };
}

pub export fn ws_file_identity_v1(file_id: c_int, out: ?*WSFileIdentity) c_int {
    const result = out orelse {
        setLastErrorMessage("NullIdentityOutput");
        return -1;
    };
    if (file_id <= 0 or result.struct_size < @sizeOf(WSFileIdentity)) {
        setLastErrorMessage("InvalidIdentityArguments");
        return -1;
    }
    const identity = db.fileIdentity(file_id) catch |err| {
        setLastError(err);
        return -1;
    };
    result.* = .{ .struct_size = @sizeOf(WSFileIdentity), .version = 1, .file_id = file_id, .kind = @backingInt(identity.kind), .algorithm = @backingInt(identity.algorithm), .reserved = 0, .content_hash = identity.hash, .file_size = identity.size, .mtime_ns = identity.mtime_ns };
    return 0;
}

pub export fn ws_duplicate_verify_v1(request: ?*query_cancel.Request, file_id: c_int, out: ?*WSDuplicateVerification) c_int {
    const previous = query_cancel.current;
    query_cancel.current = request orelse {
        setLastErrorMessage("NullQueryRequest");
        return -1;
    };
    defer query_cancel.current = previous;
    if (query_cancel.isCancelled()) return queryResult(0);
    const result = out orelse {
        setLastErrorMessage("NullVerificationOutput");
        return -1;
    };
    if (file_id <= 0 or result.struct_size < @sizeOf(WSDuplicateVerification)) {
        setLastErrorMessage("InvalidVerificationArguments");
        return -1;
    }
    const verified = db.verifyDuplicates(file_id) catch |err| {
        setLastError(err);
        return queryResult(-1);
    };
    result.* = .{ .struct_size = @sizeOf(WSDuplicateVerification), .version = 1, .file_id = file_id, .candidate_count = verified.candidate_count, .verified_count = verified.verified_count, .reserved = 0, .source_bytes_read = verified.bytes_read };
    return queryResult(0);
}

pub export fn ws_fingerprint_storage_repack_v1(request: ?*query_cancel.Request, max_files: c_int, out: ?*WSFingerprintStorageResult) c_int {
    const previous = query_cancel.current;
    query_cancel.current = request orelse {
        setLastErrorMessage("NullQueryRequest");
        return -1;
    };
    defer query_cancel.current = previous;
    if (query_cancel.isCancelled()) return queryResult(0);
    const result = out orelse {
        setLastErrorMessage("NullStorageOutput");
        return -1;
    };
    if (max_files <= 0 or max_files > 1024 or result.struct_size < @sizeOf(WSFingerprintStorageResult)) {
        setLastErrorMessage("InvalidStorageArguments");
        return -1;
    }
    const stored = db.repackFingerprints(allocator, @intCast(max_files)) catch |err| {
        setLastError(err);
        return queryResult(-1);
    };
    result.* = .{ .struct_size = @sizeOf(WSFingerprintStorageResult), .version = 1, .processed_count = stored.processed_count, .reserved = 0, .bytes_before = stored.bytes_before, .bytes_after = stored.bytes_after };
    return queryResult(0);
}

pub export fn ws_query_create() ?*query_cancel.Request {
    const request = allocator.create(query_cancel.Request) catch {
        setLastError(error.OutOfMemory);
        return null;
    };
    request.* = .{};
    return request;
}

pub export fn ws_query_cancel(request: ?*query_cancel.Request) void {
    if (request) |value| value.cancel();
}

pub export fn ws_query_destroy(request: ?*query_cancel.Request) void {
    if (request) |value| {
        value.clearLexical();
        allocator.destroy(value);
    }
}

fn queryResult(result: c_int) c_int {
    if (query_cancel.isCancelled()) {
        setLastError(error.Cancelled);
        return -2;
    }
    return result;
}

// The handle remains sticky across the lexical and hybrid stages. Each call
// restores TLS so subsequent legacy calls on this thread remain independent.
pub export fn ws_search_v2(request: ?*query_cancel.Request, query: ?[*:0]const u8, folder_id: c_int, out: ?[*]WSResult, max_results: c_int, flags: u32) c_int {
    const previous = query_cancel.current;
    query_cancel.current = request orelse {
        setLastErrorMessage("NullQueryRequest");
        return -1;
    };
    defer query_cancel.current = previous;
    if (query_cancel.isCancelled()) return queryResult(0);
    if (flags > 1) {
        setLastErrorMessage("InvalidSearchFlags");
        return -1;
    }
    if (flags == 0) return queryResult(ws_search(query, folder_id, out, max_results));
    const text = query orelse {
        setLastErrorMessage("NullQuery");
        return -1;
    };
    if (max_results < 0 or folder_id < -1 or (max_results > 0 and out == null)) {
        setLastErrorMessage("InvalidSearchArguments");
        return -1;
    }
    if (max_results == 0) return queryResult(0);
    const count = search.search(allocator, std.mem.span(text), if (folder_id == -1) null else folder_id, out.?, @intCast(max_results)) catch |err| {
        setLastError(err);
        return queryResult(-1);
    };
    return queryResult(@intCast(count));
}

pub export fn ws_list_folder_v2(request: ?*query_cancel.Request, folder_id: c_int, out: ?[*]WSResult, max_results: c_int) c_int {
    const previous = query_cancel.current;
    query_cancel.current = request orelse {
        setLastErrorMessage("NullQueryRequest");
        return -1;
    };
    defer query_cancel.current = previous;
    if (query_cancel.isCancelled()) return queryResult(0);
    return queryResult(ws_list_folder(folder_id, out, max_results));
}

pub export fn ws_list_folder_page_v2(request: ?*query_cancel.Request, folder_id: c_int, after_name: ?[*:0]const u8, after_id: c_int, out: ?[*]WSResult, max_results: c_int) c_int {
    const previous = query_cancel.current;
    query_cancel.current = request orelse {
        setLastErrorMessage("NullQueryRequest");
        return -1;
    };
    defer query_cancel.current = previous;
    if (query_cancel.isCancelled()) return queryResult(0);
    if (folder_id < 0 or after_id < 0 or max_results < 0 or max_results > 1000 or (after_name == null and after_id != 0) or (max_results > 0 and out == null)) {
        setLastErrorMessage("InvalidPageArguments");
        return -1;
    }
    if (max_results == 0) return 0;
    const name = if (after_name) |ptr| std.mem.span(ptr) else null;
    if (name) |text| if (text.len > 255) {
        setLastErrorMessage("InvalidPageCursor");
        return -1;
    };
    const count = search.listFolderPage(allocator, folder_id, name, after_id, out.?, @intCast(max_results)) catch |err| {
        setLastError(err);
        return queryResult(-1);
    };
    return queryResult(@intCast(count));
}

pub export fn ws_search_by_example_v2(request: ?*query_cancel.Request, path: ?[*:0]const u8, folder_id: c_int, out: ?[*]WSExampleResult, max_results: c_int) c_int {
    const previous = query_cancel.current;
    query_cancel.current = request orelse {
        setLastErrorMessage("NullQueryRequest");
        return -1;
    };
    defer query_cancel.current = previous;
    if (query_cancel.isCancelled()) return queryResult(0);
    return queryResult(ws_search_by_example(path, folder_id, out, max_results));
}

pub export fn ws_search_by_example_pcm_v2(request: ?*query_cancel.Request, samples: ?[*]const f32, frames: u64, channels: u32, sample_rate: u32, folder_id: c_int, out: ?[*]WSExampleResult, max_results: c_int) c_int {
    const previous = query_cancel.current;
    query_cancel.current = request orelse {
        setLastErrorMessage("NullQueryRequest");
        return -1;
    };
    defer query_cancel.current = previous;
    if (query_cancel.isCancelled()) return queryResult(0);
    return queryResult(ws_search_by_example_pcm(samples, frames, channels, sample_rate, folder_id, out, max_results));
}

pub export fn ws_search(query: ?[*:0]const u8, folder_id: c_int, out: ?[*]WSResult, max_results: c_int) c_int {
    const query_ptr = query orelse {
        setLastErrorMessage("NullQuery");
        return -1;
    };
    if (max_results < 0 or folder_id < -1) {
        setLastErrorMessage("InvalidSearchArguments");
        return -1;
    }
    if (max_results == 0) return 0;
    const out_ptr = out orelse {
        setLastErrorMessage("NullResults");
        return -1;
    };
    const query_slice = std.mem.span(query_ptr);
    if (query_slice.len > 4096) {
        setLastError(error.QueryTooLong);
        return -1;
    }
    const parsed = search.parseSearchQuery(query_slice);
    if (!parsed.impossible and !parsed.text.isEmpty() and clap_provider.canSearch()) {
        var embedding: [512]f32 = undefined;
        clap_provider.embedText(parsed.text.slice(), &embedding) catch |err| {
            if (err == error.Cancelled or query_cancel.isCancelled()) return queryResult(-1);
            // A provider failure must never remove lexical search availability,
            // but preserve the diagnostic for UI/logging.
            setLastError(err);
            const fallback = search.search(allocator, query_slice, if (folder_id == -1) null else folder_id, out_ptr, @intCast(max_results)) catch |search_err| {
                setLastError(search_err);
                return -1;
            };
            return @intCast(fallback);
        };
        const hybrid = search.searchWithEmbedding(allocator, query_slice, &embedding, if (folder_id == -1) null else folder_id, out_ptr, @intCast(max_results)) catch |err| {
            if (err == error.Cancelled or query_cancel.isCancelled()) return queryResult(-1);
            setLastError(err);
            const fallback = search.search(allocator, query_slice, if (folder_id == -1) null else folder_id, out_ptr, @intCast(max_results)) catch |search_err| {
                setLastError(search_err);
                return -1;
            };
            return @intCast(fallback);
        };
        return @intCast(hybrid);
    }
    const n = search.search(allocator, query_slice, if (folder_id == -1) null else folder_id, out_ptr, @intCast(max_results)) catch |err| {
        setLastError(err);
        return -1;
    };
    return @intCast(n);
}

// Cheap capability check; never count the semantic catalog on a keystroke.
pub export fn ws_search_needs_refinement(query: ?[*:0]const u8) c_int {
    const text = query orelse return 0;
    const bytes = std.mem.span(text);
    if (bytes.len > 4096 or !clap_provider.canSearch()) return 0;
    const parsed = search.parseSearchQuery(bytes);
    return @intFromBool(!parsed.impossible and !parsed.text.isEmpty());
}

pub export fn ws_clap_load(runtime_library_path: ?[*:0]const u8, model_dir: ?[*:0]const u8, intra_op_threads: c_int) c_int {
    const runtime_ptr = runtime_library_path orelse {
        setLastErrorMessage("NullRuntimeLibraryPath");
        return -1;
    };
    const model_ptr = model_dir orelse {
        setLastErrorMessage("NullModelDirectory");
        return -1;
    };
    if (intra_op_threads <= 0 or intra_op_threads > std.math.maxInt(u31)) {
        setLastErrorMessage("InvalidThreadCount");
        return -1;
    }
    lockMutations();
    defer mutation_mutex.unlock();
    clap_provider.load(std.mem.span(runtime_ptr), std.mem.span(model_ptr), @intCast(intra_op_threads)) catch |err| {
        setLastError(err);
        return -1;
    };
    semantic.reset();
    return 0;
}

pub export fn ws_clap_unload() void {
    lockMutations();
    defer mutation_mutex.unlock();
    clap_provider.unload();
}

pub export fn ws_refinement_generation() u64 {
    return cancellation.currentGeneration();
}

pub export fn ws_clap_index_pending(folder_id: c_int, max_files: c_int) c_int {
    return clapIndexPending(folder_id, max_files, null);
}

pub export fn ws_clap_index_pending_v2(folder_id: c_int, max_files: c_int, expected_generation: u64) c_int {
    return clapIndexPending(folder_id, max_files, expected_generation);
}

fn clapIndexPending(folder_id: c_int, max_files: c_int, expected_generation: ?u64) c_int {
    if (folder_id < -1 or max_files < 0) {
        setLastErrorMessage("InvalidIndexArguments");
        return -1;
    }
    lockMutations();
    defer mutation_mutex.unlock();
    const result = if (expected_generation) |generation|
        clap_provider.indexPendingExpected(allocator, if (folder_id == -1) null else folder_id, @intCast(max_files), generation)
    else
        clap_provider.indexPending(allocator, if (folder_id == -1) null else folder_id, @intCast(max_files));
    const value = result catch |err| {
        setLastError(err);
        return -1;
    };
    semantic.reset();
    if (value.successful > std.math.maxInt(c_int)) {
        setLastErrorMessage("IndexCountOverflow");
        return -1;
    }
    return @intCast(value.successful);
}

pub export fn ws_semantic_model_set(model_key: ?[*:0]const u8, dimension: c_int) c_int {
    const key_ptr = model_key orelse {
        setLastErrorMessage("NullModelKey");
        return -1;
    };
    if (dimension <= 0 or dimension > vector.MAX_DIMENSION) {
        setLastErrorMessage("InvalidDimension");
        return -1;
    }
    lockMutations();
    defer mutation_mutex.unlock();
    if (clap_provider.isLoaded()) {
        setLastErrorMessage("ProviderLoaded");
        return -1;
    }
    _ = db.setSemanticModel(std.mem.span(key_ptr), @intCast(dimension)) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_semantic_embedding_upsert(file_id: c_int, content_hash: i64, values: ?[*]const f32, dimension: c_int) c_int {
    const vector_ptr = values orelse {
        setLastErrorMessage("NullVector");
        return -1;
    };
    if (file_id <= 0 or dimension <= 0 or dimension > vector.MAX_DIMENSION) {
        setLastErrorMessage("InvalidDimensionOrFileId");
        return -1;
    }
    db.upsertSemanticEmbedding(allocator, file_id, content_hash, vector_ptr[0..@intCast(dimension)]) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_search_with_embedding(
    query: ?[*:0]const u8,
    query_vector: ?[*]const f32,
    dimension: c_int,
    folder_id: c_int,
    out: ?[*]WSResult,
    max_results: c_int,
) c_int {
    const query_ptr = query orelse {
        setLastErrorMessage("NullQuery");
        return -1;
    };
    const vector_ptr = query_vector orelse {
        setLastErrorMessage("NullVector");
        return -1;
    };
    if (dimension <= 0 or dimension > vector.MAX_DIMENSION or max_results < 0 or folder_id < -1) {
        setLastErrorMessage("InvalidSearchArguments");
        return -1;
    }
    if (max_results == 0) return 0;
    const out_ptr = out orelse {
        setLastErrorMessage("NullResults");
        return -1;
    };
    const n = search.searchWithEmbedding(
        allocator,
        std.mem.span(query_ptr),
        vector_ptr[0..@intCast(dimension)],
        if (folder_id == -1) null else folder_id,
        out_ptr,
        @intCast(max_results),
    ) catch |err| {
        setLastError(err);
        return -1;
    };
    return @intCast(n);
}

pub export fn ws_semantic_status(out: ?*WSSemanticStatus) c_int {
    const result = out orelse {
        setLastErrorMessage("NullStatus");
        return -1;
    };
    if (result.struct_size < @sizeOf(WSSemanticStatus)) {
        setLastErrorMessage("SemanticStatusBufferTooSmall");
        return -1;
    }
    const status = db.semanticStatus() catch |err| {
        setLastError(err);
        return -1;
    };
    result.* = .{
        .struct_size = @sizeOf(WSSemanticStatus),
        .version = types.WS_SEMANTIC_STATUS_VERSION,
        .active = if (status.active) 1 else 0,
        .dimension = @intCast(status.dimension),
        .model_id = status.model_id,
        .generation = status.generation,
        .embedded_count = status.embedded_count,
        .pending_count = status.pending_count,
        .model_key = status.model_key,
        .failed_count = status.failed_count,
        .provider_loaded = if (clap_provider.isLoaded()) 1 else 0,
    };
    return 0;
}

pub export fn ws_list_folder(folder_id: c_int, out: ?[*]WSResult, max_results: c_int) c_int {
    if (max_results < 0 or folder_id < 0) {
        setLastErrorMessage("InvalidListArguments");
        return -1;
    }
    if (max_results == 0) return 0;
    const out_ptr = out orelse {
        setLastErrorMessage("NullResults");
        return -1;
    };
    const n = search.listFolder(allocator, folder_id, out_ptr, @intCast(max_results)) catch |err| {
        setLastError(err);
        return -1;
    };
    return @intCast(n);
}

pub export fn ws_acoustic_index_pending(folder_id: c_int, max_files: c_int) c_int {
    return acousticIndexPending(folder_id, max_files, null);
}

pub export fn ws_acoustic_index_pending_v2(folder_id: c_int, max_files: c_int, expected_generation: u64) c_int {
    return acousticIndexPending(folder_id, max_files, expected_generation);
}

fn acousticIndexPending(folder_id: c_int, max_files: c_int, expected_generation: ?u64) c_int {
    if (folder_id < -1 or max_files < 0) {
        setLastErrorMessage("InvalidIndexArguments");
        return -1;
    }
    lockMutations();
    defer mutation_mutex.unlock();
    const result = if (expected_generation) |generation|
        acoustic.indexPendingExpected(allocator, if (folder_id == -1) null else folder_id, @intCast(max_files), generation)
    else
        acoustic.indexPending(allocator, if (folder_id == -1) null else folder_id, @intCast(max_files));
    const value = result catch |err| {
        setLastError(err);
        return -1;
    };
    if (value.successful > std.math.maxInt(c_int)) {
        setLastErrorMessage("IndexCountOverflow");
        return -1;
    }
    return @intCast(value.successful);
}

pub export fn ws_acoustic_status(out: ?*WSAcousticStatus) c_int {
    const result = out orelse {
        setLastErrorMessage("NullStatus");
        return -1;
    };
    if (result.struct_size < @sizeOf(WSAcousticStatus)) {
        setLastErrorMessage("AcousticStatusBufferTooSmall");
        return -1;
    }
    const status = acoustic.status() catch |err| {
        setLastError(err);
        return -1;
    };
    result.* = .{
        .struct_size = @sizeOf(WSAcousticStatus),
        .version = types.WS_ACOUSTIC_STATUS_VERSION,
        .indexed_count = status.indexed,
        .pending_count = status.pending,
        .failed_count = status.failed,
    };
    return 0;
}

pub export fn ws_search_by_example(path: ?[*:0]const u8, folder_id: c_int, out: ?[*]WSExampleResult, max_results: c_int) c_int {
    const path_ptr = path orelse {
        setLastErrorMessage("NullAudioPath");
        return -1;
    };
    if (folder_id < -1 or max_results < 0) {
        setLastErrorMessage("InvalidSearchArguments");
        return -1;
    }
    if (max_results == 0) return 0;
    const output = out orelse {
        setLastErrorMessage("NullResults");
        return -1;
    };
    const max: usize = @intCast(max_results);
    if (max > std.math.maxInt(usize) / @sizeOf(WSExampleResult)) {
        setLastErrorMessage("ResultSizeOverflow");
        return -1;
    }
    for (output[0..max]) |*item| if (item.struct_size != @sizeOf(WSExampleResult)) {
        setLastErrorMessage("ExampleResultBufferTooSmall");
        return -1;
    };
    const matches = acoustic.searchPath(allocator, std.mem.span(path_ptr), if (folder_id == -1) null else folder_id, max) catch |err| {
        setLastError(err);
        return -1;
    };
    defer allocator.free(matches);
    fillExampleResults(matches, output);
    return @intCast(matches.len);
}

pub export fn ws_search_by_example_pcm(samples: ?[*]const f32, frames: u64, channels: u32, sample_rate: u32, folder_id: c_int, out: ?[*]WSExampleResult, max_results: c_int) c_int {
    const pcm = samples orelse {
        setLastErrorMessage("NullPcm");
        return -1;
    };
    if (frames == 0 or frames > std.math.maxInt(usize) or channels == 0 or channels > clap_audio.MAX_CHANNELS or sample_rate == 0 or frames > @as(u64, sample_rate) * clap_audio.MAX_EXTERNAL_PCM_SECONDS or folder_id < -1 or max_results < 0) {
        setLastErrorMessage("InvalidPcmSearchArguments");
        return -1;
    }
    if (max_results == 0) return 0;
    const output = out orelse {
        setLastErrorMessage("NullResults");
        return -1;
    };
    const max: usize = @intCast(max_results);
    if (max > std.math.maxInt(usize) / @sizeOf(WSExampleResult)) {
        setLastErrorMessage("ResultSizeOverflow");
        return -1;
    }
    for (output[0..max]) |*item| if (item.struct_size != @sizeOf(WSExampleResult)) {
        setLastErrorMessage("ExampleResultBufferTooSmall");
        return -1;
    };
    const sample_count = std.math.mul(usize, @intCast(frames), @intCast(channels)) catch {
        setLastErrorMessage("PcmSizeOverflow");
        return -1;
    };
    if (sample_count > std.math.maxInt(usize) / @sizeOf(f32)) {
        setLastErrorMessage("PcmSizeOverflow");
        return -1;
    }
    const matches = acoustic.searchPcm(allocator, pcm[0..sample_count], @intCast(frames), @intCast(channels), sample_rate, if (folder_id == -1) null else folder_id, max) catch |err| {
        setLastError(err);
        return -1;
    };
    defer allocator.free(matches);
    fillExampleResults(matches, output);
    return @intCast(matches.len);
}

fn fillExampleResults(matches: []const acoustic.SearchResult, output: [*]WSExampleResult) void {
    for (matches, output[0..matches.len]) |match, *dest| dest.* = .{
        .struct_size = @sizeOf(WSExampleResult),
        .version = types.WS_EXAMPLE_RESULT_VERSION,
        .result = candidateResult(&match.candidate),
        .fused_score = match.fused_score,
        .fingerprint_score_ppm = match.fingerprint_score_ppm,
        .fingerprint_votes = match.fingerprint_votes,
        .offset_ms = @intCast(@divTrunc(@as(i64, match.offset_frames) * fingerprint.HOP_SIZE * 1000, clap_audio.FINGERPRINT_SAMPLE_RATE)),
        .embedding_rank = if (match.embedding_rank) |rank| @intCast(rank) else -1,
        .acoustic_group_id = match.group_id,
    };
}

pub export fn ws_acoustic_group(file_id: c_int, out: ?*WSAcousticGroup) c_int {
    const result = out orelse {
        setLastErrorMessage("NullGroup");
        return -1;
    };
    if (file_id <= 0 or result.struct_size < @sizeOf(WSAcousticGroup)) {
        setLastErrorMessage("InvalidGroupArguments");
        return -1;
    }
    const info = acoustic.groupInfo(allocator, file_id) catch |err| {
        setLastError(err);
        return -1;
    } orelse {
        setLastErrorMessage("FingerprintNotFound");
        return -1;
    };
    result.* = .{
        .struct_size = @sizeOf(WSAcousticGroup),
        .version = types.WS_ACOUSTIC_GROUP_VERSION,
        .file_id = file_id,
        .member_count = info.member_count,
        .group_id = info.group_id,
        .confidence_ppm = info.confidence_ppm,
        .reserved = 0,
    };
    return 0;
}

fn candidateResult(candidate: *const db.Candidate) WSResult {
    return .{
        .file_id = candidate.file_id,
        .folder_id = candidate.folder_id,
        .path = candidate.path,
        .name = candidate.name,
        .duration_ms = candidate.duration_ms,
        .content_hash = candidate.content_hash,
    };
}

const LegacySourceIdentity = struct { file_size: i64, mtime_ns: i64 };

fn legacySourceIdentity(path: []const u8) !LegacySourceIdentity {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return .{
        .file_size = std.math.cast(i64, stat.size) orelse return error.FileTooLarge,
        .mtime_ns = std.math.cast(i64, stat.mtime.nanoseconds) orelse return error.InvalidModificationTime,
    };
}

pub export fn ws_waveform(path: ?[*:0]const u8, out_samples: ?[*]f32, num_points: c_int) c_int {
    const path_ptr = path orelse {
        setLastErrorMessage("NullAudioPath");
        return -1;
    };
    if (num_points < 0) {
        setLastErrorMessage("NegativeSampleCount");
        return -1;
    }
    if (num_points == 0) return 0;
    const samples_ptr = out_samples orelse {
        setLastErrorMessage("NullSamples");
        return -1;
    };
    const path_slice = std.mem.span(path_ptr);
    const n: usize = @intCast(num_points);
    if (db.getWaveform(allocator, path_slice) catch null) |cached| {
        defer allocator.free(cached);
        // The cache stores the requested resolution. A different resolution
        // must be regenerated rather than truncated or padded with fake data.
        if (cached.len == n) {
            @memcpy(samples_ptr[0..n], cached);
            return 0;
        }
    }
    const catalog_identity = db.legacyWaveformIdentity(path_slice) catch null;
    const source_before = legacySourceIdentity(path_slice) catch null;
    audio.waveform(path_slice, samples_ptr, n) catch |err| {
        setLastError(err);
        return -1;
    };
    if (catalog_identity) |catalog| if (source_before) |before| {
        const after = legacySourceIdentity(path_slice) catch return 0;
        if (catalog.file_size == before.file_size and catalog.mtime_ns == before.mtime_ns and
            before.file_size == after.file_size and before.mtime_ns == after.mtime_ns)
            _ = db.saveWaveformIfIdentity(path_slice, catalog, samples_ptr[0..n]) catch false;
    };
    return 0;
}

fn waveformStatus(err: anyerror) c_int {
    setLastError(err);
    return switch (err) {
        error.InvalidArgument => -100,
        error.UnsupportedVersion => -101,
        error.InvalidState => -102,
        error.UnsupportedBackend => -103,
        error.OutOfMemory => -104,
        error.Cancelled => -105,
        error.FrameCountMismatch => -106,
        error.BufferTooSmall => -107,
        error.CorruptWvt3 => -108,
        else => -100,
    };
}

fn waveformAnalyzer(handle: *anyopaque) *waveform.Analyzer {
    return @ptrCast(@alignCast(handle));
}

fn waveformResult(handle: *const anyopaque) *const waveform.Result {
    return @ptrCast(@alignCast(handle));
}

pub export fn ws_waveform_analyzer_create_v1(config: ?*const WSWaveformAnalyzerConfig, out_analyzer: ?*?*anyopaque) c_int {
    const output = out_analyzer orelse return waveformStatus(error.InvalidArgument);
    output.* = null;
    const value = config orelse return waveformStatus(error.InvalidArgument);
    const analyzer = waveform.Analyzer.create(allocator, value.*) catch |err| return waveformStatus(err);
    output.* = @ptrCast(analyzer);
    return 0;
}

pub export fn ws_waveform_analyzer_push_v1(handle: ?*anyopaque, buffer: ?*const WSWaveformPCMBuffer) c_int {
    const analyzer = waveformAnalyzer(handle orelse return waveformStatus(error.InvalidArgument));
    const value = buffer orelse return waveformStatus(error.InvalidArgument);
    analyzer.push(value.*) catch |err| return waveformStatus(err);
    return 0;
}

pub export fn ws_waveform_analyzer_cancel(handle: ?*anyopaque) c_int {
    const analyzer = waveformAnalyzer(handle orelse return waveformStatus(error.InvalidArgument));
    analyzer.cancel();
    return 0;
}

pub export fn ws_waveform_analyzer_finish_v1(handle: ?*anyopaque, out_result: ?*?*anyopaque) c_int {
    const output = out_result orelse return waveformStatus(error.InvalidArgument);
    output.* = null;
    const analyzer = waveformAnalyzer(handle orelse return waveformStatus(error.InvalidArgument));
    const result = analyzer.finish() catch |err| return waveformStatus(err);
    output.* = @ptrCast(result);
    return 0;
}

pub export fn ws_waveform_analyzer_destroy(handle: ?*anyopaque) void {
    if (handle) |value| waveformAnalyzer(value).deinit();
}

pub export fn ws_waveform_result_create_v1(info: ?*const WSWaveformResultInfo, peaks: ?[*]const WSWaveformPeak, peak_count: u64, out_result: ?*?*anyopaque) c_int {
    const output = out_result orelse return waveformStatus(error.InvalidArgument);
    output.* = null;
    if (peak_count > std.math.maxInt(usize)) return waveformStatus(error.InvalidArgument);
    const values = if (peak_count == 0)
        &[_]WSWaveformPeak{}
    else
        (peaks orelse return waveformStatus(error.InvalidArgument))[0..@intCast(peak_count)];
    const result = waveform.resultFromHost(allocator, (info orelse return waveformStatus(error.InvalidArgument)).*, values) catch |err| return waveformStatus(err);
    output.* = @ptrCast(result);
    return 0;
}

pub export fn ws_waveform_result_info_v1(handle: ?*const anyopaque, out_info: ?*WSWaveformResultInfo) c_int {
    const output = out_info orelse return waveformStatus(error.InvalidArgument);
    if (output.struct_size != @sizeOf(WSWaveformResultInfo) or output.version != types.WS_WAVEFORM_RESULT_INFO_VERSION) return waveformStatus(error.UnsupportedVersion);
    waveformResult(handle orelse return waveformStatus(error.InvalidArgument)).fillInfo(output);
    return 0;
}

pub export fn ws_waveform_result_copy_level_v1(handle: ?*const anyopaque, level_index: u32, out_peaks: ?[*]WSWaveformPeak, capacity: u64, required: ?*u64) c_int {
    const needed = required orelse return waveformStatus(error.InvalidArgument);
    const result = waveformResult(handle orelse return waveformStatus(error.InvalidArgument));
    if (level_index >= result.levels.len) return waveformStatus(error.InvalidArgument);
    const level = result.levels[level_index];
    const count: u64 = @intCast(level.bucket_count * level.rendered_channels);
    needed.* = count;
    if (out_peaks == null and capacity == 0) return 0;
    if (capacity < count) return waveformStatus(error.BufferTooSmall);
    if (count == 0) return 0;
    const output = out_peaks orelse return waveformStatus(error.InvalidArgument);
    for (0..level.rendered_channels) |channel| for (0..level.bucket_count) |bucket| {
        const index = channel * level.bucket_count + bucket;
        const offset = index * 2;
        output[index] = .{
            .minimum = waveform.muDecode(level.codes[offset]) catch return waveformStatus(error.CorruptWvt3),
            .maximum = waveform.muDecode(level.codes[offset + 1]) catch return waveformStatus(error.CorruptWvt3),
        };
    };
    return 0;
}

pub export fn ws_waveform_result_serialize_wvt3_v1(handle: ?*const anyopaque, tier: u32, out_bytes: ?[*]u8, capacity: u64, required: ?*u64) c_int {
    const needed = required orelse return waveformStatus(error.InvalidArgument);
    const result = waveformResult(handle orelse return waveformStatus(error.InvalidArgument));
    const size = waveform.serializedSize(result, tier) catch |err| return waveformStatus(err);
    needed.* = size;
    if (out_bytes == null and capacity == 0) return 0;
    if (capacity < size) return waveformStatus(error.BufferTooSmall);
    if (size == 0) return 0;
    const output = out_bytes orelse return waveformStatus(error.InvalidArgument);
    _ = waveform.serialize(result, tier, output[0..size]) catch |err| return waveformStatus(err);
    return 0;
}

pub export fn ws_waveform_result_deserialize_wvt3_v1(bytes: ?[*]const u8, size: u64, out_result: ?*?*anyopaque) c_int {
    const output = out_result orelse return waveformStatus(error.InvalidArgument);
    output.* = null;
    if (size == 0 or size > 4 * 1024 * 1024 or size > std.math.maxInt(usize)) return waveformStatus(error.InvalidArgument);
    const input = (bytes orelse return waveformStatus(error.InvalidArgument))[0..@intCast(size)];
    const result = waveform.deserialize(allocator, input) catch |err| return waveformStatus(err);
    output.* = @ptrCast(result);
    return 0;
}

pub export fn ws_waveform_result_destroy(handle: ?*anyopaque) void {
    if (handle) |value| {
        const result: *waveform.Result = @ptrCast(@alignCast(value));
        result.deinit();
    }
}

const MAX_WAVEFORM_CACHE_BYTES: usize = 64 * 1024 * 1024;

pub export fn ws_waveform_cache_size(path: ?[*:0]const u8) i64 {
    const path_ptr = path orelse {
        setLastErrorMessage("NullAudioPath");
        return -1;
    };
    const size = db.waveformCacheBlobSize(std.mem.span(path_ptr), MAX_WAVEFORM_CACHE_BYTES) catch |err| {
        setLastError(err);
        return -1;
    } orelse return 0;
    return @intCast(size);
}

pub export fn ws_waveform_cache_load(path: ?[*:0]const u8, out_bytes: ?[*]u8, capacity: u64) c_int {
    const path_ptr = path orelse {
        setLastErrorMessage("NullAudioPath");
        return -1;
    };
    if (capacity > MAX_WAVEFORM_CACHE_BYTES or capacity > std.math.maxInt(usize)) {
        setLastErrorMessage("WaveformCacheBufferTooLarge");
        return -1;
    }
    const output = out_bytes orelse {
        setLastErrorMessage("NullWaveformCacheBuffer");
        return -1;
    };
    const loaded = db.loadWaveformCacheBlob(std.mem.span(path_ptr), output[0..@intCast(capacity)]) catch |err| {
        setLastError(err);
        return -1;
    } orelse return 0;
    return @intCast(loaded);
}

pub export fn ws_waveform_cache_store(path: ?[*:0]const u8, bytes: ?[*]const u8, size: u64) c_int {
    const path_ptr = path orelse {
        setLastErrorMessage("NullAudioPath");
        return -1;
    };
    if (size == 0 or size > MAX_WAVEFORM_CACHE_BYTES or size > std.math.maxInt(usize)) {
        setLastErrorMessage("InvalidWaveformCacheSize");
        return -1;
    }
    const input = bytes orelse {
        setLastErrorMessage("NullWaveformCacheBytes");
        return -1;
    };
    db.saveWaveformCacheBlob(std.mem.span(path_ptr), input[0..@intCast(size)]) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

const MAX_WAVEFORM_TIER_BYTES: usize = 4 * 1024 * 1024;
pub const WS_WAVEFORM_TIER_UNIVERSAL: u32 = 1;
pub const WS_WAVEFORM_TIER_DETAILED: u32 = 2;

fn waveformTierIsDetailed(tier: u32) !bool {
    return switch (tier) {
        WS_WAVEFORM_TIER_UNIVERSAL => false,
        WS_WAVEFORM_TIER_DETAILED => true,
        else => error.InvalidWaveformTier,
    };
}

pub export fn ws_waveform_identity_refresh(file_id: c_int, content_hash: i64, file_size: i64, mtime_ns: i64) c_int {
    const refreshed = db.refreshLegacyWaveformIdentity(file_id, content_hash, file_size, mtime_ns) catch |err| {
        setLastError(err);
        return -1;
    };
    if (!refreshed) {
        setLastErrorMessage("StaleWaveformIdentity");
        return -1;
    }
    return 0;
}

pub export fn ws_waveform_tier_size(file_id: c_int, tier: u32) i64 {
    if (file_id <= 0) {
        setLastErrorMessage("InvalidFileId");
        return -1;
    }
    const detailed = waveformTierIsDetailed(tier) catch |err| {
        setLastError(err);
        return -1;
    };
    const size = db.waveformTierBlobSize(file_id, detailed, MAX_WAVEFORM_TIER_BYTES) catch |err| {
        setLastError(err);
        return -1;
    } orelse return 0;
    return @intCast(size);
}

pub export fn ws_waveform_tier_load(file_id: c_int, tier: u32, out_bytes: ?[*]u8, capacity: u64) c_int {
    if (file_id <= 0 or capacity > MAX_WAVEFORM_TIER_BYTES or capacity > std.math.maxInt(usize)) {
        setLastErrorMessage("InvalidWaveformTierLoad");
        return -1;
    }
    const detailed = waveformTierIsDetailed(tier) catch |err| {
        setLastError(err);
        return -1;
    };
    const output = out_bytes orelse {
        setLastErrorMessage("NullWaveformTierBuffer");
        return -1;
    };
    const loaded = db.loadWaveformTierBlob(file_id, detailed, output[0..@intCast(capacity)]) catch |err| {
        setLastError(err);
        return -1;
    } orelse return 0;
    return @intCast(loaded);
}

pub export fn ws_waveform_tiers_store(
    file_id: c_int,
    content_hash: i64,
    file_size: i64,
    mtime_ns: i64,
    codec_version: u32,
    universal_bytes: ?[*]const u8,
    universal_size: u64,
    detailed_bytes: ?[*]const u8,
    detailed_size: u64,
) c_int {
    if (file_id <= 0 or codec_version == 0 or codec_version > std.math.maxInt(i32) or universal_size == 0 or universal_size > MAX_WAVEFORM_TIER_BYTES or detailed_size > MAX_WAVEFORM_TIER_BYTES or universal_size > std.math.maxInt(usize) or detailed_size > std.math.maxInt(usize)) {
        setLastErrorMessage("InvalidWaveformTierStore");
        return -1;
    }
    const universal_ptr = universal_bytes orelse {
        setLastErrorMessage("NullUniversalWaveformBytes");
        return -1;
    };
    const detailed: ?[]const u8 = if (detailed_size == 0) null else blk: {
        const ptr = detailed_bytes orelse {
            setLastErrorMessage("NullDetailedWaveformBytes");
            return -1;
        };
        break :blk ptr[0..@intCast(detailed_size)];
    };
    db.storeWaveformTiers(file_id, content_hash, file_size, mtime_ns, @intCast(codec_version), universal_ptr[0..@intCast(universal_size)], detailed) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_waveform_tier_touch(file_id: c_int, tier: u32) c_int {
    if (file_id <= 0 or tier != WS_WAVEFORM_TIER_DETAILED) {
        setLastErrorMessage("InvalidWaveformTierTouch");
        return -1;
    }
    db.touchDetailedWaveform(file_id) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_waveform_work_claim(out: ?*WSWaveformWorkItem) c_int {
    const result = out orelse {
        setLastErrorMessage("NullWaveformWorkItem");
        return -1;
    };
    if (result.struct_size < @sizeOf(WSWaveformWorkItem)) {
        setLastErrorMessage("WaveformWorkBufferTooSmall");
        return -1;
    }
    var item = db.nextWaveformWork(allocator) catch |err| {
        setLastError(err);
        return -1;
    } orelse return 0;
    defer item.deinit(allocator);
    result.* = std.mem.zeroes(WSWaveformWorkItem);
    result.struct_size = @sizeOf(WSWaveformWorkItem);
    result.version = types.WS_WAVEFORM_WORK_VERSION;
    result.file_id = item.file_id;
    result.content_hash = item.content_hash;
    result.file_size = item.file_size;
    result.mtime_ns = item.mtime_ns;
    const length = @min(item.path.len, result.path.len - 1);
    @memcpy(result.path[0..length], item.path[0..length]);
    return 1;
}

pub export fn ws_waveform_work_claim_v2(out: ?*WSWaveformWorkClaim) c_int {
    const result = out orelse {
        setLastErrorMessage("NullWaveformWorkClaim");
        return -1;
    };
    if (result.struct_size < @sizeOf(WSWaveformWorkClaim)) {
        setLastErrorMessage("WaveformWorkClaimBufferTooSmall");
        return -1;
    }
    var item = db.nextWaveformWork(allocator) catch |err| {
        setLastError(err);
        return -1;
    } orelse return 0;
    defer item.deinit(allocator);
    result.* = std.mem.zeroes(WSWaveformWorkClaim);
    result.struct_size = @sizeOf(WSWaveformWorkClaim);
    result.version = types.WS_WAVEFORM_WORK_CLAIM_VERSION;
    result.file_id = item.file_id;
    result.content_hash = item.content_hash;
    result.file_size = item.file_size;
    result.mtime_ns = item.mtime_ns;
    result.claim_token = item.claim_token;
    result.claim_until_ns = item.claim_until_ns;
    const length = @min(item.path.len, result.path.len - 1);
    @memcpy(result.path[0..length], item.path[0..length]);
    return 1;
}

pub export fn ws_waveform_work_renew(file_id: c_int, claim_token: u64) c_int {
    if (file_id <= 0 or claim_token == 0) {
        setLastErrorMessage("InvalidWaveformWorkClaim");
        return -1;
    }
    db.renewWaveformWork(file_id, claim_token) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_waveform_work_release(file_id: c_int, claim_token: u64) c_int {
    if (file_id <= 0 or claim_token == 0) {
        setLastErrorMessage("InvalidWaveformWorkClaim");
        return -1;
    }
    db.releaseWaveformWork(file_id, claim_token) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_waveform_work_pending() c_int {
    return if (db.waveformWorkPending() catch |err| {
        setLastError(err);
        return -1;
    }) 1 else 0;
}

pub export fn ws_waveform_work_fail(file_id: c_int, content_hash: i64, file_size: i64, mtime_ns: i64, permanent: c_int, detail: ?[*:0]const u8) c_int {
    const detail_ptr = detail orelse {
        setLastErrorMessage("NullWaveformFailureDetail");
        return -1;
    };
    db.recordWaveformFailure(file_id, content_hash, file_size, mtime_ns, null, permanent != 0, std.mem.span(detail_ptr)) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_waveform_work_fail_v2(file_id: c_int, content_hash: i64, file_size: i64, mtime_ns: i64, claim_token: u64, permanent: c_int, detail: ?[*:0]const u8) c_int {
    const detail_ptr = detail orelse {
        setLastErrorMessage("NullWaveformFailureDetail");
        return -1;
    };
    if (file_id <= 0 or claim_token == 0) {
        setLastErrorMessage("InvalidWaveformWorkClaim");
        return -1;
    }
    db.recordWaveformFailure(file_id, content_hash, file_size, mtime_ns, claim_token, permanent != 0, std.mem.span(detail_ptr)) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_waveform_cache_status(out: ?*WSWaveformCacheStatus) c_int {
    const result = out orelse {
        setLastErrorMessage("NullWaveformCacheStatus");
        return -1;
    };
    if (result.struct_size < @sizeOf(WSWaveformCacheStatus)) {
        setLastErrorMessage("WaveformCacheStatusBufferTooSmall");
        return -1;
    }
    const status = db.waveformCacheStatus() catch |err| {
        setLastError(err);
        return -1;
    };
    result.* = .{
        .struct_size = @sizeOf(WSWaveformCacheStatus),
        .version = types.WS_WAVEFORM_CACHE_STATUS_VERSION,
        .universal_count = status.universal_count,
        .detailed_count = status.detailed_count,
        .pending_count = status.pending_count,
        .failed_count = status.failed_count,
        .universal_bytes = status.universal_bytes,
        .detailed_bytes = status.detailed_bytes,
        .detailed_budget_bytes = status.detailed_budget_bytes,
    };
    return 0;
}

pub export fn ws_waveform_cache_set_detailed_budget(bytes: i64) c_int {
    db.setWaveformDetailedBudget(bytes) catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_waveform_cache_clear() c_int {
    lockMutations();
    defer mutation_mutex.unlock();
    db.clearWaveformCache() catch |err| {
        setLastError(err);
        return -1;
    };
    return 0;
}

pub export fn ws_last_error_message() [*:0]const u8 {
    return &last_error_buf;
}
