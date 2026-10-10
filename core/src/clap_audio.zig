const std = @import("std");
const query_cancel = @import("query.zig");
const audio_file = @import("audio_file.zig");

/// Audio contract for the selected CLAP ONNX model pack.
pub const SAMPLE_RATE: u32 = 48_000;
pub const FINGERPRINT_SAMPLE_RATE: u32 = 16_000;
pub const MAX_FINGERPRINT_SECONDS: usize = 300;
pub const MAX_EXTERNAL_PCM_SECONDS: usize = 60;
pub const WINDOW_SAMPLES: usize = 480_000;
pub const WINDOW_SECONDS: usize = 10;
/// Revision includes center cropping, whole-waveform repeats plus zero tail,
/// a 32-tap/1025-phase Blackman-windowed sinc resampler, and the CLAP int16
/// compatibility round-trip.
pub const PREPROCESSING_REVISION = "clap-waveform-48k-mono-10s-sinc32-repeat-zero-i16rt-multi5-mean-l2-v2";
pub const MAX_AUDIO_WINDOWS: usize = 5;

pub const MAX_WAV_BYTES: u64 = 1024 * 1024 * 1024;
pub const MAX_CHUNK_BYTES: u64 = 1024 * 1024 * 1024;
pub const MAX_SAMPLE_RATE: u32 = 384_000;
pub const MAX_CHANNELS: u16 = 256;

const FILTER_RADIUS: usize = 16;
const FILTER_TAPS: usize = FILTER_RADIUS * 2;
const FILTER_PHASES: usize = 1024;
const SCRATCH_BYTES: usize = 64 * 1024;

const Encoding = enum { pcm, float };

const Format = struct {
    encoding: Encoding,
    channels: u16,
    sample_rate: u32,
    block_align: u16,
    container_bits: u16,
    valid_bits: u16,
    unsigned_pcm8: bool = true,
};

const Parsed = struct {
    endian: std.builtin.Endian,
    format: Format,
    data_offset: u64,
    data_size: u64,
    frames: usize,
};

const Input = union(enum) {
    bytes: []const u8,
    file: audio_file.Reader,

    fn len(self: Input) u64 {
        return switch (self) {
            .bytes => |bytes| bytes.len,
            .file => |file| file.size,
        };
    }

    fn readExact(self: Input, offset: u64, dest: []u8) !void {
        try query_cancel.check();
        const end = std.math.add(u64, offset, dest.len) catch return error.TruncatedWav;
        if (end > self.len()) return error.TruncatedWav;
        switch (self) {
            .bytes => |bytes| {
                const start: usize = @intCast(offset);
                @memcpy(dest, bytes[start .. start + dest.len]);
            },
            .file => |file| {
                const got = try file.readAll(dest, offset);
                if (got != dest.len) return error.TruncatedWav;
            },
        }
        try query_cancel.check();
    }
};

pub fn canonicalizeInterleavedPcm(allocator: std.mem.Allocator, samples: []const f32, frames: usize, channels: u16, sample_rate: u32) ![]f32 {
    try query_cancel.check();
    if (frames == 0 or channels == 0 or channels > MAX_CHANNELS or sample_rate == 0 or sample_rate > MAX_SAMPLE_RATE) return error.InvalidPcmContract;
    if (frames > @as(usize, sample_rate) * MAX_EXTERNAL_PCM_SECONDS) return error.ExternalPcmDurationLimit;
    const expected = std.math.mul(usize, frames, channels) catch return error.AudioTooLarge;
    if (samples.len != expected) return error.InvalidPcmContract;
    const mono = try allocator.alloc(f32, frames);
    defer allocator.free(mono);
    for (mono, 0..) |*destination, frame| {
        if (frame % 1024 == 0) try query_cancel.check();
        var sum: f64 = 0;
        for (0..channels) |channel| {
            const value = samples[frame * channels + channel];
            if (!std.math.isFinite(value)) return error.NonFiniteSample;
            sum += value;
        }
        destination.* = @floatCast(sum / @as(f64, @floatFromInt(channels)));
    }
    const output_count = (@as(u128, frames) * FINGERPRINT_SAMPLE_RATE) / sample_rate;
    if (output_count == 0 or output_count > std.math.maxInt(usize)) return error.AudioTooLarge;
    const output = try allocator.alloc(f32, @intCast(output_count));
    errdefer allocator.free(output);
    if (sample_rate == FINGERPRINT_SAMPLE_RATE) {
        for (output, mono, 0..) |*destination, value, index| {
            if (index % 1024 == 0) try query_cancel.check();
            destination.* = int16CompatibilityRoundTrip(value);
        }
        try query_cancel.check();
        return output;
    }
    const table = try makePolyphaseTable(allocator, sample_rate, FINGERPRINT_SAMPLE_RATE);
    defer allocator.free(table);
    for (output, 0..) |*destination, index| {
        if (index % 1024 == 0) try query_cancel.check();
        destination.* = int16CompatibilityRoundTrip(resampleOne(mono, 0, mono.len, index, sample_rate, FINGERPRINT_SAMPLE_RATE, false, table));
    }
    try query_cancel.check();
    return output;
}

pub fn isBuiltInAudioPath(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".wav") or std.ascii.endsWithIgnoreCase(path, ".aif") or std.ascii.endsWithIgnoreCase(path, ".aiff") or std.ascii.endsWithIgnoreCase(path, ".aifc");
}

pub fn durationMsFile(io: std.Io, path: []const u8) !i32 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return durationMsFromFile(.{ .handle = &file, .io = io, .size = stat.size });
}

pub fn durationMsFromFile(reader: audio_file.Reader) !i32 {
    const input: Input = .{ .file = reader };
    const parsed = try parseAudio(input);
    const milliseconds = (@as(u128, parsed.frames) * 1000) / parsed.format.sample_rate;
    return @intCast(@min(milliseconds, std.math.maxInt(i32)));
}

pub fn preprocessFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]f32 {
    try query_cancel.check();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > MAX_WAV_BYTES) return error.FileTooLarge;
    const input: Input = .{ .file = .{ .handle = &file, .io = io, .size = stat.size } };
    return preprocessInput(allocator, input);
}

pub fn preprocessWavBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]f32 {
    try query_cancel.check();
    if (bytes.len > MAX_WAV_BYTES) return error.FileTooLarge;
    return preprocessInput(allocator, .{ .bytes = bytes });
}

