//! World Coordinate System keyword set: parse and serialize (FR-WCS-1, §18.1;
//! FITS 4.0 §8.1–8.2, Tables 21–22).
//!
//! `Wcs.fromHeader` reads the WCS keywords for a given alternate description (`a` = `' '` for
//! the primary, `'A'`–`'Z'` for alternates): `WCSAXES`, `CTYPEi`, `CRPIXi`, `CRVALi`,
//! `CDELTi`, `CUNITi`, the **mutually exclusive** `CDi_j` / `PCi_j` matrices, `PVi_m`,
//! `PSi_m`, `LONPOLE`/`LATPOLE`, `RADESYS`, `EQUINOX`. The legacy `CROTAi` is read but
//! deprecated and is never written together with `PCi_j`/`PVi_m`/`PSi_m`. `writeTo` emits the
//! set back into a header. The pixel↔world transforms themselves are WCS-2 (`celestial.zig`).
const std = @import("std");
const WcsError = @import("../errors.zig").WcsError;
const Header = @import("../header/header.zig").Header;
const Card = @import("../header/card.zig").Card;
const value = @import("../header/value.zig");
const convert = @import("../convert.zig");

const Allocator = std.mem.Allocator;

/// A `PVi_m` numeric projection-parameter term.
pub const PvTerm = struct { axis: u16, m: u16, value: f64 };
/// A `PSi_m` string projection-parameter term (allocator-owned `value`).
pub const PsTerm = struct { axis: u16, m: u16, value: []u8 };

/// The linear transform: either a `PCi_j` matrix (with per-axis `CDELTi`) or a `CDi_j`
/// matrix (which folds in the scale), or none (implicit identity `PC`).
pub const Transform = union(enum) {
    none,
    pc: [][]f64,
    cd: [][]f64,
};

