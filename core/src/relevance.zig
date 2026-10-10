const std = @import("std");
const db = @import("db.zig");
const search = @import("search.zig");
const clap_provider = @import("clap_provider.zig");
const types = @import("types.zig");
const TOP_K = 10;
const Grades = std.StringHashMap(u8);

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const runtime_path = args.next() orelse return usage();
    const model_dir = args.next() orelse return usage();
    const audio_dir = args.next() orelse return usage();
    const labels_path = args.next() orelse return usage();
    const judgments_path = args.next();
    if (args.next() != null) return usage();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const labels_bytes = try std.Io.Dir.cwd().readFileAlloc(io, labels_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(labels_bytes);
    var labels = std.StringHashMap([]const u8).init(allocator);
    defer labels.deinit();
    var categories = std.StringHashMap(void).init(allocator);
    defer categories.deinit();
    var lines = std.mem.splitScalar(u8, labels_bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.MalformedLabels;
        const name = line[0..tab];
        const category = line[tab + 1 ..];
        if (name.len == 0 or category.len == 0 or labels.contains(name)) return error.MalformedLabels;
        try labels.put(name, category);
        try categories.put(category, {});
    }
    if (labels.count() == 0 or (judgments_path == null and categories.count() < 2)) return error.InsufficientLabels;
    const judgments_bytes = if (judgments_path) |path| try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) else null;
    defer if (judgments_bytes) |bytes| allocator.free(bytes);
    var queries = std.StringHashMap(Grades).init(allocator);
    defer {
        var it = queries.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        queries.deinit();
    }
    if (judgments_bytes) |bytes| {
        var rows = std.mem.splitScalar(u8, bytes, '\n');
        while (rows.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const query = fields.next() orelse return error.MalformedJudgments;
            const name = fields.next() orelse return error.MalformedJudgments;
            const grade = std.fmt.parseInt(u8, fields.next() orelse return error.MalformedJudgments, 10) catch return error.MalformedJudgments;
            if (fields.next() != null or query.len == 0 or query.len > 1024 or !labels.contains(name) or grade > 3) return error.MalformedJudgments;
            const entry = try queries.getOrPut(query);
            if (!entry.found_existing) {
                entry.value_ptr.* = Grades.init(allocator);
                entry.key_ptr.* = allocator.dupe(u8, query) catch |err| {
                    _ = queries.remove(query);
                    return err;
                };
            }
            if (entry.value_ptr.contains(name)) return error.DuplicateJudgment;
            try entry.value_ptr.put(name, grade);
        }
    } else {
        var categories_it = categories.iterator();
        while (categories_it.next()) |category| {
            const query = try allocator.dupe(u8, category.key_ptr.*);
            std.mem.replaceScalar(u8, query, '_', ' ');
            var grades = Grades.init(allocator);
            errdefer {
                allocator.free(query);
                grades.deinit();
            }
            var labels_it = labels.iterator();
            while (labels_it.next()) |entry| if (std.mem.eql(u8, entry.value_ptr.*, category.key_ptr.*)) {
                try grades.put(entry.key_ptr.*, 1);
            };
            try queries.put(query, grades);
        }
    }
    if (queries.count() == 0) return error.InsufficientJudgments;
    // A NEW, disposable database: never delete/overwrite an existing catalog.
    var nonce: u64 = undefined;
    std.Io.random(io, std.mem.asBytes(&nonce));
    const db_path = try std.fmt.allocPrint(allocator, "{s}/.wavesearch-relevance-{x}.db", .{ std.fs.path.dirname(labels_path) orelse ".", nonce });
    defer allocator.free(db_path);
    const reserved = try std.Io.Dir.cwd().createFile(io, db_path, .{ .exclusive = true });
    reserved.close(io);
    defer {
        std.Io.Dir.cwd().deleteFile(io, db_path) catch {};
        for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
            const sidecar = std.fmt.allocPrint(allocator, "{s}{s}", .{ db_path, suffix }) catch continue;
            defer allocator.free(sidecar);
            std.Io.Dir.cwd().deleteFile(io, sidecar) catch {};
        }
    }
    try db.open(allocator, db_path);
    defer db.close();
    const absolute_audio = try std.Io.Dir.cwd().realPathFileAlloc(io, audio_dir, allocator);
    defer allocator.free(absolute_audio);
    try search.indexFolder(allocator, 1, absolute_audio);
    try clap_provider.load(runtime_path, model_dir, 2);
    defer clap_provider.unload();
    const indexed = try clap_provider.indexPending(allocator, 1, 0);
    if (indexed.successful != labels.count() or indexed.failed != 0) return error.IncompleteSemanticIndex;
    var top1_hits: usize = 0;
    var top5_hits: usize = 0;
    var reciprocal_sum: f64 = 0;
    var ndcg_sum: f64 = 0;
    var queries_it = queries.iterator();
    while (queries_it.next()) |entry| {
        const query = entry.key_ptr.*;
        const parsed = search.parseSearchQuery(query);
        var results: [TOP_K]types.WSResult = undefined;
        const count = if (parsed.text.isEmpty() or parsed.impossible) try search.search(allocator, query, 1, &results, TOP_K) else semantic: {
            var embedding: [512]f32 = undefined;
            try clap_provider.embedText(parsed.text.slice(), &embedding);
            break :semantic try search.searchWithEmbedding(allocator, query, &embedding, 1, &results, TOP_K);
        };
        var grades: [TOP_K]u8 = undefined;
        var ideal: std.ArrayList(u8) = .empty;
        defer ideal.deinit(allocator);
        var grades_it = entry.value_ptr.valueIterator();
        while (grades_it.next()) |grade| try ideal.append(allocator, grade.*);
        var first_rank: ?usize = null;
        std.debug.print("query={s}\n", .{query});
        for (results[0..count], 0..) |result, rank| {
            const name = std.mem.sliceTo(&result.name, 0);
            grades[rank] = entry.value_ptr.get(name) orelse 0;
            std.debug.print("  {d}. {s} [grade={d}]\n", .{ rank + 1, name, grades[rank] });
            if (first_rank == null and rank < 5 and grades[rank] > 0) first_rank = rank + 1;
        }
        if (first_rank) |rank| {
            if (rank == 1) top1_hits += 1;
            top5_hits += 1;
            reciprocal_sum += 1.0 / @as(f64, @floatFromInt(rank));
        }
        const score = ndcg10(grades[0..count], ideal.items);
        ndcg_sum += score;
        std.debug.print("  ndcg@10={d:.3}\n", .{score});
    }
    const n: f64 = @floatFromInt(queries.count());
    const top1 = @as(f64, @floatFromInt(top1_hits)) / n;
    const recall5 = @as(f64, @floatFromInt(top5_hits)) / n;
    const mrr5 = reciprocal_sum / n;
    const ndcg = ndcg_sum / n;
    std.debug.print("{s}: clips={d} queries={d} top1={d:.3} recall@5={d:.3} mrr@5={d:.3} ndcg@10={d:.3}\n", .{ if (judgments_path == null) "ESC-50 opaque-name relevance" else "Judged catalog relevance", labels.count(), queries.count(), top1, recall5, mrr5, ndcg });
    if (ndcg < 0.75 or (judgments_path == null and (top1 < 0.80 or recall5 < 0.75 or mrr5 < 0.50))) return error.RelevanceAcceptanceFailed;
}

