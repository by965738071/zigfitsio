//! Binary-table column view: typed cell/column/element access over a `BINTABLE` HDU
//! (FR-BTB-1/2/3/4/5, FR-BTB-7, FR-CONV-1, FR-UTL-4; design §13.1–§13.4; FITS 4.0 §7.3).
//!
//! A `BinTable` parses `TFORMn`/`TTYPEn`/`TSCALn`/`TZEROn`/`TNULLn`/`TDIMn` once in `of`,
//! computes each column's byte offset within a row, and then presents columnar read/write
//! access. Every numeric crossing goes through `convert.cast` (single-cell `.scalar`, whole
//! column `.bulk`, per FR-CONV-1) and every multi-byte wire value through `endian` (FITS is
//! big-endian on disk, GC-5).
//!
//! Type-code handling (FR-BTB-2):
//!   - `L` logical: `'T'`/`'F'` (and `0` ⇒ null) bytes ↔ `bool`/numeric 0/1.
//!   - `X` bit: packed MSB-first into `ceil(r/8)` bytes ↔ one element per bit.
//!   - `B I J K` integers, `E D` floats, `C M` complex (each complex value is two consecutive
//!     real/imaginary scalar slots in the caller's buffer).
//!   - `A` char: decode terminates at the first NUL, encode pads with spaces; a leading NUL is
//!     a null string (FR-BTB-7). The non-standard `rAw` substring shorthand is out of scope.
//!   - `P`/`Q` descriptors are parsed into a column but following them into the heap is phase 2
//!     (VLA-1/`heap.zig`); access on such a column returns `error.BadDescriptor`.
//!
//! Scaling/nulls (FR-BTB-4): physical = `TZERO + TSCAL × stored`. When `TSCAL == 1` and
//! `TZERO` is integral, the offset is applied in integer (`i128`) space so the CFITSIO
//! unsigned/signed conventions (`u16`/`u32`/`u64`/`i8` over `I`/`J`/`K`/`B` + `TZERO`) carry no
//! `f64` precision loss near `2^63`. Integer `TNULLn` and IEEE-NaN floating nulls are honored.
const std = @import("std");
const errors = @import("../errors.zig");
const convert = @import("../convert.zig");
const endian = @import("../endian.zig");
const limits = @import("../limits.zig");
const Fits = @import("../fits.zig").Fits;
const Hdu = @import("../hdu.zig").Hdu;
const Device = @import("../io/device.zig").Device;
const common = @import("common.zig");
const BinTform = common.BinTform;
const BinaryType = common.BinaryType;
const name_mod = @import("../header/name.zig");
const Matches = name_mod.Matches;
const matchWildcard = name_mod.matchWildcard;

const Allocator = std.mem.Allocator;
const Mode = convert.Mode;

/// A reference to a column either by 0-based position or by (wildcard-capable) name.
pub const ColumnRef = union(enum) {
    /// 0-based column index.
    index: u16,
    /// Column name (matched against `TTYPEn`, case-insensitive, `*`/`?`/`#` wildcards).
    name: []const u8,
};

/// Per-call read options, element-typed so a null sentinel cannot mismatch the read type.
pub fn ReadOpts(comptime T: type) type {
    return struct {
        /// Substitute this value for a stored `TNULLn` (integer) or IEEE-NaN (float) null.
        /// When `null`, the raw (converted) value is returned unchanged.
        null_sentinel: ?T = null,
    };
}

/// Per-call write options (symmetric with `ReadOpts`).
pub fn WriteOpts(comptime T: type) type {
    return struct {
        /// When an input element equals this sentinel, write the column's `TNULLn` (integer
        /// columns) or an IEEE-NaN (float columns) to mark the cell null.
        null_sentinel: ?T = null,
    };
}

/// One parsed binary-table column: its identity, `TFORM`, byte position within a row, and the
/// scaling/null/shape metadata.
pub const Column = struct {
    /// 0-based column position.
    index: u16,
    /// Owned, blank-trimmed `TTYPEn` name, or `null` when the column is unnamed.
    name: ?[]u8,
    /// Parsed `TFORMn`.
    tform: BinTform,
    /// Byte offset of this field from the start of a row.
    byte_offset: u64,
    /// `TSCALn` (default 1).
    scal: f64 = 1,
    /// `TZEROn` (default 0).
    zero: f64 = 0,
    /// `TZEROn` as an exact integer when `TSCALn == 1` and `TZEROn` is integral (enables the
    /// precision-safe integer-space offset path); `null` otherwise.
    zero_int: ?i128 = null,
    /// `TNULLn` integer null sentinel (raw, pre-scale), or `null`.
    tnull: ?i64 = null,
    /// Owned `TDIMn` shape (most-rapidly-varying first), or `null`. Product ≤ `tform.repeat`.
    tdim: ?[]u64 = null,
};

/// Error set for parsing a `BinTable` from an HDU.
pub const OpenError = errors.TableError || errors.StructError || errors.IoError ||
    errors.ConvError || errors.ValueError || errors.HeaderError || errors.LimitError ||
    Allocator.Error;

/// Error set for cell/column read and write operations.
pub const AccessError = errors.TableError || errors.IoError || errors.ConvError ||
    errors.LimitError;

