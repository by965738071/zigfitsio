//! Hierarchical **grouping tables** (GRP-1): the FITS "Grouping" registry convention layered on
//! top of a `BINTABLE` (design §20.4; FITS grouping convention, Jennings/Pence/Folk/Schlesinger).
//!
//! A *grouping table* is an ordinary binary table whose rows each describe one **member HDU**.
//! The standard member-identity columns (FR-GRP-1) are:
//!   - `MEMBER_XTENSION` — the member's `XTENSION` string (e.g. `'IMAGE'`, `'BINTABLE'`).
//!   - `MEMBER_NAME`     — the member's `EXTNAME`.
//!   - `MEMBER_VERSION`  — the member's `EXTVER`.
//!   - `MEMBER_POSITION` — the member's 1-based HDU position within its file.
//!   - `MEMBER_URI_TYPE` — the URI scheme of `MEMBER_LOCATION` (e.g. `'URL'`), or blank in-file.
//!   - `MEMBER_LOCATION` — the URI of the file holding the member, or blank when in the same file.
//! The group itself may carry a `GRPNAME` header keyword.
//!
//! The reciprocal **member-side linkage** keywords live in each member HDU's header (FR-GRP-1):
//!   - `GRPIDn`  — a signed integer; for an in-file group its (positive) value is the 1-based HDU
//!                 position of the grouping table. A negative value pairs with a `GRPLCn`.
//!   - `GRPLCn`  — the location URI of the file holding the grouping table (inter-file links).
//!
//! Resolution (FR-GRP-1): a row is matched to a real `*Hdu` in the same `Fits` first by
//! `MEMBER_POSITION` (the unambiguous in-file pointer), falling back to `EXTNAME`/`EXTVER`
//! (`MEMBER_NAME`/`MEMBER_VERSION`). Inter-file members (non-blank `MEMBER_LOCATION`) resolve to
//! `null` — following them across files is out of scope here.
//!
//! Editing (FR-GRP-2): `create` builds a conforming grouping `BINTABLE`; `addMember`/`removeMember`
//! keep the table rows and the member's `GRPIDn` keyword in sync (rows via the BTB-3b
//! `BinTable.appendRows`/`deleteRows`, headers via `Fits.rewriteHeaderInPlace`), so a re-resolve
//! after either edit reflects the change.
const std = @import("std");
const errors = @import("errors.zig");
const fits_mod = @import("fits.zig");
const Fits = fits_mod.Fits;
const Hdu = @import("hdu.zig").Hdu;
const Header = @import("header/header.zig").Header;
const KeywordValue = @import("header/value.zig").KeywordValue;
const binary = @import("table/binary.zig");
const BinTable = binary.BinTable;
const common = @import("table/common.zig");
const BinTform = common.BinTform;

const Allocator = std.mem.Allocator;

/// The error set produced by grouping-table operations. `binary.OpenError` already unions
/// `TableError`/`StructError`/`IoError`/`ConvError`/`ValueError`/`HeaderError`/`LimitError`/
/// `Allocator.Error`, which is a superset of `Fits.FitsError` and `binary.AccessError`, so it is
/// the single set every routine here may return.
pub const GroupError = binary.OpenError;

/// One member-side linkage read from an HDU's header (`GRPIDn` and its optional `GRPLCn`).
pub const GroupLink = struct {
    /// The `GRPIDn` value: positive ⇒ in-file group at that 1-based HDU position; negative ⇒
    /// inter-file link keyed by `location`.
    grpid: i64,
    /// Owned `GRPLCn` location URI (caller frees), or `null` for an in-file link.
    location: ?[]u8,
};

/// Free a slice returned by `groupsOf` (each owned `location` then the slice itself).
pub fn freeGroupLinks(alloc: Allocator, links: []GroupLink) void {
    for (links) |l| if (l.location) |s| alloc.free(s);
    alloc.free(links);
}

