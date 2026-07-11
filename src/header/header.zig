//! Header container: ordered cards, lookups, and the read API (FR-HDR-5/7/11/13, §9.4).
//!
//! A `Header` is the ordered list of `Card`s for one HDU plus a read/edit API over them. The
//! ordered list is the serialization source of truth (round-trip fidelity, FR-HDR-5). `END`
//! is mandatory: scanning a header that never reaches `END` within its block budget is
//! `error.MissingEnd` (FR-HDR-7). Numeric reads go through `convert.cast(.scalar)` so the
//! single conversion policy applies (FR-HDR-13).
//!
//! Lookups are a linear scan of the (typically small) card list; this keeps the model simple
//! and allocation-free. A hashed name index can be layered on later without changing the API.
const std = @import("std");
const errors = @import("../errors.zig");
const ValueError = errors.ValueError;
const HeaderError = errors.HeaderError;
const ConvError = errors.ConvError;
const convert = @import("../convert.zig");
const Card = @import("card.zig").Card;
const Name = @import("name.zig").Name;
const Matches = @import("name.zig").Matches;
const value = @import("value.zig");
// `continue` is a Zig keyword, so the long-string module is imported under `continuation`.
const continuation = @import("continue.zig");
const hierarch = @import("hierarch.zig");
const block = @import("../io/block.zig");

const Allocator = std.mem.Allocator;

