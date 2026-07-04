//! Floating-point → scaled-integer quantization for tile compression — an exact port of
//! CFITSIO 4.6.4 `quantize.c` `fits_quantize_float` / `fits_quantize_double` plus the noise
//! estimators they drive (`FnNoise5_float/_double`, `FnNoise3_float/_double` in min/max mode,
//! `quick_select_float/_double`), generic over the pixel type (`f32`/`f64`).
//!
//! This is the WRITE-side machinery behind CFITSIO's `q` quantization parameter (`fpack -q`,
//! `fits_set_quantize_level`): a float tile is linearly mapped to 32-bit integers with
//! per-tile `ZSCALE`/`ZZERO`, optionally subtractive-dithered, and then handed to any integer
//! tile codec (RICE/HCOMPRESS/GZIP). The parity rules ported here (CFITSIO 4.6.4):
//!
//!   • `qlevel > 0`  → `delta = sigma / qlevel`, where sigma is the tile's background noise:
//!     `FnNoise5`'s noise3 estimate, replaced by a smaller non-zero noise2/noise5.
//!   • `qlevel == 0` → `delta = sigma / 4` (the CFITSIO/fpack default).
//!   • `qlevel < 0`  → `delta = -qlevel`, data-independent (absolute mode; only min/max are
//!     computed, via `FnNoise3` with the noise output disabled — whose *distinct* good-pixel
//!     counting rules are ported verbatim, since `ngood == n` selects the ZZERO branch).
//!   • ZZERO: with no nulls, `minval` *fudged to an exact integer multiple of delta*
//!     (`iqfactor`, so repeated fpack/funpack cycles re-derive the same scaling), unless the
//!     range needs centering (`(min+max)/2`) or `SUBTRACTIVE_DITHER_2` shifts it near the
//!     null sentinel; with nulls (NaN pixels), `minval − delta·(NULL_VALUE + 10)` so the
//!     stored values sit just above the reserved band.
//!   • Rounding is CFITSIO `NINT` — `(int)(x + 0.5)` / `(int)(x − 0.5)`, i.e. truncation
//!     after the half offset (NOT round-to-nearest-even, and NOT `std.math.round` at
//!     double-rounding knife edges) — and stored values are NOT nudged out of the §10.2.1
//!     reserved band (CFITSIO doesn't either; only the exact NULL/ZERO sentinels are special
//!     on read).
//!   • "Can't quantize" (a 0/1-pixel tile, zero noise, or a range wider than the i32 span)
//!     returns `.not_quantized`: the caller must store the tile losslessly as raw gzipped
//!     floats (CFITSIO's `GZIP_COMPRESSED_DATA` fallback).
//!
//! Null convention: a NaN pixel is the null (it maps to the reserved `NULL_VALUE` and is
//! skipped by the estimators). CFITSIO reaches the same result via a magic in-band value
//! (`FLOATNULLVALUE`) substituted for NaN when fpack reads the input; comparing `isNan`
//! directly is equivalent for real data and avoids the in-band collision hazard.
//!
//! ── Deliberate fail-safe divergence ───────────────────────────────────────────────────────
//! A tile containing ±Inf returns `.not_quantized` (stored losslessly). CFITSIO has no Inf
//! guard: an Inf pixel flows into its noise estimator and quantization arithmetic, where the
//! result is undefined-behavior casts over inf/NaN doubles — garbage stored values on real
//! builds. Storing the tile losslessly preserves the data instead; funpack/Astropy read such
//! fallback tiles exactly (it is the same mechanism CFITSIO itself uses for unquantizable
//! tiles). The `iqfactor` truncation also saturates (`lossyCast`) where the C's `(LONGLONG)`
//! cast of an out-of-range double is UB.
const std = @import("std");
const dither = @import("dither.zig");

const Allocator = std.mem.Allocator;

/// Successful quantization: the per-tile linear map (record as `ZSCALE`/`ZZERO`) and whether
/// any pixel was null (NaN → `NULL_VALUE`; the file then needs a `ZBLANK` card).
pub const Params = struct {
    /// `ZSCALE` — the quantization step (CFITSIO `bscale`/`delta`).
    bscale: f64,
    /// `ZZERO` — the offset (CFITSIO `bzero`/`zeropt`).
    bzero: f64,
    /// True when at least one pixel quantized to the reserved null sentinel.
    has_null: bool,
};

/// Outcome of `quantizeTile` — mirrors `fits_quantize_float`'s int return (1 = quantized,
/// 0 = store the tile losslessly instead).
pub const Result = union(enum) {
    /// `idata` was filled; record the params and compress the integers.
    quantized: Params,
    /// CFITSIO chose not to quantize this tile (tiny tile, zero noise, range overflow — or
    /// the fail-safe ±Inf guard): store it as raw gzipped floats (lossless fallback).
    not_quantized,
};

