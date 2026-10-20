const std = @import("std");
const Reader = @import("audio_file.zig").Reader;
const query = @import("query.zig");

pub const MAX_CHUNKS = 65_536;
pub const FAST_BUDGET = 256 * 1024;
pub const NORMAL_BUDGET = 2 * 1024 * 1024;

pub const Technical = struct {
    channels: ?u32 = null,
    sample_rate: ?u32 = null,
    bit_depth: ?u32 = null,
    encoding: ?u32 = null, // 1 = integer PCM, 3 = IEEE float; NULL = unknown.
    limited: bool = false,
};

/// Seek over PCM/unknown chunks. Payload and header ceilings are independent;
/// limits are observable rather than pretending the description is complete.
pub fn read(allocator: std.mem.Allocator, all: *std.ArrayList(u8), description: *std.ArrayList(u8), reader: Reader, budget: usize, cancel: ?*const std.atomic.Value(bool)) !bool {
    if (reader.size < 12) return false;
    var riff: [12]u8 = undefined;
    if (try reader.readAll(&riff, 0) != riff.len) return error.TruncatedMetadata;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, riff[0..4], "RIFF")) .little else if (std.mem.eql(u8, riff[0..4], "RIFX")) .big else return false;
    if (!std.mem.eql(u8, riff[8..12], "WAVE")) return false;
    const riff_end: u64 = @as(u64, std.mem.readInt(u32, riff[4..8], endian)) + 8;
    if (riff_end < 12) return error.MalformedMetadata;
    if (riff_end > reader.size) return error.TruncatedMetadata;
    var remaining = budget;
    var position: u64 = 12;
    var chunks: usize = 0;
    var limited = false;
    while (position < riff_end and chunks < MAX_CHUNKS) : (chunks += 1) {
        try query.check();
        if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
        if (riff_end - position < 8) return error.TruncatedMetadata;
        var header: [8]u8 = undefined;
        if (try reader.readAll(&header, position) != header.len) return error.TruncatedMetadata;
        const size: u64 = std.mem.readInt(u32, header[4..8], endian);
        const payload = position + 8;
        const next = std.math.add(u64, payload, size + (size & 1)) catch return error.MalformedMetadata;
        if (next > riff_end) return error.TruncatedMetadata;
        const id = header[0..4];
        if (std.mem.eql(u8, id, "bext") or std.mem.eql(u8, id, "iXML") or std.mem.eql(u8, id, "_PMX") or std.mem.eql(u8, id, "LIST")) {
            const wanted: usize = @intCast(@min(size, remaining));
            limited = limited or wanted < size;
            if (wanted > 0) {
                const bytes = try allocator.alloc(u8, wanted);
                defer allocator.free(bytes);
                if (try reader.readAll(bytes, payload) != wanted) return error.TruncatedMetadata;
                if (std.mem.eql(u8, id, "bext")) {
                    // Text fields stop before binary time-reference/version/UMID.
                    for ([_][2]usize{ .{ 0, 256 }, .{ 256, 288 }, .{ 288, 320 }, .{ 320, 330 }, .{ 330, 338 }, .{ 602, bytes.len } }, 0..) |bounds, index| {
                        if (bounds[0] >= bytes.len) continue;
                        const value = bytes[bounds[0]..@min(bounds[1], bytes.len)];
                        try clean(allocator, all, value);
                        if (index == 0) try clean(allocator, description, value);
                    }
                } else if (std.mem.eql(u8, id, "LIST")) {
                    limited = (try list(allocator, all, description, bytes, endian)) or limited;
                } else limited = (try xml(allocator, all, description, bytes)) or limited;
                remaining -= wanted;
            }
        }
        position = next;
    }
    return limited or position < riff_end;
}

