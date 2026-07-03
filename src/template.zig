//! ASCII header **template loader** (FR-TPL-1, design §20.3) — a thin convenience layer over
//! the programmatic HDU builder in `fits.zig`, which remains the primary, fully-supported
//! construction path (FR-TPL-2).
//!
//! `buildFromTemplate` reads a CFITSIO-style ASCII *header template* and creates the
//! corresponding HDUs in a freshly-`create`d file. Each parsed HDU header is materialized
//! through `Fits.appendHdu`, so geometry validation and data-unit reservation are exactly the
//! same code paths the programmatic builder uses — the template never has a private notion of
//! "valid HDU".
//!
//! ## Grammar (the CFITSIO-style subset we support)
//!
//! ```text
//! line      := blank | comment | hdu_start | keyword
//! comment   := <line whose first non-blank char is '#' or '/'>
//! hdu_start := ('SIMPLE' | 'XTENSION') <rest-of-keyword-line>
//! keyword   := name ['='] value-field           (name auto-indexed if it contains '#')
//! ```
//!
//!   * **Blank lines** and lines whose first character is `#` or `/` are comments and ignored.
//!   * A line whose keyword is `SIMPLE` (the primary) or `XTENSION` (an extension) **starts a
//!     new HDU**; the accumulated previous HDU, if any, is finalized via `appendHdu` first.
//!   * Every other line is a keyword card `NAME = value / comment` (the `=` is optional, so the
//!     free-form `NAME value` shape is also accepted) appended to the HDU currently being built.
//!   * **Auto-indexing (`FR-TPL-1`).** A keyword written with a `#` — e.g. `NAXIS#`, `TFORM#` —
//!     has its `#` replaced by a per-HDU counter that increments on each use of that exact
//!     token: the first `NAXIS#` becomes `NAXIS1`, the second `NAXIS2`, and so on. Counters are
//!     per-keyword-token and reset at every new HDU.
//!   * **Commentary keywords** (`COMMENT`, `HISTORY`, blank) keep their free text verbatim.
//!   * **Unquoted string values.** A value that is not a number, logical, or quoted string
//!     (e.g. `XTENSION BINTABLE`, `TFORM1 J`) is taken as a string value, matching CFITSIO's
//!     lenient template value handling.
//!
//! ## Scope & errors (NFR-INTEROP-1: never silently drop)
//!
//! Image and table HDU creation is in scope. Parser **directives we do not implement** — any
//! line beginning with `\` (e.g. `\group`/`\end`) — are rejected, never ignored. Because the
//! deliverable signature is `FitsError!Fits`, template-level faults are surfaced as the nearest
//! existing typed error rather than a private set:
//!
//!   * an unsupported `\…` directive → `error.BadExtension`;
//!   * a keyword before any `SIMPLE`/`XTENSION` (no open HDU) → `error.KeywordOrder`;
//!   * a malformed keyword name → `error.BadKeywordName`; a value/comment too long for the
//!     70-byte field → `error.CardOverflow`; missing mandatory keywords surface from
//!     `appendHdu` as `error.MissingRequiredKeyword` / `error.BadBitpix` / etc.
const std = @import("std");
const fits_mod = @import("fits.zig");
const Fits = fits_mod.Fits;
const FitsError = fits_mod.FitsError;
const OpenOpts = fits_mod.OpenOpts;
const Device = @import("io/device.zig").Device;
const Header = @import("header/header.zig").Header;
const Name = @import("header/name.zig").Name;
const value = @import("header/value.zig");

const Allocator = std.mem.Allocator;

/// Maximum bytes of commentary free text that fit in a card (columns 9–80).
const COMMENTARY_WIDTH: usize = 72;

/// Options for `buildFromTemplate`. Wraps the file-handle `OpenOpts` so limits / diagnostics /
/// checksum behavior carry through to the created file, leaving room for template-specific
/// switches later without breaking the call site.
pub const TemplateOpts = struct {
    /// Passed straight to `Fits.create` for the new file.
    open: OpenOpts = .{},
};

