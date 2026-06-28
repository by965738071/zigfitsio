//! PLIO_1 tile codec — IRAF run-length mask compression (FR-CMP-5, §17.2;
//! FITS 4.0 §10.4.3, Table 38; CFITSIO `pl_p2li` / `pl_l2pi`).
//!
//! PLIO ("pixel list I/O") is the compression IRAF uses for *mask* images: integer planes
//! that are mostly background (0) with sparse runs of small non-negative label values. A tile
//! is reduced to a 1-D line of `nelem` mask values and re-expressed as a *line list*: an array
//! of 16-bit instruction words. On the wire the words are stored **big-endian**, exactly as the
//! surrounding FITS variable-length heap stores every other multi-byte value, so all word
//! access goes through `endian.zig` (GC-5).
//!
//! ## Instruction-word layout (Table 38)
//! Each 16-bit word is `sign(1) | opcode(3) | data(12)`:
//!   - bit 15        — sign bit (`0x8000`); unused by these opcodes, always 0 on encode and
//!                     ignored on decode.
//!   - bits 14..12   — 3-bit opcode: `opcode = (word >> 12) & 0x7`.
//!   - bits 11..0    — 12-bit operand: `data = word & 0x0FFF` (0..4095).
//!
//! The decoder keeps a running **high value** register (the current label), initialised to 1 at
//! the start of each line, and a current output position. The instructions are:
//!   - `ZN` (0) — zero the next `data` pixels; advance position by `data`.
//!   - `SH` (1) — set the high value **absolutely**: low 12 bits come from this word's `data`,
//!                the high 15 bits from the *following* 16-bit word; position unaffected.
//!   - `IH` (2) — increment the high value by `data`; position unaffected.
//!   - `DH` (3) — decrement the high value by `data`; position unaffected.
//!   - `HN` (4) — set the next `data` pixels to the high value; advance by `data`.
//!   - `PN` (5) — zero the next `data - 1` pixels, then set pixel `data` to the high value;
//!                advance by `data` (a sparse "gap then one label" word).
//!   - `IS` (6) — increment the high value by `data`, then output ONE high pixel (advance 1).
//!   - `DS` (7) — decrement the high value by `data`, then output ONE high pixel (advance 1).
//!
//! ## Resolved spec ambiguity
//! Table 38 prints opcode `05` for BOTH `PN` and `SH`, which is impossible. Opcode `1` is
//! otherwise unused. Following the real IRAF/CFITSIO `pl_p2li`/`pl_l2pi` assignment we give `SH`
//! the free opcode **1** and keep `PN = 5`; this is the only deviation from the literal table and
//! is required for interoperability with the reference implementation.
//!
//! ## Constraints & errors
//! PLIO_1 only supports integer image masks with values in `0..2^24-1`; a pixel outside that
//! range is a `DataConstraintViolated`. An odd byte length, a truncated `SH` (no following
//! word), a high value that escapes `0..2^24-1`, a run that overruns/under-fills the declared
//! `nelem`, are all a `CorruptTile`.
//!
//! Byte-exact parity against a committed CFITSIO PLIO tile is tracked as an X-FIXTURES item;
//! the contract verified here is round-trip fidelity and full opcode coverage.
const std = @import("std");
const endian = @import("../endian.zig");

const Allocator = std.mem.Allocator;

/// Codec error set shared with `tiled.zig` (the integrator plugs `decompress`/`compress` in
/// behind the `PLIO_1` `ZCMPTYPE`). Kept identical to the rice/hcompress sibling codecs.
pub const PlioError = error{ DataConstraintViolated, CorruptTile, OutOfMemory };

/// Largest mask value PLIO can carry: 24 bits.
pub const mask_max: i64 = (1 << 24) - 1;

/// Maximum operand carried by one instruction word (12-bit `data` field).
const data_max: u32 = (1 << 12) - 1; // 4095

// 3-bit opcodes (bits 14..12 of each word). See the module header for the SH=1 ambiguity note.
const op_zn: u16 = 0; // zero run
const op_sh: u16 = 1; // set high value absolutely (this word + the following word)
const op_ih: u16 = 2; // increment high value
const op_dh: u16 = 3; // decrement high value
const op_hn: u16 = 4; // high run (current high value)
const op_pn: u16 = 5; // zero data-1 pixels then one high-value pixel
const op_is: u16 = 6; // increment high value, then emit one high-value pixel
const op_ds: u16 = 7; // decrement high value, then emit one high-value pixel

