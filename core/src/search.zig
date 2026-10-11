const std = @import("std");
const db = @import("db.zig");
const types = @import("types.zig");
const audio = @import("audio.zig");
const audio_file = @import("audio_file.zig");
const semantic = @import("semantic.zig");
const vector = @import("vector.zig");
const ranking = @import("ranking.zig");
const query_cancel = @import("query.zig");
const text_mod = @import("text.zig");
const isDelimiter = text_mod.isDelimiter;
const normalizeText = text_mod.normalize;

const AUDIO_EXTENSIONS = [_][]const u8{ ".wav", ".aiff", ".aif", ".aifc", ".mp3", ".flac", ".ogg", ".m4a" };
pub const MAX_QUERY_LEN = 1024;
const MAX_CANDIDATES = 256;

pub const IndexOptions = struct {
    deep: bool = false,
    fast: bool = false,
    cancel: ?*const std.atomic.Value(bool) = null,
    discovered: ?*std.atomic.Value(u64) = null,
};

pub fn indexFolder(allocator: std.mem.Allocator, folder_id: i32, path: []const u8) !void {
    return indexFolderWithOptions(allocator, folder_id, path, .{});
}

pub fn indexFolderWithOptions(allocator: std.mem.Allocator, folder_id: i32, path: []const u8, options: IndexOptions) !void {
    // The expensive and failure-prone filesystem/audio scan happens before the
    // write transaction. WAL readers see an atomic old-or-new catalog throughout
    // publication, without waiting for the indexing connection's transaction.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stage = try db.IndexStage.init(folder_id, options.cancel);
    defer stage.deinit();

    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var full_path: std.ArrayList(u8) = .empty;
    defer full_path.deinit(allocator);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(allocator);

    while (true) {
        if (options.cancel) |token| if (token.load(.acquire)) return error.Cancelled;
        // An incomplete walk must not become an authoritative snapshot: doing
        // so would delete previously indexed files from an inaccessible subtree.
        const entry = (try walker.next(io)) orelse break;
        if (entry.kind != .file or !isAudioFile(entry.basename)) continue;

        full_path.clearRetainingCapacity();
        try full_path.appendSlice(allocator, path);
        if (!std.mem.endsWith(u8, path, "/")) try full_path.append(allocator, '/');
        try full_path.appendSlice(allocator, entry.path);

        var file = try std.Io.Dir.openFileAbsolute(io, full_path.items, .{});
        defer file.close(io);
        const stat = try file.stat(io);

        const file_size: i64 = @intCast(@min(stat.size, @as(u64, std.math.maxInt(i64))));
        const mtime_ns: i64 = @intCast(stat.mtime.nanoseconds);
        if (options.discovered) |counter| _ = counter.fetchAdd(1, .monotonic);
        if (!options.deep and try stage.retainIfUnchanged(entry.path, file_size, mtime_ns)) continue;

        text.clearRetainingCapacity();
        try appendNormalizedPathText(allocator, &text, entry.path);
        const wav = std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.path), ".wav");
        const prefix_limit: u64 = if (wav and !options.fast) 2 * 1024 * 1024 else FAST_HASH_BLOCK_SIZE;
        try prefix.resize(allocator, @intCast(@min(stat.size, prefix_limit)));
        if (try file.readPositionalAll(io, prefix.items, 0) != prefix.items.len) return error.FileChangedDuringScan;
        const reader = audio_file.Reader{ .handle = &file, .io = io, .size = stat.size, .prefix = prefix.items };
        if (wav) {
            if (options.fast)
                audio.appendMetadataTextFromFileSparse(allocator, &text, reader, 256 * 1024) catch {}
            else
                audio.appendMetadataTextFromFileLimit(allocator, &text, reader, 2 * 1024 * 1024) catch {};
        }
        const duration_ms = audio.durationMsFromFile(reader, full_path.items) catch 0;
        const content_hash = try contentHash(reader, options.deep, options.fast, file_size, mtime_ns, options.cancel);
        // Reusing a descriptor must not hide a file replaced at its path
        // while we inspected it, even if its size and mtime were preserved.
        const current = std.Io.Dir.cwd().statFile(io, full_path.items, .{}) catch return error.FileChangedDuringScan;
        if (current.inode != stat.inode or current.size != stat.size or
            current.mtime.nanoseconds != stat.mtime.nanoseconds or
            current.ctime.nanoseconds != stat.ctime.nanoseconds) return error.FileChangedDuringScan;

        try stage.append(.{
            .path = full_path.items,
            .relative_path = entry.path,
            .name = entry.basename,
            .search_text = text.items,
            .duration_ms = duration_ms,
            .content_hash = content_hash,
            .file_size = file_size,
            .mtime_ns = mtime_ns,
        });
    }

    // Stage's primary-key traversal gives deterministic fresh IDs without a
    // second manifest, duplicated strings, publication array or in-memory sort.
    if (options.cancel) |token| if (token.load(.acquire)) return error.Cancelled;
    try stage.publishAtRoot(path, options.cancel);
}

