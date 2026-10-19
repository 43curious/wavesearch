const std = @import("std");
const db = @import("db.zig");
const fingerprint = @import("fingerprint.zig");
const semantic = @import("semantic.zig");
const clap_provider = @import("clap_provider.zig");
const cancellation = @import("cancellation.zig");
const ranking = @import("ranking.zig");
const clap_audio = @import("clap_audio.zig");
const query_cancel = @import("query.zig");

const CANDIDATE_LIMIT: usize = 128;
const EDGE_CANDIDATE_LIMIT: usize = 1024;
const RRF_SCALE: u64 = 1_000_000_000;
const RRF_OFFSET: u64 = 60;

pub const IndexResult = struct { successful: usize = 0, failed: usize = 0 };

pub const SearchResult = struct {
    candidate: db.Candidate,
    fingerprint_score_ppm: u32 = 0,
    fingerprint_votes: u32 = 0,
    offset_frames: i32 = 0,
    embedding_rank: ?usize = null,
    fused_score: u64 = 0,
    group_id: i64 = 0,
};

pub const GroupInfo = struct {
    group_id: i64,
    member_count: u32,
    confidence_ppm: u32,
};

pub fn indexPending(allocator: std.mem.Allocator, folder_id: ?i32, max_files: usize) !IndexResult {
    return indexPendingExpected(allocator, folder_id, max_files, cancellation.currentGeneration());
}

pub fn indexPendingExpected(allocator: std.mem.Allocator, folder_id: ?i32, max_files: usize, expected_generation: u64) !IndexResult {
    const cancel = cancellation.beginExpected(expected_generation);
    defer cancellation.end();
    if (cancel.isCancelled()) return error.Cancelled;
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    var result = IndexResult{};
    var cursor: i32 = 0;
    var groups_dirty = false;
    var remaining = max_files;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    while (max_files == 0 or remaining > 0) {
        if (cancel.isCancelled()) return error.Cancelled;
        const batch_size = if (max_files == 0) @as(usize, 16) else @min(remaining, 16);
        const files = try db.pendingFingerprintFilesAfter(allocator, algorithm_id, folder_id, batch_size, cursor);
        defer db.freePendingSemanticFiles(allocator, files);
        if (files.len == 0) break;
        cursor = files[files.len - 1].id;
        for (files) |file| {
            if (cancel.isCancelled()) return error.Cancelled;
            const landmarks = fingerprint.fromFile(allocator, io, file.path) catch |err| {
                if (!isTerminalAudioError(err)) return err;
                try db.recordFingerprintFailure(algorithm_id, file.id, file.source_content_hash, "decode", @errorName(err));
                result.failed += 1;
                if (max_files != 0) remaining -= 1;
                continue;
            };
            defer allocator.free(landmarks);
            if (cancel.isCancelled()) return error.Cancelled;
            const blob = try fingerprint.serialize(allocator, landmarks);
            defer allocator.free(blob);
            const selected = try fingerprint.selectors(allocator, landmarks);
            defer allocator.free(selected);
            const neighbors = try searchLandmarks(allocator, landmarks, folder_id, EDGE_CANDIDATE_LIMIT);
            defer allocator.free(neighbors);
            var edges: std.ArrayList(db.AcousticEdge) = .empty;
            defer edges.deinit(allocator);
            for (neighbors) |neighbor| {
                if (neighbor.candidate.file_id == file.id or neighbor.fingerprint_votes < 6 or neighbor.fingerprint_score_ppm < 120_000) continue;
                try edges.append(allocator, .{
                    .other_file_id = neighbor.candidate.file_id,
                    .score_ppm = neighbor.fingerprint_score_ppm,
                    .aligned = neighbor.fingerprint_votes,
                });
            }
            if (cancel.isCancelled()) return error.Cancelled;
            db.upsertFingerprintWithEdges(algorithm_id, file.id, file.source_content_hash, blob, selected, edges.items) catch |err| {
                if (err == error.StaleContentHash or err == error.FileNotFound) continue;
                return err;
            };
            groups_dirty = true;
            result.successful += 1;
            if (max_files != 0) remaining -= 1;
        }
    }
    // Bounded background calls leave dirty groups hidden until the queue is
    // drained. This avoids a corpus-wide union-find rebuild after every file.
    var scope_drained = true;
    if (max_files != 0) {
        const pending = try db.pendingFingerprintFiles(allocator, algorithm_id, folder_id, 1);
        defer db.freePendingSemanticFiles(allocator, pending);
        scope_drained = pending.len == 0;
    }
    if (scope_drained and (groups_dirty or try db.acousticGroupsDirty(algorithm_id)))
        try db.rebuildAcousticGroups(allocator, algorithm_id);
    return result;
}

