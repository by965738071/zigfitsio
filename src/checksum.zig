//! `DATASUM` and `CHECKSUM` data-integrity keywords (FR-SUM-1/2/3, §16; FITS 4.0 §4.4.2.7,
//! Appendix J).
//!
//! This module implements the standard FITS 1's-complement checksum in the CFITSIO `ff_csum`
//! form, the Seaman–Pence 16-character ASCII encoding of that checksum, and the read-side
//! verification of both keywords.
//!
//! - **`DATASUM`** is the 32-bit 1's-complement sum over the **whole padded data unit**
//!   (`ceil(data_bytes / 2880) * 2880` bytes from `hdu.data_off`, the trailing fill included —
//!   zero for images/binary tables, ASCII space `0x20` for ASCII tables). It is stored as an
//!   unsigned **decimal character string** in a string-valued keyword card.
//! - **`CHECKSUM`** is the whole-HDU (header + padded data) checksum encoded in the 16-character
//!   ASCII form, chosen so that the **complete HDU sums to all-ones** (`0xFFFFFFFF`). It is a
//!   string-valued keyword whose quotes fall in card columns 11–28 (its own bytes are part of
//!   the accumulated sum).
//!
//! Ordering is enforced by `update`: `DATASUM` is written **before** `CHECKSUM` is accumulated,
//! because the `CHECKSUM` covers the `DATASUM` card text (FR-SUM-1). Every multi-byte wire value
//! is read big-endian through `endian.read` (GC-5); the data unit is summed in block-aligned
//! chunks so a multi-GB HDU stays in bounded memory (NFR-PERF-3).
const std = @import("std");
const errors = @import("errors.zig");
const endian = @import("endian.zig");
const block = @import("io/block.zig");
const Fits = @import("fits.zig").Fits;
const FitsError = @import("fits.zig").FitsError;
const Hdu = @import("hdu.zig").Hdu;
const Header = @import("header/header.zig").Header;
const Card = @import("header/card.zig").Card;

const Allocator = std.mem.Allocator;

/// The fixed-format placeholder written into the `CHECKSUM` value field while the whole-HDU
/// checksum is accumulated. Each character is ASCII `'0'` (`0x30`); the 16 placeholder bytes
/// and the 16 final encoded bytes share the same `0xC0C0` self-contribution, so swapping one
/// for the other shifts the running sum by exactly the encoded value (Appendix J).
const ZERO_CHECKSUM: *const [16]u8 = "0000000000000000";

/// Bytes summed per device read in `datasum`/`hduSum`. A block multiple, so every chunk is a
/// multiple of four bytes (no per-chunk tail) and the accumulation stays bounded.
const CHUNK: usize = block.BLOCK * 4;

/// The three-way outcome of checking one integrity keyword (FR-SUM-2): the recomputed value
/// agreed (`match`), disagreed (`mismatch`), or the keyword was absent (`not_present`).
pub const Verify = enum { match, mismatch, not_present };

/// The result of `verify`: the `CHECKSUM` (`sum`) and `DATASUM` (`data`) outcomes.
pub const Report = struct {
    /// Outcome of the whole-HDU `CHECKSUM` test.
    sum: Verify,
    /// Outcome of the data-unit `DATASUM` test.
    data: Verify,
};

/// Error set produced by `verify`. Reads the device and the integrity cards; mismatches are
/// reported through `Report`, not as errors. `ChecksumError` is included for signature
/// conformance with §16.
pub const VerifyError = errors.ChecksumError || errors.IoError || errors.ValueError ||
    errors.HeaderError || Allocator.Error;

/// Error set produced by `update`: device I/O, card formatting, the staging allocation, and a
/// missing placeholder keyword.
pub const UpdateError = errors.IoError || errors.HeaderError || errors.StructError ||
    Allocator.Error;

