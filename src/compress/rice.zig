//! RICE_1 tile codec (CMP-4; FITS 4.0 §10.4.1, Table 37).
//!
//! Rice coding of the *first-difference* sequence of an integer tile, exactly as implemented by
//! CFITSIO's `fits_rcomp`/`fits_rdecomp` (`ricecomp.c`). The pixel stream is split into blocks of
//! `BLOCKSIZE` elements (default 32). Within a block:
//!
//!   1. each pixel is differenced against its predecessor (the first pixel of the whole tile is
//!      differenced against itself, so the very first difference is always zero),
//!   2. the signed difference is folded to a non-negative integer by the zig-zag map
//!      (`d>=0 → 2d`, `d<0 → 2|d|-1`),
//!   3. an optimal split count `FS` (the number of low "remainder" bits to emit verbatim) is
//!      chosen from the block's mean folded value, and
//!   4. each folded value `v` is emitted as `v>>FS` in unary (`v>>FS` zero bits then a `1`)
//!      followed by the `FS` low bits of `v`, all packed MSB-first.
//!
//! Two escapes share the per-block `FS` identifier field (`FSBITS` bits, written as `FS+1` so the
//! decoder can recover a sentinel): a *low-entropy* block whose differences are all zero writes
//! the identifier `0` and no payload; a *high-entropy* block (`FS >= FSMAX`) writes the identifier
//! `FSMAX+1` and then every folded value verbatim in `BBITS` (= element-width) bits, sidestepping
//! Rice coding entirely. The per-width tuning constants match CFITSIO:
//!
//!   | BYTEPIX | element | FSBITS | FSMAX | BBITS |
//!   |    1    |   i8    |   3    |   6   |   8   |
//!   |    2    |  i16    |   4    |  14   |  16   |
//!   |    4    |  i32    |   5    |  25   |  32   |
//!
//! The tile header is the first pixel written big-endian in `BYTEPIX` bytes; the bit stream
//! follows, MSB-first, zero-padded to a byte boundary at the end.
//!
//! This module is integer-only and codec-pure: `compress` takes (and `decompress` returns)
//! `nelem * BYTEPIX` **native-endian** element bytes — the caller (`compress/tiled.zig`) owns the
//! big-endian↔native translation, BLANK/scaling and dither. A non-integer / unsupported `BYTEPIX`
//! or a misaligned input is `error.DataConstraintViolated`; a truncated or garbled stream is
//! `error.CorruptTile` (never a panic; NFR-SAFE-1).
//!
//! X-FIXTURES: byte-exact parity against a committed CFITSIO RICE_1 tile is not asserted here
//! (it needs CFITSIO to produce the reference); the packing and `FS` selection mirror
//! `fits_rcomp` so that such a fixture can be added later without changing the wire format.
const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const native_endian = builtin.cpu.arch.endian();

/// Errors surfaced by the RICE_1 codec. `DataConstraintViolated` flags an unsupported/misaligned
/// request (caller bug); `CorruptTile` flags a malformed compressed stream; `OutOfMemory` comes
/// from the allocator.
pub const RiceError = error{ DataConstraintViolated, CorruptTile, OutOfMemory };

/// Decode a RICE_1 tile of `nelem` elements of `bytepix` (∈ {1,2,4}) bytes each, coded with the
/// given `blocksize`. Returns `nelem * bytepix` native-endian element bytes (caller owns).
/// `bytepix` not in {1,2,4} or `blocksize == 0` is `error.DataConstraintViolated`; a truncated or
/// malformed stream is `error.CorruptTile`.
pub fn decompress(alloc: Allocator, src: []const u8, nelem: usize, bytepix: u8, blocksize: u32) RiceError![]u8 {
    if (blocksize == 0) return error.DataConstraintViolated;
    return switch (bytepix) {
        1 => decompressTyped(i8, alloc, src, nelem, blocksize),
        2 => decompressTyped(i16, alloc, src, nelem, blocksize),
        4 => decompressTyped(i32, alloc, src, nelem, blocksize),
        else => error.DataConstraintViolated,
    };
}