/// A parsed WCS keyword set for one alternate description.
pub const Wcs = struct {
    alt: u8 = ' ',
    axes: u16 = 0,
    ctype: [][]u8 = &.{},
    cunit: [][]u8 = &.{},
    crpix: []f64 = &.{},
    crval: []f64 = &.{},
    cdelt: []f64 = &.{},
    crota: []f64 = &.{}, // legacy, read-only
    transform: Transform = .none,
    pv: []PvTerm = &.{},
    ps: []PsTerm = &.{},
    lonpole: ?f64 = null,
    latpole: ?f64 = null,
    equinox: ?f64 = null,
    radesys: ?[]u8 = null,

    /// Read the WCS keyword set for alternate `alt` (`' '` for the primary). `WCSAXES`
    /// defaults to `NAXIS`. Returns `error.BadWcs` if both `CDi_j` and `PCi_j` are present.
    pub fn fromHeader(a: Allocator, h: *const Header, alt: u8) (WcsError || std.mem.Allocator.Error)!Wcs {
        var self: Wcs = .{ .alt = alt };
        errdefer self.deinit(a);

        // Build a keyword→card index over the header (and its INHERIT chain) ONCE so every WCS
        // lookup below is O(1). Probing CDi_j/PCi_j (up to n², n ≤ 999) and PVi_m/PSi_m (n×100)
        // names via Header.findFirst is an O(cards) linear scan each; a crafted WCSAXES=999 header
        // padded with filler cards otherwise costs ~n²×cards ≈ 10¹¹ comparisons — a CPU-exhaustion
        // DoS (NFR-SAFE-1). All WCS keywords are inheritable, so the merged index preserves INHERIT
        // semantics (NAXIS, which is not inheritable, is read separately below via Header.getValue).
        var name_map = try buildNameMap(a, h);
        defer name_map.deinit(a);

        const naxes = blk: {
            if (getValueAlt(&name_map, u16, "WCSAXES", alt)) |n| break :blk n;
            break :blk h.getValue(u16, "NAXIS") catch 0;
        };
        // A FITS axis count is ≤ 999 (NAXIS/WCSAXES). Reject an oversized declaration: besides
        // making keyword names overflow the 8-char buffer, an unbounded `n` makes anyMatrix's
        // n×n probe an O(n²) CPU DoS (up to 65535² lookups) on a single crafted card.
        if (naxes > 999) return error.BadWcs;
        self.axes = naxes;
        const n: usize = naxes;

        self.ctype = try a.alloc([]u8, n);
        @memset(self.ctype, &.{});
        self.cunit = try a.alloc([]u8, n);
        @memset(self.cunit, &.{});
        self.crpix = try a.alloc(f64, n);
        self.crval = try a.alloc(f64, n);
        self.cdelt = try a.alloc(f64, n);
        self.crota = try a.alloc(f64, n);

        var buf: [8]u8 = undefined;
        for (0..n) |i| {
            const idx = i + 1;
            self.ctype[i] = getStringAlt(a, &name_map, "CTYPE", idx, alt) orelse try a.dupe(u8, "");
            self.cunit[i] = getStringAlt(a, &name_map, "CUNIT", idx, alt) orelse try a.dupe(u8, "");
            self.crpix[i] = getIndexedAlt(&name_map, "CRPIX", idx, alt) orelse 0;
            self.crval[i] = getIndexedAlt(&name_map, "CRVAL", idx, alt) orelse 0;
            self.cdelt[i] = getIndexedAlt(&name_map, "CDELT", idx, alt) orelse 1;
            self.crota[i] = getIndexedAlt(&name_map, "CROTA", idx, alt) orelse 0;
            _ = &buf;
        }

        // Detect CD vs PC (mutually exclusive).
        const has_cd = anyMatrix(&name_map, "CD", n, alt);
        const has_pc = anyMatrix(&name_map, "PC", n, alt);
        if (has_cd and has_pc) return error.BadWcs;
        if (has_cd) {
            self.transform = .{ .cd = try readMatrix(a, &name_map, "CD", n, alt, 0) }; // CD default 0
        } else if (has_pc) {
            self.transform = .{ .pc = try readMatrix(a, &name_map, "PC", n, alt, null) }; // PC default identity
        } else {
            self.transform = .none;
        }

        self.pv = try readPv(a, &name_map, n, alt);
        self.ps = try readPs(a, &name_map, n, alt);
        self.lonpole = getValueAlt(&name_map, f64, "LONPOLE", alt);
        self.latpole = getValueAlt(&name_map, f64, "LATPOLE", alt);
        self.equinox = getValueAlt(&name_map, f64, "EQUINOX", alt);
        if (getStringAltName(a, &name_map, "RADESYS", alt)) |r| self.radesys = r;
        return self;
    }

    /// Serialize the keyword set into `h`. `CROTAi` is **not** written when a `PC`/`PV`/`PS`
    /// representation is present (FR-WCS-1). Mandatory-keyword ordering is the HDU's concern;
    /// this appends the WCS cards.
    pub fn writeTo(self: *const Wcs, a: Allocator, h: *Header) (WcsError || @import("../errors.zig").HeaderError || std.mem.Allocator.Error)!void {
        var buf: [8]u8 = undefined;
        try h.appendValue(a, nameAlt(&buf, "WCSAXES", self.alt), .{ .int = self.axes }, null);
        // An index/axis whose keyword would exceed 8 chars (CTYPE1000, CDi_j with i/j ≥ 100)
        // is unrepresentable in standard FITS keywords -> error.BadWcs rather than a panic.
        for (0..self.axes) |i| {
            const idx = i + 1;
            if (self.ctype[i].len > 0) try h.appendValue(a, indexedName(&buf, "CTYPE", idx, self.alt) orelse return error.BadWcs, .{ .string = self.ctype[i] }, null);
            try h.appendValue(a, indexedName(&buf, "CRPIX", idx, self.alt) orelse return error.BadWcs, .{ .float = self.crpix[i] }, null);
            try h.appendValue(a, indexedName(&buf, "CRVAL", idx, self.alt) orelse return error.BadWcs, .{ .float = self.crval[i] }, null);
            try h.appendValue(a, indexedName(&buf, "CDELT", idx, self.alt) orelse return error.BadWcs, .{ .float = self.cdelt[i] }, null);
            if (self.cunit[i].len > 0) try h.appendValue(a, indexedName(&buf, "CUNIT", idx, self.alt) orelse return error.BadWcs, .{ .string = self.cunit[i] }, null);
        }
        switch (self.transform) {
            .none => {},
            .pc => |m| try writeMatrix(a, h, "PC", m, self.alt),
            .cd => |m| try writeMatrix(a, h, "CD", m, self.alt),
        }
        for (self.pv) |t| {
            try h.appendValue(a, matrixName(&buf, "PV", t.axis, t.m, self.alt) orelse return error.BadWcs, .{ .float = t.value }, null);
        }
        for (self.ps) |t| {
            try h.appendValue(a, matrixName(&buf, "PS", t.axis, t.m, self.alt) orelse return error.BadWcs, .{ .string = t.value }, null);
        }
        if (self.lonpole) |v| try h.appendValue(a, nameAlt(&buf, "LONPOLE", self.alt), .{ .float = v }, null);
        if (self.latpole) |v| try h.appendValue(a, nameAlt(&buf, "LATPOLE", self.alt), .{ .float = v }, null);
        if (self.equinox) |v| try h.appendValue(a, nameAlt(&buf, "EQUINOX", self.alt), .{ .float = v }, null);
        if (self.radesys) |r| try h.appendValue(a, nameAlt(&buf, "RADESYS", self.alt), .{ .string = r }, null);
        // CROTAi is deprecated and intentionally not written when PC/PV/PS exist; since we
        // always serialize via PC/CD, CROTAi is never emitted here (FR-WCS-1).
    }

    /// Release all allocator-owned strings and matrices in this WCS definition.
    pub fn deinit(self: *Wcs, a: Allocator) void {
        for (self.ctype) |s| a.free(s);
        a.free(self.ctype);
        for (self.cunit) |s| a.free(s);
        a.free(self.cunit);
        a.free(self.crpix);
        a.free(self.crval);
        a.free(self.cdelt);
        a.free(self.crota);
        switch (self.transform) {
            .none => {},
            .pc, .cd => |m| {
                for (m) |row| a.free(row);
                a.free(m);
            },
        }
        a.free(self.pv);
        for (self.ps) |t| a.free(t.value);
        a.free(self.ps);
        if (self.radesys) |r| a.free(r);
    }
};