/// Parse a CFITSIO-style ASCII header template `text` and build the corresponding FITS file on
/// `dev`, returning the open (create-mode) handle (FR-TPL-1, §20.3). The handle does not own
/// `dev` (it was supplied, not opened by path), so the caller still owns and closes it.
///
/// This is sugar over `Fits.create` + `Fits.appendHdu`: every HDU the template describes is
/// built as a `Header` and appended, so it goes through the same validation and data-unit
/// reservation as a hand-coded programmatic build (FR-TPL-2). On any error the partially-built
/// file handle is torn down before returning.
pub fn buildFromTemplate(alloc: Allocator, dev: Device, text: []const u8, opts: TemplateOpts) FitsError!Fits {
    var f = try Fits.create(alloc, dev, opts.open);
    errdefer f.deinit();

    var b: Builder = .{};
    defer b.deinit(alloc); // frees the in-progress header (on error) and the index counters

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue; // blank line
        switch (line[0]) {
            '#', '/' => continue, // full-line comment
            '\\' => return error.BadExtension, // unsupported parser directive (e.g. \group)
            else => {},
        }
        try b.handleLine(alloc, &f, line);
    }
    try b.flush(&f); // finalize the last HDU
    return f;
}

// ── internals ────────────────────────────────────────────────────────────────────────────

// A per-HDU auto-index counter keyed by the exact `#`-bearing keyword token (e.g. "NAXIS#").
const Counter = struct {
    key: [8]u8,
    len: u8,
    count: usize,
};

// Incremental template→HDU builder: accumulates the cards of the HDU currently being read and
// flushes it through `appendHdu` when the next HDU starts or input ends.
const Builder = struct {
    /// The header of the HDU currently being built; `null` until the first `SIMPLE`/`XTENSION`.
    /// Owned by the builder until handed to `appendHdu` (which then owns and frees it).
    current: ?Header = null,
    /// Auto-index counters for the current HDU; cleared at each new HDU.
    counters: std.ArrayList(Counter) = .empty,

    fn deinit(self: *Builder, alloc: Allocator) void {
        if (self.current) |*h| h.deinit(alloc);
        self.current = null;
        self.counters.deinit(alloc);
    }

    // Finalize the accumulated HDU (if any) by appending it. Ownership of the header transfers
    // to `appendHdu`, which frees it on its own error — so `current` is cleared *before* the
    // call to keep `deinit` from double-freeing on a failed append.
    fn flush(self: *Builder, f: *Fits) FitsError!void {
        if (self.current) |hdr| {
            self.current = null;
            _ = try f.appendHdu(hdr);
        }
    }

    // Process one non-comment, non-directive template line.
    fn handleLine(self: *Builder, alloc: Allocator, f: *Fits, line: []const u8) FitsError!void {
        // Split off the keyword token: everything up to the first space or '='.
        var i: usize = 0;
        while (i < line.len and line[i] != ' ' and line[i] != '=') : (i += 1) {}
        const kw = line[0..i];
        const after_kw = std.mem.trimStart(u8, line[i..], " ");

        // Resolve auto-indexing (`NAXIS#` → `NAXIS1`, …) then normalize/validate the name.
        var name_buf: [16]u8 = undefined;
        const kw_final = try self.substituteIndex(alloc, kw, &name_buf);
        const name = try Name.parse(kw_final);

        // `SIMPLE` / `XTENSION` begin a new HDU.
        if (name.eqlText("SIMPLE") or name.eqlText("XTENSION")) {
            try self.flush(f); // append the previous HDU first
            self.current = Header.initEmpty();
            self.counters.clearRetainingCapacity();
            try appendKeyword(alloc, &self.current.?, name, after_kw);
            return;
        }

        // Any other card requires an HDU to be open.
        if (self.current == null) return error.KeywordOrder;
        if (name.isEnd()) return; // `END` is appended by `appendHdu`; never duplicate it

        try appendKeyword(alloc, &self.current.?, name, after_kw);
    }

    // Replace a single `#` in `kw` with its per-HDU running index, writing the result into
    // `buf`; returns `kw` unchanged when there is no `#`. A result longer than 8 chars overflows
    // the name field and is reported as `error.BadKeywordName`.
    fn substituteIndex(self: *Builder, alloc: Allocator, kw: []const u8, buf: []u8) FitsError![]const u8 {
        const hash = std.mem.indexOfScalar(u8, kw, '#') orelse return kw;
        const idx = try self.bumpCounter(alloc, kw);
        return std.fmt.bufPrint(buf, "{s}{d}{s}", .{ kw[0..hash], idx, kw[hash + 1 ..] }) catch
            return error.BadKeywordName;
    }

    // Return the next index for the auto-indexed keyword token `kw` (1-based), creating its
    // counter on first use within the current HDU.
    fn bumpCounter(self: *Builder, alloc: Allocator, kw: []const u8) FitsError!usize {
        for (self.counters.items) |*c| {
            if (c.len == kw.len and std.mem.eql(u8, c.key[0..c.len], kw)) {
                c.count += 1;
                return c.count;
            }
        }
        var c: Counter = .{ .key = undefined, .len = 0, .count = 1 };
        const n = @min(kw.len, c.key.len);
        @memcpy(c.key[0..n], kw[0..n]);
        c.len = @intCast(n);
        try self.counters.append(alloc, c);
        return 1;
    }
};