/// Accumulate the FITS 1's-complement checksum of `bytes` into the running sum `prev`, returning
/// the new folded 32-bit value (CFITSIO `ff_csum` form).
///
/// `bytes` is walked in 4-byte **big-endian** groups (read through `endian.read`): each group's
/// high 16 bits are added to a high accumulator and its low 16 bits to a low accumulator, then
/// the carries are folded until both halves fit in 16 bits. A trailing run of fewer than four
/// bytes (only possible at a non-block-aligned end) is zero-padded on the right before summing.
/// Pass `0` for `prev` to start a fresh sum, or a previous result to continue one (the sum of a
/// concatenation equals continuing the accumulation, since FITS units are 4-byte aligned).
pub fn sumBytes(prev: u32, bytes: []const u8) u32 {
    // 64-bit accumulators so a large single buffer cannot overflow before the final fold.
    var hi: u64 = prev >> 16;
    var lo: u64 = prev & 0xFFFF;

    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        const g = endian.read(u32, bytes[i..][0..4]);
        hi += g >> 16;
        lo += g & 0xFFFF;
    }
    // Zero-padded tail (<4 bytes), summed only at a non-block-aligned end.
    if (i < bytes.len) {
        var tail = [4]u8{ 0, 0, 0, 0 };
        const rem = bytes.len - i;
        @memcpy(tail[0..rem], bytes[i..][0..rem]);
        const g = endian.read(u32, &tail);
        hi += g >> 16;
        lo += g & 0xFFFF;
    }

    // Fold the end-around carries until both halves are 16-bit.
    while (hi > 0xFFFF or lo > 0xFFFF) {
        const hicarry = hi >> 16;
        const locarry = lo >> 16;
        hi = (hi & 0xFFFF) + locarry;
        lo = (lo & 0xFFFF) + hicarry;
    }
    return @intCast((hi << 16) + lo);
}

/// Encode the 32-bit checksum `value` into the 16 ASCII bytes of a `CHECKSUM` value field, using
/// the Seaman–Pence algorithm (FITS 4.0 Appendix J).
///
/// Each of the four value bytes is spread over four characters whose sum equals the byte plus a
/// constant; ASCII punctuation between the digit/upper/lower ranges is avoided by an
/// incrementing fix-up that preserves that per-byte sum, and the result is rotated one position
/// to the right. `decodeChecksum` is the exact inverse. Callers that need the complement form
/// (so the HDU sums to all-ones) pass the complemented value here.
pub fn encodeChecksum(value: u32, out: *[16]u8) void {
    // The 13 ASCII punctuation codes that must not appear in the encoded field.
    const exclude = [13]u8{
        0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40,
        0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60,
    };
    const offset: u32 = 0x30; // ASCII '0'

    var asc: [16]u8 = undefined;
    var ii: usize = 0;
    while (ii < 4) : (ii += 1) {
        const shift: u5 = @intCast(24 - ii * 8);
        const byte: u32 = (value >> shift) & 0xFF;
        const quotient: u32 = byte / 4 + offset;
        const remainder: u32 = byte % 4;

        var ch = [4]u32{ quotient, quotient, quotient, quotient };
        ch[0] += remainder;

        // Nudge any character off a punctuation code, keeping the 4-character sum constant.
        var check = true;
        while (check) {
            check = false;
            for (exclude) |ex| {
                var jj: usize = 0;
                while (jj < 4) : (jj += 2) {
                    if (ch[jj] == ex or ch[jj + 1] == ex) {
                        ch[jj] += 1;
                        ch[jj + 1] -= 1;
                        check = true;
                    }
                }
            }
        }

        var jj: usize = 0;
        while (jj < 4) : (jj += 1) asc[4 * jj + ii] = @intCast(ch[jj]);
    }

    // Rotate the 16 characters one place to the right.
    var k: usize = 0;
    while (k < 16) : (k += 1) out[k] = asc[(k + 15) % 16];
}

/// Decode a 16-character `CHECKSUM` value field back to its 32-bit checksum value — the exact
/// inverse of `encodeChecksum`.
///
/// The rotation is undone, then for each of the four byte positions the four contributing
/// characters are summed (their sum is the byte plus the encoder's constant `0xC0`) and the
/// constant removed, reconstructing the big-endian value.
pub fn decodeChecksum(card16: *const [16]u8) u32 {
    var bytes = [4]u32{ 0, 0, 0, 0 };
    var ii: usize = 0;
    while (ii < 4) : (ii += 1) {
        var s: u32 = 0;
        var jj: usize = 0;
        while (jj < 4) : (jj += 1) {
            const m = 4 * jj + ii; // index into the un-rotated `asc` array
            s += card16[(m + 1) % 16]; // asc[m] == card16[(m+1) % 16]
        }
        // Wrapping subtract + mask: for encoder-produced input s ∈ [0xC0, 0x1BF] so this is
        // exactly `byte`; for an arbitrary/blank 16-byte field (s may be < 0xC0 or > 0x1BF) it
        // avoids the u32 underflow panic and keeps each byte ≤ 0xFF so the `<<24` cannot overflow.
        bytes[ii] = (s -% 0xC0) & 0xFF;
    }
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
}

