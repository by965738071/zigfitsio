//! The 80-byte header card: parsing, classification, and byte-exact preservation
//! (`FR-HDR-1/2/6`, §9.1; FITS 4.0 §4.1, §4.4.2.4).
//!
//! A card is exactly 80 bytes of printable ASCII (`0x20`–`0x7E`); any control character is
//! `error.NonAsciiInHeader`. Layout: keyword name in bytes 1–8, the optional value indicator
//! `= ` in bytes 9–10, value/comment text in bytes 11–80.
//!
//! The single most error-prone rule in the format is "is this a value card?" This module
//! encodes `FR-HDR-6` **exactly** (see `classify`): a card is a *value* card **iff** bytes
//! 9–10 are `= ` (`0x3D 0x20`) **and** its name is not a commentary keyword
//! (`COMMENT`/`HISTORY`/blank). Anything else — no indicator, or a commentary name even when
//! `= ` appears — is commentary with free text in bytes 9–80 and is **preserved, never
//! rejected**. The `raw` bytes are kept verbatim so an unmodified card round-trips bit for
//! bit (`FR-HDR-5`).
const std = @import("std");
const HeaderError = @import("../errors.zig").HeaderError;
const Name = @import("name.zig").Name;
const value = @import("value.zig");

/// One 80-byte FITS keyword record (§9.1). `raw` is the canonical on-disk form and the
/// round-trip source of truth; `name` and `kind` are the parsed views over it.
pub const Card = struct {
    /// The verbatim 80 on-disk bytes (printable ASCII). Unmodified cards round-trip exactly.
    raw: [80]u8,
    /// The normalized 8-byte keyword name (upper-cased, space-padded) from bytes 1–8.
    name: Name,
    /// The classification of this card (see `classify`).
    kind: Kind,

    /// What a card *is*, per the `FR-HDR-6` classification rule.
    pub const Kind = enum {
        /// A keyword with a value: `= ` indicator in bytes 9–10 and a non-commentary name.
        value,
        /// `COMMENT`/`HISTORY`, or a blank keyword with free text — free text in bytes 9–80.
        commentary,
        /// An entirely blank card (all 80 bytes are spaces).
        blank,
        /// The `END` card that terminates the header.
        end,
        /// A `CONTINUE` long-string continuation card (commentary-like; classified by name).
        continuation,
    };

    /// Parse exactly 80 bytes into a `Card`, validating and classifying without allocating.
    ///
    /// Every byte must be printable ASCII (`0x20`–`0x7E`); any control or high byte yields
    /// `error.NonAsciiInHeader`. The keyword field (bytes 1–8) is normalized via `Name.parse`,
    /// which rejects an illegal name alphabet with `error.BadKeywordName`. The `raw` bytes are
    /// copied verbatim, so `bytes()` reproduces the input exactly.
    pub fn parse(raw: *const [80]u8) HeaderError!Card {
        for (raw) |b| {
            if (b < 0x20 or b > 0x7E) return error.NonAsciiInHeader;
        }
        const name = try Name.parse(raw[0..8]);
        return .{ .raw = raw.*, .name = name, .kind = classify(&name, raw) };
    }

    /// Build a value card `NAME    = <value> / comment` into 80 space-padded bytes.
    ///
    /// The name is normalized (`Name.parseStrict` errors on a bad alphabet or on blanks
    /// that are not trailing padding); the value indicator `= ` is placed in bytes 9–10;
    /// `v` is rendered into the value field by `value.zig` (fixed-format for numbers and
    /// logicals), followed by `/ comment` when `comment` is non-null. A non-finite real
    /// (NaN/Inf) yields `error.BadValueSyntax` — the FITS real grammar cannot express it
    /// (`value.requireFinite`). A value or comment
    /// too long for the 70-byte field yields `error.CardOverflow`; the result is re-parsed
    /// so its `kind` reflects the `FR-HDR-6` rule (e.g. a commentary name stays commentary
    /// even with the indicator present).
    pub fn buildValue(name_field: []const u8, v: value.KeywordValue, comment: ?[]const u8) HeaderError!Card {
        const name = try Name.parseStrict(name_field);
        try value.requireFinite(v);
        var raw: [80]u8 = [_]u8{' '} ** 80;
        @memcpy(raw[0..8], &name.bytes);
        raw[8] = '=';
        raw[9] = ' ';
        var w = std.Io.Writer.fixed(raw[10..]);
        value.formatValue(&w, v) catch return error.CardOverflow;
        if (comment) |c| {
            w.writeAll(" / ") catch return error.CardOverflow;
            w.writeAll(c) catch return error.CardOverflow;
        }
        return parse(&raw);
    }

    /// The canonical 80 on-disk bytes — the round-trip source of truth (`FR-HDR-5`).
    pub fn bytes(self: *const Card) *const [80]u8 {
        return &self.raw;
    }

    /// The value field: card bytes 11–80 (0-based indices 10–80). Meaningful for `.value`
    /// cards; pass to `value.parseValue`/`value.parseComment`. Returned untrimmed.
    pub fn valueField(self: *const Card) []const u8 {
        return self.raw[10..];
    }

    /// The commentary free text: card bytes 9–80 (0-based indices 8–80). Meaningful for
    /// `.commentary`/`.continuation` cards. Returned untrimmed.
    pub fn commentaryText(self: *const Card) []const u8 {
        return self.raw[8..];
    }
};

