const std = @import("std");

pub const QueryBuf = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const QueryBuf) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn isEmpty(self: *const QueryBuf) bool {
        return self.len == 0;
    }
};

pub fn isDelimiter(ch: u8) bool {
    return switch (ch) {
        ' ', '\t', '\n', '\r', '-', '_', '.', '/', '\\', '(', ')', '[', ']', '{', '}', ',', ';', ':', '+', '#', '!', '@', '$', '%', '^', '&', '=', '~', '`', '\'', '"', '?', '*', '<', '>' => true,
        else => false,
    };
}

// Match the existing lexical exact/prefix semantics, including punctuation.
// Unicode bytes remain intact; FTS5 remains responsible for Unicode tokenization.
pub fn normalize(input: []const u8) QueryBuf {
    var result = QueryBuf{};
    var last_space = true;
    for (input) |raw| {
        const ch = std.ascii.toLower(raw);
        if (isDelimiter(ch)) {
            if (!last_space and result.len < result.buf.len) {
                result.buf[result.len] = ' ';
                result.len += 1;
                last_space = true;
            }
        } else if (result.len < result.buf.len) {
            result.buf[result.len] = ch;
            result.len += 1;
            last_space = false;
        }
    }
    if (result.len > 0 and result.buf[result.len - 1] == ' ') result.len -= 1;
    return result;
}

pub fn distanceAtMostOne(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const diff = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (diff > 1) return false;
    if (a.len == b.len) {
        var mismatches: [2]usize = undefined;
        var count: usize = 0;
        for (a, b, 0..) |x, y, i| if (x != y) {
            if (count == 2) return false;
            mismatches[count] = i;
            count += 1;
        };
        return count == 1 or (count == 2 and a[mismatches[0]] == b[mismatches[1]] and a[mismatches[1]] == b[mismatches[0]]);
    }
    const longer = if (a.len > b.len) a else b;
    const shorter = if (a.len > b.len) b else a;
    var i: usize = 0;
    var j: usize = 0;
    var skipped = false;
    while (i < longer.len and j < shorter.len) {
        if (longer[i] == shorter[j]) {
            i += 1;
            j += 1;
        } else if (skipped) return false else {
            skipped = true;
            i += 1;
        }
    }
    return true;
}
