const std = @import("std");

const c = @import("c");

pub const AUDIO_SAMPLES: usize = 480_000;
pub const TEXT_TOKENS: usize = 77;
pub const EMBEDDING_DIMENSION: usize = 512;
pub const DIAGNOSTIC_CAPACITY: usize = 1024;

pub const Error = error{
    InvalidArgument,
    OutOfMemory,
    LibraryLoadFailed,
    SymbolNotFound,
    ApiVersionUnsupported,
    OnnxRuntimeFailure,
    ModelContractMismatch,
    OutputContractMismatch,
    WrongSessionKind,
    NonFiniteEmbedding,
    ZeroNormEmbedding,
    BridgeFailure,
};

threadlocal var init_diagnostic: [DIAGNOSTIC_CAPACITY]u8 = @splat(0);

fn checkResult(result: c_int) Error!void {
    return switch (result) {
        c.WS_ONNX_OK => {},
        c.WS_ONNX_INVALID_ARGUMENT => error.InvalidArgument,
        c.WS_ONNX_OUT_OF_MEMORY => error.OutOfMemory,
        c.WS_ONNX_LIBRARY_LOAD_FAILED => error.LibraryLoadFailed,
        c.WS_ONNX_SYMBOL_NOT_FOUND => error.SymbolNotFound,
        c.WS_ONNX_API_VERSION_UNSUPPORTED => error.ApiVersionUnsupported,
        c.WS_ONNX_RUNTIME_ERROR => error.OnnxRuntimeFailure,
        c.WS_ONNX_MODEL_CONTRACT_ERROR => error.ModelContractMismatch,
        c.WS_ONNX_OUTPUT_CONTRACT_ERROR => error.OutputContractMismatch,
        c.WS_ONNX_WRONG_SESSION_KIND => error.WrongSessionKind,
        else => error.BridgeFailure,
    };
}

fn sentinelLength(buffer: []const u8) usize {
    return std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
}

fn dupePath(path: []const u8) Error![:0]u8 {
    return std.heap.c_allocator.dupeSentinel(u8, path, 0) catch error.OutOfMemory;
}

/// Owns the dynamically loaded shared library and OrtEnv. Sessions retain the
/// C runtime internally, so moving these small Zig handles is safe. Deinit may
/// be called repeatedly, but must not race a method on the same Zig handle.
pub const Runtime = struct {
    handle: ?*c.WsOnnxRuntime = null,

    pub fn init(library_path: []const u8) Error!Runtime {
        @memset(&init_diagnostic, 0);
        const path_z = try dupePath(library_path);
        defer std.heap.c_allocator.free(path_z);
        var handle: ?*c.WsOnnxRuntime = null;
        const result = c.ws_onnx_runtime_open(path_z.ptr, &handle, &init_diagnostic, init_diagnostic.len);
        try checkResult(result);
        return .{ .handle = handle orelse return error.BridgeFailure };
    }

    /// The returned thread-local view remains valid until Runtime.init is
    /// called again on this thread.
    pub fn lastInitDiagnostic() []const u8 {
        return init_diagnostic[0..sentinelLength(&init_diagnostic)];
    }

    pub fn deinit(self: *Runtime) void {
        c.ws_onnx_runtime_close(&self.handle);
    }

    pub fn version(self: *const Runtime, buffer: []u8) Error![]const u8 {
        if (buffer.len == 0) return error.InvalidArgument;
        try checkResult(c.ws_onnx_runtime_version(self.handle, buffer.ptr, buffer.len));
        return buffer[0..sentinelLength(buffer)];
    }

    pub fn lastError(self: *const Runtime, buffer: []u8) Error![]const u8 {
        if (buffer.len == 0) return error.InvalidArgument;
        try checkResult(c.ws_onnx_runtime_error(self.handle, buffer.ptr, buffer.len));
        return buffer[0..sentinelLength(buffer)];
    }
};

pub const Session = struct {
    handle: ?*c.WsOnnxSession = null,

    fn init(runtime: *const Runtime, model_path: []const u8, kind: c.WsOnnxSessionKind, intra_op_threads: u31) Error!Session {
        @memset(&init_diagnostic, 0);
        const path_z = try dupePath(model_path);
        defer std.heap.c_allocator.free(path_z);
        var handle: ?*c.WsOnnxSession = null;
        const result = c.ws_onnx_session_open(
            runtime.handle,
            path_z.ptr,
            kind,
            @intCast(intra_op_threads),
            &handle,
            &init_diagnostic,
            init_diagnostic.len,
        );
        try checkResult(result);
        return .{ .handle = handle orelse return error.BridgeFailure };
    }

    pub fn openAudio(runtime: *const Runtime, model_path: []const u8, intra_op_threads: u31) Error!Session {
        return init(runtime, model_path, c.WS_ONNX_SESSION_AUDIO, intra_op_threads);
    }

    pub fn openText(runtime: *const Runtime, model_path: []const u8, intra_op_threads: u31) Error!Session {
        return init(runtime, model_path, c.WS_ONNX_SESSION_TEXT, intra_op_threads);
    }

    /// Session-open failures use the same per-thread diagnostic buffer as
    /// Runtime.init failures.
    pub fn lastInitDiagnostic() []const u8 {
        return Runtime.lastInitDiagnostic();
    }

    pub fn deinit(self: *Session) void {
        c.ws_onnx_session_close(&self.handle);
    }

    /// Copies the per-session diagnostic while the bridge's diagnostic lock is
    /// held. The caller owns `buffer`, so the returned text remains stable.
    pub fn lastError(self: *const Session, buffer: []u8) Error![]const u8 {
        if (buffer.len == 0) return error.InvalidArgument;
        try checkResult(c.ws_onnx_session_error(self.handle, buffer.ptr, buffer.len));
        return buffer[0..sentinelLength(buffer)];
    }

    /// Calls on one session are serialized in the C bridge. Input and output
    /// storage are caller-owned and no waveform-sized stack temporary exists.
    pub fn runAudio(self: *Session, waveform: []const f32, embedding: []f32) Error!void {
        try checkResult(c.ws_onnx_run_audio(
            self.handle,
            waveform.ptr,
            waveform.len,
            embedding.ptr,
            embedding.len,
        ));
        try normalizeEmbedding(embedding);
    }

    pub fn runText(self: *Session, input_ids: []const i64, attention_mask: []const i64, embedding: []f32) Error!void {
        try checkResult(c.ws_onnx_run_text(
            self.handle,
            input_ids.ptr,
            input_ids.len,
            attention_mask.ptr,
            attention_mask.len,
            embedding.ptr,
            embedding.len,
        ));
        try normalizeEmbedding(embedding);
    }
};

