const std = @import("std");
const clap_audio = @import("clap_audio.zig");
const query_cancel = @import("query.zig");

pub const ALGORITHM_KEY = "ws-landmark-full-16k-sinc32-fft1024-hop256-local2x3-fan3-qf4-qdt2-fuzzy1-v3";
pub const FFT_SIZE: usize = 1024;
pub const HOP_SIZE: usize = 256;
pub const MIN_BIN: usize = 5; // Approximately 78 Hz at 16 kHz.
pub const MAX_BIN: usize = 480; // Approximately 7.5 kHz.
pub const MAX_PEAKS_PER_FRAME: usize = 4;
pub const FAN_OUT: usize = 3;
pub const MIN_TARGET_DELTA: usize = 2;
pub const MAX_TARGET_DELTA: usize = 32;
pub const MAX_LANDMARKS: usize = 100_000;
pub const SELECTOR_COUNT: usize = 96;

pub const Landmark = packed struct {
    hash: u32,
    frame: u32,
};

pub const Match = struct {
    score_ppm: u32 = 0,
    aligned: u32 = 0,
    offset_frames: i32 = 0,

    pub fn highConfidence(self: Match) bool {
        return self.aligned >= 6 and self.score_ppm >= 120_000;
    }
};

const Peak = struct {
    bin: u16,
    power: f32,
};

pub fn fromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]Landmark {
    var reader = try clap_audio.FingerprintReader.initFile(allocator, io, path);
    defer reader.deinit();
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    var samples: [4096]f32 = undefined;
    while (true) {
        const count = try reader.next(&samples);
        if (count == 0) break;
        try analyzer.push(samples[0..count]);
    }
    return analyzer.finish();
}

pub fn fromSamples(allocator: std.mem.Allocator, samples: []const f32) ![]Landmark {
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try analyzer.push(samples);
    return analyzer.finish();
}