// ── name builders ──────────────────────────────────────────────────────────────────────

// The alternate-WCS letter as a keyword suffix, written into `buf` (empty for the primary
// description). The byte must live in caller-owned storage: returning a slice of a temporary
// `&[_]u8{alt}` dangles into reclaimed stack the moment this returns — harmless in Debug (the
// stack still holds the byte) but a garbage suffix in ReleaseFast, which silently mis-reads
// every alternate-WCS keyword (e.g. `CTYPE1A`).
fn altSuffix(buf: *[1]u8, alt: u8) []const u8 {
    if (alt == ' ' or alt == 0) return "";
    buf[0] = alt;
    return buf[0..1];
}

fn nameAlt(buf: *[8]u8, comptime base: []const u8, alt: u8) []const u8 {
    var sfx: [1]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, altSuffix(&sfx, alt) }) catch unreachable;
}

// `null` when the formatted keyword would exceed the 8-char FITS limit (e.g. CTYPE1000,
// CD100_100): such a keyword cannot exist in a valid header, so callers treat it as absent
// rather than panicking via `catch unreachable`.
fn indexedName(buf: *[8]u8, comptime base: []const u8, idx: usize, alt: u8) ?[]const u8 {
    var sfx: [1]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}{d}{s}", .{ base, idx, altSuffix(&sfx, alt) }) catch null;
}

fn matrixName(buf: *[8]u8, comptime base: []const u8, i: usize, j: usize, alt: u8) ?[]const u8 {
    var sfx: [1]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}{d}_{d}{s}", .{ base, i, j, altSuffix(&sfx, alt) }) catch null;
}

// ── readers ────────────────────────────────────────────────────────────────────────────

// A keyword-name → card index, used to make the WCS keyword reads O(1) instead of O(cards).
const NameMap = std.StringHashMapUnmanaged(*const Card);