/// Quantize one float tile to 32-bit stored integers — CFITSIO 4.6.4 `fits_quantize_float`
/// (`T == f32`) / `fits_quantize_double` (`T == f64`), bit-exact including the noise-based
/// step selection, the `iqfactor` ZZERO fudge, `NINT` rounding, and the §10.2 dither draws.
///
/// `nxpix` is the tile's fastest-axis extent and `nypix` the collapsed count of the remaining
/// axes (CFITSIO `fits_calc_tile_rows`). `qlevel` follows `fits_set_quantize_level`: `> 0`
/// noise-based, `0` the default (`sigma/4`), `< 0` absolute. `method` selects the §10.2
/// dither: `.none` (NO_DITHER) quantizes by plain `NINT`; the subtractive kinds consume one
/// draw per pixel from `table` (the `fitsRandom` table, required then) seeded by
/// `(tile_index + zdither0 − 1) mod 10000`. `idata.len` must equal `fdata.len`.
pub fn quantizeTile(
    comptime T: type,
    alloc: Allocator,
    fdata: []const T,
    nxpix: usize,
    nypix: usize,
    qlevel: f32,
    method: dither.DitherKind,
    table: ?[]const f32,
    zdither0: i64,
    tile_index: u64,
    idata: []i32,
) Allocator.Error!Result {
    comptime std.debug.assert(T == f32 or T == f64);
    std.debug.assert(fdata.len == nxpix * nypix);
    std.debug.assert(idata.len == fdata.len);
    std.debug.assert(method == .none or table != null);

    const n = fdata.len;
    if (n <= 1) return .not_quantized;

    // Fail-safe divergence (see module doc): ±Inf would drive CFITSIO's estimator and NINT
    // casts into undefined behavior; store such tiles losslessly instead.
    for (fdata) |v| {
        if (std.math.isInf(v)) return .not_quantized;
    }

    var minval: T = undefined;
    var maxval: T = undefined;
    var ngood: usize = undefined;
    var delta: f64 = undefined;

    if (qlevel >= 0) {
        // Noise-based step: sigma from the MAD estimators over this tile.
        const est = try fnNoise5(T, alloc, fdata, nxpix, nypix);
        ngood = est.ngood;
        minval = est.minval;
        maxval = est.maxval;
        var stdev: f64 = undefined;
        if (ngood == 0) {
            // An all-null tile: dummy parameters (never used for a real pixel).
            minval = 0;
            maxval = 1;
            stdev = 1;
        } else {
            stdev = est.noise3;
            if (est.noise2 != 0 and est.noise2 < stdev) stdev = est.noise2;
            if (est.noise5 != 0 and est.noise5 < stdev) stdev = est.noise5;
        }
        delta = if (qlevel == 0) stdev / 4.0 else stdev / @as(f64, qlevel);
        if (delta == 0) return .not_quantized; // e.g. a constant tile — don't quantize
    } else {
        // Absolute step; only min/max/ngood are needed (FnNoise3 with noise disabled — its
        // counting quirks differ from FnNoise5's and are ported verbatim below).
        delta = -@as(f64, qlevel);
        const mm = fnNoise3MinMax(T, fdata, nxpix, nypix);
        ngood = mm.ngood;
        minval = mm.minval;
        maxval = mm.maxval;
    }

    // The whole range must fit the (dithered) i32 span less the reserved band.
    if (@as(f64, maxval - minval) / delta > 2.0 * 2147483647.0 - reserved_f) return .not_quantized;

    // ZZERO selection (see module doc). `null_shift == NULL_VALUE + N_RESERVED_VALUES`.
    const null_shift: f64 = @floatFromInt(dither.null_value + dither.reserved_count);
    var zeropt: f64 = undefined;
    if (ngood == n) {
        if (method == .subtractive_2) {
            zeropt = @as(f64, minval) - delta * null_shift;
        } else if (@as(f64, maxval - minval) / delta < 2147483647.0 - reserved_f) {
            zeropt = @as(f64, minval);
            // Fudge ZZERO to an exact integer multiple of delta (truncating cast, as the C's
            // `(LONGLONG)`; saturating where the C would be UB).
            const iqfactor = std.math.lossyCast(i64, zeropt / delta + 0.5);
            zeropt = @as(f64, @floatFromInt(iqfactor)) * delta;
        } else {
            zeropt = @as(f64, minval + maxval) / 2.0;
        }
    } else {
        // Nulls present: shift the range so stored values sit just above the reserved band.
        zeropt = @as(f64, minval) - delta * null_shift;
    }
    if (!std.math.isFinite(delta) or !std.math.isFinite(zeropt)) return .not_quantized;

    var has_null = false;
    if (method != .none) {
        // Subtractive dither: one draw per pixel — including null/zero specials — so encoder
        // and decoder stay in lock-step (§10.2). Same cursor convention as `dither.Dither`.
        const tbl = table.?;
        var iseed = dither.tileOffset(zdither0, tile_index);
        var nextrand: usize = @intFromFloat(tbl[iseed] * 500.0);
        for (fdata, idata) |v, *o| {
            if (std.math.isNan(v)) {
                has_null = true;
                o.* = dither.null_value;
            } else if (method == .subtractive_2 and v == 0.0) {
                o.* = dither.zero_value;
            } else {
                o.* = nint((@as(f64, v) - zeropt) / delta + @as(f64, tbl[nextrand]) - 0.5);
            }
            nextrand += 1;
            if (nextrand == dither.random_count) {
                iseed += 1;
                if (iseed == dither.random_count) iseed = 0;
                nextrand = @intFromFloat(tbl[iseed] * 500.0);
            }
        }
    } else {
        // NO_DITHER: plain NINT quantization.
        for (fdata, idata) |v, *o| {
            if (std.math.isNan(v)) {
                has_null = true;
                o.* = dither.null_value;
            } else {
                o.* = nint((@as(f64, v) - zeropt) / delta);
            }
        }
    }

    return .{ .quantized = .{ .bscale = delta, .bzero = zeropt, .has_null = has_null } };
}

