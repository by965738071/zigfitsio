//! HDU model: kind detection, mandatory-keyword validation, and data geometry
//! (FR-HDU-1/2/5/6, §10.1, §10.2; FITS 4.0 §3.3, §4.4.1, §7).
//!
//! An `Hdu` is a header plus the location and size of its data unit. Kind detection follows
//! §3.3: HDU 1 with `SIMPLE=T` is `primary` (or `random_groups` when `NAXIS1=0` and
//! `GROUPS=T`); extensions dispatch on `XTENSION`. Validation enforces mandatory-keyword
//! presence/order/type when an HDU is finalized; per FR-HDU-6 a missing or non-adjacent
//! `EXTEND` is **never** flagged (it is advisory).
const std = @import("std");
const errors = @import("errors.zig");
const StructError = errors.StructError;
const Header = @import("header/header.zig").Header;
const block = @import("io/block.zig");
const limits = @import("limits.zig");
const Limits = limits.Limits;

const Allocator = std.mem.Allocator;

/// The kind of an HDU (§10.1).
pub const HduKind = enum {
    primary,
    image,
    ascii_table,
    binary_table,
    random_groups,

    /// Whether this kind carries an image-like data array (primary, IMAGE, random groups).
    pub fn isImageLike(self: HduKind) bool {
        return self == .primary or self == .image or self == .random_groups;
    }
};

