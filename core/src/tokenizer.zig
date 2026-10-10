const std = @import("std");

pub const DEFAULT_MAX_TOKENS: usize = 77;
pub const MAX_TOKENIZER_JSON_BYTES: usize = 256 * 1024 * 1024;
/// Bump whenever token segmentation, byte mapping, truncation, or BPE behavior
/// changes in a way that can alter CLAP embeddings.
pub const IMPLEMENTATION_REVISION = "roberta-bytelevel-bpe-zig-v1";

const Pair = struct {
    left: []const u8,
    right: []const u8,
};

const PairContext = struct {
    pub fn hash(_: PairContext, pair: Pair) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(pair.left);
        const separator = [_]u8{0};
        hasher.update(&separator);
        hasher.update(pair.right);
        return hasher.final();
    }

    pub fn eql(_: PairContext, a: Pair, b: Pair) bool {
        return std.mem.eql(u8, a.left, b.left) and std.mem.eql(u8, a.right, b.right);
    }
};

const MergeMap = std.HashMapUnmanaged(Pair, usize, PairContext, std.hash_map.default_max_load_percentage);

pub const Tokenizer = struct {
    allocator: std.mem.Allocator,
    vocab: std.StringHashMapUnmanaged(i64) = .empty,
    merges: MergeMap = .empty,
    bos_id: i64,
    eos_id: i64,
    pad_id: i64,
    unk_id: ?i64,
    add_prefix_space: bool,

    pub fn initFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Tokenizer {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_TOKENIZER_JSON_BYTES));
        defer allocator.free(bytes);
        return initFromBytes(allocator, bytes);
    }

    pub fn initFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !Tokenizer {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        const root = try expectObject(parsed.value);
        if (root.get("normalizer")) |normalizer| {
            if (normalizer != .null) return error.UnsupportedConfiguration;
        }

        const pre_tokenizer = try expectObject(try required(root, "pre_tokenizer"));
        try expectType(pre_tokenizer, "ByteLevel");
        const add_prefix_space = try optionalBool(pre_tokenizer, "add_prefix_space", false);
        if (!try optionalBool(pre_tokenizer, "use_regex", true)) return error.UnsupportedConfiguration;

        const model = try expectObject(try required(root, "model"));
        try expectType(model, "BPE");
        try validateBpeOptions(model);

        var result = Tokenizer{
            .allocator = allocator,
            .bos_id = undefined,
            .eos_id = undefined,
            .pad_id = undefined,
            .unk_id = null,
            .add_prefix_space = add_prefix_space,
        };
        errdefer result.deinit();

        const vocab = try expectObject(try required(model, "vocab"));
        if (vocab.count() == 0) return error.EmptyVocabulary;
        var seen_ids: std.AutoHashMapUnmanaged(i64, void) = .empty;
        defer seen_ids.deinit(allocator);
        var vocab_it = vocab.iterator();
        while (vocab_it.next()) |entry| {
            const id = try expectTokenId(entry.value_ptr.*);
            const id_entry = try seen_ids.getOrPut(allocator, id);
            if (id_entry.found_existing) return error.DuplicateVocabularyId;

            const owned_token = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(owned_token);
            const token_entry = try result.vocab.getOrPut(allocator, owned_token);
            if (token_entry.found_existing) return error.DuplicateVocabularyToken;
            token_entry.value_ptr.* = id;
        }

        if (model.get("unk_token")) |unk_value| {
            switch (unk_value) {
                .null => {},
                .string => |token| result.unk_id = result.vocab.get(token) orelse return error.InvalidSpecialToken,
                else => return error.MalformedConfiguration,
            }
        }

        const merge_values = try expectArray(try required(model, "merges"));
        for (merge_values.items, 0..) |merge_value, rank| {
            const parts = try parseMerge(merge_value);
            if (result.vocab.get(parts.left) == null or result.vocab.get(parts.right) == null) {
                return error.InconsistentMerge;
            }
            const merged = try std.mem.concat(allocator, u8, &.{ parts.left, parts.right });
            defer allocator.free(merged);
            if (result.vocab.get(merged) == null) return error.InconsistentMerge;

            const owned_left = try allocator.dupe(u8, parts.left);
            errdefer allocator.free(owned_left);
            const owned_right = try allocator.dupe(u8, parts.right);
            errdefer allocator.free(owned_right);
            const pair = Pair{ .left = owned_left, .right = owned_right };
            const merge_entry = try result.merges.getOrPut(allocator, pair);
            if (merge_entry.found_existing) return error.DuplicateMerge;
            merge_entry.value_ptr.* = rank;
        }

        const processor = try expectObject(try required(root, "post_processor"));
        try expectType(processor, "RobertaProcessing");
        const cls = try parseSpecialTuple(try required(processor, "cls"));
        const sep = try parseSpecialTuple(try required(processor, "sep"));
        try result.validateSpecial(cls);
        try result.validateSpecial(sep);
        result.bos_id = cls.id;
        result.eos_id = sep.id;

        var pad = Special{ .token = "<pad>", .id = result.vocab.get("<pad>") orelse return error.InvalidSpecialToken };
        if (root.get("padding")) |padding_value| {
            switch (padding_value) {
                .null => {},
                .object => |padding| {
                    if (padding.get("direction")) |value| {
                        if (!std.mem.eql(u8, try expectString(value), "Right")) return error.UnsupportedConfiguration;
                    }
                    if (padding.get("pad_token")) |value| pad.token = try expectString(value);
                    if (padding.get("pad_id")) |value| pad.id = try expectTokenId(value);
                },
                else => return error.MalformedConfiguration,
            }
        }
        try result.validateSpecial(pad);
        result.pad_id = pad.id;
        if (result.bos_id == result.eos_id or result.bos_id == result.pad_id or result.eos_id == result.pad_id) {
            return error.InvalidSpecialToken;
        }

        if (root.get("added_tokens")) |added| try result.validateAddedTokens(try expectArray(added));
        return result;
    }

    pub fn deinit(self: *Tokenizer) void {
        var vocab_it = self.vocab.iterator();
        while (vocab_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.vocab.deinit(self.allocator);

        var merges_it = self.merges.iterator();
        while (merges_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.left);
            self.allocator.free(entry.key_ptr.right);
        }
        self.merges.deinit(self.allocator);
        self.* = undefined;
    }

    /// Encodes exactly DEFAULT_MAX_TOKENS entries into the starts of `ids` and
    /// `attention_mask`. Extra caller capacity is left untouched.
    pub fn encode(self: *const Tokenizer, query: []const u8, ids: []i64, attention_mask: []i64) !void {
        return self.encodeMax(query, DEFAULT_MAX_TOKENS, ids, attention_mask);
    }

    /// Encodes a single RoBERTa sequence as BOS, content, EOS, then right
    /// padding. Content that does not fit is truncated before EOS.
    pub fn encodeMax(
        self: *const Tokenizer,
        query: []const u8,
        max_tokens: usize,
        ids: []i64,
        attention_mask: []i64,
    ) !void {
        if (max_tokens < 2) return error.InvalidMaxTokens;
        if (ids.len < max_tokens or attention_mask.len < max_tokens) return error.OutputBufferTooSmall;
        if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidUtf8;

        const output_ids = ids[0..max_tokens];
        const output_mask = attention_mask[0..max_tokens];
        const ids_start = @intFromPtr(output_ids.ptr);
        const mask_start = @intFromPtr(output_mask.ptr);
        const byte_len = max_tokens * @sizeOf(i64);
        if (ids_start < mask_start + byte_len and mask_start < ids_start + byte_len) {
            return error.OutputBuffersOverlap;
        }
        @memset(output_ids, self.pad_id);
        @memset(output_mask, 0);
        output_ids[0] = self.bos_id;
        output_mask[0] = 1;

        var prefixed: ?[]u8 = null;
        defer if (prefixed) |buffer| self.allocator.free(buffer);
        var input = query;
        if (self.add_prefix_space and query.len != 0 and query[0] != ' ') {
            const buffer = try self.allocator.alloc(u8, query.len + 1);
            buffer[0] = ' ';
            @memcpy(buffer[1..], query);
            prefixed = buffer;
            input = buffer;
        }

        const content_limit = max_tokens - 2;
        var content_count: usize = 0;
        var offset: usize = 0;
        while (offset < input.len and content_count < content_limit) {
            const piece = nextPretoken(input, &offset);
            try self.encodePiece(piece, output_ids[1 .. 1 + content_limit], &content_count);
        }

        const eos_index = content_count + 1;
        output_ids[eos_index] = self.eos_id;
        @memset(output_mask[0 .. eos_index + 1], 1);
    }

    fn encodePiece(self: *const Tokenizer, piece: []const u8, output: []i64, count: *usize) !void {
        var mapped: std.ArrayList(u8) = .empty;
        defer mapped.deinit(self.allocator);
        var symbols: std.ArrayList(Symbol) = .empty;
        defer symbols.deinit(self.allocator);

        for (piece) |byte| {
            const start = mapped.items.len;
            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(byte_to_unicode[byte], &encoded) catch unreachable;
            try mapped.appendSlice(self.allocator, encoded[0..len]);
            try symbols.append(self.allocator, .{ .start = start, .end = mapped.items.len });
        }

        var scratch: std.ArrayList(Symbol) = .empty;
        defer scratch.deinit(self.allocator);
        while (symbols.items.len > 1) {
            var best_rank: ?usize = null;
            var best_pair: Pair = undefined;
            for (0..symbols.items.len - 1) |index| {
                const pair = Pair{
                    .left = symbols.items[index].slice(mapped.items),
                    .right = symbols.items[index + 1].slice(mapped.items),
                };
                if (self.merges.get(pair)) |rank| {
                    if (best_rank == null or rank < best_rank.?) {
                        best_rank = rank;
                        best_pair = pair;
                    }
                }
            }
            if (best_rank == null) break;

            scratch.clearRetainingCapacity();
            var index: usize = 0;
            while (index < symbols.items.len) {
                if (index + 1 < symbols.items.len and
                    std.mem.eql(u8, symbols.items[index].slice(mapped.items), best_pair.left) and
                    std.mem.eql(u8, symbols.items[index + 1].slice(mapped.items), best_pair.right))
                {
                    try scratch.append(self.allocator, .{
                        .start = symbols.items[index].start,
                        .end = symbols.items[index + 1].end,
                    });
                    index += 2;
                } else {
                    try scratch.append(self.allocator, symbols.items[index]);
                    index += 1;
                }
            }
            std.mem.swap(std.ArrayList(Symbol), &symbols, &scratch);
        }

        for (symbols.items) |symbol| {
            if (count.* == output.len) return;
            output[count.*] = self.vocab.get(symbol.slice(mapped.items)) orelse self.unk_id orelse return error.UnknownToken;
            count.* += 1;
        }
    }

    fn validateSpecial(self: *const Tokenizer, special: Special) !void {
        const actual = self.vocab.get(special.token) orelse return error.InvalidSpecialToken;
        if (actual != special.id) return error.InvalidSpecialToken;
    }

    fn validateAddedTokens(self: *const Tokenizer, added: std.json.Array) !void {
        for (added.items) |value| {
            const object = try expectObject(value);
            const id = try expectTokenId(try required(object, "id"));
            const content = try expectString(try required(object, "content"));
            if (self.vocab.get(content) != id) return error.InconsistentAddedToken;
            const special = object.get("special") orelse return error.MalformedConfiguration;
            switch (special) {
                .bool => |is_special| if (!is_special) return error.UnsupportedConfiguration,
                else => return error.MalformedConfiguration,
            }
        }
    }
};

