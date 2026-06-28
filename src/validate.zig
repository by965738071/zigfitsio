//! `fitsverify`-style structural validation pass (FR-VAL-1/2, §19.3; FITS 4.0 §3, §4.2.1.1,
//! §4.4.1, §4.4.2.5, §5.3, §7).
//!
//! `verify` walks every HDU of an already-opened `Fits` and reports **all** structural findings
//! (not just the first), each classified `err` vs `warning` (FR-VAL-2). It is read-only: it
//! never mutates the file and never aborts on a structural problem — a malformed value becomes a
//! `Finding`, while only an unrecoverable device error or an allocation failure is returned as a
//! typed error (`IoError`/`Allocator.Error`).
//!
//! Checks (FR-VAL-1):
//!  - **Block sizing** — the file length is a multiple of 2880 bytes (§3.1).
//!  - **Mandatory keywords** — presence, the leading order (`SIMPLE`/`XTENSION`, then `BITPIX`,
//!    `NAXIS`, `NAXIS1..NAXISn`), and that there is **no duplicate** of a mandatory keyword
//!    (§4.2.1.1); a duplicate of a non-mandatory value keyword is a `warning`.
//!  - **Value ranges** — `BITPIX` in {8,16,32,64,-32,-64}; `NAXISn` non-negative; `GCOUNT`
//!    positive; and `BLANK` only with a **positive** (integer) `BITPIX` (§4.4.2.5/§5.3).
//!  - **Table geometry** — binary tables: `NAXIS1` equals the summed `TFORM` field widths;
//!    ASCII tables: each `TBCOLn-1 + width <= NAXIS1` (`NAXIS1` MAY exceed the field extent).
//!  - **Declared vs actual size** — the padded data unit does not run past the device length.
//!  - **`END`/padding** — the header is terminated by an `END` card.
//!  - **Integrity** — `DATASUM`/`CHECKSUM` are verified via `checksum.verify`; a mismatch is a
//!    finding, while an absent keyword (`not_present`) is fine.
//!
//! Per FR-HDU-6 a missing or non-adjacent `EXTEND` is **never** a finding. Random-groups
//! geometry is skipped (handled by a separate module); the generic checks still apply.
const std = @import("std");
const errors = @import("errors.zig");
const block = @import("io/block.zig");
const limits = @import("limits.zig");
const Fits = @import("fits.zig").Fits;
const Hdu = @import("hdu.zig").Hdu;
const HduKind = @import("hdu.zig").HduKind;
const common = @import("table/common.zig");
const checksum = @import("checksum.zig");

const Allocator = std.mem.Allocator;

/// How serious a finding is (FR-VAL-2). `err` is a hard FITS 4.0 conformance violation;
/// `warning` is a recommendation or a non-mandatory irregularity.
pub const Severity = enum { err, warning };

/// One structural finding produced by `verify`.
///
/// `hdu` is the **1-based** HDU number the finding belongs to, or `0` for a whole-file finding
/// (e.g. block sizing). `kw` is the offending keyword name (allocator-owned when non-null) or
/// `null` when the finding is not keyword-specific. `msg` is a static string literal and is
/// never freed. Free a list of findings with `deinitFindings`.
pub const Finding = struct {
    /// Error vs warning classification.
    severity: Severity,
    /// 1-based HDU number, or 0 for a whole-file finding.
    hdu: u32,
    /// Offending keyword name, allocator-owned (freed by `deinitFindings`), or `null`.
    kw: ?[]const u8,
    /// Human-readable description; a static string literal (never freed).
    msg: []const u8,
};

/// The list type returned by `verify`. Caller-owned; release with `deinitFindings`.
pub const Findings = std.ArrayList(Finding);

/// Error set produced by `verify`: a genuine device failure or an allocation failure. Every
/// *structural* problem is reported as a `Finding`, not returned as an error.
pub const VerifyError = errors.IoError || Allocator.Error;