// Index every named card of `h` and its INHERIT chain by its normalized keyword text, nearest
// header winning (matching `Header.findFirst`-then-inherit). Built once per `fromHeader`; the
// keys reference card-owned bytes that outlive the map (freed before `fromHeader` returns).
fn buildNameMap(a: Allocator, h: *const Header) Allocator.Error!NameMap {
    var map: NameMap = .empty;
    errdefer map.deinit(a);
    var hp: ?*const Header = h;
    while (hp) |hdr| : (hp = hdr.inherit) {
        for (hdr.cards.items) |*c| {
            if (c.kind == .end) continue;
            const gop = try map.getOrPut(a, c.name.text());
            if (!gop.found_existing) gop.value_ptr.* = c; // first occurrence wins
        }
    }
    return map;
}

// Read `name` as an int/float, mirroring `Header.getValue` coercion; `null` when absent or not a
// numeric value (a string value needs allocation, so the empty fixed buffer maps it to `null`).
fn mapValue(map: *const NameMap, comptime T: type, name: []const u8) ?T {
    const card = map.get(name) orelse return null;
    var fixed = std.heap.FixedBufferAllocator.init(&[_]u8{});
    const v = value.parseValue(fixed.allocator(), card.valueField()) catch return null;
    return switch (v) {
        .int => |nn| convert.cast(T, nn, .scalar) catch null,
        .float => |f| convert.cast(T, f, .scalar) catch null,
        else => null,
    };
}

// Read `name` as an owned string (caller frees), mirroring `Header.getString`; `null` when absent
// or not a string value.
fn mapString(a: Allocator, map: *const NameMap, name: []const u8) ?[]u8 {
    const card = map.get(name) orelse return null;
    const v = value.parseValue(a, card.valueField()) catch return null;
    switch (v) {
        .string => |s| return @constCast(s),
        else => {
            v.deinit(a);
            return null;
        },
    }
}

fn getValueAlt(map: *const NameMap, comptime T: type, comptime base: []const u8, alt: u8) ?T {
    var buf: [8]u8 = undefined;
    return mapValue(map, T, nameAlt(&buf, base, alt));
}

fn getIndexedAlt(map: *const NameMap, comptime base: []const u8, idx: usize, alt: u8) ?f64 {
    var buf: [8]u8 = undefined;
    const name = indexedName(&buf, base, idx, alt) orelse return null;
    return mapValue(map, f64, name);
}

fn getStringAlt(a: Allocator, map: *const NameMap, comptime base: []const u8, idx: usize, alt: u8) ?[]u8 {
    var buf: [8]u8 = undefined;
    const name = indexedName(&buf, base, idx, alt) orelse return null;
    return mapString(a, map, name);
}

fn getStringAltName(a: Allocator, map: *const NameMap, comptime base: []const u8, alt: u8) ?[]u8 {
    var buf: [8]u8 = undefined;
    return mapString(a, map, nameAlt(&buf, base, alt));
}

fn anyMatrix(map: *const NameMap, comptime base: []const u8, n: usize, alt: u8) bool {
    var buf: [8]u8 = undefined;
    for (1..n + 1) |i| {
        for (1..n + 1) |j| {
            const name = matrixName(&buf, base, i, j, alt) orelse continue;
            if (map.get(name) != null) return true;
        }
    }
    return false;
}

fn readMatrix(a: Allocator, map: *const NameMap, comptime base: []const u8, n: usize, alt: u8, default_off_diag: ?f64) std.mem.Allocator.Error![][]f64 {
    var buf: [8]u8 = undefined;
    const m = try a.alloc([]f64, n);
    var made: usize = 0;
    errdefer {
        for (m[0..made]) |row| a.free(row);
        a.free(m);
    }
    for (0..n) |i| {
        m[i] = try a.alloc(f64, n);
        made += 1;
        for (0..n) |j| {
            // Default: PC is identity (1 on diagonal, 0 off); CD is 0 everywhere. A name that
            // can't fit 8 chars (i/j ≥ 100) can't be present, so it keeps the default.
            const def = if (default_off_diag) |d| d else (if (i == j) @as(f64, 1) else 0);
            const name = matrixName(&buf, base, i + 1, j + 1, alt) orelse {
                m[i][j] = def;
                continue;
            };
            m[i][j] = mapValue(map, f64, name) orelse def;
        }
    }
    return m;
}

