const std = @import("std");
const db = @import("db.zig");
const audio = @import("audio.zig");
const search = @import("search.zig");
const main_c = @import("main_c.zig");
const vector = @import("vector.zig");
const semantic = @import("semantic.zig");
const tokenizer = @import("tokenizer.zig");
const clap_audio = @import("clap_audio.zig");
const onnx_runtime = @import("onnx_runtime.zig");
const model_manifest = @import("model_manifest.zig");
const clap_provider = @import("clap_provider.zig");
const sync = @import("sync.zig");
const fingerprint = @import("fingerprint.zig");
const acoustic = @import("acoustic.zig");
const waveform = @import("waveform.zig");
const operations = @import("operations.zig");
const c = db.c;

test "module tests are included" {
    std.testing.refAllDecls(tokenizer);
    std.testing.refAllDecls(clap_audio);
    std.testing.refAllDecls(onnx_runtime);
    std.testing.refAllDecls(model_manifest);
    std.testing.refAllDecls(clap_provider);
    std.testing.refAllDecls(sync);
    std.testing.refAllDecls(@import("refinement_schedule.zig"));
    std.testing.refAllDecls(@import("semantic_segments.zig"));
    std.testing.refAllDecls(@import("coverage_relevance.zig"));
    std.testing.refAllDecls(@import("audio_fuzz.zig"));
    std.testing.refAllDecls(@import("sound_vocabulary.zig"));
}
const abi_c = @import("c");
const env_c = @import("c");

const allocator = std.testing.allocator;
const io = std.testing.io;

fn repeatedString(comptime text: []const u8, comptime count: usize) *const [text.len * count:0]u8 {
    const value = comptime blk: {
        var bytes: [text.len * count:0]u8 = undefined;
        for (0..count) |i| @memcpy(bytes[i * text.len ..][0..text.len], text);
        bytes[bytes.len] = 0;
        break :blk bytes;
    };
    return &value;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    db_path: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(root);
        const db_path = try std.fmt.allocPrint(allocator, "{s}/index.sqlite", .{root});
        return .{ .tmp = tmp, .root = root, .db_path = db_path };
    }

    fn deinit(self: *Fixture) void {
        semantic.reset();
        db.close();
        allocator.free(self.db_path);
        allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn path(self: *Fixture, sub: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.root, sub });
    }
};

fn writeWav(dir: std.Io.Dir, relative_path: []const u8, duration_ms: u32, seed: i16) !void {
    const sample_rate: u32 = 8000;
    const frames: u32 = @intCast((@as(u64, sample_rate) * duration_ms) / 1000);
    const data_size: u32 = frames * 2;
    const bytes = try allocator.alloc(u8, 44 + data_size);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_size, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], sample_rate * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_size, .little);
    var offset: usize = 44;
    var value = seed;
    while (offset < bytes.len) : (offset += 2) {
        std.mem.writeInt(i16, bytes[offset..][0..2], value, .little);
        value +%= 97;
    }
    try dir.writeFile(io, .{ .sub_path = relative_path, .data = bytes });
}

fn writeFingerprintWav(dir: std.Io.Dir, relative_path: []const u8, rate: u32, start_seconds: f64, duration_seconds: f64, gain: f64, unrelated: bool) !void {
    const frames: u32 = @intFromFloat(@as(f64, @floatFromInt(rate)) * duration_seconds);
    const data_size = frames * 2;
    const bytes = try allocator.alloc(u8, 44 + data_size);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_size, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], rate, .little);
    std.mem.writeInt(u32, bytes[28..32], rate * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_size, .little);
    for (0..frames) |i| {
        const t = start_seconds + @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate));
        const value = if (unrelated)
            0.55 * @sin(2.0 * std.math.pi * (70.0 * t + 95.0 * t * t))
        else
            0.45 * @sin(2.0 * std.math.pi * (180.0 * t + 330.0 * t * t)) + (if (@mod(t, 0.2) < 0.008) 0.3 * @sin(2.0 * std.math.pi * 2100.0 * t) else 0);
        const sample: i16 = @intFromFloat(std.math.clamp(value * gain, -1.0, 1.0) * 30_000.0);
        std.mem.writeInt(i16, bytes[44 + i * 2 ..][0..2], sample, .little);
    }
    try dir.writeFile(io, .{ .sub_path = relative_path, .data = bytes });
}

fn writeFingerprintAiff(dir: std.Io.Dir, relative_path: []const u8, rate: u32, duration_seconds: f64, gain: f64) !void {
    const frames: u32 = @intFromFloat(@as(f64, @floatFromInt(rate)) * duration_seconds);
    const data_size: usize = frames * 2;
    const total = 12 + 8 + 18 + 8 + 8 + data_size;
    const bytes = try allocator.alloc(u8, total);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "FORM");
    std.mem.writeInt(u32, bytes[4..8], @intCast(total - 8), .big);
    @memcpy(bytes[8..12], "AIFF");
    @memcpy(bytes[12..16], "COMM");
    std.mem.writeInt(u32, bytes[16..20], 18, .big);
    std.mem.writeInt(u16, bytes[20..22], 1, .big);
    std.mem.writeInt(u32, bytes[22..26], frames, .big);
    std.mem.writeInt(u16, bytes[26..28], 16, .big);
    const rate80 = if (rate == 48_000) [_]u8{ 0x40, 0x0e, 0xbb, 0x80, 0, 0, 0, 0, 0, 0 } else [_]u8{ 0x40, 0x0e, 0xac, 0x44, 0, 0, 0, 0, 0, 0 };
    @memcpy(bytes[28..38], &rate80);
    @memcpy(bytes[38..42], "SSND");
    std.mem.writeInt(u32, bytes[42..46], @intCast(data_size + 8), .big);
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rate));
        const value = 0.45 * @sin(2.0 * std.math.pi * (180.0 * t + 330.0 * t * t)) + (if (@mod(t, 0.2) < 0.008) 0.3 * @sin(2.0 * std.math.pi * 2100.0 * t) else 0);
        const sample: i16 = @intFromFloat(std.math.clamp(value * gain, -1.0, 1.0) * 30_000.0);
        std.mem.writeInt(i16, bytes[54 + i * 2 ..][0..2], sample, .big);
    }
    try dir.writeFile(io, .{ .sub_path = relative_path, .data = bytes });
}

fn writeToneWav(dir: std.Io.Dir, relative_path: []const u8, rate: u32, frequency: f64, seconds: u32) !void {
    const frames = rate * seconds;
    const data_size = frames * 2;
    const bytes = try allocator.alloc(u8, 44 + data_size);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_size, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], rate, .little);
    std.mem.writeInt(u32, bytes[28..32], rate * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_size, .little);
    for (0..frames) |i| {
        const value: i16 = @intFromFloat(26_000.0 * @sin(2.0 * std.math.pi * frequency * @as(f64, @floatFromInt(i)) / rate));
        std.mem.writeInt(i16, bytes[44 + i * 2 ..][0..2], value, .little);
    }
    try dir.writeFile(io, .{ .sub_path = relative_path, .data = bytes });
}

fn writeSineWav48k(dir: std.Io.Dir, relative_path: []const u8) !void {
    const rate: u32 = 48_000;
    const frames: u32 = rate;
    const data_size = frames * 2;
    const bytes = try allocator.alloc(u8, 44 + data_size);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_size, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], rate, .little);
    std.mem.writeInt(u32, bytes[28..32], rate * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_size, .little);
    for (0..frames) |i| {
        const sample: i16 = @intFromFloat(12000.0 * @sin(2.0 * std.math.pi * 440.0 * @as(f64, @floatFromInt(i)) / rate));
        std.mem.writeInt(i16, bytes[44 + i * 2 ..][0..2], sample, .little);
    }
    try dir.writeFile(io, .{ .sub_path = relative_path, .data = bytes });
}

fn resultCandidateName(candidate: *const db.Candidate) []const u8 {
    return std.mem.sliceTo(&candidate.name, 0);
}

fn resultName(result: *const main_c.WSResult) []const u8 {
    return result.name[0..(std.mem.indexOfScalar(u8, &result.name, 0) orelse result.name.len)];
}

fn openFixture(fixture: *Fixture) !void {
    try db.open(allocator, fixture.db_path);
}

test "FTS query building quotes tokens and duration parsing is bounded" {
    const simple = search.buildQuery("BigBoom-file.wav");
    try std.testing.expectEqualStrings("\"big\"* AND \"boom\"* AND \"file\"* AND \"wav\"*", simple.slice());

    const escaped = search.buildQuery("stone \" OR *");
    try std.testing.expectEqualStrings("\"stone\"* AND \"or\"*", escaped.slice());
    try std.testing.expect(std.mem.indexOf(u8, escaped.slice(), "\" OR *") == null);
    const long = search.buildQuery(repeatedString("abcdefghij ", 200));
    try std.testing.expect(long.len <= search.MAX_QUERY_LEN);
    try std.testing.expect(long.slice()[long.len - 1] == '*');

    try std.testing.expectEqual(@as(?i32, 500), search.parseDurationMs("500ms"));
    try std.testing.expectEqual(@as(?i32, 1500), search.parseDurationMs("1.5s"));
    try std.testing.expectEqual(@as(?i32, 2000), search.parseDurationMs("2"));
    try std.testing.expectEqual(@as(?i32, null), search.parseDurationMs("nan"));
    try std.testing.expectEqual(@as(?i32, null), search.parseDurationMs("-2s"));
    const parsed = search.parseSearchQuery("whoosh >1s <2.5s");
    try std.testing.expectEqualStrings("whoosh", parsed.text.slice());
    try std.testing.expectEqual(@as(i32, 1001), parsed.min_ms);
    try std.testing.expectEqual(@as(i32, 2499), parsed.max_ms);
    try std.testing.expect(!parsed.impossible);
    try std.testing.expect(search.parseSearchQuery("<0ms").impossible);
    try std.testing.expect(search.parseSearchQuery(">2s <1s").impossible);
    try std.testing.expect(search.parseSearchQuery("<1ms").impossible);
    try std.testing.expect(search.parseSearchQuery(">2s =1s").impossible);
    try std.testing.expect(search.parseSearchQuery("=1s >2s").impossible);
    try std.testing.expect(search.parseSearchQuery("=1s =3s").impossible);
}

test "fresh schema is current and future schemas are rejected" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try std.testing.expectEqual(@as(i32, db.SCHEMA_VERSION), try db.schemaVersion());
    db.close();

    try rawExec(fixture.db_path, "PRAGMA user_version=99;");
    try std.testing.expectError(error.FutureSchemaVersion, db.open(allocator, fixture.db_path));
}

test "v4 migration creates current semantic failure fingerprint group and waveform schemas transactionally" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try rawExec(fixture.db_path, "CREATE TABLE files(" ++
        "id INTEGER PRIMARY KEY AUTOINCREMENT,folder_id INTEGER NOT NULL,path TEXT NOT NULL UNIQUE," ++
        "relative_path TEXT NOT NULL DEFAULT '',name TEXT NOT NULL,search_text TEXT NOT NULL DEFAULT ''," ++
        "duration_ms INTEGER NOT NULL DEFAULT 0,content_hash INTEGER NOT NULL DEFAULT 0,waveform BLOB," ++
        "file_size INTEGER NOT NULL DEFAULT -1,mtime_ns INTEGER NOT NULL DEFAULT -1);" ++
        "INSERT INTO files(id,folder_id,path,relative_path,name,search_text,duration_ms,content_hash,file_size,mtime_ns) " ++
        "VALUES(8,2,'/v4.wav','v4.wav','v4.wav','v4 wav',100,44,10,20);" ++
        "PRAGMA user_version=4;");
    try openFixture(&fixture);
    try std.testing.expectEqual(db.SCHEMA_VERSION, try db.schemaVersion());
    _ = try db.setSemanticModel("test/model@1", 2);
    try db.upsertSemanticEmbedding(allocator, 8, 44, &.{ 1, 0 });
    const status = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 1), status.embedded_count);
    try std.testing.expectEqual(@as(i64, 0), status.pending_count);
}

test "v5 migration adds current embedding failures fingerprints groups and waveform analysis" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    db.close();
    try rawExec(fixture.db_path, @import("storage_schema.zig").dropForTests ++ @import("refinement_schema.zig").dropForTests ++ @import("schema_optimizations.zig").dropForTests);
    try rawExec(fixture.db_path, "DROP TRIGGER waveform_analysis_source_changed;DROP TRIGGER waveform_files_ai;DROP TRIGGER waveform_tier_rescan_au;DROP TRIGGER waveform_claim_source_changed;DROP TRIGGER waveform_claim_file_ad;DROP TABLE waveform_failures;DROP TABLE waveform_cache_state;DROP TABLE waveform_tiers;DROP TABLE waveform_analyses;DROP TRIGGER acoustic_edges_ai;DROP TRIGGER acoustic_edges_ad;DROP TABLE acoustic_group_state;DROP TABLE acoustic_groups;DROP TABLE acoustic_edges;DROP TABLE fingerprint_postings;DROP TABLE fingerprint_failures;DROP TABLE file_fingerprints;DROP TABLE fingerprint_algorithms;DROP TABLE embedding_failures;" ++ db.DROP_QUANTIZED_INDEX_SQL ++ "PRAGMA user_version=5;");
    try openFixture(&fixture);
    try std.testing.expectEqual(db.SCHEMA_VERSION, try db.schemaVersion());
    db.close();
    try std.testing.expectEqual(@as(i64, 1), try rawScalar(fixture.db_path, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='embedding_failures';"));
    try std.testing.expectEqual(@as(i64, 1), try rawScalar(fixture.db_path, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='file_fingerprints';"));
}

test "v6 migration preserves semantic rows and adds current derived schemas" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{.{
        .path = "/preserved.wav",
        .relative_path = "preserved.wav",
        .name = "preserved.wav",
        .search_text = "preserved wav",
        .duration_ms = 10,
        .content_hash = 55,
        .file_size = 4,
        .mtime_ns = 8,
    }};
    try db.applyFolderIndex(1, &files);
    _ = try db.setSemanticModel("preserved/model@1", 2);
    const file_id: i32 = @intCast((try db.inspectFile("preserved.wav")).?.id);
    try db.upsertSemanticEmbedding(allocator, file_id, 55, &.{ 1, 0 });
    db.close();
    try rawExec(fixture.db_path, @import("storage_schema.zig").dropForTests ++ @import("refinement_schema.zig").dropForTests ++ @import("schema_optimizations.zig").dropForTests);
    try rawExec(fixture.db_path, "DROP TRIGGER waveform_analysis_source_changed;DROP TRIGGER waveform_files_ai;DROP TRIGGER waveform_tier_rescan_au;DROP TRIGGER waveform_claim_source_changed;DROP TRIGGER waveform_claim_file_ad;DROP TABLE waveform_failures;DROP TABLE waveform_cache_state;DROP TABLE waveform_tiers;DROP TABLE waveform_analyses;DROP TRIGGER acoustic_edges_ai;DROP TRIGGER acoustic_edges_ad;DROP TABLE acoustic_group_state;DROP TABLE acoustic_groups;DROP TABLE acoustic_edges;DROP TABLE fingerprint_postings;DROP TABLE fingerprint_failures;DROP TABLE file_fingerprints;DROP TABLE fingerprint_algorithms;PRAGMA user_version=6;");
    try openFixture(&fixture);
    try std.testing.expectEqual(db.SCHEMA_VERSION, try db.schemaVersion());
    try std.testing.expectEqual(@as(i64, 1), (try db.semanticStatus()).embedded_count);
    _ = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
}

test "v7 migration preserves fingerprints and adds current derived schemas" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{.{ .path = "/v7.wav", .relative_path = "v7.wav", .name = "v7.wav", .search_text = "v7 wav", .duration_ms = 1, .content_hash = 71, .file_size = 1, .mtime_ns = 1 }};
    try db.applyFolderIndex(1, &files);
    const file_id: i32 = @intCast((try db.inspectFile("v7.wav")).?.id);
    const algorithm_id = try db.ensureFingerprintAlgorithm("legacy-fingerprint-v7");
    const landmarks = [_]fingerprint.Landmark{ .{ .hash = 1, .frame = 1 }, .{ .hash = 2, .frame = 2 }, .{ .hash = 3, .frame = 3 }, .{ .hash = 4, .frame = 4 }, .{ .hash = 5, .frame = 5 }, .{ .hash = 6, .frame = 6 } };
    const blob = try fingerprint.serialize(allocator, &landmarks);
    defer allocator.free(blob);
    const selected = try fingerprint.selectors(allocator, &landmarks);
    defer allocator.free(selected);
    try db.upsertFingerprint(algorithm_id, file_id, 71, blob, selected);
    db.close();
    try rawExec(fixture.db_path, @import("storage_schema.zig").dropForTests ++ @import("refinement_schema.zig").dropForTests ++ @import("schema_optimizations.zig").dropForTests);
    try rawExec(fixture.db_path, "DROP TRIGGER waveform_analysis_source_changed;DROP TRIGGER waveform_files_ai;DROP TRIGGER waveform_tier_rescan_au;DROP TRIGGER waveform_claim_source_changed;DROP TRIGGER waveform_claim_file_ad;DROP TABLE waveform_failures;DROP TABLE waveform_cache_state;DROP TABLE waveform_tiers;DROP TABLE waveform_analyses;DROP TRIGGER acoustic_edges_ai;DROP TRIGGER acoustic_edges_ad;DROP TABLE acoustic_group_state;DROP TABLE acoustic_groups;DROP TABLE acoustic_edges;PRAGMA user_version=7;");
    try openFixture(&fixture);
    try std.testing.expectEqual(db.SCHEMA_VERSION, try db.schemaVersion());
    var stored = (try db.loadFingerprint(allocator, algorithm_id, file_id)).?;
    defer stored.deinit(allocator);
    try std.testing.expectEqual(blob.len, stored.landmarks.len);
    try db.rebuildAcousticGroups(allocator, algorithm_id);
    try std.testing.expectEqual(@as(u32, 1), (try db.acousticGroupInfo(algorithm_id, file_id)).?.member_count);
}

test "v8 migration preserves legacy waveform and adds current derived schemas" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{.{ .path = "/v8.wav", .relative_path = "v8.wav", .name = "v8.wav", .search_text = "v8 wav", .duration_ms = 1, .content_hash = 8, .file_size = 8, .mtime_ns = 8 }};
    try db.applyFolderIndex(8, &files);
    try db.saveWaveform(files[0].path, &.{ 0.25, 0.5 });
    db.close();
    try rawExec(fixture.db_path, @import("storage_schema.zig").dropForTests ++ @import("refinement_schema.zig").dropForTests ++ @import("schema_optimizations.zig").dropForTests);
    try rawExec(fixture.db_path, "DROP TRIGGER waveform_analysis_source_changed;DROP TRIGGER waveform_files_ai;DROP TRIGGER waveform_tier_rescan_au;DROP TRIGGER waveform_claim_source_changed;DROP TRIGGER waveform_claim_file_ad;DROP TABLE waveform_failures;DROP TABLE waveform_cache_state;DROP TABLE waveform_tiers;DROP TABLE waveform_analyses;PRAGMA user_version=8;");
    try openFixture(&fixture);
    try std.testing.expectEqual(db.SCHEMA_VERSION, try db.schemaVersion());
    const legacy = (try db.getWaveform(allocator, files[0].path)).?;
    defer allocator.free(legacy);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.5 }, legacy);
    try db.saveWaveformCacheBlob(files[0].path, "WWF2");
    try std.testing.expectEqual(@as(?usize, 4), try db.waveformCacheBlobSize(files[0].path, 1024));
}

test "v9 migration invalidates legacy analysis and adds current derived schemas" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{.{ .path = "/v9.wav", .relative_path = "v9.wav", .name = "v9.wav", .search_text = "v9 wav", .duration_ms = 1, .content_hash = 9, .file_size = 9, .mtime_ns = 9 }};
    try db.applyFolderIndex(9, &files);
    try db.saveWaveformCacheBlob(files[0].path, "WWF2-old");
    db.close();
    try rawExec(fixture.db_path, @import("storage_schema.zig").dropForTests ++ @import("refinement_schema.zig").dropForTests ++ @import("schema_optimizations.zig").dropForTests);
    try rawExec(fixture.db_path, "DROP TRIGGER waveform_analysis_source_changed;DROP TRIGGER waveform_files_ai;DROP TRIGGER waveform_tier_rescan_au;DROP TRIGGER waveform_claim_source_changed;DROP TRIGGER waveform_claim_file_ad;DROP TABLE waveform_failures;DROP TABLE waveform_cache_state;DROP TABLE waveform_tiers;CREATE TRIGGER waveform_analysis_source_changed AFTER UPDATE OF file_size,mtime_ns,content_hash ON files BEGIN DELETE FROM waveform_analyses WHERE file_id=new.id; END;PRAGMA user_version=9;");
    try openFixture(&fixture);
    try std.testing.expectEqual(db.SCHEMA_VERSION, try db.schemaVersion());
    try std.testing.expectEqual(@as(?usize, null), try db.waveformCacheBlobSize(files[0].path, 1024));
    const status = try db.waveformCacheStatus();
    try std.testing.expectEqual(@as(i64, 1), status.pending_count);
    try std.testing.expectEqual(@as(i64, 256 * 1024 * 1024), status.detailed_budget_bytes);
}