const reserved_f: f64 = @floatFromInt(dither.reserved_count); // N_RESERVED_VALUES as a double

/// CFITSIO `NINT`: `(int)(x + 0.5)` for `x ≥ 0`, `(int)(x − 0.5)` otherwise — truncation
/// after the half offset. Kept verbatim (NOT `std.math.round`): the two differ when `x ± 0.5`
/// rounds across an integer in double precision. Saturates where the C cast would be UB.
inline fn nint(x: f64) i32 {
    const y = if (x >= 0.0) x + 0.5 else x - 0.5;
    return std.math.lossyCast(i32, y);
}

// ── FnNoise5 (float/double): MAD background-noise estimates + min/max/ngood ────────────────

fn Noise5(comptime T: type) type {
    return struct {
        ngood: usize,
        minval: T,
        maxval: T,
        noise2: f64,
        noise3: f64,
        noise5: f64,
    };
}

/// CFITSIO `FnNoise5_float`/`FnNoise5_double` with NaN as the null. Row-median MAD noise
/// estimates (2nd/3rd/5th order) plus min/max and the good-pixel count. All difference
/// arithmetic is in `T` (the C computes float diffs for the float variant, double for the
/// double variant); row medians and the final calibration are in f64, exactly as the C.
/// The `differences2`-selected-over-`nvals` quirk and the never-cleared scratch reuse are
/// ported verbatim from the C (see `imgstats.zig` for the same quirk on the int variant).
fn fnNoise5(comptime T: type, alloc: Allocator, array: []const T, nx_in: usize, ny_in: usize) Allocator.Error!Noise5(T) {
    var nx = nx_in;
    var ny = ny_in;
    if (nx < 9) {
        // Treat the entire array as an image with a single row.
        nx = nx * ny;
        ny = 1;
    }

    var xminval: T = std.math.floatMax(T);
    var xmaxval: T = -std.math.floatMax(T);
    var ngoodpix: usize = 0;

    if (nx < 9) {
        for (array) |v| {
            if (std.math.isNan(v)) continue;
            if (v < xminval) xminval = v;
            if (v > xmaxval) xmaxval = v;
            ngoodpix += 1;
        }
        return .{ .ngood = ngoodpix, .minval = xminval, .maxval = xmaxval, .noise2 = 0, .noise3 = 0, .noise5 = 0 };
    }

    // Scratch: zero-filled ONCE and reused across rows without clearing (the C callocs once;
    // the noise2 selection can read stale entries from earlier rows — quirk parity).
    const differences2 = try alloc.alloc(T, nx);
    defer alloc.free(differences2);
    const differences3 = try alloc.alloc(T, nx);
    defer alloc.free(differences3);
    const differences5 = try alloc.alloc(T, nx);
    defer alloc.free(differences5);
    @memset(differences2, 0);
    @memset(differences3, 0);
    @memset(differences5, 0);

    const diffs2 = try alloc.alloc(f64, ny);
    defer alloc.free(diffs2);
    const diffs3 = try alloc.alloc(f64, ny);
    defer alloc.free(diffs3);
    const diffs5 = try alloc.alloc(f64, ny);
    defer alloc.free(diffs5);

    var nrows: usize = 0;
    var nrows2: usize = 0;

    var jj: usize = 0;
    row_loop: while (jj < ny) : (jj += 1) {
        const rowpix = array[jj * nx ..][0..nx];

        // The 9-wide sliding window over GOOD (non-NaN) pixels: find v1..v8, counting each.
        var window: [8]T = undefined;
        var ii: usize = 0;
        for (&window) |*v| {
            while (ii < nx and std.math.isNan(rowpix[ii])) ii += 1;
            if (ii == nx) continue :row_loop; // hit end of row
            v.* = rowpix[ii];
            ngoodpix += 1;
            if (v.* < xminval) xminval = v.*;
            if (v.* > xmaxval) xmaxval = v.*;
            ii += 1;
        }
        var v1 = window[0];
        var v2 = window[1];
        var v3 = window[2];
        var v4 = window[3];
        var v5 = window[4];
        var v6 = window[5];
        var v7 = window[6];
        var v8 = window[7];

        var nvals: usize = 0;
        var nvals2: usize = 0;
        while (ii < nx) : (ii += 1) {
            while (ii < nx and std.math.isNan(rowpix[ii])) ii += 1;
            if (ii == nx) break;
            const v9 = rowpix[ii];
            if (v9 < xminval) xminval = v9;
            if (v9 > xmaxval) xmaxval = v9;

            if (!(v5 == v6 and v6 == v7)) {
                differences2[nvals2] = @abs(v5 - v7);
                nvals2 += 1;
            }
            if (!(v3 == v4 and v4 == v5 and v5 == v6 and v6 == v7)) {
                differences3[nvals] = @abs((2 * v5) - v3 - v7);
                differences5[nvals] = @abs((6 * v5) - (4 * v3) - (4 * v7) + v1 + v9);
                nvals += 1;
            } else {
                ngoodpix += 1; // constant background region, ignored for the medians
            }

            v1 = v2;
            v2 = v3;
            v3 = v4;
            v4 = v5;
            v5 = v6;
            v6 = v7;
            v7 = v8;
            v8 = v9;
        }

        ngoodpix += nvals;
        if (nvals == 0) {
            continue; // cannot compute medians on this row (nrows NOT incremented)
        } else if (nvals == 1) {
            if (nvals2 == 1) {
                diffs2[nrows2] = @as(f64, differences2[0]);
                nrows2 += 1;
            }
            diffs3[nrows] = @as(f64, differences3[0]);
            diffs5[nrows] = @as(f64, differences5[0]);
        } else {
            if (nvals2 > 1) {
                // CFITSIO quirk: selected over nvals (NOT nvals2) entries — kept verbatim.
                diffs2[nrows2] = @as(f64, quickSelect(T, differences2[0..nvals]));
                nrows2 += 1;
            }
            diffs3[nrows] = @as(f64, quickSelect(T, differences3[0..nvals]));
            diffs5[nrows] = @as(f64, quickSelect(T, differences5[0..nvals]));
        }
        nrows += 1;
    }

    // Median of the per-row values: 0 / single / sorted mean-of-middles.
    var xnoise2: f64 = 0;
    var xnoise3: f64 = 0;
    var xnoise5: f64 = 0;
    if (nrows == 1) {
        xnoise3 = diffs3[0];
        xnoise5 = diffs5[0];
    } else if (nrows > 1) {
        std.mem.sort(f64, diffs3[0..nrows], {}, std.sort.asc(f64));
        std.mem.sort(f64, diffs5[0..nrows], {}, std.sort.asc(f64));
        xnoise3 = (diffs3[(nrows - 1) / 2] + diffs3[nrows / 2]) / 2.0;
        xnoise5 = (diffs5[(nrows - 1) / 2] + diffs5[nrows / 2]) / 2.0;
    }
    if (nrows2 == 1) {
        xnoise2 = diffs2[0];
    } else if (nrows2 > 1) {
        std.mem.sort(f64, diffs2[0..nrows2], {}, std.sort.asc(f64));
        xnoise2 = (diffs2[(nrows2 - 1) / 2] + diffs2[nrows2 / 2]) / 2.0;
    }

    return .{
        .ngood = ngoodpix,
        .minval = xminval,
        .maxval = xmaxval,
        .noise2 = 1.0483579 * xnoise2,
        .noise3 = 0.6052697 * xnoise3,
        .noise5 = 0.1772048 * xnoise5,
    };
}

