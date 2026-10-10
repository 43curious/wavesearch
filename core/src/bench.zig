const std = @import("std");
const vector = @import("vector.zig");

const DEFAULT_VECTOR_COUNT = 10_000;
const DIMENSION = 512;
const TOP_K = 20;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const count = if (args.next()) |value|
        try std.fmt.parseInt(usize, value, 10)
    else
        DEFAULT_VECTOR_COUNT;
    if (count == 0 or count > std.math.maxInt(i32)) return error.InvalidVectorCount;

    const total_values = try std.math.mul(usize, count, DIMENSION);
    const vectors = try allocator.alloc(f32, total_values);
    defer allocator.free(vectors);
    const ids = try allocator.alloc(i32, count);
    defer allocator.free(ids);
    const folders = try allocator.alloc(i32, count);
    defer allocator.free(folders);
    const durations = try allocator.alloc(i32, count);
    defer allocator.free(durations);

    var prng = std.Random.DefaultPrng.init(0x5753564543544f52);
    const random = prng.random();
    for (0..count) |row| {
        ids[row] = @intCast(row + 1);
        folders[row] = @intCast(row % 8);
        durations[row] = @intCast(100 + row % 30_000);
        const values = vectors[row * DIMENSION ..][0..DIMENSION];
        for (values) |*value| value.* = random.float(f32) * 2.0 - 1.0;
        try vector.normalize(values);
    }
    const query = try allocator.dupe(f32, vectors[0..DIMENSION]);
    defer allocator.free(query);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const start = std.Io.Clock.awake.now(io);
    const matches = try vector.exactTopK(allocator, query, ids, folders, durations, vectors, DIMENSION, .{}, TOP_K);
    defer allocator.free(matches);
    const elapsed_ns = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();

    std.debug.print(
        "exact vector top-{d}: vectors={d} dimension={d} values={d} vector_bytes={d} metadata_bytes={d} result_bytes<={d} elapsed_ms={d:.3}\n",
        .{
            TOP_K,
            count,
            DIMENSION,
            total_values,
            total_values * @sizeOf(f32),
            count * 3 * @sizeOf(i32),
            TOP_K * @sizeOf(vector.Match),
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
        },
    );
}
