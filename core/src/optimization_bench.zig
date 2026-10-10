//! Disposable production-path benchmarks; PATH must not already exist.
const std = @import("std");
const db = @import("db.zig");
const search = @import("search.zig");
const main_c = @import("main_c.zig");
const fingerprint = @import("fingerprint.zig");
const perf = @import("perf.zig");
const relevance = @import("relevance.zig");
const allocator = std.heap.c_allocator;
const runs = 30;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const mode = args.next() orelse return error.MissingMode;
    const path = args.next() orelse return error.MissingPath;
    const count = try std.fmt.parseInt(usize, args.next() orelse "10000", 10);
    if (args.next() != null or count == 0 or count > std.math.maxInt(i32)) return error.InvalidArguments;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    file.close(io);
    defer {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
            const sidecar = std.fmt.allocPrint(allocator, "{s}{s}", .{ path, suffix }) catch continue;
            defer allocator.free(sidecar);
            std.Io.Dir.cwd().deleteFile(io, sidecar) catch {};
        }
    }
    try db.open(allocator, path);
    defer db.close();
    if (std.mem.eql(u8, mode, "fingerprint")) return fingerprintBench(io, count);
    if (std.mem.eql(u8, mode, "scan")) return scanBench(io, path, count);
    if (std.mem.eql(u8, mode, "index-contention")) return indexContentionBench(io, count);
    if (std.mem.eql(u8, mode, "quality")) {
        const score = try qualityBench(io);
        if (score < 0.95) return error.QualityRegression;
        return;
    }
    try db.insertSyntheticBenchmarkFiles(count);
    if (std.mem.eql(u8, mode, "catalog")) return catalogBench(io);
    if (std.mem.eql(u8, mode, "waveform")) return waveformBench(io, count);
    if (std.mem.eql(u8, mode, "acoustic")) return acousticBench(io, count);
    return error.InvalidMode;
}

fn catalogBench(io: std.Io) !void {
    const output = try allocator.alloc(main_c.WSResult, 100);
    defer allocator.free(output);
    var exact: [runs]u64 = undefined;
    var typo: [runs]u64 = undefined;
    var staged: [runs]u64 = undefined;
    for (0..runs) |i| {
        var start = std.Io.Clock.awake.now(io);
        const n = try search.search(allocator, "impact-00000000.wav", null, output.ptr, output.len);
        if (n == 0 or output[0].file_id != 1) return error.ExactNameRegression;
        exact[i] = elapsed(io, start);
        start = std.Io.Clock.awake.now(io);
        if (try search.search(allocator, "impaxt", null, output.ptr, output.len) == 0) return error.TypoRegression;
        typo[i] = elapsed(io, start);
        const request = main_c.ws_query_create() orelse return error.OutOfMemory;
        defer main_c.ws_query_destroy(request);
        start = std.Io.Clock.awake.now(io);
        if (main_c.ws_search_v2(request, "impaxt", -1, output.ptr, @intCast(output.len), 1) <= 0 or
            main_c.ws_search_v2(request, "impaxt", -1, output.ptr, @intCast(output.len), 0) <= 0) return error.StagedSearchRegression;
        staged[i] = elapsed(io, start);
    }
    report("exact_name", &exact);
    report("typo", &typo);
    report("lexical_then_hybrid_without_provider", &staged);
    std.debug.print("peak_rss_bytes={d}\n", .{perf.peakRssBytes()});
}

