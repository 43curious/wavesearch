const std = @import("std");
const types = @import("types.zig");

/// Sticky, request-local cancellation. The host owns the handle until both the
/// blocking call and every concurrent canceller have returned; never reset it.
pub const Request = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    // Calls on one handle are sequential; only cancellation is concurrent.
    lexical: ?LexicalCache = null,
    lexical_builds: usize = 0,

    pub const LexicalCache = struct {
        query: []u8,
        folder_id: ?i32,
        limit: usize,
        revision: [2]u64,
        rows: []types.SearchCandidate,
    };

    pub fn clearLexical(self: *Request) void {
        if (self.lexical) |cache| {
            std.heap.c_allocator.free(cache.query);
            std.heap.c_allocator.free(cache.rows);
        }
        self.lexical = null;
    }

    pub fn cancel(self: *Request) void {
        self.cancelled.store(true, .release);
    }
};

// Scoped by the synchronous C entry points, never carried across a thread hop.
// Legacy calls and scan/refinement calls have no current request.
pub threadlocal var current: ?*Request = null;

pub fn isCancelled() bool {
    return if (current) |request| request.cancelled.load(.acquire) else false;
}

pub fn check() error{Cancelled}!void {
    if (isCancelled()) return error.Cancelled;
}