/// Compute `DATASUM`: the 1's-complement checksum over the **padded** data unit of `hdu`
/// (`ceil(data_bytes / 2880) * 2880` bytes from `hdu.data_off`). The trailing block fill is
/// summed as written on disk (zero for images/binary tables, ASCII space for ASCII tables).
/// The unit is read in block-aligned chunks via `fits.dev`, so memory stays bounded (§16).
pub fn datasum(fits: *Fits, hdu: *Hdu) errors.IoError!u32 {
    return sumRange(fits, hdu.data_off, block.roundUpBlocks(hdu.data_bytes), 0);
}

// Sum `len` bytes from device offset `off`, seeded with `prev`. `len` is a block multiple, so
// every chunk read is a multiple of four bytes.
fn sumRange(fits: *Fits, off: u64, len: u64, prev: u32) errors.IoError!u32 {
    var sum = prev;
    var cur = off;
    var remaining = len;
    var buf: [CHUNK]u8 = undefined;
    while (remaining > 0) {
        const n: usize = @intCast(@min(@as(u64, CHUNK), remaining));
        try fits.dev.readAll(buf[0..n], cur);
        sum = sumBytes(sum, buf[0..n]);
        cur += n;
        remaining -= n;
    }
    return sum;
}

// Checksum of the (padded) header unit, computed from the in-memory cards plus the space fill
// to the next block boundary. The on-disk header is byte-identical (cards round-trip verbatim).
fn headerSum(header: *const Header) u32 {
    var sum: u32 = 0;
    for (header.cards.items) |*c| sum = sumBytes(sum, c.bytes());
    const used: u64 = @as(u64, header.count()) * block.CARD;
    const pad_len: usize = @intCast(block.roundUpBlocks(used) - used);
    if (pad_len > 0) {
        var spaces: [block.BLOCK]u8 = @splat(' '); // [_]u8{' '} ** block.BLOCK;
        sum = sumBytes(sum, spaces[0..pad_len]);
    }
    return sum;
}

// Whole-HDU checksum: the padded header (in memory) followed by the padded data unit (on disk).
fn hduSum(fits: *Fits, hdu: *Hdu) errors.IoError!u32 {
    const hs = headerSum(&hdu.header);
    return sumRange(fits, hdu.data_off, block.roundUpBlocks(hdu.data_bytes), hs);
}

// Index of the first non-END value/commentary card named `name`, or null.
fn findCardIndex(header: *const Header, name: []const u8) ?usize {
    for (header.cards.items, 0..) |*c, i| {
        if (c.kind == .end) continue;
        if (c.name.eqlText(name)) return i;
    }
    return null;
}

/// Recompute and write `DATASUM` then `CHECKSUM` for `hdu`, in that order (FR-SUM-1), and
/// rewrite the header to disk.
///
/// The header **must already contain placeholder `DATASUM` and `CHECKSUM` cards** (e.g.
/// `DATASUM = '0'`, `CHECKSUM = '0000000000000000'`); their values are replaced **in place** so
/// the card count — and therefore the data-unit offset — never changes. `DATASUM` is set first
/// (the `CHECKSUM` covers its card text); the `CHECKSUM` value is the Seaman–Pence encoding of
/// the complement of the whole-HDU sum, so the complete HDU then sums to all-ones. Returns
/// `error.MissingRequiredKeyword` if either placeholder card is absent.
pub fn update(fits: *Fits, hdu: *Hdu) UpdateError!void {
    const ds_idx = findCardIndex(&hdu.header, "DATASUM") orelse return error.MissingRequiredKeyword;
    const cs_idx = findCardIndex(&hdu.header, "CHECKSUM") orelse return error.MissingRequiredKeyword;

    // 1. DATASUM over the padded data unit, written as an unsigned decimal string (FR-SUM-1).
    const ds = try datasum(fits, hdu);
    var dbuf: [16]u8 = undefined;
    const dstr = std.fmt.bufPrint(&dbuf, "{d}", .{ds}) catch unreachable; // u32 ⇒ ≤10 digits
    hdu.header.cards.items[ds_idx] = try Card.buildValue("DATASUM", .{ .string = dstr }, "data unit checksum");

    // 2. Reset CHECKSUM to the placeholder, then accumulate the whole-HDU sum over it.
    hdu.header.cards.items[cs_idx] = try Card.buildValue("CHECKSUM", .{ .string = ZERO_CHECKSUM }, "HDU checksum");
    const s = try hduSum(fits, hdu);

    // 3. Encode the complement so the complete HDU sums to all-ones, and store it in place.
    var enc: [16]u8 = undefined;
    encodeChecksum(~s, &enc);
    hdu.header.cards.items[cs_idx] = try Card.buildValue("CHECKSUM", .{ .string = &enc }, "HDU checksum");

    // 4. Rewrite the (same-size) header unit to disk; the data unit is untouched.
    var bw = try block.BlockWriter.init(fits.alloc, fits.dev, hdu.header_off, 0);
    defer bw.deinit();
    try hdu.header.writeTo(&bw);
}