// Append one parsed card to `header`. Commentary keywords keep their free text verbatim; value
// keywords parse their value field (with the optional leading `=` stripped) and re-emit it as a
// fixed/free-format card via `Header.appendValue` — the same path the programmatic builder uses.
fn appendKeyword(alloc: Allocator, header: *Header, name: Name, after_kw: []const u8) FitsError!void {
    if (name.isCommentary()) {
        var raw: [80]u8 = @splat(' ');
        const nt = name.text();
        @memcpy(raw[0..nt.len], nt);
        if (after_kw.len > COMMENTARY_WIDTH) return error.CardOverflow;
        @memcpy(raw[8..][0..after_kw.len], after_kw);
        try header.appendRaw(alloc, &raw);
        return;
    }

    // Value field: drop a leading `=` (the optional value indicator) and its trailing blanks.
    var vfield = after_kw;
    if (vfield.len > 0 and vfield[0] == '=') vfield = std.mem.trimStart(u8, vfield[1..], " ");

    const cmt = value.parseComment(vfield);
    const parsed = value.parseValue(alloc, vfield) catch |e| switch (e) {
        // A bare token that is neither numeric, logical, nor quoted is taken as a string value
        // (CFITSIO template leniency) — e.g. `XTENSION BINTABLE` or `TFORM1 J`.
        error.BadValueSyntax => {
            const tok = stringToken(vfield);
            if (tok.len == 0) return e;
            try header.appendValue(alloc, name.text(), .{ .string = tok }, cmt);
            return;
        },
        else => return e,
    };
    defer parsed.deinit(alloc); // free a parsed `.string` after `appendValue` copies it
    try header.appendValue(alloc, name.text(), parsed, cmt);
}

// The value token of `vfield`: everything before the first `/` comment delimiter, blank-trimmed.
fn stringToken(vfield: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, vfield, '/');
    const part = if (slash) |s| vfield[0..s] else vfield;
    return std.mem.trim(u8, part, " ");
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("io/memory.zig").MemoryDevice;
const Hdu = @import("hdu.zig").Hdu;
const HduKind = @import("hdu.zig").HduKind;

fn newMem(alloc: Allocator) !*MemoryDevice {
    const mem = try alloc.create(MemoryDevice);
    mem.* = MemoryDevice.init(alloc);
    return mem;
}

fn freeMem(alloc: Allocator, mem: *MemoryDevice) void {
    mem.deinit();
    alloc.destroy(mem);
}