test "early development v10 failure rows and claim columns upgrade safely" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{.{ .path = "/dev10.wav", .relative_path = "dev10.wav", .name = "dev10.wav", .search_text = "dev10 wav", .duration_ms = 1, .content_hash = 10, .file_size = 100, .mtime_ns = 200 }};
    try db.applyFolderIndex(10, &files);
    db.close();
    try rawExec(fixture.db_path, @import("storage_schema.zig").dropForTests ++ @import("refinement_schema.zig").dropForTests ++ @import("schema_optimizations.zig").dropForTests ++ db.DROP_QUANTIZED_INDEX_SQL ++ "PRAGMA user_version=10;");
    try rawExec(fixture.db_path, "DROP TRIGGER waveform_claim_source_changed;DROP TRIGGER waveform_claim_file_ad;" ++
        "DROP TRIGGER waveform_analysis_source_changed;" ++
        "CREATE TRIGGER waveform_analysis_source_changed AFTER UPDATE OF file_size,mtime_ns,content_hash ON files BEGIN DELETE FROM waveform_analyses WHERE file_id=new.id;DELETE FROM waveform_tiers WHERE file_id=new.id;DELETE FROM waveform_failures WHERE file_id=new.id;UPDATE waveform_cache_state SET universal_scan_complete=0 WHERE singleton=1;END;" ++
        "ALTER TABLE waveform_cache_state DROP COLUMN waveform_claimed_file_id;" ++
        "ALTER TABLE waveform_cache_state DROP COLUMN waveform_claim_token;" ++
        "ALTER TABLE waveform_cache_state DROP COLUMN waveform_claim_until_ns;" ++
        "ALTER TABLE waveform_failures DROP COLUMN source_file_size;" ++
        "ALTER TABLE waveform_failures DROP COLUMN source_mtime_ns;" ++
        "INSERT INTO waveform_failures(file_id,source_content_hash,permanent,attempt_count,retry_after_ns,detail) VALUES(1,10,1,1,0,'legacy');" ++
        "UPDATE waveform_cache_state SET universal_scan_complete=1 WHERE singleton=1;");
    try openFixture(&fixture);
    const status = try db.waveformCacheStatus();
    try std.testing.expectEqual(@as(i64, 0), status.failed_count);
    try std.testing.expectEqual(@as(i64, 1), status.pending_count);
    var claim = std.mem.zeroes(main_c.WSWaveformWorkClaim);
    claim.struct_size = @sizeOf(main_c.WSWaveformWorkClaim);
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_waveform_work_claim_v2(&claim));
    try std.testing.expectEqual(@as(c_int, 1), claim.file_id);
}

test "expired waveform claim is reclaimed before cursor advances" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{
        .{ .path = "/claim-a.wav", .relative_path = "claim-a.wav", .name = "claim-a.wav", .search_text = "claim a wav", .duration_ms = 1, .content_hash = 1, .file_size = 10, .mtime_ns = 10 },
        .{ .path = "/claim-b.wav", .relative_path = "claim-b.wav", .name = "claim-b.wav", .search_text = "claim b wav", .duration_ms = 1, .content_hash = 2, .file_size = 20, .mtime_ns = 20 },
    };
    try db.applyFolderIndex(11, &files);
    var first = std.mem.zeroes(main_c.WSWaveformWorkClaim);
    first.struct_size = @sizeOf(main_c.WSWaveformWorkClaim);
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_waveform_work_claim_v2(&first));
    db.close();
    try rawExec(fixture.db_path, "UPDATE waveform_cache_state SET waveform_claim_until_ns=0 WHERE singleton=1;");
    try openFixture(&fixture);
    var reclaimed = std.mem.zeroes(main_c.WSWaveformWorkClaim);
    reclaimed.struct_size = @sizeOf(main_c.WSWaveformWorkClaim);
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_waveform_work_claim_v2(&reclaimed));
    try std.testing.expectEqual(first.file_id, reclaimed.file_id);
    try std.testing.expect(reclaimed.claim_token != first.claim_token);
}

test "v3 migration directly to current schema preserves id waveform and content hash" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try rawExec(fixture.db_path, "CREATE TABLE files(" ++
        "id INTEGER PRIMARY KEY AUTOINCREMENT,folder_id INTEGER NOT NULL,path TEXT NOT NULL UNIQUE," ++
        "relative_path TEXT NOT NULL DEFAULT '',name TEXT NOT NULL,search_text TEXT NOT NULL DEFAULT ''," ++
        "duration_ms INTEGER DEFAULT 0,content_hash INTEGER DEFAULT 0,waveform BLOB);" ++
        "INSERT INTO files(id,folder_id,path,relative_path,name,search_text,duration_ms,content_hash,waveform) " ++
        "VALUES(42,7,'/old/Impact.wav','Impact.wav','Impact.wav','impact wav',1000,987654,X'0000803F');" ++
        // Synchronization trigger names may already exist in intermediate or
        // downstream v3 databases and must not make migration destructive.
        "CREATE TRIGGER files_ai AFTER INSERT ON files BEGIN SELECT 1; END;" ++
        "CREATE TRIGGER files_ad AFTER DELETE ON files BEGIN SELECT 1; END;" ++
        "CREATE TRIGGER files_au AFTER UPDATE ON files BEGIN SELECT 1; END;" ++
        "PRAGMA user_version=3;");
    try openFixture(&fixture);
    const info = (try db.inspectFile("Impact.wav")).?;
    try std.testing.expectEqual(@as(i64, 42), info.id);
    try std.testing.expectEqual(@as(i64, 987654), info.content_hash);
    try std.testing.expect(info.has_waveform);
    try std.testing.expectEqual(@as(i64, -1), info.file_size);
    try std.testing.expect(try db.refreshLegacyWaveformIdentity(42, 987654, 123, 456));
    const refreshed = (try db.inspectFile("Impact.wav")).?;
    try std.testing.expectEqual(@as(i64, 123), refreshed.file_size);
    try std.testing.expectEqual(@as(i64, 456), refreshed.mtime_ns);
    const legacy_waveform = (try db.getWaveform(allocator, "/old/Impact.wav")).?;
    defer allocator.free(legacy_waveform);
    try std.testing.expectEqual(@as(f32, 1.0), legacy_waveform[0]);
}

test "indexed substring typo duration and folder retrieval use FTS indexes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(io, "one", .default_dir);
    try fixture.tmp.dir.createDir(io, "two", .default_dir);
    try writeWav(fixture.tmp.dir, "one/Impact.wav", 1000, 1);
    try writeWav(fixture.tmp.dir, "one/ExactBoundary.wav", 2000, 4);
    try writeWav(fixture.tmp.dir, "one/SubmarineDive.wav", 3000, 2);
    try writeWav(fixture.tmp.dir, "two/WhooshTransition.wav", 1500, 3);
    try openFixture(&fixture);
    const one = try fixture.path("one");
    defer allocator.free(one);
    const two = try fixture.path("two");
    defer allocator.free(two);
    try search.indexFolder(allocator, 1, one);
    try search.indexFolder(allocator, 2, two);

    var results: [16]main_c.WSResult = undefined;
    var count = try search.search(allocator, "marine", null, &results, results.len);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("SubmarineDive.wav", resultName(&results[0]));

    count = try search.search(allocator, "impaxt", null, &results, results.len);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqualStrings("Impact.wav", resultName(&results[0]));

    count = try search.search(allocator, "<2s", null, &results, results.len);
    try std.testing.expectEqual(@as(usize, 2), count);
    count = try search.search(allocator, "<2s", 1, &results, results.len);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("Impact.wav", resultName(&results[0]));
    count = try search.search(allocator, ">1s", null, &results, results.len);
    try std.testing.expectEqual(@as(usize, 3), count);

    count = try search.search(allocator, "***", null, &results, results.len);
    try std.testing.expectEqual(@as(usize, 0), count);

    count = try search.search(allocator, "hit", null, &results, results.len);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqualStrings("Impact.wav", resultName(&results[0]));

    const production = @embedFile("search.zig");
    try std.testing.expect(std.mem.indexOf(u8, production, " LIKE ") == null);
    try std.testing.expect(std.mem.indexOf(u8, production, "%query%") == null);
}

test "exact prefix and substring rank before typo candidates" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(io, "sounds", .default_dir);
    try writeWav(fixture.tmp.dir, "sounds/Impact.wav", 500, 1);
    try writeWav(fixture.tmp.dir, "sounds/ImpactLong.wav", 500, 2);
    try writeWav(fixture.tmp.dir, "sounds/MyImpactTail.wav", 500, 3);
    try writeWav(fixture.tmp.dir, "sounds/Impaxt.wav", 500, 4);
    try openFixture(&fixture);
    const sounds = try fixture.path("sounds");
    defer allocator.free(sounds);
    try search.indexFolder(allocator, 1, sounds);
    var results: [16]main_c.WSResult = undefined;
    const count = try search.search(allocator, "impact", null, &results, results.len);
    try std.testing.expect(count >= 4);
    try std.testing.expectEqualStrings("Impact.wav", resultName(&results[0]));
    try std.testing.expectEqualStrings("ImpactLong.wav", resultName(&results[1]));
    try std.testing.expectEqualStrings("MyImpactTail.wav", resultName(&results[2]));
    try std.testing.expectEqualStrings("Impaxt.wav", resultName(&results[3]));
}

test "incremental reindex preserves unchanged ids hashes and waveforms and clears changed waveform" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(io, "sounds", .default_dir);
    try writeWav(fixture.tmp.dir, "sounds/Stable.wav", 500, 11);
    try writeWav(fixture.tmp.dir, "sounds/Gone.wav", 250, 12);
    try openFixture(&fixture);
    const sounds = try fixture.path("sounds");
    defer allocator.free(sounds);
    try search.indexFolder(allocator, 3, sounds);
    const file_path = try fixture.path("sounds/Stable.wav");
    defer allocator.free(file_path);
    const samples = [_]f32{ 0.1, 0.2, 0.3 };
    try db.saveWaveform(file_path, &samples);
    const before = (try db.inspectFile("Stable.wav")).?;

    try fixture.tmp.dir.deleteFile(io, "sounds/Gone.wav");
    try search.indexFolder(allocator, 3, sounds);
    const unchanged = (try db.inspectFile("Stable.wav")).?;
    var results: [4]main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(usize, 1), try search.search(allocator, "stable", 3, &results, results.len));
    try std.testing.expectEqual(@as(c_int, 1), try db.countForFolder(3));
    try std.testing.expect((try db.inspectFile("Gone.wav")) == null);
    try std.testing.expectEqual(before.id, unchanged.id);
    try std.testing.expectEqual(before.content_hash, unchanged.content_hash);
    try std.testing.expect(unchanged.has_waveform);

    try writeWav(fixture.tmp.dir, "sounds/Stable.wav", 750, 22);
    try search.indexFolder(allocator, 3, sounds);
    const changed = (try db.inspectFile("Stable.wav")).?;
    try std.testing.expectEqual(before.id, changed.id);
    try std.testing.expect(changed.content_hash != before.content_hash);
    try std.testing.expect(!changed.has_waveform);
}

test "index update rolls back atomically on a duplicate scanned path" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const initial = [_]db.ScannedFile{.{
        .path = "/a.wav",
        .relative_path = "a.wav",
        .name = "a.wav",
        .search_text = "a wav",
        .duration_ms = 100,
        .content_hash = 10,
        .file_size = 100,
        .mtime_ns = 1,
    }};
    try db.applyFolderIndex(9, &initial);
    const broken = [_]db.ScannedFile{
        .{ .path = "/a.wav", .relative_path = "a.wav", .name = "a.wav", .search_text = "changed", .duration_ms = 200, .content_hash = 20, .file_size = 200, .mtime_ns = 2 },
        .{ .path = "/other.wav", .relative_path = "a.wav", .name = "other.wav", .search_text = "other", .duration_ms = 1, .content_hash = 1, .file_size = 1, .mtime_ns = 1 },
    };
    try std.testing.expectError(error.DuplicateRelativePath, db.applyFolderIndex(9, &broken));
    const after = (try db.inspectFile("a.wav")).?;
    try std.testing.expectEqual(@as(i64, 100), after.file_size);
    try std.testing.expectEqual(@as(i64, 10), after.content_hash);
}

test "ranked search fits a dispatch-sized worker stack" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);

    var owned_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_paths.items) |path| allocator.free(path);
        owned_paths.deinit(allocator);
    }
    var records: std.ArrayList(db.ScannedFile) = .empty;
    defer records.deinit(allocator);
    for (0..256) |i| {
        const path = try std.fmt.allocPrint(allocator, "/impact-{d}.wav", .{i});
        try owned_paths.append(allocator, path);
        const name = path[1..];
        try records.append(allocator, .{
            .path = path,
            .relative_path = name,
            .name = name,
            .search_text = name,
            .duration_ms = 100,
            .content_hash = @intCast(i + 1),
            .file_size = 100,
            .mtime_ns = 1,
        });
    }
    try db.applyFolderIndex(10, records.items);

    var failed: std.atomic.Value(bool) = .init(false);
    var worker = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, smallStackSearchWorker, .{&failed});
    worker.join();
    try std.testing.expect(!failed.load(.acquire));
}

test "exact 512-D scan fits a dispatch-sized worker stack" {
    const dimension = 512;
    const count = 1000;
    const vectors = try allocator.alloc(f32, count * dimension);
    defer allocator.free(vectors);
    @memset(vectors, 0);
    const ids = try allocator.alloc(i32, count);
    defer allocator.free(ids);
    const folders = try allocator.alloc(i32, count);
    defer allocator.free(folders);
    const durations = try allocator.alloc(i32, count);
    defer allocator.free(durations);
    for (0..count) |row| {
        vectors[row * dimension + (row % dimension)] = 1;
        ids[row] = @intCast(row + 1);
        folders[row] = 1;
        durations[row] = 100;
    }
    const query = try allocator.alloc(f32, dimension);
    defer allocator.free(query);
    @memset(query, 0);
    query[0] = 1;

    var failed: std.atomic.Value(bool) = .init(false);
    var worker = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, smallStackVectorWorker, .{ &failed, query, ids, folders, durations, vectors });
    worker.join();
    try std.testing.expect(!failed.load(.acquire));
}

fn smallStackVectorWorker(failed: *std.atomic.Value(bool), query: []const f32, ids: []const i32, folders: []const i32, durations: []const i32, vectors: []const f32) void {
    const matches = vector.exactTopK(std.heap.c_allocator, query, ids, folders, durations, vectors, query.len, .{}, 20) catch {
        failed.store(true, .release);
        return;
    };
    defer std.heap.c_allocator.free(matches);
    if (matches.len != 20 or matches[0].file_id != 1) failed.store(true, .release);
}

fn smallStackSearchWorker(failed: *std.atomic.Value(bool)) void {
    const out = std.heap.c_allocator.alloc(main_c.WSResult, 500) catch {
        failed.store(true, .release);
        return;
    };
    defer std.heap.c_allocator.free(out);
    const count = search.search(std.heap.c_allocator, "impact", null, out.ptr, out.len) catch {
        failed.store(true, .release);
        return;
    };
    if (count != 256) failed.store(true, .release);
}

test "cancelled scans preserve live index and deep scans hash every file" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(io, "cancel", .default_dir);
    try writeWav(fixture.tmp.dir, "cancel/one.wav", 100, 1);
    try openFixture(&fixture);
    const folder = try fixture.path("cancel");
    defer allocator.free(folder);
    try search.indexFolder(allocator, 9, folder);
    try std.testing.expectEqual(@as(c_int, 1), try db.countForFolder(9));
    try writeWav(fixture.tmp.dir, "cancel/two.wav", 100, 2);
    var cancelled = std.atomic.Value(bool).init(true);
    var discovered = std.atomic.Value(u64).init(0);
    try std.testing.expectError(error.Cancelled, search.indexFolderWithOptions(allocator, 9, folder, .{ .cancel = &cancelled, .discovered = &discovered }));
    try std.testing.expectError(error.Cancelled, search.indexFolderWithOptions(allocator, 9, folder, .{ .fast = true, .cancel = &cancelled, .discovered = &discovered }));
    try std.testing.expectEqual(@as(c_int, 1), try db.countForFolder(9));
    cancelled.store(false, .release);
    try search.indexFolderWithOptions(allocator, 9, folder, .{ .deep = true, .cancel = &cancelled, .discovered = &discovered });
    try std.testing.expectEqual(@as(c_int, 2), try db.countForFolder(9));
    try std.testing.expect(discovered.load(.acquire) >= 2);
}

test "waveform extraction streams long WAV sample data" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try writeFingerprintWav(fixture.tmp.dir, "long.wav", 48_000, 0, 60.0, 0.5, false);
    const path = try fixture.path("long.wav");
    defer allocator.free(path);
    var points: [256]f32 = undefined;
    try audio.waveform(path, &points, points.len);
    for (points) |point| try std.testing.expect(std.math.isFinite(point) and point >= 0 and point <= 1);
}

test "online backup restore and integrity checks recover the live database" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{.{ .path = "/backup.wav", .relative_path = "backup.wav", .name = "backup.wav", .search_text = "backup wav", .duration_ms = 1, .content_hash = 9, .file_size = 1, .mtime_ns = 1 }};
    try db.applyFolderIndex(4, &files);
    const before = try db.integrityCheck(true);
    try std.testing.expectEqual(@as(u32, 0), before.errors_found);
    try std.testing.expectError(error.UnsafeBackupDestination, db.backupTo(fixture.db_path));
    var original_claim = std.mem.zeroes(main_c.WSWaveformWorkClaim);
    original_claim.struct_size = @sizeOf(main_c.WSWaveformWorkClaim);
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_waveform_work_claim_v2(&original_claim));
    const backup_path = try fixture.path("backup.sqlite");
    defer allocator.free(backup_path);
    try db.backupTo(backup_path);
    try db.removeFolder(4);
    try std.testing.expectEqual(@as(c_int, 0), try db.countForFolder(4));
    try db.restoreFrom(backup_path);
    try std.testing.expectEqual(@as(c_int, 1), try db.countForFolder(4));
    var restored_claim = std.mem.zeroes(main_c.WSWaveformWorkClaim);
    restored_claim.struct_size = @sizeOf(main_c.WSWaveformWorkClaim);
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_waveform_work_claim_v2(&restored_claim));
    try std.testing.expect(restored_claim.claim_token != original_claim.claim_token);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_work_release(restored_claim.file_id, restored_claim.claim_token));
    const after = try db.integrityCheck(false);
    try std.testing.expectEqual(@as(u32, 0), after.errors_found);

    const future_path = try fixture.path("future.sqlite");
    defer allocator.free(future_path);
    try rawExec(future_path, "CREATE TABLE files(id INTEGER PRIMARY KEY);PRAGMA user_version=99;");
    try std.testing.expectError(error.FutureSchemaVersion, db.restoreFrom(future_path));
    try std.testing.expectEqual(@as(c_int, 1), try db.countForFolder(4));

    const malformed_path = try fixture.path("malformed.sqlite");
    defer allocator.free(malformed_path);
    try rawExec(malformed_path, "CREATE TABLE files(id INTEGER PRIMARY KEY);PRAGMA user_version=8;");
    try std.testing.expectError(error.InvalidBackupSchema, db.restoreFrom(malformed_path));
    try std.testing.expectEqual(@as(c_int, 1), try db.countForFolder(4));

    const malformed_legacy_path = try fixture.path("malformed-v3.sqlite");
    defer allocator.free(malformed_legacy_path);
    try rawExec(malformed_legacy_path, "CREATE TABLE files(id INTEGER PRIMARY KEY);PRAGMA user_version=3;");
    try std.testing.expectError(error.InvalidBackupSchema, db.restoreFrom(malformed_legacy_path));
    try std.testing.expectEqual(@as(c_int, 1), try db.countForFolder(4));
}

test "concurrent search list and waveform database operations are safe" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(io, "sounds", .default_dir);
    try writeWav(fixture.tmp.dir, "sounds/ConcurrentImpact.wav", 200, 5);
    try openFixture(&fixture);
    const sounds = try fixture.path("sounds");
    defer allocator.free(sounds);
    const file_path = try fixture.path("sounds/ConcurrentImpact.wav");
    defer allocator.free(file_path);
    try search.indexFolder(allocator, 4, sounds);

    var failed: std.atomic.Value(bool) = .init(false);
    const args = .{ &failed, file_path };
    var t1 = try std.Thread.spawn(.{}, searchWorker, .{&failed});
    var t2 = try std.Thread.spawn(.{}, listWorker, .{&failed});
    var t3 = try std.Thread.spawn(.{}, waveformWorker, args);
    t1.join();
    t2.join();
    t3.join();
    try std.testing.expect(!failed.load(.acquire));
}

fn searchWorker(failed: *std.atomic.Value(bool)) void {
    var out: [4]main_c.WSResult = undefined;
    for (0..30) |_| {
        const count = search.search(std.heap.c_allocator, "impact", null, &out, out.len) catch {
            failed.store(true, .release);
            return;
        };
        if (count == 0) {
            failed.store(true, .release);
            return;
        }
    }
}

fn listWorker(failed: *std.atomic.Value(bool)) void {
    var out: [4]main_c.WSResult = undefined;
    for (0..30) |_| {
        const count = search.listFolder(std.heap.c_allocator, 4, &out, out.len) catch {
            failed.store(true, .release);
            return;
        };
        if (count != 1) {
            failed.store(true, .release);
            return;
        }
    }
}

fn waveformWorker(failed: *std.atomic.Value(bool), path: []const u8) void {
    const values = [_]f32{ 0.25, 0.5, 0.75 };
    for (0..30) |_| {
        db.saveWaveform(path, &values) catch {
            failed.store(true, .release);
            return;
        };
        const got = db.getWaveform(std.heap.c_allocator, path) catch {
            failed.store(true, .release);
            return;
        } orelse {
            failed.store(true, .release);
            return;
        };
        defer std.heap.c_allocator.free(got);
        if (got.len != values.len) {
            failed.store(true, .release);
            return;
        }
    }
}

test "waveform cache is regenerated when requested resolution changes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(io, "sounds", .default_dir);
    try writeWav(fixture.tmp.dir, "sounds/Wave.wav", 100, 7);
    try openFixture(&fixture);
    const sounds = try fixture.path("sounds");
    defer allocator.free(sounds);
    const file_path = try fixture.path("sounds/Wave.wav");
    defer allocator.free(file_path);
    try search.indexFolder(allocator, 5, sounds);
    try db.saveWaveform(file_path, &.{ 0.1, 0.2 });

    const path_z = try allocator.dupeSentinel(u8, file_path, 0);
    defer allocator.free(path_z);
    var output: [3]f32 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform(path_z, &output, output.len));
    const cached = (try db.getWaveform(allocator, file_path)).?;
    defer allocator.free(cached);
    try std.testing.expectEqual(@as(usize, output.len), cached.len);

    const identity = (try db.legacyWaveformIdentity(file_path)).?;
    const changed = [_]db.ScannedFile{.{
        .path = file_path,
        .relative_path = "Wave.wav",
        .name = "Wave.wav",
        .search_text = "wave wav",
        .duration_ms = 2,
        .content_hash = identity.content_hash + 1,
        .file_size = identity.file_size,
        .mtime_ns = identity.mtime_ns,
    }};
    try db.applyFolderIndex(5, &changed);
    try std.testing.expect(!try db.saveWaveformIfIdentity(file_path, identity, &output));
    try std.testing.expect((try db.getWaveform(allocator, file_path)) == null);
}