// ── FnNoise3 (min/max mode): the absolute-quantization path's range scan ───────────────────

fn MinMax(comptime T: type) type {
    return struct { ngood: usize, minval: T, maxval: T };
}

/// CFITSIO `FnNoise3_float`/`FnNoise3_double` called with the noise output DISABLED — the only
/// form the quantizer uses (`qlevel < 0`). Its good-pixel counting differs from `FnNoise5`'s
/// and is ported verbatim because `ngood == n` selects the ZZERO branch: pixels are counted
/// per row as (pixels beyond the 4th) + 4, and a row that ends before its 4th good pixel
/// contributes NOTHING (its 1–3 found pixels are never counted). Min/max still see every
/// good pixel, including those in early-terminated rows.
fn fnNoise3MinMax(comptime T: type, array: []const T, nx_in: usize, ny_in: usize) MinMax(T) {
    var nx = nx_in;
    var ny = ny_in;
    if (nx < 5) {
        nx = nx * ny;
        ny = 1;
    }

    var xminval: T = std.math.floatMax(T);
    var xmaxval: T = -std.math.floatMax(T);
    var ngoodpix: usize = 0;

    if (nx < 5) {
        for (array) |v| {
            if (std.math.isNan(v)) continue;
            if (v < xminval) xminval = v;
            if (v > xmaxval) xmaxval = v;
            ngoodpix += 1;
        }
        return .{ .ngood = ngoodpix, .minval = xminval, .maxval = xmaxval };
    }

    var jj: usize = 0;
    row_loop: while (jj < ny) : (jj += 1) {
        const rowpix = array[jj * nx ..][0..nx];

        // Find v1..v4 (min/max updated, but NOT counted unless the row reaches its 4th).
        var ii: usize = 0;
        for (0..4) |_| {
            while (ii < nx and std.math.isNan(rowpix[ii])) ii += 1;
            if (ii == nx) continue :row_loop;
            const v = rowpix[ii];
            if (v < xminval) xminval = v;
            if (v > xmaxval) xmaxval = v;
            ii += 1;
        }

        // Remaining pixels: counted individually (noise mode disabled), then += 4.
        while (ii < nx) : (ii += 1) {
            while (ii < nx and std.math.isNan(rowpix[ii])) ii += 1;
            if (ii == nx) break;
            const v = rowpix[ii];
            if (v < xminval) xminval = v;
            if (v > xmaxval) xmaxval = v;
            ngoodpix += 1;
        }
        ngoodpix += 4;
    }

    return .{ .ngood = ngoodpix, .minval = xminval, .maxval = xmaxval };
}