pub const WindowReader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    size: u64,
    parsed: Parsed,
    destination_frames: usize,
    window_count: usize,
    next_window: usize = 0,
    coefficients: ?[]f32,

    pub fn initFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !WindowReader {
        try query_cancel.check();
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.size > MAX_WAV_BYTES) return error.FileTooLarge;
        const input: Input = .{ .file = .{ .handle = &file, .io = io, .size = stat.size } };
        const parsed = try parseAudio(input);
        if (parsed.format.encoding == .float) try validateFiniteFloatData(allocator, input, parsed);
        const destination_frames = try resampledFrameCount(parsed.frames, parsed.format.sample_rate, SAMPLE_RATE);
        const planned_windows = audioWindowCount(destination_frames);
        const coefficients = if (parsed.format.sample_rate == SAMPLE_RATE) null else try makePolyphaseTable(allocator, parsed.format.sample_rate, SAMPLE_RATE);
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .size = stat.size,
            .parsed = parsed,
            .destination_frames = destination_frames,
            .window_count = planned_windows,
            .coefficients = coefficients,
        };
    }

    pub fn deinit(self: *WindowReader) void {
        if (self.coefficients) |table| self.allocator.free(table);
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn count(self: *const WindowReader) usize {
        return self.window_count;
    }

    pub fn next(self: *WindowReader, output: []f32) !bool {
        try query_cancel.check();
        if (output.len != WINDOW_SAMPLES) return error.InvalidWindowSize;
        if (self.next_window >= self.window_count) return false;
        const start = audioWindowStart(self.destination_frames, self.window_count, self.next_window);
        const input: Input = .{ .file = .{ .handle = &self.file, .io = self.io, .size = self.size } };
        try renderWindow(self.allocator, input, self.parsed, self.destination_frames, start, output, self.coefficients);
        self.next_window += 1;
        return true;
    }
};

fn audioWindowCount(destination_frames: usize) usize {
    if (destination_frames <= WINDOW_SAMPLES) return 1;
    const natural = 1 + (destination_frames - WINDOW_SAMPLES + WINDOW_SAMPLES - 1) / WINDOW_SAMPLES;
    return @min(MAX_AUDIO_WINDOWS, natural);
}

fn audioWindowStart(destination_frames: usize, count: usize, index: usize) usize {
    if (destination_frames <= WINDOW_SAMPLES or count <= 1) return 0;
    return @intCast((@as(u128, index) * (destination_frames - WINDOW_SAMPLES)) / (count - 1));
}

fn renderWindow(allocator: std.mem.Allocator, input: Input, parsed: Parsed, destination_frames: usize, destination_start: usize, output: []f32, coefficients: ?[]const f32) !void {
    const is_short = destination_frames < WINDOW_SAMPLES;
    var source_start: usize = 0;
    var source_count = parsed.frames;
    if (!is_short and parsed.format.sample_rate != SAMPLE_RATE) {
        const first_base = sourceBase(destination_start, parsed.format.sample_rate, SAMPLE_RATE);
        const last_base = sourceBase(destination_start + WINDOW_SAMPLES - 1, parsed.format.sample_rate, SAMPLE_RATE);
        source_start = first_base -| FILTER_RADIUS;
        source_count = @min(parsed.frames, last_base + FILTER_RADIUS + 2) - source_start;
    } else if (!is_short and parsed.format.sample_rate == SAMPLE_RATE) {
        source_start = destination_start;
        source_count = WINDOW_SAMPLES;
    }
    const mono = try decodeMonoRange(allocator, input, parsed, source_start, source_count);
    defer allocator.free(mono);
    if (parsed.format.sample_rate == SAMPLE_RATE) {
        const repeated = if (is_short) (WINDOW_SAMPLES / mono.len) * mono.len else WINDOW_SAMPLES;
        for (output, 0..) |*sample, i| {
            if (i % 1024 == 0) try query_cancel.check();
            sample.* = int16CompatibilityRoundTrip(if (is_short and i >= repeated) 0 else mono[if (is_short) i % mono.len else i]);
        }
        try query_cancel.check();
        return;
    }
    const table = coefficients orelse return error.ResamplerFailure;
    const repeated = if (is_short) (WINDOW_SAMPLES / destination_frames) * destination_frames else WINDOW_SAMPLES;
    for (output, 0..) |*sample, i| {
        if (i % 1024 == 0) try query_cancel.check();
        if (is_short and i >= repeated) {
            sample.* = 0;
            continue;
        }
        const destination_index = if (is_short) i % destination_frames else destination_start + i;
        const value = resampleOne(mono, source_start, parsed.frames, destination_index, parsed.format.sample_rate, SAMPLE_RATE, is_short, table);
        if (!std.math.isFinite(value)) return error.NonFiniteSample;
        sample.* = int16CompatibilityRoundTrip(value);
    }
    try query_cancel.check();
}

/// Decode the complete WAV timeline to bounded 16 kHz mono samples for
/// fingerprints and waveforms. Source decoding is chunked, so high-rate or
/// multichannel input does not require a whole-file PCM allocation.
pub fn decodeFingerprintFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]f32 {
    try query_cancel.check();
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > MAX_WAV_BYTES) return error.FileTooLarge;
    const input: Input = .{ .file = .{ .handle = &file, .io = io, .size = stat.size } };
    const parsed = try parseAudio(input);
    if (parsed.format.encoding == .float) try validateFiniteFloatData(allocator, input, parsed);
    const max_source_frames = @as(u64, parsed.format.sample_rate) * MAX_FINGERPRINT_SECONDS;
    if (parsed.frames > max_source_frames) return error.FingerprintDurationLimit;
    const output_count_u64 = (@as(u64, parsed.frames) * FINGERPRINT_SAMPLE_RATE) / parsed.format.sample_rate;
    if (output_count_u64 == 0 or output_count_u64 > std.math.maxInt(usize)) return error.EmptyAudio;
    const output_count: usize = @intCast(output_count_u64);
    const output = try allocator.alloc(f32, output_count);
    errdefer allocator.free(output);

    const output_chunk: usize = 64 * 1024;
    const coefficients = if (parsed.format.sample_rate == FINGERPRINT_SAMPLE_RATE)
        null
    else
        try makePolyphaseTable(allocator, parsed.format.sample_rate, FINGERPRINT_SAMPLE_RATE);
    defer if (coefficients) |table| allocator.free(table);
    var output_start: usize = 0;
    while (output_start < output_count) {
        try query_cancel.check();
        const output_end = @min(output_count, output_start + output_chunk);
        const first_base = sourceBase(output_start, parsed.format.sample_rate, FINGERPRINT_SAMPLE_RATE);
        const last_base = sourceBase(output_end - 1, parsed.format.sample_rate, FINGERPRINT_SAMPLE_RATE);
        const source_start = first_base -| FILTER_RADIUS;
        const source_end = @min(parsed.frames, last_base + FILTER_RADIUS + 2);
        const mono = try decodeMonoRange(allocator, input, parsed, source_start, source_end - source_start);
        defer allocator.free(mono);
        for (output[output_start..output_end], output_start..) |*destination, output_index| {
            if (output_index % 1024 == 0) try query_cancel.check();
            const value = if (coefficients) |table|
                resampleOne(mono, source_start, parsed.frames, output_index, parsed.format.sample_rate, FINGERPRINT_SAMPLE_RATE, false, table)
            else
                mono[output_index - source_start];
            if (!std.math.isFinite(value)) return error.NonFiniteSample;
            destination.* = int16CompatibilityRoundTrip(value);
        }
        output_start = output_end;
    }
    try query_cancel.check();
    return output;
}