// Compare two HDUs on the structural facets the template must reproduce.
fn expectSameHdu(expected: *const Hdu, actual: *const Hdu) !void {
    try testing.expectEqual(expected.kind, actual.kind);
    try testing.expectEqual(expected.bitpix, actual.bitpix);
    try testing.expectEqual(expected.naxis, actual.naxis);
    try testing.expectEqualSlices(u64, expected.axes, actual.axes);
    try testing.expectEqual(expected.data_bytes, actual.data_bytes);
}

// The BINTABLE header used by both the programmatic and template builds in the parity test.
fn buildBinTableHeader(alloc: Allocator) !Header {
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, "binary table extension");
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = 5 }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "TTYPE1", .{ .string = "COUNTS" }, null);
    try h.appendValue(alloc, "TFORM1", .{ .string = "J" }, null);
    try h.appendValue(alloc, "TTYPE2", .{ .string = "FLUX" }, null);
    try h.appendValue(alloc, "TFORM2", .{ .string = "E" }, null);
    return h;
}

test "template primary image + BINTABLE matches the equivalent programmatic build" {
    const alloc = testing.allocator;

    const template =
        \\# a primary image followed by a binary table
        \\SIMPLE  =                    T / conforms to FITS standard
        \\BITPIX  =                    8
        \\NAXIS   =                    2
        \\NAXIS1  =                  100
        \\NAXIS2  =                  200
        \\END
        \\
        \\XTENSION= 'BINTABLE'          / binary table extension
        \\BITPIX  =                    8
        \\NAXIS   =                    2
        \\NAXIS1  =                    8
        \\NAXIS2  =                    5
        \\PCOUNT  =                    0
        \\GCOUNT  =                    1
        \\TFIELDS =                    2
        \\TTYPE1  = 'COUNTS'
        \\TFORM1  = 'J'
        \\TTYPE2  = 'FLUX'
        \\TFORM2  = 'E'
        \\END
    ;

    // Build from template.
    const mem_t = try newMem(alloc);
    defer freeMem(alloc, mem_t);
    {
        var f = try buildFromTemplate(alloc, mem_t.device(), template, .{});
        defer f.deinit();
        try testing.expectEqual(@as(usize, 2), try f.hduCount());
    }

    // Build the same thing programmatically.
    const mem_p = try newMem(alloc);
    defer freeMem(alloc, mem_p);
    {
        var f = try Fits.create(alloc, mem_p.device(), .{});
        defer f.deinit();
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{ 100, 200 } });
        _ = try f.appendHdu(try buildBinTableHeader(alloc));
    }

    // Reopen both and compare HDU-by-HDU.
    var ft = try Fits.open(alloc, mem_t.device(), .read_only, .{});
    defer ft.deinit();
    var fp = try Fits.open(alloc, mem_p.device(), .read_only, .{});
    defer fp.deinit();

    try testing.expectEqual(try fp.hduCount(), try ft.hduCount());

    const t1 = try ft.select(1);
    const p1 = try fp.select(1);
    try expectSameHdu(p1, t1);
    try testing.expectEqual(HduKind.primary, t1.kind);
    try testing.expectEqual(@as(i64, 8), try t1.header.getValue(i64, "BITPIX"));
    try testing.expectEqualSlices(u64, &.{ 100, 200 }, t1.axes);

    const t2 = try ft.select(2);
    const p2 = try fp.select(2);
    try expectSameHdu(p2, t2);
    try testing.expectEqual(HduKind.binary_table, t2.kind);
    try testing.expectEqual(@as(u64, 8 * 5), t2.data_bytes);

    // Key string keywords round-trip identically.
    const ttype1 = try t2.header.getString(alloc, "TTYPE1");
    defer alloc.free(ttype1);
    try testing.expectEqualStrings("COUNTS", ttype1);
    const tform2 = try t2.header.getString(alloc, "TFORM2");
    defer alloc.free(tform2);
    try testing.expectEqualStrings("E", tform2);
}

