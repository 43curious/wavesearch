const std = @import("std");

pub const VECTOR_FORMAT = "f32le-l2-v1";
pub const MAX_DIMENSION: usize = 65_536;
const LANES = 8;
const Vec = @Vector(LANES, f32);
const NORMALIZED_TOLERANCE: f64 = 1.0e-4;

pub const Filter = struct {
    folder_id: ?i32 = null,
    min_duration_ms: i32 = 0,
    max_duration_ms: i32 = 0,
};

pub const Match = struct {
    file_id: i32,
    score: f32,
    // Identity at scoring time, so unrelated background embeddings need not
    // invalidate a completed search, while changed sources never reuse scores.
    source_content_hash: i64 = 0,
};

pub fn validateFinite(values: []const f32) !void {
    if (values.len == 0 or values.len > MAX_DIMENSION) return error.InvalidDimension;
    for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteVector;
}

fn squaredNorm(values: []const f32) f64 {
    var sum: f64 = 0;
    for (values) |value| {
        const wide: f64 = value;
        sum += wide * wide;
    }
    return sum;
}

pub fn normalize(values: []f32) !void {
    try validateFinite(values);
    const norm2 = squaredNorm(values);
    if (!std.math.isFinite(norm2) or norm2 <= 0) return error.ZeroVector;
    const inverse: f32 = @floatCast(1.0 / @sqrt(norm2));
    for (values) |*value| value.* *= inverse;
    try validateNormalized(values);
}

pub fn validateNormalized(values: []const f32) !void {
    try validateFinite(values);
    const norm2 = squaredNorm(values);
    if (!std.math.isFinite(norm2) or @abs(norm2 - 1.0) > NORMALIZED_TOLERANCE) return error.VectorNotNormalized;
}

/// A fixed-width SIMD reduction followed by a scalar tail. The lane count and
/// reduction order are fixed so a given target produces stable rankings.
pub fn dot(a: []const f32, b: []const f32) !f32 {
    if (a.len != b.len or a.len == 0) return error.DimensionMismatch;
    var accum: Vec = @splat(0);
    var i: usize = 0;
    while (i + LANES <= a.len) : (i += LANES) {
        const av: Vec = a[i..][0..LANES].*;
        const bv: Vec = b[i..][0..LANES].*;
        accum += av * bv;
    }
    var result: f32 = @reduce(.Add, accum);
    while (i < a.len) : (i += 1) result += a[i] * b[i];
    return result;
}

pub fn cosine(a: []const f32, b: []const f32) !f32 {
    try validateFinite(a);
    try validateFinite(b);
    if (a.len != b.len) return error.DimensionMismatch;
    const a_norm = squaredNorm(a);
    const b_norm = squaredNorm(b);
    if (a_norm <= 0 or b_norm <= 0) return error.ZeroVector;
    return @as(f32, @floatCast(@as(f64, try dot(a, b)) / @sqrt(a_norm * b_norm)));
}

pub fn serializeNormalized(allocator: std.mem.Allocator, values: []const f32) ![]u8 {
    try validateNormalized(values);
    const bytes = try allocator.alloc(u8, std.math.mul(usize, values.len, @sizeOf(f32)) catch return error.InvalidDimension);
    errdefer allocator.free(bytes);
    for (values, 0..) |value, i| {
        const bits: u32 = @bitCast(value);
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], bits, .little);
    }
    return bytes;
}

pub fn decodeNormalizedInto(bytes: []const u8, out: []f32) !void {
    if (out.len == 0 or out.len > MAX_DIMENSION or bytes.len != out.len * @sizeOf(f32)) return error.InvalidVectorBlob;
    for (out, 0..) |*value, i| {
        const bits = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        value.* = @bitCast(bits);
    }
    try validateNormalized(out);
}

pub fn deserializeNormalized(allocator: std.mem.Allocator, bytes: []const u8, dimension: usize) ![]f32 {
    if (dimension == 0 or dimension > MAX_DIMENSION or bytes.len != dimension * @sizeOf(f32)) return error.InvalidVectorBlob;
    const values = try allocator.alloc(f32, dimension);
    errdefer allocator.free(values);
    try decodeNormalizedInto(bytes, values);
    return values;
}