// The exact `FR-HDR-6` classification. `END` and `CONTINUE` are recognized by name first;
// a blank keyword is `.blank` only when the whole card is blank, else it is a (blank-keyword)
// commentary card. A non-commentary name with `= ` in bytes 9–10 is the lone `.value` case;
// everything else is commentary and is preserved.
fn classify(name: *const Name, raw: *const [80]u8) Card.Kind {
    if (name.isEnd()) return .end;
    if (std.mem.eql(u8, name.text(), "CONTINUE")) return .continuation;
    if (name.isBlank()) return if (isAllBlank(raw)) .blank else .commentary;
    if (name.isCommentary()) return .commentary; // COMMENT / HISTORY
    if (raw[8] == '=' and raw[9] == ' ') return .value;
    return .commentary;
}

// Whether all 80 card bytes are ASCII spaces.
fn isAllBlank(raw: *const [80]u8) bool {
    for (raw) |b| {
        if (b != ' ') return false;
    }
    return true;
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

// Build an 80-byte card: `s` left-justified, space-padded. Caller ensures `s.len <= 80`.
fn card80(s: []const u8) [80]u8 {
    var b: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(b[0..s.len], s);
    return b;
}

test "normal value card classifies as value and round-trips its bytes" {
    const raw = card80("BITPIX  =                   16 / bits per pixel");
    const c = try Card.parse(&raw);
    try testing.expectEqual(Card.Kind.value, c.kind);
    try testing.expectEqualStrings("BITPIX", c.name.text());
    // Round-trip fidelity: the stored bytes equal the input verbatim.
    try testing.expectEqualSlices(u8, &raw, c.bytes());
    // The value field re-parses to the integer with its comment intact.
    const v = try value.parseValue(testing.allocator, c.valueField());
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 16), v.int);
    try testing.expectEqualStrings("bits per pixel", value.parseComment(c.valueField()).?);
}

test "COMMENT with a '= ' indicator stays commentary (the acceptance rule)" {
    const raw = card80("COMMENT = this looks like a value but is not");
    const c = try Card.parse(&raw);
    try testing.expectEqual(Card.Kind.commentary, c.kind);
    try testing.expectEqualStrings("COMMENT", c.name.text());
    try testing.expectEqualStrings(raw[8..], c.commentaryText());
    try testing.expectEqualSlices(u8, &raw, c.bytes()); // preserved, not rejected
}

test "HISTORY is commentary" {
    const raw = card80("HISTORY processed by pipeline v2");
    const c = try Card.parse(&raw);
    try testing.expectEqual(Card.Kind.commentary, c.kind);
    try testing.expectEqualStrings("HISTORY", c.name.text());
}

test "an entirely blank card is .blank, a blank keyword with text is commentary" {
    const blank = card80(""); // all spaces
    const cb = try Card.parse(&blank);
    try testing.expectEqual(Card.Kind.blank, cb.kind);
    try testing.expect(cb.name.isBlank());

    // Blank keyword (bytes 1–8 spaces) but free text in 9–80 ⇒ commentary, not .blank.
    var raw: [80]u8 = [_]u8{' '} ** 80;
    const txt = "blank-keyword free text";
    @memcpy(raw[10..][0..txt.len], txt);
    const c = try Card.parse(&raw);
    try testing.expectEqual(Card.Kind.commentary, c.kind);
    try testing.expect(c.name.isBlank());
}

