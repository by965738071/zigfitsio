//! HCOMPRESS_1 tile codec for 2-D images (`FR-CMP-6`, §17.2; FITS 4.0 §10.4.4, Table 39).
//!
//! HCOMPRESS is the CFITSIO `hcompress`/`hdecompress` algorithm: a three-stage pipeline over a
//! single 2-D tile of `i32` pixels.
//!
//!   1. **H-transform** (`htrans`/`hinv`) — a multi-resolution 2×2 "butterfly" wavelet. Each
//!      level replaces every 2×2 block `(a,b,c,d)` by four coefficients
//!         `h0 = a+b+c+d`   (DC / sum),
//!         `hx = -a-b+c+d`  (vertical detail),
//!         `hy = -a+b-c+d`  (horizontal detail),
//!         `hc = a-b-c+d`   (diagonal detail),
//!      then *shuffles* the DC coefficients into the top-left quadrant and recurses on that
//!      quadrant. Odd axis lengths are handled with 2-element (edge) and 1-element (corner)
//!      butterflies, so the transform pads/handles non-power-of-two and odd dimensions exactly.
//!      This implementation keeps **full `i64` precision** (no lossy bit-shifting), so `hinv` is
//!      an exact integer inverse — the inverse butterfly divides by 4 (or 2 at edges), which is
//!      always exact because the synthesis sums are constructed to be divisible.
//!
//!   2. **Quantization** (SCALE) — for `scale > 1`, AC coefficients are divided by `scale`
//!      (lossy); `scale <= 1` (and the acceptance target `scale == 0`) is **lossless**. The DC
//!      term (the running sum of all pixels) is always carried losslessly in the stream header.
//!
//!   3. **Quadtree bit-plane coder** (`encode`/`decode`) — coefficients are split into a sign
//!      bit and an unsigned magnitude; magnitudes are coded MSB-first, one bit plane at a time,
//!      each plane compressed by a recursive quadtree: one bit per region says "any coefficient
//!      in this region has this bit set"; a `0` prunes the whole region, a `1` recurses down to
//!      the 1×1 leaf (where the region bit *is* the coefficient bit). Sign bits for the non-zero
//!      coefficients follow, in row-major order. `encode` and `decode` walk identical geometry,
//!      so the coder is exactly symmetric.
//!
//! Stream layout (self-describing; `decompress` reads it back): a 25-byte header
//!   `magic "ZHC1" (4) | nx u32 | ny u32 | scale i32 | sumall i64 | nbitplanes u8`
//! (all multi-byte fields big-endian via `endian.zig`) followed by the MSB-first bit stream
//! (bit planes then sign bits). Only 2-D tiles are supported: a `data.len != nx*ny` request (or
//! a zero axis) is `error.DataConstraintViolated`; a malformed/truncated stream is
//! `error.CorruptTile`.
//!
//! X-FIXTURES (not yet covered here): byte-exact parity against a committed CFITSIO
//! `HCOMPRESS_1` tile, and quantitative lossy-mode (`scale > 1`) tolerance checks. The stream
//! format and quadtree coding here are self-consistent (round-trip exact) but are **not** the
//! CFITSIO on-disk byte format; the `tiled.zig` integrator must keep that in mind until the
//! parity fixtures land.
const std = @import("std");

const Allocator = std.mem.Allocator;

// Big-endian header field I/O. `endian.zig` (the project's wire-access module) is the canonical
// home for this, but it lives outside this file's module root, so the standalone `zig test`
// self-verify cannot import it; `std.mem.{read,write}Int(..., .big)` is exactly what that module
// wraps, so we use it directly here (pure std, identical bytes on the wire).
fn writeBE(comptime T: type, v: T, out: *[@sizeOf(T)]u8) void {
    std.mem.writeInt(T, out, v, .big);
}
fn readBE(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return std.mem.readInt(T, bytes, .big);
}