/// The standard grouping-table member columns, in canonical order, with the `TFORM` widths used
/// by `create`. String widths are generous defaults; a grouping table opened with `of` may use any
/// widths (the code reads each column's actual width from its parsed `TFORM`).
const GroupCol = struct { name: []const u8, tform: []const u8 };
const GROUP_COLS = [_]GroupCol{
    .{ .name = "MEMBER_XTENSION", .tform = "20A" },
    .{ .name = "MEMBER_NAME", .tform = "48A" },
    .{ .name = "MEMBER_VERSION", .tform = "1J" },
    .{ .name = "MEMBER_POSITION", .tform = "1J" },
    .{ .name = "MEMBER_URI_TYPE", .tform = "8A" },
    .{ .name = "MEMBER_LOCATION", .tform = "80A" },
};

/// A view over a grouping `BINTABLE`: the underlying `BinTable` plus the resolved (optional)
/// member-column indices.
pub const GroupTable = struct {
    /// The underlying binary-table view (owns the column descriptors).
    table: BinTable,
    col_xtension: ?u16,
    col_name: ?u16,
    col_version: ?u16,
    col_position: ?u16,
    col_uri_type: ?u16,
    col_location: ?u16,

    /// Wrap an existing grouping `BINTABLE` HDU, resolving whichever standard member columns are
    /// present. `error.WrongHduType` if `hdu` is not a binary table, or if it carries none of the
    /// `MEMBER_*` identity columns (so it is not a grouping table at all).
    pub fn of(fits: *Fits, hdu: *Hdu) GroupError!GroupTable {
        var table = try BinTable.of(fits, hdu);
        errdefer table.deinit(fits.alloc);
        const self = fromTable(table);
        if (self.col_position == null and self.col_name == null) return error.WrongHduType;
        return self;
    }

    /// Create a new, empty grouping `BINTABLE` (appended after the last HDU) with the canonical
    /// member columns and an optional `GRPNAME`. Returns the wrapped view (FR-GRP-2).
    pub fn create(fits: *Fits, name: ?[]const u8) GroupError!GroupTable {
        const header = try buildGroupingHeader(fits.alloc, name);
        const hdu = try fits.appendHdu(header); // takes ownership of `header`
        var table = try BinTable.of(fits, hdu);
        errdefer table.deinit(fits.alloc);
        return fromTable(table);
    }

    fn fromTable(table: BinTable) GroupTable {
        return .{
            .table = table,
            .col_xtension = findCol(&table, "MEMBER_XTENSION"),
            .col_name = findCol(&table, "MEMBER_NAME"),
            .col_version = findCol(&table, "MEMBER_VERSION"),
            .col_position = findCol(&table, "MEMBER_POSITION"),
            .col_uri_type = findCol(&table, "MEMBER_URI_TYPE"),
            .col_location = findCol(&table, "MEMBER_LOCATION"),
        };
    }

    /// Release the owned column descriptors of the underlying table.
    pub fn deinit(self: *GroupTable, alloc: Allocator) void {
        self.table.deinit(alloc);
    }

    /// Number of member rows (`NAXIS2`).
    pub fn memberCount(self: *const GroupTable) u64 {
        return self.table.rowCount();
    }

    /// The 1-based HDU position of this grouping table within its file (forces a full scan).
    pub fn position(self: *GroupTable) GroupError!usize {
        const fits = self.table.fits;
        _ = try fits.hduCount();
        return (hduIndex(fits, self.table.hdu) orelse return error.WrongHduType) + 1;
    }

    /// The grouping table's `GRPNAME` (owned, caller frees), or `null` when absent.
    pub fn groupName(self: *const GroupTable, alloc: Allocator) GroupError!?[]u8 {
        const hdr = &self.table.hdu.header;
        if (!hdr.has("GRPNAME")) return null;
        return hdr.getString(alloc, "GRPNAME") catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    }

    /// The `MEMBER_NAME` of `row` (owned, trailing blanks trimmed), or `null` if the column is
    /// absent or the cell is blank.
    pub fn memberName(self: *GroupTable, alloc: Allocator, row: u64) GroupError!?[]u8 {
        const ci = self.col_name orelse return null;
        const s = try self.readStrCell(alloc, ci, row);
        if (s.len == 0) {
            alloc.free(s);
            return null;
        }
        return s;
    }

    /// The `MEMBER_POSITION` of `row` (1-based), or `null` if the column is absent.
    pub fn memberPosition(self: *GroupTable, row: u64) GroupError!?i64 {
        const ci = self.col_position orelse return null;
        return try self.readIntCell(ci, row);
    }

    /// Resolve `row` to the actual member `*Hdu` in the same `Fits`, or `null` for an unresolved
    /// or inter-file member (FR-GRP-1). Tries `MEMBER_POSITION` first, then `EXTNAME`/`EXTVER`.
    pub fn resolveMember(self: *GroupTable, row: u64) GroupError!?*Hdu {
        if (row >= self.table.rowCount()) return error.RowOutOfRange;
        const fits = self.table.fits;
        _ = try fits.hduCount(); // membership only resolves against a fully-scanned file

        // An inter-file member (non-blank MEMBER_LOCATION) lives in another file; following it is
        // out of scope here, so never let MEMBER_POSITION/EXTNAME resolve it against the local
        // file. The cell is inspected at ANY column width — a MEMBER_LOCATION wider than a stack
        // buffer must not be skipped (that silently mis-resolved an inter-file row to a local HDU).
        if (self.col_location) |ci| {
            if (try self.cellNonBlank(ci, row)) return null;
        }

        if (self.col_position) |ci| {
            const pos = try self.readIntCell(ci, row);
            if (pos >= 1 and @as(u64, @intCast(pos)) <= fits.hdus.items.len) {
                return fits.hdus.items[@intCast(pos - 1)];
            }
        }
        if (self.col_name) |ci| {
            const alloc = self.table.fits.alloc;
            const nm = try self.readStrCell(alloc, ci, row); // handles any column width
            defer alloc.free(nm);
            if (nm.len > 0) {
                const ver: i64 = if (self.col_version) |vi| try self.readIntCell(vi, row) else 1;
                return matchByNameVer(fits, nm, ver);
            }
        }
        return null;
    }

    // True if the cell at (col_idx, row) has any non-blank content, inspected at the column's full
    // width: a stack buffer for the common case, the handle allocator for wider columns.
    fn cellNonBlank(self: *GroupTable, col_idx: u16, row: u64) GroupError!bool {
        const col = &self.table.columns[col_idx];
        const w: usize = @intCast(col.tform.repeat);
        if (w == 0) return false;
        var stack: [256]u8 = undefined;
        if (w <= stack.len) {
            try self.table.readColumn(u8, .{ .index = col_idx }, row, stack[0..w], .{});
            return std.mem.trimEnd(u8, stack[0..w], " ").len > 0;
        }
        const alloc = self.table.fits.alloc;
        const buf = try alloc.alloc(u8, w);
        defer alloc.free(buf);
        try self.table.readColumn(u8, .{ .index = col_idx }, row, buf, .{});
        return std.mem.trimEnd(u8, buf, " ").len > 0;
    }

    /// Resolve every member row to a `*Hdu`, returning an owned slice (caller frees) of the
    /// resolvable in-file members in row order. Unresolved/inter-file rows are skipped.
    pub fn members(self: *GroupTable, alloc: Allocator) GroupError![]*Hdu {
        var list: std.ArrayList(*Hdu) = .empty;
        errdefer list.deinit(alloc);
        var r: u64 = 0;
        while (r < self.table.rowCount()) : (r += 1) {
            if (try self.resolveMember(r)) |h| try list.append(alloc, h);
        }
        return list.toOwnedSlice(alloc);
    }

    /// Add `member` to the group (FR-GRP-2): append a row whose `MEMBER_*` cells describe the
    /// member, and add a `GRPIDn` keyword to the member's header pointing at this grouping table.
    /// Returns the new 0-based row index. `error.NotWritable` on a read-only handle.
    pub fn addMember(self: *GroupTable, member: *Hdu) GroupError!u64 {
        const fits = self.table.fits;
        if (fits.mode == .read_only or !fits.dev.isWritable()) return error.NotWritable;
        const grp_pos = try self.position();
        const mpos = (hduIndex(fits, member) orelse return error.WrongHduType) + 1;

        const new_row = self.table.rowCount();
        try self.table.appendRows(1);

        // Fill the new row's identity cells from the member's header.
        if (self.col_xtension) |ci| try self.writeHduString(ci, new_row, member, "XTENSION");
        if (self.col_name) |ci| try self.writeHduString(ci, new_row, member, "EXTNAME");
        if (self.col_version) |ci| {
            const ver = member.header.getValue(i64, "EXTVER") catch 1;
            try self.writeIntCell(ci, new_row, ver);
        }
        if (self.col_position) |ci| try self.writeIntCell(ci, new_row, @intCast(mpos));
        // URI_TYPE / LOCATION are left blank (the zero-filled row already reads as blank): the
        // member lives in the same file.

        // Member-side linkage: add the next free GRPIDn = grouping-table position.
        const n = try nextGrpidIndex(&member.header);
        var kw: [16]u8 = undefined;
        try member.header.update(fits.alloc, grpidName(&kw, n), .{ .int = @intCast(grp_pos) }, null);
        try fits.rewriteHeaderInPlace(member);

        return new_row;
    }

    /// Remove `member` from the group (FR-GRP-2): delete its row and the matching `GRPIDn`/`GRPLCn`
    /// keywords from the member's header. Returns `true` if a member row was found and removed.
    /// `error.NotWritable` on a read-only handle.
    pub fn removeMember(self: *GroupTable, member: *Hdu) GroupError!bool {
        const fits = self.table.fits;
        if (fits.mode == .read_only or !fits.dev.isWritable()) return error.NotWritable;
        const grp_pos = try self.position();
        const mpos = (hduIndex(fits, member) orelse return error.WrongHduType) + 1;

        // Find the row that resolves to this member.
        var found: ?u64 = null;
        var r: u64 = 0;
        while (r < self.table.rowCount()) : (r += 1) {
            if (try self.resolveMember(r)) |h| {
                if (h == member) {
                    found = r;
                    break;
                }
            }
        }
        const row = found orelse return false;
        try self.table.deleteRows(row, 1);

        // Member-side linkage: drop the GRPIDn (and any paired GRPLCn) that pointed at this group.
        try self.dropGrpid(member, @intCast(grp_pos));
        // `mpos` is unused beyond the existence check above; keep it referenced.
        _ = mpos;
        return true;
    }

    // ── internals ────────────────────────────────────────────────────────────────────────────

    fn dropGrpid(self: *GroupTable, member: *Hdu, grp_pos: i64) GroupError!void {
        const fits = self.table.fits;
        var changed = false;
        var n: usize = 1;
        var kw: [16]u8 = undefined;
        while (n <= 999) : (n += 1) {
            const name = grpidName(&kw, n);
            if (!member.header.has(name)) continue; // scan the full range (mirror groupsOf)
            const v = member.header.getValue(i64, name) catch continue;
            if (v == grp_pos) {
                member.header.delete(name) catch {};
                var lk: [16]u8 = undefined;
                member.header.delete(grplcName(&lk, n)) catch {};
                changed = true;
            }
        }
        if (changed) try fits.rewriteHeaderInPlace(member);
    }

    fn writeHduString(self: *GroupTable, col_idx: u16, row: u64, hdu: *Hdu, kw: []const u8) GroupError!void {
        const alloc = self.table.fits.alloc;
        const s = hdu.header.getString(alloc, kw) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.writeStrCell(col_idx, row, "");
                return;
            },
        };
        defer alloc.free(s);
        try self.writeStrCell(col_idx, row, std.mem.trim(u8, s, " "));
    }

    fn readStrCell(self: *GroupTable, alloc: Allocator, col_idx: u16, row: u64) GroupError![]u8 {
        const col = &self.table.columns[col_idx];
        const w: usize = @intCast(col.tform.repeat);
        const buf = try alloc.alloc(u8, w);
        defer alloc.free(buf);
        if (w > 0) try self.table.readColumn(u8, .{ .index = col_idx }, row, buf, .{});
        const trimmed = std.mem.trimEnd(u8, buf, " ");
        return alloc.dupe(u8, trimmed);
    }

    fn writeStrCell(self: *GroupTable, col_idx: u16, row: u64, s: []const u8) GroupError!void {
        const alloc = self.table.fits.alloc;
        const col = &self.table.columns[col_idx];
        const w: usize = @intCast(col.tform.repeat);
        if (w == 0) return;
        const buf = try alloc.alloc(u8, w);
        defer alloc.free(buf);
        @memset(buf, ' ');
        const n = @min(w, s.len);
        @memcpy(buf[0..n], s[0..n]);
        try self.table.writeColumn(u8, .{ .index = col_idx }, row, buf, .{});
    }

    fn readIntCell(self: *GroupTable, col_idx: u16, row: u64) GroupError!i64 {
        var b: [1]i64 = undefined;
        try self.table.readCell(i64, .{ .index = col_idx }, row, &b, .{});
        return b[0];
    }

    fn writeIntCell(self: *GroupTable, col_idx: u16, row: u64, v: i64) GroupError!void {
        try self.table.writeColumn(i64, .{ .index = col_idx }, row, &[_]i64{v}, .{});
    }
};