fn preprocessInput(allocator: std.mem.Allocator, input: Input) ![]f32 {
    const parsed = try parseAudio(input);
    if (parsed.format.encoding == .float) try validateFiniteFloatData(allocator, input, parsed);

    const dst_frames = try resampledFrameCount(parsed.frames, parsed.format.sample_rate, SAMPLE_RATE);
    const is_short = dst_frames < WINDOW_SAMPLES;
    const dst_start: usize = if (dst_frames > WINDOW_SAMPLES) (dst_frames - WINDOW_SAMPLES) / 2 else 0;

    var source_start: usize = 0;
    var source_count: usize = parsed.frames;
    if (!is_short and parsed.format.sample_rate != SAMPLE_RATE) {
        const first_base = sourceBase(dst_start, parsed.format.sample_rate, SAMPLE_RATE);
        const last_base = sourceBase(dst_start + WINDOW_SAMPLES - 1, parsed.format.sample_rate, SAMPLE_RATE);
        source_start = first_base -| FILTER_RADIUS;
        const wanted_end = @min(parsed.frames, last_base + FILTER_RADIUS + 2);
        source_count = wanted_end - source_start;
    } else if (!is_short and parsed.format.sample_rate == SAMPLE_RATE) {
        source_start = dst_start;
        source_count = WINDOW_SAMPLES;
    }

    const mono = try decodeMonoRange(allocator, input, parsed, source_start, source_count);
    defer allocator.free(mono);
    if (mono.len == 0) return error.EmptyAudio;

    const output = try allocator.alloc(f32, WINDOW_SAMPLES);
    errdefer allocator.free(output);

    if (parsed.format.sample_rate == SAMPLE_RATE) {
        const repeated_samples = if (is_short) (WINDOW_SAMPLES / mono.len) * mono.len else WINDOW_SAMPLES;
        for (output, 0..) |*sample, i| {
            if (i % 1024 == 0) try query_cancel.check();
            const value = if (is_short and i >= repeated_samples) 0 else mono[if (is_short) i % mono.len else i];
            sample.* = int16CompatibilityRoundTrip(value);
        }
        try query_cancel.check();
        return output;
    }

    const coefficients = try makePolyphaseTable(allocator, parsed.format.sample_rate, SAMPLE_RATE);
    defer allocator.free(coefficients);
    const repeated_samples = if (is_short) (WINDOW_SAMPLES / dst_frames) * dst_frames else WINDOW_SAMPLES;
    for (output, 0..) |*sample, i| {
        if (i % 1024 == 0) try query_cancel.check();
        if (is_short and i >= repeated_samples) {
            sample.* = 0;
            continue;
        }
        const dst_index = if (is_short) i % dst_frames else dst_start + i;
        const value = resampleOne(
            mono,
            source_start,
            parsed.frames,
            dst_index,
            parsed.format.sample_rate,
            SAMPLE_RATE,
            is_short,
            coefficients,
        );
        if (!std.math.isFinite(value)) return error.NonFiniteSample;
        sample.* = int16CompatibilityRoundTrip(value);
    }
    try query_cancel.check();
    return output;
}

fn parseAudio(input: Input) !Parsed {
    if (input.len() < 12) {
        if (input.len() >= 4) {
            var magic: [4]u8 = undefined;
            try input.readExact(0, &magic);
            if (std.mem.eql(u8, &magic, "RIFF") or std.mem.eql(u8, &magic, "RIFX")) return error.TruncatedWav;
            if (std.mem.eql(u8, &magic, "FORM")) return error.TruncatedAiff;
        }
        return error.TruncatedAudio;
    }
    var header: [12]u8 = undefined;
    try input.readExact(0, &header);
    if ((std.mem.eql(u8, header[0..4], "RIFF") or std.mem.eql(u8, header[0..4], "RIFX")) and std.mem.eql(u8, header[8..12], "WAVE")) return parseWav(input);
    if (std.mem.eql(u8, header[0..4], "FORM") and (std.mem.eql(u8, header[8..12], "AIFF") or std.mem.eql(u8, header[8..12], "AIFC"))) return parseAiff(input, std.mem.eql(u8, header[8..12], "AIFC"));
    return error.NotWav;
}

