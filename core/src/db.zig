const std = @import("std");
const builtin = @import("builtin");
const vector = @import("vector.zig");
const fingerprint = @import("fingerprint.zig");
const sync = @import("sync.zig");
const query_cancel = @import("query.zig");
const text_mod = @import("text.zig");
const optimization_schema = @import("schema_optimizations.zig");
const refinement_schema = @import("refinement_schema.zig");

// SQLite invokes progress on the executing thread. TLS selects only that
// request; never sqlite3_interrupt the shared connection from a canceller.
fn queryProgress(_: ?*anyopaque) callconv(.c) c_int {
    return if (query_cancel.isCancelled()) 1 else 0;
}

pub const c = @import("c");
extern fn ws_sqlite_transient() c.sqlite3_destructor_type;

pub const SCHEMA_VERSION: i32 = 14;
pub const Testing = if (builtin.is_test) struct {
    pub threadlocal var before_fingerprint_repack_publish: ?*const fn () void = null;
} else struct {};
const file_identity = @import("file_identity.zig");
const storage_schema = @import("storage_schema.zig");
pub const PAGE_SIZE: usize = 16384;
pub const CACHE_KIB: usize = 8192;
const QUANTIZED_BACKFILL_SQL = "INSERT OR REPLACE INTO semantic_sq8 SELECT model_id,file_id,source_content_hash,ws_sq8_v1(vector) FROM file_embeddings;";
pub const QUANTIZED_INDEX_SQL =
    "CREATE TABLE IF NOT EXISTS semantic_sq8(" ++
    "model_id INTEGER NOT NULL,file_id INTEGER NOT NULL,source_content_hash INTEGER NOT NULL,code BLOB NOT NULL," ++
    "PRIMARY KEY(model_id,file_id),FOREIGN KEY(model_id,file_id) REFERENCES file_embeddings(model_id,file_id) ON DELETE CASCADE ON UPDATE CASCADE) WITHOUT ROWID;" ++
    QUANTIZED_BACKFILL_SQL ++
    "CREATE TRIGGER IF NOT EXISTS file_embeddings_sq8_ai AFTER INSERT ON file_embeddings BEGIN " ++
    "INSERT INTO semantic_sq8 VALUES(new.model_id,new.file_id,new.source_content_hash,ws_sq8_v1(new.vector)); END;" ++
    "CREATE TRIGGER IF NOT EXISTS file_embeddings_sq8_au AFTER UPDATE OF vector,source_content_hash ON file_embeddings BEGIN " ++
    "UPDATE semantic_sq8 SET source_content_hash=new.source_content_hash,code=ws_sq8_v1(new.vector) WHERE model_id=new.model_id AND file_id=new.file_id; END;";
pub const DROP_QUANTIZED_INDEX_SQL = "DROP TRIGGER file_embeddings_sq8_ai; DROP TRIGGER file_embeddings_sq8_au; DROP TABLE semantic_sq8;";

/// SQLite owns index maintenance, rollback, and backup consistency. No separate
/// ANN graph or cache can become stale after an embedding update.
pub fn registerVectorFunctions(handle: *c.sqlite3) !void {
    const Callback = struct {
        fn quantize(context: ?*c.sqlite3_context, _: c_int, args: [*c]?*c.sqlite3_value) callconv(.c) void {
            const raw = c.sqlite3_value_blob(args[0]);
            const length: usize = @intCast(c.sqlite3_value_bytes(args[0]));
            if (raw == null or length == 0 or length % 4 != 0 or length / 4 > vector.MAX_DIMENSION) {
                c.sqlite3_result_error(context, "InvalidVectorBlob", -1);
                return;
            }
            const allocator = std.heap.c_allocator;
            const values = allocator.alloc(f32, length / 4) catch {
                c.sqlite3_result_error_nomem(context);
                return;
            };
            defer allocator.free(values);
            vector.decodeNormalizedInto(@as([*]const u8, @ptrCast(raw))[0..length], values) catch {
                c.sqlite3_result_error(context, "InvalidStoredVector", -1);
                return;
            };
            const bytes = vector.quantize(allocator, values) catch {
                c.sqlite3_result_error_nomem(context);
                return;
            };
            defer allocator.free(bytes);
            c.sqlite3_result_blob(context, bytes.ptr, @intCast(bytes.len), ws_sqlite_transient());
        }
    };
    if (c.sqlite3_create_function_v2(handle, "ws_sq8_v1", 1, c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC | c.SQLITE_INNOCUOUS, null, Callback.quantize, null, null, null) != c.SQLITE_OK) return error.FunctionRegistrationFailed;
    const Names = struct {
        fn key(context: ?*c.sqlite3_context, _: c_int, args: [*c]?*c.sqlite3_value) callconv(.c) void {
            const ptr = c.sqlite3_value_text(args[0]) orelse {
                c.sqlite3_result_null(context);
                return;
            };
            const input = ptr[0..@intCast(c.sqlite3_value_bytes(args[0]))];
            const result = text_mod.normalize(if (c.sqlite3_user_data(context) != null) std.fs.path.stem(input) else input);
            c.sqlite3_result_text(context, result.buf[0..].ptr, @intCast(result.len), ws_sqlite_transient());
        }
    };
    const flags = c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC | c.SQLITE_INNOCUOUS;
    if (c.sqlite3_create_function_v2(handle, "ws_name_key", 1, flags, null, Names.key, null, null, null) != c.SQLITE_OK or
        c.sqlite3_create_function_v2(handle, "ws_stem_key", 1, flags, @ptrFromInt(1), Names.key, null, null, null) != c.SQLITE_OK) return error.FunctionRegistrationFailed;
}
pub const MODEL_KEY_CAPACITY = 128;
const WAVEFORM_CLAIM_LEASE_NS: i64 = 5 * std.time.ns_per_min;

var db_handle: ?*c.sqlite3 = null;
var db_path_owned: ?[:0]u8 = null;
var mutex: sync.Mutex = .{};
// Index connections never hold the metadata mutex during a manifest copy or
// publication. Close/reopen waits for those connections before replacing files.
var index_connection_mutex: sync.Mutex = .{};
// One reusable reader is enough for the latest-request worker and keeps the
// ceiling explicit: semantic scans are serialized, never multiplied by callers.
var semantic_reader_mutex: sync.Mutex = .{};
var semantic_reader: ?*c.sqlite3 = null;
var semantic_reader_serial: u64 = 0;
var connection_serial: u64 = 0;
var acoustic_group_rebuild_serial: u64 = 0;
var pending_query_steps: [2]u64 = .{ 0, 0 };

pub fn pendingQueryStepsForTests() [2]u64 {
    lock();
    defer mutex.unlock();
    return pending_query_steps;
}
pub fn catalogRevision() ![2]u64 {
    lock();
    defer mutex.unlock();
    return catalogRevisionLocked();
}

fn catalogRevisionLocked() ![2]u64 {
    return catalogRevisionOn(try handleLocked(), connection_serial);
}

