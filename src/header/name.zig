//! Keyword-name normalization and case-insensitive wildcard matching (FR-HDR-2, FR-UTL-4,
//! §9.1, §19.1; FITS 4.0 §4.1.2.1).
//!
//! Standard keyword names occupy bytes 1–8 of a card and use only `[A-Z0-9_-]` (FR-HDR-2);
//! lower-case is normalized to upper on read. A `Name` stores the 8-byte, space-padded,
//! upper-cased field as the round-trip source of truth and exposes the classification helpers
//! the card model needs (`isEnd`, `isCommentary`, `isBlank`).
//!
//! Wildcard matching (FR-UTL-4) is case-insensitive with `*` (any run, possibly empty), `?`
//! (exactly one character), and `#` (a run of one or more digits). The match *result
//! contract* — zero / exactly-one / ordered-all — is carried by `Matches`, a fixed-capacity
//! accumulator, never the CFITSIO status-iteration idiom (FR-ERR-2): callers inspect
//! `Matches.len` and read the ordered indices, and `overflow` flags truncation past
//! `MAX_MATCHES`.
const std = @import("std");
const HeaderError = @import("../errors.zig").HeaderError;
const limits = @import("../limits.zig");

/// Comptime inline-buffer capacity for a `Matches` list (§19.1). The runtime ceiling
/// `Limits.max_matches` (§7.2) must stay `<=` this value; the assertion below enforces it so
/// the two cannot drift apart. This is a top-level constant because a struct's *runtime*
/// field cannot serve as a type-qualified comptime array bound on Zig 0.16.
pub const MAX_MATCHES: usize = 4096;

comptime {
    // Cross-module invariant promised in limits.zig: the runtime ceiling never exceeds the
    // comptime inline capacity, so a `Matches` accumulator can always hold a full run.
    std.debug.assert((limits.Limits{}).max_matches <= MAX_MATCHES);
}

/// Fixed-capacity, allocation-free accumulator for a wildcard query's result list (§19.1).
///
/// The result contract of FR-UTL-4 is read off this value: `len == 0` is the zero-match
/// case, `len == 1` is the unique match, and `slice()` is the ordered list of all matches.
/// When more matches exist than fit in `buf`, `add` stops appending and sets `overflow`,
/// so a truncated list is always self-describing (no silent loss).
pub const Matches = struct {
    /// Backing store of 0-based indices (e.g. column or card positions). Only `buf[0..len]`
    /// is meaningful; the tail is `undefined`.
    buf: [MAX_MATCHES]u32 = undefined,
    /// Number of valid entries in `buf`.
    len: usize = 0,
    /// Set `true` when more matches existed than fit (the list was truncated at `cap`).
    overflow: bool = false,
    /// Effective ceiling on the accumulated count (≤ `MAX_MATCHES`). Defaults to the full inline
    /// capacity; set from a handle's `Limits.max_matches` via `withLimit` to enforce a lower
    /// runtime ceiling (FR-UTL-4 / NFR-SAFE-1).
    cap: u32 = MAX_MATCHES,

    /// A `Matches` whose effective ceiling is the handle's `Limits.max_matches` (clamped to the
    /// comptime inline capacity, so it is always safe to index `buf`).
    pub fn withLimit(lim: limits.Limits) Matches {
        return .{ .cap = @min(lim.max_matches, @as(u32, MAX_MATCHES)) };
    }

    /// The ordered list of matched indices accumulated so far.
    pub fn slice(self: *const Matches) []const u32 {
        return self.buf[0..self.len];
    }

    /// The `i`-th matched index. Caller must ensure `i < len`.
    pub fn at(self: *const Matches, i: usize) u32 {
        return self.buf[i];
    }

    /// Append `idx` to the list, preserving insertion order. If the buffer is full the index
    /// is dropped and `overflow` is set `true`; existing entries are never disturbed.
    pub fn add(self: *Matches, idx: u32) void {
        // Bound by the runtime ceiling `cap` (≤ MAX_MATCHES); `@min` is belt-and-suspenders so a
        // stale/over-large `cap` can never index past the inline buffer.
        if (self.len >= @min(self.cap, @as(u32, MAX_MATCHES))) {
            self.overflow = true;
            return;
        }
        self.buf[self.len] = idx;
        self.len += 1;
    }

    /// Clear the list for reuse: `len` and `overflow` return to zero/false. `buf` is left
    /// as-is (its stale tail is unreachable through `slice`/`at`).
    pub fn reset(self: *Matches) void {
        self.len = 0;
        self.overflow = false;
    }
};