/// Errors from `compress`/`decompress`. `DataConstraintViolated` is a caller/shape error (e.g.
/// a non-2-D request); `CorruptTile` is a malformed/truncated/out-of-range compressed stream.
pub const HcompressError = error{ DataConstraintViolated, CorruptTile, OutOfMemory };

/// The 4-byte stream magic identifying this codec's container.
const magic = "ZHC1";

/// Fixed header size in bytes: `magic(4) + nx(4) + ny(4) + scale(4) + sumall(8) + nbitplanes(1)`.
const header_len = 4 + 4 + 4 + 4 + 8 + 1;

/// A decoded tile: the recovered `nx*ny` pixels (caller owns `data`) plus the geometry read
/// back from the stream header.
pub const Decoded = struct {
    /// Recovered pixels, row-major with the first axis (`nx` rows) varying slowest.
    data: []i32,
    /// Number of rows (first axis).
    nx: usize,
    /// Number of columns (second axis).
    ny: usize,
};

// ── public API ───────────────────────────────────────────────────────────────────────────────

/// Compress an `nx × ny` 2-D `i32` tile (row-major, `data[r*ny + c]`) with HCOMPRESS_1.
///
/// `scale` controls quantization: `0` (or `1`) is lossless; `scale > 1` divides AC coefficients
/// (lossy). `data.len` must equal `nx*ny` and both axes must be non-zero, else
/// `error.DataConstraintViolated` (HCOMPRESS is 2-D only). Caller owns the returned stream.
pub fn compress(alloc: Allocator, data: []const i32, nx: usize, ny: usize, scale: i32) HcompressError![]u8 {
    if (nx == 0 or ny == 0) return error.DataConstraintViolated;
    const n = std.math.mul(usize, nx, ny) catch return error.DataConstraintViolated;
    if (data.len != n) return error.DataConstraintViolated;
    if (scale < 0) return error.DataConstraintViolated;

    // Working array in full i64 precision (the transform grows coefficients).
    const a = try alloc.alloc(i64, n);
    defer alloc.free(a);
    for (data, 0..) |v, i| a[i] = v;

    try htrans(alloc, a, nx, ny);

    // The DC coefficient (running sum of all pixels) carries losslessly in the header; zero it
    // so it does not blow up the bit-plane count of the coded array.
    const sumall = a[0];
    a[0] = 0;

    // Lossy quantization (SCALE). scale <= 1 is a no-op (lossless).
    if (scale > 1) {
        const s: i64 = scale;
        for (a) |*v| v.* = divRound(v.*, s);
    }

    // Magnitudes (for the bit-plane coder) and the maximum, which sets the plane count.
    const mag = try alloc.alloc(u64, n);
    defer alloc.free(mag);
    var maxmag: u64 = 0;
    for (a, 0..) |v, i| {
        const m: u64 = @intCast(@abs(v));
        mag[i] = m;
        if (m > maxmag) maxmag = m;
    }
    const nbitplanes: u8 = @intCast(@as(usize, 64) - @as(usize, @clz(maxmag)));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // Header.
    var hdr: [header_len]u8 = undefined;
    @memcpy(hdr[0..4], magic);
    writeBE(u32, @intCast(nx), hdr[4..][0..4]);
    writeBE(u32, @intCast(ny), hdr[8..][0..4]);
    writeBE(i32, scale, hdr[12..][0..4]);
    writeBE(i64, sumall, hdr[16..][0..8]);
    hdr[24] = nbitplanes;
    try out.appendSlice(alloc, &hdr);

    // Bit stream: each magnitude bit plane top-down, then a sign bit per non-zero coefficient.
    var bw = BitWriter{ .alloc = alloc, .list = &out };
    var bp: usize = nbitplanes;
    while (bp > 0) {
        bp -= 1;
        try encodeRegion(&bw, mag, ny, 0, 0, nx, ny, @intCast(bp));
    }
    for (a, 0..) |v, i| {
        if (mag[i] != 0) try bw.putBit(if (v < 0) 1 else 0);
    }
    try bw.flush();

    return out.toOwnedSlice(alloc);
}

