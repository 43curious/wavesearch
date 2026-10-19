const std = @import("std");

const sqlite_flags = &.{
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_OMIT_LOAD_EXTENSION=1",
    "-DSQLITE_ENABLE_FTS5",
    "-DSQLITE_DEFAULT_CACHE_SIZE=-16384",
    "-O2",
};

fn configureModule(b: *std.Build, mod: *std.Build.Module) void {
    const bindings = b.addTranslateC(.{
        .root_source_file = b.path("src/c_imports.h"),
        .target = mod.resolved_target.?,
        .optimize = mod.optimize.?,
    });
    bindings.addIncludePath(b.path("vendor"));
    bindings.addIncludePath(b.path("include"));
    bindings.addIncludePath(b.path("src"));
    mod.addImport("c", bindings.createModule());

    mod.addIncludePath(b.path("vendor"));
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("src"));
    mod.addCSourceFile(.{ .file = b.path("vendor/sqlite3.c"), .flags = sqlite_flags });
    mod.addCSourceFile(.{ .file = b.path("src/sqlite_helpers.c"), .flags = &.{ "-I", "vendor" } });
    mod.addCSourceFile(.{ .file = b.path("src/filesystem_helpers.c"), .flags = &.{} });
    mod.addCSourceFile(.{ .file = b.path("src/onnx_bridge.c"), .flags = &.{"-std=c11"} });
    if (mod.resolved_target.?.result.os.tag == .linux) {
        mod.linkSystemLibrary("m", .{});
        mod.linkSystemLibrary("dl", .{});
    }
}