pub const QueryBuf = text_mod.QueryBuf;

pub fn buildQuery(input: []const u8) QueryBuf {
    return buildFtsQuery(input, true);
}

fn buildFtsQuery(input: []const u8, expand_synonyms: bool) QueryBuf {
    var q = QueryBuf{};
    var token: [96]u8 = undefined;
    var token_len: usize = 0;
    var prev: u8 = 0;
    for (input) |raw| {
        const ch = std.ascii.toLower(raw);
        const camel_boundary = token_len > 0 and std.ascii.isUpper(raw) and std.ascii.isLower(prev);
        if (isDelimiter(ch) or camel_boundary) {
            appendQueryToken(&q, token[0..token_len], expand_synonyms);
            token_len = 0;
        }
        if (!isDelimiter(ch) and token_len < token.len) {
            token[token_len] = ch;
            token_len += 1;
        }
        prev = raw;
    }
    appendQueryToken(&q, token[0..token_len], expand_synonyms);
    return q;
}

fn appendQueryToken(q: *QueryBuf, token: []const u8, expand_synonyms: bool) void {
    if (token.len == 0) return;
    const syns: SynonymList = if (expand_synonyms) synonymsFor(token) else &.{};
    var needed: usize = token.len + 3; // quoted token plus '*'
    if (syns.len > 0) {
        needed += 2; // parentheses
        for (syns) |syn| needed += 4 + syn.len + 3; // " OR " and quoted prefix
    }
    if (q.len > 0) needed += 5; // " AND "
    // Never leave a syntactically incomplete FTS expression at the fixed cap.
    if (needed > q.buf.len - q.len) return;

    if (q.len > 0) appendSlice(q, " AND ");
    if (syns.len == 0) {
        appendQuotedPrefix(q, token);
        return;
    }
    appendByte(q, '(');
    appendQuotedPrefix(q, token);
    for (syns) |syn| {
        appendSlice(q, " OR ");
        appendQuotedPrefix(q, syn);
    }
    appendByte(q, ')');
}

fn appendQuotedPrefix(q: *QueryBuf, token: []const u8) void {
    appendByte(q, '"');
    for (token) |b| {
        if (b == '"') appendByte(q, '"');
        appendByte(q, b);
    }
    appendSlice(q, "\"*");
}

fn appendByte(q: *QueryBuf, b: u8) void {
    if (q.len < q.buf.len) {
        q.buf[q.len] = b;
        q.len += 1;
    }
}
fn appendSlice(q: *QueryBuf, s: []const u8) void {
    for (s) |b| appendByte(q, b);
}