/// Decompress an HCOMPRESS_1 stream produced by `compress`. Reads `nx`, `ny`, `scale`, `sumall`
/// and the plane count from the header, inverts the quadtree coder and the H-transform, and
/// returns the recovered pixels. A bad magic, truncated body, or out-of-range value is
/// `error.CorruptTile`. Caller owns `Decoded.data`.
pub fn decompress(alloc: Allocator, src: []const u8) HcompressError!Decoded {
    if (src.len < header_len) return error.CorruptTile;
    if (!std.mem.eql(u8, src[0..4], magic)) return error.CorruptTile;

    const nx: usize = readBE(u32, src[4..][0..4]);
    const ny: usize = readBE(u32, src[8..][0..4]);
    const scale: i32 = readBE(i32, src[12..][0..4]);
    const sumall: i64 = readBE(i64, src[16..][0..8]);
    const nbitplanes: u8 = src[24];

    if (nx == 0 or ny == 0) return error.CorruptTile;
    if (scale < 0) return error.CorruptTile;
    if (nbitplanes > 64) return error.CorruptTile;
    const n = std.math.mul(usize, nx, ny) catch return error.CorruptTile;

    const mag = try alloc.alloc(u64, n);
    defer alloc.free(mag);
    @memset(mag, 0);

    var br = BitReader{ .data = src[header_len..] };

    // Rebuild magnitudes plane by plane (top-down), then a signed coefficient array.
    var bp: usize = nbitplanes;
    while (bp > 0) {
        bp -= 1;
        try decodeRegion(&br, mag, ny, 0, 0, nx, ny, @intCast(bp));
    }

    const a = try alloc.alloc(i64, n);
    defer alloc.free(a);
    for (mag, 0..) |m, i| {
        if (m == 0) {
            a[i] = 0;
        } else {
            const mi: i64 = @intCast(m);
            const sign = try br.getBit();
            a[i] = if (sign == 1) -mi else mi;
        }
    }

    // Undo quantization, restore the DC term, invert the transform.
    if (scale > 1) {
        const s: i64 = scale;
        for (a) |*v| v.* = std.math.mul(i64, v.*, s) catch return error.CorruptTile;
    }
    a[0] = sumall;
    try hinv(alloc, a, nx, ny);

    const out = try alloc.alloc(i32, n);
    errdefer alloc.free(out);
    for (a, 0..) |v, i| {
        out[i] = std.math.cast(i32, v) orelse return error.CorruptTile;
    }
    return .{ .data = out, .nx = nx, .ny = ny };
}

// ── H-transform ────────────────────────────────────────────────────────────────────────────

// Fill `nxs`/`nys` with the active sub-image size at each reduction level and return the level
// count `log2n = ceil(log2(max(nx,ny)))`. Level `k` operates on the top-left `nxs[k] × nys[k]`
// block; the next level's size is the ceil-halving of both axes.
fn computeLevels(nx: usize, ny: usize, nxs: []usize, nys: []usize) usize {
    const log2n = ceilLog2(@max(nx, ny));
    var cx = nx;
    var cy = ny;
    var k: usize = 0;
    while (k < log2n) : (k += 1) {
        nxs[k] = cx;
        nys[k] = cy;
        cx = (cx + 1) / 2;
        cy = (cy + 1) / 2;
    }
    return log2n;
}

// In-place forward H-transform of the `nx × ny` image stored in `a` (`a[r*ny + c]`). After it,
// `a[0]` holds the DC term (running sum) and the rest hold detail coefficients.
fn htrans(alloc: Allocator, a: []i64, nx: usize, ny: usize) Allocator.Error!void {
    var nxs: [65]usize = undefined;
    var nys: [65]usize = undefined;
    const log2n = computeLevels(nx, ny, &nxs, &nys);
    if (log2n == 0) return;

    const tmp = try alloc.alloc(i64, @max(nx, ny));
    defer alloc.free(tmp);

    var k: usize = 0;
    while (k < log2n) : (k += 1) {
        const nxt = nxs[k];
        const nyt = nys[k];
        butterfly(a, ny, nxt, nyt);
        // Group DC coefficients into the top-left quadrant: shuffle within each active row, then
        // within each active column.
        var r: usize = 0;
        while (r < nxt) : (r += 1) shuffleLine(a, r * ny, nyt, 1, tmp);
        var c: usize = 0;
        while (c < nyt) : (c += 1) shuffleLine(a, c, nxt, ny, tmp);
    }
}