/// SQ8 v1: Float32 LE inverse code norm and L2 error bound, then Int8 codes.
/// Originals remain Float32; this representation only selects rerank candidates.
pub fn quantize(allocator: std.mem.Allocator, values: []const f32) ![]u8 {
    try validateNormalized(values);
    var peak: f32 = 0;
    for (values) |value| peak = @max(peak, @abs(value));
    const scale = peak / 127;
    const bytes = try allocator.alloc(u8, values.len + 8);
    var energy: u32 = 0;
    for (values, bytes[8..]) |value, *dest| {
        const rounded: i8 = @intFromFloat(@max(-127, @min(127, @round(value / scale))));
        dest.* = @bitCast(rounded);
        energy += @intCast(@as(i32, rounded) * rounded);
    }
    // Renormalize the codes: otherwise quantization norm error biases rankings
    // in dense neighborhoods more than the directional error does.
    const inverse_norm: f32 = 1 / @sqrt(@as(f32, @floatFromInt(energy)));
    std.mem.writeInt(u32, bytes[0..4], @bitCast(inverse_norm), .little);
    var error_squared: f64 = 0;
    for (values, bytes[8..]) |value, code| {
        const decoded = @as(f64, @floatFromInt(@as(i8, @bitCast(code)))) * inverse_norm;
        const delta = @as(f64, value) - decoded;
        error_squared += delta * delta;
    }
    const bound: f32 = @floatCast(@sqrt(error_squared) * 1.000001 + 1e-7);
    std.mem.writeInt(u32, bytes[4..8], @bitCast(bound), .little);
    return bytes;
}

pub fn quantizedDot(query: []const f32, bytes: []const u8) !f32 {
    if (query.len == 0 or query.len > MAX_DIMENSION or bytes.len != query.len + 8) return error.InvalidQuantizedVector;
    const scale: f32 = @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
    if (!std.math.isFinite(scale) or scale <= 0 or scale > 1.001 / 127.0) return error.InvalidQuantizedVector;
    var accum: Vec = @splat(0);
    var i: usize = 0;
    const encoded = bytes[8..];
    while (i + LANES <= query.len) : (i += LANES) {
        const encoded_lanes: @Vector(LANES, u8) = encoded[i..][0..LANES].*;
        const signed: @Vector(LANES, i8) = @bitCast(encoded_lanes);
        const decoded: Vec = @floatFromInt(signed);
        const q: Vec = query[i..][0..LANES].*;
        accum += q * decoded;
    }
    var score = @reduce(.Add, accum);
    while (i < query.len) : (i += 1) score += query[i] * @as(f32, @floatFromInt(@as(i8, @bitCast(encoded[i]))));
    return score * scale;
}

pub fn quantizedError(bytes: []const u8) !f32 {
    if (bytes.len < 8) return error.InvalidQuantizedVector;
    const bound: f32 = @bitCast(std.mem.readInt(u32, bytes[4..8], .little));
    if (!std.math.isFinite(bound) or bound < 0 or bound > 2.001) return error.InvalidQuantizedVector;
    // validateNormalized permits squared norms within 1e-4 of one.
    return bound * 1.0001;
}

pub fn dotRoundingMargin(dimension: usize) f32 {
    // Cover rounding in BOTH eight-lane reductions, including scalar tails.
    return @as(f32, @floatFromInt(dimension / LANES + LANES + 4)) * std.math.floatEps(f32) * 4;
}

test "SQ8 encoding validates inputs and approximates cosine including scalar tail" {
    var values = [_]f32{ -1, 0.2, 0.3, -0.4, 0, 0.6, -0.7, 0.8, 0.9 };
    try normalize(&values);
    const bytes = try quantize(std.testing.allocator, &values);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(values.len + 8, bytes.len);
    try std.testing.expectApproxEqAbs(try dot(&values, &values), try quantizedDot(&values, bytes), 0.01);
    try std.testing.expect(@abs(try dot(&values, &values) - try quantizedDot(&values, bytes)) <= try quantizedError(bytes) + dotRoundingMargin(values.len));
    try std.testing.expectError(error.InvalidQuantizedVector, quantizedDot(&values, bytes[1..]));
    @memset(bytes[0..4], 0);
    try std.testing.expectError(error.InvalidQuantizedVector, quantizedDot(&values, bytes));
    try std.testing.expectError(error.VectorNotNormalized, quantize(std.testing.allocator, &.{2}));
}

test "SQ8 pruning bound covers dot error at small, SIMD-tail, CLAP and maximum dimensions" {
    var random = std.Random.DefaultPrng.init(123);
    for ([_]usize{ 1, 7, 8, 9, 512, MAX_DIMENSION }) |dimension| {
        const query = try std.testing.allocator.alloc(f32, dimension);
        defer std.testing.allocator.free(query);
        const values = try std.testing.allocator.alloc(f32, dimension);
        defer std.testing.allocator.free(values);
        for (0..8) |_| {
            for (query, values) |*q, *v| {
                q.* = random.random().float(f32) * 2 - 1;
                v.* = random.random().float(f32) * 2 - 1;
            }
            try normalize(query);
            try normalize(values);
            const bytes = try quantize(std.testing.allocator, values);
            defer std.testing.allocator.free(bytes);
            const delta = @abs(try dot(query, values) - try quantizedDot(query, bytes));
            try std.testing.expect(delta <= try quantizedError(bytes) + dotRoundingMargin(dimension));
        }
    }
}

