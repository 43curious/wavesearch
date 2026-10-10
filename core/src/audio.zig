const std = @import("std");
const clap_audio = @import("clap_audio.zig");
const audio_file = @import("audio_file.zig");

pub fn waveform(path: []const u8, out: [*]f32, num_points: usize) !void {
    if (num_points == 0) return;
    if (clap_audio.isBuiltInAudioPath(path)) {
        try waveformFromWav(path, out, num_points);
    } else {
        placeholderWaveform(out, num_points);
    }
}

pub fn appendMetadataText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    return appendMetadataTextIo(allocator, out, threaded.io(), path);
}

pub fn appendMetadataTextIo(allocator: std.mem.Allocator, out: *std.ArrayList(u8), io: std.Io, path: []const u8) !void {
    return appendMetadataTextIoLimit(allocator, out, io, path, 2 * 1024 * 1024);
}

pub fn appendMetadataTextIoLimit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), io: std.Io, path: []const u8, max_read: usize) !void {
    const ext = std.fs.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(ext, ".wav")) return;

    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    return appendMetadataTextFromFileLimit(allocator, out, .{ .handle = &file, .io = io, .size = stat.size }, max_read);
}

pub fn appendMetadataTextFromFileLimit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), reader: audio_file.Reader, max_read: usize) !void {
    const read_size: usize = @intCast(@min(reader.size, max_read));
    if (read_size < 44) return;
    if (read_size <= reader.prefix.len) return appendWavMetadataFromBytes(allocator, out, reader.prefix[0..read_size]);

    const data = try std.heap.c_allocator.alloc(u8, read_size);
    defer std.heap.c_allocator.free(data);
    const bytes_read = try reader.readAll(data, 0);
    try appendWavMetadataFromBytes(allocator, out, data[0..bytes_read]);
}

pub fn appendMetadataTextIoSparse(allocator: std.mem.Allocator, out: *std.ArrayList(u8), io: std.Io, path: []const u8, byte_budget: usize) !void {
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".wav") or byte_budget == 0) return;
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return appendMetadataTextFromFileSparse(allocator, out, .{ .handle = &file, .io = io, .size = stat.size }, byte_budget);
}

pub fn appendMetadataTextFromFileSparse(allocator: std.mem.Allocator, out: *std.ArrayList(u8), reader: audio_file.Reader, byte_budget: usize) !void {
    if (reader.size < 12 or byte_budget == 0) return;
    var riff: [12]u8 = undefined;
    if (try reader.readAll(&riff, 0) != riff.len) return error.TruncatedMetadata;
    if (!std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) return;

    var remaining = byte_budget;
    var position: u64 = 12;
    var chunks: usize = 0;
    while (position <= reader.size and reader.size - position >= 8 and chunks < 65_536) : (chunks += 1) {
        var header: [8]u8 = undefined;
        if (try reader.readAll(&header, position) != header.len) return error.TruncatedMetadata;
        const chunk_size: u64 = std.mem.readInt(u32, header[4..8], .little);
        const payload = position + 8;
        const padded_size = chunk_size + (chunk_size & 1);
        const next = std.math.add(u64, payload, padded_size) catch return error.MalformedMetadata;
        if (next > reader.size) return error.TruncatedMetadata;
        const recognized = std.mem.eql(u8, header[0..4], "bext") or
            std.mem.eql(u8, header[0..4], "iXML") or
            std.mem.eql(u8, header[0..4], "_PMX") or
            std.mem.eql(u8, header[0..4], "LIST");
        if (recognized and remaining > 0 and chunk_size > 0) {
            const wanted: usize = @intCast(@min(chunk_size, remaining));
            const chunk = try allocator.alloc(u8, wanted);
            defer allocator.free(chunk);
            if (try reader.readAll(chunk, payload) != wanted) return error.TruncatedMetadata;
            if (std.mem.eql(u8, header[0..4], "bext")) {
                try appendCleanText(allocator, out, chunk[0..@min(chunk.len, 602)]);
            } else if (std.mem.eql(u8, header[0..4], "LIST")) {
                try appendListInfoText(allocator, out, chunk);
            } else {
                try appendCleanText(allocator, out, chunk);
            }
            remaining -= wanted;
        }
        position = next;
    }
}

