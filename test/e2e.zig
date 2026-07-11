//! In-house comprehensive end-to-end harness (testprog.c-equivalent), Deliverable 1.
//!
//! Builds maximal multi-HDU FITS files through the *public* API into in-memory devices,
//! flushes, reopens read-only, and asserts the full feature matrix round-trips. Ends with a
//! committed byte-snapshot digest as a regression tripwire. Pure-Zig and hermetic: no external
//! toolchain and no network, so it rides `zig build test` on every CI cell (including the
//! s390x big-endian QEMU cell) and runs alone via `zig build e2e`.
//!
//! This mirrors the role CFITSIO's `testprog.c` plays for the reference implementation: one
//! broad program that exercises the whole library at once, rather than many isolated checks.
//! Tests are split into focused blocks so a failure localizes, plus one "maximal file" block
//! and the deterministic snapshot tripwire.
//!
//! Everything flows through `const fits = @import("zigfitsio")` — the single public module
//! surface (`src/root.zig`); no internal module is imported.
const std = @import("std");
const fits = @import("zigfitsio");

const testing = std.testing;
const Allocator = std.mem.Allocator;

/// The tile-codec enum (`Codec`) is reached through its `CompressSpec.codec` field, since the
/// public surface exports `CompressSpec`/`writeCompressed` but not the bare `Codec` name.
const Codec = @FieldType(fits.CompressSpec, "codec");

// ── shared header builders (public-API mirrors of the per-module test helpers) ───────────

/// The eight mandatory table-structure cards shared by ASCII and binary tables.
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

/// Format an indexed keyword (`TFORM3`, `TBCOL2`, …) into `buf`.
fn kw(buf: []u8, comptime prefix: []const u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "{d}", .{n}) catch unreachable;
}

/// Append a commentary card (`COMMENT`/`HISTORY`) with free text via the raw-card path.
fn appendCommentary(h: *fits.Header, alloc: Allocator, comptime keyword: []const u8, text: []const u8) !void {
    comptime std.debug.assert(keyword.len <= 8);
    var raw: [80]u8 = @splat(' ');
    @memcpy(raw[0..keyword.len], keyword);
    const n = @min(text.len, 80 - 8);
    @memcpy(raw[8..][0..n], text[0..n]);
    try h.appendRaw(alloc, &raw);
}

/// Whether `h` carries a commentary card named `keyword` whose free text contains `text`.
fn headerHasCommentary(h: *const fits.Header, keyword: []const u8, text: []const u8) bool {
    var i: usize = 0;
    while (i < h.count()) : (i += 1) {
        const c = h.at(i);
        if (c.kind == .commentary and c.name.eqlText(keyword)) {
            if (std.mem.indexOf(u8, c.commentaryText(), text) != null) return true;
        }
    }
    return false;
}

// ── ASCII table showcase: every FORTRAN format Aw/Iw/Fw.d/Ew.d/Dw.d in one table ─────────
//
// Layout: A8 [1,9) | I6 [9,15) | F8.2 [15,23) | E15.7 [23,38) | D23.15 [38,61). NAXIS1 = 60.

const ascii_labels = [_][]const u8{ "alpha", "beta", "gamma" };
const ascii_count = [_]?i64{ 10, -20, 30 }; // Iw
const ascii_valf = [_]?f64{ 1.25, 2.5, -3.75 }; // Fw.d (≤2 decimals ⇒ exact)
const ascii_vale = [_]?f64{ 1.25, -2.5, 100.0 }; // Ew.d
const ascii_vald = [_]?f64{ 0.5, -0.25, 8.0 }; // Dw.d (powers of two ⇒ exact)

fn asciiShowcaseHeader(alloc: Allocator) !fits.Header {
    var h = fits.Header.initEmpty();
    errdefer h.deinit(alloc); // disarmed on normal return, before appendHdu takes ownership
    try appendTableSpine(&h, alloc, "TABLE", 60, 3, 0, 5);
    var b: [16]u8 = undefined;
    const cols = [_]struct { tbcol: i64, tform: []const u8, ttype: []const u8 }{
        .{ .tbcol = 1, .tform = "A8", .ttype = "LABEL" },
        .{ .tbcol = 9, .tform = "I6", .ttype = "COUNT" },
        .{ .tbcol = 15, .tform = "F8.2", .ttype = "VALF" },
        .{ .tbcol = 23, .tform = "E15.7", .ttype = "VALE" },
        .{ .tbcol = 38, .tform = "D23.15", .ttype = "VALD" },
    };
    inline for (cols, 0..) |c, i| {
        try h.appendValue(alloc, kw(&b, "TBCOL", i + 1), .{ .int = c.tbcol }, null);
        try h.appendValue(alloc, kw(&b, "TFORM", i + 1), .{ .string = c.tform }, null);
        try h.appendValue(alloc, kw(&b, "TTYPE", i + 1), .{ .string = c.ttype }, null);
    }
    try h.ensureEnd(alloc);
    return h;
}

fn appendAsciiShowcase(f: *fits.Fits, alloc: Allocator) !*fits.Hdu {
    const hdu = try f.appendHdu(try asciiShowcaseHeader(alloc));
    var t = try fits.AsciiTable.of(f, hdu);
    defer t.deinit(alloc);
    for (ascii_labels, 0..) |s, i| try t.writeCellStr(.{ .index = 0 }, i, s);
    try t.writeColumn(i64, .{ .index = 1 }, 0, &ascii_count);
    try t.writeColumn(f64, .{ .index = 2 }, 0, &ascii_valf);
    try t.writeColumn(f64, .{ .index = 3 }, 0, &ascii_vale);
    try t.writeColumn(f64, .{ .index = 4 }, 0, &ascii_vald);
    return hdu;
}

// ── simple binary table: 1I/1J/1E/8A (used by the snapshot + read-only failure path) ─────

const simple_bt_i16 = [_]i16{ 1, 2, 3 };
const simple_bt_i32 = [_]i32{ 10, 20, 30 };
const simple_bt_f32 = [_]f32{ 1.5, 2.5, 3.5 };
const simple_bt_str = "alpha   beta    gamma   ".*; // 3 rows × 8A (space-padded), 24 bytes