fn catalogRevisionOn(handle: *c.sqlite3, serial: u64) ![2]u64 {
    const stmt = try prepareOn(handle, "SELECT generation FROM catalog_stats WHERE singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    return .{ serial, @intCast(c.sqlite3_column_int64(stmt, 0)) };
}

fn wallClockNs() i64 {
    var timestamp: c.struct_timespec = undefined;
    if (c.timespec_get(&timestamp, c.TIME_UTC) == c.TIME_UTC) {
        return @as(i64, @intCast(timestamp.tv_sec)) * std.time.ns_per_s + @as(i64, @intCast(timestamp.tv_nsec));
    }
    return @as(i64, @intCast(c.time(null))) * std.time.ns_per_s;
}

fn lock() void {
    mutex.lock();
}

pub const ScannedFile = struct {
    path: []const u8,
    relative_path: []const u8,
    name: []const u8,
    search_text: []const u8,
    duration_ms: i32,
    content_hash: i64,
    file_size: i64,
    mtime_ns: i64,
    identity_kind: file_identity.Kind = .unknown,
    hash_algorithm: file_identity.Algorithm = .unknown,
};

pub const Candidate = @import("types.zig").SearchCandidate;

pub const FileInfo = struct {
    id: i64,
    file_size: i64,
    mtime_ns: i64,
    content_hash: i64,
    has_waveform: bool,
    identity_kind: file_identity.Kind,
    hash_algorithm: file_identity.Algorithm,
};

pub const LegacyWaveformIdentity = struct {
    connection_serial: u64,
    file_id: i64,
    content_hash: i64,
    file_size: i64,
    mtime_ns: i64,
};

pub const WaveformWorkItem = struct {
    file_id: i32,
    path: []u8,
    content_hash: i64,
    file_size: i64,
    mtime_ns: i64,
    claim_token: u64,
    claim_until_ns: i64,

    pub fn deinit(self: *WaveformWorkItem, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const WaveformCacheStatus = struct {
    universal_count: i64 = 0,
    detailed_count: i64 = 0,
    pending_count: i64 = 0,
    failed_count: i64 = 0,
    universal_bytes: i64 = 0,
    detailed_bytes: i64 = 0,
    detailed_budget_bytes: i64 = 0,
};

pub const ExistingFile = struct {
    relative_path: []u8,
    file_size: i64,
    mtime_ns: i64,
    content_hash: i64,
};

pub const SemanticInfo = struct {
    connection_serial: u64,
    model_id: i64,
    dimension: usize,
    generation: i64,
};

pub const SemanticStatus = struct {
    active: bool = false,
    model_id: i64 = 0,
    dimension: i32 = 0,
    generation: i64 = 0,
    embedded_count: i64 = 0,
    pending_count: i64 = 0,
    failed_count: i64 = 0,
    model_key: [MODEL_KEY_CAPACITY]u8 = @splat(0),
};

pub const PendingSemanticFile = struct {
    id: i32,
    path: []u8,
    source_content_hash: i64,

    pub fn deinit(self: *PendingSemanticFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub fn freePendingSemanticFiles(allocator: std.mem.Allocator, files: []PendingSemanticFile) void {
    for (files) |*file| file.deinit(allocator);
    allocator.free(files);
}

pub const VectorSnapshot = struct {
    connection_serial: u64,
    model_id: i64,
    dimension: usize,
    generation: i64,
    file_ids: []i32,
    folder_ids: []i32,
    durations_ms: []i32,
    vectors: []f32,

    pub fn deinit(self: *VectorSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.file_ids);
        allocator.free(self.folder_ids);
        allocator.free(self.durations_ms);
        allocator.free(self.vectors);
        self.* = undefined;
    }
};

pub fn freeFolderManifest(allocator: std.mem.Allocator, manifest: []ExistingFile) void {
    for (manifest) |file| allocator.free(file.relative_path);
    allocator.free(manifest);
}

pub fn open(_: std.mem.Allocator, path: []const u8) !void {
    index_connection_mutex.lock();
    defer index_connection_mutex.unlock();
    lock();
    defer mutex.unlock();
    closeLocked();

    const path_z = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
    defer std.heap.c_allocator.free(path_z);

    var handle: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
    if (c.sqlite3_open_v2(path_z.ptr, &handle, flags, null) != c.SQLITE_OK) {
        if (handle) |h| _ = c.sqlite3_close_v2(h);
        return error.DbOpenFailed;
    }
    db_handle = handle;
    c.sqlite3_progress_handler(handle, 1000, queryProgress, null);
    db_path_owned = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
    connection_serial +%= 1;
    if (connection_serial == 0) connection_serial = 1;
    errdefer closeLocked();
    try registerVectorFunctions(handle.?);

    if (c.sqlite3_busy_timeout(handle, 5000) != c.SQLITE_OK) return error.PragmaFailed;
    // Existing WAL catalogs are never vacuumed on startup. compactTo creates
    // an explicit checked copy; new catalogs get blob-friendly pages directly.
    try execLocked("PRAGMA page_size=16384;");
    try applyPragmasLocked();
    try migrateLocked();
}

pub fn close() void {
    index_connection_mutex.lock();
    defer index_connection_mutex.unlock();
    lock();
    defer mutex.unlock();
    closeLocked();
}

fn closeSemanticReader() void {
    semantic_reader_mutex.lock();
    defer semantic_reader_mutex.unlock();
    if (semantic_reader) |reader| _ = c.sqlite3_close_v2(reader);
    semantic_reader = null;
    semantic_reader_serial = 0;
}

fn closeLocked() void {
    closeSemanticReader();
    if (db_handle) |h| {
        _ = c.sqlite3_close_v2(h);
        db_handle = null;
    }
    if (db_path_owned) |owned| {
        std.heap.c_allocator.free(owned);
        db_path_owned = null;
    }
}

fn handleLocked() !*c.sqlite3 {
    return db_handle orelse error.NotOpen;
}

fn execLocked(sql: [*:0]const u8) !void {
    return execOn(try handleLocked(), sql);
}

fn execOn(handle: *c.sqlite3, sql: [*:0]const u8) !void {
    if (c.sqlite3_exec(handle, sql, null, null, null) != c.SQLITE_OK) return error.ExecFailed;
}

fn applyPragmasLocked() !void {
    // journal_mode returns a row, so verify that WAL was actually selected.
    var stmt: ?*c.sqlite3_stmt = null;
    const h = try handleLocked();
    if (c.sqlite3_prepare_v2(h, "PRAGMA journal_mode=WAL", -1, &stmt, null) != c.SQLITE_OK) return error.PragmaFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.PragmaFailed;
    const mode = c.sqlite3_column_text(stmt, 0) orelse return error.PragmaFailed;
    const mode_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    if (!std.ascii.eqlIgnoreCase(mode[0..mode_len], "wal")) return error.PragmaFailed;

    try execLocked("PRAGMA synchronous=NORMAL;");
    try execLocked("PRAGMA foreign_keys=ON;");
    try execLocked("PRAGMA cache_size=-8192;");
    try execLocked("PRAGMA temp_store=MEMORY;");
    try execLocked("PRAGMA temp.cache_size=-2048;");
}

fn userVersionLocked() !i32 {
    var stmt: ?*c.sqlite3_stmt = null;
    const h = try handleLocked();
    if (c.sqlite3_prepare_v2(h, "PRAGMA user_version", -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    return c.sqlite3_column_int(stmt, 0);
}

fn migrateLocked() !void {
    const version = try userVersionLocked();
    if (version > SCHEMA_VERSION) return error.FutureSchemaVersion;
    if (version == SCHEMA_VERSION) return validateRestoreSchema(try handleLocked(), version, true);
    if (version == 13) {
        try execLocked("BEGIN IMMEDIATE;");
        errdefer execLocked("ROLLBACK;") catch {};
        try createStorageSchemaLocked();
        try execLocked("PRAGMA user_version=14;");
        try validateRestoreSchema(try handleLocked(), SCHEMA_VERSION, true);
        try execLocked("COMMIT;");
        return;
    }
    if (version == 12) {
        try execLocked("BEGIN IMMEDIATE;");
        errdefer execLocked("ROLLBACK;") catch {};
        try execLocked(refinement_schema.create);
        try createStorageSchemaLocked();
        try execLocked("PRAGMA user_version=14;");
        try validateRestoreSchema(try handleLocked(), SCHEMA_VERSION, true);
        try execLocked("COMMIT;");
        return;
    }
    if (version >= 10) {
        try execLocked("BEGIN IMMEDIATE;");
        errdefer execLocked("ROLLBACK;") catch {};
        // Development schema-v10 databases created before the resumable cursor
        // was added are upgraded in place; released older schemas still follow
        // the transactional migration below.
        execLocked("ALTER TABLE waveform_cache_state ADD COLUMN universal_cursor_file_id INTEGER NOT NULL DEFAULT 0;") catch {};
        execLocked("ALTER TABLE waveform_cache_state ADD COLUMN universal_scan_complete INTEGER NOT NULL DEFAULT 0 CHECK(universal_scan_complete IN (0,1));") catch {};
        execLocked("ALTER TABLE waveform_cache_state ADD COLUMN waveform_claimed_file_id INTEGER NOT NULL DEFAULT 0;") catch {};
        execLocked("ALTER TABLE waveform_cache_state ADD COLUMN waveform_claim_token INTEGER NOT NULL DEFAULT 0;") catch {};
        execLocked("ALTER TABLE waveform_cache_state ADD COLUMN waveform_claim_until_ns INTEGER NOT NULL DEFAULT 0;") catch {};
        execLocked("ALTER TABLE waveform_failures ADD COLUMN source_file_size INTEGER NOT NULL DEFAULT -1;") catch {};
        execLocked("ALTER TABLE waveform_failures ADD COLUMN source_mtime_ns INTEGER NOT NULL DEFAULT -1;") catch {};
        // Early development-v10 failures lacked complete identity. They cannot
        // safely block or be updated as current-source failures, so reclaim them.
        try execLocked("UPDATE waveform_cache_state SET universal_scan_complete=0 WHERE singleton=1 AND EXISTS(SELECT 1 FROM waveform_failures WHERE source_file_size<0 OR source_mtime_ns<0);");
        try execLocked("DELETE FROM waveform_failures WHERE source_file_size<0 OR source_mtime_ns<0;");
        execLocked("CREATE TRIGGER IF NOT EXISTS waveform_files_ai AFTER INSERT ON files BEGIN UPDATE waveform_cache_state SET universal_scan_complete=0 WHERE singleton=1; END;") catch {};
        execLocked("CREATE TRIGGER IF NOT EXISTS waveform_tier_rescan_au AFTER UPDATE OF file_size,mtime_ns,content_hash ON files BEGIN UPDATE waveform_cache_state SET universal_scan_complete=0 WHERE singleton=1; END;") catch {};
        execLocked("DROP TRIGGER IF EXISTS waveform_claim_source_changed;") catch {};
        execLocked("CREATE TRIGGER waveform_claim_source_changed AFTER UPDATE OF file_size,mtime_ns,content_hash ON files WHEN (old.file_size!=new.file_size OR old.mtime_ns!=new.mtime_ns OR old.content_hash!=new.content_hash) AND NOT ((old.file_size<0 OR old.mtime_ns<0) AND old.content_hash=new.content_hash) BEGIN UPDATE waveform_cache_state SET waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1 AND waveform_claimed_file_id=new.id; END;") catch {};
        execLocked("CREATE TRIGGER IF NOT EXISTS waveform_claim_file_ad AFTER DELETE ON files BEGIN UPDATE waveform_cache_state SET waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1 AND waveform_claimed_file_id=old.id; END;") catch {};
        if (version == 10) try execLocked(QUANTIZED_INDEX_SQL);
        try execLocked(optimization_schema.create);
        try execLocked(refinement_schema.create);
        try createStorageSchemaLocked();
        try execLocked("PRAGMA user_version=14;");
        try validateRestoreSchema(try handleLocked(), SCHEMA_VERSION, true);
        try execLocked("COMMIT;");
        return;
    }
    if (version != 0 and version != 3 and version != 4 and version != 5 and version != 6 and version != 7 and version != 8 and version != 9) return error.UnsupportedSchemaVersion;

    // Every supported path, including v3 directly to v5, commits as one unit.
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};

    if (version == 0) {
        try execLocked("CREATE TABLE files (" ++
            "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
            "folder_id INTEGER NOT NULL," ++
            "path TEXT NOT NULL UNIQUE," ++
            "relative_path TEXT NOT NULL DEFAULT ''," ++
            "name TEXT NOT NULL," ++
            "search_text TEXT NOT NULL DEFAULT ''," ++
            "duration_ms INTEGER NOT NULL DEFAULT 0," ++
            "content_hash INTEGER NOT NULL DEFAULT 0," ++
            "waveform BLOB," ++
            "file_size INTEGER NOT NULL DEFAULT -1," ++
            "mtime_ns INTEGER NOT NULL DEFAULT -1" ++
            ");");
        try createDerivedSchemaLocked();
    } else if (version == 3) {
        // v3's canonical rows remain in place. Drop any synchronization
        // triggers first: triggers attached to files survive dropping FTS tables.
        try execLocked("DROP TRIGGER IF EXISTS files_ai;");
        try execLocked("DROP TRIGGER IF EXISTS files_ad;");
        try execLocked("DROP TRIGGER IF EXISTS files_au;");
        try execLocked("DROP TABLE IF EXISTS files_fts;");
        try execLocked("DROP TABLE IF EXISTS files_trigram;");
        try execLocked("ALTER TABLE files ADD COLUMN file_size INTEGER NOT NULL DEFAULT -1;");
        try execLocked("ALTER TABLE files ADD COLUMN mtime_ns INTEGER NOT NULL DEFAULT -1;");
        try createDerivedSchemaLocked();
    }

    if (version != 5 and version != 6 and version != 7 and version != 8 and version != 9) try createSemanticSchemaLocked();
    if (version != 6 and version != 7 and version != 8 and version != 9) try createFailureSchemaLocked();
    if (version != 7 and version != 8 and version != 9) try createFingerprintSchemaLocked();
    if (version != 8 and version != 9) try createAcousticGroupSchemaLocked();
    if (version != 9) try createWaveformAnalysisSchemaLocked();
    try createWaveformTierSchemaLocked();
    try execLocked("DELETE FROM waveform_analyses;");
    try execLocked(QUANTIZED_INDEX_SQL);
    try execLocked(optimization_schema.create);
    try execLocked(refinement_schema.create);
    try createStorageSchemaLocked();
    try execLocked("PRAGMA user_version=14;");
    try execLocked("COMMIT;");
}

fn addStorageColumnLocked(comptime table: []const u8, comptime name: []const u8, sql: [*:0]const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(try handleLocked(), "SELECT " ++ name ++ " FROM " ++ table ++ " LIMIT 0", -1, &stmt, null);
    defer if (stmt) |value| {
        _ = c.sqlite3_finalize(value);
    };
    if (rc == c.SQLITE_OK) return;
    if (rc != c.SQLITE_ERROR) return error.PrepareFailed;
    try execLocked(sql);
}

fn createStorageSchemaLocked() !void {
    try addStorageColumnLocked("files", "identity_kind", "ALTER TABLE files ADD COLUMN identity_kind INTEGER NOT NULL DEFAULT 0 CHECK(identity_kind IN(0,1,2,3));");
    try addStorageColumnLocked("files", "hash_algorithm", "ALTER TABLE files ADD COLUMN hash_algorithm INTEGER NOT NULL DEFAULT 0 CHECK(hash_algorithm IN(0,1));");
    try addStorageColumnLocked("file_fingerprints", "storage_version", "ALTER TABLE file_fingerprints ADD COLUMN storage_version INTEGER NOT NULL DEFAULT 0 CHECK(storage_version IN(0,1));");
    try execLocked(storage_schema.create);
}

fn createDerivedSchemaLocked() !void {
    try execLocked("CREATE UNIQUE INDEX IF NOT EXISTS idx_files_folder_relative ON files(folder_id, relative_path);");
    try execLocked("CREATE INDEX IF NOT EXISTS idx_files_folder_name ON files(folder_id, name COLLATE NOCASE);");
    try execLocked("CREATE INDEX IF NOT EXISTS idx_files_name ON files(name COLLATE NOCASE);");
    try execLocked("CREATE INDEX IF NOT EXISTS idx_files_folder_duration ON files(folder_id, duration_ms);");
    try execLocked("CREATE INDEX IF NOT EXISTS idx_files_duration ON files(duration_ms);");
    try execLocked("CREATE INDEX IF NOT EXISTS idx_files_hash ON files(content_hash);");

    try execLocked("CREATE VIRTUAL TABLE files_fts USING fts5(" ++
        "search_text, name, content='files', content_rowid='id'," ++
        "tokenize='unicode61 remove_diacritics 1'" ++
        ");");
    try execLocked("CREATE VIRTUAL TABLE files_trigram USING fts5(" ++
        "search_text, content='files', content_rowid='id', tokenize='trigram'" ++
        ");");
    try execLocked("CREATE TRIGGER files_ai AFTER INSERT ON files BEGIN " ++
        "INSERT INTO files_fts(rowid,search_text,name) VALUES(new.id,new.search_text,new.name);" ++
        "INSERT INTO files_trigram(rowid,search_text) VALUES(new.id,new.search_text);" ++
        "END;");
    try execLocked("CREATE TRIGGER files_ad AFTER DELETE ON files BEGIN " ++
        "INSERT INTO files_fts(files_fts,rowid,search_text,name) VALUES('delete',old.id,old.search_text,old.name);" ++
        "INSERT INTO files_trigram(files_trigram,rowid,search_text) VALUES('delete',old.id,old.search_text);" ++
        "END;");
    try execLocked("CREATE TRIGGER files_au AFTER UPDATE OF search_text,name ON files BEGIN " ++
        "INSERT INTO files_fts(files_fts,rowid,search_text,name) VALUES('delete',old.id,old.search_text,old.name);" ++
        "INSERT INTO files_fts(rowid,search_text,name) VALUES(new.id,new.search_text,new.name);" ++
        "INSERT INTO files_trigram(files_trigram,rowid,search_text) VALUES('delete',old.id,old.search_text);" ++
        "INSERT INTO files_trigram(rowid,search_text) VALUES(new.id,new.search_text);" ++
        "END;");
    try execLocked("INSERT INTO files_fts(files_fts) VALUES('rebuild');");
    try execLocked("INSERT INTO files_trigram(files_trigram) VALUES('rebuild');");
}

fn createFingerprintSchemaLocked() !void {
    try execLocked("CREATE TABLE fingerprint_algorithms (" ++
        "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
        "algorithm_key TEXT NOT NULL UNIQUE" ++
        ");");
    try execLocked("CREATE TABLE file_fingerprints (" ++
        "algorithm_id INTEGER NOT NULL REFERENCES fingerprint_algorithms(id) ON DELETE CASCADE," ++
        "file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE," ++
        "source_content_hash INTEGER NOT NULL," ++
        "token_count INTEGER NOT NULL CHECK(token_count>=0)," ++
        "landmarks BLOB NOT NULL," ++
        "PRIMARY KEY(algorithm_id,file_id)" ++
        ") WITHOUT ROWID;");
    try execLocked("CREATE TABLE fingerprint_postings (" ++
        "algorithm_id INTEGER NOT NULL," ++
        "token_hash INTEGER NOT NULL," ++
        "file_id INTEGER NOT NULL," ++
        "PRIMARY KEY(algorithm_id,token_hash,file_id)," ++
        "FOREIGN KEY(algorithm_id,file_id) REFERENCES file_fingerprints(algorithm_id,file_id) ON DELETE CASCADE" ++
        ") WITHOUT ROWID;");
    try execLocked("CREATE INDEX idx_fingerprint_postings_file ON fingerprint_postings(algorithm_id,file_id);");
    try execLocked("CREATE TABLE fingerprint_failures (" ++
        "algorithm_id INTEGER NOT NULL REFERENCES fingerprint_algorithms(id) ON DELETE CASCADE," ++
        "file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE," ++
        "source_content_hash INTEGER NOT NULL," ++
        "error_code TEXT NOT NULL," ++
        "detail TEXT NOT NULL," ++
        "PRIMARY KEY(algorithm_id,file_id)" ++
        ") WITHOUT ROWID;");
}

fn createAcousticGroupSchemaLocked() !void {
    try execLocked("CREATE TABLE acoustic_edges (" ++
        "algorithm_id INTEGER NOT NULL," ++
        "file_id_a INTEGER NOT NULL," ++
        "file_id_b INTEGER NOT NULL," ++
        "score_ppm INTEGER NOT NULL," ++
        "aligned INTEGER NOT NULL," ++
        "PRIMARY KEY(algorithm_id,file_id_a,file_id_b)," ++
        "CHECK(file_id_a<file_id_b)," ++
        "FOREIGN KEY(algorithm_id,file_id_a) REFERENCES file_fingerprints(algorithm_id,file_id) ON DELETE CASCADE," ++
        "FOREIGN KEY(algorithm_id,file_id_b) REFERENCES file_fingerprints(algorithm_id,file_id) ON DELETE CASCADE" ++
        ") WITHOUT ROWID;");
    try execLocked("CREATE INDEX idx_acoustic_edges_b ON acoustic_edges(algorithm_id,file_id_b,file_id_a);");
    try execLocked("CREATE TABLE acoustic_groups (" ++
        "algorithm_id INTEGER NOT NULL," ++
        "file_id INTEGER NOT NULL," ++
        "group_id INTEGER NOT NULL," ++
        "member_count INTEGER NOT NULL," ++
        "confidence_ppm INTEGER NOT NULL," ++
        "PRIMARY KEY(algorithm_id,file_id)," ++
        "FOREIGN KEY(algorithm_id,file_id) REFERENCES file_fingerprints(algorithm_id,file_id) ON DELETE CASCADE" ++
        ") WITHOUT ROWID;");
    try execLocked("CREATE INDEX idx_acoustic_groups_group ON acoustic_groups(algorithm_id,group_id,file_id);");
    try execLocked("CREATE TABLE acoustic_group_state (algorithm_id INTEGER PRIMARY KEY REFERENCES fingerprint_algorithms(id) ON DELETE CASCADE,dirty INTEGER NOT NULL CHECK(dirty IN (0,1))) WITHOUT ROWID;");
    try execLocked("INSERT INTO acoustic_group_state(algorithm_id,dirty) SELECT id,0 FROM fingerprint_algorithms;");
    try execLocked("CREATE TRIGGER acoustic_edges_ai AFTER INSERT ON acoustic_edges BEGIN INSERT INTO acoustic_group_state(algorithm_id,dirty) VALUES(new.algorithm_id,1) ON CONFLICT(algorithm_id) DO UPDATE SET dirty=1; END;");
    try execLocked("CREATE TRIGGER acoustic_edges_ad AFTER DELETE ON acoustic_edges BEGIN INSERT INTO acoustic_group_state(algorithm_id,dirty) VALUES(old.algorithm_id,1) ON CONFLICT(algorithm_id) DO UPDATE SET dirty=1; END;");
    try execLocked("INSERT INTO acoustic_groups(algorithm_id,file_id,group_id,member_count,confidence_ppm) SELECT algorithm_id,file_id,file_id,1,0 FROM file_fingerprints;");
}

fn createWaveformAnalysisSchemaLocked() !void {
    try execLocked("CREATE TABLE waveform_analyses (" ++
        "file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE," ++
        "blob BLOB NOT NULL" ++
        ") WITHOUT ROWID;");
    try execLocked("CREATE TRIGGER waveform_analysis_source_changed AFTER UPDATE OF file_size,mtime_ns,content_hash ON files " ++
        "WHEN old.file_size!=new.file_size OR old.mtime_ns!=new.mtime_ns OR old.content_hash!=new.content_hash BEGIN " ++
        "DELETE FROM waveform_analyses WHERE file_id=new.id; END;");
}

fn createWaveformTierSchemaLocked() !void {
    try execLocked("DROP TRIGGER IF EXISTS waveform_analysis_source_changed;");
    try execLocked("CREATE TABLE waveform_tiers (" ++
        "file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE," ++
        "source_content_hash INTEGER NOT NULL," ++
        "source_file_size INTEGER NOT NULL," ++
        "source_mtime_ns INTEGER NOT NULL," ++
        "codec_version INTEGER NOT NULL," ++
        "universal_blob BLOB NOT NULL," ++
        "universal_bytes INTEGER NOT NULL CHECK(universal_bytes>0 AND universal_bytes=length(universal_blob))," ++
        "detailed_blob BLOB," ++
        "detailed_bytes INTEGER NOT NULL DEFAULT 0 CHECK((detailed_blob IS NULL AND detailed_bytes=0) OR (detailed_blob IS NOT NULL AND detailed_bytes=length(detailed_blob)))," ++
        "detailed_access_ns INTEGER NOT NULL DEFAULT 0" ++
        ") WITHOUT ROWID;");
    try execLocked("CREATE INDEX idx_waveform_tiers_detail_lru ON waveform_tiers(detailed_access_ns,file_id) WHERE detailed_blob IS NOT NULL;");
    try execLocked("CREATE TABLE waveform_cache_state (" ++
        "singleton INTEGER PRIMARY KEY CHECK(singleton=1)," ++
        "detailed_budget_bytes INTEGER NOT NULL CHECK(detailed_budget_bytes>=0 AND detailed_budget_bytes<=536870912)," ++
        "universal_cursor_file_id INTEGER NOT NULL DEFAULT 0," ++
        "universal_scan_complete INTEGER NOT NULL DEFAULT 0 CHECK(universal_scan_complete IN (0,1))," ++
        "waveform_claimed_file_id INTEGER NOT NULL DEFAULT 0," ++
        "waveform_claim_token INTEGER NOT NULL DEFAULT 0," ++
        "waveform_claim_until_ns INTEGER NOT NULL DEFAULT 0" ++
        ") WITHOUT ROWID;");
    try execLocked("INSERT INTO waveform_cache_state(singleton,detailed_budget_bytes,universal_cursor_file_id,universal_scan_complete,waveform_claimed_file_id,waveform_claim_token,waveform_claim_until_ns) VALUES(1,268435456,0,0,0,0,0);");
    try execLocked("CREATE TABLE waveform_failures (" ++
        "file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE," ++
        "source_content_hash INTEGER NOT NULL," ++
        "source_file_size INTEGER NOT NULL," ++
        "source_mtime_ns INTEGER NOT NULL," ++
        "permanent INTEGER NOT NULL CHECK(permanent IN (0,1))," ++
        "attempt_count INTEGER NOT NULL DEFAULT 1 CHECK(attempt_count>0)," ++
        "retry_after_ns INTEGER NOT NULL DEFAULT 0," ++
        "detail TEXT NOT NULL DEFAULT ''" ++
        ") WITHOUT ROWID;");
    try execLocked("CREATE TRIGGER waveform_analysis_source_changed AFTER UPDATE OF file_size,mtime_ns,content_hash ON files " ++
        "WHEN old.file_size!=new.file_size OR old.mtime_ns!=new.mtime_ns OR old.content_hash!=new.content_hash BEGIN " ++
        "DELETE FROM waveform_analyses WHERE file_id=new.id; " ++
        "DELETE FROM waveform_tiers WHERE file_id=new.id; " ++
        "DELETE FROM waveform_failures WHERE file_id=new.id; " ++
        "UPDATE waveform_cache_state SET universal_scan_complete=0 WHERE singleton=1; END;");
    try execLocked("CREATE TRIGGER waveform_files_ai AFTER INSERT ON files BEGIN UPDATE waveform_cache_state SET universal_scan_complete=0 WHERE singleton=1; END;");
    try execLocked("CREATE TRIGGER waveform_tier_rescan_au AFTER UPDATE OF file_size,mtime_ns,content_hash ON files BEGIN UPDATE waveform_cache_state SET universal_scan_complete=0 WHERE singleton=1; END;");
    try execLocked("CREATE TRIGGER waveform_claim_source_changed AFTER UPDATE OF file_size,mtime_ns,content_hash ON files WHEN (old.file_size!=new.file_size OR old.mtime_ns!=new.mtime_ns OR old.content_hash!=new.content_hash) AND NOT ((old.file_size<0 OR old.mtime_ns<0) AND old.content_hash=new.content_hash) BEGIN UPDATE waveform_cache_state SET waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1 AND waveform_claimed_file_id=new.id; END;");
    try execLocked("CREATE TRIGGER waveform_claim_file_ad AFTER DELETE ON files BEGIN UPDATE waveform_cache_state SET waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1 AND waveform_claimed_file_id=old.id; END;");
}

fn createFailureSchemaLocked() !void {
    try execLocked("CREATE TABLE embedding_failures (" ++
        "model_id INTEGER NOT NULL REFERENCES embedding_models(id) ON DELETE CASCADE," ++
        "file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE," ++
        "source_content_hash INTEGER NOT NULL," ++
        "error_code TEXT NOT NULL," ++
        "detail TEXT NOT NULL," ++
        "PRIMARY KEY(model_id,file_id)" ++
        ") WITHOUT ROWID;");
    try execLocked("CREATE INDEX idx_embedding_failures_file ON embedding_failures(file_id);");
}

fn createSemanticSchemaLocked() !void {
    try execLocked("CREATE TABLE embedding_models (" ++
        "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
        "model_key TEXT NOT NULL UNIQUE," ++
        "dimension INTEGER NOT NULL CHECK(dimension>0 AND dimension<=65536)," ++
        "vector_format TEXT NOT NULL" ++
        ");");
    try execLocked("CREATE TABLE file_embeddings (" ++
        "model_id INTEGER NOT NULL REFERENCES embedding_models(id) ON DELETE CASCADE," ++
        "file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE," ++
        "source_content_hash INTEGER NOT NULL," ++
        "vector BLOB NOT NULL," ++
        "PRIMARY KEY(model_id,file_id)" ++
        ") WITHOUT ROWID;");
    try execLocked("CREATE INDEX idx_file_embeddings_file ON file_embeddings(file_id);");
    try execLocked("CREATE TABLE semantic_state (" ++
        "singleton INTEGER PRIMARY KEY CHECK(singleton=1)," ++
        "active_model_id INTEGER REFERENCES embedding_models(id) ON DELETE SET NULL," ++
        "generation INTEGER NOT NULL DEFAULT 0" ++
        ");");
    try execLocked("INSERT INTO semantic_state(singleton,active_model_id,generation) VALUES(1,NULL,0);");
    try execLocked("CREATE TRIGGER file_embeddings_ai AFTER INSERT ON file_embeddings BEGIN " ++
        "UPDATE semantic_state SET generation=generation+1 WHERE singleton=1; END;");
    try execLocked("CREATE TRIGGER file_embeddings_ad AFTER DELETE ON file_embeddings BEGIN " ++
        "UPDATE semantic_state SET generation=generation+1 WHERE singleton=1; END;");
    try execLocked("CREATE TRIGGER file_embeddings_au AFTER UPDATE ON file_embeddings BEGIN " ++
        "UPDATE semantic_state SET generation=generation+1 WHERE singleton=1; END;");
    try execLocked("CREATE TRIGGER embedding_models_ad AFTER DELETE ON embedding_models BEGIN " ++
        "UPDATE semantic_state SET generation=generation+1 WHERE singleton=1; END;");
}

fn prepareLocked(sql: [*:0]const u8) !*c.sqlite3_stmt {
    return prepareOn(try handleLocked(), sql);
}

fn prepareOn(handle: *c.sqlite3, sql: [*:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
        try query_cancel.check();
        return error.PrepareFailed;
    }
    return stmt orelse error.PrepareFailed;
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.BindFailed;
}

fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: i32) !void {
    if (c.sqlite3_bind_int(stmt, index, value) != c.SQLITE_OK) return error.BindFailed;
}

fn bindOptionalInt(stmt: *c.sqlite3_stmt, index: c_int, value: ?i32) !void {
    if (value) |number| return bindInt(stmt, index, number);
    if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) return error.BindFailed;
}

fn bindInt64(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return error.BindFailed;
}

// Caller holds index_connection_mutex, so the captured catalog cannot be closed
// or replaced until this short-lived connection has finalized its statements.
const IndexConnection = struct {
    handle: *c.sqlite3,
    serial: u64,

    fn init() !IndexConnection {
        const identity = blk: {
            lock();
            defer mutex.unlock();
            _ = try handleLocked();
            break :blk .{ .path = try std.heap.c_allocator.dupeSentinel(u8, db_path_owned.?, 0), .serial = connection_serial };
        };
        defer std.heap.c_allocator.free(identity.path);
        var opened: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(identity.path.ptr, &opened, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) {
            if (opened) |h| _ = c.sqlite3_close_v2(h);
            return error.DbOpenFailed;
        }
        const h = opened orelse return error.DbOpenFailed;
        errdefer _ = c.sqlite3_close_v2(h);
        try registerVectorFunctions(h);
        if (c.sqlite3_busy_timeout(h, 5000) != c.SQLITE_OK) return error.PragmaFailed;
        try execOn(h, "PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA cache_size=-8192; PRAGMA temp_store=FILE; PRAGMA temp.cache_size=-2048;");
        return .{ .handle = h, .serial = identity.serial };
    }

    fn deinit(self: IndexConnection) void {
        _ = c.sqlite3_close_v2(self.handle);
    }
};

// Discardable disk-backed manifests. SQLite deletes its anonymous temp DB on
// close, including cancellation/error paths. Only publication touches live files.
pub const IndexStage = struct {
    handle: *c.sqlite3,
    folder_id: i32,
    revision: [2]u64,
    lookup: *c.sqlite3_stmt,
    insert: *c.sqlite3_stmt,
    retain: *c.sqlite3_stmt,
    observed: *c.sqlite3_stmt,
    old_count: usize,
    read: ?*c.sqlite3_stmt = null,
    root: ?[]const u8 = null,

    pub fn init(folder_id: i32, cancel: ?*const std.atomic.Value(bool)) !IndexStage {
        index_connection_mutex.lock();
        defer index_connection_mutex.unlock();
        const live = try IndexConnection.init();
        defer live.deinit();
        var opened: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2("", &opened, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) {
            if (opened) |h| {
                _ = c.sqlite3_close_v2(h);
            }
            return error.StageOpenFailed;
        }
        const h = opened.?;
        errdefer _ = c.sqlite3_close_v2(h);
        // ponytail: disposable staging needs no crash recovery; the live index
        // still publishes atomically with its normal WAL transaction.
        if (c.sqlite3_exec(h, "PRAGMA journal_mode=OFF; PRAGMA cache_size=-2048; PRAGMA temp_store=FILE; CREATE TABLE old_files(relative_path TEXT PRIMARY KEY,file_size INTEGER,mtime_ns INTEGER,content_hash INTEGER,file_id INTEGER NOT NULL,identity_kind INTEGER,hash_algorithm INTEGER,seen INTEGER NOT NULL DEFAULT 0 CHECK(seen IN (0,1,2))) WITHOUT ROWID; CREATE TABLE scanned(relative_path TEXT PRIMARY KEY,path TEXT,name TEXT,search_text TEXT,duration_ms INTEGER,content_hash INTEGER,file_size INTEGER,mtime_ns INTEGER,identity_kind INTEGER,hash_algorithm INTEGER) WITHOUT ROWID; BEGIN;", null, null, null) != c.SQLITE_OK) return error.StageOpenFailed;
        const copy = try prepareOn(h, "INSERT INTO old_files(relative_path,file_size,mtime_ns,content_hash,file_id,identity_kind,hash_algorithm) VALUES(?,?,?,?,?,?,?)");
        defer _ = c.sqlite3_finalize(copy);
        try execOn(live.handle, "BEGIN DEFERRED;");
        errdefer execOn(live.handle, "ROLLBACK;") catch {};
        const revision = try catalogRevisionOn(live.handle, live.serial);
        const old = try prepareOn(live.handle, "SELECT relative_path,file_size,mtime_ns,content_hash,id,identity_kind,hash_algorithm FROM files WHERE folder_id=? ORDER BY relative_path");
        defer _ = c.sqlite3_finalize(old);
        try bindInt(old, 1, folder_id);
        var old_count: usize = 0;
        while (true) {
            if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
            const rc = c.sqlite3_step(old);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            _ = c.sqlite3_reset(copy);
            try bindText(copy, 1, columnSlice(old, 0));
            for (1..7) |i| try bindInt64(copy, @intCast(i + 1), c.sqlite3_column_int64(old, @intCast(i)));
            if (c.sqlite3_step(copy) != c.SQLITE_DONE) return error.StageWriteFailed;
            old_count += 1;
        }
        try execOn(live.handle, "COMMIT;");
        const lookup = try prepareOn(h, "SELECT file_size,mtime_ns,content_hash FROM old_files WHERE relative_path=?");
        errdefer _ = c.sqlite3_finalize(lookup);
        const insert = try prepareOn(h, "INSERT INTO scanned VALUES(?,?,?,?,?,?,?,?,?,?)");
        errdefer _ = c.sqlite3_finalize(insert);
        // 0 = absent from walk, 1 = retained unchanged, 2 = full staged record.
        // A repeated observation violates CHECK rather than accepting ambiguity.
        const retain = try prepareOn(h, "UPDATE old_files SET seen=CASE WHEN seen=0 THEN 1 ELSE 3 END WHERE relative_path=?1 AND (?2<0 OR (file_size>=0 AND file_size=?2 AND mtime_ns=?3 AND identity_kind!=0 AND hash_algorithm=1))");
        errdefer _ = c.sqlite3_finalize(retain);
        const observed = try prepareOn(h, "UPDATE old_files SET seen=CASE WHEN seen=0 THEN 2 ELSE 3 END WHERE relative_path=?");
        return .{ .handle = h, .folder_id = folder_id, .revision = revision, .lookup = lookup, .insert = insert, .retain = retain, .observed = observed, .old_count = old_count };
    }

    pub fn deinit(self: *IndexStage) void {
        if (self.read) |stmt| {
            _ = c.sqlite3_finalize(stmt);
        }
        _ = c.sqlite3_finalize(self.lookup);
        _ = c.sqlite3_finalize(self.insert);
        _ = c.sqlite3_finalize(self.retain);
        _ = c.sqlite3_finalize(self.observed);
        _ = c.sqlite3_close_v2(self.handle);
    }

    pub fn previous(self: *IndexStage, relative_path: []const u8) !?struct { file_size: i64, mtime_ns: i64, content_hash: i64 } {
        _ = c.sqlite3_reset(self.lookup);
        try bindText(self.lookup, 1, relative_path);
        const rc = c.sqlite3_step(self.lookup);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StageReadFailed;
        return .{ .file_size = c.sqlite3_column_int64(self.lookup, 0), .mtime_ns = c.sqlite3_column_int64(self.lookup, 1), .content_hash = c.sqlite3_column_int64(self.lookup, 2) };
    }

    pub fn append(self: *IndexStage, file: ScannedFile) !void {
        _ = c.sqlite3_reset(self.insert);
        try bindText(self.insert, 1, file.relative_path);
        try bindText(self.insert, 2, file.path);
        try bindText(self.insert, 3, file.name);
        try bindText(self.insert, 4, file.search_text);
        try bindInt(self.insert, 5, file.duration_ms);
        try bindInt64(self.insert, 6, file.content_hash);
        try bindInt64(self.insert, 7, file.file_size);
        try bindInt64(self.insert, 8, file.mtime_ns);
        try bindInt(self.insert, 9, @intCast(@backingInt(file.identity_kind)));
        try bindInt(self.insert, 10, @intCast(@backingInt(file.hash_algorithm)));
        if (c.sqlite3_step(self.insert) != c.SQLITE_DONE) return error.StageWriteFailed;
        if (self.old_count == 0) return;
        _ = c.sqlite3_reset(self.observed);
        try bindText(self.observed, 1, file.relative_path);
        if (c.sqlite3_step(self.observed) != c.SQLITE_DONE) return error.DuplicateRelativePath;
    }

    /// Retain an already validated size/mtime identity without copying its paths
    /// or derived metadata. The scan root is supplied once at publication.
    pub fn retainUnchanged(self: *IndexStage, relative_path: []const u8) !void {
        if (!try self.retainIdentity(relative_path, -1, 0)) return error.StageReadFailed;
    }

    /// Fuse the identity lookup and observation for the common unchanged case.
    pub fn retainIfUnchanged(self: *IndexStage, relative_path: []const u8, file_size: i64, mtime_ns: i64) !bool {
        if (self.old_count == 0) return false;
        return self.retainIdentity(relative_path, file_size, mtime_ns);
    }

    fn retainIdentity(self: *IndexStage, relative_path: []const u8, file_size: i64, mtime_ns: i64) !bool {
        _ = c.sqlite3_reset(self.retain);
        try bindText(self.retain, 1, relative_path);
        try bindInt64(self.retain, 2, file_size);
        try bindInt64(self.retain, 3, mtime_ns);
        const rc = c.sqlite3_step(self.retain);
        if (rc != c.SQLITE_DONE) return error.DuplicateRelativePath;
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn publish(self: *IndexStage, cancel: ?*const std.atomic.Value(bool)) !void {
        return self.publishAtRoot(null, cancel);
    }

    pub fn publishAtRoot(self: *IndexStage, root: ?[]const u8, cancel: ?*const std.atomic.Value(bool)) !void {
        self.root = root; // Borrowed only for this synchronous publication call.
        defer self.root = null;
        _ = c.sqlite3_reset(self.lookup);
        _ = c.sqlite3_reset(self.insert);
        _ = c.sqlite3_reset(self.retain);
        _ = c.sqlite3_reset(self.observed);
        if (c.sqlite3_exec(self.handle, "COMMIT;", null, null, null) != c.SQLITE_OK) return error.StageWriteFailed;
        self.read = try prepareOn(self.handle, "SELECT path,relative_path,name,search_text,duration_ms,content_hash,file_size,mtime_ns,identity_kind,hash_algorithm FROM scanned ORDER BY relative_path");
        return applyFolderIndexRows(self.folder_id, &.{}, self, cancel);
    }

    fn publishRetained(self: *IndexStage, live: *c.sqlite3, cancel: ?*const std.atomic.Value(bool)) !void {
        const retained = try prepareOn(self.handle, "SELECT file_id,relative_path FROM old_files WHERE seen=1 ORDER BY relative_path");
        defer _ = c.sqlite3_finalize(retained);
        const update = try prepareOn(live, "UPDATE files SET path=?1||?2 WHERE id=?3 AND path!=?1||?2");
        defer _ = c.sqlite3_finalize(update);
        const prefix = if (self.root) |root|
            try std.fmt.allocPrint(std.heap.c_allocator, "{s}{s}", .{ root, if (std.mem.endsWith(u8, root, "/")) "" else "/" })
        else
            null;
        defer if (prefix) |p| std.heap.c_allocator.free(p);
        if (prefix) |p| try bindText(update, 1, p);
        while (true) {
            if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
            const rc = c.sqlite3_step(retained);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StageReadFailed;
            if (prefix == null) return error.MissingScanRoot;
            _ = c.sqlite3_reset(update);
            try bindText(update, 2, columnSlice(retained, 1));
            try bindInt64(update, 3, c.sqlite3_column_int64(retained, 0));
            if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.UpdateFailed;
        }
    }

    fn removeMissing(self: *IndexStage, live: *c.sqlite3, cancel: ?*const std.atomic.Value(bool)) !void {
        const missing = try prepareOn(self.handle, "SELECT file_id FROM old_files WHERE seen=0 ORDER BY relative_path");
        defer _ = c.sqlite3_finalize(missing);
        const remove = try prepareOn(live, "DELETE FROM files WHERE id=?");
        defer _ = c.sqlite3_finalize(remove);
        while (true) {
            if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
            const rc = c.sqlite3_step(missing);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StageReadFailed;
            _ = c.sqlite3_reset(remove);
            try bindInt64(remove, 1, c.sqlite3_column_int64(missing, 0));
            if (c.sqlite3_step(remove) != c.SQLITE_DONE) return error.DeleteFailed;
        }
    }

    fn next(self: *IndexStage) !?ScannedFile {
        const stmt = self.read.?;
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StageReadFailed;
        return .{ .path = columnSlice(stmt, 0), .relative_path = columnSlice(stmt, 1), .name = columnSlice(stmt, 2), .search_text = columnSlice(stmt, 3), .duration_ms = c.sqlite3_column_int(stmt, 4), .content_hash = c.sqlite3_column_int64(stmt, 5), .file_size = c.sqlite3_column_int64(stmt, 6), .mtime_ns = c.sqlite3_column_int64(stmt, 7), .identity_kind = std.enums.fromInt(file_identity.Kind, c.sqlite3_column_int(stmt, 8)) orelse return error.InvalidStoredIdentity, .hash_algorithm = std.enums.fromInt(file_identity.Algorithm, c.sqlite3_column_int(stmt, 9)) orelse return error.InvalidStoredIdentity };
    }
};

fn columnSlice(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return "";
    return ptr[0..@intCast(c.sqlite3_column_bytes(stmt, column))];
}

pub fn applyFolderIndex(folder_id: i32, files: []const ScannedFile) !void {
    return applyFolderIndexCancellable(folder_id, files, null);
}

pub fn applyFolderIndexCancellable(folder_id: i32, files: []const ScannedFile, cancel: ?*const std.atomic.Value(bool)) !void {
    return applyFolderIndexRows(folder_id, files, null, cancel);
}

fn applyFolderIndexRows(folder_id: i32, files: []const ScannedFile, stage: ?*IndexStage, cancel: ?*const std.atomic.Value(bool)) !void {
    index_connection_mutex.lock();
    defer index_connection_mutex.unlock();
    const live = try IndexConnection.init();
    defer live.deinit();
    const h = live.handle;
    // WAL readers keep using the last committed catalog throughout publication.
    // ponytail: global revision rejects competing scans instead of losing updates;
    // use per-folder revisions if parallel folder publication becomes important.
    try execOn(h, "BEGIN IMMEDIATE;");
    errdefer execOn(h, "ROLLBACK;") catch {};
    if (stage) |s| if (!std.meta.eql(s.revision, try catalogRevisionOn(h, live.serial))) return error.IndexSnapshotChanged;
    const seen = if (stage == null) blk: {
        try execOn(h, "CREATE TEMP TABLE ws_seen(relative_path TEXT PRIMARY KEY) WITHOUT ROWID;");
        break :blk try prepareOn(h, "INSERT INTO ws_seen(relative_path) VALUES(?)");
    } else null;
    defer if (seen) |stmt| {
        _ = c.sqlite3_finalize(stmt);
    };
    if (stage) |s| try s.publishRetained(h, cancel);
    const lookup = try prepareOn(h, "SELECT id,file_size,mtime_ns,path,content_hash FROM files WHERE folder_id=? AND relative_path=?");
    defer _ = c.sqlite3_finalize(lookup);
    const insert = try prepareOn(h, "INSERT INTO files(folder_id,path,relative_path,name,search_text,duration_ms,content_hash,file_size,mtime_ns) VALUES(?,?,?,?,?,?,?,?,?)");
    defer _ = c.sqlite3_finalize(insert);
    const update_changed = try prepareOn(h, "UPDATE files SET path=?,name=?,search_text=?,duration_ms=?,content_hash=?,file_size=?,mtime_ns=?,waveform=NULL WHERE id=?");
    defer _ = c.sqlite3_finalize(update_changed);
    const update_preserving_waveform = try prepareOn(h, "UPDATE files SET path=?,name=?,search_text=?,duration_ms=?,content_hash=?,file_size=?,mtime_ns=? WHERE id=?");
    defer _ = c.sqlite3_finalize(update_preserving_waveform);
    const update_path = try prepareOn(h, "UPDATE files SET path=? WHERE id=?");
    defer _ = c.sqlite3_finalize(update_path);
    const update_identity = try prepareOn(h, "UPDATE files SET identity_kind=?1,hash_algorithm=?2 WHERE id=?3 AND (identity_kind!=?1 OR hash_algorithm!=?2)");
    defer _ = c.sqlite3_finalize(update_identity);
    const invalidate_embeddings = try prepareOn(h, "DELETE FROM file_embeddings WHERE file_id=?");
    defer _ = c.sqlite3_finalize(invalidate_embeddings);
    const invalidate_failures = try prepareOn(h, "DELETE FROM embedding_failures WHERE file_id=?");
    defer _ = c.sqlite3_finalize(invalidate_failures);
    const invalidate_fingerprints = try prepareOn(h, "DELETE FROM file_fingerprints WHERE file_id=?");
    defer _ = c.sqlite3_finalize(invalidate_fingerprints);
    const invalidate_fingerprint_failures = try prepareOn(h, "DELETE FROM fingerprint_failures WHERE file_id=?");
    defer _ = c.sqlite3_finalize(invalidate_fingerprint_failures);

    var file_index: usize = 0;
    while (true) {
        const file = if (stage) |s| (try s.next()) orelse break else if (file_index < files.len) files[file_index] else break;
        file_index += 1;
        if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
        if (seen) |stmt| {
            _ = c.sqlite3_reset(stmt);
            try bindText(stmt, 1, file.relative_path);
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DuplicateRelativePath;
        }

        _ = c.sqlite3_reset(lookup);
        _ = c.sqlite3_clear_bindings(lookup);
        try bindInt(lookup, 1, folder_id);
        try bindText(lookup, 2, file.relative_path);
        const lookup_rc = c.sqlite3_step(lookup);
        var published_id: i64 = 0;
        if (lookup_rc == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int64(lookup, 0);
            published_id = id;
            const old_size = c.sqlite3_column_int64(lookup, 1);
            const old_mtime = c.sqlite3_column_int64(lookup, 2);
            const old_hash = c.sqlite3_column_int64(lookup, 4);
            const hash_matches = file.content_hash == 0 or old_hash == 0 or old_hash == file.content_hash;
            const unchanged = old_size == file.file_size and old_mtime == file.mtime_ns and hash_matches;
            const legacy_unchanged = old_size < 0 and old_hash != 0 and old_hash == file.content_hash;
            const old_path_ptr = c.sqlite3_column_text(lookup, 3);
            const old_path = if (old_path_ptr) |p| p[0..@intCast(c.sqlite3_column_bytes(lookup, 3))] else "";

            const target = if (unchanged and !std.mem.eql(u8, old_path, file.path))
                update_path
            else if (legacy_unchanged)
                update_preserving_waveform
            else if (!unchanged)
                update_changed
            else
                null;
            if (target) |stmt| {
                _ = c.sqlite3_reset(stmt);
                _ = c.sqlite3_clear_bindings(stmt);
                try bindText(stmt, 1, file.path);
                if (stmt == update_changed or stmt == update_preserving_waveform) {
                    try bindText(stmt, 2, file.name);
                    try bindText(stmt, 3, file.search_text);
                    try bindInt(stmt, 4, file.duration_ms);
                    try bindInt64(stmt, 5, file.content_hash);
                    try bindInt64(stmt, 6, file.file_size);
                    try bindInt64(stmt, 7, file.mtime_ns);
                    try bindInt64(stmt, 8, id);
                } else try bindInt64(stmt, 2, id);
                if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
                if (stmt == update_changed) {
                    _ = c.sqlite3_reset(invalidate_embeddings);
                    _ = c.sqlite3_clear_bindings(invalidate_embeddings);
                    try bindInt64(invalidate_embeddings, 1, id);
                    if (c.sqlite3_step(invalidate_embeddings) != c.SQLITE_DONE) return error.DeleteFailed;
                    _ = c.sqlite3_reset(invalidate_failures);
                    _ = c.sqlite3_clear_bindings(invalidate_failures);
                    try bindInt64(invalidate_failures, 1, id);
                    if (c.sqlite3_step(invalidate_failures) != c.SQLITE_DONE) return error.DeleteFailed;
                    _ = c.sqlite3_reset(invalidate_fingerprints);
                    _ = c.sqlite3_clear_bindings(invalidate_fingerprints);
                    try bindInt64(invalidate_fingerprints, 1, id);
                    if (c.sqlite3_step(invalidate_fingerprints) != c.SQLITE_DONE) return error.DeleteFailed;
                    _ = c.sqlite3_reset(invalidate_fingerprint_failures);
                    _ = c.sqlite3_clear_bindings(invalidate_fingerprint_failures);
                    try bindInt64(invalidate_fingerprint_failures, 1, id);
                    if (c.sqlite3_step(invalidate_fingerprint_failures) != c.SQLITE_DONE) return error.DeleteFailed;
                }
            }
        } else if (lookup_rc == c.SQLITE_DONE) {
            _ = c.sqlite3_reset(insert);
            _ = c.sqlite3_clear_bindings(insert);
            try bindInt(insert, 1, folder_id);
            try bindText(insert, 2, file.path);
            try bindText(insert, 3, file.relative_path);
            try bindText(insert, 4, file.name);
            try bindText(insert, 5, file.search_text);
            try bindInt(insert, 6, file.duration_ms);
            try bindInt64(insert, 7, file.content_hash);
            try bindInt64(insert, 8, file.file_size);
            try bindInt64(insert, 9, file.mtime_ns);
            if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.InsertFailed;
            published_id = c.sqlite3_last_insert_rowid(h);
        } else return error.StepFailed;
        _ = c.sqlite3_reset(update_identity);
        try bindInt(update_identity, 1, @intCast(@backingInt(file.identity_kind)));
        try bindInt(update_identity, 2, @intCast(@backingInt(file.hash_algorithm)));
        try bindInt64(update_identity, 3, published_id);
        if (c.sqlite3_step(update_identity) != c.SQLITE_DONE) return error.UpdateFailed;
    }

    if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
    if (stage) |s| {
        try s.removeMissing(h, cancel);
    } else {
        const remove = try prepareOn(h, "DELETE FROM files WHERE folder_id=? AND NOT EXISTS (SELECT 1 FROM ws_seen WHERE ws_seen.relative_path=files.relative_path)");
        defer _ = c.sqlite3_finalize(remove);
        try bindInt(remove, 1, folder_id);
        if (c.sqlite3_step(remove) != c.SQLITE_DONE) return error.DeleteFailed;
    }
    if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
    try execOn(h, "COMMIT;");
}

pub fn unicodeCandidates(allocator: std.mem.Allocator, query: []const u8, min_ms: i32, max_ms: i32, folder_id: ?i32, limit: usize) ![]Candidate {
    return ftsCandidates(allocator, "files_fts", query, min_ms, max_ms, folder_id, limit);
}

pub fn trigramCandidates(allocator: std.mem.Allocator, query: []const u8, min_ms: i32, max_ms: i32, folder_id: ?i32, limit: usize) ![]Candidate {
    return ftsCandidates(allocator, "files_trigram", query, min_ms, max_ms, folder_id, limit);
}

const LexicalHit = struct {
    file_id: i32,
    rank: f64,
    fn less(_: void, a: LexicalHit, b: LexicalHit) bool {
        return if (a.rank == b.rank) a.file_id < b.file_id else a.rank < b.rank;
    }
};

fn ftsCandidates(allocator: std.mem.Allocator, comptime table: []const u8, query: []const u8, min_ms: i32, max_ms: i32, folder_id: ?i32, limit: usize) ![]Candidate {
    if (limit == 0) return allocator.alloc(Candidate, 0);
    lock();
    defer mutex.unlock();
    const filter = if (folder_id != null) " AND rowid IN (SELECT id FROM files WHERE folder_id=? AND duration_ms>=? AND (?=0 OR duration_ms<=?))" else if (min_ms != 0 or max_ms != 0) " AND rowid IN (SELECT id FROM files WHERE duration_ms>=? AND (?=0 OR duration_ms<=?))" else "";
    var sql_buf: [1024]u8 = undefined;
    // Trigram ties are common; sorting compact IDs inside SQLite measured
    // faster than crossing the C boundary for every tied row. Unicode FTS can
    // use native rank ordering, with complete deterministic cutoff ties below.
    const trigram = comptime std.mem.eql(u8, table, "files_trigram");
    const order = if (trigram) " ORDER BY rank,rowid LIMIT ?" else " ORDER BY rank";
    const sql = try std.mem.printSentinel(&sql_buf, "SELECT rowid,rank FROM {s} WHERE {s} MATCH ?{s}{s}", .{ table, table, filter, order }, 0);
    const stmt = try prepareLocked(sql);
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, query);
    var parameter: c_int = 2;
    if (folder_id) |fid| {
        try bindInt(stmt, parameter, fid);
        parameter += 1;
    }
    if (filter.len != 0) {
        try bindInt(stmt, parameter, min_ms);
        try bindInt(stmt, parameter + 1, max_ms);
        try bindInt(stmt, parameter + 2, max_ms);
        parameter += 3;
    }
    if (trigram) try bindInt64(stmt, parameter, @intCast(limit));
    var hits: std.ArrayList(LexicalHit) = .empty;
    defer hits.deinit(allocator);
    try hits.ensureTotalCapacity(allocator, limit);
    var worst: usize = 0;
    while (true) {
        try query_cancel.check();
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const id = c.sqlite3_column_int64(stmt, 0);
        if (id < 0 or id > std.math.maxInt(i32)) return error.ResultIdOverflow;
        const hit = LexicalHit{ .file_id = @intCast(id), .rank = c.sqlite3_column_double(stmt, 1) };
        if (hits.items.len == limit and hit.rank > hits.items[worst].rank) break;
        if (hits.items.len < limit) {
            hits.appendAssumeCapacity(hit);
            if (LexicalHit.less({}, hits.items[worst], hit)) worst = hits.items.len - 1;
        } else if (LexicalHit.less({}, hit, hits.items[worst])) {
            hits.items[worst] = hit;
            for (hits.items, 0..) |item, i| if (LexicalHit.less({}, hits.items[worst], item)) {
                worst = i;
            };
        }
        // Consume the ENTIRE cutoff tie, retaining the smallest IDs. Native
        // FTS rank ordering avoids a temp sort without nondeterministic cutoffs.
    }
    std.mem.sort(LexicalHit, hits.items, {}, LexicalHit.less);
    const hydrate = try prepareLocked("SELECT id,folder_id,path,name,duration_ms,content_hash,search_text,0.0 FROM files WHERE id=?");
    defer _ = c.sqlite3_finalize(hydrate);
    var rows: std.ArrayList(Candidate) = .empty;
    errdefer rows.deinit(allocator);
    try rows.ensureTotalCapacity(allocator, hits.items.len);
    for (hits.items) |hit| {
        try query_cancel.check();
        _ = c.sqlite3_reset(hydrate);
        try bindInt(hydrate, 1, hit.file_id);
        const rc = c.sqlite3_step(hydrate);
        if (rc == c.SQLITE_DONE) continue;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        var row = try candidateAt(hydrate);
        row.bm25 = hit.rank;
        rows.appendAssumeCapacity(row);
    }
    return rows.toOwnedSlice(allocator);
}

pub fn exactNameCandidates(allocator: std.mem.Allocator, key: []const u8, filter: vector.Filter, limit: usize) ![]Candidate {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT f.id,f.folder_id,f.path,f.name,f.duration_ms,f.content_hash,f.search_text,0.0 FROM files f NOT INDEXED WHERE f.id IN (SELECT file_id FROM file_search_keys WHERE name_key=? UNION SELECT file_id FROM file_search_keys WHERE stem_key=?) AND (? IS NULL OR f.folder_id=?) AND f.duration_ms>=? AND (?=0 OR f.duration_ms<=?) ORDER BY f.id LIMIT ?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, key);
    try bindText(stmt, 2, key);
    try bindOptionalInt(stmt, 3, filter.folder_id);
    try bindOptionalInt(stmt, 4, filter.folder_id);
    try bindInt(stmt, 5, filter.min_duration_ms);
    try bindInt(stmt, 6, filter.max_duration_ms);
    try bindInt(stmt, 7, filter.max_duration_ms);
    try bindInt(stmt, 8, @intCast(limit));
    return collectCandidates(allocator, stmt, limit);
}

// ponytail: rare short typos use at most 64 same-initial vocabulary terms;
// a dedicated edit-distance index is warranted only by real missed-query data.
pub fn shortTypoTerms(allocator: std.mem.Allocator, token: []const u8) ![][]u8 {
    var terms: std.ArrayList([]u8) = .empty;
    errdefer {
        for (terms.items) |term| allocator.free(term);
        terms.deinit(allocator);
    }
    if (token.len < 2 or token.len > 24 or !std.ascii.isAlphabetic(token[0]) or token[0] >= 127) return terms.toOwnedSlice(allocator);
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT term FROM files_vocab WHERE term>=? AND term<? AND length(term) BETWEEN ? AND ? ORDER BY doc DESC,term LIMIT 64");
    defer _ = c.sqlite3_finalize(stmt);
    const next = [_]u8{token[0] + 1};
    try bindText(stmt, 1, token[0..1]);
    try bindText(stmt, 2, &next);
    try bindInt(stmt, 3, @intCast(token.len - 1));
    try bindInt(stmt, 4, @intCast(token.len + 1));
    while (true) {
        try query_cancel.check();
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const ptr = c.sqlite3_column_text(stmt, 0) orelse continue;
        const term = ptr[0..@intCast(c.sqlite3_column_bytes(stmt, 0))];
        if (std.mem.eql(u8, term, token) or !text_mod.distanceAtMostOne(token, term)) continue;
        try terms.append(allocator, try allocator.dupe(u8, term));
    }
    return terms.toOwnedSlice(allocator);
}

pub fn durationCandidates(allocator: std.mem.Allocator, min_ms: i32, max_ms: i32, folder_id: ?i32, limit: usize) ![]Candidate {
    lock();
    defer mutex.unlock();
    const all_sql = "SELECT id,folder_id,path,name,duration_ms,content_hash,search_text,0.0 FROM files WHERE duration_ms>=? AND (?=0 OR duration_ms<=?) ORDER BY name COLLATE NOCASE,id LIMIT ?";
    const folder_sql = "SELECT id,folder_id,path,name,duration_ms,content_hash,search_text,0.0 FROM files WHERE folder_id=? AND duration_ms>=? AND (?=0 OR duration_ms<=?) ORDER BY name COLLATE NOCASE,id LIMIT ?";
    const stmt = try prepareLocked(if (folder_id == null) all_sql else folder_sql);
    defer _ = c.sqlite3_finalize(stmt);
    var i: c_int = 1;
    if (folder_id) |fid| {
        try bindInt(stmt, i, fid);
        i += 1;
    }
    try bindInt(stmt, i, min_ms);
    i += 1;
    try bindInt(stmt, i, max_ms);
    i += 1;
    try bindInt(stmt, i, max_ms);
    i += 1;
    try bindInt(stmt, i, @intCast(@min(limit, @as(usize, std.math.maxInt(i32)))));
    return collectCandidates(allocator, stmt, limit);
}

pub fn listFolder(allocator: std.mem.Allocator, folder_id: i32, limit: usize) ![]Candidate {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT id,folder_id,path,name,duration_ms,content_hash,search_text,0.0 FROM files WHERE folder_id=? ORDER BY name COLLATE NOCASE,id LIMIT ?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt(stmt, 1, folder_id);
    try bindInt(stmt, 2, @intCast(@min(limit, @as(usize, std.math.maxInt(i32)))));
    return collectCandidates(allocator, stmt, limit);
}

pub fn listFolderPage(allocator: std.mem.Allocator, folder_id: i32, after_name: ?[]const u8, after_id: i32, limit: usize) ![]Candidate {
    lock();
    defer mutex.unlock();
    var sql_buf: [1024]u8 = undefined;
    // The C display name can truncate UTF-8. Resolve its complete sort key by ID.
    const cursor = if (after_name != null) " AND (name COLLATE NOCASE,id)>(COALESCE((SELECT name FROM files WHERE id=? AND folder_id=?),?) COLLATE NOCASE,?)" else "";
    const sql = try std.mem.printSentinel(&sql_buf, "SELECT id,folder_id,path,name,duration_ms,content_hash,search_text,0.0 FROM files WHERE folder_id=?{s} ORDER BY name COLLATE NOCASE,id LIMIT ?", .{cursor}, 0);
    const stmt = try prepareLocked(sql);
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt(stmt, 1, folder_id);
    var parameter: c_int = 2;
    if (after_name) |name| {
        try bindInt(stmt, 2, after_id);
        try bindInt(stmt, 3, folder_id);
        try bindText(stmt, 4, name);
        try bindInt(stmt, 5, after_id);
        parameter = 6;
    }
    try bindInt(stmt, parameter, @intCast(limit));
    return collectCandidates(allocator, stmt, limit);
}

pub fn folderManifest(allocator: std.mem.Allocator, folder_id: i32) ![]ExistingFile {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT relative_path,file_size,mtime_ns,content_hash FROM files WHERE folder_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt(stmt, 1, folder_id);

    var files: std.ArrayList(ExistingFile) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file.relative_path);
        files.deinit(allocator);
    }
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const ptr = c.sqlite3_column_text(stmt, 0) orelse return error.InvalidStoredPath;
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        try files.append(allocator, .{
            .relative_path = try allocator.dupe(u8, ptr[0..len]),
            .file_size = c.sqlite3_column_int64(stmt, 1),
            .mtime_ns = c.sqlite3_column_int64(stmt, 2),
            .content_hash = c.sqlite3_column_int64(stmt, 3),
        });
    }
    return files.toOwnedSlice(allocator);
}

