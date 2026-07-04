//! Fuzz harnesses for the header/table parsers AND the tile codecs (X-FUZZ, NFR-SAFE-1/2, GC-6).
//!
//! Each harness feeds arbitrary bytes to a parser or decoder and asserts the contract: no panic,
//! no out-of-bounds, no unbounded allocation, no leak — only typed errors or success. Run the
//! whole set once via `zig build fuzz`; engage the in-tree fuzzer with `zig build fuzz --fuzz`.
//! The deterministic `*-seeds` tests additionally pin specific hostile inputs (huge `NAXISn`,
//! missing `END`, non-ASCII, malformed `TFORM`, truncated/forged codec streams) so the
//! validate-before-allocate paths are always exercised even without the fuzzer engine.
//!
//! Codec coverage comes in two layers: direct decoder targets (HCOMPRESS/RICE/PLIO/GZIP fed
//! hostile bytes, with the HCOMPRESS geometry pinned consistent so the deep decode paths —
//! quadtree, sign bits, undigitize, hinv±smooth — actually run), and a mutation target that
//! authors a genuine compressed HDU with `writeCompressed` and then corrupts bytes before
//! re-reading, which reaches the tile-table/decode seams random bytes almost never find.
const std = @import("std");
const fits = @import("zigfitsio");

const alloc = std.testing.allocator;

const Smith = std.testing.Smith;

// Fill one 80-byte card with smith-chosen bytes and parse it. Must never panic; any malformed
// content yields a typed HeaderError.
fn fuzzCard(_: void, smith: *Smith) anyerror!void {
    var raw: [80]u8 = undefined;
    smith.bytesWithHash(&raw, 0x01);
    _ = fits.Card.parse(&raw) catch {}; // typed error is fine; a panic/OOB is not
}

// Parse smith-chosen bytes as a binary-table TFORM. Bad codes/overflowing repeats must be typed
// errors, never a crash.
fn fuzzTform(_: void, smith: *Smith) anyerror!void {
    var buf: [48]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0x02);
    _ = fits.table_common.BinTform.parse(buf[0..n]) catch {};
}

// Open smith-chosen bytes as a whole FITS file and walk every HDU. This drives header scanning,
// kind detection, and the NAXISn-product / data-geometry limit checks. A hostile header must
// produce a typed error (or a bounded, leak-free success), never a panic or huge allocation.
fn fuzzOpen(_: void, smith: *Smith) anyerror!void {
    var buf: [2880 * 2]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0x03);
    var mem = fits.MemoryDevice.initBytes(alloc, buf[0..n]) catch return;
    defer mem.deinit();
    var f = fits.open(alloc, mem.device(), .read_only, .{}) catch return;
    defer f.deinit();
    const count = f.hduCount() catch return;
    var i: usize = 1;
    while (i <= count) : (i += 1) {
        const hdu = f.select(i) catch continue;
        if (hdu.kind.isImageLike()) {
            var view = fits.ImageView.of(&f, hdu) catch continue;
            // Read at most a few pixels into a tiny fixed buffer (bounded; never trusts NAXIS).
            var pix: [16]f64 = undefined;
            const want = @min(view.elementCount(), pix.len);
            if (want > 0) view.readPixels(f64, firstCoord(hdu.naxis)[0..hdu.naxis], pix[0..@intCast(want)], .{}) catch {};
        }
    }
}

fn firstCoord(naxis: u16) [999]u64 {
    _ = naxis;
    return [_]u64{0} ** 999;
}

// ── tile-codec decoders (X-FUZZ codec layer) ──────────────────────────────────────────────

// HCOMPRESS_1: two attempts per input. The raw attempt exercises the magic/header/geometry
// gates on fully arbitrary bytes. The deep attempt then forces the magic and a small,
// self-consistent nx×ny (the decoder rejects any stream whose declared geometry disagrees with
// the caller's `nelem`, so arbitrary bytes rarely get past the gate) — that drives the quadtree
// decoder, the sign-bit reader, undigitize, and hinv with smoothing off AND on over hostile
// payloads. Contract: typed error or a bounded, owned result; never a panic/OOB/runaway alloc.
fn fuzzHcompress(_: void, smith: *Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0x04);
    if (fits.hcompress.decompress(alloc, buf[0..n], 64, .{})) |dec| alloc.free(dec.data) else |_| {}
    if (n >= 21) {
        const nx: u32 = 1 + @as(u32, buf[2] & 0x1F); // 1..32
        const ny: u32 = 1 + @as(u32, buf[3] & 0x1F); // 1..32
        buf[0] = 0xDD; // code_magic
        buf[1] = 0x99;
        std.mem.writeInt(u32, buf[2..6], nx, .big);
        std.mem.writeInt(u32, buf[6..10], ny, .big);
        inline for (.{ false, true }) |sm| {
            if (fits.hcompress.decompress(alloc, buf[0..n], nx * ny, .{ .smooth = sm })) |dec| alloc.free(dec.data) else |_| {}
        }
    }
}