/// A typed view over a `BINTABLE` HDU's data array.
pub const BinTable = struct {
    /// The owning file handle (provides the device and allocator).
    fits: *Fits,
    /// The underlying binary-table HDU.
    hdu: *Hdu,
    /// Owned, ordered column descriptors (length == `TFIELDS`).
    columns: []Column,
    /// `NAXIS1`: row byte width.
    naxis1: u64,
    /// `NAXIS2`: number of rows.
    naxis2: u64,

    /// Build a view over a `BINTABLE` HDU: validate the kind, parse every column's
    /// `TFORMn`/`TTYPEn`/`TSCALn`/`TZEROn`/`TNULLn`/`TDIMn`, compute byte offsets, and check
    /// that `NAXIS1` equals the sum of the field widths. `error.WrongHduType` for a non-table
    /// HDU; `error.BadDimensions` when the field widths do not sum to `NAXIS1`.
    pub fn of(fits: *Fits, hdu: *Hdu) OpenError!BinTable {
        if (hdu.kind != .binary_table) return error.WrongHduType;
        if (hdu.naxis < 2) return error.BadDimensions;
        const parsed = try parseColumns(fits, hdu);
        return .{
            .fits = fits,
            .hdu = hdu,
            .columns = parsed.columns,
            .naxis1 = parsed.naxis1,
            .naxis2 = parsed.naxis2,
        };
    }

    /// Release the owned column descriptors.
    pub fn deinit(self: *BinTable, alloc: Allocator) void {
        for (self.columns) |*c| freeColumn(alloc, c);
        alloc.free(self.columns);
    }

    /// Number of rows (`NAXIS2`).
    pub fn rowCount(self: *const BinTable) u64 {
        return self.naxis2;
    }

    /// Number of columns (`TFIELDS`).
    pub fn columnCount(self: *const BinTable) u16 {
        return @intCast(self.columns.len);
    }

    /// Fill `out` with the 0-based indices of every column whose `TTYPEn` matches the wildcard
    /// `pat` (case-insensitive, `*`/`?`/`#`), preserving column order (FR-UTL-4). Unnamed
    /// columns never match. `out` is reset first; `out.overflow` flags truncation.
    pub fn columnByName(self: *const BinTable, pat: []const u8, out: *Matches) void {
        out.reset();
        for (self.columns, 0..) |*c, i| {
            if (c.name) |nm| {
                if (matchWildcard(pat, nm)) out.add(@intCast(i));
            }
        }
    }

    /// Resolve a `ColumnRef` to a 0-based column index. By index: `error.NoSuchColumn` when out
    /// of range. By name (FR-UTL-4 contract): zero matches ⇒ `error.NoSuchColumn`, one ⇒ that
    /// column, many ⇒ `error.AmbiguousColumn`.
    pub fn resolve(self: *const BinTable, col: ColumnRef) errors.TableError!u16 {
        switch (col) {
            .index => |idx| {
                if (idx >= self.columns.len) return error.NoSuchColumn;
                return idx;
            },
            .name => |nm| {
                var m: Matches = .{};
                self.columnByName(nm, &m);
                if (m.len == 0) return error.NoSuchColumn;
                if (m.len > 1) return error.AmbiguousColumn;
                return @intCast(m.at(0));
            },
        }
    }

    /// Read `out.len / cellSlots` consecutive rows of `col` starting at `first_row`, converting
    /// each stored value to `T` under the **bulk** policy (precision-losing widening is silent,
    /// FR-CONV-1). `out.len` must be a whole multiple of the per-row element count (`repeat`,
    /// or `2×repeat` for complex; bytes for `A`; bits for `X`).
    pub fn readColumn(self: *BinTable, comptime T: type, col: ColumnRef, first_row: u64, out: []T, opts: ReadOpts(T)) AccessError!void {
        const column = &self.columns[try self.resolve(col)];
        if (column.tform.type.isVla()) return error.BadDescriptor;
        const slots = cellSlots(column);
        if (slots == 0) {
            if (out.len != 0) return error.CellOutOfRange;
            if (first_row > self.naxis2) return error.RowOutOfRange;
            return;
        }
        const sl: usize = @intCast(slots);
        if (out.len % sl != 0) return error.CellOutOfRange;
        const nrows: u64 = out.len / sl;
        const last = std.math.add(u64, first_row, nrows) catch return error.RowOutOfRange;
        if (last > self.naxis2) return error.RowOutOfRange;
        var r: u64 = 0;
        while (r < nrows) : (r += 1) {
            const base: usize = @intCast(r * slots);
            try self.readCellInto(T, column, first_row + r, out[base..][0..sl], .bulk, opts);
        }
    }

    /// Read the single cell at (`row`, `col`) into `out` under the **scalar** policy (precision
    /// loss is `error.PrecisionLoss`, FR-CONV-1). `out.len` must equal the cell element count.
    pub fn readCell(self: *BinTable, comptime T: type, col: ColumnRef, row: u64, out: []T, opts: ReadOpts(T)) AccessError!void {
        const column = &self.columns[try self.resolve(col)];
        if (column.tform.type.isVla()) return error.BadDescriptor;
        if (out.len != cellSlots(column)) return error.CellOutOfRange;
        if (row >= self.naxis2) return error.RowOutOfRange;
        try self.readCellInto(T, column, row, out, .scalar, opts);
    }

    /// Write `in.len / cellSlots` consecutive rows of `col` starting at `first_row`, converting
    /// each `T` to the stored type under the **bulk** policy. `error.NotWritable` on a
    /// read-only handle.
    pub fn writeColumn(self: *BinTable, comptime T: type, col: ColumnRef, first_row: u64, in: []const T, opts: WriteOpts(T)) AccessError!void {
        if (self.fits.mode == .read_only or !self.fits.dev.isWritable()) return error.NotWritable;
        const column = &self.columns[try self.resolve(col)];
        if (column.tform.type.isVla()) return error.BadDescriptor;
        const slots = cellSlots(column);
        if (slots == 0) {
            if (in.len != 0) return error.CellOutOfRange;
            if (first_row > self.naxis2) return error.RowOutOfRange;
            return;
        }
        const sl: usize = @intCast(slots);
        if (in.len % sl != 0) return error.CellOutOfRange;
        const nrows: u64 = in.len / sl;
        const last = std.math.add(u64, first_row, nrows) catch return error.RowOutOfRange;
        if (last > self.naxis2) return error.RowOutOfRange;
        var r: u64 = 0;
        while (r < nrows) : (r += 1) {
            const base: usize = @intCast(r * slots);
            try self.writeCellInto(T, column, first_row + r, in[base..][0..sl], .bulk, opts);
        }
    }

    /// Write the single cell at (`row`, `col`) from `in` under the **scalar** policy.
    /// `in.len` must equal the cell element count. `error.NotWritable` on a read-only handle.
    pub fn writeCell(self: *BinTable, comptime T: type, col: ColumnRef, row: u64, in: []const T, opts: WriteOpts(T)) AccessError!void {
        if (self.fits.mode == .read_only or !self.fits.dev.isWritable()) return error.NotWritable;
        const column = &self.columns[try self.resolve(col)];
        if (column.tform.type.isVla()) return error.BadDescriptor;
        if (in.len != cellSlots(column)) return error.CellOutOfRange;
        if (row >= self.naxis2) return error.RowOutOfRange;
        try self.writeCellInto(T, column, row, in, .scalar, opts);
    }

    // ── BTB-3b: structural row & column editing (FR-BTB-6; design §13.5; FITS 4.0 §7.3) ──────
    //
    // Every size-changing edit goes through the Phase-1 `Fits` primitives
    // (`resizeHduData`/`rewriteHeaderInPlace`) so the surrounding HDUs stay byte-correct and
    // 2880-aligned (§3.1). The binary-table data unit is the row matrix `[data_off,
    // data_off + NAXIS1×NAXIS2)` followed by the `PCOUNT`-byte heap (§7.3.5); whenever the row
    // matrix changes size the heap region is physically relocated so it keeps trailing the rows.
    // After any edit the internal column model is re-parsed (`reparse`) so later reads see the
    // new geometry. `THEAP`-offset heaps (a non-default heap gap) are not supported here — the
    // heap is assumed to immediately follow the row matrix, as in every conforming writer.

    /// Append `n` empty (zero-filled) rows at the end of the table, growing the data unit by
    /// `n×NAXIS1` and relocating the heap. `NAXIS2` is updated; `NAXIS1`/`TFIELDS` are unchanged.
    pub fn appendRows(self: *BinTable, n: u64) OpenError!void {
        try self.insertRows(self.naxis2, n);
    }

    /// Insert `n` empty (zero-filled) rows so that the first new row has index `before_row`
    /// (0-based); existing rows at and after `before_row` shift up by `n`. `before_row` may equal
    /// the current row count (append). `error.RowOutOfRange` otherwise.
    pub fn insertRows(self: *BinTable, before_row: u64, n: u64) OpenError!void {
        try self.requireWritable();
        if (before_row > self.naxis2) return error.RowOutOfRange;
        if (n == 0) return;
        const naxis1 = self.naxis1;
        const old_rows = try limits.mul(naxis1, self.naxis2);
        const new_naxis2 = try limits.add(self.naxis2, n);
        const new_rows = try limits.mul(naxis1, new_naxis2);
        const pcount = self.hdu.pcount;
        const new_total = try limits.add(new_rows, pcount);
        const data_off = self.hdu.data_off;

        // Grow the data unit first (preserves the old rows+heap, zeroes the new tail), then move
        // the heap clear of the new rows region, shift the trailing rows up, and zero the gap.
        try self.fits.resizeHduData(self.hdu, new_total);
        if (pcount > 0) try moveRegion(self.fits.dev, data_off + old_rows, data_off + new_rows, pcount);
        const tail_bytes = try limits.mul(self.naxis2 - before_row, naxis1);
        const ins_off = try limits.mul(before_row, naxis1);
        const ins_bytes = try limits.mul(n, naxis1);
        try moveRegion(self.fits.dev, data_off + ins_off, data_off + ins_off + ins_bytes, tail_bytes);
        try zeroBytes(self.fits.dev, data_off + ins_off, ins_bytes);

        try self.hdu.header.modify("NAXIS2", .{ .int = @intCast(new_naxis2) }, null);
        try self.fits.rewriteHeaderInPlace(self.hdu);
        try self.reparse();
    }

    /// Delete `n` rows starting at `first_row` (0-based); trailing rows shift down and the data
    /// unit shrinks by `n×NAXIS1`. `error.RowOutOfRange` if the range is out of bounds.
    pub fn deleteRows(self: *BinTable, first_row: u64, n: u64) OpenError!void {
        try self.requireWritable();
        if (n == 0) return;
        const end = std.math.add(u64, first_row, n) catch return error.RowOutOfRange;
        if (end > self.naxis2) return error.RowOutOfRange;
        const naxis1 = self.naxis1;
        const old_rows = try limits.mul(naxis1, self.naxis2);
        const new_naxis2 = self.naxis2 - n;
        const new_rows = try limits.mul(naxis1, new_naxis2);
        const pcount = self.hdu.pcount;
        const new_total = try limits.add(new_rows, pcount);
        const data_off = self.hdu.data_off;

        // Shift the trailing rows down over the deleted span, slide the heap down to follow, then
        // shrink the data unit (which truncates and zeroes the now-unused tail).
        const tail_bytes = try limits.mul(self.naxis2 - end, naxis1);
        const del_off = try limits.mul(first_row, naxis1);
        const src_off = try limits.mul(end, naxis1);
        try moveRegion(self.fits.dev, data_off + src_off, data_off + del_off, tail_bytes);
        if (pcount > 0) try moveRegion(self.fits.dev, data_off + old_rows, data_off + new_rows, pcount);
        try self.fits.resizeHduData(self.hdu, new_total);

        try self.hdu.header.modify("NAXIS2", .{ .int = @intCast(new_naxis2) }, null);
        try self.fits.rewriteHeaderInPlace(self.hdu);
        try self.reparse();
    }

    /// Copy `n` rows starting at `src_first` over the `n` rows starting at `dest_first` (both
    /// 0-based, in the same table). The row count is unchanged; the byte ranges may overlap.
    /// `error.RowOutOfRange` if either range is out of bounds.
    pub fn copyRows(self: *BinTable, src_first: u64, n: u64, dest_first: u64) OpenError!void {
        try self.requireWritable();
        if (n == 0) return;
        const src_end = std.math.add(u64, src_first, n) catch return error.RowOutOfRange;
        const dest_end = std.math.add(u64, dest_first, n) catch return error.RowOutOfRange;
        if (src_end > self.naxis2 or dest_end > self.naxis2) return error.RowOutOfRange;
        if (src_first == dest_first) return;
        const naxis1 = self.naxis1;
        const data_off = self.hdu.data_off;
        const len = try limits.mul(n, naxis1);
        const so = try limits.add(data_off, try limits.mul(src_first, naxis1));
        const dofst = try limits.add(data_off, try limits.mul(dest_first, naxis1));
        try moveRegion(self.fits.dev, so, dofst, len);
    }

    /// Append a new column described by `tform` (and optional `ttype` name) after the last
    /// column. Every row is re-strided to the wider `NAXIS1` (the new cells are zero-filled),
    /// `TFIELDS`/`NAXIS1` are bumped, and the heap is relocated. Returns the new column's
    /// 0-based index.
    pub fn appendColumn(self: *BinTable, alloc: Allocator, tform: []const u8, ttype: ?[]const u8) OpenError!u16 {
        const at: u16 = @intCast(self.columns.len);
        try self.insertColumn(alloc, at, tform, ttype);
        return at;
    }

    /// Insert a new column described by `tform` (and optional `ttype`) at 0-based position `at`;
    /// existing columns at and after `at` shift up by one (their `TFORMn`/`TTYPEn`/`TUNITn`/
    /// `TSCALn`/`TZEROn`/`TNULLn`/`TDISPn`/`TDIMn` keywords are renumbered). Every row is
    /// re-strided to the wider layout with the new cell zero-filled. `error.NoSuchColumn` if
    /// `at` exceeds the current column count.
    pub fn insertColumn(self: *BinTable, alloc: Allocator, at: u16, tform: []const u8, ttype: ?[]const u8) OpenError!void {
        try self.requireWritable();
        if (at > self.columns.len) return error.NoSuchColumn;
        const parsed = try BinTform.parse(tform);
        const field_bytes = try parsed.fieldBytes();
        const old_naxis1 = self.naxis1;
        const new_naxis1 = try limits.add(old_naxis1, field_bytes);
        const ins_off: u64 = if (at < self.columns.len) self.columns[at].byte_offset else old_naxis1;

        // Re-stride: keep [0,ins_off), drop in the zeroed new field, keep the rest of the row.
        const segs = [_]Seg{
            .{ .copy = .{ .off = 0, .len = ins_off } },
            .{ .zero = field_bytes },
            .{ .copy = .{ .off = ins_off, .len = old_naxis1 - ins_off } },
        };
        try self.applyGrow(alloc, old_naxis1, new_naxis1, &segs);

        // Header: renumber the higher columns up, then add the new column's keywords.
        const tfields: usize = self.columns.len;
        try self.renumberColumns(at + 1, tfields, .up);
        var buf: [16]u8 = undefined;
        try self.hdu.header.update(self.fits.alloc, kwName(&buf, "TFORM", at + 1), .{ .string = tform }, null);
        if (ttype) |t| try self.hdu.header.update(self.fits.alloc, kwName(&buf, "TTYPE", at + 1), .{ .string = t }, null);
        try self.hdu.header.modify("TFIELDS", .{ .int = @intCast(tfields + 1) }, null);
        try self.hdu.header.modify("NAXIS1", .{ .int = @intCast(new_naxis1) }, null);

        try self.fits.rewriteHeaderInPlace(self.hdu);
        try self.reparse();
    }

    /// Delete column `col` (0-based): its per-column keywords are removed, the higher columns are
    /// renumbered down, every row is re-strided to the narrower `NAXIS1`, and the heap is
    /// relocated. `error.NoSuchColumn` if `col` is out of range.
    pub fn deleteColumn(self: *BinTable, col: u16) OpenError!void {
        try self.requireWritable();
        if (col >= self.columns.len) return error.NoSuchColumn;
        const del_off = self.columns[col].byte_offset;
        const del_width = try self.columns[col].tform.fieldBytes();
        const old_naxis1 = self.naxis1;
        const new_naxis1 = old_naxis1 - del_width;

        const segs = [_]Seg{
            .{ .copy = .{ .off = 0, .len = del_off } },
            .{ .copy = .{ .off = del_off + del_width, .len = old_naxis1 - (del_off + del_width) } },
        };
        try self.applyShrink(self.fits.alloc, old_naxis1, new_naxis1, &segs);

        const tfields: usize = self.columns.len;
        try self.deleteColumnKeywords(col + 1);
        try self.renumberColumns(col + 2, tfields, .down);
        try self.hdu.header.modify("TFIELDS", .{ .int = @intCast(tfields - 1) }, null);
        try self.hdu.header.modify("NAXIS1", .{ .int = @intCast(new_naxis1) }, null);

        try self.fits.rewriteHeaderInPlace(self.hdu);
        try self.reparse();
    }

    /// Copy the stored bytes of column `src` over column `dest` (both 0-based) for every row, as
    /// a raw per-cell byte copy (no scaling). The two columns must have equal field byte widths
    /// (`error.BadTform` otherwise). `error.NoSuchColumn` if either index is out of range.
    pub fn copyColumn(self: *BinTable, src: u16, dest: u16) OpenError!void {
        try self.requireWritable();
        if (src >= self.columns.len or dest >= self.columns.len) return error.NoSuchColumn;
        if (src == dest) return;
        const cs = &self.columns[src];
        const cd = &self.columns[dest];
        const ws = try cs.tform.fieldBytes();
        const wd = try cd.tform.fieldBytes();
        if (ws != wd) return error.BadTform;
        const data_off = self.hdu.data_off;
        var r: u64 = 0;
        while (r < self.naxis2) : (r += 1) {
            const row_base = try limits.add(data_off, try limits.mul(r, self.naxis1));
            try moveRegion(self.fits.dev, row_base + cs.byte_offset, row_base + cd.byte_offset, ws);
        }
    }

    // ── editing internals ────────────────────────────────────────────────────────────────────

    fn requireWritable(self: *const BinTable) errors.IoError!void {
        if (self.fits.mode == .read_only or !self.fits.dev.isWritable()) return error.NotWritable;
    }

    // Grow each row from `old_naxis1` to a wider `new_naxis1`: resize the data unit, slide the
    // heap up clear of the larger row matrix, then re-stride the rows back-to-front via `segs`.
    fn applyGrow(self: *BinTable, alloc: Allocator, old_naxis1: u64, new_naxis1: u64, segs: []const Seg) OpenError!void {
        const nrows = self.naxis2;
        const pcount = self.hdu.pcount;
        const old_rows = try limits.mul(old_naxis1, nrows);
        const new_rows = try limits.mul(new_naxis1, nrows);
        const new_total = try limits.add(new_rows, pcount);
        try self.fits.resizeHduData(self.hdu, new_total);
        const data_off = self.hdu.data_off;
        if (pcount > 0) try moveRegion(self.fits.dev, data_off + old_rows, data_off + new_rows, pcount);
        try restrideRows(alloc, self.fits.dev, data_off, nrows, old_naxis1, new_naxis1, segs);
    }

    // Shrink each row from `old_naxis1` to a narrower `new_naxis1`: re-stride the rows
    // front-to-back via `segs`, slide the heap down to follow, then shrink the data unit.
    fn applyShrink(self: *BinTable, alloc: Allocator, old_naxis1: u64, new_naxis1: u64, segs: []const Seg) OpenError!void {
        const nrows = self.naxis2;
        const pcount = self.hdu.pcount;
        const old_rows = try limits.mul(old_naxis1, nrows);
        const new_rows = try limits.mul(new_naxis1, nrows);
        const new_total = try limits.add(new_rows, pcount);
        const data_off = self.hdu.data_off;
        try restrideRows(alloc, self.fits.dev, data_off, nrows, old_naxis1, new_naxis1, segs);
        if (pcount > 0) try moveRegion(self.fits.dev, data_off + old_rows, data_off + new_rows, pcount);
        try self.fits.resizeHduData(self.hdu, new_total);
    }

    const RenumberDir = enum { up, down };

    // Renumber the per-column keywords for old 1-based indices `[from, to]` inclusive: `.up`
    // shifts each index `k` to `k+1` (processed high→low to avoid collisions), `.down` shifts
    // `k` to `k-1` (processed low→high). Missing keywords are skipped.
    fn renumberColumns(self: *BinTable, from: usize, to: usize, dir: RenumberDir) OpenError!void {
        if (from > to) return;
        switch (dir) {
            .up => {
                var k = to;
                while (k >= from) {
                    try self.renameColumnIndex(k, k + 1);
                    if (k == from) break;
                    k -= 1;
                }
            },
            .down => {
                var k = from;
                while (k <= to) : (k += 1) try self.renameColumnIndex(k, k - 1);
            },
        }
    }

    fn renameColumnIndex(self: *BinTable, old_n: usize, new_n: usize) OpenError!void {
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        for (COL_KW) |prefix| {
            const old_kw = kwNameRt(&b1, prefix, old_n);
            const new_kw = kwNameRt(&b2, prefix, new_n);
            self.hdu.header.rename(old_kw, new_kw) catch |e| switch (e) {
                error.KeywordNotFound => {},
                else => return e,
            };
        }
    }

    fn deleteColumnKeywords(self: *BinTable, n: usize) OpenError!void {
        var buf: [16]u8 = undefined;
        for (COL_KW) |prefix| {
            self.hdu.header.delete(kwNameRt(&buf, prefix, n)) catch |e| switch (e) {
                error.KeywordNotFound => {},
                else => return e,
            };
        }
    }

    // Re-parse the column model from the (now-edited) header so subsequent reads are correct.
    fn reparse(self: *BinTable) OpenError!void {
        const parsed = try parseColumns(self.fits, self.hdu);
        for (self.columns) |*c| freeColumn(self.fits.alloc, c);
        self.fits.alloc.free(self.columns);
        self.columns = parsed.columns;
        self.naxis1 = parsed.naxis1;
        self.naxis2 = parsed.naxis2;
    }

    // ── internals ──────────────────────────────────────────────────────────────────────────

    fn cellOffset(self: *const BinTable, column: *const Column, row: u64) errors.LimitError!u64 {
        const row_off = try limits.mul(row, self.naxis1);
        const base = try limits.add(self.hdu.data_off, row_off);
        return limits.add(base, column.byte_offset);
    }

    fn readCellInto(self: *BinTable, comptime T: type, column: *const Column, row: u64, out: []T, mode: Mode, opts: ReadOpts(T)) AccessError!void {
        const off = try self.cellOffset(column, row);
        const dev = self.fits.dev;
        switch (column.tform.type) {
            .logical => try readLogical(T, dev, off, out, mode, opts),
            .bit => try readBits(T, dev, off, out, mode),
            .char => try readChars(T, dev, off, out, mode, column),
            .byte => try readRun(u8, T, dev, off, out, column, mode, opts),
            .int16 => try readRun(i16, T, dev, off, out, column, mode, opts),
            .int32 => try readRun(i32, T, dev, off, out, column, mode, opts),
            .int64 => try readRun(i64, T, dev, off, out, column, mode, opts),
            .float32 => try readRun(f32, T, dev, off, out, column, mode, opts),
            .float64 => try readRun(f64, T, dev, off, out, column, mode, opts),
            .complex32 => try readRun(f32, T, dev, off, out, column, mode, opts),
            .complex64 => try readRun(f64, T, dev, off, out, column, mode, opts),
            .vla32, .vla64 => return error.BadDescriptor,
        }
    }

    fn writeCellInto(self: *BinTable, comptime T: type, column: *const Column, row: u64, in: []const T, mode: Mode, opts: WriteOpts(T)) AccessError!void {
        const off = try self.cellOffset(column, row);
        const dev = self.fits.dev;
        switch (column.tform.type) {
            .logical => try writeLogical(T, dev, off, in, opts),
            .bit => try writeBits(T, dev, off, in),
            .char => try writeChars(T, dev, off, in, column),
            .byte => try writeRun(u8, T, dev, off, in, column, mode, opts),
            .int16 => try writeRun(i16, T, dev, off, in, column, mode, opts),
            .int32 => try writeRun(i32, T, dev, off, in, column, mode, opts),
            .int64 => try writeRun(i64, T, dev, off, in, column, mode, opts),
            .float32 => try writeRun(f32, T, dev, off, in, column, mode, opts),
            .float64 => try writeRun(f64, T, dev, off, in, column, mode, opts),
            .complex32 => try writeRun(f32, T, dev, off, in, column, mode, opts),
            .complex64 => try writeRun(f64, T, dev, off, in, column, mode, opts),
            .vla32, .vla64 => return error.BadDescriptor,
        }
    }
};

