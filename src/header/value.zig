//! Keyword **value field** parsing and formatting (`FR-HDR-3/4`, FITS 4.0 §4.2.1–4.2.7, §9.2).
//!
//! The value field is the 70 bytes of a card after the value indicator — card columns 11–80,
//! i.e. the bytes after `"KEYWORD= "`. This module turns those bytes into a tagged
//! `KeywordValue` and back. It accepts **both fixed-format and free-format on read**
//! (`FR-HDR-4`): no column alignment is required, leading/trailing blanks around a token are
//! ignored, and the FORTRAN `D` exponent is accepted for reals. Mandatory keywords are
//! **written fixed format** (right-justified in the value field, columns 11–30).
//!
//! The three-way null/empty/undefined distinction of `FR-HDR-3` is preserved here: an absent
//! keyword is the *null* case (handled by the header lookup, not this module); `= ''` is the
//! *empty* case (a `.string` of length 0); a present indicator with a blank value field is the
//! *undefined* case (the `.undefined` tag). Non-ASCII rejection is the card layer's job; this
//! module only guarantees it never indexes out of bounds on hostile input.
const std = @import("std");
const HeaderError = @import("../errors.zig").HeaderError;
const ValueError = @import("../errors.zig").ValueError;

/// Fixed-format value-field width: columns 11–30 inclusive (`FR-HDR-4`). Mandatory numeric and
/// logical values are right-justified within these 20 columns.
const FIXED_WIDTH: usize = 20;
/// Fixed-format minimum string length: a string value is padded with blanks to at least 8
/// characters between the quotes (FITS 4.0 §4.2.1).
pub const MIN_STRING_CHARS: usize = 8;

/// A parsed FITS keyword value, carrying the standard value types plus the *undefined* tag.
///
/// The `.string` payload is allocator-owned: `''` pairs are un-escaped to a single `'`, and
/// trailing blanks are trimmed (a value of all blanks denotes one space; `''` is length 0).
/// Call `deinit` to release a `.string`; the other variants own nothing.
pub const KeywordValue = union(enum) {
    /// Signed integer value (FITS 4.0 §4.2.3).
    int: i64,
    /// Real floating value (FITS 4.0 §4.2.4); FORTRAN `D` exponents are mapped to `E` on read.
    float: f64,
    /// Complex integer pair `[real, imaginary]` (FITS 4.0 §4.2.5).
    complex_int: [2]i64,
    /// Complex floating pair `[real, imaginary]` (FITS 4.0 §4.2.6).
    complex_float: [2]f64,
    /// Logical value: `T` (true) or `F` (false) (FITS 4.0 §4.2.2).
    logical: bool,
    /// Character string (FITS 4.0 §4.2.1). Allocator-owned; `''` un-escaped to `'`; trailing
    /// blanks trimmed. `''` ⇒ length 0; all-blank ⇒ a single space.
    string: []const u8,
    /// Value indicator present but the value field is blank (the *undefined* value).
    undefined,

    /// Release any owned memory. Frees the `.string` payload; a no-op for every other variant.
    pub fn deinit(self: KeywordValue, alloc: std.mem.Allocator) void {
        switch (self) {
            .string => |s| alloc.free(s),
            else => {},
        }
    }
};

/// Parse a value field (card columns 11–80, passed as a slice) into a `KeywordValue`.
///
/// On a string value the result is allocated via `alloc`; every other variant is inline.
/// An entirely blank field — or one containing only a `/` comment — is `.undefined` (the
/// *undefined* value); `''` is an empty `.string`. Numbers parse in either fixed or free
/// format. Returns `error.UnterminatedString` for an unclosed quote and `error.BadValueSyntax`
/// for a token that matches no value type. Never indexes out of bounds on malformed input.
pub fn parseValue(
    alloc: std.mem.Allocator,
    field: []const u8,
) (HeaderError || ValueError || std.mem.Allocator.Error)!KeywordValue {
    var start: usize = 0;
    while (start < field.len and field[start] == ' ') start += 1;
    if (start == field.len) return .undefined; // blank (or empty) field ⇒ undefined value

    const lead = field[start];
    if (lead == '/') return .undefined; // comment only, no value ⇒ undefined value
    if (lead == '\'') return parseString(alloc, field, start);

    // Non-string: the value token is everything before the first '/' (the comment delimiter).
    const slash = std.mem.indexOfScalar(u8, field, '/');
    const vpart = if (slash) |s| field[0..s] else field;
    const tok = std.mem.trim(u8, vpart, " ");
    if (tok.len == 0) return .undefined;

    if (tok.len == 1 and tok[0] == 'T') return .{ .logical = true };
    if (tok.len == 1 and tok[0] == 'F') return .{ .logical = false };
    if (tok[0] == '(') return parseComplex(tok);
    return parseNumeric(tok);
}

