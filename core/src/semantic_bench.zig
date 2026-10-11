//! End-to-end SQLite retrieval, not an in-memory dot-product microbenchmark.
//! create PATH COUNT uniform|clustered|dense [corpus.f32]
//! compare|exact|quantized|auto PATH QUERIES [K=20] [FOLDER=-1] [queries.f32|-] [MIN_MS=0] [MAX_MS=0]
//! Optional files contain consecutive normalized 512-D little-endian Float32 rows.
const std = @import("std");
const db = @import("db.zig");
const vector = @import("vector.zig");
const perf = @import("perf.zig");
const c = db.c;
const allocator = std.heap.c_allocator;
const dimension = 512;
const Distribution = enum { uniform, clustered, dense };

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const command = args.next() orelse return error.MissingCommand;
    const path = args.next() orelse return error.MissingPath;
    const count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingCount, 10);
    if (count == 0 or count > std.math.maxInt(i32)) return error.InvalidCount;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (std.mem.eql(u8, command, "create")) {
        const distribution = std.meta.stringToEnum(Distribution, args.next() orelse "uniform") orelse return error.InvalidDistribution;
        const input = args.next();
        if (args.next() != null) return error.InvalidArguments;
        try create(io, path, count, distribution, input);
    } else {
        const mode = if (std.mem.eql(u8, command, "compare")) null else std.meta.stringToEnum(db.VectorRetrievalMode, command) orelse return error.InvalidMode;
        const k = try std.fmt.parseInt(usize, args.next() orelse "20", 10);
        const folder = try std.fmt.parseInt(i32, args.next() orelse "-1", 10);
        const query_arg = args.next();
        const queries = if (query_arg != null and !std.mem.eql(u8, query_arg.?, "-")) query_arg else null;
        const min_ms = try std.fmt.parseInt(i32, args.next() orelse "0", 10);
        const max_ms = try std.fmt.parseInt(i32, args.next() orelse "0", 10);
        if (args.next() != null or k == 0 or k > db.SQ8_MAX_SEED / 4 or count > 10_000 or min_ms < 0 or max_ms < 0 or (max_ms != 0 and max_ms < min_ms)) return error.InvalidArguments;
        try evaluate(io, path, count, k, .{ .folder_id = if (folder < 0) null else folder, .min_duration_ms = min_ms, .max_duration_ms = max_ms }, mode, queries);
    }
}

fn openRaw(path: []const u8, flags: c_int) !*c.sqlite3 {
    const z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(z);
    var handle: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(z.ptr, &handle, flags, null) != c.SQLITE_OK) {
        if (handle != null) _ = c.sqlite3_close(handle);
        return error.OpenFailed;
    }
    errdefer _ = c.sqlite3_close(handle);
    try db.registerVectorFunctions(handle.?);
    return handle.?;
}

fn exec(handle: *c.sqlite3, sql: [*:0]const u8) !void {
    if (c.sqlite3_exec(handle, sql, null, null, null) != c.SQLITE_OK) {
        std.debug.print("SQLite: {s}\n", .{c.sqlite3_errmsg(handle)});
        return error.SqlFailed;
    }
}