/// One Header/Data Unit: its parsed header plus the byte location and size of its data unit.
/// `*Hdu` values are individually allocated by the file handle, so a view holding one stays
/// valid as the HDU list grows (§10.3).
pub const Hdu = struct {
    kind: HduKind,
    header: Header,
    /// Byte offset of this HDU's first header card.
    header_off: u64,
    /// Byte offset of the data unit (first byte after the padded header).
    data_off: u64,
    /// Logical data length in bytes (pre-padding; checksums use the padded length, §16).
    data_bytes: u64,
    /// `BITPIX` (0 if not applicable).
    bitpix: i64,
    /// `NAXIS` (0–999).
    naxis: u16,
    /// Per-axis lengths `NAXISn` (owned; length == `naxis`).
    axes: []u64,
    /// `PCOUNT` (heap/parameter count; 0 for a plain image).
    pcount: u64,
    /// `GCOUNT` (group count; 1 for a plain image).
    gcount: u64,

    /// Build an `Hdu` from an already-parsed `header` located at `header_off`, where the
    /// header occupied `cards_consumed` cards. Detects the kind, validates mandatory keywords,
    /// computes the data geometry (validated against `lim`), and derives `data_off`. Takes
    /// ownership of `header` (frees it on `deinit`).
    pub fn init(
        alloc: Allocator,
        header: Header,
        is_primary: bool,
        header_off: u64,
        cards_consumed: u64,
        lim: Limits,
    ) (StructError || errors.ConvError || errors.ValueError || errors.HeaderError || errors.LimitError || Allocator.Error)!Hdu {
        var self: Hdu = .{
            .kind = undefined,
            .header = header,
            .header_off = header_off,
            .data_off = 0,
            .data_bytes = 0,
            .bitpix = 0,
            .naxis = 0,
            .axes = &.{},
            .pcount = 0,
            .gcount = 1,
        };
        errdefer self.header.deinit(alloc);

        self.kind = try detectKind(&self.header, is_primary);
        try validate(&self.header, self.kind);
        try self.computeGeometry(alloc, lim);

        const header_blocks = block.roundUpBlocks(cards_consumed * block.CARD);
        self.data_off = try limits.add(header_off, header_blocks);
        return self;
    }

    pub fn deinit(self: *Hdu, alloc: Allocator) void {
        alloc.free(self.axes);
        self.header.deinit(alloc);
    }

    /// Total bytes occupied by this HDU on disk (padded header + padded data).
    pub fn totalBytes(self: *const Hdu) u64 {
        const header_blocks = block.roundUpBlocks(@as(u64, self.header.count()) * block.CARD);
        // Saturating: a malformed GCOUNT/PCOUNT can make data_bytes ≈ 2^64, so the sum must not
        // integer-overflow panic. A saturated total is harmless — it only feeds size comparisons.
        return header_blocks +| block.roundUpBlocks(self.data_bytes);
    }

    /// Byte offset of the HDU following this one.
    pub fn nextOff(self: *const Hdu) u64 {
        // Saturating add: roundUpBlocks already saturates, and data_off + (saturated) would
        // otherwise overflow u64 and panic during the scan. A saturated offset lands past EOF,
        // so scanning simply stops (the declared data unit is unreadable), never panics.
        return self.data_off +| block.roundUpBlocks(self.data_bytes);
    }

    /// Bytes per pixel/element, `|BITPIX|/8`.
    pub fn elemBytes(self: *const Hdu) u64 {
        const abs: u64 = @intCast(if (self.bitpix < 0) -self.bitpix else self.bitpix);
        return abs / 8;
    }

    /// Recompute `bitpix`/`naxis`/`axes`/`pcount`/`gcount`/`data_bytes` from the HDU's CURRENT
    /// header — used after structural keywords (`BITPIX`/`NAXIS`/`NAXISn`/`PCOUNT`/`GCOUNT`) were
    /// mutated in place — WITHOUT touching the kind or any byte offset (§4.4.1.1).
    ///
    /// Atomic: the new geometry is computed into locals and committed only once every field
    /// validates, so on ANY failure (bad BITPIX, missing NAXISn, over-limit product, …) the HDU is
    /// left exactly as it was. This preserves the `naxis == axes.len` invariant every image path
    /// relies on — a torn `naxis>0, axes.len==0` state (the old behavior) OOB-indexed the empty
    /// `axes` slice in `ImageView.section()`.
    pub fn recomputeGeometry(self: *Hdu, alloc: Allocator, lim: Limits) (StructError || errors.ConvError || errors.ValueError || errors.HeaderError || errors.LimitError || Allocator.Error)!void {
        const old_axes = self.axes;
        try self.computeGeometry(alloc, lim); // commits `self.*` only on success; `self` untouched on error
        alloc.free(old_axes); // the new geometry is committed — release the previous axes allocation
    }

    // Compute the full geometry into locals and commit to `self` only once every field validates.
    // `self.axes` is replaced with a freshly-allocated slice; the caller owns freeing any prior
    // allocation AFTER a successful return (`init` starts from an empty slice, `recomputeGeometry`
    // frees the old one). On error `self` is left untouched and the newly-built axes are freed.
    fn computeGeometry(self: *Hdu, alloc: Allocator, lim: Limits) (StructError || errors.ConvError || errors.ValueError || errors.HeaderError || errors.LimitError || Allocator.Error)!void {
        const bitpix = self.header.getValue(i64, "BITPIX") catch return error.MissingRequiredKeyword;
        if (!validBitpix(bitpix)) return error.BadBitpix;

        const naxis_i = self.header.getValue(i64, "NAXIS") catch return error.MissingRequiredKeyword;
        if (naxis_i < 0 or naxis_i > 999) return error.BadNaxis;
        const naxis: u16 = @intCast(naxis_i);

        // Extensions and random groups carry PCOUNT/GCOUNT; primaries default to 0/1.
        const pcount = self.header.getValue(u64, "PCOUNT") catch 0;
        const gcount = self.header.getValue(u64, "GCOUNT") catch 1;
        if (gcount == 0) return error.BadDimensions;

        const axes = try alloc.alloc(u64, naxis);
        errdefer alloc.free(axes);
        var name_buf: [8]u8 = undefined;
        for (0..naxis) |i| {
            const kw = std.fmt.bufPrint(&name_buf, "NAXIS{d}", .{i + 1}) catch unreachable;
            const len = self.header.getValue(i64, kw) catch return error.MissingRequiredKeyword;
            if (len < 0) return error.BadDimensions;
            axes[i] = @intCast(len);
        }

        const data_bytes = try dataByteCountFrom(bitpix, naxis, self.kind, axes, pcount, gcount, lim);

        // Commit — no failure points remain past here.
        self.bitpix = bitpix;
        self.naxis = naxis;
        self.pcount = pcount;
        self.gcount = gcount;
        self.axes = axes;
        self.data_bytes = data_bytes;
    }

    // The data-unit byte count per FITS 4.0 §4.4.1.1:
    //   Nbytes = |BITPIX|/8 × GCOUNT × (PCOUNT + Π NAXISn)
    // with NAXIS=0 ⇒ no data, and random groups (NAXIS1=0) taking the product over axes 2..n.
    // Takes explicit geometry values so it can run on locals before the HDU is mutated (atomicity).
    fn dataByteCountFrom(bitpix: i64, naxis: u16, kind: HduKind, axes: []const u64, pcount: u64, gcount: u64, lim: Limits) errors.LimitError!u64 {
        if (naxis == 0) return 0;
        const start: usize = if (kind == .random_groups) 1 else 0;
        const product = try limits.naxisProduct(axes[start..], lim.max_naxis_product);
        const inner = try limits.add(pcount, product);
        const groups = try limits.mul(gcount, inner);
        const elem_bytes: u64 = @as(u64, @intCast(if (bitpix < 0) -bitpix else bitpix)) / 8;
        const total = try limits.mul(elem_bytes, groups);
        // Bound the data unit so both it and its block-rounded size stay within i64: every
        // downstream offset/size computation (nextOff, resizeHduData, deleteHdu, …) casts block
        // counts to i64, so an absurd GCOUNT/PCOUNT that drives data_bytes toward 2^64 would later
        // overflow those casts. A real data unit is astronomically smaller — reject the rest with
        // a typed error here (NFR-SAFE-1) rather than admitting a value that panics on use.
        if (total > std.math.maxInt(i64) - block.BLOCK) return error.LimitExceeded;
        return total;
    }
};