// In-place inverse H-transform: the exact inverse of `htrans`. Walks levels coarse→fine,
// undoing the column shuffle, then the row shuffle, then the butterfly at each level.
fn hinv(alloc: Allocator, a: []i64, nx: usize, ny: usize) Allocator.Error!void {
    var nxs: [65]usize = undefined;
    var nys: [65]usize = undefined;
    const log2n = computeLevels(nx, ny, &nxs, &nys);
    if (log2n == 0) return;

    const tmp = try alloc.alloc(i64, @max(nx, ny));
    defer alloc.free(tmp);

    var k: usize = log2n;
    while (k > 0) {
        k -= 1;
        const nxt = nxs[k];
        const nyt = nys[k];
        var c: usize = 0;
        while (c < nyt) : (c += 1) unshuffleLine(a, c, nxt, ny, tmp);
        var r: usize = 0;
        while (r < nxt) : (r += 1) unshuffleLine(a, r * ny, nyt, 1, tmp);
        ibutterfly(a, ny, nxt, nyt);
    }
}

// One forward butterfly pass over the top-left `nxt × nyt` block (row stride `ny`). Interior
// 2×2 blocks use the 4-point butterfly; an odd trailing column/row uses a 2-element butterfly;
// the lone corner (both odd) is left unchanged.
fn butterfly(a: []i64, ny: usize, nxt: usize, nyt: usize) void {
    const oddx = nxt & 1;
    const oddy = nyt & 1;

    var i: usize = 0;
    while (i < nxt - oddx) : (i += 2) {
        const r0 = i * ny;
        const r1 = (i + 1) * ny;
        var j: usize = 0;
        while (j < nyt - oddy) : (j += 2) {
            const av = a[r0 + j];
            const bv = a[r0 + j + 1];
            const cv = a[r1 + j];
            const dv = a[r1 + j + 1];
            a[r0 + j] = av + bv + cv + dv; // h0 (DC)
            a[r0 + j + 1] = -av + bv - cv + dv; // hy (horizontal)
            a[r1 + j] = -av - bv + cv + dv; // hx (vertical)
            a[r1 + j + 1] = av - bv - cv + dv; // hc (diagonal)
        }
        if (oddy == 1) {
            const jj = nyt - 1;
            const av = a[r0 + jj];
            const cv = a[r1 + jj];
            a[r0 + jj] = av + cv; // h0
            a[r1 + jj] = cv - av; // hx
        }
    }
    if (oddx == 1) {
        const r0 = (nxt - 1) * ny;
        var j: usize = 0;
        while (j < nyt - oddy) : (j += 2) {
            const av = a[r0 + j];
            const bv = a[r0 + j + 1];
            a[r0 + j] = av + bv; // h0
            a[r0 + j + 1] = bv - av; // hy
        }
        // The corner element (both axes odd) is its own DC — left as-is.
    }
}