/// The ordered cards of one HDU header and the API to read and build them.
pub const Header = struct {
    cards: std.ArrayList(Card) = .empty,
    /// Opt-in `INHERIT` fall-through to the primary header (FR-HDR-14); `null` disables it.
    /// Set via `setInherit`. Never changes the bytes written — it only affects lookups.
    inherit: ?*const Header = null,

    /// An empty header (no cards). Add cards with `append`/`appendValue` or fill via `parse`.
    pub fn initEmpty() Header {
        return .{};
    }

    /// Free the card list. Cards own no heap (just their 80 raw bytes), so this is all that is
    /// needed.
    pub fn deinit(self: *Header, alloc: Allocator) void {
        self.cards.deinit(alloc);
    }

    /// Parse a header from `reader`, starting at absolute card index `first_card`, scanning up
    /// to `max_cards` cards for the terminating `END`. The `END` card is included in the stored
    /// list. Returns the number of cards consumed (including `END`); the header occupies
    /// `ceil(consumed / 36)` blocks. `error.MissingEnd` if `END` is not found within the budget.
    pub fn parse(alloc: Allocator, reader: *block.BlockReader, first_card: u64, max_cards: usize) (HeaderError || errors.IoError || Allocator.Error)!struct { header: Header, cards_consumed: u64 } {
        var self: Header = .{};
        errdefer self.deinit(alloc);
        var i: usize = 0;
        while (i < max_cards) : (i += 1) {
            const raw = try reader.cardAt(first_card + i);
            const card = try Card.parse(raw);
            try self.cards.append(alloc, card);
            if (card.kind == .end) return .{ .header = self, .cards_consumed = i + 1 };
        }
        return error.MissingEnd;
    }

    /// Number of cards (including `END`).
    pub fn count(self: *const Header) usize {
        return self.cards.items.len;
    }

    /// The `n`-th card (0-based). Caller ensures `n < count()`.
    pub fn at(self: *const Header, n: usize) *const Card {
        return &self.cards.items[n];
    }

    /// Enable `INHERIT` fall-through to `parent` (the primary header), or pass `null` to
    /// disable. Opt-in and read-only in effect (FR-HDR-14); serialization is unaffected.
    pub fn setInherit(self: *Header, parent: ?*const Header) void {
        self.inherit = parent;
    }

    /// Borrow the first card whose keyword name matches `name` (case-insensitive). Returns
    /// `error.KeywordNotFound` when there is none. `END` is not matchable by name here. When
    /// `INHERIT` is enabled and `name` is inheritable, a local miss falls through to the parent.
    pub fn get(self: *const Header, name: []const u8) ValueError!*const Card {
        if (self.findFirst(name)) |idx| return &self.cards.items[idx];
        if (self.inherit) |parent| {
            if (isInheritable(name)) return parent.get(name);
        }
        return error.KeywordNotFound;
    }

    /// Whether a keyword named `name` exists (case-insensitive), honoring `INHERIT`.
    pub fn has(self: *const Header, name: []const u8) bool {
        if (self.findFirst(name) != null) return true;
        if (self.inherit) |parent| {
            if (isInheritable(name)) return parent.has(name);
        }
        return false;
    }

    // Whether `name` may be inherited from the primary header (FR-HDR-14, Appendix K): the
    // structural keywords, SIMPLE/COMMENT/HISTORY/blank, and the table column keywords are
    // excluded (they are HDU-specific and must not fall through).
    fn isInheritable(name: []const u8) bool {
        const n = std.mem.trimEnd(u8, name, " ");
        if (n.len == 0) return false; // blank
        const exact = [_][]const u8{
            "SIMPLE",  "XTENSION", "BITPIX", "NAXIS",   "PCOUNT",  "GCOUNT",
            "TFIELDS", "EXTEND",   "END",    "COMMENT", "HISTORY", "GROUPS",
        };
        for (exact) |e| if (std.ascii.eqlIgnoreCase(n, e)) return false;
        // Indexed structural/column keywords: NAXISn and the T* per-column keywords.
        const indexed = [_][]const u8{
            "NAXIS", "TFORM", "TTYPE", "TUNIT", "TSCAL", "TZERO", "TNULL", "TDIM", "TBCOL", "TDISP",
        };
        for (indexed) |p| {
            if (n.len > p.len and std.ascii.eqlIgnoreCase(n[0..p.len], p) and std.ascii.isDigit(n[p.len]))
                return false;
        }
        return true;
    }

    fn findFirst(self: *const Header, name: []const u8) ?usize {
        for (self.cards.items, 0..) |*c, i| {
            if (c.kind == .end) continue;
            if (c.name.eqlText(name)) return i;
            // The 8-byte name of every HIERARCH card is the literal "HIERARCH"; match the real
            // hierarchical keyword (either spelling) via the convention parser (FR-HDR-9).
            if (c.name.eqlText("HIERARCH") and hierarch.matchName(c, name)) return i;
        }
        return null;
    }

    /// Read the value of keyword `name` converted to `T` (an int, float, or bool) under the
    /// scalar conversion policy (FR-HDR-13, FR-CONV-1). `error.KeywordNotFound` if absent,
    /// `error.ValueUndefined` for a blank value field, `error.WrongValueType` for a type
    /// mismatch (e.g. a string requested as `f64`).
    // The value-field bytes of a resolved card. `get`/`findFirst` resolve a HIERARCH card by its
    // hierarchical name, but that card's fixed columns 11–80 (`Card.valueField`) fall inside the
    // keyword, not the value — so route HIERARCH cards through `hierarch.valueField` (the slice
    // after their `=`). `matchName` already required a `=`, so the `orelse` is defensive only.
    fn valueBytesOf(card: *const Card) HeaderError![]const u8 {
        if (hierarch.isHierarch(card)) return hierarch.valueField(card) orelse error.BadValueSyntax;
        return card.valueField();
    }

    /// Read a numeric or logical keyword as `T`, applying checked FITS-to-host conversion.
    /// String and aggregate values are available through `getString` and `getValueUnion`.
    pub fn getValue(self: *const Header, comptime T: type, name: []const u8) (ValueError || ConvError || HeaderError)!T {
        const card = try self.get(name);
        // The value is parsed from the card's raw bytes on demand. Only numeric/logical types
        // are handled here (no allocation); strings use `getString`.
        var fixed_alloc = std.heap.FixedBufferAllocator.init(&[_]u8{});
        const v = value.parseValue(fixed_alloc.allocator(), try valueBytesOf(card)) catch |err| switch (err) {
            error.OutOfMemory => return error.WrongValueType, // a string value (needs alloc) → use getString
            else => |e| return e,
        };
        return switch (@typeInfo(T)) {
            .int => switch (v) {
                .int => |n| convert.cast(T, n, .scalar),
                .float => |f| convert.cast(T, f, .scalar),
                .undefined => error.ValueUndefined,
                else => error.WrongValueType,
            },
            .float => switch (v) {
                .int => |n| convert.cast(T, n, .scalar),
                .float => |f| convert.cast(T, f, .scalar),
                .undefined => error.ValueUndefined,
                else => error.WrongValueType,
            },
            .bool => switch (v) {
                .logical => |b| b,
                .undefined => error.ValueUndefined,
                else => error.WrongValueType,
            },
            else => @compileError("getValue supports int, float, or bool; use getString for strings"),
        };
    }

    /// Read a string-valued keyword as an owned, allocator-backed slice (caller frees). The
    /// `''` escape and trailing-blank rules are applied (FR-HDR-3). `error.WrongValueType` if
    /// the value is not a string.
    pub fn getString(self: *const Header, alloc: Allocator, name: []const u8) (ValueError || HeaderError || Allocator.Error)![]u8 {
        const card = try self.get(name);
        const v = try value.parseValue(alloc, try valueBytesOf(card));
        switch (v) {
            .string => |s| return @constCast(s),
            .undefined => return error.ValueUndefined,
            else => {
                v.deinit(alloc);
                return error.WrongValueType;
            },
        }
    }

    /// Read a (possibly `CONTINUE`-continued) long string value as one owned slice (caller
    /// frees). Walks the base card plus any following `CONTINUE` cards via the long-string
    /// convention (FR-HDR-8, §4.2.1.2); a value that does not actually continue (including any
    /// literal trailing `&`) is returned as its single-card string. `error.KeywordNotFound` if
    /// absent, `error.WrongValueType` if not a string, `error.ValueUndefined` for a blank field.
    /// Honors `INHERIT` like `get`/`getString`.
    pub fn getLongString(self: *const Header, alloc: Allocator, name: []const u8) (ValueError || HeaderError || errors.LimitError || Allocator.Error)![]u8 {
        if (self.findFirst(name)) |idx| {
            // NFR-SAFE-1: Header carries no configurable Limits, so enforce the documented
            // default ceiling (limits.Limits.max_string_value) to close the assemble DoS.
            const max_str = (@import("../limits.zig").Limits{}).max_string_value;
            if (try continuation.assemble(alloc, self.cards.items, idx, max_str)) |joined| return joined.value;
            // Not a continued run: take the single-card string value (keeps any literal `&`).
            return self.getString(alloc, name);
        }
        if (self.inherit) |parent| {
            if (isInheritable(name)) return parent.getLongString(alloc, name);
        }
        return error.KeywordNotFound;
    }

    /// Read the value of a `HIERARCH` long-keyword card by its hierarchical name — either the
    /// spaced-token form (`ESO DET CHIP1 NAME`) or the full `HIERARCH …` spelling — as a parsed
    /// `KeywordValue` (FR-HDR-9). A `.string` payload is allocator-owned (caller `deinit`s it);
    /// other variants own nothing. `error.KeywordNotFound` if no `HIERARCH` card matches.
    pub fn getHierarch(self: *const Header, alloc: Allocator, name: []const u8) (ValueError || HeaderError || Allocator.Error)!value.KeywordValue {
        for (self.cards.items) |*c| {
            if (c.kind == .end) continue;
            if (c.name.eqlText("HIERARCH") and hierarch.matchName(c, name)) {
                return (try hierarch.parseValue(alloc, c)) orelse error.KeywordNotFound;
            }
        }
        return error.KeywordNotFound;
    }

    /// Read keyword `name` as the full parsed `KeywordValue` union, exposing every value type —
    /// including the `complex_int`/`complex_float`/`undefined` variants that the scalar
    /// `getValue` cannot return (FR-HDR-3). A `.string` payload is allocator-owned (caller
    /// `deinit`s it); other variants own nothing. `error.KeywordNotFound` if absent.
    pub fn getValueUnion(self: *const Header, alloc: Allocator, name: []const u8) (ValueError || HeaderError || Allocator.Error)!value.KeywordValue {
        const card = try self.get(name);
        return value.parseValue(alloc, try valueBytesOf(card));
    }

    /// Read a complex-valued keyword (FITS 4.0 §4.2.5/§4.2.6) as `[2]f64` `{real, imaginary}`.
    /// A `complex_int` is widened to floats and a real/integer scalar is taken as `{value, 0}`
    /// (FR-HDR-3, FR-CONV-1). `error.WrongValueType` for a string/logical value,
    /// `error.ValueUndefined` for a blank field, `error.KeywordNotFound` if absent. No allocation.
    pub fn getComplex(self: *const Header, name: []const u8) (ValueError || HeaderError)![2]f64 {
        const card = try self.get(name);
        var fixed_alloc = std.heap.FixedBufferAllocator.init(&[_]u8{});
        const v = value.parseValue(fixed_alloc.allocator(), try valueBytesOf(card)) catch |err| switch (err) {
            error.OutOfMemory => return error.WrongValueType, // a string value (needs alloc)
            else => |e| return e,
        };
        return switch (v) {
            .complex_float => |c| c,
            .complex_int => |c| .{ @floatFromInt(c[0]), @floatFromInt(c[1]) },
            .float => |f| .{ f, 0 },
            .int => |n| .{ @floatFromInt(n), 0 },
            .undefined => error.ValueUndefined,
            else => error.WrongValueType,
        };
    }

    /// The parsed `/ comment` of keyword `name`, borrowed from the card's bytes, or `null` if
    /// the keyword is absent or has no comment (FR-HDR-5).
    pub fn comment(self: *const Header, name: []const u8) ?[]const u8 {
        const card = self.get(name) catch return null;
        // A HIERARCH card's comment follows its value after the `=`, not at fixed columns 11–80.
        const vf = if (hierarch.isHierarch(card)) (hierarch.valueField(card) orelse return null) else card.valueField();
        return value.parseComment(vf);
    }

    /// Fill `out` with the indices of all cards whose names match the wildcard `pattern`
    /// (`*`/`?`/`#`, case-insensitive). Sets `out.overflow` if there were more than fit
    /// (FR-UTL-4). `out` is reset first.
    pub fn find(self: *const Header, pattern: []const u8, out: *Matches) void {
        out.reset();
        for (self.cards.items, 0..) |*c, i| {
            if (c.kind == .end) continue;
            if (@import("name.zig").matchWildcard(pattern, c.name.text())) {
                out.add(@intCast(i));
            } else if (c.name.eqlText("HIERARCH") and hierarch.matchName(c, pattern)) {
                // A HIERARCH card matches when `pattern` is its (exact) hierarchical keyword;
                // its literal 8-byte name is always "HIERARCH" so the wildcard pass misses it.
                out.add(@intCast(i));
            }
        }
    }

    // ── building (the read-side container also supports append-style construction; the full
    //    edit set — insert/delete/rename/update-in-place — is HDR-3b) ──────────────────────

    /// Append a pre-built card.
    pub fn append(self: *Header, alloc: Allocator, card: Card) Allocator.Error!void {
        try self.cards.append(alloc, card);
    }

    /// Build and append a value card `NAME = value / comment` (FR-HDR-11 partial; full edits
    /// in HDR-3b).
    pub fn appendValue(self: *Header, alloc: Allocator, name: []const u8, v: value.KeywordValue, comment_text: ?[]const u8) (HeaderError || Allocator.Error)!void {
        const card = try Card.buildValue(name, v, comment_text);
        try self.cards.append(alloc, card);
    }

    /// Append a string value of any length using the `CONTINUE` long-string convention
    /// (FR-HDR-8, §4.2.1.2): a base value card whose value ends with the `&` continuation marker
    /// plus one or more `CONTINUE` cards, or a single card when the string fits in 68 characters.
    /// `comment` is attached to the final card. Round-trips through `getLongString`.
    pub fn appendLongString(self: *Header, alloc: Allocator, name: []const u8, str: []const u8, comment_text: ?[]const u8) (HeaderError || Allocator.Error)!void {
        const cards = try continuation.split(alloc, name, str, comment_text);
        defer alloc.free(cards);
        try self.cards.appendSlice(alloc, cards);
    }

    /// Append a raw 80-byte card, used by builders that format their own card bytes.
    pub fn appendRaw(self: *Header, alloc: Allocator, raw: *const [80]u8) (HeaderError || Allocator.Error)!void {
        try self.cards.append(alloc, try Card.parse(raw));
    }

    /// Ensure the header ends with an `END` card (appending one if absent). Builders call this
    /// before serialization.
    pub fn ensureEnd(self: *Header, alloc: Allocator) (HeaderError || Allocator.Error)!void {
        if (self.cards.items.len > 0 and self.cards.items[self.cards.items.len - 1].kind == .end) return;
        var raw: [80]u8 = @splat(' ');
        @memcpy(raw[0..3], "END");
        try self.cards.append(alloc, try Card.parse(&raw));
    }

    /// Index of the `END` card, if present (edits insert before it).
    fn endIndex(self: *const Header) ?usize {
        for (self.cards.items, 0..) |*c, i| if (c.kind == .end) return i;
        return null;
    }

    /// Update keyword `name`'s value (and comment): replace it in place if present, else insert
    /// a new value card just before `END` — create-if-absent (FR-HDR-11). When `comment_text`
    /// is null and the keyword exists, its current comment is preserved.
    pub fn update(self: *Header, alloc: Allocator, name: []const u8, v: value.KeywordValue, comment_text: ?[]const u8) (HeaderError || Allocator.Error)!void {
        if (self.findFirst(name)) |i| {
            const keep = comment_text orelse value.parseComment(self.cards.items[i].valueField());
            // Replacing a continued long-string base with a single card must also drop its
            // CONTINUE run (same rule as `delete`): the new value does not continue, so a
            // leftover run would be orphaned garbage commentary.
            const old = &self.cards.items[i];
            var continues = old.kind == .value and continuation.endsWithSentinel(old.valueField()) and
                i + 1 < self.cards.items.len and self.cards.items[i + 1].kind == .continuation;
            self.cards.items[i] = try Card.buildValue(name, v, keep);
            while (continues and i + 1 < self.cards.items.len and self.cards.items[i + 1].kind == .continuation) {
                const c = self.cards.orderedRemove(i + 1);
                continues = continuation.endsWithSentinel(c.valueField());
            }
        } else {
            const card = try Card.buildValue(name, v, comment_text);
            // Prefer filling a reserved blank card in place (FR-HDR-12) over inserting, so the
            // following HDUs need not shift.
            if (self.firstBlankBeforeEnd()) |bi| {
                self.cards.items[bi] = card;
            } else {
                try self.cards.insert(alloc, self.endIndex() orelse self.cards.items.len, card);
            }
        }
    }

    fn firstBlankBeforeEnd(self: *const Header) ?usize {
        for (self.cards.items, 0..) |*c, i| {
            if (c.kind == .end) return null;
            if (c.kind == .blank) return i;
        }
        return null;
    }

    /// Replace an existing keyword's value in place, preserving its position (FR-HDR-11
    /// modify-in-place). `error.KeywordNotFound` if absent.
    pub fn modify(self: *Header, name: []const u8, v: value.KeywordValue, comment_text: ?[]const u8) (HeaderError || ValueError)!void {
        const i = self.findFirst(name) orelse return error.KeywordNotFound;
        const keep = comment_text orelse value.parseComment(self.cards.items[i].valueField());
        self.cards.items[i] = try Card.buildValue(name, v, keep);
    }

    /// Insert a pre-built card at position `index` (0-based).
    pub fn insert(self: *Header, alloc: Allocator, index: usize, card: Card) Allocator.Error!void {
        try self.cards.insert(alloc, index, card);
    }

    /// Delete the first card named `name`. `error.KeywordNotFound` if absent. When the deleted
    /// card holds a string value ending with the `&` continuation sentinel, its CONTINUE run is
    /// removed with it (FR-HDR-8): leaving the run behind would orphan the CONTINUE cards as
    /// garbage commentary that can splice onto a neighboring long string.
    /// `zf_write_key_longstr`'s replace-if-present relies on this to not leak the old run.
    pub fn delete(self: *Header, name: []const u8) ValueError!void {
        const i = self.findFirst(name) orelse return error.KeywordNotFound;
        const card = &self.cards.items[i];
        // A HIERARCH card keeps its value after the `=`, not at fixed columns 11–80 (same
        // routing as valueBytesOf); commentary/blank cards have no value and never continue.
        const field: ?[]const u8 = if (hierarch.isHierarch(card))
            hierarch.valueField(card)
        else if (card.kind == .value)
            card.valueField()
        else
            null;
        var continues = if (field) |vf| continuation.endsWithSentinel(vf) else false;
        _ = self.cards.orderedRemove(i);
        // The run extends while each removed fragment carries the sentinel AND another CONTINUE
        // follows — the same rule `assemble` uses (a trailing `&` on the last card is literal).
        while (continues and i < self.cards.items.len and self.cards.items[i].kind == .continuation) {
            const c = self.cards.orderedRemove(i);
            continues = continuation.endsWithSentinel(c.valueField());
        }
    }

    /// Rename keyword `old` to `new`, preserving its value/comment and position. The new name
    /// is normalized and validated (`error.BadKeywordName` on a bad alphabet).
    pub fn rename(self: *Header, old: []const u8, new: []const u8) (ValueError || HeaderError)!void {
        const i = self.findFirst(old) orelse return error.KeywordNotFound;
        const new_name = try Name.parseStrict(new);
        var raw = self.cards.items[i].raw;
        @memcpy(raw[0..8], &new_name.bytes);
        self.cards.items[i] = try Card.parse(&raw);
    }

    /// Reserve `n` blank cards just before `END` so later `update` calls can fill them in
    /// place without rewriting following HDUs (FR-HDR-12, header-space pre-allocation).
    pub fn reserveSpace(self: *Header, alloc: Allocator, n: usize) (HeaderError || Allocator.Error)!void {
        const pos = self.endIndex() orelse self.cards.items.len;
        const blank: [80]u8 = @splat(' ');
        var k: usize = 0;
        while (k < n) : (k += 1) try self.cards.insert(alloc, pos, try Card.parse(&blank));
    }

    /// Serialize all cards into `writer` (80 bytes each), padding the header unit to a block
    /// boundary with spaces (FR-IO-2). The header must already contain an `END` card.
    pub fn writeTo(self: *const Header, writer: *block.BlockWriter) errors.IoError!void {
        for (self.cards.items) |*c| {
            try writer.write(c.bytes());
        }
        try writer.pad(.space);
    }
};

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;