pub const ClapSessions = struct {
    runtime: Runtime,
    audio: Session,
    text: Session,

    pub fn init(library_path: []const u8, audio_model_path: []const u8, text_model_path: []const u8, intra_op_threads: u31) Error!ClapSessions {
        var runtime = try Runtime.init(library_path);
        errdefer runtime.deinit();
        var audio = try Session.openAudio(&runtime, audio_model_path, intra_op_threads);
        errdefer audio.deinit();
        const text = try Session.openText(&runtime, text_model_path, intra_op_threads);
        return .{ .runtime = runtime, .audio = audio, .text = text };
    }

    pub fn deinit(self: *ClapSessions) void {
        self.text.deinit();
        self.audio.deinit();
        self.runtime.deinit();
    }

    pub fn runAudio(self: *ClapSessions, waveform: []const f32, embedding: []f32) Error!void {
        return self.audio.runAudio(waveform, embedding);
    }

    pub fn runText(self: *ClapSessions, input_ids: []const i64, attention_mask: []const i64, embedding: []f32) Error!void {
        return self.text.runText(input_ids, attention_mask, embedding);
    }
};

fn normalizeEmbedding(embedding: []f32) Error!void {
    if (embedding.len != EMBEDDING_DIMENSION) return error.InvalidArgument;
    var squared_norm: f64 = 0;
    for (embedding) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteEmbedding;
        squared_norm += @as(f64, value) * @as(f64, value);
    }
    if (!std.math.isFinite(squared_norm)) return error.NonFiniteEmbedding;
    if (squared_norm <= 1.0e-24) return error.ZeroNormEmbedding;
    const inverse_norm: f32 = @floatCast(1.0 / @sqrt(squared_norm));
    if (!std.math.isFinite(inverse_norm)) return error.NonFiniteEmbedding;
    for (embedding) |*value| value.* *= inverse_norm;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    return std.mem.span(value);
}

test "missing library paths and invalid arguments have stable diagnostics" {
    try std.testing.expectError(error.InvalidArgument, Runtime.init(""));
    try std.testing.expectEqualStrings("library path and output runtime are required", Runtime.lastInitDiagnostic());

    try std.testing.expectError(error.LibraryLoadFailed, Runtime.init("/definitely/not/a/wavesearch/libonnxruntime.so"));
    try std.testing.expect(std.mem.startsWith(u8, Runtime.lastInitDiagnostic(), "failed to load ONNX Runtime library"));

    var empty_runtime: Runtime = .{};
    try std.testing.expectError(error.InvalidArgument, Session.openAudio(&empty_runtime, "missing.onnx", 1));
    try std.testing.expectEqualStrings(
        "runtime, model path, valid kind, thread count, and output session are required",
        Session.lastInitDiagnostic(),
    );
    empty_runtime.deinit();
    empty_runtime.deinit();

    var empty_session: Session = .{};
    var diagnostic: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidArgument, empty_session.lastError(&diagnostic));
    empty_session.deinit();
    empty_session.deinit();
}

test "Zig embedding validation rejects invalid values and normalizes" {
    var values: [EMBEDDING_DIMENSION]f32 = @splat(0);
    try std.testing.expectError(error.ZeroNormEmbedding, normalizeEmbedding(&values));
    values[0] = std.math.nan(f32);
    try std.testing.expectError(error.NonFiniteEmbedding, normalizeEmbedding(&values));
    values[0] = 3;
    values[1] = 4;
    try normalizeEmbedding(&values);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), values[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), values[1], 1.0e-6);
}

test "opt-in ONNX Runtime load and model checks" {
    const library_path = getenv("WS_ORT_LIBRARY") orelse return error.SkipZigTest;
    var runtime = try Runtime.init(library_path);
    defer runtime.deinit();
    var version_buffer: [128]u8 = undefined;
    const loaded_version = try runtime.version(&version_buffer);
    try std.testing.expect(loaded_version.len != 0);

    try std.testing.expectError(
        error.OnnxRuntimeFailure,
        Session.openAudio(&runtime, "/definitely/not/a/wavesearch/audio-model.onnx", 1),
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        Session.lastInitDiagnostic(),
        "failed to open ONNX model",
    ));

    if (getenv("WS_CLAP_AUDIO_MODEL")) |audio_path| {
        var audio = try Session.openAudio(&runtime, audio_path, 1);
        defer audio.deinit();
    }
    if (getenv("WS_CLAP_TEXT_MODEL")) |text_path| {
        var text = try Session.openText(&runtime, text_path, 1);
        defer text.deinit();
    }
}