fn parseAiff(input: Input, compressed: bool) !Parsed {
    var header: [12]u8 = undefined;
    try input.readExact(0, &header);
    const form_end = @as(u64, readInt(u32, header[4..8], .big)) + 8;
    if (form_end > input.len()) return error.TruncatedAiff;
    var pos: u64 = 12;
    var format: ?Format = null;
    var sample_endian: std.builtin.Endian = .big;
    var declared_frames: ?usize = null;
    var data_offset: ?u64 = null;
    var data_size: u64 = 0;
    while (pos < form_end) {
        if (form_end - pos < 8) return error.MalformedAiff;
        var chunk_header: [8]u8 = undefined;
        try input.readExact(pos, &chunk_header);
        pos += 8;
        const chunk_size: u64 = readInt(u32, chunk_header[4..8], .big);
        const chunk_end = std.math.add(u64, pos, chunk_size) catch return error.MalformedAiff;
        const padded_end = std.math.add(u64, chunk_end, chunk_size & 1) catch return error.MalformedAiff;
        if (padded_end > form_end) return error.TruncatedAiff;
        if (std.mem.eql(u8, chunk_header[0..4], "COMM")) {
            if (format != null or chunk_size < 18) return error.MalformedAiff;
            var comm: [22]u8 = undefined;
            const amount: usize = @intCast(@min(chunk_size, comm.len));
            try input.readExact(pos, comm[0..amount]);
            const channels = readInt(u16, comm[0..2], .big);
            const frames_raw = readInt(u32, comm[2..6], .big);
            const bits = readInt(u16, comm[6..8], .big);
            const rate = try decodeExtendedRate(comm[8..18]);
            if (channels == 0 or channels > MAX_CHANNELS) return error.UnsupportedChannelCount;
            const bytes_per_sample: u16 = switch (bits) {
                8 => 1,
                16 => 2,
                24 => 3,
                32 => 4,
                else => return error.UnsupportedBitDepth,
            };
            if (compressed) {
                if (chunk_size < 22) return error.MalformedAiff;
                if (std.mem.eql(u8, comm[18..22], "sowt")) sample_endian = .little else if (!std.mem.eql(u8, comm[18..22], "NONE") and !std.mem.eql(u8, comm[18..22], "twos")) return error.UnsupportedEncoding;
            }
            const block_alignment = std.math.mul(u16, channels, bytes_per_sample) catch return error.MalformedAiff;
            format = .{ .encoding = .pcm, .channels = channels, .sample_rate = rate, .block_align = block_alignment, .container_bits = bits, .valid_bits = bits, .unsigned_pcm8 = false };
            declared_frames = frames_raw;
        } else if (std.mem.eql(u8, chunk_header[0..4], "SSND")) {
            if (data_offset != null or chunk_size < 8) return error.MalformedAiff;
            var ssnd: [8]u8 = undefined;
            try input.readExact(pos, &ssnd);
            const offset = readInt(u32, ssnd[0..4], .big);
            if (@as(u64, offset) > chunk_size - 8) return error.TruncatedAiff;
            data_offset = pos + 8 + offset;
            data_size = chunk_size - 8 - offset;
        }
        pos = padded_end;
    }
    const fmt = format orelse return error.MissingFormatChunk;
    const frames = declared_frames orelse return error.MissingFormatChunk;
    const offset = data_offset orelse return error.MissingDataChunk;
    const required = std.math.mul(u64, frames, fmt.block_align) catch return error.AudioTooLarge;
    if (frames == 0 or required == 0) return error.EmptyAudio;
    if (required > data_size) return error.TruncatedAiff;
    return .{ .endian = sample_endian, .format = fmt, .data_offset = offset, .data_size = required, .frames = frames };
}

fn decodeExtendedRate(bytes: []const u8) !u32 {
    const exponent_word = readInt(u16, bytes[0..2], .big);
    if ((exponent_word & 0x8000) != 0) return error.UnsupportedSampleRate;
    const exponent = exponent_word & 0x7fff;
    const mantissa = readInt(u64, bytes[2..10], .big);
    if (exponent == 0 or exponent == 0x7fff or mantissa == 0) return error.UnsupportedSampleRate;
    const value = std.math.ldexp(@as(f64, @floatFromInt(mantissa)), @as(i32, exponent) - 16383 - 63);
    if (!std.math.isFinite(value) or value < 1 or value > MAX_SAMPLE_RATE) return error.UnsupportedSampleRate;
    const rounded = @round(value);
    if (@abs(value - rounded) > 0.001) return error.UnsupportedSampleRate;
    return @intFromFloat(rounded);
}

fn parseWav(input: Input) !Parsed {
    if (input.len() < 12) return error.TruncatedWav;
    var header: [12]u8 = undefined;
    try input.readExact(0, &header);
    const endian: std.builtin.Endian = if (std.mem.eql(u8, header[0..4], "RIFF"))
        .little
    else if (std.mem.eql(u8, header[0..4], "RIFX"))
        .big
    else
        return error.NotWav;
    if (!std.mem.eql(u8, header[8..12], "WAVE")) return error.NotWav;

    const riff_size = readInt(u32, header[4..8], endian);
    if (riff_size < 4) return error.MalformedRiff;
    const riff_end = @as(u64, riff_size) + 8;
    if (riff_end > input.len()) return error.TruncatedWav;
    if (riff_end > MAX_WAV_BYTES) return error.FileTooLarge;

    var pos: u64 = 12;
    var format: ?Format = null;
    var data_offset: ?u64 = null;
    var data_size: u64 = 0;
    while (pos < riff_end) {
        if (riff_end - pos < 8) return error.MalformedChunk;
        var chunk_header: [8]u8 = undefined;
        try input.readExact(pos, &chunk_header);
        pos += 8;
        const chunk_size: u64 = readInt(u32, chunk_header[4..8], endian);
        if (chunk_size > MAX_CHUNK_BYTES) return error.ChunkTooLarge;
        const chunk_end = std.math.add(u64, pos, chunk_size) catch return error.MalformedChunk;
        if (chunk_end > riff_end) return error.TruncatedChunk;
        const padded_end = std.math.add(u64, chunk_end, chunk_size & 1) catch return error.MalformedChunk;
        if (padded_end > riff_end) return error.TruncatedChunk;

        if (std.mem.eql(u8, chunk_header[0..4], "fmt ")) {
            if (format != null) return error.DuplicateFormatChunk;
            format = try parseFormat(input, pos, chunk_size, endian);
        } else if (std.mem.eql(u8, chunk_header[0..4], "data")) {
            if (data_offset != null) return error.MultipleDataChunks;
            data_offset = pos;
            data_size = chunk_size;
        }
        pos = padded_end;
    }
    if (pos != riff_end) return error.MalformedRiff;

    const fmt = format orelse return error.MissingFormatChunk;
    const offset = data_offset orelse return error.MissingDataChunk;
    if (data_size == 0) return error.EmptyAudio;
    if (data_size % fmt.block_align != 0) return error.PartialAudioFrame;
    const frames_u64 = data_size / fmt.block_align;
    if (frames_u64 == 0) return error.EmptyAudio;
    if (frames_u64 > std.math.maxInt(usize)) return error.AudioTooLarge;
    return .{
        .endian = endian,
        .format = fmt,
        .data_offset = offset,
        .data_size = data_size,
        .frames = @intCast(frames_u64),
    };
}