test "opaque waveform analysis cache is bounded and round trips through C ABI" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{.{
        .path = "/cache/peaks.wav",
        .relative_path = "peaks.wav",
        .name = "peaks.wav",
        .search_text = "peaks wav",
        .duration_ms = 1,
        .content_hash = 7,
        .file_size = 9,
        .mtime_ns = 11,
    }};
    try db.applyFolderIndex(12, &files);
    const path_z = try allocator.dupeSentinel(u8, files[0].path, 0);
    defer allocator.free(path_z);
    const blob = "WSW2-min-max-pyramid";
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_cache_store(path_z.ptr, blob.ptr, blob.len));
    try std.testing.expectEqual(@as(i64, blob.len), main_c.ws_waveform_cache_size(path_z.ptr));
    var output: [64]u8 = undefined;
    const loaded = main_c.ws_waveform_cache_load(path_z.ptr, &output, output.len);
    try std.testing.expectEqual(@as(c_int, blob.len), loaded);
    try std.testing.expectEqualSlices(u8, blob, output[0..@intCast(loaded)]);
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_waveform_cache_load(path_z.ptr, &output, 2));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_waveform_cache_store(path_z.ptr, null, 1));
    const changed = [_]db.ScannedFile{.{
        .path = files[0].path,
        .relative_path = files[0].relative_path,
        .name = files[0].name,
        .search_text = files[0].search_text,
        .duration_ms = 2,
        .content_hash = 8,
        .file_size = 10,
        .mtime_ns = 12,
    }};
    try db.applyFolderIndex(12, &changed);
    try std.testing.expectEqual(@as(i64, 0), main_c.ws_waveform_cache_size(path_z.ptr));
}

test "selective refinement cancellation preserves active metadata scan" {
    const stale_generation = main_c.ws_refinement_generation();
    _ = main_c.ws_cancel_refinement();
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_acoustic_index_pending_v2(-1, 1, stale_generation));
    try std.testing.expectEqualStrings("Cancelled", std.mem.span(main_c.ws_last_error_message()));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_clap_index_pending_v2(-1, 1, stale_generation));
    try std.testing.expectEqualStrings("Cancelled", std.mem.span(main_c.ws_last_error_message()));

    try operations.begin(42, false);
    defer operations.finish({});
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_cancel_refinement());
    try std.testing.expect(operations.status().active);
    try std.testing.expect(!operations.status().cancel_requested);
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_cancel_indexing());
    try std.testing.expect(operations.status().cancel_requested);
}

test "query cancellation is sticky and isolated from legacy calls and refinement" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const request = main_c.ws_query_create().?;
    defer main_c.ws_query_destroy(request);
    const other = main_c.ws_query_create().?;
    defer main_c.ws_query_destroy(other);
    var out: [2]main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_search_v2(request, "click", -1, &out, 2, 1));
    const refinement_generation = main_c.ws_refinement_generation();
    const canceller = try std.Thread.spawn(.{}, struct {
        fn run(value: *@import("query.zig").Request) void {
            main_c.ws_query_cancel(value);
        }
    }.run, .{request});
    canceller.join();
    // Cancel after the lexical stage, before hybrid dispatch. No lexical fallback.
    try std.testing.expectEqual(@as(c_int, -2), main_c.ws_search_v2(request, "click", -1, &out, 2, 0));
    try std.testing.expectEqualStrings("Cancelled", std.mem.span(main_c.ws_last_error_message()));
    try std.testing.expectEqual(@as(c_int, -2), main_c.ws_list_folder_v2(request, 1, &out, 2));
    try std.testing.expectEqual(@as(c_int, -2), main_c.ws_search_by_example_v2(request, "/missing.wav", -1, null, 0));
    try std.testing.expectEqual(@as(c_int, -2), main_c.ws_search_by_example_pcm_v2(request, null, 0, 0, 0, -1, null, 0));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_search_v2(other, "click", -1, &out, 2, 0));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_search("click", -1, &out, 2));
    try std.testing.expectEqual(refinement_generation, main_c.ws_refinement_generation());
    _ = main_c.ws_cancel_indexing();
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_list_folder_v2(other, 1, &out, 2));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_search_v2(null, "click", -1, &out, 2, 0));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_search_v2(other, "click", -1, &out, 2, 99));

    const query = @import("query.zig");
    query.current = request;
    defer query.current = null;
    try std.testing.expectError(error.Cancelled, clap_audio.preprocessWavBytes(allocator, &.{}));
    try std.testing.expectError(error.Cancelled, fingerprint.fromSamples(allocator, &.{}));
    try std.testing.expectError(error.Cancelled, db.streamActiveVectorTopK(allocator, &.{1}, .{}, 1));
}

test "portable streaming waveform analyzer is chunk and layout invariant" {
    const frames: usize = 4097;
    const left = try allocator.alloc(f32, frames);
    defer allocator.free(left);
    const right = try allocator.alloc(f32, frames);
    defer allocator.free(right);
    const interleaved = try allocator.alloc(f32, frames * 2);
    defer allocator.free(interleaved);
    for (0..frames) |index| {
        left[index] = @as(f32, @floatFromInt(@as(i32, @intCast(index % 257)) - 128)) / 128;
        right[index] = @as(f32, @floatFromInt(@as(i32, @intCast(index % 113)) - 56)) / 64;
        interleaved[index * 2] = left[index];
        interleaved[index * 2 + 1] = right[index];
    }
    left[1023] = std.math.nan(f32);
    interleaved[1023 * 2] = std.math.nan(f32);

    const config = main_c.WSWaveformAnalyzerConfig{
        .struct_size = @sizeOf(main_c.WSWaveformAnalyzerConfig),
        .version = waveform.types.WS_WAVEFORM_ANALYZER_ABI_VERSION,
        .purpose = waveform.PURPOSE_DETAILED,
        .flags = waveform.FLAG_LOUDNESS,
        .backend = waveform.BACKEND_PORTABLE,
        .reserved0 = 0,
        .sample_rate = 48_000,
        .total_frames = frames,
        .channel_count = 2,
        .reserved1 = 0,
        .source_file_size = 123,
        .source_mtime_ns = 456,
        .source_content_hash = 789,
        .reserved = .{ 0, 0 },
    };
    const planar_analyzer = try waveform.Analyzer.create(allocator, config);
    defer planar_analyzer.deinit();
    var offset: usize = 0;
    const chunk_sizes = [_]usize{ 1, 7, 1024, 3065 };
    for (chunk_sizes) |chunk| {
        var planes = [_]?[*]const f32{ left.ptr + offset, right.ptr + offset };
        try planar_analyzer.push(.{
            .struct_size = @sizeOf(main_c.WSWaveformPCMBuffer),
            .version = waveform.types.WS_WAVEFORM_PCM_BUFFER_VERSION,
            .layout = waveform.LAYOUT_PLANAR,
            .channel_count = 2,
            .frame_count = chunk,
            .interleaved = null,
            .planes = planes[0..].ptr,
            .reserved = .{ 0, 0 },
        });
        offset += chunk;
    }
    const planar = try planar_analyzer.finish();
    defer planar.deinit();

    const interleaved_analyzer = try waveform.Analyzer.create(allocator, config);
    defer interleaved_analyzer.deinit();
    try interleaved_analyzer.push(.{
        .struct_size = @sizeOf(main_c.WSWaveformPCMBuffer),
        .version = waveform.types.WS_WAVEFORM_PCM_BUFFER_VERSION,
        .layout = waveform.LAYOUT_INTERLEAVED,
        .channel_count = 2,
        .frame_count = frames,
        .interleaved = interleaved.ptr,
        .planes = null,
        .reserved = .{ 0, 0 },
    });
    const interleaved_result = try interleaved_analyzer.finish();
    defer interleaved_result.deinit();

    try std.testing.expectEqual(@as(usize, 4), planar.levels.len);
    try std.testing.expectEqual(@as(usize, 512), planar.levels[0].bucket_count);
    try std.testing.expectEqual(@as(usize, 4096), planar.levels[3].bucket_count);
    for (planar.levels, interleaved_result.levels) |a, b| try std.testing.expectEqualSlices(i8, a.codes, b.codes);
    try std.testing.expectApproxEqAbs(planar.integrated_lufs.?, interleaved_result.integrated_lufs.?, 0.000_000_001);
    try std.testing.expectApproxEqAbs(planar.sample_peak_dbfs.?, interleaved_result.sample_peak_dbfs.?, 0.000_000_001);
}

test "portable waveform WVT3 codec round trips and rejects corruption" {
    const peaks = [_]main_c.WSWaveformPeak{
        .{ .minimum = -1, .maximum = 0.5 },
        .{ .minimum = -0.25, .maximum = 0.75 },
        .{ .minimum = -0.5, .maximum = 1 },
        .{ .minimum = 0, .maximum = 0 },
    };
    var info = std.mem.zeroes(main_c.WSWaveformResultInfo);
    info.struct_size = @sizeOf(main_c.WSWaveformResultInfo);
    info.version = waveform.types.WS_WAVEFORM_RESULT_INFO_VERSION;
    info.purpose = waveform.PURPOSE_DETAILED;
    info.resolved_backend = waveform.BACKEND_PORTABLE;
    info.flags = waveform.RESULT_LOUDNESS_COMPLETE | waveform.RESULT_LUFS_VALID | waveform.RESULT_SAMPLE_PEAK_VALID;
    info.level_count = 1;
    info.level_bucket_counts[0] = 2;
    info.sample_rate = 48_000;
    info.frame_count = 2;
    info.source_channel_count = 2;
    info.rendered_channel_count = 2;
    info.source_file_size = 100;
    info.source_mtime_ns = 200;
    info.source_content_hash = 300;
    info.integrated_lufs = -18.25;
    info.sample_peak_dbfs = -1;
    const result = try waveform.resultFromHost(allocator, info, &peaks);
    defer result.deinit();
    const size = try waveform.serializedSize(result, waveform.TIER_DETAILED);
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    _ = try waveform.serialize(result, waveform.TIER_DETAILED, bytes);
    try std.testing.expectEqualSlices(u8, &.{ 129, 111, 160, 120, 145, 127, 0, 0 }, bytes[88..96]);
    const decoded = try waveform.deserialize(allocator, bytes);
    defer decoded.deinit();
    const bytes_again = try allocator.alloc(u8, size);
    defer allocator.free(bytes_again);
    _ = try waveform.serialize(decoded, waveform.TIER_DETAILED, bytes_again);
    try std.testing.expectEqualSlices(u8, bytes, bytes_again);

    std.mem.writeInt(u64, bytes[44..52], @bitCast(@as(f64, 7_999)), .little);
    std.mem.writeInt(u64, bytes[bytes.len - 8 ..][0..8], waveform.checksum64(bytes[0 .. bytes.len - 8]), .little);
    try std.testing.expectError(error.CorruptWvt3, waveform.deserialize(allocator, bytes));
    _ = try waveform.serialize(result, waveform.TIER_DETAILED, bytes);
    bytes[24] ^= 1;
    try std.testing.expectError(error.CorruptWvt3, waveform.deserialize(allocator, bytes));

    var invalid_info = info;
    invalid_info.frame_count = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidArgument, waveform.resultFromHost(allocator, invalid_info, &peaks));
    invalid_info = info;
    invalid_info.sample_rate = 7_999;
    try std.testing.expectError(error.InvalidArgument, waveform.resultFromHost(allocator, invalid_info, &peaks));
}

test "streaming waveform analyzer validates lifecycle and cancellation" {
    var config = std.mem.zeroes(main_c.WSWaveformAnalyzerConfig);
    config.struct_size = @sizeOf(main_c.WSWaveformAnalyzerConfig);
    config.version = waveform.types.WS_WAVEFORM_ANALYZER_ABI_VERSION;
    config.purpose = waveform.PURPOSE_UNIVERSAL;
    config.backend = waveform.BACKEND_PORTABLE;
    config.sample_rate = 48_000;
    config.total_frames = 4;
    config.channel_count = 1;
    config.source_file_size = 1;
    config.source_mtime_ns = 1;
    const analyzer = try waveform.Analyzer.create(allocator, config);
    defer analyzer.deinit();
    try std.testing.expectError(error.FrameCountMismatch, analyzer.finish());
    analyzer.cancel();
    const samples = [_]f32{ 0, 1, -1, 0 };
    var planes = [_]?[*]const f32{samples[0..].ptr};
    try std.testing.expectError(error.Cancelled, analyzer.push(.{
        .struct_size = @sizeOf(main_c.WSWaveformPCMBuffer),
        .version = waveform.types.WS_WAVEFORM_PCM_BUFFER_VERSION,
        .layout = waveform.LAYOUT_PLANAR,
        .channel_count = 1,
        .frame_count = samples.len,
        .interleaved = null,
        .planes = planes[0..].ptr,
        .reserved = .{ 0, 0 },
    }));
    config.version = 99;
    try std.testing.expectError(error.UnsupportedVersion, waveform.Analyzer.create(allocator, config));
    config.version = waveform.types.WS_WAVEFORM_ANALYZER_ABI_VERSION;
    config.flags = waveform.FLAG_LOUDNESS;
    config.sample_rate = 7_999;
    try std.testing.expectError(error.InvalidArgument, waveform.Analyzer.create(allocator, config));
}

test "clearing waveform cache preserves the index and reopens pending work" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{
        .{ .path = "/cache/clear.wav", .relative_path = "clear.wav", .name = "clear.wav", .search_text = "clear wav", .duration_ms = 1, .content_hash = 17, .file_size = 19, .mtime_ns = 23 },
        .{ .path = "/cache/retry.wav", .relative_path = "retry.wav", .name = "retry.wav", .search_text = "retry wav", .duration_ms = 1, .content_hash = 18, .file_size = 20, .mtime_ns = 24 },
    };
    try db.applyFolderIndex(2, &files);
    const id: i32 = @intCast((try db.inspectFile("clear.wav")).?.id);
    const retry_id: i32 = @intCast((try db.inspectFile("retry.wav")).?.id);
    var claim = std.mem.zeroes(main_c.WSWaveformWorkClaim);
    claim.struct_size = @sizeOf(main_c.WSWaveformWorkClaim);
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_waveform_work_claim_v2(&claim));
    try db.saveWaveform(files[0].path, &.{ 0.25, -0.25 });
    try db.saveWaveformCacheBlob(files[0].path, "legacy-analysis");
    try db.storeWaveformTiers(id, 17, 19, 23, 3, "universal", "detailed");
    try db.recordWaveformFailure(retry_id, 18, 20, 24, null, true, "decode failure");
    const before = try db.waveformCacheStatus();
    try std.testing.expectEqual(@as(i64, 1), before.universal_count);
    try std.testing.expectEqual(@as(i64, 1), before.failed_count);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_cache_clear());
    const after = try db.waveformCacheStatus();
    try std.testing.expectEqual(@as(i64, 0), after.universal_bytes);
    try std.testing.expectEqual(@as(i64, 0), after.detailed_bytes);
    try std.testing.expectEqual(@as(i64, 0), after.failed_count);
    try std.testing.expectEqual(@as(i64, 2), after.pending_count);
    try std.testing.expectEqual(before.detailed_budget_bytes, after.detailed_budget_bytes);
    try std.testing.expectEqual(@as(c_int, 2), main_c.ws_folder_count(2));
    try std.testing.expect(!(try db.inspectFile("clear.wav")).?.has_waveform);
    try std.testing.expectEqual(@as(?usize, null), try db.waveformCacheBlobSize(files[0].path, 1024));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_waveform_work_renew(claim.file_id, claim.claim_token));
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_waveform_work_claim_v2(&claim));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_work_release(claim.file_id, claim.claim_token));
    var results: [4]main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_search("clear", 2, &results, 4));
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
}

test "schema v10 waveform tiers store atomically enforce identity and evict detailed LRU" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{.{
        .path = "/cache/tier.wav",
        .relative_path = "tier.wav",
        .name = "tier.wav",
        .search_text = "tier wav",
        .duration_ms = 1,
        .content_hash = 17,
        .file_size = 19,
        .mtime_ns = 23,
    }};
    try db.applyFolderIndex(2, &files);
    const file_id: c_int = @intCast((try db.inspectFile("tier.wav")).?.id);
    var claim = std.mem.zeroes(main_c.WSWaveformWorkClaim);
    claim.struct_size = @sizeOf(main_c.WSWaveformWorkClaim);
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_waveform_work_claim_v2(&claim));
    try std.testing.expectEqual(file_id, claim.file_id);
    try std.testing.expect(claim.claim_token != 0);
    var work = std.mem.zeroes(main_c.WSWaveformWorkItem);
    work.struct_size = @sizeOf(main_c.WSWaveformWorkItem);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_work_claim(&work));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_work_renew(file_id, claim.claim_token));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_work_release(file_id, claim.claim_token));
    const first_token = claim.claim_token;
    claim.struct_size = @sizeOf(main_c.WSWaveformWorkClaim);
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_waveform_work_claim_v2(&claim));
    try std.testing.expect(claim.claim_token != first_token);
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_waveform_work_release(file_id, first_token));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_work_claim(&work));

    const universal = "mu8-universal";
    const detailed = "mu8-detailed-4096";
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_tiers_store(file_id, 17, 19, 23, 3, universal.ptr, universal.len, detailed.ptr, detailed.len));
    try std.testing.expectEqual(@as(i64, universal.len), main_c.ws_waveform_tier_size(file_id, main_c.WS_WAVEFORM_TIER_UNIVERSAL));
    try std.testing.expectEqual(@as(i64, detailed.len), main_c.ws_waveform_tier_size(file_id, main_c.WS_WAVEFORM_TIER_DETAILED));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_waveform_work_fail_v2(file_id, 17, 19, 23, claim.claim_token, 1, "late failure"));
    var output: [64]u8 = undefined;
    const loaded = main_c.ws_waveform_tier_load(file_id, main_c.WS_WAVEFORM_TIER_DETAILED, &output, output.len);
    try std.testing.expectEqual(@as(c_int, detailed.len), loaded);
    try std.testing.expectEqualSlices(u8, detailed, output[0..@intCast(loaded)]);

    var status = std.mem.zeroes(main_c.WSWaveformCacheStatus);
    status.struct_size = @sizeOf(main_c.WSWaveformCacheStatus);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_cache_status(&status));
    try std.testing.expectEqual(@as(i64, 1), status.universal_count);
    try std.testing.expectEqual(@as(i64, 1), status.detailed_count);
    try std.testing.expectEqual(@as(i64, 0), status.failed_count);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_work_claim(&work));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_work_pending());
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_waveform_cache_set_detailed_budget(512 * 1024 * 1024 + 1));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_cache_set_detailed_budget(0));
    try std.testing.expectEqual(@as(i64, 0), main_c.ws_waveform_tier_size(file_id, main_c.WS_WAVEFORM_TIER_DETAILED));
    try std.testing.expectEqual(@as(i64, universal.len), main_c.ws_waveform_tier_size(file_id, main_c.WS_WAVEFORM_TIER_UNIVERSAL));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_waveform_tiers_store(file_id, 999, 19, 23, 3, universal.ptr, universal.len, null, 0));
    try std.testing.expectError(error.StaleWaveformIdentity, db.recordWaveformFailure(file_id, 17, 999, 23, null, false, "stale"));
}

test "semantic embeddings preserve relocation invalidate changes and cascade deletes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const initial = [_]db.ScannedFile{.{
        .path = "/old/Stable.wav",
        .relative_path = "Stable.wav",
        .name = "Stable.wav",
        .search_text = "stable wav",
        .duration_ms = 100,
        .content_hash = 11,
        .file_size = 10,
        .mtime_ns = 20,
    }};
    try db.applyFolderIndex(1, &initial);
    const file_id: i32 = @intCast((try db.inspectFile("Stable.wav")).?.id);
    const model_id = try db.setSemanticModel("clap/test@1", 3);
    try db.upsertSemanticEmbedding(allocator, file_id, 11, &.{ 1, 0, 0 });
    const embedded = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 1), embedded.embedded_count);
    try std.testing.expectEqual(@as(i64, 0), embedded.pending_count);

    const relocated = [_]db.ScannedFile{.{
        .path = "/new-root/Stable.wav",
        .relative_path = "Stable.wav",
        .name = "ignored.wav",
        .search_text = "ignored",
        .duration_ms = 999,
        .content_hash = 11,
        .file_size = 10,
        .mtime_ns = 20,
    }};
    try db.applyFolderIndex(1, &relocated);
    const after_relocation = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 1), after_relocation.embedded_count);
    try std.testing.expectEqual(embedded.generation, after_relocation.generation);

    const changed = [_]db.ScannedFile{.{
        .path = "/new-root/Stable.wav",
        .relative_path = "Stable.wav",
        .name = "Stable.wav",
        .search_text = "stable changed",
        .duration_ms = 200,
        .content_hash = 22,
        .file_size = 11,
        .mtime_ns = 21,
    }};
    try db.applyFolderIndex(1, &changed);
    const invalidated = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 0), invalidated.embedded_count);
    try std.testing.expectEqual(@as(i64, 1), invalidated.pending_count);
    try std.testing.expect(invalidated.generation > after_relocation.generation);
    try std.testing.expectError(error.StaleContentHash, db.upsertSemanticEmbedding(allocator, file_id, 11, &.{ 1, 0, 0 }));

    try db.upsertSemanticEmbedding(allocator, file_id, 22, &.{ 1, 0, 0 });
    try db.applyFolderIndex(1, &.{});
    db.close();
    try std.testing.expectEqual(@as(i64, 0), try rawScalar(fixture.db_path, "SELECT COUNT(*) FROM file_embeddings;"));

    // Model-side cascading is part of the same schema contract.
    try openFixture(&fixture);
    const replacement = [_]db.ScannedFile{.{
        .path = "/x.wav",
        .relative_path = "x.wav",
        .name = "x.wav",
        .search_text = "x wav",
        .duration_ms = 1,
        .content_hash = 30,
        .file_size = 1,
        .mtime_ns = 1,
    }};
    try db.applyFolderIndex(2, &replacement);
    const replacement_id: i32 = @intCast((try db.inspectFile("x.wav")).?.id);
    _ = try db.setSemanticModel("clap/test@1", 3);
    try db.upsertSemanticEmbedding(allocator, replacement_id, 30, &.{ 1, 0, 0 });
    db.close();
    const delete_sql = try std.fmt.allocPrintSentinel(allocator, "PRAGMA foreign_keys=ON;DELETE FROM embedding_models WHERE id={d};", .{model_id}, 0);
    defer allocator.free(delete_sql);
    try rawExec(fixture.db_path, delete_sql);
    try std.testing.expectEqual(@as(i64, 0), try rawScalar(fixture.db_path, "SELECT COUNT(*) FROM file_embeddings;"));
}