// In-place median selection (CFITSIO `quick_select_float`/`_double`, the Wirth/N.Devillard
// routine — same control flow as `imgstats.zig`'s i64 instantiation): permutes `arr` and
// returns element `(len−1)/2` of the would-be sorted order.
fn quickSelect(comptime T: type, arr: []T) T {
    var low: isize = 0;
    var high: isize = @as(isize, @intCast(arr.len)) - 1;
    const median: isize = @divTrunc(low + high, 2);
    while (true) {
        if (high <= low) return arr[@intCast(median)]; // one element only
        if (high == low + 1) { // two elements only
            if (arr[@intCast(low)] > arr[@intCast(high)])
                std.mem.swap(T, &arr[@intCast(low)], &arr[@intCast(high)]);
            return arr[@intCast(median)];
        }
        const middle = @divTrunc(low + high, 2);
        if (arr[@intCast(middle)] > arr[@intCast(high)])
            std.mem.swap(T, &arr[@intCast(middle)], &arr[@intCast(high)]);
        if (arr[@intCast(low)] > arr[@intCast(high)])
            std.mem.swap(T, &arr[@intCast(low)], &arr[@intCast(high)]);
        if (arr[@intCast(middle)] > arr[@intCast(low)])
            std.mem.swap(T, &arr[@intCast(middle)], &arr[@intCast(low)]);
        std.mem.swap(T, &arr[@intCast(middle)], &arr[@intCast(low + 1)]);

        var ll = low + 1;
        var hh = high;
        while (true) {
            ll += 1;
            while (arr[@intCast(low)] > arr[@intCast(ll)]) ll += 1;
            hh -= 1;
            while (arr[@intCast(hh)] > arr[@intCast(low)]) hh -= 1;
            if (hh < ll) break;
            std.mem.swap(T, &arr[@intCast(ll)], &arr[@intCast(hh)]);
        }
        std.mem.swap(T, &arr[@intCast(low)], &arr[@intCast(hh)]);

        if (hh <= median) low = ll;
        if (hh >= median) high = hh - 1;
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

fn mkTable(alloc: Allocator) ![]f32 {
    return dither.fitsRandom(alloc);
}

test "NINT is truncation-after-offset, not round-to-nearest-even" {
    try testing.expectEqual(@as(i32, 3), nint(2.5));
    try testing.expectEqual(@as(i32, -3), nint(-2.5)); // half away from zero
    try testing.expectEqual(@as(i32, 2), nint(2.49999));
    try testing.expectEqual(@as(i32, 0), nint(-0.4));
    try testing.expectEqual(@as(i32, 0), nint(0.0));
    // Double-rounding knife edge: the largest double below 0.5. x + 0.5 rounds UP to 1.0 in
    // f64, so NINT = 1 where round-to-nearest(x) = 0 — the exact CFITSIO behavior.
    const knife = 0.49999999999999994; // 0x3FDFFFFFFFFFFFFF
    try testing.expectEqual(@as(i32, 1), nint(knife));
    try testing.expectEqual(@as(i32, -1), nint(-knife));
}

test "quantizeTile: NO_DITHER round-trips within delta/2 and fudges ZZERO to a delta multiple" {
    const alloc = testing.allocator;
    // A noisy positive field, absolute quantization (delta = 0.25).
    var data: [96]f32 = undefined;
    var seed: u64 = 99;
    for (&data, 0..) |*v, i| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const u: f32 = @floatFromInt((seed >> 40) & 0xFFFF);
        v.* = 20.0 + @as(f32, @floatFromInt(i % 12)) * 0.5 + u / 65536.0;
    }
    var idata: [96]i32 = undefined;
    const r = try quantizeTile(f32, alloc, &data, 12, 8, -0.25, .none, null, 1, 0, &idata);
    const p = r.quantized;
    try testing.expectEqual(@as(f64, 0.25), p.bscale);
    try testing.expect(!p.has_null);
    // ZZERO is an exact integer multiple of delta (the iqfactor fudge).
    const k = p.bzero / p.bscale;
    try testing.expectEqual(@trunc(k), k);
    // NINT reconstruction error is at most delta/2.
    for (data, idata) |v, s| {
        const rec = @as(f64, @floatFromInt(s)) * p.bscale + p.bzero;
        try testing.expect(@abs(rec - @as(f64, v)) <= 0.125 + 1e-12);
    }
}

test "quantizeTile: SUBTRACTIVE_DITHER_1 round-trips within delta via the matching unquantize" {
    const alloc = testing.allocator;
    const table = try mkTable(alloc);
    defer alloc.free(table);
    var data: [64]f32 = undefined;
    var seed: u64 = 7;
    for (&data, 0..) |*v, i| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        v.* = 5.0 + @as(f32, @floatFromInt(i % 9)) + @as(f32, @floatFromInt((seed >> 40) & 0xFF)) / 256.0;
    }
    var idata: [64]i32 = undefined;
    const r = try quantizeTile(f32, alloc, &data, 8, 8, -0.5, .subtractive_1, table, 42, 3, &idata);
    const p = r.quantized;
    // Decode with the file-format reconstruction (same draws): |err| <= delta/2.
    var cur = dither.Dither.init(table, .subtractive_1, 42, 3);
    for (data, idata) |v, s| {
        const rec = cur.unquantizeNext(s, p.bscale, p.bzero, std.math.nan(f32));
        try testing.expect(@abs(rec - v) <= 0.25 + 1e-6);
    }
}

