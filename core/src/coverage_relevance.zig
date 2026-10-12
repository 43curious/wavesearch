const std = @import("std");
const audio = @import("clap_audio.zig");
const segments = @import("semantic_segments.zig");
const provider = @import("clap_provider.zig");
const db = @import("db.zig");
const relevance = @import("relevance.zig");
const manifest = @import("model_manifest.zig");
const perf = @import("perf.zig");

const Split = enum { tuning, held_out };
const Interval = struct { start_ms: u64, end_ms: u64 };
const File = struct { id: []const u8, path: []const u8, group: []const u8, split: Split };
const Judgment = struct { file_id: []const u8, grade: u8, interval: ?Interval = null };
const Query = struct { id: []const u8, text: []const u8, split: Split, judgments: []const Judgment };
const Corpus = struct { files: []const File, queries: []const Query };
const Hit = struct { file_index: usize, score: segments.Score };
const Record = struct { vectors: []segments.Segment, duration_ms: u64 };
const Metrics = struct {
    queries: usize = 0,
    positive_queries: usize = 0,
    negative_queries: usize = 0,
    ndcg: f64 = 0,
    recall: f64 = 0,
    false_positives: usize = 0,
    returned: usize = 0,
    negative_hits: usize = 0,
    localized: usize = 0,
    annotated: usize = 0,
    iou: f64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const runtime = args.next() orelse return usage();
    if (std.mem.eql(u8, runtime, "plan")) {
        const audio_root = args.next() orelse return usage();
        const corpus_file = args.next() orelse return usage();
        if (args.next() != null) return usage();
        return planOnly(allocator, audio_root, corpus_file);
    }
    const model = args.next() orelse return usage();
    const root = args.next() orelse return usage();
    const corpus_path = args.next() orelse return usage();
    const mode = args.next() orelse "all";
    if (args.next() != null) return usage();
    const policy = if (std.mem.eql(u8, mode, "all")) null else std.meta.stringToEnum(segments.Policy, mode) orelse return usage();
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, corpus_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Corpus, allocator, bytes, .{});
    defer parsed.deinit();
    const corpus = parsed.value;
    try validate(corpus);
    const absolute_root = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
    defer allocator.free(absolute_root);
    // Provider registration is isolated from the user's persistent catalog.
    try db.open(allocator, ":memory:");
    defer db.close();
    try provider.load(runtime, model, 2);
    defer provider.unload();
    var reference = provider.acquire() orelse return error.ProviderNotLoaded;
    defer reference.release();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    std.debug.print("coverage experiment: corpus_sha256={x} model={s} track=semantic_only threshold=0.05 threads=2\n", .{ digest, reference.provider.manifest.key() });
    for ([_]segments.Policy{ .mean5, .uniform16, .events16 }) |method| {
        if (policy == null or policy.? == method) try run(allocator, io, reference.provider, absolute_root, corpus, method);
    }
}

fn validate(corpus: Corpus) !void {
    if (corpus.files.len == 0 or corpus.files.len > 2048 or corpus.queries.len == 0 or corpus.queries.len > 4096) return error.InvalidCorpusSize;
    var held_out = false;
    for (corpus.files, 0..) |file, i| {
        if (file.id.len == 0 or file.group.len == 0 or !manifest.isSafeRelativePath(file.path) or !audio.isBuiltInAudioPath(file.path)) return error.InvalidCorpusFile;
        for (corpus.files[0..i]) |prior| {
            if (std.mem.eql(u8, file.id, prior.id) or std.mem.eql(u8, file.path, prior.path)) return error.DuplicateCorpusFile;
            if (std.mem.eql(u8, file.group, prior.group) and file.split != prior.split) return error.SplitLeakage;
        }
    }
    for (corpus.queries, 0..) |query, i| {
        if (query.id.len == 0 or query.text.len == 0 or query.text.len > 1024) return error.InvalidCorpusQuery;
        for (corpus.queries[0..i]) |prior| if (std.mem.eql(u8, query.id, prior.id)) return error.DuplicateCorpusQuery;
        if (query.split == .held_out) held_out = true;
        var expected: usize = 0;
        for (corpus.files) |file| if (file.split == query.split) {
            expected += 1;
        };
        if (expected == 0 or query.judgments.len != expected) return error.IncompleteJudgments;
        for (query.judgments, 0..) |judgment, j| {
            if (judgment.grade > 3) return error.InvalidGrade;
            const index = fileIndex(corpus, judgment.file_id) orelse return error.UnknownJudgmentFile;
            if (corpus.files[index].split != query.split) return error.SplitLeakage;
            for (query.judgments[0..j]) |prior| if (std.mem.eql(u8, judgment.file_id, prior.file_id)) return error.DuplicateJudgment;
            if (judgment.interval) |interval| if (judgment.grade == 0 or interval.end_ms <= interval.start_ms) return error.InvalidJudgmentInterval;
        }
    }
    if (!held_out) return error.MissingHeldOutQueries;
}

