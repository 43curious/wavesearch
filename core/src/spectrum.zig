const std = @import("std");
const fingerprint = @import("fingerprint.zig");

/// Peak across channels preserves opposite-phase stereo content. Scratch is on
/// the heap because native decoding workers may have small stacks.
pub fn column(allocator: std.mem.Allocator, planes: []const ?[*]const f32, frames: usize, output: []f32) !void {
    if (planes.len == 0 or planes.len > 32 or frames == 0 or frames > 1024 or output.len != 513) return error.InvalidSpectrumBuffer;
    for (planes) |optional| {
        const plane = optional orelse return error.InvalidSpectrumBuffer;
        for (plane[0..frames]) |value| if (!std.math.isFinite(value)) return error.NonFiniteSpectrumPCM;
    }
    const Scratch = struct { real: [1024]f64, imag: [1024]f64, bins: [513]f64 };
    const scratch = try allocator.create(Scratch);
    defer allocator.destroy(scratch);
    @memset(&scratch.bins, 0);
    for (planes) |optional| {
        const plane = optional.?;
        var sum: f64 = 0;
        for (0..1024) |i| {
            // Window the actual extent, including very short selected ranges.
            const window = if (frames == 1) 1 else 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(frames)));
            scratch.real[i] = if (i < frames) @as(f64, plane[i]) * window else 0;
            scratch.imag[i] = 0;
            if (i < frames) sum += window;
        }
        fingerprint.fft(&scratch.real, &scratch.imag);
        for (&scratch.bins, 0..) |*peak, bin| {
            const scale: f64 = if (bin == 0 or bin == 512) 1 else 2;
            const amplitude = @sqrt(scratch.real[bin] * scratch.real[bin] + scratch.imag[bin] * scratch.imag[bin]) * scale / sum;
            peak.* = @max(peak.*, amplitude);
        }
    }
    for (output, scratch.bins) |*value, amplitude| value.* = @floatCast(@max(-100, @min(0, 20 * @log10(@max(amplitude, 1e-5)))));
}

test "spectrum calibrates tone, preserves antiphase stereo, and rejects invalid PCM without writes" {
    var left: [1024]f32 = undefined;
    var right: [1024]f32 = undefined;
    for (&left, &right, 0..) |*l, *r, i| {
        l.* = @floatCast(0.5 * @sin(2 * std.math.pi * 32 * @as(f64, @floatFromInt(i)) / 1024));
        r.* = -l.*;
    }
    const planes = [_]?[*]const f32{ &left, &right };
    var bins: [513]f32 = @splat(99);
    try column(std.testing.allocator, &planes, 1024, &bins);
    try std.testing.expectApproxEqAbs(@as(f32, -6.0206), bins[32], 0.001);
    try std.testing.expect(bins[20] < -99);
    left[0] = std.math.nan(f32);
    const before = bins;
    try std.testing.expectError(error.NonFiniteSpectrumPCM, column(std.testing.allocator, &planes, 1024, &bins));
    try std.testing.expectEqualSlices(f32, &before, &bins);
    @memset(&left, 0);
    try column(std.testing.allocator, &.{&left}, 1, &bins);
    for (bins) |value| try std.testing.expectEqual(@as(f32, -100), value);
    try std.testing.expectError(error.InvalidSpectrumBuffer, column(std.testing.allocator, &.{null}, 1024, &bins));
}