/// Run the structural validation pass over `fits` (forcing a full HDU scan) and return the list
/// of all findings (FR-VAL-1/2). The caller owns the result and must release it with
/// `deinitFindings`. A valid file yields no `err` findings.
pub fn verify(alloc: Allocator, fits: *Fits) VerifyError!Findings {
    var out: Findings = .empty;
    errdefer deinitFindings(alloc, &out);
    var v: Validator = .{ .alloc = alloc, .fits = fits, .out = &out };

    // Whole-file block sizing (§3.1): the total length must be a multiple of 2880.
    const dev_size = try fits.dev.getSize();
    if (dev_size % block.BLOCK != 0) {
        try v.add(.err, 0, null, "file length is not a multiple of 2880 bytes");
    }

    // Force a full scan so every HDU is available. A structurally-unparseable later HDU is
    // reported as a finding; a real I/O failure or OOM is surfaced as an error.
    const total: usize = fits.hduCount() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EndOfStream => return error.EndOfStream,
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.WriteFailed,
        error.SeekFailed => return error.SeekFailed,
        error.Unseekable => return error.Unseekable,
        error.NotWritable => return error.NotWritable,
        error.DeviceFull => return error.DeviceFull,
        error.BlockMisaligned => return error.BlockMisaligned,
        else => blk: {
            try v.add(.err, @intCast(fits.hdus.items.len + 1), null, "an HDU header is structurally invalid and could not be parsed");
            break :blk fits.hdus.items.len;
        },
    };

    for (fits.hdus.items[0..total], 0..) |hdu, i| {
        try v.checkHdu(hdu, @intCast(i + 1), dev_size);
    }
    return out;
}

/// Release a `Findings` list returned by `verify`, freeing every owned `kw` string and the list
/// backing store. `msg` fields are static literals and are not freed.
pub fn deinitFindings(alloc: Allocator, findings: *Findings) void {
    for (findings.items) |f| if (f.kw) |k| alloc.free(k);
    findings.deinit(alloc);
}

// ── internals ──────────────────────────────────────────────────────────────────────────────

