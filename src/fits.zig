//! The `Fits` file handle: open/create, lazy HDU scan, navigation, and the programmatic
//! HDU builder (FR-HDU-1/3/4, FR-IO-5, FR-TPL-2, NFR-MEM-1, NFR-CONC-1; §10.3, §25).
//!
//! All library state lives in this handle (no globals), so distinct handles are usable
//! concurrently from different threads; a **single handle is not thread-safe** (it mutates
//! its block cache, CHDU index, and lazily-grown HDU list). HDUs are scanned lazily and each
//! `*Hdu` is individually allocated, so a view holding one stays valid as the list grows.
const std = @import("std");
const errors = @import("errors.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const Limits = @import("limits.zig").Limits;
const limits = @import("limits.zig");
const Device = @import("io/device.zig").Device;
const FileDevice = @import("io/file.zig").FileDevice;
const file = @import("io/file.zig");
const block = @import("io/block.zig");
const Header = @import("header/header.zig").Header;
const hdu_mod = @import("hdu.zig");
const Hdu = hdu_mod.Hdu;

const Allocator = std.mem.Allocator;

/// The error set produced by file-handle operations (a wide but specific union — not the
/// umbrella `Error`, and never `anyerror`).
pub const FitsError = errors.IoError || errors.HeaderError || errors.StructError ||
    errors.ValueError || errors.ConvError || errors.LimitError || Allocator.Error;

/// How a file is opened.
pub const Mode = enum { read_only, read_write, create };

/// Options for `open`/`create`.
pub const OpenOpts = struct {
    /// Optional diagnostics sink for the most-recent failure (FR-ERR-3).
    diag: ?*Diagnostics = null,
    /// Resource limits (NFR-SAFE-1).
    limits: Limits = .{},
    /// Update `CHECKSUM`/`DATASUM` automatically on `flush`/`deinit` (FR-SUM-3).
    checksum_on_close: bool = false,
};

/// Specification for a programmatically-built image HDU (FR-TPL-2).
pub const ImageSpec = struct {
    /// `BITPIX`: 8, 16, 32, 64, -32, or -64.
    bitpix: i64,
    /// Per-axis lengths (most-rapidly-varying first); `len` is `NAXIS` (0–999).
    axes: []const u64,
};

/// A FITS file handle.
pub const Fits = struct {
    alloc: Allocator,
    dev: Device,
    mode: Mode,
    limits: Limits,
    diag: ?*Diagnostics,
    checksum_on_close: bool,
    /// Lazily-scanned HDUs; each is individually allocated for pointer stability (§10.3).
    hdus: std.ArrayList(*Hdu) = .empty,
    /// Current-HDU index (0-based; renamed from `current` to avoid a field/method collision).
    chdu: usize = 0,
    reader: block.BlockReader,
    /// Byte offset where the next unscanned HDU begins.
    scan_off: u64 = 0,
    fully_scanned: bool = false,
    /// Whether `deinit` closes the device (true when the handle created it, e.g. `openFile`).
    owns_device: bool = false,
    /// Hook registered by the checksum module; invoked by `flush` when `checksum_on_close`.
    checksum_hook: ?*const fn (*Fits) FitsError!void = null,

    /// Open an existing FITS file over `dev`. Parses HDU 1 eagerly; further HDUs are scanned
    /// on demand (§10.3). A read-only device makes write operations `error.NotWritable`.
    pub fn open(alloc: Allocator, dev: Device, mode: Mode, opts: OpenOpts) FitsError!Fits {
        std.debug.assert(mode != .create); // use `create` for new files
        var self = try initHandle(alloc, dev, mode, opts);
        errdefer self.deinitInternal(false);
        _ = try self.scanOne(); // eagerly parse HDU 1
        return self;
    }

    /// Create a new (empty) FITS file over `dev`. Build HDUs with `appendImageHdu` etc.
    pub fn create(alloc: Allocator, dev: Device, opts: OpenOpts) FitsError!Fits {
        var self = try initHandle(alloc, dev, .create, opts);
        self.fully_scanned = true; // nothing to scan yet
        return self;
    }

    /// Open an on-disk file by path (the handle owns and closes the device).
    pub fn openFile(alloc: Allocator, path: []const u8, mode: Mode, opts: OpenOpts) FitsError!Fits {
        const access: file.Access = switch (mode) {
            .read_only => .read_only,
            .read_write => .read_write,
            .create => .create,
        };
        const dev = try FileDevice.openPath(alloc, path, access);
        errdefer dev.close();
        var self = if (mode == .create)
            try create(alloc, dev, opts)
        else
            try open(alloc, dev, mode, opts);
        self.owns_device = true;
        return self;
    }

    /// Create a new on-disk file by path (the handle owns and closes the device).
    pub fn createFile(alloc: Allocator, path: []const u8, opts: OpenOpts) FitsError!Fits {
        return openFile(alloc, path, .create, opts);
    }

    fn initHandle(alloc: Allocator, dev: Device, mode: Mode, opts: OpenOpts) FitsError!Fits {
        const reader = try block.BlockReader.init(alloc, dev, 0);
        return .{
            .alloc = alloc,
            .dev = dev,
            .mode = mode,
            .limits = opts.limits,
            .diag = opts.diag,
            .checksum_on_close = opts.checksum_on_close,
            .reader = reader,
        };
    }

    /// Release all resources. Closes the device if the handle created it.
    pub fn deinit(self: *Fits) void {
        self.deinitInternal(self.owns_device);
    }

    fn deinitInternal(self: *Fits, close_device: bool) void {
        for (self.hdus.items) |h| {
            h.deinit(self.alloc);
            self.alloc.destroy(h);
        }
        self.hdus.deinit(self.alloc);
        self.reader.deinit();
        if (close_device) self.dev.close();
    }

    // ── scanning ─────────────────────────────────────────────────────────────────────────

    // Parse the next unscanned HDU, append it, and advance `scan_off`. Returns null at EOF or
    // when trailing bytes are special records (§3.5) rather than another HDU.
    fn scanOne(self: *Fits) FitsError!?*Hdu {
        if (self.fully_scanned) return null;
        const size = try self.dev.getSize();
        if (self.scan_off >= size or size - self.scan_off < block.BLOCK) {
            self.fully_scanned = true;
            return null;
        }
        const first_card = self.scan_off / block.CARD;
        const max_cards = @as(u64, self.limits.max_header_blocks) * block.CARDS_PER_BLOCK;
        const res = Header.parse(self.alloc, &self.reader, first_card, @intCast(max_cards)) catch |err| {
            // After at least one HDU, a non-header tail is treated as special records, not an error.
            if (self.hdus.items.len > 0) {
                self.fully_scanned = true;
                return null;
            }
            return err;
        };

        const is_primary = self.hdus.items.len == 0;
        const hdu_ptr = self.alloc.create(Hdu) catch |e| {
            var h = res.header;
            h.deinit(self.alloc);
            return e;
        };
        errdefer self.alloc.destroy(hdu_ptr);
        // Hdu.init takes ownership of the header (frees it on its own error).
        hdu_ptr.* = try Hdu.init(self.alloc, res.header, is_primary, self.scan_off, res.cards_consumed, self.limits);
        errdefer hdu_ptr.deinit(self.alloc);
        try self.hdus.append(self.alloc, hdu_ptr);

        self.scan_off = hdu_ptr.nextOff();
        if (self.scan_off >= size) self.fully_scanned = true;
        return hdu_ptr;
    }

    fn ensureScanned(self: *Fits, upto_count: usize) FitsError!void {
        while (self.hdus.items.len < upto_count and !self.fully_scanned) {
            _ = try self.scanOne();
        }
    }

    fn ensureScannedAll(self: *Fits) FitsError!void {
        while (!self.fully_scanned) _ = try self.scanOne();
    }

    // ── navigation ───────────────────────────────────────────────────────────────────────

    /// Total number of HDUs (forces a full scan) (FR-HDU-1).
    pub fn hduCount(self: *Fits) FitsError!usize {
        try self.ensureScannedAll();
        return self.hdus.items.len;
    }

    /// Select HDU `n` (1-based) as the current HDU and return it (FR-HDU-3).
    pub fn select(self: *Fits, n: usize) FitsError!*Hdu {
        if (n == 0) return error.WrongHduType;
        try self.ensureScanned(n);
        if (n > self.hdus.items.len) return error.WrongHduType;
        self.chdu = n - 1;
        return self.hdus.items[self.chdu];
    }

    /// Move the current HDU by `delta` (relative navigation) and return it.
    pub fn move(self: *Fits, delta: isize) FitsError!*Hdu {
        const target = @as(isize, @intCast(self.chdu)) + delta;
        if (target < 0) return error.WrongHduType;
        return self.select(@as(usize, @intCast(target)) + 1);
    }

    /// Select the first extension whose `EXTNAME` matches `extname` (case-insensitive) and,
    /// if `extver` is given, whose `EXTVER` matches (FR-HDU-3).
    pub fn selectByName(self: *Fits, extname: []const u8, extver: ?i64) FitsError!*Hdu {
        try self.ensureScannedAll();
        for (self.hdus.items, 0..) |h, i| {
            var buf: [80]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const name = h.header.getString(fba.allocator(), "EXTNAME") catch continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " "), extname)) continue;
            if (extver) |want| {
                const ver = h.header.getValue(i64, "EXTVER") catch 1;
                if (ver != want) continue;
            }
            self.chdu = i;
            return h;
        }
        return error.WrongHduType;
    }

    /// The current HDU (CHDU). Valid after `open` (HDU 1) or any navigation/append.
    pub fn current(self: *Fits) *Hdu {
        return self.hdus.items[self.chdu];
    }

    // ── mutation / builders (FR-HDU-4, FR-TPL-2) ───────────────────────────────────────────

    /// Append a programmatically-built image HDU (primary if the file is empty, else an
    /// `IMAGE` extension), reserve and zero-fill its data unit, make it current, and return
    /// it. Pixels are written via the image view (`image.zig`). This is the primary, complete
    /// HDU-construction path — no template required (FR-TPL-2).
    pub fn appendImageHdu(self: *Fits, spec: ImageSpec) FitsError!*Hdu {
        if (self.mode == .read_only or !self.dev.isWritable()) return error.NotWritable;
        if (!validBitpix(spec.bitpix)) return error.BadBitpix;
        if (spec.axes.len > 999) return error.BadNaxis;
        try self.ensureScannedAll(); // append after all existing HDUs

        const is_primary = self.hdus.items.len == 0;
        var header = try self.buildImageHeader(spec, is_primary);
        var header_owned = true;
        errdefer if (header_owned) header.deinit(self.alloc);

        const offset = self.scan_off;
        var bw = try block.BlockWriter.init(self.alloc, self.dev, offset, 0);
        defer bw.deinit();
        try header.writeTo(&bw);
        const cards = header.count();

        const hdu_ptr = try self.alloc.create(Hdu);
        errdefer self.alloc.destroy(hdu_ptr);
        header_owned = false; // Hdu.init takes ownership of `header` from here
        hdu_ptr.* = try Hdu.init(self.alloc, header, is_primary, offset, cards, self.limits);
        errdefer hdu_ptr.deinit(self.alloc);

        // Reserve & zero-fill the data unit so the file is structurally valid before pixels land.
        const data_end = try limits.add(hdu_ptr.data_off, block.roundUpBlocks(hdu_ptr.data_bytes));
        if (data_end > try self.dev.getSize()) try self.dev.setSize(data_end);

        try self.hdus.append(self.alloc, hdu_ptr);
        self.scan_off = data_end;
        self.fully_scanned = true;
        self.chdu = self.hdus.items.len - 1;
        return hdu_ptr;
    }

    fn buildImageHeader(self: *Fits, spec: ImageSpec, is_primary: bool) FitsError!Header {
        var header = Header.initEmpty();
        errdefer header.deinit(self.alloc);
        if (is_primary) {
            try header.appendValue(self.alloc, "SIMPLE", .{ .logical = true }, "conforms to FITS standard");
        } else {
            try header.appendValue(self.alloc, "XTENSION", .{ .string = "IMAGE" }, "image extension");
        }
        try header.appendValue(self.alloc, "BITPIX", .{ .int = spec.bitpix }, null);
        try header.appendValue(self.alloc, "NAXIS", .{ .int = @intCast(spec.axes.len) }, null);
        var name_buf: [8]u8 = undefined;
        for (spec.axes, 0..) |ax, i| {
            const kw = std.fmt.bufPrint(&name_buf, "NAXIS{d}", .{i + 1}) catch unreachable;
            try header.appendValue(self.alloc, kw, .{ .int = @intCast(ax) }, null);
        }
        if (is_primary) {
            try header.appendValue(self.alloc, "EXTEND", .{ .logical = true }, "may contain extensions");
        } else {
            try header.appendValue(self.alloc, "PCOUNT", .{ .int = 0 }, null);
            try header.appendValue(self.alloc, "GCOUNT", .{ .int = 1 }, null);
        }
        try header.ensureEnd(self.alloc);
        return header;
    }

    /// Flush buffered writes to the device, optionally updating checksums first (FR-SUM-3).
    pub fn flush(self: *Fits) FitsError!void {
        if (self.checksum_on_close) {
            if (self.checksum_hook) |hook| try hook(self);
        }
        try self.dev.sync();
    }

    /// The device underlying this handle (for low-level access, e.g. checksum computation).
    pub fn device(self: *Fits) Device {
        return self.dev;
    }
};

