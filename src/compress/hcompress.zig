//! HCOMPRESS_1 tile codec for 2-D images (`FR-CMP-6`, §17.2; FITS 4.0 §10.4.4, Table 39).
//!
//! This is a port of the **standard** HCOMPRESS algorithm (White 1992, "High Performance
//! Compression of Astronomical Images"), following the reference implementation in CFITSIO
//! `fits_hcompress.c` / `fits_hdecompress.c`. HCOMPRESS applies only to 2-D images. The
//! pipeline is:
//!
//!   1. **H-transform** (`htrans`/`hinv`) — a 2-D Haar-like integer wavelet. Each 2×2 block
//!      `(a00,a01,a10,a11)` becomes `h0=a11+a10+a01+a00`, `hx=a11+a10-a01-a00`,
//!      `hy=a11-a10+a01-a00`, `hc=a11-a10-a01+a00`, with the standard bit-shift/round/mask
//!      scheme that makes the transform **exactly invertible** (lossless). The DC coefficients
//!      are shuffled into the top-left quadrant and the transform recurses there, `log2n` times.
//!
//!   2. **Quantization** (`digitize`/`undigitize`) — for `scale > 1` every coefficient is
//!      divided by `scale` (lossy); `scale <= 1` (and the acceptance target `scale == 0`) is a
//!      no-op, i.e. **lossless** with exact integer pixel recovery. (FITS Table 39: `ZNAME1 =
//!      'SCALE'`, `ZVAL1` default `0.0` ⇒ lossless.)
//!
//!   3. **Quadtree nibble coding** (`encode`/`decode`) — coefficients are split into sign +
//!      magnitude; each magnitude bit plane is coded MSB-first by a recursive quadtree using the
//!      conventional 16-entry nibble Huffman table (`huff_code`/`huff_n`, decoded by
//!      `inputHuffman`), with the "expanding plane" fallback (`write_bdirect`/`read_bdirect`) and
//!      the per-quadrant `nbitplanes` header.
//!
//! On-disk byte layout (matches the CFITSIO container):
//!   `magic {0xDD,0x99} (2) | nx i32 (4) | ny i32 (4) | scale i32 (4) | sumall i64 (8) |
//!    nbitplanes[3] (3) | quadtree-coded bit stream (byte aligned) | sign bits (packed bytes)`
//! All multi-byte header fields are big-endian. `nx` is the slow axis (rows), `ny` the fast axis
//! (columns), pixels row-major as `data[r*ny + c]` — the same convention as CFITSIO's internal
//! `htrans(a, nx, ny)` (where "ny is the fastest varying dimension").
//!
//! ── Standard vs. self-verified ────────────────────────────────────────────────────────────────
//! The H-transform, quantization, quadtree/nibble coding, magic bytes, header order and field
//! widths all follow the published White-1992/CFITSIO layout. Two deliberate, documented choices
//! resolve the only practical ambiguity:
//!   * The transform working array is `i64` (CFITSIO's *64-bit* code path, `htrans64`/`hinv64`),
//!     not `i32`. This keeps the full `i32` input range lossless without the int-overflow caveat
//!     of CFITSIO's 32-bit path, and `a[0]` (the pixel sum) is carried as the same 8-byte
//!     `sumall` field either way, so the container is unchanged.
//!   * `output_nnybble`/`input_nnybble` (CFITSIO's hand-unrolled bulk-nibble I/O) are expressed
//!     here as plain loops over `outputNybble`/`inputNybble`, which are bit-for-bit equivalent.
//! BYTE-EXACT parity against CFITSIO 4.6.4 is a SEPARATE blocked external-toolchain golden-corpus
//! task (no C toolchain here); this implementation is verified by lossless self round-trip
//! (`htrans`∘`hinv` identity, and `compress`∘`decompress` over constant/gradient/checkerboard/
//! random/negative/non-power-of-two/edge tiles, plus the `write_bdirect` path), and by a bounded
//! lossy (`scale > 1`) error check.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// Errors from `compress`/`decompress`. `DataConstraintViolated` is a caller/shape error (e.g.
/// a non-2-D request); `CorruptTile` is a malformed/truncated/out-of-range compressed stream.
pub const HcompressError = error{ DataConstraintViolated, CorruptTile, OutOfMemory };

/// The 2-byte stream magic identifying the standard HCOMPRESS container (CFITSIO `code_magic`).
const code_magic = [2]u8{ 0xDD, 0x99 };

/// Fixed header size in bytes: `magic(2) + nx(4) + ny(4) + scale(4) + sumall(8) + nbitplanes(3)`.
const header_len = 2 + 4 + 4 + 4 + 8 + 3;

/// Quadtree nibble Huffman code values (the standard 16-entry table; `huff_code[v]` is the bit
/// pattern, `huff_n[v]` its length). `inputHuffman` is the matching decoder.
const huff_code = [16]u32{
    0x3e, 0x00, 0x01, 0x08, 0x02, 0x09, 0x1a, 0x1b,
    0x03, 0x1c, 0x0a, 0x1d, 0x0b, 0x1e, 0x3f, 0x0c,
};
/// Bit lengths for `huff_code`.
const huff_n = [16]u8{
    6, 3, 3, 4, 3, 4, 5, 5,
    3, 5, 4, 5, 4, 5, 6, 4,
};

/// A decoded tile: the recovered `nx*ny` pixels (caller owns `data`) plus the geometry read
/// back from the stream header.
pub const Decoded = struct {
    /// Recovered pixels, row-major with the first axis (`nx` rows) varying slowest.
    data: []i32,
    /// Number of rows (first/slow axis).
    nx: usize,
    /// Number of columns (second/fast axis).
    ny: usize,
};

// ── public API ───────────────────────────────────────────────────────────────────────────────