// Assemble a minimal in-memory header (cards then END, space-padded to a block) and return a
// MemoryDevice holding it.
fn buildHeaderDevice(alloc: Allocator, cards: []const []const u8) !MemoryDevice {
    var buf: [block.BLOCK]u8 = @splat(' ');
    for (cards, 0..) |c, i| {
        @memcpy(buf[i * 80 ..][0..c.len], c);
    }
    @memcpy(buf[cards.len * 80 ..][0..3], "END");
    return MemoryDevice.initBytes(alloc, &buf);
}

test "parse scans to END and reads values with conversion" {
    var mem = try buildHeaderDevice(testing.allocator, &.{
        "SIMPLE  =                    T / conforms to FITS standard",
        "BITPIX  =                  -32 / IEEE single precision",
        "NAXIS   =                    2",
        "NAXIS1  =                  256",
        "NAXIS2  =                  512",
        "OBJECT  = 'M31     '           / target",
    });
    defer mem.deinit();
    var reader = try block.BlockReader.init(testing.allocator, mem.device(), 0);
    defer reader.deinit();

    const res = try Header.parse(testing.allocator, &reader, 0, 36);
    var h = res.header;
    defer h.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 7), res.cards_consumed); // 6 + END

    try testing.expectEqual(true, try h.getValue(bool, "SIMPLE"));
    try testing.expectEqual(@as(i8, -32), try h.getValue(i8, "BITPIX"));
    try testing.expectEqual(@as(u16, 2), try h.getValue(u16, "NAXIS"));
    try testing.expectEqual(@as(f64, 256), try h.getValue(f64, "naxis1")); // case-insensitive
    try testing.expectEqual(@as(usize, 512), try h.getValue(usize, "NAXIS2"));

    const obj = try h.getString(testing.allocator, "OBJECT");
    defer testing.allocator.free(obj);
    try testing.expectEqualStrings("M31", obj);
    try testing.expectEqualStrings("target", h.comment("OBJECT").?);
}