fn validBitpix(b: i64) bool {
    return switch (b) {
        8, 16, 32, 64, -32, -64 => true,
        else => false,
    };
}

/// Detect the kind of an HDU from its header (§3.3). `is_primary` is true for HDU 1.
pub fn detectKind(header: *const Header, is_primary: bool) StructError!HduKind {
    if (is_primary) {
        if (!header.has("SIMPLE")) return error.MissingRequiredKeyword;
        const groups = header.getValue(bool, "GROUPS") catch false;
        const naxis = header.getValue(i64, "NAXIS") catch 0;
        if (groups and naxis >= 1) {
            const n1 = header.getValue(i64, "NAXIS1") catch -1;
            if (n1 == 0) return .random_groups;
        }
        return .primary;
    }
    // Extension: dispatch on XTENSION.
    var buf: [80]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const xt = header.getString(fba.allocator(), "XTENSION") catch return error.MissingRequiredKeyword;
    if (std.mem.eql(u8, xt, "IMAGE")) return .image;
    if (std.mem.eql(u8, xt, "TABLE")) return .ascii_table;
    if (std.mem.eql(u8, xt, "BINTABLE")) return .binary_table;
    return error.BadExtension;
}

/// Validate mandatory-keyword presence AND positional order for `kind` (FR-HDU-5 MUST;
/// FITS 4.0 §4.4.1.1, §7.2.1/§7.3.1). The leading keyword (`SIMPLE`/`XTENSION`) must be first,
/// `BITPIX` second, `NAXIS` third, and `NAXIS1..NAXISn` must immediately follow `NAXIS` in
/// order. For ASCII/binary tables `PCOUNT`, `GCOUNT`, `TFIELDS` must immediately follow
/// `NAXISn` (in that order). Random-groups HDUs interpose a `GROUPS` card before the count
/// keywords, so only the *presence* of `PCOUNT`/`GCOUNT` is required there, not their position.
/// `EXTEND` is advisory and never checked (FR-HDU-6); keyword values are validated in
/// `computeGeometry`.
pub fn validate(header: *const Header, kind: HduKind) StructError!void {
    const cnt = header.count();
    if (cnt == 0) return error.MissingRequiredKeyword;
    const first = header.at(0);

    switch (kind) {
        .primary, .random_groups => {
            if (!first.name.eqlText("SIMPLE")) return error.KeywordOrder;
        },
        .image, .ascii_table, .binary_table => {
            if (!first.name.eqlText("XTENSION")) return error.KeywordOrder;
        },
    }

    // BITPIX and NAXIS must be present (their values are validated in computeGeometry) AND in
    // their mandated positions: BITPIX is card[1], NAXIS is card[2].
    if (!header.has("BITPIX")) return error.MissingRequiredKeyword;
    if (!header.has("NAXIS")) return error.MissingRequiredKeyword;
    if (cnt < 2 or !header.at(1).name.eqlText("BITPIX")) return error.KeywordOrder;
    if (cnt < 3 or !header.at(2).name.eqlText("NAXIS")) return error.KeywordOrder;

    // NAXIS1..NAXISn must be the contiguous block immediately after NAXIS. A malformed NAXIS
    // value is left for computeGeometry (BadNaxis); we only enforce order for a legal count.
    const naxis = header.getValue(i64, "NAXIS") catch return error.MissingRequiredKeyword;
    if (naxis < 0 or naxis > 999) return; // computeGeometry reports BadNaxis
    const n: u16 = @intCast(naxis);
    var name_buf: [16]u8 = undefined;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const kw = std.fmt.bufPrint(&name_buf, "NAXIS{d}", .{i + 1}) catch unreachable;
        const idx = 3 + @as(usize, i);
        if (cnt <= idx or !header.at(idx).name.eqlText(kw)) return error.KeywordOrder;
    }

    // The card index immediately past NAXISn (where the count keywords belong).
    const after = 3 + @as(usize, n);
    switch (kind) {
        .ascii_table, .binary_table => {
            // §7.2.1/§7.3.1: PCOUNT, GCOUNT, TFIELDS in that order, immediately after NAXISn.
            if (!header.has("TFIELDS")) return error.MissingRequiredKeyword;
            if (!header.has("PCOUNT")) return error.MissingRequiredKeyword;
            if (!header.has("GCOUNT")) return error.MissingRequiredKeyword;
            if (cnt <= after or !header.at(after).name.eqlText("PCOUNT")) return error.KeywordOrder;
            if (cnt <= after + 1 or !header.at(after + 1).name.eqlText("GCOUNT")) return error.KeywordOrder;
            if (cnt <= after + 2 or !header.at(after + 2).name.eqlText("TFIELDS")) return error.KeywordOrder;
        },
        .random_groups => {
            // Random groups MUST carry PCOUNT and GCOUNT (§10.2.1), but a GROUPS card legally
            // sits between NAXISn and them, so only presence is enforced here.
            if (!header.has("PCOUNT")) return error.MissingRequiredKeyword;
            if (!header.has("GCOUNT")) return error.MissingRequiredKeyword;
        },
        .primary, .image => {},
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("io/memory.zig").MemoryDevice;

fn parseHeader(alloc: Allocator, cards: []const []const u8) !struct { h: Header, consumed: u64, mem: *MemoryDevice, reader: *block.BlockReader } {
    const mem = try alloc.create(MemoryDevice);
    var buf: [block.BLOCK]u8 = [_]u8{' '} ** block.BLOCK;
    for (cards, 0..) |c, i| @memcpy(buf[i * 80 ..][0..c.len], c);
    @memcpy(buf[cards.len * 80 ..][0..3], "END");
    mem.* = try MemoryDevice.initBytes(alloc, &buf);
    const reader = try alloc.create(block.BlockReader);
    reader.* = try block.BlockReader.init(alloc, mem.device(), 0);
    const res = try Header.parse(alloc, reader, 0, 36);
    return .{ .h = res.header, .consumed = res.cards_consumed, .mem = mem, .reader = reader };
}

test "primary image: kind, geometry, data size, next offset" {
    const p = try parseHeader(testing.allocator, &.{
        "SIMPLE  =                    T",
        "BITPIX  =                  -32",
        "NAXIS   =                    2",
        "NAXIS1  =                  256",
        "NAXIS2  =                  512",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var hdu = try Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{});
    defer hdu.deinit(testing.allocator);

    try testing.expectEqual(HduKind.primary, hdu.kind);
    try testing.expectEqual(@as(i64, -32), hdu.bitpix);
    try testing.expectEqual(@as(u16, 2), hdu.naxis);
    try testing.expectEqualSlices(u64, &.{ 256, 512 }, hdu.axes);
    try testing.expectEqual(@as(u64, 4 * 256 * 512), hdu.data_bytes); // f32 → 4 bytes
    try testing.expectEqual(@as(u64, block.BLOCK), hdu.data_off); // 1 header block
    // next HDU = header(1 block) + data(ceil(524288/2880)=183 blocks)
    try testing.expectEqual(block.BLOCK + block.roundUpBlocks(4 * 256 * 512), hdu.nextOff());
}

test "NAXIS=0 primary has no data" {
    const p = try parseHeader(testing.allocator, &.{
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var hdu = try Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{});
    defer hdu.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), hdu.data_bytes);
}

test "binary table extension geometry includes PCOUNT heap" {
    const p = try parseHeader(testing.allocator, &.{
        "XTENSION= 'BINTABLE'",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                   20",
        "NAXIS2  =                  100",
        "PCOUNT  =                  400",
        "GCOUNT  =                    1",
        "TFIELDS =                    3",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var hdu = try Hdu.init(testing.allocator, p.h, false, 0, p.consumed, .{});
    defer hdu.deinit(testing.allocator);
    try testing.expectEqual(HduKind.binary_table, hdu.kind);
    try testing.expectEqual(@as(u64, 20 * 100 + 400), hdu.data_bytes); // rows + heap
}

test "validation: bad first keyword and bad BITPIX" {
    {
        const p = try parseHeader(testing.allocator, &.{
            "BITPIX  =                    8", // SIMPLE not first
            "SIMPLE  =                    T",
            "NAXIS   =                    0",
        });
        defer {
            p.reader.deinit();
            testing.allocator.destroy(p.reader);
            p.mem.deinit();
            testing.allocator.destroy(p.mem);
        }
        try testing.expectError(error.KeywordOrder, Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{}));
    }
    {
        const p = try parseHeader(testing.allocator, &.{
            "SIMPLE  =                    T",
            "BITPIX  =                    7", // invalid
            "NAXIS   =                    0",
        });
        defer {
            p.reader.deinit();
            testing.allocator.destroy(p.reader);
            p.mem.deinit();
            testing.allocator.destroy(p.mem);
        }
        try testing.expectError(error.BadBitpix, Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{}));
    }
}

test "recomputeGeometry refreshes axes and data_bytes after a NAXISn edit" {
    const p = try parseHeader(testing.allocator, &.{
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                    4",
        "NAXIS2  =                    3",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var hdu = try Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{});
    defer hdu.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 2 * 4 * 3), hdu.data_bytes);

    // Mutate the header in place: bump NAXIS2 and add a third axis.
    try hdu.header.update(testing.allocator, "NAXIS", .{ .int = 3 }, null);
    try hdu.header.update(testing.allocator, "NAXIS2", .{ .int = 5 }, null);
    try hdu.header.update(testing.allocator, "NAXIS3", .{ .int = 2 }, null);

    try hdu.recomputeGeometry(testing.allocator, .{});
    try testing.expectEqual(@as(u16, 3), hdu.naxis);
    try testing.expectEqualSlices(u64, &.{ 4, 5, 2 }, hdu.axes);
    try testing.expectEqual(@as(u64, 2 * 4 * 5 * 2), hdu.data_bytes);
}