const Symbol = struct {
    start: usize,
    end: usize,

    fn slice(self: Symbol, bytes: []const u8) []const u8 {
        return bytes[self.start..self.end];
    }
};

const Special = struct {
    token: []const u8,
    id: i64,
};

const MergeParts = struct {
    left: []const u8,
    right: []const u8,
};

fn required(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MissingConfigurationField;
}

fn expectObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.MalformedConfiguration,
    };
}

fn expectArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.MalformedConfiguration,
    };
}

fn expectString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.MalformedConfiguration,
    };
}

fn expectTokenId(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |integer| if (integer >= 0) integer else error.InvalidTokenId,
        else => error.InvalidTokenId,
    };
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8, default: bool) !bool {
    const value = object.get(name) orelse return default;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.MalformedConfiguration,
    };
}

fn expectType(object: std.json.ObjectMap, expected: []const u8) !void {
    const actual = try expectString(try required(object, "type"));
    if (!std.mem.eql(u8, actual, expected)) return error.UnsupportedConfiguration;
}

fn validateBpeOptions(model: std.json.ObjectMap) !void {
    if (model.get("dropout")) |value| switch (value) {
        .null => {},
        .float => |number| if (number != 0) return error.UnsupportedConfiguration,
        .integer => |number| if (number != 0) return error.UnsupportedConfiguration,
        else => return error.MalformedConfiguration,
    };
    if (try optionalBool(model, "byte_fallback", false)) return error.UnsupportedConfiguration;
    if (try optionalBool(model, "fuse_unk", false)) return error.UnsupportedConfiguration;
    if (try optionalBool(model, "ignore_merges", false)) return error.UnsupportedConfiguration;
    for ([_][]const u8{ "continuing_subword_prefix", "end_of_word_suffix" }) |name| {
        if (model.get(name)) |value| switch (value) {
            .null => {},
            .string => |string| if (string.len != 0) return error.UnsupportedConfiguration,
            else => return error.MalformedConfiguration,
        };
    }
}

