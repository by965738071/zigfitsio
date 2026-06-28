//! Build script for `zigfitsio` — a pure-Zig FITS 4.0 I/O library (GC-1/2/3).
//!
//! Steps:
//!   zig build              — install the static library artifact (NFR-BUILD-2)
//!   zig build test         — run the unit/integration suite (NFR-BUILD-2)
//!   zig build bench        — run throughput benchmarks (NFR-PERF-1)
//!   zig build fuzz         — run the header/table fuzz harnesses (NFR-SAFE-2)
//!   zig build wasm-check   — compile the freestanding core for wasm32 (NFR-PORT-3)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The public, fetch-consumable module (NFR-BUILD-1). `src/root.zig` is the only file
    // a consumer imports; it re-exports the public surface and nothing internal (NFR-API-2).
    const mod = b.addModule("zigfitsio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library artifact (NFR-BUILD-2).
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigfitsio",
        .root_module = mod,
    });
    b.installArtifact(lib);

    // `zig build test` — the full suite. `root.zig` pulls in every module's tests via
    // its `test` reference block, so this single artifact covers the tree.
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the unit/integration test suite");
    test_step.dependOn(&run_tests.step);

    // `zig build bench` — throughput benchmarks against the ~2× CFITSIO goal (X-BENCH).
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("zigfitsio", mod);
    const bench = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run throughput benchmarks");
    bench_step.dependOn(&run_bench.step);

    // `zig build fuzz` — header/table fuzz harnesses (X-FUZZ). Run as a test artifact so
    // `--fuzz` engages the in-tree fuzzer; without it the seeded corpus runs as unit tests.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("test/fuzz/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("zigfitsio", mod);
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run the header/table fuzz harnesses");
    fuzz_step.dependOn(&run_fuzz.step);

    // `zig build wasm-check` — compile the freestanding core for wasm32-freestanding
    // (NFR-PORT-3). The OS-backed I/O backends (file/stream/http) are excluded; the
    // in-memory backend is the freestanding I/O path.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_check.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigfitsio-wasm",
        .root_module = wasm_mod,
    });
    const wasm_step = b.step("wasm-check", "Compile the core for wasm32-freestanding");
    wasm_step.dependOn(&wasm_lib.step);
}