test "END card" {
    const raw = card80("END");
    const c = try Card.parse(&raw);
    try testing.expectEqual(Card.Kind.end, c.kind);
    try testing.expect(c.name.isEnd());
}

test "CONTINUE card is a continuation" {
    const raw = card80("CONTINUE  'more text&'");
    const c = try Card.parse(&raw);
    try testing.expectEqual(Card.Kind.continuation, c.kind);
    try testing.expectEqualStrings("CONTINUE", c.name.text());
}

test "a control character anywhere is rejected" {
    var raw = card80("COMMENT test");
    raw[20] = 0x07; // bell
    try testing.expectError(error.NonAsciiInHeader, Card.parse(&raw));

    // A high byte (> 0x7E) in the name field is likewise rejected.
    var raw2 = card80("KEY     =                    1");
    raw2[0] = 0x7F; // DEL
    try testing.expectError(error.NonAsciiInHeader, Card.parse(&raw2));
}

test "an illegal keyword-name alphabet is BadKeywordName" {
    const raw = card80("BAD.NAME=                    1");
    try testing.expectError(error.BadKeywordName, Card.parse(&raw));
}

test "buildValue: integer with a comment" {
    const c = try Card.buildValue("NAXIS", .{ .int = 42 }, "number of axes");
    try testing.expectEqual(Card.Kind.value, c.kind);
    try testing.expectEqualStrings("NAXIS", c.name.text());
    try testing.expectEqualStrings("NAXIS   = ", c.bytes()[0..10]);
    const v = try value.parseValue(testing.allocator, c.valueField());
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 42), v.int);
    try testing.expectEqualStrings("number of axes", value.parseComment(c.valueField()).?);
}

test "buildValue: string value, no comment, re-parses" {
    const c = try Card.buildValue("OBJECT", .{ .string = "M31" }, null);
    try testing.expectEqual(Card.Kind.value, c.kind);
    const v = try value.parseValue(testing.allocator, c.valueField());
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("M31", v.string);
}

test "buildValue: undefined value is still a value card (indicator present)" {
    const c = try Card.buildValue("FOO", .undefined, null);
    try testing.expectEqual(Card.Kind.value, c.kind);
    const v = try value.parseValue(testing.allocator, c.valueField());
    try testing.expectEqual(value.KeywordValue.undefined, std.meta.activeTag(v));
}

test "buildValue: a commentary name with the indicator stays commentary" {
    const c = try Card.buildValue("COMMENT", .{ .int = 1 }, null);
    try testing.expectEqual(Card.Kind.commentary, c.kind);
}

test "buildValue: oversized comment overflows the card" {
    const long = "x" ** 70;
    try testing.expectError(error.CardOverflow, Card.buildValue("OBJECT", .{ .string = "M31" }, long));
}

test "buildValue: bad keyword name is rejected" {
    try testing.expectError(error.BadKeywordName, Card.buildValue("BAD.NAME", .{ .int = 1 }, null));
}

test "buildValue: embedded or leading blanks in the name are rejected (BUGHUNT 62)" {
    try testing.expectError(error.BadKeywordName, Card.buildValue("AB CD", .{ .int = 1 }, null));
    try testing.expectError(error.BadKeywordName, Card.buildValue(" XKEY", .{ .int = 1 }, null));
}

test "buildValue: non-finite reals are rejected on the write path (BUGHUNT 25/27)" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try testing.expectError(error.BadValueSyntax, Card.buildValue("KNAN", .{ .float = nan }, null));
    try testing.expectError(error.BadValueSyntax, Card.buildValue("KINF", .{ .float = inf }, null));
    try testing.expectError(error.BadValueSyntax, Card.buildValue("KNINF", .{ .float = -inf }, null));
    try testing.expectError(error.BadValueSyntax, Card.buildValue("KCPX", .{ .complex_float = .{ 1.0, nan } }, null));
    try testing.expectError(error.BadValueSyntax, Card.buildValue("KCPX", .{ .complex_float = .{ inf, 1.0 } }, null));
    // Finite reals still build.
    const c = try Card.buildValue("GAIN", .{ .float = 1.5 }, null);
    try testing.expectEqual(Card.Kind.value, c.kind);
}

test "Card.parse stays lenient about blanks in an on-disk name field (read contract)" {
    // Third-party files with malformed spaced names must still load; only the
    // build/edit path is strict.
    const raw = card80("AB CD   =                    1");
    const c = try Card.parse(&raw);
    try testing.expectEqualStrings("AB CD", c.name.text());
}