pub fn searchPcm(allocator: std.mem.Allocator, samples: []const f32, frames: usize, channels: u16, sample_rate: u32, folder_id: ?i32, max: usize) ![]SearchResult {
    if (max == 0) return allocator.alloc(SearchResult, 0);
    const canonical = try clap_audio.canonicalizeInterleavedPcm(allocator, samples, frames, channels, sample_rate);
    defer allocator.free(canonical);
    const landmarks = try fingerprint.fromSamples(allocator, canonical);
    defer allocator.free(landmarks);
    return searchLandmarks(allocator, landmarks, folder_id, max);
}

pub fn searchPath(allocator: std.mem.Allocator, path: []const u8, folder_id: ?i32, max: usize) ![]SearchResult {
    if (max == 0) return allocator.alloc(SearchResult, 0);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const landmarks = try fingerprint.fromFile(allocator, io, path);
    defer allocator.free(landmarks);
    return searchWithLandmarksAndPath(allocator, landmarks, path, folder_id, max);
}

pub fn searchLandmarks(allocator: std.mem.Allocator, landmarks: []const fingerprint.Landmark, folder_id: ?i32, limit: usize) ![]SearchResult {
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    const selected = try fingerprint.selectors(allocator, landmarks);
    defer allocator.free(selected);
    const candidate_limit = @min(EDGE_CANDIDATE_LIMIT, @max(limit * 8, @as(usize, 32)));
    const ids = try db.fingerprintCandidateIds(allocator, algorithm_id, selected, folder_id, candidate_limit);
    defer allocator.free(ids);

    const Scored = struct { id: i32, source_hash: i64, match: fingerprint.Match };
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(allocator);
    var offset: usize = 0;
    while (offset < ids.len) {
        const end = @min(ids.len, offset + 8);
        const batch = try db.loadFingerprintBatch(allocator, algorithm_id, ids[offset..end]);
        defer {
            for (batch) |stored| allocator.free(stored.landmarks);
            allocator.free(batch);
        }
        offset = end;
        for (batch) |stored| {
            try query_cancel.check();
            const reference = try fingerprint.deserialize(allocator, stored.landmarks);
            defer allocator.free(reference);
            const match = try fingerprint.compare(allocator, landmarks, reference);
            if (match.aligned >= 3 and match.score_ppm >= 30_000) try scored.append(allocator, .{ .id = stored.file_id, .source_hash = stored.source_content_hash, .match = match });
        }
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            const ah = a.match.highConfidence();
            const bh = b.match.highConfidence();
            if (ah != bh) return ah;
            if (a.match.score_ppm != b.match.score_ppm) return a.match.score_ppm > b.match.score_ppm;
            if (a.match.aligned != b.match.aligned) return a.match.aligned > b.match.aligned;
            return a.id < b.id;
        }
    }.lessThan);
    const count = @min(limit, scored.items.len);
    const ranked_ids = try allocator.alloc(i32, count);
    defer allocator.free(ranked_ids);
    for (scored.items[0..count], ranked_ids) |item, *id| id.* = item.id;
    const candidates = try db.candidatesForIds(allocator, ranked_ids);
    defer allocator.free(candidates);
    var by_id = std.AutoHashMap(i32, struct { match: fingerprint.Match, rank: usize, source_hash: i64 }).init(allocator);
    defer by_id.deinit();
    for (scored.items[0..count], 0..) |item, rank| try by_id.put(item.id, .{ .match = item.match, .rank = rank, .source_hash = item.source_hash });
    const results = try allocator.alloc(SearchResult, candidates.len);
    errdefer allocator.free(results);
    for (candidates, results) |candidate, *result| {
        try query_cancel.check();
        const item = by_id.get(candidate.file_id) orelse return error.ConcurrentCandidateChange;
        if (candidate.content_hash != item.source_hash) return error.ConcurrentCandidateChange;
        const persisted_group = if (item.match.highConfidence()) try db.acousticGroupInfo(algorithm_id, candidate.file_id) else null;
        result.* = .{
            .candidate = candidate,
            .fingerprint_score_ppm = item.match.score_ppm,
            .fingerprint_votes = item.match.aligned,
            .offset_frames = item.match.offset_frames,
            .fused_score = ranking.fingerprintConfidence(item.match.score_ppm, item.match.aligned) * 2 + reciprocalRank(item.rank),
            .group_id = if (persisted_group) |group| if (group.member_count > 1) group.group_id else 0 else 0,
        };
    }
    return results;
}