fn appendWavMetadataFromBytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), data: []const u8) !void {
    if (data.len < 44) return;
    if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return;

    var pos: usize = 12;
    while (pos + 8 <= data.len) {
        const chunk_id = data[pos .. pos + 4];
        const chunk_size: usize = @intCast(std.mem.readInt(u32, data[pos + 4 .. pos + 8][0..4], .little));
        pos += 8;
        if (pos > data.len) break;
        const end = @min(pos + chunk_size, data.len);
        const chunk = data[pos..end];

        if (std.mem.eql(u8, chunk_id, "bext")) {
            // BWF description/originator/originator ref fields are fixed-width
            // ASCII-ish text near the start of the chunk.
            try appendCleanText(allocator, out, chunk[0..@min(chunk.len, 602)]);
        } else if (std.mem.eql(u8, chunk_id, "iXML") or std.mem.eql(u8, chunk_id, "_PMX")) {
            try appendCleanText(allocator, out, chunk);
        } else if (std.mem.eql(u8, chunk_id, "LIST")) {
            try appendListInfoText(allocator, out, chunk);
        }

        pos += chunk_size + (chunk_size & 1);
    }
}

fn appendListInfoText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), chunk: []const u8) !void {
    if (chunk.len < 4) return;
    if (!std.mem.eql(u8, chunk[0..4], "INFO")) return;
    var pos: usize = 4;
    while (pos + 8 <= chunk.len) {
        const size: usize = @intCast(std.mem.readInt(u32, chunk[pos + 4 .. pos + 8][0..4], .little));
        pos += 8;
        const end = @min(pos + size, chunk.len);
        try appendCleanText(allocator, out, chunk[pos..end]);
        pos += size + (size & 1);
    }
}

fn appendCleanText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    var last_space = true;
    for (bytes) |b| {
        if (b == 0) continue;
        const ch = std.ascii.toLower(b);
        const keep = std.ascii.isAlphanumeric(ch);
        if (keep) {
            if (out.items.len > 0 and last_space) try out.append(allocator, ' ');
            try out.append(allocator, ch);
            last_space = false;
        } else if (!last_space) {
            last_space = true;
        }
    }
}

pub fn durationMs(path: []const u8) !i32 {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    return durationMsIo(threaded.io(), path);
}

pub fn durationMsIo(io: std.Io, path: []const u8) !i32 {
    if (!clap_audio.isBuiltInAudioPath(path)) return 0;
    return clap_audio.durationMsFile(io, path);
}

pub fn durationMsFromFile(reader: audio_file.Reader, path: []const u8) !i32 {
    if (!clap_audio.isBuiltInAudioPath(path)) return 0;
    return clap_audio.durationMsFromFile(reader);
}

fn durationMsFromWavBytes(data: []const u8) !i32 {
    if (data.len < 44) return error.TooShort;
    if (!std.mem.eql(u8, data[0..4], "RIFF")) return error.NotWav;
    if (!std.mem.eql(u8, data[8..12], "WAVE")) return error.NotWav;

    var byte_rate: u32 = 0;
    var data_size: u32 = 0;
    var pos: usize = 12;

    while (pos + 8 <= data.len) {
        const chunk_id = data[pos .. pos + 4];
        const chunk_size = std.mem.readInt(u32, data[pos + 4 .. pos + 8][0..4], .little);
        pos += 8;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (pos + 16 > data.len) break;
            byte_rate = std.mem.readInt(u32, data[pos + 8 .. pos + 12][0..4], .little);
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_size = chunk_size;
            break;
        }

        pos += chunk_size + (chunk_size & 1);
    }

    if (byte_rate == 0 or data_size == 0) return 0;
    const ms = (@as(u64, data_size) * 1000) / @as(u64, byte_rate);
    return @intCast(@min(ms, @as(u64, @intCast(std.math.maxInt(i32)))));
}

fn waveformFromWav(path: []const u8, out: [*]f32, num_points: usize) !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const samples = try clap_audio.decodeFingerprintFile(std.heap.c_allocator, threaded.io(), path);
    defer std.heap.c_allocator.free(samples);
    for (0..num_points) |point| {
        const first = point * samples.len / num_points;
        const end = (point + 1) * samples.len / num_points;
        if (end <= first) {
            out[point] = @abs(samples[@min(first, samples.len - 1)]);
            continue;
        }
        var energy: f64 = 0;
        for (samples[first..end]) |sample| energy += @as(f64, sample) * sample;
        out[point] = @floatCast(@sqrt(energy / @as(f64, @floatFromInt(end - first))));
    }
}