const SynonymList = []const []const u8;
fn synonymsFor(token: []const u8) SynonymList {
    if (std.mem.eql(u8, token, "hit")) return &.{ "impact", "slam", "thud", "punch" };
    if (std.mem.eql(u8, token, "impact")) return &.{ "hit", "slam", "thud", "punch" };
    if (std.mem.eql(u8, token, "whoosh") or std.mem.eql(u8, token, "woosh")) return &.{ "swish", "swoosh", "passby" };
    if (std.mem.eql(u8, token, "riser")) return &.{ "rise", "swell", "build" };
    if (std.mem.eql(u8, token, "swell")) return &.{ "riser", "rise", "build" };
    if (std.mem.eql(u8, token, "downer")) return &.{ "drop", "fall", "descend" };
    if (std.mem.eql(u8, token, "ambience") or std.mem.eql(u8, token, "amb")) return &.{ "ambient", "atmos", "atmosphere" };
    if (std.mem.eql(u8, token, "drone")) return &.{ "tone", "bed", "ambience" };
    return &.{};
}

pub const ParsedQuery = struct {
    text: QueryBuf,
    min_ms: i32 = 0,
    max_ms: i32 = 0,
    impossible: bool = false,
};

pub fn parseSearchQuery(query: []const u8) ParsedQuery {
    var parsed = ParsedQuery{ .text = QueryBuf{} };
    var it = std.mem.tokenizeAny(u8, query, " \t\n\r");
    while (it.next()) |part| {
        if (parseDurationFilter(part)) |filter| {
            switch (filter.op) {
                .lt => {
                    if (filter.ms == 0) {
                        parsed.impossible = true;
                    } else {
                        const exclusive_max = filter.ms - 1;
                        parsed.max_ms = if (parsed.max_ms == 0) exclusive_max else @min(parsed.max_ms, exclusive_max);
                    }
                },
                .gt => {
                    if (filter.ms == std.math.maxInt(i32)) {
                        parsed.impossible = true;
                    } else {
                        parsed.min_ms = @max(parsed.min_ms, filter.ms + 1);
                    }
                },
                .eq => {
                    parsed.min_ms = @max(0, filter.ms -| 250);
                    parsed.max_ms = filter.ms +| 250;
                },
            }
        } else {
            if (parsed.text.len > 0) appendByte(&parsed.text, ' ');
            appendSlice(&parsed.text, part);
        }
    }
    if (parsed.max_ms != 0 and parsed.min_ms > parsed.max_ms) parsed.impossible = true;
    return parsed;
}

const DurationOp = enum { lt, gt, eq };
const DurationFilter = struct { op: DurationOp, ms: i32 };

pub fn parseDurationFilter(token: []const u8) ?DurationFilter {
    if (token.len < 2) return null;
    const op: DurationOp = switch (token[0]) {
        '<' => .lt,
        '>' => .gt,
        '=' => .eq,
        else => return null,
    };
    const ms = parseDurationMs(token[1..]) orelse return null;
    if (ms < 0) return null;
    return .{ .op = op, .ms = ms };
}

pub fn parseDurationMs(value: []const u8) ?i32 {
    if (value.len == 0) return null;
    if (std.mem.endsWith(u8, value, "ms")) {
        const milliseconds = std.fmt.parseInt(i32, value[0 .. value.len - 2], 10) catch return null;
        return if (milliseconds >= 0) milliseconds else null;
    }
    const raw = if (std.mem.endsWith(u8, value, "s")) value[0 .. value.len - 1] else value;
    const seconds = std.fmt.parseFloat(f64, raw) catch return null;
    if (!std.math.isFinite(seconds) or seconds < 0 or seconds > @as(f64, @floatFromInt(std.math.maxInt(i32))) / 1000.0) return null;
    return @intFromFloat(seconds * 1000.0);
}

// Keep sortable records small. Sorting Candidate values directly makes Zig's
// generic sort reserve more than a dispatch worker's stack because Candidate
// contains fixed path/name/search buffers.
const Ranked = struct {
    candidate_index: usize,
    class: u8,
    bm25: f64,
};

pub fn search(allocator: std.mem.Allocator, query: []const u8, folder_id: ?i32, out: [*]types.WSResult, max: usize) !usize {
    if (max == 0) return 0;
    const rows = try lexicalRows(allocator, query, folder_id, max);
    defer allocator.free(rows);
    return copyResults(rows, out, max);
}

