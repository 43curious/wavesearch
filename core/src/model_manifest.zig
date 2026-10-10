const std = @import("std");
const clap_audio = @import("clap_audio.zig");
const tokenizer_mod = @import("tokenizer.zig");

pub const FORMAT_VERSION: i64 = 1;
pub const VECTOR_DIMENSION: i64 = 512;
pub const MAX_MANIFEST_BYTES: usize = 1024 * 1024;
pub const MODEL_KEY_CAPACITY: usize = 128;
pub const artifact_names = [_][]const u8{ "audio.onnx", "text.onnx", "tokenizer.json" };

pub const Artifact = struct {
    bytes: u64,
    sha256: [32]u8,
};

/// Parsed, verified model-pack identity. All string storage is owned and the
/// public value is immutable after construction.
pub const Manifest = struct {
    allocator: std.mem.Allocator,
    model_dir: []u8,
    model: []u8,
    checkpoint: []u8,
    feature_revision: []u8,
    artifacts: [3]Artifact,
    model_key: [MODEL_KEY_CAPACITY]u8,
    model_key_len: u8,

    pub fn deinit(self: *Manifest) void {
        self.allocator.free(self.model_dir);
        self.allocator.free(self.model);
        self.allocator.free(self.checkpoint);
        self.allocator.free(self.feature_revision);
        self.* = undefined;
    }

    pub fn key(self: *const Manifest) []const u8 {
        return self.model_key[0..self.model_key_len];
    }

    pub fn artifactPath(self: *const Manifest, allocator: std.mem.Allocator, index: usize) ![]u8 {
        if (index >= artifact_names.len) return error.InvalidArtifact;
        return std.fs.path.join(allocator, &.{ self.model_dir, artifact_names[index] });
    }
};

pub fn loadAndVerify(allocator: std.mem.Allocator, io: std.Io, model_dir: []const u8) !Manifest {
    if (model_dir.len == 0) return error.InvalidModelDirectory;
    const manifest_path = try std.fs.path.join(allocator, &.{ model_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(MAX_MANIFEST_BYTES));
    defer allocator.free(bytes);
    var result = try parse(allocator, model_dir, bytes);
    errdefer result.deinit();
    for (artifact_names, 0..) |_, index| try verifyArtifact(io, &result, index);
    return result;
}

pub fn parse(allocator: std.mem.Allocator, model_dir: []const u8, bytes: []const u8) !Manifest {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidManifestUtf8;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    if (try integer(try required(root, "format_version")) != FORMAT_VERSION) return error.UnsupportedManifestVersion;
    if (try integer(try required(root, "vector_dimension")) != VECTOR_DIMENSION) return error.InvalidVectorDimension;
    const model = try nonEmptyString(try required(root, "model"));
    const checkpoint = try nonEmptyString(try required(root, "checkpoint"));
    const revision = try nonEmptyString(try required(root, "feature_revision"));
    const artifact_object = try object(try required(root, "artifacts"));
    if (artifact_object.count() != artifact_names.len) return error.InvalidArtifactSet;
    // Reject dangerous/alternate keys before reporting a required key missing.
    var artifact_it = artifact_object.iterator();
    while (artifact_it.next()) |entry| {
        if (!isSafeRelativePath(entry.key_ptr.*)) return error.UnsafeArtifactPath;
        var known = false;
        for (artifact_names) |name| known = known or std.mem.eql(u8, name, entry.key_ptr.*);
        if (!known) return error.InvalidArtifactSet;
    }

    var artifacts: [3]Artifact = undefined;
    for (artifact_names, 0..) |name, index| {
        if (!isSafeRelativePath(name)) return error.UnsafeArtifactPath;
        const entry = try object(artifact_object.get(name) orelse return error.MissingArtifact);
        // The artifact record contract itself is exact too; silently ignored
        // fields can otherwise change identity without changing model_key.
        if (entry.count() != 2) return error.InvalidArtifactEntry;
        const byte_count = try integer(try required(entry, "bytes"));
        if (byte_count <= 0) return error.InvalidArtifactSize;
        const digest_text = try string(try required(entry, "sha256"));
        artifacts[index] = .{
            .bytes = @intCast(byte_count),
            .sha256 = try parseLowerSha256(digest_text),
        };
    }
    const owned_dir = try allocator.dupe(u8, model_dir);
    errdefer allocator.free(owned_dir);
    const owned_model = try allocator.dupe(u8, model);
    errdefer allocator.free(owned_model);
    const owned_checkpoint = try allocator.dupe(u8, checkpoint);
    errdefer allocator.free(owned_checkpoint);
    const owned_revision = try allocator.dupe(u8, revision);
    errdefer allocator.free(owned_revision);
    var result = Manifest{
        .allocator = allocator,
        .model_dir = owned_dir,
        .model = owned_model,
        .checkpoint = owned_checkpoint,
        .feature_revision = owned_revision,
        .artifacts = artifacts,
        .model_key = @splat(0),
        .model_key_len = 0,
    };
    buildModelKey(&result);
    return result;
}

fn verifyArtifact(io: std.Io, manifest: *const Manifest, index: usize) !void {
    const path = try manifest.artifactPath(manifest.allocator, index);
    defer manifest.allocator.free(path);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size != manifest.artifacts[index].bytes) return error.ArtifactSizeMismatch;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const amount: usize = @intCast(@min(@as(u64, buffer.len), stat.size - offset));
        const got = try file.readPositionalAll(io, buffer[0..amount], offset);
        if (got != amount) return error.ArtifactReadFailed;
        hasher.update(buffer[0..got]);
        offset += got;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    if (!std.mem.eql(u8, &digest, &manifest.artifacts[index].sha256)) return error.ArtifactHashMismatch;
}

