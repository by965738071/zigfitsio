//! Hermetic consumer of the externally-authored golden corpus under `test/golden/`
//! (X-FIXTURES). Reads only committed bytes through the public `fits` API, so it runs on every
//! `zig build test` cell — including the s390x big-endian QEMU cell, where it decodes reference
//! CFITSIO/Astropy bytes on a genuine big-endian host (coverage the LE matrix cannot produce).
//!
//! Every committed `.fits` is authored by CFITSIO 4.6.4 (`interop/c/gen_sources.c` and `fpack`);
//! the lone `.csv` is an Astropy WCS cross-check sidecar. Provenance, the generating tool, and
//! the expected decoded values for each file live in `MANIFEST.json` (and
//! `conformance/expected.json`). Regenerate with `make -C interop golden`.
//!
//! Graceful skip: if the golden corpus (its MANIFEST) is absent — a sparse checkout, or a
//! contributor without the interop fixtures — every test reports `error.SkipZigTest` (shown as
//! *skipped*, never falsely green). Once the MANIFEST is present, a missing fixture is a hard
//! failure: a half-regenerated corpus must not pass silently.
const std = @import("std");
const fits = @import("zigfitsio");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const golden_dir = "test/golden";
const manifest = golden_dir ++ "/MANIFEST.json";

/// Mirror of `test/corpus.zig`'s directory probe: a single-threaded blocking I/O context used
/// only to test a path's existence. All file *contents* flow through the public `fits` API.
fn present(path: []const u8) bool {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    return if (cwd.access(io, path, .{})) |_| true else |_| false;
}

/// Skip the whole golden suite cleanly when the corpus is not checked out.
fn requireCorpus() error{SkipZigTest}!void {
    if (!present(manifest)) return error.SkipZigTest;
}

/// Read a whole committed file into `alloc`-owned bytes via a private blocking I/O context (the
/// same single-threaded backend `FileDevice` uses). Used for the raw SHA-256 / MANIFEST / CSV
/// reads; all FITS *structure* still flows through the public `fits.openFile` API.
fn readFileAlloc(alloc: Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const size = try file.length(io);
    const buf = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

fn hexLower(digest: [32]u8) [64]u8 {
    const chars = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2] = chars[byte >> 4];
        out[i * 2 + 1] = chars[byte & 0x0f];
    }
    return out;
}

// ── Baseline presence contract ────────────────────────────────────────────────────────────

test "golden: corpus present (or cleanly skipped)" {
    try requireCorpus();
    try testing.expect(present(manifest));
}

// ── Hermetic integrity: every MANIFEST entry's bytes hash to its recorded sha256 ───────────
//
// Runs on every cell (no codec/decoder involved) and catches corruption or a half-regenerated
// corpus. Parses MANIFEST.json with std.json, ignoring the rich provenance fields.

const ManifestFile = struct { path: []const u8, sha256: []const u8 };
const Manifest = struct { files: []const ManifestFile };

