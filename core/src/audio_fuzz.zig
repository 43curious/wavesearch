//! Deterministic, model-free mutation fuzzing with a bounded replay entry point.
const std = @import("std");
const audio = @import("audio.zig");
const clap = @import("clap_audio.zig");
const audio_file = @import("audio_file.zig");
const search = @import("search.zig");

const max_input = 8192;
const heap_budget = 4 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const mode = args.next() orelse "run";
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const backing = try std.heap.c_allocator.alloc(u8, heap_budget);
    defer std.heap.c_allocator.free(backing);
    if (std.mem.eql(u8, mode, "replay")) {
        const path = args.next() orelse return error.MissingReplayPath;
        if (args.next() != null) return error.InvalidArguments;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.c_allocator, .limited(max_input));
        defer std.heap.c_allocator.free(bytes);
        try exercise(io, path, bytes, backing);
        std.debug.print("PASS: replay {s}\n", .{path});
        return;
    }
    if (!std.mem.eql(u8, mode, "run")) return error.InvalidArguments;
    const iterations = if (args.next()) |s| try std.fmt.parseInt(usize, s, 0) else 256;
    const seed = if (args.next()) |s| try std.fmt.parseInt(u64, s, 0) else 0x575346555a5a;
    const artifact = args.next() orelse "zig-out/audio-fuzz-current.bin";
    const seconds = if (args.next()) |s| try std.fmt.parseInt(u32, s, 10) else 30;
    if (args.next() != null or iterations > 1_000_000 or seconds == 0 or seconds > 3600) return error.InvalidArguments;
    if (std.fs.path.dirname(artifact)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    std.debug.print("audio fuzz: seed={d} mutations={d} budget_s={d} replay_artifact={s}\n", .{ seed, iterations, seconds, artifact });
    const started = std.Io.Clock.awake.now(io);
    const budget_ns = @as(i96, seconds) * std.time.ns_per_s;
    var cases: usize = 0;
    // Always run intact seeds, every truncation, and hostile size/payload edits.
    // The latest input is saved BEFORE execution, including in panic builds.
    campaign: {
        for (0..16) |kind| {
            var input: [max_input]u8 = undefined;
            const n = makeSeed(&input, kind);
            for (0..n + 1) |end| {
                if (started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds() >= budget_ns) break :campaign;
                try savedExercise(io, artifact, input[0..end], backing);
                cases += 1;
                if (end == n and kind != 9 and kind != 15) {
                    var fixed = std.heap.FixedBufferAllocator.init(backing);
                    _ = try clap.preprocessWavBytes(fixed.allocator(), input[0..n]);
                }
            }
            var hostile = input;
            for (0..n / 4) |word| {
                if (started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds() >= budget_ns) break :campaign;
                hostile = input;
                @memset(hostile[word * 4 ..][0..4], 0xff);
                try savedExercise(io, artifact, hostile[0..n], backing);
                cases += 1;
            }
        }
        for (0..iterations) |_| {
            if (started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds() >= budget_ns) break :campaign;
            var input: [max_input]u8 = undefined;
            var n = makeSeed(&input, random.uintLessThan(usize, 16));
            for (0..random.intRangeAtMost(usize, 1, 8)) |_| {
                switch (random.uintLessThan(u8, 4)) {
                    0 => input[random.uintLessThan(usize, n)] = random.int(u8),
                    1 => n = random.intRangeAtMost(usize, 1, n),
                    2 => {
                        const offset = random.uintLessThan(usize, n);
                        @memset(input[offset..@min(n, offset + 4)], 0xff);
                    },
                    else => {
                        const count = @min(n, max_input - n);
                        @memcpy(input[n..][0..count], input[0..count]);
                        n += count;
                    },
                }
            }
            try savedExercise(io, artifact, input[0..n], backing);
            cases += 1;
        }
    }
    try durationProperties(seed, @min(@max(iterations, 512), 16384));
    std.debug.print("PASS: {d} bounded audio cases and duration properties\n", .{cases});
}

