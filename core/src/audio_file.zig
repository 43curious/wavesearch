const std = @import("std");

// Optional request-local diagnostic counter used by disposable I/O benchmarks.
pub threadlocal var bytes_read: ?*u64 = null;

pub const Testing = if (@import("builtin").is_test) struct {
    pub threadlocal var after_read: ?*const fn () void = null;
} else struct {};

/// Borrowed positional reader. Indexing shares an opened file and its bounded
/// prefix across metadata, duration parsing, and hashing without moving a cursor.
pub const Reader = struct {
    handle: *std.Io.File,
    io: std.Io,
    size: u64,
    prefix: []const u8 = &.{},
    cancel: ?*const std.atomic.Value(bool) = null,
    read_limit: ?*usize = null,

    pub fn readAll(self: Reader, dest: []u8, offset: u64) !usize {
        if (self.cancel) |token| if (token.load(.acquire)) return error.Cancelled;
        if (self.read_limit) |remaining| {
            if (remaining.* == 0) return error.MetadataReadLimit;
            remaining.* -= 1;
        }
        const cached: usize = if (offset < self.prefix.len)
            @intCast(@min(dest.len, self.prefix.len - offset))
        else
            0;
        if (cached > 0) @memcpy(dest[0..cached], self.prefix[@intCast(offset)..][0..cached]);
        if (cached == dest.len) return cached;
        const read = try self.handle.readPositionalAll(self.io, dest[cached..], offset + cached);
        if (bytes_read) |counter| counter.* += read;
        if (comptime @import("builtin").is_test) if (Testing.after_read) |hook| hook();
        return cached + read;
    }
};