fn parseSpecialTuple(value: std.json.Value) !Special {
    const tuple = try expectArray(value);
    if (tuple.items.len != 2) return error.MalformedConfiguration;
    return .{
        .token = try expectString(tuple.items[0]),
        .id = try expectTokenId(tuple.items[1]),
    };
}

fn parseMerge(value: std.json.Value) !MergeParts {
    switch (value) {
        .array => |parts| {
            if (parts.items.len != 2) return error.MalformedMerge;
            const left = try expectString(parts.items[0]);
            const right = try expectString(parts.items[1]);
            if (left.len == 0 or right.len == 0) return error.MalformedMerge;
            return .{ .left = left, .right = right };
        },
        .string => |merge| {
            const separator = std.mem.indexOfScalar(u8, merge, ' ') orelse return error.MalformedMerge;
            if (separator == 0 or separator + 1 == merge.len) return error.MalformedMerge;
            if (std.mem.indexOfScalar(u8, merge[separator + 1 ..], ' ') != null) return error.MalformedMerge;
            return .{ .left = merge[0..separator], .right = merge[separator + 1 ..] };
        },
        else => return error.MalformedMerge,
    }
}

const Category = enum { letter, number, whitespace, other };

fn nextPretoken(input: []const u8, offset: *usize) []const u8 {
    const start = offset.*;

    if (input[start] == '\'') {
        const contractions = [_][]const u8{ "'s", "'t", "'re", "'ve", "'m", "'ll", "'d" };
        for (contractions) |contraction| {
            if (std.mem.startsWith(u8, input[start..], contraction)) {
                offset.* += contraction.len;
                return input[start..offset.*];
            }
        }
    }

    var cursor = start;
    if (input[cursor] == ' ' and cursor + 1 < input.len) {
        const next = codepointAt(input, cursor + 1);
        const category = classify(next.codepoint);
        if (category != .whitespace) {
            cursor += 1;
            while (cursor < input.len) {
                const current = codepointAt(input, cursor);
                if (classify(current.codepoint) != category) break;
                cursor += current.len;
            }
            offset.* = cursor;
            return input[start..cursor];
        }
    }

    const first = codepointAt(input, cursor);
    const category = classify(first.codepoint);
    cursor += first.len;
    if (category != .whitespace) {
        while (cursor < input.len) {
            const current = codepointAt(input, cursor);
            if (classify(current.codepoint) != category) break;
            cursor += current.len;
        }
        offset.* = cursor;
        return input[start..cursor];
    }

    var last_start = start;
    while (cursor < input.len) {
        const current = codepointAt(input, cursor);
        if (classify(current.codepoint) != .whitespace) break;
        last_start = cursor;
        cursor += current.len;
    }
    if (cursor < input.len and last_start != start) {
        offset.* = last_start;
        return input[start..last_start];
    }
    offset.* = cursor;
    return input[start..cursor];
}