/// Per-row element count of a column in caller-buffer slots: `repeat` for scalar/`A`/`X`
/// (one slot per byte / per bit), `2×repeat` for complex (real, imaginary).
fn cellSlots(column: *const Column) u64 {
    const r = column.tform.repeat;
    return switch (column.tform.type) {
        .complex32, .complex64 => 2 * r,
        else => r,
    };
}

fn freeColumn(alloc: Allocator, c: *Column) void {
    if (c.name) |nm| alloc.free(nm);
    if (c.tdim) |td| alloc.free(td);
}

fn kwName(buf: []u8, comptime prefix: []const u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "{d}", .{n}) catch unreachable;
}

// Runtime-prefix variant of `kwName` (the prefix is not comptime-known).
fn kwNameRt(buf: []u8, prefix: []const u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ prefix, n }) catch unreachable;
}

// The per-column keyword prefixes renumbered/removed by the column-structure operations
// (FITS 4.0 §7.3.2). `TBCOL` is ASCII-only and absent here, so it is intentionally excluded.
const COL_KW = [_][]const u8{ "TFORM", "TTYPE", "TUNIT", "TSCAL", "TZERO", "TNULL", "TDISP", "TDIM" };

// One piece of a re-strided row: either a verbatim copy from the old row or a zero-fill run.
const Seg = union(enum) {
    copy: struct { off: u64, len: u64 },
    zero: u64,
};

