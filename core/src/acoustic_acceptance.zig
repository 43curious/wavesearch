const std = @import("std");
const db = @import("db.zig");
const search = @import("search.zig");
const acoustic = @import("acoustic.zig");

const Label = struct { family: []const u8, source: bool };

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const audio_dir = args.next() orelse return usage();
    const labels_path = args.next() orelse return usage();
    if (args.next() != null) return usage();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, labels_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    var labels = std.StringHashMap(Label).init(allocator);
    defer labels.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse return error.MalformedLabels;
        const family = fields.next() orelse return error.MalformedLabels;
        const source = fields.next() orelse return error.MalformedLabels;
        if (fields.next() != null) return error.MalformedLabels;
        try labels.put(name, .{ .family = family, .source = std.mem.eql(u8, source, "1") });
    }
    const database_path = try std.fmt.allocPrint(allocator, "{s}/.acoustic-acceptance.sqlite", .{std.fs.path.dirname(labels_path) orelse "."});
    defer allocator.free(database_path);
    std.Io.Dir.cwd().deleteFile(io, database_path) catch {};
    try db.open(allocator, database_path);
    defer db.close();
    try search.indexFolder(allocator, 1, audio_dir);
    const indexed = try acoustic.indexPending(allocator, 1, 0);
    if (indexed.successful + indexed.failed != labels.count() or indexed.failed != 0) return error.IncompleteAcousticIndex;

    var queries: usize = 0;
    var recalled: usize = 0;
    var true_positive: usize = 0;
    var false_positive: usize = 0;
    var iterator = labels.iterator();
    while (iterator.next()) |entry| {
        if (!entry.value_ptr.source) continue;
        queries += 1;
        const source_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ audio_dir, entry.key_ptr.* });
        defer allocator.free(source_path);
        const results = try acoustic.searchPath(allocator, source_path, 1, 100);
        defer allocator.free(results);
        var family_in_top5 = false;
        for (results, 0..) |result, rank| {
            const name = std.mem.sliceTo(&result.candidate.name, 0);
            const actual = labels.get(name) orelse continue;
            const same = std.mem.eql(u8, actual.family, entry.value_ptr.family);
            if (rank < 5 and same) family_in_top5 = true;
            if (result.fingerprint_votes >= 6 and result.fingerprint_score_ppm >= 120_000) {
                if (same) true_positive += 1 else false_positive += 1;
            }
        }
        if (family_in_top5) recalled += 1;
    }
    if (queries == 0) return error.NoQueries;
    const recall = @as(f64, @floatFromInt(recalled)) / @as(f64, @floatFromInt(queries));
    const precision = if (true_positive + false_positive == 0) 0 else @as(f64, @floatFromInt(true_positive)) / @as(f64, @floatFromInt(true_positive + false_positive));
    std.debug.print("acoustic acceptance: files={d} queries={d} precision={d:.3} source_family_recall@5={d:.3}\n", .{ labels.count(), queries, precision, recall });
    if (precision < 0.99 or recall < 0.90) return error.AcousticAcceptanceFailed;
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build acoustic-acceptance -- AUDIO_DIR LABELS_TSV\n", .{});
    return error.InvalidArguments;
}
