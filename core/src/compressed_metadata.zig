const std = @import("std");
const Reader = @import("audio_file.zig").Reader;
const wav = @import("wav_metadata.zig");
const query = @import("query.zig");

const MAX_FIELDS = 4096;
const MAX_FIELD = 64 * 1024;

/// Metadata only: no decoder, artwork, source writes or unbounded tag allocation.
pub fn read(allocator: std.mem.Allocator, all: *std.ArrayList(u8), description: *std.ArrayList(u8), reader: Reader, budget: usize) !bool {
    var state = State{ .allocator = allocator, .all = all, .description = description, .reader = reader, .remaining = budget };
    var header: [10]u8 = @splat(0);
    const n = try reader.readAll(&header, 0);
    if (n >= 10 and std.mem.eql(u8, header[0..3], "ID3")) {
        try state.id3(header);
    } else if (n >= 4 and std.mem.eql(u8, header[0..4], "fLaC")) {
        try state.flac();
    } else if (n >= 4 and std.mem.eql(u8, header[0..4], "OggS")) {
        try state.ogg();
    }
    return state.limited;
}

const State = struct {
    allocator: std.mem.Allocator,
    all: *std.ArrayList(u8),
    description: *std.ArrayList(u8),
    reader: Reader,
    remaining: usize,
    limited: bool = false,

    fn bytes(self: *State, offset: u64, size: usize) !?[]u8 {
        if (size > self.remaining or size > MAX_FIELD) {
            self.limited = true;
            return null;
        }
        const out = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(out);
        if (try self.reader.readAll(out, offset) != size) return error.TruncatedMetadata;
        self.remaining -= size;
        return out;
    }

    fn value(self: *State, key: []const u8, value_: []const u8) !void {
        if (!textField(key)) return;
        try wav.clean(self.allocator, self.all, value_);
        if (descriptive(key)) try wav.clean(self.allocator, self.description, value_);
    }

    fn id3(self: *State, header: [10]u8) !void {
        const version = header[3];
        if (version < 2 or version > 4 or header[4] == 255) return error.MalformedMetadata;
        const size = try synchsafe(header[6..10]);
        const end: u64 = @as(u64, size) + 10;
        if (end > self.reader.size) return error.TruncatedMetadata;
        // v2.2 compression and v2.2/v2.3 whole-tag unsynchronisation need a
        // different logical cursor. Keep filenames usable and expose the limit.
        if ((version < 4 and header[5] & 0x80 != 0) or (version == 2 and header[5] & 0x40 != 0)) {
            self.limited = true;
            return;
        }
        var pos: u64 = 10;
        if (version >= 3 and header[5] & 0x40 != 0) {
            var ext: [4]u8 = undefined;
            if (end - pos < 4 or try self.reader.readAll(&ext, pos) != 4) return error.TruncatedMetadata;
            const len: u64 = if (version == 4) try synchsafe(&ext) else @as(u64, std.mem.readInt(u32, &ext, .big)) + 4;
            if (len < (if (version == 4) @as(u64, 6) else 10) or len > end - pos) return error.MalformedMetadata;
            pos += len;
        }
        var count: usize = 0;
        const header_size: usize = if (version == 2) 6 else 10;
        while (pos < end and count < MAX_FIELDS) : (count += 1) {
            try query.check();
            var frame: [10]u8 = @splat(0);
            if (end - pos < header_size) {
                self.limited = true;
                break;
            }
            if (try self.reader.readAll(frame[0..header_size], pos) != header_size) return error.TruncatedMetadata;
            if (frame[0] == 0) break;
            const id = frame[0..if (version == 2) @as(usize, 3) else 4];
            for (id) |ch| if (!std.ascii.isUpper(ch) and !std.ascii.isDigit(ch)) return error.MalformedMetadata;
            const len: u64 = if (version == 2) std.mem.readInt(u24, frame[3..6], .big) else if (version == 4) try synchsafe(frame[4..8]) else std.mem.readInt(u32, frame[4..8], .big);
            pos += header_size;
            if (len == 0 or len > end - pos) return error.TruncatedMetadata;
            const flags = if (version == 2) 0 else frame[9];
            const unsupported = if (version == 3) flags & 0xe0 != 0 else flags & 0xfd != 0;
            const comment = std.mem.eql(u8, id, "COMM") or std.mem.eql(u8, id, "COM");
            if (id[0] == 'T' or comment) {
                if (unsupported) {
                    self.limited = true;
                } else if (try self.bytes(pos, @intCast(len))) |raw| {
                    defer self.allocator.free(raw);
                    var used = raw.len;
                    if (version == 4 and (flags & 2 != 0 or header[5] & 0x80 != 0)) used = deunsync(raw);
                    if (used < 1 + @as(usize, if (comment) 3 else 0)) return error.MalformedMetadata;
                    const decoded = try decode(self.allocator, raw[0], raw[if (comment) @as(usize, 4) else 1..used]);
                    defer self.allocator.free(decoded);
                    const custom = std.mem.eql(u8, id, "TXXX") or std.mem.eql(u8, id, "TXX");
                    if (custom or comment) {
                        const split = std.mem.indexOfScalar(u8, decoded, 0) orelse return error.MalformedMetadata;
                        try self.value(if (comment) "COMMENT" else decoded[0..split], decoded[split + 1 ..]);
                    } else {
                        const key = if (std.mem.eql(u8, id, "TIT2") or std.mem.eql(u8, id, "TT2") or std.mem.eql(u8, id, "TIT3") or std.mem.eql(u8, id, "TT3")) "TITLE" else if (std.mem.eql(u8, id, "TCON") or std.mem.eql(u8, id, "TCO")) "GENRE" else "ARTIST";
                        try self.value(key, decoded);
                    }
                }
            }
            // Picture and unknown binary frames are skipped by declared length.
            pos += len;
        }
        self.limited = self.limited or count == MAX_FIELDS;
    }

    fn flac(self: *State) !void {
        var pos: u64 = 4;
        for (0..MAX_FIELDS) |_| {
            var header: [4]u8 = undefined;
            if (try self.reader.readAll(&header, pos) != 4) return error.TruncatedMetadata;
            const size: u64 = std.mem.readInt(u24, header[1..4], .big);
            pos += 4;
            if (pos > self.reader.size or size > self.reader.size - pos) return error.TruncatedMetadata;
            if (header[0] & 0x7f == 4) try self.commentsAt(pos, pos + size);
            if (header[0] & 0x80 != 0) return;
            pos += size;
        }
        self.limited = true;
    }

    fn integer(self: *State, pos: *u64, end: u64) !u32 {
        if (pos.* > end or end - pos.* < 4) return error.TruncatedMetadata;
        var bytes_: [4]u8 = undefined;
        if (try self.reader.readAll(&bytes_, pos.*) != 4) return error.TruncatedMetadata;
        pos.* += 4;
        return std.mem.readInt(u32, &bytes_, .little);
    }

    fn commentsAt(self: *State, start: u64, end: u64) !void {
        var pos = start;
        const vendor = try self.integer(&pos, end);
        if (vendor > end - pos) return error.TruncatedMetadata;
        pos += vendor;
        const count = try self.integer(&pos, end);
        for (0..@min(count, MAX_FIELDS)) |_| {
            const len = try self.integer(&pos, end);
            if (len > end - pos) return error.TruncatedMetadata;
            // Read just the field-name prefix before deciding whether to skip
            // a multi-megabyte base64 picture or private binary field.
            var prefix: [128]u8 = undefined;
            const wanted = @min(prefix.len, len);
            if (try self.reader.readAll(prefix[0..wanted], pos) != wanted) return error.TruncatedMetadata;
            if (std.mem.indexOfScalar(u8, prefix[0..wanted], '=')) |split| {
                if (textField(prefix[0..split])) {
                    if (try self.bytes(pos + split + 1, len - split - 1)) |bytes_| {
                        defer self.allocator.free(bytes_);
                        try self.value(prefix[0..split], bytes_);
                    }
                }
            } else self.limited = true;
            pos += len;
        }
        self.limited = self.limited or count > MAX_FIELDS;
    }

    fn ogg(self: *State) !void {
        var pos: u64 = 0;
        var packet: std.ArrayList(u8) = .empty;
        defer packet.deinit(self.allocator);
        var serial: ?u32 = null;
        var sequence: u32 = 0;
        var packet_number: usize = 0;
        for (0..1024) |_| {
            var page: [27]u8 = undefined;
            if (try self.reader.readAll(&page, pos) != page.len) return error.TruncatedMetadata;
            if (!std.mem.eql(u8, page[0..4], "OggS") or page[4] != 0) return error.MalformedMetadata;
            const page_serial = std.mem.readInt(u32, page[14..18], .little);
            const page_sequence = std.mem.readInt(u32, page[18..22], .little);
            if (serial == null) {
                if (page[5] & 2 == 0 or page_sequence != 0) return error.MalformedMetadata;
                serial = page_serial;
            }
            if (serial.? != page_serial or page_sequence != sequence or (page[5] & 1 != 0) != (packet.items.len != 0)) return error.MalformedMetadata;
            sequence +%= 1;
            var lacing: [255]u8 = undefined;
            const segments: usize = page[26];
            pos += page.len;
            if (try self.reader.readAll(lacing[0..segments], pos) != segments) return error.TruncatedMetadata;
            pos += segments;
            for (lacing[0..segments]) |size| {
                if (size > self.remaining) {
                    self.limited = true;
                    return;
                }
                const old = packet.items.len;
                try packet.resize(self.allocator, old + size);
                if (try self.reader.readAll(packet.items[old..], pos) != size) return error.TruncatedMetadata;
                self.remaining -= size;
                pos += size;
                if (size < 255) {
                    if (packet_number == 0) {
                        if (!(std.mem.startsWith(u8, packet.items, "\x01vorbis") or std.mem.startsWith(u8, packet.items, "OpusHead"))) return;
                    } else {
                        const offset: usize = if (std.mem.startsWith(u8, packet.items, "\x03vorbis")) 7 else if (std.mem.startsWith(u8, packet.items, "OpusTags")) 8 else return error.MalformedMetadata;
                        // Reuse the bounded positional parser against this packet.
                        var nested = self.*;
                        nested.reader = .{ .handle = self.reader.handle, .io = self.reader.io, .size = packet.items.len, .prefix = packet.items, .cancel = self.reader.cancel };
                        nested.remaining = packet.items.len;
                        try nested.commentsAt(offset, packet.items.len);
                        self.limited = self.limited or nested.limited;
                        return;
                    }
                    packet.clearRetainingCapacity();
                    packet_number += 1;
                }
            }
            if (pos >= self.reader.size) return error.TruncatedMetadata;
        }
        self.limited = true;
    }
};