fn lexicalRows(allocator: std.mem.Allocator, query: []const u8, folder_id: ?i32, limit: usize) ![]db.Candidate {
    try query_cancel.check();
    if (query.len > 4096) return error.QueryTooLong;
    const request = query_cancel.current;
    const revision = try db.catalogRevision();
    if (request) |r| if (r.lexical) |cache| {
        if (std.meta.eql(cache.revision, revision) and cache.folder_id == folder_id and cache.limit >= limit and std.mem.eql(u8, cache.query, query))
            return allocator.dupe(db.Candidate, cache.rows[0..@min(limit, cache.rows.len)]);
    };
    if (request == null) {
        const rows = try fetchLexicalRows(allocator, query, folder_id, limit);
        return allocator.realloc(rows, @min(limit, rows.len));
    }
    const stage_limit = @max(limit, MAX_CANDIDATES);
    const rows = try fetchLexicalRows(std.heap.c_allocator, query, folder_id, stage_limit);
    var cached = false;
    defer if (!cached) std.heap.c_allocator.free(rows);
    if (request) |r| {
        r.lexical_builds += 1;
        r.clearLexical();
        // ponytail: cache at most one bounded lexical stage per request, not a
        // global result cache with invalidation/eviction machinery.
        if (stage_limit <= MAX_CANDIDATES * 2 and std.meta.eql(revision, try db.catalogRevision())) {
            const owned_query = try std.heap.c_allocator.dupe(u8, query);
            errdefer std.heap.c_allocator.free(owned_query);
            r.lexical = .{
                .query = owned_query,
                .folder_id = folder_id,
                .limit = stage_limit,
                .revision = revision,
                .rows = rows,
            };
            cached = true;
        }
    }
    return allocator.dupe(db.Candidate, rows[0..@min(limit, rows.len)]);
}