fn buildModelKey(self: *Manifest) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, self.model);
    hashField(&hasher, self.checkpoint);
    hashField(&hasher, self.feature_revision);
    // Provider implementation details are part of embedding identity. This
    // prevents a decoder/resampler/tokenizer upgrade from silently reusing
    // vectors generated by an incompatible previous binary.
    hashField(&hasher, clap_audio.PREPROCESSING_REVISION);
    hashField(&hasher, tokenizer_mod.IMPLEMENTATION_REVISION);
    for (artifact_names, self.artifacts) |name, artifact| {
        hashField(&hasher, name);
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, artifact.bytes, .little);
        hasher.update(&size);
        hasher.update(&artifact.sha256);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const prefix = "clap-pack-v1:";
    @memcpy(self.model_key[0..prefix.len], prefix);
    _ = std.fmt.bufPrint(self.model_key[prefix.len..], "{x}", .{digest}) catch unreachable;
    self.model_key_len = prefix.len + 64;
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .little);
    hasher.update(&length);
    hasher.update(value);
}

fn parseLowerSha256(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidArtifactHash;
    var result: [32]u8 = undefined;
    for (0..32) |index| {
        const high = lowerHex(text[index * 2]) orelse return error.InvalidArtifactHash;
        const low = lowerHex(text[index * 2 + 1]) orelse return error.InvalidArtifactHash;
        result[index] = high << 4 | low;
    }
    return result;
}

fn lowerHex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}

pub fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn required(value: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return value.get(name) orelse error.MissingManifestField;
}
fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |v| v,
        else => error.InvalidManifest,
    };
}
fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |v| v,
        else => error.InvalidManifest,
    };
}
fn nonEmptyString(value: std.json.Value) ![]const u8 {
    const value_string = try string(value);
    if (value_string.len == 0) return error.EmptyManifestIdentity;
    return value_string;
}
fn integer(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |v| v,
        else => error.InvalidManifest,
    };
}

fn testDigest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn makeTestManifest(allocator: std.mem.Allocator, version: i64, audio_name: []const u8, audio: []const u8, text: []const u8, tokenizer: []const u8) ![]u8 {
    const a = testDigest(audio);
    const t = testDigest(text);
    const k = testDigest(tokenizer);
    return std.fmt.allocPrint(allocator, "{{\"format_version\":{d},\"vector_dimension\":512,\"model\":\"test-model\",\"checkpoint\":\"test.ckpt\",\"feature_revision\":\"test-rev\",\"artifacts\":{{\"{s}\":{{\"bytes\":{d},\"sha256\":\"{x}\"}},\"text.onnx\":{{\"bytes\":{d},\"sha256\":\"{x}\"}},\"tokenizer.json\":{{\"bytes\":{d},\"sha256\":\"{x}\"}}}}}}", .{ version, audio_name, audio.len, a, text.len, t, tokenizer.len, k });
}

test "manifest verifies exact tiny artifacts and stable immutable key" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "audio.onnx", .data = "audio" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "text.onnx", .data = "text" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tokenizer.json", .data = "tokenizer" });
    const json = try makeTestManifest(allocator, 1, "audio.onnx", "audio", "text", "tokenizer");
    defer allocator.free(json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest.json", .data = json });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    var first = try loadAndVerify(allocator, std.testing.io, root);
    defer first.deinit();
    var second = try loadAndVerify(allocator, std.testing.io, root);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.key(), second.key());
    try std.testing.expect(first.key().len <= MODEL_KEY_CAPACITY - 1);
}

test "manifest rejects traversal size hash version and dimension errors" {
    const allocator = std.testing.allocator;
    const good = try makeTestManifest(allocator, 1, "audio.onnx", "audio", "text", "tokenizer");
    defer allocator.free(good);
    const traversal = try makeTestManifest(allocator, 1, "../audio.onnx", "audio", "text", "tokenizer");
    defer allocator.free(traversal);
    try std.testing.expectError(error.UnsafeArtifactPath, parse(allocator, "/tmp", traversal));
    const bad_version = try makeTestManifest(allocator, 2, "audio.onnx", "audio", "text", "tokenizer");
    defer allocator.free(bad_version);
    try std.testing.expectError(error.UnsupportedManifestVersion, parse(allocator, "/tmp", bad_version));
    const bad_dimension = try std.mem.replaceOwned(u8, allocator, good, "\"vector_dimension\":512", "\"vector_dimension\":7");
    defer allocator.free(bad_dimension);
    try std.testing.expectError(error.InvalidVectorDimension, parse(allocator, "/tmp", bad_dimension));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "audio.onnx", .data = "wrong!" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "text.onnx", .data = "text" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tokenizer.json", .data = "tokenizer" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest.json", .data = good });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    try std.testing.expectError(error.ArtifactSizeMismatch, loadAndVerify(allocator, std.testing.io, root));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "audio.onnx", .data = "xxxxx" });
    try std.testing.expectError(error.ArtifactHashMismatch, loadAndVerify(allocator, std.testing.io, root));

    const upper_hash = try std.mem.replaceOwned(u8, allocator, good, "ed", "ED");
    defer allocator.free(upper_hash);
    try std.testing.expectError(error.InvalidArtifactHash, parse(allocator, "/tmp", upper_hash));
}