/// Read all member-side group linkages (`GRPIDn`/`GRPLCn`) from `hdu`'s header (FR-GRP-1).
/// Returns an owned slice (free with `freeGroupLinks`). Scans `n = 1..999` and collects every
/// present `GRPIDn`.
pub fn groupsOf(alloc: Allocator, hdu: *const Hdu) GroupError![]GroupLink {
    var list: std.ArrayList(GroupLink) = .empty;
    errdefer {
        for (list.items) |l| if (l.location) |s| alloc.free(s);
        list.deinit(alloc);
    }
    var kw: [16]u8 = undefined;
    var lk: [16]u8 = undefined;
    var n: usize = 1;
    while (n <= 999) : (n += 1) {
        const name = grpidName(&kw, n);
        if (!hdu.header.has(name)) continue;
        const grpid = hdu.header.getValue(i64, name) catch continue;
        var location: ?[]u8 = null;
        const lcn = grplcName(&lk, n);
        if (hdu.header.has(lcn)) {
            location = hdu.header.getString(alloc, lcn) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        }
        try list.append(alloc, .{ .grpid = grpid, .location = location });
    }
    return list.toOwnedSlice(alloc);
}

/// Resolve an in-file `GroupLink` (positive `grpid`, no `location`) to the grouping-table `*Hdu`,
/// or `null` for an inter-file or out-of-range link (forces a full scan).
pub fn resolveGroupLink(fits: *Fits, link: GroupLink) GroupError!?*Hdu {
    if (link.location != null) return null;
    if (link.grpid < 1) return null;
    _ = try fits.hduCount();
    const p: u64 = @intCast(link.grpid);
    if (p > fits.hdus.items.len) return null;
    return fits.hdus.items[@intCast(p - 1)];
}

