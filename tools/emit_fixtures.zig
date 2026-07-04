//! `emit-fixtures` — write the zigfitsio-authored outbound interop corpus to a directory so the
//! toolchain-gated CI `interop` job can open every file with Astropy / CFITSIO / fitsverify /
//! funpack and assert success (X-INTEROP outbound). Pure-Zig; never runs in `zig build test`.
//!
//! Usage: `zig build emit-fixtures -- <output-dir>`
//!
//! Emits tile-compressed images (GZIP/RICE/PLIO/HCOMPRESS) that `funpack` must decompress to the
//! identity ramp, an uncompressed image carrying CHECKSUM/DATASUM (`checksum_on_close`), and an
//! ASCII and binary table. The compressed members are the cross-tool-parity proof for the
//! encoders — especially PLIO_1, whose CFITSIO/IRAF line-list header zigfitsio now emits.
const std = @import("std");
const fits = @import("zigfitsio");

const Allocator = std.mem.Allocator;
const KeywordValue = fits.KeywordValue;

/// The tile-codec enum, reached through `CompressSpec.codec` (the bare `Codec` is not re-exported).
const Codec = @FieldType(fits.CompressSpec, "codec");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(alloc);
    if (argv.len < 2) {
        std.debug.print("usage: emit-fixtures <output-dir>\n", .{});
        return error.MissingOutputDir;
    }
    const outdir: []const u8 = argv[1];

    // Create the output directory (mkdir -p semantics; tolerate an existing dir).
    var threaded: std.Io.Threaded = .init_single_threaded;
    std.Io.Dir.cwd().createDirPath(threaded.io(), outdir) catch {};

    try emitCompressed(alloc, outdir, "compress_gzip.fits", .gzip_1);
    try emitCompressed(alloc, outdir, "compress_rice.fits", .rice_1);
    try emitCompressed(alloc, outdir, "compress_plio.fits", .plio_1);
    try emitCompressed(alloc, outdir, "compress_hcompress.fits", .hcompress_1);
    try emitLossyHcompress(alloc, outdir);
    try emitQuantizedFloat(alloc, outdir);
    try emitChecksumImage(alloc, outdir, "image_checksum.fits");
    try emitBinTable(alloc, outdir, "bintable.fits");
    try emitAsciiTable(alloc, outdir, "ascii.fits");

    std.debug.print("emit-fixtures: wrote 19 files to {s}\n", .{outdir});
}

fn joinPath(alloc: Allocator, outdir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ outdir, name });
}

// ── Tile-compressed image: empty primary + a ZIMAGE extension (the fpack layout) ──────────────
//
// A 16×16 identity ramp (0..255). Non-negative + 16-bit, so the one image is valid for every
// codec: GZIP (any), RICE (8/16/32-bit int), PLIO (non-negative int), HCOMPRESS (≥2-D int).

fn emitCompressed(alloc: Allocator, outdir: []const u8, name: []const u8, codec: Codec) !void {
    const path = try joinPath(alloc, outdir, name);
    var f = try fits.createFile(alloc, path, .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // empty primary
    var ramp: [256]i16 = undefined;
    for (&ramp, 0..) |*p, i| p.* = @intCast(i);
    _ = try fits.writeCompressed(i16, &f, .{
        .bitpix = 16,
        .axes = &.{ 16, 16 },
        .tile = &.{ 16, 16 },
        .codec = codec,
    }, &ramp);
    try f.flush();
}

// ── Lossy HCOMPRESS outbound trio: absolute scale, absolute+smooth, noise-adaptive ────────────
//
// Each `.fits` is paired with a raw little-endian-i32 `.pix` sidecar holding zigfitsio's OWN
// decode of the file it just wrote. `check_funpack.py` asserts CFITSIO `funpack` reproduces the
// sidecar pixels EXACTLY (outbound lossy parity: two independent decoders agree on
// zigfitsio-authored lossy bytes) and that the curved fixtures stay within the scale bound.

fn emitLossyHcompress(alloc: Allocator, outdir: []const u8) !void {
    // The curved 32×32 surface (same family as the inbound goldens: curvature everywhere, so
    // the smooth variant is non-vacuous)…
    var curved: [1024]i32 = undefined;
    for (0..32) |r| {
        for (0..32) |c| curved[r * 32 + c] = @intCast(r * r + 2 * c * c + r * c);
    }
    // …and a deterministic noisy field for the noise-adaptive (request > 0) scale path.
    var noisy: [1024]i32 = undefined;
    var seed: u64 = 0x5DEECE66D2026F00;
    for (&noisy) |*v| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        v.* = @rem(@as(i32, @bitCast(@as(u32, @truncate(seed >> 32)))), 20000);
    }

    try emitLossyOne(alloc, outdir, "compress_hcompress_lossy", &curved, -16.0, false);
    try emitLossyOne(alloc, outdir, "compress_hcompress_smooth", &curved, -16.0, true);
    try emitLossyOne(alloc, outdir, "compress_hcompress_noise", &noisy, 4.0, false);
}

