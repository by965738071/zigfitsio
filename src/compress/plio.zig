//! PLIO_1 tile codec — IRAF run-length mask compression (FR-CMP-5, §17.2;
//! FITS 4.0 §10.4.3, Table 38; CFITSIO `pl_p2li` / `pl_l2pi`).
//!
//! PLIO ("pixel list I/O") is the compression IRAF uses for *mask* images: integer planes
//! that are mostly background (0) with sparse runs of small non-negative label values. A tile
//! is reduced to a 1-D line of `nelem` mask values and re-expressed as a list of 16-bit
//! instruction words. Each word is `(opcode << 12) | data`: a 4-bit opcode in the high nibble
//! and a 12-bit operand (`data`, 0..4095) in the low bits. On the wire the words are stored
//! **big-endian**, exactly as the surrounding FITS variable-length heap stores every other
//! multi-byte value, so all word access goes through `endian.zig` (GC-5).
//!
//! ## Mask value model
//! A line is a sequence of maximal *runs* of equal value. Background runs (value 0) are
//! emitted directly; a non-zero run first loads a 24-bit **value register** (which persists
//! across following instructions, so repeated labels cost nothing) and then emits the run
//! length. Because a run length and a value half each only carry 12 bits, longer runs and the
//! full 24-bit value range are expressed by repeating / pairing instructions — this is the
//! "high/low split" Table 38 documents.
//!
//! ## Opcodes (this implementation; high nibble of each 16-bit word)
//! - `ZN` (0x1) — *zero run*: append `data` background (0) pixels.
//! - `HN` (0x2) — *high run*: append `data` pixels equal to the current value register.
//! - `SL` (0x3) — *set low*:  load bits 0..11  of the value register from `data`.
//! - `SH` (0x4) — *set high*: load bits 12..23 of the value register from `data`.
//!
//! A value `v` in `0..2^24-1` is loaded as `SH(v >> 12)` (only when its high half changes)
//! followed by `SL(v & 0xFFF)` (only when its low half changes), so small labels cost a single
//! `SL` while values above 4095 exercise both halves. Any opcode outside `{ZN,HN,SL,SH}`, an
//! odd byte length, or a stream that does not reconstruct exactly `nelem` pixels is a
//! `CorruptTile`; an input mask value outside `0..2^24-1` is a `DataConstraintViolated`.
//!
//! Byte-exact parity against a committed CFITSIO PLIO tile is tracked as an X-FIXTURES item;
//! the contract verified here is round-trip fidelity and full opcode coverage.
const std = @import("std");
const endian = @import("../endian.zig");

const Allocator = std.mem.Allocator;

/// Codec error set shared with `tiled.zig` (the integrator plugs `decompress`/`compress` in
/// behind the `PLIO_1` `ZCMPTYPE`). Kept identical to the rice/hcompress sibling codecs.
pub const PlioError = error{ DataConstraintViolated, CorruptTile, OutOfMemory };

/// Largest mask value PLIO can carry: 24 bits across the SH/SL register halves.
pub const mask_max: i64 = (1 << 24) - 1;

/// Maximum operand carried by one instruction word (12-bit `data` field).
const data_max: u32 = (1 << 12) - 1; // 4095

// Opcodes occupy the high nibble (bits 12..15). 0x0 and 0x5..0xF are intentionally unused so
// that a corrupt or foreign stream is rejected rather than silently misinterpreted.
const op_zn: u16 = 0x1; // zero run
const op_hn: u16 = 0x2; // high run (current value register)
const op_sl: u16 = 0x3; // set low 12 bits of value register
const op_sh: u16 = 0x4; // set high 12 bits of value register

