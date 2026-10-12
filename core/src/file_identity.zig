const std = @import("std");
const audio_file = @import("audio_file.zig");
const query_cancel = @import("query.zig");

pub const Kind = enum(u32) { unknown = 0, fast_provisional = 1, sampled = 2, full = 3 };
pub const Algorithm = enum(u32) { unknown = 0, wyhash_size_le64_v1 = 1 };
pub const Mode = enum { fast, normal, deep };
pub const Identity = struct { value: i64, kind: Kind, algorithm: Algorithm };
pub const Recorded = struct { hash: i64, size: i64, mtime_ns: i64, kind: Kind, algorithm: Algorithm };

pub const FAST_HASH_BLOCK_SIZE: u64 = 64 * 1024;
pub const FAST_HASH_MAX_READ: u64 = FAST_HASH_BLOCK_SIZE * 5;

pub fn fastHashSampleOffsets(file_size: u64, storage: *[5]u64) []const u64 {
    if (file_size <= FAST_HASH_MAX_READ) return storage[0..0];
    const span = file_size - FAST_HASH_BLOCK_SIZE;
    storage.* = .{ 0, span / 4, span / 2, span - span / 4, span };
    return storage;
}

pub fn compute(reader: audio_file.Reader, mode: Mode, expected_size: i64, expected_mtime_ns: i64, cancel: ?*const std.atomic.Value(bool)) !Identity {
    const deep = mode == .deep;
    const fast = mode == .fast;
    try query_cancel.check();
    const stat = try reader.handle.stat(reader.io);
    if (stat.size != expected_size or stat.mtime.nanoseconds != expected_mtime_ns) return error.FileChangedDuringScan;
    var hasher = std.hash.Wyhash.init(0);
    var size_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &size_buf, stat.size, .little);
    hasher.update(&size_buf);
    var buf: [FAST_HASH_BLOCK_SIZE]u8 = undefined;
    if (deep or (!fast and stat.size <= 16 * 1024 * 1024) or (fast and stat.size <= FAST_HASH_MAX_READ)) {
        var offset: u64 = 0;
        while (offset < stat.size) {
            try query_cancel.check();
            if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
            const wanted: usize = @intCast(@min(@as(u64, buf.len), stat.size - offset));
            const n = try reader.readAll(buf[0..wanted], offset);
            if (n != wanted) return error.FileChangedDuringScan;
            hasher.update(buf[0..n]);
            offset += n;
        }
    } else if (fast) {
        var offset_storage: [5]u64 = undefined;
        for (fastHashSampleOffsets(stat.size, &offset_storage)) |offset| {
            try query_cancel.check();
            if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
            std.mem.writeInt(u64, &size_buf, offset, .little);
            hasher.update(&size_buf);
            const n = try reader.readAll(&buf, offset);
            if (n != buf.len) return error.FileChangedDuringScan;
            hasher.update(&buf);
        }
    } else {
        const first = try reader.readAll(&buf, 0);
        if (first != buf.len) return error.FileChangedDuringScan;
        hasher.update(buf[0..first]);
        const last = try reader.readAll(&buf, stat.size - buf.len);
        if (last != buf.len) return error.FileChangedDuringScan;
        hasher.update(buf[0..last]);
    }
    const after = try reader.handle.stat(reader.io);
    if (after.size != stat.size or after.mtime.nanoseconds != stat.mtime.nanoseconds) return error.FileChangedDuringScan;
    try query_cancel.check();
    if (cancel) |token| if (token.load(.acquire)) return error.Cancelled;
    const raw_digest = hasher.final() & 0x7fff_ffff_ffff_ffff;
    const digest: i64 = @intCast(if (raw_digest == 0) 1 else raw_digest);
    const kind: Kind = if (fast) .fast_provisional else if (!deep and stat.size > 16 * 1024 * 1024) .sampled else .full;
    return .{ .value = if (kind == .full) digest else -digest, .kind = kind, .algorithm = .wyhash_size_le64_v1 };
}

/// One borrowed-path source, validated against its catalog metadata. It owns
/// only its descriptor; callers keep the path alive until deinit.
pub const Source = struct {
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    stat: std.Io.File.Stat,
    recorded: Recorded,

    pub fn init(io: std.Io, path: []const u8, recorded: Recorded) !Source {
        try query_cancel.check();
        if (recorded.kind == .unknown or recorded.algorithm != .wyhash_size_le64_v1 or recorded.size < 0) return error.UnverifiedIdentity;
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.size != recorded.size or stat.mtime.nanoseconds != recorded.mtime_ns) return error.StaleContentIdentity;
        return .{ .io = io, .file = file, .path = path, .stat = stat, .recorded = recorded };
    }

    pub fn deinit(self: *Source) void {
        self.file.close(self.io);
    }

    pub fn validateHash(self: *Source) !void {
        const mode: Mode = switch (self.recorded.kind) {
            .full => .deep,
            .sampled => .normal,
            .fast_provisional => .fast,
            .unknown => return error.UnverifiedIdentity,
        };
        const actual = try compute(.{ .handle = &self.file, .io = self.io, .size = self.stat.size }, mode, self.recorded.size, self.recorded.mtime_ns, null);
        if (actual.value != self.recorded.hash or actual.kind != self.recorded.kind) return error.StaleContentIdentity;
        try self.confirm();
    }

    pub fn confirm(self: *Source) !void {
        try query_cancel.check();
        const path_stat = try std.Io.Dir.cwd().statFile(self.io, self.path, .{});
        const after = try self.file.stat(self.io);
        if (path_stat.inode != self.stat.inode or path_stat.size != self.stat.size or path_stat.mtime.nanoseconds != self.stat.mtime.nanoseconds or path_stat.ctime.nanoseconds != self.stat.ctime.nanoseconds or after.size != self.stat.size or after.mtime.nanoseconds != self.stat.mtime.nanoseconds or after.ctime.nanoseconds != self.stat.ctime.nanoseconds) return error.StaleContentIdentity;
        try query_cancel.check();
    }

    /// Compare every byte before confirming equality, with fixed 128 KiB PCM-
    /// independent scratch. Matching sampled or full hashes are only candidates.
    pub fn equals(self: *Source, other: *Source) !bool {
        if (self.stat.size != other.stat.size) return false;
        var a: [FAST_HASH_BLOCK_SIZE]u8 = undefined;
        var b: [FAST_HASH_BLOCK_SIZE]u8 = undefined;
        var offset: u64 = 0;
        var equal = true;
        while (offset < self.stat.size) {
            try query_cancel.check();
            const wanted: usize = @intCast(@min(a.len, self.stat.size - offset));
            const left: audio_file.Reader = .{ .handle = &self.file, .io = self.io, .size = self.stat.size };
            const right: audio_file.Reader = .{ .handle = &other.file, .io = other.io, .size = other.stat.size };
            if (try left.readAll(a[0..wanted], offset) != wanted or try right.readAll(b[0..wanted], offset) != wanted) return error.StaleContentIdentity;
            if (!std.mem.eql(u8, a[0..wanted], b[0..wanted])) {
                equal = false;
                break;
            }
            offset += wanted;
        }
        try self.confirm();
        try other.confirm();
        return equal;
    }
};