/// Reserve the `DATASUM`/`CHECKSUM` placeholder cards on `header` (idempotent). `checksum_on_close`
/// calls this at HDU-build time — before the header size, and thus the data offset, is fixed — so
/// the flush-time `update` only ever rewrites the two cards *in place* (a card is a fixed 80 bytes)
/// and never has to grow the header or shift the HDUs that follow.
pub fn ensureCards(header: *Header, alloc: Allocator) (errors.HeaderError || Allocator.Error)!void {
    if (findCardIndex(header, "DATASUM") == null)
        try header.update(alloc, "DATASUM", .{ .string = "0" }, "data unit checksum");
    if (findCardIndex(header, "CHECKSUM") == null)
        try header.update(alloc, "CHECKSUM", .{ .string = ZERO_CHECKSUM }, "HDU checksum");
}

/// The body of `Fits.checksum_hook`: invoked by `flush` when `checksum_on_close` is set (FR-SUM-3).
/// Recompute the integrity cards of every HDU that carries them — the HDUs `appendHdu` reserved via
/// `ensureCards`. An HDU lacking the cards (e.g. one read from an existing file rather than
/// appended) is skipped rather than forcing a header reflow on flush. The return type is the wider
/// `FitsError` (not `update`'s `UpdateError`) so `&updateAll` matches the hook's
/// `*const fn (*Fits) FitsError!void` pointer type exactly.
pub fn updateAll(fits: *Fits) FitsError!void {
    const n = try fits.hduCount();
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const hdu = try fits.select(i);
        if (findCardIndex(&hdu.header, "DATASUM") == null) continue;
        if (findCardIndex(&hdu.header, "CHECKSUM") == null) continue;
        try update(fits, hdu);
    }
}

/// Verify `hdu`'s integrity keywords (FR-SUM-2), reporting `match`/`mismatch`/`not_present` for
/// each.
///
/// `DATASUM` (if present) is read as a decimal string and compared with a fresh data-unit sum.
/// `CHECKSUM` (if present) is verified by recomputing the whole-HDU sum: a correctly-written
/// `CHECKSUM` makes the complete HDU sum to all-ones, so any other value is a mismatch. A
/// `DATASUM` value that does not parse as a number is reported as `mismatch`.
pub fn verify(fits: *Fits, hdu: *Hdu) VerifyError!Report {
    var report = Report{ .sum = .not_present, .data = .not_present };

    if (hdu.header.has("DATASUM")) {
        const stored = try hdu.header.getString(fits.alloc, "DATASUM");
        defer fits.alloc.free(stored);
        const trimmed = std.mem.trim(u8, stored, " ");
        const actual = try datasum(fits, hdu);
        report.data = blk: {
            const parsed = std.fmt.parseInt(u64, trimmed, 10) catch break :blk .mismatch;
            break :blk if (parsed == @as(u64, actual)) .match else .mismatch;
        };
    }

    if (hdu.header.has("CHECKSUM")) {
        const s = try hduSum(fits, hdu);
        report.sum = if (s == 0xFFFFFFFF) .match else .mismatch;
    }

    return report;
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("io/memory.zig").MemoryDevice;

test "sumBytes: zero buffer, known group, carry fold, accumulation, tail" {
    // All-zero ⇒ 0.
    try testing.expectEqual(@as(u32, 0), sumBytes(0, &[_]u8{ 0, 0, 0, 0 }));
    // A single big-endian 4-byte group is itself.
    try testing.expectEqual(@as(u32, 0x12345678), sumBytes(0, &[_]u8{ 0x12, 0x34, 0x56, 0x78 }));
    // Two all-ones groups fold the end-around carry back to all-ones.
    const ones: [8]u8 = @splat(0xFF);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), sumBytes(0, &ones));
    // Continuing the accumulation equals summing the concatenation.
    const a = [_]u8{ 1, 2, 3, 4 };
    const b = [_]u8{ 5, 6, 7, 8 };
    const ab = a ++ b;
    try testing.expectEqual(sumBytes(0, &ab), sumBytes(sumBytes(0, &a), &b));
    // A short tail is zero-padded on the right.
    try testing.expectEqual(
        sumBytes(0, &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0xAB, 0, 0, 0 }),
        sumBytes(0, &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0xAB }),
    );
}