/// Decompress a PLIO_1 instruction stream (`src`, big-endian 16-bit words) into exactly
/// `nelem` mask values in `0..2^24-1`. Caller owns the returned slice. `nelem == 0` with empty
/// `src` yields an empty (still owned) slice.
pub fn decompress(alloc: Allocator, src: []const u8, nelem: usize) PlioError![]i32 {
    if (src.len % 2 != 0) return error.CorruptTile; // instructions are whole 16-bit words

    const out = try alloc.alloc(i32, nelem);
    errdefer alloc.free(out);

    var cur_low: u32 = 0;
    var cur_high: u32 = 0;
    var cur_val: i32 = 0;
    var pos: usize = 0; // pixels written so far

    var ip: usize = 0;
    while (ip < src.len) : (ip += 2) {
        const word = endian.read(u16, src[ip..][0..2]);
        const op = word >> 12;
        const data: u32 = word & 0x0FFF;
        switch (op) {
            op_zn => {
                if (pos + data > nelem) return error.CorruptTile; // run overruns the line
                @memset(out[pos .. pos + data], 0);
                pos += data;
            },
            op_hn => {
                if (pos + data > nelem) return error.CorruptTile;
                @memset(out[pos .. pos + data], cur_val);
                pos += data;
            },
            op_sl => {
                cur_low = data;
                cur_val = @intCast((cur_high << 12) | cur_low);
            },
            op_sh => {
                cur_high = data;
                cur_val = @intCast((cur_high << 12) | cur_low);
            },
            else => return error.CorruptTile, // unknown opcode
        }
    }

    if (pos != nelem) return error.CorruptTile; // stream did not cover the whole line
    return out;
}

/// Compress a 1-D mask line `data` (non-negative values in `0..2^24-1`) into a PLIO_1
/// instruction stream (big-endian 16-bit words). Caller owns the returned slice. Empty input
/// yields an empty (owned) slice.
pub fn compress(alloc: Allocator, data: []const i32) PlioError![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);

    var cur_low: u32 = 0;
    var cur_high: u32 = 0;

    var i: usize = 0;
    while (i < data.len) {
        const v = data[i];
        if (v < 0 or v > mask_max) return error.DataConstraintViolated;

        // Extend the maximal run of this value.
        var run: usize = 1;
        while (i + run < data.len and data[i + run] == v) : (run += 1) {}

        if (v == 0) {
            try emitRun(&list, alloc, op_zn, run);
        } else {
            const uv: u32 = @intCast(v);
            const high = uv >> 12;
            const low = uv & 0x0FFF;
            // Load only the register halves that actually changed; a repeated label re-uses
            // the register and emits no set words at all.
            if (high != cur_high) {
                try emitWord(&list, alloc, op_sh, high);
                cur_high = high;
            }
            if (low != cur_low) {
                try emitWord(&list, alloc, op_sl, low);
                cur_low = low;
            }
            try emitRun(&list, alloc, op_hn, run);
        }
        i += run;
    }

    return list.toOwnedSlice(alloc);
}

/// Emit a run of `count` pixels under `opcode`, splitting across as many words as the 12-bit
/// operand requires (`count` may exceed 4095).
fn emitRun(list: *std.ArrayList(u8), alloc: Allocator, opcode: u16, count: usize) Allocator.Error!void {
    var remaining = count;
    while (remaining > 0) {
        const chunk: u32 = @intCast(@min(remaining, data_max));
        try emitWord(list, alloc, opcode, chunk);
        remaining -= chunk;
    }
}

/// Append one big-endian instruction word `(opcode << 12) | data` (`data <= 4095`).
fn emitWord(list: *std.ArrayList(u8), alloc: Allocator, opcode: u16, data: u32) Allocator.Error!void {
    std.debug.assert(data <= data_max);
    const word: u16 = (opcode << 12) | @as(u16, @intCast(data));
    var buf: [2]u8 = undefined;
    endian.write(u16, word, &buf);
    try list.appendSlice(alloc, &buf);
}

// ---------------------------------------------------------------------------------------------
const testing = std.testing;

/// Compress→decompress and assert the line survives unchanged.
fn expectRoundTrip(line: []const i32) !void {
    const enc = try compress(testing.allocator, line);
    defer testing.allocator.free(enc);
    try testing.expect(enc.len % 2 == 0);
    const dec = try decompress(testing.allocator, enc, line.len);
    defer testing.allocator.free(dec);
    try testing.expectEqualSlices(i32, line, dec);
}

test "round-trip: all-zero line (pure ZN runs)" {
    const line = [_]i32{0} ** 100;
    try expectRoundTrip(&line);
}

test "round-trip: empty line" {
    try expectRoundTrip(&[_]i32{});
}

test "round-trip: single nonzero run" {
    const line = [_]i32{7} ** 10;
    try expectRoundTrip(&line);
}