/// Extract the optional `/ comment` from a value field, as a blank-trimmed slice **borrowed**
/// from `field`. Returns `null` when there is no comment (or it is empty). A `/` inside a
/// quoted string is not a delimiter; an unterminated string yields `null`.
pub fn parseComment(field: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < field.len and field[start] == ' ') start += 1;
    if (start == field.len) return null;

    var search_from: usize = 0;
    if (field[start] == '\'') {
        const close = findStringEnd(field, start) orelse return null; // unterminated ⇒ no comment
        search_from = close + 1;
    }
    const rel = std.mem.indexOfScalar(u8, field[search_from..], '/') orelse return null;
    const after = field[search_from + rel + 1 ..];
    const trimmed = std.mem.trim(u8, after, " ");
    if (trimmed.len == 0) return null;
    return trimmed;
}

/// Extract the units string from the leading `[unit]` comment convention (FR-HDR-10,
/// FITS 4.0 §4.3.2), e.g. `1200. / [s] exposure time` → `"s"`. Returns a borrowed slice into
/// `field`, or `null` when the comment does not begin with a `[unit]` group. Non-unit bracket
/// text elsewhere in the comment is not misread (only a leading `[...]` counts).
pub fn parseUnits(field: []const u8) ?[]const u8 {
    const comment = parseComment(field) orelse return null;
    const c = std.mem.trimStart(u8, comment, " ");
    if (c.len == 0 or c[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, c, ']') orelse return null;
    const unit = std.mem.trim(u8, c[1..close], " ");
    if (unit.len == 0) return null;
    return unit;
}

/// Format `v` into `w`. Numeric and logical values are written **fixed format**
/// (right-justified within the 20-column value field) as required for mandatory keywords
/// (`FR-HDR-4`); strings, complex values, and `.undefined` use the natural free-format
/// representation. Strings are single-quoted with `'`→`''` escaping and padded to the
/// fixed-format 8-character minimum; `.undefined` writes nothing (a blank value field).
pub fn formatValue(w: *std.Io.Writer, v: KeywordValue) std.Io.Writer.Error!void {
    switch (v) {
        .int => |n| try fixedNum(w, "{d}", .{n}),
        .float => |f| {
            var tmp: [64]u8 = undefined;
            try padLeft(w, formatReal(&tmp, f), FIXED_WIDTH);
        },
        .logical => |b| try padLeft(w, if (b) "T" else "F", FIXED_WIDTH),
        .complex_int => |c| try w.print("({d}, {d})", .{ c[0], c[1] }),
        .complex_float => |c| {
            var rb: [64]u8 = undefined;
            var ib: [64]u8 = undefined;
            try w.print("({s}, {s})", .{ formatReal(&rb, c[0]), formatReal(&ib, c[1]) });
        },
        .string => |s| try formatString(w, s),
        .undefined => {}, // undefined value ⇒ blank value field
    }
}

/// Format a real with the FITS-mandated **uppercase** exponent letter (FITS 4.0 §4.2.4: reals
/// are written with `E` — or the FORTRAN `D` — never a lowercase `e`). `std.fmt`'s `{e}` emits
/// a lowercase `e`, so the exponent letter is upper-cased in place within `buf`. Returns the
/// slice of `buf` used; `buf` must be ≥ 32 bytes (any `f64` in `{e}` form fits). Shared by the
/// card writer here and the HIERARCH free-format writer (`hierarch.zig`).
pub fn formatReal(buf: []u8, f: f64) []const u8 {
    const s = std.fmt.bufPrint(buf, "{e}", .{f}) catch unreachable;
    for (s) |*c| {
        if (c.* == 'e') {
            c.* = 'E';
            break; // `{e}` yields exactly one exponent letter
        }
    }
    return s;
}

// ── internals ────────────────────────────────────────────────────────────────────────────

// Index of the closing quote of a string opening at `field[open] == '\''`, accounting for the
// `''` escape; `null` if the quote is never closed.
fn findStringEnd(field: []const u8, open: usize) ?usize {
    var i: usize = open + 1;
    while (i < field.len) : (i += 1) {
        if (field[i] == '\'') {
            if (i + 1 < field.len and field[i + 1] == '\'') {
                i += 1; // consume the escaped pair's second quote (loop's i+=1 steps past it)
                continue;
            }
            return i; // a lone quote closes the string
        }
    }
    return null;
}

// Parse a single-quoted string opening at `field[open]`, applying the `''`→`'` un-escape and
// the trailing-blank rule. Allocates the result via `alloc`.
fn parseString(
    alloc: std.mem.Allocator,
    field: []const u8,
    open: usize,
) (HeaderError || std.mem.Allocator.Error)!KeywordValue {
    const close = findStringEnd(field, open) orelse return error.UnterminatedString;

    // Count un-escaped characters first so we can allocate exactly.
    var clen: usize = 0;
    {
        var i: usize = open + 1;
        while (i < close) {
            if (field[i] == '\'') {
                i += 2;
            } else {
                i += 1;
            }
            clen += 1;
        }
    }
    if (clen == 0) return .{ .string = try alloc.alloc(u8, 0) }; // `''` ⇒ empty string

    var buf = try alloc.alloc(u8, clen);
    errdefer alloc.free(buf);
    {
        var i: usize = open + 1;
        var j: usize = 0;
        while (i < close) {
            if (field[i] == '\'') {
                buf[j] = '\'';
                i += 2;
            } else {
                buf[j] = field[i];
                i += 1;
            }
            j += 1;
        }
    }

    // Trailing blanks are not significant — except an all-blank value denotes one space.
    var flen: usize = clen;
    while (flen > 0 and buf[flen - 1] == ' ') flen -= 1;
    if (flen == 0) {
        const one = try alloc.realloc(buf, 1);
        one[0] = ' ';
        return .{ .string = one };
    }
    if (flen == clen) return .{ .string = buf };
    return .{ .string = try alloc.realloc(buf, flen) };
}

// Parse a `(re, im)` complex token; integer pair iff both parts parse as `i64` with no float
// indicator, else a floating pair.
fn parseComplex(tok: []const u8) HeaderError!KeywordValue {
    if (tok.len < 2 or tok[tok.len - 1] != ')') return error.BadValueSyntax;
    const inner = tok[1 .. tok.len - 1];
    const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return error.BadValueSyntax;
    const re_s = std.mem.trim(u8, inner[0..comma], " ");
    const im_s = std.mem.trim(u8, inner[comma + 1 ..], " ");
    if (re_s.len == 0 or im_s.len == 0) return error.BadValueSyntax;

    if (!hasFloatChar(re_s) and !hasFloatChar(im_s)) {
        const ri = std.fmt.parseInt(i64, re_s, 10) catch null;
        const ii = std.fmt.parseInt(i64, im_s, 10) catch null;
        if (ri != null and ii != null) return .{ .complex_int = .{ ri.?, ii.? } };
    }
    return .{ .complex_float = .{ try parseFloatTok(re_s), try parseFloatTok(im_s) } };
}

// Parse an integer or real token. Integer iff it has no '.'/'E'/'D' and fits in `i64`; real
// otherwise (a too-large or float-shaped token falls through to floating parse).
fn parseNumeric(tok: []const u8) HeaderError!KeywordValue {
    if (!hasFloatChar(tok)) {
        // FITS integers (§4.2.3) are an optional sign + decimal digits only. std.fmt.parseInt is
        // more permissive (underscore separators, 0x/0o/0b prefixes), so screen the token first.
        if (isFitsIntToken(tok)) {
            if (std.fmt.parseInt(i64, tok, 10)) |n| {
                return .{ .int = n };
            } else |_| {} // too large for i64 → fall through to floating parse
        }
    }
    return .{ .float = try parseFloatTok(tok) };
}

// True iff `s` is a FITS integer literal: an optional leading sign followed by ≥1 decimal digit.
fn isFitsIntToken(s: []const u8) bool {
    if (s.len == 0) return false;
    const digits = if (s[0] == '+' or s[0] == '-') s[1..] else s;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// Parse a real token, mapping the FORTRAN `D`/`d` exponent to `E`/`e` first.
fn parseFloatTok(s: []const u8) HeaderError!f64 {
    var buf: [80]u8 = undefined;
    if (s.len == 0 or s.len > buf.len) return error.BadValueSyntax;
    // FITS reals (§4.2.4) use only digits, a sign, a decimal point, and an E/e/D/d exponent.
    // std.fmt.parseFloat also accepts nan/inf, hex floats, and underscores — none of which are
    // valid FITS values — so reject any other byte before parsing.
    for (s) |c| switch (c) {
        '0'...'9', '+', '-', '.', 'E', 'e', 'D', 'd' => {},
        else => return error.BadValueSyntax,
    };
    for (s, 0..) |c, i| {
        buf[i] = switch (c) {
            'D' => 'E',
            'd' => 'e',
            else => c,
        };
    }
    const v = std.fmt.parseFloat(f64, buf[0..s.len]) catch return error.BadValueSyntax;
    // A finite FITS real cannot overflow to ±inf (e.g. "1E999") or be NaN.
    if (!std.math.isFinite(v)) return error.BadValueSyntax;
    return v;
}

// True if `s` contains a real-number indicator: a decimal point or an exponent letter.
fn hasFloatChar(s: []const u8) bool {
    for (s) |c| switch (c) {
        '.', 'E', 'e', 'D', 'd' => return true,
        else => {},
    };
    return false;
}

// Format `args` with `fmt` into a scratch buffer, then right-justify in `FIXED_WIDTH` columns.
// Used for integers ("{d}", any i64 ≤ 20 chars), so `bufPrint` into the 64-byte buffer cannot
// overflow. Reals route through `formatReal` instead (uppercase-exponent fix-up).
fn fixedNum(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch unreachable;
    try padLeft(w, s, FIXED_WIDTH);
}

// Write `s` right-justified in `width` columns (left-padded with blanks; never truncated).
fn padLeft(w: *std.Io.Writer, s: []const u8, width: usize) std.Io.Writer.Error!void {
    var i: usize = s.len;
    while (i < width) : (i += 1) try w.writeByte(' ');
    try w.writeAll(s);
}

/// Rendered length of `s` once each `'` is escaped to `''` (quotes/padding not included).
pub fn escapedLen(s: []const u8) usize {
    var n: usize = s.len;
    for (s) |c| {
        if (c == '\'') n += 1;
    }
    return n;
}

/// Write `s` into `out` with each `'` doubled; `out.len` must be `escapedLen(s)`.
pub fn escapeQuotes(s: []const u8, out: []u8) void {
    var i: usize = 0;
    for (s) |c| {
        out[i] = c;
        i += 1;
        if (c == '\'') {
            out[i] = '\'';
            i += 1;
        }
    }
}

// Write a single-quoted string with `'`→`''` escaping, padded to the 8-character minimum.
fn formatString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') {
            try w.writeAll("''");
        } else {
            try w.writeByte(c);
        }
    }
    var i: usize = s.len;
    while (i < MIN_STRING_CHARS) : (i += 1) try w.writeByte(' ');
    try w.writeByte('\'');
}