// Bounded staging buffer for raw byte moves and zero-fills within the data unit (NFR-PERF-3).
const MOVE_CHUNK: usize = 64 * 1024;

// Parse every column of a `BINTABLE` HDU's CURRENT header into an owned slice and report
// `NAXIS1`/`NAXIS2`. Shared by `of` (initial open) and `reparse` (after a structural edit).
fn parseColumns(fits: *Fits, hdu: *Hdu) OpenError!struct { columns: []Column, naxis1: u64, naxis2: u64 } {
    const naxis1 = hdu.axes[0];
    const naxis2 = hdu.axes[1];

    const alloc = fits.alloc;
    const tfields = try hdu.header.getValue(u16, "TFIELDS");

    var columns: std.ArrayList(Column) = .empty;
    errdefer {
        for (columns.items) |*c| freeColumn(alloc, c);
        columns.deinit(alloc);
    }

    var off: u64 = 0;
    var name_buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < tfields) : (i += 1) {
        const n = i + 1;

        const tform_str = try hdu.header.getString(alloc, kwName(&name_buf, "TFORM", n));
        const tform = blk: {
            defer alloc.free(tform_str);
            break :blk try BinTform.parse(tform_str);
        };

        var col_name: ?[]u8 = null;
        errdefer if (col_name) |nm| alloc.free(nm);
        const ttype_kw = kwName(&name_buf, "TTYPE", n);
        if (hdu.header.has(ttype_kw)) {
            col_name = hdu.header.getString(alloc, ttype_kw) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null, // a non-string TTYPE just leaves the column unnamed
            };
        }

        var tdim: ?[]u64 = null;
        errdefer if (tdim) |td| alloc.free(td);
        const tdim_kw = kwName(&name_buf, "TDIM", n);
        if (hdu.header.has(tdim_kw)) {
            const ds = hdu.header.getString(alloc, tdim_kw) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (ds) |s| {
                defer alloc.free(s);
                // VLA columns: TDIM shapes the heap array, so the product<=repeat bound is skipped.
                const bound: ?u64 = if (tform.type.isVla()) null else tform.repeat;
                tdim = try parseTdim(alloc, s, bound);
            }
        }

        const scal = hdu.header.getValue(f64, kwName(&name_buf, "TSCAL", n)) catch 1.0;
        const zero = hdu.header.getValue(f64, kwName(&name_buf, "TZERO", n)) catch 0.0;
        const tnull = hdu.header.getValue(i64, kwName(&name_buf, "TNULL", n)) catch null;

        const zint: ?i128 = blk: {
            if (scal != 1.0) break :blk null;
            if (zero != @trunc(zero)) break :blk null;
            if (zero < -1.0e30 or zero > 1.0e30) break :blk null;
            break :blk @as(i128, @intFromFloat(zero));
        };

        const field_bytes = try tform.fieldBytes();
        const byte_offset = off;
        off = try limits.add(off, field_bytes);

        try columns.append(alloc, .{
            .index = @intCast(i),
            .name = col_name,
            .tform = tform,
            .byte_offset = byte_offset,
            .scal = scal,
            .zero = zero,
            .zero_int = zint,
            .tnull = tnull,
            .tdim = tdim,
        });
        // Ownership of col_name/tdim has transferred into `columns`; disarm the loop errdefers
        // by clearing the locals so a later failure frees them via `columns`.
        col_name = null;
        tdim = null;
    }

    if (off != naxis1) return error.BadDimensions;

    const cols = try columns.toOwnedSlice(alloc);
    return .{ .columns = cols, .naxis1 = naxis1, .naxis2 = naxis2 };
}

// Move `len` bytes from `src` to `dst` on `dev`, overlap-safe: a forward move (dst > src) copies
// back-to-front, a backward move copies front-to-back, so the source is never clobbered early.
fn moveRegion(dev: Device, src: u64, dst: u64, len: u64) errors.IoError!void {
    if (len == 0 or src == dst) return;
    var buf: [MOVE_CHUNK]u8 = undefined;
    if (dst > src) {
        var remaining = len;
        while (remaining > 0) {
            const m: usize = @intCast(@min(@as(u64, buf.len), remaining));
            const o = remaining - m;
            try dev.readAll(buf[0..m], src + o);
            try dev.writeAll(buf[0..m], dst + o);
            remaining -= m;
        }
    } else {
        var done: u64 = 0;
        while (done < len) {
            const m: usize = @intCast(@min(@as(u64, buf.len), len - done));
            try dev.readAll(buf[0..m], src + done);
            try dev.writeAll(buf[0..m], dst + done);
            done += m;
        }
    }
}

// Zero exactly `len` bytes at `off` on `dev`, in bounded chunks.
fn zeroBytes(dev: Device, off: u64, len: u64) errors.IoError!void {
    if (len == 0) return;
    var buf: [MOVE_CHUNK]u8 = [_]u8{0} ** MOVE_CHUNK;
    var remaining = len;
    var o = off;
    while (remaining > 0) {
        const m: usize = @intCast(@min(@as(u64, buf.len), remaining));
        try dev.writeAll(buf[0..m], o);
        o += m;
        remaining -= m;
    }
}

// Re-stride every row from `old_stride` to `new_stride` by rebuilding each row from `segs`
// (`copy` ranges reference the old row; `zero` runs are new fill). Rows are processed
// back-to-front when growing and front-to-back when shrinking so an in-place stride change never
// overwrites a not-yet-moved row. One old/new row buffer is allocated for the whole pass.
fn restrideRows(alloc: Allocator, dev: Device, data_off: u64, nrows: u64, old_stride: u64, new_stride: u64, segs: []const Seg) (errors.IoError || Allocator.Error)!void {
    if (nrows == 0) return;
    const oldbuf = try alloc.alloc(u8, @intCast(old_stride));
    defer alloc.free(oldbuf);
    const newbuf = try alloc.alloc(u8, @intCast(new_stride));
    defer alloc.free(newbuf);
    const growing = new_stride > old_stride;
    var idx: u64 = 0;
    while (idx < nrows) : (idx += 1) {
        const row = if (growing) nrows - 1 - idx else idx;
        if (oldbuf.len > 0) try dev.readAll(oldbuf, data_off + row * old_stride);
        var pos: usize = 0;
        for (segs) |s| switch (s) {
            .copy => |c| {
                const l: usize = @intCast(c.len);
                @memcpy(newbuf[pos..][0..l], oldbuf[@as(usize, @intCast(c.off))..][0..l]);
                pos += l;
            },
            .zero => |z| {
                const l: usize = @intCast(z);
                @memset(newbuf[pos..][0..l], 0);
                pos += l;
            },
        };
        if (newbuf.len > 0) try dev.writeAll(newbuf, data_off + row * new_stride);
    }
}

/// Parse a `TDIMn` value `"(a,b,…)"` into an owned shape. When `bound` is non-null the product
/// of the axes must be `≤ bound` (the column `repeat`; trailing elements are undefined fill,
/// FR-BTB-3) or `error.BadTdim`. For a `P`/`Q` (VLA) column `bound` is `null`: `TDIMn` then
/// describes the *heap* array shape, not the in-row descriptor repeat, so the product bound does
/// not apply.
fn parseTdim(alloc: Allocator, s_in: []const u8, bound: ?u64) (errors.TableError || Allocator.Error)![]u64 {
    const s = std.mem.trim(u8, s_in, " ");
    if (s.len < 2 or s[0] != '(' or s[s.len - 1] != ')') return error.BadTdim;
    const inner = s[1 .. s.len - 1];
    var list: std.ArrayList(u64) = .empty;
    errdefer list.deinit(alloc);
    var product: u64 = 1;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, " ");
        if (tok.len == 0) return error.BadTdim;
        const d = std.fmt.parseInt(u64, tok, 10) catch return error.BadTdim;
        product = std.math.mul(u64, product, d) catch return error.BadTdim;
        try list.append(alloc, d);
    }
    if (list.items.len == 0) return error.BadTdim;
    if (bound) |b| {
        if (product > b) return error.BadTdim;
    }
    return list.toOwnedSlice(alloc);
}

// ── conversion helpers (bool-safe wrappers around convert.cast) ──────────────────────────────

// Convert a stored numeric `src` to `T`. `bool` destinations are a nonzero test (so
// `convert.cast` is never instantiated for `bool`).
inline fn toT(comptime T: type, src: anytype, mode: Mode) errors.ConvError!T {
    if (T == bool) {
        return src != 0;
    } else {
        return convert.cast(T, src, mode);
    }
}

// Convert a caller value `v` to the stored numeric type `Stored`. `bool` sources map to 0/1.
inline fn fromT(comptime Stored: type, v: anytype, mode: Mode) errors.ConvError!Stored {
    if (@TypeOf(v) == bool) {
        return if (v) @as(Stored, 1) else @as(Stored, 0);
    } else {
        return convert.cast(Stored, v, mode);
    }
}

inline fn valEql(comptime T: type, a: T, b: T) bool {
    return a == b;
}

inline fn vToF64(comptime T: type, v: T) f64 {
    return switch (@typeInfo(T)) {
        .int => @floatFromInt(v),
        .float => @floatCast(v),
        else => unreachable,
    };
}

// Stored→physical→T, applying TNULL/NaN nulls then TSCAL/TZERO scaling.
fn convertScalar(comptime Stored: type, comptime T: type, s: Stored, column: *const Column, mode: Mode, opts: ReadOpts(T)) errors.ConvError!T {
    const sinfo = @typeInfo(Stored);
    if (sinfo == .int) {
        if (column.tnull) |tn| {
            if (@as(i128, s) == @as(i128, tn)) {
                if (opts.null_sentinel) |ns| return ns;
            }
        }
    } else {
        if (std.math.isNan(s)) {
            if (opts.null_sentinel) |ns| return ns;
        }
    }
    if (T == bool) {
        return s != 0;
    } else if (column.scal == 1.0 and column.zero == 0.0) {
        return convert.cast(T, s, mode);
    } else if (sinfo == .int and @typeInfo(T) == .int and column.zero_int != null) {
        const phys: i128 = @as(i128, s) + column.zero_int.?;
        return convert.cast(T, phys, mode);
    } else {
        const sf: f64 = if (sinfo == .int) @floatFromInt(s) else @as(f64, s);
        const phys: f64 = column.zero + column.scal * sf;
        return convert.cast(T, phys, mode);
    }
}