fn savedExercise(io: std.Io, path: []const u8, bytes: []const u8, backing: []u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    try exercise(io, path, bytes, backing);
}

/// Replays both byte and positional-file paths. Rejections and allocation-budget
/// exhaustion are valid outcomes; crashes, nonfinite output and bounds failures are not.
fn exercise(io: std.Io, path: []const u8, bytes: []const u8, backing: []u8) !void {
    if (bytes.len > max_input) return error.InputLimit;
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const allocator = fixed.allocator();
    if (clap.preprocessWavBytes(allocator, bytes)) |samples| {
        for (samples) |sample| if (!std.math.isFinite(sample)) return error.NonFiniteOutput;
    } else |_| {}
    fixed.reset();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const reader: audio_file.Reader = .{ .handle = &file, .io = io, .size = bytes.len };
    _ = clap.durationMsFromFile(reader) catch 0;
    var text: std.ArrayList(u8) = .empty;
    audio.appendMetadataTextFromFileLimit(allocator, &text, reader, max_input) catch {};
    if (text.items.len > max_input * 2) return error.MetadataOutputLimit;
    fixed.reset();
    text = .empty;
    audio.appendMetadataTextFromFileSparse(allocator, &text, reader, max_input) catch {};
    if (text.items.len > max_input * 2) return error.MetadataOutputLimit;
    // Arbitrary hostile text also exercises number parsing and bounded token output.
    const query = search.parseSearchQuery(bytes);
    if (query.text.len > search.MAX_QUERY_LEN) return error.QueryOutputLimit;
}

fn chunk(out: []u8, pos: *usize, id: *const [4]u8, payload: []const u8, endian: std.builtin.Endian) void {
    @memcpy(out[pos.*..][0..4], id);
    std.mem.writeInt(u32, out[pos.* + 4 ..][0..4], @intCast(payload.len), endian);
    pos.* += 8;
    @memcpy(out[pos.*..][0..payload.len], payload);
    pos.* += payload.len;
    if (payload.len & 1 != 0) {
        out[pos.*] = 0;
        pos.* += 1;
    }
}

fn makeSeed(out: []u8, kind: usize) usize {
    @memset(out, 0);
    var pos: usize = 12;
    const endian: std.builtin.Endian = if (kind == 8 or kind >= 10) .big else .little;
    if (kind >= 10) {
        @memcpy(out[0..4], "FORM");
        const compressed = kind >= 12;
        @memcpy(out[8..12], if (compressed) "AIFC" else "AIFF");
        var comm: [22]u8 = @splat(0);
        std.mem.writeInt(u16, comm[0..2], 1, .big);
        std.mem.writeInt(u32, comm[2..6], 2, .big);
        std.mem.writeInt(u16, comm[6..8], 16, .big);
        @memcpy(comm[8..18], &[_]u8{ 0x40, 0x0e, 0xbb, 0x80, 0, 0, 0, 0, 0, 0 }); // 48 kHz
        @memcpy(comm[18..22], if (kind == 13) "sowt" else if (kind == 14) "twos" else "NONE");
        chunk(out, &pos, "COMM", comm[0..if (compressed) 22 else 18], .big);
        chunk(out, &pos, "SSND", &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0xc0, 0 }, .big);
        if (kind == 15) chunk(out, &pos, "COMM", &comm, .big);
    } else {
        @memcpy(out[0..4], if (endian == .big) "RIFX" else "RIFF");
        @memcpy(out[8..12], "WAVE");
        const bits: u16 = switch (kind) {
            0 => 8,
            2, 6 => 24,
            3, 4, 7, 9 => 32,
            5 => 64,
            else => 16,
        };
        const float = kind == 4 or kind == 5 or kind == 7 or kind == 9;
        const extensible = kind == 6 or kind == 7;
        var fmt: [40]u8 = @splat(0);
        const encoding: u16 = if (float) 3 else 1;
        std.mem.writeInt(u16, fmt[0..2], if (extensible) 0xfffe else encoding, endian);
        std.mem.writeInt(u16, fmt[2..4], 1, endian);
        std.mem.writeInt(u32, fmt[4..8], 48_000, endian);
        std.mem.writeInt(u32, fmt[8..12], @as(u32, 48_000) * (bits / 8), endian);
        std.mem.writeInt(u16, fmt[12..14], bits / 8, endian);
        std.mem.writeInt(u16, fmt[14..16], bits, endian);
        if (extensible) {
            std.mem.writeInt(u16, fmt[16..18], 22, endian);
            std.mem.writeInt(u16, fmt[18..20], bits, endian);
            std.mem.writeInt(u16, fmt[24..26], encoding, endian);
            @memcpy(fmt[26..40], &[_]u8{ 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 });
        }
        chunk(out, &pos, "fmt ", fmt[0..if (extensible) 40 else 16], endian);
        chunk(out, &pos, "JUNK", "x", endian);
        var pcm: [16]u8 = @splat(0);
        if (kind == 9) std.mem.writeInt(u32, pcm[0..4], 0x7fc00000, endian);
        chunk(out, &pos, "data", pcm[0 .. bits / 4], endian);
        chunk(out, &pos, "bext", "door\x00hit\xff", endian);
        chunk(out, &pos, "iXML", "<BWFXML><NOTE>golpe 日本語</NOTE></BWFXML>", endian);
        chunk(out, &pos, "_PMX", "\x00\xff<> & hostile", endian);
        chunk(out, &pos, "LIST", "INFOINAM\x05\x00\x00\x00swish\x00", endian);
    }
    std.mem.writeInt(u32, out[4..8], @intCast(pos - 8), endian);
    return pos;
}

