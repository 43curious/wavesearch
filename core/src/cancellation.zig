const std = @import("std");

pub const Token = struct {
    generation: u64,

    pub fn isCancelled(self: Token) bool {
        return generation.load(.acquire) != self.generation;
    }
};

var generation = std.atomic.Value(u64).init(1);
var active = std.atomic.Value(u32).init(0);

pub fn currentGeneration() u64 {
    return generation.load(.acquire);
}

pub fn begin() Token {
    return beginExpected(currentGeneration());
}

pub fn beginExpected(expected_generation: u64) Token {
    _ = active.fetchAdd(1, .acq_rel);
    return .{ .generation = expected_generation };
}

pub fn end() void {
    _ = active.fetchSub(1, .acq_rel);
}

pub fn cancel() bool {
    const had_active = active.load(.acquire) != 0;
    _ = generation.fetchAdd(1, .acq_rel);
    return had_active;
}