test "semantic failures resume invalidate and remain isolated by model revision" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{
        .{ .path = "/a.wav", .relative_path = "a.wav", .name = "a.wav", .search_text = "a wav", .duration_ms = 10, .content_hash = 11, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/b.mp3", .relative_path = "b.mp3", .name = "b.mp3", .search_text = "b mp3", .duration_ms = 20, .content_hash = 22, .file_size = 1, .mtime_ns = 1 },
    };
    try db.applyFolderIndex(3, &files);
    const a_id: i32 = @intCast((try db.inspectFile("a.wav")).?.id);
    const b_id: i32 = @intCast((try db.inspectFile("b.mp3")).?.id);
    const revision_one = try db.setSemanticModel("clap/revision-one", 2);
    var pending = try db.pendingSemanticFiles(allocator, null, 10);
    try std.testing.expectEqual(@as(usize, 2), pending.len);
    try std.testing.expect(pending[0].id < pending[1].id);
    db.freePendingSemanticFiles(allocator, pending);

    try db.recordEmbeddingFailure(a_id, 11, "decode", "bad wav");
    pending = try db.pendingSemanticFiles(allocator, null, 10);
    defer db.freePendingSemanticFiles(allocator, pending);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(b_id, pending[0].id);
    const after_a = try db.pendingSemanticFilesForModelAfter(allocator, revision_one, null, 10, a_id);
    defer db.freePendingSemanticFiles(allocator, after_a);
    try std.testing.expectEqual(@as(usize, 1), after_a.len);
    try std.testing.expectEqual(b_id, after_a[0].id);
    const after_b = try db.pendingSemanticFilesForModelAfter(allocator, revision_one, null, 10, b_id);
    defer db.freePendingSemanticFiles(allocator, after_b);
    try std.testing.expectEqual(@as(usize, 0), after_b.len);
    var status = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 1), status.failed_count);
    try std.testing.expectEqual(@as(i64, 1), status.pending_count);

    _ = try db.setSemanticModel("clap/revision-two", 2);
    status = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 0), status.failed_count);
    try std.testing.expectEqual(@as(i64, 2), status.pending_count);
    try db.recordEmbeddingFailureForModel(revision_one, b_id, 22, "unsupported", "only wav");
    _ = try db.setSemanticModel("clap/revision-one", 2);
    status = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 2), status.failed_count);
    try std.testing.expectEqual(@as(i64, 0), status.pending_count);

    // A successful matching upsert clears a prior failure atomically.
    try db.upsertSemanticEmbedding(allocator, a_id, 11, &.{ 1, 0 });
    status = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 1), status.failed_count);
    try std.testing.expectEqual(@as(i64, 1), status.embedded_count);

    const changed = [_]db.ScannedFile{
        .{ .path = "/a.wav", .relative_path = "a.wav", .name = "a.wav", .search_text = "changed", .duration_ms = 10, .content_hash = 33, .file_size = 2, .mtime_ns = 2 },
        files[1],
    };
    try db.applyFolderIndex(3, &changed);
    try std.testing.expectError(error.StaleContentHash, db.recordEmbeddingFailure(a_id, 11, "decode", "stale"));
    status = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 0), status.embedded_count);
    try std.testing.expectEqual(@as(i64, 1), status.failed_count); // b remains failed
    try std.testing.expectEqual(@as(i64, 1), status.pending_count); // changed a resumes
}

test "bounded refinement discovery does not revisit the completed prefix after reopen" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try db.insertSyntheticBenchmarkFiles(1600);
    const model = try db.setSemanticModel("test/pending-batches", 2);
    const algorithm = try db.ensureFingerprintAlgorithm("test/pending-batches");
    var samples: [3][2]u64 = @splat(.{ 0, 0 });
    for (0..100) |batch| {
        // Match the coordinator: each bounded call starts without a cursor.
        // Reopen near completion so process-local state cannot hide the cost.
        if (batch == 99) {
            db.close();
            try openFixture(&fixture);
        }
        const sample: ?usize = switch (batch) {
            0 => 0,
            50 => 1,
            99 => 2,
            else => null,
        };
        if (sample) |index| {
            const before = db.pendingQueryStepsForTests();
            var elapsed: [2]i128 = .{ 0, 0 };
            for (0..30) |_| {
                var start = std.Io.Clock.awake.now(io);
                const semantic_batch = try db.pendingSemanticFilesForModel(allocator, model, null, 16);
                elapsed[0] += start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
                defer db.freePendingSemanticFiles(allocator, semantic_batch);
                start = std.Io.Clock.awake.now(io);
                const acoustic_batch = try db.pendingFingerprintFiles(allocator, algorithm, null, 16);
                elapsed[1] += start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
                defer db.freePendingSemanticFiles(allocator, acoustic_batch);
                try std.testing.expectEqual(@as(usize, 16), semantic_batch.len);
                try std.testing.expectEqual(@as(usize, 16), acoustic_batch.len);
            }
            const after = db.pendingQueryStepsForTests();
            samples[index] = .{ (after[0] - before[0]) / 30, (after[1] - before[1]) / 30 };
            std.debug.print("pending_batch completion={d}% semantic_vm_steps={d} acoustic_vm_steps={d} semantic_mean_us={d} acoustic_mean_us={d}\n", .{ batch, samples[index][0], samples[index][1], @divTrunc(elapsed[0], 30_000), @divTrunc(elapsed[1], 30_000) });
        }
        const semantic_pending = try db.pendingSemanticFilesForModel(allocator, model, null, 16);
        defer db.freePendingSemanticFiles(allocator, semantic_pending);
        try std.testing.expectEqual(@as(usize, 16), semantic_pending.len);
        for (semantic_pending) |file|
            try db.upsertSemanticEmbeddingForModel(allocator, model, file.id, file.source_content_hash, &.{ 1, 0 });

        const acoustic_pending = try db.pendingFingerprintFiles(allocator, algorithm, null, 16);
        defer db.freePendingSemanticFiles(allocator, acoustic_pending);
        try std.testing.expectEqual(@as(usize, 16), acoustic_pending.len);
        for (acoustic_pending) |file|
            try db.recordFingerprintFailure(algorithm, file.id, file.source_content_hash, "unsupported", "fixture");
    }
    // Work may vary slightly with B-tree depth, but must not grow with 1584
    // completed rows. VM steps give a deterministic signal independent of CPU.
    for (samples[1..]) |later| {
        for (samples[0], later) |early, late| try std.testing.expect(late <= early * 2);
    }
}

test "durable refinement queues retain uncommitted work and requeue changed or retried sources" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const model = try db.setSemanticModel("test/queue-one", 2);
    const algorithm = try db.ensureFingerprintAlgorithm("test/queue-one");
    var files = [_]db.ScannedFile{
        .{ .path = "/a.wav", .relative_path = "a.wav", .name = "a.wav", .search_text = "a wav", .duration_ms = 10, .content_hash = 11, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/b.wav", .relative_path = "b.wav", .name = "b.wav", .search_text = "b wav", .duration_ms = 10, .content_hash = 22, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/c.wav", .relative_path = "c.wav", .name = "c.wav", .search_text = "c wav", .duration_ms = 10, .content_hash = 33, .file_size = 1, .mtime_ns = 1 },
    };
    try db.applyFolderIndex(3, &files);
    const a: i32 = @intCast((try db.inspectFile("a.wav")).?.id);
    const b: i32 = @intCast((try db.inspectFile("b.wav")).?.id);
    const c_id: i32 = @intCast((try db.inspectFile("c.wav")).?.id);
    try db.applyFolderIndex(4, &.{.{ .path = "/other.wav", .relative_path = "other.wav", .name = "other.wav", .search_text = "other wav", .duration_ms = 10, .content_hash = 55, .file_size = 1, .mtime_ns = 1 }});
    const second_model = try db.registerSemanticModel("test/queue-two", 2);
    const second_algorithm = try db.ensureFingerprintAlgorithm("test/queue-two");
    try db.recordEmbeddingFailureForModel(model, a, 11, "decode", "terminal fixture");
    try db.recordFingerprintFailure(algorithm, a, 11, "decode", "terminal fixture");
    try db.upsertSemanticEmbeddingForModel(allocator, model, b, 22, &.{ 1, 0 });
    const landmarks = [_]fingerprint.Landmark{ .{ .hash = 1, .frame = 1 }, .{ .hash = 2, .frame = 2 }, .{ .hash = 3, .frame = 3 } };
    const blob = try fingerprint.serialize(allocator, &landmarks);
    defer allocator.free(blob);
    const selected = try fingerprint.selectors(allocator, &landmarks);
    defer allocator.free(selected);
    try db.upsertFingerprintWithEdges(algorithm, b, 22, blob, selected, &.{});

    const selected_work = try db.pendingSemanticFilesForModel(allocator, model, 3, 16);
    try std.testing.expectEqual(@as(usize, 1), selected_work.len);
    try std.testing.expectEqual(c_id, selected_work[0].id);
    db.freePendingSemanticFiles(allocator, selected_work);
    const generation = main_c.ws_refinement_generation();
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_cancel_refinement());
    try std.testing.expectError(error.Cancelled, acoustic.indexPendingExpected(allocator, 3, 16, generation));
    db.close();
    try openFixture(&fixture);
    const retained = try db.pendingFingerprintFiles(allocator, algorithm, 3, 16);
    defer db.freePendingSemanticFiles(allocator, retained);
    try std.testing.expectEqual(@as(usize, 1), retained.len);
    try std.testing.expectEqual(c_id, retained[0].id);

    // A changed early ID returns to both queues; a relocated completed file
    // retains analysis. Neither operation consumes the selected c work.
    files[0].content_hash = 44;
    files[0].file_size = 2;
    files[0].mtime_ns = 2;
    files[1].path = "/moved/b.wav";
    try db.applyFolderIndex(3, &files);
    const resumed = try db.pendingSemanticFilesForModel(allocator, model, 3, 16);
    defer db.freePendingSemanticFiles(allocator, resumed);
    try std.testing.expectEqual(@as(usize, 2), resumed.len);
    try std.testing.expectEqual(a, resumed[0].id);
    try std.testing.expectEqual(c_id, resumed[1].id);
    try std.testing.expectEqual(@as(i64, 1), (try db.semanticStatus()).embedded_count);
    const isolated = try db.pendingFingerprintFiles(allocator, second_algorithm, 3, 16);
    defer db.freePendingSemanticFiles(allocator, isolated);
    try std.testing.expectEqual(@as(usize, 3), isolated.len);
    const isolated_semantic = try db.pendingSemanticFilesForModel(allocator, second_model, 3, 16);
    defer db.freePendingSemanticFiles(allocator, isolated_semantic);
    try std.testing.expectEqual(@as(usize, 3), isolated_semantic.len);

    try db.recordEmbeddingFailureForModel(model, a, 44, "decode", "retry fixture");
    try db.recordFingerprintFailure(algorithm, a, 44, "decode", "retry fixture");
    // Clearing a terminal failure is an explicit retry; the same source must
    // become pending again without requiring a rescan or a model revision.
    try rawExec(fixture.db_path, "DELETE FROM embedding_failures; DELETE FROM fingerprint_failures;");
    const retried = try db.pendingFingerprintFiles(allocator, algorithm, 3, 16);
    defer db.freePendingSemanticFiles(allocator, retried);
    try std.testing.expectEqual(@as(usize, 2), retried.len);
    const retried_semantic = try db.pendingSemanticFilesForModel(allocator, model, 3, 16);
    defer db.freePendingSemanticFiles(allocator, retried_semantic);
    try std.testing.expectEqual(@as(usize, 2), retried_semantic.len);

    try db.removeFolder(3);
    const remaining = try db.pendingSemanticFilesForModel(allocator, model, null, 16);
    defer db.freePendingSemanticFiles(allocator, remaining);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqualStrings("/other.wav", remaining[0].path);
    try db.rebuildAcousticGroups(allocator, algorithm);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
}

test "schema 12 migration and restore rebuild pending work from canonical identities" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try db.insertSyntheticBenchmarkFiles(3);
    const model = try db.setSemanticModel("test/queue-migrate", 2);
    const algorithm = try db.ensureFingerprintAlgorithm("test/queue-migrate");
    try db.upsertSemanticEmbeddingForModel(allocator, model, 1, 1, &.{ 1, 0 });
    try db.recordEmbeddingFailureForModel(model, 2, 2, "decode", "terminal fixture");
    try db.recordFingerprintFailure(algorithm, 1, 1, "decode", "terminal fixture");
    db.close();
    try rawExec(fixture.db_path, @import("refinement_schema.zig").dropForTests ++ "PRAGMA user_version=12;");
    try openFixture(&fixture);
    try std.testing.expectEqual(db.SCHEMA_VERSION, try db.schemaVersion());
    const semantic_pending = try db.pendingSemanticFilesForModel(allocator, model, null, 16);
    defer db.freePendingSemanticFiles(allocator, semantic_pending);
    try std.testing.expectEqual(@as(usize, 1), semantic_pending.len);
    try std.testing.expectEqual(@as(i32, 3), semantic_pending[0].id);
    const acoustic_pending = try db.pendingFingerprintFiles(allocator, algorithm, null, 16);
    defer db.freePendingSemanticFiles(allocator, acoustic_pending);
    try std.testing.expectEqual(@as(usize, 2), acoustic_pending.len);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);

    try rawExec(fixture.db_path, "DELETE FROM pending_embeddings; DELETE FROM pending_fingerprints; INSERT INTO pending_embeddings VALUES(1,1,0);");
    try std.testing.expect((try db.integrityCheck(true)).errors_found > 0);
    const backup = try fixture.path("stale-queues.sqlite");
    defer allocator.free(backup);
    try db.backupTo(backup);
    try db.restoreFrom(backup);
    try std.testing.expectEqual(@as(i64, 1), (try db.semanticStatus()).embedded_count);
    const repaired = try db.pendingSemanticFilesForModel(allocator, model, null, 16);
    defer db.freePendingSemanticFiles(allocator, repaired);
    try std.testing.expectEqual(@as(usize, 1), repaired.len);
    try std.testing.expectEqual(@as(i32, 3), repaired[0].id);
    const repaired_acoustic = try db.pendingFingerprintFiles(allocator, algorithm, null, 16);
    defer db.freePendingSemanticFiles(allocator, repaired_acoustic);
    try std.testing.expectEqual(@as(usize, 2), repaired_acoustic.len);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
}

test "failed fingerprint edge publication rolls back analysis and leaves work pending" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try db.insertSyntheticBenchmarkFiles(2);
    const algorithm = try db.ensureFingerprintAlgorithm("test/queue-atomic");
    const landmarks = [_]fingerprint.Landmark{ .{ .hash = 1, .frame = 1 }, .{ .hash = 2, .frame = 2 }, .{ .hash = 3, .frame = 3 } };
    const blob = try fingerprint.serialize(allocator, &landmarks);
    defer allocator.free(blob);
    const selected = try fingerprint.selectors(allocator, &landmarks);
    defer allocator.free(selected);
    const bad_edge = [_]db.AcousticEdge{.{ .other_file_id = 999, .score_ppm = 200_000, .aligned = 10 }};
    try std.testing.expectError(error.InsertFailed, db.upsertFingerprintWithEdges(algorithm, 1, 1, blob, selected, &bad_edge));
    try std.testing.expectEqual(@as(?db.FingerprintBlob, null), try db.loadFingerprint(allocator, algorithm, 1));
    const pending = try db.pendingFingerprintFiles(allocator, algorithm, null, 16);
    defer db.freePendingSemanticFiles(allocator, pending);
    try std.testing.expectEqual(@as(usize, 2), pending.len);
    try db.upsertFingerprintWithEdges(algorithm, 1, 1, blob, selected, &.{});
    const completed = try db.pendingFingerprintFiles(allocator, algorithm, null, 16);
    defer db.freePendingSemanticFiles(allocator, completed);
    try std.testing.expectEqual(@as(usize, 1), completed.len);
    try std.testing.expectEqual(@as(i32, 2), completed[0].id);
    try db.rebuildAcousticGroups(allocator, algorithm);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
}

test "model activation counts compact snapshots and normalized upserts" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{
        .{ .path = "/a.wav", .relative_path = "a.wav", .name = "a.wav", .search_text = "a wav", .duration_ms = 100, .content_hash = 1, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/b.wav", .relative_path = "b.wav", .name = "b.wav", .search_text = "b wav", .duration_ms = 200, .content_hash = 2, .file_size = 2, .mtime_ns = 2 },
    };
    try db.applyFolderIndex(4, &files);
    const a_id: i32 = @intCast((try db.inspectFile("a.wav")).?.id);
    const first_model = try db.registerSemanticModel("provider/model@sha256:one", 2);
    try db.activateSemanticModel(first_model);
    try std.testing.expectError(error.VectorNotNormalized, db.upsertSemanticEmbedding(allocator, a_id, 1, &.{ 2, 0 }));
    try std.testing.expectError(error.NonFiniteVector, db.upsertSemanticEmbedding(allocator, a_id, 1, &.{ std.math.inf(f32), 0 }));
    try db.upsertSemanticEmbedding(allocator, a_id, 1, &.{ 1, 0 });
    var status = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 1), status.embedded_count);
    try std.testing.expectEqual(@as(i64, 1), status.pending_count);
    var snapshot = (try db.loadActiveVectorSnapshot(allocator)).?;
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.file_ids.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.dimension);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0 }, snapshot.vectors);
    try std.testing.expect(!@hasField(db.Candidate, "vector"));

    _ = try db.setSemanticModel("provider/model@sha256:two", 2);
    status = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 0), status.embedded_count);
    try std.testing.expectEqual(@as(i64, 2), status.pending_count);
    _ = try db.setSemanticModel("provider/model@sha256:one", 2);
    status = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 1), status.embedded_count);
    try std.testing.expectError(error.ModelIdentityConflict, db.setSemanticModel("provider/model@sha256:one", 3));
}

test "fingerprint sinc resampler rejects above-Nyquist aliases" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try writeToneWav(fixture.tmp.dir, "alias.wav", 48_000, 12_000, 1);
    const path = try fixture.path("alias.wav");
    defer allocator.free(path);
    const canonical = try clap_audio.decodeFingerprintFile(allocator, io, path);
    defer allocator.free(canonical);
    var energy: f64 = 0;
    for (canonical[128 .. canonical.len - 128]) |sample| energy += @as(f64, sample) * sample;
    const rms = @sqrt(energy / @as(f64, @floatFromInt(canonical.len - 256)));
    try std.testing.expect(rms < 0.08);
}

test "fuzzy landmark neighborhoods tolerate one quantization step without carry" {
    var query: [6]fingerprint.Landmark = undefined;
    var near: [6]fingerprint.Landmark = undefined;
    var far: [6]fingerprint.Landmark = undefined;
    const query_hash: u32 = 10 | (20 << 8) | (5 << 16);
    const near_hash: u32 = 11 | (19 << 8) | (6 << 16);
    const far_hash: u32 = 12 | (20 << 8) | (5 << 16);
    for (0..6) |index| {
        query[index] = .{ .hash = query_hash, .frame = @intCast(index * 10) };
        near[index] = .{ .hash = near_hash, .frame = @intCast(index * 10 + 4) };
        far[index] = .{ .hash = far_hash, .frame = @intCast(index * 10 + 4) };
    }
    const match = try fingerprint.compare(allocator, &query, &near);
    try std.testing.expect(match.highConfidence());
    try std.testing.expectEqual(@as(i32, 4), match.offset_frames);
    try std.testing.expect(!(try fingerprint.compare(allocator, &query, &far)).highConfidence());
    const one_reference = [_]fingerprint.Landmark{near[0]};
    const asymmetric = try fingerprint.compare(allocator, &query, &one_reference);
    try std.testing.expectEqual(@as(u32, 1), asymmetric.aligned);
    try std.testing.expect(!asymmetric.highConfidence());
    var storage: [27]u32 = undefined;
    const boundary = fingerprint.neighborHashes(0, &storage);
    try std.testing.expectEqual(@as(usize, 8), boundary.len);
    try std.testing.expect(std.sort.isSorted(u32, boundary, {}, std.sort.asc(u32)));
}

test "batched fingerprint neighborhoods preserve fuzzy and folder-filtered retrieval" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files_a = [_]db.ScannedFile{.{
        .path = "/batch/a.wav",
        .relative_path = "a.wav",
        .name = "a.wav",
        .search_text = "a wav",
        .duration_ms = 1000,
        .content_hash = 101,
        .file_size = 100,
        .mtime_ns = 1,
    }};
    const files_b = [_]db.ScannedFile{.{
        .path = "/batch/b.wav",
        .relative_path = "b.wav",
        .name = "b.wav",
        .search_text = "b wav",
        .duration_ms = 1000,
        .content_hash = 202,
        .file_size = 100,
        .mtime_ns = 1,
    }};
    try db.applyFolderIndex(41, &files_a);
    try db.applyFolderIndex(42, &files_b);
    const a_id: i32 = @intCast((try db.inspectFile("a.wav")).?.id);
    const b_id: i32 = @intCast((try db.inspectFile("b.wav")).?.id);
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    const query_hash: u32 = 0x0008_1010;
    var neighborhood_storage: [27]u32 = undefined;
    const neighborhood = fingerprint.neighborHashes(query_hash, &neighborhood_storage);
    const stored_hash = for (neighborhood) |hash| {
        if (hash != query_hash) break hash;
    } else unreachable;
    const landmark = [_]fingerprint.Landmark{.{ .hash = stored_hash, .frame = 1 }};
    const blob = try fingerprint.serialize(allocator, &landmark);
    defer allocator.free(blob);
    try db.upsertFingerprint(algorithm_id, a_id, 101, blob, &.{stored_hash});
    try db.upsertFingerprint(algorithm_id, b_id, 202, blob, &.{stored_hash});

    const all = try db.fingerprintCandidateIds(allocator, algorithm_id, &.{query_hash}, null, 8);
    defer allocator.free(all);
    try std.testing.expectEqualSlices(i32, &.{ a_id, b_id }, all);
    const folder_a = try db.fingerprintCandidateIds(allocator, algorithm_id, &.{query_hash}, 41, 8);
    defer allocator.free(folder_a);
    try std.testing.expectEqualSlices(i32, &.{a_id}, folder_a);
    const folder_missing = try db.fingerprintCandidateIds(allocator, algorithm_id, &.{query_hash}, 99, 8);
    defer allocator.free(folder_missing);
    try std.testing.expectEqual(@as(usize, 0), folder_missing.len);
}

