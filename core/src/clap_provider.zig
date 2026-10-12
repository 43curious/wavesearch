const std = @import("std");
const manifest_mod = @import("model_manifest.zig");
const tokenizer_mod = @import("tokenizer.zig");
const clap_audio = @import("clap_audio.zig");
const onnx = @import("onnx_runtime.zig");
const db = @import("db.zig");
const cancellation = @import("cancellation.zig");
const sync = @import("sync.zig");
const vector_mod = @import("vector.zig");
const query_cancel = @import("query.zig");

pub const CACHE_CAPACITY: usize = 32;
pub const INDEX_BATCH_SIZE: usize = 32;
pub const MAX_CACHED_QUERY_BYTES: usize = 4096;

const CacheEntry = struct {
    query: []u8,
    embedding: [onnx.EMBEDDING_DIMENSION]f32,
};

pub const Provider = struct {
    allocator: std.mem.Allocator,
    manifest: manifest_mod.Manifest,
    sessions: onnx.ClapSessions,
    tokenizer: tokenizer_mod.Tokenizer,
    model_id: i64,
    cache_mutex: sync.Mutex = .{},
    cache: [CACHE_CAPACITY]?CacheEntry = @splat(null),
    cache_next: usize = 0,

    fn deinit(self: *Provider) void {
        for (&self.cache) |*entry| if (entry.*) |value| self.allocator.free(value.query);
        self.tokenizer.deinit();
        self.sessions.deinit();
        self.manifest.deinit();
        self.allocator.destroy(self);
    }

    pub fn tokenize(self: *const Provider, query: []const u8, ids: []i64, mask: []i64) !void {
        return self.tokenizer.encode(query, ids, mask);
    }

    pub fn embedText(self: *Provider, query: []const u8, output: []f32) !void {
        try query_cancel.check();
        if (output.len != onnx.EMBEDDING_DIMENSION) return error.InvalidEmbeddingDimension;
        if (query.len > MAX_CACHED_QUERY_BYTES) return error.QueryTooLong;
        self.cache_mutex.lock();
        for (self.cache) |entry| if (entry) |value| {
            if (std.mem.eql(u8, value.query, query)) {
                @memcpy(output, &value.embedding);
                self.cache_mutex.unlock();
                return;
            }
        };
        self.cache_mutex.unlock();

        var ids: [onnx.TEXT_TOKENS]i64 = undefined;
        var mask: [onnx.TEXT_TOKENS]i64 = undefined;
        try self.tokenizer.encode(query, &ids, &mask);
        try query_cancel.check();
        try self.sessions.runText(&ids, &mask, output);
        try query_cancel.check();

        if (query.len <= MAX_CACHED_QUERY_BYTES) {
            const owned = try self.allocator.dupe(u8, query);
            self.cache_mutex.lock();
            defer self.cache_mutex.unlock();
            // Another inference may have populated the same exact query while
            // this session was running. Keep just one owned cache entry.
            for (self.cache) |entry| if (entry) |value| {
                if (std.mem.eql(u8, value.query, query)) {
                    self.allocator.free(owned);
                    return;
                }
            };
            const slot = self.cache_next;
            self.cache_next = (self.cache_next + 1) % CACHE_CAPACITY;
            if (self.cache[slot]) |old| self.allocator.free(old.query);
            var vector: [onnx.EMBEDDING_DIMENSION]f32 = undefined;
            @memcpy(&vector, output);
            self.cache[slot] = .{ .query = owned, .embedding = vector };
        }
    }

    pub fn embedAudio(self: *Provider, path: []const u8, output: []f32) !void {
        return self.embedAudioWithCancellation(path, null, output);
    }

    pub fn embedAudioWithCancellation(self: *Provider, path: []const u8, cancel: ?cancellation.Token, output: []f32) !void {
        if (output.len != onnx.EMBEDDING_DIMENSION) return error.InvalidEmbeddingDimension;
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        var reader = try clap_audio.WindowReader.initFile(self.allocator, threaded.io(), path);
        defer reader.deinit();
        return self.embedAudioReader(&reader, cancel, output);
    }

    /// Canonical mean pooling shared by indexing and the coverage baseline.
    /// The caller owns a fresh reader and keeps its I/O alive through inference.
    pub fn embedAudioReader(self: *Provider, reader: *clap_audio.WindowReader, cancel: ?cancellation.Token, output: []f32) !void {
        if (output.len != onnx.EMBEDDING_DIMENSION) return error.InvalidEmbeddingDimension;
        const waveform = try self.allocator.alloc(f32, clap_audio.WINDOW_SAMPLES);
        defer self.allocator.free(waveform);
        var sum: [onnx.EMBEDDING_DIMENSION]f64 = @splat(0);
        var window_embedding: [onnx.EMBEDDING_DIMENSION]f32 = undefined;
        var count: usize = 0;
        while (try reader.next(waveform)) {
            if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
            try query_cancel.check();
            try self.sessions.runAudio(waveform, &window_embedding);
            try query_cancel.check();
            if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
            for (&sum, window_embedding) |*total, value| total.* += value;
            count += 1;
        }
        if (count == 0) return error.EmptyAudio;
        for (output, sum) |*destination, total| destination.* = @floatCast(total / @as(f64, @floatFromInt(count)));
        try vector_mod.normalize(output);
    }
};