// Mutable state threaded through the per-HDU checks: the allocator, the file under inspection,
// and the growing findings list.
const Validator = struct {
    alloc: Allocator,
    fits: *Fits,
    out: *Findings,

    // Record a finding. `kw` (when non-null) is duplicated into allocator-owned memory so the
    // finding outlives any transient buffer the caller built it from.
    fn add(self: *Validator, sev: Severity, hdu: u32, kw: ?[]const u8, msg: []const u8) Allocator.Error!void {
        const owned: ?[]const u8 = if (kw) |k| try self.alloc.dupe(u8, k) else null;
        errdefer if (owned) |o| self.alloc.free(o);
        try self.out.append(self.alloc, .{ .severity = sev, .hdu = hdu, .kw = owned, .msg = msg });
    }

    // Run every check for one HDU.
    fn checkHdu(self: *Validator, hdu: *Hdu, idx: u32, dev_size: u64) VerifyError!void {
        try self.checkEnd(hdu, idx);
        try self.checkMandatory(hdu, idx);
        try self.checkRanges(hdu, idx);
        try self.checkDuplicates(hdu, idx);
        switch (hdu.kind) {
            .binary_table => try self.checkBinaryGeometry(hdu, idx),
            .ascii_table => try self.checkAsciiGeometry(hdu, idx),
            else => {}, // image-like and random groups carry no table geometry
        }
        try self.checkDataExtent(hdu, idx, dev_size);
        try self.checkIntegrity(hdu, idx);
    }

    // END/padding: the header must be terminated by an END card (§4.4.1).
    fn checkEnd(self: *Validator, hdu: *Hdu, idx: u32) Allocator.Error!void {
        const cnt = hdu.header.count();
        if (cnt == 0 or hdu.header.at(cnt - 1).kind != .end) {
            try self.add(.err, idx, "END", "header is not terminated by an END card");
        }
    }

    // Mandatory-keyword presence and leading order (§4.4.1).
    fn checkMandatory(self: *Validator, hdu: *Hdu, idx: u32) Allocator.Error!void {
        const first: []const u8 = switch (hdu.kind) {
            .primary, .random_groups => "SIMPLE",
            .image, .ascii_table, .binary_table => "XTENSION",
        };
        const cnt = hdu.header.count();
        if (cnt == 0 or !hdu.header.at(0).name.eqlText(first)) {
            try self.add(.err, idx, first, "the first keyword has the wrong name for this HDU kind");
        }
        // BITPIX then NAXIS must immediately follow the leading keyword.
        if (!hdu.header.has("BITPIX")) {
            try self.add(.err, idx, "BITPIX", "mandatory BITPIX keyword is missing");
        } else if (cnt > 1 and !hdu.header.at(1).name.eqlText("BITPIX")) {
            try self.add(.err, idx, "BITPIX", "BITPIX must immediately follow the first keyword");
        }
        if (!hdu.header.has("NAXIS")) {
            try self.add(.err, idx, "NAXIS", "mandatory NAXIS keyword is missing");
        } else if (cnt > 2 and !hdu.header.at(2).name.eqlText("NAXIS")) {
            try self.add(.err, idx, "NAXIS", "NAXIS must be the third keyword");
        }
        // NAXIS1..NAXISn must all be present.
        var nbuf: [16]u8 = undefined;
        var n: u16 = 1;
        while (n <= hdu.naxis) : (n += 1) {
            const kw = std.fmt.bufPrint(&nbuf, "NAXIS{d}", .{n}) catch unreachable;
            if (!hdu.header.has(kw)) {
                try self.add(.err, idx, kw, "mandatory NAXISn keyword is missing");
            }
        }
        // Tables additionally require TFIELDS/PCOUNT/GCOUNT.
        if (hdu.kind == .ascii_table or hdu.kind == .binary_table) {
            inline for (.{ "TFIELDS", "PCOUNT", "GCOUNT" }) |req| {
                if (!hdu.header.has(req)) try self.add(.err, idx, req, "mandatory table keyword is missing");
            }
        }
    }

    // Value ranges, including the BLANK/BITPIX constraint (§4.4.2.5/§5.3).
    fn checkRanges(self: *Validator, hdu: *Hdu, idx: u32) Allocator.Error!void {
        if (!validBitpix(hdu.bitpix)) {
            try self.add(.err, idx, "BITPIX", "BITPIX is not one of 8, 16, 32, 64, -32, -64");
        }
        // BLANK declares an integer null value and is only meaningful for a positive BITPIX.
        if (hdu.header.has("BLANK") and hdu.bitpix < 0) {
            try self.add(.err, idx, "BLANK", "BLANK is only permitted with a positive (integer) BITPIX");
        }
        if (hdu.gcount == 0) {
            try self.add(.err, idx, "GCOUNT", "GCOUNT must be a positive integer");
        }
        // For a plain image, PCOUNT should be 0 and GCOUNT should be 1 (advisory).
        if (hdu.kind == .primary or hdu.kind == .image) {
            if (hdu.pcount != 0) try self.add(.warning, idx, "PCOUNT", "PCOUNT should be 0 for an image array");
            if (hdu.gcount != 1) try self.add(.warning, idx, "GCOUNT", "GCOUNT should be 1 for an image array");
        }
    }

    // No keyword may appear more than once (§4.2.1.1). A duplicate of a mandatory keyword is an
    // error; a duplicate of any other value keyword is a warning. Commentary cards are exempt.
    fn checkDuplicates(self: *Validator, hdu: *Hdu, idx: u32) Allocator.Error!void {
        const cards = hdu.header.cards.items;
        for (cards, 0..) |*c, i| {
            if (c.kind != .value) continue;
            var dup = false;
            var j: usize = 0;
            while (j < i) : (j += 1) {
                if (cards[j].kind == .value and cards[j].name.eql(&c.name)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) continue;
            const name = c.name.text();
            if (isMandatory(name, hdu.kind)) {
                try self.add(.err, idx, name, "mandatory keyword appears more than once");
            } else {
                try self.add(.warning, idx, name, "keyword appears more than once");
            }
        }
    }

    // Binary table: NAXIS1 must equal the sum of the TFORM field widths (§7.3.1).
    fn checkBinaryGeometry(self: *Validator, hdu: *Hdu, idx: u32) Allocator.Error!void {
        if (hdu.bitpix != 8) try self.add(.err, idx, "BITPIX", "binary-table BITPIX must be 8");
        if (hdu.naxis != 2) try self.add(.err, idx, "NAXIS", "binary-table NAXIS must be 2");
        if (hdu.gcount != 1) try self.add(.err, idx, "GCOUNT", "binary-table GCOUNT must be 1");

        const tfields = (try self.readTfields(hdu, idx)) orelse return;
        const naxis1: u64 = if (hdu.naxis >= 1) hdu.axes[0] else 0;
        var sum: u64 = 0;
        var complete = true;
        var nbuf: [16]u8 = undefined;
        var n: u64 = 1;
        while (n <= tfields) : (n += 1) {
            const kw = std.fmt.bufPrint(&nbuf, "TFORM{d}", .{n}) catch unreachable;
            const s = hdu.header.getString(self.alloc, kw) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                try self.add(.err, idx, kw, "mandatory TFORMn keyword is missing or not a string");
                complete = false;
                continue;
            };
            defer self.alloc.free(s);
            const tf = common.BinTform.parse(s) catch {
                try self.add(.err, idx, kw, "TFORMn has invalid syntax");
                complete = false;
                continue;
            };
            const fb = tf.fieldBytes() catch {
                try self.add(.err, idx, kw, "TFORMn declares an invalid field width");
                complete = false;
                continue;
            };
            sum = limits.add(sum, fb) catch {
                try self.add(.err, idx, kw, "summed TFORM field widths overflow");
                complete = false;
                break;
            };
        }
        if (complete and sum != naxis1) {
            try self.add(.err, idx, "NAXIS1", "NAXIS1 does not equal the sum of the TFORM field widths");
        }
    }

    // ASCII table: each field range TBCOLn-1 + width must fit within NAXIS1, which MAY exceed the
    // extent (gaps are legal, §7.2.1).
    fn checkAsciiGeometry(self: *Validator, hdu: *Hdu, idx: u32) Allocator.Error!void {
        if (hdu.bitpix != 8) try self.add(.err, idx, "BITPIX", "ASCII-table BITPIX must be 8");
        if (hdu.naxis != 2) try self.add(.err, idx, "NAXIS", "ASCII-table NAXIS must be 2");
        if (hdu.gcount != 1) try self.add(.err, idx, "GCOUNT", "ASCII-table GCOUNT must be 1");
        if (hdu.pcount != 0) try self.add(.err, idx, "PCOUNT", "ASCII-table PCOUNT must be 0");

        const tfields = (try self.readTfields(hdu, idx)) orelse return;
        const naxis1: u64 = if (hdu.naxis >= 1) hdu.axes[0] else 0;
        var fbuf: [16]u8 = undefined;
        var cbuf: [16]u8 = undefined;
        var n: u64 = 1;
        while (n <= tfields) : (n += 1) {
            const form_kw = std.fmt.bufPrint(&fbuf, "TFORM{d}", .{n}) catch unreachable;
            const col_kw = std.fmt.bufPrint(&cbuf, "TBCOL{d}", .{n}) catch unreachable;

            const s = hdu.header.getString(self.alloc, form_kw) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                try self.add(.err, idx, form_kw, "mandatory TFORMn keyword is missing or not a string");
                continue;
            };
            defer self.alloc.free(s);
            const tf = common.AsciiTform.parse(s) catch {
                try self.add(.err, idx, form_kw, "TFORMn has invalid syntax");
                continue;
            };
            const tbcol = hdu.header.getValue(u64, col_kw) catch {
                try self.add(.err, idx, col_kw, "mandatory TBCOLn keyword is missing or not a positive integer");
                continue;
            };
            const range = common.asciiFieldRange(tbcol, tf.width) catch {
                try self.add(.err, idx, col_kw, "TBCOLn is zero or its field range overflows");
                continue;
            };
            if (range.end > naxis1) {
                try self.add(.err, idx, col_kw, "TBCOLn plus the field width extends past NAXIS1");
            }
        }
    }

    // Read and range-check TFIELDS; report and return null on any problem.
    fn readTfields(self: *Validator, hdu: *Hdu, idx: u32) Allocator.Error!?u64 {
        const v = hdu.header.getValue(i64, "TFIELDS") catch {
            try self.add(.err, idx, "TFIELDS", "mandatory TFIELDS keyword is missing or not an integer");
            return null;
        };
        if (v < 0 or v > 999) {
            try self.add(.err, idx, "TFIELDS", "TFIELDS is outside the legal range 0..999");
            return null;
        }
        return @intCast(v);
    }

    // Declared-vs-actual data size: the padded data unit must not run past the device length.
    fn checkDataExtent(self: *Validator, hdu: *Hdu, idx: u32, dev_size: u64) Allocator.Error!void {
        const padded = block.roundUpBlocks(hdu.data_bytes);
        const need = limits.add(hdu.data_off, padded) catch {
            try self.add(.err, idx, null, "declared data unit size overflows the address space");
            return;
        };
        if (need > dev_size) {
            try self.add(.err, idx, null, "declared data unit extends past the end of the file");
        }
    }

    // DATASUM/CHECKSUM verification (§4.4.2.7). A mismatch is a finding; an absent keyword is
    // fine. A device failure is surfaced as an error; a malformed integrity card is a warning.
    fn checkIntegrity(self: *Validator, hdu: *Hdu, idx: u32) VerifyError!void {
        const rep = checksum.verify(self.fits, hdu) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
            error.WriteFailed => return error.WriteFailed,
            error.SeekFailed => return error.SeekFailed,
            error.Unseekable => return error.Unseekable,
            error.NotWritable => return error.NotWritable,
            error.DeviceFull => return error.DeviceFull,
            error.BlockMisaligned => return error.BlockMisaligned,
            else => {
                try self.add(.warning, idx, "CHECKSUM", "integrity keyword could not be parsed for verification");
                return;
            },
        };
        switch (rep.data) {
            .mismatch => try self.add(.err, idx, "DATASUM", "DATASUM does not match the data unit"),
            .match, .not_present => {},
        }
        switch (rep.sum) {
            .mismatch => try self.add(.err, idx, "CHECKSUM", "CHECKSUM does not verify (the HDU does not sum to all-ones)"),
            .match, .not_present => {},
        }
    }
};