/// Complete-timeline v3 extraction with bounded PCM overlap, five spectral
/// rows, and delayed peak/landmark emission. Only the bounded output grows.
pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    pcm: [FFT_SIZE]f32 = undefined,
    filled: usize = 0,
    frame_count: usize = 0,
    powers: [5 * (MAX_BIN - MIN_BIN + 1)]f32 = undefined,
    real: [FFT_SIZE]f64 = undefined,
    imag: [FFT_SIZE]f64 = undefined,
    window: [FFT_SIZE]f64 = undefined,
    peaks: [MAX_TARGET_DELTA + 1][MAX_PEAKS_PER_FRAME]Peak = undefined,
    peak_counts: [MAX_TARGET_DELTA + 1]u8 = @splat(0),
    landmarks: std.ArrayList(Landmark) = .empty,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        var self: Analyzer = .{ .allocator = allocator };
        for (&self.window, 0..) |*value, i| {
            const phase = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(FFT_SIZE));
            value.* = 0.5 - 0.5 * @cos(phase);
        }
        return self;
    }

    pub fn deinit(self: *Analyzer) void {
        self.landmarks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *Analyzer, samples: []const f32) !void {
        if (self.finished) return error.InvalidFingerprintState;
        var offset: usize = 0;
        while (offset < samples.len) {
            try query_cancel.check();
            const count = @min(samples.len - offset, FFT_SIZE - self.filled);
            for (samples[offset..][0..count]) |sample| if (!std.math.isFinite(sample)) return error.NonFiniteSample;
            @memcpy(self.pcm[self.filled..][0..count], samples[offset..][0..count]);
            self.filled += count;
            offset += count;
            if (self.filled < FFT_SIZE) continue;
            try self.processFrame();
            std.mem.copyForwards(f32, self.pcm[0 .. FFT_SIZE - HOP_SIZE], self.pcm[HOP_SIZE..]);
            self.filled -= HOP_SIZE;
        }
    }

    fn processFrame(self: *Analyzer) !void {
        const bin_count = MAX_BIN - MIN_BIN + 1;
        const lookahead = self.frame_count;
        for (0..FFT_SIZE) |i| {
            self.real[i] = @as(f64, self.pcm[i]) * self.window[i];
            self.imag[i] = 0;
        }
        fft(&self.real, &self.imag);
        for (MIN_BIN..MAX_BIN + 1) |bin| {
            const magnitude = self.real[bin] * self.real[bin] + self.imag[bin] * self.imag[bin];
            self.powers[(lookahead % 5) * bin_count + bin - MIN_BIN] = @floatCast(magnitude);
        }
        self.frame_count += 1;
        if (lookahead >= 2) try self.processPeak(lookahead - 2, self.frame_count);
    }

    fn processPeak(self: *Analyzer, frame: usize, frame_count: usize) !void {
        const bin_count = MAX_BIN - MIN_BIN + 1;
        const slot = frame % self.peaks.len;
        self.peak_counts[slot] = 0;
        const row = self.powers[(frame % 5) * bin_count ..][0..bin_count];
        var mean: f64 = 0;
        for (row) |value| mean += value;
        mean /= @as(f64, @floatFromInt(row.len));
        const threshold: f32 = @floatCast(mean * 2.5 + 1e-18);
        for (0..bin_count) |relative_bin| {
            const value = row[relative_bin];
            if (value < threshold or !isLocalMaximum(&self.powers, frame_count, bin_count, frame, relative_bin, value)) continue;
            insertPeak(&self.peaks[slot], &self.peak_counts[slot], .{ .bin = @intCast(relative_bin + MIN_BIN), .power = value });
        }
        if (frame >= MAX_TARGET_DELTA) try emitLandmarks(self.allocator, &self.landmarks, &self.peaks, &self.peak_counts, frame - MAX_TARGET_DELTA, frame_count);
    }

    pub fn finish(self: *Analyzer) ![]Landmark {
        if (self.finished) return error.InvalidFingerprintState;
        self.finished = true;
        try query_cancel.check();
        if (self.frame_count == 0) return error.AudioTooShortForFingerprint;
        // Flush the two lookahead rows and 32 delayed anchor frames with exactly
        // the clipped tail neighborhoods used by the original batch algorithm.
        for (self.frame_count -| 2..self.frame_count) |frame| try self.processPeak(frame, self.frame_count);
        for (self.frame_count -| MAX_TARGET_DELTA..self.frame_count) |anchor| {
            try query_cancel.check();
            try emitLandmarks(self.allocator, &self.landmarks, &self.peaks, &self.peak_counts, anchor, self.frame_count);
        }
        if (self.landmarks.items.len < 6) return error.InsufficientFingerprintDetail;
        std.mem.sort(Landmark, self.landmarks.items, {}, landmarkLessThan);
        return self.landmarks.toOwnedSlice(self.allocator);
    }
};

fn emitLandmarks(allocator: std.mem.Allocator, landmarks: *std.ArrayList(Landmark), peaks: *const [MAX_TARGET_DELTA + 1][MAX_PEAKS_PER_FRAME]Peak, counts: *const [MAX_TARGET_DELTA + 1]u8, anchor_frame: usize, frame_count: usize) !void {
    for (peaks[anchor_frame % peaks.len][0..counts[anchor_frame % peaks.len]]) |anchor| {
        var emitted: usize = 0;
        const end = @min(frame_count, anchor_frame + MAX_TARGET_DELTA + 1);
        var target_frame = anchor_frame + MIN_TARGET_DELTA;
        while (target_frame < end and emitted < FAN_OUT) : (target_frame += 1) {
            for (peaks[target_frame % peaks.len][0..counts[target_frame % peaks.len]]) |target| {
                if (emitted == FAN_OUT) break;
                if (landmarks.items.len == MAX_LANDMARKS) return error.FingerprintTooLarge;
                try landmarks.append(allocator, .{ .hash = landmarkHash(anchor.bin, target.bin, target_frame - anchor_frame), .frame = @intCast(anchor_frame) });
                emitted += 1;
            }
        }
    }
}

