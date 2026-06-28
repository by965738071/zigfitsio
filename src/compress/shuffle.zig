//! GZIP_2 type-aware byte shuffle and its exact inverse (FR-CMP-2, §17.2; FITS 4.0 §10.4.2).
//!
//! The `GZIP_2` tile codec reorders the bytes of `N` `W`-byte values into `W` contiguous
//! planes before DEFLATE: plane `k` holds byte `k` of every value, in **decreasing
//! significance** (MSB-first), which groups same-significance bytes together so they compress
//! better. This applies to integer/float elements only — never logical/bit/character. `std`
//! does not provide the shuffle, so it (and its exact inverse on read) live here.
const std = @import("std");

/// Split `items` (`N` values of `W` bytes each, on-disk MSB-first order) into `W` planes
/// written to `out`: `out[k*N + i] == items[i*W + k]`. `items.len` and `out.len` must equal
/// `N*W`; `items.len % W == 0`.
pub fn shuffle(comptime W: usize, items: []const u8, out: []u8) void {
    std.debug.assert(items.len == out.len);
    std.debug.assert(items.len % W == 0);
    const n = items.len / W;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        comptime var k: usize = 0;
        inline while (k < W) : (k += 1) {
            out[k * n + i] = items[i * W + k];
        }
    }
}

/// Inverse of `shuffle`: reassemble `W` planes back into `N` `W`-byte values.
/// `out[i*W + k] == planes[k*N + i]`.
pub fn unshuffle(comptime W: usize, planes: []const u8, out: []u8) void {
    std.debug.assert(planes.len == out.len);
    std.debug.assert(out.len % W == 0);
    const n = out.len / W;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        comptime var k: usize = 0;
        inline while (k < W) : (k += 1) {
            out[i * W + k] = planes[k * n + i];
        }
    }
}

/// Runtime dispatch over the supported element widths (2/4/8 bytes for I/J/K/E/D and the
/// complex pair halves). Width 1 (`B`/`A`/`L`) is a no-op copy and is rejected here because
/// the shuffle is only meaningful for multi-byte numeric elements.
pub fn shuffleWidth(width: usize, items: []const u8, out: []u8) void {
    switch (width) {
        2 => shuffle(2, items, out),
        4 => shuffle(4, items, out),
        8 => shuffle(8, items, out),
        16 => shuffle(16, items, out), // double complex element pair as 16 bytes
        else => unreachable,
    }
}

/// Runtime dispatch inverse of `shuffleWidth`.
pub fn unshuffleWidth(width: usize, planes: []const u8, out: []u8) void {
    switch (width) {
        2 => unshuffle(2, planes, out),
        4 => unshuffle(4, planes, out),
        8 => unshuffle(8, planes, out),
        16 => unshuffle(16, planes, out),
        else => unreachable,
    }
}

const testing = std.testing;

test "shuffle produces MSB-first planes per §10.4.2" {
    // Three 4-byte values; plane 0 = the four MSBs, plane 3 = the four LSBs.
    const items = [_]u8{
        0x11, 0x12, 0x13, 0x14, // value 0
        0x21, 0x22, 0x23, 0x24, // value 1
        0x31, 0x32, 0x33, 0x34, // value 2
    };
    var out: [12]u8 = undefined;
    shuffle(4, &items, &out);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x11, 0x21, 0x31, // plane 0 (most significant bytes)
        0x12, 0x22, 0x32, // plane 1
        0x13, 0x23, 0x33, // plane 2
        0x14, 0x24, 0x34, // plane 3 (least significant bytes)
    }, &out);
}

test "unshuffle inverts shuffle for each width" {
    inline for (.{ 2, 4, 8 }) |W| {
        const n = 7;
        var items: [n * W]u8 = undefined;
        for (&items, 0..) |*b, idx| b.* = @truncate(idx * 31 + 1);
        var planes: [n * W]u8 = undefined;
        var back: [n * W]u8 = undefined;
        shuffle(W, &items, &planes);
        unshuffle(W, &planes, &back);
        try testing.expectEqualSlices(u8, &items, &back);
    }
}

test "runtime width dispatch matches comptime" {
    const items = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    shuffle(4, &items, &a);
    shuffleWidth(4, &items, &b);
    try testing.expectEqualSlices(u8, &a, &b);
    var back: [8]u8 = undefined;
    unshuffleWidth(4, &b, &back);
    try testing.expectEqualSlices(u8, &items, &back);
}