fn simpleBinTableHeader(alloc: Allocator) !fits.Header {
    var h = fits.Header.initEmpty();
    errdefer h.deinit(alloc);
    try appendTableSpine(&h, alloc, "BINTABLE", 18, 3, 0, 4); // 2+4+4+8 = 18
    var b: [16]u8 = undefined;
    const cols = [_]struct { tform: []const u8, ttype: []const u8 }{
        .{ .tform = "1I", .ttype = "I16" },
        .{ .tform = "1J", .ttype = "I32" },
        .{ .tform = "1E", .ttype = "F32" },
        .{ .tform = "8A", .ttype = "NAME" },
    };
    inline for (cols, 0..) |c, i| {
        try h.appendValue(alloc, kw(&b, "TFORM", i + 1), .{ .string = c.tform }, null);
        try h.appendValue(alloc, kw(&b, "TTYPE", i + 1), .{ .string = c.ttype }, null);
    }
    try h.ensureEnd(alloc);
    return h;
}

fn appendSimpleBinTable(f: *fits.Fits, alloc: Allocator) !*fits.Hdu {
    const hdu = try f.appendHdu(try simpleBinTableHeader(alloc));
    var t = try fits.BinTable.of(f, hdu);
    defer t.deinit(alloc);
    try t.writeColumn(i16, .{ .index = 0 }, 0, &simple_bt_i16, .{});
    try t.writeColumn(i32, .{ .index = 1 }, 0, &simple_bt_i32, .{});
    try t.writeColumn(f32, .{ .index = 2 }, 0, &simple_bt_f32, .{});
    try t.writeColumn(u8, .{ .name = "NAME" }, 0, &simple_bt_str, .{});
    return hdu;
}

// ── "monster" binary table: every TFORM code + TDIM + P/Q VLA columns ─────────────────────
//
// 14 columns / 3 rows. NAXIS1 = 1+1+1+2+4+8+4+8+8+16+8+16+8+16 = 101 bytes/row.
//   0:1L  1:8X  2:1B  3:1I  4:1J  5:1K  6:1E  7:1D  8:1C  9:1M  10:8A  11:4J(TDIM)  12:1PJ  13:1QJ

const monster_logic = [_]bool{ true, false, true };
const monster_bits = blk: {
    var b: [24]bool = undefined; // 8 bits/row × 3 rows
    for (&b, 0..) |*x, i| x.* = (i % 3 == 0);
    break :blk b;
};
const monster_u8 = [_]u8{ 1, 2, 3 };
const monster_i16 = [_]i16{ -100, 0, 100 };
const monster_i32 = [_]i32{ -100000, 0, 100000 };
const monster_i64 = [_]i64{ -(1 << 40), 0, 1 << 40 };
const monster_f32 = [_]f32{ 1.5, -2.5, 3.5 };
const monster_f64 = [_]f64{ 1.25, -2.25, 3.25 };
const monster_c64 = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 }; // 3 rows × (re, im)
const monster_c128 = [_]f64{ 10.0, 20.0, 30.0, 40.0, 50.0, 60.0 };
const monster_str = "alpha   beta    gamma   ".*; // 8A × 3 rows
const monster_grid = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }; // 4J, TDIM=(2,2)

// P (1PJ) and Q (1QJ) variable-length cells (element type J ⇒ 4 bytes each).
const vp_row0 = [_]i32{ 10, 20, 30 };
const vp_row1 = [_]i32{40};
const vp_row2 = [_]i32{ 50, 60 };
const vq_row0 = [_]i32{7};
const vq_row1 = [_]i32{ 8, 9 };
// PCOUNT = total heap bytes = (3+1+2 + 1+2) elements × 4 bytes = 36.
const monster_pcount: u64 = (vp_row0.len + vp_row1.len + vp_row2.len + vq_row0.len + vq_row1.len) * 4;

fn monsterBinTableHeader(alloc: Allocator) !fits.Header {
    var h = fits.Header.initEmpty();
    errdefer h.deinit(alloc);
    try appendTableSpine(&h, alloc, "BINTABLE", 101, 3, monster_pcount, 14);
    var b: [16]u8 = undefined;
    const cols = [_]struct { tform: []const u8, ttype: []const u8 }{
        .{ .tform = "1L", .ttype = "LOGIC" },
        .{ .tform = "8X", .ttype = "BITS" },
        .{ .tform = "1B", .ttype = "UINT8" },
        .{ .tform = "1I", .ttype = "INT16" },
        .{ .tform = "1J", .ttype = "INT32" },
        .{ .tform = "1K", .ttype = "INT64" },
        .{ .tform = "1E", .ttype = "FLT32" },
        .{ .tform = "1D", .ttype = "FLT64" },
        .{ .tform = "1C", .ttype = "CPLX64" },
        .{ .tform = "1M", .ttype = "CPLX128" },
        .{ .tform = "8A", .ttype = "STR" },
        .{ .tform = "4J", .ttype = "GRID" },
        .{ .tform = "1PJ", .ttype = "VLAP" },
        .{ .tform = "1QJ", .ttype = "VLAQ" },
    };
    inline for (cols, 0..) |c, i| {
        try h.appendValue(alloc, kw(&b, "TFORM", i + 1), .{ .string = c.tform }, null);
        try h.appendValue(alloc, kw(&b, "TTYPE", i + 1), .{ .string = c.ttype }, null);
    }
    try h.appendValue(alloc, "TDIM12", .{ .string = "(2,2)" }, null); // multidim 4J column
    try h.ensureEnd(alloc);
    return h;
}