fn fetchLexicalRows(allocator: std.mem.Allocator, query: []const u8, folder_id: ?i32, limit: usize) ![]db.Candidate {
    try query_cancel.check();
    const parsed = parseSearchQuery(query);
    if (parsed.impossible) return allocator.alloc(db.Candidate, 0);
    const raw_text = parsed.text.slice();
    if (raw_text.len == 0) {
        if (parsed.min_ms == 0 and parsed.max_ms == 0) return allocator.alloc(db.Candidate, 0);
        return db.durationCandidates(allocator, parsed.min_ms, parsed.max_ms, folder_id, limit);
    }

    const fts = buildFtsQuery(raw_text, false);
    const normalized = normalizeText(raw_text);
    if (fts.isEmpty()) return allocator.alloc(db.Candidate, 0);
    var candidates: std.ArrayList(db.Candidate) = .empty;
    defer candidates.deinit(allocator);
    var ranked: std.ArrayList(Ranked) = .empty;
    defer ranked.deinit(allocator);
    var seen: std.AutoHashMap(i32, usize) = .init(allocator);
    defer seen.deinit();

    const candidate_limit = @min(MAX_CANDIDATES, @max(limit * 4, @as(usize, 32)));
    const exact = try db.exactNameCandidates(allocator, normalized.slice(), .{ .folder_id = folder_id, .min_duration_ms = parsed.min_ms, .max_duration_ms = parsed.max_ms }, candidate_limit);
    defer allocator.free(exact);
    for (exact) |*row| try addRanked(allocator, &candidates, &ranked, &seen, row, 0);
    if (!(exact.len > 0 and limit == 1)) {
        const primary = try db.unicodeCandidates(allocator, fts.slice(), parsed.min_ms, parsed.max_ms, folder_id, candidate_limit);
        defer allocator.free(primary);
        for (primary) |*row| try addRanked(allocator, &candidates, &ranked, &seen, row, classify(normalized.slice(), row, true) orelse 3);
        const expanded = buildQuery(raw_text);
        if (primary.len < candidate_limit and !(exact.len > 0 and std.fs.path.extension(raw_text).len > 0) and !std.mem.eql(u8, expanded.slice(), fts.slice())) {
            const synonyms = try db.unicodeCandidates(allocator, expanded.slice(), parsed.min_ms, parsed.max_ms, folder_id, candidate_limit);
            defer allocator.free(synonyms);
            for (synonyms) |*row| try addRanked(allocator, &candidates, &ranked, &seen, row, classify(normalized.slice(), row, true) orelse 3);
        }
    }

    if (!(exact.len > 0 and (limit == 1 or std.fs.path.extension(raw_text).len > 0)) and ranked.items.len < candidate_limit and normalized.len >= 3) {
        const tri_query = buildTrigramQuery(normalized.slice());
        if (!tri_query.isEmpty()) {
            const fuzzy = try db.trigramCandidates(allocator, tri_query.slice(), parsed.min_ms, parsed.max_ms, folder_id, candidate_limit);
            defer allocator.free(fuzzy);
            for (fuzzy) |*row| {
                try query_cancel.check();
                const class = classify(normalized.slice(), row, false) orelse continue;
                try addRanked(allocator, &candidates, &ranked, &seen, row, class);
            }
        }
    }

    if (ranked.items.len == 0) {
        var words = std.mem.tokenizeScalar(u8, normalized.slice(), ' ');
        var tokens: usize = 0;
        while (words.next()) |word| {
            if (tokens == 4) break;
            tokens += 1;
            const terms = try db.shortTypoTerms(allocator, word);
            defer {
                for (terms) |term| allocator.free(term);
                allocator.free(terms);
            }
            for (terms) |term| {
                const typo_query = buildFtsQuery(term, false);
                const rows = try db.unicodeCandidates(allocator, typo_query.slice(), parsed.min_ms, parsed.max_ms, folder_id, candidate_limit);
                defer allocator.free(rows);
                for (rows) |*row| if (classify(normalized.slice(), row, false)) |class| try addRanked(allocator, &candidates, &ranked, &seen, row, class);
                if (ranked.items.len >= candidate_limit) break;
            }
        }
    }
    std.mem.sort(Ranked, ranked.items, candidates.items, rankedLessThan);
    const count = @min(limit, ranked.items.len);
    const rows = try allocator.alloc(db.Candidate, count);
    for (ranked.items[0..count], rows) |item, *row| row.* = candidates.items[item.candidate_index];
    return rows;
}

const RRF_SCALE: u64 = 1_000_000_000;
const RRF_OFFSET: u64 = 60;
const NO_RANK = std.math.maxInt(usize);

const Fused = struct {
    candidate_index: usize,
    exact: bool,
    tier: u8 = 3,
    score: u64,
    lexical_rank: usize = NO_RANK,
    semantic_rank: usize = NO_RANK,
};

