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

/// Max string columns that fit in one card's value field alongside the continuation `&`:
/// the 70-column value field holds `'` + 67 columns + `&` + `'`. Counts *escaped* text — a
/// `''` pair occupies two columns.
pub const CHUNK: usize = 67;
/// Max string columns in a final (non-continued) card: `'` + 68 columns + `'`.
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

    // Single card if the RENDERED string PLUS any comment fits the value field. Rendered width is
    // what Card.buildValue actually emits: `''` escapes count two columns and short strings are
    // blank-padded to the 8-char fixed-format minimum — counting raw characters here undercounted
    // quote-bearing strings near the boundary into a spurious CardOverflow.
    const esc_len = value.escapedLen(str);
    const rendered = esc_len + (if (str.len < value.MIN_STRING_CHARS) value.MIN_STRING_CHARS - str.len else 0);
    if (2 + rendered + ccost <= FIELD) {
        try list.append(alloc, try Card.buildValue(name, .{ .string = str }, comment));
        return list.toOwnedSlice(alloc);
    }
    // A comment too long to fit even alone on a final card (`'' / comment`) is unrepresentable.
    if (comment != null and 2 + ccost > FIELD) return error.CardOverflow;

    // Chunk the ESCAPED text: `assemble` un-escapes each card independently, so every chunk must
    // be well-formed on its own — quotes are doubled up front and a cut never lands inside a
    // `''` pair (the old code wrote raw chunks with no escaping at all, emitting malformed cards
    // for any continued string containing a quote).
    const esc = try alloc.alloc(u8, esc_len);
    defer alloc.free(esc);
    value.escapeQuotes(str, esc);

    // A terminal card that ALSO carries the comment has no continuation `&`, so its data capacity
    // is reduced by the comment cost. The room is reserved up front so the comment is never
    // silently dropped (the old code wrote it with `catch {}` after a full value field).
    const term_cap: usize = FIELD - 2 - ccost;

    var pos: usize = 0;
    var first = true;
    var comment_done = comment == null;
    while (pos < esc.len) {
        const remaining = esc.len - pos;
        const terminal = remaining <= term_cap; // all remaining data + the comment fit one card
        const take = if (terminal) remaining else pairSafeTake(esc[pos..], @min(CHUNK, remaining));
        const chunk = esc[pos .. pos + take];
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

// Largest cut ≤ `want` that does not land between the two quotes of a `''` escape pair. `esc`
// is fully escaped and `pos` only ever advances by pair-safe takes, so the slice always starts
// on a pair boundary and a left-to-right walk decides pair membership unambiguously.
fn pairSafeTake(esc: []const u8, want: usize) usize {
    var j: usize = 0;
    while (j < want) {
        if (esc[j] == '\'') {
            if (j + 1 == want) return want - 1; // cut would split the pair — back off one column
            j += 2;
        } else {
            j += 1;
        }
    }
    return want;
}

/// Whether a raw value field holds a *string* whose content ends with the `&` continuation
/// sentinel (trailing blanks inside the quotes are not significant, FITS 4.0 §4.2.1).
/// Allocation-free; mirrors `value.parseString`'s `''`-escape and lone-quote-closes rules so it
/// always agrees with `assemble` about which cards continue. Used by `Header.delete` to remove
/// a long string's CONTINUE run together with its base card.
pub fn endsWithSentinel(field: []const u8) bool {
    var i: usize = 0;
    while (i < field.len and field[i] == ' ') i += 1;
    if (i >= field.len or field[i] != '\'') return false; // not a string value
    i += 1;
    var last: u8 = 0; // last non-blank content byte seen
    while (i < field.len) {
        const c = field[i];
        if (c == '\'') {
            if (i + 1 < field.len and field[i + 1] == '\'') {
                last = '\''; // escaped quote is content
                i += 2;
                continue;
            }
            return last == '&'; // lone quote closes the string
        }
        if (c != ' ') last = c;
        i += 1;
    }
    return false; // unterminated string — never a continuation
}

// Build one CONTINUE-run card: the first card uses `name = '...`, the rest `CONTINUE  '...`. A
// trailing `&` (inside the quotes) is added when `continues`; a `/ comment` suffix when given.
// `chunk` is pre-escaped text (quotes already doubled) written verbatim between the quotes.
fn buildChunkCard(name: []const u8, first: *bool, chunk: []const u8, continues: bool, comment: ?[]const u8) HeaderError!Card {
    var raw: [80]u8 = @splat(' ');
    if (first.*) {
        const nm = @import("name.zig").Name.parseStrict(name) catch return error.BadKeywordName;
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

test "split escapes embedded quotes and round-trips (BUGHUNT 22/23)" {
    // The old multi-card path wrote chunks verbatim with no '' escaping, emitting malformed
    // cards for any continued string containing a quote. Every card must also parse as a
    // well-formed string on its own, since `assemble` un-escapes per card.
    const long = "it's a 'quoted' tale: " ++ "pad " ** 30 ++ "the 'end'";
    const cards = try split(testing.allocator, "STORY", long, "with 'quotes'");
    defer testing.allocator.free(cards);
    try testing.expect(cards.len >= 2);
    for (cards) |c| {
        const v = try value.parseValue(testing.allocator, c.valueField());
        defer v.deinit(testing.allocator);
        try testing.expect(v == .string); // each card individually well-formed
    }
    const a = try assemble(testing.allocator, cards, 0, 1 << 20);
    try testing.expect(a != null);
    defer testing.allocator.free(a.?.value);
    try testing.expectEqualStrings(long, a.?.value);
    try testing.expectEqualStrings("with 'quotes'", value.parseComment(cards[cards.len - 1].valueField()).?);
}

test "split never cuts a '' escape pair across cards (offset sweep)" {
    // Slide a quote across every position of the first two card boundaries; each split must
    // round-trip exactly and no card may end in a dangling half of a '' pair.
    var offset: usize = 0;
    while (offset < 80) : (offset += 1) {
        var buf: [150]u8 = undefined;
        for (&buf, 0..) |*b, k| b.* = if (k == offset or k == offset + 1) '\'' else 'x';
        const cards = try split(testing.allocator, "SWEEP", &buf, null);
        defer testing.allocator.free(cards);
        const a = try assemble(testing.allocator, cards, 0, 1 << 20);
        try testing.expect(a != null);
        defer testing.allocator.free(a.?.value);
        try testing.expectEqualStrings(&buf, a.?.value);
    }
}

test "single-card threshold counts the escaped width (was spurious CardOverflow)" {
    // 67 raw chars with two quotes render as 69 escaped + 2 delimiters = 71 > 70: the old
    // threshold (raw length) chose the single-card path and buildValue then failed with
    // CardOverflow; the string must split instead.
    const s = "''" ++ "z" ** 65;
    const cards = try split(testing.allocator, "EDGE", s, null);
    defer testing.allocator.free(cards);
    try testing.expect(cards.len >= 2);
    const a = try assemble(testing.allocator, cards, 0, 1 << 20);
    try testing.expect(a != null);
    defer testing.allocator.free(a.?.value);
    try testing.expectEqualStrings(s, a.?.value);
}

test "short string with a huge comment splits instead of CardOverflow (BUGHUNT 38)" {
    // "ab" renders as 8 padded chars, so 2+8+3+60 = 73 > 70: the old threshold (raw length,
    // no padding) chose the single-card path and buildValue rejected it.
    const comment = "c" ** 60;
    const cards = try split(testing.allocator, "AB", "ab", comment);
    defer testing.allocator.free(cards);
    const a = try assemble(testing.allocator, cards, 0, 1 << 20);
    if (a) |asm_| {
        defer testing.allocator.free(asm_.value);
        try testing.expectEqualStrings("ab", asm_.value);
    } else {
        // Emitted as one free-format card; the value must still parse exactly.
        const v = try value.parseValue(testing.allocator, cards[0].valueField());
        defer v.deinit(testing.allocator);
        try testing.expectEqualStrings("ab", v.string);
    }
    try testing.expectEqualStrings(comment, value.parseComment(cards[cards.len - 1].valueField()).?);
}

test "endsWithSentinel mirrors parseString's escape and termination rules" {
    try testing.expect(endsWithSentinel("'abc&'"));
    try testing.expect(endsWithSentinel("  'abc&'  / comment"));
    try testing.expect(endsWithSentinel("'ab''cd&'")); // escaped quote is content
    try testing.expect(endsWithSentinel("'abc&   '")); // trailing blanks not significant
    try testing.expect(!endsWithSentinel("'abc'")); // no sentinel
    try testing.expect(!endsWithSentinel("'ab&''")); // content continues past the escaped quote → unterminated
    try testing.expect(!endsWithSentinel("'ab&c'")); // sentinel not last
    try testing.expect(!endsWithSentinel("'abc&")); // unterminated
    try testing.expect(!endsWithSentinel("42 / not a string"));
    try testing.expect(!endsWithSentinel(""));
    try testing.expect(!endsWithSentinel("''")); // empty string
}