test "missing END within budget is an error" {
    var buf: [block.BLOCK]u8 = @splat(' ');
    @memcpy(buf[0..6], "SIMPLE");
    var mem = try MemoryDevice.initBytes(testing.allocator, &buf);
    defer mem.deinit();
    var reader = try block.BlockReader.init(testing.allocator, mem.device(), 0);
    defer reader.deinit();
    try testing.expectError(error.MissingEnd, Header.parse(testing.allocator, &reader, 0, 36));
}

test "lookup errors and wildcard find" {
    var mem = try buildHeaderDevice(testing.allocator, &.{
        "NAXIS   =                    2",
        "NAXIS1  =                  10",
        "NAXIS2  =                  20",
        "EXTEND  =                    T",
    });
    defer mem.deinit();
    var reader = try block.BlockReader.init(testing.allocator, mem.device(), 0);
    defer reader.deinit();
    const res = try Header.parse(testing.allocator, &reader, 0, 36);
    var h = res.header;
    defer h.deinit(testing.allocator);

    try testing.expectError(error.KeywordNotFound, h.get("MISSING"));
    try testing.expect(h.has("EXTEND"));

    var m: Matches = .{};
    h.find("NAXIS#", &m);
    try testing.expectEqual(@as(usize, 2), m.len); // NAXIS1, NAXIS2 (NAXIS has no digit)
}