fn parseFormat(input: Input, offset: u64, size: u64, endian: std.builtin.Endian) !Format {
    if (size < 16) return error.MalformedFormat;
    var bytes: [40]u8 = undefined;
    const read_len: usize = @intCast(@min(size, bytes.len));
    try input.readExact(offset, bytes[0..read_len]);

    const tag = readInt(u16, bytes[0..2], endian);
    const channels = readInt(u16, bytes[2..4], endian);
    const sample_rate = readInt(u32, bytes[4..8], endian);
    const byte_rate = readInt(u32, bytes[8..12], endian);
    const block_align = readInt(u16, bytes[12..14], endian);
    const container_bits = readInt(u16, bytes[14..16], endian);
    if (channels == 0 or channels > MAX_CHANNELS) return error.UnsupportedChannelCount;
    if (sample_rate == 0 or sample_rate > MAX_SAMPLE_RATE) return error.UnsupportedSampleRate;

    var encoding: Encoding = switch (tag) {
        1 => .pcm,
        3 => .float,
        0xfffe => undefined,
        else => return error.UnsupportedEncoding,
    };
    var valid_bits = container_bits;

    if (size > 16) {
        if (size < 18) return error.MalformedFormat;
        const cb_size = readInt(u16, bytes[16..18], endian);
        if (@as(u64, cb_size) + 18 > size) return error.MalformedFormat;
        if (tag == 0xfffe) {
            if (size < 40 or cb_size < 22) return error.MalformedExtensibleFormat;
            valid_bits = readInt(u16, bytes[18..20], endian);
            const guid = bytes[24..40];
            if (subFormatIs(guid, endian, 1)) {
                encoding = .pcm;
            } else if (subFormatIs(guid, endian, 3)) {
                encoding = .float;
            } else {
                return error.UnsupportedEncoding;
            }
        }
    } else if (tag == 0xfffe) {
        return error.MalformedExtensibleFormat;
    }

    const bytes_per_sample: u16 = switch (encoding) {
        .pcm => switch (container_bits) {
            8 => 1,
            16 => 2,
            24 => 3,
            32 => 4,
            else => return error.UnsupportedBitDepth,
        },
        .float => switch (container_bits) {
            32 => 4,
            64 => 8,
            else => return error.UnsupportedBitDepth,
        },
    };
    if (encoding == .float and valid_bits != container_bits) return error.UnsupportedValidBits;
    if (valid_bits == 0 or valid_bits > container_bits) return error.UnsupportedValidBits;
    if (encoding == .pcm and container_bits == 8 and valid_bits != 8) return error.UnsupportedValidBits;

    const expected_align = std.math.mul(u16, channels, bytes_per_sample) catch return error.MalformedFormat;
    if (block_align != expected_align) return error.MalformedFormat;
    const expected_rate = std.math.mul(u64, sample_rate, block_align) catch return error.MalformedFormat;
    if (byte_rate != expected_rate) return error.MalformedFormat;

    return .{
        .encoding = encoding,
        .channels = channels,
        .sample_rate = sample_rate,
        .block_align = block_align,
        .container_bits = container_bits,
        .valid_bits = valid_bits,
    };
}

fn subFormatIs(guid: []const u8, endian: std.builtin.Endian, tag: u32) bool {
    const tail = [_]u8{ 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 };
    return readInt(u32, guid[0..4], endian) == tag and std.mem.eql(u8, guid[4..16], &tail);
}

fn validateFiniteFloatData(allocator: std.mem.Allocator, input: Input, parsed: Parsed) !void {
    const scratch = try allocator.alloc(u8, SCRATCH_BYTES);
    defer allocator.free(scratch);
    const sample_bytes: usize = parsed.format.container_bits / 8;
    var offset = parsed.data_offset;
    var left = parsed.data_size;
    while (left > 0) {
        const amount: usize = @intCast(@min(left, scratch.len - (scratch.len % sample_bytes)));
        try input.readExact(offset, scratch[0..amount]);
        var pos: usize = 0;
        while (pos < amount) : (pos += sample_bytes) {
            if (pos % (1024 * sample_bytes) == 0) try query_cancel.check();
            const value = decodeFloat(scratch[pos .. pos + sample_bytes], parsed.endian, parsed.format.container_bits);
            if (!std.math.isFinite(value)) return error.NonFiniteSample;
        }
        offset += amount;
        left -= amount;
    }
}

fn decodeMonoRange(
    allocator: std.mem.Allocator,
    input: Input,
    parsed: Parsed,
    first_frame: usize,
    frame_count: usize,
) ![]f32 {
    if (first_frame > parsed.frames or frame_count > parsed.frames - first_frame) return error.InvalidFrameRange;
    const output = try allocator.alloc(f32, frame_count);
    errdefer allocator.free(output);
    if (frame_count == 0) return output;

    const frame_bytes: usize = parsed.format.block_align;
    const frames_per_block = @max(@as(usize, 1), SCRATCH_BYTES / frame_bytes);
    const scratch_size = frames_per_block * frame_bytes;
    const scratch = try allocator.alloc(u8, scratch_size);
    defer allocator.free(scratch);

    var done: usize = 0;
    while (done < frame_count) {
        const count = @min(frame_count - done, frames_per_block);
        const amount = count * frame_bytes;
        const frame_offset = std.math.mul(u64, first_frame + done, frame_bytes) catch return error.AudioTooLarge;
        const offset = std.math.add(u64, parsed.data_offset, frame_offset) catch return error.AudioTooLarge;
        try input.readExact(offset, scratch[0..amount]);
        for (0..count) |frame_index| {
            if (frame_index % 1024 == 0) try query_cancel.check();
            const frame = scratch[frame_index * frame_bytes ..][0..frame_bytes];
            var sum: f64 = 0;
            const sample_bytes: usize = parsed.format.container_bits / 8;
            for (0..parsed.format.channels) |channel| {
                const start: usize = @as(usize, channel) * sample_bytes;
                const value = decodeSample(frame[start .. start + sample_bytes], parsed.endian, parsed.format);
                if (!std.math.isFinite(value)) return error.NonFiniteSample;
                sum += value;
            }
            const mono: f32 = @floatCast(sum / @as(f64, @floatFromInt(parsed.format.channels)));
            if (!std.math.isFinite(mono)) return error.NonFiniteSample;
            output[done + frame_index] = mono;
        }
        done += count;
    }
    return output;
}