pub fn searchWithEmbedding(
    allocator: std.mem.Allocator,
    query: []const u8,
    query_embedding: []const f32,
    folder_id: ?i32,
    out: [*]types.WSResult,
    max: usize,
) !usize {
    try query_cancel.check();
    try vector.validateNormalized(query_embedding);
    if (max == 0) return 0;
    const parsed = parseSearchQuery(query);
    if (parsed.impossible) return 0;
    const raw_text = parsed.text.slice();
    // A vector is meaningful only for a text-bearing query. Duration-only
    // calls retain the established lexical listing behavior.
    if (raw_text.len == 0) return search(allocator, query, folder_id, out, max);
    const normalized = normalizeText(raw_text);

    const candidate_limit = @min(MAX_CANDIDATES, @max(max * 4, @as(usize, 32)));
    const lexical_revision = try db.catalogRevision();
    const lexical = try lexicalRows(allocator, query, folder_id, candidate_limit);
    defer allocator.free(lexical);
    const maybe_retrieval = try semantic.topK(allocator, query_embedding, .{
        .folder_id = folder_id,
        .min_duration_ms = parsed.min_ms,
        .max_duration_ms = parsed.max_ms,
    }, candidate_limit);
    const retrieval = maybe_retrieval orelse return copyResults(lexical, out, max);
    defer allocator.free(retrieval.matches);

    const semantic_ids = try allocator.alloc(i32, retrieval.matches.len);
    defer allocator.free(semantic_ids);
    for (retrieval.matches, semantic_ids) |match, *id| id.* = match.file_id;
    const semantic_rows = try db.candidatesForSemanticIds(allocator, semantic_ids, retrieval.model_id, retrieval.connection_serial);
    defer allocator.free(semantic_rows);

    var candidates: std.ArrayList(db.Candidate) = .empty;
    defer candidates.deinit(allocator);
    var fused: std.ArrayList(Fused) = .empty;
    defer fused.deinit(allocator);
    var by_id: std.AutoHashMap(i32, usize) = .init(allocator);
    defer by_id.deinit();

    for (lexical, 0..) |row, rank| {
        const index = fused.items.len;
        try candidates.append(allocator, row);
        errdefer _ = candidates.pop();
        try fused.append(allocator, .{
            .candidate_index = candidates.items.len - 1,
            .exact = isExactMatch(normalized.slice(), &row),
            .tier = classify(normalized.slice(), &row, true) orelse 3,
            .score = reciprocalRank(rank),
            .lexical_rank = rank,
        });
        try by_id.put(row.file_id, index);
    }

    const SemanticRank = struct { rank: usize, score: f32, source_hash: i64 };
    var semantic_rank: std.AutoHashMap(i32, SemanticRank) = .init(allocator);
    defer semantic_rank.deinit();
    for (retrieval.matches, 0..) |match, rank| try semantic_rank.put(match.file_id, .{ .rank = rank, .score = match.score, .source_hash = match.source_content_hash });
    for (semantic_rows) |row| {
        const semantic_item = semantic_rank.get(row.file_id) orelse continue;
        if (row.content_hash != semantic_item.source_hash) continue;
        const confidence = ranking.semanticConfidence(semantic_item.score);
        if (confidence == 0) continue;
        // Both channels now contribute on the same reciprocal-rank scale.
        const contribution = reciprocalRank(semantic_item.rank) * confidence / ranking.SCALE;
        if (by_id.get(row.file_id)) |index| {
            fused.items[index].score += contribution;
            fused.items[index].tier = @min(fused.items[index].tier, 3);
            fused.items[index].semantic_rank = semantic_item.rank;
            continue;
        }
        const index = fused.items.len;
        try candidates.append(allocator, row);
        errdefer _ = candidates.pop();
        try fused.append(allocator, .{
            .candidate_index = candidates.items.len - 1,
            .exact = isExactMatch(normalized.slice(), &row),
            .tier = @min(3, classify(normalized.slice(), &row, true) orelse 3),
            .score = contribution,
            .semantic_rank = semantic_item.rank,
        });
        try by_id.put(row.file_id, index);
    }

    try query_cancel.check();
    if (!std.meta.eql(lexical_revision, try db.catalogRevision())) return error.StaleSemanticSnapshot;
    std.mem.sort(Fused, fused.items, candidates.items, fusedLessThan);
    const count = @min(max, fused.items.len);
    for (fused.items[0..count], 0..) |item, i| copyResult(&candidates.items[item.candidate_index], &out[i]);
    return count;
}

fn reciprocalRank(zero_based_rank: usize) u64 {
    return RRF_SCALE / (RRF_OFFSET + @as(u64, @intCast(zero_based_rank)) + 1);
}

fn isExactMatch(query: []const u8, row: *const db.Candidate) bool {
    const q = query;
    if (q.len == 0) return false;
    const raw_name = zSlice(&row.name);
    const name = normalizeText(raw_name);
    const stem = normalizeText(std.fs.path.stem(raw_name));
    return std.ascii.eqlIgnoreCase(q, name.slice()) or std.ascii.eqlIgnoreCase(q, stem.slice());
}