const Lifecycle = sync.Lifecycle(Provider);
var lifecycle: Lifecycle = .{};

pub const Ref = Lifecycle.Ref;

pub fn acquire() ?Ref {
    return lifecycle.acquire();
}

pub fn isLoaded() bool {
    return lifecycle.isLoaded();
}

/// Verifies all manifest artifacts before parsing the tokenizer or loading any
/// ONNX graph. A successful load registers and activates exactly that pack.
/// Counters make this independent of catalog size; do not infer into an empty
/// or differently configured model catalog.
pub fn canSearch() bool {
    var reference = acquire() orelse return false;
    defer reference.release();
    const status = db.semanticStatus() catch return false;
    return status.embedded_count > 0 and std.mem.eql(u8, std.mem.sliceTo(&status.model_key, 0), reference.provider.manifest.key());
}

pub fn load(runtime_library_path: []const u8, model_dir: []const u8, intra_op_threads: u31) !void {
    if (runtime_library_path.len == 0 or model_dir.len == 0 or intra_op_threads == 0) return error.InvalidProviderArguments;
    try lifecycle.beginLoad();
    errdefer lifecycle.abortLoad();

    // Hashing the model pack and constructing ~800 MiB of ONNX sessions is
    // intentionally outside the publication lock. Searches remain lexical
    // instead of blocking for the duration of provider startup.
    const allocator = std.heap.c_allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var manifest = try manifest_mod.loadAndVerify(allocator, threaded.io(), model_dir);
    errdefer manifest.deinit();
    const tokenizer_path = try manifest.artifactPath(allocator, 2);
    defer allocator.free(tokenizer_path);
    var tokenizer_instance = try tokenizer_mod.Tokenizer.initFromFile(allocator, threaded.io(), tokenizer_path);
    errdefer tokenizer_instance.deinit();
    const audio_path = try manifest.artifactPath(allocator, 0);
    defer allocator.free(audio_path);
    const text_path = try manifest.artifactPath(allocator, 1);
    defer allocator.free(text_path);
    var sessions = try onnx.ClapSessions.init(runtime_library_path, audio_path, text_path, intra_op_threads);
    errdefer sessions.deinit();
    const provider = try allocator.create(Provider);
    errdefer allocator.destroy(provider);
    const model_id = try db.setSemanticModel(manifest.key(), onnx.EMBEDDING_DIMENSION);
    provider.* = .{
        .allocator = allocator,
        .manifest = manifest,
        .sessions = sessions,
        .tokenizer = tokenizer_instance,
        .model_id = model_id,
    };

    lifecycle.publish(provider);
}