fn searchWithLandmarksAndPath(allocator: std.mem.Allocator, landmarks: []const fingerprint.Landmark, path: []const u8, folder_id: ?i32, max: usize) ![]SearchResult {
    const acoustic_results = try searchLandmarks(allocator, landmarks, folder_id, CANDIDATE_LIMIT);
    defer allocator.free(acoustic_results);

    var by_id = std.AutoHashMap(i32, usize).init(allocator);
    defer by_id.deinit();
    var fused: std.ArrayList(SearchResult) = .empty;
    defer fused.deinit(allocator);
    for (acoustic_results) |result| {
        try by_id.put(result.candidate.file_id, fused.items.len);
        try fused.append(allocator, result);
    }

    var provider_ref = if (clap_provider.canSearch()) clap_provider.acquire() else null;
    if (provider_ref) |*provider| {
        defer provider.release();
        var embedding: [512]f32 = undefined;
        try provider.provider.embedAudio(path, &embedding);
        if (try semantic.topK(allocator, &embedding, .{ .folder_id = folder_id }, CANDIDATE_LIMIT)) |retrieval| {
            defer allocator.free(retrieval.matches);
            const semantic_ids = try allocator.alloc(i32, retrieval.matches.len);
            defer allocator.free(semantic_ids);
            for (retrieval.matches, semantic_ids) |item, *id| id.* = item.file_id;
            const candidates = try db.candidatesForSemanticIds(allocator, semantic_ids, retrieval.model_id, retrieval.connection_serial);
            defer allocator.free(candidates);
            const SemanticRank = struct { rank: usize, score: f32, source_hash: i64 };
            var ranks = std.AutoHashMap(i32, SemanticRank).init(allocator);
            defer ranks.deinit();
            for (retrieval.matches, 0..) |item, rank| try ranks.put(item.file_id, .{ .rank = rank, .score = item.score, .source_hash = item.source_content_hash });
            for (candidates) |candidate| {
                const semantic_rank = ranks.get(candidate.file_id) orelse continue;
                if (candidate.content_hash != semantic_rank.source_hash or ranking.semanticConfidence(semantic_rank.score) == 0) continue;
                if (by_id.get(candidate.file_id)) |index| {
                    fused.items[index].embedding_rank = semantic_rank.rank;
                    fused.items[index].fused_score += ranking.semanticConfidence(semantic_rank.score);
                } else {
                    try by_id.put(candidate.file_id, fused.items.len);
                    try fused.append(allocator, .{
                        .candidate = candidate,
                        .embedding_rank = semantic_rank.rank,
                        .fused_score = ranking.semanticConfidence(semantic_rank.score),
                    });
                }
            }
        }
    }

    try query_cancel.check();
    // Results contain full paths. Block sort's 512-record scratch array can
    // overflow native host worker stacks; heap sort uses constant scratch space.
    std.sort.heap(SearchResult, fused.items, {}, struct {
        fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
            const af = a.fingerprint_score_ppm >= 120_000 and a.fingerprint_votes >= 6;
            const bf = b.fingerprint_score_ppm >= 120_000 and b.fingerprint_votes >= 6;
            if (af != bf) return af;
            if (a.fused_score != b.fused_score) return a.fused_score > b.fused_score;
            if (a.fingerprint_score_ppm != b.fingerprint_score_ppm) return a.fingerprint_score_ppm > b.fingerprint_score_ppm;
            return a.candidate.file_id < b.candidate.file_id;
        }
    }.lessThan);
    return allocator.dupe(SearchResult, fused.items[0..@min(max, fused.items.len)]);
}

pub fn groupInfo(allocator: std.mem.Allocator, file_id: i32) !?GroupInfo {
    _ = allocator;
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    const group = (try db.acousticGroupInfo(algorithm_id, file_id)) orelse return null;
    return .{ .group_id = group.group_id, .member_count = group.member_count, .confidence_ppm = group.confidence_ppm };
}

pub fn rebuildGroups(allocator: std.mem.Allocator) !void {
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    try db.rebuildAcousticGroups(allocator, algorithm_id);
}

pub fn status() !db.FingerprintStatus {
    const algorithm_id = try db.ensureFingerprintAlgorithm(fingerprint.ALGORITHM_KEY);
    return db.fingerprintStatus(algorithm_id);
}

fn reciprocalRank(rank: usize) u64 {
    return RRF_SCALE / (RRF_OFFSET + @as(u64, @intCast(rank)) + 1);
}

fn isTerminalAudioError(err: anyerror) bool {
    return switch (err) {
        error.FileTooLarge,
        error.TruncatedWav,
        error.NotWav,
        error.MalformedRiff,
        error.MalformedChunk,
        error.ChunkTooLarge,
        error.TruncatedChunk,
        error.DuplicateFormatChunk,
        error.MultipleDataChunks,
        error.MissingFormatChunk,
        error.MissingDataChunk,
        error.EmptyAudio,
        error.PartialAudioFrame,
        error.AudioTooLarge,
        error.MalformedFormat,
        error.UnsupportedChannelCount,
        error.UnsupportedSampleRate,
        error.MalformedExtensibleFormat,
        error.UnsupportedEncoding,
        error.UnsupportedBitDepth,
        error.UnsupportedValidBits,
        error.NonFiniteSample,
        error.InvalidFrameRange,
        error.ResamplerFailure,
        error.AudioTooShortForFingerprint,
        error.InsufficientFingerprintDetail,
        error.FingerprintTooLarge,
        error.FingerprintDurationLimit,
        error.TruncatedAudio,
        error.TruncatedAiff,
        error.MalformedAiff,
        => true,
        else => false,
    };
}
