const std = @import("std");

// Small explicit equivalence groups, rather than global stemming or loose
// associations such as drone -> bed/tone and riser -> construction/build.
const groups = [_][]const []const u8{
    &.{ "whoosh", "woosh", "swoosh", "swish", "passby" },
    &.{ "impact", "hit", "slam", "thud", "punch", "golpe", "golpes", "impacto", "impactos" },
    &.{ "sfx", "fx" },
    &.{ "ambience", "amb", "ambient", "atmos", "atmosphere", "ambiente", "ambientes" },
    &.{ "riser", "rise", "swell", "subida", "subidas", "ascenso" },
    &.{ "downer", "descend", "descenso" },
    &.{ "drone", "zumbido", "zumbidos" },
    &.{ "footstep", "footsteps", "paso", "pasos" },
    &.{ "rain", "lluvia" },
    &.{ "wind", "viento" },
    &.{ "door", "doors", "puerta", "puertas" },
    &.{ "bark", "barking", "ladrido", "ladridos" },
    &.{ "explosion", "explosions", "explosión", "explosiones" },
};

/// Returns the entire symmetric group, including the input when canonical.
/// Folding is deliberately limited to Spanish accented letters for lookup;
/// original query bytes and SQLite's Unicode tokenizer remain unchanged.
pub fn equivalents(token: []const u8) []const []const u8 {
    var buffer: [96]u8 = undefined;
    const folded = fold(token, &buffer);
    for (groups) |group| {
        for (group) |word| {
            var other: [96]u8 = undefined;
            if (std.mem.eql(u8, folded, fold(word, &other))) return group;
        }
    }
    return &.{};
}

fn fold(input: []const u8, out: []u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < input.len and n < out.len) : (n += 1) {
        out[n] = std.ascii.toLower(input[i]);
        if (input[i] == 0xc3 and i + 1 < input.len) {
            const letter: ?u8 = switch (input[i + 1]) {
                0x81, 0xa1 => 'a',
                0x89, 0xa9 => 'e',
                0x8d, 0xad => 'i',
                0x93, 0xb3 => 'o',
                0x9a, 0xba, 0x9c, 0xbc => 'u',
                0x91, 0xb1 => 'n',
                else => null,
            };
            if (letter) |value| {
                out[n] = value;
                i += 2;
                continue;
            }
        }
        i += 1;
    }
    return out[0..n];
}

test "vocabulary groups are symmetric and Spanish lookup folds accents" {
    for (groups) |group| {
        for (group) |word| try std.testing.expect(equivalents(word).ptr == group.ptr);
    }
    try std.testing.expect(equivalents("EXPLOSIÓN").ptr == equivalents("explosion").ptr);
    for ([_][]const u8{ "bed", "tone", "build", "drop", "a", "s", "efecto" }) |word| try std.testing.expectEqual(@as(usize, 0), equivalents(word).len);
}