test "fast index mode uses deterministic bounded sample regions and rejects conflicting flags" {
    var small_storage: [5]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 0), search.fastHashSampleOffsets(search.FAST_HASH_MAX_READ, &small_storage).len);
    const file_size = search.FAST_HASH_MAX_READ * 4 + 123;
    var storage: [5]u64 = undefined;
    const offsets = search.fastHashSampleOffsets(file_size, &storage);
    try std.testing.expectEqual(@as(usize, 5), offsets.len);
    try std.testing.expectEqual(@as(u64, 0), offsets[0]);
    try std.testing.expectEqual(file_size - search.FAST_HASH_BLOCK_SIZE, offsets[4]);
    for (offsets[0 .. offsets.len - 1], offsets[1..]) |left, right|
        try std.testing.expect(right >= left + search.FAST_HASH_BLOCK_SIZE);

    try std.testing.expectEqual(@as(u32, 1), main_c.WS_INDEX_DEEP);
    try std.testing.expectEqual(@as(u32, 2), main_c.WS_INDEX_FAST);
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try writeWav(fixture.tmp.dir, "instant-impact.wav", 700, 17);
    try openFixture(&fixture);
    const root = try fixture.path("");
    defer allocator.free(root);
    const root_z = try allocator.dupeSentinel(u8, root, 0);
    defer allocator.free(root_z);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_index_folder_ex(61, root_z.ptr, main_c.WS_INDEX_FAST));
    const fast_file = (try db.inspectFile("instant-impact.wav")).?;
    try std.testing.expect(fast_file.content_hash < 0);
    try std.testing.expectEqual(@as(c_int, 0), try db.duplicateCount(fast_file.content_hash));
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    try std.testing.expectEqual(@as(i64, 1), (try db.fingerprintStatus(algorithm_id)).pending);
    var lexical = [_]main_c.WSResult{std.mem.zeroes(main_c.WSResult)};
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_search("instant", 61, &lexical, lexical.len));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_index_folder_ex(61, root_z.ptr, main_c.WS_INDEX_DEEP));
    try std.testing.expect((try db.inspectFile("instant-impact.wav")).?.content_hash > 0);
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_index_folder_ex(61, root_z.ptr, main_c.WS_INDEX_FAST | main_c.WS_INDEX_DEEP));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_index_folder_ex(61, root_z.ptr, 4));
}

test "fast sparse WAV metadata finds LIST chunks after audio data" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try writeWav(fixture.tmp.dir, "tail-metadata.wav", 10_000, 9);
    const original = try fixture.tmp.dir.readFileAlloc(io, "tail-metadata.wav", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(original);
    const text_value = "hidden tail";
    const list_payload_size: usize = 4 + 8 + text_value.len + (text_value.len & 1);
    const extended = try allocator.alloc(u8, original.len + 8 + list_payload_size);
    defer allocator.free(extended);
    @memcpy(extended[0..original.len], original);
    std.mem.writeInt(u32, extended[4..8], @intCast(extended.len - 8), .little);
    var position = original.len;
    @memcpy(extended[position..][0..4], "LIST");
    std.mem.writeInt(u32, extended[position + 4 ..][0..4], @intCast(list_payload_size), .little);
    position += 8;
    @memcpy(extended[position..][0..4], "INFO");
    position += 4;
    @memcpy(extended[position..][0..4], "INAM");
    std.mem.writeInt(u32, extended[position + 4 ..][0..4], text_value.len, .little);
    position += 8;
    @memcpy(extended[position..][0..text_value.len], text_value);
    if (text_value.len & 1 != 0) extended[position + text_value.len] = 0;
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "tail-metadata.wav", .data = extended });

    const path = try fixture.path("tail-metadata.wav");
    defer allocator.free(path);
    var metadata: std.ArrayList(u8) = .empty;
    defer metadata.deinit(allocator);
    try audio.appendMetadataTextIoSparse(allocator, &metadata, io, path, 256 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, metadata.items, "hidden tail") != null);

    // The scanner must preserve metadata, duration, and the existing hash
    // contract while its readers share a cached prefix and one descriptor.
    try openFixture(&fixture);
    const root = try fixture.path("");
    defer allocator.free(root);
    var size_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &size_bytes, extended.len, .little);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&size_bytes);
    hasher.update(extended);
    const raw_hash = hasher.final() & 0x7fff_ffff_ffff_ffff;
    const expected_hash: i64 = @intCast(if (raw_hash == 0) 1 else raw_hash);
    for ([_]search.IndexOptions{ .{}, .{ .fast = true }, .{ .deep = true } }, 0..) |options, i| {
        const folder_id: i32 = @intCast(i + 1);
        try search.indexFolderWithOptions(allocator, folder_id, root, options);
        var results: [1]main_c.WSResult = undefined;
        try std.testing.expectEqual(@as(usize, 1), try search.search(allocator, "hidden tail", folder_id, &results, results.len));
        try std.testing.expectEqual(@as(i32, 10_000), results[0].duration_ms);
        try std.testing.expectEqual(if (options.fast) -expected_hash else expected_hash, results[0].content_hash);
        try db.removeFolder(folder_id);
    }
}

test "multi-window planner covers beginning and end with bounded memory" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try writeFingerprintWav(fixture.tmp.dir, "multi.wav", 48_000, 0, 25.0, 0.8, false);
    const path = try fixture.path("multi.wav");
    defer allocator.free(path);
    var reader = try clap_audio.WindowReader.initFile(allocator, io, path);
    defer reader.deinit();
    try std.testing.expectEqual(@as(usize, 3), reader.count());
    const window = try allocator.alloc(f32, clap_audio.WINDOW_SAMPLES);
    defer allocator.free(window);
    var checksums: [3]u64 = undefined;
    var index: usize = 0;
    while (try reader.next(window)) {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.sliceAsBytes(window));
        checksums[index] = hasher.final();
        index += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), index);
    try std.testing.expect(checksums[0] != checksums[2]);
}

test "landmark fingerprints survive gain trimming and reject unrelated audio" {
    const sample_rate = 48_000;
    const source = try allocator.alloc(f32, sample_rate * 3);
    defer allocator.free(source);
    const unrelated = try allocator.alloc(f32, source.len);
    defer allocator.free(unrelated);
    for (source, unrelated, 0..) |*sample, *other, i| {
        const t = @as(f64, @floatFromInt(i)) / sample_rate;
        const sweep_phase = 2.0 * std.math.pi * (180.0 * t + 310.0 * t * t);
        const pulse = if (i % 12_000 < 500) @as(f64, 0.35) * @sin(2.0 * std.math.pi * 1900.0 * t) else 0;
        sample.* = @floatCast(0.45 * @sin(sweep_phase) + pulse);
        other.* = @floatCast(0.5 * @sin(2.0 * std.math.pi * (73.0 * t + 57.0 * t * t)) + 0.2 * @sin(2.0 * std.math.pi * (111.0 * t + 31.0 * t * t)));
    }
    const gained = try allocator.alloc(f32, source.len);
    defer allocator.free(gained);
    for (source, gained) |value, *dest| dest.* = value * 0.18;
    const trim = source[12_345 .. source.len - 7_777];

    const original_fp = try fingerprint.fromSamples(allocator, source);
    defer allocator.free(original_fp);
    const gain_fp = try fingerprint.fromSamples(allocator, gained);
    defer allocator.free(gain_fp);
    const trim_fp = try fingerprint.fromSamples(allocator, trim);
    defer allocator.free(trim_fp);
    const unrelated_fp = try fingerprint.fromSamples(allocator, unrelated);
    defer allocator.free(unrelated_fp);

    const gain_match = try fingerprint.compare(allocator, original_fp, gain_fp);
    const trim_match = try fingerprint.compare(allocator, original_fp, trim_fp);
    const negative = try fingerprint.compare(allocator, original_fp, unrelated_fp);
    try std.testing.expect(gain_match.highConfidence());
    try std.testing.expect(trim_match.highConfidence());
    try std.testing.expect(gain_match.score_ppm > 900_000);
    try std.testing.expect(trim_match.score_ppm > negative.score_ppm * 4);
    try std.testing.expect(!negative.highConfidence());

    const encoded = try fingerprint.serialize(allocator, original_fp);
    defer allocator.free(encoded);
    const decoded = try fingerprint.deserialize(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(fingerprint.Landmark, original_fp, decoded);
}

test "acoustic indexing rebuilds groups once across internal file batches" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(io, "group-batches", .default_dir);
    for (0..18) |index| {
        const relative = try std.fmt.allocPrint(allocator, "group-batches/clip-{d}.wav", .{index});
        defer allocator.free(relative);
        try writeFingerprintWav(fixture.tmp.dir, relative, 16_000, 0, 1.0, 1.0, false);
    }
    try openFixture(&fixture);
    const folder = try fixture.path("group-batches");
    defer allocator.free(folder);
    try search.indexFolder(allocator, 77, folder);
    const before = db.acousticGroupRebuildSerialForTests();
    var successful: usize = 0;
    for (0..18) |batch| {
        const indexed = try acoustic.indexPending(allocator, 77, 1);
        successful += indexed.successful;
        if (batch < 17)
            try std.testing.expectEqual(before, db.acousticGroupRebuildSerialForTests());
    }
    try std.testing.expectEqual(@as(usize, 18), successful);
    try std.testing.expectEqual(before +% 1, db.acousticGroupRebuildSerialForTests());
}

test "fingerprint indexing identifies resampled level-shifted and trimmed WAV variants" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(io, "fingerprints", .default_dir);
    try writeFingerprintWav(fixture.tmp.dir, "fingerprints/source.wav", 48_000, 0, 3.0, 1.0, false);
    try writeFingerprintWav(fixture.tmp.dir, "fingerprints/resampled-gain.wav", 44_100, 0, 3.0, 0.2, false);
    try writeFingerprintWav(fixture.tmp.dir, "fingerprints/trimmed.wav", 48_000, 0.23, 2.55, 0.7, false);
    try writeFingerprintAiff(fixture.tmp.dir, "fingerprints/container-variant.aiff", 48_000, 3.0, 0.8);
    try writeFingerprintWav(fixture.tmp.dir, "fingerprints/unrelated.wav", 48_000, 0, 3.0, 1.0, true);
    try openFixture(&fixture);
    const folder = try fixture.path("fingerprints");
    defer allocator.free(folder);
    try search.indexFolder(allocator, 1, folder);
    const indexed = try acoustic.indexPending(allocator, 1, 0);
    try std.testing.expectEqual(@as(usize, 5), indexed.successful);
    try std.testing.expectEqual(@as(usize, 0), indexed.failed);
    const source_path = try fixture.path("fingerprints/source.wav");
    defer allocator.free(source_path);
    const matches = try acoustic.searchPath(allocator, source_path, 1, 8);
    defer allocator.free(matches);
    var family_hits: usize = 0;
    var false_positives: usize = 0;
    for (matches) |match| {
        if (match.fingerprint_score_ppm < 120_000 or match.fingerprint_votes < 6) continue;
        const name = resultCandidateName(&match.candidate);
        if (std.mem.eql(u8, name, "source.wav") or std.mem.eql(u8, name, "resampled-gain.wav") or std.mem.eql(u8, name, "trimmed.wav") or std.mem.eql(u8, name, "container-variant.aiff"))
            family_hits += 1
        else
            false_positives += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), family_hits);
    try std.testing.expectEqual(@as(usize, 0), false_positives);
    try std.testing.expect(matches.len >= 4);
    for (matches[0..4]) |match| {
        const name = resultCandidateName(&match.candidate);
        try std.testing.expect(std.mem.eql(u8, name, "source.wav") or std.mem.eql(u8, name, "resampled-gain.wav") or std.mem.eql(u8, name, "trimmed.wav") or std.mem.eql(u8, name, "container-variant.aiff"));
    }
    const source_id: i32 = @intCast((try db.inspectFile("source.wav")).?.id);
    const group = (try acoustic.groupInfo(allocator, source_id)).?;
    try std.testing.expectEqual(@as(u32, 4), group.member_count);

    const source_z = try allocator.dupeSentinel(u8, source_path, 0);
    defer allocator.free(source_z);
    var abi_results = std.mem.zeroes([4]main_c.WSExampleResult);
    for (&abi_results) |*result| result.struct_size = @sizeOf(main_c.WSExampleResult);
    // Native hosts can call from 512 KiB worker stacks. Keep the C path on
    // that stack size so large sorting scratch buffers cannot regress.
    var abi_count: c_int = -1;
    const example_worker = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, struct {
        fn run(path: [*:0]const u8, results: *[4]main_c.WSExampleResult, count: *c_int) void {
            count.* = main_c.ws_search_by_example(path, 1, results, results.len);
        }
    }.run, .{ source_z.ptr, &abi_results, &abi_count });
    example_worker.join();
    try std.testing.expect(abi_count >= 3);
    var found_trimmed_offset = false;
    for (abi_results[0..@intCast(abi_count)]) |*item| {
        if (std.mem.eql(u8, resultName(&item.result), "trimmed.wav")) {
            try std.testing.expect(@abs(item.offset_ms) >= 150 and @abs(item.offset_ms) <= 350);
            found_trimmed_offset = true;
        }
    }
    try std.testing.expect(found_trimmed_offset);
    const pcm = try allocator.alloc(f32, 48_000 * 3);
    defer allocator.free(pcm);
    for (pcm, 0..) |*sample, i| {
        const t = @as(f64, @floatFromInt(i)) / 48_000.0;
        sample.* = @floatCast(0.45 * @sin(2.0 * std.math.pi * (180.0 * t + 330.0 * t * t)) + (if (@mod(t, 0.2) < 0.008) 0.3 * @sin(2.0 * std.math.pi * 2100.0 * t) else 0));
    }
    for (&abi_results) |*result| result.struct_size = @sizeOf(main_c.WSExampleResult);
    try std.testing.expect(main_c.ws_search_by_example_pcm(pcm.ptr, pcm.len, 1, 48_000, 1, &abi_results, abi_results.len) >= 4);
    var abi_group = std.mem.zeroes(main_c.WSAcousticGroup);
    abi_group.struct_size = @sizeOf(main_c.WSAcousticGroup);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_acoustic_group(source_id, &abi_group));
    try std.testing.expectEqual(@as(u32, 4), abi_group.member_count);
}

test "schema v10 fingerprints retrieve trimmed source families and group robust duplicates" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const scanned = [_]db.ScannedFile{
        .{ .path = "/source.wav", .relative_path = "source.wav", .name = "source.wav", .search_text = "source wav", .duration_ms = 3000, .content_hash = 101, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/trimmed.wav", .relative_path = "trimmed.wav", .name = "trimmed.wav", .search_text = "trimmed wav", .duration_ms = 2500, .content_hash = 102, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/other.wav", .relative_path = "other.wav", .name = "other.wav", .search_text = "other wav", .duration_ms = 3000, .content_hash = 103, .file_size = 1, .mtime_ns = 1 },
    };
    try db.applyFolderIndex(1, &scanned);
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    const samples = try allocator.alloc(f32, 48_000 * 3);
    defer allocator.free(samples);
    const other = try allocator.alloc(f32, samples.len);
    defer allocator.free(other);
    for (samples, other, 0..) |*sample, *negative, i| {
        const t = @as(f64, @floatFromInt(i)) / 48_000.0;
        sample.* = @floatCast(0.5 * @sin(2.0 * std.math.pi * (170.0 * t + 400.0 * t * t)) + (if (i % 9000 < 400) @as(f64, 0.3) * @sin(2.0 * std.math.pi * 2300.0 * t) else 0));
        negative.* = @floatCast(0.6 * @sin(2.0 * std.math.pi * (91.0 * t + 65.0 * t * t)));
    }
    const fingerprints = [_][]fingerprint.Landmark{
        try fingerprint.fromSamples(allocator, samples),
        try fingerprint.fromSamples(allocator, samples[11_111 .. samples.len - 5_555]),
        try fingerprint.fromSamples(allocator, other),
    };
    defer for (fingerprints) |items| allocator.free(items);
    for (fingerprints, scanned) |items, file| {
        const blob = try fingerprint.serialize(allocator, items);
        defer allocator.free(blob);
        const selected = try fingerprint.selectors(allocator, items);
        defer allocator.free(selected);
        const id: i32 = @intCast((try db.inspectFile(file.relative_path)).?.id);
        try db.upsertFingerprint(algorithm_id, id, file.content_hash, blob, selected);
    }
    const source_id_for_edge: i32 = @intCast((try db.inspectFile("source.wav")).?.id);
    const trimmed_id_for_edge: i32 = @intCast((try db.inspectFile("trimmed.wav")).?.id);
    const edge_match = try fingerprint.compare(allocator, fingerprints[0], fingerprints[1]);
    try db.replaceAcousticEdges(algorithm_id, source_id_for_edge, &.{.{
        .other_file_id = trimmed_id_for_edge,
        .score_ppm = edge_match.score_ppm,
        .aligned = edge_match.aligned,
    }});
    try db.rebuildAcousticGroups(allocator, algorithm_id);
    const matches = try acoustic.searchLandmarks(allocator, fingerprints[0], null, 8);
    defer allocator.free(matches);
    try std.testing.expect(matches.len >= 2);
    try std.testing.expectEqualStrings("source.wav", resultCandidateName(&matches[0].candidate));
    try std.testing.expect(matches[0].fingerprint_score_ppm > 900_000);
    try std.testing.expectEqualStrings("trimmed.wav", resultCandidateName(&matches[1].candidate));
    try std.testing.expect(matches[1].fingerprint_score_ppm >= 120_000);
    const source_id: i32 = @intCast((try db.inspectFile("source.wav")).?.id);
    const group = (try acoustic.groupInfo(allocator, source_id)).?;
    try std.testing.expectEqual(@as(u32, 2), group.member_count);
    try std.testing.expect(group.confidence_ppm >= 120_000);

    // A durable dirty state is rebuilt once at operation completion even when
    // no fingerprint files remain pending.
    try db.replaceAcousticEdges(algorithm_id, source_id_for_edge, &.{.{
        .other_file_id = trimmed_id_for_edge,
        .score_ppm = edge_match.score_ppm,
        .aligned = edge_match.aligned,
    }});
    try std.testing.expect(try db.acousticGroupsDirty(algorithm_id));
    try std.testing.expect((try db.acousticGroupInfo(algorithm_id, source_id)) == null);
    const maintenance = try acoustic.indexPending(allocator, null, 0);
    try std.testing.expectEqual(@as(usize, 0), maintenance.successful);
    try std.testing.expect(!(try db.acousticGroupsDirty(algorithm_id)));
    try std.testing.expectEqual(@as(u32, 2), (try db.acousticGroupInfo(algorithm_id, source_id)).?.member_count);
}

test "persistent acoustic families are transitive and split after bridge deletion" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const rows = [_]db.ScannedFile{
        .{ .path = "/a.wav", .relative_path = "a.wav", .name = "a.wav", .search_text = "a wav", .duration_ms = 1, .content_hash = 1, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/b.wav", .relative_path = "b.wav", .name = "b.wav", .search_text = "b wav", .duration_ms = 1, .content_hash = 2, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/c.wav", .relative_path = "c.wav", .name = "c.wav", .search_text = "c wav", .duration_ms = 1, .content_hash = 3, .file_size = 1, .mtime_ns = 1 },
    };
    try db.applyFolderIndex(1, rows[0..1]);
    try db.applyFolderIndex(2, rows[1..2]);
    try db.applyFolderIndex(3, rows[2..3]);
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    const landmarks = [_]fingerprint.Landmark{ .{ .hash = 1, .frame = 1 }, .{ .hash = 2, .frame = 2 }, .{ .hash = 3, .frame = 3 }, .{ .hash = 4, .frame = 4 }, .{ .hash = 5, .frame = 5 }, .{ .hash = 6, .frame = 6 } };
    const blob = try fingerprint.serialize(allocator, &landmarks);
    defer allocator.free(blob);
    const selected = try fingerprint.selectors(allocator, &landmarks);
    defer allocator.free(selected);
    var ids: [3]i32 = undefined;
    for (rows, 0..) |row, index| {
        ids[index] = @intCast((try db.inspectFile(row.relative_path)).?.id);
        try db.upsertFingerprint(algorithm_id, ids[index], row.content_hash, blob, selected);
    }
    try db.replaceAcousticEdges(algorithm_id, ids[0], &.{.{ .other_file_id = ids[1], .score_ppm = 800_000, .aligned = 20 }});
    try db.replaceAcousticEdges(algorithm_id, ids[1], &.{
        .{ .other_file_id = ids[0], .score_ppm = 800_000, .aligned = 20 },
        .{ .other_file_id = ids[2], .score_ppm = 700_000, .aligned = 18 },
    });
    try db.rebuildAcousticGroups(allocator, algorithm_id);
    for (ids) |id| {
        const group = (try db.acousticGroupInfo(algorithm_id, id)).?;
        try std.testing.expectEqual(@as(i64, ids[0]), group.group_id);
        try std.testing.expectEqual(@as(u32, 3), group.member_count);
    }
    db.close();
    try openFixture(&fixture);
    try std.testing.expectEqual(@as(u32, 3), (try db.acousticGroupInfo(algorithm_id, ids[2])).?.member_count);
    try db.removeFolder(2);
    try db.rebuildAcousticGroups(allocator, algorithm_id);
    try std.testing.expectEqual(@as(u32, 1), (try db.acousticGroupInfo(algorithm_id, ids[0])).?.member_count);
    try std.testing.expectEqual(@as(u32, 1), (try db.acousticGroupInfo(algorithm_id, ids[2])).?.member_count);
}