fn appendMonsterBinTable(f: *fits.Fits, alloc: Allocator) !*fits.Hdu {
    const hdu = try f.appendHdu(try monsterBinTableHeader(alloc));
    var t = try fits.BinTable.of(f, hdu);
    defer t.deinit(alloc);
    try t.writeColumn(bool, .{ .index = 0 }, 0, &monster_logic, .{});
    try t.writeColumn(bool, .{ .index = 1 }, 0, &monster_bits, .{});
    try t.writeColumn(u8, .{ .index = 2 }, 0, &monster_u8, .{});
    try t.writeColumn(i16, .{ .index = 3 }, 0, &monster_i16, .{});
    try t.writeColumn(i32, .{ .index = 4 }, 0, &monster_i32, .{});
    try t.writeColumn(i64, .{ .index = 5 }, 0, &monster_i64, .{});
    try t.writeColumn(f32, .{ .index = 6 }, 0, &monster_f32, .{});
    try t.writeColumn(f64, .{ .index = 7 }, 0, &monster_f64, .{});
    try t.writeColumn(f32, .{ .index = 8 }, 0, &monster_c64, .{}); // C: paired f32 slots
    try t.writeColumn(f64, .{ .index = 9 }, 0, &monster_c128, .{}); // M: paired f64 slots
    try t.writeColumn(u8, .{ .index = 10 }, 0, &monster_str, .{});
    try t.writeColumn(i32, .{ .index = 11 }, 0, &monster_grid, .{});

    var mgr = try fits.heap.HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);
    try fits.heap.writeVlaCell(alloc, &t, &mgr, .{ .index = 12 }, 0, i32, &vp_row0);
    try fits.heap.writeVlaCell(alloc, &t, &mgr, .{ .index = 12 }, 1, i32, &vp_row1);
    try fits.heap.writeVlaCell(alloc, &t, &mgr, .{ .index = 12 }, 2, i32, &vp_row2);
    try fits.heap.writeVlaCell(alloc, &t, &mgr, .{ .index = 13 }, 0, i32, &vq_row0);
    try fits.heap.writeVlaCell(alloc, &t, &mgr, .{ .index = 13 }, 1, i32, &vq_row1);
    try fits.heap.writeVlaCell(alloc, &t, &mgr, .{ .index = 13 }, 2, i32, &[_]i32{}); // empty Q cell
    return hdu;
}

// ── showcase assembly: a broad clean multi-HDU file (image + ext + ascii + bintable + 2 ──
//    compressed images), used by the validate and maximal blocks.

fn appendShowcaseHdus(f: *fits.Fits, alloc: Allocator) !void {
    // HDU1: primary image (i16, 2-D).
    {
        const prim = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } });
        var v = try fits.ImageView.of(f, prim);
        var px: [12]i16 = undefined;
        for (&px, 0..) |*p, i| p.* = @intCast(@as(i64, @intCast(i)) * 5 - 13);
        try v.writeAll(i16, &px, .{});
    }
    // HDU2: image extension (f32, 2-D).
    {
        const ext = try f.appendImageHdu(.{ .bitpix = -32, .axes = &.{ 3, 2 } });
        var v = try fits.ImageView.of(f, ext);
        var px: [6]f32 = undefined;
        for (&px, 0..) |*p, i| p.* = @as(f32, @floatFromInt(i)) * 0.5 - 1.0;
        try v.writeAll(f32, &px, .{});
    }
    // HDU3: ASCII table; HDU4: binary table exercising every TFORM + VLA.
    _ = try appendAsciiShowcase(f, alloc);
    _ = try appendMonsterBinTable(f, alloc);
    // HDU5: GZIP_1 tile-compressed image; HDU6: RICE_1 tile-compressed image.
    {
        var src: [12]i32 = undefined;
        for (&src, 0..) |*p, i| p.* = @intCast(i);
        _ = try fits.writeCompressed(i32, f, .{ .bitpix = 32, .axes = &.{ 4, 3 }, .tile = &.{ 4, 3 }, .codec = .gzip_1 }, &src);
    }
    {
        var src: [12]i16 = undefined;
        for (&src, 0..) |*p, i| p.* = @intCast(@as(i64, @intCast(i)) * 2);
        _ = try fits.writeCompressed(i16, f, .{ .bitpix = 16, .axes = &.{ 4, 3 }, .tile = &.{ 4, 3 }, .codec = .rice_1 }, &src);
    }
}

// ── a hand-built TAN WCS, serialized through the public `Wcs.writeTo` ─────────────────────

fn makeTanWcs(alloc: Allocator) !fits.Wcs {
    var w = fits.Wcs{ .alt = ' ', .axes = 2 };
    w.ctype = try alloc.alloc([]u8, 2);
    w.ctype[0] = try alloc.dupe(u8, "RA---TAN");
    w.ctype[1] = try alloc.dupe(u8, "DEC--TAN");
    w.cunit = try alloc.alloc([]u8, 2);
    w.cunit[0] = try alloc.dupe(u8, "");
    w.cunit[1] = try alloc.dupe(u8, "");
    w.crpix = try alloc.dupe(f64, &[_]f64{ 256.0, 256.0 });
    w.crval = try alloc.dupe(f64, &[_]f64{ 150.0, 2.5 });
    w.cdelt = try alloc.dupe(f64, &[_]f64{ -0.000277, 0.000277 });
    w.crota = try alloc.dupe(f64, &[_]f64{ 0.0, 0.0 });
    return w; // transform stays `.none`; pv/ps empty; freed by `w.deinit`
}

// =========================================================================================
//   the harness
// =========================================================================================