fn emitLossyOne(alloc: Allocator, outdir: []const u8, base: []const u8, pixels: *const [1024]i32, scale: f32, smooth: bool) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.fits", .{ outdir, base });
    var f = try fits.createFile(alloc, path, .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // empty primary (fpack layout)
    const hdu = try fits.writeCompressed(i32, &f, .{
        .bitpix = 32,
        .axes = &.{ 32, 32 },
        .tile = &.{ 32, 16 }, // two tiles (mirrors the inbound goldens' tiling)
        .codec = .hcompress_1,
        .hcomp_scale = scale,
        .hcomp_smooth = smooth,
    }, pixels);
    try f.flush();

    // Sidecar: zigfitsio's own decode of what it just wrote — the funpack parity expectation.
    var ti = try fits.TiledImage.of(&f, hdu);
    defer ti.deinit(alloc);
    var out: [1024]i32 = undefined;
    try ti.readAll(i32, &out);
    var raw: [1024 * 4]u8 = undefined;
    for (out, 0..) |v, i| std.mem.writeInt(i32, raw[i * 4 ..][0..4], v, .little);

    const pix_path = try std.fmt.allocPrint(alloc, "{s}/{s}.pix", .{ outdir, base });
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var pf = try std.Io.Dir.cwd().createFile(io, pix_path, .{});
    defer pf.close(io);
    try pf.writePositionalAll(io, &raw, 0);
}

// ── Quantized-float outbound trio: dithered HCOMPRESS/RICE + NO_DITHER HCOMPRESS ──────────────
//
// f32 pixels quantized with the CFITSIO fits_quantize parity port (compress/quantize.zig,
// q = 4 default) and compressed through the integer codecs. Each `.fits` is paired with a raw
// little-endian-f32 `.pix` sidecar holding zigfitsio's OWN dequantized decode; check_funpack.py
// asserts CFITSIO `funpack` reproduces the sidecar to the exact f32 bit pattern (outbound
// quantized-float parity: two independent decoders agree on zigfitsio-authored bytes).

fn emitQuantizedFloat(alloc: Allocator, outdir: []const u8) !void {
    // The same all-positive LCG noise+gradient family as the inbound goldens (all-positive so
    // no near-zero reconstruction sits on an FP-contraction knife edge — see the golden
    // generator's note; CFITSIO's own builds disagree on those bits).
    var field: [1024]f32 = undefined;
    var state: u32 = 12345;
    for (&field, 0..) |*v, i| {
        state = state *% 1664525 +% 1013904223;
        const u = @as(f64, @floatFromInt(state >> 8)) / 16777216.0;
        const r: f64 = @floatFromInt(i / 32);
        const c: f64 = @floatFromInt(i % 32);
        v.* = @floatCast(10.0 + (r + c) * 0.5 + (u - 0.5) * 8.0);
    }

    try emitQuantizedOne(alloc, outdir, "compress_hcompress_fdith", &field, .hcompress_1, .subtractive_dither_1);
    try emitQuantizedOne(alloc, outdir, "compress_rice_fdith", &field, .rice_1, .subtractive_dither_1);
    try emitQuantizedOne(alloc, outdir, "compress_hcompress_fq0", &field, .hcompress_1, .no_dither);
}

fn emitQuantizedOne(
    alloc: Allocator,
    outdir: []const u8,
    base: []const u8,
    pixels: *const [1024]f32,
    codec: Codec,
    method: @FieldType(fits.CompressSpec, "quantize"),
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.fits", .{ outdir, base });
    var f = try fits.createFile(alloc, path, .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // empty primary (fpack layout)
    const hdu = try fits.writeCompressed(f32, &f, .{
        .bitpix = -32,
        .axes = &.{ 32, 32 }, // default tiling: HCOMPRESS row blocks (32×16), RICE row strips
        .codec = codec,
        .quantize = method,
        .zdither0 = 1,
    }, pixels);
    try f.flush();

    // Sidecar: zigfitsio's own dequantized decode — the funpack parity expectation.
    var ti = try fits.TiledImage.of(&f, hdu);
    defer ti.deinit(alloc);
    var out: [1024]f32 = undefined;
    try ti.readAll(f32, &out);
    var raw: [1024 * 4]u8 = undefined;
    for (out, 0..) |v, i| std.mem.writeInt(u32, raw[i * 4 ..][0..4], @bitCast(v), .little);

    const pix_path = try std.fmt.allocPrint(alloc, "{s}/{s}.pix", .{ outdir, base });
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var pf = try std.Io.Dir.cwd().createFile(io, pix_path, .{});
    defer pf.close(io);
    try pf.writePositionalAll(io, &raw, 0);
}

// ── Uncompressed image with CHECKSUM/DATASUM written on flush (checksum_on_close) ─────────────

fn emitChecksumImage(alloc: Allocator, outdir: []const u8, name: []const u8) !void {
    const path = try joinPath(alloc, outdir, name);
    var f = try fits.createFile(alloc, path, .{ .checksum_on_close = true });
    defer f.deinit();
    var img = try fits.ImageView.append(&f, .{ .bitpix = 16, .axes = &.{ 8, 4 } });
    var px: [32]i16 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(@as(i32, @intCast(i)) * 3 - 5);
    try img.writeAll(i16, &px, .{});
    try f.flush(); // the checksum hook writes DATASUM/CHECKSUM here
}

// ── Tables (mirror the public-API builders in test/corpus.zig) ────────────────────────────────

fn appendTableSpine(
    h: *fits.Header,
    alloc: Allocator,
    xtension: []const u8,
    naxis1: u64,
    nrows: u64,
    pcount: u64,
    tfields: u64,
) !void {
    try h.appendValue(alloc, "XTENSION", .{ .string = xtension }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = @intCast(naxis1) }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = @intCast(nrows) }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = @intCast(pcount) }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = @intCast(tfields) }, null);
}

