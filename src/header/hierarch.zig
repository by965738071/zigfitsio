//! The `HIERARCH` long/hierarchical keyword convention (FR-HDR-9, §9.3; FITS Registry).
//!
//! A `HIERARCH` card carries a hierarchical, possibly long keyword name after the literal
//! `HIERARCH` token, separated from its value by `=`:
//!
//!     HIERARCH ESO DET CHIP1 NAME = 'CCD1' / detector name
//!
//! Because bytes 9–10 are not the `= ` value indicator, the card layer classifies a `HIERARCH`
//! card as **commentary** (preserved verbatim). This module interprets those cards: it extracts
//! the hierarchical name and the value, builds new `HIERARCH` cards, and looks one up by either
//! the spaced token form (`ESO DET CHIP1 NAME`) or the full `HIERARCH …` spelling.
const std = @import("std");
const errors = @import("../errors.zig");
const HeaderError = errors.HeaderError;
const Card = @import("card.zig").Card;
const value = @import("value.zig");

const Allocator = std.mem.Allocator;

/// Whether `card` is a `HIERARCH` card (its name field is exactly `HIERARCH`).
pub fn isHierarch(card: *const Card) bool {
    return card.name.eqlText("HIERARCH");
}

/// The hierarchical keyword name of a `HIERARCH` card — the text between `HIERARCH` and the
/// first `=`, with runs of spaces collapsed to single spaces, written into `out`. Returns the
/// slice of `out` used, or `null` if `card` is not a well-formed `HIERARCH` card. `out` should
/// be at least 70 bytes.
pub fn keyword(card: *const Card, out: []u8) ?[]const u8 {
    if (!isHierarch(card)) return null;
    const rest = card.raw[8..]; // bytes 9–80
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    const name_part = std.mem.trim(u8, rest[0..eq], " ");
    if (name_part.len == 0) return null;
    // Collapse internal whitespace runs to single spaces.
    var n: usize = 0;
    var prev_space = false;
    for (name_part) |c| {
        const is_space = c == ' ';
        if (is_space) {
            if (prev_space) continue;
            prev_space = true;
        } else prev_space = false;
        if (n >= out.len) return null;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

/// Parse the value of a `HIERARCH` card (everything after the first `=`). Allocates a string
/// payload via `alloc`. `null` if `card` is not a well-formed `HIERARCH` card.
pub fn parseValue(alloc: Allocator, card: *const Card) (HeaderError || errors.ValueError || Allocator.Error)!?value.KeywordValue {
    if (!isHierarch(card)) return null;
    const rest = card.raw[8..];
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    return try value.parseValue(alloc, rest[eq + 1 ..]);
}

/// Build a `HIERARCH` card for hierarchical name `name` (spaced tokens) with value `v` and an
/// optional comment. `error.CardOverflow` if it does not fit in 80 bytes.
pub fn build(name: []const u8, v: value.KeywordValue, comment: ?[]const u8) HeaderError!Card {
    var raw: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(raw[0..8], "HIERARCH");
    var w = std.Io.Writer.fixed(raw[8..]);
    w.writeByte(' ') catch return error.CardOverflow;
    w.writeAll(std.mem.trim(u8, name, " ")) catch return error.CardOverflow;
    w.writeAll(" = ") catch return error.CardOverflow;
    formatFree(&w, v) catch return error.CardOverflow;
    if (comment) |c| {
        w.writeAll(" / ") catch return error.CardOverflow;
        w.writeAll(c) catch return error.CardOverflow;
    }
    // Validate printable ASCII via the normal card parser (kind will be .commentary).
    return Card.parse(&raw);
}

// Free-format (compact) value writer for HIERARCH cards (the fixed-format 20-column padding
// of mandatory keywords does not apply to the long-keyword convention).
fn formatFree(w: *std.Io.Writer, v: value.KeywordValue) std.Io.Writer.Error!void {
    switch (v) {
        .int => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{e}", .{f}),
        .logical => |b| try w.writeAll(if (b) "T" else "F"),
        .complex_int => |c| try w.print("({d}, {d})", .{ c[0], c[1] }),
        .complex_float => |c| try w.print("({e}, {e})", .{ c[0], c[1] }),
        .string => |s| {
            try w.writeByte('\'');
            for (s) |ch| {
                if (ch == '\'') try w.writeAll("''") else try w.writeByte(ch);
            }
            try w.writeByte('\'');
        },
        .undefined => {},
    }
}

/// Case-insensitive comparison of a `HIERARCH` card's name to `query`. `query` may be the
/// spaced token form (`ESO DET CHIP1 NAME`) or the full form (`HIERARCH ESO DET CHIP1 NAME`).
pub fn matchName(card: *const Card, query: []const u8) bool {
    var buf: [70]u8 = undefined;
    const kw = keyword(card, &buf) orelse return false;
    var q = std.mem.trim(u8, query, " ");
    if (std.ascii.startsWithIgnoreCase(q, "HIERARCH ")) q = std.mem.trim(u8, q[9..], " ");
    return tokensEqualIgnoreCase(kw, q);
}

// Compare two space-separated token strings ignoring case and collapsing whitespace.
fn tokensEqualIgnoreCase(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeScalar(u8, a, ' ');
    var ib = std.mem.tokenizeScalar(u8, b, ' ');
    while (true) {
        const ta = ia.next();
        const tb = ib.next();
        if (ta == null and tb == null) return true;
        if (ta == null or tb == null) return false;
        if (!std.ascii.eqlIgnoreCase(ta.?, tb.?)) return false;
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

fn card80(s: []const u8) Card {
    var b: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(b[0..s.len], s);
    return Card.parse(&b) catch unreachable;
}

test "parse a HIERARCH card: name and value" {
    const c = card80("HIERARCH ESO DET CHIP1 NAME = 'CCD1' / detector name");
    try testing.expect(isHierarch(&c));
    var buf: [70]u8 = undefined;
    try testing.expectEqualStrings("ESO DET CHIP1 NAME", keyword(&c, &buf).?);
    const v = (try parseValue(testing.allocator, &c)).?;
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("CCD1", v.string);
}

test "HIERARCH numeric value" {
    const c = card80("HIERARCH ESO INS TEMP = 12.5 / Celsius");
    const v = (try parseValue(testing.allocator, &c)).?;
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 12.5), v.float);
}

test "build a HIERARCH card and round-trip it" {
    const c = try build("ESO DET CHIP1 GAIN", .{ .float = 2.1 }, "e-/ADU");
    try testing.expect(isHierarch(&c));
    var buf: [70]u8 = undefined;
    try testing.expectEqualStrings("ESO DET CHIP1 GAIN", keyword(&c, &buf).?);
    const v = (try parseValue(testing.allocator, &c)).?;
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 2.1), v.float);
}

test "matchName accepts both spellings, case-insensitive, whitespace-collapsed" {
    const c = card80("HIERARCH ESO  DET CHIP1 NAME = 'x'"); // note double space
    try testing.expect(matchName(&c, "ESO DET CHIP1 NAME"));
    try testing.expect(matchName(&c, "eso det chip1 name"));
    try testing.expect(matchName(&c, "HIERARCH ESO DET CHIP1 NAME"));
    try testing.expect(!matchName(&c, "ESO DET CHIP2 NAME"));
    try testing.expect(!matchName(&c, "ESO DET"));
}

test "non-HIERARCH card yields null" {
    const c = card80("BITPIX  =                    8");
    try testing.expect(!isHierarch(&c));
    var buf: [70]u8 = undefined;
    try testing.expect(keyword(&c, &buf) == null);
    try testing.expect((try parseValue(testing.allocator, &c)) == null);
}