test "build, ensureEnd, write, and re-parse round-trips" {
    var h = Header.initEmpty();
    defer h.deinit(testing.allocator);
    try h.appendValue(testing.allocator, "SIMPLE", .{ .logical = true }, "standard");
    try h.appendValue(testing.allocator, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(testing.allocator, "NAXIS", .{ .int = 0 }, null);
    try h.ensureEnd(testing.allocator);

    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var writer = try block.BlockWriter.init(testing.allocator, mem.device(), 0, 0);
    defer writer.deinit();
    try h.writeTo(&writer);
    try testing.expectEqual(@as(u64, block.BLOCK), try mem.device().getSize()); // one padded block

    var reader = try block.BlockReader.init(testing.allocator, mem.device(), 0);
    defer reader.deinit();
    const res = try Header.parse(testing.allocator, &reader, 0, 36);
    var h2 = res.header;
    defer h2.deinit(testing.allocator);
    try testing.expectEqual(true, try h2.getValue(bool, "SIMPLE"));
    try testing.expectEqual(@as(u8, 8), try h2.getValue(u8, "BITPIX"));
    try testing.expectEqual(@as(u16, 0), try h2.getValue(u16, "NAXIS"));
}

test "edit ops: update/modify/insert/delete/rename preserve order and index" {
    var h = Header.initEmpty();
    defer h.deinit(testing.allocator);
    try h.appendValue(testing.allocator, "SIMPLE", .{ .logical = true }, null);
    try h.appendValue(testing.allocator, "BITPIX", .{ .int = 8 }, "bits");
    try h.appendValue(testing.allocator, "NAXIS", .{ .int = 0 }, null);
    try h.ensureEnd(testing.allocator);
    const n0 = h.count();

    // update existing in place (preserve comment when null), and create-if-absent before END.
    try h.update(testing.allocator, "BITPIX", .{ .int = 16 }, null);
    try testing.expectEqual(@as(i64, 16), try h.getValue(i64, "BITPIX"));
    try testing.expectEqualStrings("bits", h.comment("BITPIX").?); // comment preserved
    try h.update(testing.allocator, "EXTEND", .{ .logical = true }, "new");
    try testing.expectEqual(n0 + 1, h.count());
    try testing.expectEqual(true, try h.getValue(bool, "EXTEND"));
    try testing.expect(h.at(h.count() - 1).kind == .end); // END still last

    // modify requires existence.
    try testing.expectError(error.KeywordNotFound, h.modify("MISSING", .{ .int = 1 }, null));
    try h.modify("NAXIS", .{ .int = 2 }, "axes");
    try testing.expectEqual(@as(i64, 2), try h.getValue(i64, "NAXIS"));

    // rename and delete.
    try h.rename("EXTEND", "GROUPS");
    try testing.expect(!h.has("EXTEND"));
    try testing.expectEqual(true, try h.getValue(bool, "GROUPS"));
    try h.delete("GROUPS");
    try testing.expect(!h.has("GROUPS"));
    try testing.expectError(error.KeywordNotFound, h.delete("GROUPS"));
}

test "INHERIT: extension falls through to primary except structural/column keywords (FR-HDR-14)" {
    var primary = Header.initEmpty();
    defer primary.deinit(testing.allocator);
    try primary.appendValue(testing.allocator, "SIMPLE", .{ .logical = true }, null);
    try primary.appendValue(testing.allocator, "BITPIX", .{ .int = 8 }, null);
    try primary.appendValue(testing.allocator, "OBSERVER", .{ .string = "Hubble" }, null);
    try primary.appendValue(testing.allocator, "EQUINOX", .{ .float = 2000.0 }, null);
    try primary.ensureEnd(testing.allocator);

    var ext = Header.initEmpty();
    defer ext.deinit(testing.allocator);
    try ext.appendValue(testing.allocator, "XTENSION", .{ .string = "IMAGE" }, null);
    try ext.appendValue(testing.allocator, "BITPIX", .{ .int = -32 }, null);
    try ext.ensureEnd(testing.allocator);

    // Without inheritance: only the extension's own keywords are visible.
    try testing.expect(!ext.has("OBSERVER"));
    ext.setInherit(&primary);

    // Inheritable keywords fall through.
    const obs = try ext.getString(testing.allocator, "OBSERVER");
    defer testing.allocator.free(obs);
    try testing.expectEqualStrings("Hubble", obs);
    try testing.expectEqual(@as(f64, 2000.0), try ext.getValue(f64, "EQUINOX"));

    // Structural keywords are NOT inherited: the extension's own BITPIX wins, and SIMPLE /
    // NAXISn from the primary are not visible.
    try testing.expectEqual(@as(i64, -32), try ext.getValue(i64, "BITPIX"));
    try testing.expect(!ext.has("SIMPLE"));

    ext.setInherit(null);
    try testing.expect(!ext.has("OBSERVER")); // disabled again
}

test "reserveSpace inserts blank cards before END for in-place fill (FR-HDR-12)" {
    var h = Header.initEmpty();
    defer h.deinit(testing.allocator);
    try h.appendValue(testing.allocator, "SIMPLE", .{ .logical = true }, null);
    try h.ensureEnd(testing.allocator);
    try h.reserveSpace(testing.allocator, 5);
    try testing.expect(h.at(h.count() - 1).kind == .end); // END remains last
    // Filling a keyword uses a reserved slot without growing past the reserved block.
    const before = h.count();
    try h.update(testing.allocator, "BITPIX", .{ .int = 8 }, null);
    try testing.expectEqual(before, h.count()); // filled a blank, no net growth
}

test "long-string CONTINUE: append then getLongString round-trips through the Header (FR-HDR-8)" {
    var h = Header.initEmpty();
    defer h.deinit(testing.allocator);
    const long = "The quick brown fox jumps over the lazy dog, and then keeps right on running " ++
        "across a very wide open field for a good long while under a clear blue sky."; // > 68
    try h.appendLongString(testing.allocator, "LONGSTR", long, "a long comment");
    try h.appendLongString(testing.allocator, "OBJECT", "M31", null); // short ⇒ single card
    try h.ensureEnd(testing.allocator);

    // The long value spanned a base value card plus at least one CONTINUE card.
    try testing.expect(h.at(0).kind == .value);
    try testing.expect(h.at(1).kind == .continuation);

    const got = try h.getLongString(testing.allocator, "LONGSTR");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(long, got);

    // A short (non-continued) string also reads correctly through getLongString.
    const obj = try h.getLongString(testing.allocator, "OBJECT");
    defer testing.allocator.free(obj);
    try testing.expectEqualStrings("M31", obj);

    // A non-string keyword is still a type error.
    try h.appendValue(testing.allocator, "NX", .{ .int = 2 }, null);
    try testing.expectError(error.WrongValueType, h.getLongString(testing.allocator, "NX"));
}

test "getLongString reassembles a multi-card CONTINUE value parsed from real cards (FR-HDR-8)" {
    var mem = try buildHeaderDevice(testing.allocator, &.{
        "WEATHER = 'Partly cloudy during the evening f&'",
        "CONTINUE  'ollowed by cloudy skies overnight.&'",
        "CONTINUE  ' Low 21C. Winds NNE at 5 to 10 mph.'",
        "OBJECT  = 'M31     '",
    });
    defer mem.deinit();
    var reader = try block.BlockReader.init(testing.allocator, mem.device(), 0);
    defer reader.deinit();
    const res = try Header.parse(testing.allocator, &reader, 0, 36);
    var h = res.header;
    defer h.deinit(testing.allocator);

    const got = try h.getLongString(testing.allocator, "WEATHER");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "Partly cloudy during the evening followed by cloudy skies overnight. Low 21C. Winds NNE at 5 to 10 mph.",
        got,
    );
    // The trailing single-card keyword is unaffected by the preceding CONTINUE run.
    const obj = try h.getLongString(testing.allocator, "OBJECT");
    defer testing.allocator.free(obj);
    try testing.expectEqualStrings("M31", obj);
}