test "e2e: images — every BITPIX (8/16/32/64/-32/-64) and NAXIS 0..3 round-trip" {
    const alloc = testing.allocator;

    // Every BITPIX, written from a common i64 source and read back through it (FR-IMG-1/9).
    inline for (.{ 8, 16, 32, 64, -32, -64 }) |bp| {
        var mem = fits.MemoryDevice.init(alloc);
        defer mem.deinit();
        {
            var f = try fits.create(alloc, mem.device(), .{});
            defer f.deinit();
            var img = try fits.ImageView.append(&f, .{ .bitpix = bp, .axes = &.{64} });
            var src: [64]i64 = undefined;
            for (&src, 0..) |*s, i| s.* = @intCast(i + 1);
            try img.writeAll(i64, &src, .{});
            try f.flush();
        }
        var f = try fits.open(alloc, mem.device(), .read_only, .{});
        defer f.deinit();
        const hdu = try f.select(1);
        try testing.expectEqual(@as(i64, bp), try hdu.header.getValue(i64, "BITPIX"));
        var v = try fits.ImageView.of(&f, hdu);
        var out: [64]i64 = undefined;
        try v.readAll(i64, &out, .{});
        var src: [64]i64 = undefined;
        for (&src, 0..) |*s, i| s.* = @intCast(i + 1);
        try testing.expectEqualSlices(i64, &src, &out);
    }

    // NAXIS 0 (empty primary), 1, 2, 3 in one file.
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        _ = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{} }); // NAXIS 0
        {
            var v = try fits.ImageView.append(&f, .{ .bitpix = 16, .axes = &.{5} });
            try v.writeAll(i16, &[_]i16{ 1, 2, 3, 4, 5 }, .{});
        }
        {
            var v = try fits.ImageView.append(&f, .{ .bitpix = 16, .axes = &.{ 3, 2 } });
            try v.writeAll(i16, &[_]i16{ 1, 2, 3, 4, 5, 6 }, .{});
        }
        {
            var v = try fits.ImageView.append(&f, .{ .bitpix = 16, .axes = &.{ 2, 2, 2 } });
            try v.writeAll(i16, &[_]i16{ 1, 2, 3, 4, 5, 6, 7, 8 }, .{});
        }
        try f.flush();
    }
    var f = try fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 4), try f.hduCount());
    try testing.expectEqual(@as(i64, 0), try (try f.select(1)).header.getValue(i64, "NAXIS"));
    {
        const h2 = try f.select(2);
        var v = try fits.ImageView.of(&f, h2);
        var out: [5]i16 = undefined;
        try v.readAll(i16, &out, .{});
        try testing.expectEqualSlices(i16, &[_]i16{ 1, 2, 3, 4, 5 }, &out);
    }
    {
        const h4 = try f.select(4);
        try testing.expectEqual(@as(i64, 3), try h4.header.getValue(i64, "NAXIS"));
        var v = try fits.ImageView.of(&f, h4);
        var out: [8]i16 = undefined;
        try v.readAll(i16, &out, .{});
        try testing.expectEqualSlices(i16, &[_]i16{ 1, 2, 3, 4, 5, 6, 7, 8 }, &out);
    }
}

test "e2e: image scaling, BLANK/NaN nulls, and section I/O" {
    const alloc = testing.allocator;

    // BSCALE/BZERO applied on read, inverted on write (FR-IMG-5/6).
    {
        var mem = fits.MemoryDevice.init(alloc);
        defer mem.deinit();
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        var img = try fits.ImageView.append(&f, .{ .bitpix = 16, .axes = &.{4} });
        const sc: fits.Scaling = .{ .bscale = 2.0, .bzero = 100.0 };
        const physical = [_]f64{ 100, 102, 200, 300 }; // stored = (p-100)/2
        try img.writeAll(f64, &physical, .{ .scaling = sc });
        var phys: [4]f64 = undefined;
        try img.readAll(f64, &phys, .{ .scaling = sc });
        try testing.expectEqualSlices(f64, &physical, &phys);
        var raw: [4]i16 = undefined;
        try img.readAll(i16, &raw, .{ .scaling = .{ .mode = .raw } });
        try testing.expectEqualSlices(i16, &[_]i16{ 0, 1, 50, 100 }, &raw);
    }

    // Integer BLANK null maps to the caller sentinel (FR-IMG-8).
    {
        var mem = fits.MemoryDevice.init(alloc);
        defer mem.deinit();
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        var img = try fits.ImageView.append(&f, .{ .bitpix = 16, .axes = &.{4} });
        const sc: fits.Scaling = .{ .blank = -32768 };
        const vals = [_]i32{ 1, -999, 2, 3 };
        try img.writeAll(i32, &vals, .{ .scaling = sc, .null_sentinel = -999 });
        var raw: [4]i16 = undefined;
        try img.readAll(i16, &raw, .{ .scaling = .{ .mode = .raw } });
        try testing.expectEqual(@as(i16, -32768), raw[1]);
        var out: [4]i32 = undefined;
        try img.readAll(i32, &out, .{ .scaling = sc, .null_sentinel = -999 });
        try testing.expectEqualSlices(i32, &vals, &out);
    }

    // Float NaN null maps to the caller sentinel.
    {
        var mem = fits.MemoryDevice.init(alloc);
        defer mem.deinit();
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        var img = try fits.ImageView.append(&f, .{ .bitpix = -32, .axes = &.{3} });
        const vals = [_]f32{ 1.5, -1.0, 3.5 };
        try img.writeAll(f32, &vals, .{ .null_sentinel = -1.0 });
        var raw: [3]f32 = undefined;
        try img.readAll(f32, &raw, .{ .scaling = .{ .mode = .raw } });
        try testing.expect(std.math.isNan(raw[1]));
        var out: [3]f32 = undefined;
        try img.readAll(f32, &out, .{ .null_sentinel = -1.0 });
        try testing.expectEqualSlices(f32, &vals, &out);
    }

    // Strided rectangular sub-region read and write (FR-IMG-7).
    {
        var mem = fits.MemoryDevice.init(alloc);
        defer mem.deinit();
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        var img = try fits.ImageView.append(&f, .{ .bitpix = 32, .axes = &.{ 6, 6 } });
        var pixels: [36]i32 = undefined;
        for (&pixels, 0..) |*p, i| p.* = @intCast(i);
        try img.writeAll(i32, &pixels, .{});
        var out: [6]i32 = undefined;
        try img.readSection(i32, &.{ 0, 1 }, &.{ 4, 3 }, &.{ 2, 2 }, &out, .{});
        try testing.expectEqualSlices(i32, &[_]i32{ 6, 8, 10, 18, 20, 22 }, &out);

        var img2 = try fits.ImageView.append(&f, .{ .bitpix = 32, .axes = &.{ 4, 3 } });
        var zeros: [12]i32 = @splat(0);
        try img2.writeAll(i32, &zeros, .{});
        var nines = [_]i32{ 9, 9, 9, 9 };
        try img2.writeSection(i32, &.{ 0, 0 }, &.{ 2, 2 }, &.{ 2, 2 }, &nines, .{});
        var full: [12]i32 = undefined;
        try img2.readAll(i32, &full, .{});
        try testing.expectEqual(@as(i32, 9), full[0]);
        try testing.expectEqual(@as(i32, 9), full[2]);
        try testing.expectEqual(@as(i32, 0), full[1]); // gap preserved
    }
}