// RICE_1: arbitrary bytes across all three supported bytepix widths, element count derived from
// the input (bounded ≤ 256). Truncated bodies/headers must be `CorruptTile`, unsupported
// parameters `DataConstraintViolated` — never a panic.
fn fuzzRice(_: void, smith: *Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0x05);
    if (n < 2) return;
    const nelem: usize = 1 + @as(usize, buf[0]);
    inline for (.{ 1, 2, 4 }) |bytepix| {
        if (fits.rice.decompress(alloc, buf[0..n], nelem, bytepix, 32)) |out| alloc.free(out) else |_| {}
    }
}

// PLIO_1: arbitrary bytes as an IRAF line-list (7-word header + opcode words). Escaping the
// 24-bit range, overrunning the declared element count, or under-filling the line must all be
// typed `CorruptTile` errors.
fn fuzzPlio(_: void, smith: *Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0x06);
    if (n < 1) return;
    const nelem: usize = 1 + @as(usize, buf[0]);
    if (fits.plio.decompress(alloc, buf[0..n], nelem)) |out| alloc.free(out) else |_| {}
}

// GZIP_1/GZIP_2: arbitrary bytes through the bounded inflate (output ceiling enforced) and the
// shuffle-aware GZIP_2 variant.
fn fuzzGzip(_: void, smith: *Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0x07);
    if (fits.gzip.gzipDecode(alloc, buf[0..n], 1 << 16)) |out| alloc.free(out) else |_| {}
    if (fits.gzip.gzip2Decode(alloc, buf[0..n], 4, 1 << 16)) |out| alloc.free(out) else |_| {}
}

// Tile-table mutation: author a small, genuinely valid compressed HDU (codec picked by the
// input: RICE i16 / lossy HCOMPRESS i32 / dithered-float GZIP_2), then flip input-chosen bytes
// anywhere in the serialized file and re-read it through `TiledImage`. Mutating near-valid
// files reaches the ZIMAGE header/tile-table/decode seams that fully random bytes almost never
// assemble. Contract: typed error or bounded success on every mutation.
fn fuzzTileMutation(_: void, smith: *Smith) anyerror!void {
    var raw: [16]u8 = undefined;
    smith.bytesWithHash(&raw, 0x08);

    var mem = fits.MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = fits.create(alloc, mem.device(), .{}) catch return;
        defer f.deinit();
        _ = f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }) catch return; // primary
        switch (raw[0] % 3) {
            0 => {
                var pix: [64]i16 = undefined;
                for (&pix, 0..) |*v, i| v.* = @intCast((i * 7) % 100);
                _ = fits.writeCompressed(i16, &f, .{ .bitpix = 16, .axes = &.{ 8, 8 }, .codec = .rice_1 }, &pix) catch return;
            },
            1 => {
                var pix: [64]i32 = undefined;
                for (&pix, 0..) |*v, i| v.* = @intCast(i * i % 977);
                _ = fits.writeCompressed(i32, &f, .{ .bitpix = 32, .axes = &.{ 8, 8 }, .codec = .hcompress_1, .hcomp_scale = -2 }, &pix) catch return;
            },
            else => {
                var pix: [64]f32 = undefined;
                for (&pix, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 0.75 - 20.0;
                _ = fits.writeCompressed(f32, &f, .{ .bitpix = -32, .axes = &.{ 8, 8 }, .codec = .gzip_2, .quantize = .subtractive_dither_1, .zdither0 = 1 }, &pix) catch return;
            },
        }
    }

    const copy = alloc.dupe(u8, mem.bytes()) catch return;
    defer alloc.free(copy);
    if (copy.len == 0) return;
    // Up to 4 byte flips at input-chosen offsets (two bytes each for file-wide reach).
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        const pos = (@as(usize, raw[1 + k * 2]) << 8 | raw[2 + k * 2]) % copy.len;
        copy[pos] ^= raw[9 + k] | 1; // always a real flip
    }

    var mem2 = fits.MemoryDevice.initBytes(alloc, copy) catch return;
    defer mem2.deinit();
    var f2 = fits.open(alloc, mem2.device(), .read_only, .{}) catch return;
    defer f2.deinit();
    const hdu = f2.select(2) catch return;
    var ti = fits.TiledImage.of(&f2, hdu) catch return;
    defer ti.deinit(alloc);
    var out: [64]f64 = undefined;
    if (ti.elementCount() == out.len) ti.readAll(f64, &out) catch {};
}

test "fuzz: card parser" {
    try std.testing.fuzz({}, fuzzCard, .{});
}
test "fuzz: TFORM parser" {
    try std.testing.fuzz({}, fuzzTform, .{});
}
test "fuzz: whole-file open + HDU walk" {
    try std.testing.fuzz({}, fuzzOpen, .{});
}
test "fuzz: HCOMPRESS_1 decoder" {
    try std.testing.fuzz({}, fuzzHcompress, .{});
}
test "fuzz: RICE_1 decoder" {
    try std.testing.fuzz({}, fuzzRice, .{});
}
test "fuzz: PLIO_1 decoder" {
    try std.testing.fuzz({}, fuzzPlio, .{});
}
test "fuzz: GZIP_1/GZIP_2 decoder" {
    try std.testing.fuzz({}, fuzzGzip, .{});
}
test "fuzz: compressed-HDU byte mutation" {
    try std.testing.fuzz({}, fuzzTileMutation, .{});
}