// Inverse of `butterfly`. The synthesis sums are divisible by 4 (interior) or 2 (edges), so the
// arithmetic right shifts are exact integer divisions.
fn ibutterfly(a: []i64, ny: usize, nxt: usize, nyt: usize) void {
    const oddx = nxt & 1;
    const oddy = nyt & 1;

    var i: usize = 0;
    while (i < nxt - oddx) : (i += 2) {
        const r0 = i * ny;
        const r1 = (i + 1) * ny;
        var j: usize = 0;
        while (j < nyt - oddy) : (j += 2) {
            const h0 = a[r0 + j];
            const hy = a[r0 + j + 1];
            const hx = a[r1 + j];
            const hc = a[r1 + j + 1];
            a[r0 + j] = (h0 - hx - hy + hc) >> 2; // a
            a[r0 + j + 1] = (h0 - hx + hy - hc) >> 2; // b
            a[r1 + j] = (h0 + hx - hy - hc) >> 2; // c
            a[r1 + j + 1] = (h0 + hx + hy + hc) >> 2; // d
        }
        if (oddy == 1) {
            const jj = nyt - 1;
            const h0 = a[r0 + jj];
            const hx = a[r1 + jj];
            a[r0 + jj] = (h0 - hx) >> 1; // a
            a[r1 + jj] = (h0 + hx) >> 1; // c
        }
    }
    if (oddx == 1) {
        const r0 = (nxt - 1) * ny;
        var j: usize = 0;
        while (j < nyt - oddy) : (j += 2) {
            const h0 = a[r0 + j];
            const hy = a[r0 + j + 1];
            a[r0 + j] = (h0 - hy) >> 1; // a
            a[r0 + j + 1] = (h0 + hy) >> 1; // b
        }
    }
}

// Shuffle `n` elements starting at `base` with stride `s` from interleaved even/odd order into
// "all evens, then all odds" order, using `tmp` as scratch. Its exact inverse is `unshuffleLine`.
fn shuffleLine(a: []i64, base: usize, n: usize, s: usize, tmp: []i64) void {
    var i: usize = 0;
    while (i < n) : (i += 1) tmp[i] = a[base + i * s];
    const ne = (n + 1) / 2;
    i = 0;
    while (i < ne) : (i += 1) a[base + i * s] = tmp[2 * i];
    const no = n / 2;
    i = 0;
    while (i < no) : (i += 1) a[base + (ne + i) * s] = tmp[2 * i + 1];
}

// Inverse of `shuffleLine`: regroup "all evens, then all odds" back into interleaved order.
fn unshuffleLine(a: []i64, base: usize, n: usize, s: usize, tmp: []i64) void {
    var i: usize = 0;
    while (i < n) : (i += 1) tmp[i] = a[base + i * s];
    const ne = (n + 1) / 2;
    i = 0;
    while (i < ne) : (i += 1) a[base + (2 * i) * s] = tmp[i];
    const no = n / 2;
    i = 0;
    while (i < no) : (i += 1) a[base + (2 * i + 1) * s] = tmp[ne + i];
}

// ── quadtree bit-plane coder ─────────────────────────────────────────────────────────────────

// Whether any magnitude in the [r0,r0+h) × [c0,c0+w) region has bit `bit` set.
fn anyBit(mag: []const u64, ny: usize, r0: usize, c0: usize, h: usize, w: usize, bit: u6) bool {
    var r: usize = r0;
    while (r < r0 + h) : (r += 1) {
        const base = r * ny;
        var c: usize = c0;
        while (c < c0 + w) : (c += 1) {
            if ((mag[base + c] >> bit) & 1 != 0) return true;
        }
    }
    return false;
}

// Encode bit plane `bit` of `mag` over the region, MSB-first quadtree: one bit "any set?" per
// node; a leaf node's bit *is* the coefficient bit.
fn encodeRegion(bw: *BitWriter, mag: []const u64, ny: usize, r0: usize, c0: usize, h: usize, w: usize, bit: u6) Allocator.Error!void {
    const any = anyBit(mag, ny, r0, c0, h, w, bit);
    try bw.putBit(if (any) 1 else 0);
    if (!any) return;
    if (h == 1 and w == 1) return; // the region bit was the leaf bit
    const h1 = (h + 1) / 2;
    const w1 = (w + 1) / 2;
    try encodeRegion(bw, mag, ny, r0, c0, h1, w1, bit);
    if (w > w1) try encodeRegion(bw, mag, ny, r0, c0 + w1, h1, w - w1, bit);
    if (h > h1) try encodeRegion(bw, mag, ny, r0 + h1, c0, h - h1, w1, bit);
    if (h > h1 and w > w1) try encodeRegion(bw, mag, ny, r0 + h1, c0 + w1, h - h1, w - w1, bit);
}