/// Compress an `nx × ny` 2-D `i32` tile (row-major, `data[r*ny + c]`) with HCOMPRESS_1.
///
/// `scale` controls quantization: `0` (or `1`) is lossless; `scale > 1` divides coefficients
/// (lossy). `data.len` must equal `nx*ny` and both axes must be non-zero, else
/// `error.DataConstraintViolated` (HCOMPRESS is 2-D only). Caller owns the returned stream.
pub fn compress(alloc: Allocator, data: []const i32, nx: usize, ny: usize, scale: i32) HcompressError![]u8 {
    if (nx == 0 or ny == 0) return error.DataConstraintViolated;
    const n = std.math.mul(usize, nx, ny) catch return error.DataConstraintViolated;
    if (data.len != n) return error.DataConstraintViolated;
    if (scale < 0) return error.DataConstraintViolated;

    // Working array in i64 precision (CFITSIO's 64-bit path), so the transform is overflow-free
    // and exactly invertible for the full i32 input range.
    const a = try alloc.alloc(i64, n);
    defer alloc.free(a);
    for (data, 0..) |v, i| a[i] = v;

    try htrans(alloc, a, nx, ny);
    digitize(a, scale);

    // The DC coefficient (running sum of all pixels) is carried losslessly in the header; the
    // quadtree coder then sees it as zero.
    const sumall = a[0];
    a[0] = 0;

    // Split into sign bits (packed 8/byte, MSB-first) and magnitudes.
    const mag = try alloc.alloc(u64, n);
    defer alloc.free(mag);
    const signbits = try alloc.alloc(u8, (n + 7) / 8);
    defer alloc.free(signbits);
    @memset(signbits, 0);

    var nsign: usize = 0;
    var btg: i32 = 8;
    var cur: u8 = 0;
    for (a, 0..) |v, i| {
        if (v > 0) {
            cur = cur << 1;
            btg -= 1;
            mag[i] = @intCast(v);
        } else if (v < 0) {
            cur = (cur << 1) | 1;
            btg -= 1;
            mag[i] = @intCast(-v);
        } else {
            mag[i] = 0;
        }
        if (btg == 0) {
            signbits[nsign] = cur;
            nsign += 1;
            cur = 0;
            btg = 8;
        }
    }
    if (btg != 8) {
        // Left-align the final partial byte.
        signbits[nsign] = cur << @as(u3, @intCast(btg));
        nsign += 1;
    }

    // Per-quadrant maximum magnitude → bit-plane counts. Quadrant index q = (col>=ny2)+(row>=nx2):
    // 0 = top-left, 1 = top-right or bottom-left, 2 = bottom-right.
    const nx2 = (nx + 1) / 2;
    const ny2 = (ny + 1) / 2;
    var vmax = [3]u64{ 0, 0, 0 };
    {
        var jc: usize = 0;
        var kr: usize = 0;
        for (mag) |m| {
            const q: usize = @as(usize, @intFromBool(jc >= ny2)) + @as(usize, @intFromBool(kr >= nx2));
            if (vmax[q] < m) vmax[q] = m;
            jc += 1;
            if (jc >= ny) {
                jc = 0;
                kr += 1;
            }
        }
    }
    var nbitplanes: [3]u8 = .{ 0, 0, 0 };
    for (0..3) |q| {
        var v = vmax[q];
        var cnt: u8 = 0;
        while (v > 0) : (v >>= 1) cnt += 1;
        nbitplanes[q] = cnt;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // Header.
    try out.appendSlice(alloc, &code_magic);
    try appendBE(u32, &out, alloc, @intCast(nx));
    try appendBE(u32, &out, alloc, @intCast(ny));
    try appendBE(u32, &out, alloc, @bitCast(scale));
    try appendBE(u64, &out, alloc, @bitCast(sumall));
    try out.append(alloc, nbitplanes[0]);
    try out.append(alloc, nbitplanes[1]);
    try out.append(alloc, nbitplanes[2]);

    // Quadtree-coded bit stream over the four sub-quadrants, then a 0-nibble EOF.
    var enc = Encoder{ .alloc = alloc, .out = &out };
    enc.startOutputingBits();
    try enc.qtreeEncode(alloc, mag, 0, ny, nx2, ny2, nbitplanes[0]);
    try enc.qtreeEncode(alloc, mag, ny2, ny, nx2, ny / 2, nbitplanes[1]);
    try enc.qtreeEncode(alloc, mag, ny * nx2, ny, nx / 2, ny2, nbitplanes[1]);
    try enc.qtreeEncode(alloc, mag, ny * nx2 + ny2, ny, nx / 2, ny / 2, nbitplanes[2]);
    try enc.outputNybble(0);
    try enc.doneOutputingBits();

    // Sign bits (raw, byte-aligned after the quadtree stream).
    if (nsign > 0) try out.appendSlice(alloc, signbits[0..nsign]);

    return out.toOwnedSlice(alloc);
}

/// Decompress an HCOMPRESS_1 stream produced by `compress` (or any standard-layout encoder).
/// Reads `nx`, `ny`, `scale`, `sumall` and the per-quadrant plane counts, inverts the quadtree
/// coder, the quantization and the H-transform, and returns the recovered pixels. A bad magic,
/// truncated body, or out-of-range value is `error.CorruptTile`. Caller owns `Decoded.data`.
pub fn decompress(alloc: Allocator, src: []const u8) HcompressError!Decoded {
    if (src.len < 2 or src[0] != code_magic[0] or src[1] != code_magic[1]) return error.CorruptTile;
    var dec = Decoder{ .data = src, .nextchar = 2 };

    const nx_u = try readBE(u32, &dec);
    const ny_u = try readBE(u32, &dec);
    const scale_u = try readBE(u32, &dec);
    const sumall_u = try readBE(u64, &dec);
    const nb0 = try dec.readByte();
    const nb1 = try dec.readByte();
    const nb2 = try dec.readByte();

    const nx: usize = nx_u;
    const ny: usize = ny_u;
    const scale: i32 = @bitCast(scale_u);
    const sumall: i64 = @bitCast(sumall_u);

    if (nx == 0 or ny == 0) return error.CorruptTile;
    if (scale < 0) return error.CorruptTile;
    if (nb0 > 63 or nb1 > 63 or nb2 > 63) return error.CorruptTile;
    const n = std.math.mul(usize, nx, ny) catch return error.CorruptTile;

    const mag = try alloc.alloc(u64, n);
    defer alloc.free(mag);
    @memset(mag, 0);

    const nx2 = (nx + 1) / 2;
    const ny2 = (ny + 1) / 2;

    // Quadtree decode of the four sub-quadrants, then the 0-nibble EOF.
    dec.startInputingBits();
    try dec.qtreeDecode(alloc, mag, 0, ny, nx2, ny2, nb0);
    try dec.qtreeDecode(alloc, mag, ny2, ny, nx2, ny / 2, nb1);
    try dec.qtreeDecode(alloc, mag, ny * nx2, ny, nx / 2, ny2, nb1);
    try dec.qtreeDecode(alloc, mag, ny * nx2 + ny2, ny, nx / 2, ny / 2, nb2);
    if ((try dec.inputNybble()) != 0) return error.CorruptTile;

    // Sign bits begin at the next byte boundary; apply them to the magnitudes.
    const a = try alloc.alloc(i64, n);
    defer alloc.free(a);
    dec.startInputingBits();
    for (mag, 0..) |m, i| {
        if (m != 0) {
            const neg = (try dec.inputBit()) != 0;
            const mi: i64 = @intCast(m);
            a[i] = if (neg) -mi else mi;
        } else {
            a[i] = 0;
        }
    }

    // Restore the DC term, undo quantization, invert the transform.
    a[0] = sumall;
    undigitize(a, scale);
    try hinv(alloc, a, nx, ny);

    const out = try alloc.alloc(i32, n);
    errdefer alloc.free(out);
    for (a, 0..) |v, i| {
        out[i] = std.math.cast(i32, v) orelse return error.CorruptTile;
    }
    return .{ .data = out, .nx = nx, .ny = ny };
}

// ── H-transform ────────────────────────────────────────────────────────────────────────────

// Forward integer H-transform (CFITSIO `htrans`), in place on the `nx × ny` image `a[r*ny+c]`.
// After it, `a[0]` holds the DC term and the rest hold detail coefficients. Lossless: `hinv`
// exactly inverts it.
fn htrans(alloc: Allocator, a: []i64, nx: usize, ny: usize) Allocator.Error!void {
    const log2n = ceilLog2(@max(nx, ny));
    if (log2n == 0) return;
    const tmp = try alloc.alloc(i64, (@max(nx, ny) + 1) / 2);
    defer alloc.free(tmp);

    var shift: u6 = 0;
    var mask: i64 = -2;
    var mask2: i64 = mask << 1;
    var prnd: i64 = 1;
    var prnd2: i64 = prnd << 1;
    var nrnd2: i64 = prnd2 - 1;
    var nxtop: usize = nx;
    var nytop: usize = ny;

    var lvl: usize = 0;
    while (lvl < log2n) : (lvl += 1) {
        const oddx = (nxtop & 1) == 1;
        const oddy = (nytop & 1) == 1;
        var i: usize = 0;
        while (i + 1 < nxtop) : (i += 2) {
            const r0 = i * ny;
            const r1 = r0 + ny;
            var j: usize = 0;
            while (j + 1 < nytop) : (j += 2) {
                const s00 = r0 + j;
                const s10 = r1 + j;
                const a00 = a[s00];
                const a01 = a[s00 + 1];
                const a10 = a[s10];
                const a11 = a[s10 + 1];
                const h0 = (a11 + a10 + a01 + a00) >> shift;
                const hx = (a11 + a10 - a01 - a00) >> shift;
                const hy = (a11 - a10 + a01 - a00) >> shift;
                const hc = (a11 - a10 - a01 + a00) >> shift;
                a[s10 + 1] = hc;
                a[s10] = (if (hx >= 0) hx + prnd else hx) & mask;
                a[s00 + 1] = (if (hy >= 0) hy + prnd else hy) & mask;
                a[s00] = (if (h0 >= 0) h0 + prnd2 else h0 + nrnd2) & mask2;
            }
            if (oddy) {
                const s00 = r0 + (nytop - 1);
                const s10 = r1 + (nytop - 1);
                const sh1: u6 = 1 - shift;
                const h0 = (a[s10] + a[s00]) << sh1;
                const hx = (a[s10] - a[s00]) << sh1;
                a[s10] = (if (hx >= 0) hx + prnd else hx) & mask;
                a[s00] = (if (h0 >= 0) h0 + prnd2 else h0 + nrnd2) & mask2;
            }
        }
        if (oddx) {
            const r0 = (nxtop - 1) * ny;
            var j: usize = 0;
            while (j + 1 < nytop) : (j += 2) {
                const s00 = r0 + j;
                const sh1: u6 = 1 - shift;
                const h0 = (a[s00 + 1] + a[s00]) << sh1;
                const hy = (a[s00 + 1] - a[s00]) << sh1;
                a[s00 + 1] = (if (hy >= 0) hy + prnd else hy) & mask;
                a[s00] = (if (h0 >= 0) h0 + prnd2 else h0 + nrnd2) & mask2;
            }
            if (oddy) {
                const s00 = r0 + (nytop - 1);
                const sh2: u6 = 2 - shift;
                const h0 = a[s00] << sh2;
                a[s00] = (if (h0 >= 0) h0 + prnd2 else h0 + nrnd2) & mask2;
            }
        }
        // Group DC coefficients into the top-left quadrant: shuffle within rows, then columns.
        var r: usize = 0;
        while (r < nxtop) : (r += 1) shuffle(a, r * ny, nytop, 1, tmp);
        var c: usize = 0;
        while (c < nytop) : (c += 1) shuffle(a, c, nxtop, ny, tmp);

        nxtop = (nxtop + 1) >> 1;
        nytop = (nytop + 1) >> 1;
        shift = 1;
        mask = mask2;
        prnd = prnd2;
        mask2 = mask2 << 1;
        prnd2 = prnd2 << 1;
        nrnd2 = prnd2 - 1;
    }
}

// Inverse integer H-transform (CFITSIO `hinv`, no smoothing). Exact inverse of `htrans`.
fn hinv(alloc: Allocator, a: []i64, nx: usize, ny: usize) Allocator.Error!void {
    const log2n = ceilLog2(@max(nx, ny));
    if (log2n == 0) return;
    const tmp = try alloc.alloc(i64, (@max(nx, ny) + 1) / 2);
    defer alloc.free(tmp);

    var shift: u6 = 1;
    var bit0: i64 = @as(i64, 1) << @as(u6, @intCast(log2n - 1));
    var bit1: i64 = bit0 << 1;
    var mask0: i64 = -bit0;
    var mask1: i64 = mask0 << 1;
    var prnd0: i64 = bit0 >> 1;
    var prnd1: i64 = bit1 >> 1;
    var nrnd0: i64 = prnd0 - 1;
    var nrnd1: i64 = prnd1 - 1;

    // Round h0 (DC) to a multiple of bit2 = bit0<<2 (a no-op for an exact `htrans` output).
    {
        const bit2: i64 = bit0 << 2;
        const mask2: i64 = mask0 << 2;
        const prnd2: i64 = bit2 >> 1;
        const nrnd2: i64 = prnd2 - 1;
        a[0] = (a[0] + (if (a[0] >= 0) prnd2 else nrnd2)) & mask2;
    }

    var nxtop: usize = 1;
    var nytop: usize = 1;
    var nxf: usize = nx;
    var nyf: usize = ny;
    var c: usize = @as(usize, 1) << @as(u6, @intCast(log2n));

    var k: usize = log2n;
    while (k > 0) {
        k -= 1;
        // Generate ntop[k-1] = (ntop[k]+1)/2 with ntop[log2n] = nx/ny.
        c = c >> 1;
        nxtop = nxtop << 1;
        nytop = nytop << 1;
        if (nxf <= c) nxtop -= 1 else nxf -= c;
        if (nyf <= c) nytop -= 1 else nyf -= c;
        if (k == 0) {
            nrnd0 = 0;
            shift = 2;
        }
        var ui: usize = 0;
        while (ui < nxtop) : (ui += 1) unshuffle(a, ny * ui, nytop, 1, tmp);
        var uj: usize = 0;
        while (uj < nytop) : (uj += 1) unshuffle(a, uj, nxtop, ny, tmp);

        const oddx = (nxtop & 1) == 1;
        const oddy = (nytop & 1) == 1;
        var i: usize = 0;
        while (i + 1 < nxtop) : (i += 2) {
            const r0 = ny * i;
            const r1 = r0 + ny;
            var j: usize = 0;
            while (j + 1 < nytop) : (j += 2) {
                const s00 = r0 + j;
                const s10 = r1 + j;
                var h0 = a[s00];
                var hx = a[s10];
                var hy = a[s00 + 1];
                var hc = a[s10 + 1];
                hx = (hx + (if (hx >= 0) prnd1 else nrnd1)) & mask1;
                hy = (hy + (if (hy >= 0) prnd1 else nrnd1)) & mask1;
                hc = (hc + (if (hc >= 0) prnd0 else nrnd0)) & mask0;
                const lowbit0 = hc & bit0;
                hx = if (hx >= 0) hx - lowbit0 else hx + lowbit0;
                hy = if (hy >= 0) hy - lowbit0 else hy + lowbit0;
                const lowbit1 = (hc ^ hx ^ hy) & bit1;
                h0 = if (h0 >= 0)
                    h0 + lowbit0 - lowbit1
                else
                    h0 + (if (lowbit0 == 0) lowbit1 else lowbit0 - lowbit1);
                a[s10 + 1] = (h0 + hx + hy + hc) >> shift;
                a[s10] = (h0 + hx - hy - hc) >> shift;
                a[s00 + 1] = (h0 - hx + hy - hc) >> shift;
                a[s00] = (h0 - hx - hy + hc) >> shift;
            }
            if (oddy) {
                const s00 = r0 + (nytop - 1);
                const s10 = r1 + (nytop - 1);
                var h0 = a[s00];
                var hx = a[s10];
                hx = (hx + (if (hx >= 0) prnd1 else nrnd1)) & mask1;
                const lowbit1 = hx & bit1;
                h0 = if (h0 >= 0) h0 - lowbit1 else h0 + lowbit1;
                a[s10] = (h0 + hx) >> shift;
                a[s00] = (h0 - hx) >> shift;
            }
        }
        if (oddx) {
            const r0 = (nxtop - 1) * ny;
            var j: usize = 0;
            while (j + 1 < nytop) : (j += 2) {
                const s00 = r0 + j;
                var h0 = a[s00];
                var hy = a[s00 + 1];
                hy = (hy + (if (hy >= 0) prnd1 else nrnd1)) & mask1;
                const lowbit1 = hy & bit1;
                h0 = if (h0 >= 0) h0 - lowbit1 else h0 + lowbit1;
                a[s00 + 1] = (h0 + hy) >> shift;
                a[s00] = (h0 - hy) >> shift;
            }
            if (oddy) {
                const s00 = r0 + (nytop - 1);
                a[s00] = a[s00] >> shift;
            }
        }
        bit1 = bit0;
        bit0 = bit0 >> 1;
        mask1 = mask0;
        mask0 = mask0 >> 1;
        prnd1 = prnd0;
        prnd0 = prnd0 >> 1;
        nrnd1 = nrnd0;
        nrnd0 = prnd0 - 1;
    }
}

// Shuffle `n` elements at `base` with stride `s` from interleaved order into "evens then odds"
// (CFITSIO `shuffle`); `unshuffle` is its exact inverse.
fn shuffle(a: []i64, base: usize, n: usize, s: usize, tmp: []i64) void {
    var pt: usize = 0;
    var p1: usize = base + s;
    var i: usize = 1;
    while (i < n) : (i += 2) {
        tmp[pt] = a[p1];
        pt += 1;
        p1 += 2 * s;
    }
    p1 = base + s;
    var p2: usize = base + 2 * s;
    i = 2;
    while (i < n) : (i += 2) {
        a[p1] = a[p2];
        p1 += s;
        p2 += 2 * s;
    }
    pt = 0;
    i = 1;
    while (i < n) : (i += 2) {
        a[p1] = tmp[pt];
        p1 += s;
        pt += 1;
    }
}

// Inverse of `shuffle` (CFITSIO `unshuffle`).
fn unshuffle(a: []i64, base: usize, n: usize, s: usize, tmp: []i64) void {
    const nhalf = (n + 1) >> 1;
    // Copy 2nd half to tmp.
    var pt: usize = 0;
    var p1: usize = base + s * nhalf;
    var i: usize = nhalf;
    while (i < n) : (i += 1) {
        tmp[pt] = a[p1];
        p1 += s;
        pt += 1;
    }
    // Distribute 1st half to even elements (reverse order to keep in-place safe).
    var ridx: isize = @as(isize, @intCast(nhalf)) - 1;
    var p2: usize = base + s * (nhalf - 1);
    p1 = base + (s * (nhalf - 1)) * 2;
    while (ridx >= 0) : (ridx -= 1) {
        a[p1] = a[p2];
        if (ridx > 0) {
            p2 -= s;
            p1 -= 2 * s;
        }
    }
    // Distribute 2nd half (tmp) to odd elements.
    pt = 0;
    p1 = base + s;
    i = 1;
    while (i < n) : (i += 2) {
        a[p1] = tmp[pt];
        p1 += 2 * s;
        pt += 1;
    }
}

// ── quantization ─────────────────────────────────────────────────────────────────────────────

// Divide coefficients by `scale` with symmetric rounding (CFITSIO `digitize`). `scale <= 1` is a
// lossless no-op.
fn digitize(a: []i64, scale: i32) void {
    if (scale <= 1) return;
    const s: i64 = scale;
    const d: i64 = @divTrunc(s + 1, 2) - 1;
    for (a) |*p| {
        p.* = @divTrunc(if (p.* > 0) p.* + d else p.* - d, s);
    }
}

// Multiply coefficients by `scale` (CFITSIO `undigitize`). `scale <= 1` is a no-op.
fn undigitize(a: []i64, scale: i32) void {
    if (scale <= 1) return;
    const s: i64 = scale;
    for (a) |*p| p.* = p.* * s;
}

// ── quadtree nibble coding (pure helpers) ──────────────────────────────────────────────────────

inline fn bitAt(m: u64, bit: u6) u64 {
    return (m >> bit) & 1;
}
inline fn nz(x: u8) u8 {
    return if (x != 0) 1 else 0;
}

// Extract bit plane `bit` of the magnitudes in the `nqx × nqy` sub-image at `base` (stride `n`)
// into the nibble array `scratch` (CFITSIO `qtree_onebit`). Nibble layout: bit0=a[s10+1],
// bit1=a[s10], bit2=a[s00+1], bit3=a[s00].
fn qtreeOnebit(mag: []const u64, base: usize, n: usize, nqx: usize, nqy: usize, scratch: []u8, bit: u6) void {
    var k: usize = 0;
    var i: usize = 0;
    while (i + 1 < nqx) : (i += 2) {
        const r0 = base + n * i;
        const r1 = r0 + n;
        var j: usize = 0;
        while (j + 1 < nqy) : (j += 2) {
            scratch[k] = @intCast(bitAt(mag[r1 + j + 1], bit) |
                (bitAt(mag[r1 + j], bit) << 1) |
                (bitAt(mag[r0 + j + 1], bit) << 2) |
                (bitAt(mag[r0 + j], bit) << 3));
            k += 1;
        }
        if (j < nqy) {
            scratch[k] = @intCast((bitAt(mag[r1 + j], bit) << 1) | (bitAt(mag[r0 + j], bit) << 3));
            k += 1;
        }
    }
    if (i < nqx) {
        const r0 = base + n * i;
        var j: usize = 0;
        while (j + 1 < nqy) : (j += 2) {
            scratch[k] = @intCast((bitAt(mag[r0 + j + 1], bit) << 2) | (bitAt(mag[r0 + j], bit) << 3));
            k += 1;
        }
        if (j < nqy) {
            scratch[k] = @intCast(bitAt(mag[r0 + j], bit) << 3);
            k += 1;
        }
    }
}

// Reduce an `nx × ny` nibble array (stride `n`) to its quadtree parent, in place (CFITSIO
// `qtree_reduce`): each parent nibble flags which of its 4 children are non-zero.
fn qtreeReduce(s: []u8, n: usize, nx: usize, ny: usize) void {
    var k: usize = 0;
    var i: usize = 0;
    while (i + 1 < nx) : (i += 2) {
        const r0 = n * i;
        const r1 = r0 + n;
        var j: usize = 0;
        while (j + 1 < ny) : (j += 2) {
            s[k] = nz(s[r1 + j + 1]) | (nz(s[r1 + j]) << 1) | (nz(s[r0 + j + 1]) << 2) | (nz(s[r0 + j]) << 3);
            k += 1;
        }
        if (j < ny) {
            s[k] = (nz(s[r1 + j]) << 1) | (nz(s[r0 + j]) << 3);
            k += 1;
        }
    }
    if (i < nx) {
        const r0 = n * i;
        var j: usize = 0;
        while (j + 1 < ny) : (j += 2) {
            s[k] = (nz(s[r0 + j + 1]) << 2) | (nz(s[r0 + j]) << 3);
            k += 1;
        }
        if (j < ny) {
            s[k] = nz(s[r0 + j]) << 3;
            k += 1;
        }
    }
}

// Insert the nibbles of `scratch` into bit plane `bit` of the `nqx × nqy` magnitude sub-image at
// `base` (stride `n`) (CFITSIO `qtree_bitins`).
fn qtreeBitins(scratch: []const u8, nqx: usize, nqy: usize, mag: []u64, base: usize, n: usize, bit: u6) void {
    const plane: u64 = @as(u64, 1) << bit;
    var k: usize = 0;
    var i: usize = 0;
    while (i + 1 < nqx) : (i += 2) {
        const r0 = base + n * i;
        const r1 = r0 + n;
        var j: usize = 0;
        while (j + 1 < nqy) : (j += 2) {
            const cc = scratch[k];
            if (cc & 1 != 0) mag[r1 + j + 1] |= plane;
            if (cc & 2 != 0) mag[r1 + j] |= plane;
            if (cc & 4 != 0) mag[r0 + j + 1] |= plane;
            if (cc & 8 != 0) mag[r0 + j] |= plane;
            k += 1;
        }
        if (j < nqy) {
            const cc = scratch[k];
            if (cc & 2 != 0) mag[r1 + j] |= plane;
            if (cc & 8 != 0) mag[r0 + j] |= plane;
            k += 1;
        }
    }
    if (i < nqx) {
        const r0 = base + n * i;
        var j: usize = 0;
        while (j + 1 < nqy) : (j += 2) {
            const cc = scratch[k];
            if (cc & 4 != 0) mag[r0 + j + 1] |= plane;
            if (cc & 8 != 0) mag[r0 + j] |= plane;
            k += 1;
        }
        if (j < nqy) {
            const cc = scratch[k];
            if (cc & 8 != 0) mag[r0 + j] |= plane;
            k += 1;
        }
    }
}

// Expand a compact `(nx2 × ny2)` nibble array to an `nx × ny` quadtree level, in place (CFITSIO
// `qtree_copy`, with the equivalent bit-extraction form of its 16-case switch). `n` is the
// declared row stride of the expanded array.
fn qtreeCopy(s: []u8, nx: usize, ny: usize, n: usize) void {
    const nx2 = (nx + 1) / 2;
    const ny2 = (ny + 1) / 2;
    // Scatter compact nibbles to stride-2 positions (reverse, so in-place is safe).
    var kk: isize = @intCast(ny2 * (nx2 - 1) + ny2 - 1);
    var ri: isize = @as(isize, @intCast(nx2)) - 1;
    while (ri >= 0) : (ri -= 1) {
        var s00: isize = @intCast(2 * (n * @as(usize, @intCast(ri)) + ny2 - 1));
        var rj: isize = @as(isize, @intCast(ny2)) - 1;
        while (rj >= 0) : (rj -= 1) {
            s[@intCast(s00)] = s[@intCast(kk)];
            kk -= 1;
            s00 -= 2;
        }
    }
    // Expand each 2x2 block.
    var i: usize = 0;
    while (i + 1 < nx) : (i += 2) {
        const r0 = n * i;
        const r1 = r0 + n;
        var j: usize = 0;
        while (j + 1 < ny) : (j += 2) {
            const v = s[r0 + j];
            s[r1 + j + 1] = v & 1;
            s[r1 + j] = (v >> 1) & 1;
            s[r0 + j + 1] = (v >> 2) & 1;
            s[r0 + j] = (v >> 3) & 1;
        }
        if (j < ny) {
            const v = s[r0 + j];
            s[r1 + j] = (v >> 1) & 1;
            s[r0 + j] = (v >> 3) & 1;
        }
    }
    if (i < nx) {
        const r0 = n * i;
        var j: usize = 0;
        while (j + 1 < ny) : (j += 2) {
            const v = s[r0 + j];
            s[r0 + j + 1] = (v >> 2) & 1;
            s[r0 + j] = (v >> 3) & 1;
        }
        if (j < ny) {
            s[r0 + j] = (s[r0 + j] >> 3) & 1;
        }
    }
}

// ceil(log2(m)); 0 for m <= 1. Matches CFITSIO's `log2n` for all tile-sized inputs.
fn ceilLog2(m: usize) usize {
    if (m <= 1) return 0;
    return 64 - @as(usize, @clz(@as(u64, m - 1)));
}

// ── encoder ─────────────────────────────────────────────────────────────────────────────────

const Encoder = struct {
    alloc: Allocator,
    out: *std.ArrayList(u8),
    // MSB-first bit output state (CFITSIO buffer2/bits_to_go2).
    buffer2: u32 = 0,
    bits_to_go2: i32 = 8,
    // Per-bit-plane code accumulator (CFITSIO bitbuffer/bits_to_go3).
    bitbuffer: u32 = 0,
    bits_to_go3: i32 = 0,

    fn startOutputingBits(self: *Encoder) void {
        self.buffer2 = 0;
        self.bits_to_go2 = 8;
    }

    fn outputNbits(self: *Encoder, bits: u32, n: u8) Allocator.Error!void {
        const mask = [_]u32{ 0, 1, 3, 7, 15, 31, 63, 127, 255 };
        self.buffer2 = (self.buffer2 << @as(u5, @intCast(n))) | (bits & mask[n]);
        self.bits_to_go2 -= @as(i32, n);
        if (self.bits_to_go2 <= 0) {
            const sh: u5 = @intCast(-self.bits_to_go2);
            try self.out.append(self.alloc, @intCast((self.buffer2 >> sh) & 0xff));
            self.bits_to_go2 += 8;
        }
    }

    fn outputNybble(self: *Encoder, bits: u32) Allocator.Error!void {
        self.buffer2 = (self.buffer2 << 4) | (bits & 15);
        self.bits_to_go2 -= 4;
        if (self.bits_to_go2 <= 0) {
            const sh: u5 = @intCast(-self.bits_to_go2);
            try self.out.append(self.alloc, @intCast((self.buffer2 >> sh) & 0xff));
            self.bits_to_go2 += 8;
        }
    }

    fn outputHuffman(self: *Encoder, c: u8) Allocator.Error!void {
        try self.outputNbits(huff_code[c], huff_n[c]);
    }

    fn doneOutputingBits(self: *Encoder) Allocator.Error!void {
        if (self.bits_to_go2 < 8) {
            const sh: u5 = @intCast(self.bits_to_go2);
            try self.out.append(self.alloc, @intCast((self.buffer2 << sh) & 0xff));
        }
    }

    // Copy non-zero nibbles' Huffman codes into `buffer` (LSB-first packing, spilling whole
    // bytes). Returns true if `buffer` overflowed (signals the quadtree-expanding fallback).
    fn bufcopy(self: *Encoder, a: []const u8, buffer: []u8, b: *usize, bmax: usize) bool {
        for (a) |val| {
            if (val != 0) {
                self.bitbuffer |= huff_code[val] << @as(u5, @intCast(self.bits_to_go3));
                self.bits_to_go3 += @as(i32, huff_n[val]);
                if (self.bits_to_go3 >= 8) {
                    buffer[b.*] = @intCast(self.bitbuffer & 0xFF);
                    b.* += 1;
                    if (b.* >= bmax) return true;
                    self.bitbuffer >>= 8;
                    self.bits_to_go3 -= 8;
                }
            }
        }
        return false;
    }

    // Fallback for a bit plane the quadtree fails to compress: write a 0-nibble marker then the
    // raw first-level nibble map (CFITSIO `write_bdirect`).
    fn writeBdirect(self: *Encoder, mag: []const u64, base: usize, n: usize, nqx: usize, nqy: usize, scratch: []u8, bit: u6) Allocator.Error!void {
        try self.outputNybble(0x0);
        qtreeOnebit(mag, base, n, nqx, nqy, scratch, bit);
        const cnt = ((nqx + 1) / 2) * ((nqy + 1) / 2);
        var i: usize = 0;
        while (i < cnt) : (i += 1) try self.outputNybble(scratch[i]);
    }

    // Quadtree-encode the bit planes of one sub-quadrant (CFITSIO `qtree_encode`).
    fn qtreeEncode(self: *Encoder, alloc: Allocator, mag: []const u64, base: usize, n: usize, nqx: usize, nqy: usize, nbitplanes: u8) HcompressError!void {
        const log2n = ceilLog2(@max(nqx, nqy));
        const nqx2 = (nqx + 1) / 2;
        const nqy2 = (nqy + 1) / 2;
        const bmax = (nqx2 * nqy2 + 1) / 2;
        const scratch = try alloc.alloc(u8, @max(1, nqx2 * nqy2));
        defer alloc.free(scratch);
        const buffer = try alloc.alloc(u8, @max(1, bmax));
        defer alloc.free(buffer);

        var bit: i32 = @as(i32, nbitplanes) - 1;
        while (bit >= 0) : (bit -= 1) {
            const bitu: u6 = @intCast(bit);
            var b: usize = 0;
            self.bitbuffer = 0;
            self.bits_to_go3 = 0;

            qtreeOnebit(mag, base, n, nqx, nqy, scratch, bitu);
            var cx = (nqx + 1) >> 1;
            var cy = (nqy + 1) >> 1;
            if (self.bufcopy(scratch[0 .. cx * cy], buffer, &b, bmax)) {
                try self.writeBdirect(mag, base, n, nqx, nqy, scratch, bitu);
                continue;
            }
            var did_bdirect = false;
            var lvl: usize = 1;
            while (lvl < log2n) : (lvl += 1) {
                qtreeReduce(scratch, cy, cx, cy);
                cx = (cx + 1) >> 1;
                cy = (cy + 1) >> 1;
                if (self.bufcopy(scratch[0 .. cx * cy], buffer, &b, bmax)) {
                    try self.writeBdirect(mag, base, n, nqx, nqy, scratch, bitu);
                    did_bdirect = true;
                    break;
                }
            }
            if (did_bdirect) continue;

            // Quadtree warning nibble, the leftover partial code bits, then buffer in reverse.
            try self.outputNybble(0xF);
            if (self.bits_to_go3 > 0) {
                const nb: u5 = @intCast(self.bits_to_go3);
                try self.outputNbits(self.bitbuffer & ((@as(u32, 1) << nb) - 1), @intCast(self.bits_to_go3));
            } else if (b == 0) {
                try self.outputHuffman(0);
            }
            var ii: usize = b;
            while (ii > 0) {
                ii -= 1;
                try self.outputNbits(buffer[ii], 8);
            }
        }
    }
};

// ── decoder ─────────────────────────────────────────────────────────────────────────────────

const Decoder = struct {
    data: []const u8,
    nextchar: usize = 0,
    // MSB-first bit input state (CFITSIO buffer2/bits_to_go).
    buffer2: u32 = 0,
    bits_to_go: i32 = 0,

    fn readByte(self: *Decoder) error{CorruptTile}!u8 {
        if (self.nextchar >= self.data.len) return error.CorruptTile;
        const b = self.data[self.nextchar];
        self.nextchar += 1;
        return b;
    }

    fn startInputingBits(self: *Decoder) void {
        self.bits_to_go = 0;
    }

    fn inputBit(self: *Decoder) error{CorruptTile}!u32 {
        if (self.bits_to_go == 0) {
            self.buffer2 = try self.readByte();
            self.bits_to_go = 8;
        }
        self.bits_to_go -= 1;
        return (self.buffer2 >> @as(u5, @intCast(self.bits_to_go))) & 1;
    }

    fn inputNbits(self: *Decoder, n: u8) error{CorruptTile}!u32 {
        const mask = [_]u32{ 0, 1, 3, 7, 15, 31, 63, 127, 255 };
        if (self.bits_to_go < @as(i32, n)) {
            self.buffer2 = (self.buffer2 << 8) | @as(u32, try self.readByte());
            self.bits_to_go += 8;
        }
        self.bits_to_go -= @as(i32, n);
        return (self.buffer2 >> @as(u5, @intCast(self.bits_to_go))) & mask[n];
    }

    fn inputNybble(self: *Decoder) error{CorruptTile}!u32 {
        return self.inputNbits(4);
    }

    // Decode one variable-length quadtree nibble code (CFITSIO `input_huffman`).
    fn inputHuffman(self: *Decoder) error{CorruptTile}!u32 {
        var c = try self.inputNbits(3);
        if (c < 4) return @as(u32, 1) << @as(u5, @intCast(c));
        c = (try self.inputBit()) | (c << 1);
        if (c < 13) return switch (c) {
            8 => 3,
            9 => 5,
            10 => 10,
            11 => 12,
            12 => 15,
            else => error.CorruptTile,
        };
        c = (try self.inputBit()) | (c << 1);
        if (c < 31) return switch (c) {
            26 => 6,
            27 => 7,
            28 => 9,
            29 => 11,
            30 => 13,
            else => error.CorruptTile,
        };
        c = (try self.inputBit()) | (c << 1);
        return if (c == 62) 0 else 14;
    }

    // Read a directly-written bit plane (CFITSIO `read_bdirect`).
    fn readBdirect(self: *Decoder, mag: []u64, base: usize, n: usize, nqx: usize, nqy: usize, scratch: []u8, bit: u6) error{CorruptTile}!void {
        const cnt = ((nqx + 1) / 2) * ((nqy + 1) / 2);
        var i: usize = 0;
        while (i < cnt) : (i += 1) scratch[i] = @intCast(try self.inputNybble());
        qtreeBitins(scratch, nqx, nqy, mag, base, n, bit);
    }

    // Expand a quadtree level, reading a fresh nibble for each non-zero parent (CFITSIO
    // `qtree_expand`).
    fn qtreeExpand(self: *Decoder, scratch: []u8, nx: usize, ny: usize) error{CorruptTile}!void {
        qtreeCopy(scratch, nx, ny, ny);
        var i: isize = @as(isize, @intCast(nx * ny)) - 1;
        while (i >= 0) : (i -= 1) {
            if (scratch[@intCast(i)] != 0) scratch[@intCast(i)] = @intCast(try self.inputHuffman());
        }
    }

    // Quadtree-decode the bit planes of one sub-quadrant (CFITSIO `qtree_decode`).
    fn qtreeDecode(self: *Decoder, alloc: Allocator, mag: []u64, base: usize, n: usize, nqx: usize, nqy: usize, nbitplanes: u8) HcompressError!void {
        const log2n = ceilLog2(@max(nqx, nqy));
        const nqx2 = (nqx + 1) / 2;
        const nqy2 = (nqy + 1) / 2;

        // Scratch must hold the largest expansion level (which, for degenerate quadrant shapes,
        // can exceed nqx2*nqy2), plus the direct/bitins map.
        var smax: usize = @max(1, nqx2 * nqy2);
        {
            var nx: usize = 1;
            var ny: usize = 1;
            var nfx = nqx;
            var nfy = nqy;
            var c: usize = @as(usize, 1) << @as(u6, @intCast(log2n));
            var k: usize = 1;
            while (k < log2n) : (k += 1) {
                c >>= 1;
                nx <<= 1;
                ny <<= 1;
                if (nfx <= c) nx -= 1 else nfx -= c;
                if (nfy <= c) ny -= 1 else nfy -= c;
                if (nx * ny > smax) smax = nx * ny;
            }
        }
        const scratch = try alloc.alloc(u8, smax + 1);
        defer alloc.free(scratch);

        var bit: i32 = @as(i32, nbitplanes) - 1;
        while (bit >= 0) : (bit -= 1) {
            const bitu: u6 = @intCast(bit);
            const b = try self.inputNybble();
            if (b == 0) {
                try self.readBdirect(mag, base, n, nqx, nqy, scratch, bitu);
            } else if (b != 0xF) {
                return error.CorruptTile;
            } else {
                scratch[0] = @intCast(try self.inputHuffman());
                var nx: usize = 1;
                var ny: usize = 1;
                var nfx = nqx;
                var nfy = nqy;
                var c: usize = @as(usize, 1) << @as(u6, @intCast(log2n));
                var k: usize = 1;
                while (k < log2n) : (k += 1) {
                    c >>= 1;
                    nx <<= 1;
                    ny <<= 1;
                    if (nfx <= c) nx -= 1 else nfx -= c;
                    if (nfy <= c) ny -= 1 else nfy -= c;
                    try self.qtreeExpand(scratch, nx, ny);
                }
                qtreeBitins(scratch, nqx, nqy, mag, base, n, bitu);
            }
        }
    }
};

// ── small helpers ──────────────────────────────────────────────────────────────────────────

fn appendBE(comptime T: type, out: *std.ArrayList(u8), alloc: Allocator, v: T) Allocator.Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .big);
    try out.appendSlice(alloc, &buf);
}