fn fileIndex(corpus: Corpus, id: []const u8) ?usize {
    for (corpus.files, 0..) |file, index| if (std.mem.eql(u8, file.id, id)) return index;
    return null;
}

fn run(allocator: std.mem.Allocator, io: std.Io, clap: *provider.Provider, root: []const u8, corpus: Corpus, policy: segments.Policy) !void {
    var identity: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(clap.manifest.key());
    hasher.update(policy.revision());
    hasher.final(&identity);
    std.debug.print("method={s} representation_sha256={x} revision={s}\n", .{ @tagName(policy), identity, policy.revision() });
    const records = try allocator.alloc(Record, corpus.files.len);
    defer allocator.free(records);
    var completed: usize = 0;
    defer for (records[0..completed]) |record| allocator.free(record.vectors);
    const waveform = if (policy == .mean5) null else try allocator.alloc(f32, audio.WINDOW_SAMPLES);
    defer if (waveform) |buffer| allocator.free(buffer);
    var inference_count: usize = 0;
    var retained_bytes: usize = 0;
    var index_ns: i96 = 0;
    for (corpus.files, records) |file, *record| {
        const path = try std.fs.path.join(allocator, &.{ root, file.path });
        defer allocator.free(path);
        const start = std.Io.Clock.awake.now(io);
        var reader = try audio.WindowReader.initFile(allocator, io, path);
        defer reader.deinit();
        const plan = try segments.plan(&reader, policy);
        const duration_ms = (@as(u64, reader.destination_frames) * 1000) / audio.SAMPLE_RATE;
        const pooled = policy == .mean5;
        const embeddings = try allocator.alloc(segments.Segment, if (pooled) 1 else plan.len);
        errdefer allocator.free(embeddings);
        if (pooled) {
            embeddings[0] = .{ .start_ms = 0, .end_ms = duration_ms, .embedding = undefined };
            try clap.embedAudioReader(&reader, null, &embeddings[0].embedding);
        } else {
            for (plan.starts[0..plan.len], 0..) |offset, index| {
                try reader.readAt(offset, waveform.?);
                var embedding: [segments.DIMENSION]f32 = undefined;
                try clap.sessions.runAudio(waveform.?, &embedding);
                const start_ms = (@as(u64, offset) * 1000) / audio.SAMPLE_RATE;
                embeddings[index] = .{ .start_ms = start_ms, .end_ms = @min(duration_ms, start_ms + 10_000), .embedding = embedding };
            }
        }
        record.* = .{ .vectors = embeddings, .duration_ms = duration_ms };
        completed += 1;
        const ns = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        index_ns += ns;
        inference_count += plan.len;
        const payload = embeddings.len * (segments.DIMENSION * 4 + (if (pooled) @as(usize, 0) else 16));
        retained_bytes += payload;
        std.debug.print("asset method={s} id={s} duration_ms={d} inferences={d} vectors={d} payload_bytes={d} index_ms={d:.3}\n", .{ @tagName(policy), file.id, duration_ms, plan.len, embeddings.len, payload, perf.milliseconds(ns) });
    }
    // Validate timing annotations against decoded media, not rounded metadata.
    for (corpus.queries) |query| for (query.judgments) |judgment| {
        if (judgment.interval) |interval| if (interval.end_ms > records[fileIndex(corpus, judgment.file_id).?].duration_ms) return error.IntervalOutsideSource;
    };
    const hits = try allocator.alloc(Hit, corpus.files.len);
    defer allocator.free(hits);
    var totals: [2]Metrics = @splat(.{});
    for (corpus.queries) |query| {
        var embedding: [segments.DIMENSION]f32 = undefined;
        try clap.embedText(query.text, &embedding);
        var count: usize = 0;
        for (corpus.files, records, 0..) |file, record, index| {
            if (file.split != query.split) continue;
            const score = try segments.score(&embedding, record.vectors, policy == .mean5);
            if (score.cosine <= 0.05) continue;
            hits[count] = .{ .file_index = index, .score = score };
            count += 1;
        }
        std.mem.sort(Hit, hits[0..count], {}, struct {
            fn less(_: void, a: Hit, b: Hit) bool {
                if (a.score.cosine != b.score.cosine) return a.score.cosine > b.score.cosine;
                return a.file_index < b.file_index;
            }
        }.less);
        const top = hits[0..@min(10, count)];
        const metric = try evaluate(allocator, corpus, query, top);
        const total = &totals[@backingInt(query.split)];
        inline for (@typeInfo(Metrics).@"struct".field_names) |name| @field(total, name) += @field(metric, name);
        std.debug.print("query method={s} split={s} id={s} ndcg@10={d:.6} recall@10={d:.6} false_positives={d}/{d} localized={d}/{d} iou_sum={d:.6}\n", .{ @tagName(policy), @tagName(query.split), query.id, metric.ndcg, metric.recall, metric.false_positives, metric.returned, metric.localized, metric.annotated, metric.iou });
        for (top, 0..) |hit, rank| {
            std.debug.print("hit query={s} rank={d} file={s} cosine={d:.6}", .{ query.id, rank + 1, corpus.files[hit.file_index].id, hit.score.cosine });
            if (hit.score.interval) |interval| std.debug.print(" start_ms={d} end_ms={d}", .{ interval.start_ms, interval.end_ms });
            std.debug.print("\n", .{});
        }
    }
    for (totals, 0..) |total, index| {
        if (total.queries == 0) continue;
        std.debug.print("summary method={s} split={s} queries={d} positive_queries={d} negative_queries={d} mean_ndcg@10={d:.6} mean_recall@10={d:.6} false_positive_fraction={d:.6} negative_hit_rate={d:.6} localization_recall={d:.6} mean_iou={d:.6}\n", .{ @tagName(policy), @tagName(@as(Split, @fromBackingInt(@intCast(index)))), total.queries, total.positive_queries, total.negative_queries, ratio(total.ndcg, total.positive_queries), ratio(total.recall, total.positive_queries), ratio(@floatFromInt(total.false_positives), total.returned), ratio(@floatFromInt(total.negative_hits), total.negative_queries), ratio(@floatFromInt(total.localized), total.annotated), ratio(total.iou, total.annotated) });
    }
    std.debug.print("resources method={s} audio_inferences={d} retained_payload_bytes={d} index_ms={d:.3} process_peak_rss_bytes={d}\n", .{ @tagName(policy), inference_count, retained_bytes, perf.milliseconds(index_ns), perf.peakRssBytes() });
}