// ── tests ────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "empty string `''` is a zero-length string (the empty case)" {
    const v = try parseValue(testing.allocator, "''");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(KeywordValue.string, std.meta.activeTag(v));
    try testing.expectEqual(@as(usize, 0), v.string.len);
}

test "blank value field is undefined (the undefined case)" {
    // `= ` then nothing but blanks: the whole value field is blank.
    const v = try parseValue(testing.allocator, "                        ");
    try testing.expectEqual(KeywordValue.undefined, std.meta.activeTag(v));
    // An empty slice (no value field at all) is also undefined.
    const v2 = try parseValue(testing.allocator, "");
    try testing.expectEqual(KeywordValue.undefined, std.meta.activeTag(v2));
}

test "comment-only field is undefined with a borrowed comment" {
    const field = "   / just a comment";
    const v = try parseValue(testing.allocator, field);
    try testing.expectEqual(KeywordValue.undefined, std.meta.activeTag(v));
    try testing.expectEqualStrings("just a comment", parseComment(field).?);
}

test "FITS 4.2.1 string examples: trailing trimmed, leading kept, '' escape, all-blank" {
    const Case = struct { in: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .in = "'abc'", .want = "abc" },
        .{ .in = "'ABC     '", .want = "ABC" }, // trailing blanks not significant
        .{ .in = "'  ab'", .want = "  ab" }, // leading blanks ARE significant
        .{ .in = "'O''HARA'", .want = "O'HARA" }, // '' escape ⇒ one quote
        .{ .in = "' '", .want = " " }, // all-blank denotes one space
        .{ .in = "'        '", .want = " " }, // many blanks still ⇒ one space
    };
    for (cases) |c| {
        const v = try parseValue(testing.allocator, c.in);
        defer v.deinit(testing.allocator);
        try testing.expectEqualStrings(c.want, v.string);
    }
}

