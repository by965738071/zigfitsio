//! Background-noise estimation for integer image tiles — an exact port of CFITSIO 4.6.4
//! `quantize.c` `FnNoise5_int` (the no-null path) and `quick_select_longlong`.
//!
//! The estimates drive the CFITSIO-compatible **noise-adaptive lossy HCOMPRESS scale**: a
//! positive requested `hcomp_scale` means "scale = request × background sigma", where sigma is
//! `min(noise2, noise3, noise5)` over the tile (`imcompress.c` `imcomp_compress_tile`). The
//! algorithm computes 2nd/3rd/5th-order Median Absolute Differences along each row
//! (ST-ECF newsletter #42 MAD estimators):
//!
//!   noise2 ∝ median |v(i-2) − v(i+2)|
//!   noise3 ∝ median |2·v(i) − v(i-2) − v(i+2)|
//!   noise5 ∝ median |6·v(i) − 4·v(i-2) − 4·v(i+2) + v(i-4) + v(i+4)|
//!
//! then takes the median across rows and applies the calibration constants
//! (1.0483579 / 0.6052697 / 0.1772048).
//!
//! ── Deliberate quirk parity ───────────────────────────────────────────────────────────────
//! CFITSIO selects the per-row noise2 median as `quick_select(differences2, nvals)` — `nvals`
//! is the *noise3/5* count, not `nvals2` — over scratch buffers that are zero-initialized once
//! and NEVER cleared between rows (so when `nvals > nvals2` the selection reads stale/zero
//! entries, partially permuted by earlier rows' in-place selections). Byte-exact interop with
//! fpack's noise-adaptive scale requires reproducing this, so this port allocates the scratch
//! once, zero-fills once, and reuses it across rows exactly as the C does. All difference
//! arithmetic is i64 (matches the C's LONGLONG; cannot overflow for i32 pixels).
const std = @import("std");

const Allocator = std.mem.Allocator;

/// The three MAD noise estimates of `FnNoise5_int` (already calibration-scaled).
pub const Noise = struct {
    /// 2nd-order estimate (× 1.0483579).
    noise2: f64,
    /// 3rd-order estimate (× 0.6052697).
    noise3: f64,
    /// 5th-order estimate (× 0.1772048).
    noise5: f64,
};