fn fft(real: []f64, imag: []f64) void {
    var j: usize = 0;
    for (1..FFT_SIZE) |i| {
        var bit = FFT_SIZE >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            std.mem.swap(f64, &real[i], &real[j]);
            std.mem.swap(f64, &imag[i], &imag[j]);
        }
    }
    var len: usize = 2;
    while (len <= FFT_SIZE) : (len <<= 1) {
        const angle = -2.0 * std.math.pi / @as(f64, @floatFromInt(len));
        const wlen_real = @cos(angle);
        const wlen_imag = @sin(angle);
        var base: usize = 0;
        while (base < FFT_SIZE) : (base += len) {
            var wr: f64 = 1;
            var wi: f64 = 0;
            for (0..len / 2) |offset| {
                const even = base + offset;
                const odd = even + len / 2;
                const vr = real[odd] * wr - imag[odd] * wi;
                const vi = real[odd] * wi + imag[odd] * wr;
                const ur = real[even];
                const ui = imag[even];
                real[even] = ur + vr;
                imag[even] = ui + vi;
                real[odd] = ur - vr;
                imag[odd] = ui - vi;
                const next_wr = wr * wlen_real - wi * wlen_imag;
                wi = wr * wlen_imag + wi * wlen_real;
                wr = next_wr;
            }
        }
    }
}

fn isLocalMaximum(powers: []const f32, frame_count: usize, bin_count: usize, frame: usize, bin: usize, value: f32) bool {
    const first_frame = frame -| 2;
    const last_frame = @min(frame_count - 1, frame + 2);
    const first_bin = bin -| 3;
    const last_bin = @min(bin_count - 1, bin + 3);
    for (first_frame..last_frame + 1) |other_frame| {
        for (first_bin..last_bin + 1) |other_bin| {
            if (other_frame == frame and other_bin == bin) continue;
            const other = powers[(other_frame % 5) * bin_count + other_bin];
            if (other > value) return false;
            if (other == value and (other_frame < frame or (other_frame == frame and other_bin < bin))) return false;
        }
    }
    return true;
}

fn insertPeak(dest: *[MAX_PEAKS_PER_FRAME]Peak, count: *u8, peak: Peak) void {
    var position: usize = 0;
    const used: usize = count.*;
    while (position < used and (dest[position].power > peak.power or (dest[position].power == peak.power and dest[position].bin < peak.bin))) : (position += 1) {}
    if (position >= MAX_PEAKS_PER_FRAME) return;
    const new_count = @min(used + 1, MAX_PEAKS_PER_FRAME);
    var i = new_count;
    while (i > position + 1) {
        i -= 1;
        dest[i] = dest[i - 1];
    }
    dest[position] = peak;
    count.* = @intCast(new_count);
}

test "rolling spectrogram preserves the v3 fingerprint bytes" {
    const allocator = std.testing.allocator;
    const samples = try allocator.alloc(f32, 30 * 16000);
    defer allocator.free(samples);
    var random = std.Random.DefaultPrng.init(42);
    for (samples) |*sample| sample.* = random.random().float(f32) * 2 - 1;
    const landmarks = try fromSamples(allocator, samples);
    defer allocator.free(landmarks);
    const blob = try serializeRaw(allocator, landmarks);
    defer allocator.free(blob);
    try std.testing.expectEqual(@as(usize, 22404), landmarks.len);
    try std.testing.expectEqual(@as(u64, 0x4077abbfe9e0262d), std.hash.Wyhash.hash(0, blob));
}

fn landmarkHash(anchor_bin: u16, target_bin: u16, delta: usize) u32 {
    const q1: u32 = @intCast(@min(@as(usize, anchor_bin / 4), 255));
    const q2: u32 = @intCast(@min(@as(usize, target_bin / 4), 255));
    const qdt: u32 = @intCast(@min(delta / 2, 63));
    return packHash(q1, q2, qdt);
}