fn durationProperties(seed: u64, iterations: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (0..iterations) |i| {
        const a = if (i < 4) @as(i32, @intCast(i)) else random.intRangeAtMost(i32, 0, std.math.maxInt(i32));
        const b = if (i < 4) std.math.maxInt(i32) - @as(i32, @intCast(i)) else random.intRangeAtMost(i32, 0, std.math.maxInt(i32));
        const c = random.intRangeAtMost(i32, 0, std.math.maxInt(i32));
        const ops = "<=>";
        const op1 = ops[random.uintLessThan(usize, 3)];
        const op2 = ops[random.uintLessThan(usize, 3)];
        var buf: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "impact {c}{d}ms {c}{d}ms", .{ op1, a, op2, b });
        const parsed = search.parseSearchQuery(text);
        var reverse_buf: [256]u8 = undefined;
        const reverse = search.parseSearchQuery(try std.fmt.bufPrint(&reverse_buf, "impact {c}{d}ms {c}{d}ms", .{ op2, b, op1, a }));
        if (parsed.min_ms != reverse.min_ms or parsed.max_ms != reverse.max_ms or parsed.impossible != reverse.impossible) return error.FilterOrderDependence;
        for ([_]i32{ 0, 1, a, a -| 1, a +| 1, a -| 250, a +| 250, b, b -| 1, b +| 1, b -| 250, b +| 250, c, std.math.maxInt(i32) }) |ms| {
            const expected = ms > 0 and predicate(ms, op1, a) and predicate(ms, op2, b);
            const actual = !parsed.impossible and ms >= parsed.min_ms and (parsed.max_ms == 0 or ms <= parsed.max_ms);
            if (expected != actual) return error.FilterIntersectionMismatch;
        }
        if (!std.mem.eql(u8, parsed.text.slice(), "impact")) return error.FilterTextMismatch;
        const number = try std.fmt.bufPrint(&buf, "{d}ms", .{a});
        if (search.parseDurationMs(number) != a) return error.DurationRoundTrip;
    }
}

fn predicate(ms: i32, op: u8, value: i32) bool {
    return switch (op) {
        '<' => ms < value,
        '>' => ms > value,
        '=' => @abs(@as(i64, ms) - value) <= 250,
        else => unreachable,
    };
}

test "generated duration filters intersect independent of order" {
    try durationProperties(0x5753, 4096);
}