fn decodeSample(bytes: []const u8, endian: std.builtin.Endian, format: Format) f64 {
    if (format.encoding == .float) return decodeFloat(bytes, endian, format.container_bits);
    if (format.container_bits == 8) {
        return if (format.unsigned_pcm8)
            (@as(f64, @floatFromInt(bytes[0])) - 128.0) / 128.0
        else
            @as(f64, @floatFromInt(@as(i8, @bitCast(bytes[0])))) / 128.0;
    }

    const raw: i64 = switch (format.container_bits) {
        16 => readInt(i16, bytes[0..2], endian),
        24 => decodeI24(bytes[0..3], endian),
        32 => readInt(i32, bytes[0..4], endian),
        else => unreachable,
    };
    const unused: u6 = @intCast(format.container_bits - format.valid_bits);
    const value = raw >> unused;
    const scale = std.math.pow(f64, 2.0, @floatFromInt(format.valid_bits - 1));
    return @as(f64, @floatFromInt(value)) / scale;
}

fn decodeFloat(bytes: []const u8, endian: std.builtin.Endian, bits: u16) f64 {
    return switch (bits) {
        32 => @as(f64, @floatCast(@as(f32, @bitCast(readInt(u32, bytes[0..4], endian))))),
        64 => @as(f64, @bitCast(readInt(u64, bytes[0..8], endian))),
        else => unreachable,
    };
}

fn decodeI24(bytes: []const u8, endian: std.builtin.Endian) i32 {
    const unsigned: u32 = if (endian == .little)
        @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16)
    else
        (@as(u32, bytes[0]) << 16) | (@as(u32, bytes[1]) << 8) | @as(u32, bytes[2]);
    return if ((unsigned & 0x800000) != 0)
        @as(i32, @bitCast(unsigned | 0xff000000))
    else
        @intCast(unsigned);
}

fn resampledFrameCount(frames: usize, source_rate: u32, destination_rate: u32) !usize {
    const numerator = @as(u128, frames) * destination_rate + source_rate / 2;
    const result = @max(@as(u128, 1), numerator / source_rate);
    if (result > std.math.maxInt(usize)) return error.AudioTooLarge;
    return @intCast(result);
}

fn sourceBase(dst_index: usize, source_rate: u32, destination_rate: u32) usize {
    return @intCast((@as(u128, dst_index) * source_rate) / destination_rate);
}

fn makePolyphaseTable(allocator: std.mem.Allocator, source_rate: u32, destination_rate: u32) ![]f32 {
    const table = try allocator.alloc(f32, (FILTER_PHASES + 1) * FILTER_TAPS);
    errdefer allocator.free(table);
    const cutoff: f64 = @min(1.0, @as(f64, @floatFromInt(destination_rate)) / @as(f64, @floatFromInt(source_rate))) * 0.94;
    for (0..FILTER_PHASES + 1) |phase| {
        if (phase % 32 == 0) try query_cancel.check();
        const fraction = @as(f64, @floatFromInt(phase)) / FILTER_PHASES;
        var sum: f64 = 0;
        for (0..FILTER_TAPS) |tap| {
            const relative_index: isize = @as(isize, @intCast(tap)) - @as(isize, FILTER_RADIUS) + 1;
            const distance = @as(f64, @floatFromInt(relative_index)) - fraction;
            const x = std.math.pi * cutoff * distance;
            const sinc = if (@abs(x) < 1.0e-12) 1.0 else @sin(x) / x;
            const window_x = std.math.pi * distance / FILTER_RADIUS;
            const window = 0.42 + 0.5 * @cos(window_x) + 0.08 * @cos(2.0 * window_x);
            const weight = cutoff * sinc * window;
            table[phase * FILTER_TAPS + tap] = @floatCast(weight);
            sum += weight;
        }
        if (!std.math.isFinite(sum) or @abs(sum) < 1.0e-12) return error.ResamplerFailure;
        for (table[phase * FILTER_TAPS ..][0..FILTER_TAPS]) |*weight| {
            weight.* = @floatCast(@as(f64, weight.*) / sum);
        }
    }
    return table;
}

fn resampleOne(
    source: []const f32,
    source_start: usize,
    total_frames: usize,
    dst_index: usize,
    source_rate: u32,
    destination_rate: u32,
    wrap: bool,
    coefficients: []const f32,
) f32 {
    const numerator = @as(u128, dst_index) * source_rate;
    const base: isize = @intCast(numerator / destination_rate);
    const remainder: u64 = @intCast(numerator % destination_rate);
    const phase: usize = @intCast((remainder * FILTER_PHASES + destination_rate / 2) / destination_rate);
    const weights = coefficients[phase * FILTER_TAPS ..][0..FILTER_TAPS];
    var sum: f64 = 0;
    for (weights, 0..) |weight, tap| {
        const relative: isize = @as(isize, @intCast(tap)) - @as(isize, FILTER_RADIUS) + 1;
        var index = base + relative;
        if (wrap) {
            const count: isize = @intCast(total_frames);
            index = @mod(index, count);
        } else {
            index = std.math.clamp(index, 0, @as(isize, @intCast(total_frames - 1)));
        }
        const local: usize = @intCast(index - @as(isize, @intCast(source_start)));
        sum += @as(f64, source[local]) * weight;
    }
    return @floatCast(sum);
}

fn int16CompatibilityRoundTrip(value: f32) f32 {
    const clamped = std.math.clamp(value, -1.0, 1.0);
    const quantized: i16 = @intFromFloat(@trunc(clamped * 32767.0));
    return @as(f32, @floatFromInt(quantized)) / 32767.0;
}

fn readInt(comptime T: type, bytes: []const u8, endian: std.builtin.Endian) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], endian);
}

const TestWavConfig = struct {
    encoding: Encoding,
    bits: u16,
    channels: u16 = 1,
    rate: u32 = SAMPLE_RATE,
    endian: std.builtin.Endian = .little,
    extensible: bool = false,
    odd_junk: bool = false,
};