/// Decompress a PLIO_1 line list (`src`, big-endian 16-bit words) into exactly `nelem` mask
/// values in `0..2^24-1`. Caller owns the returned slice. `nelem == 0` with empty `src` yields
/// an empty (still owned) slice.
pub fn decompress(alloc: Allocator, src: []const u8, nelem: usize) PlioError![]i32 {
    if (src.len % 2 != 0) return error.CorruptTile; // instructions are whole 16-bit words

    const out = try alloc.alloc(i32, nelem);
    errdefer alloc.free(out);

    var high: i64 = 1; // running high value, reset to 1 at the start of every line
    var pos: usize = 0; // pixels written so far

    var ip: usize = 0;
    while (ip + 2 <= src.len) {
        const word = endian.read(u16, src[ip..][0..2]);
        ip += 2;
        const op = (word >> 12) & 0x7;
        const data: u32 = word & 0x0FFF;
        switch (op) {
            op_zn => {
                if (pos + data > nelem) return error.CorruptTile; // run overruns the line
                @memset(out[pos .. pos + data], 0);
                pos += data;
            },
            op_hn => {
                if (pos + data > nelem) return error.CorruptTile;
                @memset(out[pos .. pos + data], @intCast(high));
                pos += data;
            },
            op_pn => {
                if (data == 0) continue; // degenerate; nothing to emit
                if (pos + data > nelem) return error.CorruptTile;
                @memset(out[pos .. pos + data - 1], 0);
                out[pos + data - 1] = @intCast(high);
                pos += data;
            },
            op_sh => {
                if (ip + 2 > src.len) return error.CorruptTile; // truncated SH (no following word)
                const w2 = endian.read(u16, src[ip..][0..2]);
                ip += 2;
                const hi: i64 = w2 & 0x7FFF; // high 15 bits live in the following word
                high = (hi << 12) | @as(i64, data);
                if (high < 0 or high > mask_max) return error.CorruptTile;
            },
            op_ih => {
                high += data;
                if (high < 0 or high > mask_max) return error.CorruptTile;
            },
            op_dh => {
                high -= data;
                if (high < 0 or high > mask_max) return error.CorruptTile;
            },
            op_is => {
                high += data;
                if (high < 0 or high > mask_max) return error.CorruptTile;
                if (pos + 1 > nelem) return error.CorruptTile;
                out[pos] = @intCast(high);
                pos += 1;
            },
            op_ds => {
                high -= data;
                if (high < 0 or high > mask_max) return error.CorruptTile;
                if (pos + 1 > nelem) return error.CorruptTile;
                out[pos] = @intCast(high);
                pos += 1;
            },
            else => unreachable, // op is masked to 0..7 and every value is defined above
        }
    }

    if (pos != nelem) return error.CorruptTile; // stream did not cover the whole line
    return out;
}

/// Compress a 1-D mask line `data` (non-negative values in `0..2^24-1`) into a PLIO_1 line list
/// (big-endian 16-bit words). Caller owns the returned slice. Empty input yields an empty (owned)
/// slice. The encoder picks economically between ZN/HN/PN to lay down runs and SH/IH/DH/IS/DS to
/// move the high value, reusing the high register across runs so repeated labels stay cheap.
pub fn compress(alloc: Allocator, data: []const i32) PlioError![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);

    var high: i64 = 1; // mirror the decoder's initial high value

    var i: usize = 0;
    while (i < data.len) {
        const v = data[i];
        if (v < 0 or v > mask_max) return error.DataConstraintViolated;
        const run = runLength(data, i);

        if (v == 0) {
            // Fold an isolated "gap then one label equal to the current high value" into a single
            // PN word: zero the gap and place the one high pixel without touching the register.
            const next = i + run;
            if (next < data.len and
                @as(i64, data[next]) == high and
                runLength(data, next) == 1 and
                run + 1 <= data_max)
            {
                try emitWord(&list, alloc, op_pn, @intCast(run + 1));
                i = next + 1;
                continue;
            }
            try emitRun(&list, alloc, op_zn, run);
            i += run;
        } else {
            try setHighAndEmitRun(&list, alloc, &high, v, run);
            i += run;
        }
    }

    return list.toOwnedSlice(alloc);
}