test "encodeChecksum/decodeChecksum round-trip and produce a clean ASCII alphabet" {
    const exclude = [_]u8{
        0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40,
        0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60,
    };
    const vals = [_]u32{
        0,          1,          0xFFFFFFFF, 0x12345678,
        0xDEADBEEF, 628729719,  0x80000000, 0x0000FFFF,
        0xFFFF0000, 0x01020304, 0x7F7F7F7F,
    };
    for (vals) |v| {
        var buf: [16]u8 = undefined;
        encodeChecksum(v, &buf);
        for (buf) |c| {
            try testing.expect(c >= 0x30 and c <= 0x7A); // printable, within the alphabet
            try testing.expect(std.mem.indexOfScalar(u8, &exclude, c) == null);
        }
        try testing.expectEqual(v, decodeChecksum(&buf));
    }
}

test "decodeChecksum does not panic on a blank / out-of-alphabet 16-byte field" {
    // Regression: a blank CHECKSUM field sums each byte-column to 4*0x20 = 0x80 < 0xC0, so the
    // `s - 0xC0` subtraction underflowed u32 and panicked. It must now return a value, not crash.
    _ = decodeChecksum(&@as([16]u8, @splat(' ')));
    _ = decodeChecksum(&@as([16]u8, @splat(0)));
    _ = decodeChecksum(&@as([16]u8, @splat(0xFF))); // high end: must not overflow the <<24 reconstruction
}

test "encodeChecksum matches the FITS Appendix J.3 reference vector" {
    // Appendix J.3 worked example: the complemented sum 0xCC3FDFE2 encodes to this 16-char field.
    var buf: [16]u8 = undefined;
    encodeChecksum(0xCC3FDFE2, &buf);
    try testing.expectEqualStrings("hcHjjc9ghcEghc9g", &buf);
}

test "ASCII-table data unit is ASCII-space padded, changing DATASUM (FITS §3)" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary

    // A 1-column ASCII table (XTENSION='TABLE'); the data unit must be filled with 0x20, not 0x00.
    var h = Header.initEmpty();
    try h.appendValue(alloc, "XTENSION", .{ .string = "TABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = 10 }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = 3 }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TBCOL1", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFORM1", .{ .string = "I10" }, null);
    const hdu = try f.appendHdu(h); // ownership transferred

    // The reserved+padded data unit reads back as ASCII space everywhere it is untouched.
    var first: [1]u8 = undefined;
    try f.dev.readAll(&first, hdu.data_off);
    try testing.expectEqual(@as(u8, ' '), first[0]);

    // DATASUM over the space-padded unit differs from the zero-padded value it would have had.
    const space_sum = try datasum(&f, hdu);
    const padded = block.roundUpBlocks(hdu.data_bytes);
    const zeros = try alloc.alloc(u8, @intCast(padded));
    defer alloc.free(zeros);
    @memset(zeros, 0);
    try testing.expect(space_sum != sumBytes(0, zeros));
}

// Build a minimal primary image header (BITPIX=8, NAXIS=1) for the round-trip tests. With
// `checksum_cards`, placeholder DATASUM/CHECKSUM cards are appended so `update` can edit them in
// place. The errdefer is discharged on success; the returned header is handed to `appendHdu`.
fn makeImageHeader(alloc: Allocator, naxis1: u64, checksum_cards: bool) !Header {
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    try h.appendValue(alloc, "SIMPLE", .{ .logical = true }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 1 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = @intCast(naxis1) }, null);
    if (checksum_cards) {
        try h.appendValue(alloc, "DATASUM", .{ .string = "0" }, "data unit checksum");
        try h.appendValue(alloc, "CHECKSUM", .{ .string = "0000000000000000" }, "HDU checksum");
    }
    return h;
}

