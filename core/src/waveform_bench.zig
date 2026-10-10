const std = @import("std");
const waveform = @import("waveform.zig");
const types = @import("types.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const seconds = if (args.next()) |value| try std.fmt.parseInt(u64, value, 10) else 60;
    if (seconds == 0 or seconds > 3600) return error.InvalidDuration;
    const sample_rate: u64 = 48_000;
    const total_frames = try std.math.mul(u64, sample_rate, seconds);
    const chunk_frames: usize = 32_768;
    const left = try allocator.alloc(f32, chunk_frames);
    defer allocator.free(left);
    const right = try allocator.alloc(f32, chunk_frames);
    defer allocator.free(right);
    for (0..chunk_frames) |index| {
        left[index] = @as(f32, @floatFromInt(@as(i32, @intCast(index % 2048)) - 1024)) / 1024;
        right[index] = @as(f32, @floatFromInt(@as(i32, @intCast(index % 997)) - 498)) / 512;
    }
    const config = types.WSWaveformAnalyzerConfig{
        .struct_size = @sizeOf(types.WSWaveformAnalyzerConfig),
        .version = types.WS_WAVEFORM_ANALYZER_ABI_VERSION,
        .purpose = waveform.PURPOSE_DETAILED,
        .flags = waveform.FLAG_LOUDNESS,
        .backend = waveform.BACKEND_PORTABLE,
        .reserved0 = 0,
        .sample_rate = @floatFromInt(sample_rate),
        .total_frames = total_frames,
        .channel_count = 2,
        .reserved1 = 0,
        .source_file_size = 1,
        .source_mtime_ns = 1,
        .source_content_hash = 1,
        .reserved = .{ 0, 0 },
    };
    const analyzer = try waveform.Analyzer.create(allocator, config);
    defer analyzer.deinit();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const start = std.Io.Clock.awake.now(io);
    var consumed: u64 = 0;
    while (consumed < total_frames) {
        const count: usize = @intCast(@min(chunk_frames, total_frames - consumed));
        var planes = [_]?[*]const f32{ left.ptr, right.ptr };
        try analyzer.push(.{
            .struct_size = @sizeOf(types.WSWaveformPCMBuffer),
            .version = types.WS_WAVEFORM_PCM_BUFFER_VERSION,
            .layout = waveform.LAYOUT_PLANAR,
            .channel_count = 2,
            .frame_count = count,
            .interleaved = null,
            .planes = planes[0..].ptr,
            .reserved = .{ 0, 0 },
        });
        consumed += count;
    }
    const result = try analyzer.finish();
    defer result.deinit();
    const elapsed_ns = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000;
    std.debug.print(
        "portable waveform: duration_s={d} frames={d} elapsed_ms={d:.3} realtime_x={d:.1} levels={d}\n",
        .{ seconds, total_frames, elapsed_ms, @as(f64, @floatFromInt(seconds * 1000)) / elapsed_ms, result.levels.len },
    );
    if (seconds == 60 and elapsed_ms > 250) return error.PerformanceGateFailed;
}