fn keyEquals(key: []const u8, wanted: []const u8) bool {
    const local = if (std.mem.indexOfScalar(u8, key, ':')) |i| key[i + 1 ..] else key;
    const stripped = if (std.ascii.startsWithIgnoreCase(local, "SM_")) local[3..] else if (std.ascii.startsWithIgnoreCase(local, "ASWG_")) local[5..] else local;
    return std.ascii.eqlIgnoreCase(stripped, wanted);
}

fn descriptive(key: []const u8) bool {
    for ([_][]const u8{ "TITLE", "DESCRIPTION", "COMMENT", "KEYWORDS", "SUBJECT", "NOTES", "FXNAME" }) |field| if (keyEquals(key, field)) return true;
    return false;
}

fn textField(key: []const u8) bool {
    if (descriptive(key)) return true;
    for ([_][]const u8{ "ARTIST", "ALBUM", "GENRE", "CATEGORY", "SUBCATEGORY", "CATID", "DESIGNER", "LIBRARY", "VENDOR", "SOURCE", "LOCATION", "RECORDIST", "MANUFACTURER", "MICROPHONE", "CREATORID", "SOURCEID", "USERCATEGORY" }) |field| if (keyEquals(key, field)) return true;
    return false;
}

fn synchsafe(bytes_: *const [4]u8) !u32 {
    var n: u32 = 0;
    for (bytes_) |b| {
        if (b & 0x80 != 0) return error.MalformedMetadata;
        n = (n << 7) | b;
    }
    return n;
}