// Decode bit plane `bit` into `mag`, mirroring `encodeRegion` exactly (identical geometry).
fn decodeRegion(br: *BitReader, mag: []u64, ny: usize, r0: usize, c0: usize, h: usize, w: usize, bit: u6) error{CorruptTile}!void {
    const any = try br.getBit();
    if (any == 0) return;
    if (h == 1 and w == 1) {
        mag[r0 * ny + c0] |= (@as(u64, 1) << bit);
        return;
    }
    const h1 = (h + 1) / 2;
    const w1 = (w + 1) / 2;
    try decodeRegion(br, mag, ny, r0, c0, h1, w1, bit);
    if (w > w1) try decodeRegion(br, mag, ny, r0, c0 + w1, h1, w - w1, bit);
    if (h > h1) try decodeRegion(br, mag, ny, r0 + h1, c0, h - h1, w1, bit);
    if (h > h1 and w > w1) try decodeRegion(br, mag, ny, r0 + h1, c0 + w1, h - h1, w - w1, bit);
}

// ── bit I/O (MSB-first) ──────────────────────────────────────────────────────────────────────

const BitWriter = struct {
    alloc: Allocator,
    list: *std.ArrayList(u8),
    acc: u8 = 0,
    nbits: u4 = 0,

    fn putBit(self: *BitWriter, bit: u1) Allocator.Error!void {
        // `acc` only ever holds `nbits` (< 8) valid low bits, so the shift never overflows u8.
        self.acc = (self.acc << 1) | bit;
        self.nbits += 1;
        if (self.nbits == 8) {
            try self.list.append(self.alloc, self.acc);
            self.acc = 0;
            self.nbits = 0;
        }
    }

    fn flush(self: *BitWriter) Allocator.Error!void {
        if (self.nbits > 0) {
            self.acc <<= @intCast(8 - self.nbits);
            try self.list.append(self.alloc, self.acc);
            self.acc = 0;
            self.nbits = 0;
        }
    }
};

const BitReader = struct {
    data: []const u8,
    pos: usize = 0, // next bit index (MSB-first within each byte)

    fn getBit(self: *BitReader) error{CorruptTile}!u1 {
        const byte_i = self.pos >> 3;
        if (byte_i >= self.data.len) return error.CorruptTile;
        const bit_i: u3 = @intCast(self.pos & 7);
        self.pos += 1;
        return @intCast((self.data[byte_i] >> (7 - bit_i)) & 1);
    }
};

// ── small helpers ──────────────────────────────────────────────────────────────────────────

// ceil(log2(m)); 0 for m <= 1.
fn ceilLog2(m: usize) usize {
    if (m <= 1) return 0;
    return 64 - @as(usize, @clz(@as(u64, m - 1)));
}