fn macLibrary(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main_c.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = arch,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
        }),
        .optimize = optimize,
        .link_libc = true,
    });
    configureModule(b, mod);
    const lib = b.addLibrary(.{
        .name = if (arch == .aarch64) "wavesearch-arm64" else "wavesearch-x86_64",
        .root_module = mod,
        .linkage = .static,
    });
    lib.bundle_compiler_rt = false;
    return lib;
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const native_mod = b.createModule(.{
        .root_source_file = b.path("src/main_c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureModule(b, native_mod);
    const native_lib = b.addLibrary(.{ .name = "wavesearch", .root_module = native_mod, .linkage = .static });
    const install_native = b.addInstallArtifact(native_lib, .{});
    const lib_step = b.step("lib", "Build and install the portable native static library");
    lib_step.dependOn(&install_native.step);
    if (b.graph.host.result.os.tag == .macos and target.result.os.tag == .macos) {
        const ranlib = b.addSystemCommand(&.{"ranlib"});
        ranlib.addFileArg(b.graph.path(.install_lib, "libwavesearch.a"));
        ranlib.step.dependOn(&install_native.step);
        lib_step.dependOn(&ranlib.step);
    }

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureModule(b, test_mod);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run native Zig tests with vendored SQLite");
    test_step.dependOn(&run_tests.step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/audio_fuzz.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    configureModule(b, fuzz_mod);
    const fuzz_exe = b.addExecutable(.{ .name = "audio-fuzz", .root_module = fuzz_mod });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    run_fuzz.addPassthruArgs();
    b.step("audio-fuzz", "Bounded model-free audio mutation fuzzing; run [iterations seed artifact] or replay path").dependOn(&run_fuzz.step);
    const short_fuzz = b.addRunArtifact(fuzz_exe);
    test_step.dependOn(&short_fuzz.step);

    const waveform_abi_mod = b.createModule(.{
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    waveform_abi_mod.addIncludePath(b.path("include"));
    waveform_abi_mod.addCSourceFile(.{ .file = b.path("src/waveform_abi_test.c"), .flags = &.{"-std=c11"} });
    waveform_abi_mod.addCSourceFile(.{ .file = b.path("src/legacy_abi_test.c"), .flags = &.{"-std=c11"} });
    waveform_abi_mod.linkLibrary(native_lib);
    const waveform_abi_exe = b.addExecutable(.{ .name = "waveform-abi-test", .root_module = waveform_abi_mod });
    const run_waveform_abi = b.addRunArtifact(waveform_abi_exe);
    const waveform_abi_step = b.step("waveform-abi", "Compile and run the public C ABI and waveform contract");
    waveform_abi_step.dependOn(&run_waveform_abi.step);
    test_step.dependOn(&run_waveform_abi.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    const bench_exe = b.addExecutable(.{ .name = "vector-bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Exact top-20 over synthetic normalized 512-D vectors (default 10k)");
    bench_step.dependOn(&run_bench.step);

    const semantic_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/semantic_bench.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    configureModule(b, semantic_bench_mod);
    const semantic_bench_exe = b.addExecutable(.{ .name = "semantic-bench", .root_module = semantic_bench_mod });
    const run_semantic_bench = b.addRunArtifact(semantic_bench_exe);
    run_semantic_bench.addPassthruArgs();
    const semantic_bench_step = b.step("semantic-bench", "Compare SQLite exact retrieval and SQ8 plus exact reranking");
    semantic_bench_step.dependOn(&run_semantic_bench.step);

    const optimization_mod = b.createModule(.{
        .root_source_file = b.path("src/optimization_bench.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    configureModule(b, optimization_mod);
    const optimization_exe = b.addExecutable(.{ .name = "optimization-bench", .root_module = optimization_mod });
    const run_optimization = b.addRunArtifact(optimization_exe);
    run_optimization.addPassthruArgs();
    b.step("optimization-bench", "Disposable catalog, waveform, acoustic, fingerprint and filesystem benchmarks").dependOn(&run_optimization.step);

    const waveform_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/waveform_bench.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    const waveform_bench_exe = b.addExecutable(.{ .name = "waveform-bench", .root_module = waveform_bench_mod });
    const run_waveform_bench = b.addRunArtifact(waveform_bench_exe);
    run_waveform_bench.addPassthruArgs();
    const waveform_bench_step = b.step("waveform-bench", "Portable streaming PCM waveform throughput gate");
    waveform_bench_step.dependOn(&run_waveform_bench.step);

    const relevance_mod = b.createModule(.{
        .root_source_file = b.path("src/relevance.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    configureModule(b, relevance_mod);
    const relevance_exe = b.addExecutable(.{ .name = "relevance", .root_module = relevance_mod });
    const run_relevance = b.addRunArtifact(relevance_exe);
    run_relevance.addPassthruArgs();
    const relevance_step = b.step("relevance", "Run the opt-in real-audio CLAP relevance acceptance set");
    relevance_step.dependOn(&run_relevance.step);

    const coverage_mod = b.createModule(.{
        .root_source_file = b.path("src/coverage_relevance.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    configureModule(b, coverage_mod);
    const coverage_exe = b.addExecutable(.{ .name = "coverage-relevance", .root_module = coverage_mod });
    const run_coverage = b.addRunArtifact(coverage_exe);
    run_coverage.addPassthruArgs();
    b.step("coverage-relevance", "Opt-in mean/segment CLAP coverage comparison with held-out judgments").dependOn(&run_coverage.step);
    // Compile the optional harness in ordinary checks; never load/download models.
    test_step.dependOn(&coverage_exe.step);
    const check_compile = b.step("check-compile", "Compile core check executables without running them");
    for ([_]*std.Build.Step.Compile{ tests, fuzz_exe, waveform_abi_exe, coverage_exe }) |artifact| {
        check_compile.dependOn(&artifact.step);
    }

    const acoustic_acceptance_mod = b.createModule(.{
        .root_source_file = b.path("src/acoustic_acceptance.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    configureModule(b, acoustic_acceptance_mod);
    const acoustic_acceptance_exe = b.addExecutable(.{ .name = "acoustic-acceptance", .root_module = acoustic_acceptance_mod });
    const run_acoustic_acceptance = b.addRunArtifact(acoustic_acceptance_exe);
    run_acoustic_acceptance.addPassthruArgs();
    const acoustic_acceptance_step = b.step("acoustic-acceptance", "Run the opt-in transformed-codec acoustic acceptance set");
    acoustic_acceptance_step.dependOn(&run_acoustic_acceptance.step);

    const perf_mod = b.createModule(.{
        .root_source_file = b.path("src/perf.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    configureModule(b, perf_mod);
    const perf_exe = b.addExecutable(.{ .name = "perf", .root_module = perf_mod });
    const run_perf = b.addRunArtifact(perf_exe);
    run_perf.addPassthruArgs();
    const perf_step = b.step("perf", "Generate and benchmark an opt-in large synthetic metadata corpus");
    perf_step.dependOn(&run_perf.step);

    const xc_step = b.step("xcframework", "Build the macOS universal WaveSearchKit.xcframework");
    if (b.graph.host.result.os.tag != .macos) {
        xc_step.dependOn(&b.addFail("xcframework requires a macOS host with ranlib, lipo, and xcodebuild").step);
        return;
    }

    const arm64 = macLibrary(b, optimize, .aarch64);
    const x86_64 = macLibrary(b, optimize, .x86_64);
    const ranlib_arm64 = b.addSystemCommand(&.{"ranlib"});
    ranlib_arm64.addFileArg(arm64.getEmittedBin());
    const ranlib_x86 = b.addSystemCommand(&.{"ranlib"});
    ranlib_x86.addFileArg(x86_64.getEmittedBin());

    const lipo = b.addSystemCommand(&.{"lipo"});
    lipo.step.dependOn(&ranlib_arm64.step);
    lipo.step.dependOn(&ranlib_x86.step);
    lipo.addArg("-create");
    lipo.addArg("-output");
    const universal = lipo.addOutputFileArg("libwavesearch.a");
    lipo.addFileArg(arm64.getEmittedBin());
    lipo.addFileArg(x86_64.getEmittedBin());

    const rm = b.addSystemCommand(&.{ "rm", "-rf", "WaveSearchKit.xcframework" });
    const xc = b.addSystemCommand(&.{"xcodebuild"});
    xc.step.dependOn(&rm.step);
    xc.step.dependOn(&lipo.step);
    xc.addArgs(&.{ "-create-xcframework", "-library" });
    xc.addFileArg(universal);
    xc.addArgs(&.{ "-headers", "include", "-output", "WaveSearchKit.xcframework" });
    xc_step.dependOn(&xc.step);
}
