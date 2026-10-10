const std = @import("std");
pub const types = @import("types.zig");

pub const ANALYZER_VERSION: u32 = 3;
pub const CODEC_VERSION: u32 = 3;
pub const PURPOSE_DETAILED: u32 = 1;
pub const PURPOSE_UNIVERSAL: u32 = 2;
pub const FLAG_LOUDNESS: u32 = 1;
pub const BACKEND_AUTO: u32 = 0;
pub const BACKEND_PORTABLE: u32 = 1;
pub const BACKEND_ACCELERATE: u32 = 2;
pub const LAYOUT_PLANAR: u32 = 1;
pub const LAYOUT_INTERLEAVED: u32 = 2;
pub const TIER_UNIVERSAL: u32 = 1;
pub const TIER_DETAILED: u32 = 2;
pub const RESULT_LOUDNESS_COMPLETE: u32 = 1;
pub const RESULT_LUFS_VALID: u32 = 2;
pub const RESULT_SAMPLE_PEAK_VALID: u32 = 4;
pub const RESULT_UNIVERSAL_AVAILABLE: u32 = 8;
pub const RESULT_DETAILED_AVAILABLE: u32 = 16;
pub const MAX_CHANNELS: u32 = 256;
pub const MAX_PUSH_FRAMES: u64 = 32_768;
pub const MAX_LEVELS: usize = 4;
pub const MIN_LOUDNESS_SAMPLE_RATE: f64 = 8_000;
const MAX_BUCKETS: usize = 4096;
const UNIVERSAL_BUCKETS: usize = 512;
const HISTOGRAM_BINS: usize = 120_001;
const WVT3_MAGIC: u32 = 0x3354_5657;
const WVT3_FORMAT_VERSION: u32 = 1;
const WVT3_HEADER_BYTES: usize = 88;
const WVT3_CHECKSUM_BYTES: usize = 8;
const MAX_WVT3_BYTES: usize = 4 * 1024 * 1024;

pub const Error = error{
    InvalidArgument,
    UnsupportedVersion,
    InvalidState,
    UnsupportedBackend,
    OutOfMemory,
    Cancelled,
    FrameCountMismatch,
    BufferTooSmall,
    CorruptWvt3,
};

const State = enum { accepting, finished, failed };

const Biquad = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z1: f64 = 0,
    z2: f64 = 0,

    fn process(self: *Biquad, input: f64) f64 {
        const output = self.b0 * input + self.z1;
        self.z1 = self.b1 * input - self.a1 * output + self.z2;
        self.z2 = self.b2 * input - self.a2 * output;
        return output;
    }

    fn shelf(sample_rate: f64) Biquad {
        const frequency = 1681.974450955533;
        const gain: f64 = 3.999843853973347;
        const q = 0.7071752369554196;
        const k = @tan(std.math.pi * frequency / sample_rate);
        const vh = std.math.pow(f64, 10, gain / 20);
        const vb = std.math.pow(f64, vh, 0.4996667741545416);
        const a0 = 1 + k / q + k * k;
        return .{
            .b0 = (vh + vb * k / q + k * k) / a0,
            .b1 = 2 * (k * k - vh) / a0,
            .b2 = (vh - vb * k / q + k * k) / a0,
            .a1 = 2 * (k * k - 1) / a0,
            .a2 = (1 - k / q + k * k) / a0,
        };
    }

    fn highPass(sample_rate: f64) Biquad {
        const frequency = 38.13547087602444;
        const q = 0.5003270373238773;
        const k = @tan(std.math.pi * frequency / sample_rate);
        const a0 = 1 + k / q + k * k;
        return .{
            .b0 = 1,
            .b1 = -2,
            .b2 = 1,
            .a1 = 2 * (k * k - 1) / a0,
            .a2 = (1 - k / q + k * k) / a0,
        };
    }
};

const KFilter = struct {
    shelf_filter: Biquad,
    high_pass: Biquad,

    fn init(sample_rate: f64) KFilter {
        return .{ .shelf_filter = Biquad.shelf(sample_rate), .high_pass = Biquad.highPass(sample_rate) };
    }

    fn process(self: *KFilter, sample: f64) f64 {
        return self.high_pass.process(self.shelf_filter.process(sample));
    }
};