// Mutates only the caller's disposable ideal-grade array, not its judgments.
pub fn ndcg10(grades: []const u8, ideal: []u8) f64 {
    std.mem.sort(u8, ideal, {}, std.sort.desc(u8));
    const denominator = dcg(ideal);
    return if (denominator == 0) @floatFromInt(@intFromBool(grades.len == 0)) else dcg(grades) / denominator;
}

fn dcg(grades: []const u8) f64 {
    var value: f64 = 0;
    for (grades[0..@min(10, grades.len)], 0..) |grade, rank| {
        value += (std.math.pow(f64, 2, @floatFromInt(grade)) - 1) / @log2(@as(f64, @floatFromInt(rank + 2)));
    }
    return value;
}

test "graded nDCG discounts ordering and rejects unsupported filler" {
    var ideal = [_]u8{ 2, 3 };
    try std.testing.expectApproxEqAbs(@as(f64, 1), ndcg10(&.{ 3, 2 }, &ideal), 1e-12);
    try std.testing.expect(ndcg10(&.{ 2, 3 }, &ideal) < 1);
    try std.testing.expectEqual(@as(f64, 0), ndcg10(&.{}, &ideal));
    try std.testing.expectEqual(@as(f64, 1), ndcg10(&.{}, &.{}));
    try std.testing.expectEqual(@as(f64, 0), ndcg10(&.{0}, &.{}));
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build relevance -- RUNTIME_LIBRARY MODEL_DIR AUDIO_DIR LABELS_TSV [JUDGMENTS_TSV]\n", .{});
    return error.InvalidArguments;
}