/// Move the high register to `v` and lay down a `run`-long stretch of that label, choosing the
/// cheapest instruction(s). Single-pixel runs collapse the register move and the emit into one
/// IS/DS word when the delta fits 12 bits.
fn setHighAndEmitRun(
    list: *std.ArrayList(u8),
    alloc: Allocator,
    high: *i64,
    v: i32,
    run: usize,
) PlioError!void {
    const delta: i64 = @as(i64, v) - high.*;
    const dmax: i64 = data_max;

    if (delta == 0) {
        try emitRun(list, alloc, op_hn, run); // register already correct
    } else if (run == 1 and delta >= 1 and delta <= dmax) {
        try emitWord(list, alloc, op_is, @intCast(delta)); // increment + one pixel
    } else if (run == 1 and delta <= -1 and delta >= -dmax) {
        try emitWord(list, alloc, op_ds, @intCast(-delta)); // decrement + one pixel
    } else if (delta >= 1 and delta <= dmax) {
        try emitWord(list, alloc, op_ih, @intCast(delta));
        try emitRun(list, alloc, op_hn, run);
    } else if (delta <= -1 and delta >= -dmax) {
        try emitWord(list, alloc, op_dh, @intCast(-delta));
        try emitRun(list, alloc, op_hn, run);
    } else {
        try emitSh(list, alloc, v); // delta too large for a single increment word
        try emitRun(list, alloc, op_hn, run);
    }
    high.* = v;
}

/// Length of the maximal run of equal values starting at `start` (>= 1).
fn runLength(data: []const i32, start: usize) usize {
    var n: usize = 1;
    while (start + n < data.len and data[start + n] == data[start]) : (n += 1) {}
    return n;
}

/// Emit a run of `count` pixels under `opcode` (ZN or HN), splitting across as many words as the
/// 12-bit operand requires (`count` may exceed 4095).
fn emitRun(list: *std.ArrayList(u8), alloc: Allocator, opcode: u16, count: usize) Allocator.Error!void {
    var remaining = count;
    while (remaining > 0) {
        const chunk: u32 = @intCast(@min(remaining, data_max));
        try emitWord(list, alloc, opcode, chunk);
        remaining -= chunk;
    }
}

/// Emit an absolute set-high (`SH`): the opcode word carries the low 12 bits of `v`, the
/// following raw word carries its high 15 bits.
fn emitSh(list: *std.ArrayList(u8), alloc: Allocator, v: i32) Allocator.Error!void {
    const uv: u32 = @intCast(v);
    try emitWord(list, alloc, op_sh, uv & 0x0FFF);
    try emitRawWord(list, alloc, @intCast((uv >> 12) & 0x7FFF));
}

/// Append one big-endian instruction word `(opcode << 12) | data` (`data <= 4095`).
fn emitWord(list: *std.ArrayList(u8), alloc: Allocator, opcode: u16, data: u32) Allocator.Error!void {
    std.debug.assert(data <= data_max);
    try emitRawWord(list, alloc, (opcode << 12) | @as(u16, @intCast(data)));
}