fn validBitpix(b: i64) bool {
    return switch (b) {
        8, 16, 32, 64, -32, -64 => true,
        else => false,
    };
}

// Whether `name` is `prefix` followed by one or more decimal digits (e.g. "NAXIS3" for "NAXIS").
fn isIndexed(name: []const u8, prefix: []const u8) bool {
    if (name.len <= prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) return false;
    for (name[prefix.len..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// Whether `name` is a mandatory keyword for an HDU of `kind` (used to classify duplicates).
fn isMandatory(name: []const u8, kind: HduKind) bool {
    if (std.ascii.eqlIgnoreCase(name, "BITPIX") or std.ascii.eqlIgnoreCase(name, "NAXIS")) return true;
    if (isIndexed(name, "NAXIS")) return true;
    switch (kind) {
        .primary, .random_groups => if (std.ascii.eqlIgnoreCase(name, "SIMPLE")) return true,
        .image, .ascii_table, .binary_table => if (std.ascii.eqlIgnoreCase(name, "XTENSION")) return true,
    }
    switch (kind) {
        .ascii_table, .binary_table => {
            if (std.ascii.eqlIgnoreCase(name, "TFIELDS") or
                std.ascii.eqlIgnoreCase(name, "PCOUNT") or
                std.ascii.eqlIgnoreCase(name, "GCOUNT")) return true;
            if (isIndexed(name, "TFORM")) return true;
            if (kind == .ascii_table and isIndexed(name, "TBCOL")) return true;
        },
        else => {},
    }
    return false;
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const Header = @import("header/header.zig").Header;
const MemoryDevice = @import("io/memory.zig").MemoryDevice;

// Count findings of a given severity.
fn countSeverity(findings: *const Findings, sev: Severity) usize {
    var c: usize = 0;
    for (findings.items) |f| {
        if (f.severity == sev) c += 1;
    }
    return c;
}

// Whether any finding matches the (hdu, severity, keyword) triple.
fn hasFinding(findings: *const Findings, hdu: u32, sev: Severity, kw: ?[]const u8) bool {
    for (findings.items) |f| {
        if (f.hdu != hdu or f.severity != sev) continue;
        if (kw) |want| {
            const got = f.kw orelse continue;
            if (!std.ascii.eqlIgnoreCase(got, want)) continue;
        } else if (f.kw != null) continue;
        return true;
    }
    return false;
}

test "a valid created file yields no findings" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    _ = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } });
    try f.flush();

    var findings = try verify(alloc, &f);
    defer deinitFindings(alloc, &findings);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "duplicate NAXIS and BLANK-with-float-BITPIX both reported (more than one finding)" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    var h = Header.initEmpty();
    {
        errdefer h.deinit(alloc);
        try h.appendValue(alloc, "SIMPLE", .{ .logical = true }, null);
        try h.appendValue(alloc, "BITPIX", .{ .int = -32 }, null); // float pixels
        try h.appendValue(alloc, "NAXIS", .{ .int = 1 }, null);
        try h.appendValue(alloc, "NAXIS1", .{ .int = 4 }, null);
        try h.appendValue(alloc, "NAXIS", .{ .int = 1 }, null); // duplicate mandatory keyword
        try h.appendValue(alloc, "BLANK", .{ .int = 0 }, null); // illegal with negative BITPIX
    }
    _ = try f.appendHdu(h); // appendHdu takes ownership (frees on its own error)
    try f.flush();

    var findings = try verify(alloc, &f);
    defer deinitFindings(alloc, &findings);

    // The pass reports ALL findings, not just the first.
    try testing.expect(findings.items.len > 1);
    try testing.expect(countSeverity(&findings, .err) >= 2);
    try testing.expect(hasFinding(&findings, 1, .err, "NAXIS")); // duplicate mandatory
    try testing.expect(hasFinding(&findings, 1, .err, "BLANK")); // BLANK with float BITPIX
}