test "datasum over a created HDU's data unit matches a direct sum (create→write→read)" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    const header = try makeImageHeader(alloc, 100, false);
    const hdu = try f.appendHdu(header); // ownership transferred; data unit zero-filled

    var data: [100]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    try f.dev.writeAll(&data, hdu.data_off);

    // Expected: the padded 2880-byte unit — 100 data bytes then zero fill.
    var padded: [block.BLOCK]u8 = @splat(0);
    @memcpy(padded[0..100], &data);
    try testing.expectEqual(sumBytes(0, &padded), try datasum(&f, hdu));
}

test "verify reports not_present when the integrity cards are absent" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    const hdu = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{50} });
    const r = try verify(&f, hdu);
    try testing.expectEqual(Verify.not_present, r.data);
    try testing.expectEqual(Verify.not_present, r.sum);
}

test "update then verify reports match, and tampering is detected" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    const header = try makeImageHeader(alloc, 100, true);
    const hdu = try f.appendHdu(header);

    var data: [100]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 13 + 5);
    try f.dev.writeAll(&data, hdu.data_off);

    try update(&f, hdu);

    const r = try verify(&f, hdu);
    try testing.expectEqual(Verify.match, r.data);
    try testing.expectEqual(Verify.match, r.sum);

    // The whole HDU now sums to all-ones by construction.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), try hduSum(&f, hdu));

    // Corrupt one data byte: both keywords must now fail.
    var corrupt: [1]u8 = .{data[0] ^ 0xFF};
    try f.dev.writeAll(&corrupt, hdu.data_off);
    const r2 = try verify(&f, hdu);
    try testing.expectEqual(Verify.mismatch, r2.data);
    try testing.expectEqual(Verify.mismatch, r2.sum);
}

test "verify after reopen: persisted DATASUM/CHECKSUM round-trip through the device" {
    const alloc = testing.allocator;
    // Pin the device on the heap so it can outlive the writing handle and be reopened.
    const mem = try alloc.create(MemoryDevice);
    mem.* = MemoryDevice.init(alloc);
    defer {
        mem.deinit();
        alloc.destroy(mem);
    }

    {
        var f = try Fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        const header = try makeImageHeader(alloc, 64, true);
        const hdu = try f.appendHdu(header);
        var data: [64]u8 = undefined;
        for (&data, 0..) |*b, i| b.* = @truncate(i + 3);
        try f.dev.writeAll(&data, hdu.data_off);
        try update(&f, hdu);
        try f.flush();
    }

    var f = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(1);
    const r = try verify(&f, hdu);
    try testing.expectEqual(Verify.match, r.data);
    try testing.expectEqual(Verify.match, r.sum);
}

// Regression (FR-SUM-3): `checksum_on_close` must actually write verifiable integrity cards on
// `flush`, with no manual `update` call. Before the hook was registered this silently did nothing
// and `verify` returned `not_present` — this test would have caught that.
test "checksum_on_close: flush reserves and writes verifiable DATASUM/CHECKSUM (no manual update)" {
    const alloc = testing.allocator;
    const mem = try alloc.create(MemoryDevice);
    mem.* = MemoryDevice.init(alloc);
    defer {
        mem.deinit();
        alloc.destroy(mem);
    }

    {
        var f = try Fits.create(alloc, mem.device(), .{ .checksum_on_close = true });
        defer f.deinit();
        const hdu = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } });
        // The cards were reserved at append time (before the data offset was fixed).
        try testing.expect(findCardIndex(&hdu.header, "DATASUM") != null);
        try testing.expect(findCardIndex(&hdu.header, "CHECKSUM") != null);
        var data: [24]u8 = undefined;
        for (&data, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
        try f.dev.writeAll(&data, hdu.data_off);
        try f.flush(); // the hook fires here: DATASUM/CHECKSUM computed and written in place
    }

    var f = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(1);
    const r = try verify(&f, hdu);
    try testing.expectEqual(Verify.match, r.data);
    try testing.expectEqual(Verify.match, r.sum);
}

test "update requires the placeholder cards to exist" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    const hdu = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{16} });
    try testing.expectError(error.MissingRequiredKeyword, update(&f, hdu));
}