fn packHash(q1: u32, q2: u32, qdt: u32) u32 {
    return q1 | (q2 << 8) | (qdt << 16);
}

pub fn neighborHashes(hash: u32, output: *[27]u32) []const u32 {
    const q1: i32 = @intCast(hash & 0xff);
    const q2: i32 = @intCast((hash >> 8) & 0xff);
    const qdt: i32 = @intCast((hash >> 16) & 0x3f);
    var count: usize = 0;
    const deltas = [_]i32{ -1, 0, 1 };
    for (deltas) |d1| for (deltas) |d2| for (deltas) |dt| {
        const n1 = q1 + d1;
        const n2 = q2 + d2;
        const ndt = qdt + dt;
        if (n1 < 0 or n1 > 255 or n2 < 0 or n2 > 255 or ndt < 0 or ndt > 63) continue;
        output[count] = packHash(@intCast(n1), @intCast(n2), @intCast(ndt));
        count += 1;
    };
    std.mem.sort(u32, output[0..count], {}, std.sort.asc(u32));
    return output[0..count];
}

fn landmarkLessThan(_: void, a: Landmark, b: Landmark) bool {
    if (a.hash != b.hash) return a.hash < b.hash;
    return a.frame < b.frame;
}

pub fn compare(allocator: std.mem.Allocator, query: []const Landmark, reference: []const Landmark) !Match {
    if (query.len == 0 or reference.len == 0) return .{};
    var offsets = std.AutoHashMap(i32, u32).init(allocator);
    defer offsets.deinit();
    var seen_query_votes = std.AutoHashMap(u64, void).init(allocator);
    defer seen_query_votes.deinit();
    var seen_reference_votes = std.AutoHashMap(u64, void).init(allocator);
    defer seen_reference_votes.deinit();
    var q_start: usize = 0;
    while (q_start < query.len) {
        try query_cancel.check();
        var q_end = q_start + 1;
        while (q_end < query.len and query[q_end].hash == query[q_start].hash) : (q_end += 1) {}
        var neighborhood_storage: [27]u32 = undefined;
        const neighborhood = neighborHashes(query[q_start].hash, &neighborhood_storage);
        const q_count = @min(q_end - q_start, 16);
        for (neighborhood) |neighbor| {
            const r_start = lowerBoundHash(reference, neighbor);
            if (r_start == reference.len or reference[r_start].hash != neighbor) continue;
            var r_end = r_start + 1;
            while (r_end < reference.len and reference[r_end].hash == neighbor) : (r_end += 1) {}
            const r_count = @min(r_end - r_start, 16);
            for (0..q_count) |q_sample| for (0..r_count) |r_sample| {
                const query_index = q_start + sampledOccurrence(q_end - q_start, q_count, q_sample);
                const q = query[query_index];
                const reference_index = r_start + sampledOccurrence(r_end - r_start, r_count, r_sample);
                const r = reference[reference_index];
                const delta64 = @as(i64, r.frame) - @as(i64, q.frame);
                if (delta64 < std.math.minInt(i32) or delta64 > std.math.maxInt(i32)) continue;
                const delta: i32 = @intCast(delta64);
                const bucket = @divFloor(delta, 2);
                const query_vote_key = (@as(u64, query_index) << 32) | @as(u32, @bitCast(bucket));
                const reference_vote_key = (@as(u64, reference_index) << 32) | @as(u32, @bitCast(bucket));
                if (seen_query_votes.contains(query_vote_key) or seen_reference_votes.contains(reference_vote_key)) continue;
                try seen_query_votes.put(query_vote_key, {});
                try seen_reference_votes.put(reference_vote_key, {});
                const entry = try offsets.getOrPut(bucket);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += 1;
            };
        }
        q_start = q_end;
    }
    var best = Match{};
    var it = offsets.iterator();
    while (it.next()) |entry| {
        try query_cancel.check();
        const votes = entry.value_ptr.*;
        const offset_frames = entry.key_ptr.* * 2;
        if (votes > best.aligned or (votes == best.aligned and offset_frames < best.offset_frames)) {
            best.aligned = votes;
            best.offset_frames = offset_frames;
        }
    }
    const denominator = @min(query.len, reference.len);
    best.score_ppm = @intCast(@min(@as(u64, 1_000_000), @as(u64, best.aligned) * 1_000_000 / denominator));
    return best;
}