fn fusedLessThan(candidates: []db.Candidate, a: Fused, b: Fused) bool {
    if (a.exact != b.exact) return a.exact;
    if (a.tier != b.tier) return a.tier < b.tier;
    if (a.score != b.score) return a.score > b.score;
    if (a.lexical_rank != b.lexical_rank) return a.lexical_rank < b.lexical_rank;
    if (a.semantic_rank != b.semantic_rank) return a.semantic_rank < b.semantic_rank;
    const a_row = &candidates[a.candidate_index];
    const b_row = &candidates[b.candidate_index];
    const order = std.ascii.orderIgnoreCase(zSlice(&a_row.name), zSlice(&b_row.name));
    if (order != .eq) return order == .lt;
    return a_row.file_id < b_row.file_id;
}

fn addRanked(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(db.Candidate),
    ranked: *std.ArrayList(Ranked),
    seen: *std.AutoHashMap(i32, usize),
    row: *const db.Candidate,
    class: u8,
) !void {
    if (seen.get(row.file_id)) |index| {
        ranked.items[index].class = @min(ranked.items[index].class, class);
        ranked.items[index].bm25 = @min(ranked.items[index].bm25, row.bm25);
        return;
    }
    const ranked_index = ranked.items.len;
    const candidate_index = candidates.items.len;
    try candidates.append(allocator, row.*);
    errdefer _ = candidates.pop();
    try ranked.append(allocator, .{ .candidate_index = candidate_index, .class = class, .bm25 = row.bm25 });
    try seen.put(row.file_id, ranked_index);
}

fn rankedLessThan(candidates: []db.Candidate, a: Ranked, b: Ranked) bool {
    if (a.class != b.class) return a.class < b.class;
    if (a.bm25 != b.bm25) return a.bm25 < b.bm25;
    const a_row = &candidates[a.candidate_index];
    const b_row = &candidates[b.candidate_index];
    const an = zSlice(&a_row.name);
    const bn = zSlice(&b_row.name);
    const order = std.ascii.orderIgnoreCase(an, bn);
    if (order != .eq) return order == .lt;
    return a_row.file_id < b_row.file_id;
}

fn classify(query: []const u8, row: *const db.Candidate, allow_fts: bool) ?u8 {
    const q = query;
    const raw_name = zSlice(&row.name);
    const name = normalizeText(raw_name);
    const stem = normalizeText(std.fs.path.stem(raw_name));
    const text = normalizeText(zSlice(&row.search_text));
    if (std.ascii.eqlIgnoreCase(q, name.slice()) or std.ascii.eqlIgnoreCase(q, stem.slice())) return 0;
    if (std.ascii.startsWithIgnoreCase(name.slice(), q)) return 1;
    if (std.ascii.findIgnoreCase(text.slice(), q) != null or std.ascii.findIgnoreCase(name.slice(), q) != null or allTokensPresent(q, text.slice())) return 2;
    if (allTokensNear(q, text.slice())) return 4;
    return if (allow_fts) 3 else null;
}

