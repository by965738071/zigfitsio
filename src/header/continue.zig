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
pub fn assemble(alloc: Allocator, cards: []const Card, i: usize, max_len: usize) (HeaderError || errors.LimitError || Allocator.Error)!?Assembled {
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
    // NFR-SAFE-1: bound the assembled length against limits.Limits.max_string_value so a long
    // run of CONTINUE cards cannot drive an unbounded allocation (DoS).
    if (buf.items.len > max_len) return error.LimitExceeded;

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
            if (buf.items.len > max_len) return error.LimitExceeded;
        } else {
            // Last card: keep its text verbatim (a trailing '&' here is literal).
            try buf.appendSlice(alloc, cs);
            if (buf.items.len > max_len) return error.LimitExceeded;
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

    const FIELD: usize = 70; // value-field width (cols 10..80)
    const ccost: usize = if (comment) |c| 3 + c.len else 0; // " / " + comment, on the final card

    // Single card if the quoted string PLUS any comment fits the value field. Accounting for the
    // comment here is what was missing: a 61–68 char string with a comment was wrongly forced
    // down the single-card path and then rejected by Card.buildValue with CardOverflow.
    if (2 + str.len + ccost <= FIELD) {
        try list.append(alloc, try Card.buildValue(name, .{ .string = str }, comment));
        return list.toOwnedSlice(alloc);
    }
    // A comment too long to fit even alone on a final card (`'' / comment`) is unrepresentable.
    if (comment != null and 2 + ccost > FIELD) return error.CardOverflow;

    // A terminal card that ALSO carries the comment has no continuation `&`, so its data capacity
    // is reduced by the comment cost. The room is reserved up front so the comment is never
    // silently dropped (the old code wrote it with `catch {}` after a full value field).
    const term_cap: usize = FIELD - 2 - ccost;

    var pos: usize = 0;
    var first = true;
    var comment_done = comment == null;
    while (pos < str.len) {
        const remaining = str.len - pos;
        const terminal = remaining <= term_cap; // all remaining data + the comment fit one card
        const take = if (terminal) remaining else @min(CHUNK, remaining);
        const chunk = str[pos .. pos + take];
        pos += take;
        // A `&` marks that more cards follow — either more data or the dedicated comment card.
        try list.append(alloc, try buildChunkCard(name, &first, chunk, !terminal, if (terminal) comment else null));
        if (terminal) {
            comment_done = true;
            break;
        }
    }
    // The data ran out on a continuation card (a chunk in (term_cap, CHUNK]); the comment still
    // needs a home, so place it on a dedicated empty-string continuation card (`'' / comment`),
    // which contributes nothing to the reassembled value.
    if (!comment_done) {
        try list.append(alloc, try buildChunkCard(name, &first, "", false, comment));
    }
    return list.toOwnedSlice(alloc);
}

// Build one CONTINUE-run card: the first card uses `name = '...`, the rest `CONTINUE  '...`. A
// trailing `&` (inside the quotes) is added when `continues`; a `/ comment` suffix when given.
fn buildChunkCard(name: []const u8, first: *bool, chunk: []const u8, continues: bool, comment: ?[]const u8) HeaderError!Card {
    var raw: [80]u8 = @splat(' ');
    if (first.*) {
        const nm = @import("name.zig").Name.parse(name) catch return error.BadKeywordName;
        @memcpy(raw[0..8], &nm.bytes);
        raw[8] = '=';
        raw[9] = ' ';
        first.* = false;
    } else {
        @memcpy(raw[0..8], "CONTINUE");
    }
    var w = std.Io.Writer.fixed(raw[10..]);
    w.writeByte('\'') catch return error.CardOverflow;
    w.writeAll(chunk) catch return error.CardOverflow;
    if (continues) w.writeByte('&') catch return error.CardOverflow;
    w.writeByte('\'') catch return error.CardOverflow;
    if (comment) |c| {
        w.writeAll(" / ") catch return error.CardOverflow;
        w.writeAll(c) catch return error.CardOverflow;
    }
    return Card.parse(&raw);
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

fn card80(s: []const u8) Card {
    var b: [80]u8 = @splat(' ');
    @memcpy(b[0..s.len], s);
    return Card.parse(&b) catch unreachable;
}

test "assemble a 3-card continued string (FITS §4.2.1.2 style)" {
    const cards = [_]Card{
        card80("WEATHER = 'Partly cloudy during the evening f&'"),
        card80("CONTINUE  'ollowed by cloudy skies overnight.&'"),
        card80("CONTINUE  ' Low 21C. Winds NNE at 5 to 10 mph.'"),
    };
    const a = try assemble(testing.allocator, &cards, 0, 1 << 20);
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
    const a = try assemble(testing.allocator, &cards, 0, 1 << 20);
    try testing.expect(a == null); // not a continuation; caller keeps the literal value "M31 &"
}

test "orphaned CONTINUE is not a value start" {
    const cards = [_]Card{
        card80("CONTINUE  'orphaned text'"),
    };
    const a = try assemble(testing.allocator, &cards, 0, 1 << 20);
    try testing.expect(a == null); // a CONTINUE card is commentary, not a value card
}

test "split then assemble round-trips a long string" {
    const long = "The quick brown fox jumps over the lazy dog, and then continues running across " ++
        "a very wide field for a considerable distance under a clear blue sky."; // > 68 chars
    const cards = try split(testing.allocator, "LONGKEY", long, "a comment");
    defer testing.allocator.free(cards);
    try testing.expect(cards.len >= 2); // it was split
    try testing.expect(cards[0].kind == .value);
    try testing.expect(cards[1].kind == .continuation);

    const a = try assemble(testing.allocator, cards, 0, 1 << 20);
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

test "split preserves the comment when the final data chunk would fill the card (no silent drop)" {
    // 135 chars: greedy 67-char chunking leaves a full 68-char final chunk, so the old code wrote
    // a full value field and then dropped the comment via `catch {}`. The comment must survive.
    const long = &@as([135]u8, @splat('x'));
    const cards = try split(testing.allocator, "DESC", long, "units");
    defer testing.allocator.free(cards);
    const a = try assemble(testing.allocator, cards, 0, 1 << 20);
    try testing.expect(a != null);
    defer testing.allocator.free(a.?.value);
    try testing.expectEqualStrings(long, a.?.value); // value still reassembles exactly
    const last = cards[cards.len - 1];
    try testing.expectEqualStrings("units", value.parseComment(last.valueField()).?);
}

test "split with a comment that overflows a single card falls through to multi-card" {
    // A 68-char string fits one card alone but not with a comment; it must split, not be rejected
    // with CardOverflow (regression: the single-card threshold ignored the comment).
    const s = &@as([68]u8, @splat('y'));
    const cards = try split(testing.allocator, "DESC", s, "note");
    defer testing.allocator.free(cards);
    try testing.expect(cards.len >= 2);
    const a = try assemble(testing.allocator, cards, 0, 1 << 20);
    try testing.expect(a != null);
    defer testing.allocator.free(a.?.value);
    try testing.expectEqualStrings(s, a.?.value);
    const last = cards[cards.len - 1];
    try testing.expectEqualStrings("note", value.parseComment(last.valueField()).?);
}