// Round-to-nearest integer division by a positive `scale`, symmetric about zero.
fn divRound(v: i64, scale: i64) i64 {
    const half = @divTrunc(scale, 2);
    if (v >= 0) return @divTrunc(v + half, scale);
    return -@divTrunc(-v + half, scale);
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

// Round-trip helper: compress then decompress, asserting recovered geometry and returning the
// decoded pixels (caller frees).
fn roundTrip(alloc: Allocator, data: []const i32, nx: usize, ny: usize, scale: i32) ![]i32 {
    const enc = try compress(alloc, data, nx, ny, scale);
    defer alloc.free(enc);
    const dec = try decompress(alloc, enc);
    try testing.expectEqual(nx, dec.nx);
    try testing.expectEqual(ny, dec.ny);
    return dec.data;
}

fn expectLosslessRoundTrip(alloc: Allocator, data: []const i32, nx: usize, ny: usize) !void {
    const got = try roundTrip(alloc, data, nx, ny, 0);
    defer alloc.free(got);
    try testing.expectEqualSlices(i32, data, got);
}

test "htrans/hinv are exact inverses across shapes (incl. odd dims and edges)" {
    const alloc = testing.allocator;
    const shapes = [_][2]usize{
        .{ 1, 1 }, .{ 2, 2 }, .{ 2, 1 }, .{ 1, 7 }, .{ 3, 3 },
        .{ 5, 1 }, .{ 2, 3 }, .{ 8, 8 }, .{ 16, 16 }, .{ 17, 13 },
    };
    inline for (shapes) |sh| {
        const nx = sh[0];
        const ny = sh[1];
        const n = nx * ny;
        const a = try alloc.alloc(i64, n);
        defer alloc.free(a);
        const orig = try alloc.alloc(i64, n);
        defer alloc.free(orig);
        var seed: u64 = 0x9E3779B97F4A7C15 ^ (nx * 131 + ny);
        for (a, orig) |*v, *o| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            const x: i64 = @as(i32, @bitCast(@as(u32, @truncate(seed >> 32))));
            v.* = @rem(x, 100000);
            o.* = v.*;
        }
        try htrans(alloc, a, nx, ny);
        try hinv(alloc, a, nx, ny);
        try testing.expectEqualSlices(i64, orig, a);
    }
}

test "lossless round-trip: constant image" {
    const alloc = testing.allocator;
    const nx = 16;
    const ny = 16;
    var data: [nx * ny]i32 = undefined;
    @memset(&data, 1234);
    try expectLosslessRoundTrip(alloc, &data, nx, ny);
}

test "lossless round-trip: smooth ramp" {
    const alloc = testing.allocator;
    const nx = 16;
    const ny = 16;
    var data: [nx * ny]i32 = undefined;
    for (0..nx) |r| {
        for (0..ny) |c| data[r * ny + c] = @intCast(r * ny + c);
    }
    try expectLosslessRoundTrip(alloc, &data, nx, ny);
}

test "lossless round-trip: checkerboard (with negatives)" {
    const alloc = testing.allocator;
    const nx = 16;
    const ny = 16;
    var data: [nx * ny]i32 = undefined;
    for (0..nx) |r| {
        for (0..ny) |c| data[r * ny + c] = if ((r + c) % 2 == 0) @as(i32, 30000) else @as(i32, -30000);
    }
    try expectLosslessRoundTrip(alloc, &data, nx, ny);
}

test "lossless round-trip: random-ish data" {
    const alloc = testing.allocator;
    const nx = 24;
    const ny = 20;
    var data: [nx * ny]i32 = undefined;
    var seed: u64 = 0xDEADBEEFCAFEBABE;
    for (&data) |*v| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        v.* = @as(i32, @bitCast(@as(u32, @truncate(seed >> 31)))) >> 8; // moderate spread
    }
    try expectLosslessRoundTrip(alloc, &data, nx, ny);
}

test "lossless round-trip: non-power-of-two size 17x13" {
    const alloc = testing.allocator;
    const nx = 17;
    const ny = 13;
    var data: [nx * ny]i32 = undefined;
    var seed: u64 = 0x123456789ABCDEF0;
    for (&data) |*v| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        v.* = @rem(@as(i32, @bitCast(@as(u32, @truncate(seed >> 33)))), 5000);
    }
    try expectLosslessRoundTrip(alloc, &data, nx, ny);
}

test "lossless round-trip: 1x1 and 2x2 edges" {
    const alloc = testing.allocator;
    {
        const data = [_]i32{ -7 };
        try expectLosslessRoundTrip(alloc, &data, 1, 1);
    }
    {
        const data = [_]i32{ 5 };
        try expectLosslessRoundTrip(alloc, &data, 1, 1);
    }
    {
        const data = [_]i32{ 1, 2, 3, 4 };
        try expectLosslessRoundTrip(alloc, &data, 2, 2);
    }
    {
        const data = [_]i32{ -100, 0, 250, -3 };
        try expectLosslessRoundTrip(alloc, &data, 2, 2);
    }
}