const Loudness = struct {
    allocator: std.mem.Allocator,
    filters: []KFilter,
    weights: []f64,
    power_sums: []f64,
    counts: []u64,
    segment_frames: u64,
    segment_energy: f64 = 0,
    frames_in_segment: u64 = 0,
    recent_energy: [4]f64 = @splat(0),
    recent_frames: [4]u64 = @splat(0),
    recent_count: usize = 0,
    absolute_power_sum: f64 = 0,
    absolute_block_count: u64 = 0,
    total_energy: f64 = 0,
    total_frames: u64 = 0,

    fn init(allocator: std.mem.Allocator, sample_rate: f64, channel_count: usize) !Loudness {
        const filters = try allocator.alloc(KFilter, channel_count);
        errdefer allocator.free(filters);
        const weights = try allocator.alloc(f64, channel_count);
        errdefer allocator.free(weights);
        for (filters, 0..) |*filter, channel| {
            filter.* = KFilter.init(sample_rate);
            weights[channel] = if (channel_count >= 6 and channel == 3)
                0
            else if (channel_count >= 6 and channel >= 4)
                1.41
            else
                1;
        }
        const power_sums = try allocator.alloc(f64, HISTOGRAM_BINS);
        errdefer allocator.free(power_sums);
        @memset(power_sums, 0);
        const counts = try allocator.alloc(u64, HISTOGRAM_BINS);
        errdefer allocator.free(counts);
        @memset(counts, 0);
        return .{
            .allocator = allocator,
            .filters = filters,
            .weights = weights,
            .power_sums = power_sums,
            .counts = counts,
            .segment_frames = @max(1, @as(u64, @intFromFloat(@round(sample_rate * 0.1)))),
        };
    }

    fn deinit(self: *Loudness) void {
        self.allocator.free(self.filters);
        self.allocator.free(self.weights);
        self.allocator.free(self.power_sums);
        self.allocator.free(self.counts);
    }

    fn consumeFrame(self: *Loudness, samples: []const f32) void {
        for (samples, 0..) |raw, channel| {
            if (self.weights[channel] == 0) continue;
            const sample: f64 = if (std.math.isFinite(raw)) @floatCast(raw) else 0;
            const weighted = self.filters[channel].process(sample);
            self.segment_energy += weighted * weighted * self.weights[channel];
        }
        self.frames_in_segment += 1;
        if (self.frames_in_segment == self.segment_frames) self.appendSegment();
    }

    fn finishStream(self: *Loudness) void {
        if (self.frames_in_segment > 0) self.appendSegment();
    }

    fn appendSegment(self: *Loudness) void {
        const frames = @max(self.frames_in_segment, 1);
        self.total_energy += self.segment_energy;
        self.total_frames += frames;
        if (self.recent_count < 4) {
            self.recent_energy[self.recent_count] = self.segment_energy;
            self.recent_frames[self.recent_count] = frames;
            self.recent_count += 1;
        }
        if (self.recent_count == 4) {
            var frame_count: u64 = 0;
            var energy: f64 = 0;
            for (0..4) |index| {
                frame_count += self.recent_frames[index];
                energy += self.recent_energy[index];
            }
            if (frame_count == self.segment_frames * 4) self.appendBlockPower(energy / @as(f64, @floatFromInt(frame_count)));
            for (0..3) |index| {
                self.recent_energy[index] = self.recent_energy[index + 1];
                self.recent_frames[index] = self.recent_frames[index + 1];
            }
            self.recent_count = 3;
        }
        self.segment_energy = 0;
        self.frames_in_segment = 0;
    }

    fn appendBlockPower(self: *Loudness, power: f64) void {
        if (!(power > 0) or !std.math.isFinite(power)) return;
        const loudness = -0.691 + 10 * @log10(power);
        if (!(loudness > -70)) return;
        self.absolute_power_sum += power;
        self.absolute_block_count += 1;
        const raw_index: i64 = @intFromFloat(@floor((loudness + 70) * 1000));
        const index: usize = @intCast(std.math.clamp(raw_index, 0, HISTOGRAM_BINS - 1));
        self.power_sums[index] += power;
        self.counts[index] += 1;
    }

    fn integrated(self: *const Loudness) ?f64 {
        if (self.absolute_block_count == 0) {
            if (self.total_frames == 0 or !(self.total_energy > 0) or !std.math.isFinite(self.total_energy)) return null;
            const power = self.total_energy / @as(f64, @floatFromInt(self.total_frames));
            const value = -0.691 + 10 * @log10(power);
            return if (std.math.isFinite(value) and value > -70) value else null;
        }
        const preliminary = self.absolute_power_sum / @as(f64, @floatFromInt(self.absolute_block_count));
        if (!(preliminary > 0) or !std.math.isFinite(preliminary)) return null;
        const threshold = -0.691 + 10 * @log10(preliminary) - 10;
        var power_sum: f64 = 0;
        var count: u64 = 0;
        for (self.counts, 0..) |bin_count, index| {
            if (bin_count == 0) continue;
            const center = -70 + (@as(f64, @floatFromInt(index)) + 0.5) / 1000;
            if (center > threshold) {
                power_sum += self.power_sums[index];
                count += bin_count;
            }
        }
        if (count == 0 or !(power_sum > 0) or !std.math.isFinite(power_sum)) return null;
        const result = -0.691 + 10 * @log10(power_sum / @as(f64, @floatFromInt(count)));
        return if (std.math.isFinite(result)) result else null;
    }
};

