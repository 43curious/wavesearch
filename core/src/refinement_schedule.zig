const std = @import("std");

pub const waveform: u32 = 1;
pub const acoustic: u32 = 2;
pub const semantic: u32 = 4;
const slots = [_]u32{ waveform, acoustic, waveform, semantic };

/// Select one admitted step, skipping unavailable queues without losing fairness.
/// A continuously ready queue is selected within four completed selections.
pub fn next(cursor: *u32, ready_mask: u32) u32 {
    for (slots) |_| {
        const index = cursor.* % slots.len;
        cursor.* = @intCast((index + 1) % slots.len);
        const queue = slots[index];
        if (ready_mask & queue != 0) return queue;
    }
    return 0;
}

test "ready refinement queues make bounded progress with a persistent backlog" {
    for (0..8) |ready| {
        var cursor: u32 = 0;
        var previous: [3]?usize = @splat(null);
        var counts: [3]usize = @splat(0);
        for (0..100) |step| {
            const selected = next(&cursor, @intCast(ready));
            if (ready == 0) {
                try std.testing.expectEqual(@as(u32, 0), selected);
                continue;
            }
            try std.testing.expect(selected & ready != 0);
            const index: usize = @intCast(@ctz(selected));
            if (previous[index]) |last| {
                try std.testing.expect(step - last <= slots.len);
            } else {
                try std.testing.expect(step < slots.len);
            }
            previous[index] = step;
            counts[index] += 1;
            for (0..3) |i| {
                if (ready & (@as(usize, 1) << @intCast(i)) != 0 and step >= slots.len) {
                    try std.testing.expect(step - (previous[i] orelse 0) < slots.len);
                }
            }
        }
        if (ready == 7) try std.testing.expectEqualSlices(usize, &.{ 50, 25, 25 }, &counts);
    }
    // A parked queue can resume without resetting the cursor or waiting for
    // another queue's backlog to finish.
    var cursor: u32 = 0;
    _ = next(&cursor, waveform);
    try std.testing.expectEqual(acoustic, next(&cursor, waveform | acoustic));
    _ = next(&cursor, waveform | acoustic);
    try std.testing.expectEqual(semantic, next(&cursor, waveform | acoustic | semantic));
}