test "e2e: ASCII table — Aw/Iw/Fw.d/Ew.d/Dw.d round-trip" {
    const alloc = testing.allocator;
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary
        _ = try appendAsciiShowcase(&f, alloc);
        try f.flush();
    }
    var f = try fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(2);
    try testing.expectEqual(fits.HduKind.ascii_table, hdu.kind);
    var t = try fits.AsciiTable.of(&f, hdu);
    defer t.deinit(alloc);
    try testing.expectEqual(@as(u16, 5), t.columnCount());
    try testing.expectEqual(@as(u64, 3), t.rowCount());

    var buf: [8]u8 = undefined;
    for (ascii_labels, 0..) |want, i| {
        const got = (try t.readCellStr(.{ .index = 0 }, i, &buf)).?;
        try testing.expectEqualStrings(want, got);
    }
    var oi: [3]?i64 = undefined;
    try t.readColumn(i64, .{ .name = "COUNT" }, 0, &oi);
    for (ascii_count, oi) |want, got| try testing.expectEqual(want.?, got.?);
    var of_: [3]?f64 = undefined;
    try t.readColumn(f64, .{ .name = "VALF" }, 0, &of_);
    for (ascii_valf, of_) |want, got| try testing.expectEqual(want.?, got.?);
    var oe: [3]?f64 = undefined;
    try t.readColumn(f64, .{ .name = "VALE" }, 0, &oe);
    for (ascii_vale, oe) |want, got| try testing.expectEqual(want.?, got.?);
    var od: [3]?f64 = undefined;
    try t.readColumn(f64, .{ .name = "VALD" }, 0, &od);
    for (ascii_vald, od) |want, got| try testing.expectEqual(want.?, got.?);
}

test "e2e: binary table — every TFORM code, TDIM, and P/Q VLA round-trip" {
    const alloc = testing.allocator;
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary
    const hdu = try appendMonsterBinTable(&f, alloc);

    var t = try fits.BinTable.of(&f, hdu);
    defer t.deinit(alloc);
    try testing.expectEqual(@as(u16, 14), t.columnCount());
    try testing.expectEqual(@as(u64, 3), t.rowCount());

    var logic: [3]bool = undefined;
    try t.readColumn(bool, .{ .name = "LOGIC" }, 0, &logic, .{});
    try testing.expectEqualSlices(bool, &monster_logic, &logic);
    var bits: [24]bool = undefined;
    try t.readColumn(bool, .{ .name = "BITS" }, 0, &bits, .{});
    try testing.expectEqualSlices(bool, &monster_bits, &bits);
    var u8o: [3]u8 = undefined;
    try t.readColumn(u8, .{ .name = "UINT8" }, 0, &u8o, .{});
    try testing.expectEqualSlices(u8, &monster_u8, &u8o);
    var i16o: [3]i16 = undefined;
    try t.readColumn(i16, .{ .name = "INT16" }, 0, &i16o, .{});
    try testing.expectEqualSlices(i16, &monster_i16, &i16o);
    var i32o: [3]i32 = undefined;
    try t.readColumn(i32, .{ .name = "INT32" }, 0, &i32o, .{});
    try testing.expectEqualSlices(i32, &monster_i32, &i32o);
    var i64o: [3]i64 = undefined;
    try t.readColumn(i64, .{ .name = "INT64" }, 0, &i64o, .{});
    try testing.expectEqualSlices(i64, &monster_i64, &i64o);
    var f32o: [3]f32 = undefined;
    try t.readColumn(f32, .{ .name = "FLT32" }, 0, &f32o, .{});
    try testing.expectEqualSlices(f32, &monster_f32, &f32o);
    var f64o: [3]f64 = undefined;
    try t.readColumn(f64, .{ .name = "FLT64" }, 0, &f64o, .{});
    try testing.expectEqualSlices(f64, &monster_f64, &f64o);
    var c64: [6]f32 = undefined;
    try t.readColumn(f32, .{ .name = "CPLX64" }, 0, &c64, .{});
    try testing.expectEqualSlices(f32, &monster_c64, &c64);
    var c128: [6]f64 = undefined;
    try t.readColumn(f64, .{ .name = "CPLX128" }, 0, &c128, .{});
    try testing.expectEqualSlices(f64, &monster_c128, &c128);
    var str: [24]u8 = undefined;
    try t.readColumn(u8, .{ .name = "STR" }, 0, &str, .{});
    try testing.expectEqualSlices(u8, &monster_str, &str);
    var grid: [12]i32 = undefined;
    try t.readColumn(i32, .{ .name = "GRID" }, 0, &grid, .{});
    try testing.expectEqualSlices(i32, &monster_grid, &grid);
    try testing.expectEqualSlices(u64, &.{ 2, 2 }, t.columns[11].tdim.?); // TDIM parsed

    // P (1PJ) variable-length cells.
    {
        const r0 = try fits.heap.readVlaCell(alloc, &t, .{ .name = "VLAP" }, 0, i32);
        defer alloc.free(r0);
        const r1 = try fits.heap.readVlaCell(alloc, &t, .{ .name = "VLAP" }, 1, i32);
        defer alloc.free(r1);
        const r2 = try fits.heap.readVlaCell(alloc, &t, .{ .name = "VLAP" }, 2, i32);
        defer alloc.free(r2);
        try testing.expectEqualSlices(i32, &vp_row0, r0);
        try testing.expectEqualSlices(i32, &vp_row1, r1);
        try testing.expectEqualSlices(i32, &vp_row2, r2);
    }
    // Q (1QJ) variable-length cells (incl. an empty cell).
    {
        const q0 = try fits.heap.readVlaCell(alloc, &t, .{ .name = "VLAQ" }, 0, i32);
        defer alloc.free(q0);
        const q1 = try fits.heap.readVlaCell(alloc, &t, .{ .name = "VLAQ" }, 1, i32);
        defer alloc.free(q1);
        const q2 = try fits.heap.readVlaCell(alloc, &t, .{ .name = "VLAQ" }, 2, i32);
        defer alloc.free(q2);
        try testing.expectEqualSlices(i32, &vq_row0, q0);
        try testing.expectEqualSlices(i32, &vq_row1, q1);
        try testing.expectEqual(@as(usize, 0), q2.len);
    }
}