fn evaluate(allocator: std.mem.Allocator, corpus: Corpus, query: Query, hits: []const Hit) !Metrics {
    var metric = Metrics{ .queries = 1, .returned = hits.len };
    var relevant: usize = 0;
    var found: usize = 0;
    const ideal = try allocator.alloc(u8, query.judgments.len);
    defer allocator.free(ideal);
    for (query.judgments, ideal) |judgment, *grade| {
        grade.* = judgment.grade;
        if (judgment.grade > 0) relevant += 1;
        if (judgment.interval != null) metric.annotated += 1;
    }
    var grades: [10]u8 = undefined;
    for (hits, 0..) |hit, rank| {
        const id = corpus.files[hit.file_index].id;
        const judgment = for (query.judgments) |j| {
            if (std.mem.eql(u8, id, j.file_id)) break j;
        } else return error.IncompleteJudgments;
        grades[rank] = judgment.grade;
        if (judgment.grade == 0) metric.false_positives += 1 else found += 1;
        if (judgment.interval) |truth| if (hit.score.interval) |predicted| {
            const iou = intervalIou(truth, .{ .start_ms = predicted.start_ms, .end_ms = predicted.end_ms });
            if (iou > 0) metric.localized += 1;
            metric.iou += iou;
        };
    }
    if (relevant == 0) {
        metric.negative_queries = 1;
        metric.negative_hits = @intFromBool(hits.len > 0);
    } else {
        metric.positive_queries = 1;
        metric.ndcg = relevance.ndcg10(grades[0..hits.len], ideal);
        metric.recall = ratio(@floatFromInt(found), relevant);
    }
    return metric;
}