fn kw(buf: []u8, comptime prefix: []const u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "{d}", .{n}) catch unreachable;
}

fn emitBinTable(alloc: Allocator, outdir: []const u8, name: []const u8) !void {
    const path = try joinPath(alloc, outdir, name);
    var f = try fits.createFile(alloc, path, .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary

    var h = fits.Header.initEmpty();
    errdefer h.deinit(alloc);
    try appendTableSpine(&h, alloc, "BINTABLE", 10, 3, 0, 3); // 1I + 1J + 1E = 2+4+4 = 10
    var b: [16]u8 = undefined;
    try h.appendValue(alloc, kw(&b, "TFORM", 1), .{ .string = "1I" }, null);
    try h.appendValue(alloc, kw(&b, "TTYPE", 1), .{ .string = "I16" }, null);
    try h.appendValue(alloc, kw(&b, "TFORM", 2), .{ .string = "1J" }, null);
    try h.appendValue(alloc, kw(&b, "TTYPE", 2), .{ .string = "I32" }, null);
    try h.appendValue(alloc, kw(&b, "TFORM", 3), .{ .string = "1E" }, null);
    try h.appendValue(alloc, kw(&b, "TTYPE", 3), .{ .string = "F32" }, null);
    try h.ensureEnd(alloc);
    const hdu = try f.appendHdu(h);

    var t = try fits.BinTable.of(&f, hdu);
    defer t.deinit(alloc);
    try t.writeColumn(i16, .{ .index = 0 }, 0, &[_]i16{ 1, 2, 3 }, .{});
    try t.writeColumn(i32, .{ .index = 1 }, 0, &[_]i32{ 10, 20, 30 }, .{});
    try t.writeColumn(f32, .{ .index = 2 }, 0, &[_]f32{ 1.5, 2.5, 3.5 }, .{});
    try f.flush();
}

fn emitAsciiTable(alloc: Allocator, outdir: []const u8, name: []const u8) !void {
    const path = try joinPath(alloc, outdir, name);
    var f = try fits.createFile(alloc, path, .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary

    var h = fits.Header.initEmpty();
    errdefer h.deinit(alloc);
    try appendTableSpine(&h, alloc, "TABLE", 23, 3, 0, 2); // I6 [1,7) + E15.7 [8,23) ⇒ NAXIS1 = 22→23
    var b: [16]u8 = undefined;
    try h.appendValue(alloc, kw(&b, "TBCOL", 1), .{ .int = 1 }, null);
    try h.appendValue(alloc, kw(&b, "TFORM", 1), .{ .string = "I6" }, null);
    try h.appendValue(alloc, kw(&b, "TTYPE", 1), .{ .string = "COUNT" }, null);
    try h.appendValue(alloc, kw(&b, "TBCOL", 2), .{ .int = 8 }, null);
    try h.appendValue(alloc, kw(&b, "TFORM", 2), .{ .string = "E15.7" }, null);
    try h.appendValue(alloc, kw(&b, "TTYPE", 2), .{ .string = "VALUE" }, null);
    try h.ensureEnd(alloc);
    const hdu = try f.appendHdu(h);

    var t = try fits.AsciiTable.of(&f, hdu);
    defer t.deinit(alloc);
    try t.writeColumn(i64, .{ .index = 0 }, 0, &[_]?i64{ 10, 20, 30 });
    try t.writeColumn(f64, .{ .index = 1 }, 0, &[_]?f64{ 1.25, -2.5, 100.0 });
    try f.flush();
}