fn prepare(handle: *c.sqlite3, sql: [*:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(handle, sql, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    return stmt orelse error.PrepareFailed;
}

fn scalar(handle: *c.sqlite3, sql: [*:0]const u8) !i64 {
    const stmt = try prepare(handle, sql);
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.StepFailed;
    return c.sqlite3_column_int64(stmt, 0);
}

fn generate(row: usize, distribution: Distribution, values: *[dimension]f32) !void {
    var noise = std.Random.DefaultPrng.init(0x5753535138 ^ row);
    var center = std.Random.DefaultPrng.init(0x434c5553544552 ^ (row % 64));
    for (values) |*value| {
        const sample = noise.random().float(f32) * 2 - 1;
        value.* = switch (distribution) {
            .uniform => sample,
            .clustered => center.random().float(f32) * 2 - 1 + sample * 0.35,
            .dense => center.random().float(f32) * 2 - 1 + sample * 0.001,
        };
    }
    try vector.normalize(values);
}

fn readVector(file: std.Io.File, io: std.Io, row: usize, values: *[dimension]f32) !void {
    var bytes: [dimension * 4]u8 = undefined;
    if (try file.readPositionalAll(io, &bytes, row * bytes.len) != bytes.len) return error.TruncatedVectorFile;
    try vector.decodeNormalizedInto(&bytes, values);
}

fn create(io: std.Io, path: []const u8, count: usize, distribution: Distribution, input_path: ?[]const u8) !void {
    // Never replace a user's database. All generated artifacts live at this new path.
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    file.close(io);
    const input = if (input_path) |p| try std.Io.Dir.cwd().openFile(io, p, .{}) else null;
    defer if (input) |f| f.close(io);
    const start = std.Io.Clock.awake.now(io);
    try db.open(allocator, path);
    errdefer db.close();
    _ = try db.setSemanticModel("benchmark/sq8-v1", dimension);
    try db.insertSyntheticBenchmarkFiles(count);
    db.close();
    const handle = try openRaw(path, c.SQLITE_OPEN_READWRITE);
    defer _ = c.sqlite3_close(handle);
    try exec(handle, db.DROP_QUANTIZED_INDEX_SQL ++ " PRAGMA journal_mode=DELETE; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; CREATE TABLE semantic_benchmark(distribution INTEGER,imported INTEGER); BEGIN IMMEDIATE;");
    errdefer exec(handle, "ROLLBACK;") catch {};
    const meta = try prepare(handle, "INSERT INTO semantic_benchmark VALUES(?,?)");
    defer _ = c.sqlite3_finalize(meta);
    _ = c.sqlite3_bind_int(meta, 1, @backingInt(distribution));
    _ = c.sqlite3_bind_int(meta, 2, @intFromBool(input != null));
    if (c.sqlite3_step(meta) != c.SQLITE_DONE) return error.StepFailed;
    const insert = try prepare(handle, "INSERT INTO file_embeddings(model_id,file_id,source_content_hash,vector) VALUES(1,?,?,?)");
    defer _ = c.sqlite3_finalize(insert);
    var values: [dimension]f32 = undefined;
    var bytes: [dimension * 4]u8 = undefined;
    for (0..count) |row| {
        if (input) |f| try readVector(f, io, row, &values) else try generate(row, distribution, &values);
        for (values, 0..) |value, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], @bitCast(value), .little);
        _ = c.sqlite3_reset(insert);
        _ = c.sqlite3_bind_int64(insert, 1, @intCast(row + 1));
        _ = c.sqlite3_bind_int64(insert, 2, @intCast(row + 1));
        _ = c.sqlite3_bind_blob(insert, 3, &bytes, bytes.len, null);
        if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.InsertFailed;
    }
    try exec(handle, "COMMIT; VACUUM;");
    const before = try scalar(handle, "PRAGMA page_count;");
    const build_start = std.Io.Clock.awake.now(io);
    try exec(handle, db.QUANTIZED_INDEX_SQL ++ @import("schema_optimizations.zig").quantizedCounters ++ "UPDATE embedding_models SET quantized_count=(SELECT COUNT(*) FROM semantic_sq8 WHERE model_id=embedding_models.id);");
    const build_ns = build_start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    const after = try scalar(handle, "PRAGMA page_count;");
    const page_size = try scalar(handle, "PRAGMA page_size;");
    std.debug.print("created count={d} dimension={d} distribution={s} imported={} original_db_bytes={d} sq8_index_bytes={d} total_db_bytes={d} index_build_ms={d:.3} total_build_ms={d:.3} build_peak_rss_bytes={d}\n", .{
        count,                       dimension,                                                                       @tagName(distribution), input != null, before * page_size, (after - before) * page_size, after * page_size,
        perf.milliseconds(build_ns), perf.milliseconds(start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds()), perf.peakRssBytes(),
    });
}

