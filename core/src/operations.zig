const std = @import("std");

pub const Status = struct {
    active: bool,
    cancel_requested: bool,
    deep: bool,
    folder_id: i32,
    discovered: u64,
    completed_operations: u64,
    cancelled_operations: u64,
    failed_operations: u64,
};

var active = std.atomic.Value(bool).init(false);
var cancel_requested = std.atomic.Value(bool).init(false);
var deep = std.atomic.Value(bool).init(false);
var folder_id = std.atomic.Value(i32).init(-1);
var discovered = std.atomic.Value(u64).init(0);
var completed_operations = std.atomic.Value(u64).init(0);
var cancelled_operations = std.atomic.Value(u64).init(0);
var failed_operations = std.atomic.Value(u64).init(0);

pub fn begin(folder: i32, is_deep: bool) !void {
    // Mutation callers are serialized externally. Publish `active` only after
    // every field and the fresh cancellation token are visible.
    if (active.load(.acquire)) return error.OperationAlreadyActive;
    cancel_requested.store(false, .release);
    deep.store(is_deep, .release);
    folder_id.store(folder, .release);
    discovered.store(0, .release);
    active.store(true, .release);
}

pub fn finish(result: anyerror!void) void {
    if (result) |_| {
        _ = completed_operations.fetchAdd(1, .monotonic);
    } else |err| {
        if (err == error.Cancelled)
            _ = cancelled_operations.fetchAdd(1, .monotonic)
        else
            _ = failed_operations.fetchAdd(1, .monotonic);
    }
    active.store(false, .release);
    folder_id.store(-1, .release);
}

pub fn requestCancel() bool {
    if (!active.load(.acquire)) return false;
    cancel_requested.store(true, .release);
    return true;
}

pub fn cancelToken() *const std.atomic.Value(bool) {
    return &cancel_requested;
}

pub fn discoveredCounter() *std.atomic.Value(u64) {
    return &discovered;
}

pub fn status() Status {
    return .{
        .active = active.load(.acquire),
        .cancel_requested = cancel_requested.load(.acquire),
        .deep = deep.load(.acquire),
        .folder_id = folder_id.load(.acquire),
        .discovered = discovered.load(.acquire),
        .completed_operations = completed_operations.load(.acquire),
        .cancelled_operations = cancelled_operations.load(.acquire),
        .failed_operations = failed_operations.load(.acquire),
    };
}