// T→physical→stored, applying the inverse scaling and null encoding.
fn convertStored(comptime Stored: type, comptime T: type, v: T, column: *const Column, mode: Mode, opts: WriteOpts(T)) errors.ConvError!Stored {
    if (opts.null_sentinel) |ns| {
        if (valEql(T, v, ns)) {
            if (@typeInfo(Stored) == .int) {
                if (column.tnull) |tn| return convert.cast(Stored, tn, mode);
            } else {
                return std.math.nan(Stored);
            }
        }
    }
    if (T == bool) {
        return fromT(Stored, v, mode);
    } else if (column.scal == 1.0 and column.zero == 0.0) {
        return convert.cast(Stored, v, mode);
    } else if (@typeInfo(Stored) == .int and @typeInfo(T) == .int and column.zero_int != null) {
        const phys: i128 = @as(i128, v) - column.zero_int.?;
        return convert.cast(Stored, phys, mode);
    } else {
        const vf: f64 = vToF64(T, v);
        const stored_f: f64 = (vf - column.zero) / column.scal;
        return convert.cast(Stored, stored_f, mode);
    }
}

// ── per-type transfer cores ──────────────────────────────────────────────────────────────────

const SCRATCH_BYTES: usize = 8192;

// Numeric/complex read: `out.len` stored values, chunked, byte-swapped, scaled, converted.
fn readRun(comptime Stored: type, comptime T: type, dev: Device, off: u64, out: []T, column: *const Column, mode: Mode, opts: ReadOpts(T)) (errors.IoError || errors.ConvError)!void {
    const cap = @max(1, SCRATCH_BYTES / @sizeOf(Stored));
    var scratch: [cap]Stored = undefined;
    var done: usize = 0;
    while (done < out.len) {
        const m = @min(scratch.len, out.len - done);
        const raw = std.mem.sliceAsBytes(scratch[0..m]);
        try dev.readAll(raw, off + @as(u64, done) * @sizeOf(Stored));
        endian.swapToNative(Stored, scratch[0..m]);
        for (scratch[0..m], 0..) |s, i| out[done + i] = try convertScalar(Stored, T, s, column, mode, opts);
        done += m;
    }
}

// Numeric/complex write: inverse of `readRun`.
fn writeRun(comptime Stored: type, comptime T: type, dev: Device, off: u64, in: []const T, column: *const Column, mode: Mode, opts: WriteOpts(T)) (errors.IoError || errors.ConvError)!void {
    const cap = @max(1, SCRATCH_BYTES / @sizeOf(Stored));
    var scratch: [cap]Stored = undefined;
    var done: usize = 0;
    while (done < in.len) {
        const m = @min(scratch.len, in.len - done);
        for (0..m) |i| scratch[i] = try convertStored(Stored, T, in[done + i], column, mode, opts);
        endian.swapToBig(Stored, scratch[0..m]);
        const raw = std.mem.sliceAsBytes(scratch[0..m]);
        try dev.writeAll(raw, off + @as(u64, done) * @sizeOf(Stored));
        done += m;
    }
}

// L: 'T'/'F' bytes ↔ bool/numeric; a 0 byte is the logical null.
fn readLogical(comptime T: type, dev: Device, off: u64, out: []T, mode: Mode, opts: ReadOpts(T)) (errors.IoError || errors.ConvError)!void {
    var scratch: [SCRATCH_BYTES]u8 = undefined;
    var done: usize = 0;
    while (done < out.len) {
        const m = @min(scratch.len, out.len - done);
        try dev.readAll(scratch[0..m], off + done);
        for (scratch[0..m], 0..) |b, i| {
            if (T == bool) {
                out[done + i] = if (b == 0) (opts.null_sentinel orelse false) else (b == 'T' or b == 't');
            } else {
                if (b == 0 and opts.null_sentinel != null) {
                    out[done + i] = opts.null_sentinel.?;
                } else {
                    const tv: u8 = if (b == 'T' or b == 't') 1 else 0;
                    out[done + i] = try convert.cast(T, tv, mode);
                }
            }
        }
        done += m;
    }
}

fn writeLogical(comptime T: type, dev: Device, off: u64, in: []const T, opts: WriteOpts(T)) (errors.IoError || errors.ConvError)!void {
    var scratch: [SCRATCH_BYTES]u8 = undefined;
    var done: usize = 0;
    while (done < in.len) {
        const m = @min(scratch.len, in.len - done);
        for (0..m) |i| {
            const v = in[done + i];
            const is_null = if (opts.null_sentinel) |ns| valEql(T, v, ns) else false;
            if (is_null) {
                scratch[i] = 0;
            } else {
                const truth: bool = if (T == bool) v else (v != 0);
                scratch[i] = if (truth) 'T' else 'F';
            }
        }
        try dev.writeAll(scratch[0..m], off + done);
        done += m;
    }
}

// X: MSB-first packed bits ↔ one element per bit. `out.len` is the bit (repeat) count.
fn readBits(comptime T: type, dev: Device, off: u64, out: []T, mode: Mode) (errors.IoError || errors.ConvError)!void {
    const nbits = out.len;
    const fbytes = (nbits + 7) / 8;
    var scratch: [SCRATCH_BYTES]u8 = undefined;
    var byte_done: usize = 0;
    while (byte_done < fbytes) {
        const m = @min(scratch.len, fbytes - byte_done);
        try dev.readAll(scratch[0..m], off + byte_done);
        for (scratch[0..m], 0..) |b, bi| {
            const base_bit = (byte_done + bi) * 8;
            var k: usize = 0;
            while (k < 8) : (k += 1) {
                const bit_index = base_bit + k;
                if (bit_index >= nbits) break;
                const shift: u3 = @intCast(7 - k);
                const bitval: u8 = (b >> shift) & 1;
                out[bit_index] = if (T == bool) (bitval == 1) else try convert.cast(T, bitval, mode);
            }
        }
        byte_done += m;
    }
}

fn writeBits(comptime T: type, dev: Device, off: u64, in: []const T) (errors.IoError || errors.ConvError)!void {
    const nbits = in.len;
    const fbytes = (nbits + 7) / 8;
    var scratch: [SCRATCH_BYTES]u8 = undefined;
    var byte_done: usize = 0;
    while (byte_done < fbytes) {
        const m = @min(scratch.len, fbytes - byte_done);
        @memset(scratch[0..m], 0);
        for (0..m) |bi| {
            const base_bit = (byte_done + bi) * 8;
            var byte: u8 = 0;
            var k: usize = 0;
            while (k < 8) : (k += 1) {
                const bit_index = base_bit + k;
                if (bit_index >= nbits) break;
                const truth: bool = if (T == bool) in[bit_index] else (in[bit_index] != 0);
                if (truth) {
                    const shift: u3 = @intCast(7 - k);
                    byte |= (@as(u8, 1) << shift);
                }
            }
            scratch[bi] = byte;
        }
        try dev.writeAll(scratch[0..m], off + byte_done);
        byte_done += m;
    }
}

// The per-string width of an `A` cell: `TDIMn`'s most-rapidly-varying axis (`tdim[0]`) when a
// `TDIMn` is present (FR-BTB-7: the field is an array of fixed-width strings), else the whole
// field. A zero axis falls back to the whole field so the modulus below is never by zero.
fn charWidth(column: *const Column, full: usize) usize {
    if (column.tdim) |td| {
        if (td.len > 0 and td[0] > 0 and td[0] <= full) return @intCast(td[0]);
    }
    return full;
}

// A: decode terminates at the first NUL (rest → spaces); leading NUL ⇒ null (all spaces). When
// `TDIMn` declares a string array (`TDIMn=(w,…)`), the NUL/pad state resets at every `w`-byte
// substring boundary so a NUL in one string does not blank the following strings (FR-BTB-7).
// For non-`u8` `T`, each byte is simply converted (no string semantics).
fn readChars(comptime T: type, dev: Device, off: u64, out: []T, mode: Mode, column: *const Column) (errors.IoError || errors.ConvError)!void {
    const width = charWidth(column, out.len);
    var scratch: [SCRATCH_BYTES]u8 = undefined;
    var done: usize = 0;
    var hit_nul = false;
    while (done < out.len) {
        const m = @min(scratch.len, out.len - done);
        try dev.readAll(scratch[0..m], off + done);
        for (scratch[0..m], 0..) |b, i| {
            if (T == u8) {
                if ((done + i) % width == 0) hit_nul = false; // new substring: reset latch
                if (hit_nul) {
                    out[done + i] = ' ';
                } else if (b == 0) {
                    hit_nul = true;
                    out[done + i] = ' ';
                } else {
                    out[done + i] = b;
                }
            } else {
                out[done + i] = try toT(T, b, mode);
            }
        }
        done += m;
    }
}

// A: encode pads with spaces; once an input NUL is seen the remainder of the field is spaces.
// As in `readChars`, a `TDIMn` string array resets the pad state at every `tdim[0]`-byte
// substring boundary so each string is padded independently (FR-BTB-7).
fn writeChars(comptime T: type, dev: Device, off: u64, in: []const T, column: *const Column) (errors.IoError || errors.ConvError)!void {
    const width = charWidth(column, in.len);
    var scratch: [SCRATCH_BYTES]u8 = undefined;
    var done: usize = 0;
    var hit_nul = false;
    while (done < in.len) {
        const m = @min(scratch.len, in.len - done);
        for (0..m) |i| {
            if (T == u8) {
                if ((done + i) % width == 0) hit_nul = false; // new substring: reset latch
                const b = in[done + i];
                if (hit_nul) {
                    scratch[i] = ' ';
                } else if (b == 0) {
                    hit_nul = true;
                    scratch[i] = ' ';
                } else {
                    scratch[i] = b;
                }
            } else {
                scratch[i] = try fromT(u8, in[done + i], .bulk);
            }
        }
        try dev.writeAll(scratch[0..m], off + done);
        done += m;
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;
const Header = @import("../header/header.zig").Header;

const ColSpec = struct {
    tform: []const u8,
    ttype: ?[]const u8 = null,
    tzero: ?f64 = null,
    tscal: ?f64 = null,
    tnull: ?i64 = null,
    tdim: ?[]const u8 = null,
};

fn buildHeader(alloc: Allocator, specs: []const ColSpec, nrows: u64, naxis1_override: ?u64) !Header {
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    var rowbytes: u64 = 0;
    for (specs) |s| rowbytes += try (try BinTform.parse(s.tform)).fieldBytes();
    const naxis1 = naxis1_override orelse rowbytes;

    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = @intCast(naxis1) }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = @intCast(nrows) }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = @intCast(specs.len) }, null);
    var buf: [16]u8 = undefined;
    for (specs, 0..) |s, i| {
        const n = i + 1;
        try h.appendValue(alloc, kwName(&buf, "TFORM", n), .{ .string = s.tform }, null);
        if (s.ttype) |t| try h.appendValue(alloc, kwName(&buf, "TTYPE", n), .{ .string = t }, null);
        if (s.tzero) |z| try h.appendValue(alloc, kwName(&buf, "TZERO", n), .{ .float = z }, null);
        if (s.tscal) |sc| try h.appendValue(alloc, kwName(&buf, "TSCAL", n), .{ .float = sc }, null);
        if (s.tnull) |tn| try h.appendValue(alloc, kwName(&buf, "TNULL", n), .{ .int = tn }, null);
        if (s.tdim) |d| try h.appendValue(alloc, kwName(&buf, "TDIM", n), .{ .string = d }, null);
    }
    try h.ensureEnd(alloc);
    return h;
}