// ── free helpers ──────────────────────────────────────────────────────────────────────────────

fn findCol(table: *const BinTable, name: []const u8) ?u16 {
    return table.resolve(.{ .name = name }) catch null;
}

fn hduIndex(fits: *Fits, hdu: *const Hdu) ?usize {
    for (fits.hdus.items, 0..) |h, i| {
        if (h == hdu) return i;
    }
    return null;
}

// Match a member by EXTNAME (case-insensitive, blank-trimmed) and EXTVER (default 1).
fn matchByNameVer(fits: *Fits, name: []const u8, ver: i64) ?*Hdu {
    for (fits.hdus.items) |h| {
        var buf: [80]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const en = h.header.getString(fba.allocator(), "EXTNAME") catch continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, en, " "), name)) continue;
        const v = h.header.getValue(i64, "EXTVER") catch 1;
        if (v == ver) return h;
    }
    return null;
}

// Smallest n ≥ 1 such that GRPIDn is absent from the header.
fn nextGrpidIndex(header: *const Header) GroupError!usize {
    var kw: [16]u8 = undefined;
    var n: usize = 1;
    while (n <= 999) : (n += 1) {
        if (!header.has(grpidName(&kw, n))) return n;
    }
    return error.LimitExceeded;
}

fn grpidName(buf: []u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "GRPID{d}", .{n}) catch unreachable;
}

