//! Subtractive dithering and the FITS random-number generator (`CMP-7`; design §17.2;
//! FITS 4.0 §10.2/§10.2.1, Appendix I).
//!
//! Lossy floating-point tile compression quantizes each pixel to an integer with a per-tile
//! linear map `physical = ZZERO + ZSCALE × stored` (§10.2). Plain rounding biases the
//! reconstructed image wherever many neighbouring pixels share a value (it pushes them all the
//! same way), so the convention optionally *dithers*: before rounding, a pseudo-random number
//! `r ∈ [0,1)` is added and `0.5` subtracted, and on read it is undone. This spreads the
//! rounding error into white noise and removes the bias. Two methods exist — `SUBTRACTIVE_DITHER_1`
//! and `SUBTRACTIVE_DITHER_2` (the latter additionally preserves exact `0.0` pixels, §10.2.1).
//!
//! To be reproducible on any machine, the convention fixes the dither values: a global table of
//! 10000 numbers produced by the Park–Miller "minimal standard" PRNG (`a = 16807`,
//! `m = 2^31 − 1`, seed `1`), evaluated with Schrage's method so the multiply never overflows
//! (Appendix I). Each tile draws from this table starting at an offset derived from `ZDITHER0`
//! and the tile's row index (§10.2), so the same tile always sees the same dither sequence.
//!
//! Special pixels (§10.2.1): a NaN/undefined float is stored as the reserved integer
//! `null_value` (= `−(2^31−1)`) and is excluded from the dither math (NaN ↔ null); under
//! `SUBTRACTIVE_DITHER_2` an exact `0.0` is stored as the reserved `zero_value` and read back as
//! `0.0` (so a true zero is never perturbed into a small non-zero). The bottom `reserved_count`
//! integers are never emitted for an ordinary pixel.
//!
//! This module is codec-agnostic: it produces/consumes the *quantized integers*; the surrounding
//! tiled codec (`compress/tiled.zig`) packs them and applies the underlying compressor.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// Number of entries in the global random-number table (FITS 4.0 Appendix I).
pub const random_count: usize = 10_000;

/// Reserved integer that represents an undefined / NaN floating-point pixel (`= −(2^31−1)`,
/// FITS 4.0 §10.2.1). Excluded from the dither math; reads back as NaN.
pub const null_value: i32 = -2147483647;

/// Reserved integer that `SUBTRACTIVE_DITHER_2` uses to represent an exact `0.0` pixel
/// (`= −(2^31−2)`, FITS 4.0 §10.2.1). Reads back as exactly `0.0`.
pub const zero_value: i32 = -2147483646;

/// How many integers at the bottom of the `i32` range are reserved (starting at `null_value`)
/// and therefore never produced for an ordinary pixel (FITS 4.0 §10.2.1). Includes both
/// `null_value` and `zero_value`.
pub const reserved_count: i32 = 10;

// Park–Miller minimal-standard constants and Schrage decomposition (Appendix I).
const pm_a: i64 = 16807; // multiplier
const pm_m: i64 = 2147483647; // modulus, 2^31 − 1
const pm_q: i64 = @divTrunc(pm_m, pm_a); // 127773
const pm_r: i64 = @rem(pm_m, pm_a); // 2836

/// The floating-point dither method named by `ZQUANTIZ` (FITS 4.0 §10.2).
pub const DitherKind = enum {
    /// `NO_DITHER` (or absent): quantize by plain rounding, no random perturbation.
    none,
    /// `SUBTRACTIVE_DITHER_1`: add `r − 0.5` before rounding and undo on read.
    subtractive_1,
    /// `SUBTRACTIVE_DITHER_2`: as `subtractive_1`, but exact `0.0` pixels are preserved
    /// losslessly via `zero_value` (§10.2.1).
    subtractive_2,

    /// Map a `ZQUANTIZ` string (case-insensitive, blank-trimmed) to a `DitherKind`. Returns
    /// `null` for an unrecognized value so the caller can report it precisely rather than
    /// silently treating it as `none`.
    pub fn fromName(s_in: []const u8) ?DitherKind {
        const s = std.mem.trim(u8, s_in, " ");
        if (std.ascii.eqlIgnoreCase(s, "NO_DITHER")) return .none;
        if (std.ascii.eqlIgnoreCase(s, "SUBTRACTIVE_DITHER_1")) return .subtractive_1;
        if (std.ascii.eqlIgnoreCase(s, "SUBTRACTIVE_DITHER_2")) return .subtractive_2;
        return null;
    }
};