fn buildBinTable(f: *Fits, alloc: Allocator, specs: []const ColSpec, nrows: u64, naxis1_override: ?u64) !*Hdu {
    const h = try buildHeader(alloc, specs, nrows, naxis1_override);
    return f.appendHdu(h);
}

test "round-trip I/J/K/E/D/A columns via appendHdu" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary

    const specs = [_]ColSpec{
        .{ .tform = "1I", .ttype = "I16" },
        .{ .tform = "1J", .ttype = "I32" },
        .{ .tform = "1K", .ttype = "I64" },
        .{ .tform = "1E", .ttype = "F32" },
        .{ .tform = "1D", .ttype = "F64" },
        .{ .tform = "8A", .ttype = "STR" },
    };
    const hdu = try buildBinTable(&f, alloc, &specs, 3, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    try testing.expectEqual(@as(u64, 3), t.rowCount());
    try testing.expectEqual(@as(u16, 6), t.columnCount());

    try t.writeColumn(i16, .{ .index = 0 }, 0, &[_]i16{ 1, 2, 3 }, .{});
    try t.writeColumn(i32, .{ .index = 1 }, 0, &[_]i32{ 10, 20, 30 }, .{});
    try t.writeColumn(i64, .{ .index = 2 }, 0, &[_]i64{ 100, 200, 300 }, .{});
    try t.writeColumn(f32, .{ .index = 3 }, 0, &[_]f32{ 1.5, 2.5, 3.5 }, .{});
    try t.writeColumn(f64, .{ .index = 4 }, 0, &[_]f64{ 1.25, 2.25, 3.25 }, .{});

    var sbuf: [24]u8 = undefined;
    @memset(&sbuf, ' ');
    @memcpy(sbuf[0..5], "alpha");
    @memcpy(sbuf[8..12], "beta");
    @memcpy(sbuf[16..21], "gamma");
    try t.writeColumn(u8, .{ .name = "STR" }, 0, &sbuf, .{});

    var i16o: [3]i16 = undefined;
    var i32o: [3]i32 = undefined;
    var i64o: [3]i64 = undefined;
    var f32o: [3]f32 = undefined;
    var f64o: [3]f64 = undefined;
    var so: [24]u8 = undefined;
    try t.readColumn(i16, .{ .index = 0 }, 0, &i16o, .{});
    try t.readColumn(i32, .{ .name = "i32" }, 0, &i32o, .{}); // case-insensitive name
    try t.readColumn(i64, .{ .index = 2 }, 0, &i64o, .{});
    try t.readColumn(f32, .{ .index = 3 }, 0, &f32o, .{});
    try t.readColumn(f64, .{ .index = 4 }, 0, &f64o, .{});
    try t.readColumn(u8, .{ .index = 5 }, 0, &so, .{});

    try testing.expectEqualSlices(i16, &[_]i16{ 1, 2, 3 }, &i16o);
    try testing.expectEqualSlices(i32, &[_]i32{ 10, 20, 30 }, &i32o);
    try testing.expectEqualSlices(i64, &[_]i64{ 100, 200, 300 }, &i64o);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.5, 2.5, 3.5 }, &f32o);
    try testing.expectEqualSlices(f64, &[_]f64{ 1.25, 2.25, 3.25 }, &f64o);
    try testing.expectEqualSlices(u8, &sbuf, &so);

    // single cell read
    var one: [1]i32 = undefined;
    try t.readCell(i32, .{ .index = 1 }, 1, &one, .{});
    try testing.expectEqual(@as(i32, 20), one[0]);
}

test "X bit column packs/unpacks MSB-first; r=0 accepted" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{
        .{ .tform = "16X", .ttype = "FLAGS" },
        .{ .tform = "0J", .ttype = "EMPTY" }, // r=0 accepted
    };
    const hdu = try buildBinTable(&f, alloc, &specs, 1, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    var bits: [16]bool = [_]bool{false} ** 16;
    bits[0] = true; // MSB of first byte
    bits[8] = true; // MSB of second byte
    bits[15] = true; // LSB of second byte
    try t.writeColumn(bool, .{ .index = 0 }, 0, &bits, .{});

    // First field byte must be 0x80 (MSB-first), second 0x81.
    var raw: [2]u8 = undefined;
    try f.dev.readAll(&raw, hdu.data_off);
    try testing.expectEqual(@as(u8, 0x80), raw[0]);
    try testing.expectEqual(@as(u8, 0x81), raw[1]);

    var out: [16]bool = undefined;
    try t.readColumn(bool, .{ .index = 0 }, 0, &out, .{});
    try testing.expectEqualSlices(bool, &bits, &out);

    // r=0 column: empty read/write are no-ops.
    var none: [0]i32 = undefined;
    try t.readColumn(i32, .{ .index = 1 }, 0, &none, .{});
    try t.writeColumn(i32, .{ .index = 1 }, 0, &none, .{});
}

test "L logical column round-trips bytes T/F" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1L", .ttype = "OK" }};
    const hdu = try buildBinTable(&f, alloc, &specs, 3, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    try t.writeColumn(bool, .{ .index = 0 }, 0, &[_]bool{ true, false, true }, .{});
    var raw: [3]u8 = undefined;
    try f.dev.readAll(&raw, hdu.data_off);
    try testing.expectEqualSlices(u8, "TFT", &raw);

    var out: [3]bool = undefined;
    try t.readColumn(bool, .{ .index = 0 }, 0, &out, .{});
    try testing.expectEqualSlices(bool, &[_]bool{ true, false, true }, &out);
}

test "C and M complex columns round-trip as paired slots" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{
        .{ .tform = "1C", .ttype = "CF" },
        .{ .tform = "1M", .ttype = "CD" },
    };
    const hdu = try buildBinTable(&f, alloc, &specs, 2, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    // 2 rows × 2 slots (re, im).
    try t.writeColumn(f32, .{ .index = 0 }, 0, &[_]f32{ 1.5, -2.5, 3.0, 4.0 }, .{});
    try t.writeColumn(f64, .{ .index = 1 }, 0, &[_]f64{ 10.0, 20.0, -30.0, 40.0 }, .{});

    var cf: [4]f32 = undefined;
    var cd: [4]f64 = undefined;
    try t.readColumn(f32, .{ .index = 0 }, 0, &cf, .{});
    try t.readColumn(f64, .{ .index = 1 }, 0, &cd, .{});
    try testing.expectEqualSlices(f32, &[_]f32{ 1.5, -2.5, 3.0, 4.0 }, &cf);
    try testing.expectEqualSlices(f64, &[_]f64{ 10.0, 20.0, -30.0, 40.0 }, &cd);
}

test "unsigned U (u16 over I) and W (u64 over K) via integer-space TZERO" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const two63: f64 = 9223372036854775808.0; // 2^63
    const specs = [_]ColSpec{
        .{ .tform = "1I", .ttype = "U16", .tzero = 32768.0 },
        .{ .tform = "1K", .ttype = "U64", .tzero = two63 },
    };
    const hdu = try buildBinTable(&f, alloc, &specs, 3, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    try t.writeColumn(u16, .{ .index = 0 }, 0, &[_]u16{ 0, 32768, 65535 }, .{});
    const umax: u64 = std.math.maxInt(u64);
    try t.writeColumn(u64, .{ .index = 1 }, 0, &[_]u64{ 0, two63_int, umax }, .{});

    var u16o: [3]u16 = undefined;
    var u64o: [3]u64 = undefined;
    try t.readColumn(u16, .{ .index = 0 }, 0, &u16o, .{});
    try t.readColumn(u64, .{ .index = 1 }, 0, &u64o, .{});
    try testing.expectEqualSlices(u16, &[_]u16{ 0, 32768, 65535 }, &u16o);
    try testing.expectEqualSlices(u64, &[_]u64{ 0, two63_int, umax }, &u64o);
}
const two63_int: u64 = @as(u64, 1) << 63;

test "integer TNULL read/write with sentinel" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "VAL", .tnull = -1 }};
    const hdu = try buildBinTable(&f, alloc, &specs, 3, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    // Writing the sentinel 999 stores TNULL (-1); other values store directly.
    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 5, 999, 7 }, .{ .null_sentinel = 999 });
    var raw: [3]i32 = undefined;
    try t.readColumn(i32, .{ .index = 0 }, 0, &raw, .{}); // no sentinel: raw TNULL visible
    try testing.expectEqual(@as(i32, -1), raw[1]);

    var out: [3]i32 = undefined;
    try t.readColumn(i32, .{ .index = 0 }, 0, &out, .{ .null_sentinel = 999 });
    try testing.expectEqualSlices(i32, &[_]i32{ 5, 999, 7 }, &out);
}

test "unsigned u32 over 1J via integer-space TZERO=2^31" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const two31: f64 = 2147483648.0; // 2^31
    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "U32", .tzero = two31 }};
    const hdu = try buildBinTable(&f, alloc, &specs, 3, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    const two31_int: u32 = @as(u32, 1) << 31;
    const umax32: u32 = std.math.maxInt(u32);
    try t.writeColumn(u32, .{ .index = 0 }, 0, &[_]u32{ 0, two31_int, umax32 }, .{});
    // Stored i32 spans the full signed range (0→min, 2^31→0, 2^32-1→max); reading back over u32
    // is the round-trip we assert.
    var out: [3]u32 = undefined;
    try t.readColumn(u32, .{ .index = 0 }, 0, &out, .{});
    try testing.expectEqualSlices(u32, &[_]u32{ 0, two31_int, umax32 }, &out);
}

test "signed i8 over 1B via integer-space TZERO=-128" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1B", .ttype = "I8", .tzero = -128.0 }};
    const hdu = try buildBinTable(&f, alloc, &specs, 3, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    try t.writeColumn(i8, .{ .index = 0 }, 0, &[_]i8{ -128, 0, 127 }, .{});
    // Stored u8 spans the full unsigned range (-128→0, 0→128, 127→255).
    var raw: [3]u8 = undefined;
    try f.dev.readAll(&raw, hdu.data_off);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 128, 255 }, &raw);

    var out: [3]i8 = undefined;
    try t.readColumn(i8, .{ .index = 0 }, 0, &out, .{});
    try testing.expectEqualSlices(i8, &[_]i8{ -128, 0, 127 }, &out);
}