// Retained temporarily as a parser reference while all callers use the shared,
// validated decoder above.
fn legacyWaveformFromWav(path: []const u8, out: [*]f32, num_points: usize) !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const file_size = (try file.stat(io)).size;
    if (file_size < 44) return error.TooShort;

    // Only the RIFF headers are buffered. Sample data is streamed below in
    // bounded blocks, so long recordings cannot allocate hundreds of MiB.
    const MAX_HEADER_READ: usize = 2 * 1024 * 1024;
    const read_size: usize = @intCast(@min(file_size, MAX_HEADER_READ));
    const data = try std.heap.c_allocator.alloc(u8, read_size);
    defer std.heap.c_allocator.free(data);

    const bytes_read = try file.readPositionalAll(io, data, 0);
    if (bytes_read < 44) return error.TooShort;

    if (!std.mem.eql(u8, data[0..4], "RIFF")) return error.NotWav;
    if (!std.mem.eql(u8, data[8..12], "WAVE")) return error.NotWav;

    var bits_per_sample: u16 = 0;
    var num_channels: u16 = 1;
    var data_start: usize = 0;
    var data_size: usize = 0;
    var pos: usize = 12;

    while (pos + 8 <= bytes_read) {
        const chunk_id = data[pos .. pos + 4];
        const chunk_size = std.mem.readInt(u32, data[pos + 4 .. pos + 8][0..4], .little);
        pos += 8;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (pos + 16 > bytes_read) break;
            num_channels = std.mem.readInt(u16, data[pos + 2 .. pos + 4][0..2], .little);
            bits_per_sample = std.mem.readInt(u16, data[pos + 14 .. pos + 16][0..2], .little);
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_start = pos;
            data_size = @intCast(@min(@as(u64, chunk_size), file_size -| pos));
            break;
        }

        pos += chunk_size + (chunk_size & 1);
    }

    if (data_start == 0 or bits_per_sample == 0 or num_channels == 0) return error.BadFormat;

    const bytes_per_sample = bits_per_sample / 8;
    if (bytes_per_sample == 0) return error.BadFormat;

    const bytes_per_frame = @as(usize, bytes_per_sample) * @as(usize, num_channels);
    if (bytes_per_frame == 0) return error.BadFormat;

    const total_frames = data_size / bytes_per_frame;
    if (total_frames == 0) return error.NoSamples;

    const frames_per_point = @as(f64, @floatFromInt(total_frames)) / @as(f64, @floatFromInt(num_points));

    var rms_acc: f64 = 0;
    var rms_count: u64 = 0;
    var point_idx: usize = 0;

    const block_frames = @max(@as(usize, 1), (64 * 1024) / bytes_per_frame);
    const block = try std.heap.c_allocator.alloc(u8, block_frames * bytes_per_frame);
    defer std.heap.c_allocator.free(block);
    var first_frame: usize = 0;
    while (first_frame < total_frames and point_idx < num_points) {
        const wanted_frames = @min(block_frames, total_frames - first_frame);
        const wanted_bytes = wanted_frames * bytes_per_frame;
        const got = try file.readPositionalAll(io, block[0..wanted_bytes], data_start + first_frame * bytes_per_frame);
        const got_frames = got / bytes_per_frame;
        if (got_frames == 0) break;
        for (0..got_frames) |local_frame| {
            const frame = first_frame + local_frame;
            const frame_offset = local_frame * bytes_per_frame;
            const s = block[frame_offset .. frame_offset + bytes_per_sample];
            const sample: f32 = switch (bits_per_sample) {
                8 => (@as(f32, @floatFromInt(s[0])) - 128.0) / 128.0,
                16 => @as(f32, @floatFromInt(std.mem.readInt(i16, s[0..2], .little))) / 32768.0,
                24 => blk: {
                    const raw = @as(i32, s[0]) | (@as(i32, s[1]) << 8) | (@as(i32, s[2]) << 16);
                    const value: i32 = if (raw & 0x800000 != 0) raw | @as(i32, @bitCast(@as(u32, 0xFF000000))) else raw;
                    break :blk @as(f32, @floatFromInt(value)) / 8388608.0;
                },
                32 => @as(f32, @floatFromInt(std.mem.readInt(i32, s[0..4], .little))) / 2147483648.0,
                else => 0.0,
            };
            rms_acc += @as(f64, sample) * @as(f64, sample);
            rms_count += 1;
            const next_boundary = @as(f64, @floatFromInt(point_idx + 1)) * frames_per_point;
            if (@as(f64, @floatFromInt(frame + 1)) >= next_boundary) {
                out[point_idx] = if (rms_count > 0) @floatCast(std.math.sqrt(rms_acc / @as(f64, @floatFromInt(rms_count)))) else 0.0;
                point_idx += 1;
                rms_acc = 0;
                rms_count = 0;
                if (point_idx == num_points) break;
            }
        }
        first_frame += got_frames;
        if (got < wanted_bytes) break;
    }

    while (point_idx < num_points) : (point_idx += 1) out[point_idx] = 0;
}

fn placeholderWaveform(out: [*]f32, num_points: usize) void {
    for (0..num_points) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_points));
        const v = @abs(std.math.sin(t * 12.0) * 0.6 +
            std.math.sin(t * 7.3) * 0.3 +
            std.math.sin(t * 23.0) * 0.1);
        out[i] = v;
    }
}