/// Advance the Park–Miller generator one step: returns `(pm_a × seed) mod pm_m` computed with
/// Schrage's method (exact, overflow-free for any `seed ∈ [1, pm_m−1]`). The result is again in
/// `[1, pm_m−1]` so the sequence is a full-period permutation (Appendix I).
fn pmNext(seed: i64) i64 {
    const hi = @divTrunc(seed, pm_q);
    const lo = @rem(seed, pm_q);
    var t = pm_a * lo - pm_r * hi;
    if (t < 0) t += pm_m;
    return t;
}

/// Build the global 10000-entry random table (Appendix I): starting from seed `1`, draw 10000
/// Park–Miller values and store `seed / pm_m` (a number in `[0,1)`) for each. The drawn seeds
/// match the canonical sequence whose 10000th value is `1043618065`. Caller owns the slice.
pub fn fitsRandom(alloc: Allocator) Allocator.Error![]f32 {
    const out = try alloc.alloc(f32, random_count);
    errdefer alloc.free(out);
    const m_f: f64 = @floatFromInt(pm_m);
    var seed: i64 = 1;
    for (out) |*v| {
        seed = pmNext(seed);
        v.* = @floatCast(@as(f64, @floatFromInt(seed)) / m_f);
    }
    return out;
}

/// Whether `i` is one of the bottom `reserved_count` integers (§10.2.1) that must never be
/// emitted for an ordinary pixel.
fn isReserved(i: i32) bool {
    return i >= null_value and i < null_value + reserved_count;
}

/// Quantize one floating-point `value` to its stored integer under the per-tile linear map and a
/// single dither draw `r = dither_value ∈ [0,1)` (FITS 4.0 §10.2):
///
///   `stored = round((value − zzero) / zscale + r − 0.5)`.
///
/// A NaN `value` maps to `null_value` (§10.2.1). Results are saturated to the `i32` range and
/// nudged out of the reserved low band so an ordinary pixel never collides with a sentinel.
/// This is the *plain* helper; exact-zero preservation (`SUBTRACTIVE_DITHER_2`) is layered on by
/// `Dither.quantizeNext`.
pub fn quantize(value: f32, zscale: f64, zzero: f64, dither_value: f32) i32 {
    if (std.math.isNan(value)) return null_value;
    const x = (@as(f64, value) - zzero) / zscale + @as(f64, dither_value) - 0.5;
    const i = std.math.lossyCast(i32, std.math.round(x));
    if (isReserved(i)) return null_value + reserved_count;
    return i;
}

/// Reconstruct the floating-point value from its `stored` integer, the per-tile linear map, and
/// the matching dither draw `r = dither_value` (FITS 4.0 §10.2):
///
///   `value = (stored − r + 0.5) × zscale + zzero`.
///
/// `null_value` reads back as NaN (§10.2.1). This is the exact inverse of `quantize` to within
/// half a quantization step (`zscale/2`). Exact-zero handling for `SUBTRACTIVE_DITHER_2` is
/// layered on by `Dither.unquantizeNext`.
pub fn unquantize(stored: i32, zscale: f64, zzero: f64, dither_value: f32) f32 {
    if (stored == null_value) return std.math.nan(f32);
    const f = (@as(f64, @floatFromInt(stored)) - @as(f64, dither_value) + 0.5) * zscale + zzero;
    return @floatCast(f);
}