const Codepoint = struct { codepoint: u21, len: usize };

fn codepointAt(input: []const u8, offset: usize) Codepoint {
    const len = std.unicode.utf8ByteSequenceLength(input[offset]) catch unreachable;
    return .{
        .codepoint = std.unicode.utf8Decode(input[offset .. offset + len]) catch unreachable,
        .len = len,
    };
}

fn classify(codepoint: u21) Category {
    if (isWhitespace(codepoint)) return .whitespace;
    if (isNumber(codepoint)) return .number;
    if (codepoint < 128) return if (std.ascii.isAlphabetic(@intCast(codepoint))) .letter else .other;
    if (isUnicodeMarkPunctuationOrSymbol(codepoint)) return .other;
    return .letter;
}

fn isWhitespace(cp: u21) bool {
    return (cp >= 0x09 and cp <= 0x0d) or cp == 0x20 or cp == 0x85 or cp == 0xa0 or
        cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x2028 or cp == 0x2029 or
        cp == 0x202f or cp == 0x205f or cp == 0x3000;
}

fn isNumber(cp: u21) bool {
    const decimal_starts = [_]u21{
        0x30,    0x660,   0x6f0,   0x7c0,   0x966,   0x9e6,   0xa66,   0xae6,
        0xb66,   0xbe6,   0xc66,   0xce6,   0xd66,   0xde6,   0xe50,   0xed0,
        0xf20,   0x1040,  0x1090,  0x17e0,  0x1810,  0x1946,  0x19d0,  0x1a80,
        0x1a90,  0x1b50,  0x1bb0,  0x1c40,  0x1c50,  0xa620,  0xa8d0,  0xa900,
        0xa9d0,  0xa9f0,  0xaa50,  0xabf0,  0xff10,  0x104a0, 0x10d30, 0x11066,
        0x110f0, 0x11136, 0x111d0, 0x112f0, 0x11450, 0x114d0, 0x11650, 0x116c0,
        0x11730, 0x118e0, 0x11950, 0x11c50, 0x11d50, 0x11da0, 0x16a60, 0x16ac0,
        0x16b50, 0x1d7ce, 0x1e140, 0x1e2f0, 0x1e950,
    };
    for (decimal_starts) |start| if (cp >= start and cp <= start + 9) return true;
    return (cp >= 0x00b2 and cp <= 0x00b3) or cp == 0x00b9 or
        (cp >= 0x00bc and cp <= 0x00be) or (cp >= 0x2160 and cp <= 0x2188) or
        (cp >= 0x2460 and cp <= 0x249b);
}