fn collectCandidates(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, limit: usize) ![]Candidate {
    var rows: std.ArrayList(Candidate) = .empty;
    errdefer rows.deinit(allocator);
    while (rows.items.len < limit) {
        try query_cancel.check();
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        try rows.append(allocator, try candidateAt(stmt));
    }
    return rows.toOwnedSlice(allocator);
}

fn candidateAt(stmt: *c.sqlite3_stmt) !Candidate {
    var row = Candidate{};
    const file_id = c.sqlite3_column_int64(stmt, 0);
    if (file_id < 0 or file_id > std.math.maxInt(c_int)) return error.ResultIdOverflow;
    row.file_id = @intCast(file_id);
    row.folder_id = c.sqlite3_column_int(stmt, 1);
    copyText(stmt, 2, &row.path);
    copyText(stmt, 3, &row.name);
    row.duration_ms = c.sqlite3_column_int(stmt, 4);
    row.content_hash = c.sqlite3_column_int64(stmt, 5);
    copyText(stmt, 6, &row.search_text);
    row.bm25 = c.sqlite3_column_double(stmt, 7);
    return row;
}

fn copyText(stmt: *c.sqlite3_stmt, column: c_int, dest: []u8) void {
    const ptr = c.sqlite3_column_text(stmt, column);
    if (ptr) |p| {
        const len = @min(@as(usize, @intCast(c.sqlite3_column_bytes(stmt, column))), dest.len - 1);
        @memcpy(dest[0..len], p[0..len]);
        dest[len] = 0;
    } else dest[0] = 0;
}

pub fn countForFolder(folder_id: i32) !c_int {
    return scalarCount("SELECT COUNT(*) FROM files WHERE folder_id=?", folder_id);
}

pub fn removeFolder(folder_id: i32) !void {
    lock();
    defer mutex.unlock();
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    const stmt = try prepareLocked("DELETE FROM files WHERE folder_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt(stmt, 1, folder_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DeleteFailed;
    // files_ad maintains both FTS tables; foreign-key cascades remove semantic
    // vectors and terminal failures in the same transaction.
    try execLocked("COMMIT;");
}

pub fn duplicateCount(content_hash: i64) !c_int {
    if (content_hash <= 0) return 0;
    const group = blk: {
        lock();
        defer mutex.unlock();
        const revision = try catalogRevisionLocked();
        const stmt = try prepareLocked("SELECT id,identity_kind,hash_algorithm FROM files WHERE content_hash=? ORDER BY id");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, content_hash);
        var count: u32 = 0;
        var first_id: i32 = 0;
        while (true) {
            try query_cancel.check();
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            if (c.sqlite3_column_int(stmt, 1) != @backingInt(file_identity.Kind.full) or c.sqlite3_column_int(stmt, 2) != @backingInt(file_identity.Algorithm.wyhash_size_le64_v1)) return 0;
            if (count == 0) first_id = c.sqlite3_column_int(stmt, 0);
            count += 1;
        }
        break :blk .{ .id = first_id, .count = count, .revision = revision };
    };
    if (group.count == 0) return 0;
    const verified = try verifyDuplicates(group.id);
    if (!std.meta.eql(group.revision, verified.revision)) return error.ConcurrentCatalogChange;
    if (verified.verified_count != group.count) return 0;
    return @intCast(verified.verified_count);
}

pub fn fileIdentity(file_id: i32) !file_identity.Recorded {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT content_hash,file_size,mtime_ns,identity_kind,hash_algorithm FROM files WHERE id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt(stmt, 1, file_id);
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return error.FileNotFound;
    if (rc != c.SQLITE_ROW) return error.StepFailed;
    return columnIdentity(stmt, 0);
}

fn columnIdentity(stmt: *c.sqlite3_stmt, start: c_int) !file_identity.Recorded {
    return .{
        .hash = c.sqlite3_column_int64(stmt, start),
        .size = c.sqlite3_column_int64(stmt, start + 1),
        .mtime_ns = c.sqlite3_column_int64(stmt, start + 2),
        .kind = std.enums.fromInt(file_identity.Kind, c.sqlite3_column_int(stmt, start + 3)) orelse return error.InvalidStoredIdentity,
        .algorithm = std.enums.fromInt(file_identity.Algorithm, c.sqlite3_column_int(stmt, start + 4)) orelse return error.InvalidStoredIdentity,
    };
}

// Independent read-only WAL snapshot. A final catalog revision check rejects
// close/reopen or publication during filesystem I/O; no live DB mutex is held.
const VerificationConnection = struct {
    handle: *c.sqlite3,
    serial: u64,

    fn init() !VerificationConnection {
        const identity = blk: {
            lock();
            defer mutex.unlock();
            _ = try handleLocked();
            break :blk .{ .path = try std.heap.c_allocator.dupeSentinel(u8, db_path_owned.?, 0), .serial = connection_serial };
        };
        defer std.heap.c_allocator.free(identity.path);
        var opened: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(identity.path.ptr, &opened, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) {
            if (opened) |handle| _ = c.sqlite3_close_v2(handle);
            return error.DbOpenFailed;
        }
        const h = opened orelse return error.DbOpenFailed;
        errdefer _ = c.sqlite3_close_v2(h);
        try registerVectorFunctions(h);
        if (c.sqlite3_busy_timeout(h, 5000) != c.SQLITE_OK) return error.PragmaFailed;
        try execOn(h, "PRAGMA query_only=ON; PRAGMA cache_size=-2048; BEGIN DEFERRED;");
        c.sqlite3_progress_handler(h, 1000, queryProgress, null);
        return .{ .handle = h, .serial = identity.serial };
    }

    fn deinit(self: VerificationConnection) void {
        c.sqlite3_progress_handler(self.handle, 0, null, null);
        _ = c.sqlite3_exec(self.handle, "ROLLBACK;", null, null, null);
        _ = c.sqlite3_close_v2(self.handle);
    }
};

pub const DuplicateVerification = struct {
    candidate_count: u32 = 0,
    verified_count: u32 = 0,
    bytes_read: u64 = 0,
    revision: [2]u64 = @splat(0),
};

pub fn verifyDuplicates(file_id: i32) !DuplicateVerification {
    try query_cancel.check();
    const connection = try VerificationConnection.init();
    defer connection.deinit();
    var result = DuplicateVerification{ .revision = try catalogRevisionOn(connection.handle, connection.serial) };
    const previous_counter = @import("audio_file.zig").bytes_read;
    @import("audio_file.zig").bytes_read = &result.bytes_read;
    defer {
        @import("audio_file.zig").bytes_read = previous_counter;
        if (previous_counter) |counter| counter.* += result.bytes_read;
    }
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const anchor_stmt = try prepareOn(connection.handle, "SELECT path,content_hash,file_size,mtime_ns,identity_kind,hash_algorithm FROM files WHERE id=?");
    defer _ = c.sqlite3_finalize(anchor_stmt);
    try bindInt(anchor_stmt, 1, file_id);
    const rc = c.sqlite3_step(anchor_stmt);
    if (rc == c.SQLITE_DONE) return error.FileNotFound;
    if (rc != c.SQLITE_ROW) {
        try query_cancel.check();
        return error.StepFailed;
    }
    const recorded = try columnIdentity(anchor_stmt, 1);
    var anchor = try file_identity.Source.init(io, columnSlice(anchor_stmt, 0), recorded);
    defer anchor.deinit();
    try anchor.validateHash();
    const candidates = try prepareOn(connection.handle, "SELECT id,path,content_hash,file_size,mtime_ns,identity_kind,hash_algorithm FROM files WHERE content_hash=?1 AND identity_kind=?2 AND hash_algorithm=?3 AND file_size=?4 ORDER BY id");
    defer _ = c.sqlite3_finalize(candidates);
    try bindInt64(candidates, 1, recorded.hash);
    try bindInt(candidates, 2, @intCast(@backingInt(recorded.kind)));
    try bindInt(candidates, 3, @intCast(@backingInt(recorded.algorithm)));
    try bindInt64(candidates, 4, recorded.size);
    while (true) {
        try query_cancel.check();
        const step = c.sqlite3_step(candidates);
        if (step == c.SQLITE_DONE) break;
        if (step != c.SQLITE_ROW) {
            try query_cancel.check();
            return error.StepFailed;
        }
        result.candidate_count += 1;
        if (c.sqlite3_column_int(candidates, 0) == file_id) {
            result.verified_count += 1;
            continue;
        }
        var source = try file_identity.Source.init(io, columnSlice(candidates, 1), try columnIdentity(candidates, 2));
        defer source.deinit();
        if (try anchor.equals(&source)) result.verified_count += 1;
    }
    try anchor.confirm();
    try query_cancel.check();
    lock();
    defer mutex.unlock();
    if (!std.meta.eql(result.revision, try catalogRevisionLocked())) return error.ConcurrentCatalogChange;
    return result;
}

pub const FingerprintStorageResult = struct { processed_count: u32 = 0, bytes_before: u64 = 0, bytes_after: u64 = 0 };