fn raw80(s: []const u8) [80]u8 {
    var b: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(b[0..s.len], s);
    return b;
}

test "delete removes the full CONTINUE run of a long string (BUGHUNT 34)" {
    var h = Header.initEmpty();
    defer h.deinit(testing.allocator);
    try h.appendValue(testing.allocator, "BEFORE", .{ .int = 1 }, null);
    try h.appendLongString(testing.allocator, "LONGSTR", "x" ** 150, "c");
    try h.appendValue(testing.allocator, "AFTER", .{ .int = 2 }, null);
    try h.ensureEnd(testing.allocator);
    try testing.expect(h.count() >= 6); // BEFORE + base + ≥2 CONTINUE + AFTER + END

    try h.delete("LONGSTR");
    // The base card AND every CONTINUE card are gone; neighbors and END are intact.
    for (h.cards.items) |c| try testing.expect(c.kind != .continuation);
    try testing.expectEqual(@as(i64, 1), try h.getValue(i64, "BEFORE"));
    try testing.expectEqual(@as(i64, 2), try h.getValue(i64, "AFTER"));
    try testing.expect(!h.has("LONGSTR"));
    try testing.expect(h.at(h.count() - 1).kind == .end);
}

test "delete of a HIERARCH long-string base removes its CONTINUE run" {
    var h = Header.initEmpty();
    defer h.deinit(testing.allocator);
    try h.appendRaw(testing.allocator, &raw80("HIERARCH ESO LONG STR = 'aaaa&'"));
    try h.appendRaw(testing.allocator, &raw80("CONTINUE  'bbbb&'"));
    try h.appendRaw(testing.allocator, &raw80("CONTINUE  'cccc'"));
    try h.appendValue(testing.allocator, "AFTER", .{ .int = 2 }, null);
    try h.ensureEnd(testing.allocator);

    try h.delete("ESO LONG STR"); // HIERARCH name resolved via matchName
    for (h.cards.items) |c| try testing.expect(c.kind != .continuation);
    try testing.expectEqual(@as(i64, 2), try h.getValue(i64, "AFTER"));
    try testing.expectEqual(@as(usize, 2), h.count()); // AFTER + END
}