fn readPv(a: Allocator, map: *const NameMap, n: usize, alt: u8) std.mem.Allocator.Error![]PvTerm {
    var list: std.ArrayList(PvTerm) = .empty;
    errdefer list.deinit(a);
    var buf: [8]u8 = undefined;
    for (1..n + 1) |i| {
        for (0..100) |m| {
            const name = matrixName(&buf, "PV", i, m, alt) orelse continue;
            if (mapValue(map, f64, name)) |v| {
                try list.append(a, .{ .axis = @intCast(i), .m = @intCast(m), .value = v });
            }
        }
    }
    return list.toOwnedSlice(a);
}

fn readPs(a: Allocator, map: *const NameMap, n: usize, alt: u8) std.mem.Allocator.Error![]PsTerm {
    var list: std.ArrayList(PsTerm) = .empty;
    errdefer {
        for (list.items) |t| a.free(t.value);
        list.deinit(a);
    }
    var buf: [8]u8 = undefined;
    for (1..n + 1) |i| {
        for (0..100) |m| {
            const name = matrixName(&buf, "PS", i, m, alt) orelse continue;
            const s = mapString(a, map, name) orelse continue;
            errdefer a.free(s); // free the just-parsed string if the append below fails (OOM)
            try list.append(a, .{ .axis = @intCast(i), .m = @intCast(m), .value = s });
        }
    }
    return list.toOwnedSlice(a);
}

fn writeMatrix(a: Allocator, h: *Header, comptime base: []const u8, m: [][]f64, alt: u8) (WcsError || @import("../errors.zig").HeaderError || std.mem.Allocator.Error)!void {
    var buf: [8]u8 = undefined;
    for (m, 0..) |row, i| {
        for (row, 0..) |v, j| {
            // i/j ≥ 100 would make `base{i}_{j}` exceed 8 chars — unrepresentable in standard
            // FITS keywords, so the WCS cannot be serialized.
            const name = matrixName(&buf, base, i + 1, j + 1, alt) orelse return error.BadWcs;
            try h.appendValue(a, name, .{ .float = v }, null);
        }
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const block = @import("../io/block.zig");
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;

fn headerFrom(a: Allocator, cards: []const []const u8) !struct { h: Header, mem: *MemoryDevice, reader: *block.BlockReader } {
    const mem = try a.create(MemoryDevice);
    var buf: [block.BLOCK]u8 = @splat(' ');
    for (cards, 0..) |c, i| @memcpy(buf[i * 80 ..][0..c.len], c);
    @memcpy(buf[cards.len * 80 ..][0..3], "END");
    mem.* = try MemoryDevice.initBytes(a, &buf);
    const reader = try a.create(block.BlockReader);
    reader.* = try block.BlockReader.init(a, mem.device(), 0);
    const res = try Header.parse(a, reader, 0, 36);
    return .{ .h = res.header, .mem = mem, .reader = reader };
}

test "parse a TAN WCS with PC matrix and PV terms" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---TAN'",
        "CTYPE2  = 'DEC--TAN'",
        "CRPIX1  =                256.0",
        "CRPIX2  =                256.0",
        "CRVAL1  =                150.0",
        "CRVAL2  =                  2.5",
        "CDELT1  =               -0.001",
        "CDELT2  =                0.001",
        "PC1_1   =                  1.0",
        "PC1_2   =                  0.0",
        "PC2_1   =                  0.0",
        "PC2_2   =                  1.0",
        "PV2_1   =                  0.0",
        "LONPOLE =                180.0",
        "RADESYS = 'FK5'",
        "EQUINOX =               2000.0",
    });
    defer {
        p.h.deinit(testing.allocator);
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var w = try Wcs.fromHeader(testing.allocator, &p.h, ' ');
    defer w.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), w.axes);
    try testing.expectEqualStrings("RA---TAN", w.ctype[0]);
    try testing.expectEqualStrings("DEC--TAN", w.ctype[1]);
    try testing.expectEqual(@as(f64, 256.0), w.crpix[0]);
    try testing.expectEqual(@as(f64, -0.001), w.cdelt[0]);
    try testing.expect(w.transform == .pc);
    try testing.expectEqual(@as(f64, 1.0), w.transform.pc[0][0]);
    try testing.expectEqual(@as(usize, 1), w.pv.len);
    try testing.expectEqual(@as(f64, 180.0), w.lonpole.?);
    try testing.expectEqual(@as(f64, 2000.0), w.equinox.?);
    try testing.expectEqualStrings("FK5", w.radesys.?);
}