fn validBitpix(b: i64) bool {
    return switch (b) {
        8, 16, 32, 64, -32, -64 => true,
        else => false,
    };
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("io/memory.zig").MemoryDevice;

// Write a two-HDU file (primary NAXIS=0 + an IMAGE extension) into a memory device.
fn twoHduFile(alloc: Allocator) !*MemoryDevice {
    const mem = try alloc.create(MemoryDevice);
    mem.* = MemoryDevice.init(alloc);
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary, no data
    _ = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } }); // image extension
    try f.flush();
    return mem;
}

test "create → append two HDUs → reopen → scan and navigate" {
    const mem = try twoHduFile(testing.allocator);
    defer {
        mem.deinit();
        testing.allocator.destroy(mem);
    }

    var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), try f.hduCount());

    const h1 = try f.select(1);
    try testing.expectEqual(hdu_mod.HduKind.primary, h1.kind);
    try testing.expectEqual(@as(u16, 0), h1.naxis);

    const h2 = try f.select(2);
    try testing.expectEqual(hdu_mod.HduKind.image, h2.kind);
    try testing.expectEqual(@as(i64, 16), h2.bitpix);
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, h2.axes);
    try testing.expectEqual(@as(u64, 2 * 4 * 3), h2.data_bytes);

    // relative navigation
    const back = try f.move(-1);
    try testing.expectEqual(hdu_mod.HduKind.primary, back.kind);

    // out-of-range selection is typed, not a crash
    try testing.expectError(error.WrongHduType, f.select(3));
}

test "lazy scan only parses HDU 1 on open" {
    const mem = try twoHduFile(testing.allocator);
    defer {
        mem.deinit();
        testing.allocator.destroy(mem);
    }
    var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 1), f.hdus.items.len); // only HDU 1 scanned
    _ = try f.hduCount();
    try testing.expectEqual(@as(usize, 2), f.hdus.items.len);
}

test "*Hdu stays valid across reallocating appends (stable pointers)" {
    const mem = try testing.allocator.create(MemoryDevice);
    mem.* = MemoryDevice.init(testing.allocator);
    defer {
        mem.deinit();
        testing.allocator.destroy(mem);
    }
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const first = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    // Append many more HDUs, forcing the hdus list to grow/reallocate.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{2} });
    }
    // The original pointer is still valid (individually allocated).
    try testing.expectEqual(hdu_mod.HduKind.primary, first.kind);
}

test "read-only device rejects appends" {
    const mem = try twoHduFile(testing.allocator);
    defer {
        mem.deinit();
        testing.allocator.destroy(mem);
    }
    var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
    defer f.deinit();
    // The memory device is writable, but read_only mode forbids mutation.
    try testing.expectError(error.NotWritable, f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }));
}