fn allTokensPresent(query: []const u8, text: []const u8) bool {
    var queries = std.mem.tokenizeScalar(u8, query, ' ');
    var had_query = false;
    while (queries.next()) |q| {
        had_query = true;
        var words = std.mem.tokenizeScalar(u8, text, ' ');
        var found = false;
        while (words.next()) |word| if (std.mem.startsWith(u8, word, q)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return had_query;
}

fn allTokensNear(query: []const u8, text: []const u8) bool {
    var queries = std.mem.tokenizeAny(u8, query, " ");
    var had_query = false;
    while (queries.next()) |q| {
        had_query = true;
        var words = std.mem.tokenizeAny(u8, text, " ");
        var found = false;
        while (words.next()) |word| {
            if (distanceAtMostOne(q, word)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return had_query;
}

pub const distanceAtMostOne = text_mod.distanceAtMostOne;

pub fn buildTrigramQuery(input: []const u8) QueryBuf {
    var result = QueryBuf{};
    var seen: [MAX_QUERY_LEN]u32 = undefined;
    var seen_count: usize = 0;
    var words = std.mem.tokenizeAny(u8, input, " ");
    while (words.next()) |word| {
        if (word.len < 3) continue;
        for (0..word.len - 2) |i| {
            const key = @as(u32, word[i]) | (@as(u32, word[i + 1]) << 8) | (@as(u32, word[i + 2]) << 16);
            if (std.mem.indexOfScalar(u32, seen[0..seen_count], key) != null) continue;
            if (seen_count == seen.len) break;
            seen[seen_count] = key;
            seen_count += 1;
            const needed: usize = 5 + (if (result.len > 0) @as(usize, 4) else 0);
            if (needed > result.buf.len - result.len) break;
            if (result.len > 0) appendSlice(&result, " OR ");
            appendByte(&result, '"');
            for (word[i .. i + 3]) |b| {
                if (b == '"') appendByte(&result, '"');
                appendByte(&result, b);
            }
            appendByte(&result, '"');
        }
    }
    return result;
}

pub fn listFolderPage(allocator: std.mem.Allocator, folder_id: i32, after_name: ?[]const u8, after_id: i32, out: [*]types.WSResult, max: usize) !usize {
    const rows = try db.listFolderPage(allocator, folder_id, after_name, after_id, max);
    defer allocator.free(rows);
    return copyResults(rows, out, max);
}

pub fn listFolder(allocator: std.mem.Allocator, folder_id: i32, out: [*]types.WSResult, max: usize) !usize {
    if (max == 0) return 0;
    const rows = try db.listFolder(allocator, folder_id, max);
    defer allocator.free(rows);
    return copyResults(rows, out, max);
}

fn copyResults(rows: []const db.Candidate, out: [*]types.WSResult, max: usize) usize {
    const count = @min(rows.len, max);
    for (rows[0..count], 0..) |*row, i| copyResult(row, &out[i]);
    return count;
}

fn copyResult(row: *const db.Candidate, out: *types.WSResult) void {
    out.file_id = row.file_id;
    out.folder_id = row.folder_id;
    out.path = row.path;
    out.name = row.name;
    out.duration_ms = row.duration_ms;
    out.content_hash = row.content_hash;
}

fn zSlice(buf: []const u8) []const u8 {
    return buf[0..(std.mem.indexOfScalar(u8, buf, 0) orelse buf.len)];
}

fn appendNormalizedPathText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) !void {
    var prev: u8 = 0;
    var last_was_space = true;
    for (path) |raw| {
        const camel_boundary = !last_was_space and std.ascii.isUpper(raw) and std.ascii.isLower(prev);
        const ch = std.ascii.toLower(raw);
        if (isDelimiter(ch) or camel_boundary) {
            if (!last_was_space) {
                try out.append(allocator, ' ');
                last_was_space = true;
            }
        } else {
            try out.append(allocator, ch);
            last_was_space = false;
        }
        prev = raw;
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
}

pub const FAST_HASH_BLOCK_SIZE: u64 = 64 * 1024;
pub const FAST_HASH_MAX_READ: u64 = FAST_HASH_BLOCK_SIZE * 5;

pub fn fastHashSampleOffsets(file_size: u64, storage: *[5]u64) []const u64 {
    if (file_size <= FAST_HASH_MAX_READ) return storage[0..0];
    const span = file_size - FAST_HASH_BLOCK_SIZE;
    storage.* = .{ 0, span / 4, span / 2, span - span / 4, span };
    return storage;
}

fn contentHash(reader: audio_file.Reader, deep: bool, fast: bool, expected_size: i64, expected_mtime_ns: i64, cancel: ?*const std.atomic.Value(bool)) !i64 {
    if (deep and fast) return error.InvalidIndexMode;
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
    const raw_digest = hasher.final() & 0x7fff_ffff_ffff_ffff;
    const digest: i64 = @intCast(if (raw_digest == 0) 1 else raw_digest);
    // Negative values explicitly mark bounded fast identities as provisional;
    // legacy exact-hash duplicate APIs must not treat them as proof of equality.
    return if (fast) -digest else digest;
}

fn isAudioFile(name: []const u8) bool {
    for (AUDIO_EXTENSIONS) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}