fn deunsync(bytes_: []u8) usize {
    var used: usize = 0;
    var prev: u8 = 0;
    for (bytes_) |b| {
        if (b == 0 and prev == 255) {
            prev = 0;
            continue;
        }
        bytes_[used] = b;
        used += 1;
        prev = b;
    }
    return used;
}

fn decode(allocator: std.mem.Allocator, encoding: u8, bytes_: []const u8) ![]u8 {
    if (encoding == 3) {
        if (!std.unicode.utf8ValidateSlice(bytes_)) return error.MalformedMetadata;
        return allocator.dupe(u8, bytes_);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (encoding == 0) {
        for (bytes_) |b| try appendScalar(allocator, &out, b);
    } else if (encoding == 1 or encoding == 2) {
        var endian: std.builtin.Endian = .big;
        var pos: usize = 0;
        if (encoding == 1) {
            if (bytes_.len < 2) return error.MalformedMetadata;
            endian = if (std.mem.eql(u8, bytes_[0..2], "\xff\xfe")) .little else if (std.mem.eql(u8, bytes_[0..2], "\xfe\xff")) .big else return error.MalformedMetadata;
            pos = 2;
        }
        if ((bytes_.len - pos) % 2 != 0) return error.MalformedMetadata;
        while (pos < bytes_.len) {
            const first = std.mem.readInt(u16, bytes_[pos..][0..2], endian);
            pos += 2;
            var scalar: u21 = first;
            if (first >= 0xd800 and first <= 0xdbff) {
                if (bytes_.len - pos < 2) return error.MalformedMetadata;
                const second = std.mem.readInt(u16, bytes_[pos..][0..2], endian);
                if (second < 0xdc00 or second > 0xdfff) return error.MalformedMetadata;
                pos += 2;
                scalar = 0x10000 + (@as(u21, first - 0xd800) << 10) + second - 0xdc00;
            }
            if (scalar != 0xfeff) try appendScalar(allocator, &out, scalar);
        }
    } else return error.MalformedMetadata;
    return out.toOwnedSlice(allocator);
}

fn appendScalar(allocator: std.mem.Allocator, out: *std.ArrayList(u8), scalar: u21) !void {
    var encoded: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(scalar, &encoded) catch return error.MalformedMetadata;
    try out.appendSlice(allocator, encoded[0..n]);
}

test "ID3 Unicode encodings and field names keep descriptive values" {
    const a = std.testing.allocator;
    const latin = try decode(a, 0, "caf\xe9");
    defer a.free(latin);
    try std.testing.expectEqualStrings("café", latin);
    const utf16 = try decode(a, 1, "\xff\xfe\x71\x67\xac\x4e\x00\x00\x3d\xd8\x00\xde");
    defer a.free(utf16);
    try std.testing.expectEqualStrings("東京\x00😀", utf16);
    try std.testing.expectError(error.MalformedMetadata, decode(a, 2, "\xd8\x00"));
    try std.testing.expect(descriptive("ASWG_fxName"));
    try std.testing.expect(descriptive("SM_Description"));
    try std.testing.expect(!textField("METADATA_BLOCK_PICTURE"));
}