test "quantizeTile: NaN maps to NULL_VALUE, shifts ZZERO to the null branch, reports has_null" {
    const alloc = testing.allocator;
    var data: [32]f32 = undefined;
    for (&data, 0..) |*v, i| v.* = 10.0 + @as(f32, @floatFromInt(i)) * 0.5;
    data[5] = std.math.nan(f32);
    var idata: [32]i32 = undefined;
    const r = try quantizeTile(f32, alloc, &data, 32, 1, -0.5, .none, null, 1, 0, &idata);
    const p = r.quantized;
    try testing.expect(p.has_null);
    try testing.expectEqual(dither.null_value, idata[5]);
    // Nulls branch: min maps just above the reserved band (NULL_VALUE + 10).
    try testing.expectEqual(dither.null_value + dither.reserved_count, idata[0]);
}

test "quantizeTile: SUBTRACTIVE_DITHER_2 preserves exact zeros via ZERO_VALUE" {
    const alloc = testing.allocator;
    const table = try mkTable(alloc);
    defer alloc.free(table);
    var data: [32]f32 = undefined;
    for (&data, 0..) |*v, i| v.* = -4.0 + @as(f32, @floatFromInt(i)) * 0.3;
    data[3] = 0.0;
    data[17] = 0.0;
    var idata: [32]i32 = undefined;
    const r = try quantizeTile(f32, alloc, &data, 32, 1, -0.125, .subtractive_2, table, 1, 0, &idata);
    try testing.expect(r == .quantized);
    try testing.expectEqual(dither.zero_value, idata[3]);
    try testing.expectEqual(dither.zero_value, idata[17]);
    var cur = dither.Dither.init(table, .subtractive_2, 1, 0);
    for (data, idata) |v, s| {
        const rec = cur.unquantizeNext(s, r.quantized.bscale, r.quantized.bzero, std.math.nan(f32));
        if (v == 0.0) {
            try testing.expectEqual(@as(f32, 0.0), rec);
        } else {
            try testing.expect(@abs(rec - v) <= 0.0625 + 1e-6);
        }
    }
}

test "quantizeTile: not_quantized on tiny/constant/Inf tiles" {
    const alloc = testing.allocator;
    var idata: [64]i32 = undefined;
    // 1-pixel tile.
    try testing.expect((try quantizeTile(f32, alloc, &.{1.5}, 1, 1, 4.0, .none, null, 1, 0, idata[0..1])) == .not_quantized);
    // Constant tile: zero noise → delta == 0 on the noise-based path.
    const flat = [_]f32{3.25} ** 64;
    try testing.expect((try quantizeTile(f32, alloc, &flat, 8, 8, 4.0, .none, null, 1, 0, &idata)) == .not_quantized);
    // ±Inf tile: the fail-safe guard.
    var with_inf = [_]f32{1.0} ** 64;
    with_inf[10] = std.math.inf(f32);
    try testing.expect((try quantizeTile(f32, alloc, &with_inf, 8, 8, -1.0, .none, null, 1, 0, &idata)) == .not_quantized);
}

test "quantizeTile: noise-based default (qlevel 0) equals qlevel 4 (delta = sigma/4)" {
    const alloc = testing.allocator;
    var data: [256]f32 = undefined;
    var seed: u64 = 0xC0FFEE;
    for (&data, 0..) |*v, i| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        v.* = 100.0 + @as(f32, @floatFromInt(i % 16)) + @as(f32, @floatFromInt((seed >> 40) & 0xFF)) / 32.0;
    }
    var ia: [256]i32 = undefined;
    var ib: [256]i32 = undefined;
    const a = try quantizeTile(f32, alloc, &data, 16, 16, 0.0, .none, null, 1, 0, &ia);
    const b = try quantizeTile(f32, alloc, &data, 16, 16, 4.0, .none, null, 1, 0, &ib);
    try testing.expectEqual(a.quantized.bscale, b.quantized.bscale);
    try testing.expectEqual(a.quantized.bzero, b.quantized.bzero);
    try testing.expectEqualSlices(i32, &ia, &ib);
}

test "fnNoise5: constant image yields zero noise; f64 variant matches structure" {
    const alloc = testing.allocator;
    const flat = [_]f32{42.5} ** 256;
    const n = try fnNoise5(f32, alloc, &flat, 16, 16);
    try testing.expectEqual(@as(f64, 0), n.noise2);
    try testing.expectEqual(@as(f64, 0), n.noise3);
    try testing.expectEqual(@as(f64, 0), n.noise5);
    try testing.expectEqual(@as(f32, 42.5), n.minval);
    try testing.expectEqual(@as(f32, 42.5), n.maxval);
    try testing.expectEqual(@as(usize, 256), n.ngood);

    const flat64 = [_]f64{-1.25} ** 100;
    const n64 = try fnNoise5(f64, alloc, &flat64, 10, 10);
    try testing.expectEqual(@as(f64, 0), n64.noise3);
    try testing.expectEqual(@as(usize, 100), n64.ngood);
}