/// A normalized FITS keyword name: the 8-byte, space-padded, upper-cased name field (§9.1).
///
/// Construction is via `parse`, which validates the `[A-Z0-9_-]` (plus padding space)
/// alphabet of FR-HDR-2 and upper-cases lower-case input. The stored `bytes` are the
/// round-trip canonical form; the helpers classify the name without re-parsing.
pub const Name = struct {
    /// The 8-character name field: upper-cased, left-justified, space-padded.
    bytes: [8]u8,

    /// Parse and normalize bytes 1–8 of a card (a slice of up to 8 bytes) into a `Name`.
    ///
    /// Lower-case letters are upper-cased; the only permitted characters are
    /// `A–Z`, `0–9`, `_`, `-`, and the padding space. Any control character or other
    /// illegal byte, or a field longer than 8 bytes, yields `error.BadKeywordName`. A short
    /// or empty field is right-padded with spaces (an all-space field is a blank name).
    pub fn parse(field: []const u8) HeaderError!Name {
        if (field.len > 8) return error.BadKeywordName;
        var self: Name = .{ .bytes = [_]u8{' '} ** 8 };
        for (field, 0..) |c, i| {
            const up = std.ascii.toUpper(c);
            const ok = (up >= 'A' and up <= 'Z') or
                (up >= '0' and up <= '9') or
                up == '_' or up == '-' or up == ' ';
            if (!ok) return error.BadKeywordName;
            self.bytes[i] = up;
        }
        return self;
    }

    /// The name with trailing padding spaces removed (the human-readable form).
    pub fn text(self: *const Name) []const u8 {
        return std.mem.trimEnd(u8, &self.bytes, " ");
    }

    /// Exact equality of two normalized names (a byte compare of the padded fields).
    pub fn eql(self: *const Name, other: *const Name) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Case-insensitive comparison to a plain string `s` (trailing spaces in `s` ignored).
    pub fn eqlText(self: *const Name, s: []const u8) bool {
        const t = std.mem.trimEnd(u8, s, " ");
        return std.ascii.eqlIgnoreCase(self.text(), t);
    }

    /// Whether this is a commentary keyword: `COMMENT`, `HISTORY`, or all-blank (§9.1).
    pub fn isCommentary(self: *const Name) bool {
        const t = self.text();
        return t.len == 0 or std.mem.eql(u8, t, "COMMENT") or std.mem.eql(u8, t, "HISTORY");
    }

    /// Whether this is the `END` keyword.
    pub fn isEnd(self: *const Name) bool {
        return std.mem.eql(u8, self.text(), "END");
    }

    /// Whether the name field is entirely spaces (a blank keyword).
    pub fn isBlank(self: *const Name) bool {
        for (self.bytes) |b| {
            if (b != ' ') return false;
        }
        return true;
    }
};

/// Case-insensitive wildcard match of `name` against `pattern` (FR-UTL-4, §19.1).
///
/// Wildcards: `*` matches any run of zero or more characters, `?` matches exactly one
/// character, and `#` matches a run of one or more decimal digits. All other pattern
/// characters match the corresponding `name` character ignoring ASCII case. Returns `true`
/// iff the whole `name` is consumed by the whole `pattern`.
pub fn matchWildcard(pattern: []const u8, name: []const u8) bool {
    return matchAt(pattern, name, 0, 0);
}

fn charEqIgnoreCase(a: u8, b: u8) bool {
    return std.ascii.toUpper(a) == std.ascii.toUpper(b);
}