/// The per-tile starting index into the random table: `(tile_index + ZDITHER0 - 1) mod
/// random_count`, where `tile_index` is the 0-based tile/row number. `@mod` keeps the result in
/// `[0, random_count)` even for a negative sum.
///
/// The `- 1` matches CFITSIO/fpack/astropy — the de-facto standard every real dithered file is
/// written and read against — which seeds the table at `(irow - 1 + ZDITHER0 - 1) % N_RANDOM`
/// with `irow` 1-based (i.e. `irow - 1 == tile_index`). The FITS 4.0 standard's *literal* Eq. text
/// omits this offset; following it (as this code originally did) mis-decodes every
/// SUBTRACTIVE_DITHER file exchanged with the ecosystem by one table entry.
pub fn tileOffset(zdither0: i64, tile_index: u64) usize {
    const sum: i128 = @as(i128, @intCast(tile_index)) + zdither0 - 1;
    return @intCast(@mod(sum, @as(i128, random_count)));
}

/// A per-tile dithering cursor over the global random table (FITS 4.0 §10.2). Encode and decode
/// of the *same* tile must drive two `Dither`s initialized identically so they consume the same
/// dither sequence in lock-step.
///
/// The cursor mirrors the reference convention: the tile's outer index `iseed` is
/// `tileOffset(ZDITHER0, tile_index)`, and the first draw position within the table is
/// `floor(table[iseed] × 500)`. After every pixel the draw position advances by one; when it
/// reaches the end of the table it wraps and re-seeds from the next `iseed` entry. The draw
/// advances for *every* pixel — including NaN/zero specials — so both sides stay aligned.
pub const Dither = struct {
    /// The global random table (borrowed; produced by `fitsRandom`).
    table: []const f32,
    /// The dither method in effect for this tile.
    kind: DitherKind,
    /// Outer index into `table`, used to re-seed `draw` when it wraps.
    iseed: usize,
    /// Current draw position into `table` (the index of the next random value to use).
    draw: usize,

    /// Initialize the cursor for tile `tile_index` (0-based) given the header's `ZDITHER0`
    /// (`zdither0`). `table` must have `random_count` entries.
    pub fn init(table: []const f32, kind: DitherKind, zdither0: i64, tile_index: u64) Dither {
        std.debug.assert(table.len == random_count);
        const iseed = tileOffset(zdither0, tile_index);
        return .{
            .table = table,
            .kind = kind,
            .iseed = iseed,
            .draw = drawFrom(table, iseed),
        };
    }

    fn drawFrom(table: []const f32, iseed: usize) usize {
        // table[iseed] ∈ [0,1) ⇒ value ∈ [0,500) ⇒ index ∈ [0,499]; `@intFromFloat` truncates.
        return @intFromFloat(table[iseed] * 500.0);
    }

    /// The dither value for the current pixel.
    fn current(self: *const Dither) f32 {
        return self.table[self.draw];
    }

    /// Step the cursor to the next pixel's dither value (re-seeding on table wrap).
    fn advance(self: *Dither) void {
        self.draw += 1;
        if (self.draw == random_count) {
            self.iseed += 1;
            if (self.iseed == random_count) self.iseed = 0;
            self.draw = drawFrom(self.table, self.iseed);
        }
    }

    /// Quantize the next pixel, consuming one dither draw. Applies the §10.2.1 specials on top of
    /// `quantize`: NaN → `null_value`; under `subtractive_2`, exact `0.0` → `zero_value`. Under
    /// `none` the draw is still consumed but `r` is ignored (plain rounding).
    pub fn quantizeNext(self: *Dither, value: f32, zscale: f64, zzero: f64) i32 {
        const r = self.current();
        self.advance();
        if (std.math.isNan(value)) return null_value;
        if (self.kind == .subtractive_2 and value == 0.0) return zero_value;
        const dv: f32 = if (self.kind == .none) 0.5 else r; // none ⇒ r−0.5 term vanishes
        return quantize(value, zscale, zzero, dv);
    }

    /// Reconstruct the next pixel, consuming one dither draw. Applies the §10.2.1 specials on top
    /// of `unquantize`: `null_value` → `null_out` (pass NaN, or a `BLANK` substitute); under
    /// `subtractive_2`, `zero_value` → exactly `0.0`.
    pub fn unquantizeNext(self: *Dither, stored: i32, zscale: f64, zzero: f64, null_out: f32) f32 {
        const r = self.current();
        self.advance();
        if (stored == null_value) return null_out;
        if (self.kind == .subtractive_2 and stored == zero_value) return 0.0;
        const dv: f32 = if (self.kind == .none) 0.5 else r;
        return unquantize(stored, zscale, zzero, dv);
    }
};