test "string with embedded quote and a trailing comment" {
    const field = "'it''s here'  / has a quote";
    const v = try parseValue(testing.allocator, field);
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("it's here", v.string);
    try testing.expectEqualStrings("has a quote", parseComment(field).?);
}

test "unterminated string is an error and leaks nothing" {
    try testing.expectError(error.UnterminatedString, parseValue(testing.allocator, "'no closing quote"));
    // parseComment tolerates the same input by reporting no comment.
    try testing.expectEqual(@as(?[]const u8, null), parseComment("'no closing quote"));
}

test "logical T/F in free format" {
    const t = try parseValue(testing.allocator, "                   T");
    try testing.expectEqual(true, t.logical);
    const f = try parseValue(testing.allocator, "  F  / boolean");
    try testing.expectEqual(false, f.logical);
}

test "integers parse in free and fixed format" {
    try testing.expectEqual(@as(i64, 42), (try parseValue(testing.allocator, "42")).int);
    try testing.expectEqual(@as(i64, 42), (try parseValue(testing.allocator, "                  42")).int);
    try testing.expectEqual(@as(i64, -7), (try parseValue(testing.allocator, "  -7 / count")).int);
    try testing.expectEqual(@as(i64, 100), (try parseValue(testing.allocator, "+100")).int);
}