test "golden: file sha256 matches MANIFEST" {
    try requireCorpus();
    const alloc = testing.allocator;

    const mbytes = try readFileAlloc(alloc, manifest);
    defer alloc.free(mbytes);
    const parsed = try std.json.parseFromSlice(Manifest, alloc, mbytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testing.expect(parsed.value.files.len >= 26); // all goldens accounted for
    for (parsed.value.files) |entry| {
        const path = try std.fmt.allocPrint(alloc, golden_dir ++ "/{s}", .{entry.path});
        defer alloc.free(path);
        const bytes = try readFileAlloc(alloc, path);
        defer alloc.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = hexLower(digest);
        testing.expectEqualStrings(entry.sha256, &hex) catch |e| {
            std.debug.print("sha256 mismatch for {s}\n", .{entry.path});
            return e;
        };
    }
}

// ── CMP-4/5/6: tile-compressed images authored by fpack decode to the identity ramp ────────
//
// Each `.fz` golden is `pixel[i] = i` over a 16×16 image (256 pixels). The Zig consumer decodes
// HDU 2 (fpack writes an empty primary + a ZIMAGE BINTABLE) and asserts the ramp by formula —
// no sidecar values needed. A wrong pixel here is a genuine inbound codec-interop bug.

fn expectRampTile(alloc: Allocator, rel: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, golden_dir ++ "/{s}", .{rel});
    defer alloc.free(path);
    var f = try fits.openFile(alloc, path, .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(2); // empty primary + tile-compressed BINTABLE
    var ti = try fits.TiledImage.of(&f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(u64, 256), ti.elementCount());
    try testing.expectEqualSlices(u64, &.{ 16, 16 }, ti.dims());
    var out: [256]i32 = undefined;
    try ti.readAll(i32, &out);
    for (out, 0..) |got, i| try testing.expectEqual(@as(i32, @intCast(i)), got);
}

test "golden: CMP-4 RICE_1 tile decodes to ramp (fpack -r)" {
    try requireCorpus();
    try expectRampTile(testing.allocator, "compress/tile_rice.fits");
}

test "golden: GZIP_1 tile decodes to ramp (fpack -g1)" {
    try requireCorpus();
    try expectRampTile(testing.allocator, "compress/tile_gzip.fits");
}

test "golden: CMP-6 HCOMPRESS_1 lossless tile decodes to ramp (fpack -h -s 0)" {
    try requireCorpus();
    try expectRampTile(testing.allocator, "compress/tile_hcompress.fits");
}

// ── CMP-6 lossy: CFITSIO lossy HCOMPRESS tiles must decode EXACTLY like funpack ─────────────
//
// Each lossy `.fz` (absolute scale 16 over a curved 32×32 surface, 32×16 tiles) is paired with
// a committed `*_expected.fits` — funpack's own decode of those bytes, i.e. the authoritative
// pixels. Lossy HCOMPRESS decode is deterministic integer math, so zigfitsio must reproduce
// funpack bit-for-bit: `lossy16`/`lossy32` cover the plain (`ZVAL2 = 0`) inverse across both
// CFITSIO decode variants (int for ZBITPIX 16, LONGLONG for 32), and `smooth` (`ZVAL2 = 1`)
// proves decode-side hsmooth is CFITSIO-identical — not merely "close".

const curv_n = 32 * 32;

fn readExpectedPixels(alloc: Allocator, rel: []const u8, out: *[curv_n]i32) !void {
    const path = try std.fmt.allocPrint(alloc, golden_dir ++ "/{s}", .{rel});
    defer alloc.free(path);
    var f = try fits.openFile(alloc, path, .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(1); // funpack restores the image as the primary HDU
    try testing.expectEqualSlices(u64, &.{ 32, 32 }, hdu.axes);
    var v = try fits.ImageView.of(&f, hdu);
    try v.readAll(i32, out, .{});
}

fn expectLossyTile(alloc: Allocator, fz_rel: []const u8, expected_rel: []const u8) !void {
    var expected: [curv_n]i32 = undefined;
    try readExpectedPixels(alloc, expected_rel, &expected);

    const path = try std.fmt.allocPrint(alloc, golden_dir ++ "/{s}", .{fz_rel});
    defer alloc.free(path);
    var f = try fits.openFile(alloc, path, .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(2); // empty primary + tile-compressed BINTABLE
    var ti = try fits.TiledImage.of(&f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(u64, curv_n), ti.elementCount());
    var out: [curv_n]i32 = undefined;
    try ti.readAll(i32, &out);
    try testing.expectEqualSlices(i32, &expected, &out);
}

test "golden: CMP-6 lossy HCOMPRESS_1 i16 tile decodes exactly like funpack (fpack -h -s -16)" {
    try requireCorpus();
    try expectLossyTile(testing.allocator, "compress/tile_hcompress_lossy16.fits", "compress/tile_hcompress_lossy16_expected.fits");
}

test "golden: CMP-6 lossy HCOMPRESS_1 i32 tile decodes exactly like funpack (scale -16, SMOOTH=0)" {
    try requireCorpus();
    try expectLossyTile(testing.allocator, "compress/tile_hcompress_lossy32.fits", "compress/tile_hcompress_lossy32_expected.fits");
}

test "golden: CMP-6 smoothed lossy HCOMPRESS_1 tile (ZVAL2=1) decodes exactly like funpack hsmooth" {
    try requireCorpus();
    const alloc = testing.allocator;
    try expectLossyTile(alloc, "compress/tile_hcompress_smooth.fits", "compress/tile_hcompress_smooth_expected.fits");

    // Non-vacuousness: the smooth file differs from the SMOOTH=0 file only in ZVAL2 (identical
    // compressed streams), so their funpack decodes differing proves the smoothing pass — in
    // funpack AND (via the exact-match asserts above) in zigfitsio — actually changed pixels.
    var plain: [curv_n]i32 = undefined;
    try readExpectedPixels(alloc, "compress/tile_hcompress_lossy32_expected.fits", &plain);
    var smoothed: [curv_n]i32 = undefined;
    try readExpectedPixels(alloc, "compress/tile_hcompress_smooth_expected.fits", &smoothed);
    try testing.expect(!std.mem.eql(i32, &plain, &smoothed));
}

// ── Quantized-float tiles: CFITSIO-quantized f32 goldens decode EXACTLY like funpack ───────
//
// Each `.fz` holds the 32×32 f32 noise+gradient field quantized by CFITSIO (q = 4) — HCOMPRESS
// under SUBTRACTIVE_DITHER_1 (ZDITHER0 = 1) and NO_DITHER, and RICE under SUBTRACTIVE_DITHER_1 —
// paired with funpack's own dequantized decode. Dequantization is deterministic arithmetic over
// the shared 10000-entry Park–Miller table, so zigfitsio must reproduce funpack to the exact
// f32 bit pattern: these goldens pin the inbound quantized-float path (dither offsets, per-tile
// ZSCALE/ZZERO, and the `(stored − r + 0.5)·ZSCALE + ZZERO` reconstruction) permanently.

const noise_n = 32 * 32;

fn expectQuantizedTile(alloc: Allocator, fz_rel: []const u8, expected_rel: []const u8, quantiz: []const u8) !void {
    // funpack's decode: the authoritative dequantized pixels (primary HDU, BITPIX -32).
    var expected: [noise_n]f32 = undefined;
    {
        const path = try std.fmt.allocPrint(alloc, golden_dir ++ "/{s}", .{expected_rel});
        defer alloc.free(path);
        var f = try fits.openFile(alloc, path, .read_only, .{});
        defer f.deinit();
        const hdu = try f.select(1);
        try testing.expectEqual(@as(i64, -32), try hdu.header.getValue(i64, "BITPIX"));
        try testing.expectEqualSlices(u64, &.{ 32, 32 }, hdu.axes);
        var v = try fits.ImageView.of(&f, hdu);
        try v.readAll(f32, &expected, .{ .scaling = .{ .mode = .raw } });
    }

    const path = try std.fmt.allocPrint(alloc, golden_dir ++ "/{s}", .{fz_rel});
    defer alloc.free(path);
    var f = try fits.openFile(alloc, path, .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(2); // empty primary + tile-compressed BINTABLE
    const zq = try hdu.header.getString(alloc, "ZQUANTIZ");
    defer alloc.free(zq);
    try testing.expectEqualStrings(quantiz, std.mem.trim(u8, zq, " "));
    var ti = try fits.TiledImage.of(&f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(u64, noise_n), ti.elementCount());
    var out: [noise_n]f32 = undefined;
    try ti.readAll(f32, &out);
    // Bit-pattern equality (stricter than `==`): the dequantization must be funpack-identical.
    for (expected, out, 0..) |e, g, i| {
        testing.expectEqual(@as(u32, @bitCast(e)), @as(u32, @bitCast(g))) catch |err| {
            std.debug.print("pixel {d}: expected {e}, got {e}\n", .{ i, e, g });
            return err;
        };
    }
}

test "golden: CMP-6 quantized-float HCOMPRESS_1 dithered tile decodes exactly like funpack (SUBTRACTIVE_DITHER_1, ZDITHER0=1)" {
    try requireCorpus();
    try expectQuantizedTile(testing.allocator, "compress/tile_hcompress_fdith.fits", "compress/tile_hcompress_fdith_expected.fits", "SUBTRACTIVE_DITHER_1");
}

test "golden: CMP-6 quantized-float HCOMPRESS_1 undithered tile decodes exactly like funpack (fpack -q0 4)" {
    try requireCorpus();
    try expectQuantizedTile(testing.allocator, "compress/tile_hcompress_fq0.fits", "compress/tile_hcompress_fq0_expected.fits", "NO_DITHER");
}

test "golden: CMP-4 quantized-float RICE_1 dithered tile decodes exactly like funpack (SUBTRACTIVE_DITHER_1, ZDITHER0=1)" {
    try requireCorpus();
    try expectQuantizedTile(testing.allocator, "compress/tile_rice_fdith.fits", "compress/tile_rice_fdith_expected.fits", "SUBTRACTIVE_DITHER_1");
}

// The f64 variant of `expectQuantizedTile`: the quantized-DOUBLE (ZBITPIX = -64) decode must
// reproduce funpack's full-double dequantization to the exact f64 bit pattern. Pins the
// double-precision read path permanently (hunt 2026-07-06 item 41: an f32 funnel in
// `dither.unquantize` corrupted every pixel of every quantized double file; the fix also
// matches CFITSIO/astropy's FMA-contracted `* ZSCALE + ZZERO` via `@mulAdd`).
fn expectQuantizedTileF64(alloc: Allocator, fz_rel: []const u8, expected_rel: []const u8, quantiz: []const u8) !void {
    const npix = noise_n;
    var expected: [npix]f64 = undefined;
    {
        const path = try std.fmt.allocPrint(alloc, golden_dir ++ "/{s}", .{expected_rel});
        defer alloc.free(path);
        var f = try fits.openFile(alloc, path, .read_only, .{});
        defer f.deinit();
        const hdu = try f.select(1);
        try testing.expectEqual(@as(i64, -64), try hdu.header.getValue(i64, "BITPIX"));
        try testing.expectEqualSlices(u64, &.{ 32, 32 }, hdu.axes);
        var v = try fits.ImageView.of(&f, hdu);
        try v.readAll(f64, &expected, .{ .scaling = .{ .mode = .raw } });
    }

    const path = try std.fmt.allocPrint(alloc, golden_dir ++ "/{s}", .{fz_rel});
    defer alloc.free(path);
    var f = try fits.openFile(alloc, path, .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(2); // empty primary + tile-compressed BINTABLE
    const zq = try hdu.header.getString(alloc, "ZQUANTIZ");
    defer alloc.free(zq);
    try testing.expectEqualStrings(quantiz, std.mem.trim(u8, zq, " "));
    try testing.expectEqual(@as(i64, -64), try hdu.header.getValue(i64, "ZBITPIX"));
    var ti = try fits.TiledImage.of(&f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(u64, npix), ti.elementCount());
    var out: [npix]f64 = undefined;
    try ti.readAll(f64, &out);
    for (expected, out, 0..) |e, g, i| {
        testing.expectEqual(@as(u64, @bitCast(e)), @as(u64, @bitCast(g))) catch |err| {
            std.debug.print("pixel {d}: expected {e}, got {e}\n", .{ i, e, g });
            return err;
        };
    }
}

test "golden: CMP-4 quantized-double RICE_1 dithered tile decodes exactly like funpack at full f64 width (SUBTRACTIVE_DITHER_1, ZDITHER0=1)" {
    try requireCorpus();
    try expectQuantizedTileF64(testing.allocator, "compress/tile_rice_ddith.fits", "compress/tile_rice_ddith_expected.fits", "SUBTRACTIVE_DITHER_1");
}

// CMP-5: a genuine CFITSIO `fpack -p` PLIO tile decodes to the exact ramp. This golden caught a
// real interop bug — zigfitsio's PLIO codec omitted the 7-word IRAF/CFITSIO line-list header, so
// it could neither read CFITSIO tiles nor write CFITSIO-readable ones. Fixed in
// `src/compress/plio.zig` (the codec now emits + skips the header); this asserts the inbound leg.
test "golden: CMP-5 PLIO_1 tile decodes to ramp (fpack -p)" {
    try requireCorpus();
    try expectRampTile(testing.allocator, "compress/tile_plio.fits");
}

// ── X-SUM: CFITSIO checksum vector — DATASUM recomputes and CHECKSUM/DATASUM both verify ───

test "golden: X-SUM CFITSIO checksum vector recomputes and verifies" {
    try requireCorpus();
    const alloc = testing.allocator;
    var f = try fits.openFile(alloc, golden_dir ++ "/checksum/cfitsio_ascii_checksum.fits", .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(2); // the ASCII TABLE carrying the integrity cards

    // The DATASUM card CFITSIO wrote (authoritative), parsed from its string value.
    const ds_str = try hdu.header.getString(alloc, "DATASUM");
    defer alloc.free(ds_str);
    const ds_card = try std.fmt.parseInt(u32, std.mem.trim(u8, ds_str, " "), 10);
    try testing.expectEqual(@as(u32, 1837006711), ds_card); // recorded in MANIFEST

    // zigfitsio recomputes the same data-unit checksum CFITSIO authored.
    const ds_recomputed = try fits.checksum.datasum(&f, hdu);
    try testing.expectEqual(ds_card, ds_recomputed);

    // Both integrity keywords verify against zigfitsio's independent recompute.
    const r = try fits.checksum.verify(&f, hdu);
    try testing.expectEqual(fits.checksum.Verify.match, r.data);
    try testing.expectEqual(fits.checksum.Verify.match, r.sum);
}

// ── X-INTEROP inbound: plain CFITSIO images and tables read back to their authored values ──

test "golden: inbound i16 image (value[i] = i - 8)" {
    try requireCorpus();
    const alloc = testing.allocator;
    var f = try fits.openFile(alloc, golden_dir ++ "/images/img_i16.fits", .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(1);
    try testing.expectEqual(@as(i64, 16), try hdu.header.getValue(i64, "BITPIX"));
    try testing.expectEqualSlices(u64, &.{ 8, 4 }, hdu.axes);
    var v = try fits.ImageView.of(&f, hdu);
    var out: [32]i16 = undefined;
    try v.readAll(i16, &out, .{});
    for (out, 0..) |got, i| {
        try testing.expectEqual(@as(i16, @intCast(@as(i64, @intCast(i)) - 8)), got);
    }
}

test "golden: inbound f32 image with IEEE-NaN null pixel" {
    try requireCorpus();
    const alloc = testing.allocator;
    var f = try fits.openFile(alloc, golden_dir ++ "/images/img_f32.fits", .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(1);
    try testing.expectEqual(@as(i64, -32), try hdu.header.getValue(i64, "BITPIX"));
    var v = try fits.ImageView.of(&f, hdu);

    // Raw read preserves the NaN null at index 7; other pixels are i*0.25.
    var raw: [15]f32 = undefined;
    try v.readAll(f32, &raw, .{ .scaling = .{ .mode = .raw } });
    try testing.expect(std.math.isNan(raw[7]));
    for (raw, 0..) |got, i| {
        if (i == 7) continue;
        try testing.expectEqual(@as(f32, @floatFromInt(i)) * 0.25, got);
    }

    // A null-sentinel read maps the NaN to the caller sentinel.
    var out: [15]f32 = undefined;
    try v.readAll(f32, &out, .{ .null_sentinel = -1.0 });
    try testing.expectEqual(@as(f32, -1.0), out[7]);
}

test "golden: inbound binary table (1J/1E/1D/8A)" {
    try requireCorpus();
    const alloc = testing.allocator;
    var f = try fits.openFile(alloc, golden_dir ++ "/tables/bintable.fits", .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(2);
    try testing.expectEqual(fits.HduKind.binary_table, hdu.kind);
    var t = try fits.BinTable.of(&f, hdu);
    defer t.deinit(alloc);
    try testing.expectEqual(@as(u16, 4), t.columnCount());
    try testing.expectEqual(@as(u64, 3), t.rowCount());

    var idx: [3]i32 = undefined;
    try t.readColumn(i32, .{ .name = "INDEX" }, 0, &idx, .{});
    try testing.expectEqualSlices(i32, &.{ 10, 20, 30 }, &idx);
    var flux: [3]f32 = undefined;
    try t.readColumn(f32, .{ .name = "FLUX" }, 0, &flux, .{});
    try testing.expectEqualSlices(f32, &.{ 1.5, 2.5, 3.5 }, &flux);
    var dvl: [3]f64 = undefined;
    try t.readColumn(f64, .{ .name = "DVAL" }, 0, &dvl, .{});
    try testing.expectEqualSlices(f64, &.{ 0.25, 0.5, 0.75 }, &dvl);

    var nm: [24]u8 = undefined; // 3 rows × 8A
    try t.readColumn(u8, .{ .name = "NAME" }, 0, &nm, .{});
    try testing.expectEqualStrings("alpha", std.mem.trimEnd(u8, nm[0..8], " \x00"));
    try testing.expectEqualStrings("beta", std.mem.trimEnd(u8, nm[8..16], " \x00"));
    try testing.expectEqualStrings("gamma", std.mem.trimEnd(u8, nm[16..24], " \x00"));
}

test "golden: inbound ASCII table (I6/F12.4/A5)" {
    try requireCorpus();
    const alloc = testing.allocator;
    var f = try fits.openFile(alloc, golden_dir ++ "/tables/ascii.fits", .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(2);
    try testing.expectEqual(fits.HduKind.ascii_table, hdu.kind);
    var t = try fits.AsciiTable.of(&f, hdu);
    defer t.deinit(alloc);
    try testing.expectEqual(@as(u16, 3), t.columnCount());
    try testing.expectEqual(@as(u64, 3), t.rowCount());

    var id: [3]?i64 = undefined;
    try t.readColumn(i64, .{ .name = "ID" }, 0, &id);
    try testing.expectEqual(@as(i64, 100), id[0].?);
    try testing.expectEqual(@as(i64, 200), id[1].?);
    try testing.expectEqual(@as(i64, 300), id[2].?);

    var flux: [3]?f64 = undefined;
    try t.readColumn(f64, .{ .name = "FLUX" }, 0, &flux);
    try testing.expect(@abs(flux[0].? - 3.1416) < 1e-6);
    try testing.expect(@abs(flux[1].? - 2.7183) < 1e-6);
    try testing.expect(@abs(flux[2].? - 1.4142) < 1e-6);

    var note: [8]u8 = undefined;
    const s = (try t.readCellStr(.{ .name = "NOTE" }, 0, &note)).?;
    try testing.expectEqualStrings("aaa", s);
}

// ── WCS: CFITSIO TAN image, Astropy reference points (within 1e-6 deg) ─────────────────────

test "golden: WCS TAN pixel→world matches Astropy refpoints (≤1e-6 deg)" {
    try requireCorpus();
    const alloc = testing.allocator;
    var f = try fits.openFile(alloc, golden_dir ++ "/wcs/wcs_tan.fits", .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(1);
    var w = try fits.Wcs.fromHeader(alloc, &hdu.header, ' ');
    defer w.deinit(alloc);
    const cel = try fits.Celestial.fromWcs(&w);

    const csv = try readFileAlloc(alloc, golden_dir ++ "/wcs/wcs_refpoints.csv");
    defer alloc.free(csv);
    var lines = std.mem.tokenizeScalar(u8, csv, '\n');
    _ = lines.next(); // skip the "px,py,ra_deg,dec_deg" header
    var rows: usize = 0;
    while (lines.next()) |line_in| {
        const line = std.mem.trimEnd(u8, line_in, "\r");
        if (line.len == 0) continue;
        var cols = std.mem.tokenizeScalar(u8, line, ',');
        const px = try std.fmt.parseFloat(f64, cols.next().?);
        const py = try std.fmt.parseFloat(f64, cols.next().?);
        const ra = try std.fmt.parseFloat(f64, cols.next().?);
        const dec = try std.fmt.parseFloat(f64, cols.next().?);
        const world = try cel.pixelToWorld(.{ px, py });
        try testing.expect(@abs(world[0] - ra) < 1e-6);
        try testing.expect(@abs(world[1] - dec) < 1e-6);
        rows += 1;
    }
    try testing.expect(rows >= 5); // every authored reference point was checked
}

// ── X-CONF: validate.verify yields zero err on a clean file, the expected finding on a ─────
//    deliberately malformed one (BLANK on a float-BITPIX image, per conformance/expected.json).

test "golden: X-CONF valid image has zero err findings" {
    try requireCorpus();
    const alloc = testing.allocator;
    var f = try fits.openFile(alloc, golden_dir ++ "/conformance/valid/image.fits", .read_only, .{});
    defer f.deinit();
    var findings = try fits.validate.verify(alloc, &f);
    defer fits.validate.deinitFindings(alloc, &findings);
    for (findings.items) |fd| try testing.expect(fd.severity != .err);
}

test "golden: X-CONF malformed BLANK-on-float is flagged (hdu 1, err, BLANK)" {
    try requireCorpus();
    const alloc = testing.allocator;
    var f = try fits.openFile(alloc, golden_dir ++ "/conformance/malformed/blank_on_float.fits", .read_only, .{});
    defer f.deinit();
    var findings = try fits.validate.verify(alloc, &f);
    defer fits.validate.deinitFindings(alloc, &findings);
    var found = false;
    for (findings.items) |fd| {
        if (fd.severity == .err and fd.hdu == 1 and fd.kw != null and std.mem.eql(u8, fd.kw.?, "BLANK")) {
            found = true;
        }
    }
    try testing.expect(found);
}