fn lowerBoundHash(landmarks: []const Landmark, hash: u32) usize {
    var low: usize = 0;
    var high = landmarks.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (landmarks[middle].hash < hash) low = middle + 1 else high = middle;
    }
    return low;
}

fn sampledOccurrence(total: usize, sampled: usize, index: usize) usize {
    if (sampled <= 1 or total <= 1) return 0;
    return index * (total - 1) / (sampled - 1);
}

pub fn selectors(allocator: std.mem.Allocator, landmarks: []const Landmark) ![]u32 {
    var unique: std.ArrayList(u32) = .empty;
    defer unique.deinit(allocator);
    var previous: ?u32 = null;
    for (landmarks) |landmark| {
        try query_cancel.check();
        if (previous == null or previous.? != landmark.hash) try unique.append(allocator, landmark.hash);
        previous = landmark.hash;
    }
    std.mem.sort(u32, unique.items, {}, struct {
        fn lessThan(_: void, a: u32, b: u32) bool {
            return mixed(a) < mixed(b);
        }
        fn mixed(value: u32) u32 {
            var x = value;
            x ^= x >> 16;
            x *%= 0x7feb352d;
            x ^= x >> 15;
            x *%= 0x846ca68b;
            return x ^ (x >> 16);
        }
    }.lessThan);
    return allocator.dupe(u32, unique.items[0..@min(SELECTOR_COUNT, unique.items.len)]);
}

// WFP1 groups sorted hashes and delta-encodes frame positions with bounded
// unsigned LEB128. Legacy raw blobs stay readable; choose raw if it is smaller.
pub fn serialize(allocator: std.mem.Allocator, landmarks: []const Landmark) ![]u8 {
    if (landmarks.len > MAX_LANDMARKS or !std.sort.isSorted(Landmark, landmarks, {}, landmarkLessThan)) return error.InvalidFingerprintBlob;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendNTimes(allocator, 0, 24);
    var start: usize = 0;
    var previous_hash: u32 = 0;
    while (start < landmarks.len) {
        try query_cancel.check();
        var end = start + 1;
        while (end < landmarks.len and landmarks[end].hash == landmarks[start].hash) : (end += 1) {}
        try appendVarint(allocator, &bytes, landmarks[start].hash - previous_hash);
        try appendVarint(allocator, &bytes, @intCast(end - start));
        var previous_frame: u32 = 0;
        for (landmarks[start..end], start..) |landmark, index| {
            if (index % 1024 == 0) try query_cancel.check();
            try appendVarint(allocator, &bytes, landmark.frame - previous_frame);
            previous_frame = landmark.frame;
        }
        previous_hash = landmarks[start].hash;
        start = end;
    }
    const payload_len = bytes.items.len - 24;
    // The length tag also distinguishes compressed blobs from raw 8-byte pairs.
    while (bytes.items.len % 8 != 1) try bytes.append(allocator, 0);
    if (bytes.items.len >= landmarks.len * 8) return serializeRaw(allocator, landmarks);
    @memcpy(bytes.items[0..4], "WFP1");
    std.mem.writeInt(u32, bytes.items[4..8], 1, .little);
    std.mem.writeInt(u32, bytes.items[8..12], @intCast(landmarks.len), .little);
    std.mem.writeInt(u32, bytes.items[12..16], @intCast(payload_len), .little);
    var checksum = std.hash.Wyhash.init(0);
    checksum.update(bytes.items[0..16]);
    checksum.update(bytes.items[24..][0..payload_len]);
    std.mem.writeInt(u64, bytes.items[16..24], checksum.final(), .little);
    return bytes.toOwnedSlice(allocator);
}