test "binary table with wrong NAXIS1 sum is flagged" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary, so HDU 2 is an extension

    var h = Header.initEmpty();
    {
        errdefer h.deinit(alloc);
        try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
        try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
        try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
        try h.appendValue(alloc, "NAXIS1", .{ .int = 10 }, null); // wrong: 1J+1E = 8 bytes
        try h.appendValue(alloc, "NAXIS2", .{ .int = 2 }, null);
        try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
        try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
        try h.appendValue(alloc, "TFIELDS", .{ .int = 2 }, null);
        try h.appendValue(alloc, "TFORM1", .{ .string = "1J" }, null);
        try h.appendValue(alloc, "TFORM2", .{ .string = "1E" }, null);
    }
    _ = try f.appendHdu(h);
    try f.flush();

    var findings = try verify(alloc, &f);
    defer deinitFindings(alloc, &findings);

    try testing.expect(hasFinding(&findings, 2, .err, "NAXIS1"));
    try testing.expectEqual(@as(usize, 0), countWithHdu(&findings, 1)); // primary is clean
}

// Count findings belonging to a given HDU number.
fn countWithHdu(findings: *const Findings, hdu: u32) usize {
    var c: usize = 0;
    for (findings.items) |f| {
        if (f.hdu == hdu) c += 1;
    }
    return c;
}