test "full integrity detects fingerprint posting corruption" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{.{ .path = "/integrity.wav", .relative_path = "integrity.wav", .name = "integrity.wav", .search_text = "integrity wav", .duration_ms = 1, .content_hash = 88, .file_size = 1, .mtime_ns = 1 }};
    try db.applyFolderIndex(1, &files);
    const file_id: i32 = @intCast((try db.inspectFile("integrity.wav")).?.id);
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    const landmarks = [_]fingerprint.Landmark{
        .{ .hash = 1, .frame = 0 }, .{ .hash = 2, .frame = 1 }, .{ .hash = 3, .frame = 2 },
        .{ .hash = 4, .frame = 3 }, .{ .hash = 5, .frame = 4 }, .{ .hash = 6, .frame = 5 },
    };
    const blob = try fingerprint.serialize(allocator, &landmarks);
    defer allocator.free(blob);
    const selected = try fingerprint.selectors(allocator, &landmarks);
    defer allocator.free(selected);
    try db.upsertFingerprint(algorithm_id, file_id, 88, blob, selected);
    try db.rebuildAcousticGroups(allocator, algorithm_id);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
    db.close();
    try rawExec(fixture.db_path, "UPDATE fingerprint_postings SET token_hash=token_hash+1000000 WHERE token_hash=(SELECT MIN(token_hash) FROM fingerprint_postings);");
    try openFixture(&fixture);
    try std.testing.expect((try db.integrityCheck(true)).errors_found > 0);
}

test "removing a folder cascades FTS embeddings and failures atomically" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{
        .{ .path = "/remove.wav", .relative_path = "remove.wav", .name = "remove.wav", .search_text = "remove wav", .duration_ms = 100, .content_hash = 11, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/keep.wav", .relative_path = "keep.wav", .name = "keep.wav", .search_text = "keep wav", .duration_ms = 100, .content_hash = 22, .file_size = 1, .mtime_ns = 1 },
    };
    try db.applyFolderIndex(1, files[0..1]);
    try db.applyFolderIndex(2, files[1..2]);
    _ = try db.setSemanticModel("remove-test@1", 2);
    const remove_id: i32 = @intCast((try db.inspectFile("remove.wav")).?.id);
    try db.upsertSemanticEmbedding(allocator, remove_id, 11, &.{ 1, 0 });
    try db.recordEmbeddingFailure(remove_id, 11, "fixture", "terminal fixture");

    try db.removeFolder(1);
    try std.testing.expectEqual(@as(c_int, 0), try db.countForFolder(1));
    try std.testing.expectEqual(@as(c_int, 1), try db.countForFolder(2));
    try std.testing.expectEqual(@as(i64, 0), try rawScalar(fixture.db_path, "SELECT COUNT(*) FROM file_embeddings;"));
    try std.testing.expectEqual(@as(i64, 0), try rawScalar(fixture.db_path, "SELECT COUNT(*) FROM embedding_failures;"));
    var results: [4]main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(usize, 0), try search.search(allocator, "remove", null, &results, results.len));
    try std.testing.expectEqual(@as(usize, 1), try search.search(allocator, "keep", null, &results, results.len));
}

test "sequential lexical and hybrid stages reuse candidates and invalidate on catalog changes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try db.insertSyntheticBenchmarkFiles(100);
    const request = main_c.ws_query_create().?;
    defer main_c.ws_query_destroy(request);
    _ = try db.setSemanticModel("test/request-reuse", 2);
    var results: [100]main_c.WSResult = undefined;
    try std.testing.expect(main_c.ws_search_v2(request, "impact", -1, &results, results.len, 1) > 0);
    try std.testing.expect(main_c.ws_search_v2(request, "impact", -1, &results, results.len, 0) > 0);
    const previous_request = @import("query.zig").current;
    @import("query.zig").current = request;
    defer @import("query.zig").current = previous_request;
    try std.testing.expect(try search.searchWithEmbedding(allocator, "impact", &.{ 1, 0 }, null, &results, results.len) > 0);
    try std.testing.expectEqual(@as(usize, 1), request.lexical_builds);
    try std.testing.expect(request.lexical.?.limit >= 256);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_search_needs_refinement("<2s"));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_search_needs_refinement("impact"));
    try db.removeFolder(0);
    try std.testing.expect(main_c.ws_search_v2(request, "impact", -1, &results, results.len, 0) > 0);
    try std.testing.expectEqual(@as(usize, 2), request.lexical_builds);
    try std.testing.expect(main_c.ws_search_v2(request, "rain", -1, &results, results.len, 0) > 0);
    try std.testing.expectEqual(@as(usize, 3), request.lexical_builds);
    main_c.ws_query_cancel(request);
    try std.testing.expectEqual(@as(c_int, -2), main_c.ws_search_v2(request, "impact", -1, &results, results.len, 0));
}

test "semantic retrieval hybrid fusion filters and lexical-only fallback are deterministic" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{
        .{ .path = "/Rain.wav", .relative_path = "Rain.wav", .name = "Rain.wav", .search_text = "rain wav", .duration_ms = 100, .content_hash = 101, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/Ocean.wav", .relative_path = "Ocean.wav", .name = "Ocean.wav", .search_text = "ocean wav", .duration_ms = 500, .content_hash = 102, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/Metal.wav", .relative_path = "Metal.wav", .name = "Metal.wav", .search_text = "metal wav", .duration_ms = 100, .content_hash = 103, .file_size = 1, .mtime_ns = 1 },
    };
    try db.applyFolderIndex(1, files[0..1]);
    try db.applyFolderIndex(2, files[1..]);
    _ = try db.setSemanticModel("test/hybrid@1", 2);
    const rain: i32 = @intCast((try db.inspectFile("Rain.wav")).?.id);
    const ocean: i32 = @intCast((try db.inspectFile("Ocean.wav")).?.id);
    const metal: i32 = @intCast((try db.inspectFile("Metal.wav")).?.id);
    try db.upsertSemanticEmbedding(allocator, rain, 101, &.{ 0, 1 });
    try db.upsertSemanticEmbedding(allocator, ocean, 102, &.{ 1, 0 });
    try db.upsertSemanticEmbedding(allocator, metal, 103, &.{ -1, 0 });

    // The bounded reader is reusable after a completed scan; this catches
    // stale interrupted-transaction state without requiring a second connection.
    const streamed = (try db.streamActiveVectorTopK(allocator, &.{ 1, 0 }, .{}, 3)).?;
    defer allocator.free(streamed.matches);
    try std.testing.expectEqual(@as(usize, 3), streamed.matches.len);
    const streamed_again = (try db.streamActiveVectorTopK(allocator, &.{ 1, 0 }, .{}, 3)).?;
    defer allocator.free(streamed_again.matches);
    try std.testing.expectEqualSlices(vector.Match, streamed.matches, streamed_again.matches);
    try std.testing.expectEqual(@as(i64, 102), streamed.matches[0].source_content_hash);
    // Background embedding generations do not invalidate unchanged scored files.
    try db.upsertSemanticEmbedding(allocator, metal, 103, &.{ -1, 0 });
    const hydrated = try db.candidatesForSemanticIds(allocator, &.{ rain, ocean, metal }, streamed.model_id, streamed.connection_serial);
    defer allocator.free(hydrated);
    try std.testing.expectEqual(@as(usize, 3), hydrated.len);

    var results: [8]main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(usize, 0), try search.search(allocator, "water", null, &results, results.len));
    var count = try search.searchWithEmbedding(allocator, "water", &.{ 1, 0 }, null, &results, results.len);
    // Unrelated zero-confidence semantic-only rows are not result fillers.
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("Ocean.wav", resultName(&results[0]));

    count = try search.searchWithEmbedding(allocator, "rain", &.{ 1, 0 }, null, &results, results.len);
    try std.testing.expect(count >= 2);
    try std.testing.expectEqualStrings("Rain.wav", resultName(&results[0]));

    count = try search.searchWithEmbedding(allocator, "water <200ms", &.{ 1, 0 }, 1, &results, results.len);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectError(error.DimensionMismatch, search.searchWithEmbedding(allocator, "water", &.{ 1, 0, 0 }, null, &results, results.len));
}

test "additive semantic C ABI layout pointer validation and behavior" {
    try std.testing.expectEqual(@sizeOf(abi_c.WSSemanticStatus), @sizeOf(main_c.WSSemanticStatus));
    try std.testing.expectEqual(@alignOf(abi_c.WSSemanticStatus), @alignOf(main_c.WSSemanticStatus));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(main_c.WSSemanticStatus, "struct_size"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(main_c.WSSemanticStatus, "model_id"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(main_c.WSSemanticStatus, "model_key"));
    try std.testing.expectEqual(@as(usize, 176), @offsetOf(main_c.WSSemanticStatus, "failed_count"));
    try std.testing.expectEqual(@as(usize, 184), @offsetOf(main_c.WSSemanticStatus, "provider_loaded"));
    try std.testing.expectEqual(@as(usize, 192), @sizeOf(main_c.WSSemanticStatus));
    try std.testing.expectEqual(@sizeOf(abi_c.WSAcousticStatus), @sizeOf(main_c.WSAcousticStatus));
    try std.testing.expectEqual(@sizeOf(abi_c.WSExampleResult), @sizeOf(main_c.WSExampleResult));
    try std.testing.expectEqual(@sizeOf(abi_c.WSAcousticGroup), @sizeOf(main_c.WSAcousticGroup));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(main_c.WSAcousticStatus));
    try std.testing.expectEqual(@as(usize, 1344), @sizeOf(main_c.WSExampleResult));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(main_c.WSAcousticGroup));
    try std.testing.expectEqual(@sizeOf(abi_c.WSOperationStatus), @sizeOf(main_c.WSOperationStatus));
    try std.testing.expectEqual(@sizeOf(abi_c.WSIntegrityReport), @sizeOf(main_c.WSIntegrityReport));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(main_c.WSOperationStatus));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(main_c.WSIntegrityReport));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_clap_load(null, null, 0));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_clap_index_pending(-2, -1));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_semantic_model_set(null, 2));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_semantic_status(null));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_search_with_embedding(null, null, 0, -2, null, -1));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_acoustic_index_pending(-2, 0));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_acoustic_status(null));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_search_by_example(null, -1, null, 1));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_search_by_example_pcm(null, 1, 1, 48_000, -1, null, 1));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_acoustic_group(0, null));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_operation_status(null));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_integrity_check(0, null));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_backup_create(null));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_backup_restore(null));

    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{.{
        .path = "/Semantic.wav",
        .relative_path = "Semantic.wav",
        .name = "Semantic.wav",
        .search_text = "semantic wav",
        .duration_ms = 100,
        .content_hash = 77,
        .file_size = 1,
        .mtime_ns = 1,
    }};
    try db.applyFolderIndex(1, &files);
    const id: i32 = @intCast((try db.inspectFile("Semantic.wav")).?.id);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_semantic_model_set("abi/model@1", 2));
    const values = [_]f32{ 1, 0 };
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_semantic_embedding_upsert(id, 77, &values, values.len));
    var status = std.mem.zeroes(main_c.WSSemanticStatus);
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_semantic_status(&status));
    status.struct_size = @sizeOf(main_c.WSSemanticStatus);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_semantic_status(&status));
    try std.testing.expectEqual(@as(u32, @sizeOf(main_c.WSSemanticStatus)), status.struct_size);
    try std.testing.expectEqual(@as(u32, 2), status.version);
    try std.testing.expectEqual(@as(c_int, 1), status.active);
    try std.testing.expectEqual(@as(i64, 1), status.embedded_count);
    var out: [2]main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_search_with_embedding("concept", &values, values.len, -1, &out, out.len));
    try std.testing.expectEqualStrings("Semantic.wav", resultName(&out[0]));
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_semantic_embedding_upsert(id, 77, null, 2));
}

test "opt-in real CLAP provider text and generated 48k WAV integration" {
    const runtime_ptr = env_c.getenv("WS_ORT_LIBRARY") orelse return error.SkipZigTest;
    const model_ptr = env_c.getenv("WS_CLAP_MODEL_DIR") orelse return error.SkipZigTest;
    const runtime = std.mem.span(runtime_ptr);
    const model_dir = std.mem.span(model_ptr);

    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try fixture.tmp.dir.createDir(io, "sounds", .default_dir);
    try writeSineWav48k(fixture.tmp.dir, "sounds/sine.wav");
    try writeFingerprintWav(fixture.tmp.dir, "sounds/long.wav", 48_000, 0, 15.0, 0.7, false);
    try writeFingerprintAiff(fixture.tmp.dir, "sounds/equivalent.aiff", 48_000, 1.0, 0.7);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "sounds/not-supported.mp3", .data = "not an audio decoder fixture" });
    const wav_path = try fixture.path("sounds/sine.wav");
    defer allocator.free(wav_path);

    try clap_provider.load(runtime, model_dir, 1);
    defer clap_provider.unload();
    var loaded_status = std.mem.zeroes(main_c.WSSemanticStatus);
    loaded_status.struct_size = @sizeOf(main_c.WSSemanticStatus);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_semantic_status(&loaded_status));
    try std.testing.expectEqual(@as(c_int, 1), loaded_status.provider_loaded);
    var provider_ref = clap_provider.acquire().?;
    var ids: [77]i64 = undefined;
    var mask: [77]i64 = undefined;
    try provider_ref.provider.tokenize("dog", &ids, &mask);
    try std.testing.expectEqualSlices(i64, &.{ 0, 16319, 2 }, ids[0..3]);
    try provider_ref.provider.tokenize("ocean waves", &ids, &mask);
    try std.testing.expectEqualSlices(i64, &.{ 0, 139, 35210, 6995, 2 }, ids[0..5]);
    provider_ref.release();

    var dog: [512]f32 = undefined;
    var rain: [512]f32 = undefined;
    var audio_embedding: [512]f32 = undefined;
    try clap_provider.embedText("dog", &dog);
    try clap_provider.embedText("rain", &rain);
    try clap_provider.embedAudio(wav_path, &audio_embedding);
    const sounds_path = try fixture.path("sounds");
    defer allocator.free(sounds_path);
    try search.indexFolder(allocator, 12, sounds_path);
    const indexed = try clap_provider.indexPending(allocator, 12, 0);
    try std.testing.expectEqual(@as(usize, 4), indexed.attempted);
    try std.testing.expectEqual(@as(usize, 3), indexed.successful);
    try std.testing.expectEqual(@as(usize, 1), indexed.failed);
    const semantic_status = try db.semanticStatus();
    try std.testing.expectEqual(@as(i64, 3), semantic_status.embedded_count);
    try std.testing.expectEqual(@as(i64, 1), semantic_status.failed_count);
    try std.testing.expectEqual(@as(i64, 0), semantic_status.pending_count);
    for ([_][]const f32{ &dog, &rain, &audio_embedding }) |values| {
        var norm: f64 = 0;
        for (values) |value| {
            try std.testing.expect(std.math.isFinite(value));
            norm += @as(f64, value) * value;
        }
        try std.testing.expectApproxEqAbs(@as(f64, 1), norm, 2.0e-4);
    }
    const text_cosine = try vector.dot(&dog, &rain);
    const dog_audio = try vector.dot(&dog, &audio_embedding);
    const rain_audio = try vector.dot(&rain, &audio_embedding);
    try std.testing.expect(text_cosine < 0.999 and text_cosine > -1.001);
    try std.testing.expect(@abs(dog_audio - rain_audio) > 1.0e-5);
}

test "indexed exact names survive BM25 exclusion and short typos need no shared trigram" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const rows = try allocator.alloc(db.ScannedFile, 301);
    defer {
        for (rows) |row| allocator.free(row.path);
        allocator.free(rows);
    }
    for (rows, 0..) |*row, i| {
        const name = if (i == 0) try allocator.dupe(u8, "Impact.wav") else try std.fmt.allocPrint(allocator, "Impact-{d}.wav", .{i});
        row.* = .{ .path = name, .relative_path = name, .name = name, .search_text = if (i == 0) "impact wav " ++ repeatedString("irrelevant detail decoration ", 300) else "impact wav", .duration_ms = 100, .content_hash = @intCast(i + 1), .file_size = 1, .mtime_ns = 1 };
    }
    try db.applyFolderIndex(1, rows);
    const exact = (try db.inspectFile("Impact.wav")).?;
    const query = search.buildQuery("Impact.wav");
    const capped = try db.unicodeCandidates(allocator, query.slice(), 0, 0, null, 256);
    defer allocator.free(capped);
    try std.testing.expectEqual(@as(usize, 256), capped.len);
    for (capped) |row| try std.testing.expect(row.file_id != exact.id);
    var results: [16]main_c.WSResult = undefined;
    try std.testing.expect(try search.search(allocator, "Impact.wav", null, &results, results.len) > 0);
    try std.testing.expectEqual(exact.id, results[0].file_id);
    try rawExec(fixture.db_path, "UPDATE files SET name='Renamed.wav',search_text='renamed wav' WHERE relative_path='Impact.wav';");
    try std.testing.expect(try search.search(allocator, "Renamed.wav", null, &results, results.len) > 0);
    try std.testing.expectEqual(exact.id, results[0].file_id);
    const dig = [_]db.ScannedFile{.{ .path = "/dig.wav", .relative_path = "dig.wav", .name = "Dig.wav", .search_text = "dig sand", .duration_ms = 100, .content_hash = 55, .file_size = 1, .mtime_ns = 1 }};
    try db.applyFolderIndex(2, &dig);
    for ([_][]const u8{ "dog", "dgi" }) |typo| {
        try std.testing.expectEqual(@as(usize, 1), try search.search(allocator, typo, 2, &results, results.len));
        try std.testing.expectEqualStrings("Dig.wav", resultName(&results[0]));
    }
}

test "disk staging cancels atomically and rejects competing publication" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const old = db.ScannedFile{ .path = "/old.wav", .relative_path = "old.wav", .name = "Old.wav", .search_text = "old", .duration_ms = 10, .content_hash = 10, .file_size = 1, .mtime_ns = 1 };
    try db.applyFolderIndex(1, &.{old});
    const identity = (try db.inspectFile(old.relative_path)).?;
    var stage = try db.IndexStage.init(1, null);
    defer stage.deinit();
    try std.testing.expectEqual(@as(i64, 10), (try stage.previous(old.relative_path)).?.content_hash);
    try stage.append(.{ .path = "/new.wav", .relative_path = "new.wav", .name = "New.wav", .search_text = "new", .duration_ms = 10, .content_hash = 20, .file_size = 1, .mtime_ns = 1 });
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, stage.publish(&cancel));
    try std.testing.expectEqual(identity.id, (try db.inspectFile(old.relative_path)).?.id);
    try std.testing.expectEqual(@as(?db.FileInfo, null), try db.inspectFile("new.wav"));
    var competing = try db.IndexStage.init(1, null);
    defer competing.deinit();
    try competing.retainUnchanged(old.relative_path);
    try db.applyFolderIndex(2, &.{.{ .path = "/other.wav", .relative_path = "other.wav", .name = "Other.wav", .search_text = "other", .duration_ms = 10, .content_hash = 30, .file_size = 1, .mtime_ns = 1 }});
    try std.testing.expectError(error.IndexSnapshotChanged, competing.publishAtRoot("/moved", null));
    try std.testing.expectEqual(identity.id, (try db.inspectFile(old.relative_path)).?.id);

    var reopened = try db.IndexStage.init(1, null);
    defer reopened.deinit();
    try reopened.retainUnchanged(old.relative_path);
    try openFixture(&fixture);
    try std.testing.expectError(error.IndexSnapshotChanged, reopened.publishAtRoot("/moved", null));
}

test "compact staging preserves retained analysis, moves roots and removes only missing identities" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const rows = [_]db.ScannedFile{
        .{ .path = "/old/nested/keep.wav", .relative_path = "nested/keep.wav", .name = "Keep.wav", .search_text = "bronze bell", .duration_ms = 1000, .content_hash = 10, .file_size = 20, .mtime_ns = 1 },
        .{ .path = "/old/change.wav", .relative_path = "change.wav", .name = "Change.wav", .search_text = "old effect", .duration_ms = 2000, .content_hash = 11, .file_size = 20, .mtime_ns = 1 },
        .{ .path = "/old/missing.wav", .relative_path = "missing.wav", .name = "Missing.wav", .search_text = "missing", .duration_ms = 3000, .content_hash = 12, .file_size = 20, .mtime_ns = 1 },
    };
    try db.applyFolderIndex(1, &rows);
    const keep = (try db.inspectFile(rows[0].relative_path)).?;
    const change = (try db.inspectFile(rows[1].relative_path)).?;
    try db.applyFolderIndex(2, &.{.{ .path = "/other.wav", .relative_path = "other.wav", .name = "Other.wav", .search_text = "other", .duration_ms = 10, .content_hash = 13, .file_size = 20, .mtime_ns = 1 }});
    _ = try db.setSemanticModel("test/compact-stage", 2);
    for ([_]db.FileInfo{ keep, change }) |file| {
        try db.upsertSemanticEmbedding(allocator, @intCast(file.id), file.content_hash, &.{ 1, 0 });
        try db.storeWaveformTiers(@intCast(file.id), file.content_hash, file.file_size, file.mtime_ns, 3, "universal", null);
    }
    var stage = try db.IndexStage.init(1, null);
    defer stage.deinit();
    try stage.retainUnchanged(rows[0].relative_path);
    var changed = rows[1];
    changed.path = "/new/change.wav";
    changed.content_hash = 99;
    changed.mtime_ns = 2;
    changed.search_text = "new effect";
    try stage.append(changed);
    try stage.append(.{ .path = "/new/added.wav", .relative_path = "added.wav", .name = "Added.wav", .search_text = "new", .duration_ms = 10, .content_hash = 100, .file_size = 20, .mtime_ns = 1 });
    try stage.publishAtRoot("/new/", null);
    const kept = (try db.inspectFile(rows[0].relative_path)).?;
    const updated = (try db.inspectFile(rows[1].relative_path)).?;
    try std.testing.expectEqual(keep.id, kept.id);
    try std.testing.expectEqual(change.id, updated.id);
    try std.testing.expectEqual(@as(i64, 99), updated.content_hash);
    try std.testing.expectEqual(@as(?db.FileInfo, null), try db.inspectFile("missing.wav"));
    try std.testing.expectEqual(@as(c_int, 3), try db.countForFolder(1));
    try std.testing.expectEqual(@as(c_int, 1), try db.countForFolder(2));
    try std.testing.expectEqual(@as(i64, 1), (try db.semanticStatus()).embedded_count);
    try std.testing.expectEqual(@as(i64, 1), (try db.waveformCacheStatus()).universal_count);
    var results: [1]main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(usize, 1), try search.search(allocator, "bronze bell", 1, &results, results.len));
    try std.testing.expectEqualStrings("/new/nested/keep.wav", std.mem.sliceTo(&results[0].path, 0));
    try std.testing.expectEqual(@as(i32, 1000), results[0].duration_ms);
    var ambiguous = try db.IndexStage.init(1, null);
    defer ambiguous.deinit();
    try ambiguous.retainUnchanged(rows[0].relative_path);
    try std.testing.expectError(error.DuplicateRelativePath, ambiguous.retainUnchanged(rows[0].relative_path));
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
}