test "reals parse, including the FORTRAN D exponent" {
    try testing.expectEqual(@as(f64, 3.14), (try parseValue(testing.allocator, "3.14")).float);
    try testing.expectEqual(@as(f64, -2.5e3), (try parseValue(testing.allocator, "-2.5E3")).float);
    try testing.expectEqual(@as(f64, 1.5e2), (try parseValue(testing.allocator, "1.5D2")).float); // D ⇒ E
    try testing.expectEqual(@as(f64, 6.0e-7), (try parseValue(testing.allocator, "  6.0D-7  / tiny")).float);
}

test "complex integer and complex float pairs" {
    const ci = try parseValue(testing.allocator, "(3, 4)");
    try testing.expectEqual([2]i64{ 3, 4 }, ci.complex_int);
    const cf = try parseValue(testing.allocator, "(1.5, -2.5)");
    try testing.expectEqual([2]f64{ 1.5, -2.5 }, cf.complex_float);
    // Mixed: one float part promotes the whole value to complex_float.
    const cm = try parseValue(testing.allocator, "(2, -3.0)");
    try testing.expectEqual([2]f64{ 2.0, -3.0 }, cm.complex_float);
}

test "malformed tokens and complex yield BadValueSyntax" {
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "not_a_value"));
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "(3 4)")); // no comma
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "(3, )")); // empty part
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "(1, 2")); // no close paren
}

test "non-FITS numeric tokens (nan/inf/hex/underscore/overflow) are rejected" {
    // Regression: std.fmt.parseInt/parseFloat accepted these and returned NaN/Inf/bogus values
    // that propagated silently into scaling/WCS math. FITS §4.2.3/§4.2.4 forbid all of them.
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "nan"));
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "inf"));
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "-inf"));
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "infinity"));
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "1_000"));
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "0x10"));
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "1e3_0"));
    try testing.expectError(error.BadValueSyntax, parseValue(testing.allocator, "1E999")); // overflow → inf
}

test "parseComment edge cases" {
    try testing.expectEqual(@as(?[]const u8, null), parseComment("42")); // no slash
    try testing.expectEqual(@as(?[]const u8, null), parseComment("42 /   ")); // empty comment
    try testing.expectEqualStrings("the answer", parseComment("42 / the answer").?);
    // A slash inside a quoted string is not a comment delimiter.
    try testing.expectEqual(@as(?[]const u8, null), parseComment("'a/b'"));
    try testing.expectEqualStrings("real comment", parseComment("'a/b' / real comment").?);
}