test "fnNoise5: single 9-pixel row, hand-computed (mirrors the int-variant vector)" {
    const alloc = testing.allocator;
    // Same construction as imgstats.zig's hand vector: v1..v9 = 1,3,2,5,4,7,6,9,8
    //   d2 = |v5-v7| = 2;  d3 = |2*4-2-6| = 0;  d5 = |6*4-4*2-4*6+1+8| = 1
    const data = [_]f32{ 1, 3, 2, 5, 4, 7, 6, 9, 8 };
    const n = try fnNoise5(f32, alloc, &data, 9, 1);
    try testing.expectApproxEqAbs(1.0483579 * 2.0, n.noise2, 1e-12);
    try testing.expectApproxEqAbs(0.0, n.noise3, 1e-12);
    try testing.expectApproxEqAbs(0.1772048 * 1.0, n.noise5, 1e-12);
    try testing.expectEqual(@as(usize, 9), n.ngood);
}

test "fnNoise5: NaN pixels are skipped by the window and excluded from min/max/ngood" {
    const alloc = testing.allocator;
    // 12 pixels with one NaN: the window must skip it and still form diffs.
    var data = [_]f32{ 1, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13 };
    data[4] = std.math.nan(f32);
    const n = try fnNoise5(f32, alloc, &data, 12, 1);
    try testing.expectEqual(@as(usize, 11), n.ngood);
    try testing.expectEqual(@as(f32, 1), n.minval);
    try testing.expectEqual(@as(f32, 13), n.maxval);
}

test "fnNoise3MinMax: counting quirk — a row ending before its 4th good pixel counts nothing" {
    // Row 0 has 12 good pixels; row 1 has only 3 (then NaNs): FnNoise3 counts 12 + 0.
    var data: [24]f32 = undefined;
    for (0..12) |i| data[i] = @floatFromInt(i);
    for (12..15) |i| data[i] = @floatFromInt(i);
    for (15..24) |i| data[i] = std.math.nan(f32);
    const mm = fnNoise3MinMax(f32, &data, 12, 2);
    try testing.expectEqual(@as(usize, 12), mm.ngood);
    // …but min/max still saw row 1's pixels.
    try testing.expectEqual(@as(f32, 0), mm.minval);
    try testing.expectEqual(@as(f32, 14), mm.maxval);
}

test "quantizeTile: CFITSIO 4.6.4 fits_quantize_float/_double bit-exact reference vectors" {
    // Expected values produced by the REAL CFITSIO 4.6.4 fits_quantize_float/_double
    // (Homebrew dylib, called via a local uncommitted ctypes harness — the same authoring
    // pattern as imgstats.zig's vectors) over the exact inputs below. `bscale`/`bzero` are
    // compared at the f64 bit level; the full stored-integer array via FNV-1a over its
    // little-endian i32 bytes plus first/middle/last samples. Covers: the noise-based step
    // (dithered A, undithered default-q B), the absolute step with SUBTRACTIVE_DITHER_2 and
    // an exact zero (C), the NaN/nulls ZZERO branch (D), the f64 variant (E), and the
    // FnNoise3 min/max absolute path (F).
    const alloc = testing.allocator;
    const table = try mkTable(alloc);
    defer alloc.free(table);

    const Vec = struct { bscale_bits: u64, bzero_bits: u64, idata_fnv: u64, first: i32, mid: i32, last: i32 };
    const vecs = [_]Vec{
        .{ .bscale_bits = 0x3fe33278f6367ae7, .bzero_bits = 0x4017ff1733c419a1, .idata_fnv = 0x209849c097ee81e2, .first = 0, .mid = 20, .last = 52 },
        .{ .bscale_bits = 0x3fe33278f6367ae7, .bzero_bits = 0x4017ff1733c419a1, .idata_fnv = 0x7b0298ae5227d88f, .first = 0, .mid = 20, .last = 52 },
        .{ .bscale_bits = 0x3fd0000000000000, .bzero_bits = 0x41bffffff569c8e0, .idata_fnv = 0xe2fa923de6074749, .first = -2147483637, .mid = -2147483591, .last = -2147483513 },
        .{ .bscale_bits = 0x3fe33278f6367ae7, .bzero_bits = 0x41d33278f6389d76, .idata_fnv = 0x5b044dffa662b260, .first = -2147483647, .mid = -2147483619, .last = -2147483586 },
        .{ .bscale_bits = 0x3fe3327917c2a0c5, .bzero_bits = 0x4017ff175db348f6, .idata_fnv = 0x209849c097ee81e2, .first = 0, .mid = 20, .last = 52 },
        .{ .bscale_bits = 0x3fe0000000000000, .bzero_bits = 0x4058000000000000, .idata_fnv = 0x8ea022d9058dba89, .first = 0, .mid = 11, .last = 19 },
    };

    // The deterministic LCG noise+gradient field shared with the harness (and the golden
    // generator): value = base + (r+c)*0.5 + (u-0.5)*8.0, u = (state>>8)/2^24, f64 chain.
    const Field = struct {
        fn fill(comptime T: type, out: []T, w: usize, base: f64) void {
            var state: u32 = 12345;
            for (out, 0..) |*v, i| {
                state = state *% 1664525 +% 1013904223;
                const u = @as(f64, @floatFromInt(state >> 8)) / 16777216.0;
                const r: f64 = @floatFromInt(i / w);
                const c: f64 = @floatFromInt(i % w);
                const x = base + (r + c) * 0.5 + (u - 0.5) * 8.0;
                v.* = if (T == f32) @floatCast(x) else x;
            }
        }
        fn fnv(idata: []const i32) u64 {
            var h: u64 = 0xcbf29ce484222325;
            for (idata) |v| {
                for (std.mem.asBytes(&std.mem.nativeToLittle(i32, v))) |b| {
                    h = (h ^ b) *% 0x100000001b3;
                }
            }
            return h;
        }
        fn check(v: Vec, p: Params, idata: []const i32) !void {
            try testing.expectEqual(v.bscale_bits, @as(u64, @bitCast(p.bscale)));
            try testing.expectEqual(v.bzero_bits, @as(u64, @bitCast(p.bzero)));
            try testing.expectEqual(v.first, idata[0]);
            try testing.expectEqual(v.mid, idata[idata.len / 2]);
            try testing.expectEqual(v.last, idata[idata.len - 1]);
            try testing.expectEqual(v.idata_fnv, fnv(idata));
        }
    };

    var f32data: [1024]f32 = undefined;
    var f64data: [1024]f64 = undefined;
    var idata: [1024]i32 = undefined;

    // A: q=4, SUBTRACTIVE_DITHER_1, tile 0, seed 1.
    Field.fill(f32, &f32data, 32, 10.0);
    var r = try quantizeTile(f32, alloc, &f32data, 32, 32, 4.0, .subtractive_1, table, 1, 0, &idata);
    try Field.check(vecs[0], r.quantized, &idata);
    // B: q=0 (default sigma/4), NO_DITHER — same data.
    r = try quantizeTile(f32, alloc, &f32data, 32, 32, 0.0, .none, null, 1, 0, &idata);
    try Field.check(vecs[1], r.quantized, &idata);
    // C: zero-crossing field with one exact zero, q=-0.25, SUBTRACTIVE_DITHER_2, tile 7, seed 42.
    Field.fill(f32, &f32data, 32, -4.0);
    f32data[100] = 0.0;
    r = try quantizeTile(f32, alloc, &f32data, 32, 32, -0.25, .subtractive_2, table, 42, 7, &idata);
    try Field.check(vecs[2], r.quantized, &idata);
    try testing.expectEqual(dither.zero_value, idata[100]);
    // D: NaN every 97th pixel, q=4, SUBTRACTIVE_DITHER_1, tile 3, seed 5.
    Field.fill(f32, &f32data, 32, 10.0);
    var i: usize = 0;
    while (i < f32data.len) : (i += 97) f32data[i] = std.math.nan(f32);
    r = try quantizeTile(f32, alloc, &f32data, 32, 32, 4.0, .subtractive_1, table, 5, 3, &idata);
    try testing.expect(r.quantized.has_null);
    try Field.check(vecs[3], r.quantized, &idata);
    // E: the f64 variant (same LCG chain, no f32 cast), q=4, SUBTRACTIVE_DITHER_1.
    Field.fill(f64, &f64data, 32, 10.0);
    r = try quantizeTile(f64, alloc, &f64data, 32, 32, 4.0, .subtractive_1, table, 1, 0, &idata);
    try Field.check(vecs[4], r.quantized, &idata);
    // F: 12x8 absolute path (FnNoise3 min/max), NO_DITHER.
    var small: [96]f32 = undefined;
    Field.fill(f32, &small, 12, 100.0);
    r = try quantizeTile(f32, alloc, &small, 12, 8, -0.5, .none, null, 1, 0, idata[0..96]);
    try Field.check(vecs[5], r.quantized, idata[0..96]);
}