test "e2e: tiled compression — GZIP_1/GZIP_2/RICE_1/PLIO_1/HCOMPRESS_1 round-trip" {
    const alloc = testing.allocator;
    // GZIP works on any BITPIX; RICE/PLIO/HCOMPRESS are integer-only (8/16/32-bit) here.
    try roundTripCompressed(i32, alloc, 32, &.{ 4, 3 }, &.{ 4, 3 }, .gzip_1, &[_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 });
    try roundTripCompressed(i16, alloc, 16, &.{ 4, 2 }, &.{ 4, 1 }, .gzip_2, &[_]i16{ 100, -200, 300, -400, 500, -600, 700, -800 });
    try roundTripCompressed(i16, alloc, 16, &.{ 4, 3 }, &.{ 4, 3 }, .rice_1, &[_]i16{ 7, 9, 11, 13, 100, 99, 98, 97, -5, -4, -3, -2 });
    try roundTripCompressed(i32, alloc, 32, &.{ 4, 3 }, &.{ 4, 3 }, .plio_1, &[_]i32{ 0, 0, 5, 5, 5, 0, 3, 0, 0, 7, 7, 0 }); // non-negative mask
    try roundTripCompressed(i32, alloc, 32, &.{ 4, 3 }, &.{ 4, 3 }, .hcompress_1, &[_]i32{ 1, 2, 3, 4, 10, 11, 12, 13, -7, -6, -5, -4 });
}

fn roundTripCompressed(
    comptime T: type,
    alloc: Allocator,
    bitpix: i64,
    axes: []const u64,
    tile: []const u64,
    codec: Codec,
    src: []const T,
) !void {
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary
    const hdu = try fits.writeCompressed(T, &f, .{ .bitpix = bitpix, .axes = axes, .tile = tile, .codec = codec }, src);
    var ti = try fits.TiledImage.of(&f, hdu);
    defer ti.deinit(alloc);
    const out = try alloc.alloc(T, src.len);
    defer alloc.free(out);
    try ti.readAll(T, out);
    try testing.expectEqualSlices(T, src, out);
}

test "e2e: headers — CONTINUE long string, HIERARCH, COMMENT/HISTORY round-trip" {
    const alloc = testing.allocator;
    const long = "The quick brown fox jumps over the lazy dog, then keeps right on running " ++
        "across a very wide field for a good long while under a clear 'blue' sky, " ++
        "it's said."; // > 68 chars; quotes exercise ''-escaping across the CONTINUE split
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        const hdr = blk: {
            var h = fits.Header.initEmpty();
            errdefer h.deinit(alloc);
            try h.appendValue(alloc, "SIMPLE", .{ .logical = true }, null);
            try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
            try h.appendValue(alloc, "NAXIS", .{ .int = 0 }, null);
            try h.appendLongString(alloc, "LONGSTR", long, "a long comment"); // CONTINUE
            try h.append(alloc, try fits.hierarch.build("ESO DET CHIP1 GAIN", .{ .float = 2.1 }, "e-/ADU"));
            try appendCommentary(&h, alloc, "COMMENT", "a friendly comment line");
            try appendCommentary(&h, alloc, "HISTORY", "processed by zigfitsio e2e");
            try h.ensureEnd(alloc);
            break :blk h;
        };
        _ = try f.appendHdu(hdr);
        try f.flush();
    }
    var f = try fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(1);

    const got = try hdu.header.getLongString(alloc, "LONGSTR");
    defer alloc.free(got);
    try testing.expectEqualStrings(long, got);

    const hv = try hdu.header.getHierarch(alloc, "ESO DET CHIP1 GAIN");
    defer hv.deinit(alloc);
    try testing.expectEqual(@as(f64, 2.1), hv.float);

    try testing.expect(headerHasCommentary(&hdu.header, "COMMENT", "a friendly comment line"));
    try testing.expect(headerHasCommentary(&hdu.header, "HISTORY", "processed by zigfitsio e2e"));
}

test "e2e: checksums — checksum_on_close writes verifiable DATASUM/CHECKSUM on flush" {
    const alloc = testing.allocator;
    // The real end-to-end path: open with `checksum_on_close = true`, build and fill an HDU, then
    // `flush`. The registered hook reserves the integrity cards at append time and computes them at
    // flush; reopening and `checksum.verify` must report both `.match` — with no manual
    // `checksum.update`. (This is the path the checksum_on_close hook fix restored, FR-SUM-3.)
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = try fits.create(alloc, mem.device(), .{ .checksum_on_close = true });
        defer f.deinit();
        var v = try fits.ImageView.append(&f, .{ .bitpix = 8, .axes = &.{100} });
        var data: [100]u8 = undefined;
        for (&data, 0..) |*d, i| d.* = @truncate(i * 13 + 5);
        try v.writeAll(u8, &data, .{});
        try f.flush(); // the hook fires here: DATASUM/CHECKSUM computed and written in place
    }
    var f = try fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(1);
    const r = try fits.checksum.verify(&f, hdu);
    try testing.expectEqual(fits.checksum.Verify.match, r.data);
    try testing.expectEqual(fits.checksum.Verify.match, r.sum);
}