fn grplcName(buf: []u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "GRPLC{d}", .{n}) catch unreachable;
}

fn buildGroupingHeader(alloc: Allocator, name: ?[]const u8) GroupError!Header {
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);

    var rowbytes: u64 = 0;
    for (GROUP_COLS) |c| rowbytes += try (try BinTform.parse(c.tform)).fieldBytes();

    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, "grouping table");
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = @intCast(rowbytes) }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = 0 }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = @intCast(GROUP_COLS.len) }, null);
    var buf: [16]u8 = undefined;
    for (GROUP_COLS, 0..) |c, i| {
        const k = i + 1;
        try h.appendValue(alloc, std.fmt.bufPrint(&buf, "TFORM{d}", .{k}) catch unreachable, .{ .string = c.tform }, null);
        try h.appendValue(alloc, std.fmt.bufPrint(&buf, "TTYPE{d}", .{k}) catch unreachable, .{ .string = c.name }, null);
    }
    try h.appendValue(alloc, "EXTNAME", .{ .string = "GROUPING" }, null);
    if (name) |nm| try h.appendValue(alloc, "GRPNAME", .{ .string = nm }, null);
    try h.ensureEnd(alloc);
    return h;
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("io/memory.zig").MemoryDevice;
const hdu_mod = @import("hdu.zig");