test "1B column with TNULL sentinel round-trips" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    // A `B` (u8-stored) column whose null is 255, read over i16 so the sentinel fits.
    const specs = [_]ColSpec{.{ .tform = "1B", .ttype = "V", .tnull = 255 }};
    const hdu = try buildBinTable(&f, alloc, &specs, 3, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    try t.writeColumn(i16, .{ .index = 0 }, 0, &[_]i16{ 5, 999, 7 }, .{ .null_sentinel = 999 });
    // The sentinel stored as TNULL (255) is visible without a read sentinel.
    var raw: [3]i16 = undefined;
    try t.readColumn(i16, .{ .index = 0 }, 0, &raw, .{});
    try testing.expectEqual(@as(i16, 255), raw[1]);

    var out: [3]i16 = undefined;
    try t.readColumn(i16, .{ .index = 0 }, 0, &out, .{ .null_sentinel = 999 });
    try testing.expectEqualSlices(i16, &[_]i16{ 5, 999, 7 }, &out);
}

test "FR-CONV-1: single-cell precision-losing read errors, column read does not" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1K", .ttype = "BIG" }};
    const hdu = try buildBinTable(&f, alloc, &specs, 1, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    const big: i64 = (@as(i64, 1) << 53) + 1; // not exactly representable in f64
    try t.writeColumn(i64, .{ .index = 0 }, 0, &[_]i64{big}, .{});

    var cell: [1]f64 = undefined;
    try testing.expectError(error.PrecisionLoss, t.readCell(f64, .{ .index = 0 }, 0, &cell, .{}));

    var col: [1]f64 = undefined; // bulk: silent
    try t.readColumn(f64, .{ .index = 0 }, 0, &col, .{});
    try testing.expectEqual(@as(f64, @floatFromInt(big)), col[0]);
}

test "columnByName wildcard contract: zero / one / many; resolve maps accordingly" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{
        .{ .tform = "1J", .ttype = "FLUX" },
        .{ .tform = "1J", .ttype = "FLUXERR" },
        .{ .tform = "1J", .ttype = "NAME" },
    };
    const hdu = try buildBinTable(&f, alloc, &specs, 1, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    var m: Matches = .{};
    t.columnByName("XYZ", &m);
    try testing.expectEqual(@as(usize, 0), m.len);
    try testing.expectError(error.NoSuchColumn, t.resolve(.{ .name = "XYZ" }));

    t.columnByName("flux", &m); // exactly one (case-insensitive)
    try testing.expectEqual(@as(usize, 1), m.len);
    try testing.expectEqual(@as(u16, 0), try t.resolve(.{ .name = "flux" }));

    t.columnByName("FLUX*", &m); // many
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqual(@as(u32, 0), m.at(0));
    try testing.expectEqual(@as(u32, 1), m.at(1));
    try testing.expectError(error.AmbiguousColumn, t.resolve(.{ .name = "FLUX*" }));
}

test "TDIM parses and bounds against repeat" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    {
        const specs = [_]ColSpec{.{ .tform = "6A", .ttype = "GRID", .tdim = "(3,2)" }};
        const hdu = try buildBinTable(&f, alloc, &specs, 1, null);
        var t = try BinTable.of(&f, hdu);
        defer t.deinit(alloc);
        try testing.expectEqualSlices(u64, &[_]u64{ 3, 2 }, t.columns[0].tdim.?);
    }
    {
        // product 7 > repeat 6 → BadTdim (detected when the view is built)
        const specs = [_]ColSpec{.{ .tform = "6A", .ttype = "BAD", .tdim = "(7)" }};
        const hdu = try buildBinTable(&f, alloc, &specs, 1, null);
        try testing.expectError(error.BadTdim, BinTable.of(&f, hdu));
    }
}

test "VLA TDIM bounds the heap array, not the descriptor repeat (1PJ TDIM=(10))" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    // A P/Q column has repeat 1 (one descriptor), but TDIM describes the heap array shape; a
    // product (10) far exceeding the descriptor repeat must be accepted, not over-rejected.
    const specs = [_]ColSpec{.{ .tform = "1PJ", .ttype = "VLA", .tdim = "(10)" }};
    const hdu = try buildBinTable(&f, alloc, &specs, 1, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);
    try testing.expectEqualSlices(u64, &[_]u64{10}, t.columns[0].tdim.?);

    // A non-VLA column with the same over-large TDIM is still rejected.
    const bad = [_]ColSpec{.{ .tform = "1J", .ttype = "FIX", .tdim = "(10)" }};
    const bhdu = try buildBinTable(&f, alloc, &bad, 1, null);
    try testing.expectError(error.BadTdim, BinTable.of(&f, bhdu));
}

test "FR-BTB-7: TDIM string array resets NUL/pad per substring (60A / (5,4,3))" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "60A", .ttype = "GRID", .tdim = "(5,4,3)" }};
    const hdu = try buildBinTable(&f, alloc, &specs, 1, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);
    try testing.expectEqualSlices(u64, &[_]u64{ 5, 4, 3 }, t.columns[0].tdim.?);

    // 12 fixed-width (5-byte) strings; each is NUL-terminated and NUL-padded within its slot. A
    // NUL in an early slot must not blank the following slots (the single-latch bug).
    const words = [_][]const u8{
        "ab", "cdefg", "h", "ijkl", "mno", "p", "qrstu", "vw", "xyz", "AB", "CDE", "FG",
    };
    var in: [60]u8 = undefined;
    @memset(&in, 0);
    for (words, 0..) |w, s| @memcpy(in[s * 5 ..][0..w.len], w);
    try t.writeColumn(u8, .{ .index = 0 }, 0, &in, .{});

    var out: [60]u8 = undefined;
    try t.readColumn(u8, .{ .index = 0 }, 0, &out, .{});

    // Each 5-byte slot decodes independently: chars up to its first NUL, then spaces.
    for (words, 0..) |w, s| {
        var exp: [5]u8 = [_]u8{' '} ** 5;
        @memcpy(exp[0..w.len], w);
        try testing.expectEqualSlices(u8, &exp, out[s * 5 ..][0..5]);
    }

    // A single cell read uses the scalar policy but the same per-substring semantics.
    var cell: [60]u8 = undefined;
    try t.readCell(u8, .{ .index = 0 }, 0, &cell, .{});
    try testing.expectEqualSlices(u8, &out, &cell);
}

test "NAXIS1 must equal the sum of field widths" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{
        .{ .tform = "1J" },
        .{ .tform = "1I" },
    }; // real width 6; declare 8
    const hdu = try buildBinTable(&f, alloc, &specs, 1, 8);
    try testing.expectError(error.BadDimensions, BinTable.of(&f, hdu));
}

test "out-of-range row/cell and wrong-length buffers are typed errors" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "V" }};
    const hdu = try buildBinTable(&f, alloc, &specs, 2, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    var one: [1]i32 = undefined;
    try testing.expectError(error.RowOutOfRange, t.readCell(i32, .{ .index = 0 }, 2, &one, .{}));
    var two: [2]i32 = undefined;
    try testing.expectError(error.CellOutOfRange, t.readCell(i32, .{ .index = 0 }, 0, &two, .{}));
    try testing.expectError(error.NoSuchColumn, t.resolve(.{ .index = 5 }));

    var many: [3]i32 = undefined; // 3 rows requested, only 2 exist
    try testing.expectError(error.RowOutOfRange, t.readColumn(i32, .{ .index = 0 }, 0, &many, .{}));
}

test "non-table HDU is rejected" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    const prim = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    try testing.expectError(error.WrongHduType, BinTable.of(&f, prim));
}

// ── BTB-3b: structural row/column editing tests ──────────────────────────────────────────────

// Write/verify a recognizable, position-dependent byte pattern (used on a trailing HDU's data to
// confirm size-changing edits relocate it byte-intact and block-aligned).
fn writePattern(dev: Device, off: u64, len: usize, seed: u8) !void {
    var buf: [4096]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        const n = @min(buf.len, len - done);
        for (buf[0..n], 0..) |*b, i| b.* = @truncate(seed +% @as(u8, @truncate(done + i)));
        try dev.writeAll(buf[0..n], off + done);
        done += n;
    }
}

fn expectPattern(dev: Device, off: u64, len: usize, seed: u8) !void {
    var buf: [4096]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        const n = @min(buf.len, len - done);
        try dev.readAll(buf[0..n], off + done);
        for (buf[0..n], 0..) |b, i| {
            try testing.expectEqual(@as(u8, @truncate(seed +% @as(u8, @truncate(done + i)))), b);
        }
        done += n;
    }
}

// Build: primary, a BINTABLE (from `specs`/`nrows`), and a trailing IMAGE extension with `img`
// data bytes pre-filled with `seed`. Returns the table HDU and the trailing image HDU.
fn buildSandwich(f: *Fits, alloc: Allocator, specs: []const ColSpec, nrows: u64, img: u64, seed: u8) !struct { tab: *Hdu, img: *Hdu } {
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary
    const tab = try buildBinTable(f, alloc, specs, nrows, null);
    const image = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{img} });
    try writePattern(f.dev, image.data_off, @intCast(img), seed);
    return .{ .tab = tab, .img = image };
}

test "appendRows grows the table; new rows are writable and the trailing HDU stays intact" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    const specs = [_]ColSpec{ .{ .tform = "1J", .ttype = "A" }, .{ .tform = "1E", .ttype = "B" } };
    const s = try buildSandwich(&f, alloc, &specs, 2, 24, 0x40);
    var t = try BinTable.of(&f, s.tab);
    defer t.deinit(alloc);

    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 10, 20 }, .{});
    try t.writeColumn(f32, .{ .index = 1 }, 0, &[_]f32{ 1.5, 2.5 }, .{});

    try t.appendRows(2);
    try testing.expectEqual(@as(u64, 4), t.naxis2);
    try testing.expectEqual(@as(u64, 8), t.naxis1); // unchanged
    try testing.expectEqual(@as(u16, 2), t.columnCount());
    try testing.expectEqual(@as(i64, 4), try s.tab.header.getValue(i64, "NAXIS2"));

    // Newly-appended rows read back zero, then are writable.
    var a: [4]i32 = undefined;
    try t.readColumn(i32, .{ .index = 0 }, 0, &a, .{});
    try testing.expectEqualSlices(i32, &[_]i32{ 10, 20, 0, 0 }, &a);
    try t.writeColumn(i32, .{ .index = 0 }, 2, &[_]i32{ 30, 40 }, .{});
    try t.readColumn(i32, .{ .index = 0 }, 0, &a, .{});
    try testing.expectEqualSlices(i32, &[_]i32{ 10, 20, 30, 40 }, &a);

    // The trailing image HDU moved with the growth but kept its bytes and block alignment.
    try testing.expectEqual(s.tab.nextOff(), s.img.header_off);
    try expectPattern(f.dev, s.img.data_off, 24, 0x40);

    // A fresh open agrees on structure.
    var f2 = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f2.deinit();
    try testing.expectEqual(@as(usize, 3), try f2.hduCount());
    const r2 = try f2.select(2);
    try testing.expectEqual(@as(i64, 4), try r2.header.getValue(i64, "NAXIS2"));
}

