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
const block = @import("../io/block.zig");

const Allocator = std.mem.Allocator;

/// The ordered cards of one HDU header and the API to read and build them.
pub const Header = struct {
    cards: std.ArrayList(Card) = .empty,

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

    /// Borrow the first card whose keyword name matches `name` (case-insensitive). Returns
    /// `error.KeywordNotFound` when there is none. `END` is not matchable by name here.
    pub fn get(self: *const Header, name: []const u8) ValueError!*const Card {
        const idx = self.findFirst(name) orelse return error.KeywordNotFound;
        return &self.cards.items[idx];
    }

    /// Whether a keyword named `name` exists (case-insensitive).
    pub fn has(self: *const Header, name: []const u8) bool {
        return self.findFirst(name) != null;
    }

    fn findFirst(self: *const Header, name: []const u8) ?usize {
        for (self.cards.items, 0..) |*c, i| {
            if (c.kind == .end) continue;
            if (c.name.eqlText(name)) return i;
        }
        return null;
    }

    /// Read the value of keyword `name` converted to `T` (an int, float, or bool) under the
    /// scalar conversion policy (FR-HDR-13, FR-CONV-1). `error.KeywordNotFound` if absent,
    /// `error.ValueUndefined` for a blank value field, `error.WrongValueType` for a type
    /// mismatch (e.g. a string requested as `f64`).
    pub fn getValue(self: *const Header, comptime T: type, name: []const u8) (ValueError || ConvError || HeaderError)!T {
        const card = try self.get(name);
        // The value is parsed from the card's raw bytes on demand. Only numeric/logical types
        // are handled here (no allocation); strings use `getString`.
        var fixed_alloc = std.heap.FixedBufferAllocator.init(&[_]u8{});
        const v = value.parseValue(fixed_alloc.allocator(), card.valueField()) catch |err| switch (err) {
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
        const v = try value.parseValue(alloc, card.valueField());
        switch (v) {
            .string => |s| return @constCast(s),
            .undefined => return error.ValueUndefined,
            else => {
                v.deinit(alloc);
                return error.WrongValueType;
            },
        }
    }

    /// The parsed `/ comment` of keyword `name`, borrowed from the card's bytes, or `null` if
    /// the keyword is absent or has no comment (FR-HDR-5).
    pub fn comment(self: *const Header, name: []const u8) ?[]const u8 {
        const card = self.get(name) catch return null;
        return value.parseComment(card.valueField());
    }

    /// Fill `out` with the indices of all cards whose names match the wildcard `pattern`
    /// (`*`/`?`/`#`, case-insensitive). Sets `out.overflow` if there were more than fit
    /// (FR-UTL-4). `out` is reset first.
    pub fn find(self: *const Header, pattern: []const u8, out: *Matches) void {
        out.reset();
        for (self.cards.items, 0..) |*c, i| {
            if (c.kind == .end) continue;
            if (@import("name.zig").matchWildcard(pattern, c.name.text())) out.add(@intCast(i));
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

    /// Append a raw 80-byte card, used by builders that format their own card bytes.
    pub fn appendRaw(self: *Header, alloc: Allocator, raw: *const [80]u8) (HeaderError || Allocator.Error)!void {
        try self.cards.append(alloc, try Card.parse(raw));
    }

    /// Ensure the header ends with an `END` card (appending one if absent). Builders call this
    /// before serialization.
    pub fn ensureEnd(self: *Header, alloc: Allocator) (HeaderError || Allocator.Error)!void {
        if (self.cards.items.len > 0 and self.cards.items[self.cards.items.len - 1].kind == .end) return;
        var raw: [80]u8 = [_]u8{' '} ** 80;
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
            self.cards.items[i] = try Card.buildValue(name, v, keep);
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

    /// Delete the first card named `name`. `error.KeywordNotFound` if absent.
    pub fn delete(self: *Header, name: []const u8) ValueError!void {
        const i = self.findFirst(name) orelse return error.KeywordNotFound;
        _ = self.cards.orderedRemove(i);
    }

    /// Rename keyword `old` to `new`, preserving its value/comment and position. The new name
    /// is normalized and validated (`error.BadKeywordName` on a bad alphabet).
    pub fn rename(self: *Header, old: []const u8, new: []const u8) (ValueError || HeaderError)!void {
        const i = self.findFirst(old) orelse return error.KeywordNotFound;
        const new_name = try Name.parse(new);
        var raw = self.cards.items[i].raw;
        @memcpy(raw[0..8], &new_name.bytes);
        self.cards.items[i] = try Card.parse(&raw);
    }

    /// Reserve `n` blank cards just before `END` so later `update` calls can fill them in
    /// place without rewriting following HDUs (FR-HDR-12, header-space pre-allocation).
    pub fn reserveSpace(self: *Header, alloc: Allocator, n: usize) (HeaderError || Allocator.Error)!void {
        const pos = self.endIndex() orelse self.cards.items.len;
        const blank: [80]u8 = [_]u8{' '} ** 80;
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
    var buf: [block.BLOCK]u8 = [_]u8{' '} ** block.BLOCK;
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
    var buf: [block.BLOCK]u8 = [_]u8{' '} ** block.BLOCK;
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
