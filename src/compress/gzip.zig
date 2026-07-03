//! GZIP_1 / GZIP_2 tile codecs (FR-CMP-2, §17.2; FITS 4.0 §10.4.2).
//!
//! Both use the gzip container (RFC 1952 header / CRC32 / ISIZE) over DEFLATE via
//! `std.compress.flate` — the container is supplied by `std`, never hand-rolled. `GZIP_2`
//! additionally applies the MSB-first type-aware byte shuffle (`compress/shuffle.zig`) before
//! compression (and its inverse after decompression) for multi-byte numeric elements only —
//! never logical/bit/character data.
const std = @import("std");
const flate = std.compress.flate;
const CompressError = @import("../errors.zig").CompressError;
const shuffle = @import("shuffle.zig");

const Allocator = std.mem.Allocator;
const Alloc = Allocator.Error;

/// GZIP_1: compress raw `in` bytes into a gzip stream. Caller owns the returned slice.
pub fn gzipEncode(alloc: Allocator, in: []const u8) (CompressError || Alloc)![]u8 {
    // gzip never expands data by more than the container overhead plus a small per-block
    // amount; this bound comfortably covers the worst case (stored blocks).
    const cap = in.len + (in.len >> 3) + 128;
    const out = try alloc.alloc(u8, cap);
    errdefer alloc.free(out);
    var ow = std.Io.Writer.fixed(out);
    var window: [flate.max_window_len]u8 = undefined;
    var comp = flate.Compress.init(&ow, &window, .gzip, .default) catch return error.CorruptTile;
    comp.writer.writeAll(in) catch return error.CorruptTile;
    comp.finish() catch return error.CorruptTile;
    const n = ow.buffered().len;
    // Shrink to fit. On the (essentially unreachable) realloc-down failure, propagate the error:
    // the `errdefer` above frees the intact `out` at its real capacity. Returning `out[0..n]`
    // instead would hand back a length-`n` slice of a capacity-length allocation, so a later
    // `alloc.free` sees a mismatched length (DebugAllocator asserts, page/arena leak or corrupt).
    return try alloc.realloc(out, n);
}

/// GZIP_1: decompress a gzip stream into raw bytes, bounded by `max_out` (NFR-SAFE-1).
/// Caller owns the returned slice.
pub fn gzipDecode(alloc: Allocator, in: []const u8, max_out: u64) (CompressError || Alloc)![]u8 {
    var rdr = std.Io.Reader.fixed(in);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&rdr, .gzip, &window);
    return dec.reader.allocRemaining(alloc, std.Io.Limit.limited64(max_out)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.CorruptTile, // exceeded the tile-size ceiling
        else => error.CorruptTile,
    };
}

/// GZIP_2: decompress, then un-shuffle for the given element byte width. `elem_width` of 1
/// (B/A/L) means no shuffle was applied, so this is identical to `gzipDecode`. Caller owns
/// the returned slice.
pub fn gzip2Decode(alloc: Allocator, in: []const u8, elem_width: usize, max_out: u64) (CompressError || Alloc)![]u8 {
    const planes = try gzipDecode(alloc, in, max_out);
    if (elem_width <= 1) return planes;
    if (!isShuffleWidth(elem_width) or planes.len % elem_width != 0) {
        alloc.free(planes);
        return error.CorruptTile;
    }
    defer alloc.free(planes);
    const out = try alloc.alloc(u8, planes.len);
    errdefer alloc.free(out);
    shuffle.unshuffleWidth(elem_width, planes, out);
    return out;
}

/// GZIP_2: shuffle for the given element byte width, then compress. `elem_width` of 1 means
/// no shuffle. Caller owns the returned slice.
pub fn gzip2Encode(alloc: Allocator, in: []const u8, elem_width: usize) (CompressError || Alloc)![]u8 {
    if (elem_width <= 1) return gzipEncode(alloc, in);
    if (!isShuffleWidth(elem_width) or in.len % elem_width != 0) return error.DataConstraintViolated;
    const planes = try alloc.alloc(u8, in.len);
    defer alloc.free(planes);
    shuffle.shuffleWidth(elem_width, in, planes);
    return gzipEncode(alloc, planes);
}

fn isShuffleWidth(w: usize) bool {
    return w == 2 or w == 4 or w == 8 or w == 16;
}

const testing = std.testing;

test "GZIP_1 encode→decode round-trips" {
    const original = comptime blk: {
        const s = "SIMPLE  =                    T / FITS tile payload ";
        var buf: [s.len * 30]u8 = undefined;
        for (0..30) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        break :blk buf;
    };
    const enc = try gzipEncode(testing.allocator, &original);
    defer testing.allocator.free(enc);
    try testing.expect(enc.len < original.len);
    const dec = try gzipDecode(testing.allocator, enc, 1 << 20);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(&original, dec);
}

test "GZIP_2 shuffles numeric widths and round-trips" {
    inline for (.{ 2, 4, 8 }) |W| {
        var data: [W * 64]u8 = undefined;
        for (&data, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
        const enc = try gzip2Encode(testing.allocator, &data, W);
        defer testing.allocator.free(enc);
        const dec = try gzip2Decode(testing.allocator, enc, W, 1 << 20);
        defer testing.allocator.free(dec);
        try testing.expectEqualSlices(u8, &data, dec);
    }
}

test "GZIP_2 with width 1 is plain gzip (no shuffle)" {
    const data = comptime blk: {
        const s = "byte column data, no shuffle for A/B/L";
        var buf: [s.len * 4]u8 = undefined;
        for (0..4) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        break :blk buf;
    };
    const enc = try gzip2Encode(testing.allocator, &data, 1);
    defer testing.allocator.free(enc);
    const dec = try gzip2Decode(testing.allocator, enc, 1, 1 << 20);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(&data, dec);
}

test "decode enforces the output ceiling" {
    const original = &@as([5000]u8, @splat('x'));
    const enc = try gzipEncode(testing.allocator, original);
    defer testing.allocator.free(enc);
    try testing.expectError(error.CorruptTile, gzipDecode(testing.allocator, enc, 100));
}

test "corrupt gzip stream fails typed" {
    try testing.expectError(error.CorruptTile, gzipDecode(testing.allocator, "not a gzip stream", 1 << 20));
}