fn appendVarint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: u32) !void {
    var value = input;
    while (value >= 128) {
        try out.append(allocator, @as(u8, @truncate(value)) | 0x80);
        value >>= 7;
    }
    try out.append(allocator, @intCast(value));
}

fn readVarint(bytes: []const u8, offset: *usize) !u32 {
    var value: u32 = 0;
    for (0..5) |i| {
        if (offset.* == bytes.len) return error.InvalidFingerprintBlob;
        const b = bytes[offset.*];
        offset.* += 1;
        if (i == 4 and b > 15) return error.InvalidFingerprintBlob;
        value |= @as(u32, b & 0x7f) << @intCast(i * 7);
        if (b & 0x80 == 0) {
            if (i > 0 and b == 0) return error.InvalidFingerprintBlob;
            return value;
        }
    }
    return error.InvalidFingerprintBlob;
}

pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) ![]Landmark {
    try query_cancel.check();
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "WFP1")) return deserializeRaw(allocator, bytes);
    if (bytes.len < 25 or bytes.len % 8 != 1 or bytes.len > MAX_LANDMARKS * 11 + 32 or std.mem.readInt(u32, bytes[4..8], .little) != 1) return error.InvalidFingerprintBlob;
    const count = std.mem.readInt(u32, bytes[8..12], .little);
    const payload_len = std.mem.readInt(u32, bytes[12..16], .little);
    if (count == 0 or count > MAX_LANDMARKS or payload_len > bytes.len - 24 or bytes.len - 24 - payload_len >= 8) return error.InvalidFingerprintBlob;
    for (bytes[24 + payload_len ..]) |pad| if (pad != 0) return error.InvalidFingerprintBlob;
    const payload = bytes[24..][0..payload_len];
    var checksum = std.hash.Wyhash.init(0);
    checksum.update(bytes[0..16]);
    checksum.update(payload);
    if (checksum.final() != std.mem.readInt(u64, bytes[16..24], .little)) return error.InvalidFingerprintBlob;
    const landmarks = try allocator.alloc(Landmark, count);
    errdefer allocator.free(landmarks);
    var offset: usize = 0;
    var row: usize = 0;
    var previous_hash: u32 = 0;
    while (row < count) {
        try query_cancel.check();
        const delta = try readVarint(payload, &offset);
        if (row > 0 and delta == 0) return error.InvalidFingerprintBlob;
        const hash = std.math.add(u32, previous_hash, delta) catch return error.InvalidFingerprintBlob;
        const group = try readVarint(payload, &offset);
        if (group == 0 or group > count - row) return error.InvalidFingerprintBlob;
        var frame: u32 = 0;
        for (landmarks[row..][0..group], row..) |*landmark, index| {
            if (index % 1024 == 0) try query_cancel.check();
            frame = std.math.add(u32, frame, try readVarint(payload, &offset)) catch return error.InvalidFingerprintBlob;
            landmark.* = .{ .hash = hash, .frame = frame };
        }
        row += group;
        previous_hash = hash;
    }
    if (offset != payload.len) return error.InvalidFingerprintBlob;
    return landmarks;
}

pub fn serializeRaw(allocator: std.mem.Allocator, landmarks: []const Landmark) ![]u8 {
    const bytes = try allocator.alloc(u8, try std.math.mul(usize, landmarks.len, 8));
    for (landmarks, 0..) |landmark, i| {
        std.mem.writeInt(u32, bytes[i * 8 ..][0..4], landmark.hash, .little);
        std.mem.writeInt(u32, bytes[i * 8 + 4 ..][0..4], landmark.frame, .little);
    }
    return bytes;
}