fn readBE(comptime T: type, dec: *Decoder) error{CorruptTile}!T {
    var v: T = 0;
    var i: usize = 0;
    while (i < @sizeOf(T)) : (i += 1) {
        v = (v << 8) | @as(T, try dec.readByte());
    }
    return v;
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

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
        .{ 31, 5 }, .{ 9, 9 },
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

test "lossless round-trip: dense random exercises the write_bdirect fallback" {
    const alloc = testing.allocator;
    const nx = 32;
    const ny = 32;
    var data: [nx * ny]i32 = undefined;
    var seed: u64 = 0x0123456789ABCDEF;
    for (&data) |*v| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        // Full-range-ish noise: low bit planes are ~50% dense, so the quadtree expands and the
        // codec must fall back to write_bdirect/read_bdirect.
        v.* = @as(i32, @bitCast(@as(u32, @truncate(seed >> 32)))) >> 12;
    }
    try expectLosslessRoundTrip(alloc, &data, nx, ny);
}

test "lossless round-trip: larger dense random 48x40" {
    const alloc = testing.allocator;
    const nx = 48;
    const ny = 40;
    const data = try alloc.alloc(i32, nx * ny);
    defer alloc.free(data);
    var seed: u64 = 0xA5A5F00DD00FA5A5;
    for (data) |*v| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        v.* = @as(i32, @bitCast(@as(u32, @truncate(seed >> 30)))) >> 10;
    }
    try expectLosslessRoundTrip(alloc, data, nx, ny);
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