fn ratio(numerator: f64, denominator: usize) f64 {
    return if (denominator == 0) 0 else numerator / @as(f64, @floatFromInt(denominator));
}

fn intervalIou(a: Interval, b: Interval) f64 {
    const overlap = @min(a.end_ms, b.end_ms) -| @max(a.start_ms, b.start_ms);
    const combined = (a.end_ms - a.start_ms) + (b.end_ms - b.start_ms) - overlap;
    return if (combined == 0) 0 else @as(f64, @floatFromInt(overlap)) / @as(f64, @floatFromInt(combined));
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build coverage-relevance -- RUNTIME MODEL AUDIO_ROOT CORPUS_JSON [all|mean5|uniform16|events16]\n", .{});
    std.debug.print("       zig build coverage-relevance -- plan AUDIO_ROOT CORPUS_JSON (no inference)\n", .{});
    return error.InvalidArguments;
}

fn planOnly(allocator: std.mem.Allocator, root: []const u8, corpus_path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, corpus_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Corpus, allocator, bytes, .{});
    defer parsed.deinit();
    const corpus = parsed.value;
    try validate(corpus);
    const absolute_root = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
    defer allocator.free(absolute_root);
    std.debug.print("window coverage only: no inference, no retrieval quality measurement\n", .{});
    for ([_]segments.Policy{ .mean5, .uniform16, .events16 }) |policy| {
        var planned: usize = 0;
        var annotations: usize = 0;
        var covered: usize = 0;
        const begin = std.Io.Clock.awake.now(io);
        for (corpus.files) |file| {
            const path = try std.fs.path.join(allocator, &.{ absolute_root, file.path });
            defer allocator.free(path);
            var reader = try audio.WindowReader.initFile(allocator, io, path);
            defer reader.deinit();
            const plan = try segments.plan(&reader, policy);
            const duration = (@as(u64, reader.destination_frames) * 1000) / audio.SAMPLE_RATE;
            planned += plan.len;
            var file_covered: usize = 0;
            var file_annotations: usize = 0;
            for (corpus.queries) |query| for (query.judgments) |judgment| {
                if (!std.mem.eql(u8, file.id, judgment.file_id)) continue;
                const truth = judgment.interval orelse continue;
                if (truth.end_ms > duration) return error.IntervalOutsideSource;
                file_annotations += 1;
                for (plan.starts[0..plan.len]) |offset| {
                    const start = (@as(u64, offset) * 1000) / audio.SAMPLE_RATE;
                    if (intervalIou(truth, .{ .start_ms = start, .end_ms = @min(duration, start + 10_000) }) > 0) {
                        file_covered += 1;
                        break;
                    }
                }
            };
            covered += file_covered;
            annotations += file_annotations;
            std.debug.print("plan method={s} file={s} duration_ms={d} windows={d} annotated_coverage={d}/{d} starts_ms=", .{ @tagName(policy), file.id, duration, plan.len, file_covered, file_annotations });
            for (plan.starts[0..plan.len]) |offset| std.debug.print("{d},", .{(@as(u64, offset) * 1000) / audio.SAMPLE_RATE});
            std.debug.print("\n", .{});
        }
        std.debug.print("plan_summary method={s} planned_audio_inferences={d} annotated_window_coverage={d:.6} planning_ms={d:.3} process_peak_rss_bytes={d}\n", .{ @tagName(policy), planned, ratio(@floatFromInt(covered), annotations), perf.milliseconds(begin.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds()), perf.peakRssBytes() });
    }
}