test "update of a long-string base to a short value removes its CONTINUE run (BUGHUNT 24)" {
    var h = Header.initEmpty();
    defer h.deinit(testing.allocator);
    try h.appendLongString(testing.allocator, "LSTR", "z" ** 150, null);
    try h.appendValue(testing.allocator, "AFTER", .{ .int = 2 }, null);
    try h.ensureEnd(testing.allocator);

    try h.update(testing.allocator, "LSTR", .{ .string = "tiny" }, null);
    for (h.cards.items) |c| try testing.expect(c.kind != .continuation);
    const got = try h.getLongString(testing.allocator, "LSTR");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("tiny", got);
    try testing.expectEqual(@as(i64, 2), try h.getValue(i64, "AFTER"));
}

test "delete keeps a literal trailing '&' value and an unrelated CONTINUE run intact" {
    var h = Header.initEmpty();
    defer h.deinit(testing.allocator);
    // A '&'-terminated value with NO following CONTINUE keeps the '&' literal — deleting it
    // must not consume the next keyword's unrelated CONTINUE run.
    try h.appendRaw(testing.allocator, &raw80("AMPLIT  = 'M31 &'"));
    try h.appendRaw(testing.allocator, &raw80("WEATHER = 'cloudy skies over&'"));
    try h.appendRaw(testing.allocator, &raw80("CONTINUE  'night'"));
    try h.ensureEnd(testing.allocator);

    try h.delete("AMPLIT");
    const got = try h.getLongString(testing.allocator, "WEATHER");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("cloudy skies overnight", got);
}

test "write-path keyword names reject embedded/leading blanks (BUGHUNT 62)" {
    var h = Header.initEmpty();
    defer h.deinit(testing.allocator);
    try testing.expectError(error.BadKeywordName, h.appendValue(testing.allocator, "AB CD", .{ .int = 1 }, null));
    try testing.expectError(error.BadKeywordName, h.appendValue(testing.allocator, " XKEY", .{ .int = 1 }, null));
    try testing.expectError(error.BadKeywordName, h.update(testing.allocator, "AB CD", .{ .int = 1 }, null));
    try testing.expectError(error.BadKeywordName, h.appendLongString(testing.allocator, "AB CD", "z" ** 150, null));

    try h.appendValue(testing.allocator, "GOODKEY", .{ .int = 7 }, null);
    try testing.expectError(error.BadKeywordName, h.rename("GOODKEY", "AB CD"));
    try testing.expectError(error.BadKeywordName, h.rename("GOODKEY", " XKEY"));
    try testing.expectEqual(@as(i64, 7), try h.getValue(i64, "GOODKEY")); // untouched by the failed renames
}