test "ASCII table TBCOL plus width past NAXIS1 is flagged; NAXIS1 may exceed extent" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary

    var h = Header.initEmpty();
    {
        errdefer h.deinit(alloc);
        try h.appendValue(alloc, "XTENSION", .{ .string = "TABLE" }, null);
        try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
        try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
        try h.appendValue(alloc, "NAXIS1", .{ .int = 10 }, null); // row width; gap beyond field 1 is legal
        try h.appendValue(alloc, "NAXIS2", .{ .int = 1 }, null);
        try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
        try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
        try h.appendValue(alloc, "TFIELDS", .{ .int = 2 }, null);
        try h.appendValue(alloc, "TBCOL1", .{ .int = 1 }, null);
        try h.appendValue(alloc, "TFORM1", .{ .string = "I4" }, null); // [0,4) within NAXIS1 — fine
        try h.appendValue(alloc, "TBCOL2", .{ .int = 8 }, null);
        try h.appendValue(alloc, "TFORM2", .{ .string = "I5" }, null); // [7,12) past NAXIS1=10 — error
    }
    _ = try f.appendHdu(h);
    try f.flush();

    var findings = try verify(alloc, &f);
    defer deinitFindings(alloc, &findings);

    try testing.expect(hasFinding(&findings, 2, .err, "TBCOL2")); // overruns NAXIS1
    try testing.expect(!hasFinding(&findings, 2, .err, "TBCOL1")); // fits, plus the gap is legal
}