fn list(allocator: std.mem.Allocator, all: *std.ArrayList(u8), description: *std.ArrayList(u8), bytes: []const u8, endian: std.builtin.Endian) !bool {
    if (bytes.len < 4) return true;
    if (!std.mem.eql(u8, bytes[0..4], "INFO")) return false;
    var pos: usize = 4;
    while (pos + 8 <= bytes.len) {
        const id = bytes[pos..][0..4];
        const size: usize = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], endian);
        pos += 8;
        const end = pos + @min(size, bytes.len - pos);
        try clean(allocator, all, bytes[pos..end]);
        if (std.mem.eql(u8, id, "INAM") or std.mem.eql(u8, id, "ICMT") or std.mem.eql(u8, id, "ISBJ") or std.mem.eql(u8, id, "IKEY")) try clean(allocator, description, bytes[pos..end]);
        if (size > bytes.len - pos) return true;
        pos += size + (size & 1);
    }
    return pos != bytes.len;
}

/// Preserve valid UTF-8 scalars. Invalid bytes/control characters separate words;
/// only ASCII case is folded here, leaving Unicode tokenization to SQLite.
pub fn clean(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    var pos: usize = 0;
    var separator = out.items.len > 0;
    while (pos < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch {
            separator = true;
            pos += 1;
            continue;
        };
        if (len > bytes.len - pos) break;
        const scalar = std.unicode.utf8Decode(bytes[pos..][0..len]) catch {
            separator = true;
            pos += 1;
            continue;
        };
        const keep = if (scalar < 128) std.ascii.isAlphanumeric(@intCast(scalar)) else scalar > 0x9f and scalar != 0xa0 and scalar != 0x2028 and scalar != 0x2029 and scalar != 0xfeff;
        if (keep) {
            if (separator and out.items.len > 0) try out.append(allocator, ' ');
            if (len == 1) try out.append(allocator, std.ascii.toLower(bytes[pos])) else try out.appendSlice(allocator, bytes[pos..][0..len]);
            separator = false;
        } else separator = true;
        pos += len;
    }
}

fn descriptive(name: []const u8) bool {
    const local = if (std.mem.lastIndexOfScalar(u8, name, ':')) |i| name[i + 1 ..] else name;
    for ([_][]const u8{ "DESCRIPTION", "BWF_DESCRIPTION", "NOTE", "NOTES", "COMMENT", "TITLE", "SUBJECT", "KEYWORDS", "FXNAME", "ASWG_FXNAME", "SM_DESCRIPTION" }) |key| if (std.ascii.eqlIgnoreCase(local, key)) return true;
    return false;
}

// A bounded character-data extractor, not an XML validator. No DTD/entity
// expansion, tag/attribute indexing or external resource access is performed.
fn xml(allocator: std.mem.Allocator, all: *std.ArrayList(u8), description: *std.ArrayList(u8), bytes: []const u8) !bool {
    var stack: [32]bool = undefined;
    var depth: usize = 0;
    var pos: usize = 0;
    while (pos < bytes.len) {
        try query.check();
        if (bytes[pos] != '<') {
            const end = if (std.mem.indexOfScalarPos(u8, bytes, pos, '<')) |i| i else bytes.len;
            try characterData(allocator, all, bytes[pos..end], true);
            if (depth > 0 and stack[depth - 1]) try characterData(allocator, description, bytes[pos..end], true);
            pos = end;
            continue;
        }
        if (std.mem.startsWith(u8, bytes[pos..], "<!--")) {
            pos = (std.mem.indexOfPos(u8, bytes, pos + 4, "-->") orelse return true) + 3;
            continue;
        }
        if (std.mem.startsWith(u8, bytes[pos..], "<![CDATA[")) {
            const end = std.mem.indexOfPos(u8, bytes, pos + 9, "]]>") orelse return true;
            try characterData(allocator, all, bytes[pos + 9 .. end], false);
            if (depth > 0 and stack[depth - 1]) try characterData(allocator, description, bytes[pos + 9 .. end], false);
            pos = end + 3;
            continue;
        }
        var end = pos + 1;
        var quote: u8 = 0;
        var subset: usize = 0;
        while (end < bytes.len) : (end += 1) {
            const ch = bytes[end];
            if (quote != 0) {
                if (ch == quote) quote = 0;
            } else if (ch == '"' or ch == '\'') {
                quote = ch;
            } else if (ch == '[') {
                subset += 1;
            } else if (ch == ']' and subset > 0) {
                subset -= 1;
            } else if (ch == '>' and subset == 0) break;
        }
        if (end == bytes.len) return true;
        const tag = std.mem.trim(u8, bytes[pos + 1 .. end], " \t\r\n");
        if (tag.len > 0 and tag[0] == '/') {
            if (depth == 0) return true;
            depth -= 1;
        } else if (tag.len > 0 and tag[0] != '?' and tag[0] != '!') {
            if (!std.mem.endsWith(u8, tag, "/")) {
                if (depth == stack.len) return true;
                const name_end = std.mem.indexOfAny(u8, tag, " \t\r\n/") orelse tag.len;
                stack[depth] = (depth > 0 and stack[depth - 1]) or descriptive(tag[0..name_end]);
                depth += 1;
            }
        }
        pos = end + 1;
    }
    return depth != 0;
}