/// Encode `data` (= `nelem * bytepix` native-endian element bytes) as a RICE_1 stream with the
/// given `blocksize`. Returns the compressed bytes (caller owns). `bytepix` not in {1,2,4},
/// `blocksize == 0`, or a `data.len` not a multiple of `bytepix` is `error.DataConstraintViolated`.
pub fn compress(alloc: Allocator, data: []const u8, bytepix: u8, blocksize: u32) RiceError![]u8 {
    if (blocksize == 0) return error.DataConstraintViolated;
    return switch (bytepix) {
        1 => compressTyped(i8, alloc, data, blocksize),
        2 => compressTyped(i16, alloc, data, blocksize),
        4 => compressTyped(i32, alloc, data, blocksize),
        else => error.DataConstraintViolated,
    };
}

// ── per-width tuning constants (CFITSIO ricecomp.c) ──────────────────────────────────────────

const Tuning = struct { fsbits: u6, fsmax: u32, bbits: u6 };

fn tuning(comptime W: usize) Tuning {
    return switch (W) {
        1 => .{ .fsbits = 3, .fsmax = 6, .bbits = 8 },
        2 => .{ .fsbits = 4, .fsmax = 14, .bbits = 16 },
        4 => .{ .fsbits = 5, .fsmax = 25, .bbits = 32 },
        else => @compileError("rice: unsupported element width"),
    };
}

fn Unsigned(comptime T: type) type {
    return @Int(.unsigned, @bitSizeOf(T));
}

// Zig-zag fold: signed `d` → non-negative `2d` (d≥0) / `2|d|-1` (d<0), all in W-bit wrap arithmetic.
fn zigzag(comptime T: type, d: T) Unsigned(T) {
    const U = Unsigned(T);
    const W = @bitSizeOf(T);
    const u: U = @bitCast(d);
    const sign: U = @bitCast(d >> (W - 1)); // arithmetic shift → all-ones for negatives, else 0
    return (u << 1) ^ sign;
}

// Inverse of `zigzag`.
fn unzigzag(comptime T: type, v: Unsigned(T)) T {
    const U = Unsigned(T);
    const delta: U = (v >> 1) ^ (@as(U, 0) -% (v & 1));
    return @bitCast(delta);
}

// ── MSB-first bit I/O ────────────────────────────────────────────────────────────────────────

// Packs bits MSB-first into a growable byte list. `acc` holds the not-yet-flushed low bits;
// `nbits` counts them (always < 8 between calls). Each `putBits` may push at most 32 new bits.
const BitWriter = struct {
    list: *std.ArrayList(u8),
    alloc: Allocator,
    acc: u64 = 0,
    nbits: u6 = 0,

    fn putBits(self: *BitWriter, value: u64, n: u6) RiceError!void {
        if (n == 0) return;
        const mask = (@as(u64, 1) << n) - 1;
        self.acc = (self.acc << n) | (value & mask);
        self.nbits += n;
        while (self.nbits >= 8) {
            self.nbits -= 8;
            try self.list.append(self.alloc, @truncate(self.acc >> self.nbits));
        }
    }

    // Emit `top` zero bits followed by a single 1 bit (the unary part of a Rice code), in 32-bit
    // chunks so an arbitrarily large `top` cannot overflow a single `putBits`.
    fn putUnary(self: *BitWriter, top: u64) RiceError!void {
        var rem = top;
        while (rem >= 32) : (rem -= 32) try self.putBits(0, 32);
        try self.putBits(1, @intCast(rem + 1));
    }

    // Zero-pad to the next byte boundary and flush.
    fn flush(self: *BitWriter) RiceError!void {
        if (self.nbits != 0) try self.putBits(0, @intCast(8 - @as(u8, self.nbits)));
    }
};