// Recursive backtracking matcher. Recursion depth is bounded by `pattern.len` (every
// recursive call advances the pattern past a `*`/`#` token), so there is no unbounded stack
// growth on hostile input; the only branching is the bounded split search at `*`/`#`.
fn matchAt(pattern: []const u8, name: []const u8, pi: usize, ni: usize) bool {
    var p = pi;
    var n = ni;
    while (p < pattern.len) {
        switch (pattern[p]) {
            '*' => {
                // Collapse a run of '*' to a single any-run token.
                var pp = p + 1;
                while (pp < pattern.len and pattern[pp] == '*') pp += 1;
                if (pp == pattern.len) return true; // trailing '*' matches the rest
                // Try matching the remainder at every split point from here to end-of-name.
                var k = n;
                while (k <= name.len) : (k += 1) {
                    if (matchAt(pattern, name, pp, k)) return true;
                }
                return false;
            },
            '#' => {
                // A run of one or more digits; match greedily then backtrack to shorter runs.
                var maxk = n;
                while (maxk < name.len and std.ascii.isDigit(name[maxk])) maxk += 1;
                var k = maxk;
                while (k > n) : (k -= 1) { // k from maxk down to n+1 ⇒ at least one digit
                    if (matchAt(pattern, name, p + 1, k)) return true;
                }
                return false;
            },
            '?' => {
                if (n >= name.len) return false;
                p += 1;
                n += 1;
            },
            else => {
                if (n >= name.len) return false;
                if (!charEqIgnoreCase(pattern[p], name[n])) return false;
                p += 1;
                n += 1;
            },
        }
    }
    return n == name.len;
}

const testing = std.testing;

test "Matches: zero / one / ordered-all and reset" {
    var m: Matches = .{};
    try testing.expectEqual(@as(usize, 0), m.len);
    try testing.expectEqual(@as(usize, 0), m.slice().len);
    try testing.expect(!m.overflow);

    m.add(7);
    try testing.expectEqual(@as(usize, 1), m.len);
    try testing.expectEqual(@as(u32, 7), m.at(0));

    m.add(3);
    m.add(9);
    try testing.expectEqualSlices(u32, &.{ 7, 3, 9 }, m.slice()); // insertion order preserved

    m.reset();
    try testing.expectEqual(@as(usize, 0), m.len);
    try testing.expect(!m.overflow);
}

test "Matches: overflow set past MAX_MATCHES, earlier entries intact" {
    var m: Matches = .{};
    var i: u32 = 0;
    while (i < MAX_MATCHES) : (i += 1) m.add(i);
    try testing.expectEqual(MAX_MATCHES, m.len);
    try testing.expect(!m.overflow);

    m.add(123); // one too many
    try testing.expect(m.overflow);
    try testing.expectEqual(MAX_MATCHES, m.len); // length did not grow
    try testing.expectEqual(@as(u32, 0), m.at(0)); // earliest entry untouched
    try testing.expectEqual(@as(u32, MAX_MATCHES - 1), m.at(MAX_MATCHES - 1));
}

test "Matches.withLimit enforces a lowered runtime ceiling (max_matches)" {
    // Regression: Limits.max_matches was never read, so a lowered ceiling had no effect.
    var m = Matches.withLimit(.{ .max_matches = 8 });
    var i: u32 = 0;
    while (i < 50) : (i += 1) m.add(i);
    try testing.expectEqual(@as(usize, 8), m.len); // capped at the configured ceiling
    try testing.expect(m.overflow);
    try testing.expectEqual(@as(u32, 7), m.at(7)); // first 8 retained in order
    // An over-large override is clamped to the comptime inline capacity (no OOB).
    const big = Matches.withLimit(.{ .max_matches = 1_000_000 });
    try testing.expectEqual(@as(u32, MAX_MATCHES), big.cap);
}

test "Name.parse normalizes case and pads, text trims" {
    const n = try Name.parse("naxis");
    try testing.expectEqualStrings("NAXIS   ", &n.bytes);
    try testing.expectEqualStrings("NAXIS", n.text());

    const full = try Name.parse("TUNIT123");
    try testing.expectEqualStrings("TUNIT123", &full.bytes);
    try testing.expectEqualStrings("TUNIT123", full.text());

    const empty = try Name.parse("");
    try testing.expectEqualStrings("        ", &empty.bytes);
    try testing.expectEqualStrings("", empty.text());
}

test "Name.parse accepts the full legal alphabet" {
    const n = try Name.parse("A0-_Z9");
    try testing.expectEqualStrings("A0-_Z9", n.text());
}