test "e2e: WCS — TAN pixel→world→pixel round-trip" {
    const alloc = testing.allocator;
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        const hdr = blk: {
            var h = fits.Header.initEmpty();
            errdefer h.deinit(alloc);
            try h.appendValue(alloc, "SIMPLE", .{ .logical = true }, null);
            try h.appendValue(alloc, "BITPIX", .{ .int = 16 }, null);
            try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
            try h.appendValue(alloc, "NAXIS1", .{ .int = 512 }, null);
            try h.appendValue(alloc, "NAXIS2", .{ .int = 512 }, null);
            var w = try makeTanWcs(alloc);
            defer w.deinit(alloc);
            try w.writeTo(alloc, &h); // serialize the TAN WCS keyword set
            try h.ensureEnd(alloc);
            break :blk h;
        };
        _ = try f.appendHdu(hdr);
        try f.flush();
    }
    var f = try fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(1);
    var w2 = try fits.Wcs.fromHeader(alloc, &hdu.header, ' ');
    defer w2.deinit(alloc);
    const cel = try fits.Celestial.fromWcs(&w2);

    // The reference pixel maps to CRVAL.
    const ref = try cel.pixelToWorld(.{ 256.0, 256.0 });
    try testing.expect(@abs(ref[0] - 150.0) < 1e-9);
    try testing.expect(@abs(ref[1] - 2.5) < 1e-9);

    // The reference pixel round-trips essentially exactly (tight 1e-9).
    {
        const world = try cel.pixelToWorld(.{ 256.0, 256.0 });
        const back = try cel.worldToPixel(world);
        try testing.expect(@abs(back[0] - 256.0) < 1e-9);
        try testing.expect(@abs(back[1] - 256.0) < 1e-9);
    }
    // Off-center pixels round-trip pixel → world → pixel within the projection's tolerance.
    const pts = [_][2]f64{ .{ 100, 100 }, .{ 300, 400 }, .{ 511, 511 } };
    for (pts) |pt| {
        const world = try cel.pixelToWorld(pt);
        const back = try cel.worldToPixel(world);
        try testing.expect(@abs(back[0] - pt[0]) < 1e-6);
        try testing.expect(@abs(back[1] - pt[1]) < 1e-6);
    }
}

test "e2e: validate — clean multi-HDU file has zero error findings" {
    const alloc = testing.allocator;
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        try appendShowcaseHdus(&f, alloc);
        try f.flush();
    }
    var f = try fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    var findings = try fits.validate.verify(alloc, &f);
    defer fits.validate.deinitFindings(alloc, &findings);
    var errs: usize = 0;
    for (findings.items) |fd| {
        if (fd.severity == .err) errs += 1;
    }
    try testing.expectEqual(@as(usize, 0), errs);
}

test "e2e: iterator — walk a binary-table column" {
    const alloc = testing.allocator;
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary
    const hdr = blk: {
        var h = fits.Header.initEmpty();
        errdefer h.deinit(alloc);
        try appendTableSpine(&h, alloc, "BINTABLE", 4, 5, 0, 1);
        try h.appendValue(alloc, "TFORM1", .{ .string = "1J" }, null);
        try h.appendValue(alloc, "TTYPE1", .{ .string = "VAL" }, null);
        try h.ensureEnd(alloc);
        break :blk h;
    };
    const hdu = try f.appendHdu(hdr);
    var t = try fits.BinTable.of(&f, hdu);
    defer t.deinit(alloc);
    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 2, 4, 6, 8, 10 }, .{});

    const Cols = struct { val: []i32 };
    const Acc = struct {
        var sum: i64 = 0;
        var rows: usize = 0;
        fn work(n: usize, cols: *Cols) error{}!void {
            rows += n;
            for (cols.val[0..n]) |v| sum += v;
        }
    };
    Acc.sum = 0;
    Acc.rows = 0;
    var it = fits.Iterator(Cols, error{}){ .bindings = &.{
        .{ .ref = .{ .index = 0 }, .role = .in, .field = "val" },
    } };
    try it.run(&t, 2, Acc.work); // chunks of 2, 2, 1
    try testing.expectEqual(@as(usize, 5), Acc.rows);
    try testing.expectEqual(@as(i64, 30), Acc.sum); // 2+4+6+8+10
}

test "e2e: group table — create, add members, reopen, resolve" {
    const alloc = testing.allocator;
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // HDU1 primary
        const h2 = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } }); // HDU2
        const h3 = try f.appendImageHdu(.{ .bitpix = 32, .axes = &.{2} }); // HDU3
        var grp = try fits.GroupTable.create(&f, "MYGROUP"); // HDU4
        defer grp.deinit(alloc);
        _ = try grp.addMember(h2);
        _ = try grp.addMember(h3);
        try f.flush();
    }
    var f = try fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 4), try f.hduCount());
    const ghdu = try f.select(4);
    var grp = try fits.GroupTable.of(&f, ghdu);
    defer grp.deinit(alloc);
    try testing.expectEqual(@as(u64, 2), grp.memberCount());

    const m0 = (try grp.resolveMember(0)).?;
    const m1 = (try grp.resolveMember(1)).?;
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, m0.axes);
    try testing.expectEqualSlices(u64, &.{2}, m1.axes);

    const name = try grp.groupName(alloc);
    defer if (name) |s| alloc.free(s);
    try testing.expectEqualStrings("MYGROUP", name.?);
}

test "e2e: template — buildFromTemplate keywords" {
    const alloc = testing.allocator;
    const tmpl =
        \\# a primary image followed by a binary table
        \\SIMPLE  =                    T / conforms to FITS standard
        \\BITPIX  =                    8
        \\NAXIS   =                    2
        \\NAXIS1  =                  100
        \\NAXIS2  =                  200
        \\END
        \\
        \\XTENSION= 'BINTABLE'          / binary table extension
        \\BITPIX  =                    8
        \\NAXIS   =                    2
        \\NAXIS1  =                    8
        \\NAXIS2  =                    5
        \\PCOUNT  =                    0
        \\GCOUNT  =                    1
        \\TFIELDS =                    2
        \\TTYPE1  = 'COUNTS'
        \\TFORM1  = 'J'
        \\TTYPE2  = 'FLUX'
        \\TFORM2  = 'E'
        \\END
    ;
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = try fits.buildFromTemplate(alloc, mem.device(), tmpl, .{});
        defer f.deinit();
        try testing.expectEqual(@as(usize, 2), try f.hduCount());
        try f.flush();
    }
    var f = try fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const t1 = try f.select(1);
    try testing.expectEqual(fits.HduKind.primary, t1.kind);
    try testing.expectEqual(@as(i64, 8), try t1.header.getValue(i64, "BITPIX"));
    try testing.expectEqualSlices(u64, &.{ 100, 200 }, t1.axes);

    const t2 = try f.select(2);
    try testing.expectEqual(fits.HduKind.binary_table, t2.kind);
    const ttype1 = try t2.header.getString(alloc, "TTYPE1");
    defer alloc.free(ttype1);
    try testing.expectEqualStrings("COUNTS", ttype1);
    const tform2 = try t2.header.getString(alloc, "TFORM2");
    defer alloc.free(tform2);
    try testing.expectEqualStrings("E", tform2);
}