/// Append one raw big-endian 16-bit word (used for an SH continuation word).
fn emitRawWord(list: *std.ArrayList(u8), alloc: Allocator, word: u16) Allocator.Error!void {
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

/// Walk a line list opcode by opcode, correctly skipping each SH's following raw word, invoking
/// `f` with every instruction opcode.
fn forEachOpcode(enc: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), u16) void) void {
    var ip: usize = 0;
    while (ip + 2 <= enc.len) {
        const op = (endian.read(u16, enc[ip..][0..2]) >> 12) & 0x7;
        ip += 2;
        if (op == op_sh) ip += 2; // skip the continuation word so it is not read as an opcode
        f(ctx, op);
    }
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

test "round-trip: high-value run >4095 exercises SH" {
    const line = [_]i32{70000} ** 8; // 70000 = 0x11170 -> low 0x170, high 17
    try expectRoundTrip(&line);
}

test "round-trip: value near 2^24" {
    const big: i32 = @intCast(mask_max); // 16777215 = 0xFFFFFF -> low 0xFFF, high 0xFFF
    const line = [_]i32{ 0, 0, big, big, big, 0, 1, big };
    try expectRoundTrip(&line);
}

test "round-trip: line exercising every opcode (ZN, SH, IH, DH, HN, PN, IS, DS)" {
    // ZN(zeros) IH+HN(5×3) IS(6) DS(2) IH+HN(60×2) DH+HN(10×2) SH+HN(70000×2) PN(gap+70000).
    const line = [_]i32{ 0, 0, 0, 5, 5, 5, 6, 2, 60, 60, 10, 10, 70000, 70000, 0, 0, 70000 };
    const enc = try compress(testing.allocator, &line);
    defer testing.allocator.free(enc);

    var seen = [_]bool{false} ** 8;
    forEachOpcode(enc, &seen, struct {
        fn mark(s: *[8]bool, op: u16) void {
            s[op] = true;
        }
    }.mark);
    for (seen, 0..) |hit, op| {
        if (!hit) {
            std.debug.print("opcode {d} never emitted\n", .{op});
            return error.TestUnexpectedResult;
        }
    }

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

const RegCount = struct { changes: usize = 0 };

test "round-trip: repeated label re-uses the high register" {
    // value 42 appears twice separated by zeros; the second run must move the register zero times.
    const line = [_]i32{ 42, 42, 0, 0, 42, 42, 42 };
    const enc = try compress(testing.allocator, &line);
    defer testing.allocator.free(enc);

    var rc = RegCount{};
    forEachOpcode(enc, &rc, struct {
        fn count(c: *RegCount, op: u16) void {
            switch (op) {
                op_sh, op_ih, op_dh, op_is, op_ds => c.changes += 1,
                else => {},
            }
        }
    }.count);
    try testing.expectEqual(@as(usize, 1), rc.changes); // only the first 42-run loads the register

    const dec = try decompress(testing.allocator, enc, line.len);
    defer testing.allocator.free(dec);
    try testing.expectEqualSlices(i32, &line, dec);
}

test "round-trip: sparse single labels fold into PN words" {
    // isolated 4s separated by zero gaps; after the first the register stays put, so PN applies.
    const line = [_]i32{ 0, 0, 4, 0, 0, 0, 4, 0, 4 };
    const enc = try compress(testing.allocator, &line);
    defer testing.allocator.free(enc);

    var saw_pn = false;
    forEachOpcode(enc, &saw_pn, struct {
        fn mark(p: *bool, op: u16) void {
            if (op == op_pn) p.* = true;
        }
    }.mark);
    try testing.expect(saw_pn);

    const dec = try decompress(testing.allocator, enc, line.len);
    defer testing.allocator.free(dec);
    try testing.expectEqualSlices(i32, &line, dec);
}

test "round-trip: randomized sparse masks" {
    var prng = std.Random.DefaultPrng.init(0xF175);
    const rand = prng.random();
    var buf: [512]i32 = undefined;
    var trial: usize = 0;
    while (trial < 64) : (trial += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*p| {
            // ~70% background, otherwise a label spanning the full 24-bit range.
            p.* = if (rand.intRangeAtMost(u8, 0, 9) < 7)
                0
            else
                @intCast(rand.intRangeAtMost(i64, 1, mask_max));
        }
        try expectRoundTrip(buf[0..len]);
    }
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

test "corrupt: truncated SH (missing following word)" {
    // A lone SH opcode word with no continuation word to supply the high bits.
    var buf: [2]u8 = undefined;
    endian.write(u16, (op_sh << 12) | 0x123, &buf);
    try testing.expectError(error.CorruptTile, decompress(testing.allocator, &buf, 4));
}

test "corrupt: SH high value escapes the 24-bit range" {
    // low 12 bits = 0, high 15 bits = 0x7FFF -> value 0x7FFF000, far above mask_max.
    var buf: [4]u8 = undefined;
    endian.write(u16, (op_sh << 12) | 0x000, buf[0..2]);
    endian.write(u16, 0x7FFF, buf[2..4]);
    try testing.expectError(error.CorruptTile, decompress(testing.allocator, &buf, 1));
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
