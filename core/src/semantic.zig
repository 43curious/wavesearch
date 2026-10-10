const std = @import("std");
const db = @import("db.zig");
const vector = @import("vector.zig");

/// Semantic rows are streamed from SQLite into a dimension-sized decode buffer
/// and a K-sized result heap. This keeps one-million-vector retrieval bounded
/// instead of retaining a multi-gigabyte process-wide snapshot.
pub fn reset() void {}

pub const Retrieval = struct {
    model_id: i64,
    connection_serial: u64,
    generation: i64,
    matches: []vector.Match,
};

pub fn topK(
    allocator: std.mem.Allocator,
    query: []const f32,
    filter: vector.Filter,
    k: usize,
) !?Retrieval {
    try vector.validateNormalized(query);
    const streamed = (try db.streamActiveVectorTopK(allocator, query, filter, k)) orelse return null;
    return .{
        .model_id = streamed.model_id,
        .connection_serial = streamed.connection_serial,
        .generation = streamed.generation,
        .matches = streamed.matches,
    };
}