fn better(a: Match, b: Match) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.file_id < b.file_id;
}

/// Exact (non-ANN) top-K scan over row-major normalized vectors. Only the K
/// matches are heap-allocated; no dimension-sized data is placed on the stack.
pub fn exactTopK(
    allocator: std.mem.Allocator,
    query: []const f32,
    file_ids: []const i32,
    folder_ids: []const i32,
    durations_ms: []const i32,
    vectors: []const f32,
    dimension: usize,
    filter: Filter,
    k: usize,
) ![]Match {
    try validateNormalized(query);
    if (dimension == 0 or dimension != query.len or
        file_ids.len != folder_ids.len or file_ids.len != durations_ms.len or
        vectors.len != std.math.mul(usize, file_ids.len, dimension) catch return error.InvalidSnapshot)
        return error.InvalidSnapshot;
    if (k == 0 or file_ids.len == 0) return allocator.alloc(Match, 0);

    const capacity = @min(k, file_ids.len);
    const top = try allocator.alloc(Match, capacity);
    errdefer allocator.free(top);
    var count: usize = 0;

    for (file_ids, folder_ids, durations_ms, 0..) |file_id, folder_id, duration, row| {
        if (filter.folder_id) |wanted| if (folder_id != wanted) continue;
        if (duration < filter.min_duration_ms) continue;
        if (filter.max_duration_ms != 0 and duration > filter.max_duration_ms) continue;
        const score = try dot(query, vectors[row * dimension ..][0..dimension]);
        const item = Match{ .file_id = file_id, .score = score };
        var insert_at: usize = 0;
        while (insert_at < count and !better(item, top[insert_at])) : (insert_at += 1) {}
        if (insert_at >= capacity) continue;
        if (count < capacity) count += 1;
        var move = count - 1;
        while (move > insert_at) : (move -= 1) top[move] = top[move - 1];
        top[insert_at] = item;
    }
    return allocator.realloc(top, count);
}

test "finite validation normalization and cosine" {
    var values = [_]f32{ 3, 4, 0 };
    try normalize(&values);
    try validateNormalized(&values);
    try std.testing.expectApproxEqAbs(@as(f32, 1), try cosine(&values, &values), 0.00001);
    var zeros = [_]f32{ 0, 0 };
    try std.testing.expectError(error.ZeroVector, normalize(&zeros));
    try std.testing.expectError(error.NonFiniteVector, validateFinite(&[_]f32{std.math.nan(f32)}));
}

test "SIMD dot includes scalar tail deterministically" {
    const a = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const b = [_]f32{ 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2 };
    try std.testing.expectEqual(@as(f32, 102), try dot(&a, &b));
    try std.testing.expectEqual(try dot(&a, &b), try dot(&a, &b));
}

test "normalized float32 serialization is little endian and validated" {
    const values = [_]f32{ 1, 0 };
    const bytes = try serializeNormalized(std.testing.allocator, &values);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 128, 63, 0, 0, 0, 0 }, bytes);
    const decoded = try deserializeNormalized(std.testing.allocator, bytes, 2);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(f32, &values, decoded);
    try std.testing.expectError(error.InvalidVectorBlob, deserializeNormalized(std.testing.allocator, bytes[0..7], 2));
    const non_finite = [_]u8{ 0, 0, 128, 127, 0, 0, 0, 0 };
    var invalid_out: [2]f32 = undefined;
    try std.testing.expectError(error.NonFiniteVector, decodeNormalizedInto(&non_finite, &invalid_out));
}

test "exact top K filters and uses stable file ID ties" {
    const query = [_]f32{ 1, 0, 0 };
    const ids = [_]i32{ 9, 3, 5, 7 };
    const folders = [_]i32{ 1, 1, 2, 1 };
    const durations = [_]i32{ 100, 100, 100, 500 };
    const vectors = [_]f32{
        1,   0,   0,
        1,   0,   0,
        0,   1,   0,
        0.8, 0.6, 0,
    };
    const got = try exactTopK(std.testing.allocator, &query, &ids, &folders, &durations, &vectors, 3, .{ .folder_id = 1, .max_duration_ms = 200 }, 10);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(@as(i32, 3), got[0].file_id);
    try std.testing.expectEqual(@as(i32, 9), got[1].file_id);

    const reverse_ids = [_]i32{ 3, 9 };
    const reverse_vectors = [_]f32{ 1, 0, 0, 1, 0, 0 };
    const reverse = try exactTopK(std.testing.allocator, &query, &reverse_ids, &.{ 1, 1 }, &.{ 100, 100 }, &reverse_vectors, 3, .{}, 2);
    defer std.testing.allocator.free(reverse);
    try std.testing.expectEqual(@as(i32, 3), reverse[0].file_id);
    try std.testing.expectEqual(@as(i32, 9), reverse[1].file_id);
}