/// Repack outside the mutation mutex; publication guards the captured source,
/// original bytes, storage revision and connection. A single SQL update is atomic.
pub fn repackFingerprints(allocator: std.mem.Allocator, max_files: usize) !FingerprintStorageResult {
    if (max_files == 0 or max_files > 1024) return error.InvalidBatchSize;
    var result = FingerprintStorageResult{};
    for (0..max_files) |_| {
        try query_cancel.check();
        const row = blk: {
            lock();
            defer mutex.unlock();
            const stmt = try prepareLocked("SELECT algorithm_id,file_id,source_content_hash,token_count,landmarks FROM file_fingerprints INDEXED BY idx_fingerprint_storage_pending WHERE storage_version=0 ORDER BY algorithm_id,file_id LIMIT 1");
            defer _ = c.sqlite3_finalize(stmt);
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) {
                try query_cancel.check();
                return error.StepFailed;
            }
            const ptr = c.sqlite3_column_blob(stmt, 4) orelse return error.InvalidFingerprintBlob;
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
            if (len == 0 or len > fingerprint.MAX_LANDMARKS * 11 + 32) return error.InvalidFingerprintBlob;
            break :blk .{ .serial = connection_serial, .algorithm_id = c.sqlite3_column_int64(stmt, 0), .file_id = c.sqlite3_column_int(stmt, 1), .source_hash = c.sqlite3_column_int64(stmt, 2), .count = c.sqlite3_column_int64(stmt, 3), .bytes = try allocator.dupe(u8, @as([*]const u8, @ptrCast(ptr))[0..len]) };
        };
        defer allocator.free(row.bytes);
        const landmarks = try fingerprint.deserialize(allocator, row.bytes);
        defer allocator.free(landmarks);
        if (landmarks.len != row.count) return error.InvalidFingerprintBlob;
        const compact = try fingerprint.serialize(allocator, landmarks);
        defer allocator.free(compact);
        if (comptime builtin.is_test) if (Testing.before_fingerprint_repack_publish) |hook| hook();
        try query_cancel.check();
        {
            lock();
            defer mutex.unlock();
            try query_cancel.check();
            if (row.serial != connection_serial) return error.IndexSnapshotChanged;
            const update = try prepareLocked("UPDATE file_fingerprints SET landmarks=?1,storage_version=1 WHERE algorithm_id=?2 AND file_id=?3 AND source_content_hash=?4 AND storage_version=0 AND landmarks=?5 AND token_count=?6 AND EXISTS(SELECT 1 FROM files WHERE id=?3 AND content_hash=?4)");
            defer _ = c.sqlite3_finalize(update);
            if (c.sqlite3_bind_blob(update, 1, compact.ptr, @intCast(compact.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.BindFailed;
            try bindInt64(update, 2, row.algorithm_id);
            try bindInt(update, 3, row.file_id);
            try bindInt64(update, 4, row.source_hash);
            if (c.sqlite3_bind_blob(update, 5, row.bytes.ptr, @intCast(row.bytes.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.BindFailed;
            try bindInt64(update, 6, row.count);
            if (c.sqlite3_step(update) != c.SQLITE_DONE) {
                try query_cancel.check();
                return error.UpdateFailed;
            }
            if (c.sqlite3_changes(try handleLocked()) != 1) return error.StaleContentHash;
        }
        result.processed_count += 1;
        result.bytes_before += row.bytes.len;
        result.bytes_after += compact.len;
    }
    try query_cancel.check();
    return result;
}

fn scalarCount(sql: [*:0]const u8, value: i32) !c_int {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked(sql);
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt(stmt, 1, value);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    return c.sqlite3_column_int(stmt, 0);
}

pub fn getWaveform(allocator: std.mem.Allocator, path: []const u8) !?[]f32 {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT waveform FROM files WHERE path=? AND waveform IS NOT NULL");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, path);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const blob = c.sqlite3_column_blob(stmt, 0) orelse return null;
    const byte_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    if (byte_len == 0 or byte_len % @sizeOf(f32) != 0) return null;
    const result = try allocator.alloc(f32, byte_len / @sizeOf(f32));
    @memcpy(std.mem.sliceAsBytes(result), @as([*]const u8, @ptrCast(blob))[0..byte_len]);
    return result;
}

pub fn saveWaveform(path: []const u8, samples: []const f32) !void {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("UPDATE files SET waveform=? WHERE path=?");
    defer _ = c.sqlite3_finalize(stmt);
    const bytes = std.mem.sliceAsBytes(samples);
    if (c.sqlite3_bind_blob(stmt, 1, bytes.ptr, @intCast(bytes.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.BindFailed;
    try bindText(stmt, 2, path);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
}

pub fn legacyWaveformIdentity(path: []const u8) !?LegacyWaveformIdentity {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT id,content_hash,file_size,mtime_ns FROM files WHERE path=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, path);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{
        .connection_serial = connection_serial,
        .file_id = c.sqlite3_column_int64(stmt, 0),
        .content_hash = c.sqlite3_column_int64(stmt, 1),
        .file_size = c.sqlite3_column_int64(stmt, 2),
        .mtime_ns = c.sqlite3_column_int64(stmt, 3),
    };
}

pub fn saveWaveformIfIdentity(path: []const u8, identity: LegacyWaveformIdentity, samples: []const f32) !bool {
    lock();
    defer mutex.unlock();
    if (identity.connection_serial != connection_serial) return false;
    const stmt = try prepareLocked("UPDATE files SET waveform=? WHERE path=? AND id=? AND content_hash=? AND file_size=? AND mtime_ns=?");
    defer _ = c.sqlite3_finalize(stmt);
    const bytes = std.mem.sliceAsBytes(samples);
    if (c.sqlite3_bind_blob(stmt, 1, bytes.ptr, @intCast(bytes.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.BindFailed;
    try bindText(stmt, 2, path);
    try bindInt64(stmt, 3, identity.file_id);
    try bindInt64(stmt, 4, identity.content_hash);
    try bindInt64(stmt, 5, identity.file_size);
    try bindInt64(stmt, 6, identity.mtime_ns);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    return c.sqlite3_changes(try handleLocked()) == 1;
}

pub fn waveformCacheBlobSize(path: []const u8, max_bytes: usize) !?usize {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT length(a.blob) FROM waveform_analyses a JOIN files f ON f.id=a.file_id WHERE f.path=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, path);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const byte_len = c.sqlite3_column_int64(stmt, 0);
    if (byte_len <= 0 or byte_len > max_bytes) return error.InvalidWaveformCacheBlob;
    return @intCast(byte_len);
}

pub fn loadWaveformCacheBlob(path: []const u8, output: []u8) !?usize {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT a.blob FROM waveform_analyses a JOIN files f ON f.id=a.file_id WHERE f.path=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, path);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const blob = c.sqlite3_column_blob(stmt, 0) orelse return null;
    const byte_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    if (byte_len == 0 or byte_len > output.len) return error.WaveformCacheBufferTooSmall;
    @memcpy(output[0..byte_len], @as([*]const u8, @ptrCast(blob))[0..byte_len]);
    return byte_len;
}

pub fn getWaveformCacheBlob(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) !?[]u8 {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT a.blob FROM waveform_analyses a JOIN files f ON f.id=a.file_id WHERE f.path=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, path);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const blob = c.sqlite3_column_blob(stmt, 0) orelse return null;
    const byte_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    if (byte_len == 0 or byte_len > max_bytes) return error.InvalidWaveformCacheBlob;
    return @as(?[]u8, try allocator.dupe(u8, @as([*]const u8, @ptrCast(blob))[0..byte_len]));
}

pub fn saveWaveformCacheBlob(path: []const u8, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > 64 * 1024 * 1024) return error.InvalidWaveformCacheBlob;
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("INSERT INTO waveform_analyses(file_id,blob) SELECT id,? FROM files WHERE path=? ON CONFLICT(file_id) DO UPDATE SET blob=excluded.blob");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_bind_blob(stmt, 1, bytes.ptr, @intCast(bytes.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.BindFailed;
    try bindText(stmt, 2, path);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
}

pub fn refreshLegacyWaveformIdentity(file_id: i32, expected_hash: i64, file_size: i64, mtime_ns: i64) !bool {
    if (file_id <= 0 or file_size < 0 or mtime_ns < 0) return false;
    lock();
    defer mutex.unlock();
    const update = try prepareLocked("UPDATE files SET file_size=?,mtime_ns=? WHERE id=? AND content_hash=? AND (file_size<0 OR mtime_ns<0)");
    defer _ = c.sqlite3_finalize(update);
    try bindInt64(update, 1, file_size);
    try bindInt64(update, 2, mtime_ns);
    try bindInt(update, 3, file_id);
    try bindInt64(update, 4, expected_hash);
    if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.StepFailed;
    const verify = try prepareLocked("SELECT COUNT(*) FROM files WHERE id=? AND content_hash=? AND file_size=? AND mtime_ns=?");
    defer _ = c.sqlite3_finalize(verify);
    try bindInt(verify, 1, file_id);
    try bindInt64(verify, 2, expected_hash);
    try bindInt64(verify, 3, file_size);
    try bindInt64(verify, 4, mtime_ns);
    if (c.sqlite3_step(verify) != c.SQLITE_ROW) return error.StepFailed;
    return c.sqlite3_column_int(verify, 0) == 1;
}

pub fn waveformTierBlobSize(file_id: i32, detailed: bool, max_bytes: usize) !?usize {
    lock();
    defer mutex.unlock();
    const sql = if (detailed)
        "SELECT length(detailed_blob) FROM waveform_tiers WHERE file_id=? AND detailed_blob IS NOT NULL"
    else
        "SELECT length(universal_blob) FROM waveform_tiers WHERE file_id=?";
    const stmt = try prepareLocked(sql);
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt(stmt, 1, file_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const byte_len = c.sqlite3_column_int64(stmt, 0);
    if (byte_len <= 0 or byte_len > max_bytes) return error.InvalidWaveformCacheBlob;
    return @intCast(byte_len);
}

pub fn loadWaveformTierBlob(file_id: i32, detailed: bool, output: []u8) !?usize {
    lock();
    defer mutex.unlock();
    const sql = if (detailed)
        "SELECT detailed_blob FROM waveform_tiers WHERE file_id=? AND detailed_blob IS NOT NULL"
    else
        "SELECT universal_blob FROM waveform_tiers WHERE file_id=?";
    const stmt = try prepareLocked(sql);
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt(stmt, 1, file_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const blob = c.sqlite3_column_blob(stmt, 0) orelse return null;
    const byte_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    if (byte_len == 0 or byte_len > output.len) return error.WaveformCacheBufferTooSmall;
    @memcpy(output[0..byte_len], @as([*]const u8, @ptrCast(blob))[0..byte_len]);
    return byte_len;
}

fn waveformDetailedBytesLocked() !i64 {
    const stmt = try prepareLocked("SELECT detailed_bytes FROM catalog_stats WHERE singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    return c.sqlite3_column_int64(stmt, 0);
}

fn waveformDetailedCountLocked() !i64 {
    const stmt = try prepareLocked("SELECT detailed_count FROM catalog_stats WHERE singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    return c.sqlite3_column_int64(stmt, 0);
}

fn waveformDetailedBudgetLocked() !i64 {
    const stmt = try prepareLocked("SELECT detailed_budget_bytes FROM waveform_cache_state WHERE singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    return c.sqlite3_column_int64(stmt, 0);
}

fn evictDetailedWaveformsLocked(protected_file_id: i32) !void {
    const budget = try waveformDetailedBudgetLocked();
    var bytes = try waveformDetailedBytesLocked();
    var count = try waveformDetailedCountLocked();
    if (bytes <= budget and count <= 10000) return;
    const oldest = try prepareLocked("SELECT file_id,detailed_bytes FROM waveform_tiers WHERE detailed_blob IS NOT NULL AND file_id!=? ORDER BY detailed_access_ns,file_id LIMIT 256");
    defer _ = c.sqlite3_finalize(oldest);
    try bindInt(oldest, 1, protected_file_id);
    const remove = try prepareLocked("UPDATE waveform_tiers SET detailed_blob=NULL,detailed_bytes=0,detailed_access_ns=0 WHERE file_id=? AND detailed_blob IS NOT NULL");
    defer _ = c.sqlite3_finalize(remove);
    while (bytes > budget or count > 10000) {
        try query_cancel.check();
        var ids: [256]i32 = undefined;
        var used: usize = 0;
        _ = c.sqlite3_reset(oldest);
        while (used < ids.len and (bytes > budget or count > 10000)) {
            const rc = c.sqlite3_step(oldest);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            ids[used] = c.sqlite3_column_int(oldest, 0);
            used += 1;
            bytes -= c.sqlite3_column_int64(oldest, 1);
            count -= 1;
        }
        _ = c.sqlite3_reset(oldest);
        if (used == 0) break;
        for (ids[0..used]) |id| {
            _ = c.sqlite3_reset(remove);
            try bindInt(remove, 1, id);
            if (c.sqlite3_step(remove) != c.SQLITE_DONE) return error.StepFailed;
        }
    }
    if ((bytes > budget or count > 10000) and protected_file_id > 0) {
        _ = c.sqlite3_reset(remove);
        try bindInt(remove, 1, protected_file_id);
        if (c.sqlite3_step(remove) != c.SQLITE_DONE) return error.StepFailed;
    }
}

pub fn storeWaveformTiers(
    file_id: i32,
    expected_hash: i64,
    expected_size: i64,
    expected_mtime_ns: i64,
    codec_version: i32,
    universal: []const u8,
    detailed: ?[]const u8,
) !void {
    if (universal.len == 0 or universal.len > 1024 * 1024) return error.InvalidWaveformCacheBlob;
    if (detailed) |blob| if (blob.len == 0 or blob.len > 4 * 1024 * 1024) return error.InvalidWaveformCacheBlob;
    lock();
    defer mutex.unlock();
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};

    const identity = try prepareLocked("SELECT COUNT(*) FROM files WHERE id=? AND content_hash=? AND file_size=? AND mtime_ns=?");
    defer _ = c.sqlite3_finalize(identity);
    try bindInt(identity, 1, file_id);
    try bindInt64(identity, 2, expected_hash);
    try bindInt64(identity, 3, expected_size);
    try bindInt64(identity, 4, expected_mtime_ns);
    if (c.sqlite3_step(identity) != c.SQLITE_ROW) return error.StepFailed;
    if (c.sqlite3_column_int(identity, 0) != 1) return error.StaleWaveformIdentity;

    const now_ns = wallClockNs();
    const stmt = try prepareLocked("INSERT INTO waveform_tiers(file_id,source_content_hash,source_file_size,source_mtime_ns,codec_version,universal_blob,universal_bytes,detailed_blob,detailed_bytes,detailed_access_ns) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(file_id) DO UPDATE SET source_content_hash=excluded.source_content_hash,source_file_size=excluded.source_file_size,source_mtime_ns=excluded.source_mtime_ns,codec_version=excluded.codec_version,universal_blob=excluded.universal_blob,universal_bytes=excluded.universal_bytes,detailed_blob=CASE WHEN excluded.detailed_blob IS NOT NULL THEN excluded.detailed_blob WHEN waveform_tiers.codec_version=excluded.codec_version THEN waveform_tiers.detailed_blob ELSE NULL END,detailed_bytes=CASE WHEN excluded.detailed_blob IS NOT NULL THEN excluded.detailed_bytes WHEN waveform_tiers.codec_version=excluded.codec_version THEN waveform_tiers.detailed_bytes ELSE 0 END,detailed_access_ns=CASE WHEN excluded.detailed_blob IS NOT NULL THEN excluded.detailed_access_ns WHEN waveform_tiers.codec_version=excluded.codec_version THEN waveform_tiers.detailed_access_ns ELSE 0 END");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt(stmt, 1, file_id);
    try bindInt64(stmt, 2, expected_hash);
    try bindInt64(stmt, 3, expected_size);
    try bindInt64(stmt, 4, expected_mtime_ns);
    try bindInt(stmt, 5, codec_version);
    if (c.sqlite3_bind_blob(stmt, 6, universal.ptr, @intCast(universal.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.BindFailed;
    try bindInt64(stmt, 7, @intCast(universal.len));
    if (detailed) |blob| {
        if (c.sqlite3_bind_blob(stmt, 8, blob.ptr, @intCast(blob.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.BindFailed;
        try bindInt64(stmt, 9, @intCast(blob.len));
        try bindInt64(stmt, 10, now_ns);
    } else {
        if (c.sqlite3_bind_null(stmt, 8) != c.SQLITE_OK) return error.BindFailed;
        try bindInt64(stmt, 9, 0);
        try bindInt64(stmt, 10, 0);
    }
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    if (detailed != null) try evictDetailedWaveformsLocked(file_id);
    const clear_failure = try prepareLocked("DELETE FROM waveform_failures WHERE file_id=?");
    defer _ = c.sqlite3_finalize(clear_failure);
    try bindInt(clear_failure, 1, file_id);
    if (c.sqlite3_step(clear_failure) != c.SQLITE_DONE) return error.StepFailed;
    const clear_claim = try prepareLocked("UPDATE waveform_cache_state SET waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1 AND waveform_claimed_file_id=?");
    defer _ = c.sqlite3_finalize(clear_claim);
    try bindInt(clear_claim, 1, file_id);
    if (c.sqlite3_step(clear_claim) != c.SQLITE_DONE) return error.StepFailed;
    try execLocked("COMMIT;");
}

pub fn touchDetailedWaveform(file_id: i32) !void {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("UPDATE waveform_tiers SET detailed_access_ns=? WHERE file_id=? AND detailed_blob IS NOT NULL");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, wallClockNs());
    try bindInt(stmt, 2, file_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
}

pub fn setWaveformDetailedBudget(bytes: i64) !void {
    if (bytes < 0 or bytes > 512 * 1024 * 1024) return error.InvalidWaveformCacheBudget;
    lock();
    defer mutex.unlock();
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    const stmt = try prepareLocked("UPDATE waveform_cache_state SET detailed_budget_bytes=? WHERE singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, bytes);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    try evictDetailedWaveformsLocked(-1);
    try execLocked("COMMIT;");
}

pub fn nextWaveformWork(allocator: std.mem.Allocator) !?WaveformWorkItem {
    lock();
    defer mutex.unlock();
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    const now_ns = wallClockNs();
    const state = try prepareLocked("SELECT universal_scan_complete,waveform_claimed_file_id,waveform_claim_until_ns FROM waveform_cache_state WHERE singleton=1");
    defer _ = c.sqlite3_finalize(state);
    if (c.sqlite3_step(state) != c.SQLITE_ROW) return error.StepFailed;
    const claimed_file_id = c.sqlite3_column_int(state, 1);
    const claim_until_ns = c.sqlite3_column_int64(state, 2);
    if (claimed_file_id != 0 and claim_until_ns > now_ns) {
        try execLocked("COMMIT;");
        return null;
    }
    if (claimed_file_id != 0) {
        const reclaim = try prepareLocked("UPDATE waveform_cache_state SET universal_cursor_file_id=CASE WHEN ?>0 THEN ?-1 ELSE 0 END,universal_scan_complete=0,waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1");
        defer _ = c.sqlite3_finalize(reclaim);
        try bindInt(reclaim, 1, claimed_file_id);
        try bindInt(reclaim, 2, claimed_file_id);
        if (c.sqlite3_step(reclaim) != c.SQLITE_DONE) return error.StepFailed;
    }
    if (c.sqlite3_column_int(state, 0) != 0) {
        const retries = try prepareLocked("SELECT COUNT(*) FROM waveform_failures x JOIN files f ON f.id=x.file_id AND f.content_hash=x.source_content_hash AND f.file_size=x.source_file_size AND f.mtime_ns=x.source_mtime_ns WHERE x.permanent=0 AND x.retry_after_ns<=?");
        defer _ = c.sqlite3_finalize(retries);
        try bindInt64(retries, 1, now_ns);
        if (c.sqlite3_step(retries) != c.SQLITE_ROW) return error.StepFailed;
        if (c.sqlite3_column_int64(retries, 0) == 0) {
            try execLocked("COMMIT;");
            return null;
        }
        try execLocked("UPDATE waveform_cache_state SET universal_scan_complete=0 WHERE singleton=1;");
    }
    const stmt = try prepareLocked("SELECT f.id,f.path,f.content_hash,f.file_size,f.mtime_ns FROM files f LEFT JOIN waveform_tiers w ON w.file_id=f.id LEFT JOIN waveform_failures x ON x.file_id=f.id AND x.source_content_hash=f.content_hash AND x.source_file_size=f.file_size AND x.source_mtime_ns=f.mtime_ns WHERE f.id>(SELECT universal_cursor_file_id FROM waveform_cache_state WHERE singleton=1) AND w.file_id IS NULL AND (x.file_id IS NULL OR (x.permanent=0 AND x.retry_after_ns<=?)) ORDER BY f.id LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, now_ns);
    var rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_ROW) {
        if (rc != c.SQLITE_DONE) return error.StepFailed;
        try execLocked("UPDATE waveform_cache_state SET universal_cursor_file_id=0 WHERE singleton=1;");
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        try bindInt64(stmt, 1, now_ns);
        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) {
            try execLocked("UPDATE waveform_cache_state SET universal_scan_complete=1,universal_cursor_file_id=(SELECT COALESCE(MAX(id),0) FROM files) WHERE singleton=1;");
            try execLocked("COMMIT;");
            return null;
        }
        if (rc != c.SQLITE_ROW) return error.StepFailed;
    }
    const file_id = c.sqlite3_column_int(stmt, 0);
    const path_ptr = c.sqlite3_column_text(stmt, 1) orelse return error.InvalidPath;
    const path_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
    const token_stmt = try prepareLocked("SELECT random()");
    defer _ = c.sqlite3_finalize(token_stmt);
    if (c.sqlite3_step(token_stmt) != c.SQLITE_ROW) return error.StepFailed;
    var claim_token: u64 = @bitCast(c.sqlite3_column_int64(token_stmt, 0));
    if (claim_token == 0) claim_token = 1;
    const claim_until = now_ns + WAVEFORM_CLAIM_LEASE_NS;
    const result = WaveformWorkItem{
        .file_id = file_id,
        .path = try allocator.dupe(u8, path_ptr[0..path_len]),
        .content_hash = c.sqlite3_column_int64(stmt, 2),
        .file_size = c.sqlite3_column_int64(stmt, 3),
        .mtime_ns = c.sqlite3_column_int64(stmt, 4),
        .claim_token = claim_token,
        .claim_until_ns = claim_until,
    };
    errdefer allocator.free(result.path);
    const advance = try prepareLocked("UPDATE waveform_cache_state SET universal_cursor_file_id=?,universal_scan_complete=0,waveform_claimed_file_id=?,waveform_claim_token=?,waveform_claim_until_ns=? WHERE singleton=1");
    defer _ = c.sqlite3_finalize(advance);
    try bindInt(advance, 1, file_id);
    try bindInt(advance, 2, file_id);
    try bindInt64(advance, 3, @bitCast(claim_token));
    try bindInt64(advance, 4, claim_until);
    if (c.sqlite3_step(advance) != c.SQLITE_DONE) return error.StepFailed;
    try execLocked("COMMIT;");
    return result;
}

pub fn renewWaveformWork(file_id: i32, claim_token: u64) !void {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("UPDATE waveform_cache_state SET waveform_claim_until_ns=? WHERE singleton=1 AND waveform_claimed_file_id=? AND waveform_claim_token=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, wallClockNs() + WAVEFORM_CLAIM_LEASE_NS);
    try bindInt(stmt, 2, file_id);
    try bindInt64(stmt, 3, @bitCast(claim_token));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    if (c.sqlite3_changes(try handleLocked()) == 0) return error.StaleWaveformClaim;
}

pub fn releaseWaveformWork(file_id: i32, claim_token: u64) !void {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("UPDATE waveform_cache_state SET waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1 AND waveform_claimed_file_id=? AND waveform_claim_token=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt(stmt, 1, file_id);
    try bindInt64(stmt, 2, @bitCast(claim_token));
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    if (c.sqlite3_changes(try handleLocked()) != 0) return;
    const state = try prepareLocked("SELECT waveform_claimed_file_id FROM waveform_cache_state WHERE singleton=1");
    defer _ = c.sqlite3_finalize(state);
    if (c.sqlite3_step(state) != c.SQLITE_ROW) return error.StepFailed;
    if (c.sqlite3_column_int(state, 0) != 0) return error.StaleWaveformClaim;
}

pub fn recordWaveformFailure(file_id: i32, expected_hash: i64, expected_size: i64, expected_mtime_ns: i64, claim_token: ?u64, permanent: bool, detail: []const u8) !void {
    lock();
    defer mutex.unlock();
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    if (claim_token) |token| {
        const claim = try prepareLocked("SELECT COUNT(*) FROM waveform_cache_state WHERE singleton=1 AND waveform_claimed_file_id=? AND waveform_claim_token=?");
        defer _ = c.sqlite3_finalize(claim);
        try bindInt(claim, 1, file_id);
        try bindInt64(claim, 2, @bitCast(token));
        if (c.sqlite3_step(claim) != c.SQLITE_ROW) return error.StepFailed;
        if (c.sqlite3_column_int(claim, 0) != 1) return error.StaleWaveformClaim;
    }
    const retry_after = if (permanent) @as(i64, 0) else wallClockNs() + 30 * std.time.ns_per_s;
    const stmt = try prepareLocked("INSERT INTO waveform_failures(file_id,source_content_hash,source_file_size,source_mtime_ns,permanent,attempt_count,retry_after_ns,detail) SELECT id,?,?,?,?,1,?,? FROM files WHERE id=? AND content_hash=? AND file_size=? AND mtime_ns=? AND NOT EXISTS(SELECT 1 FROM waveform_tiers WHERE file_id=?) ON CONFLICT(file_id) DO UPDATE SET source_file_size=excluded.source_file_size,source_mtime_ns=excluded.source_mtime_ns,permanent=excluded.permanent,attempt_count=waveform_failures.attempt_count+1,retry_after_ns=excluded.retry_after_ns,detail=excluded.detail WHERE waveform_failures.source_content_hash=excluded.source_content_hash AND waveform_failures.source_file_size=excluded.source_file_size AND waveform_failures.source_mtime_ns=excluded.source_mtime_ns");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, expected_hash);
    try bindInt64(stmt, 2, expected_size);
    try bindInt64(stmt, 3, expected_mtime_ns);
    try bindInt(stmt, 4, if (permanent) 1 else 0);
    try bindInt64(stmt, 5, retry_after);
    try bindText(stmt, 6, detail[0..@min(detail.len, 1024)]);
    try bindInt(stmt, 7, file_id);
    try bindInt64(stmt, 8, expected_hash);
    try bindInt64(stmt, 9, expected_size);
    try bindInt64(stmt, 10, expected_mtime_ns);
    try bindInt(stmt, 11, file_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
    if (c.sqlite3_changes(try handleLocked()) == 0) {
        const completed = try prepareLocked("SELECT COUNT(*) FROM waveform_tiers w JOIN files f ON f.id=w.file_id WHERE w.file_id=? AND f.content_hash=? AND f.file_size=? AND f.mtime_ns=?");
        defer _ = c.sqlite3_finalize(completed);
        try bindInt(completed, 1, file_id);
        try bindInt64(completed, 2, expected_hash);
        try bindInt64(completed, 3, expected_size);
        try bindInt64(completed, 4, expected_mtime_ns);
        if (c.sqlite3_step(completed) != c.SQLITE_ROW) return error.StepFailed;
        if (c.sqlite3_column_int(completed, 0) == 0) return error.StaleWaveformIdentity;
    }
    const clear_claim_sql: [*:0]const u8 = if (claim_token != null)
        "UPDATE waveform_cache_state SET waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1 AND waveform_claimed_file_id=? AND waveform_claim_token=?"
    else
        "UPDATE waveform_cache_state SET waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1 AND waveform_claimed_file_id=?";
    const clear_claim = try prepareLocked(clear_claim_sql);
    defer _ = c.sqlite3_finalize(clear_claim);
    try bindInt(clear_claim, 1, file_id);
    if (claim_token) |token| try bindInt64(clear_claim, 2, @bitCast(token));
    if (c.sqlite3_step(clear_claim) != c.SQLITE_DONE) return error.StepFailed;
    try execLocked("COMMIT;");
}

pub fn waveformWorkPending() !bool {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT universal_scan_complete=0 OR EXISTS(SELECT 1 FROM waveform_failures x JOIN files f ON f.id=x.file_id AND f.content_hash=x.source_content_hash AND f.file_size=x.source_file_size AND f.mtime_ns=x.source_mtime_ns WHERE x.permanent=0 AND x.retry_after_ns<=?) FROM waveform_cache_state WHERE singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, wallClockNs());
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    return c.sqlite3_column_int(stmt, 0) != 0;
}

/// Clear generated waveform data while preserving the catalog and search
/// refinements. Producers must be drained before callers discard their caches.
pub fn clearWaveformCache() !void {
    lock();
    defer mutex.unlock();
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    try execLocked("DELETE FROM waveform_tiers;");
    try execLocked("DELETE FROM waveform_analyses;");
    try execLocked("DELETE FROM waveform_failures;");
    try execLocked("UPDATE files SET waveform=NULL WHERE waveform IS NOT NULL;");
    try execLocked("UPDATE waveform_cache_state SET universal_cursor_file_id=0,universal_scan_complete=0,waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1;");
    try execLocked("COMMIT;");
}

pub fn waveformCacheStatus() !WaveformCacheStatus {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT s.universal_count,s.detailed_count,s.file_count-s.universal_count-s.waveform_failure_count,s.waveform_terminal_count,s.universal_bytes,s.detailed_bytes,w.detailed_budget_bytes FROM catalog_stats s JOIN waveform_cache_state w ON w.singleton=s.singleton WHERE s.singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    return .{
        .universal_count = c.sqlite3_column_int64(stmt, 0),
        .detailed_count = c.sqlite3_column_int64(stmt, 1),
        .pending_count = c.sqlite3_column_int64(stmt, 2),
        .failed_count = c.sqlite3_column_int64(stmt, 3),
        .universal_bytes = c.sqlite3_column_int64(stmt, 4),
        .detailed_bytes = c.sqlite3_column_int64(stmt, 5),
        .detailed_budget_bytes = c.sqlite3_column_int64(stmt, 6),
    };
}

pub fn inspectFile(relative_path: []const u8) !?FileInfo {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT id,file_size,mtime_ns,content_hash,waveform IS NOT NULL,identity_kind,hash_algorithm FROM files WHERE relative_path=? LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, relative_path);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{
        .id = c.sqlite3_column_int64(stmt, 0),
        .file_size = c.sqlite3_column_int64(stmt, 1),
        .mtime_ns = c.sqlite3_column_int64(stmt, 2),
        .content_hash = c.sqlite3_column_int64(stmt, 3),
        .has_waveform = c.sqlite3_column_int(stmt, 4) != 0,
        .identity_kind = std.enums.fromInt(file_identity.Kind, c.sqlite3_column_int(stmt, 5)) orelse return error.InvalidStoredIdentity,
        .hash_algorithm = std.enums.fromInt(file_identity.Algorithm, c.sqlite3_column_int(stmt, 6)) orelse return error.InvalidStoredIdentity,
    };
}

fn registerSemanticModelLocked(model_key: []const u8, dimension: usize) !i64 {
    if (model_key.len == 0 or model_key.len >= MODEL_KEY_CAPACITY) return error.InvalidModelKey;
    if (dimension == 0 or dimension > vector.MAX_DIMENSION) return error.InvalidDimension;
    const insert = try prepareLocked("INSERT OR IGNORE INTO embedding_models(model_key,dimension,vector_format) VALUES(?,?,?)");
    defer _ = c.sqlite3_finalize(insert);
    try bindText(insert, 1, model_key);
    try bindInt(insert, 2, @intCast(dimension));
    try bindText(insert, 3, vector.VECTOR_FORMAT);
    if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.InsertFailed;

    const lookup = try prepareLocked("SELECT id,dimension,vector_format FROM embedding_models WHERE model_key=?");
    defer _ = c.sqlite3_finalize(lookup);
    try bindText(lookup, 1, model_key);
    if (c.sqlite3_step(lookup) != c.SQLITE_ROW) return error.ModelNotFound;
    if (c.sqlite3_column_int(lookup, 1) != dimension) return error.ModelIdentityConflict;
    const format_ptr = c.sqlite3_column_text(lookup, 2) orelse return error.ModelIdentityConflict;
    const format = format_ptr[0..@intCast(c.sqlite3_column_bytes(lookup, 2))];
    if (!std.mem.eql(u8, format, vector.VECTOR_FORMAT)) return error.ModelIdentityConflict;
    return c.sqlite3_column_int64(lookup, 0);
}

pub fn registerSemanticModel(model_key: []const u8, dimension: usize) !i64 {
    lock();
    defer mutex.unlock();
    return registerSemanticModelLocked(model_key, dimension);
}

pub fn activateSemanticModel(model_id: i64) !void {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("UPDATE semantic_state SET generation=generation+(active_model_id IS NOT ?),active_model_id=? WHERE singleton=1 AND EXISTS(SELECT 1 FROM embedding_models WHERE id=?)");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, model_id);
    try bindInt64(stmt, 2, model_id);
    try bindInt64(stmt, 3, model_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
    if (c.sqlite3_changes(try handleLocked()) != 1) return error.ModelNotFound;
}

pub fn setSemanticModel(model_key: []const u8, dimension: usize) !i64 {
    lock();
    defer mutex.unlock();
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    const model_id = try registerSemanticModelLocked(model_key, dimension);
    const stmt = try prepareLocked("UPDATE semantic_state SET generation=generation+(active_model_id IS NOT ?),active_model_id=? WHERE singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, model_id);
    try bindInt64(stmt, 2, model_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UpdateFailed;
    try execLocked("COMMIT;");
    return model_id;
}

pub fn upsertSemanticEmbedding(allocator: std.mem.Allocator, file_id: i32, source_content_hash: i64, values: []const f32) !void {
    lock();
    defer mutex.unlock();
    const info = (try activeSemanticInfoLocked()) orelse return error.NoActiveSemanticModel;
    return upsertSemanticEmbeddingLocked(allocator, info.model_id, info.dimension, file_id, source_content_hash, values);
}

pub fn upsertSemanticEmbeddingForModel(allocator: std.mem.Allocator, model_id: i64, file_id: i32, source_content_hash: i64, values: []const f32) !void {
    lock();
    defer mutex.unlock();
    const model = try prepareLocked("SELECT dimension FROM embedding_models WHERE id=?");
    defer _ = c.sqlite3_finalize(model);
    try bindInt64(model, 1, model_id);
    if (c.sqlite3_step(model) != c.SQLITE_ROW) return error.ModelNotFound;
    const dimension = c.sqlite3_column_int64(model, 0);
    if (dimension <= 0 or dimension > vector.MAX_DIMENSION) return error.InvalidStoredDimension;
    return upsertSemanticEmbeddingLocked(allocator, model_id, @intCast(dimension), file_id, source_content_hash, values);
}

fn upsertSemanticEmbeddingLocked(allocator: std.mem.Allocator, model_id: i64, dimension: usize, file_id: i32, source_content_hash: i64, values: []const f32) !void {
    if (values.len != dimension) return error.DimensionMismatch;
    const bytes = try vector.serializeNormalized(allocator, values);
    defer allocator.free(bytes);

    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    const file = try prepareLocked("SELECT content_hash FROM files WHERE id=?");
    defer _ = c.sqlite3_finalize(file);
    try bindInt(file, 1, file_id);
    if (c.sqlite3_step(file) != c.SQLITE_ROW) return error.FileNotFound;
    if (c.sqlite3_column_int64(file, 0) != source_content_hash) return error.StaleContentHash;

    const stmt = try prepareLocked("INSERT INTO file_embeddings(model_id,file_id,source_content_hash,vector) VALUES(?,?,?,?) " ++
        "ON CONFLICT(model_id,file_id) DO UPDATE SET source_content_hash=excluded.source_content_hash,vector=excluded.vector");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, model_id);
    try bindInt(stmt, 2, file_id);
    try bindInt64(stmt, 3, source_content_hash);
    if (c.sqlite3_bind_blob(stmt, 4, bytes.ptr, @intCast(bytes.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.BindFailed;
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
    const clear = try prepareLocked("DELETE FROM embedding_failures WHERE model_id=? AND file_id=? AND source_content_hash=?");
    defer _ = c.sqlite3_finalize(clear);
    try bindInt64(clear, 1, model_id);
    try bindInt(clear, 2, file_id);
    try bindInt64(clear, 3, source_content_hash);
    if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DeleteFailed;
    try execLocked("COMMIT;");
}

pub fn pendingSemanticFiles(allocator: std.mem.Allocator, folder_id: ?i32, limit: usize) ![]PendingSemanticFile {
    return pendingSemanticFilesAfter(allocator, folder_id, limit, 0);
}

pub fn pendingSemanticFilesForModel(allocator: std.mem.Allocator, model_id: i64, folder_id: ?i32, limit: usize) ![]PendingSemanticFile {
    return pendingSemanticFilesForModelAfter(allocator, model_id, folder_id, limit, 0);
}

pub fn pendingSemanticFilesForModelAfter(allocator: std.mem.Allocator, model_id: i64, folder_id: ?i32, limit: usize, after_id: i32) ![]PendingSemanticFile {
    lock();
    defer mutex.unlock();
    return pendingSemanticFilesLocked(allocator, model_id, folder_id, limit, after_id);
}

fn pendingSemanticFilesAfter(allocator: std.mem.Allocator, folder_id: ?i32, limit: usize, after_id: i32) ![]PendingSemanticFile {
    lock();
    defer mutex.unlock();
    const info = (try activeSemanticInfoLocked()) orelse return error.NoActiveSemanticModel;
    return pendingSemanticFilesLocked(allocator, info.model_id, folder_id, limit, after_id);
}

fn pendingSemanticFilesLocked(allocator: std.mem.Allocator, model_id: i64, folder_id: ?i32, limit: usize, after_id: i32) ![]PendingSemanticFile {
    if (limit == 0) return allocator.alloc(PendingSemanticFile, 0);
    // Drive retrieval from the pending index, including folder-scoped calls.
    // Completed catalog rows are never revisited by the next bounded batch.
    const all_sql = "SELECT f.id,f.path,f.content_hash FROM pending_embeddings p CROSS JOIN files f ON f.id=p.file_id WHERE p.model_id=? AND p.file_id>? ORDER BY p.file_id LIMIT ?";
    const folder_sql = "SELECT f.id,f.path,f.content_hash FROM pending_embeddings p INDEXED BY idx_pending_embeddings_folder CROSS JOIN files f ON f.id=p.file_id WHERE p.model_id=? AND p.folder_id=? AND p.file_id>? ORDER BY p.file_id LIMIT ?";
    const stmt = try prepareLocked(if (folder_id == null) all_sql else folder_sql);
    defer _ = c.sqlite3_finalize(stmt);
    defer if (builtin.is_test) {
        pending_query_steps[0] += @intCast(c.sqlite3_stmt_status(stmt, c.SQLITE_STMTSTATUS_VM_STEP, 0));
    };
    var index: c_int = 1;
    try bindInt64(stmt, index, model_id);
    index += 1;
    if (folder_id) |folder| {
        try bindInt(stmt, index, folder);
        index += 1;
    }
    try bindInt(stmt, index, after_id);
    index += 1;
    try bindInt(stmt, index, @intCast(@min(limit, @as(usize, std.math.maxInt(i32)))));

    var files: std.ArrayList(PendingSemanticFile) = .empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const raw_id = c.sqlite3_column_int64(stmt, 0);
        if (raw_id <= 0 or raw_id > std.math.maxInt(i32)) return error.ResultIdOverflow;
        const path_ptr = c.sqlite3_column_text(stmt, 1) orelse return error.InvalidStoredPath;
        const path_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        try files.append(allocator, .{
            .id = @intCast(raw_id),
            .path = try allocator.dupe(u8, path_ptr[0..path_len]),
            .source_content_hash = c.sqlite3_column_int64(stmt, 2),
        });
    }
    return files.toOwnedSlice(allocator);
}

pub fn recordEmbeddingFailure(file_id: i32, source_content_hash: i64, error_code: []const u8, detail: []const u8) !void {
    lock();
    defer mutex.unlock();
    const info = (try activeSemanticInfoLocked()) orelse return error.NoActiveSemanticModel;
    return recordEmbeddingFailureLocked(info.model_id, file_id, source_content_hash, error_code, detail);
}

pub fn recordEmbeddingFailureForModel(model_id: i64, file_id: i32, source_content_hash: i64, error_code: []const u8, detail: []const u8) !void {
    lock();
    defer mutex.unlock();
    return recordEmbeddingFailureLocked(model_id, file_id, source_content_hash, error_code, detail);
}

fn recordEmbeddingFailureLocked(model_id: i64, file_id: i32, source_content_hash: i64, error_code: []const u8, detail: []const u8) !void {
    if (error_code.len == 0 or error_code.len > 128 or detail.len > 4096) return error.InvalidFailureDetail;
    const file = try prepareLocked("SELECT content_hash FROM files WHERE id=?");
    defer _ = c.sqlite3_finalize(file);
    try bindInt(file, 1, file_id);
    if (c.sqlite3_step(file) != c.SQLITE_ROW) return error.FileNotFound;
    if (c.sqlite3_column_int64(file, 0) != source_content_hash) return error.StaleContentHash;
    const stmt = try prepareLocked("INSERT INTO embedding_failures(model_id,file_id,source_content_hash,error_code,detail) SELECT ?1,?2,?3,?4,?5 WHERE EXISTS(SELECT 1 FROM files WHERE id=?2 AND content_hash=?3) AND NOT EXISTS(SELECT 1 FROM file_embeddings WHERE model_id=?1 AND file_id=?2 AND source_content_hash=?3) " ++
        "ON CONFLICT(model_id,file_id) DO UPDATE SET source_content_hash=excluded.source_content_hash,error_code=excluded.error_code,detail=excluded.detail");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, model_id);
    try bindInt(stmt, 2, file_id);
    try bindInt64(stmt, 3, source_content_hash);
    try bindText(stmt, 4, error_code);
    try bindText(stmt, 5, detail);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
}

fn activeSemanticInfoLocked() !?SemanticInfo {
    const stmt = try prepareLocked("SELECT m.id,m.dimension,s.generation FROM semantic_state s JOIN embedding_models m ON m.id=s.active_model_id WHERE s.singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return null;
    if (rc != c.SQLITE_ROW) return error.StepFailed;
    const dimension = c.sqlite3_column_int64(stmt, 1);
    if (dimension <= 0 or dimension > vector.MAX_DIMENSION) return error.InvalidStoredDimension;
    return .{
        .connection_serial = connection_serial,
        .model_id = c.sqlite3_column_int64(stmt, 0),
        .dimension = @intCast(dimension),
        .generation = c.sqlite3_column_int64(stmt, 2),
    };
}

pub fn activeSemanticInfo() !?SemanticInfo {
    lock();
    defer mutex.unlock();
    return activeSemanticInfoLocked();
}

pub fn semanticStatus() !SemanticStatus {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT s.generation,m.id,m.model_key,m.dimension,m.embedded_count,c.file_count,m.failed_count FROM semantic_state s JOIN catalog_stats c ON c.singleton=s.singleton LEFT JOIN embedding_models m ON m.id=s.active_model_id WHERE s.singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    var status = SemanticStatus{ .generation = c.sqlite3_column_int64(stmt, 0) };
    const total = c.sqlite3_column_int64(stmt, 5);
    if (c.sqlite3_column_type(stmt, 1) != c.SQLITE_NULL) {
        status.active = true;
        status.model_id = c.sqlite3_column_int64(stmt, 1);
        status.dimension = c.sqlite3_column_int(stmt, 3);
        status.embedded_count = c.sqlite3_column_int64(stmt, 4);
        status.failed_count = c.sqlite3_column_int64(stmt, 6);
        const key = c.sqlite3_column_text(stmt, 2) orelse return error.InvalidStoredModel;
        const len = @min(@as(usize, @intCast(c.sqlite3_column_bytes(stmt, 2))), status.model_key.len - 1);
        @memcpy(status.model_key[0..len], key[0..len]);
    }
    status.pending_count = total - status.embedded_count - status.failed_count;
    return status;
}

pub fn loadActiveVectorSnapshot(allocator: std.mem.Allocator) !?VectorSnapshot {
    lock();
    defer mutex.unlock();
    const info = (try activeSemanticInfoLocked()) orelse return null;

    const count_stmt = try prepareLocked("SELECT COUNT(*) FROM file_embeddings e JOIN files f ON f.id=e.file_id WHERE e.model_id=? AND e.source_content_hash=f.content_hash");
    defer _ = c.sqlite3_finalize(count_stmt);
    try bindInt64(count_stmt, 1, info.model_id);
    if (c.sqlite3_step(count_stmt) != c.SQLITE_ROW) return error.StepFailed;
    const count_raw = c.sqlite3_column_int64(count_stmt, 0);
    if (count_raw < 0) return error.InvalidStoredVector;
    const count: usize = @intCast(count_raw);

    var snapshot = VectorSnapshot{
        .connection_serial = info.connection_serial,
        .model_id = info.model_id,
        .dimension = info.dimension,
        .generation = info.generation,
        .file_ids = try allocator.alloc(i32, count),
        .folder_ids = undefined,
        .durations_ms = undefined,
        .vectors = undefined,
    };
    errdefer allocator.free(snapshot.file_ids);
    snapshot.folder_ids = try allocator.alloc(i32, count);
    errdefer allocator.free(snapshot.folder_ids);
    snapshot.durations_ms = try allocator.alloc(i32, count);
    errdefer allocator.free(snapshot.durations_ms);
    snapshot.vectors = try allocator.alloc(f32, std.math.mul(usize, count, info.dimension) catch return error.InvalidStoredVector);
    errdefer allocator.free(snapshot.vectors);

    const stmt = try prepareLocked("SELECT f.id,f.folder_id,f.duration_ms,e.vector FROM file_embeddings e JOIN files f ON f.id=e.file_id WHERE e.model_id=? AND e.source_content_hash=f.content_hash ORDER BY f.id");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, info.model_id);
    var row: usize = 0;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW or row >= count) return error.StepFailed;
        const raw_id = c.sqlite3_column_int64(stmt, 0);
        if (raw_id < 0 or raw_id > std.math.maxInt(i32)) return error.ResultIdOverflow;
        snapshot.file_ids[row] = @intCast(raw_id);
        snapshot.folder_ids[row] = c.sqlite3_column_int(stmt, 1);
        snapshot.durations_ms[row] = c.sqlite3_column_int(stmt, 2);
        const blob = c.sqlite3_column_blob(stmt, 3) orelse return error.InvalidStoredVector;
        const byte_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 3));
        try vector.decodeNormalizedInto(@as([*]const u8, @ptrCast(blob))[0..byte_len], snapshot.vectors[row * info.dimension ..][0..info.dimension]);
        row += 1;
    }
    if (row != count) return error.StepFailed;
    return snapshot;
}

pub const StreamingVectorMatches = struct {
    model_id: i64,
    connection_serial: u64,
    generation: i64,
    matches: []vector.Match,
    quantized: bool = false,
    scanned: usize = 0,
    reranked: usize = 0,
    refinement_scanned: usize = 0,
};

pub const VectorRetrievalMode = enum { auto, exact, quantized };
pub const SQ8_MIN_ROWS: usize = 4096;
pub const SQ8_MAX_SEED: usize = 4096;

fn rollbackSemanticReader(reader: *c.sqlite3) void {
    // A sticky request cancellation must not interrupt cleanup and poison the
    // reusable reader's transaction state.
    c.sqlite3_progress_handler(reader, 0, null, null);
    _ = c.sqlite3_exec(reader, "ROLLBACK;", null, null, null);
    c.sqlite3_progress_handler(reader, 1000, queryProgress, null);
}

fn semanticReaderLocked(path: [:0]const u8, serial: u64) !*c.sqlite3 {
    if (semantic_reader) |reader| {
        if (semantic_reader_serial == serial) return reader;
        _ = c.sqlite3_close_v2(reader);
        semantic_reader = null;
        semantic_reader_serial = 0;
    }

    var opened: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(path.ptr, &opened, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) {
        if (opened) |handle| _ = c.sqlite3_close_v2(handle);
        return error.DbOpenFailed;
    }
    const reader = opened orelse return error.DbOpenFailed;
    errdefer {
        _ = c.sqlite3_close_v2(reader);
        semantic_reader = null;
        semantic_reader_serial = 0;
    }
    try registerVectorFunctions(reader);
    c.sqlite3_progress_handler(reader, 1000, queryProgress, null);
    if (c.sqlite3_busy_timeout(reader, 5000) != c.SQLITE_OK) return error.PragmaFailed;
    if (c.sqlite3_exec(reader, "PRAGMA query_only=ON; PRAGMA cache_size=-16384;", null, null, null) != c.SQLITE_OK) return error.PragmaFailed;
    semantic_reader = reader;
    semantic_reader_serial = serial;
    return reader;
}

pub fn streamActiveVectorTopK(allocator: std.mem.Allocator, query: []const f32, filter: vector.Filter, k: usize) !?StreamingVectorMatches {
    return streamActiveVectorTopKWithMode(allocator, query, filter, k, .auto);
}

/// Exact remains available as the recall oracle and for selective SQL filters.
pub fn streamActiveVectorTopKWithMode(allocator: std.mem.Allocator, query: []const f32, filter: vector.Filter, k: usize, mode: VectorRetrievalMode) !?StreamingVectorMatches {
    try query_cancel.check();
    try vector.validateNormalized(query);
    const snapshot = blk: {
        lock();
        defer mutex.unlock();
        const info = (try activeSemanticInfoLocked()) orelse return null;
        const path = db_path_owned orelse return error.NotOpen;
        break :blk .{ .info = info, .path = try std.heap.c_allocator.dupeSentinel(u8, path, 0) };
    };
    defer std.heap.c_allocator.free(snapshot.path);
    const info = snapshot.info;
    if (query.len != info.dimension) return error.DimensionMismatch;
    if (k == 0) return .{ .model_id = info.model_id, .connection_serial = info.connection_serial, .generation = info.generation, .matches = try allocator.alloc(vector.Match, 0) };
    const result = blk: {
        semantic_reader_mutex.lock();
        defer semantic_reader_mutex.unlock();
        try query_cancel.check();
        const reader = try semanticReaderLocked(snapshot.path, info.connection_serial);
        if (c.sqlite3_exec(reader, "BEGIN DEFERRED;", null, null, null) != c.SQLITE_OK) return error.PragmaFailed;
        defer rollbackSemanticReader(reader);
        // Finalize every statement BEFORE returning the reader to another caller.
        break :blk try retrieveVectors(allocator, reader, info, query, filter, k, mode);
    };
    errdefer allocator.free(result.matches);
    try query_cancel.check();
    lock();
    const current = activeSemanticInfoLocked() catch null;
    mutex.unlock();
    if (current == null or current.?.connection_serial != info.connection_serial or current.?.model_id != info.model_id) return error.StaleSemanticSnapshot;
    return result;
}

fn retrieveVectors(allocator: std.mem.Allocator, reader: *c.sqlite3, info: SemanticInfo, query: []const f32, filter: vector.Filter, k: usize, mode: VectorRetrievalMode) !StreamingVectorMatches {
    const state = try prepareOn(reader, "SELECT generation FROM semantic_state WHERE singleton=1 AND active_model_id=?");
    defer _ = c.sqlite3_finalize(state);
    try bindInt64(state, 1, info.model_id);
    if (c.sqlite3_step(state) != c.SQLITE_ROW) return error.StaleSemanticSnapshot;
    const read_generation = c.sqlite3_column_int64(state, 0);
    const filtered = filter.folder_id != null or filter.min_duration_ms > 0 or filter.max_duration_ms != 0;
    var use_quantized = mode == .quantized and k <= SQ8_MAX_SEED / 4;
    if (mode == .auto and k <= SQ8_MAX_SEED / 4) {
        const counts = try prepareOn(reader, "SELECT embedded_count,quantized_count FROM embedding_models WHERE id=?");
        defer _ = c.sqlite3_finalize(counts);
        try bindInt64(counts, 1, info.model_id);
        if (c.sqlite3_step(counts) != c.SQLITE_ROW) return error.StaleSemanticSnapshot;
        const count = c.sqlite3_column_int64(counts, 0);
        // A damaged/incomplete derived index falls back to canonical exact.
        use_quantized = count >= SQ8_MIN_ROWS and count == c.sqlite3_column_int64(counts, 1);
        if (use_quantized and filtered) {
            // Stop at the crossover instead of counting a whole matching corpus.
            // Read only identities, never canonical Float32 payloads, in this probe.
            const population = try prepareOn(reader, if (filter.folder_id != null)
                "SELECT COUNT(*) FROM (SELECT f.id FROM files f INDEXED BY idx_files_folder_duration CROSS JOIN file_embeddings e ON e.file_id=f.id WHERE f.folder_id=?2 AND f.duration_ms>=?3 AND f.duration_ms<=?4 AND e.model_id=?1 AND e.source_content_hash=f.content_hash LIMIT ?5)"
            else
                "SELECT COUNT(*) FROM (SELECT f.id FROM files f INDEXED BY idx_files_duration CROSS JOIN file_embeddings e ON e.file_id=f.id WHERE f.duration_ms>=?3 AND f.duration_ms<=?4 AND e.model_id=?1 AND e.source_content_hash=f.content_hash AND ?2<0 LIMIT ?5)");
            defer _ = c.sqlite3_finalize(population);
            try bindVectorFilter(population, info.model_id, filter);
            try bindInt(population, 5, SQ8_MIN_ROWS);
            const rc = c.sqlite3_step(population);
            try query_cancel.check();
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            use_quantized = c.sqlite3_column_int64(population, 0) >= SQ8_MIN_ROWS;
        }
    }
    // ponytail: SQ8 still scans O(N*d) compact codes. Seed a bounded heap, then
    // use conservative error bounds to score any ambiguous candidates exactly.
    const capacity = if (use_quantized) @max(k * 4, 128) else k;
    const top = try allocator.alloc(vector.Match, capacity);
    errdefer allocator.free(top);
    var count: usize = 0;
    var scanned: usize = 0;
    var reranked: usize = 0;
    var refinement_scanned: usize = 0;
    var maximum_error: f32 = 0;
    var discarded_score = -std.math.inf(f32);
    const rounding_margin = vector.dotRoundingMargin(info.dimension);
    const sql = if (use_quantized)
        vectorScanSql("semantic_sq8", "code", filter)
    else
        vectorScanSql("file_embeddings", "vector", filter);
    const stmt = try prepareOn(reader, sql);
    defer _ = c.sqlite3_finalize(stmt);
    try bindVectorFilter(stmt, info.model_id, filter);
    const decoded = try allocator.alloc(f32, info.dimension);
    defer allocator.free(decoded);
    while (true) {
        try query_cancel.check();
        const rc = c.sqlite3_step(stmt);
        try query_cancel.check();
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const raw_id = c.sqlite3_column_int64(stmt, 0);
        if (raw_id <= 0 or raw_id > std.math.maxInt(i32)) return error.ResultIdOverflow;
        const blob = c.sqlite3_column_blob(stmt, 1) orelse return error.InvalidStoredVector;
        const byte_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        const bytes = @as([*]const u8, @ptrCast(blob))[0..byte_len];
        const score = if (use_quantized) try vector.quantizedDot(query, bytes) else exact: {
            try vector.decodeNormalizedInto(bytes, decoded);
            break :exact try vector.dot(query, decoded);
        };
        if (use_quantized) maximum_error = @max(maximum_error, try vector.quantizedError(bytes));
        const item = vector.Match{ .file_id = @intCast(raw_id), .score = score, .source_content_hash = c.sqlite3_column_int64(stmt, 2) };
        scanned += 1;
        if (count < capacity) {
            top[count] = item;
            vectorHeapSiftUp(top[0 .. count + 1], count);
            count += 1;
        } else if (vectorMatchBetter(item, top[0])) {
            discarded_score = @max(discarded_score, top[0].score);
            top[0] = item;
            vectorHeapSiftDown(top[0..count], 0);
        } else {
            discarded_score = @max(discarded_score, item.score);
        }
    }
    if (use_quantized) {
        // The same read transaction supplies both codes and original vectors.
        const rerank = try prepareOn(reader, "SELECT vector FROM file_embeddings WHERE model_id=? AND file_id=?");
        defer _ = c.sqlite3_finalize(rerank);
        try bindInt64(rerank, 1, info.model_id);
        const seed_ids = try allocator.alloc(i32, count);
        defer allocator.free(seed_ids);
        for (top[0..count], seed_ids) |*item, *id| {
            id.* = item.file_id;
            item.score = try rerankVector(rerank, item.file_id, query, decoded);
        }
        reranked = count;
        // Rebuild after replacing approximate scores, retaining only exact top-K.
        var parent = count / 2;
        while (parent > 0) {
            parent -= 1;
            vectorHeapSiftDown(top[0..count], parent);
        }
        while (count > k) {
            count -= 1;
            top[0] = top[count];
            vectorHeapSiftDown(top[0..count], 0);
        }
        if (count > 0 and discarded_score + maximum_error + rounding_margin >= top[0].score) {
            // A fixed shortlist loses recall in dense/near-duplicate clusters.
            // Revisit compact codes only when an excluded vector could beat Kth.
            _ = c.sqlite3_reset(stmt);
            while (true) {
                try query_cancel.check();
                const rc = c.sqlite3_step(stmt);
                try query_cancel.check();
                if (rc == c.SQLITE_DONE) break;
                if (rc != c.SQLITE_ROW) return error.StepFailed;
                refinement_scanned += 1;
                const blob = c.sqlite3_column_blob(stmt, 1) orelse return error.InvalidStoredVector;
                const length: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
                const bytes = @as([*]const u8, @ptrCast(blob))[0..length];
                const upper = try vector.quantizedDot(query, bytes) + try vector.quantizedError(bytes) + rounding_margin;
                if (upper < top[0].score) continue;
                const id = c.sqlite3_column_int(stmt, 0); // Validated in the first pass of this same snapshot.
                if (std.mem.indexOfScalar(i32, seed_ids, id) != null) continue;
                const item = vector.Match{ .file_id = id, .score = try rerankVector(rerank, id, query, decoded), .source_content_hash = c.sqlite3_column_int64(stmt, 2) };
                reranked += 1;
                if (vectorMatchBetter(item, top[0])) {
                    top[0] = item;
                    vectorHeapSiftDown(top[0..count], 0);
                }
            }
        }
    }
    std.mem.sort(vector.Match, top[0..count], {}, struct {
        fn lessThan(_: void, a: vector.Match, b: vector.Match) bool {
            return vectorMatchBetter(a, b);
        }
    }.lessThan);
    return .{ .model_id = info.model_id, .connection_serial = info.connection_serial, .generation = read_generation, .matches = try allocator.realloc(top, @min(count, k)), .quantized = use_quantized, .scanned = scanned, .reranked = reranked, .refinement_scanned = refinement_scanned };
}

fn bindVectorFilter(stmt: *c.sqlite3_stmt, model_id: i64, filter: vector.Filter) !void {
    try bindInt64(stmt, 1, model_id);
    try bindInt(stmt, 2, filter.folder_id orelse -1);
    try bindInt(stmt, 3, filter.min_duration_ms);
    try bindInt(stmt, 4, if (filter.max_duration_ms == 0) std.math.maxInt(i32) else filter.max_duration_ms);
}

fn vectorScanSql(comptime table: []const u8, comptime payload: []const u8, filter: vector.Filter) [:0]const u8 {
    const projection = "SELECT f.id,e." ++ payload ++ ",f.content_hash FROM ";
    const predicate = " WHERE e.model_id=?1 AND e.source_content_hash=f.content_hash AND f.duration_ms>=?3 AND f.duration_ms<=?4";
    if (filter.folder_id != null)
        return projection ++ "files f INDEXED BY idx_files_folder_duration CROSS JOIN " ++ table ++ " e ON e.file_id=f.id" ++ predicate ++ " AND f.folder_id=?2";
    if (filter.min_duration_ms > 0 or filter.max_duration_ms != 0)
        return projection ++ "files f INDEXED BY idx_files_duration CROSS JOIN " ++ table ++ " e ON e.file_id=f.id" ++ predicate ++ " AND ?2<0";
    return projection ++ table ++ " e NOT INDEXED CROSS JOIN files f ON f.id=e.file_id" ++ predicate ++ " AND ?2<0";
}

fn rerankVector(stmt: *c.sqlite3_stmt, id: i32, query: []const f32, decoded: []f32) !f32 {
    try query_cancel.check();
    _ = c.sqlite3_reset(stmt);
    try bindInt(stmt, 2, id);
    const rc = c.sqlite3_step(stmt);
    try query_cancel.check();
    if (rc != c.SQLITE_ROW) return error.StepFailed;
    const blob = c.sqlite3_column_blob(stmt, 0) orelse return error.InvalidStoredVector;
    const length: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    try vector.decodeNormalizedInto(@as([*]const u8, @ptrCast(blob))[0..length], decoded);
    return vector.dot(query, decoded);
}

fn vectorMatchBetter(a: vector.Match, b: vector.Match) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.file_id < b.file_id;
}

fn vectorMatchWorse(a: vector.Match, b: vector.Match) bool {
    return vectorMatchBetter(b, a);
}

fn vectorHeapSiftUp(heap: []vector.Match, start: usize) void {
    var child = start;
    while (child > 0) {
        const parent = (child - 1) / 2;
        if (!vectorMatchWorse(heap[child], heap[parent])) break;
        std.mem.swap(vector.Match, &heap[child], &heap[parent]);
        child = parent;
    }
}

fn vectorHeapSiftDown(heap: []vector.Match, start: usize) void {
    var parent = start;
    while (true) {
        const left = parent * 2 + 1;
        if (left >= heap.len) break;
        const right = left + 1;
        const worse_child = if (right < heap.len and vectorMatchWorse(heap[right], heap[left])) right else left;
        if (!vectorMatchWorse(heap[worse_child], heap[parent])) break;
        std.mem.swap(vector.Match, &heap[parent], &heap[worse_child]);
        parent = worse_child;
    }
}

pub fn candidatesForSemanticIds(allocator: std.mem.Allocator, ids: []const i32, model_id: i64, serial: u64) ![]Candidate {
    if (ids.len == 0) return allocator.alloc(Candidate, 0);
    lock();
    defer mutex.unlock();
    if (serial != connection_serial) return error.StaleSemanticSnapshot;
    var rows: std.ArrayList(Candidate) = .empty;
    errdefer rows.deinit(allocator);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "SELECT f.id,f.folder_id,f.path,f.name,f.duration_ms,f.content_hash,f.search_text,0.0 " ++
        "FROM files f JOIN semantic_state s ON s.singleton=1 AND s.active_model_id=? " ++
        "JOIN file_embeddings e ON e.file_id=f.id AND e.model_id=? AND e.source_content_hash=f.content_hash WHERE f.id IN (");
    for (ids, 0..) |_, index| {
        if (index > 0) try sql.append(allocator, ',');
        try sql.append(allocator, '?');
    }
    try sql.append(allocator, ')');
    const sql_z = try sql.toOwnedSliceSentinel(allocator, 0);
    defer allocator.free(sql_z);
    const stmt = try prepareLocked(sql_z.ptr);
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, model_id);
    try bindInt64(stmt, 2, model_id);
    for (ids, 0..) |id, index| try bindInt(stmt, @intCast(index + 3), id);
    while (true) {
        try query_cancel.check();
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        var row = Candidate{};
        row.file_id = c.sqlite3_column_int(stmt, 0);
        row.folder_id = c.sqlite3_column_int(stmt, 1);
        copyText(stmt, 2, &row.path);
        copyText(stmt, 3, &row.name);
        row.duration_ms = c.sqlite3_column_int(stmt, 4);
        row.content_hash = c.sqlite3_column_int64(stmt, 5);
        copyText(stmt, 6, &row.search_text);
        try rows.append(allocator, row);
    }
    return rows.toOwnedSlice(allocator);
}

pub const FingerprintBlob = struct {
    file_id: i32,
    source_content_hash: i64,
    landmarks: []u8,

    pub fn deinit(self: *FingerprintBlob, allocator: std.mem.Allocator) void {
        allocator.free(self.landmarks);
        self.* = undefined;
    }
};

pub const FingerprintStatus = struct {
    indexed: i64,
    pending: i64,
    failed: i64,
};

pub fn ensureFingerprintAlgorithm(algorithm_key: []const u8) !i64 {
    if (algorithm_key.len == 0 or algorithm_key.len > 256) return error.InvalidAlgorithmKey;
    lock();
    defer mutex.unlock();
    const insert = try prepareLocked("INSERT OR IGNORE INTO fingerprint_algorithms(algorithm_key) VALUES(?)");
    defer _ = c.sqlite3_finalize(insert);
    try bindText(insert, 1, algorithm_key);
    if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.InsertFailed;
    const lookup = try prepareLocked("SELECT id FROM fingerprint_algorithms WHERE algorithm_key=?");
    defer _ = c.sqlite3_finalize(lookup);
    try bindText(lookup, 1, algorithm_key);
    if (c.sqlite3_step(lookup) != c.SQLITE_ROW) return error.AlgorithmNotFound;
    return c.sqlite3_column_int64(lookup, 0);
}

pub fn pendingFingerprintFiles(allocator: std.mem.Allocator, algorithm_id: i64, folder_id: ?i32, limit: usize) ![]PendingSemanticFile {
    return pendingFingerprintFilesAfter(allocator, algorithm_id, folder_id, limit, 0);
}

pub fn pendingFingerprintFilesAfter(allocator: std.mem.Allocator, algorithm_id: i64, folder_id: ?i32, limit: usize, after_id: i32) ![]PendingSemanticFile {
    lock();
    defer mutex.unlock();
    if (limit == 0) return allocator.alloc(PendingSemanticFile, 0);
    const all_sql = "SELECT f.id,f.path,f.content_hash FROM pending_fingerprints p CROSS JOIN files f ON f.id=p.file_id WHERE p.algorithm_id=? AND p.file_id>? ORDER BY p.file_id LIMIT ?";
    const folder_sql = "SELECT f.id,f.path,f.content_hash FROM pending_fingerprints p INDEXED BY idx_pending_fingerprints_folder CROSS JOIN files f ON f.id=p.file_id WHERE p.algorithm_id=? AND p.folder_id=? AND p.file_id>? ORDER BY p.file_id LIMIT ?";
    const stmt = try prepareLocked(if (folder_id == null) all_sql else folder_sql);
    defer _ = c.sqlite3_finalize(stmt);
    defer if (builtin.is_test) {
        pending_query_steps[1] += @intCast(c.sqlite3_stmt_status(stmt, c.SQLITE_STMTSTATUS_VM_STEP, 0));
    };
    var index: c_int = 1;
    try bindInt64(stmt, index, algorithm_id);
    index += 1;
    if (folder_id) |folder| {
        try bindInt(stmt, index, folder);
        index += 1;
    }
    try bindInt(stmt, index, after_id);
    index += 1;
    try bindInt(stmt, index, @intCast(@min(limit, @as(usize, std.math.maxInt(i32)))));
    var files: std.ArrayList(PendingSemanticFile) = .empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const path = c.sqlite3_column_text(stmt, 1) orelse return error.InvalidStoredPath;
        const path_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        try files.append(allocator, .{
            .id = c.sqlite3_column_int(stmt, 0),
            .path = try allocator.dupe(u8, path[0..path_len]),
            .source_content_hash = c.sqlite3_column_int64(stmt, 2),
        });
    }
    return files.toOwnedSlice(allocator);
}

pub fn upsertFingerprint(algorithm_id: i64, file_id: i32, source_content_hash: i64, blob: []const u8, selectors_list: []const u32) !void {
    return publishFingerprint(algorithm_id, file_id, source_content_hash, blob, selectors_list, null);
}

/// Refinement commits the fingerprint, postings and verified edges together.
/// A failed/cancelled caller before this commit leaves the file pending.
pub fn upsertFingerprintWithEdges(algorithm_id: i64, file_id: i32, source_content_hash: i64, blob: []const u8, selectors_list: []const u32, edges: []const AcousticEdge) !void {
    return publishFingerprint(algorithm_id, file_id, source_content_hash, blob, selectors_list, edges);
}

fn publishFingerprint(algorithm_id: i64, file_id: i32, source_content_hash: i64, blob: []const u8, selectors_list: []const u32, edges: ?[]const AcousticEdge) !void {
    if (blob.len == 0 or selectors_list.len > fingerprint.SELECTOR_COUNT) return error.InvalidFingerprint;
    const decoded = try fingerprint.deserialize(std.heap.c_allocator, blob);
    defer std.heap.c_allocator.free(decoded);
    if (decoded.len == 0) return error.InvalidFingerprint;
    try query_cancel.check();
    lock();
    defer mutex.unlock();
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    const file = try prepareLocked("SELECT content_hash FROM files WHERE id=?");
    defer _ = c.sqlite3_finalize(file);
    try bindInt(file, 1, file_id);
    if (c.sqlite3_step(file) != c.SQLITE_ROW) return error.FileNotFound;
    if (c.sqlite3_column_int64(file, 0) != source_content_hash) return error.StaleContentHash;
    const clear_edges = try prepareLocked("DELETE FROM acoustic_edges WHERE algorithm_id=? AND (file_id_a=? OR file_id_b=?)");
    defer _ = c.sqlite3_finalize(clear_edges);
    try bindInt64(clear_edges, 1, algorithm_id);
    try bindInt(clear_edges, 2, file_id);
    try bindInt(clear_edges, 3, file_id);
    if (c.sqlite3_step(clear_edges) != c.SQLITE_DONE) return error.DeleteFailed;
    const clear_group = try prepareLocked("DELETE FROM acoustic_groups WHERE algorithm_id=? AND file_id=?");
    defer _ = c.sqlite3_finalize(clear_group);
    try bindInt64(clear_group, 1, algorithm_id);
    try bindInt(clear_group, 2, file_id);
    if (c.sqlite3_step(clear_group) != c.SQLITE_DONE) return error.DeleteFailed;
    const upsert = try prepareLocked("INSERT INTO file_fingerprints(algorithm_id,file_id,source_content_hash,token_count,landmarks,storage_version) VALUES(?,?,?,?,?,1) " ++
        "ON CONFLICT(algorithm_id,file_id) DO UPDATE SET source_content_hash=excluded.source_content_hash,token_count=excluded.token_count,landmarks=excluded.landmarks,storage_version=1");
    defer _ = c.sqlite3_finalize(upsert);
    try bindInt64(upsert, 1, algorithm_id);
    try bindInt(upsert, 2, file_id);
    try bindInt64(upsert, 3, source_content_hash);
    try bindInt(upsert, 4, @intCast(decoded.len));
    if (c.sqlite3_bind_blob(upsert, 5, blob.ptr, @intCast(blob.len), ws_sqlite_transient()) != c.SQLITE_OK) return error.BindFailed;
    if (c.sqlite3_step(upsert) != c.SQLITE_DONE) return error.InsertFailed;
    const dirty_group = try prepareLocked("INSERT INTO acoustic_group_state(algorithm_id,dirty) VALUES(?,1) ON CONFLICT(algorithm_id) DO UPDATE SET dirty=1");
    defer _ = c.sqlite3_finalize(dirty_group);
    try bindInt64(dirty_group, 1, algorithm_id);
    if (c.sqlite3_step(dirty_group) != c.SQLITE_DONE) return error.InsertFailed;
    const singleton_group = try prepareLocked("INSERT INTO acoustic_groups(algorithm_id,file_id,group_id,member_count,confidence_ppm) VALUES(?,?,?,1,0)");
    defer _ = c.sqlite3_finalize(singleton_group);
    try bindInt64(singleton_group, 1, algorithm_id);
    try bindInt(singleton_group, 2, file_id);
    try bindInt(singleton_group, 3, file_id);
    if (c.sqlite3_step(singleton_group) != c.SQLITE_DONE) return error.InsertFailed;
    const clear_postings = try prepareLocked("DELETE FROM fingerprint_postings WHERE algorithm_id=? AND file_id=?");
    defer _ = c.sqlite3_finalize(clear_postings);
    try bindInt64(clear_postings, 1, algorithm_id);
    try bindInt(clear_postings, 2, file_id);
    if (c.sqlite3_step(clear_postings) != c.SQLITE_DONE) return error.DeleteFailed;
    const posting = try prepareLocked("INSERT INTO fingerprint_postings(algorithm_id,token_hash,file_id) VALUES(?,?,?)");
    defer _ = c.sqlite3_finalize(posting);
    for (selectors_list) |token_hash| {
        _ = c.sqlite3_reset(posting);
        _ = c.sqlite3_clear_bindings(posting);
        try bindInt64(posting, 1, algorithm_id);
        try bindInt64(posting, 2, token_hash);
        try bindInt(posting, 3, file_id);
        if (c.sqlite3_step(posting) != c.SQLITE_DONE) return error.InsertFailed;
    }
    const clear_failure = try prepareLocked("DELETE FROM fingerprint_failures WHERE algorithm_id=? AND file_id=?");
    defer _ = c.sqlite3_finalize(clear_failure);
    try bindInt64(clear_failure, 1, algorithm_id);
    try bindInt(clear_failure, 2, file_id);
    if (c.sqlite3_step(clear_failure) != c.SQLITE_DONE) return error.DeleteFailed;
    if (edges) |verified| try replaceAcousticEdgesLocked(algorithm_id, file_id, verified);
    try execLocked("COMMIT;");
}

pub fn recordFingerprintFailure(algorithm_id: i64, file_id: i32, source_content_hash: i64, code: []const u8, detail: []const u8) !void {
    if (code.len == 0 or code.len > 128 or detail.len > 4096) return error.InvalidFailureDetail;
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("INSERT INTO fingerprint_failures(algorithm_id,file_id,source_content_hash,error_code,detail) SELECT ?1,?2,?3,?4,?5 WHERE EXISTS(SELECT 1 FROM files WHERE id=?2 AND content_hash=?3) AND NOT EXISTS(SELECT 1 FROM file_fingerprints WHERE algorithm_id=?1 AND file_id=?2 AND source_content_hash=?3) " ++
        "ON CONFLICT(algorithm_id,file_id) DO UPDATE SET source_content_hash=excluded.source_content_hash,error_code=excluded.error_code,detail=excluded.detail");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, algorithm_id);
    try bindInt(stmt, 2, file_id);
    try bindInt64(stmt, 3, source_content_hash);
    try bindText(stmt, 4, code);
    try bindText(stmt, 5, detail);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
}

pub fn loadFingerprint(allocator: std.mem.Allocator, algorithm_id: i64, file_id: i32) !?FingerprintBlob {
    const rows = try loadFingerprintBatch(allocator, algorithm_id, &.{file_id});
    defer allocator.free(rows);
    return if (rows.len == 0) null else rows[0];
}

// At most eight validated blobs (<6.4 MB), one prepared statement/lock per batch.
pub fn loadFingerprintBatch(allocator: std.mem.Allocator, algorithm_id: i64, ids: []const i32) ![]FingerprintBlob {
    if (ids.len > 8) return error.FingerprintBatchTooLarge;
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT p.source_content_hash,p.landmarks FROM file_fingerprints p JOIN files f ON f.id=p.file_id AND f.content_hash=p.source_content_hash WHERE p.algorithm_id=? AND p.file_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, algorithm_id);
    var rows: std.ArrayList(FingerprintBlob) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }
    for (ids) |id| {
        try query_cancel.check();
        _ = c.sqlite3_reset(stmt);
        try bindInt(stmt, 2, id);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) continue;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const raw = c.sqlite3_column_blob(stmt, 1) orelse return error.InvalidFingerprintBlob;
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        if (len == 0 or len > fingerprint.MAX_LANDMARKS * 11 + 32) return error.InvalidFingerprintBlob;
        const blob = try allocator.dupe(u8, @as([*]const u8, @ptrCast(raw))[0..len]);
        errdefer allocator.free(blob);
        try rows.append(allocator, .{ .file_id = id, .source_content_hash = c.sqlite3_column_int64(stmt, 0), .landmarks = blob });
    }
    return rows.toOwnedSlice(allocator);
}

const FINGERPRINT_NEIGHBOR_SLOTS: usize = 27;
const FINGERPRINT_NEIGHBOR_PLACEHOLDERS = "?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?";

fn bindFingerprintNeighborhood(stmt: *c.sqlite3_stmt, algorithm_id: i64, neighborhood: []const u32) !c_int {
    if (neighborhood.len > FINGERPRINT_NEIGHBOR_SLOTS) return error.InvalidFingerprintNeighborhood;
    try bindInt64(stmt, 1, algorithm_id);
    for (0..FINGERPRINT_NEIGHBOR_SLOTS) |index| {
        const parameter: c_int = @intCast(index + 2);
        if (index < neighborhood.len) {
            try bindInt64(stmt, parameter, neighborhood[index]);
        } else if (c.sqlite3_bind_null(stmt, parameter) != c.SQLITE_OK) return error.BindFailed;
    }
    return @intCast(FINGERPRINT_NEIGHBOR_SLOTS + 2);
}

pub const FINGERPRINT_POSTING_BUDGET: usize = 32768;
pub const FINGERPRINT_CANDIDATE_BUDGET: usize = 8192;
pub const FingerprintCandidateStats = struct { postings_read: usize = 0, peak_candidates: usize = 0, capped: bool = false };

pub fn fingerprintCandidateIds(allocator: std.mem.Allocator, algorithm_id: i64, selector_list: []const u32, folder_id: ?i32, limit: usize) ![]i32 {
    var stats = FingerprintCandidateStats{};
    return fingerprintCandidateIdsWithStats(allocator, algorithm_id, selector_list, folder_id, limit, &stats);
}

pub fn fingerprintCandidateIdsWithStats(allocator: std.mem.Allocator, algorithm_id: i64, selector_list: []const u32, folder_id: ?i32, limit: usize, stats: *FingerprintCandidateStats) ![]i32 {
    stats.* = .{};
    if (selector_list.len > fingerprint.SELECTOR_COUNT) return error.InvalidFingerprint;
    if (limit == 0 or selector_list.len == 0) return allocator.alloc(i32, 0);
    lock();
    defer mutex.unlock();
    const Probe = struct { hash: u32, df: u64 };
    const Selector = struct { hash: u32, df: u64 = 0, max_df: u64 = 0, probes: [27]Probe = undefined, count: usize = 0 };
    var selectors: [fingerprint.SELECTOR_COUNT]Selector = undefined;
    var selector_count: usize = 0;
    const frequencies = try prepareLocked("SELECT token_hash,document_count FROM fingerprint_df WHERE algorithm_id=? AND token_hash IN (" ++ FINGERPRINT_NEIGHBOR_PLACEHOLDERS ++ ")");
    defer _ = c.sqlite3_finalize(frequencies);
    for (selector_list) |hash| {
        try query_cancel.check();
        var duplicate = false;
        for (selectors[0..selector_count]) |s| if (s.hash == hash) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        var selector = Selector{ .hash = hash };
        var neighbors: [27]u32 = undefined;
        _ = c.sqlite3_reset(frequencies);
        _ = try bindFingerprintNeighborhood(frequencies, algorithm_id, fingerprint.neighborHashes(hash, &neighbors));
        while (true) {
            const rc = c.sqlite3_step(frequencies);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            const df: u64 = @intCast(@max(0, c.sqlite3_column_int64(frequencies, 1)));
            selector.probes[selector.count] = .{ .hash = @intCast(c.sqlite3_column_int64(frequencies, 0)), .df = df };
            selector.count += 1;
            selector.df +|= df;
            selector.max_df = @max(selector.max_df, df);
        }
        if (selector.count == 0) continue;
        std.mem.sort(Probe, selector.probes[0..selector.count], {}, struct {
            fn less(_: void, a: Probe, b: Probe) bool {
                return if (a.df == b.df) a.hash < b.hash else a.df < b.df;
            }
        }.less);
        selectors[selector_count] = selector;
        selector_count += 1;
    }
    std.mem.sort(Selector, selectors[0..selector_count], {}, struct {
        fn less(_: void, a: Selector, b: Selector) bool {
            return if (a.df == b.df) a.hash < b.hash else a.df < b.df;
        }
    }.less);
    const total = try prepareLocked("SELECT document_count FROM fingerprint_algorithms WHERE id=?");
    defer _ = c.sqlite3_finalize(total);
    try bindInt64(total, 1, algorithm_id);
    if (c.sqlite3_step(total) != c.SQLITE_ROW) return error.StepFailed;
    const documents: u64 = @intCast(@max(0, c.sqlite3_column_int64(total, 0)));
    const max_df = @max(@as(u64, 32), documents / 20);
    const postings = try prepareLocked("SELECT p.file_id,f.folder_id FROM fingerprint_postings p CROSS JOIN files f ON f.id=p.file_id WHERE p.algorithm_id=? AND p.token_hash=? ORDER BY p.file_id LIMIT ?");
    defer _ = c.sqlite3_finalize(postings);
    var scores = std.AutoHashMap(i32, u64).init(allocator);
    defer scores.deinit();
    var visited = std.AutoHashMap(i32, void).init(allocator);
    defer visited.deinit();
    // ponytail: rare-first approximate candidates, hard 32K posting / 8K ID
    // ceilings. Increase only with measured acoustic recall; verification stays exact.
    for (0..2) |pass| {
        if (pass == 1 and scores.count() > 0) break;
        for (selectors[0..selector_count], 0..) |selector, index| {
            if (stats.postings_read == FINGERPRINT_POSTING_BUDGET) {
                stats.capped = true;
                break;
            }
            if (pass == 0 and documents >= 640 and selector.max_df > max_df) continue;
            if (pass == 1 and index >= 8) break;
            visited.clearRetainingCapacity();
            const weight = if (pass == 1) 1 else @as(u64, 1000000) / @max(@as(u64, 1), selector.df);
            for (selector.probes[0..selector.count]) |probe| {
                const remaining = FINGERPRINT_POSTING_BUDGET - stats.postings_read;
                if (remaining == 0) break;
                _ = c.sqlite3_reset(postings);
                try bindInt64(postings, 1, algorithm_id);
                try bindInt64(postings, 2, probe.hash);
                try bindInt64(postings, 3, @intCast(remaining));
                while (true) {
                    try query_cancel.check();
                    const rc = c.sqlite3_step(postings);
                    if (rc == c.SQLITE_DONE) break;
                    if (rc != c.SQLITE_ROW) return error.StepFailed;
                    stats.postings_read += 1;
                    if (folder_id) |folder| if (c.sqlite3_column_int(postings, 1) != folder) continue;
                    const id = c.sqlite3_column_int(postings, 0);
                    if (visited.contains(id)) continue;
                    if (!scores.contains(id) and scores.count() == FINGERPRINT_CANDIDATE_BUDGET) {
                        stats.capped = true;
                        continue;
                    }
                    try visited.put(id, {});
                    const score = try scores.getOrPut(id);
                    if (!score.found_existing) score.value_ptr.* = 0;
                    score.value_ptr.* +|= weight;
                }
            }
        }
    }
    stats.capped = stats.capped or stats.postings_read == FINGERPRINT_POSTING_BUDGET;
    stats.peak_candidates = scores.count();
    const Ranked = struct {
        id: i32,
        score: u64,
        fn order(_: void, a: @This(), b: @This()) std.math.Order {
            return if (a.score == b.score) std.math.order(b.id, a.id) else std.math.order(a.score, b.score);
        }
    };
    var heap = std.PriorityQueue(Ranked, void, Ranked.order).initContext({});
    defer heap.deinit(allocator);
    var iterator = scores.iterator();
    while (iterator.next()) |entry| {
        try query_cancel.check();
        const item = Ranked{ .id = entry.key_ptr.*, .score = entry.value_ptr.* };
        if (heap.count() < limit) {
            try heap.push(allocator, item);
        } else if (Ranked.order({}, item, heap.peek().?) == .gt) {
            _ = heap.pop();
            try heap.push(allocator, item);
        }
    }
    const ids = try allocator.alloc(i32, heap.count());
    var index = ids.len;
    while (heap.pop()) |item| {
        index -= 1;
        ids[index] = item.id;
    }
    return ids;
}

pub const AcousticEdge = struct {
    other_file_id: i32,
    score_ppm: u32,
    aligned: u32,
};

pub const AcousticGroupInfo = struct {
    group_id: i64,
    member_count: u32,
    confidence_ppm: u32,
};

pub fn replaceAcousticEdges(algorithm_id: i64, file_id: i32, edges: []const AcousticEdge) !void {
    lock();
    defer mutex.unlock();
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    try replaceAcousticEdgesLocked(algorithm_id, file_id, edges);
    try execLocked("COMMIT;");
}

fn replaceAcousticEdgesLocked(algorithm_id: i64, file_id: i32, edges: []const AcousticEdge) !void {
    const clear = try prepareLocked("DELETE FROM acoustic_edges WHERE algorithm_id=? AND (file_id_a=? OR file_id_b=?)");
    defer _ = c.sqlite3_finalize(clear);
    try bindInt64(clear, 1, algorithm_id);
    try bindInt(clear, 2, file_id);
    try bindInt(clear, 3, file_id);
    if (c.sqlite3_step(clear) != c.SQLITE_DONE) return error.DeleteFailed;
    const insert = try prepareLocked("INSERT OR REPLACE INTO acoustic_edges(algorithm_id,file_id_a,file_id_b,score_ppm,aligned) VALUES(?,?,?,?,?)");
    defer _ = c.sqlite3_finalize(insert);
    for (edges) |edge| {
        if (edge.other_file_id == file_id) continue;
        const a = @min(file_id, edge.other_file_id);
        const b = @max(file_id, edge.other_file_id);
        _ = c.sqlite3_reset(insert);
        _ = c.sqlite3_clear_bindings(insert);
        try bindInt64(insert, 1, algorithm_id);
        try bindInt(insert, 2, a);
        try bindInt(insert, 3, b);
        try bindInt64(insert, 4, edge.score_ppm);
        try bindInt64(insert, 5, edge.aligned);
        if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.InsertFailed;
    }
}

pub fn rebuildAcousticGroups(allocator: std.mem.Allocator, algorithm_id: i64) !void {
    lock();
    defer mutex.unlock();
    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(allocator);
    const files_stmt = try prepareLocked("SELECT p.file_id FROM file_fingerprints p JOIN files f ON f.id=p.file_id AND f.content_hash=p.source_content_hash WHERE p.algorithm_id=? ORDER BY p.file_id");
    defer _ = c.sqlite3_finalize(files_stmt);
    try bindInt64(files_stmt, 1, algorithm_id);
    while (true) {
        const rc = c.sqlite3_step(files_stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        try ids.append(allocator, c.sqlite3_column_int(files_stmt, 0));
    }
    var by_id = std.AutoHashMap(i32, usize).init(allocator);
    defer by_id.deinit();
    const parents = try allocator.alloc(usize, ids.items.len);
    defer allocator.free(parents);
    for (ids.items, parents, 0..) |id, *parent, index| {
        parent.* = index;
        try by_id.put(id, index);
    }
    const edges_stmt = try prepareLocked("SELECT file_id_a,file_id_b,score_ppm FROM acoustic_edges WHERE algorithm_id=? ORDER BY file_id_a,file_id_b");
    defer _ = c.sqlite3_finalize(edges_stmt);
    try bindInt64(edges_stmt, 1, algorithm_id);
    while (true) {
        const rc = c.sqlite3_step(edges_stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const a = by_id.get(c.sqlite3_column_int(edges_stmt, 0)) orelse continue;
        const b = by_id.get(c.sqlite3_column_int(edges_stmt, 1)) orelse continue;
        unionAcoustic(parents, ids.items, a, b);
    }
    const counts = try allocator.alloc(u32, ids.items.len);
    defer allocator.free(counts);
    const confidence = try allocator.alloc(u32, ids.items.len);
    defer allocator.free(confidence);
    @memset(counts, 0);
    @memset(confidence, 0);
    for (0..ids.items.len) |index| counts[findAcousticRoot(parents, index)] += 1;
    _ = c.sqlite3_reset(edges_stmt);
    _ = c.sqlite3_clear_bindings(edges_stmt);
    try bindInt64(edges_stmt, 1, algorithm_id);
    while (true) {
        const rc = c.sqlite3_step(edges_stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const a = by_id.get(c.sqlite3_column_int(edges_stmt, 0)) orelse continue;
        const root = findAcousticRoot(parents, a);
        const edge_score: u32 = @intCast(c.sqlite3_column_int64(edges_stmt, 2));
        confidence[root] = if (confidence[root] == 0) edge_score else @min(confidence[root], edge_score);
    }
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    const clear_groups = try prepareLocked("DELETE FROM acoustic_groups WHERE algorithm_id=?");
    defer _ = c.sqlite3_finalize(clear_groups);
    try bindInt64(clear_groups, 1, algorithm_id);
    if (c.sqlite3_step(clear_groups) != c.SQLITE_DONE) return error.DeleteFailed;
    const insert_group = try prepareLocked("INSERT INTO acoustic_groups(algorithm_id,file_id,group_id,member_count,confidence_ppm) VALUES(?,?,?,?,?)");
    defer _ = c.sqlite3_finalize(insert_group);
    for (ids.items, 0..) |id, index| {
        const root = findAcousticRoot(parents, index);
        _ = c.sqlite3_reset(insert_group);
        _ = c.sqlite3_clear_bindings(insert_group);
        try bindInt64(insert_group, 1, algorithm_id);
        try bindInt(insert_group, 2, id);
        try bindInt(insert_group, 3, ids.items[root]);
        try bindInt64(insert_group, 4, counts[root]);
        try bindInt64(insert_group, 5, confidence[root]);
        if (c.sqlite3_step(insert_group) != c.SQLITE_DONE) return error.InsertFailed;
    }
    const clean_state = try prepareLocked("INSERT INTO acoustic_group_state(algorithm_id,dirty) VALUES(?,0) ON CONFLICT(algorithm_id) DO UPDATE SET dirty=0");
    defer _ = c.sqlite3_finalize(clean_state);
    try bindInt64(clean_state, 1, algorithm_id);
    if (c.sqlite3_step(clean_state) != c.SQLITE_DONE) return error.UpdateFailed;
    try execLocked("COMMIT;");
    if (builtin.is_test) acoustic_group_rebuild_serial +%= 1;
}

pub fn acousticGroupRebuildSerialForTests() u64 {
    lock();
    defer mutex.unlock();
    return acoustic_group_rebuild_serial;
}

fn findAcousticRoot(parents: []usize, start: usize) usize {
    var current = start;
    while (parents[current] != current) current = parents[current];
    var compress = start;
    while (parents[compress] != compress) {
        const next = parents[compress];
        parents[compress] = current;
        compress = next;
    }
    return current;
}

fn unionAcoustic(parents: []usize, ids: []const i32, a: usize, b: usize) void {
    const root_a = findAcousticRoot(parents, a);
    const root_b = findAcousticRoot(parents, b);
    if (root_a == root_b) return;
    if (ids[root_a] < ids[root_b]) parents[root_b] = root_a else parents[root_a] = root_b;
}

pub fn acousticGroupsDirty(algorithm_id: i64) !bool {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT dirty FROM acoustic_group_state WHERE algorithm_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, algorithm_id);
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return false;
    if (rc != c.SQLITE_ROW) return error.StepFailed;
    return c.sqlite3_column_int(stmt, 0) != 0;
}

pub fn acousticGroupInfo(algorithm_id: i64, file_id: i32) !?AcousticGroupInfo {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT g.group_id,g.member_count,g.confidence_ppm FROM acoustic_groups g JOIN acoustic_group_state s ON s.algorithm_id=g.algorithm_id AND s.dirty=0 WHERE g.algorithm_id=? AND g.file_id=?");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, algorithm_id);
    try bindInt(stmt, 2, file_id);
    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return null;
    if (rc != c.SQLITE_ROW) return error.StepFailed;
    return .{ .group_id = c.sqlite3_column_int64(stmt, 0), .member_count = @intCast(c.sqlite3_column_int64(stmt, 1)), .confidence_ppm = @intCast(c.sqlite3_column_int64(stmt, 2)) };
}

pub fn candidatesForIds(allocator: std.mem.Allocator, ids: []const i32) ![]Candidate {
    lock();
    defer mutex.unlock();
    var rows: std.ArrayList(Candidate) = .empty;
    errdefer rows.deinit(allocator);
    const stmt = try prepareLocked("SELECT id,folder_id,path,name,duration_ms,content_hash,search_text,0.0 FROM files WHERE id=?");
    defer _ = c.sqlite3_finalize(stmt);
    for (ids) |id| {
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        try bindInt(stmt, 1, id);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) continue;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        var row = Candidate{};
        row.file_id = c.sqlite3_column_int(stmt, 0);
        row.folder_id = c.sqlite3_column_int(stmt, 1);
        copyText(stmt, 2, &row.path);
        copyText(stmt, 3, &row.name);
        row.duration_ms = c.sqlite3_column_int(stmt, 4);
        row.content_hash = c.sqlite3_column_int64(stmt, 5);
        copyText(stmt, 6, &row.search_text);
        try rows.append(allocator, row);
    }
    return rows.toOwnedSlice(allocator);
}

pub fn fingerprintStatus(algorithm_id: i64) !FingerprintStatus {
    lock();
    defer mutex.unlock();
    const stmt = try prepareLocked("SELECT a.document_count,a.failed_count,c.file_count FROM fingerprint_algorithms a CROSS JOIN catalog_stats c WHERE a.id=? AND c.singleton=1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindInt64(stmt, 1, algorithm_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    const indexed = c.sqlite3_column_int64(stmt, 0);
    const failed = c.sqlite3_column_int64(stmt, 1);
    return .{ .indexed = indexed, .failed = failed, .pending = c.sqlite3_column_int64(stmt, 2) - indexed - failed };
}

pub const IntegrityReport = struct {
    checks_run: u32 = 0,
    errors_found: u32 = 0,
};

pub fn integrityCheck(full: bool) !IntegrityReport {
    lock();
    defer mutex.unlock();
    var report = IntegrityReport{};
    const pragma: [*:0]const u8 = if (full) "PRAGMA integrity_check" else "PRAGMA quick_check";
    const stmt = try prepareLocked(pragma);
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.IntegrityCheckFailed;
        report.checks_run += 1;
        const text = c.sqlite3_column_text(stmt, 0) orelse {
            report.errors_found += 1;
            continue;
        };
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (!std.mem.eql(u8, text[0..len], "ok")) report.errors_found += 1;
    }
    const stats = try prepareLocked(optimization_schema.check);
    defer _ = c.sqlite3_finalize(stats);
    if (c.sqlite3_step(stats) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
    report.errors_found += @intCast(c.sqlite3_column_int(stats, 0));
    report.checks_run += 1;
    const foreign_keys = try prepareLocked("PRAGMA foreign_key_check");
    defer _ = c.sqlite3_finalize(foreign_keys);
    while (true) {
        const rc = c.sqlite3_step(foreign_keys);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.IntegrityCheckFailed;
        report.checks_run += 1;
        report.errors_found += 1;
    }
    report.checks_run += 4;
    const vector_check = try prepareLocked("SELECT COUNT(*) FROM file_embeddings e JOIN embedding_models m ON m.id=e.model_id WHERE length(e.vector)!=m.dimension*4");
    defer _ = c.sqlite3_finalize(vector_check);
    if (c.sqlite3_step(vector_check) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
    report.errors_found += @intCast(@min(c.sqlite3_column_int64(vector_check, 0), std.math.maxInt(u32)));
    report.errors_found += try storedFingerprintErrorsOn(try handleLocked());
    const identities = try prepareLocked(storage_schema.check);
    defer _ = c.sqlite3_finalize(identities);
    if (c.sqlite3_step(identities) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
    report.errors_found += @intCast(c.sqlite3_column_int64(identities, 0));
    const fts_count = try prepareLocked("SELECT (SELECT COUNT(*) FROM files)!=(SELECT COUNT(*) FROM files_fts)");
    defer _ = c.sqlite3_finalize(fts_count);
    if (c.sqlite3_step(fts_count) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
    report.errors_found += @intCast(c.sqlite3_column_int(fts_count, 0));
    const trigram_count = try prepareLocked("SELECT (SELECT COUNT(*) FROM files)!=(SELECT COUNT(*) FROM files_trigram)");
    defer _ = c.sqlite3_finalize(trigram_count);
    if (c.sqlite3_step(trigram_count) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
    report.errors_found += @intCast(c.sqlite3_column_int(trigram_count, 0));
    report.checks_run += 3;
    const waveform_rows = try prepareLocked("SELECT COUNT(*) FROM waveform_tiers w JOIN files f ON f.id=w.file_id WHERE w.source_content_hash!=f.content_hash OR w.source_file_size!=f.file_size OR w.source_mtime_ns!=f.mtime_ns OR w.universal_bytes!=length(w.universal_blob) OR (w.detailed_blob IS NULL)!=(w.detailed_bytes=0) OR (w.detailed_blob IS NOT NULL AND w.detailed_bytes!=length(w.detailed_blob))");
    defer _ = c.sqlite3_finalize(waveform_rows);
    if (c.sqlite3_step(waveform_rows) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
    report.errors_found += @intCast(@min(c.sqlite3_column_int64(waveform_rows, 0), std.math.maxInt(u32)));
    const waveform_budget = try prepareLocked("SELECT (SELECT COALESCE(SUM(detailed_bytes),0) FROM waveform_tiers)>detailed_budget_bytes FROM waveform_cache_state WHERE singleton=1");
    defer _ = c.sqlite3_finalize(waveform_budget);
    if (c.sqlite3_step(waveform_budget) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
    report.errors_found += @intCast(c.sqlite3_column_int(waveform_budget, 0));
    const waveform_claim = try prepareLocked("SELECT NOT((waveform_claimed_file_id=0 AND waveform_claim_token=0 AND waveform_claim_until_ns=0) OR (waveform_claimed_file_id>0 AND waveform_claim_token!=0 AND waveform_claim_until_ns>0 AND EXISTS(SELECT 1 FROM files WHERE id=waveform_claimed_file_id) AND NOT EXISTS(SELECT 1 FROM waveform_tiers WHERE file_id=waveform_claimed_file_id))) FROM waveform_cache_state WHERE singleton=1");
    defer _ = c.sqlite3_finalize(waveform_claim);
    if (c.sqlite3_step(waveform_claim) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
    report.errors_found += @intCast(c.sqlite3_column_int(waveform_claim, 0));
    if (full) {
        const queues = try prepareLocked(refinement_schema.check);
        defer _ = c.sqlite3_finalize(queues);
        if (c.sqlite3_step(queues) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
        report.errors_found += @intCast(c.sqlite3_column_int(queues, 0));
        report.checks_run += 1;
        report.checks_run += 2;
        execLocked("INSERT INTO files_fts(files_fts,rank) VALUES('integrity-check',1);") catch {
            report.errors_found += 1;
        };
        execLocked("INSERT INTO files_trigram(files_trigram,rank) VALUES('integrity-check',1);") catch {
            report.errors_found += 1;
        };

        const vectors = try prepareLocked("SELECT m.dimension,e.vector FROM file_embeddings e JOIN embedding_models m ON m.id=e.model_id");
        defer _ = c.sqlite3_finalize(vectors);
        while (true) {
            const rc = c.sqlite3_step(vectors);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.IntegrityCheckFailed;
            report.checks_run += 1;
            const dimension_raw = c.sqlite3_column_int64(vectors, 0);
            const blob = c.sqlite3_column_blob(vectors, 1);
            if (dimension_raw <= 0 or dimension_raw > vector.MAX_DIMENSION or blob == null) {
                report.errors_found += 1;
                continue;
            }
            const dimension: usize = @intCast(dimension_raw);
            const decoded = std.heap.c_allocator.alloc(f32, dimension) catch return error.OutOfMemory;
            defer std.heap.c_allocator.free(decoded);
            const byte_len: usize = @intCast(c.sqlite3_column_bytes(vectors, 1));
            vector.decodeNormalizedInto(@as([*]const u8, @ptrCast(blob.?))[0..byte_len], decoded) catch {
                report.errors_found += 1;
            };
        }

        const fingerprints = try prepareLocked("SELECT algorithm_id,file_id,landmarks FROM file_fingerprints");
        defer _ = c.sqlite3_finalize(fingerprints);
        const posting_rows = try prepareLocked("SELECT token_hash FROM fingerprint_postings WHERE algorithm_id=? AND file_id=? ORDER BY token_hash");
        defer _ = c.sqlite3_finalize(posting_rows);
        while (true) {
            const rc = c.sqlite3_step(fingerprints);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.IntegrityCheckFailed;
            report.checks_run += 1;
            const blob = c.sqlite3_column_blob(fingerprints, 2) orelse {
                report.errors_found += 1;
                continue;
            };
            const byte_len: usize = @intCast(c.sqlite3_column_bytes(fingerprints, 2));
            const landmarks = fingerprint.deserialize(std.heap.c_allocator, @as([*]const u8, @ptrCast(blob))[0..byte_len]) catch {
                report.errors_found += 1;
                continue;
            };
            defer std.heap.c_allocator.free(landmarks);
            const expected = fingerprint.selectors(std.heap.c_allocator, landmarks) catch return error.OutOfMemory;
            defer std.heap.c_allocator.free(expected);
            std.mem.sort(u32, expected, {}, std.sort.asc(u32));
            _ = c.sqlite3_reset(posting_rows);
            _ = c.sqlite3_clear_bindings(posting_rows);
            try bindInt64(posting_rows, 1, c.sqlite3_column_int64(fingerprints, 0));
            try bindInt(posting_rows, 2, c.sqlite3_column_int(fingerprints, 1));
            var posting_index: usize = 0;
            var posting_mismatch = false;
            while (true) {
                const posting_rc = c.sqlite3_step(posting_rows);
                if (posting_rc == c.SQLITE_DONE) break;
                if (posting_rc != c.SQLITE_ROW) return error.IntegrityCheckFailed;
                const stored_hash = c.sqlite3_column_int64(posting_rows, 0);
                if (posting_index >= expected.len or stored_hash != expected[posting_index]) posting_mismatch = true;
                posting_index += 1;
            }
            if (posting_mismatch or posting_index != expected.len) report.errors_found += 1;
        }
        report.checks_run += 4;
        const missing_groups = try prepareLocked("SELECT COUNT(*) FROM file_fingerprints p LEFT JOIN acoustic_groups g ON g.algorithm_id=p.algorithm_id AND g.file_id=p.file_id WHERE g.file_id IS NULL");
        defer _ = c.sqlite3_finalize(missing_groups);
        if (c.sqlite3_step(missing_groups) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
        report.errors_found += @intCast(@min(c.sqlite3_column_int64(missing_groups, 0), std.math.maxInt(u32)));
        const malformed_groups = try prepareLocked("SELECT COUNT(*) FROM acoustic_groups g WHERE g.group_id!=(SELECT MIN(x.file_id) FROM acoustic_groups x WHERE x.algorithm_id=g.algorithm_id AND x.group_id=g.group_id) OR g.member_count!=(SELECT COUNT(*) FROM acoustic_groups x WHERE x.algorithm_id=g.algorithm_id AND x.group_id=g.group_id)");
        defer _ = c.sqlite3_finalize(malformed_groups);
        if (c.sqlite3_step(malformed_groups) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
        report.errors_found += @intCast(@min(c.sqlite3_column_int64(malformed_groups, 0), std.math.maxInt(u32)));
        const crossing_edges = try prepareLocked("SELECT COUNT(*) FROM acoustic_edges e JOIN acoustic_groups a ON a.algorithm_id=e.algorithm_id AND a.file_id=e.file_id_a JOIN acoustic_groups b ON b.algorithm_id=e.algorithm_id AND b.file_id=e.file_id_b WHERE a.group_id!=b.group_id");
        defer _ = c.sqlite3_finalize(crossing_edges);
        if (c.sqlite3_step(crossing_edges) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
        report.errors_found += @intCast(@min(c.sqlite3_column_int64(crossing_edges, 0), std.math.maxInt(u32)));
        const dirty_groups = try prepareLocked("SELECT COUNT(*) FROM acoustic_group_state WHERE dirty!=0");
        defer _ = c.sqlite3_finalize(dirty_groups);
        if (c.sqlite3_step(dirty_groups) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
        report.errors_found += @intCast(@min(c.sqlite3_column_int64(dirty_groups, 0), std.math.maxInt(u32)));
    }
    return report;
}

fn pathEqualsBaseSuffix(path: []const u8, base: []const u8, suffix: []const u8) bool {
    return path.len == base.len + suffix.len and std.mem.eql(u8, path[0..base.len], base) and std.mem.eql(u8, path[base.len..], suffix);
}

pub fn backupTo(path: []const u8) !void {
    lock();
    defer mutex.unlock();
    const live = try handleLocked();
    const live_name_ptr = c.sqlite3_db_filename(live, "main") orelse return error.BackupPathUnavailable;
    const live_name = std.mem.span(live_name_ptr);
    const resolved_path = try std.fs.path.resolve(std.heap.c_allocator, &.{path});
    defer std.heap.c_allocator.free(resolved_path);
    const resolved_live = try std.fs.path.resolve(std.heap.c_allocator, &.{live_name});
    defer std.heap.c_allocator.free(resolved_live);
    if (std.mem.eql(u8, resolved_path, resolved_live) or pathEqualsBaseSuffix(resolved_path, resolved_live, "-wal") or pathEqualsBaseSuffix(resolved_path, resolved_live, "-shm") or pathEqualsBaseSuffix(resolved_path, resolved_live, ".tmp") or pathEqualsBaseSuffix(resolved_path, resolved_live, ".restore.tmp")) return error.UnsafeBackupDestination;
    const path_z = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
    defer std.heap.c_allocator.free(path_z);
    const temporary = try std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}.tmp", .{path}, 0);
    defer std.heap.c_allocator.free(temporary);
    _ = c.remove(temporary.ptr);
    var destination: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(temporary.ptr, &destination, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) {
        if (destination) |handle| _ = c.sqlite3_close_v2(handle);
        return error.BackupOpenFailed;
    }
    const backup = c.sqlite3_backup_init(destination, "main", try handleLocked(), "main") orelse {
        _ = c.sqlite3_close_v2(destination);
        return error.BackupInitFailed;
    };
    const step = c.sqlite3_backup_step(backup, -1);
    const finish = c.sqlite3_backup_finish(backup);
    const close_result = c.sqlite3_close_v2(destination);
    if (step != c.SQLITE_DONE or finish != c.SQLITE_OK or close_result != c.SQLITE_OK) {
        _ = c.remove(temporary.ptr);
        return error.BackupFailed;
    }
    if (c.rename(temporary.ptr, path_z.ptr) != 0) {
        _ = c.remove(temporary.ptr);
        return error.BackupRenameFailed;
    }
}

fn validateIdentityRowsOn(handle: *c.sqlite3) !void {
    const stmt = try prepareOn(handle, storage_schema.check);
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW or c.sqlite3_column_int64(stmt, 0) != 0) return error.InvalidBackupSchema;
}

fn validateStoredFingerprintsOn(handle: *c.sqlite3) !void {
    if (try storedFingerprintErrorsOn(handle) != 0) return error.InvalidFingerprintBlob;
}

fn storedFingerprintErrorsOn(handle: *c.sqlite3) !u32 {
    const stmt = try prepareOn(handle, "SELECT token_count,landmarks FROM file_fingerprints");
    defer _ = c.sqlite3_finalize(stmt);
    var errors: u32 = 0;
    while (true) {
        try query_cancel.check();
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const ptr = c.sqlite3_column_blob(stmt, 1) orelse {
            errors += 1;
            continue;
        };
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        const decoded = fingerprint.deserialize(std.heap.c_allocator, @as([*]const u8, @ptrCast(ptr))[0..len]) catch |err| {
            if (err == error.OutOfMemory or err == error.Cancelled) return err;
            errors += 1;
            continue;
        };
        defer std.heap.c_allocator.free(decoded);
        if (decoded.len == 0 or decoded.len != c.sqlite3_column_int64(stmt, 0)) errors += 1;
    }
    return errors;
}

fn validateRestoreSchema(handle: *c.sqlite3, version: i32, canonical: bool) !void {
    const table_sql: [*:0]const u8 = switch (version) {
        3 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='files'",
        4 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','files_fts','files_trigram')",
        5 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','files_fts','files_trigram','embedding_models','file_embeddings','semantic_state')",
        6 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','files_fts','files_trigram','embedding_models','file_embeddings','semantic_state','embedding_failures')",
        7 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','files_fts','files_trigram','embedding_models','file_embeddings','semantic_state','embedding_failures','fingerprint_algorithms','file_fingerprints','fingerprint_postings','fingerprint_failures')",
        8 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','files_fts','files_trigram','embedding_models','file_embeddings','semantic_state','embedding_failures','fingerprint_algorithms','file_fingerprints','fingerprint_postings','fingerprint_failures','acoustic_edges','acoustic_groups','acoustic_group_state')",
        9 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','files_fts','files_trigram','embedding_models','file_embeddings','semantic_state','embedding_failures','fingerprint_algorithms','file_fingerprints','fingerprint_postings','fingerprint_failures','acoustic_edges','acoustic_groups','acoustic_group_state','waveform_analyses')",
        10 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','files_fts','files_trigram','embedding_models','file_embeddings','semantic_state','embedding_failures','fingerprint_algorithms','file_fingerprints','fingerprint_postings','fingerprint_failures','acoustic_edges','acoustic_groups','acoustic_group_state','waveform_analyses','waveform_tiers','waveform_cache_state','waveform_failures')",
        11 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','files_fts','files_trigram','embedding_models','file_embeddings','semantic_state','embedding_failures','fingerprint_algorithms','file_fingerprints','fingerprint_postings','fingerprint_failures','acoustic_edges','acoustic_groups','acoustic_group_state','waveform_analyses','waveform_tiers','waveform_cache_state','waveform_failures','semantic_sq8')",
        12 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','files_fts','files_trigram','embedding_models','file_embeddings','semantic_state','embedding_failures','fingerprint_algorithms','file_fingerprints','fingerprint_postings','fingerprint_failures','acoustic_edges','acoustic_groups','acoustic_group_state','waveform_analyses','waveform_tiers','waveform_cache_state','waveform_failures','semantic_sq8','file_search_keys','files_vocab','catalog_stats','fingerprint_df')",
        13, 14 => "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files','files_fts','files_trigram','embedding_models','file_embeddings','semantic_state','embedding_failures','fingerprint_algorithms','file_fingerprints','fingerprint_postings','fingerprint_failures','acoustic_edges','acoustic_groups','acoustic_group_state','waveform_analyses','waveform_tiers','waveform_cache_state','waveform_failures','semantic_sq8','file_search_keys','files_vocab','catalog_stats','fingerprint_df','pending_embeddings','pending_fingerprints')",
        else => return error.UnsupportedSchemaVersion,
    };
    const expected_tables: c_int = switch (version) {
        3 => 1,
        4 => 3,
        5 => 6,
        6 => 7,
        7 => 11,
        8 => 14,
        9 => 15,
        10 => 18,
        11 => 19,
        12 => 23,
        13, 14 => 25,
        else => unreachable,
    };
    var tables: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(handle, table_sql, -1, &tables, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
    defer _ = c.sqlite3_finalize(tables);
    if (c.sqlite3_step(tables) != c.SQLITE_ROW or c.sqlite3_column_int(tables, 0) != expected_tables) return error.InvalidBackupSchema;
    const file_contract = if (version == 3)
        "SELECT id,folder_id,path,relative_path,name,search_text,duration_ms,content_hash,waveform FROM files LIMIT 0"
    else if (version >= 14)
        "SELECT id,folder_id,path,relative_path,name,search_text,duration_ms,content_hash,waveform,file_size,mtime_ns,identity_kind,hash_algorithm FROM files LIMIT 0"
    else
        "SELECT id,folder_id,path,relative_path,name,search_text,duration_ms,content_hash,waveform,file_size,mtime_ns FROM files LIMIT 0";
    var contract: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(handle, file_contract, -1, &contract, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
    _ = c.sqlite3_finalize(contract);
    if (version >= 14) {
        const storage = try prepareOn(handle, "SELECT storage_version FROM file_fingerprints LIMIT 0");
        defer _ = c.sqlite3_finalize(storage);
        const objects = try prepareOn(handle, "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('idx_fingerprint_storage_pending','file_identity_au','file_identity_source_au')");
        defer _ = c.sqlite3_finalize(objects);
        if (c.sqlite3_step(objects) != c.SQLITE_ROW or c.sqlite3_column_int(objects, 0) != 3) return error.InvalidBackupSchema;
    }
    if (version >= 4) {
        var triggers: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('files_ai','files_ad','files_au')", -1, &triggers, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(triggers);
        if (c.sqlite3_step(triggers) != c.SQLITE_ROW or c.sqlite3_column_int(triggers, 0) != 3) return error.InvalidBackupSchema;
    }
    if (version >= 5) {
        var semantic: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM semantic_state WHERE singleton=1", -1, &semantic, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(semantic);
        if (c.sqlite3_step(semantic) != c.SQLITE_ROW or c.sqlite3_column_int(semantic, 0) != 1) return error.InvalidBackupSchema;
        var semantic_contract: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, "SELECT m.id,m.model_key,m.dimension,m.vector_format,e.model_id,e.file_id,e.source_content_hash,e.vector,s.active_model_id,s.generation FROM embedding_models m LEFT JOIN file_embeddings e ON e.model_id=m.id JOIN semantic_state s ON s.singleton=1 LIMIT 0", -1, &semantic_contract, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
        _ = c.sqlite3_finalize(semantic_contract);
    }
    if (version >= 7) {
        var fingerprint_contract: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, "SELECT a.algorithm_key,p.algorithm_id,p.file_id,p.source_content_hash,p.token_count,p.landmarks,x.token_hash FROM fingerprint_algorithms a LEFT JOIN file_fingerprints p ON p.algorithm_id=a.id LEFT JOIN fingerprint_postings x ON x.algorithm_id=p.algorithm_id AND x.file_id=p.file_id LIMIT 0", -1, &fingerprint_contract, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
        _ = c.sqlite3_finalize(fingerprint_contract);
    }
    if (version >= 8) {
        var acoustic_triggers: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('acoustic_edges_ai','acoustic_edges_ad')", -1, &acoustic_triggers, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(acoustic_triggers);
        if (c.sqlite3_step(acoustic_triggers) != c.SQLITE_ROW or c.sqlite3_column_int(acoustic_triggers, 0) != 2) return error.InvalidBackupSchema;
        var group_contract: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, "SELECT e.file_id_a,e.file_id_b,e.score_ppm,e.aligned,g.group_id,g.member_count,g.confidence_ppm,s.dirty FROM acoustic_edges e LEFT JOIN acoustic_groups g ON g.algorithm_id=e.algorithm_id LEFT JOIN acoustic_group_state s ON s.algorithm_id=e.algorithm_id LIMIT 0", -1, &group_contract, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
        _ = c.sqlite3_finalize(group_contract);
    }
    if (version >= 9) {
        var waveform_contract: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, "SELECT a.file_id,a.blob FROM waveform_analyses a JOIN files f ON f.id=a.file_id LIMIT 0", -1, &waveform_contract, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
        _ = c.sqlite3_finalize(waveform_contract);
        var waveform_trigger: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='waveform_analysis_source_changed'", -1, &waveform_trigger, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(waveform_trigger);
        if (c.sqlite3_step(waveform_trigger) != c.SQLITE_ROW or c.sqlite3_column_int(waveform_trigger, 0) != 1) return error.InvalidBackupSchema;
    }
    if (version >= 10) {
        var tier_contract: ?*c.sqlite3_stmt = null;
        const tier_contract_sql: [*:0]const u8 = if (canonical)
            "SELECT w.file_id,w.source_content_hash,w.source_file_size,w.source_mtime_ns,w.codec_version,w.universal_blob,w.universal_bytes,w.detailed_blob,w.detailed_bytes,w.detailed_access_ns,s.detailed_budget_bytes,s.universal_cursor_file_id,s.universal_scan_complete,s.waveform_claimed_file_id,s.waveform_claim_token,s.waveform_claim_until_ns FROM waveform_tiers w CROSS JOIN waveform_cache_state s WHERE s.singleton=1 LIMIT 0"
        else
            "SELECT w.file_id,w.source_content_hash,w.source_file_size,w.source_mtime_ns,w.codec_version,w.universal_blob,w.universal_bytes,w.detailed_blob,w.detailed_bytes,w.detailed_access_ns,s.detailed_budget_bytes FROM waveform_tiers w CROSS JOIN waveform_cache_state s WHERE s.singleton=1 LIMIT 0";
        if (c.sqlite3_prepare_v2(handle, tier_contract_sql, -1, &tier_contract, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
        _ = c.sqlite3_finalize(tier_contract);
        var state: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM waveform_cache_state WHERE singleton=1", -1, &state, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(state);
        if (c.sqlite3_step(state) != c.SQLITE_ROW or c.sqlite3_column_int(state, 0) != 1) return error.InvalidBackupSchema;
        if (canonical) {
            var failure_contract: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(handle, "SELECT file_id,source_content_hash,source_file_size,source_mtime_ns,permanent,attempt_count,retry_after_ns,detail FROM waveform_failures LIMIT 0", -1, &failure_contract, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
            _ = c.sqlite3_finalize(failure_contract);
            var waveform_triggers: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('waveform_files_ai','waveform_tier_rescan_au','waveform_claim_source_changed','waveform_claim_file_ad')", -1, &waveform_triggers, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
            defer _ = c.sqlite3_finalize(waveform_triggers);
            if (c.sqlite3_step(waveform_triggers) != c.SQLITE_ROW or c.sqlite3_column_int(waveform_triggers, 0) != 4) return error.InvalidBackupSchema;
        }
    }
    if (version >= 11) {
        const sq8_contract = prepareOn(handle, "SELECT model_id,file_id,source_content_hash,code FROM semantic_sq8 LIMIT 0") catch return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(sq8_contract);
        const triggers = prepareOn(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('file_embeddings_sq8_ai','file_embeddings_sq8_au')") catch return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(triggers);
        if (c.sqlite3_step(triggers) != c.SQLITE_ROW or c.sqlite3_column_int(triggers, 0) != 2) return error.InvalidBackupSchema;
    }
    if (version >= 12) {
        const optimization_contract = prepareOn(handle, "SELECT k.name_key,k.stem_key,c.generation,c.file_count,c.universal_count,c.detailed_count,c.universal_bytes,c.detailed_bytes,c.waveform_failure_count,c.waveform_terminal_count,m.embedded_count,m.failed_count,m.quantized_count,a.document_count,a.failed_count FROM file_search_keys k,catalog_stats c,embedding_models m,fingerprint_algorithms a LIMIT 0") catch return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(optimization_contract);
        const triggers = prepareOn(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('search_keys_ai','search_keys_au','catalog_files_ai','catalog_files_ad','catalog_files_au','catalog_source_bu','stats_waveform_ai','stats_waveform_ad','stats_waveform_au','stats_waveform_fail_ai','stats_waveform_fail_ad','stats_waveform_fail_au','stats_embedding_ai','stats_embedding_ad','stats_embedding_fail_ai','stats_embedding_fail_ad','stats_sq8_ai','stats_sq8_ad','stats_fingerprint_ai','stats_fingerprint_ad','stats_fingerprint_fail_ai','stats_fingerprint_fail_ad','stats_posting_ai','stats_posting_ad','stats_posting_au')") catch return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(triggers);
        if (c.sqlite3_step(triggers) != c.SQLITE_ROW or c.sqlite3_column_int(triggers, 0) != 25) return error.InvalidBackupSchema;
    }
    if (version >= 13) {
        const semantic_queue = prepareOn(handle, "SELECT model_id,file_id,folder_id FROM pending_embeddings INDEXED BY idx_pending_embeddings_folder LIMIT 0") catch return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(semantic_queue);
        const acoustic_queue = prepareOn(handle, "SELECT algorithm_id,file_id,folder_id FROM pending_fingerprints INDEXED BY idx_pending_fingerprints_folder LIMIT 0") catch return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(acoustic_queue);
        const triggers = prepareOn(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('pending_embeddings_owner_ai','pending_embeddings_file_ai','pending_embeddings_file_au','pending_embeddings_result_ai','pending_embeddings_result_au','pending_embeddings_result_ad','pending_embeddings_failure_ai','pending_embeddings_failure_au','pending_embeddings_failure_ad','pending_fingerprints_owner_ai','pending_fingerprints_file_ai','pending_fingerprints_file_au','pending_fingerprints_result_ai','pending_fingerprints_result_au','pending_fingerprints_result_ad','pending_fingerprints_failure_ai','pending_fingerprints_failure_au','pending_fingerprints_failure_ad')") catch return error.InvalidBackupSchema;
        defer _ = c.sqlite3_finalize(triggers);
        if (c.sqlite3_step(triggers) != c.SQLITE_ROW or c.sqlite3_column_int(triggers, 0) != 18) return error.InvalidBackupSchema;
    }
}

fn migrateRestoredLocked() !void {
    const version = try userVersionLocked();
    try migrateLocked();
    if (version >= 11) {
        // Codes are derived, not trusted backup input. Rebuild before publication.
        try execLocked("BEGIN IMMEDIATE;");
        errdefer execLocked("ROLLBACK;") catch {};
        try execLocked("DELETE FROM semantic_sq8;");
        try execLocked(QUANTIZED_BACKFILL_SQL);
        try execLocked("COMMIT;");
    }
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    try execLocked(optimization_schema.reconcile);
    // Pending rows are derived from canonical sources/results/failures. Rebuild
    // backup input so a stale or missing work row cannot strand refinement.
    try execLocked(refinement_schema.rebuild);
    try execLocked("DELETE FROM file_search_keys; INSERT INTO file_search_keys SELECT id,ws_name_key(name),ws_stem_key(name) FROM files;");
    try execLocked("COMMIT;");
    // A claim belongs to the process working against the source database, not
    // to a restored copy. Never publish an ephemeral lease from a backup.
    try execLocked("UPDATE waveform_cache_state SET waveform_claimed_file_id=0,waveform_claim_token=0,waveform_claim_until_ns=0 WHERE singleton=1;");
}

// Explicit offline upgrade: preserve the live database and require a NEW path.
// The caller can retain its original/backup and restore this verified copy.
pub fn compactTo(path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const reserved = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    reserved.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try backupTo(path);
    const path_z = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
    defer std.heap.c_allocator.free(path_z);
    var copy: ?*c.sqlite3 = null;
    defer {
        if (copy) |handle| {
            _ = c.sqlite3_close_v2(handle);
        }
    }
    if (c.sqlite3_open_v2(path_z, &copy, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) return error.OpenFailed;
    const handle = copy.?;
    try registerVectorFunctions(handle);
    if (c.sqlite3_exec(handle, "PRAGMA journal_mode=DELETE; PRAGMA page_size=16384; PRAGMA cache_size=-16384; VACUUM; PRAGMA foreign_keys=ON; INSERT INTO files_fts(files_fts,rank) VALUES('integrity-check',1); INSERT INTO files_trigram(files_trigram,rank) VALUES('integrity-check',1);", null, null, null) != c.SQLITE_OK) return error.CompactFailed;
    const check = try prepareOn(handle, "PRAGMA integrity_check");
    defer _ = c.sqlite3_finalize(check);
    if (c.sqlite3_step(check) != c.SQLITE_ROW) return error.CompactFailed;
    const result = c.sqlite3_column_text(check, 0) orelse return error.CompactFailed;
    if (!std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(result))), "ok") or c.sqlite3_step(check) != c.SQLITE_DONE) return error.CompactFailed;
    const foreign_keys = try prepareOn(handle, "PRAGMA foreign_key_check");
    defer _ = c.sqlite3_finalize(foreign_keys);
    if (c.sqlite3_step(foreign_keys) != c.SQLITE_DONE) return error.CompactFailed;
    try validateRestoreSchema(handle, SCHEMA_VERSION, false);
    try validateStoredFingerprintsOn(handle);
    try validateIdentityRowsOn(handle);
    const stats = try prepareOn(handle, optimization_schema.check);
    defer _ = c.sqlite3_finalize(stats);
    if (c.sqlite3_step(stats) != c.SQLITE_ROW or c.sqlite3_column_int(stats, 0) != 0) return error.DerivedStatsMismatch;
    const queues = try prepareOn(handle, refinement_schema.check);
    defer _ = c.sqlite3_finalize(queues);
    if (c.sqlite3_step(queues) != c.SQLITE_ROW or c.sqlite3_column_int(queues, 0) != 0) return error.RefinementQueueMismatch;
}

pub fn restoreFrom(path: []const u8) !void {
    index_connection_mutex.lock();
    defer index_connection_mutex.unlock();
    lock();
    defer mutex.unlock();
    const path_z = try std.heap.c_allocator.dupeSentinel(u8, path, 0);
    defer std.heap.c_allocator.free(path_z);
    var source: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(path_z.ptr, &source, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) {
        if (source) |handle| _ = c.sqlite3_close_v2(handle);
        return error.BackupOpenFailed;
    }
    defer _ = c.sqlite3_close_v2(source);
    try registerVectorFunctions(source.?);
    var check_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(source, "PRAGMA quick_check", -1, &check_stmt, null) != c.SQLITE_OK) return error.InvalidBackup;
    defer _ = c.sqlite3_finalize(check_stmt);
    if (c.sqlite3_step(check_stmt) != c.SQLITE_ROW) return error.InvalidBackup;
    const check = c.sqlite3_column_text(check_stmt, 0) orelse return error.InvalidBackup;
    const check_len: usize = @intCast(c.sqlite3_column_bytes(check_stmt, 0));
    if (!std.mem.eql(u8, check[0..check_len], "ok")) return error.InvalidBackup;
    var version_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(source, "PRAGMA user_version", -1, &version_stmt, null) != c.SQLITE_OK) return error.InvalidBackup;
    defer _ = c.sqlite3_finalize(version_stmt);
    if (c.sqlite3_step(version_stmt) != c.SQLITE_ROW) return error.InvalidBackup;
    const source_version = c.sqlite3_column_int(version_stmt, 0);
    if (source_version > SCHEMA_VERSION) return error.FutureSchemaVersion;
    if (source_version < 3) return error.UnsupportedSchemaVersion;
    try validateRestoreSchema(source.?, source_version, false);
    // Stage and migrate the backup before touching the live connection. This
    // prevents a valid-SQLite but malformed legacy schema from destroying a
    // healthy live index when migration subsequently fails.
    const live = try handleLocked();
    const live_name_ptr = c.sqlite3_db_filename(live, "main") orelse return error.RestoreStagingFailed;
    const live_name = std.mem.span(live_name_ptr);
    const staged_path = try std.fmt.allocPrintSentinel(std.heap.c_allocator, "{s}.restore.tmp", .{live_name}, 0);
    defer std.heap.c_allocator.free(staged_path);
    _ = c.remove(staged_path.ptr);
    var staged: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(staged_path.ptr, &staged, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) {
        if (staged) |handle| _ = c.sqlite3_close_v2(handle);
        return error.RestoreStagingFailed;
    }
    errdefer {
        if (staged) |handle| _ = c.sqlite3_close_v2(handle);
        _ = c.remove(staged_path.ptr);
    }
    try registerVectorFunctions(staged.?);
    const stage_backup = c.sqlite3_backup_init(staged, "main", source, "main") orelse return error.BackupInitFailed;
    const stage_step = c.sqlite3_backup_step(stage_backup, -1);
    const stage_finish = c.sqlite3_backup_finish(stage_backup);
    if (stage_step != c.SQLITE_DONE or stage_finish != c.SQLITE_OK) return error.BackupFailed;

    if (c.sqlite3_exec(staged, "PRAGMA foreign_keys=ON;", null, null, null) != c.SQLITE_OK) return error.PragmaFailed;
    db_handle = staged;
    const migration_result = migrateRestoredLocked();
    db_handle = live;
    migration_result catch |err| return err;

    var staged_check: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(staged, "PRAGMA quick_check", -1, &staged_check, null) != c.SQLITE_OK) return error.InvalidBackup;
    defer _ = c.sqlite3_finalize(staged_check);
    if (c.sqlite3_step(staged_check) != c.SQLITE_ROW) return error.InvalidBackup;
    const staged_text = c.sqlite3_column_text(staged_check, 0) orelse return error.InvalidBackup;
    const staged_len: usize = @intCast(c.sqlite3_column_bytes(staged_check, 0));
    if (!std.mem.eql(u8, staged_text[0..staged_len], "ok")) return error.InvalidBackup;
    try validateRestoreSchema(staged.?, SCHEMA_VERSION, true);
    try validateStoredFingerprintsOn(staged.?);
    try validateIdentityRowsOn(staged.?);
    var foreign_key_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(staged, "PRAGMA foreign_key_check", -1, &foreign_key_stmt, null) != c.SQLITE_OK) return error.InvalidBackupSchema;
    defer _ = c.sqlite3_finalize(foreign_key_stmt);
    if (c.sqlite3_step(foreign_key_stmt) != c.SQLITE_DONE) return error.InvalidBackupSchema;

    const different_pages = blk: {
        const live_pages = try prepareOn(live, "PRAGMA page_size");
        defer _ = c.sqlite3_finalize(live_pages);
        const staged_pages = try prepareOn(staged.?, "PRAGMA page_size");
        defer _ = c.sqlite3_finalize(staged_pages);
        if (c.sqlite3_step(live_pages) != c.SQLITE_ROW or c.sqlite3_step(staged_pages) != c.SQLITE_ROW) return error.PragmaFailed;
        break :blk c.sqlite3_column_int(live_pages, 0) != c.sqlite3_column_int(staged_pages, 0);
    };
    closeSemanticReader();
    // SQLite cannot restore a different page size into a WAL destination.
    if (different_pages) try execLocked("PRAGMA journal_mode=DELETE;");
    errdefer if (different_pages) applyPragmasLocked() catch {};
    const publish = c.sqlite3_backup_init(live, "main", staged, "main") orelse return error.BackupInitFailed;
    const publish_step = c.sqlite3_backup_step(publish, -1);
    const publish_finish = c.sqlite3_backup_finish(publish);
    if (publish_step != c.SQLITE_DONE or publish_finish != c.SQLITE_OK) return error.BackupFailed;
    _ = c.sqlite3_finalize(staged_check);
    staged_check = null;
    if (c.sqlite3_close_v2(staged) != c.SQLITE_OK) return error.BackupFailed;
    staged = null;
    _ = c.remove(staged_path.ptr);
    try applyPragmasLocked();
    connection_serial +%= 1;
    if (connection_serial == 0) connection_serial = 1;
}

/// Deterministic metadata-only corpus generation for the explicit performance
/// harness. This is not exported through the product ABI.
pub fn insertSyntheticBenchmarkFiles(count: usize) !void {
    if (count > std.math.maxInt(i32)) return error.TooManyBenchmarkFiles;
    lock();
    defer mutex.unlock();
    try execLocked("BEGIN IMMEDIATE;");
    errdefer execLocked("ROLLBACK;") catch {};
    const stmt = try prepareLocked("INSERT INTO files(folder_id,path,relative_path,name,search_text,duration_ms,content_hash,file_size,mtime_ns) VALUES(?,?,?,?,?,?,?,?,?)");
    defer _ = c.sqlite3_finalize(stmt);
    var path_buf: [96]u8 = undefined;
    var relative_buf: [64]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    var search_buf: [128]u8 = undefined;
    for (0..count) |i| {
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
        const category = switch (i % 8) {
            0 => "impact",
            1 => "whoosh",
            2 => "rain",
            3 => "footsteps",
            4 => "engine",
            5 => "ambience",
            6 => "bird",
            else => "water",
        };
        const name = std.fmt.bufPrint(&name_buf, "{s}-{d:0>8}.wav", .{ category, i }) catch return error.BenchmarkFormatFailed;
        const relative = std.fmt.bufPrint(&relative_buf, "set-{d}/{s}", .{ i % 1000, name }) catch return error.BenchmarkFormatFailed;
        const path = std.fmt.bufPrint(&path_buf, "/synthetic/{s}", .{relative}) catch return error.BenchmarkFormatFailed;
        const search_text = std.fmt.bufPrint(&search_buf, "{s} synthetic library field recording variant {d}", .{ category, i % 97 }) catch return error.BenchmarkFormatFailed;
        try bindInt(stmt, 1, @intCast(i % 1000));
        try bindText(stmt, 2, path);
        try bindText(stmt, 3, relative);
        try bindText(stmt, 4, name);
        try bindText(stmt, 5, search_text);
        try bindInt(stmt, 6, @intCast(100 + i % 60_000));
        try bindInt64(stmt, 7, @intCast(i + 1));
        try bindInt64(stmt, 8, @intCast(1000 + i % 1_000_000));
        try bindInt64(stmt, 9, @intCast(i));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.InsertFailed;
    }
    try execLocked("COMMIT;");
}

pub fn schemaVersion() !i32 {
    lock();
    defer mutex.unlock();
    return userVersionLocked();
}

test "SQ8 indexed retrieval reranks exactly, filters early, maintains identity, migrates and recovers after interruption" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/sq8.sqlite", .{root}, 0);
    defer allocator.free(path);
    const backup_path = try std.fmt.allocPrint(allocator, "{s}/backup.sqlite", .{root});
    defer allocator.free(backup_path);
    try open(allocator, path);
    defer close();
    try insertSyntheticBenchmarkFiles(SQ8_MIN_ROWS);
    _ = try setSemanticModel("test/sq8-v1", 16);
    var rng = std.Random.DefaultPrng.init(1234);
    var values: [16]f32 = undefined;
    for (0..SQ8_MIN_ROWS) |i| {
        for (&values) |*value| value.* = rng.random().float(f32) * 2 - 1;
        try vector.normalize(&values);
        try upsertSemanticEmbedding(allocator, @intCast(i + 1), @intCast(i + 1), &values);
    }
    const query = values;
    const info = (try activeSemanticInfo()).?;
    const reader = try semanticReaderLocked(path, info.connection_serial);
    const Hooks = struct {
        fn mustNotEncode(context: ?*c.sqlite3_context, _: c_int, _: [*c]?*c.sqlite3_value) callconv(.c) void {
            c.sqlite3_result_error(context, "Query recomputed SQ8 instead of reading the covering index", -1);
        }
        fn cancelDuringScan(_: ?*anyopaque) callconv(.c) c_int {
            query_cancel.current.?.cancel();
            return 1;
        }
        fn compare(expected: []const vector.Match, actual: []const vector.Match) !void {
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |a, b| {
                try std.testing.expectEqual(a.file_id, b.file_id);
                try std.testing.expectEqual(a.score, b.score);
            }
        }
    };
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_create_function_v2(reader, "ws_sq8_v1", 1, c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC | c.SQLITE_INNOCUOUS, null, Hooks.mustNotEncode, null, null, null));
    const exact = (try streamActiveVectorTopKWithMode(allocator, &query, .{}, 20, .exact)).?;
    defer allocator.free(exact.matches);
    const compact = (try streamActiveVectorTopK(allocator, &query, .{}, 20)).?;
    defer allocator.free(compact.matches);
    try std.testing.expect(compact.quantized);
    try std.testing.expectEqual(@as(usize, 128), compact.reranked);
    try Hooks.compare(exact.matches, compact.matches);
    for ([_]vector.Filter{ .{ .folder_id = 0 }, .{ .min_duration_ms = 101, .max_duration_ms = 105 } }) |filter| {
        const filtered = (try streamActiveVectorTopK(allocator, &query, filter, 20)).?;
        defer allocator.free(filtered.matches);
        const filtered_sq8 = (try streamActiveVectorTopKWithMode(allocator, &query, filter, 20, .quantized)).?;
        defer allocator.free(filtered_sq8.matches);
        try std.testing.expect(!filtered.quantized);
        try std.testing.expectEqual(@as(usize, 5), filtered.scanned);
        try Hooks.compare(filtered.matches, filtered_sq8.matches);
    }
    // A broad duration or folder filter must use compact retrieval, while a
    // small matching population still benefits from exact canonical reads.
    const broad_duration: vector.Filter = .{ .min_duration_ms = 100, .max_duration_ms = 100_000 };
    const broad = (try streamActiveVectorTopK(allocator, &query, broad_duration, 20)).?;
    defer allocator.free(broad.matches);
    try std.testing.expect(broad.quantized);
    try Hooks.compare(exact.matches, broad.matches);
    try execLocked("UPDATE files SET folder_id=7;");
    const broad_folder: vector.Filter = .{ .folder_id = 7, .max_duration_ms = 100_000 };
    const scoped = (try streamActiveVectorTopK(allocator, &query, broad_folder, 20)).?;
    defer allocator.free(scoped.matches);
    try std.testing.expect(scoped.quantized);
    try Hooks.compare(exact.matches, scoped.matches);
    try execLocked("DELETE FROM semantic_sq8 WHERE file_id=1;");
    const incomplete = (try streamActiveVectorTopK(allocator, &query, broad_folder, 20)).?;
    defer allocator.free(incomplete.matches);
    try std.testing.expect(!incomplete.quantized);
    try Hooks.compare(exact.matches, incomplete.matches);
    try upsertSemanticEmbedding(allocator, 1, 1, &query);
    // SQLite maintains codes on UPDATE and backup/restore, not application hooks.
    try upsertSemanticEmbedding(allocator, 1, 1, &query);
    // Derived codes from a backup are rebuilt rather than trusted.
    try execLocked("UPDATE semantic_sq8 SET code=zeroblob(24) WHERE file_id=1;");
    try backupTo(backup_path);
    try execLocked("UPDATE files SET content_hash=-1 WHERE id=1;");
    const stale = (try streamActiveVectorTopKWithMode(allocator, &query, .{}, 1, .quantized)).?;
    defer allocator.free(stale.matches);
    try std.testing.expectEqual(@as(i32, SQ8_MIN_ROWS), stale.matches[0].file_id);
    try restoreFrom(backup_path);
    const restored = (try streamActiveVectorTopKWithMode(allocator, &query, .{}, 1, .quantized)).?;
    defer allocator.free(restored.matches);
    try std.testing.expectEqual(@as(i32, 1), restored.matches[0].file_id);
    _ = try setSemanticModel("test/other-sq8-model", 16);
    const empty = (try streamActiveVectorTopKWithMode(allocator, &query, .{}, 20, .quantized)).?;
    defer allocator.free(empty.matches);
    try std.testing.expectEqual(@as(usize, 0), empty.matches.len);
    _ = try setSemanticModel("test/sq8-v1", 16);
    try execLocked("DELETE FROM files WHERE id=1;");
    // Existing v10 catalogs are backfilled atomically without re-running CLAP.
    try execLocked(storage_schema.dropForTests ++ refinement_schema.dropForTests ++ optimization_schema.dropForTests ++ DROP_QUANTIZED_INDEX_SQL ++ "PRAGMA user_version=10;");
    close();
    try open(allocator, path);
    try std.testing.expectEqual(SCHEMA_VERSION, try schemaVersion());
    const reopened_info = (try activeSemanticInfo()).?;
    const reused_reader = try semanticReaderLocked(path, reopened_info.connection_serial);
    var request: query_cancel.Request = .{};
    query_cancel.current = &request;
    defer query_cancel.current = null;
    c.sqlite3_progress_handler(reused_reader, 10_000, Hooks.cancelDuringScan, null);
    try std.testing.expectError(error.Cancelled, streamActiveVectorTopKWithMode(allocator, &query, .{}, 20, .quantized));
    try std.testing.expect(request.cancelled.load(.acquire));
    try std.testing.expect(c.sqlite3_get_autocommit(reused_reader) != 0);
    try std.testing.expect(c.sqlite3_next_stmt(reused_reader, null) == null);
    query_cancel.current = null;
    const recovered = (try streamActiveVectorTopKWithMode(allocator, &query, .{}, 20, .quantized)).?;
    defer allocator.free(recovered.matches);
    try std.testing.expectEqual(@as(i32, SQ8_MIN_ROWS), recovered.matches[0].file_id);
    try std.testing.expectEqual(SQ8_MIN_ROWS - 1, recovered.scanned);
    // Almost identical vectors collapse to the same SQ8 code. A fixed shortlist
    // misses true neighbors; error-bound refinement must recover the exact IDs.
    for (1..SQ8_MIN_ROWS) |i| {
        for (&values) |*value| value.* = 1 + rng.random().float(f32) * 0.001;
        try vector.normalize(&values);
        try upsertSemanticEmbedding(allocator, @intCast(i + 1), @intCast(i + 1), &values);
    }
    const dense_exact = (try streamActiveVectorTopKWithMode(allocator, &values, .{}, 20, .exact)).?;
    defer allocator.free(dense_exact.matches);
    const dense_sq8 = (try streamActiveVectorTopKWithMode(allocator, &values, .{}, 20, .quantized)).?;
    defer allocator.free(dense_sq8.matches);
    try std.testing.expectEqual(SQ8_MIN_ROWS - 1, dense_sq8.refinement_scanned);
    try std.testing.expectEqual(SQ8_MIN_ROWS - 1, dense_sq8.reranked);
    try Hooks.compare(dense_exact.matches, dense_sq8.matches);
    const dense_filtered = (try streamActiveVectorTopKWithMode(allocator, &values, broad_folder, 20, .quantized)).?;
    defer allocator.free(dense_filtered.matches);
    try std.testing.expectEqual(SQ8_MIN_ROWS - 1, dense_filtered.refinement_scanned);
    try Hooks.compare(dense_exact.matches, dense_filtered.matches);
    // Interrupt the bounded population probe itself, before vector retrieval.
    try execLocked("INSERT INTO files(folder_id,path,relative_path,name,search_text,duration_ms,content_hash,file_size,mtime_ns) VALUES(7,'/probe.wav','probe.wav','probe.wav','probe',1000,999,1,1);");
    try upsertSemanticEmbedding(allocator, SQ8_MIN_ROWS + 1, 999, &values);
    request = .{};
    query_cancel.current = &request;
    c.sqlite3_progress_handler(reused_reader, 100, Hooks.cancelDuringScan, null);
    try std.testing.expectError(error.Cancelled, streamActiveVectorTopK(allocator, &values, broad_folder, 20));
    try std.testing.expect(c.sqlite3_get_autocommit(reused_reader) != 0);
    try std.testing.expect(c.sqlite3_next_stmt(reused_reader, null) == null);
    query_cancel.current = null;
}

test "SQLite progress interrupts only the executing query and leaves the connection usable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/cancel.sqlite", .{root});
    defer std.testing.allocator.free(path);
    try open(std.testing.allocator, path);
    defer close();
    var request: query_cancel.Request = .{};
    query_cancel.current = &request;
    defer query_cancel.current = null;
    const Callback = struct {
        fn cancelDuringStep(context: ?*c.sqlite3_context, _: c_int, _: [*c]?*c.sqlite3_value) callconv(.c) void {
            query_cancel.current.?.cancel();
            c.sqlite3_result_int(context, 1);
        }
    };
    const handle = try handleLocked();
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_create_function_v2(handle, "cancel_now", 0, c.SQLITE_UTF8, null, Callback.cancelDuringStep, null, null, null));
    // Cancellation is triggered by SQLite itself while the VM is running, not
    // by a sleep or a pre-dispatch check. The progress handler stops the scan.
    const sql = "WITH RECURSIVE n(x) AS (SELECT cancel_now() UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT sum(x) FROM n";
    try std.testing.expectEqual(c.SQLITE_INTERRUPT, c.sqlite3_exec(handle, sql, null, null, null));
    try std.testing.expect(query_cancel.isCancelled());
    query_cancel.current = null;
    try std.testing.expectEqual(@as(c_int, 0), try countForFolder(1));
}