// Measures metadata reads while the real staging and atomic publication paths
// run on another thread. The corpus stays in the disposable benchmark database.
fn indexContentionBench(io: std.Io, count: usize) !void {
    const rows = try allocator.alloc(db.ScannedFile, count);
    defer allocator.free(rows);
    var initialized: usize = 0;
    defer for (rows[0..initialized]) |row| allocator.free(row.path);
    for (rows, 0..) |*row, i| {
        const path = try std.fmt.allocPrint(allocator, "impact-{d:0>8}.wav", .{i});
        row.* = .{ .path = path, .relative_path = path, .name = path, .search_text = "impact original", .duration_ms = 10, .content_hash = 1, .file_size = 1, .mtime_ns = 1 };
        initialized += 1;
    }
    try db.applyFolderIndex(1, rows);
    const State = struct {
        done: std.atomic.Value(bool) = .init(false),
        stage: ?db.IndexStage = null,
        err: ?anyerror = null,
        publish: bool = false,
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            if (self.publish) {
                self.stage.?.publish(null) catch |err| {
                    self.err = err;
                };
            } else {
                self.stage = db.IndexStage.init(1, null) catch |err| {
                    self.err = err;
                    return;
                };
            }
        }
    };
    var state = State{};
    defer if (state.stage) |*stage| stage.deinit();
    for ([_][]const u8{ "manifest", "publication" }, 0..) |phase, index| {
        if (index == 1) {
            for (rows) |*row| {
                row.mtime_ns = 2;
                row.content_hash = 2;
                row.search_text = "impact updated";
                try state.stage.?.append(row.*);
            }
            state.publish = true;
            state.done.store(false, .release);
        }
        const start = std.Io.Clock.awake.now(io);
        const worker = try std.Thread.spawn(.{}, State.run, .{&state});
        var worst: u64 = 0;
        var queries: usize = 0;
        var results: [10]main_c.WSResult = undefined;
        while (!state.done.load(.acquire)) {
            const query_start = std.Io.Clock.awake.now(io);
            const found = search.search(allocator, "impact-00000000.wav", null, &results, results.len) catch |err| {
                worker.join();
                return err;
            };
            if (found != 1) {
                worker.join();
                return error.ConcurrentSearchRegression;
            }
            worst = @max(worst, elapsed(io, query_start));
            queries += 1;
        }
        worker.join();
        if (state.err) |err| return err;
        std.debug.print("{s}_ms={d:.3} concurrent_queries={d} worst_query_ms={d:.3}\n", .{ phase, perf.milliseconds(elapsed(io, start)), queries, perf.milliseconds(worst) });
    }
    std.debug.print("index_count={d} peak_rss_bytes={d}\n", .{ count, perf.peakRssBytes() });
}

fn waveformBench(io: std.Io, count: usize) !void {
    const universal: [1024]u8 = @splat(1);
    const start = std.Io.Clock.awake.now(io);
    for (0..count) |row| {
        try db.storeWaveformTiers(@intCast(row + 1), @intCast(row + 1), @intCast(1000 + row % 1_000_000), @intCast(row), 3, &universal, null);
    }
    std.debug.print("universal_store_count={d} total_ms={d:.3}\n", .{ count, perf.milliseconds(elapsed(io, start)) });
    var status_times: [runs]u64 = undefined;
    for (&status_times) |*time| {
        const t = std.Io.Clock.awake.now(io);
        const status = try db.waveformCacheStatus();
        if (status.universal_count != count or status.universal_bytes != count * universal.len or status.pending_count != 0) return error.CounterRegression;
        time.* = elapsed(io, t);
    }
    report("waveform_status", &status_times);
    std.debug.print("peak_rss_bytes={d}\n", .{perf.peakRssBytes()});
}