test "round-trip: multiple alternating runs" {
    const line = [_]i32{ 0, 0, 0, 5, 5, 0, 9, 9, 9, 9, 0, 0, 5, 5, 5 };
    try expectRoundTrip(&line);
}

test "round-trip: high-value run >4095 exercises SH+SL split" {
    const line = [_]i32{70000} ** 8; // 70000 = 0x11170 -> high 17, low 0x170
    try expectRoundTrip(&line);
}

test "round-trip: value near 2^24" {
    const big: i32 = @intCast(mask_max); // 16777215 -> high 4095, low 4095
    const line = [_]i32{ 0, 0, big, big, big, 0, 1, big };
    try expectRoundTrip(&line);
}

test "round-trip: line exercising every opcode (ZN, SL, HN, SH)" {
    // zeros -> ZN; small label -> SL + HN; large label -> SH + SL + HN.
    const line = [_]i32{ 0, 0, 0, 5, 5, 5, 0, 70000, 70000, 0, 0 };
    const enc = try compress(testing.allocator, &line);
    defer testing.allocator.free(enc);

    var seen_zn = false;
    var seen_hn = false;
    var seen_sl = false;
    var seen_sh = false;
    var ip: usize = 0;
    while (ip < enc.len) : (ip += 2) {
        switch (endian.read(u16, enc[ip..][0..2]) >> 12) {
            op_zn => seen_zn = true,
            op_hn => seen_hn = true,
            op_sl => seen_sl = true,
            op_sh => seen_sh = true,
            else => unreachable,
        }
    }
    try testing.expect(seen_zn and seen_hn and seen_sl and seen_sh);

    const dec = try decompress(testing.allocator, enc, line.len);
    defer testing.allocator.free(dec);
    try testing.expectEqualSlices(i32, &line, dec);
}

test "round-trip: runs longer than one 12-bit operand are split" {
    // 5000 zeros then 5000 of value 3: each run needs two instruction words.
    var line: [10000]i32 = undefined;
    @memset(line[0..5000], 0);
    @memset(line[5000..10000], 3);
    try expectRoundTrip(&line);
}

test "round-trip: repeated label re-uses the value register" {
    // value 42 appears twice separated by zeros; the second run must emit no set words.
    const line = [_]i32{ 42, 42, 0, 0, 42, 42, 42 };
    const enc = try compress(testing.allocator, &line);
    defer testing.allocator.free(enc);

    var set_words: usize = 0;
    var ip: usize = 0;
    while (ip < enc.len) : (ip += 2) {
        switch (endian.read(u16, enc[ip..][0..2]) >> 12) {
            op_sl, op_sh => set_words += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), set_words); // only the first run loads the register

    const dec = try decompress(testing.allocator, enc, line.len);
    defer testing.allocator.free(dec);
    try testing.expectEqualSlices(i32, &line, dec);
}

test "out-of-range value is rejected" {
    const too_big = [_]i32{ 0, @as(i32, @intCast(mask_max)) + 1 };
    try testing.expectError(error.DataConstraintViolated, compress(testing.allocator, &too_big));

    const negative = [_]i32{ 0, -1, 0 };
    try testing.expectError(error.DataConstraintViolated, compress(testing.allocator, &negative));
}

test "corrupt: odd byte length" {
    try testing.expectError(error.CorruptTile, decompress(testing.allocator, &[_]u8{0x10}, 0));
}

test "corrupt: unknown opcode" {
    // 0xF000 -> opcode 0xF, which no encoder emits.
    const bad = [_]u8{ 0xF0, 0x00 };
    try testing.expectError(error.CorruptTile, decompress(testing.allocator, &bad, 4));
}

test "corrupt: run overruns declared nelem" {
    // ZN with data 5 but nelem declared as 3.
    var buf: [2]u8 = undefined;
    endian.write(u16, (op_zn << 12) | 5, &buf);
    try testing.expectError(error.CorruptTile, decompress(testing.allocator, &buf, 3));
}

test "corrupt: stream under-fills the line" {
    // ZN with data 2 but nelem declared as 10.
    var buf: [2]u8 = undefined;
    endian.write(u16, (op_zn << 12) | 2, &buf);
    try testing.expectError(error.CorruptTile, decompress(testing.allocator, &buf, 10));
}
