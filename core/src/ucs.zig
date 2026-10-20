const std = @import("std");

pub const version = "8.2.1";
pub const Entry = struct { id: []const u8, category: []const u8, subcategory: []const u8 };
pub const entries: [753]Entry = blk: {
    @setEvalBranchQuota(100_000);
    var result: [753]Entry = undefined;
    var lines = std.mem.tokenizeScalar(u8, @embedFile("data/ucs-8.2.1.tsv"), '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) {
        var fields = std.mem.splitScalar(u8, line, '\t');
        result[i] = .{ .id = fields.next().?, .category = fields.next().?, .subcategory = fields.next().? };
    }
    if (i != result.len) @compileError("Unexpected UCS taxonomy size");
    break :blk result;
};

/// Exact known CatIDs only. Case and filenames are preserved in the catalog.
pub fn lookup(id: []const u8) ?u32 {
    for (entries, 0..) |entry, i| if (std.mem.eql(u8, entry.id, id)) return @intCast(i);
    return null;
}

pub fn fromFilename(name: []const u8) ?u32 {
    const end = std.mem.indexOfScalar(u8, name, '_') orelse return null;
    // UCS permits a user category after '-' before the first underscore.
    const prefix = name[0..end];
    return lookup(prefix[0 .. std.mem.indexOfScalar(u8, prefix, '-') orelse prefix.len]);
}

test "known UCS IDs and user categories never classify unknown names" {
    try std.testing.expectEqual(lookup("AIRBlow"), fromFilename("AIRBlow-Soft_café.wav"));
    try std.testing.expect(lookup("WOODHndl") != null);
    try std.testing.expect(fromFilename("AIR_unknown.wav") == null);
    try std.testing.expect(fromFilename("AIRBlow.wav") == null);
    try std.testing.expect(lookup("airblow") == null);
}