fn characterData(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8, entities: bool) !void {
    if (!entities) return clean(allocator, out, bytes);
    // Decode into one bounded scratch buffer so an entity inside a word does
    // not introduce artificial spaces (e.g. explos&#xF3;n).
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    var pos: usize = 0;
    while (pos < bytes.len) {
        if (bytes[pos] != '&') {
            try decoded.append(allocator, bytes[pos]);
            pos += 1;
            continue;
        }
        const relative_end = std.mem.indexOfScalar(u8, bytes[pos + 1 .. @min(bytes.len, pos + 18)], ';') orelse {
            try decoded.append(allocator, ' ');
            pos += 1;
            continue;
        };
        const end = pos + 1 + relative_end;
        const name = bytes[pos + 1 .. end];
        const scalar: ?u21 = if (std.mem.eql(u8, name, "amp")) '&' else if (std.mem.eql(u8, name, "lt")) '<' else if (std.mem.eql(u8, name, "gt")) '>' else if (std.mem.eql(u8, name, "quot")) '"' else if (std.mem.eql(u8, name, "apos")) '\'' else if (std.mem.startsWith(u8, name, "#x")) std.fmt.parseInt(u21, name[2..], 16) catch null else if (std.mem.startsWith(u8, name, "#")) std.fmt.parseInt(u21, name[1..], 10) catch null else null;
        if (scalar) |value| {
            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(value, &encoded) catch {
                try decoded.append(allocator, ' ');
                pos = end + 1;
                continue;
            };
            try decoded.appendSlice(allocator, encoded[0..len]);
        } else try decoded.append(allocator, ' ');
        pos = end + 1;
    }
    try clean(allocator, out, decoded.items);
}

test "XML extraction bounds nesting and entities and preserves valid character data" {
    const allocator = std.testing.allocator;
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(allocator);
    var description: std.ArrayList(u8) = .empty;
    defer description.deinit(allocator);
    try std.testing.expect(!try xml(allocator, &all, &description, "<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><x><dc:description language='attribute > noise'>caf&#233; &secret; <![CDATA[東京]]></dc:description><PRIVATE>море</PRIVATE></x>"));
    try std.testing.expectEqualStrings("café 東京 море", all.items);
    try std.testing.expectEqualStrings("café 東京", description.items);
    try std.testing.expect(try xml(allocator, &all, &description, "<x><NOTE>partial<!-- missing end"));
    try clean(allocator, &all, "x\xff\xc0\x80y\xe2\x82");
    try std.testing.expect(std.unicode.utf8ValidateSlice(all.items));
    var deep: [128]u8 = undefined;
    for (0..32) |i| @memcpy(deep[i * 4 ..][0..4], "<xx>");
    try std.testing.expect(try xml(allocator, &all, &description, &deep));
}