test "HIERARCH lookup through the Header by both spellings (FR-HDR-9)" {
    var mem = try buildHeaderDevice(testing.allocator, &.{
        "BITPIX  =                    8",
        "HIERARCH ESO DET CHIP1 NAME = 'CCD1' / detector name",
        "HIERARCH ESO INS TEMP = 12.5 / Celsius",
    });
    defer mem.deinit();
    var reader = try block.BlockReader.init(testing.allocator, mem.device(), 0);
    defer reader.deinit();
    const res = try Header.parse(testing.allocator, &reader, 0, 36);
    var h = res.header;
    defer h.deinit(testing.allocator);

    // has/get resolve HIERARCH cards by either spelling, case-insensitive.
    try testing.expect(h.has("ESO DET CHIP1 NAME"));
    try testing.expect(h.has("hierarch eso det chip1 name"));
    try testing.expect(!h.has("ESO DET CHIP2 NAME"));
    _ = try h.get("ESO DET CHIP1 NAME"); // resolves to the HIERARCH card (no KeywordNotFound)

    // getHierarch reads the parsed value (string and numeric variants).
    const name = try h.getHierarch(testing.allocator, "ESO DET CHIP1 NAME");
    defer name.deinit(testing.allocator);
    try testing.expectEqualStrings("CCD1", name.string);
    const temp = try h.getHierarch(testing.allocator, "HIERARCH ESO INS TEMP"); // full spelling
    try testing.expectEqual(@as(f64, 12.5), temp.float);
    try testing.expectError(error.KeywordNotFound, h.getHierarch(testing.allocator, "ESO DET CHIP9 GONE"));

    // find() also surfaces a HIERARCH card by its exact hierarchical name.
    var m: Matches = .{};
    h.find("ESO INS TEMP", &m);
    try testing.expectEqual(@as(usize, 1), m.len);

    // Regression: the generic value/comment getters resolve a HIERARCH card by name (has/get
    // above), but previously parsed `card.valueField()` (fixed columns 11–80, which land inside
    // the keyword) instead of the value after the `=`. getValue then returned a spurious
    // BadValueSyntax and comment() returned silently-wrong text. They must now agree with
    // getHierarch and expose the real value/comment.
    try testing.expectEqual(@as(f64, 12.5), try h.getValue(f64, "ESO INS TEMP"));
    try testing.expectEqualStrings("Celsius", h.comment("ESO INS TEMP").?);
    try testing.expectEqualStrings("detector name", h.comment("ESO DET CHIP1 NAME").?);
    const nm = try h.getString(testing.allocator, "ESO DET CHIP1 NAME");
    defer testing.allocator.free(nm);
    try testing.expectEqualStrings("CCD1", nm);
    const un = try h.getValueUnion(testing.allocator, "ESO INS TEMP");
    defer un.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 12.5), un.float);
}

test "complex and undefined values are reachable via getValueUnion/getComplex (FR-HDR-3)" {
    var h = Header.initEmpty();
    defer h.deinit(testing.allocator);
    try h.appendValue(testing.allocator, "CPLXF", .{ .complex_float = .{ 1.5, -2.5 } }, null);
    try h.appendValue(testing.allocator, "CPLXI", .{ .complex_int = .{ 3, 4 } }, null);
    try h.appendValue(testing.allocator, "UNDEF", .undefined, null);
    try h.appendValue(testing.allocator, "REAL", .{ .float = 7.0 }, null);
    try h.appendValue(testing.allocator, "OBJECT", .{ .string = "M31" }, null);
    try h.ensureEnd(testing.allocator);

    // getValueUnion exposes every variant, including those getValue cannot return.
    const vf = try h.getValueUnion(testing.allocator, "CPLXF");
    defer vf.deinit(testing.allocator);
    try testing.expectEqual([2]f64{ 1.5, -2.5 }, vf.complex_float);
    const vi = try h.getValueUnion(testing.allocator, "CPLXI");
    defer vi.deinit(testing.allocator);
    try testing.expectEqual([2]i64{ 3, 4 }, vi.complex_int);
    const vu = try h.getValueUnion(testing.allocator, "UNDEF");
    defer vu.deinit(testing.allocator);
    try testing.expectEqual(value.KeywordValue.undefined, std.meta.activeTag(vu));

    // getComplex normalizes int→float pairs and scalars→(v, 0); rejects non-numeric types.
    try testing.expectEqual([2]f64{ 1.5, -2.5 }, try h.getComplex("CPLXF"));
    try testing.expectEqual([2]f64{ 3.0, 4.0 }, try h.getComplex("CPLXI"));
    try testing.expectEqual([2]f64{ 7.0, 0.0 }, try h.getComplex("REAL"));
    try testing.expectError(error.ValueUndefined, h.getComplex("UNDEF"));
    try testing.expectError(error.WrongValueType, h.getComplex("OBJECT"));

    // getValue still cannot coerce a complex value to a scalar (unchanged contract).
    try testing.expectError(error.WrongValueType, h.getValue(f64, "CPLXF"));
}
