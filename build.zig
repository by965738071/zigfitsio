//! Build script for `zigfitsio` — a pure-Zig FITS 4.0 I/O library (GC-1/2/3).
//!
//! Steps:
//!   zig build              — install the static library artifact (NFR-BUILD-2)
//!   zig build test         — run the unit/integration suite (NFR-BUILD-2)
//!   zig build bench        — run throughput benchmarks (NFR-PERF-1)
//!   zig build fitsverify   — run the structural-validation CLI demo (X-TOOL)
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

    // C-ABI shim (Python/C bindings, design bindings/). A separate dynamic library compiled
    // from `bindings/capi/capi.zig`, which imports the public `zigfitsio` module and exports the
    // `zf_*` C symbols. Kept out of `src/` so the repo's "no C header under src" guard is moot;
    // the hand-written contract lives in `bindings/c/zigfitsio.h`.
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("bindings/capi/capi.zig"),
        .target = target,
        .optimize = optimize,
    });
    capi_mod.addImport("zigfitsio", mod);
    const capi_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zigfitsio_capi",
        .root_module = capi_mod,
    });
    b.installArtifact(capi_lib);
    // Install the shared library into `zig-out/lib` when `zig build capi` is invoked directly
    // (the compile step alone does not copy the artifact out of the cache).
    const capi_install = b.addInstallArtifact(capi_lib, .{});
    const capi_step = b.step("capi", "Build the C-ABI shared library for the bindings");
    capi_step.dependOn(&capi_install.step);

    // `zig build capi-test` — round-trip tests of the C-ABI shim (in `bindings/capi/test_capi.zig`).
    const capi_test_mod = b.createModule(.{
        .root_source_file = b.path("bindings/capi/test_capi.zig"),
        .target = target,
        .optimize = optimize,
    });
    capi_test_mod.addImport("zigfitsio", mod);
    const capi_tests = b.addTest(.{ .root_module = capi_test_mod });
    const run_capi_tests = b.addRunArtifact(capi_tests);
    const capi_test_step = b.step("capi-test", "Test the C-ABI shim");
    capi_test_step.dependOn(&run_capi_tests.step);

    // `zig build test` — the full suite. `root.zig` pulls in every module's tests via
    // its `test` reference block, so this single artifact covers the tree.
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the unit/integration test suite");
    test_step.dependOn(&run_tests.step);

    // The on-disk sample-corpus harness (NFR-TEST-2) lives under `test/` (outside the module
    // path), so it is its own test artifact importing the public `zigfitsio` module. It reads
    // the committed `test/corpus/*.fits` files from the build root and asserts header + data
    // round-trip through `openFile`. Wired into `test` so the single command covers it.
    const corpus_mod = b.createModule(.{
        .root_source_file = b.path("test/corpus.zig"),
        .target = target,
        .optimize = optimize,
    });
    corpus_mod.addImport("zigfitsio", mod);
    const corpus_tests = b.addTest(.{ .root_module = corpus_mod });
    const run_corpus = b.addRunArtifact(corpus_tests);
    test_step.dependOn(&run_corpus.step);

    // `test/e2e.zig` — in-house comprehensive end-to-end harness (testprog.c-equivalent,
    // Deliverable 1). Hermetic, pure-Zig: builds a maximal multi-HDU file, reopens, asserts the
    // full feature matrix, and checks a byte-snapshot digest tripwire. Wired into `test` and
    // also runnable alone via `zig build e2e`.
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("zigfitsio", mod);
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e = b.addRunArtifact(e2e_tests);
    test_step.dependOn(&run_e2e.step);
    const e2e_step = b.step("e2e", "Run the in-house comprehensive e2e harness");
    e2e_step.dependOn(&run_e2e.step);

    // `test/golden.zig` — hermetic consumer of the externally-authored CFITSIO/Astropy golden
    // corpus under `test/golden/` (X-FIXTURES). Reads committed bytes only and graceful-skips
    // when the corpus is absent, so it is safe to wire into `test` on every cell (and decodes
    // reference bytes on the big-endian cell).
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("test/golden.zig"),
        .target = target,
        .optimize = optimize,
    });
    golden_mod.addImport("zigfitsio", mod);
    const golden_tests = b.addTest(.{ .root_module = golden_mod });
    const run_golden = b.addRunArtifact(golden_tests);
    test_step.dependOn(&run_golden.step);

    // `zig build emit-fixtures -- <outdir>` — emit the zigfitsio-authored outbound interop
    // corpus the toolchain-gated `interop` CI job opens with Astropy/CFITSIO (X-INTEROP
    // outbound). Pure-Zig; deliberately NOT wired into `test`.
    const emit_mod = b.createModule(.{
        .root_source_file = b.path("tools/emit_fixtures.zig"),
        .target = target,
        .optimize = optimize,
    });
    emit_mod.addImport("zigfitsio", mod);
    const emit = b.addExecutable(.{ .name = "emit-fixtures", .root_module = emit_mod });
    const run_emit = b.addRunArtifact(emit);
    if (b.args) |args| run_emit.addArgs(args);
    const emit_step = b.step("emit-fixtures", "Emit the zigfitsio-authored outbound interop corpus");
    emit_step.dependOn(&run_emit.step);

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

    // `zig build fitsverify` — CLI demo over the structural validation pass (X-TOOL).
    const fv_mod = b.createModule(.{
        .root_source_file = b.path("tools/fitsverify.zig"),
        .target = target,
        .optimize = optimize,
    });
    fv_mod.addImport("zigfitsio", mod);
    const fitsverify = b.addExecutable(.{ .name = "fitsverify", .root_module = fv_mod });
    b.installArtifact(fitsverify);
    const run_fv = b.addRunArtifact(fitsverify);
    if (b.args) |args| run_fv.addArgs(args);
    const fv_step = b.step("fitsverify", "Run the fitsverify CLI demo");
    fv_step.dependOn(&run_fv.step);

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