test "cancellation during retained and verified move publication rolls back moves and removals" {
    const Hooks = struct {
        var cancel: std.atomic.Value(bool) = .init(false);
        fn install(handle: ?*db.c.sqlite3, _: [*c][*c]u8, _: ?*const db.c.sqlite3_api_routines) callconv(.c) c_int {
            return db.c.sqlite3_create_function_v2(handle, "ws_test_stage_cancel", 0, db.c.SQLITE_UTF8, null, stop, null, null, null);
        }
        fn stop(context: ?*db.c.sqlite3_context, _: c_int, _: [*c]?*db.c.sqlite3_value) callconv(.c) void {
            cancel.store(true, .release);
            db.c.sqlite3_result_null(context);
        }
    };
    Hooks.cancel.store(false, .release);
    const extension: *const fn () callconv(.c) void = @ptrCast(&Hooks.install);
    try std.testing.expectEqual(@as(c_int, db.c.SQLITE_OK), db.c.sqlite3_auto_extension(extension));
    defer _ = db.c.sqlite3_cancel_auto_extension(extension);
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try db.applyFolderIndex(1, &.{
        .{ .path = "/old/a.wav", .relative_path = "a.wav", .name = "A.wav", .search_text = "alpha", .duration_ms = 10, .content_hash = 1, .file_size = 1, .mtime_ns = 1, .sha256 = @as([32]u8, @splat(7)) },
        .{ .path = "/old/b.wav", .relative_path = "b.wav", .name = "B.wav", .search_text = "beta", .duration_ms = 10, .content_hash = 2, .file_size = 1, .mtime_ns = 1 },
    });
    try rawExec(fixture.db_path, "CREATE TRIGGER ws_test_stage_cancel AFTER UPDATE OF path ON files BEGIN SELECT ws_test_stage_cancel(); END;");
    var stage = try db.IndexStage.init(1, null);
    defer stage.deinit();
    try stage.retainUnchanged("a.wav");
    try std.testing.expectError(error.Cancelled, stage.publishAtRoot("/moved", &Hooks.cancel));
    try std.testing.expect(Hooks.cancel.load(.acquire));
    try std.testing.expectEqual(@as(c_int, 2), try db.countForFolder(1));
    var results: [1]main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(usize, 1), try search.search(allocator, "alpha", 1, &results, results.len));
    try std.testing.expectEqualStrings("/old/a.wav", std.mem.sliceTo(&results[0].path, 0));
    Hooks.cancel.store(false, .release);
    var verified = try db.IndexStage.init(1, null);
    defer verified.deinit();
    try verified.append(.{ .path = "/old/renamed.wav", .relative_path = "renamed.wav", .name = "Renamed.wav", .search_text = "alpha", .duration_ms = 10, .content_hash = 1, .file_size = 1, .mtime_ns = 1, .sha256 = @as([32]u8, @splat(7)) });
    try std.testing.expectError(error.Cancelled, verified.publishAtRoot("/old", &Hooks.cancel));
    try std.testing.expect(Hooks.cancel.load(.acquire));
    try std.testing.expectEqual(@as(c_int, 2), try db.countForFolder(1));
    try std.testing.expectEqual(@as(?db.FileInfo, null), try db.inspectFile("renamed.wav"));
    try std.testing.expect((try db.inspectFile("a.wav")) != null);
}

test "lexical search reads the committed snapshot while index publication is paused" {
    // A SQLite trigger pauses the actual publication transaction. A search must
    // finish before we release it, proving readers do not wait for the writer.
    const State = struct {
        var active: ?*@This() = null;
        mutex: sync.Mutex = .{},
        condition: sync.Condition = .{},
        entered: bool = false,
        released: bool = false,
        reader_done: std.atomic.Value(bool) = .init(false),
        reader_count: usize = 0,
        err: ?anyerror = null,
        stage: ?*db.IndexStage = null,

        fn install(handle: ?*db.c.sqlite3, _: [*c][*c]u8, _: ?*const db.c.sqlite3_api_routines) callconv(.c) c_int {
            return db.c.sqlite3_create_function_v2(handle, "ws_test_index_pause", 0, db.c.SQLITE_UTF8, active, pause, null, null, null);
        }
        fn pause(context: ?*db.c.sqlite3_context, _: c_int, _: [*c]?*db.c.sqlite3_value) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(db.c.sqlite3_user_data(context).?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.entered = true;
            self.condition.broadcast();
            while (!self.released) self.condition.wait(&self.mutex);
            db.c.sqlite3_result_null(context);
        }
        fn publish(self: *@This()) void {
            self.stage.?.publish(null) catch |err| {
                self.err = err;
            };
        }
        fn read(self: *@This()) void {
            var results: [2]main_c.WSResult = undefined;
            self.reader_count = search.search(std.heap.c_allocator, "bronze bell", null, &results, results.len) catch 0;
            self.reader_done.store(true, .release);
        }
    };
    var state = State{};
    State.active = &state;
    defer State.active = null;
    const extension: *const fn () callconv(.c) void = @ptrCast(&State.install);
    try std.testing.expectEqual(@as(c_int, db.c.SQLITE_OK), db.c.sqlite3_auto_extension(extension));
    defer _ = db.c.sqlite3_cancel_auto_extension(extension);
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const old = db.ScannedFile{ .path = "/old.wav", .relative_path = "old.wav", .name = "Old.wav", .search_text = "bronze bell", .duration_ms = 10, .content_hash = 1, .file_size = 1, .mtime_ns = 1 };
    try db.applyFolderIndex(1, &.{old});
    try rawExec(fixture.db_path, "CREATE TRIGGER ws_test_pause BEFORE UPDATE ON files BEGIN SELECT ws_test_index_pause(); END;");
    var stage = try db.IndexStage.init(1, null);
    defer stage.deinit();
    var changed = old;
    changed.search_text = "nylon chord";
    changed.mtime_ns = 2;
    changed.content_hash = 2;
    try stage.append(changed);
    state.stage = &stage;
    const publisher = try std.Thread.spawn(.{}, State.publish, .{&state});
    state.mutex.lock();
    while (!state.entered) state.condition.wait(&state.mutex);
    state.mutex.unlock();
    const reader = try std.Thread.spawn(.{}, State.read, .{&state});
    // Generous deadlock backstop; the assertion is snapshot availability, not
    // a performance threshold. Release both threads before asserting on failure.
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
    while (!state.reader_done.load(.acquire) and std.Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds)
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    const read_before_commit = state.reader_done.load(.acquire);
    state.mutex.lock();
    state.released = true;
    state.condition.broadcast();
    state.mutex.unlock();
    publisher.join();
    reader.join();
    try std.testing.expect(read_before_commit);
    try std.testing.expectEqual(@as(usize, 1), state.reader_count);
    if (state.err) |err| return err;
    var results: [2]main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(usize, 1), try search.search(allocator, "nylon chord", null, &results, results.len));
    try std.testing.expectEqual(@as(usize, 0), try search.search(allocator, "bronze bell", null, &results, results.len));
}

test "keyset browse preserves NOCASE ties without missing or duplicating rows" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const names = [_][]const u8{ "Alpha.wav", "alpha.wav", "Beta.wav", "beta.wav", "Gamma.wav", "Café.wav", "Zeta.wav", repeatedString("猫", 90) ++ ".wav" };
    var rows: [names.len]db.ScannedFile = undefined;
    for (names, &rows, 0..) |name, *row, i| row.* = .{ .path = name, .relative_path = name, .name = name, .search_text = name, .duration_ms = 10, .content_hash = @intCast(i + 1), .file_size = 1, .mtime_ns = 1 };
    try db.applyFolderIndex(1, &rows);
    const all = try db.listFolder(allocator, 1, 100);
    defer allocator.free(all);
    const request = main_c.ws_query_create().?;
    defer main_c.ws_query_destroy(request);
    var page: [3]main_c.WSResult = undefined;
    var after_name: [256]u8 = @splat(0);
    var after_id: i32 = 0;
    var seen: usize = 0;
    while (true) {
        const count = main_c.ws_list_folder_page_v2(request, 1, if (seen == 0) null else @ptrCast(&after_name), after_id, &page, page.len);
        try std.testing.expect(count >= 0);
        if (count == 0) break;
        for (page[0..@intCast(count)]) |result| {
            try std.testing.expect(seen < all.len);
            try std.testing.expectEqual(all[seen].file_id, result.file_id);
            seen += 1;
        }
        after_name = page[@intCast(count - 1)].name;
        after_id = page[@intCast(count - 1)].file_id;
    }
    try std.testing.expectEqual(all.len, seen);
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_list_folder_page_v2(request, 1, null, 0, &page, 1001));
    main_c.ws_query_cancel(request);
    try std.testing.expectEqual(@as(c_int, -2), main_c.ws_list_folder_page_v2(request, 1, null, 0, &page, page.len));
}

test "derived counters survive rollback source changes and checked compaction without rewriting live pages" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try rawExec(fixture.db_path, "PRAGMA page_size=4096; CREATE TABLE reserve(id INTEGER); DROP TABLE reserve;");
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{
        .{ .path = "/one.wav", .relative_path = "one.wav", .name = "One.wav", .search_text = "one", .duration_ms = 10, .content_hash = 10, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/two.wav", .relative_path = "two.wav", .name = "Two.wav", .search_text = "two", .duration_ms = 10, .content_hash = 20, .file_size = 1, .mtime_ns = 1 },
    };
    try db.applyFolderIndex(1, &files);
    const one: i32 = @intCast((try db.inspectFile("one.wav")).?.id);
    const two: i32 = @intCast((try db.inspectFile("two.wav")).?.id);
    _ = try db.setSemanticModel("test/counts", 2);
    try db.upsertSemanticEmbedding(allocator, one, 10, &.{ 1, 0 });
    try db.recordEmbeddingFailure(two, 20, "decode", "fixture");
    const algorithm = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    const blob = try fingerprint.serialize(allocator, &.{.{ .hash = 17, .frame = 1 }});
    defer allocator.free(blob);
    try db.upsertFingerprint(algorithm, one, 10, blob, &.{17});
    try db.rebuildAcousticGroups(allocator, algorithm);
    try db.recordFingerprintFailure(algorithm, two, 20, "decode", "fixture");
    try db.storeWaveformTiers(one, 10, 1, 1, 3, "universal", "detail");
    try db.recordWaveformFailure(two, 20, 1, 1, null, true, "fixture");
    try std.testing.expectEqual(@as(i64, 0), (try db.waveformCacheStatus()).pending_count);
    try std.testing.expectEqual(@as(i64, 0), (try db.semanticStatus()).pending_count);
    try std.testing.expectEqual(@as(i64, 0), (try db.fingerprintStatus(algorithm)).pending);
    try rawExec(fixture.db_path, "PRAGMA foreign_keys=ON; BEGIN; DELETE FROM file_embeddings; DELETE FROM file_fingerprints; UPDATE waveform_tiers SET detailed_blob=NULL,detailed_bytes=0; ROLLBACK;");
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
    const compact = try fixture.path("compact.db");
    defer allocator.free(compact);
    try db.compactTo(compact);
    try std.testing.expectEqual(@as(i64, 4096), try rawScalar(fixture.db_path, "PRAGMA page_size;"));
    try std.testing.expectEqual(@as(i64, 16384), try rawScalar(compact, "PRAGMA page_size;"));
    try std.testing.expectError(error.PathAlreadyExists, db.compactTo(compact));
    try rawExec(fixture.db_path, "PRAGMA foreign_keys=ON; UPDATE files SET content_hash=99,file_size=2,mtime_ns=2 WHERE relative_path='one.wav';");
    try std.testing.expectEqual(@as(i64, 1), (try db.waveformCacheStatus()).pending_count);
    try std.testing.expectEqual(@as(i64, 1), (try db.semanticStatus()).pending_count);
    try std.testing.expectEqual(@as(i64, 1), (try db.fingerprintStatus(algorithm)).pending);
    try db.rebuildAcousticGroups(allocator, algorithm);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
    try db.restoreFrom(compact);
    try std.testing.expectEqual(@as(i64, 1), (try db.semanticStatus()).embedded_count);
    try rawExec(fixture.db_path, "UPDATE catalog_stats SET universal_bytes=universal_bytes+1000;");
    try std.testing.expect((try db.integrityCheck(true)).errors_found > 0);
    const damaged = try fixture.path("damaged-counts.db");
    defer allocator.free(damaged);
    try db.backupTo(damaged);
    try db.restoreFrom(damaged);
    try std.testing.expectEqual(@as(i64, 9), (try db.waveformCacheStatus()).universal_bytes);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
}

test "waveform eviction batches more than 256 details while preserving universals" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try db.insertSyntheticBenchmarkFiles(520);
    for (0..520) |i| try db.storeWaveformTiers(@intCast(i + 1), @intCast(i + 1), @intCast(1000 + i % 1000000), @intCast(i), 3, "u", "dddd");
    try db.setWaveformDetailedBudget(0);
    const status = try db.waveformCacheStatus();
    try std.testing.expectEqual(@as(i64, 520), status.universal_count);
    try std.testing.expectEqual(@as(i64, 0), status.detailed_count);
    try std.testing.expectEqual(@as(i64, 0), status.detailed_bytes);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
}

test "fingerprint postings and candidate memory obey hard budgets under common-selector fallback" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const count = db.FINGERPRINT_CANDIDATE_BUDGET + 512;
    try db.insertSyntheticBenchmarkFiles(count);
    const algorithm = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    const selectors = [_]u32{ 0x101010, 0x202020, 0x303030, 0x3f4040 };
    const blob = try fingerprint.serialize(allocator, &.{.{ .hash = selectors[0], .frame = 1 }});
    defer allocator.free(blob);
    for (0..count) |i| try db.upsertFingerprint(algorithm, @intCast(i + 1), @intCast(i + 1), blob, &selectors);
    var stats = db.FingerprintCandidateStats{};
    const ids = try db.fingerprintCandidateIdsWithStats(allocator, algorithm, &selectors, null, 64, &stats);
    defer allocator.free(ids);
    try std.testing.expect(stats.capped);
    try std.testing.expectEqual(db.FINGERPRINT_POSTING_BUDGET, stats.postings_read);
    try std.testing.expectEqual(db.FINGERPRINT_CANDIDATE_BUDGET, stats.peak_candidates);
    try std.testing.expectEqual(@as(usize, 64), ids.len);
    for (ids, 0..) |id, i| try std.testing.expectEqual(@as(i32, @intCast(i + 1)), id);
}

test "graded controlled hybrid fixture and nDCG guard ranking quality" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try std.testing.expect(try @import("optimization_bench.zig").qualityBench(io) >= 0.95);
}

test "bilingual lexical judgments protect ranking, recall and negative queries" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try db.open(allocator, fixture.db_path);
    const quality = try @import("optimization_bench.zig").lexicalQualityBench();
    try std.testing.expect(quality.ndcg >= 0.99);
    try std.testing.expectEqual(@as(f64, 1), quality.recall);
    try std.testing.expectEqual(@as(usize, 0), quality.false_positives);
}

test "WSResult C ABI layout remains stable and negative counts are rejected" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(main_c.WSResult, "file_id"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(main_c.WSResult, "folder_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(main_c.WSResult, "path"));
    try std.testing.expectEqual(@as(usize, 1032), @offsetOf(main_c.WSResult, "name"));
    try std.testing.expectEqual(@as(usize, 1288), @offsetOf(main_c.WSResult, "duration_ms"));
    try std.testing.expectEqual(@as(usize, 1296), @offsetOf(main_c.WSResult, "content_hash"));
    try std.testing.expectEqual(@as(usize, 1304), @sizeOf(main_c.WSResult));
    try std.testing.expectEqual(@sizeOf(abi_c.WSResult), @sizeOf(main_c.WSResult));
    try std.testing.expectEqual(@alignOf(abi_c.WSResult), @alignOf(main_c.WSResult));
    var out: [1]main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_search("x", -1, &out, -1));
    var samples: [1]f32 = undefined;
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_waveform("/none", &samples, -1));
}

fn rawScalar(path: []const u8, sql: [*:0]const u8) !i64 {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    var handle: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path_z.ptr, &handle) != c.SQLITE_OK) return error.RawOpenFailed;
    defer _ = c.sqlite3_close(handle);
    try db.registerVectorFunctions(handle.?);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(handle, sql, -1, &stmt, null) != c.SQLITE_OK) return error.RawPrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.RawStepFailed;
    return c.sqlite3_column_int64(stmt, 0);
}

fn rawExec(path: []const u8, sql: [*:0]const u8) !void {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    var handle: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path_z.ptr, &handle) != c.SQLITE_OK) return error.RawOpenFailed;
    defer _ = c.sqlite3_close(handle);
    try db.registerVectorFunctions(handle.?);
    if (c.sqlite3_exec(handle, sql, null, null, null) != c.SQLITE_OK) return error.RawExecFailed;
}

test "five-minute fingerprint input uses bounded PCM memory and rejects duration before payload reads" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var header: [44]u8 = @splat(0);
    const frames = 300 * 16000;
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], 36 + frames * 4, .little);
    @memcpy(header[8..20], "WAVEfmt \x10\x00\x00\x00");
    std.mem.writeInt(u16, header[20..22], 3, .little);
    std.mem.writeInt(u16, header[22..24], 1, .little);
    std.mem.writeInt(u32, header[24..28], 16000, .little);
    std.mem.writeInt(u32, header[28..32], 64000, .little);
    std.mem.writeInt(u16, header[32..34], 4, .little);
    std.mem.writeInt(u16, header[34..36], 32, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], frames * 4, .little);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "bounded.wav", .data = &header });
    {
        const file = try fixture.tmp.dir.openFile(io, "bounded.wav", .{ .mode = .read_write });
        defer file.close(io);
        try file.setLength(io, 44 + frames * 4);
    }
    const path = try fixture.path("bounded.wav");
    defer allocator.free(path);
    const memory = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    // Silence is rejected for insufficient detail after the complete timeline;
    // an attempted 19.2 MB PCM allocation would instead fail this 1 MiB budget.
    try std.testing.expectError(error.InsufficientFingerprintDetail, fingerprint.fromFile(fixed.allocator(), io, path));
    std.mem.writeInt(u32, header[4..8], 36 + (frames + 16000) * 4, .little);
    std.mem.writeInt(u32, header[40..44], (frames + 16000) * 4, .little);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "bounded.wav", .data = &header });
    {
        const file = try fixture.tmp.dir.openFile(io, "bounded.wav", .{ .mode = .read_write });
        defer file.close(io);
        try file.setLength(io, 44 + (frames + 16000) * 4);
    }
    var reads: u64 = 0;
    @import("audio_file.zig").bytes_read = &reads;
    defer @import("audio_file.zig").bytes_read = null;
    try std.testing.expectError(error.FingerprintDurationLimit, fingerprint.fromFile(allocator, io, path));
    try std.testing.expect(reads < 1024);
}