const Built = struct {
    f: Fits,
    mem: *MemoryDevice,
    fn deinit(self: *Built, alloc: Allocator) void {
        self.f.deinit();
        self.mem.deinit();
        alloc.destroy(self.mem);
    }
};

fn newHandle(alloc: Allocator) !Built {
    const mem = try alloc.create(MemoryDevice);
    mem.* = MemoryDevice.init(alloc);
    const f = try Fits.create(alloc, mem.device(), .{});
    return .{ .f = f, .mem = mem };
}

test "addMember adds a row + GRPIDn and resolves to the right HDUs; removeMember reverses it" {
    const alloc = testing.allocator;
    var b = try newHandle(alloc);
    defer b.deinit(alloc);
    const f = &b.f;

    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // HDU1 primary
    const h2 = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } }); // HDU2
    const h3 = try f.appendImageHdu(.{ .bitpix = 32, .axes = &.{ 2, 2 } }); // HDU3

    var grp = try GroupTable.create(f, "MYGROUP"); // HDU4
    defer grp.deinit(alloc);
    try testing.expectEqual(@as(u64, 0), grp.memberCount());
    try testing.expectEqual(@as(usize, 4), try grp.position());

    const r2 = try grp.addMember(h2);
    const r3 = try grp.addMember(h3);
    try testing.expectEqual(@as(u64, 0), r2);
    try testing.expectEqual(@as(u64, 1), r3);
    try testing.expectEqual(@as(u64, 2), grp.memberCount());

    // Membership resolves to the right HDUs.
    try testing.expectEqual(@as(?*Hdu, h2), try grp.resolveMember(0));
    try testing.expectEqual(@as(?*Hdu, h3), try grp.resolveMember(1));

    // The MEMBER_POSITION cells were written.
    try testing.expectEqual(@as(?i64, 2), try grp.memberPosition(0));
    try testing.expectEqual(@as(?i64, 3), try grp.memberPosition(1));

    // The member HDUs gained a GRPID1 = 4 (the grouping table's position).
    try testing.expectEqual(@as(i64, 4), try h2.header.getValue(i64, "GRPID1"));
    try testing.expectEqual(@as(i64, 4), try h3.header.getValue(i64, "GRPID1"));

    // members() lists both, in order.
    const ms = try grp.members(alloc);
    defer alloc.free(ms);
    try testing.expectEqual(@as(usize, 2), ms.len);
    try testing.expectEqual(h2, ms[0]);
    try testing.expectEqual(h3, ms[1]);

    // groupsOf reads the member-side linkage and resolves back to the grouping table.
    const links = try groupsOf(alloc, h2);
    defer freeGroupLinks(alloc, links);
    try testing.expectEqual(@as(usize, 1), links.len);
    try testing.expectEqual(@as(i64, 4), links[0].grpid);
    try testing.expectEqual(@as(?*Hdu, grp.table.hdu), try resolveGroupLink(f, links[0]));

    // removeMember reverses: row dropped, GRPID removed, re-resolution updated.
    try testing.expect(try grp.removeMember(h2));
    try testing.expectEqual(@as(u64, 1), grp.memberCount());
    try testing.expectEqual(@as(?*Hdu, h3), try grp.resolveMember(0));
    try testing.expect(!h2.header.has("GRPID1"));

    const links2 = try groupsOf(alloc, h2);
    defer freeGroupLinks(alloc, links2);
    try testing.expectEqual(@as(usize, 0), links2.len);
}