fn makeTestWav(allocator: std.mem.Allocator, config: TestWavConfig, samples: []const f64) ![]u8 {
    if (samples.len % config.channels != 0) return error.InvalidTestSamples;
    const sample_bytes: usize = config.bits / 8;
    const data_size = samples.len * sample_bytes;
    const fmt_size: usize = if (config.extensible) 40 else 16;
    const junk_total: usize = if (config.odd_junk) 12 else 0; // 8 + 3 + one pad byte
    const total = 12 + junk_total + 8 + fmt_size + 8 + data_size + (data_size & 1);
    const wav = try allocator.alloc(u8, total);
    errdefer allocator.free(wav);
    @memset(wav, 0);
    @memcpy(wav[0..4], if (config.endian == .little) "RIFF" else "RIFX");
    putInt(u32, wav[4..8], @intCast(total - 8), config.endian);
    @memcpy(wav[8..12], "WAVE");
    var pos: usize = 12;
    if (config.odd_junk) {
        @memcpy(wav[pos .. pos + 4], "JUNK");
        putInt(u32, wav[pos + 4 .. pos + 8], 3, config.endian);
        @memcpy(wav[pos + 8 .. pos + 11], "odd");
        pos += 12;
    }
    @memcpy(wav[pos .. pos + 4], "fmt ");
    putInt(u32, wav[pos + 4 .. pos + 8], @intCast(fmt_size), config.endian);
    const fmt = wav[pos + 8 ..][0..fmt_size];
    const tag: u16 = if (config.extensible) 0xfffe else if (config.encoding == .pcm) 1 else 3;
    const block_align: u16 = @intCast(config.channels * sample_bytes);
    putInt(u16, fmt[0..2], tag, config.endian);
    putInt(u16, fmt[2..4], config.channels, config.endian);
    putInt(u32, fmt[4..8], config.rate, config.endian);
    putInt(u32, fmt[8..12], config.rate * block_align, config.endian);
    putInt(u16, fmt[12..14], block_align, config.endian);
    putInt(u16, fmt[14..16], config.bits, config.endian);
    if (config.extensible) {
        putInt(u16, fmt[16..18], 22, config.endian);
        putInt(u16, fmt[18..20], config.bits, config.endian);
        putInt(u32, fmt[20..24], 0, config.endian);
        putInt(u32, fmt[24..28], if (config.encoding == .pcm) 1 else 3, config.endian);
        @memcpy(fmt[28..40], &[_]u8{ 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 });
    }
    pos += 8 + fmt_size;
    @memcpy(wav[pos .. pos + 4], "data");
    putInt(u32, wav[pos + 4 .. pos + 8], @intCast(data_size), config.endian);
    pos += 8;
    for (samples, 0..) |sample, i| {
        encodeTestSample(wav[pos + i * sample_bytes ..][0..sample_bytes], sample, config);
    }
    return wav;
}

fn encodeTestSample(dest: []u8, value: f64, config: TestWavConfig) void {
    if (config.encoding == .float) {
        if (config.bits == 32) {
            putInt(u32, dest, @bitCast(@as(f32, @floatCast(value))), config.endian);
        } else {
            putInt(u64, dest, @bitCast(value), config.endian);
        }
        return;
    }
    if (config.bits == 8) {
        const scaled = std.math.clamp(value, -1.0, 127.0 / 128.0) * 128.0 + 128.0;
        dest[0] = @intFromFloat(@round(scaled));
        return;
    }
    const scale = std.math.pow(f64, 2.0, @floatFromInt(config.bits - 1));
    const maximum = (scale - 1.0) / scale;
    const integer: i64 = @intFromFloat(@round(std.math.clamp(value, -1.0, maximum) * scale));
    switch (config.bits) {
        16 => putInt(i16, dest, @intCast(integer), config.endian),
        24 => {
            const raw: u24 = @bitCast(@as(i24, @intCast(integer)));
            if (config.endian == .little) {
                dest[0] = @truncate(raw);
                dest[1] = @truncate(raw >> 8);
                dest[2] = @truncate(raw >> 16);
            } else {
                dest[0] = @truncate(raw >> 16);
                dest[1] = @truncate(raw >> 8);
                dest[2] = @truncate(raw);
            }
        },
        32 => putInt(i32, dest, @intCast(integer), config.endian),
        else => unreachable,
    }
}

fn putInt(comptime T: type, dest: []u8, value: T, endian: std.builtin.Endian) void {
    std.mem.writeInt(T, dest[0..@sizeOf(T)], value, endian);
}

fn expectNear(expected: f32, actual: f32, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

test "PCM, IEEE float, extensible, and RIFX encodings preprocess deterministically" {
    const allocator = std.testing.allocator;
    const configs = [_]TestWavConfig{
        .{ .encoding = .pcm, .bits = 8 },
        .{ .encoding = .pcm, .bits = 16 },
        .{ .encoding = .pcm, .bits = 24 },
        .{ .encoding = .pcm, .bits = 32 },
        .{ .encoding = .float, .bits = 32 },
        .{ .encoding = .float, .bits = 64 },
        .{ .encoding = .pcm, .bits = 24, .extensible = true },
        .{ .encoding = .float, .bits = 32, .extensible = true },
        .{ .encoding = .pcm, .bits = 16, .endian = .big },
        .{ .encoding = .float, .bits = 64, .endian = .big },
    };
    for (configs) |config| {
        const wav = try makeTestWav(allocator, config, &.{ 0.25, -0.5 });
        defer allocator.free(wav);
        const output = try preprocessWavBytes(allocator, wav);
        defer allocator.free(output);
        try std.testing.expectEqual(@as(usize, WINDOW_SAMPLES), output.len);
        try expectNear(0.25, output[0], 0.008);
        try expectNear(-0.5, output[1], 0.0001);
        try std.testing.expectEqual(output[0], output[2]);
    }
}

test "channel averaging and odd chunk and data padding are handled" {
    const allocator = std.testing.allocator;
    const stereo = try makeTestWav(allocator, .{ .encoding = .float, .bits = 32, .channels = 2 }, &.{ 0.75, -0.25, -0.5, 0.25 });
    defer allocator.free(stereo);
    const downmixed = try preprocessWavBytes(allocator, stereo);
    defer allocator.free(downmixed);
    try expectNear(0.25, downmixed[0], 0.0001);
    try expectNear(-0.125, downmixed[1], 0.0001);

    const odd = try makeTestWav(allocator, .{ .encoding = .pcm, .bits = 8, .odd_junk = true }, &.{ 0.0, 0.25, -0.5 });
    defer allocator.free(odd);
    const padded = try preprocessWavBytes(allocator, odd);
    defer allocator.free(padded);
    try expectNear(0.0, padded[0], 0.0001);
    try expectNear(0.25, padded[1], 0.008);
    try expectNear(-0.5, padded[2], 0.0001);
}

test "malformed and truncated WAV structures are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.TruncatedWav, preprocessWavBytes(allocator, "RIFF"));
    try std.testing.expectError(error.NotWav, preprocessWavBytes(allocator, "NOPE\x04\x00\x00\x00WAVE"));

    const good = try makeTestWav(allocator, .{ .encoding = .pcm, .bits = 16 }, &.{0.0});
    defer allocator.free(good);
    const truncated = try allocator.dupe(u8, good);
    defer allocator.free(truncated);
    putInt(u32, truncated[4..8], @intCast(truncated.len + 100), .little);
    try std.testing.expectError(error.TruncatedWav, preprocessWavBytes(allocator, truncated));

    const bad_data = try allocator.dupe(u8, good);
    defer allocator.free(bad_data);
    putInt(u32, bad_data[40..44], 1, .little);
    try std.testing.expectError(error.PartialAudioFrame, preprocessWavBytes(allocator, bad_data));

    const oversized_chunk = try allocator.dupe(u8, good);
    defer allocator.free(oversized_chunk);
    putInt(u32, oversized_chunk[40..44], 100, .little);
    try std.testing.expectError(error.TruncatedChunk, preprocessWavBytes(allocator, oversized_chunk));

    const odd = try makeTestWav(allocator, .{ .encoding = .pcm, .bits = 8 }, &.{0.0});
    defer allocator.free(odd);
    try std.testing.expectError(error.TruncatedWav, preprocessWavBytes(allocator, odd[0 .. odd.len - 1]));
}