test "e2e: failure paths — read-only write and malformed header" {
    const alloc = testing.allocator;

    // (a) A write through a `.read_only` handle is a typed `error.NotWritable`.
    {
        var mem = fits.MemoryDevice.init(alloc);
        defer mem.deinit();
        {
            var f = try fits.create(alloc, mem.device(), .{});
            defer f.deinit();
            _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary
            _ = try appendSimpleBinTable(&f, alloc);
            try f.flush();
        }
        var f = try fits.open(alloc, mem.device(), .read_only, .{});
        defer f.deinit();
        const hdu = try f.select(2);
        var t = try fits.BinTable.of(&f, hdu);
        defer t.deinit(alloc);
        try testing.expectError(error.NotWritable, t.writeColumn(i32, .{ .index = 1 }, 0, &[_]i32{ 0, 0, 0 }, .{}));
    }

    // (b) An obviously-malformed header surfaces a typed error from `open`, never a panic.
    {
        var mem = fits.MemoryDevice.init(alloc);
        defer mem.deinit();
        var junk: [2880]u8 = undefined;
        @memset(&junk, 0); // not a SIMPLE card; not printable ASCII
        try mem.device().writeAll(&junk, 0);
        if (fits.open(alloc, mem.device(), .read_only, .{})) |opened| {
            var o = opened;
            o.deinit();
            try testing.expect(false); // open should have rejected the garbage
        } else |_| {
            // reached only via a typed error return — the behaviour we require
        }
    }
}

test "e2e: maximal multi-HDU file round-trips end-to-end" {
    const alloc = testing.allocator;
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = try fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        try appendShowcaseHdus(&f, alloc); // image + ext + ascii + monster bintable + 2 compressed
        try f.flush();
    }
    var f = try fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 6), try f.hduCount());

    // HDU1 primary image.
    {
        const hdu = try f.select(1);
        var v = try fits.ImageView.of(&f, hdu);
        var out: [12]i16 = undefined;
        try v.readAll(i16, &out, .{});
        try testing.expectEqual(@as(i16, -13), out[0]);
        try testing.expectEqual(@as(i16, 42), out[11]);
    }
    // HDU3 ASCII table.
    {
        const hdu = try f.select(3);
        var t = try fits.AsciiTable.of(&f, hdu);
        defer t.deinit(alloc);
        var oi: [3]?i64 = undefined;
        try t.readColumn(i64, .{ .name = "COUNT" }, 0, &oi);
        for (ascii_count, oi) |want, got| try testing.expectEqual(want.?, got.?);
    }
    // HDU4 monster binary table: a fixed column + a VLA cell.
    {
        const hdu = try f.select(4);
        var t = try fits.BinTable.of(&f, hdu);
        defer t.deinit(alloc);
        try testing.expectEqual(@as(u16, 14), t.columnCount());
        var i32o: [3]i32 = undefined;
        try t.readColumn(i32, .{ .name = "INT32" }, 0, &i32o, .{});
        try testing.expectEqualSlices(i32, &monster_i32, &i32o);
        const r = try fits.heap.readVlaCell(alloc, &t, .{ .name = "VLAP" }, 0, i32);
        defer alloc.free(r);
        try testing.expectEqualSlices(i32, &vp_row0, r);
    }
    // HDU5 GZIP_1-compressed image decodes transparently through `ImageView`.
    {
        const hdu = try f.select(5);
        var v = try fits.ImageView.of(&f, hdu);
        try testing.expect(v.isCompressed());
        var out: [12]i32 = undefined;
        try v.readAll(i32, &out, .{});
        for (out, 0..) |g, i| try testing.expectEqual(@as(i32, @intCast(i)), g);
    }

    // The whole assembled file is structurally clean.
    var findings = try fits.validate.verify(alloc, &f);
    defer fits.validate.deinitFindings(alloc, &findings);
    for (findings.items) |fd| try testing.expect(fd.severity != .err);
}

// ── deterministic byte-snapshot tripwire (regression) ────────────────────────────────────
//
// Builds a FIXED multi-HDU file (primary image + ASCII table + binary table, fixed values) and
// asserts a SHA-256 over the device bytes. The writers inject no wall-clock data (no auto `DATE`
// card; `src/` writes none), so the bytes are deterministic. This test must FAIL on any drift —
// it never self-heals. Re-derive the constant only by reading the failure digest, pasting it,
// and confirming it is identical across two runs.
const SNAPSHOT_SHA256 = "57f724a786c6d0a682180d8e92bddd2bcc282865347c377138f82b5fd6a8bfc9";

const snapshot_pixels = [_]i16{ -3, -1, 1, 3, 5, 7 };

fn buildSnapshotFile(alloc: Allocator, mem: *fits.MemoryDevice) !void {
    var f = try fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    var img = try fits.ImageView.append(&f, .{ .bitpix = 16, .axes = &.{ 3, 2 } });
    try img.writeAll(i16, &snapshot_pixels, .{});
    _ = try appendAsciiShowcase(&f, alloc);
    _ = try appendSimpleBinTable(&f, alloc);
    try f.flush();
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

test "e2e: deterministic byte snapshot (regression tripwire)" {
    const alloc = testing.allocator;
    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    try buildSnapshotFile(alloc, &mem);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(mem.bytes(), &digest, .{});
    const hex = hexLower(digest);
    try testing.expectEqualStrings(SNAPSHOT_SHA256, &hex);
}
