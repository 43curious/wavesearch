const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");
const search = @import("search.zig");
const types = @import("types.zig");
const audio = @import("audio.zig");

const RUNS: usize = 30;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const count = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 1_000_000;
    const path = args.next() orelse "../.perf/library.sqlite";
    if (args.next() != null or count == 0) return error.InvalidArguments;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (std.fs.path.dirname(path)) |directory| std.Io.Dir.cwd().createDirPath(io, directory) catch {};
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{path});
    defer allocator.free(wal);
    std.Io.Dir.cwd().deleteFile(io, wal) catch {};
    const shm = try std.fmt.allocPrint(allocator, "{s}-shm", .{path});
    defer allocator.free(shm);
    std.Io.Dir.cwd().deleteFile(io, shm) catch {};

    try db.open(allocator, path);
    defer db.close();
    var clock = std.Io.Clock.awake;
    const index_start = clock.now(io);
    try db.insertSyntheticBenchmarkFiles(count);
    const index_ns = index_start.durationTo(clock.now(io)).toNanoseconds();

    var exact: [RUNS]u64 = undefined;
    var typo: [RUNS]u64 = undefined;
    var folder: [RUNS]u64 = undefined;
    var waveform: [RUNS]u64 = undefined;
    const wave_path = "../.perf/waveform-60s.wav";
    try writeBenchmarkWav(allocator, io, wave_path);
    const wave_absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, wave_path, allocator);
    defer allocator.free(wave_absolute);
    var wave_points: [512]f32 = undefined;
    const results = try allocator.alloc(types.WSResult, 100);
    defer allocator.free(results);
    for (0..RUNS) |run| {
        var start = clock.now(io);
        _ = try search.search(allocator, "impact-00000000.wav", null, results.ptr, 1);
        exact[run] = @intCast(start.durationTo(clock.now(io)).toNanoseconds());
        start = clock.now(io);
        _ = try search.search(allocator, "impaxt", null, results.ptr, results.len);
        typo[run] = @intCast(start.durationTo(clock.now(io)).toNanoseconds());
        start = clock.now(io);
        _ = try search.listFolder(allocator, @intCast(run % 1000), results.ptr, results.len);
        folder[run] = @intCast(start.durationTo(clock.now(io)).toNanoseconds());
        start = clock.now(io);
        try audio.waveform(wave_absolute, &wave_points, wave_points.len);
        waveform[run] = @intCast(start.durationTo(clock.now(io)).toNanoseconds());
    }
    std.mem.sort(u64, &exact, {}, std.sort.asc(u64));
    std.mem.sort(u64, &typo, {}, std.sort.asc(u64));
    std.mem.sort(u64, &folder, {}, std.sort.asc(u64));
    std.mem.sort(u64, &waveform, {}, std.sort.asc(u64));
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    const rss = peakRssBytes();
    std.debug.print(
        "corpus={d} schema={d} db_bytes={d} peak_rss_bytes={d} index_s={d:.3}\n" ++
            "exact_ms p50={d:.3} p95={d:.3}\n" ++
            "typo_ms p50={d:.3} p95={d:.3}\n" ++
            "folder_ms p50={d:.3} p95={d:.3}\n" ++
            "waveform60s_ms p50={d:.3} p95={d:.3}\n",
        .{
            count,
            db.SCHEMA_VERSION,
            stat.size,
            rss,
            seconds(index_ns),
            milliseconds(percentile(&exact, 50)),
            milliseconds(percentile(&exact, 95)),
            milliseconds(percentile(&typo, 50)),
            milliseconds(percentile(&typo, 95)),
            milliseconds(percentile(&folder, 50)),
            milliseconds(percentile(&folder, 95)),
            milliseconds(percentile(&waveform, 50)),
            milliseconds(percentile(&waveform, 95)),
        },
    );
    if (count >= 1_000_000 and (milliseconds(percentile(&exact, 95)) > 100 or milliseconds(percentile(&typo, 95)) > 250 or milliseconds(percentile(&folder, 95)) > 100 or milliseconds(percentile(&waveform, 95)) > 150 or rss > 512 * 1024 * 1024))
        return error.PerformanceBudgetExceeded;
}

fn writeBenchmarkWav(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const rate: u32 = 48_000;
    const frames: u32 = rate * 60;
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
        const sample: i16 = @intFromFloat(12_000.0 * @sin(2.0 * std.math.pi * 220.0 * @as(f64, @floatFromInt(i)) / rate));
        std.mem.writeInt(i16, bytes[44 + i * 2 ..][0..2], sample, .little);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn percentile(values: []const u64, percent: usize) u64 {
    return values[@min(values.len - 1, (values.len * percent + 99) / 100 - 1)];
}

pub fn milliseconds(ns: anytype) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn seconds(ns: anytype) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
}

pub fn peakRssBytes() u64 {
    // Zig's libc binding avoids translated anonymous unions in glibc rusage.
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0) return 0;
    const raw: u64 = @intCast(@max(usage.maxrss, 0));
    return if (builtin.os.tag == .macos) raw else raw * 1024;
}