test "nonfinite and zero-frame audio are rejected" {
    const allocator = std.testing.allocator;
    const wav = try makeTestWav(allocator, .{ .encoding = .float, .bits = 32 }, &.{ 0.0, std.math.nan(f64), 0.5 });
    defer allocator.free(wav);
    try std.testing.expectError(error.NonFiniteSample, preprocessWavBytes(allocator, wav));

    const empty = try makeTestWav(allocator, .{ .encoding = .pcm, .bits = 16 }, &.{});
    defer allocator.free(empty);
    try std.testing.expectError(error.EmptyAudio, preprocessWavBytes(allocator, empty));
}

test "file API streams the same preprocessing result" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const wav = try makeTestWav(allocator, .{ .encoding = .pcm, .bits = 16 }, &.{0.25});
    defer allocator.free(wav);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.wav", .data = wav });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/sample.wav", .{root});
    defer allocator.free(path);
    const output = try preprocessFile(allocator, io, path);
    defer allocator.free(output);
    try expectNear(0.25, output[0], 0.0001);
    try std.testing.expectEqual(@as(usize, WINDOW_SAMPLES), output.len);
}

test "short input repeats whole waveforms then zero pads the remainder" {
    const allocator = std.testing.allocator;
    const wav = try makeTestWav(allocator, .{ .encoding = .float, .bits = 32 }, &.{ 0.125, -0.25, 0.5 });
    defer allocator.free(wav);
    const output = try preprocessWavBytes(allocator, wav);
    defer allocator.free(output);
    for (0..12) |i| try expectNear(@as([3]f32, .{ 0.125, -0.25, 0.5 })[i % 3], output[i], 0.0001);
    // 480000 is divisible by three, so no zero tail is needed here.
    try std.testing.expectEqual(output[WINDOW_SAMPLES - 1], output[(WINDOW_SAMPLES - 1) % 3]);

    const four = try makeTestWav(allocator, .{ .encoding = .float, .bits = 32 }, &.{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7 });
    defer allocator.free(four);
    const padded = try preprocessWavBytes(allocator, four);
    defer allocator.free(padded);
    try std.testing.expectEqual(@as(f32, 0), padded[WINDOW_SAMPLES - 1]);
}

test "long input uses a deterministic center crop" {
    const allocator = std.testing.allocator;
    const count = WINDOW_SAMPLES + 4;
    const samples = try allocator.alloc(f64, count);
    defer allocator.free(samples);
    @memset(samples, 0);
    samples[1] = -0.75;
    samples[2] = 0.25;
    samples[count - 3] = 0.5;
    const wav = try makeTestWav(allocator, .{ .encoding = .float, .bits = 32 }, samples);
    defer allocator.free(wav);
    const first = try preprocessWavBytes(allocator, wav);
    defer allocator.free(first);
    const second = try preprocessWavBytes(allocator, wav);
    defer allocator.free(second);
    try expectNear(0.25, first[0], 0.0001);
    try expectNear(0.5, first[WINDOW_SAMPLES - 1], 0.0001);
    try std.testing.expectEqualSlices(f32, first, second);
}

test "44.1 kHz windowed-sinc resampling preserves sine and impulse timing" {
    const allocator = std.testing.allocator;
    const rate: u32 = 44_100;
    const sine_frames: usize = 4410;
    const sine = try allocator.alloc(f64, sine_frames);
    defer allocator.free(sine);
    for (sine, 0..) |*sample, i| {
        sample.* = 0.7 * @sin(2.0 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / rate);
    }
    const sine_wav = try makeTestWav(allocator, .{ .encoding = .float, .bits = 32, .rate = rate }, sine);
    defer allocator.free(sine_wav);
    const sine_out = try preprocessWavBytes(allocator, sine_wav);
    defer allocator.free(sine_out);
    var squared: f64 = 0;
    for (sine_out[100..4900]) |sample| squared += @as(f64, sample) * sample;
    const rms = @sqrt(squared / 4800.0);
    try std.testing.expect(rms > 0.47 and rms < 0.52);
    try expectNear(0.7, sine_out[12], 0.03); // quarter-cycle at 48 kHz

    const impulse = try allocator.alloc(f64, 441);
    defer allocator.free(impulse);
    @memset(impulse, 0);
    impulse[100] = 1.0;
    const impulse_wav = try makeTestWav(allocator, .{ .encoding = .float, .bits = 64, .rate = rate }, impulse);
    defer allocator.free(impulse_wav);
    const impulse_out = try preprocessWavBytes(allocator, impulse_wav);
    defer allocator.free(impulse_out);
    var peak_index: usize = 0;
    var peak: f32 = 0;
    for (impulse_out[0..400], 0..) |sample, i| {
        if (@abs(sample) > peak) {
            peak = @abs(sample);
            peak_index = i;
        }
    }
    try std.testing.expect(peak_index >= 108 and peak_index <= 110);
    try std.testing.expect(peak > 0.85 and peak <= 1.0);
}