/// Detaches the provider first so no new references can be acquired, then
/// waits for active text/audio/indexing calls before freeing sessions.
pub fn unload() void {
    if (lifecycle.detachForUnload()) |provider| {
        lifecycle.awaitDrain();
        provider.deinit();
        lifecycle.finishUnload();
    }
}

pub fn embedText(query: []const u8, output: []f32) !void {
    var provider_ref = acquire() orelse return error.ProviderNotLoaded;
    defer provider_ref.release();
    return provider_ref.provider.embedText(query, output);
}

pub fn embedAudio(path: []const u8, output: []f32) !void {
    var provider_ref = acquire() orelse return error.ProviderNotLoaded;
    defer provider_ref.release();
    return provider_ref.provider.embedAudio(path, output);
}

pub const IndexResult = struct {
    successful: usize = 0,
    attempted: usize = 0,
    failed: usize = 0,
};

pub fn indexPending(allocator: std.mem.Allocator, folder_id: ?i32, max_files: usize) !IndexResult {
    return indexPendingExpected(allocator, folder_id, max_files, cancellation.currentGeneration());
}

pub fn indexPendingExpected(allocator: std.mem.Allocator, folder_id: ?i32, max_files: usize, expected_generation: u64) !IndexResult {
    const cancel = cancellation.beginExpected(expected_generation);
    defer cancellation.end();
    if (cancel.isCancelled()) return error.Cancelled;
    var provider_ref = acquire() orelse return error.ProviderNotLoaded;
    defer provider_ref.release();
    const provider = provider_ref.provider;
    var result = IndexResult{};
    var cursor: i32 = 0;

    while (max_files == 0 or result.attempted < max_files) {
        if (cancel.isCancelled()) return error.Cancelled;
        const remaining = if (max_files == 0) INDEX_BATCH_SIZE else @min(INDEX_BATCH_SIZE, max_files - result.attempted);
        if (remaining == 0) break;
        const pending = try db.pendingSemanticFilesForModelAfter(allocator, provider.model_id, folder_id, remaining, cursor);
        defer db.freePendingSemanticFiles(allocator, pending);
        if (pending.len == 0) break;
        cursor = pending[pending.len - 1].id;

        for (pending) |file| {
            if (cancel.isCancelled()) return error.Cancelled;
            result.attempted += 1;
            if (!clap_audio.isBuiltInAudioPath(file.path)) {
                try db.recordEmbeddingFailureForModel(provider.model_id, file.id, file.source_content_hash, "unsupported", "built-in semantic indexing supports WAV and uncompressed AIFF/AIFC");
                result.failed += 1;
                continue;
            }
            var embedding: [onnx.EMBEDDING_DIMENSION]f32 = undefined;
            provider.embedAudioWithCancellation(file.path, cancel, &embedding) catch |err| {
                // Only deterministic file/codec defects are terminal. Runtime,
                // memory, I/O, and model failures remain pending and abort this
                // pass so a later call can retry them.
                if (!isTerminalDecodeError(err)) return err;
                try db.recordEmbeddingFailureForModel(provider.model_id, file.id, file.source_content_hash, "decode", @errorName(err));
                result.failed += 1;
                continue;
            };
            if (cancel.isCancelled()) return error.Cancelled;
            db.upsertSemanticEmbeddingForModel(allocator, provider.model_id, file.id, file.source_content_hash, &embedding) catch |err| {
                // A stale row is an indexing race, not a permanent audio
                // failure. Leave it pending under its new content hash.
                if (err == error.StaleContentHash or err == error.FileNotFound) continue;
                return err;
            };
            result.successful += 1;
        }
    }
    return result;
}

fn isTerminalDecodeError(err: anyerror) bool {
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
        error.TruncatedAudio,
        error.TruncatedAiff,
        error.MalformedAiff,
        => true,
        else => false,
    };
}
