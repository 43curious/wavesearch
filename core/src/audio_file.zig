const std = @import("std");

/// Borrowed positional reader. Indexing shares an opened file and its bounded
/// prefix across metadata, duration parsing, and hashing without moving a cursor.
pub const Reader = struct {
    handle: *std.Io.File,
    io: std.Io,
    size: u64,
    prefix: []const u8 = &.{},

    pub fn readAll(self: Reader, dest: []u8, offset: u64) !usize {
        const cached: usize = if (offset < self.prefix.len)
            @intCast(@min(dest.len, self.prefix.len - offset))
        else
            0;
        if (cached > 0) @memcpy(dest[0..cached], self.prefix[@intCast(offset)..][0..cached]);
        if (cached == dest.len) return cached;
        return cached + try self.handle.readPositionalAll(self.io, dest[cached..], offset + cached);
    }
};