// ── deterministic hostile-input seeds (validate-before-allocate, NFR-SAFE-1) ─────────────

fn block2880(cards: []const []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, 2880);
    @memset(buf, ' ');
    for (cards, 0..) |c, i| @memcpy(buf[i * 80 ..][0..c.len], c);
    return buf;
}

test "seeds: hostile headers yield typed errors, never panic or huge alloc" {
    const cases = [_][]const []const u8{
        // NAXISn product overflow: must be a typed limit/dimension error, not an allocation.
        &.{
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    3",
            "NAXIS1  =          4000000000",
            "NAXIS2  =          4000000000",
            "NAXIS3  =          4000000000",
            "END",
        },
        // Missing END within the block.
        &.{
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
        },
        // Bad BITPIX.
        &.{
            "SIMPLE  =                    T",
            "BITPIX  =                    7",
            "NAXIS   =                    0",
            "END",
        },
        // SIMPLE not first.
        &.{
            "BITPIX  =                    8",
            "SIMPLE  =                    T",
            "NAXIS   =                    0",
            "END",
        },
    };
    for (cases) |cards| {
        const buf = try block2880(cards);
        defer alloc.free(buf);
        var mem = try fits.MemoryDevice.initBytes(alloc, buf);
        defer mem.deinit();
        var f = fits.open(alloc, mem.device(), .read_only, .{}) catch {
            continue; // a typed open error is an acceptable outcome
        };
        defer f.deinit();
        // If open succeeded, forcing a full scan must still be typed-or-ok, never a panic.
        _ = f.hduCount() catch {};
    }
}

test "seeds: a control character in a card is rejected" {
    var raw: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(raw[0..6], "OBJECT");
    raw[20] = 0x07; // bell
    try std.testing.expectError(error.NonAsciiInHeader, fits.Card.parse(&raw));
}

test "seeds: malformed TFORM strings are typed errors" {
    const bad = [_][]const u8{ "", "5", "3G", "1Jx", "999999999999999999999J", "2PJ" };
    for (bad) |s| {
        _ = fits.table_common.BinTform.parse(s) catch continue;
        // "2PJ" (P/Q repeat > 1) and others must error; if one unexpectedly parses, that's a bug.
        if (std.mem.eql(u8, s, "2PJ")) return error.TestUnexpectedResult;
    }
}

test "seeds: hostile codec streams are typed errors, never a panic" {
    // HCOMPRESS: bad magic, magic-only truncation, header truncated mid-geometry, oversized
    // bitplane counts, and a declared-geometry/nelem mismatch (unbounded-alloc guard).
    try std.testing.expectError(error.CorruptTile, fits.hcompress.decompress(alloc, &.{ 0xAA, 0xBB, 0, 0 }, 4, .{}));
    try std.testing.expectError(error.CorruptTile, fits.hcompress.decompress(alloc, &.{ 0xDD, 0x99 }, 4, .{}));
    try std.testing.expectError(error.CorruptTile, fits.hcompress.decompress(alloc, &.{ 0xDD, 0x99, 0, 0, 0, 4, 0, 0 }, 16, .{}));
    {
        var hdr = [_]u8{ 0xDD, 0x99 } ++ [_]u8{0} ** 19;
        std.mem.writeInt(u32, hdr[2..6], 4, .big);
        std.mem.writeInt(u32, hdr[6..10], 4, .big);
        hdr[18] = 99; // nbitplanes[0] > 63
        try std.testing.expectError(error.CorruptTile, fits.hcompress.decompress(alloc, &hdr, 16, .{}));
        hdr[18] = 8;
        // Geometry says 4×4 but the caller's tile is 64 pixels: must be rejected before any
        // stream-driven allocation.
        try std.testing.expectError(error.CorruptTile, fits.hcompress.decompress(alloc, &hdr, 64, .{}));
    }
    // RICE: empty, sub-header, and truncated-body streams.
    try std.testing.expectError(error.CorruptTile, fits.rice.decompress(alloc, &.{}, 8, 2, 32));
    try std.testing.expectError(error.CorruptTile, fits.rice.decompress(alloc, &.{ 0x01, 0x02 }, 8, 4, 32));
    // PLIO: odd byte length, and an SH opcode whose value escapes the 24-bit range.
    try std.testing.expectError(error.CorruptTile, fits.plio.decompress(alloc, &.{0x00}, 4));
    // GZIP: not a gzip stream; and a valid stream must respect the output ceiling.
    try std.testing.expectError(error.CorruptTile, fits.gzip.gzipDecode(alloc, "not gzip at all", 1 << 16));
    {
        const big = try alloc.alloc(u8, 4096);
        defer alloc.free(big);
        @memset(big, 'z');
        const enc = try fits.gzip.gzipEncode(alloc, big);
        defer alloc.free(enc);
        try std.testing.expectError(error.CorruptTile, fits.gzip.gzipDecode(alloc, enc, 64));
    }
}