test "recomputeGeometry is atomic: a failed recompute leaves the HDU geometry unchanged" {
    const p = try parseHeader(testing.allocator, &.{
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                    4",
        "NAXIS2  =                    3",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var hdu = try Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{});
    defer hdu.deinit(testing.allocator); // must not double-free after the failed recompute

    // Claim a third axis but omit NAXIS3 ⇒ recompute fails partway. The HDU must be left EXACTLY as
    // it was: the old NAXIS/axes/data_bytes survive and `naxis == axes.len` holds. The pre-fix code
    // committed `naxis = 3` before failing yet reset `axes` to empty — a torn state that made
    // `ImageView.section()` index `axes[0..3]` on a zero-length slice (OOB).
    try hdu.header.update(testing.allocator, "NAXIS", .{ .int = 3 }, null);
    try testing.expectError(error.MissingRequiredKeyword, hdu.recomputeGeometry(testing.allocator, .{}));
    try testing.expectEqual(@as(u16, 2), hdu.naxis);
    try testing.expectEqual(@as(usize, hdu.naxis), hdu.axes.len); // invariant preserved
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, hdu.axes);
    try testing.expectEqual(@as(u64, 2 * 4 * 3), hdu.data_bytes);
}

test "validate rejects BITPIX/NAXIS out of position (KeywordOrder)" {
    // SIMPLE present and first, but NAXIS precedes BITPIX → card[1] is not BITPIX.
    const p = try parseHeader(testing.allocator, &.{
        "SIMPLE  =                    T",
        "NAXIS   =                    0",
        "BITPIX  =                    8",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    try testing.expectError(error.KeywordOrder, Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{}));
}

test "validate rejects non-contiguous NAXISn (KeywordOrder)" {
    // A foreign keyword interrupts the NAXIS1..NAXISn run.
    const p = try parseHeader(testing.allocator, &.{
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                    4",
        "OBJECT  = 'M31'",
        "NAXIS2  =                    3",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    try testing.expectError(error.KeywordOrder, Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{}));
}

test "validate rejects table count keywords out of position (KeywordOrder)" {
    // PCOUNT/GCOUNT/TFIELDS must immediately follow NAXIS2; here a TFORM intrudes first.
    const p = try parseHeader(testing.allocator, &.{
        "XTENSION= 'BINTABLE'",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                    4",
        "NAXIS2  =                    1",
        "TFORM1  = '1J'",
        "PCOUNT  =                    0",
        "GCOUNT  =                    1",
        "TFIELDS =                    1",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    try testing.expectError(error.KeywordOrder, Hdu.init(testing.allocator, p.h, false, 0, p.consumed, .{}));
}

test "validate rejects a random-groups header missing PCOUNT/GCOUNT" {
    // GROUPS=T with NAXIS1=0 ⇒ random groups; PCOUNT/GCOUNT are then mandatory.
    const p = try parseHeader(testing.allocator, &.{
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                    0",
        "NAXIS2  =                    5",
        "GROUPS  =                    T",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    try testing.expectError(error.MissingRequiredKeyword, Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{}));
}

test "validate accepts a well-formed random-groups header with PCOUNT/GCOUNT" {
    // GROUPS legally sits between NAXISn and the count keywords; presence (not position) suffices.
    const p = try parseHeader(testing.allocator, &.{
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                    0",
        "NAXIS2  =                    5",
        "GROUPS  =                    T",
        "PCOUNT  =                    0",
        "GCOUNT  =                    3",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var hdu = try Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{});
    defer hdu.deinit(testing.allocator);
    try testing.expectEqual(HduKind.random_groups, hdu.kind);
}

test "oversized NAXIS product is a typed limit error before allocation" {
    const p = try parseHeader(testing.allocator, &.{
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =          4000000000",
        "NAXIS2  =          4000000000",
    });
    defer {
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    try testing.expectError(error.LimitExceeded, Hdu.init(testing.allocator, p.h, true, 0, p.consumed, .{}));
}