// ── tests ────────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "Park–Miller generator reaches the Appendix I check value at 10000 draws" {
    var seed: i64 = 1;
    var i: usize = 0;
    while (i < random_count) : (i += 1) seed = pmNext(seed);
    try testing.expectEqual(@as(i64, 1043618065), seed);
}

test "fitsRandom yields 10000 values, all in [0,1), matching the drawn seeds" {
    const table = try fitsRandom(testing.allocator);
    defer testing.allocator.free(table);
    try testing.expectEqual(random_count, table.len);
    for (table) |v| {
        try testing.expect(v >= 0.0);
        try testing.expect(v < 1.0);
    }
    // The last stored value is the 10000th seed / m.
    const expect_last: f32 = @floatCast(1043618065.0 / 2147483647.0);
    try testing.expectApproxEqAbs(expect_last, table[random_count - 1], 1e-7);
}

test "quantize → unquantize reproduces the value within half a quantization step" {
    const combos = [_]struct { zscale: f64, zzero: f64 }{
        .{ .zscale = 1.0, .zzero = 0.0 },
        .{ .zscale = 0.25, .zzero = 100.0 },
        .{ .zscale = 12.5, .zzero = -3000.0 },
        .{ .zscale = 0.001, .zzero = 7.0 },
    };
    const values = [_]f32{ 0.0, 1.5, -2.7, 123.456, -9999.9, 42.0 };
    const dithers = [_]f32{ 0.0, 0.123, 0.5, 0.9999 };
    for (combos) |c| {
        for (values) |f| {
            for (dithers) |r| {
                const code = quantize(f, c.zscale, c.zzero, r);
                try testing.expect(!isReserved(code));
                const back = unquantize(code, c.zscale, c.zzero, r);
                const tol: f32 = @floatCast(c.zscale * 0.5 + @abs(c.zzero) * 1e-6 + 1e-4);
                try testing.expect(@abs(back - f) <= tol);
            }
        }
    }
}

test "NaN maps to the reserved null integer and back to NaN (§10.2.1)" {
    const nan = std.math.nan(f32);
    try testing.expectEqual(null_value, quantize(nan, 1.0, 0.0, 0.3));
    try testing.expect(std.math.isNan(unquantize(null_value, 1.0, 0.0, 0.3)));
}

test "quantize never emits a reserved sentinel for an ordinary pixel" {
    // Crafted so the linear map lands exactly on null_value; the guard must nudge it clear.
    const g = quantize(1.0, 1.0, 2147483648.0, 0.5);
    try testing.expect(!isReserved(g));
    try testing.expectEqual(null_value + reserved_count, g);
    // Sentinel classification.
    try testing.expect(isReserved(null_value));
    try testing.expect(isReserved(zero_value));
    try testing.expect(!isReserved(0));
    try testing.expect(!isReserved(null_value + reserved_count));
}