fn isUnicodeMarkPunctuationOrSymbol(cp: u21) bool {
    return (cp >= 0x00a1 and cp <= 0x00a9) or cp == 0x00ab or cp == 0x00ac or
        (cp >= 0x00ae and cp <= 0x00b1) or cp == 0x00b4 or (cp >= 0x00b6 and cp <= 0x00b8) or
        cp == 0x00bb or cp == 0x00bf or cp == 0x00d7 or cp == 0x00f7 or
        (cp >= 0x0300 and cp <= 0x036f) or (cp >= 0x0483 and cp <= 0x0489) or
        (cp >= 0x0591 and cp <= 0x05c7) or (cp >= 0x0610 and cp <= 0x061a) or
        (cp >= 0x064b and cp <= 0x065f) or (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or (cp >= 0x2000 and cp <= 0x206f) or
        (cp >= 0x20a0 and cp <= 0x214f) or (cp >= 0x2190 and cp <= 0x2bff) or
        (cp >= 0x2e00 and cp <= 0x2e7f) or (cp >= 0x3001 and cp <= 0x303f) or
        (cp >= 0xfe00 and cp <= 0xfe6f) or (cp >= 0xff01 and cp <= 0xff0f) or
        (cp >= 0xff1a and cp <= 0xff20) or (cp >= 0xff3b and cp <= 0xff40) or
        (cp >= 0xff5b and cp <= 0xff65) or (cp >= 0x1f000 and cp <= 0x1faff) or
        (cp >= 0xe0100 and cp <= 0xe01ef);
}

fn isDirectByteCodepoint(byte: u8) bool {
    return (byte >= '!' and byte <= '~') or (byte >= 0xa1 and byte <= 0xac) or (byte >= 0xae);
}

const byte_to_unicode: [256]u21 = block: {
    var table: [256]u21 = undefined;
    var extra: u21 = 0;
    for (0..256) |index| {
        const byte: u8 = @intCast(index);
        if (isDirectByteCodepoint(byte)) {
            table[index] = byte;
        } else {
            table[index] = 256 + extra;
            extra += 1;
        }
    }
    break :block table;
};

const fixture_json =
    \\{
    \\  "version":"1.0",
    \\  "truncation":null,
    \\  "padding":null,
    \\  "added_tokens":[
    \\    {"id":0,"content":"<s>","special":true},
    \\    {"id":1,"content":"<pad>","special":true},
    \\    {"id":2,"content":"</s>","special":true},
    \\    {"id":3,"content":"<unk>","special":true}
    \\  ],
    \\  "pre_tokenizer":{"type":"ByteLevel","add_prefix_space":false,"trim_offsets":true,"use_regex":true},
    \\  "post_processor":{"type":"RobertaProcessing","sep":["</s>",2],"cls":["<s>",0],"trim_offsets":true,"add_prefix_space":false},
    \\  "decoder":{"type":"ByteLevel"},
    \\  "model":{
    \\    "type":"BPE","dropout":null,"unk_token":"<unk>","continuing_subword_prefix":"","end_of_word_suffix":"","fuse_unk":false,"byte_fallback":false,
    \\    "vocab":{"<s>":0,"<pad>":1,"</s>":2,"<unk>":3,"h":4,"e":5,"l":6,"o":7,"Ġ":8,"w":9,"r":10,"d":11,"!":12,"'":13,"s":14,",":15,"Ã":16,"©":17,"Ã©":18,"he":19,"hel":20,"hell":21,"hello":22,"Ġw":23,"Ġwo":24,"Ġwor":25,"Ġworl":26,"Ġworld":27,"'s":28,"!!":29,"1":30,"2":31,"12":32,"a":33,"a1":34},
    \\    "merges":["a 1","1 2","h e","he l","hel l","hell o","Ġ w","Ġw o","Ġwo r","Ġwor l","Ġworl d","' s","Ã ©",["!","!"]]
    \\  }
    \\}
;

fn expectEncoding(tokenizer: *const Tokenizer, query: []const u8, max_tokens: usize, expected: []const i64) !void {
    const allocator = std.testing.allocator;
    const ids = try allocator.alloc(i64, max_tokens);
    defer allocator.free(ids);
    const mask = try allocator.alloc(i64, max_tokens);
    defer allocator.free(mask);
    try tokenizer.encodeMax(query, max_tokens, ids, mask);
    try std.testing.expectEqualSlices(i64, expected, ids);
    var expected_mask = try allocator.alloc(i64, max_tokens);
    defer allocator.free(expected_mask);
    @memset(expected_mask, 0);
    // Padding is ID 1 in this fixture; count through EOS instead of relying on IDs.
    const eos = std.mem.indexOfScalar(i64, expected, 2).?;
    @memset(expected_mask[0 .. eos + 1], 1);
    try std.testing.expectEqualSlices(i64, expected_mask, mask);
}

test "byte-level BPE spaces punctuation contractions UTF-8 and padding" {
    var tokenizer = try Tokenizer.initFromBytes(std.testing.allocator, fixture_json);
    defer tokenizer.deinit();

    try expectEncoding(&tokenizer, "hello world!", 9, &.{ 0, 22, 27, 12, 2, 1, 1, 1, 1 });
    try expectEncoding(&tokenizer, "hello's!!", 9, &.{ 0, 22, 28, 29, 2, 1, 1, 1, 1 });
    try expectEncoding(&tokenizer, "é", 6, &.{ 0, 18, 2, 1, 1, 1 });
    try expectEncoding(&tokenizer, "?", 5, &.{ 0, 3, 2, 1, 1 });
    try expectEncoding(&tokenizer, "a12", 6, &.{ 0, 33, 32, 2, 1, 1 });
    try expectEncoding(&tokenizer, " hello", 7, &.{ 0, 8, 22, 2, 1, 1, 1 });
    try expectEncoding(&tokenizer, "hello, world", 8, &.{ 0, 22, 15, 27, 2, 1, 1, 1 });
}

test "tokenizer truncates content and validates output and UTF-8" {
    var tokenizer = try Tokenizer.initFromBytes(std.testing.allocator, fixture_json);
    defer tokenizer.deinit();

    try expectEncoding(&tokenizer, "hello world!!", 4, &.{ 0, 22, 27, 2 });
    var ids: [77]i64 = undefined;
    var short_mask: [76]i64 = undefined;
    try std.testing.expectError(error.OutputBufferTooSmall, tokenizer.encode("hello", &ids, &short_mask));
    try std.testing.expectError(error.InvalidMaxTokens, tokenizer.encodeMax("hello", 1, &ids, &ids));
    try std.testing.expectError(error.InvalidUtf8, tokenizer.encodeMax("\xff", 4, &ids, &ids));
    try std.testing.expectError(error.OutputBuffersOverlap, tokenizer.encodeMax("hello", 4, &ids, &ids));
}

test "tokenizer loads from a file and owns parsed strings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tokenizer.json", .data = fixture_json });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "tokenizer.json", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var tokenizer = try Tokenizer.initFromFile(std.testing.allocator, std.testing.io, path);
    defer tokenizer.deinit();
    try expectEncoding(&tokenizer, "hello", 5, &.{ 0, 22, 2, 1, 1 });
}