test "sampled identities verify complete bytes instead of confirming different middle content" {
    const identity = @import("file_identity.zig");
    const reader_module = @import("audio_file.zig");
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const payload_bytes = 18 * 1024 * 1024;
    const bytes = try allocator.alloc(u8, 44 + payload_bytes);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + payload_bytes, .little);
    @memcpy(bytes[8..20], "WAVEfmt \x10\x00\x00\x00");
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], 48000, .little);
    std.mem.writeInt(u32, bytes[28..32], 96000, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], payload_bytes, .little);
    try fixture.tmp.dir.createDir(io, "sounds", .default_dir);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "sounds/a.wav", .data = bytes });
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "sounds/c.wav", .data = bytes });
    bytes[9 * 1024 * 1024 + 12345] = 7;
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "sounds/b.wav", .data = bytes });
    try openFixture(&fixture);
    const root = try fixture.path("sounds");
    defer allocator.free(root);
    try search.indexFolder(allocator, 81, root);
    const a = (try db.inspectFile("a.wav")).?;
    const b = (try db.inspectFile("b.wav")).?;
    const c_file = (try db.inspectFile("c.wav")).?;
    try std.testing.expectEqual(a.content_hash, b.content_hash);
    try std.testing.expectEqual(a.content_hash, c_file.content_hash);
    try std.testing.expect(a.content_hash < 0);
    try std.testing.expectEqual(identity.Kind.sampled, a.identity_kind);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_duplicate_count(a.content_hash));
    var info = std.mem.zeroes(main_c.WSFileIdentity);
    info.struct_size = @sizeOf(main_c.WSFileIdentity);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_file_identity_v1(@intCast(a.id), &info));
    try std.testing.expectEqual(@as(u32, 2), info.kind);
    try std.testing.expectEqual(@as(u32, 1), info.algorithm);
    try std.testing.expectEqual(@sizeOf(abi_c.WSFileIdentity), @sizeOf(main_c.WSFileIdentity));
    try std.testing.expectEqual(@sizeOf(abi_c.WSDuplicateVerification), @sizeOf(main_c.WSDuplicateVerification));
    try std.testing.expectEqual(@sizeOf(abi_c.WSFingerprintStorageResult), @sizeOf(main_c.WSFingerprintStorageResult));
    const request = main_c.ws_query_create().?;
    defer main_c.ws_query_destroy(request);
    var verified = std.mem.zeroes(main_c.WSDuplicateVerification);
    verified.struct_size = @sizeOf(main_c.WSDuplicateVerification);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_duplicate_verify_v1(request, @intCast(a.id), &verified));
    try std.testing.expectEqual(@as(u32, 3), verified.candidate_count);
    try std.testing.expectEqual(@as(u32, 2), verified.verified_count);
    try std.testing.expect(verified.source_bytes_read > bytes.len * 2);

    // Interrupt after actual file I/O, before any result can be published.
    const Hooks = struct {
        var active_request: ?*@import("query.zig").Request = null;
        var limit: u64 = 0;
        fn cancelAfterReads() void {
            if (reader_module.bytes_read.?.* >= limit) active_request.?.cancel();
        }
        var dir: std.Io.Dir = undefined;
        var failure: ?anyerror = null;
        var replaced = false;
        fn replaceAfterReads() void {
            if (!replaced and reader_module.bytes_read.?.* >= limit) {
                replaced = true;
                dir.rename("sounds/replacement.wav", dir, "sounds/a.wav", io) catch |err| {
                    failure = err;
                };
            }
        }
    };
    Hooks.active_request = request;
    Hooks.limit = 20 * 1024 * 1024;
    reader_module.Testing.after_read = Hooks.cancelAfterReads;
    defer reader_module.Testing.after_read = null;
    verified.verified_count = 99;
    try std.testing.expectEqual(@as(c_int, -2), main_c.ws_duplicate_verify_v1(request, @intCast(a.id), &verified));
    try std.testing.expectEqual(@as(u32, 99), verified.verified_count);
    reader_module.Testing.after_read = null;

    // Replacing the path with equal bytes/size/mtime must still invalidate the
    // active descriptor's confirmation; an inode change is not a relocation.
    bytes[9 * 1024 * 1024 + 12345] = 0;
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "sounds/replacement.wav", .data = bytes });
    {
        const replacement = try fixture.tmp.dir.openFile(io, "sounds/replacement.wav", .{});
        defer replacement.close(io);
        try replacement.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = a.mtime_ns } } });
    }
    const fresh = main_c.ws_query_create().?;
    defer main_c.ws_query_destroy(fresh);
    Hooks.dir = fixture.tmp.dir;
    reader_module.Testing.after_read = Hooks.replaceAfterReads;
    try std.testing.expectEqual(@as(c_int, -1), main_c.ws_duplicate_verify_v1(fresh, @intCast(a.id), &verified));
    try std.testing.expect(Hooks.replaced);
    try std.testing.expect(Hooks.failure == null);
    try std.testing.expectEqual(@as(u32, 99), verified.verified_count);
    reader_module.Testing.after_read = null;
    try search.indexFolderWithOptions(allocator, 81, root, .{ .deep = true });
    const deep_a = (try db.inspectFile("a.wav")).?;
    const deep_b = (try db.inspectFile("b.wav")).?;
    try std.testing.expectEqual(a.id, deep_a.id);
    try std.testing.expectEqual(identity.Kind.full, deep_a.identity_kind);
    try std.testing.expect(deep_a.content_hash > 0 and deep_a.content_hash != deep_b.content_hash);
    try std.testing.expectEqual(@as(c_int, 2), main_c.ws_duplicate_count(deep_a.content_hash));
    // Metadata-only changes are byte changes; identical PCM is not exact identity.
    bytes[9 * 1024 * 1024 + 12345] = 7;
    const metadata_bytes = try allocator.alloc(u8, bytes.len + 24);
    defer allocator.free(metadata_bytes);
    @memcpy(metadata_bytes[0..bytes.len], bytes);
    std.mem.writeInt(u32, metadata_bytes[4..8], @intCast(metadata_bytes.len - 8), .little);
    const metadata = metadata_bytes[bytes.len..];
    @memcpy(metadata[0..4], "LIST");
    std.mem.writeInt(u32, metadata[4..8], 16, .little);
    @memcpy(metadata[8..16], "INFOISFT");
    std.mem.writeInt(u32, metadata[16..20], 4, .little);
    @memcpy(metadata[20..24], "edit");
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "sounds/b.wav", .data = metadata_bytes });
    try search.indexFolderWithOptions(allocator, 81, root, .{ .deep = true });
    try std.testing.expect((try db.inspectFile("b.wav")).?.content_hash != deep_b.content_hash);
}

test "legacy fingerprint repacking resumes across migration cancellation reopen and backup restore" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const files = [_]db.ScannedFile{
        .{ .path = "/a.wav", .relative_path = "a.wav", .name = "a.wav", .search_text = "a", .duration_ms = 1000, .content_hash = 101, .file_size = 1, .mtime_ns = 1 },
        .{ .path = "/b.wav", .relative_path = "b.wav", .name = "b.wav", .search_text = "b", .duration_ms = 1000, .content_hash = 102, .file_size = 1, .mtime_ns = 1 },
    };
    try db.applyFolderIndex(82, &files);
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    var landmarks: [200]fingerprint.Landmark = undefined;
    for (&landmarks, 0..) |*landmark, i| landmark.* = .{ .hash = @intCast(i / 25), .frame = @intCast((i % 25) * 32) };
    const raw = try fingerprint.serializeRaw(allocator, &landmarks);
    defer allocator.free(raw);
    const selectors = try fingerprint.selectors(allocator, &landmarks);
    defer allocator.free(selectors);
    var ids: [2]i32 = undefined;
    for (files, 0..) |file, i| {
        ids[i] = @intCast((try db.inspectFile(file.relative_path)).?.id);
        try db.upsertFingerprint(algorithm_id, ids[i], file.content_hash, raw, selectors);
    }
    try db.replaceAcousticEdges(algorithm_id, ids[0], &.{.{ .other_file_id = ids[1], .score_ppm = 900000, .aligned = 32 }});
    try db.rebuildAcousticGroups(allocator, algorithm_id);
    db.close();
    try rawExec(fixture.db_path, @import("storage_schema.zig").dropForTests ++ "PRAGMA user_version=13;");
    try openFixture(&fixture);
    try std.testing.expectEqual(db.SCHEMA_VERSION, try db.schemaVersion());
    try std.testing.expectEqual(@as(i64, 2), try rawScalar(fixture.db_path, "SELECT COUNT(*) FROM file_fingerprints WHERE storage_version=0"));
    const first = try db.repackFingerprints(allocator, 1);
    try std.testing.expectEqual(@as(u32, 1), first.processed_count);
    try std.testing.expect(first.bytes_after < first.bytes_before);
    try std.testing.expectEqual(@as(u32, 2), (try db.acousticGroupInfo(algorithm_id, ids[0])).?.member_count);
    try std.testing.expectEqual(@as(i64, 0), (try db.fingerprintStatus(algorithm_id)).pending);
    const request = main_c.ws_query_create().?;
    defer main_c.ws_query_destroy(request);
    main_c.ws_query_cancel(request);
    var outcome = std.mem.zeroes(main_c.WSFingerprintStorageResult);
    outcome.struct_size = @sizeOf(main_c.WSFingerprintStorageResult);
    try std.testing.expectEqual(@as(c_int, -2), main_c.ws_fingerprint_storage_repack_v1(request, 16, &outcome));
    try std.testing.expectEqual(@as(i64, 1), try rawScalar(fixture.db_path, "SELECT COUNT(*) FROM file_fingerprints WHERE storage_version=0"));
    const backup = try fixture.path("mixed.sqlite");
    defer allocator.free(backup);
    try db.backupTo(backup);
    db.close();
    try openFixture(&fixture);
    const fresh = main_c.ws_query_create().?;
    defer main_c.ws_query_destroy(fresh);
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_fingerprint_storage_repack_v1(fresh, 16, &outcome));
    try std.testing.expectEqual(@as(u32, 1), outcome.processed_count);
    try db.restoreFrom(backup);
    try std.testing.expectEqual(@as(i64, 1), try rawScalar(fixture.db_path, "SELECT COUNT(*) FROM file_fingerprints WHERE storage_version=0"));
    _ = try db.repackFingerprints(allocator, 16);
    const stored = (try db.loadFingerprint(allocator, algorithm_id, ids[1])).?;
    defer allocator.free(stored.landmarks);
    const decoded = try fingerprint.deserialize(allocator, stored.landmarks);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(fingerprint.Landmark, &landmarks, decoded);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
    try rawExec(fixture.db_path, "UPDATE file_fingerprints SET landmarks=zeroblob(length(landmarks)),storage_version=0 WHERE file_id=1;");
    try std.testing.expect((try db.integrityCheck(false)).errors_found > 0);
    try std.testing.expectError(error.InvalidFingerprintBlob, db.repackFingerprints(allocator, 1));
    const corrupt = try fixture.path("corrupt-codec.sqlite");
    defer allocator.free(corrupt);
    try db.backupTo(corrupt);
    try std.testing.expectError(error.InvalidFingerprintBlob, db.restoreFrom(corrupt));
    try db.restoreFrom(backup);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
    const Hooks = struct {
        var changed: [2]db.ScannedFile = undefined;
        var failure: ?anyerror = null;
        fn changeSource() void {
            db.Testing.before_fingerprint_repack_publish = null;
            db.applyFolderIndex(82, &changed) catch |err| {
                failure = err;
            };
        }
    };
    Hooks.changed = files;
    Hooks.changed[1].content_hash = 103;
    Hooks.changed[1].file_size = 2;
    Hooks.changed[1].mtime_ns = 2;
    db.Testing.before_fingerprint_repack_publish = Hooks.changeSource;
    defer db.Testing.before_fingerprint_repack_publish = null;
    try std.testing.expectError(error.StaleContentHash, db.repackFingerprints(allocator, 1));
    try std.testing.expect(Hooks.failure == null);
    try std.testing.expect((try db.loadFingerprint(allocator, algorithm_id, ids[1])) == null);
    try std.testing.expectEqual(@as(i64, 1), (try db.fingerprintStatus(algorithm_id)).pending);
}

test "verified rename retains ID, embeddings, fingerprints and retimed waveform tiers" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try fixture.tmp.dir.createDirPath(io, "sounds/nested");
    try writeWav(fixture.tmp.dir, "sounds/old.wav", 500, 19);
    const root = try fixture.path("sounds");
    defer allocator.free(root);
    try search.indexFolderWithOptions(allocator, 1, root, .{ .fast = true });
    const old = (try db.inspectFile("old.wav")).?;
    _ = try db.setSemanticModel("move-proof", 2);
    try db.upsertSemanticEmbedding(allocator, @intCast(old.id), old.content_hash, &.{ 1, 0 });
    _ = try acoustic.indexPending(allocator, 1, 1);
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    const before_acoustic = try db.fingerprintStatus(algorithm_id);
    const config = waveform.types.WSWaveformAnalyzerConfig{
        .struct_size = @sizeOf(waveform.types.WSWaveformAnalyzerConfig),
        .version = 1,
        .purpose = waveform.PURPOSE_DETAILED,
        .flags = waveform.FLAG_LOUDNESS,
        .backend = waveform.BACKEND_PORTABLE,
        .reserved0 = 0,
        .sample_rate = 8000,
        .total_frames = 1,
        .channel_count = 1,
        .reserved1 = 0,
        .source_file_size = old.file_size,
        .source_mtime_ns = old.mtime_ns,
        .source_content_hash = old.content_hash,
        .reserved = .{ 0, 0 },
    };
    const analyzer = try waveform.Analyzer.create(allocator, config);
    defer analyzer.deinit();
    const sample = [_]f32{0.25};
    try analyzer.push(.{ .struct_size = @sizeOf(waveform.types.WSWaveformPCMBuffer), .version = 1, .layout = waveform.LAYOUT_INTERLEAVED, .channel_count = 1, .frame_count = 1, .interleaved = &sample, .planes = null, .reserved = .{ 0, 0 } });
    const result = try analyzer.finish();
    defer result.deinit();
    const blob = try allocator.alloc(u8, try waveform.serializedSize(result, waveform.TIER_UNIVERSAL));
    defer allocator.free(blob);
    _ = try waveform.serialize(result, waveform.TIER_UNIVERSAL, blob);
    try db.storeWaveformTiers(@intCast(old.id), old.content_hash, old.file_size, old.mtime_ns, 3, blob, null);
    try fixture.tmp.dir.rename("sounds/old.wav", fixture.tmp.dir, "sounds/nested/new.wav", io);
    var moved = try fixture.tmp.dir.openFile(io, "sounds/nested/new.wav", .{ .mode = .read_write });
    defer moved.close(io);
    try moved.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = old.mtime_ns + std.time.ns_per_s } } });
    // A hash-mode change rebinds analysis without recomputing it after complete
    // byte verification. Deep/normal identity strength still follows the mode.
    try search.indexFolder(allocator, 1, root);
    const current = (try db.inspectFile("nested/new.wav")).?;
    try std.testing.expectEqual(old.id, current.id);
    try std.testing.expect(current.content_hash > 0);
    try std.testing.expectEqual(@import("file_identity.zig").Kind.full, current.identity_kind);
    try std.testing.expectEqual(@as(i64, 1), (try db.semanticStatus()).embedded_count);
    try std.testing.expectEqual(before_acoustic.indexed, (try db.fingerprintStatus(algorithm_id)).indexed);
    var loaded: [4096]u8 = undefined;
    const len = (try db.loadWaveformTierBlob(@intCast(old.id), false, &loaded)).?;
    const restored = try waveform.deserialize(allocator, loaded[0..len]);
    defer restored.deinit();
    try std.testing.expectEqual(current.mtime_ns, restored.source_mtime_ns);
    try std.testing.expectEqual(current.content_hash, restored.source_content_hash);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
    var output: main_c.WSResult = undefined;
    try std.testing.expectEqual(@as(c_int, 1), main_c.ws_file_lookup_v1(@intCast(old.id), &output));
    try std.testing.expect(std.mem.endsWith(u8, std.mem.sliceTo(&output.path, 0), "/nested/new.wav"));
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_file_lookup_v1(2_000_000_000, &output));
    try openFixture(&fixture);
    try std.testing.expectEqual(old.id, (try db.inspectFile("nested/new.wav")).?.id);
    try writeWav(fixture.tmp.dir, "sounds/nested/new.wav", 750, 41);
    try search.indexFolder(allocator, 1, root);
    try std.testing.expectEqual(@as(i64, 0), (try db.semanticStatus()).embedded_count);
    try std.testing.expectEqual(@as(i64, 0), (try db.fingerprintStatus(algorithm_id)).indexed);
    try std.testing.expectEqual(@as(?usize, null), try db.loadWaveformTierBlob(@intCast(old.id), false, &loaded));
}

test "move matching rejects copies, duplicate ambiguity and absent proofs atomically" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    const proof: [32]u8 = @splat(7);
    const rows = [_]db.ScannedFile{
        .{ .path = "/root/a.wav", .relative_path = "a.wav", .name = "a.wav", .search_text = "a", .duration_ms = 1, .content_hash = -7, .file_size = 3, .mtime_ns = 1, .sha256 = proof },
        .{ .path = "/root/unknown.wav", .relative_path = "unknown.wav", .name = "unknown.wav", .search_text = "unknown", .duration_ms = 1, .content_hash = -7, .file_size = 3, .mtime_ns = 1 },
    };
    try db.applyFolderIndex(1, &rows);
    const a = (try db.inspectFile("a.wav")).?;
    var stage = try db.IndexStage.init(1, null);
    defer stage.deinit();
    try stage.retainUnchanged("a.wav");
    try stage.retainUnchanged("unknown.wav");
    var copy = rows[0];
    copy.path = "/root/copy.wav";
    copy.relative_path = "copy.wav";
    copy.name = "copy.wav";
    try stage.append(copy);
    try stage.publishAtRoot("/root", null);
    const copied = (try db.inspectFile("copy.wav")).?;
    try std.testing.expect(a.id != copied.id);
    var ambiguous = try db.IndexStage.init(1, null);
    defer ambiguous.deinit();
    copy.path = "/root/new.wav";
    copy.relative_path = "new.wav";
    copy.name = "new.wav";
    try ambiguous.append(copy);
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, ambiguous.publishAtRoot("/root", &cancel));
    try std.testing.expectEqual(a.id, (try db.inspectFile("a.wav")).?.id);
    // A fresh staging call after cancellation sees both old duplicate sources.
    var retried = try db.IndexStage.init(1, null);
    defer retried.deinit();
    try retried.append(copy);
    try retried.publishAtRoot("/root", null);
    const fresh = (try db.inspectFile("new.wav")).?;
    try std.testing.expect(fresh.id != a.id and fresh.id != copied.id);
    // A same-sized sampled hash is not a proof; even a unique match gets no ID.
    var unproven = try db.IndexStage.init(1, null);
    defer unproven.deinit();
    copy.sha256 = null;
    copy.path = "/root/other.wav";
    copy.relative_path = "other.wav";
    try unproven.append(copy);
    try unproven.publishAtRoot("/root", null);
    try std.testing.expect(fresh.id != (try db.inspectFile("other.wav")).?.id);
    // Cross-library moves never adopt a row from another folder snapshot.
    const other_id = (try db.inspectFile("other.wav")).?.id;
    copy.path = "/other-library/other.wav";
    copy.sha256 = proof;
    var cross = try db.IndexStage.init(2, null);
    defer cross.deinit();
    try cross.append(copy);
    try cross.publishAtRoot("/other-library", null);
    try std.testing.expect((try db.lookupFile(0, copy.path)).?.file_id != other_id);
    try std.testing.expect((try db.lookupFile(@intCast(other_id), null)) != null);
}

test "background full-byte proof protects fast-mode moves from sampled collisions" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try fixture.tmp.dir.createDirPath(io, "sounds");
    try writeWav(fixture.tmp.dir, "sounds/a.wav", 70_000, 9);
    const root = try fixture.path("sounds");
    defer allocator.free(root);
    try search.indexFolderWithOptions(allocator, 1, root, .{ .fast = true });
    const old = (try db.inspectFile("a.wav")).?;
    const cancellation = @import("cancellation.zig");
    const token = cancellation.begin();
    defer cancellation.end();
    var bytes: u64 = 0;
    @import("audio_file.zig").bytes_read = &bytes;
    defer @import("audio_file.zig").bytes_read = null;
    _ = cancellation.cancel();
    try std.testing.expectError(error.Cancelled, db.captureMoveIdentity(@intCast(old.id), old.content_hash, token));
    try std.testing.expectEqual(@as(u64, 0), bytes);
    // Native waveform publication establishes the same proof for every host-
    // decoded format, without changing the fast content hash or requiring CLAP.
    try std.testing.expectEqual(@as(c_int, 0), main_c.ws_waveform_tiers_store(@intCast(old.id), old.content_hash, old.file_size, old.mtime_ns, 3, "universal", 9, null, 0));
    try std.testing.expectEqual(@as(u64, @intCast(old.file_size)), bytes);
    const baseline_bytes = bytes;
    bytes = 0;
    try fixture.tmp.dir.rename("sounds/a.wav", fixture.tmp.dir, "sounds/b.wav", io);
    try search.indexFolderWithOptions(allocator, 1, root, .{ .fast = true });
    try std.testing.expectEqual(old.id, (try db.inspectFile("b.wav")).?.id);
    const rename_bytes = bytes;
    bytes = 0;
    var file = try fixture.tmp.dir.openFile(io, "sounds/b.wav", .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, &.{ 55, 66 }, 150_000);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = old.mtime_ns } } });
    try fixture.tmp.dir.rename("sounds/b.wav", fixture.tmp.dir, "sounds/c.wav", io);
    try search.indexFolderWithOptions(allocator, 1, root, .{ .fast = true });
    const different = (try db.inspectFile("c.wav")).?;
    try std.testing.expectEqual(old.content_hash, different.content_hash);
    try std.testing.expect(old.id != different.id);
    std.debug.print("move proof: source_bytes={d}, baseline_bytes={d}, rename_reader_bytes={d}, collision_reader_bytes={d}; sampled collision rejected\n", .{ old.file_size, baseline_bytes, rename_bytes, bytes });
}

test "schema 14 migration preserves analysis but does not invent move proofs" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try fixture.tmp.dir.createDirPath(io, "sounds");
    try writeWav(fixture.tmp.dir, "sounds/old.wav", 100, 9);
    const root = try fixture.path("sounds");
    defer allocator.free(root);
    try search.indexFolder(allocator, 1, root);
    const old = (try db.inspectFile("old.wav")).?;
    _ = try db.setSemanticModel("migration-proof", 2);
    try db.upsertSemanticEmbedding(allocator, @intCast(old.id), old.content_hash, &.{ 1, 0 });
    db.close();
    try rawExec(fixture.db_path, @import("move_schema.zig").dropForTests ++ "PRAGMA user_version=14;");
    try openFixture(&fixture);
    try std.testing.expectEqual(db.SCHEMA_VERSION, try db.schemaVersion());
    try std.testing.expectEqual(@as(i64, 1), (try db.semanticStatus()).embedded_count);
    try fixture.tmp.dir.rename("sounds/old.wav", fixture.tmp.dir, "sounds/new.wav", io);
    try search.indexFolder(allocator, 1, root);
    try std.testing.expect(old.id != (try db.inspectFile("new.wav")).?.id);
    try std.testing.expectEqual(@as(u32, 0), (try db.integrityCheck(true)).errors_found);
}

test "replaced or unavailable scan roots cannot publish deletions" {
    const Hooks = struct {
        var dir: std.Io.Dir = undefined;
        var fired = false;
        var failure: ?anyerror = null;
        fn replaceRoot() void {
            if (fired) return;
            fired = true;
            dir.rename("sounds", dir, "disconnected", io) catch |err| {
                failure = err;
                return;
            };
            dir.createDirPath(io, "sounds") catch |err| {
                failure = err;
            };
        }
    };
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try openFixture(&fixture);
    try fixture.tmp.dir.createDirPath(io, "sounds");
    try writeWav(fixture.tmp.dir, "sounds/keep.wav", 100, 4);
    const root = try fixture.path("sounds");
    defer allocator.free(root);
    try search.indexFolder(allocator, 1, root);
    const old = (try db.inspectFile("keep.wav")).?;
    try writeWav(fixture.tmp.dir, "sounds/new.wav", 70_000, 8);
    Hooks.dir = fixture.tmp.dir;
    Hooks.fired = false;
    Hooks.failure = null;
    @import("audio_file.zig").Testing.after_read = Hooks.replaceRoot;
    defer @import("audio_file.zig").Testing.after_read = null;
    try std.testing.expectError(error.FileChangedDuringScan, search.indexFolderWithOptions(allocator, 1, root, .{ .fast = true }));
    try std.testing.expect(Hooks.fired and Hooks.failure == null);
    try std.testing.expectEqual(old.id, (try db.inspectFile("keep.wav")).?.id);
    try std.testing.expectEqual(@as(c_int, 1), try db.countForFolder(1));
}