test "coverage judgments enforce held-out groups and fully judged negatives" {
    const files = [_]File{
        .{ .id = "a", .path = "a.wav", .group = "one", .split = .tuning },
        .{ .id = "b", .path = "b.wav", .group = "two", .split = .held_out },
    };
    const queries = [_]Query{.{ .id = "negative", .text = "absent event", .split = .held_out, .judgments = &.{.{ .file_id = "b", .grade = 0 }} }};
    try validate(.{ .files = &files, .queries = &queries });
    var leaked = files;
    leaked[1].group = "one";
    try std.testing.expectError(error.SplitLeakage, validate(.{ .files = &leaked, .queries = &queries }));
    var incomplete = queries;
    incomplete[0].judgments = &.{};
    try std.testing.expectError(error.IncompleteJudgments, validate(.{ .files = &files, .queries = &incomplete }));
    const metric = try evaluate(std.testing.allocator, .{ .files = &files, .queries = &queries }, queries[0], &.{.{ .file_index = 1, .score = .{ .cosine = 0.5, .interval = null } }});
    try std.testing.expectEqual(@as(usize, 1), metric.negative_hits);
    try std.testing.expectEqual(@as(usize, 1), metric.false_positives);
    try std.testing.expectEqual(@as(f64, 0), metric.ndcg);
}

test "localization reports overlap and interval precision separately" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), intervalIou(.{ .start_ms = 2000, .end_ms = 3000 }, .{ .start_ms = 0, .end_ms = 10_000 }), 1e-9);
    try std.testing.expectEqual(@as(f64, 0), intervalIou(.{ .start_ms = 20_000, .end_ms = 21_000 }, .{ .start_ms = 0, .end_ms = 10_000 }));
}

test "graded metrics count missed assets and retrieved irrelevant results" {
    const files = [_]File{
        .{ .id = "a", .path = "a.wav", .group = "a", .split = .held_out },
        .{ .id = "b", .path = "b.wav", .group = "b", .split = .held_out },
        .{ .id = "c", .path = "c.wav", .group = "c", .split = .held_out },
    };
    const query = Query{ .id = "event", .text = "event", .split = .held_out, .judgments = &.{
        .{ .file_id = "a", .grade = 3, .interval = .{ .start_ms = 2000, .end_ms = 3000 } },
        .{ .file_id = "b", .grade = 1, .interval = .{ .start_ms = 20_000, .end_ms = 21_000 } },
        .{ .file_id = "c", .grade = 0 },
    } };
    const corpus = Corpus{ .files = &files, .queries = &.{query} };
    try validate(corpus);
    const metric = try evaluate(std.testing.allocator, corpus, query, &.{
        .{ .file_index = 2, .score = .{ .cosine = 0.8, .interval = null } },
        .{ .file_index = 0, .score = .{ .cosine = 0.7, .interval = .{ .start_ms = 0, .end_ms = 10_000 } } },
    });
    try std.testing.expectApproxEqAbs((7 / @log2(@as(f64, 3))) / (7 + 1 / @log2(@as(f64, 3))), metric.ndcg, 1e-12);
    try std.testing.expectEqual(@as(f64, 0.5), metric.recall);
    try std.testing.expectEqual(@as(usize, 1), metric.false_positives);
    try std.testing.expectEqual(@as(usize, 2), metric.annotated);
    try std.testing.expectEqual(@as(usize, 1), metric.localized);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), metric.iou, 1e-12);
}
