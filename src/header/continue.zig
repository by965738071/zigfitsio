//! The `CONTINUE` long-string convention (FR-HDR-8, §9.3; FITS 4.0 §4.2.1.2).
//!
//! A string value longer than fits in one card is split across a primary card whose value
//! ends with an ampersand `&` and one or more `CONTINUE` cards, each also ending with `&`
//! except the last. `assemble` reassembles such a run into one owned string; `split` performs
//! the inverse for writing. Two edge cases are handled distinctly: a value ending in `&` with
//! **no** following `CONTINUE` keeps the `&` as a literal character (no continuation), and an
//! orphaned `CONTINUE` card (no preceding `&`) is treated as commentary, not part of a value.
const std = @import("std");
const errors = @import("../errors.zig");
const HeaderError = errors.HeaderError;
const Card = @import("card.zig").Card;
const value = @import("value.zig");

const Allocator = std.mem.Allocator;

/// Max string characters that fit in one card's value field alongside the continuation `&`:
/// the 70-column value field holds `'` + 67 chars + `&` + `'`.
pub const CHUNK: usize = 67;
/// Max string characters in a final (non-continued) card: `'` + 68 chars + `'`.
pub const LAST_CHUNK: usize = 68;

/// The result of `assemble`: the owned reassembled string and the number of cards it spanned
/// (the primary plus its `CONTINUE` cards).
pub const Assembled = struct {
    value: []u8,
    consumed: usize,
};

/// Reassemble the long string value beginning at card `i`. Returns `null` when card `i` is
/// not a string value that actually continues (so the caller uses the single-card value as-is,
/// keeping any literal trailing `&`). The returned `value` is allocator-owned.
pub fn assemble(alloc: Allocator, cards: []const Card, i: usize) (HeaderError || Allocator.Error)!?Assembled {
    if (i >= cards.len or cards[i].kind != .value) return null;
    const first = value.parseValue(alloc, cards[i].valueField()) catch return null;
    defer first.deinit(alloc);
    const s0 = switch (first) {
        .string => |s| s,
        else => return null,
    };
    // Continues only if it ends with '&' AND a CONTINUE card follows; otherwise '&' is literal.
    if (s0.len == 0 or s0[s0.len - 1] != '&') return null;
    if (i + 1 >= cards.len or cards[i + 1].kind != .continuation) return null;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, s0[0 .. s0.len - 1]);

    var consumed: usize = 1;
    var j = i + 1;
    while (j < cards.len and cards[j].kind == .continuation) : (j += 1) {
        const cv = value.parseValue(alloc, cards[j].valueField()) catch break;
        defer cv.deinit(alloc);
        const cs = switch (cv) {
            .string => |s| s,
            else => break,
        };
        consumed += 1;
        const continues = cs.len > 0 and cs[cs.len - 1] == '&' and
            (j + 1 < cards.len and cards[j + 1].kind == .continuation);
        if (continues) {
            try buf.appendSlice(alloc, cs[0 .. cs.len - 1]);
        } else {
            // Last card: keep its text verbatim (a trailing '&' here is literal).
            try buf.appendSlice(alloc, cs);
            break;
        }
    }
    return .{ .value = try buf.toOwnedSlice(alloc), .consumed = consumed };
}