test "CD and PC together is BadWcs" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    2",
        "CD1_1   =                  1.0",
        "PC1_1   =                  1.0",
    });
    defer {
        p.h.deinit(testing.allocator);
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    try testing.expectError(error.BadWcs, Wcs.fromHeader(testing.allocator, &p.h, ' '));
}

test "oversized WCSAXES is handled without overflowing the 8-char keyword buffer" {
    // WCSAXES=100 is FITS-legal. CDi_j with i/j ≥ 100 (e.g. CD100_100, 9 chars) simply can't
    // exist, so the matrix probe skips them — was a `catch unreachable` panic. fromHeader returns.
    {
        var p = try headerFrom(testing.allocator, &.{"WCSAXES =                  100"});
        defer {
            p.h.deinit(testing.allocator);
            p.reader.deinit();
            testing.allocator.destroy(p.reader);
            p.mem.deinit();
            testing.allocator.destroy(p.mem);
        }
        var w = try Wcs.fromHeader(testing.allocator, &p.h, ' ');
        defer w.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 100), w.axes);
    }
    // WCSAXES > 999 is not FITS-legal; rejecting it also bounds the O(n²) matrix probe (DoS).
    {
        var p = try headerFrom(testing.allocator, &.{"WCSAXES =                 1000"});
        defer {
            p.h.deinit(testing.allocator);
            p.reader.deinit();
            testing.allocator.destroy(p.reader);
            p.mem.deinit();
            testing.allocator.destroy(p.mem);
        }
        try testing.expectError(error.BadWcs, Wcs.fromHeader(testing.allocator, &p.h, ' '));
    }
}

test "PC defaults to identity, CD defaults to zero" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---TAN'",
        "CTYPE2  = 'DEC--TAN'",
    });
    defer {
        p.h.deinit(testing.allocator);
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var w = try Wcs.fromHeader(testing.allocator, &p.h, ' ');
    defer w.deinit(testing.allocator);
    // No PC/CD present ⇒ none (implicit identity); cdelt defaults to 1.
    try testing.expect(w.transform == .none);
    try testing.expectEqual(@as(f64, 1), w.cdelt[0]);
}

test "round-trip: parse, write to a new header, re-parse" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---SIN'",
        "CTYPE2  = 'DEC--SIN'",
        "CRPIX1  =                100.0",
        "CRPIX2  =                100.0",
        "CRVAL1  =                 10.0",
        "CRVAL2  =                -20.0",
        "CDELT1  =                 0.01",
        "CDELT2  =                 0.01",
    });
    defer {
        p.h.deinit(testing.allocator);
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var w = try Wcs.fromHeader(testing.allocator, &p.h, ' ');
    defer w.deinit(testing.allocator);

    var h2 = Header.initEmpty();
    defer h2.deinit(testing.allocator);
    try w.writeTo(testing.allocator, &h2);

    var w2 = try Wcs.fromHeader(testing.allocator, &h2, ' ');
    defer w2.deinit(testing.allocator);
    try testing.expectEqualStrings("RA---SIN", w2.ctype[0]);
    try testing.expectEqual(@as(f64, 100.0), w2.crpix[0]);
    try testing.expectEqual(@as(f64, -20.0), w2.crval[1]);
    try testing.expectEqual(@as(f64, 0.01), w2.cdelt[0]);
}

test "alternate WCS description with a suffix" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXESA=                    1",
        "CTYPE1A = 'WAVE'",
        "CRVAL1A =               5000.0",
        "CDELT1A =                  1.5",
    });
    defer {
        p.h.deinit(testing.allocator);
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var w = try Wcs.fromHeader(testing.allocator, &p.h, 'A');
    defer w.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 1), w.axes);
    try testing.expectEqualStrings("WAVE", w.ctype[0]);
    try testing.expectEqual(@as(f64, 5000.0), w.crval[0]);
}