test "Name.parse rejects illegal characters and oversize fields" {
    try testing.expectError(error.BadKeywordName, Name.parse("NAME.X")); // '.' illegal
    try testing.expectError(error.BadKeywordName, Name.parse("A+B")); // '+' illegal
    try testing.expectError(error.BadKeywordName, Name.parse("AB\x01")); // control char
    try testing.expectError(error.BadKeywordName, Name.parse("LONGNAME9")); // 9 > 8 bytes
}

test "Name.eql and eqlText" {
    const a = try Name.parse("NAXIS");
    const b = try Name.parse("naxis");
    const c = try Name.parse("NAXIS2");
    try testing.expect(a.eql(&b)); // both normalize to the same padded field
    try testing.expect(!a.eql(&c));

    try testing.expect(a.eqlText("naxis"));
    try testing.expect(a.eqlText("NAXIS"));
    try testing.expect(a.eqlText("naxis   ")); // trailing spaces ignored
    try testing.expect(!a.eqlText("NAX"));
    try testing.expect(!a.eqlText("NAXIS2"));
}

test "Name classification: commentary / end / blank" {
    const comment = try Name.parse("COMMENT");
    const history = try Name.parse("history");
    const blank = try Name.parse("        ");
    const end = try Name.parse("END");
    const value = try Name.parse("BITPIX");

    try testing.expect(comment.isCommentary());
    try testing.expect(history.isCommentary());
    try testing.expect(blank.isCommentary());
    try testing.expect(!value.isCommentary());

    try testing.expect(end.isEnd());
    try testing.expect(!value.isEnd());

    try testing.expect(blank.isBlank());
    try testing.expect(!value.isBlank());
}

test "matchWildcard: literal and case-insensitive" {
    try testing.expect(matchWildcard("NAXIS", "naxis"));
    try testing.expect(matchWildcard("flux", "FLUX"));
    try testing.expect(!matchWildcard("NAXIS", "NAXIS1"));
    try testing.expect(!matchWildcard("ABC", "abd"));
    try testing.expect(matchWildcard("", "")); // empty matches empty
    try testing.expect(!matchWildcard("", "X"));
}

test "matchWildcard: '*' any run including empty" {
    try testing.expect(matchWildcard("*", ""));
    try testing.expect(matchWildcard("*", "ANYTHING"));
    try testing.expect(matchWildcard("TUNIT*", "TUNIT")); // '*' matches empty run
    try testing.expect(matchWildcard("TUNIT*", "TUNIT1"));
    try testing.expect(matchWildcard("*X", "abX"));
    try testing.expect(!matchWildcard("*X", "abY"));
    try testing.expect(matchWildcard("A*B*C", "AxxByyC"));
    try testing.expect(matchWildcard("**FLUX**", "flux")); // collapsed stars
}

test "matchWildcard: '?' exactly one character" {
    try testing.expect(matchWildcard("T?", "TA"));
    try testing.expect(!matchWildcard("T?", "T"));
    try testing.expect(!matchWildcard("T?", "TAB"));
    try testing.expect(matchWildcard("??", "ab"));
}

test "matchWildcard: '#' run of digits" {
    try testing.expect(matchWildcard("NAXIS#", "NAXIS2"));
    try testing.expect(matchWildcard("NAXIS#", "NAXIS12")); // a run, not just one digit
    try testing.expect(!matchWildcard("NAXIS#", "NAXIS")); // needs at least one digit
    try testing.expect(!matchWildcard("NAXIS#", "NAXISA")); // non-digit
    try testing.expect(matchWildcard("#", "007"));
    try testing.expect(!matchWildcard("#", "A"));
    try testing.expect(matchWildcard("A#5", "A125")); // '#' backtracks to leave the '5'
    try testing.expect(matchWildcard("A#B", "A12B"));
}

test "matchWildcard: combined wildcards" {
    try testing.expect(matchWildcard("TTYPE#", "TTYPE42"));
    try testing.expect(matchWildcard("T*#", "TUNIT7"));
    try testing.expect(matchWildcard("*FLUX?", "the_FLUX1"));
    try testing.expect(!matchWildcard("*FLUX?", "the_FLUX")); // '?' has nothing to match
}