fn evaluate(io: std.Io, path: []const u8, runs: usize, k: usize, filter: vector.Filter, mode: ?db.VectorRetrievalMode, query_path: ?[]const u8) !void {
    // Require the benchmark marker before db.open can migrate anything.
    const metadata = blk: {
        const handle = try openRaw(path, c.SQLITE_OPEN_READONLY);
        defer _ = c.sqlite3_close(handle);
        const imported = try scalar(handle, "SELECT imported FROM semantic_benchmark") != 0;
        const distribution = std.enums.fromInt(Distribution, try scalar(handle, "SELECT distribution FROM semantic_benchmark")) orelse return error.InvalidDistribution;
        const count: usize = @intCast(try scalar(handle, "SELECT COUNT(*) FROM file_embeddings"));
        break :blk .{ .imported = imported, .distribution = distribution, .count = count };
    };
    const count = metadata.count;
    const distribution = metadata.distribution;
    const imported = metadata.imported;
    if (count == 0 or (imported and query_path == null)) return error.MissingHeldOutQueries;
    const input = if (query_path) |p| try std.Io.Dir.cwd().openFile(io, p, .{}) else null;
    defer if (input) |f| f.close(io);
    try db.open(allocator, path);
    defer db.close();
    const exact_times = try allocator.alloc(u64, runs);
    defer allocator.free(exact_times);
    const compact_times = try allocator.alloc(u64, runs);
    defer allocator.free(compact_times);
    var recall_sum: f64 = 0;
    var minimum_recall: f64 = 1;
    var first_exact: u64 = 0;
    var first_compact: u64 = 0;
    var scanned: usize = 0;
    var reranked: usize = 0;
    var refinement_scanned: usize = 0;
    var used_quantized = false;
    var payload_bytes: [2]usize = .{ 0, 0 };
    var values: [dimension]f32 = undefined;
    for (0..runs + 1) |run| {
        if (input) |f| try readVector(f, io, if (run == 0) 0 else run - 1, &values) else try generate(count + run, distribution, &values);
        var exact: ?db.StreamingVectorMatches = null;
        defer if (exact) |result| allocator.free(result.matches);
        var compact: ?db.StreamingVectorMatches = null;
        defer if (compact) |result| allocator.free(result.matches);
        // Alternate order in paired comparisons; report first query separately.
        for (0..2) |turn| {
            const selected: db.VectorRetrievalMode = if (mode) |m| m else if ((turn + run) % 2 == 0) .exact else .auto;
            if (mode != null and turn == 1) break;
            const start = std.Io.Clock.awake.now(io);
            const result = (try db.streamActiveVectorTopKWithMode(allocator, &values, filter, k, selected)) orelse return error.NoModel;
            const ns: u64 = @intCast(start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
            if (selected == .exact) {
                exact = result;
                if (run == 0) first_exact = ns else exact_times[run - 1] = ns;
            } else {
                compact = result;
                if (run == 0) first_compact = ns else compact_times[run - 1] = ns;
            }
            scanned = result.scanned;
            reranked = @max(reranked, result.reranked);
            refinement_scanned = @max(refinement_scanned, result.refinement_scanned);
            used_quantized = used_quantized or result.quantized;
            const payload = if (result.quantized)
                (result.scanned + result.refinement_scanned) * (dimension + 8) + result.reranked * dimension * 4
            else
                result.scanned * dimension * 4;
            const index: usize = if (selected == .exact) 0 else 1;
            payload_bytes[index] = @max(payload_bytes[index], payload);
        }
        if (mode == null and run > 0) {
            var found: usize = 0;
            for (exact.?.matches) |expected| {
                for (compact.?.matches) |actual| {
                    if (actual.file_id == expected.file_id) {
                        // Reranking must publish the exact Float32 score, not SQ8.
                        if (actual.score != expected.score) return error.InexactRerankScore;
                        found += 1;
                        break;
                    }
                }
            }
            const recall = if (exact.?.matches.len == 0) 1 else @as(f64, @floatFromInt(found)) / @as(f64, @floatFromInt(exact.?.matches.len));
            recall_sum += recall;
            minimum_recall = @min(minimum_recall, recall);
        }
    }
    std.debug.print("count={d} distribution={s} queries={d} k={d} folder={d} min_ms={d} max_ms={d} mode={s} used_sq8={} scanned={d} max_reranked={d} max_refinement_scanned={d} query_peak_rss_bytes={d}\n", .{
        count, @tagName(distribution), runs, k, filter.folder_id orelse -1, filter.min_duration_ms, filter.max_duration_ms, if (mode) |m| @tagName(m) else "compare", used_quantized, scanned, reranked, refinement_scanned, perf.peakRssBytes(),
    });
    if (mode == null or mode.? == .exact) report("exact", first_exact, exact_times);
    if (mode == null or mode.? != .exact) report("selected", first_compact, compact_times);
    // Logical code/vector blob bytes, not physical disk or SQLite page traffic.
    std.debug.print("max_vector_payload_bytes exact={d} selected={d}\n", .{ payload_bytes[0], payload_bytes[1] });
    if (mode == null) {
        std.debug.print("recall@{d} mean={d:.6} min={d:.6}\n", .{ k, recall_sum / @as(f64, @floatFromInt(runs)), minimum_recall });
        if (minimum_recall < 1) return error.RecallRegression;
    }
}

fn report(label: []const u8, first: u64, times: []u64) void {
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    std.debug.print("{s}_ms first={d:.3} p50={d:.3} p95={d:.3}\n", .{ label, perf.milliseconds(first), perf.milliseconds(perf.percentile(times, 50)), perf.milliseconds(perf.percentile(times, 95)) });
}