pub const Level = struct {
    bucket_count: usize,
    rendered_channels: usize,
    codes: []i8,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    purpose: u32,
    resolved_backend: u32 = BACKEND_PORTABLE,
    flags: u32,
    sample_rate: f64,
    frame_count: u64,
    source_channel_count: u32,
    rendered_channel_count: u32,
    source_file_size: i64,
    source_mtime_ns: i64,
    source_content_hash: i64,
    integrated_lufs: ?f64,
    sample_peak_dbfs: ?f64,
    levels: []Level,

    pub fn deinit(self: *Result) void {
        for (self.levels) |level| self.allocator.free(level.codes);
        self.allocator.free(self.levels);
        self.allocator.destroy(self);
    }

    pub fn fillInfo(self: *const Result, info: *types.WSWaveformResultInfo) void {
        info.* = std.mem.zeroes(types.WSWaveformResultInfo);
        info.struct_size = @sizeOf(types.WSWaveformResultInfo);
        info.version = types.WS_WAVEFORM_RESULT_INFO_VERSION;
        info.analyzer_version = ANALYZER_VERSION;
        info.codec_version = CODEC_VERSION;
        info.purpose = self.purpose;
        info.resolved_backend = self.resolved_backend;
        info.flags = self.flags;
        info.level_count = @intCast(self.levels.len);
        info.sample_rate = self.sample_rate;
        info.frame_count = self.frame_count;
        info.source_channel_count = self.source_channel_count;
        info.rendered_channel_count = self.rendered_channel_count;
        for (self.levels, 0..) |level, index| info.level_bucket_counts[index] = @intCast(level.bucket_count);
        info.source_file_size = self.source_file_size;
        info.source_mtime_ns = self.source_mtime_ns;
        info.source_content_hash = self.source_content_hash;
        info.integrated_lufs = self.integrated_lufs orelse std.math.nan(f64);
        info.sample_peak_dbfs = self.sample_peak_dbfs orelse std.math.nan(f64);
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    config: types.WSWaveformAnalyzerConfig,
    state: State = .accepting,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rendered_channels: usize,
    base_bucket_count: usize,
    minima: []f32,
    maxima: []f32,
    touched: []bool,
    loudness: ?Loudness,
    sample_peak: f32 = 0,
    frames_seen: u64 = 0,
    frame_samples: []f32,

    pub fn create(allocator: std.mem.Allocator, config: types.WSWaveformAnalyzerConfig) !*Analyzer {
        try validateConfig(config);
        const analyzer = try allocator.create(Analyzer);
        errdefer allocator.destroy(analyzer);
        const rendered_channels: usize = @min(config.channel_count, 2);
        const base_count: usize = if (config.purpose == PURPOSE_UNIVERSAL and config.total_frames >= MAX_BUCKETS)
            UNIVERSAL_BUCKETS
        else
            @min(@as(usize, @intCast(config.total_frames)), MAX_BUCKETS);
        const extrema_count = std.math.mul(usize, base_count, rendered_channels) catch return error.InvalidArgument;
        const minima = try allocator.alloc(f32, extrema_count);
        errdefer allocator.free(minima);
        @memset(minima, std.math.inf(f32));
        const maxima = try allocator.alloc(f32, extrema_count);
        errdefer allocator.free(maxima);
        @memset(maxima, -std.math.inf(f32));
        const touched = try allocator.alloc(bool, base_count);
        errdefer allocator.free(touched);
        @memset(touched, false);
        const frame_samples = try allocator.alloc(f32, config.channel_count);
        errdefer allocator.free(frame_samples);
        var loudness: ?Loudness = null;
        if ((config.flags & FLAG_LOUDNESS) != 0) loudness = try Loudness.init(allocator, config.sample_rate, config.channel_count);
        analyzer.* = .{
            .allocator = allocator,
            .config = config,
            .rendered_channels = rendered_channels,
            .base_bucket_count = base_count,
            .minima = minima,
            .maxima = maxima,
            .touched = touched,
            .loudness = loudness,
            .frame_samples = frame_samples,
        };
        return analyzer;
    }

    pub fn deinit(self: *Analyzer) void {
        if (self.loudness) |*loudness| loudness.deinit();
        self.allocator.free(self.minima);
        self.allocator.free(self.maxima);
        self.allocator.free(self.touched);
        self.allocator.free(self.frame_samples);
        self.allocator.destroy(self);
    }

    pub fn cancel(self: *Analyzer) void {
        self.cancelled.store(true, .release);
    }

    pub fn push(self: *Analyzer, buffer: types.WSWaveformPCMBuffer) !void {
        if (self.state != .accepting) return error.InvalidState;
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        try validateBuffer(self, buffer);
        if (buffer.frame_count > self.config.total_frames - self.frames_seen) return error.FrameCountMismatch;
        const frames: usize = @intCast(buffer.frame_count);
        const channels: usize = self.config.channel_count;
        for (0..frames) |frame| {
            if ((frame & 1023) == 0 and self.cancelled.load(.acquire)) return error.Cancelled;
            const absolute = self.frames_seen + frame;
            const bucket: usize = @intCast((@as(u128, absolute) * self.base_bucket_count) / self.config.total_frames);
            self.touched[bucket] = true;
            for (0..channels) |channel| {
                const raw = sampleAt(buffer, frame, channel, channels);
                const sample: f32 = if (std.math.isFinite(raw)) raw else 0;
                self.frame_samples[channel] = sample;
                const magnitude = @abs(sample);
                if (magnitude > self.sample_peak) self.sample_peak = magnitude;
                if (channel < self.rendered_channels) {
                    const index = channel * self.base_bucket_count + bucket;
                    self.minima[index] = @min(self.minima[index], sample);
                    self.maxima[index] = @max(self.maxima[index], sample);
                }
            }
            if (self.loudness) |*loudness| loudness.consumeFrame(self.frame_samples);
        }
        self.frames_seen += buffer.frame_count;
    }

    pub fn finish(self: *Analyzer) !*Result {
        if (self.state != .accepting) return error.InvalidState;
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (self.frames_seen != self.config.total_frames) return error.FrameCountMismatch;
        if (self.loudness) |*loudness| loudness.finishStream();
        for (self.touched, 0..) |was_touched, bucket| {
            if (was_touched) continue;
            for (0..self.rendered_channels) |channel| {
                const index = channel * self.base_bucket_count + bucket;
                self.minima[index] = 0;
                self.maxima[index] = 0;
            }
        }
        const result = try resultFromFloatBase(
            self.allocator,
            self.config.purpose,
            BACKEND_PORTABLE,
            self.config.sample_rate,
            self.config.total_frames,
            self.config.channel_count,
            @intCast(self.rendered_channels),
            self.config.source_file_size,
            self.config.source_mtime_ns,
            self.config.source_content_hash,
            self.loudness != null,
            if (self.loudness) |*loudness| loudness.integrated() else null,
            if (self.loudness != null and self.sample_peak > 0) 20 * @log10(@as(f64, self.sample_peak)) else null,
            self.minima,
            self.maxima,
            self.base_bucket_count,
        );
        self.state = .finished;
        return result;
    }
};

fn validateConfig(config: types.WSWaveformAnalyzerConfig) !void {
    if (config.struct_size != @sizeOf(types.WSWaveformAnalyzerConfig) or config.version != types.WS_WAVEFORM_ANALYZER_ABI_VERSION) return error.UnsupportedVersion;
    if (config.purpose != PURPOSE_DETAILED and config.purpose != PURPOSE_UNIVERSAL) return error.InvalidArgument;
    if ((config.flags & ~FLAG_LOUDNESS) != 0 or config.reserved0 != 0 or config.reserved1 != 0 or config.reserved[0] != 0 or config.reserved[1] != 0) return error.InvalidArgument;
    if (config.backend == BACKEND_ACCELERATE) return error.UnsupportedBackend;
    if (config.backend != BACKEND_AUTO and config.backend != BACKEND_PORTABLE) return error.UnsupportedBackend;
    if (!std.math.isFinite(config.sample_rate) or config.sample_rate < 1 or config.sample_rate > 768_000) return error.InvalidArgument;
    if ((config.flags & FLAG_LOUDNESS) != 0 and config.sample_rate < MIN_LOUDNESS_SAMPLE_RATE) return error.InvalidArgument;
    if (config.total_frames == 0 or config.total_frames > std.math.maxInt(i64)) return error.InvalidArgument;
    if (config.channel_count == 0 or config.channel_count > MAX_CHANNELS) return error.InvalidArgument;
    if (config.source_file_size < 0 or config.source_mtime_ns < 0) return error.InvalidArgument;
}

fn validateBuffer(analyzer: *const Analyzer, buffer: types.WSWaveformPCMBuffer) !void {
    if (buffer.struct_size != @sizeOf(types.WSWaveformPCMBuffer) or buffer.version != types.WS_WAVEFORM_PCM_BUFFER_VERSION) return error.UnsupportedVersion;
    if (buffer.reserved[0] != 0 or buffer.reserved[1] != 0 or buffer.channel_count != analyzer.config.channel_count or buffer.frame_count == 0 or buffer.frame_count > MAX_PUSH_FRAMES) return error.InvalidArgument;
    if (buffer.layout == LAYOUT_PLANAR) {
        if (buffer.planes == null or buffer.interleaved != null) return error.InvalidArgument;
        const planes = buffer.planes.?;
        for (0..buffer.channel_count) |channel| if (planes[channel] == null) return error.InvalidArgument;
    } else if (buffer.layout == LAYOUT_INTERLEAVED) {
        if (buffer.interleaved == null or buffer.planes != null) return error.InvalidArgument;
    } else return error.InvalidArgument;
}

fn sampleAt(buffer: types.WSWaveformPCMBuffer, frame: usize, channel: usize, channels: usize) f32 {
    return if (buffer.layout == LAYOUT_PLANAR)
        buffer.planes.?[channel].?[frame]
    else
        buffer.interleaved.?[frame * channels + channel];
}

fn muEncode(raw: f32) i8 {
    const value = if (std.math.isFinite(raw)) std.math.clamp(raw, -1, 1) else 0;
    if (value == 0) return 0;
    const mu: f32 = 255;
    const magnitude = std.math.log1p(mu * @abs(value)) / std.math.log1p(mu);
    const rounded: i32 = @intFromFloat(@floor(magnitude * 127 + 0.5));
    const code: i8 = @intCast(std.math.clamp(rounded, 0, 127));
    return if (value < 0) -code else code;
}

pub fn muDecode(code: i8) !f32 {
    if (code == std.math.minInt(i8)) return error.CorruptWvt3;
    if (code == 0) return 0;
    const mu: f32 = 255;
    const magnitude = std.math.expm1(@as(f32, @floatFromInt(@abs(@as(i16, code)))) / 127 * std.math.log1p(mu)) / mu;
    return if (code < 0) -magnitude else magnitude;
}

fn allocLevelFromFloat(allocator: std.mem.Allocator, minima: []const f32, maxima: []const f32, channels: usize, buckets: usize) !Level {
    const codes = try allocator.alloc(i8, channels * buckets * 2);
    for (0..channels) |channel| for (0..buckets) |bucket| {
        const source = channel * buckets + bucket;
        const target = (channel * buckets + bucket) * 2;
        codes[target] = muEncode(minima[source]);
        codes[target + 1] = muEncode(maxima[source]);
    };
    return .{ .bucket_count = buckets, .rendered_channels = channels, .codes = codes };
}

fn reduceLevel(allocator: std.mem.Allocator, source: Level, target_buckets: usize) !Level {
    const codes = try allocator.alloc(i8, source.rendered_channels * target_buckets * 2);
    for (0..source.rendered_channels) |channel| for (0..target_buckets) |bucket| {
        const start = bucket * source.bucket_count / target_buckets;
        const end = @max(start + 1, (bucket + 1) * source.bucket_count / target_buckets);
        var low: i8 = 127;
        var high: i8 = -127;
        for (start..@min(end, source.bucket_count)) |index| {
            const offset = (channel * source.bucket_count + index) * 2;
            low = @min(low, source.codes[offset]);
            high = @max(high, source.codes[offset + 1]);
        }
        const target = (channel * target_buckets + bucket) * 2;
        codes[target] = low;
        codes[target + 1] = high;
    };
    return .{ .bucket_count = target_buckets, .rendered_channels = source.rendered_channels, .codes = codes };
}

fn buildDetailedLevels(allocator: std.mem.Allocator, base: Level) ![]Level {
    var counts: [MAX_LEVELS]usize = undefined;
    var count_len: usize = 0;
    var count: usize = @min(UNIVERSAL_BUCKETS, base.bucket_count);
    while (count < base.bucket_count) {
        if (count_len >= MAX_LEVELS - 1 or count == 0) return error.InvalidArgument;
        counts[count_len] = count;
        count_len += 1;
        count = @min(base.bucket_count, std.math.mul(usize, count, 2) catch base.bucket_count);
    }
    counts[count_len] = base.bucket_count;
    count_len += 1;
    const levels = try allocator.alloc(Level, count_len);
    errdefer allocator.free(levels);
    var initialized: usize = 0;
    errdefer for (levels[0..initialized]) |level| allocator.free(level.codes);
    for (counts[0..count_len], 0..) |target, index| {
        levels[index] = if (target == base.bucket_count)
            .{ .bucket_count = base.bucket_count, .rendered_channels = base.rendered_channels, .codes = try allocator.dupe(i8, base.codes) }
        else
            try reduceLevel(allocator, base, target);
        initialized += 1;
    }
    return levels;
}

fn resultFromFloatBase(
    allocator: std.mem.Allocator,
    purpose: u32,
    backend: u32,
    sample_rate: f64,
    frame_count: u64,
    source_channels: u32,
    rendered_channels: u32,
    source_file_size: i64,
    source_mtime_ns: i64,
    source_content_hash: i64,
    loudness_complete: bool,
    integrated_lufs: ?f64,
    sample_peak_dbfs: ?f64,
    minima: []const f32,
    maxima: []const f32,
    base_bucket_count: usize,
) !*Result {
    const base = try allocLevelFromFloat(allocator, minima, maxima, rendered_channels, base_bucket_count);
    defer allocator.free(base.codes);
    const levels = if (purpose == PURPOSE_DETAILED)
        try buildDetailedLevels(allocator, base)
    else blk: {
        const target = @min(UNIVERSAL_BUCKETS, base.bucket_count);
        const output = try allocator.alloc(Level, 1);
        errdefer allocator.free(output);
        output[0] = if (target == base.bucket_count)
            .{ .bucket_count = base.bucket_count, .rendered_channels = base.rendered_channels, .codes = try allocator.dupe(i8, base.codes) }
        else
            try reduceLevel(allocator, base, target);
        break :blk output;
    };
    errdefer {
        for (levels) |level| allocator.free(level.codes);
        allocator.free(levels);
    }
    const result = try allocator.create(Result);
    var flags: u32 = RESULT_UNIVERSAL_AVAILABLE;
    if (purpose == PURPOSE_DETAILED) flags |= RESULT_DETAILED_AVAILABLE;
    if (loudness_complete) flags |= RESULT_LOUDNESS_COMPLETE;
    if (integrated_lufs != null) flags |= RESULT_LUFS_VALID;
    if (sample_peak_dbfs != null) flags |= RESULT_SAMPLE_PEAK_VALID;
    result.* = .{
        .allocator = allocator,
        .purpose = purpose,
        .resolved_backend = backend,
        .flags = flags,
        .sample_rate = sample_rate,
        .frame_count = frame_count,
        .source_channel_count = source_channels,
        .rendered_channel_count = rendered_channels,
        .source_file_size = source_file_size,
        .source_mtime_ns = source_mtime_ns,
        .source_content_hash = source_content_hash,
        .integrated_lufs = integrated_lufs,
        .sample_peak_dbfs = sample_peak_dbfs,
        .levels = levels,
    };
    return result;
}

pub fn resultFromHost(allocator: std.mem.Allocator, info: types.WSWaveformResultInfo, peaks: []const types.WSWaveformPeak) !*Result {
    if (info.struct_size != @sizeOf(types.WSWaveformResultInfo) or info.version != types.WS_WAVEFORM_RESULT_INFO_VERSION) return error.UnsupportedVersion;
    if (info.purpose != PURPOSE_DETAILED and info.purpose != PURPOSE_UNIVERSAL) return error.InvalidArgument;
    if (!std.math.isFinite(info.sample_rate) or info.sample_rate < 1 or info.sample_rate > 768_000 or info.frame_count == 0 or info.frame_count > std.math.maxInt(i64) or info.source_channel_count == 0 or info.source_channel_count > MAX_CHANNELS or info.rendered_channel_count == 0 or info.rendered_channel_count > 2 or info.rendered_channel_count > info.source_channel_count or info.level_count == 0 or info.level_count > MAX_LEVELS or info.source_file_size < 0 or info.source_mtime_ns < 0) return error.InvalidArgument;
    if ((info.flags & RESULT_LOUDNESS_COMPLETE) != 0 and info.sample_rate < MIN_LOUDNESS_SAMPLE_RATE) return error.InvalidArgument;
    const bucket_count: usize = info.level_bucket_counts[info.level_count - 1];
    if (bucket_count == 0 or bucket_count > MAX_BUCKETS or peaks.len != bucket_count * info.rendered_channel_count) return error.InvalidArgument;
    const minima = try allocator.alloc(f32, peaks.len);
    defer allocator.free(minima);
    const maxima = try allocator.alloc(f32, peaks.len);
    defer allocator.free(maxima);
    for (peaks, 0..) |peak, index| {
        const low = if (std.math.isFinite(peak.minimum)) peak.minimum else 0;
        const high = if (std.math.isFinite(peak.maximum)) peak.maximum else 0;
        minima[index] = @min(low, high);
        maxima[index] = @max(low, high);
    }
    return resultFromFloatBase(
        allocator,
        info.purpose,
        if (info.resolved_backend == BACKEND_ACCELERATE) BACKEND_ACCELERATE else BACKEND_PORTABLE,
        info.sample_rate,
        info.frame_count,
        info.source_channel_count,
        info.rendered_channel_count,
        info.source_file_size,
        info.source_mtime_ns,
        info.source_content_hash,
        (info.flags & RESULT_LOUDNESS_COMPLETE) != 0,
        if ((info.flags & RESULT_LUFS_VALID) != 0 and std.math.isFinite(info.integrated_lufs)) info.integrated_lufs else null,
        if ((info.flags & RESULT_SAMPLE_PEAK_VALID) != 0 and std.math.isFinite(info.sample_peak_dbfs)) info.sample_peak_dbfs else null,
        minima,
        maxima,
        bucket_count,
    );
}

fn tierLevel(result: *const Result, tier: u32) !Level {
    if (tier == TIER_UNIVERSAL) return result.levels[0];
    if (tier == TIER_DETAILED and result.purpose == PURPOSE_DETAILED) return result.levels[result.levels.len - 1];
    return error.InvalidArgument;
}

pub fn serializedSize(result: *const Result, tier: u32) !usize {
    if ((result.flags & RESULT_LOUDNESS_COMPLETE) == 0) return error.InvalidState;
    const level = try tierLevel(result, tier);
    return WVT3_HEADER_BYTES + level.codes.len + WVT3_CHECKSUM_BYTES;
}

pub fn serialize(result: *const Result, tier: u32, output: []u8) !usize {
    const required = try serializedSize(result, tier);
    if (output.len < required) return error.BufferTooSmall;
    const level = try tierLevel(result, tier);
    writeU32(output, 0, WVT3_MAGIC);
    writeU32(output, 4, WVT3_FORMAT_VERSION);
    writeU32(output, 8, CODEC_VERSION);
    writeU32(output, 12, tier);
    writeU32(output, 16, ANALYZER_VERSION);
    writeI64(output, 20, result.source_file_size);
    writeI64(output, 28, result.source_mtime_ns);
    writeI64(output, 36, result.source_content_hash);
    writeF64(output, 44, result.sample_rate);
    writeI64(output, 52, @intCast(result.frame_count));
    writeU32(output, 60, result.source_channel_count);
    writeU32(output, 64, @intCast(level.bucket_count));
    writeU32(output, 68, result.rendered_channel_count);
    writeF64(output, 72, result.integrated_lufs orelse std.math.nan(f64));
    writeF64(output, 80, result.sample_peak_dbfs orelse std.math.nan(f64));
    @memcpy(output[WVT3_HEADER_BYTES .. WVT3_HEADER_BYTES + level.codes.len], std.mem.sliceAsBytes(level.codes));
    const checksum = checksum64(output[0 .. required - WVT3_CHECKSUM_BYTES]);
    writeU64(output, required - WVT3_CHECKSUM_BYTES, checksum);
    return required;
}

pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !*Result {
    if (bytes.len < WVT3_HEADER_BYTES + WVT3_CHECKSUM_BYTES or bytes.len > MAX_WVT3_BYTES) return error.CorruptWvt3;
    const stored_checksum = readU64(bytes, bytes.len - WVT3_CHECKSUM_BYTES) catch return error.CorruptWvt3;
    if (stored_checksum != checksum64(bytes[0 .. bytes.len - WVT3_CHECKSUM_BYTES])) return error.CorruptWvt3;
    if ((readU32(bytes, 0) catch return error.CorruptWvt3) != WVT3_MAGIC or (readU32(bytes, 4) catch return error.CorruptWvt3) != WVT3_FORMAT_VERSION or (readU32(bytes, 8) catch return error.CorruptWvt3) != CODEC_VERSION or (readU32(bytes, 16) catch return error.CorruptWvt3) != ANALYZER_VERSION) return error.CorruptWvt3;
    const tier = readU32(bytes, 12) catch return error.CorruptWvt3;
    if (tier != TIER_UNIVERSAL and tier != TIER_DETAILED) return error.CorruptWvt3;
    const source_file_size = readI64(bytes, 20) catch return error.CorruptWvt3;
    const source_mtime_ns = readI64(bytes, 28) catch return error.CorruptWvt3;
    const source_content_hash = readI64(bytes, 36) catch return error.CorruptWvt3;
    const sample_rate = readF64(bytes, 44) catch return error.CorruptWvt3;
    const frame_count_i = readI64(bytes, 52) catch return error.CorruptWvt3;
    const source_channels = readU32(bytes, 60) catch return error.CorruptWvt3;
    const buckets: usize = readU32(bytes, 64) catch return error.CorruptWvt3;
    const rendered_channels: usize = readU32(bytes, 68) catch return error.CorruptWvt3;
    if (source_file_size < 0 or source_mtime_ns < 0 or !std.math.isFinite(sample_rate) or sample_rate < MIN_LOUDNESS_SAMPLE_RATE or sample_rate > 768_000 or frame_count_i <= 0 or source_channels == 0 or source_channels > MAX_CHANNELS or buckets == 0 or buckets > MAX_BUCKETS or rendered_channels == 0 or rendered_channels > 2 or rendered_channels > source_channels) return error.CorruptWvt3;
    const code_count = std.math.mul(usize, buckets, rendered_channels * 2) catch return error.CorruptWvt3;
    if (bytes.len != WVT3_HEADER_BYTES + code_count + WVT3_CHECKSUM_BYTES) return error.CorruptWvt3;
    const base_codes = try allocator.alloc(i8, code_count);
    defer allocator.free(base_codes);
    for (base_codes, bytes[WVT3_HEADER_BYTES .. WVT3_HEADER_BYTES + code_count]) |*code, byte| code.* = @bitCast(byte);
    for (0..rendered_channels) |channel| for (0..buckets) |bucket| {
        const offset = (channel * buckets + bucket) * 2;
        if (base_codes[offset] == std.math.minInt(i8) or base_codes[offset + 1] == std.math.minInt(i8) or base_codes[offset] > base_codes[offset + 1]) return error.CorruptWvt3;
    };
    const base = Level{ .bucket_count = buckets, .rendered_channels = rendered_channels, .codes = base_codes };
    const levels = if (tier == TIER_DETAILED)
        try buildDetailedLevels(allocator, base)
    else blk: {
        const output = try allocator.alloc(Level, 1);
        errdefer allocator.free(output);
        output[0] = .{ .bucket_count = buckets, .rendered_channels = rendered_channels, .codes = try allocator.dupe(i8, base_codes) };
        break :blk output;
    };
    errdefer {
        for (levels) |level| allocator.free(level.codes);
        allocator.free(levels);
    }
    const result = try allocator.create(Result);
    const lufs_raw = readF64(bytes, 72) catch return error.CorruptWvt3;
    const peak_raw = readF64(bytes, 80) catch return error.CorruptWvt3;
    var flags: u32 = RESULT_LOUDNESS_COMPLETE | RESULT_UNIVERSAL_AVAILABLE;
    if (tier == TIER_DETAILED) flags |= RESULT_DETAILED_AVAILABLE;
    if (std.math.isFinite(lufs_raw)) flags |= RESULT_LUFS_VALID;
    if (std.math.isFinite(peak_raw)) flags |= RESULT_SAMPLE_PEAK_VALID;
    result.* = .{
        .allocator = allocator,
        .purpose = if (tier == TIER_DETAILED) PURPOSE_DETAILED else PURPOSE_UNIVERSAL,
        .flags = flags,
        .sample_rate = sample_rate,
        .frame_count = @intCast(frame_count_i),
        .source_channel_count = source_channels,
        .rendered_channel_count = @intCast(rendered_channels),
        .source_file_size = source_file_size,
        .source_mtime_ns = source_mtime_ns,
        .source_content_hash = source_content_hash,
        .integrated_lufs = if (std.math.isFinite(lufs_raw)) lufs_raw else null,
        .sample_peak_dbfs = if (std.math.isFinite(peak_raw)) peak_raw else null,
        .levels = levels,
    };
    return result;
}

pub fn checksum64(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x0000_0100_0000_01b3;
    }
    return hash;
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
}
fn writeI64(bytes: []u8, offset: usize, value: i64) void {
    std.mem.writeInt(i64, bytes[offset..][0..8], value, .little);
}
fn writeF64(bytes: []u8, offset: usize, value: f64) void {
    writeU64(bytes, offset, @bitCast(value));
}
fn readU32(bytes: []const u8, offset: usize) !u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.CorruptWvt3;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn readU64(bytes: []const u8, offset: usize) !u64 {
    if (offset > bytes.len or bytes.len - offset < 8) return error.CorruptWvt3;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}
fn readI64(bytes: []const u8, offset: usize) !i64 {
    if (offset > bytes.len or bytes.len - offset < 8) return error.CorruptWvt3;
    return std.mem.readInt(i64, bytes[offset..][0..8], .little);
}
fn readF64(bytes: []const u8, offset: usize) !f64 {
    return @bitCast(try readU64(bytes, offset));
}