test "auto-indexing: NAXIS# yields NAXIS1/NAXIS2 within an HDU" {
    const alloc = testing.allocator;
    const template =
        \\SIMPLE  =                    T
        \\BITPIX  =                   16
        \\NAXIS   =                    2
        \\NAXIS#  =                    4
        \\NAXIS#  =                    3
    ;
    const mem = try newMem(alloc);
    defer freeMem(alloc, mem);
    {
        var f = try buildFromTemplate(alloc, mem.device(), template, .{});
        f.deinit();
    }

    var f = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const h = try f.select(1);
    try testing.expectEqual(@as(u16, 2), h.naxis);
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, h.axes); // NAXIS1=4, NAXIS2=3
    try testing.expectEqual(@as(i64, 4), try h.header.getValue(i64, "NAXIS1"));
    try testing.expectEqual(@as(i64, 3), try h.header.getValue(i64, "NAXIS2"));
    try testing.expectEqual(@as(u64, 2 * 4 * 3), h.data_bytes); // i16 → 2 bytes
}

test "auto-index counters are per-token and reset per HDU" {
    const alloc = testing.allocator;
    // Two separate auto-indexed tokens in HDU 2: TTYPE# and TFORM# count independently, and
    // NAXIS# resets from HDU 1.
    const template =
        \\SIMPLE  =                    T
        \\BITPIX  =                    8
        \\NAXIS   =                    1
        \\NAXIS#  =                    5
        \\END
        \\XTENSION= 'BINTABLE'
        \\BITPIX  =                    8
        \\NAXIS   =                    2
        \\NAXIS#  =                    6
        \\NAXIS#  =                    2
        \\PCOUNT  =                    0
        \\GCOUNT  =                    1
        \\TFIELDS =                    2
        \\TTYPE#  = 'A'
        \\TFORM#  = '1J'
        \\TTYPE#  = 'B'
        \\TFORM#  = '1E'
    ;
    const mem = try newMem(alloc);
    defer freeMem(alloc, mem);
    {
        var f = try buildFromTemplate(alloc, mem.device(), template, .{});
        f.deinit();
    }
    var f = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();

    const h1 = try f.select(1);
    try testing.expectEqualSlices(u64, &.{5}, h1.axes); // NAXIS1 reset to first index

    const h2 = try f.select(2);
    try testing.expectEqualSlices(u64, &.{ 6, 2 }, h2.axes); // NAXIS1=6, NAXIS2=2
    const tt1 = try h2.header.getString(alloc, "TTYPE1");
    defer alloc.free(tt1);
    try testing.expectEqualStrings("A", tt1);
    const tt2 = try h2.header.getString(alloc, "TTYPE2");
    defer alloc.free(tt2);
    try testing.expectEqualStrings("B", tt2);
    const tf2 = try h2.header.getString(alloc, "TFORM2");
    defer alloc.free(tf2);
    try testing.expectEqualStrings("1E", tf2);
}

test "free-form: optional '=' and unquoted string values" {
    const alloc = testing.allocator;
    const template =
        \\SIMPLE  =                    T
        \\BITPIX  8
        \\NAXIS   0
        \\END
        \\XTENSION BINTABLE
        \\BITPIX  =                    8
        \\NAXIS   =                    2
        \\NAXIS1  =                    8
        \\NAXIS2  =                    3
        \\PCOUNT  =                    0
        \\GCOUNT  =                    1
        \\TFIELDS =                    1
        \\TTYPE1   TIME
        \\TFORM1   1D
    ;
    const mem = try newMem(alloc);
    defer freeMem(alloc, mem);
    {
        var f = try buildFromTemplate(alloc, mem.device(), template, .{});
        f.deinit();
    }
    var f = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();

    const h1 = try f.select(1);
    try testing.expectEqual(HduKind.primary, h1.kind);
    try testing.expectEqual(@as(i64, 8), try h1.header.getValue(i64, "BITPIX"));

    const h2 = try f.select(2);
    try testing.expectEqual(HduKind.binary_table, h2.kind);
    const ttype1 = try h2.header.getString(alloc, "TTYPE1");
    defer alloc.free(ttype1);
    try testing.expectEqualStrings("TIME", ttype1); // unquoted token → string value
    const tform1 = try h2.header.getString(alloc, "TFORM1");
    defer alloc.free(tform1);
    try testing.expectEqualStrings("1D", tform1);
}