test "decompress reports geometry from the stream header" {
    const alloc = testing.allocator;
    var data: [17 * 13]i32 = undefined;
    for (&data, 0..) |*v, i| v.* = @intCast(i);
    const enc = try compress(alloc, &data, 17, 13, 0);
    defer alloc.free(enc);
    try testing.expect(std.mem.eql(u8, enc[0..4], magic));
    const dec = try decompress(alloc, enc);
    defer alloc.free(dec.data);
    try testing.expectEqual(@as(usize, 17), dec.nx);
    try testing.expectEqual(@as(usize, 13), dec.ny);
}

test "non-2-D / bad-shape requests error typed" {
    const alloc = testing.allocator;
    const data = [_]i32{ 1, 2, 3, 4, 5, 6 };
    // data.len (6) != nx*ny (8)
    try testing.expectError(error.DataConstraintViolated, compress(alloc, &data, 4, 2, 0));
    // zero axis
    try testing.expectError(error.DataConstraintViolated, compress(alloc, &data, 0, 6, 0));
    try testing.expectError(error.DataConstraintViolated, compress(alloc, &data, 6, 0, 0));
    // negative scale
    try testing.expectError(error.DataConstraintViolated, compress(alloc, &data, 3, 2, -1));
}

test "corrupt streams error typed" {
    const alloc = testing.allocator;
    // Too short for a header.
    try testing.expectError(error.CorruptTile, decompress(alloc, "short"));
    // Right length but wrong magic.
    var buf: [header_len]u8 = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..4], "XXXX");
    try testing.expectError(error.CorruptTile, decompress(alloc, &buf));

    // Valid header but truncated bit stream (claim plenty of planes, supply no body bytes).
    var data: [8 * 8]i32 = undefined;
    var seed: u64 = 42;
    for (&data) |*v| {
        seed = seed *% 6364136223846793005 +% 1;
        v.* = @rem(@as(i32, @bitCast(@as(u32, @truncate(seed >> 32)))), 9999);
    }
    const enc = try compress(alloc, &data, 8, 8, 0);
    defer alloc.free(enc);
    // Cut the body off, keeping only the header: the quadtree decode must run out of bits.
    try testing.expectError(error.CorruptTile, decompress(alloc, enc[0..header_len]));
}

test "lossy (scale>1) round-trip stays within tolerance and is bounded" {
    const alloc = testing.allocator;
    const nx = 16;
    const ny = 16;
    var data: [nx * ny]i32 = undefined;
    for (0..nx) |r| {
        for (0..ny) |c| data[r * ny + c] = @intCast((r * 37 + c * 11) % 4096);
    }
    const scale: i32 = 4;
    const got = try roundTrip(alloc, &data, nx, ny, scale);
    defer alloc.free(got);
    // Quantizing H-transform coefficients by `scale` bounds the per-pixel error; just assert it
    // is finite and reasonably bounded (exact tolerance parity is an X-FIXTURES item).
    var maxerr: i64 = 0;
    for (data, got) |o, g| {
        const e: i64 = @intCast(@abs(@as(i64, o) - @as(i64, g)));
        if (e > maxerr) maxerr = e;
    }
    try testing.expect(maxerr <= 256);
}

test "empty/zero magnitudes: all-zero image round-trips and stays tiny" {
    const alloc = testing.allocator;
    const nx = 8;
    const ny = 8;
    var data: [nx * ny]i32 = undefined;
    @memset(&data, 0);
    const enc = try compress(alloc, &data, nx, ny, 0);
    defer alloc.free(enc);
    // No bit planes, no sign bits → header only.
    try testing.expectEqual(@as(usize, header_len), enc.len);
    const got = try roundTrip(alloc, &data, nx, ny, 0);
    defer alloc.free(got);
    try testing.expectEqualSlices(i32, &data, got);
}
