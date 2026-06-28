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
    try emitChecksumImage(alloc, outdir, "image_checksum.fits");
    try emitBinTable(alloc, outdir, "bintable.fits");
    try emitAsciiTable(alloc, outdir, "ascii.fits");

    std.debug.print("emit-fixtures: wrote 7 files to {s}\n", .{outdir});
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