fn deserializeRaw(allocator: std.mem.Allocator, bytes: []const u8) ![]Landmark {
    if (bytes.len % 8 != 0 or bytes.len / 8 > MAX_LANDMARKS) return error.InvalidFingerprintBlob;
    const landmarks = try allocator.alloc(Landmark, bytes.len / 8);
    errdefer allocator.free(landmarks);
    for (landmarks, 0..) |*landmark, i| landmark.* = .{
        .hash = std.mem.readInt(u32, bytes[i * 8 ..][0..4], .little),
        .frame = std.mem.readInt(u32, bytes[i * 8 + 4 ..][0..4], .little),
    };
    if (!std.sort.isSorted(Landmark, landmarks, {}, landmarkLessThan)) return error.InvalidFingerprintBlob;
    return landmarks;
}

test "streamed landmark extraction is invariant to PCM chunk boundaries and cancellation" {
    const allocator = std.testing.allocator;
    const samples = try allocator.alloc(f32, 3 * 16000 + 191);
    defer allocator.free(samples);
    var random = std.Random.DefaultPrng.init(49);
    for (samples) |*sample| sample.* = random.random().float(f32) * 2 - 1;
    const expected = try fromSamples(allocator, samples);
    defer allocator.free(expected);
    for ([_]usize{ 1, 127, 256, 1023, 4096, 8192 }) |chunk| {
        var analyzer = Analyzer.init(allocator);
        defer analyzer.deinit();
        var offset: usize = 0;
        while (offset < samples.len) {
            const end = @min(samples.len, offset + chunk);
            try analyzer.push(samples[offset..end]);
            offset = end;
        }
        const actual = try analyzer.finish();
        defer allocator.free(actual);
        try std.testing.expectEqualSlices(Landmark, expected, actual);
    }
    var request = query_cancel.Request{};
    query_cancel.current = &request;
    defer query_cancel.current = null;
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try analyzer.push(samples[0..2048]);
    request.cancel();
    try std.testing.expectError(error.Cancelled, analyzer.push(samples[2048..]));
    try std.testing.expectError(error.Cancelled, analyzer.finish());
}

test "lossless grouped fingerprint storage preserves legacy landmarks and rejects corruption" {
    const allocator = std.testing.allocator;
    var landmarks: [1000]Landmark = undefined;
    for (&landmarks, 0..) |*landmark, index| landmark.* = .{ .hash = @intCast(index / 25), .frame = @intCast((index % 25) * 150 + (index / 25)) };
    const raw = try serializeRaw(allocator, &landmarks);
    defer allocator.free(raw);
    const compact = try serialize(allocator, &landmarks);
    defer allocator.free(compact);
    try std.testing.expect(compact.len < raw.len / 2);
    for ([_][]const u8{ raw, compact }) |blob| {
        const decoded = try deserialize(allocator, blob);
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(Landmark, &landmarks, decoded);
        const match = try compare(allocator, &landmarks, decoded);
        try std.testing.expect(match.highConfidence());
    }
    // Every encoded byte, including header/checksum/padding, is validated.
    for (0..compact.len) |index| {
        const original = compact[index];
        compact[index] ^= 1;
        try std.testing.expectError(error.InvalidFingerprintBlob, deserialize(allocator, compact));
        compact[index] = original;
    }
    for (0..compact.len) |length| {
        if (length % 8 == 0 and length < 4) continue; // Empty legacy blob.
        try std.testing.expectError(error.InvalidFingerprintBlob, deserialize(allocator, compact[0..length]));
    }
    // Raw fallback covers tiny/high-entropy data and full uint32 boundaries.
    const extremes = [_]Landmark{ .{ .hash = 0, .frame = 0 }, .{ .hash = std.math.maxInt(u32), .frame = std.math.maxInt(u32) } };
    const tiny = try serialize(allocator, &extremes);
    defer allocator.free(tiny);
    const decoded = try deserialize(allocator, tiny);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(Landmark, &extremes, decoded);
}
