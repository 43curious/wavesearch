const std = @import("std");
const audio = @import("clap_audio.zig");
const vector = @import("vector.zig");

pub const MAX_SEGMENTS = 16;
pub const DIMENSION = 512;
pub const Policy = enum {
    mean5,
    uniform16,
    events16,

    pub fn revision(self: Policy) []const u8 {
        return switch (self) {
            .mean5 => audio.PREPROCESSING_REVISION,
            .uniform16 => "coverage-uniform16-max-cosine-v1",
            .events16 => "coverage-uniform8-energy-rise8-max-cosine-v1",
        };
    }
};

pub const Plan = struct {
    starts: [MAX_SEGMENTS]usize = @splat(0),
    len: usize = 0,

    pub fn uniform(frames: usize, limit: usize) Plan {
        std.debug.assert(limit > 0 and limit <= MAX_SEGMENTS);
        var result = Plan{};
        const span = frames -| audio.WINDOW_SAMPLES;
        const natural = 1 + (span + audio.WINDOW_SAMPLES - 1) / audio.WINDOW_SAMPLES;
        result.len = @min(natural, limit);
        for (result.starts[0..result.len], 0..) |*start, index| {
            start.* = if (result.len == 1) 0 else @intCast((@as(u128, index) * span) / (result.len - 1));
        }
        return result;
    }

    /// Keep eight coverage anchors, then add up to eight strongest energy rises
    /// at least half a window from prior selections. This is a hypothesis about
    /// transient coverage, not a semantic event detector.
    pub fn withEvents(frames: usize, energy: []const f64) Plan {
        var result = uniform(frames, 8);
        if (energy.len == 0) return result;
        const span = frames -| audio.WINDOW_SAMPLES;
        while (result.len < MAX_SEGMENTS) {
            var best_score: f64 = 0;
            var best_start: ?usize = null;
            for (energy, 0..) |value, index| {
                const rise = value - (if (index == 0) 0 else energy[index - 1]);
                if (!std.math.isFinite(rise) or rise <= best_score) continue;
                const center: usize = @intCast((@as(u128, index * 2 + 1) * frames) / (energy.len * 2));
                const start = @min(span, center -| (audio.WINDOW_SAMPLES / 2));
                var near = false;
                for (result.starts[0..result.len]) |prior| {
                    if (@max(start, prior) - @min(start, prior) < audio.WINDOW_SAMPLES / 2) near = true;
                }
                if (near) continue;
                best_score = rise;
                best_start = start;
            }
            const start = best_start orelse break;
            result.starts[result.len] = start;
            result.len += 1;
        }
        std.mem.sort(usize, result.starts[0..result.len], {}, std.sort.asc(usize));
        return result;
    }
};

pub fn plan(reader: *audio.WindowReader, policy: Policy) !Plan {
    if (policy != .events16 or reader.destination_frames <= 5 * audio.WINDOW_SAMPLES)
        return Plan.uniform(reader.destination_frames, if (policy == .mean5) 5 else MAX_SEGMENTS);
    // At least quarter-second bins, capped at 4096 for arbitrarily long sources.
    const count = @min(4096, @max(1, reader.destination_frames / (audio.SAMPLE_RATE / 4)));
    var energy: [4096]f64 = undefined;
    try reader.energyBins(energy[0..count]);
    return Plan.withEvents(reader.destination_frames, energy[0..count]);
}

pub const Segment = struct {
    start_ms: u64,
    end_ms: u64,
    embedding: [DIMENSION]f32,
};

pub const Score = struct { cosine: f32, interval: ?struct { start_ms: u64, end_ms: u64 } };

/// One score per recording prevents a long file from filling multiple result
/// slots. Retain the earliest best interval on ties for repeatable localization.
pub fn score(query: []const f32, segments: []const Segment, pooled: bool) !Score {
    if (segments.len == 0 or segments.len > MAX_SEGMENTS) return error.InvalidSegmentCount;
    var result = Score{ .cosine = -std.math.inf(f32), .interval = null };
    for (segments) |segment| {
        const cosine = try vector.dot(query, &segment.embedding);
        if (cosine > result.cosine) {
            result.cosine = cosine;
            result.interval = if (pooled) null else .{ .start_ms = segment.start_ms, .end_ms = segment.end_ms };
        }
    }
    return result;
}

test "uniform plans retain short effects and bound long recording inference" {
    for ([_]usize{ 1, 5, 10, 11, 50, 60, 300, 3600 }) |seconds| {
        const frames = seconds * audio.SAMPLE_RATE;
        const p = Plan.uniform(frames, MAX_SEGMENTS);
        try std.testing.expect(p.len <= MAX_SEGMENTS);
        try std.testing.expectEqual(@as(usize, 0), p.starts[0]);
        try std.testing.expectEqual(frames -| audio.WINDOW_SAMPLES, p.starts[p.len - 1]);
        if (seconds <= 10) try std.testing.expectEqual(@as(usize, 1), p.len);
        for (p.starts[1..p.len], p.starts[0 .. p.len - 1]) |a, b| try std.testing.expect(a > b);
    }
}

test "energy rise selection catches a transient between baseline windows" {
    const frames = 300 * audio.SAMPLE_RATE;
    var energy: [1200]f64 = @splat(0);
    energy[120] = 1; // 30 seconds: baseline starts at 0, 72.5, 145, 217.5, 290.
    const p = Plan.withEvents(frames, &energy);
    try std.testing.expect(p.len <= MAX_SEGMENTS);
    var captured = false;
    for (p.starts[0..p.len]) |start| {
        if (start <= 30 * audio.SAMPLE_RATE and start + audio.WINDOW_SAMPLES > 30 * audio.SAMPLE_RATE) captured = true;
    }
    try std.testing.expect(captured);
    const silent = Plan.withEvents(frames, &@as([1200]f64, @splat(0)));
    try std.testing.expectEqual(@as(usize, 8), silent.len);
}

test "segment maxima preserve transient scores that mean pooling dilutes" {
    var segments = [_]Segment{
        .{ .start_ms = 0, .end_ms = 10_000, .embedding = @splat(0) },
        .{ .start_ms = 20_000, .end_ms = 30_000, .embedding = @splat(0) },
    };
    segments[0].embedding[0] = 1;
    segments[1].embedding[1] = 1;
    var query: [DIMENSION]f32 = @splat(0);
    query[1] = 1;
    const best = try score(&query, &segments, false);
    try std.testing.expectEqual(@as(f32, 1), best.cosine);
    try std.testing.expectEqual(@as(u64, 20_000), best.interval.?.start_ms);
    var mean = segments[0];
    mean.embedding[1] = 1;
    try vector.normalize(&mean.embedding);
    const baseline = try score(&query, &.{mean}, true);
    try std.testing.expect(baseline.cosine < best.cosine);
    try std.testing.expect(baseline.interval == null);
}