test "lossless round-trip: 1xN, Nx1, and small edge shapes" {
    const alloc = testing.allocator;
    {
        const data = [_]i32{-7};
        try expectLosslessRoundTrip(alloc, &data, 1, 1);
    }
    {
        const data = [_]i32{5};
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
    {
        const data = [_]i32{ 9, -8 };
        try expectLosslessRoundTrip(alloc, &data, 2, 1);
    }
    {
        const data = [_]i32{ 3, -1, 4, -1, 5, -9, 2 };
        try expectLosslessRoundTrip(alloc, &data, 1, 7);
    }
    {
        const data = [_]i32{ 11, -22, 33, -44, 55 };
        try expectLosslessRoundTrip(alloc, &data, 5, 1);
    }
}

test "lossless round-trip: 3x4 tile (tiled.zig dispatch shape)" {
    const alloc = testing.allocator;
    const data = [_]i32{ 1, 2, 3, 4, 10, 11, 12, 13, -7, -6, -5, -4 };
    try expectLosslessRoundTrip(alloc, &data, 3, 4);
}

test "decompress reports geometry and standard magic from the stream header" {
    const alloc = testing.allocator;
    var data: [17 * 13]i32 = undefined;
    for (&data, 0..) |*v, i| v.* = @intCast(i);
    const enc = try compress(alloc, &data, 17, 13, 0);
    defer alloc.free(enc);
    try testing.expectEqual(@as(u8, 0xDD), enc[0]);
    try testing.expectEqual(@as(u8, 0x99), enc[1]);
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
    // Too short for the magic.
    try testing.expectError(error.CorruptTile, decompress(alloc, "s"));
    // Long enough but wrong magic.
    var buf: [header_len]u8 = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..2], "ZZ");
    try testing.expectError(error.CorruptTile, decompress(alloc, &buf));

    // Valid header but truncated bit stream.
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
    // Quantizing the H-transform coefficients by `scale` bounds the per-pixel error.
    var maxerr: i64 = 0;
    for (data, got) |o, g| {
        const e: i64 = @intCast(@abs(@as(i64, o) - @as(i64, g)));
        if (e > maxerr) maxerr = e;
    }
    try testing.expect(maxerr <= 256);
}