test "commentary keywords keep their free text" {
    const alloc = testing.allocator;
    const template =
        \\SIMPLE  =                    T
        \\BITPIX  =                    8
        \\NAXIS   =                    0
        \\COMMENT  built from a template
        \\HISTORY  step 1
    ;
    const mem = try newMem(alloc);
    defer freeMem(alloc, mem);
    {
        var f = try buildFromTemplate(alloc, mem.device(), template, .{});
        f.deinit();
    }
    var f = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const h = try f.select(1);

    var saw_comment = false;
    var saw_history = false;
    var i: usize = 0;
    while (i < h.header.count()) : (i += 1) {
        const card = h.header.at(i);
        if (card.kind != .commentary) continue;
        const txt = std.mem.trim(u8, card.commentaryText(), " ");
        if (std.mem.eql(u8, card.name.text(), "COMMENT") and std.mem.eql(u8, txt, "built from a template")) saw_comment = true;
        if (std.mem.eql(u8, card.name.text(), "HISTORY") and std.mem.eql(u8, txt, "step 1")) saw_history = true;
    }
    try testing.expect(saw_comment);
    try testing.expect(saw_history);
}

test "unsupported directive errors typed (and leaks nothing)" {
    const alloc = testing.allocator;
    const template =
        \\SIMPLE  =                    T
        \\BITPIX  =                    8
        \\NAXIS   =                    0
        \\\group GROUP_1
    ;
    const mem = try newMem(alloc);
    defer freeMem(alloc, mem);
    try testing.expectError(error.BadExtension, buildFromTemplate(alloc, mem.device(), template, .{}));
}

test "keyword before any HDU is a typed order error" {
    const alloc = testing.allocator;
    const template =
        \\BITPIX  =                    8
        \\NAXIS   =                    0
    ;
    const mem = try newMem(alloc);
    defer freeMem(alloc, mem);
    try testing.expectError(error.KeywordOrder, buildFromTemplate(alloc, mem.device(), template, .{}));
}

test "malformed keyword name is rejected" {
    const alloc = testing.allocator;
    const template =
        \\SIMPLE  =                    T
        \\BAD.KEY =                    1
    ;
    const mem = try newMem(alloc);
    defer freeMem(alloc, mem);
    try testing.expectError(error.BadKeywordName, buildFromTemplate(alloc, mem.device(), template, .{}));
}

test "a template missing a mandatory keyword surfaces a typed struct error" {
    const alloc = testing.allocator;
    // No BITPIX in the primary ⇒ appendHdu validation fails.
    const template =
        \\SIMPLE  =                    T
        \\NAXIS   =                    0
    ;
    const mem = try newMem(alloc);
    defer freeMem(alloc, mem);
    try testing.expectError(error.MissingRequiredKeyword, buildFromTemplate(alloc, mem.device(), template, .{}));
}

test "comments and CRLF line endings are tolerated" {
    const alloc = testing.allocator;
    const template = "# header template\r\nSIMPLE  = T\r\n/ a slash-comment line\r\nBITPIX  = 8\r\nNAXIS   = 0\r\n";
    const mem = try newMem(alloc);
    defer freeMem(alloc, mem);
    {
        var f = try buildFromTemplate(alloc, mem.device(), template, .{});
        f.deinit();
    }
    var f = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const h = try f.select(1);
    try testing.expectEqual(HduKind.primary, h.kind);
    try testing.expectEqual(@as(i64, 8), try h.header.getValue(i64, "BITPIX"));
    try testing.expectEqual(@as(u16, 0), h.naxis);
}