test "tileOffset is (tile_index + ZDITHER0 - 1) mod 10000 (CFITSIO convention), in range for huge indices" {
    // ZDITHER0=1 (the default) with the first tile seeds at table index 0, matching fpack.
    try testing.expectEqual(@as(usize, 0), tileOffset(1, 0)); // 0 + 1 - 1
    try testing.expectEqual(@as(usize, 3), tileOffset(5, 9999)); // 10003 mod 10000
    try testing.expectEqual(@as(usize, 9999), tileOffset(1, 9999)); // 9999 mod 10000
    // Negative / small sums still floor into range.
    try testing.expectEqual(@as(usize, 9998), tileOffset(-1, 0)); // -2 mod 10000
    // Large tile index never goes out of range.
    const big = tileOffset(7, std.math.maxInt(u64));
    try testing.expect(big < random_count);
}

test "SUBTRACTIVE_DITHER_2 round-trips, preserving NaN and exact zero (§10.2.1)" {
    const table = try fitsRandom(testing.allocator);
    defer testing.allocator.free(table);
    const nan = std.math.nan(f32);
    const zscale: f64 = 0.5;
    const zzero: f64 = 10.0;

    // Two identically-seeded cursors stay in lock-step (encode vs decode).
    var enc = Dither.init(table, .subtractive_2, 7, 3);
    var dec = Dither.init(table, .subtractive_2, 7, 3);
    const inputs = [_]f32{ 1.5, 0.0, nan, -2.3, 0.0, 42.0, 0.25 };
    for (inputs) |f| {
        const code = enc.quantizeNext(f, zscale, zzero);
        const back = dec.unquantizeNext(code, zscale, zzero, nan);
        if (std.math.isNan(f)) {
            try testing.expectEqual(null_value, code);
            try testing.expect(std.math.isNan(back));
        } else if (f == 0.0) {
            try testing.expectEqual(zero_value, code); // exact-zero preserved losslessly
            try testing.expectEqual(@as(f32, 0.0), back);
        } else {
            try testing.expect(!isReserved(code));
            const tol: f32 = @floatCast(zscale * 0.5 + 1e-4);
            try testing.expect(@abs(back - f) <= tol);
        }
    }
}

test "SUBTRACTIVE_DITHER_1 does not specially preserve zero" {
    const table = try fitsRandom(testing.allocator);
    defer testing.allocator.free(table);
    const zscale: f64 = 1.0;
    const zzero: f64 = 0.0;
    var enc = Dither.init(table, .subtractive_1, 100, 0);
    var dec = Dither.init(table, .subtractive_1, 100, 0);
    const code = enc.quantizeNext(0.0, zscale, zzero);
    try testing.expect(code != zero_value); // not the reserved sentinel
    const back = dec.unquantizeNext(code, zscale, zzero, std.math.nan(f32));
    try testing.expect(@abs(back - 0.0) <= zscale * 0.5 + 1e-4);
}

test "NO_DITHER uses plain rounding (dither term cancels)" {
    const table = try fitsRandom(testing.allocator);
    defer testing.allocator.free(table);
    var enc = Dither.init(table, .none, 1, 0);
    var dec = Dither.init(table, .none, 1, 0);
    // With kind=none, the result must equal plain rounding (dither_value = 0.5).
    const f: f32 = 3.49;
    const code = enc.quantizeNext(f, 1.0, 0.0);
    try testing.expectEqual(quantize(f, 1.0, 0.0, 0.5), code);
    const back = dec.unquantizeNext(code, 1.0, 0.0, std.math.nan(f32));
    try testing.expect(@abs(back - f) <= 0.5 + 1e-4);
}

test "Dither cursor wraps across the whole table without going out of bounds" {
    const table = try fitsRandom(testing.allocator);
    defer testing.allocator.free(table);
    var d = Dither.init(table, .subtractive_1, 9990, 0);
    // Drive well past one full table length to exercise the wrap/re-seed path.
    var i: usize = 0;
    while (i < random_count * 2 + 123) : (i += 1) {
        const code = d.quantizeNext(1.0, 1.0, 0.0);
        try testing.expect(!isReserved(code));
        try testing.expect(d.draw < random_count);
        try testing.expect(d.iseed < random_count);
    }
}