// Reads bits MSB-first from a fixed buffer. Running past the end is `error.CorruptTile`.
const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    acc: u64 = 0,
    nbits: u6 = 0,

    fn getBits(self: *BitReader, n: u6) RiceError!u64 {
        if (n == 0) return 0;
        while (self.nbits < n) {
            if (self.pos >= self.data.len) return error.CorruptTile;
            self.acc = (self.acc << 8) | self.data[self.pos];
            self.pos += 1;
            self.nbits += 8;
        }
        self.nbits -= n;
        const mask = (@as(u64, 1) << n) - 1;
        return (self.acc >> self.nbits) & mask;
    }

    // Count leading zero bits up to (and consuming) the terminating 1 bit.
    fn getUnary(self: *BitReader) RiceError!u64 {
        var count: u64 = 0;
        while ((try self.getBits(1)) == 0) count += 1;
        return count;
    }
};

// ── typed compress / decompress ──────────────────────────────────────────────────────────────

fn compressTyped(comptime T: type, alloc: Allocator, data: []const u8, blocksize: u32) RiceError![]u8 {
    const W = @sizeOf(T);
    const U = Unsigned(T);
    const cfg = comptime tuning(W);
    if (data.len % W != 0) return error.DataConstraintViolated;
    const nelem = data.len / W;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (nelem == 0) return out.toOwnedSlice(alloc);

    const bs: usize = @intCast(blocksize);
    const diff = try alloc.alloc(U, @min(bs, nelem));
    defer alloc.free(diff);

    var bw = BitWriter{ .list = &out, .alloc = alloc };

    // Tile header: first pixel verbatim, big-endian in W bytes; seed `last` with it.
    var last: T = std.mem.readInt(T, data[0..W], native_endian);
    try bw.putBits(@as(U, @bitCast(last)), @intCast(W * 8));

    var i: usize = 0;
    while (i < nelem) {
        const thisblock = @min(bs, nelem - i);

        // Fold differences and accumulate the block sum.
        var pixelsum: u64 = 0;
        for (0..thisblock) |j| {
            const next = std.mem.readInt(T, data[(i + j) * W ..][0..W], native_endian);
            const v = zigzag(T, next -% last);
            last = next;
            diff[j] = v;
            pixelsum += v;
        }

        // Optimal split: FS = bit length of floor((sum - block/2 - 1)/block) >> 1 (CFITSIO).
        const half: u64 = thisblock / 2;
        var dpsum: u64 = 0;
        if (pixelsum > half) dpsum = (pixelsum - half - 1) / @as(u64, thisblock);
        var psum: u64 = dpsum >> 1;
        var fs: u32 = 0;
        while (psum > 0) : (fs += 1) psum >>= 1;

        if (fs >= cfg.fsmax) {
            // High-entropy escape: identifier FSMAX+1, then every value verbatim in BBITS bits.
            try bw.putBits(cfg.fsmax + 1, cfg.fsbits);
            for (0..thisblock) |j| try bw.putBits(diff[j], cfg.bbits);
        } else if (fs == 0 and pixelsum == 0) {
            // Low-entropy escape: identifier 0, no payload (whole block equals its predecessor).
            try bw.putBits(0, cfg.fsbits);
        } else {
            // Normal Rice coding: identifier FS+1, then unary high part + FS low bits per value.
            const fsw: u6 = @intCast(fs);
            const fsmask = (@as(u64, 1) << fsw) - 1;
            try bw.putBits(fs + 1, cfg.fsbits);
            for (0..thisblock) |j| {
                const v: u64 = diff[j];
                try bw.putUnary(v >> fsw);
                try bw.putBits(v & fsmask, fsw);
            }
        }

        i += thisblock;
    }

    try bw.flush();
    return out.toOwnedSlice(alloc);
}