test "quantizeTile: half-integer rounding boundaries pin NINT (half away from zero, not banker's)" {
    // Absolute step 0.25 with data whose minimum is exactly 0: the iqfactor fudge yields
    // zeropt = 0 exactly (trunc(0/0.25 + 0.5) = 0), so each stored value is NINT(v/0.25) with
    // no offset — pinning the exact rounding rule on real quantizer arithmetic. x = 0.5, 1.5,
    // 2.5, 3.5 must round to 1, 2, 3, 4 (truncation after +0.5 = half AWAY from zero); a
    // round-to-nearest-EVEN implementation would produce 0, 2, 2, 4 and a plain-round port
    // could diverge at double-rounding knife edges (see the dedicated NINT test).
    const alloc = testing.allocator;
    const data = [_]f32{ 0.0, 0.125, 0.375, 0.625, 0.875, 1.0, 2.0, 3.0 };
    var idata: [8]i32 = undefined;
    const r = try quantizeTile(f32, alloc, &data, 8, 1, -0.25, .none, null, 1, 0, &idata);
    const p = r.quantized;
    try testing.expectEqual(@as(f64, 0.25), p.bscale);
    try testing.expectEqual(@as(f64, 0.0), p.bzero); // iqfactor fudge landed exactly on zero
    const expected = [_]i32{ 0, 1, 2, 3, 4, 4, 8, 12 };
    try testing.expectEqualSlices(i32, &expected, &idata);
}

test "quickSelect: lower-middle median convention across lengths (float)" {
    var a1 = [_]f32{ 5, 1, 4, 2, 3 };
    try testing.expectEqual(@as(f32, 3), quickSelect(f32, &a1));
    var a2 = [_]f32{ 4, 1, 3, 2 };
    try testing.expectEqual(@as(f32, 2), quickSelect(f32, &a2));
    var a3 = [_]f64{ 7, 7 };
    try testing.expectEqual(@as(f64, 7), quickSelect(f64, &a3));
    var a4 = [_]f64{9};
    try testing.expectEqual(@as(f64, 9), quickSelect(f64, &a4));
}