/// Estimate the background noise of `array`, a row-major image with `nx` pixels per row
/// (the FITS fastest axis) and `ny` rows — CFITSIO `FnNoise5_int(array, nx, ny, 0, ...)`.
/// `array.len` must equal `nx * ny`. Rows shorter than 9 pixels flatten the image into a
/// single row (CFITSIO behavior); if still shorter than 9, every estimate is 0.
pub fn noiseEstimates(alloc: Allocator, array: []const i32, nx_in: usize, ny_in: usize) Allocator.Error!Noise {
    std.debug.assert(array.len == nx_in * ny_in);
    var nx = nx_in;
    var ny = ny_in;
    if (nx < 9) {
        // Treat the entire array as an image with a single row.
        nx = nx * ny;
        ny = 1;
    }
    if (nx < 9) return .{ .noise2 = 0, .noise3 = 0, .noise5 = 0 };

    // Scratch: per-row absolute differences (i64, len nx) — zero-filled ONCE, reused across
    // rows without clearing (see the quirk-parity note above) — and per-row medians (f64).
    const differences2 = try alloc.alloc(i64, nx);
    defer alloc.free(differences2);
    const differences3 = try alloc.alloc(i64, nx);
    defer alloc.free(differences3);
    const differences5 = try alloc.alloc(i64, nx);
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
    while (jj < ny) : (jj += 1) {
        const rowpix = array[jj * nx ..][0..nx];
        // The 9-wide sliding window (no null pixels in this path, so v1..v8 are simply the
        // first 8 values and the loop feeds v9 from index 8 on).
        var v1: i64 = rowpix[0];
        var v2: i64 = rowpix[1];
        var v3: i64 = rowpix[2];
        var v4: i64 = rowpix[3];
        var v5: i64 = rowpix[4];
        var v6: i64 = rowpix[5];
        var v7: i64 = rowpix[6];
        var v8: i64 = rowpix[7];

        var nvals: usize = 0;
        var nvals2: usize = 0;
        var ii: usize = 8;
        while (ii < nx) : (ii += 1) {
            const v9: i64 = rowpix[ii];

            if (!(v5 == v6 and v6 == v7)) {
                differences2[nvals2] = @intCast(@abs(v5 - v7));
                nvals2 += 1;
            }
            if (!(v3 == v4 and v4 == v5 and v5 == v6 and v6 == v7)) {
                differences3[nvals] = @intCast(@abs(2 * v5 - v3 - v7));
                differences5[nvals] = @intCast(@abs(6 * v5 - 4 * v3 - 4 * v7 + v1 + v9));
                nvals += 1;
            } // else: constant background region, ignored

            v1 = v2;
            v2 = v3;
            v3 = v4;
            v4 = v5;
            v5 = v6;
            v6 = v7;
            v7 = v8;
            v8 = v9;
        }

        if (nvals == 0) {
            continue; // cannot compute medians on this row (nrows NOT incremented)
        } else if (nvals == 1) {
            if (nvals2 == 1) {
                diffs2[nrows2] = @floatFromInt(differences2[0]);
                nrows2 += 1;
            }
            diffs3[nrows] = @floatFromInt(differences3[0]);
            diffs5[nrows] = @floatFromInt(differences5[0]);
        } else {
            if (nvals2 > 1) {
                // CFITSIO quirk: selected over nvals (NOT nvals2) entries — kept verbatim.
                diffs2[nrows2] = @floatFromInt(quickSelect(differences2[0..nvals]));
                nrows2 += 1;
            }
            diffs3[nrows] = @floatFromInt(quickSelect(differences3[0..nvals]));
            diffs5[nrows] = @floatFromInt(quickSelect(differences5[0..nvals]));
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
        .noise2 = 1.0483579 * xnoise2,
        .noise3 = 0.6052697 * xnoise3,
        .noise5 = 0.1772048 * xnoise5,
    };
}

// In-place median selection (CFITSIO `quick_select_longlong`, the classic Wirth/N.Devillard
// routine): permutes `arr` and returns element `(len-1)/2` of the would-be sorted order (the
// LOWER middle for even lengths — no averaging). Indices are signed to mirror the C exactly
// (`high` legitimately reaches -1 on exit paths).
fn quickSelect(arr: []i64) i64 {
    var low: isize = 0;
    var high: isize = @as(isize, @intCast(arr.len)) - 1;
    const median: isize = @divTrunc(low + high, 2);
    while (true) {
        if (high <= low) return arr[@intCast(median)]; // one element only
        if (high == low + 1) { // two elements only
            if (arr[@intCast(low)] > arr[@intCast(high)])
                std.mem.swap(i64, &arr[@intCast(low)], &arr[@intCast(high)]);
            return arr[@intCast(median)];
        }
        // Median-of-three pivot into position `low`, sentinel into `low+1`.
        const middle = @divTrunc(low + high, 2);
        if (arr[@intCast(middle)] > arr[@intCast(high)])
            std.mem.swap(i64, &arr[@intCast(middle)], &arr[@intCast(high)]);
        if (arr[@intCast(low)] > arr[@intCast(high)])
            std.mem.swap(i64, &arr[@intCast(low)], &arr[@intCast(high)]);
        if (arr[@intCast(middle)] > arr[@intCast(low)])
            std.mem.swap(i64, &arr[@intCast(middle)], &arr[@intCast(low)]);
        std.mem.swap(i64, &arr[@intCast(middle)], &arr[@intCast(low + 1)]);

        // Nibble from each end towards the middle, swapping when stuck.
        var ll = low + 1;
        var hh = high;
        while (true) {
            ll += 1;
            while (arr[@intCast(low)] > arr[@intCast(ll)]) ll += 1;
            hh -= 1;
            while (arr[@intCast(hh)] > arr[@intCast(low)]) hh -= 1;
            if (hh < ll) break;
            std.mem.swap(i64, &arr[@intCast(ll)], &arr[@intCast(hh)]);
        }
        std.mem.swap(i64, &arr[@intCast(low)], &arr[@intCast(hh)]);

        // Re-set the active partition.
        if (hh <= median) low = ll;
        if (hh >= median) high = hh - 1;
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "quickSelect: lower-middle median convention across lengths" {
    // Odd length → true median; even length → LOWER middle (index (n-1)/2), no averaging.
    var a1 = [_]i64{ 5, 1, 4, 2, 3 };
    try testing.expectEqual(@as(i64, 3), quickSelect(&a1));
    var a2 = [_]i64{ 4, 1, 3, 2 };
    try testing.expectEqual(@as(i64, 2), quickSelect(&a2));
    var a3 = [_]i64{ 7, 7 };
    try testing.expectEqual(@as(i64, 7), quickSelect(&a3));
    var a4 = [_]i64{9};
    try testing.expectEqual(@as(i64, 9), quickSelect(&a4));
    var a5 = [_]i64{ 2, 1 };
    try testing.expectEqual(@as(i64, 1), quickSelect(&a5));
}

test "noiseEstimates: constant image yields zero noise" {
    const alloc = testing.allocator;
    const data = [_]i32{42} ** 256;
    const n = try noiseEstimates(alloc, &data, 16, 16);
    try testing.expectEqual(@as(f64, 0), n.noise2);
    try testing.expectEqual(@as(f64, 0), n.noise3);
    try testing.expectEqual(@as(f64, 0), n.noise5);
}

test "noiseEstimates: single 9-pixel row, hand-computed" {
    const alloc = testing.allocator;
    // One row, nx = 9 → exactly one window position (ii = 8):
    //   v1..v9 = 1,3,2,5,4,7,6,9,8 → v3=2 v5=4 v7=6 (not all equal)
    //   d2 = |v5-v7| = 2;  d3 = |2*4-2-6| = 0;  d5 = |6*4-4*2-4*6+1+8| = |24-8-24+9| = 1
    // nvals = nvals2 = 1 → per-row medians are the single values; one row total.
    const data = [_]i32{ 1, 3, 2, 5, 4, 7, 6, 9, 8 };
    const n = try noiseEstimates(alloc, &data, 9, 1);
    try testing.expectApproxEqAbs(1.0483579 * 2.0, n.noise2, 1e-12);
    try testing.expectApproxEqAbs(0.0, n.noise3, 1e-12);
    try testing.expectApproxEqAbs(0.1772048 * 1.0, n.noise5, 1e-12);
}

test "noiseEstimates: CFITSIO 4.6.4 bit-exact reference vectors" {
    const alloc = testing.allocator;
    // Expected f64 bit patterns produced by CFITSIO 4.6.4 `fits_img_stats_int` over the exact
    // same inputs. These two committed vectors are the in-repo bit-exactness evidence; they
    // were authored with a local (uncommitted) parity harness against the Homebrew cfitsio
    // 4.6.4 dylib, which also checked ten further shape/pattern cases at authoring time.

    // (a) 16×16 repetitive pattern with constant runs (v[c] = 100 if c%5==0 else 7): exercises
    //     the constant-background skip AND the nvals/nvals2 quirk (noise3 median is exactly 0).
    {
        var data: [256]i32 = undefined;
        for (0..16) |r| {
            for (0..16) |c| data[r * 16 + c] = if (c % 5 == 0) 100 else 7;
        }
        const n = try noiseEstimates(alloc, &data, 16, 16);
        try testing.expectEqual(@as(u64, 0x40585fd38334d347), @as(u64, @bitCast(n.noise2)));
        try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(n.noise3)));
        try testing.expectEqual(@as(u64, 0x40307ae452249002), @as(u64, @bitCast(n.noise5)));
    }
    // (b) 32×32 signed pseudo-random field (LCG seeded 0x9E3779B97F4A7C15 ^ (nx*131 + ny)).
    {
        var data: [1024]i32 = undefined;
        var seed: u64 = 0x9E3779B97F4A7C15 ^ @as(u64, 32 * 131 + 32);
        for (&data) |*v| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            v.* = @intCast(@rem(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(seed >> 32))))), 20000));
        }
        const n = try noiseEstimates(alloc, &data, 32, 32);
        try testing.expectEqual(@as(u64, 0x40c5480dcd7e3815), @as(u64, @bitCast(n.noise2)));
        try testing.expectEqual(@as(u64, 0x40c61122284e6843), @as(u64, @bitCast(n.noise3)));
        try testing.expectEqual(@as(u64, 0x40c4d48912dba4d7), @as(u64, @bitCast(n.noise5)));
    }
}

test "noiseEstimates: rows shorter than 9 flatten to a single row" {
    const alloc = testing.allocator;
    // 4×4 (nx = 4 < 9) flattens to one 16-pixel row: identical to computing on 16×1 directly.
    var data: [16]i32 = undefined;
    var seed: u64 = 0xABCD1234;
    for (&data) |*v| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        v.* = @intCast((seed >> 33) % 1000);
    }
    const a = try noiseEstimates(alloc, &data, 4, 4);
    const b = try noiseEstimates(alloc, &data, 16, 1);
    try testing.expectEqual(b.noise2, a.noise2);
    try testing.expectEqual(b.noise3, a.noise3);
    try testing.expectEqual(b.noise5, a.noise5);
    // And a still-too-short image is all zeros.
    const tiny = [_]i32{ 3, 1, 4, 1, 5, 9, 2, 6 };
    const z = try noiseEstimates(alloc, &tiny, 4, 2);
    try testing.expectEqual(@as(f64, 0), z.noise3);
}
