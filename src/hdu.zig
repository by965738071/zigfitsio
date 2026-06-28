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
        return header_blocks + block.roundUpBlocks(self.data_bytes);
    }

    /// Byte offset of the HDU following this one.
    pub fn nextOff(self: *const Hdu) u64 {
        return self.data_off + block.roundUpBlocks(self.data_bytes);
    }

    /// Bytes per pixel/element, `|BITPIX|/8`.
    pub fn elemBytes(self: *const Hdu) u64 {
        const abs: u64 = @intCast(if (self.bitpix < 0) -self.bitpix else self.bitpix);
        return abs / 8;
    }

    fn computeGeometry(self: *Hdu, alloc: Allocator, lim: Limits) (StructError || errors.ConvError || errors.ValueError || errors.HeaderError || errors.LimitError || Allocator.Error)!void {
        self.bitpix = self.header.getValue(i64, "BITPIX") catch return error.MissingRequiredKeyword;
        if (!validBitpix(self.bitpix)) return error.BadBitpix;

        const naxis = self.header.getValue(i64, "NAXIS") catch return error.MissingRequiredKeyword;
        if (naxis < 0 or naxis > 999) return error.BadNaxis;
        self.naxis = @intCast(naxis);

        // Extensions and random groups carry PCOUNT/GCOUNT; primaries default to 0/1.
        self.pcount = self.header.getValue(u64, "PCOUNT") catch 0;
        self.gcount = self.header.getValue(u64, "GCOUNT") catch 1;
        if (self.gcount == 0) return error.BadDimensions;

        self.axes = try alloc.alloc(u64, self.naxis);
        errdefer alloc.free(self.axes);
        var name_buf: [8]u8 = undefined;
        for (0..self.naxis) |i| {
            const kw = std.fmt.bufPrint(&name_buf, "NAXIS{d}", .{i + 1}) catch unreachable;
            const len = self.header.getValue(i64, kw) catch return error.MissingRequiredKeyword;
            if (len < 0) return error.BadDimensions;
            self.axes[i] = @intCast(len);
        }

        self.data_bytes = try self.dataByteCount(lim);
    }

    // The data-unit byte count per FITS 4.0 §4.4.1.1:
    //   Nbytes = |BITPIX|/8 × GCOUNT × (PCOUNT + Π NAXISn)
    // with NAXIS=0 ⇒ no data, and random groups (NAXIS1=0) taking the product over axes 2..n.
    fn dataByteCount(self: *const Hdu, lim: Limits) errors.LimitError!u64 {
        if (self.naxis == 0) return 0;
        const start: usize = if (self.kind == .random_groups) 1 else 0;
        const product = try limits.naxisProduct(self.axes[start..], lim.max_naxis_product);
        const inner = try limits.add(self.pcount, product);
        const groups = try limits.mul(self.gcount, inner);
        return limits.mul(self.elemBytes(), groups);
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

/// Validate mandatory-keyword presence, the first keyword, and basic types for `kind`
/// (FR-HDU-5). `EXTEND` is advisory and never checked (FR-HDU-6).
pub fn validate(header: *const Header, kind: HduKind) StructError!void {
    if (header.count() == 0) return error.MissingRequiredKeyword;
    const first = header.at(0);

    switch (kind) {
        .primary, .random_groups => {
            if (!first.name.eqlText("SIMPLE")) return error.KeywordOrder;
        },
        .image, .ascii_table, .binary_table => {
            if (!first.name.eqlText("XTENSION")) return error.KeywordOrder;
        },
    }

    // BITPIX and NAXIS must be present (their values are validated in computeGeometry).
    if (!header.has("BITPIX")) return error.MissingRequiredKeyword;
    if (!header.has("NAXIS")) return error.MissingRequiredKeyword;

    // Tables additionally require TFIELDS, PCOUNT, GCOUNT.
    if (kind == .ascii_table or kind == .binary_table) {
        if (!header.has("TFIELDS")) return error.MissingRequiredKeyword;
        if (!header.has("PCOUNT")) return error.MissingRequiredKeyword;
        if (!header.has("GCOUNT")) return error.MissingRequiredKeyword;
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