fn acousticBench(io: std.Io, count: usize) !void {
    const algorithm = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    var query: [fingerprint.SELECTOR_COUNT]u32 = undefined;
    for (&query, 0..) |*hash, i| hash.* = @intCast(0x081010 + i * 0x020202);
    var blob: [8]u8 = undefined;
    std.mem.writeInt(u32, blob[4..8], 0, .little);
    for (0..count) |row| {
        const hash = query[row % query.len];
        std.mem.writeInt(u32, blob[0..4], hash, .little);
        try db.upsertFingerprint(algorithm, @intCast(row + 1), @intCast(row + 1), &blob, &.{hash});
    }
    var times: [runs]u64 = undefined;
    for (&times) |*time| {
        const start = std.Io.Clock.awake.now(io);
        const ids = if (comptime @hasDecl(db, "fingerprintCandidateIdsWithStats")) bounded: {
            var stats = db.FingerprintCandidateStats{};
            const found = try db.fingerprintCandidateIdsWithStats(allocator, algorithm, &query, null, 128, &stats);
            if (stats.postings_read > db.FINGERPRINT_POSTING_BUDGET or stats.peak_candidates > db.FINGERPRINT_CANDIDATE_BUDGET) return error.BudgetRegression;
            if (time == &times[0]) std.debug.print("postings_read={d} peak_candidates={d} capped={}\n", .{ stats.postings_read, stats.peak_candidates, stats.capped });
            break :bounded found;
        } else try db.fingerprintCandidateIds(allocator, algorithm, &query, null, 128);
        defer allocator.free(ids);
        if (ids.len == 0) return error.AcousticRegression;
        time.* = elapsed(io, start);
    }
    report("acoustic_candidates", &times);
    std.debug.print("peak_rss_bytes={d}\n", .{perf.peakRssBytes()});
}

fn fingerprintBench(io: std.Io, seconds: usize) !void {
    const samples = try allocator.alloc(f32, try std.math.mul(usize, seconds, 16000));
    defer allocator.free(samples);
    var random = std.Random.DefaultPrng.init(42);
    for (samples) |*sample| sample.* = random.random().float(f32) * 2 - 1;
    var times: [runs]u64 = undefined;
    var hash: u64 = 0;
    var landmarks_count: usize = 0;
    for (&times) |*time| {
        const start = std.Io.Clock.awake.now(io);
        const landmarks = try fingerprint.fromSamples(allocator, samples);
        defer allocator.free(landmarks);
        time.* = elapsed(io, start);
        const blob = try fingerprint.serialize(allocator, landmarks);
        defer allocator.free(blob);
        const digest = std.hash.Wyhash.hash(0, blob);
        if (hash != 0 and hash != digest) return error.FingerprintChanged;
        hash = digest;
        landmarks_count = landmarks.len;
    }
    report("fingerprint", &times);
    std.debug.print("seconds={d} landmarks={d} fingerprint_digest={x} peak_rss_bytes={d}\n", .{ seconds, landmarks_count, hash, perf.peakRssBytes() });
}

fn scanBench(io: std.Io, path: []const u8, count: usize) !void {
    const directory = try std.fmt.allocPrint(allocator, "{s}.audio", .{path});
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDir(io, directory, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var wav: [46]u8 = @splat(0);
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 38, .little);
    @memcpy(wav[8..20], "WAVEfmt \x10\x00\x00\x00");
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 1, .little);
    std.mem.writeInt(u32, wav[24..28], 16000, .little);
    std.mem.writeInt(u32, wav[28..32], 32000, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 2, .little);
    for (0..count) |row| {
        const name = try std.fmt.allocPrint(allocator, "{s}/impact-{d:0>8}.wav", .{ directory, row });
        defer allocator.free(name);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = &wav });
    }
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, directory, allocator);
    defer allocator.free(absolute);
    var start = std.Io.Clock.awake.now(io);
    try search.indexFolderWithOptions(allocator, 1, absolute, .{ .fast = true });
    std.debug.print("scan_count={d} first_scan_ms={d:.3}\n", .{ count, perf.milliseconds(elapsed(io, start)) });
    start = std.Io.Clock.awake.now(io);
    try search.indexFolderWithOptions(allocator, 1, absolute, .{ .fast = true });
    if (try db.countForFolder(1) != count) return error.ScanRegression;
    std.debug.print("unchanged_scan_ms={d:.3} peak_rss_bytes={d}\n", .{ perf.milliseconds(elapsed(io, start)), perf.peakRssBytes() });
}