test "GroupTable round-trips through a fresh open (read-side resolution by position)" {
    const alloc = testing.allocator;
    var b = try newHandle(alloc);
    defer b.deinit(alloc);
    {
        const f = &b.f;
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
        const h2 = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } });
        const h3 = try f.appendImageHdu(.{ .bitpix = 32, .axes = &.{2} });
        var grp = try GroupTable.create(f, "G");
        defer grp.deinit(alloc);
        _ = try grp.addMember(h2);
        _ = try grp.addMember(h3);
        try f.flush();
    }

    // Re-open and re-resolve membership from the on-disk bytes.
    var f2 = try Fits.open(alloc, b.mem.device(), .read_only, .{});
    defer f2.deinit();
    try testing.expectEqual(@as(usize, 4), try f2.hduCount());
    const ghdu = try f2.select(4);
    var grp2 = try GroupTable.of(&f2, ghdu);
    defer grp2.deinit(alloc);

    try testing.expectEqual(@as(u64, 2), grp2.memberCount());
    const name = try grp2.groupName(alloc);
    defer if (name) |s| alloc.free(s);
    try testing.expectEqualStrings("G", name.?);

    const m0 = (try grp2.resolveMember(0)).?;
    const m1 = (try grp2.resolveMember(1)).?;
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, m0.axes);
    try testing.expectEqualSlices(u64, &.{2}, m1.axes);

    // MEMBER_NAME/XTENSION were recorded (XTENSION='IMAGE'; EXTNAME absent ⇒ blank name).
    const nm = try grp2.memberName(alloc, 0);
    defer if (nm) |s| alloc.free(s);
    try testing.expectEqual(@as(?[]u8, null), nm);
}

test "resolveMember falls back to EXTNAME/EXTVER when MEMBER_POSITION is invalid" {
    const alloc = testing.allocator;
    var b = try newHandle(alloc);
    defer b.deinit(alloc);
    const f = &b.f;

    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    const h2 = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{3} });
    // Give the member an EXTNAME/EXTVER so name-based resolution can find it.
    try h2.header.update(f.alloc, "EXTNAME", .{ .string = "IMG" }, null);
    try h2.header.update(f.alloc, "EXTVER", .{ .int = 7 }, null);
    try f.rewriteHeaderInPlace(h2);

    var grp = try GroupTable.create(f, null);
    defer grp.deinit(alloc);
    try grp.table.appendRows(1);
    // Write a row with an *invalid* position (0) but a matching name/version.
    try grp.writeIntCell(grp.col_position.?, 0, 0);
    try grp.writeStrCell(grp.col_name.?, 0, "img"); // case-insensitive match
    try grp.writeIntCell(grp.col_version.?, 0, 7);

    try testing.expectEqual(@as(?*Hdu, h2), try grp.resolveMember(0));

    // A version mismatch fails to resolve.
    try grp.writeIntCell(grp.col_version.?, 0, 9);
    try testing.expectEqual(@as(?*Hdu, null), try grp.resolveMember(0));
}

test "of rejects a non-grouping binary table and a non-table HDU" {
    const alloc = testing.allocator;
    var b = try newHandle(alloc);
    defer b.deinit(alloc);
    const f = &b.f;
    const prim = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    try testing.expectError(error.WrongHduType, GroupTable.of(f, prim));
}

test "resolveMember returns null for a non-blank MEMBER_LOCATION (inter-file) row" {
    const alloc = testing.allocator;
    var b = try newHandle(alloc);
    defer b.deinit(alloc);
    const f = &b.f;

    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // HDU1 primary
    _ = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{3} }); // HDU2 (a valid local target)

    var grp = try GroupTable.create(f, null); // HDU3
    defer grp.deinit(alloc);
    try grp.table.appendRows(1);
    // A *valid* local position (2) that would otherwise resolve, but a non-blank MEMBER_LOCATION
    // marks this as an inter-file member ⇒ must resolve to null.
    try grp.writeIntCell(grp.col_position.?, 0, 2);
    try grp.writeStrCell(grp.col_location.?, 0, "file://elsewhere.fits");
    try testing.expectEqual(@as(?*Hdu, null), try grp.resolveMember(0));

    // Clearing MEMBER_LOCATION re-enables local resolution by position.
    try grp.writeStrCell(grp.col_location.?, 0, "");
    try testing.expectEqual(@as(?*Hdu, f.hdus.items[1]), try grp.resolveMember(0));
}