fn decompressTyped(comptime T: type, alloc: Allocator, src: []const u8, nelem: usize, blocksize: u32) RiceError![]u8 {
    const W = @sizeOf(T);
    const U = Unsigned(T);
    const cfg = comptime tuning(W);

    const out = try alloc.alloc(u8, nelem * W);
    errdefer alloc.free(out);
    if (nelem == 0) return out;

    var br = BitReader{ .data = src };

    // Tile header: first pixel, big-endian in W bytes.
    var last: T = @bitCast(@as(U, @truncate(try br.getBits(@intCast(W * 8)))));

    const bs: usize = @intCast(blocksize);
    var i: usize = 0;
    while (i < nelem) {
        const thisblock = @min(bs, nelem - i);
        const code = try br.getBits(cfg.fsbits);
        const fs: i64 = @as(i64, @intCast(code)) - 1;

        if (fs < 0) {
            // Low-entropy block: every pixel equals its predecessor.
            for (0..thisblock) |j| std.mem.writeInt(T, out[(i + j) * W ..][0..W], last, native_endian);
        } else if (fs == cfg.fsmax) {
            // High-entropy block: each value coded verbatim in BBITS bits.
            for (0..thisblock) |j| {
                const v: U = @truncate(try br.getBits(cfg.bbits));
                last +%= unzigzag(T, v);
                std.mem.writeInt(T, out[(i + j) * W ..][0..W], last, native_endian);
            }
        } else {
            const fsw: u6 = @intCast(fs);
            for (0..thisblock) |j| {
                const top = try br.getUnary();
                const low = try br.getBits(fsw);
                const v: U = @truncate((top << fsw) | low);
                last +%= unzigzag(T, v);
                std.mem.writeInt(T, out[(i + j) * W ..][0..W], last, native_endian);
            }
        }

        i += thisblock;
    }

    return out;
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

// Pack a slice of native ints into the native-endian byte buffer the codec consumes/produces.
fn pack(comptime T: type, alloc: Allocator, vals: []const T) ![]u8 {
    const W = @sizeOf(T);
    const buf = try alloc.alloc(u8, vals.len * W);
    for (vals, 0..) |v, k| std.mem.writeInt(T, buf[k * W ..][0..W], v, native_endian);
    return buf;
}

// Compress then decompress `vals` at `blocksize` and assert byte-exact recovery.
fn roundtrip(comptime T: type, vals: []const T, blocksize: u32) !void {
    const alloc = testing.allocator;
    const W = @sizeOf(T);
    const raw = try pack(T, alloc, vals);
    defer alloc.free(raw);

    const enc = try compress(alloc, raw, W, blocksize);
    defer alloc.free(enc);

    const dec = try decompress(alloc, enc, vals.len, W, blocksize);
    defer alloc.free(dec);

    try testing.expectEqualSlices(u8, raw, dec);
}

test "round-trip i8 across patterns and blocksizes" {
    inline for (.{ 16, 32 }) |bs| {
        try roundtrip(i8, &.{42}, bs); // single element
        try roundtrip(i8, &@as([100]i8, @splat(5)), bs); // constant
        var ramp: [200]i8 = undefined;
        for (&ramp, 0..) |*p, k| p.* = @truncate(@as(i32, @intCast(k)) - 100);
        try roundtrip(i8, &ramp, bs); // ramp
        var alt: [200]i8 = undefined;
        for (&alt, 0..) |*p, k| p.* = if (k % 2 == 0) std.math.minInt(i8) else std.math.maxInt(i8);
        try roundtrip(i8, &alt, bs); // alternating extremes
        var rnd: [257]i8 = undefined;
        var s: u32 = 0x1234567;
        for (&rnd) |*p| {
            s = s *% 1103515245 +% 12345;
            p.* = @truncate(@as(i32, @bitCast(s >> 16)));
        }
        try roundtrip(i8, &rnd, bs); // pseudo-random
    }
}

test "round-trip i16 across patterns and blocksizes" {
    inline for (.{ 16, 32 }) |bs| {
        try roundtrip(i16, &.{-12345}, bs);
        try roundtrip(i16, &@as([100]i16, @splat(1000)), bs);
        var ramp: [300]i16 = undefined;
        for (&ramp, 0..) |*p, k| p.* = @truncate(@as(i32, @intCast(k)) * 37 - 5000);
        try roundtrip(i16, &ramp, bs);
        var alt: [300]i16 = undefined;
        for (&alt, 0..) |*p, k| p.* = if (k % 2 == 0) std.math.minInt(i16) else std.math.maxInt(i16);
        try roundtrip(i16, &alt, bs);
        var rnd: [301]i16 = undefined;
        var s: u32 = 0xC0FFEE;
        for (&rnd) |*p| {
            s = s *% 1103515245 +% 12345;
            p.* = @truncate(@as(i32, @bitCast(s >> 8)));
        }
        try roundtrip(i16, &rnd, bs);
    }
}

test "round-trip i32 across patterns and blocksizes" {
    inline for (.{ 16, 32 }) |bs| {
        try roundtrip(i32, &.{-2000000000}, bs);
        try roundtrip(i32, &@as([100]i32, @splat(123456)), bs);
        var ramp: [300]i32 = undefined;
        for (&ramp, 0..) |*p, k| p.* = @as(i32, @intCast(k)) * 100003 - 1000000;
        try roundtrip(i32, &ramp, bs);
        var alt: [300]i32 = undefined;
        for (&alt, 0..) |*p, k| p.* = if (k % 2 == 0) std.math.minInt(i32) else std.math.maxInt(i32);
        try roundtrip(i32, &alt, bs);
        var rnd: [301]i32 = undefined;
        var s: u64 = 0xDEADBEEFCAFE;
        for (&rnd) |*p| {
            s = s *% 6364136223846793005 +% 1442695040888963407;
            p.* = @bitCast(@as(u32, @truncate(s >> 24)));
        }
        try roundtrip(i32, &rnd, bs);
    }
}

test "empty tile round-trips to empty" {
    const alloc = testing.allocator;
    const enc = try compress(alloc, &.{}, 4, 32);
    defer alloc.free(enc);
    const dec = try decompress(alloc, enc, 0, 4, 32);
    defer alloc.free(dec);
    try testing.expectEqual(@as(usize, 0), dec.len);
}

test "constant tile compresses far below raw size" {
    const alloc = testing.allocator;
    const raw = try pack(i32, alloc, &@as([1000]i32, @splat(7)));
    defer alloc.free(raw);
    const enc = try compress(alloc, raw, 4, 32);
    defer alloc.free(enc);
    try testing.expect(enc.len < raw.len / 4);
}

test "unsupported bytepix is DataConstraintViolated" {
    const alloc = testing.allocator;
    try testing.expectError(error.DataConstraintViolated, compress(alloc, "abc", 3, 32));
    try testing.expectError(error.DataConstraintViolated, decompress(alloc, "abc", 1, 3, 32));
    try testing.expectError(error.DataConstraintViolated, compress(alloc, "ab", 0, 32));
}

test "zero blocksize is DataConstraintViolated" {
    const alloc = testing.allocator;
    try testing.expectError(error.DataConstraintViolated, compress(alloc, "ab", 2, 0));
    try testing.expectError(error.DataConstraintViolated, decompress(alloc, "ab", 1, 2, 0));
}

test "misaligned input length is DataConstraintViolated" {
    const alloc = testing.allocator;
    try testing.expectError(error.DataConstraintViolated, compress(alloc, "abcde", 2, 32));
}

test "truncated streams fail with CorruptTile, never panic" {
    const alloc = testing.allocator;
    var ramp: [100]i32 = undefined;
    for (&ramp, 0..) |*p, k| p.* = @as(i32, @intCast(k)) * 99991;
    const raw = try pack(i32, alloc, &ramp);
    defer alloc.free(raw);
    const enc = try compress(alloc, raw, 4, 32);
    defer alloc.free(enc);

    // Header itself truncated (< 4 bytes available).
    try testing.expectError(error.CorruptTile, decompress(alloc, enc[0..2], ramp.len, 4, 32));
    // Header present but body cut off mid-stream.
    try testing.expectError(error.CorruptTile, decompress(alloc, enc[0..5], ramp.len, 4, 32));
    // Completely empty input with a non-empty request.
    try testing.expectError(error.CorruptTile, decompress(alloc, &.{}, 4, 4, 32));
}

test "zig-zag fold is a bijection round-trip at the extremes" {
    inline for (.{ i8, i16, i32 }) |T| {
        for ([_]T{ 0, 1, -1, std.math.minInt(T), std.math.maxInt(T) }) |d| {
            try testing.expectEqual(d, unzigzag(T, zigzag(T, d)));
        }
    }
}