test "lossy: scale==0 and scale==1 are both lossless" {
    const alloc = testing.allocator;
    const nx = 12;
    const ny = 9;
    var data: [nx * ny]i32 = undefined;
    var seed: u64 = 0xFEEDFACE12345678;
    for (&data) |*v| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        v.* = @rem(@as(i32, @bitCast(@as(u32, @truncate(seed >> 32)))), 20000);
    }
    {
        const got = try roundTrip(alloc, &data, nx, ny, 0);
        defer alloc.free(got);
        try testing.expectEqualSlices(i32, &data, got);
    }
    {
        const got = try roundTrip(alloc, &data, nx, ny, 1);
        defer alloc.free(got);
        try testing.expectEqualSlices(i32, &data, got);
    }
}

test "empty/zero magnitudes: all-zero image round-trips and stays tiny" {
    const alloc = testing.allocator;
    const nx = 8;
    const ny = 8;
    var data: [nx * ny]i32 = undefined;
    @memset(&data, 0);
    const enc = try compress(alloc, &data, nx, ny, 0);
    defer alloc.free(enc);
    // Header + a single EOF byte (empty quadtrees, no sign bits).
    try testing.expectEqual(@as(usize, header_len + 1), enc.len);
    const got = try roundTrip(alloc, &data, nx, ny, 0);
    defer alloc.free(got);
    try testing.expectEqualSlices(i32, &data, got);
}