test "resolveMember inspects a MEMBER_LOCATION wider than the stack buffer (no mis-resolve)" {
    const alloc = testing.allocator;
    var b = try newHandle(alloc);
    defer b.deinit(alloc);
    const f = &b.f;

    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // HDU1 primary
    _ = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{3} }); // HDU2 (a valid local target)

    // A grouping BINTABLE whose MEMBER_LOCATION column is 300A — wider than the 256-byte stack
    // buffer the guard used to use (anything wider was skipped → silently mis-resolved locally).
    var h = Header.initEmpty();
    {
        errdefer h.deinit(alloc);
        try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
        try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
        try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
        try h.appendValue(alloc, "NAXIS1", .{ .int = 304 }, null); // 1J (4) + 300A
        try h.appendValue(alloc, "NAXIS2", .{ .int = 0 }, null);
        try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
        try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
        try h.appendValue(alloc, "TFIELDS", .{ .int = 2 }, null);
        try h.appendValue(alloc, "TFORM1", .{ .string = "1J" }, null);
        try h.appendValue(alloc, "TTYPE1", .{ .string = "MEMBER_POSITION" }, null);
        try h.appendValue(alloc, "TFORM2", .{ .string = "300A" }, null);
        try h.appendValue(alloc, "TTYPE2", .{ .string = "MEMBER_LOCATION" }, null);
    }
    const hdu = try f.appendHdu(h);
    var grp = try GroupTable.of(f, hdu);
    defer grp.deinit(alloc);
    try grp.table.appendRows(1);

    // Valid local position (2) but a non-blank 300-wide MEMBER_LOCATION ⇒ inter-file ⇒ null.
    try grp.writeIntCell(grp.col_position.?, 0, 2);
    try grp.writeStrCell(grp.col_location.?, 0, "file://somewhere/very/long/path/to/another/elsewhere.fits");
    try testing.expectEqual(@as(?*Hdu, null), try grp.resolveMember(0));

    // Clearing it re-enables local resolution by position.
    try grp.writeStrCell(grp.col_location.?, 0, "");
    try testing.expectEqual(@as(?*Hdu, f.hdus.items[1]), try grp.resolveMember(0));
}

test "removeMember drops GRPID2 even after the lower GRPID1 was already removed" {
    const alloc = testing.allocator;
    var b = try newHandle(alloc);
    defer b.deinit(alloc);
    const f = &b.f;

    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // HDU1 primary
    const h2 = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{3} }); // HDU2 member

    var grpA = try GroupTable.create(f, "A"); // HDU3
    defer grpA.deinit(alloc);
    var grpB = try GroupTable.create(f, "B"); // HDU4
    defer grpB.deinit(alloc);

    _ = try grpA.addMember(h2); // GRPID1 = 3
    _ = try grpB.addMember(h2); // GRPID2 = 4
    try testing.expectEqual(@as(i64, 3), try h2.header.getValue(i64, "GRPID1"));
    try testing.expectEqual(@as(i64, 4), try h2.header.getValue(i64, "GRPID2"));

    // Remove from the lower-GRPIDn group first: drops GRPID1, leaving a gap at n==1.
    try testing.expect(try grpA.removeMember(h2));
    try testing.expect(!h2.header.has("GRPID1"));
    try testing.expect(h2.header.has("GRPID2"));

    // Removing from the second group must still scan past the gap and drop GRPID2.
    try testing.expect(try grpB.removeMember(h2));
    try testing.expect(!h2.header.has("GRPID2"));
}

test "addMember/removeMember are rejected on a read-only handle" {
    const alloc = testing.allocator;
    var b = try newHandle(alloc);
    {
        const f = &b.f;
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{2} });
        var grp = try GroupTable.create(f, null);
        grp.deinit(alloc);
        try f.flush();
    }
    b.f.deinit(); // close the writable handle, keep the device
    defer {
        b.mem.deinit();
        alloc.destroy(b.mem);
    }

    var f2 = try Fits.open(alloc, b.mem.device(), .read_only, .{});
    defer f2.deinit();
    const h2 = try f2.select(2);
    const ghdu = try f2.select(3);
    var grp2 = try GroupTable.of(&f2, ghdu);
    defer grp2.deinit(alloc);
    try testing.expectError(error.NotWritable, grp2.addMember(h2));
    try testing.expectError(error.NotWritable, grp2.removeMember(h2));
}