/// Split a string value into a primary card plus `CONTINUE` cards (FR-HDR-8). Short strings
/// that fit in one card produce a single card. The returned slice is allocator-owned (free it
/// and not the individual cards). `name` is the keyword; `comment` is attached to the last card.
pub fn split(alloc: Allocator, name: []const u8, str: []const u8, comment: ?[]const u8) (HeaderError || Allocator.Error)![]Card {
    var list: std.ArrayList(Card) = .empty;
    errdefer list.deinit(alloc);

    // Fits in a single card?
    if (str.len <= LAST_CHUNK) {
        try list.append(alloc, try Card.buildValue(name, .{ .string = str }, comment));
        return list.toOwnedSlice(alloc);
    }

    var pos: usize = 0;
    var first = true;
    while (pos < str.len) {
        const remaining = str.len - pos;
        const is_last = remaining <= LAST_CHUNK;
        const take = if (is_last) remaining else CHUNK;
        const chunk = str[pos .. pos + take];
        pos += take;

        var raw: [80]u8 = [_]u8{' '} ** 80;
        if (first) {
            const nm = @import("name.zig").Name.parse(name) catch return error.BadKeywordName;
            @memcpy(raw[0..8], &nm.bytes);
            raw[8] = '=';
            raw[9] = ' ';
            first = false;
        } else {
            @memcpy(raw[0..8], "CONTINUE");
        }
        var w = std.Io.Writer.fixed(raw[10..]);
        w.writeByte('\'') catch return error.CardOverflow;
        w.writeAll(chunk) catch return error.CardOverflow;
        if (!is_last) w.writeByte('&') catch return error.CardOverflow;
        w.writeByte('\'') catch return error.CardOverflow;
        if (is_last) {
            if (comment) |c| {
                w.writeAll(" / ") catch {};
                w.writeAll(c) catch {};
            }
        }
        try list.append(alloc, try Card.parse(&raw));
    }
    return list.toOwnedSlice(alloc);
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

fn card80(s: []const u8) Card {
    var b: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(b[0..s.len], s);
    return Card.parse(&b) catch unreachable;
}

test "assemble a 3-card continued string (FITS §4.2.1.2 style)" {
    const cards = [_]Card{
        card80("WEATHER = 'Partly cloudy during the evening f&'"),
        card80("CONTINUE  'ollowed by cloudy skies overnight.&'"),
        card80("CONTINUE  ' Low 21C. Winds NNE at 5 to 10 mph.'"),
    };
    const a = try assemble(testing.allocator, &cards, 0);
    try testing.expect(a != null);
    defer testing.allocator.free(a.?.value);
    try testing.expectEqual(@as(usize, 3), a.?.consumed);
    try testing.expectEqualStrings(
        "Partly cloudy during the evening followed by cloudy skies overnight. Low 21C. Winds NNE at 5 to 10 mph.",
        a.?.value,
    );
}

test "value ending in '&' with no following CONTINUE keeps '&' literal" {
    const cards = [_]Card{
        card80("OBJECT  = 'M31 &'"),
        card80("BITPIX  =                    8"),
    };
    const a = try assemble(testing.allocator, &cards, 0);
    try testing.expect(a == null); // not a continuation; caller keeps the literal value "M31 &"
}

test "orphaned CONTINUE is not a value start" {
    const cards = [_]Card{
        card80("CONTINUE  'orphaned text'"),
    };
    const a = try assemble(testing.allocator, &cards, 0);
    try testing.expect(a == null); // a CONTINUE card is commentary, not a value card
}

test "split then assemble round-trips a long string" {
    const long = "The quick brown fox jumps over the lazy dog, and then continues running across " ++
        "a very wide field for a considerable distance under a clear blue sky." ; // > 68 chars
    const cards = try split(testing.allocator, "LONGKEY", long, "a comment");
    defer testing.allocator.free(cards);
    try testing.expect(cards.len >= 2); // it was split
    try testing.expect(cards[0].kind == .value);
    try testing.expect(cards[1].kind == .continuation);

    const a = try assemble(testing.allocator, cards, 0);
    try testing.expect(a != null);
    defer testing.allocator.free(a.?.value);
    try testing.expectEqualStrings(long, a.?.value);
    try testing.expectEqual(cards.len, a.?.consumed);
}

test "split keeps a short string in one card" {
    const cards = try split(testing.allocator, "OBJECT", "M31", null);
    defer testing.allocator.free(cards);
    try testing.expectEqual(@as(usize, 1), cards.len);
    try testing.expect(cards[0].kind == .value);
}