test "formatValue writes mandatory ints and logicals fixed format" {
    var buf: [80]u8 = undefined;
    {
        var w = std.Io.Writer.fixed(&buf);
        try formatValue(&w, .{ .int = 42 });
        try testing.expectEqualStrings("                  42", w.buffered()); // 18 blanks + "42"
        try testing.expectEqual(@as(usize, FIXED_WIDTH), w.buffered().len);
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try formatValue(&w, .{ .logical = true });
        try testing.expectEqualStrings("                   T", w.buffered()); // 19 blanks + "T"
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try formatValue(&w, .{ .logical = false });
        try testing.expectEqual(@as(usize, FIXED_WIDTH), w.buffered().len);
        try testing.expectEqual(@as(u8, 'F'), w.buffered()[FIXED_WIDTH - 1]);
    }
}

test "formatValue strings escape, pad to 8, and round-trip through parseValue" {
    var buf: [80]u8 = undefined;
    {
        var w = std.Io.Writer.fixed(&buf);
        try formatValue(&w, .{ .string = "O'HARA" });
        try testing.expectEqualStrings("'O''HARA  '", w.buffered()); // escaped + padded to 8
    }
    // Round-trip: format then re-parse yields the same logical string.
    const originals = [_][]const u8{ "abc", "O'HARA", " ", "a longer value" };
    for (originals) |orig| {
        var w = std.Io.Writer.fixed(&buf);
        try formatValue(&w, .{ .string = orig });
        const v = try parseValue(testing.allocator, w.buffered());
        defer v.deinit(testing.allocator);
        try testing.expectEqualStrings(orig, v.string);
    }
}

test "formatValue writes reals with an UPPERCASE 'E' exponent (§4.2.4)" {
    var buf: [80]u8 = undefined;
    {
        // A representative .float: 150.0 ⇒ "1.5E2", right-justified in the 20-column field.
        var w = std.Io.Writer.fixed(&buf);
        try formatValue(&w, .{ .float = 1.5e2 });
        const s = w.buffered();
        try testing.expectEqual(@as(usize, FIXED_WIDTH), s.len);
        try testing.expectEqualStrings("               1.5E2", s); // 15 blanks + "1.5E2"
        try testing.expect(std.mem.indexOfScalar(u8, s, 'e') == null); // never a lowercase 'e'
    }
    {
        // A representative .complex_float: pins the uppercase 'E' in BOTH parts.
        var w = std.Io.Writer.fixed(&buf);
        try formatValue(&w, .{ .complex_float = .{ 1.5e2, -2.5e-3 } });
        const s = w.buffered();
        try testing.expectEqualStrings("(1.5E2, -2.5E-3)", s);
        try testing.expect(std.mem.indexOfScalar(u8, s, 'e') == null);
    }
    // formatReal upper-cases the exponent and otherwise matches std.fmt's "{e}".
    var rb: [64]u8 = undefined;
    try testing.expectEqualStrings("1E2", formatReal(&rb, 100.0));
    try testing.expectEqualStrings("3.14E0", formatReal(&rb, 3.14));
}

test "formatValue undefined writes a blank value field" {
    var buf: [80]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatValue(&w, .undefined);
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "parseUnits: leading [unit] comment convention (FR-HDR-10)" {
    try testing.expectEqualStrings("s", parseUnits("1200. / [s] exposure time").?);
    try testing.expectEqualStrings("Angstrom", parseUnits("5000.0 / [Angstrom] wavelength").?);
    // No leading bracket ⇒ no units; a bracket later in the comment is not misread.
    try testing.expectEqual(@as(?[]const u8, null), parseUnits("42 / plain comment"));
    try testing.expectEqual(@as(?[]const u8, null), parseUnits("42 / see table [3]"));
    try testing.expectEqual(@as(?[]const u8, null), parseUnits("42 / [] empty"));
    try testing.expectEqual(@as(?[]const u8, null), parseUnits("42")); // no comment
}

test "deinit frees only strings (no leaks under the testing allocator)" {
    // String allocates and must be freed.
    const s = try parseValue(testing.allocator, "'owned'");
    s.deinit(testing.allocator);
    // Non-owning variants: deinit is a harmless no-op.
    (KeywordValue{ .int = 1 }).deinit(testing.allocator);
    (@as(KeywordValue, .undefined)).deinit(testing.allocator);
}