test "tokenizer rejects malformed and unsupported configurations" {
    try std.testing.expectError(error.UnsupportedConfiguration, Tokenizer.initFromBytes(
        std.testing.allocator,
        "{\"pre_tokenizer\":{\"type\":\"Whitespace\"},\"model\":{\"type\":\"BPE\"},\"post_processor\":{\"type\":\"RobertaProcessing\"}}",
    ));
    try std.testing.expectError(error.DuplicateVocabularyId, Tokenizer.initFromBytes(
        std.testing.allocator,
        "{\"pre_tokenizer\":{\"type\":\"ByteLevel\"},\"model\":{\"type\":\"BPE\",\"vocab\":{\"<s>\":0,\"</s>\":2,\"<pad>\":1,\"x\":1},\"merges\":[]},\"post_processor\":{\"type\":\"RobertaProcessing\",\"cls\":[\"<s>\",0],\"sep\":[\"</s>\",2]}}",
    ));
    try std.testing.expectError(error.InvalidSpecialToken, Tokenizer.initFromBytes(
        std.testing.allocator,
        "{\"pre_tokenizer\":{\"type\":\"ByteLevel\"},\"model\":{\"type\":\"BPE\",\"vocab\":{\"<s>\":0,\"</s>\":2,\"<pad>\":1},\"merges\":[]},\"post_processor\":{\"type\":\"RobertaProcessing\",\"cls\":[\"<s>\",9],\"sep\":[\"</s>\",2]}}",
    ));
    try std.testing.expectError(error.InvalidUtf8, Tokenizer.initFromBytes(std.testing.allocator, "\xff"));
    try std.testing.expectError(error.UnexpectedEndOfInput, Tokenizer.initFromBytes(std.testing.allocator, "{"));
}