test "insertRows in the middle shifts existing cells and zeroes the gap" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "V" }};
    const s = try buildSandwich(&f, alloc, &specs, 3, 10, 0x77);
    var t = try BinTable.of(&f, s.tab);
    defer t.deinit(alloc);

    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 100, 200, 300 }, .{});

    try t.insertRows(1, 2); // two blank rows before old row 1
    try testing.expectEqual(@as(u64, 5), t.naxis2);

    var v: [5]i32 = undefined;
    try t.readColumn(i32, .{ .index = 0 }, 0, &v, .{});
    try testing.expectEqualSlices(i32, &[_]i32{ 100, 0, 0, 200, 300 }, &v);

    try expectPattern(f.dev, s.img.data_off, 10, 0x77);
    try testing.expectEqual(s.tab.nextOff(), s.img.header_off);
}

test "deleteRows removes the chosen span and shrinks the data unit" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "V" }};
    const s = try buildSandwich(&f, alloc, &specs, 5, 12, 0x33);
    var t = try BinTable.of(&f, s.tab);
    defer t.deinit(alloc);

    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 1, 2, 3, 4, 5 }, .{});
    try t.deleteRows(1, 2); // drop rows 1,2 (values 2,3)
    try testing.expectEqual(@as(u64, 3), t.naxis2);

    var v: [3]i32 = undefined;
    try t.readColumn(i32, .{ .index = 0 }, 0, &v, .{});
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 4, 5 }, &v);

    try expectPattern(f.dev, s.img.data_off, 12, 0x33);
    try testing.expectEqual(s.tab.nextOff(), s.img.header_off);
    try testing.expectError(error.RowOutOfRange, t.deleteRows(2, 5));
}

test "copyRows overwrites a destination span (overlap-safe)" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "V" }};
    const hdu = try buildBinTable(&f, alloc, &specs, 5, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 1, 2, 3, 4, 5 }, .{});
    try t.copyRows(0, 2, 3); // rows 0,1 -> rows 3,4
    var v: [5]i32 = undefined;
    try t.readColumn(i32, .{ .index = 0 }, 0, &v, .{});
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 1, 2 }, &v);
    try testing.expectError(error.RowOutOfRange, t.copyRows(3, 3, 0));
}

test "appendColumn widens the row; existing columns preserved, new column writable" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    const specs = [_]ColSpec{ .{ .tform = "1J", .ttype = "A" }, .{ .tform = "1E", .ttype = "B" } };
    const s = try buildSandwich(&f, alloc, &specs, 3, 16, 0x50);
    var t = try BinTable.of(&f, s.tab);
    defer t.deinit(alloc);

    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 11, 22, 33 }, .{});
    try t.writeColumn(f32, .{ .index = 1 }, 0, &[_]f32{ 1.5, 2.5, 3.5 }, .{});

    const ci = try t.appendColumn(alloc, "1K", "C");
    try testing.expectEqual(@as(u16, 2), ci);
    try testing.expectEqual(@as(u16, 3), t.columnCount());
    try testing.expectEqual(@as(u64, 4 + 4 + 8), t.naxis1);
    try testing.expectEqual(@as(i64, 3), try s.tab.header.getValue(i64, "TFIELDS"));

    // Original columns survive the re-stride; new column reads zero then writes back.
    var a: [3]i32 = undefined;
    var b: [3]f32 = undefined;
    var c: [3]i64 = undefined;
    try t.readColumn(i32, .{ .index = 0 }, 0, &a, .{});
    try t.readColumn(f32, .{ .index = 1 }, 0, &b, .{});
    try t.readColumn(i64, .{ .name = "C" }, 0, &c, .{});
    try testing.expectEqualSlices(i32, &[_]i32{ 11, 22, 33 }, &a);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.5, 2.5, 3.5 }, &b);
    try testing.expectEqualSlices(i64, &[_]i64{ 0, 0, 0 }, &c);
    try t.writeColumn(i64, .{ .index = 2 }, 0, &[_]i64{ 7, 8, 9 }, .{});
    try t.readColumn(i64, .{ .index = 2 }, 0, &c, .{});
    try testing.expectEqualSlices(i64, &[_]i64{ 7, 8, 9 }, &c);

    try expectPattern(f.dev, s.img.data_off, 16, 0x50);
    try testing.expectEqual(s.tab.nextOff(), s.img.header_off);

    var f2 = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f2.deinit();
    const r2 = try f2.select(2);
    try testing.expectEqual(@as(i64, 3), try r2.header.getValue(i64, "TFIELDS"));
    try testing.expectEqual(@as(i64, 16), try r2.header.getValue(i64, "NAXIS1"));
}

test "insertColumn renumbers higher columns and preserves the others" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    const specs = [_]ColSpec{ .{ .tform = "1J", .ttype = "A" }, .{ .tform = "1E", .ttype = "B" } };
    const s = try buildSandwich(&f, alloc, &specs, 2, 8, 0x60);
    var t = try BinTable.of(&f, s.tab);
    defer t.deinit(alloc);

    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 5, 6 }, .{});
    try t.writeColumn(f32, .{ .index = 1 }, 0, &[_]f32{ 9.5, 8.5 }, .{});

    try t.insertColumn(alloc, 1, "1I", "MID"); // between A and B
    try testing.expectEqual(@as(u16, 3), t.columnCount());
    try testing.expectEqual(@as(u64, 4 + 2 + 4), t.naxis1);

    // Names landed in the right order; the renumbered B is now column index 2.
    try testing.expectEqual(@as(u16, 0), try t.resolve(.{ .name = "A" }));
    try testing.expectEqual(@as(u16, 1), try t.resolve(.{ .name = "MID" }));
    try testing.expectEqual(@as(u16, 2), try t.resolve(.{ .name = "B" }));

    var a: [2]i32 = undefined;
    var mid: [2]i16 = undefined;
    var b: [2]f32 = undefined;
    try t.readColumn(i32, .{ .name = "A" }, 0, &a, .{});
    try t.readColumn(i16, .{ .name = "MID" }, 0, &mid, .{});
    try t.readColumn(f32, .{ .name = "B" }, 0, &b, .{});
    try testing.expectEqualSlices(i32, &[_]i32{ 5, 6 }, &a);
    try testing.expectEqualSlices(i16, &[_]i16{ 0, 0 }, &mid); // new column zeroed
    try testing.expectEqualSlices(f32, &[_]f32{ 9.5, 8.5 }, &b);

    try expectPattern(f.dev, s.img.data_off, 8, 0x60);
}

test "deleteColumn narrows the row and renumbers the rest" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();

    const specs = [_]ColSpec{
        .{ .tform = "1J", .ttype = "A" },
        .{ .tform = "1E", .ttype = "B" },
        .{ .tform = "1I", .ttype = "C" },
    };
    const s = try buildSandwich(&f, alloc, &specs, 2, 8, 0x70);
    var t = try BinTable.of(&f, s.tab);
    defer t.deinit(alloc);

    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 1, 2 }, .{});
    try t.writeColumn(f32, .{ .index = 1 }, 0, &[_]f32{ 3.5, 4.5 }, .{});
    try t.writeColumn(i16, .{ .index = 2 }, 0, &[_]i16{ 7, 8 }, .{});

    try t.deleteColumn(1); // remove B
    try testing.expectEqual(@as(u16, 2), t.columnCount());
    try testing.expectEqual(@as(u64, 4 + 2), t.naxis1);
    try testing.expectEqual(@as(i64, 2), try s.tab.header.getValue(i64, "TFIELDS"));

    try testing.expectError(error.NoSuchColumn, t.resolve(.{ .name = "B" }));
    var a: [2]i32 = undefined;
    var c: [2]i16 = undefined;
    try t.readColumn(i32, .{ .name = "A" }, 0, &a, .{});
    try t.readColumn(i16, .{ .name = "C" }, 0, &c, .{});
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2 }, &a);
    try testing.expectEqualSlices(i16, &[_]i16{ 7, 8 }, &c);

    try expectPattern(f.dev, s.img.data_off, 8, 0x70);
    try testing.expectEqual(s.tab.nextOff(), s.img.header_off);
}

test "copyColumn duplicates one column's bytes over another of equal width" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    const specs = [_]ColSpec{
        .{ .tform = "1J", .ttype = "SRC" },
        .{ .tform = "1J", .ttype = "DST" },
        .{ .tform = "1I", .ttype = "NARROW" },
    };
    const hdu = try buildBinTable(&f, alloc, &specs, 3, null);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 11, 22, 33 }, .{});
    try t.writeColumn(i32, .{ .index = 1 }, 0, &[_]i32{ 0, 0, 0 }, .{});
    try t.copyColumn(0, 1);
    var d: [3]i32 = undefined;
    try t.readColumn(i32, .{ .index = 1 }, 0, &d, .{});
    try testing.expectEqualSlices(i32, &[_]i32{ 11, 22, 33 }, &d);

    // Mismatched widths are rejected; out-of-range is typed.
    try testing.expectError(error.BadTform, t.copyColumn(0, 2));
    try testing.expectError(error.NoSuchColumn, t.copyColumn(0, 9));
}

test "structural edits are rejected on a read-only handle" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    {
        var f = try Fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
        const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "V" }};
        _ = try buildBinTable(&f, alloc, &specs, 2, null);
        try f.flush();
    }
    defer mem.deinit();

    var f = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(2);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);
    try testing.expectError(error.NotWritable, t.appendRows(1));
    try testing.expectError(error.NotWritable, t.deleteRows(0, 1));
    try testing.expectError(error.NotWritable, t.appendColumn(alloc, "1J", "X"));
    try testing.expectError(error.NotWritable, t.deleteColumn(0));
}