// Controlled professional-effect descriptors and deliberately imperfect vectors.
// This tests fusion, not a claim about real CLAP inference or audio relevance.
pub fn qualityBench(io: std.Io) !f64 {
    const File = struct { name: []const u8, search_text: []const u8, duration_ms: i32, folder: i32, embedding: []const f32 };
    const Judgment = struct { name: []const u8, grade: u8 };
    const Query = struct { text: []const u8, embedding: []const f32, folder: ?i32 = null, judgments: []const Judgment };
    const Fixture = struct { files: []const File, queries: []const Query };
    const parsed = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/search-quality.json"), .{});
    defer parsed.deinit();
    const fixture = parsed.value;
    for ([_]i32{ 1, 2 }) |folder| {
        var rows: std.ArrayList(db.ScannedFile) = .empty;
        defer {
            for (rows.items) |row| allocator.free(row.path);
            rows.deinit(allocator);
        }
        for (fixture.files, 0..) |file, i| {
            if (file.folder != 1 and file.folder != 2) return error.InvalidQualityFixture;
            if (file.folder != folder) continue;
            const path = try std.fmt.allocPrint(allocator, "/quality/{d}/{s}", .{ folder, file.name });
            errdefer allocator.free(path);
            try rows.append(allocator, .{ .path = path, .relative_path = file.name, .name = file.name, .search_text = file.search_text, .duration_ms = file.duration_ms, .content_hash = @intCast(i + 1), .file_size = 1000, .mtime_ns = 1 });
        }
        try db.applyFolderIndex(folder, rows.items);
    }
    _ = try db.setSemanticModel("benchmark/controlled-quality-v1", 8);
    for (fixture.files) |file| {
        const indexed = (try db.inspectFile(file.name)) orelse return error.InvalidQualityFixture;
        try db.upsertSemanticEmbedding(allocator, @intCast(indexed.id), indexed.content_hash, file.embedding);
    }
    var total: f64 = 0;
    var empty_results: usize = 0;
    const times = try allocator.alloc(u64, fixture.queries.len);
    defer allocator.free(times);
    for (fixture.queries, times) |query, *time| {
        var results: [10]main_c.WSResult = undefined;
        const start = std.Io.Clock.awake.now(io);
        const count = try search.searchWithEmbedding(allocator, query.text, query.embedding, query.folder, &results, results.len);
        time.* = elapsed(io, start);
        var actual: [10]u8 = undefined;
        const ideal = try allocator.alloc(u8, query.judgments.len);
        defer allocator.free(ideal);
        for (query.judgments, ideal) |judgment, *grade| {
            if (judgment.grade > 3) return error.InvalidQualityFixture;
            grade.* = judgment.grade;
        }
        for (results[0..count], 0..) |result, i| {
            actual[i] = 0;
            for (query.judgments) |judgment| if (std.mem.eql(u8, std.mem.sliceTo(&result.name, 0), judgment.name)) {
                actual[i] = judgment.grade;
                break;
            };
        }
        const score = relevance.ndcg10(actual[0..count], ideal);
        total += score;
        if (query.judgments.len == 0) empty_results += count;
        std.debug.print("quality_query=\"{s}\" ndcg@10={d:.3} count={d}\n", .{ query.text, score, count });
    }
    const mean = total / @as(f64, @floatFromInt(fixture.queries.len));
    report("quality_search", times);
    std.debug.print("quality_cases={d} mean_ndcg@10={d:.6} empty_query_results={d}\n", .{ fixture.queries.len, mean, empty_results });
    return mean;
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
}

fn report(label: []const u8, times: []u64) void {
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    std.debug.print("{s}_ms p50={d:.3} p95={d:.3}\n", .{ label, perf.milliseconds(perf.percentile(times, 50)), perf.milliseconds(perf.percentile(times, 95)) });
}