test "declared data unit past the device length is flagged" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    const hdu = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{100} });
    try f.flush();
    // Truncate the file to the header boundary (a block multiple) so only the data-extent check
    // fires — the data unit is now entirely missing.
    try f.dev.setSize(hdu.data_off);

    var findings = try verify(alloc, &f);
    defer deinitFindings(alloc, &findings);

    try testing.expect(hasFinding(&findings, 1, .err, null)); // data extends past EOF
    try testing.expect(!hasFinding(&findings, 0, .err, null)); // still a block multiple
}

test "DATASUM/CHECKSUM mismatch is reported as findings" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    var h = Header.initEmpty();
    {
        errdefer h.deinit(alloc);
        try h.appendValue(alloc, "SIMPLE", .{ .logical = true }, null);
        try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
        try h.appendValue(alloc, "NAXIS", .{ .int = 1 }, null);
        try h.appendValue(alloc, "NAXIS1", .{ .int = 10 }, null);
        // Integrity cards present but never recomputed → they will not verify.
        try h.appendValue(alloc, "DATASUM", .{ .string = "42" }, null);
        try h.appendValue(alloc, "CHECKSUM", .{ .string = "0000000000000000" }, null);
    }
    _ = try f.appendHdu(h); // data unit zero-filled
    try f.flush();

    var findings = try verify(alloc, &f);
    defer deinitFindings(alloc, &findings);

    try testing.expect(hasFinding(&findings, 1, .err, "DATASUM"));
    try testing.expect(hasFinding(&findings, 1, .err, "CHECKSUM"));
}

test "duplicate non-mandatory keyword is a warning" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    var h = Header.initEmpty();
    {
        errdefer h.deinit(alloc);
        try h.appendValue(alloc, "SIMPLE", .{ .logical = true }, null);
        try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
        try h.appendValue(alloc, "NAXIS", .{ .int = 0 }, null);
        try h.appendValue(alloc, "OBJECT", .{ .string = "M31" }, null);
        try h.appendValue(alloc, "OBJECT", .{ .string = "M32" }, null); // duplicate, not mandatory
    }
    _ = try f.appendHdu(h);
    try f.flush();

    var findings = try verify(alloc, &f);
    defer deinitFindings(alloc, &findings);

    try testing.expect(hasFinding(&findings, 1, .warning, "OBJECT"));
    try testing.expectEqual(@as(usize, 0), countSeverity(&findings, .err));
}

test "deinitFindings frees owned keyword strings with no leak" {
    const alloc = testing.allocator;
    var findings: Findings = .empty;
    var v: Validator = .{ .alloc = alloc, .fits = undefined, .out = &findings };
    try v.add(.err, 1, "NAXIS3", "missing");
    try v.add(.warning, 2, null, "file-level note");
    try testing.expectEqual(@as(usize, 2), findings.items.len);
    try testing.expectEqualStrings("NAXIS3", findings.items[0].kw.?);
    try testing.expectEqual(@as(?[]const u8, null), findings.items[1].kw);
    deinitFindings(alloc, &findings); // testing.allocator asserts no leak
}
