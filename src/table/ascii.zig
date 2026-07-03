//! ASCII-table view over an `XTENSION='TABLE'` HDU (FR-ATB-1..4, §12; FITS 4.0 §7.2).
//!
//! An `AsciiTable` presents an ASCII (FORTRAN fixed-width text) table HDU as a set of typed
//! columns. Each column stores every field as fixed-width text at a 1-based byte position
//! (`TBCOLn`) with a FORTRAN edit descriptor (`TFORMn` ∈ {`Aw`, `Iw`, `Fw.d`, `Ew.d`,
//! `Dw.d`}). Cell access is comptime-typed in the caller's element type `T`, bridged through
//! `convert.cast` (FR-CONV-1): `.scalar` mode for single cells (precision loss is an error)
//! and `.bulk` mode for whole-column transfers. Per-column `TSCALn`/`TZEROn` linear scaling is
//! applied transparently (`physical = TZEROn + TSCALn × stored`), and a field that equals the
//! column's `TNULLn` string — or is entirely blank — reads back as `null`.
//!
//! Reads slice `[TBCOLn-1, TBCOLn-1+width)` out of each row, trim FORTRAN padding, and parse;
//! writes format to exactly `width` columns (right-justified for numerics, left-justified for
//! `Aw`). A value whose text would overflow the field width is a typed `error.Overflow`, never
//! a silent truncation. All multi-byte wire access here is plain ASCII bytes, so no endian
//! conversion is needed (ASCII tables store text, not binary words).
//!
//! `NAXIS1` MAY exceed the sum of the field extents (inter-field gaps are legal, §7.2); `of`
//! only requires that each `TBCOLn-1+width <= NAXIS1`.
const std = @import("std");
const errors = @import("../errors.zig");
const convert = @import("../convert.zig");
const limits = @import("../limits.zig");
const common = @import("common.zig");
const AsciiTform = common.AsciiTform;
const asciiFieldRange = common.asciiFieldRange;
const Fits = @import("../fits.zig").Fits;
const Hdu = @import("../hdu.zig").Hdu;
const Header = @import("../header/header.zig").Header;
const Matches = @import("../header/name.zig").Matches;
const matchWildcard = @import("../header/name.zig").matchWildcard;

const Allocator = std.mem.Allocator;

/// The error set produced by ASCII-table operations (a narrow union, never `anyerror`).
pub const Error = errors.TableError || errors.StructError || errors.ValueError ||
    errors.ConvError || errors.HeaderError || errors.IoError || errors.LimitError ||
    Allocator.Error;

/// Maximum on-stack field width handled by the numeric cell path. Numeric ASCII fields are at
/// most a few dozen characters in practice; a numeric column wider than this is reported as
/// `error.BadTform` at access time rather than read into an unbounded stack buffer. (Character
/// columns are not subject to this bound: `readCellStr`/`writeCellStr` stream the caller's
/// buffer.)
const MAX_NUM_FIELD: usize = 512;

/// Scratch buffer for rendered floating text before width-checking. Sized to hold the widest
/// decimal `f64` rendering; a value needing more is reported as `error.Overflow`.
const RENDER_BUF: usize = 1024;

/// A reference to a column by 0-based position or by (wildcard) name (`FR-UTL-4`).
pub const ColumnRef = union(enum) {
    /// 0-based column index into `AsciiTable.columns`.
    index: u16,
    /// Case-insensitive name pattern (`*`/`?`/`#` wildcards); must resolve to exactly one.
    name: []const u8,
};

/// One parsed ASCII-table column: its position, format, optional metadata, and scaling.
///
/// All owned slices (`name`, `tnull`, `unit`) are released by `AsciiTable.deinit`.
pub const AsciiColumn = struct {
    /// 0-based position of this column (the FITS column number is `index + 1`).
    index: u16,
    /// `TTYPEn` column name (owned), or `null` if unspecified.
    name: ?[]u8 = null,
    /// `TBCOLn`: 1-based byte start of the field within a row.
    tbcol: u64,
    /// Parsed `TFORMn` edit descriptor.
    tform: AsciiTform,
    /// `TSCALn` linear scale factor (default 1).
    tscal: f64 = 1,
    /// `TZEROn` linear zero offset (default 0).
    tzero: f64 = 0,
    /// `TNULLn` null string (owned), or `null` if unspecified.
    tnull: ?[]u8 = null,
    /// `TUNITn` physical unit (owned), or `null` if unspecified.
    unit: ?[]u8 = null,

    /// Release this column's owned slices and reset them to `null` (idempotent).
    fn deinitFields(self: *AsciiColumn, alloc: Allocator) void {
        if (self.name) |s| alloc.free(s);
        if (self.tnull) |s| alloc.free(s);
        if (self.unit) |s| alloc.free(s);
        self.name = null;
        self.tnull = null;
        self.unit = null;
    }
};

/// A typed view over an ASCII-table HDU's data unit.
pub const AsciiTable = struct {
    fits: *Fits,
    hdu: *Hdu,
    /// Parsed columns (length == `TFIELDS`), owned; freed by `deinit`.
    columns: []AsciiColumn,
    /// `NAXIS1`: row width in bytes.
    naxis1: u64,
    /// `NAXIS2`: row count.
    naxis2: u64,

    /// Wrap an `XTENSION='TABLE'` HDU, parsing per-column metadata
    /// (`TBCOLn`/`TFORMn`/`TTYPEn`/`TUNITn`/`TSCALn`/`TZEROn`/`TNULLn`).
    ///
    /// `error.WrongHduType` if the HDU is not an ASCII table; `error.MissingRequiredKeyword`
    /// if a mandatory `TBCOLn`/`TFORMn` is absent; `error.BadTform` for a malformed `TFORMn`;
    /// `error.BadTbcol` if `TBCOLn-1 + width` exceeds `NAXIS1` (gaps below `NAXIS1` are legal).
    pub fn of(fits: *Fits, hdu: *Hdu) Error!AsciiTable {
        if (hdu.kind != .ascii_table) return error.WrongHduType;
        if (hdu.naxis != 2) return error.BadNaxis;
        const naxis1 = hdu.axes[0];
        const naxis2 = hdu.axes[1];

        const tfields_u = hdu.header.getValue(u64, "TFIELDS") catch |e| switch (e) {
            error.KeywordNotFound => return error.MissingRequiredKeyword,
            else => |err| return err,
        };
        if (tfields_u > std.math.maxInt(u16)) return error.BadDimensions;
        const tfields: u16 = @intCast(tfields_u);

        const columns = try fits.alloc.alloc(AsciiColumn, tfields);
        errdefer fits.alloc.free(columns);
        var built: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < built) : (i += 1) columns[i].deinitFields(fits.alloc);
        }

        const header = &hdu.header;
        var n: u16 = 1;
        while (n <= tfields) : (n += 1) {
            var kwbuf: [16]u8 = undefined;

            const tbcol_kw = std.fmt.bufPrint(&kwbuf, "TBCOL{d}", .{n}) catch unreachable;
            const tbcol = header.getValue(u64, tbcol_kw) catch |e| switch (e) {
                error.KeywordNotFound => return error.MissingRequiredKeyword,
                else => |err| return err,
            };

            const tform_kw = std.fmt.bufPrint(&kwbuf, "TFORM{d}", .{n}) catch unreachable;
            const tform_str = header.getString(fits.alloc, tform_kw) catch |e| switch (e) {
                error.KeywordNotFound => return error.MissingRequiredKeyword,
                else => |err| return err,
            };
            defer fits.alloc.free(tform_str);
            const tform = try AsciiTform.parse(std.mem.trim(u8, tform_str, " "));

            // Validate the field fits within the declared row width (NAXIS1 MAY exceed it).
            const range = try asciiFieldRange(tbcol, tform.width);
            if (range.end > naxis1) return error.BadTbcol;

            const name = try optString(fits.alloc, header, "TTYPE", n);
            errdefer if (name) |s| fits.alloc.free(s);
            const unit = try optString(fits.alloc, header, "TUNIT", n);
            errdefer if (unit) |s| fits.alloc.free(s);
            const tnull = try optString(fits.alloc, header, "TNULL", n);
            errdefer if (tnull) |s| fits.alloc.free(s);

            const tscal = optFloat(header, "TSCAL", n, 1);
            const tzero = optFloat(header, "TZERO", n, 0);

            columns[built] = .{
                .index = n - 1,
                .name = name,
                .tbcol = tbcol,
                .tform = tform,
                .tscal = tscal,
                .tzero = tzero,
                .tnull = tnull,
                .unit = unit,
            };
            built += 1;
        }

        return .{
            .fits = fits,
            .hdu = hdu,
            .columns = columns,
            .naxis1 = naxis1,
            .naxis2 = naxis2,
        };
    }

    /// Release the parsed columns (their names/units/null strings and the column slice).
    pub fn deinit(self: *AsciiTable, alloc: Allocator) void {
        for (self.columns) |*c| c.deinitFields(alloc);
        alloc.free(self.columns);
        self.columns = &.{};
    }

    /// Number of rows (`NAXIS2`).
    pub fn rowCount(self: *const AsciiTable) u64 {
        return self.naxis2;
    }

    /// Number of columns (`TFIELDS`).
    pub fn columnCount(self: *const AsciiTable) u16 {
        return @intCast(self.columns.len);
    }

    /// Fill `out` with the 0-based indices of every column whose `TTYPEn` name matches the
    /// case-insensitive wildcard `pat` (`*`/`?`/`#`). `out` is reset first; columns without a
    /// name are skipped. The result contract of `FR-UTL-4` is read off `out` (`len == 0` none,
    /// `len == 1` unique, ordered list otherwise).
    pub fn columnByName(self: *const AsciiTable, pat: []const u8, out: *Matches) void {
        out.reset();
        for (self.columns, 0..) |*c, i| {
            const nm = c.name orelse continue;
            if (matchWildcard(pat, nm)) out.add(@intCast(i));
        }
    }

    /// Read one numeric cell at `row` (0-based) from column `col`, converted to `T` (an int or
    /// float) under the scalar conversion policy with `TSCALn`/`TZEROn` applied. Returns `null`
    /// when the field is blank or equals the column's `TNULLn`. `error.WrongValueType` for a
    /// character (`Aw`) column — use `readCellStr` for those.
    pub fn readCell(self: *AsciiTable, comptime T: type, col: ColumnRef, row: u64) Error!?T {
        const c = try self.columnPtr(col);
        return self.readCellValue(T, c, row, .scalar);
    }

    /// Write one numeric cell at `row` (0-based) into column `col` from a value of type `T`.
    /// `TSCALn`/`TZEROn` are inverted before formatting. A `null` value writes the column's
    /// `TNULLn` string (or blanks if none). The formatted text must fit the field width, else
    /// `error.Overflow`. `error.WrongValueType` for a character column — use `writeCellStr`.
    pub fn writeCell(self: *AsciiTable, comptime T: type, col: ColumnRef, row: u64, value: ?T) Error!void {
        const c = try self.columnPtr(col);
        return self.writeCellValue(T, c, row, value, .scalar);
    }

    /// Read a contiguous run of `out.len` numeric cells starting at `first_row` into `out`
    /// (each element `null` for a blank/`TNULLn` field). Uses bulk conversion (precision-losing
    /// widening is silent, FR-CONV-1). `error.RowOutOfRange` if the run extends past `NAXIS2`.
    pub fn readColumn(self: *AsciiTable, comptime T: type, col: ColumnRef, first_row: u64, out: []?T) Error!void {
        const c = try self.columnPtr(col);
        const end = try limits.add(first_row, out.len);
        if (end > self.naxis2) return error.RowOutOfRange;
        for (out, 0..) |*o, i| o.* = try self.readCellValue(T, c, first_row + i, .bulk);
    }

    /// Write a contiguous run of numeric cells (symmetric with `readColumn`; bulk conversion).
    /// A `null` element writes the column's `TNULLn` (or blanks). `error.RowOutOfRange` if the
    /// run extends past `NAXIS2`; `error.Overflow` if any value overflows the field width.
    pub fn writeColumn(self: *AsciiTable, comptime T: type, col: ColumnRef, first_row: u64, values: []const ?T) Error!void {
        const c = try self.columnPtr(col);
        const end = try limits.add(first_row, values.len);
        if (end > self.naxis2) return error.RowOutOfRange;
        for (values, 0..) |v, i| try self.writeCellValue(T, c, first_row + i, v, .bulk);
    }

    /// Read one cell at `row` as text into `out` (which must be at least `width` bytes). Returns
    /// the trimmed field (a slice into `out`, trailing blanks/NULs removed), or `null` for a
    /// blank/`TNULLn` field. Works for any column type (the raw formatted text is returned).
    /// `error.Overflow` if `out` is smaller than the field width.
    pub fn readCellStr(self: *AsciiTable, col: ColumnRef, row: u64, out: []u8) Error!?[]const u8 {
        const c = try self.columnPtr(col);
        const w: usize = c.tform.width;
        if (out.len < w) return error.Overflow;
        const off = try self.fieldOffset(c, row);
        try self.fits.dev.readAll(out[0..w], off);
        const raw = out[0..w];
        if (fieldIsNull(c, raw, true)) return null;
        return std.mem.trimEnd(u8, raw, " \x00");
    }

    /// Write one character (`Aw`) cell at `row` from `value`, left-justified and space-padded
    /// to the field width. A `null` value writes the column's `TNULLn` (or blanks).
    /// `error.WrongValueType` for a non-character column; `error.Overflow` if the text exceeds
    /// the field width.
    pub fn writeCellStr(self: *AsciiTable, col: ColumnRef, row: u64, value: ?[]const u8) Error!void {
        const c = try self.columnPtr(col);
        if (c.tform.type != .char) return error.WrongValueType;
        const w: u64 = c.tform.width;
        const off = try self.fieldOffset(c, row);
        if (value) |val| {
            if (val.len > w) return error.Overflow;
            if (val.len > 0) try self.fits.dev.writeAll(val, off);
            try self.padSpaces(off + val.len, w - val.len);
        } else if (c.tnull) |tn| {
            const t = std.mem.trimEnd(u8, tn, " \x00");
            if (t.len > w) return error.Overflow;
            if (t.len > 0) try self.fits.dev.writeAll(t, off);
            try self.padSpaces(off + t.len, w - t.len);
        } else {
            try self.padSpaces(off, w);
        }
    }

    // ── internals ──────────────────────────────────────────────────────────────────────────

    /// Resolve a `ColumnRef` to a column pointer (`error.NoSuchColumn`/`error.AmbiguousColumn`).
    fn columnPtr(self: *AsciiTable, col: ColumnRef) errors.TableError!*AsciiColumn {
        switch (col) {
            .index => |i| {
                if (i >= self.columns.len) return error.NoSuchColumn;
                return &self.columns[i];
            },
            .name => |nm| {
                // Full capacity (not max_matches): single-column resolution must see ≥2 matches to
                // report AmbiguousColumn; max_matches is a user-facing cap for their own list queries.
                var m: Matches = .{};
                self.columnByName(nm, &m);
                if (m.len == 0) return error.NoSuchColumn;
                if (m.len > 1) return error.AmbiguousColumn;
                return &self.columns[m.at(0)];
            },
        }
    }

    /// Absolute device byte offset of the field for `col` at `row` (bounds-checked).
    fn fieldOffset(self: *const AsciiTable, col: *const AsciiColumn, row: u64) (errors.TableError || errors.LimitError)!u64 {
        if (row >= self.naxis2) return error.RowOutOfRange;
        const row_off = try limits.mul(row, self.naxis1);
        const start = col.tbcol - 1; // tbcol >= 1 guaranteed by `of` validation
        const within = try limits.add(row_off, start);
        return limits.add(self.hdu.data_off, within);
    }

    fn readCellValue(self: *AsciiTable, comptime T: type, col: *const AsciiColumn, row: u64, mode: convert.Mode) Error!?T {
        if (col.tform.type == .char) return error.WrongValueType;
        const w: usize = col.tform.width;
        if (w > MAX_NUM_FIELD) return error.BadTform;
        var buf: [MAX_NUM_FIELD]u8 = undefined;
        const off = try self.fieldOffset(col, row);
        try self.fits.dev.readAll(buf[0..w], off);
        const raw = buf[0..w];
        if (fieldIsNull(col, raw, false)) return null;

        const tok = std.mem.trim(u8, raw, " \x00");
        const identity = col.tscal == 1 and col.tzero == 0;
        switch (col.tform.type) {
            .int => {
                // std.fmt.parseInt accepts interior '_' digit separators (e.g. "1_000"→1000),
                // which FITS §7.2.5 forbids; screen the token so a malformed Iw field is a typed
                // error rather than a silently-wrong value (matches header/value.zig).
                if (!isFitsIntToken(tok)) return error.BadValueSyntax;
                const iv = std.fmt.parseInt(i64, tok, 10) catch return error.BadValueSyntax;
                if (identity) return try convert.cast(T, iv, mode);
                const phys = col.tzero + col.tscal * @as(f64, @floatFromInt(iv));
                return try convert.cast(T, phys, mode);
            },
            .fixed, .exp_single, .exp_double => {
                const fv = try parseAsciiFloat(tok, col.tform.decimals);
                if (identity) return try convert.cast(T, fv, mode);
                const phys = col.tzero + col.tscal * fv;
                return try convert.cast(T, phys, mode);
            },
            .char => unreachable, // handled above
        }
    }

    fn writeCellValue(self: *AsciiTable, comptime T: type, col: *const AsciiColumn, row: u64, value: ?T, mode: convert.Mode) Error!void {
        if (col.tform.type == .char) return error.WrongValueType;
        const w: usize = col.tform.width;
        if (w > MAX_NUM_FIELD) return error.BadTform;
        var field: [MAX_NUM_FIELD]u8 = undefined;
        const out = field[0..w];

        if (value) |v| {
            const identity = col.tscal == 1 and col.tzero == 0;
            switch (col.tform.type) {
                .int => {
                    var iv: i64 = undefined;
                    if (identity) {
                        iv = try convert.cast(i64, v, mode);
                    } else {
                        const vf = try convert.cast(f64, v, mode);
                        iv = try convert.cast(i64, (vf - col.tzero) / col.tscal, mode);
                    }
                    try formatIntField(iv, out);
                },
                .fixed => {
                    const vf = try convert.cast(f64, v, mode);
                    const raw = if (identity) vf else (vf - col.tzero) / col.tscal;
                    try formatDecimalField(raw, col.tform.decimals, out);
                },
                .exp_single, .exp_double => {
                    const vf = try convert.cast(f64, v, mode);
                    const raw = if (identity) vf else (vf - col.tzero) / col.tscal;
                    try formatExpField(raw, col.tform.decimals, col.tform.type == .exp_double, out);
                },
                .char => unreachable, // handled above
            }
        } else {
            try fillNull(col, out, false);
        }

        const off = try self.fieldOffset(col, row);
        try self.fits.dev.writeAll(out, off);
    }

    /// Write `count` ASCII spaces at `off`, in bounded chunks (no allocation).
    fn padSpaces(self: *AsciiTable, off: u64, count: u64) errors.IoError!void {
        const spaces: [256]u8 = @splat(' ');
        var done: u64 = 0;
        while (done < count) {
            const n: usize = @intCast(@min(@as(u64, spaces.len), count - done));
            try self.fits.dev.writeAll(spaces[0..n], off + done);
            done += n;
        }
    }
};

// ── field helpers ──────────────────────────────────────────────────────────────────────────

/// Read an optional string keyword `<prefix><n>`; a missing/blank/non-string value yields `null`.
fn optString(alloc: Allocator, header: *const Header, comptime prefix: []const u8, n: u16) (errors.HeaderError || Allocator.Error)!?[]u8 {
    var buf: [16]u8 = undefined;
    const kw = std.fmt.bufPrint(&buf, prefix ++ "{d}", .{n}) catch unreachable;
    return header.getString(alloc, kw) catch |e| switch (e) {
        error.KeywordNotFound, error.ValueUndefined, error.WrongValueType => null,
        else => |err| err,
    };
}

/// Read an optional float keyword `<prefix><n>`, falling back to `default` when absent/unreadable.
fn optFloat(header: *const Header, comptime prefix: []const u8, n: u16, default: f64) f64 {
    var buf: [16]u8 = undefined;
    const kw = std.fmt.bufPrint(&buf, prefix ++ "{d}", .{n}) catch unreachable;
    return header.getValue(f64, kw) catch default;
}

/// Whether `raw` represents a null field for `col`: entirely blank (spaces/NULs), or equal to
/// `TNULLn` after trimming. `for_string` trims only the trailing padding for the blank test
/// (leading blanks are significant in `Aw`); the `TNULLn` comparison always trims both ends.
fn fieldIsNull(col: *const AsciiColumn, raw: []const u8, for_string: bool) bool {
    const blank = if (for_string)
        std.mem.trimEnd(u8, raw, " \x00")
    else
        std.mem.trim(u8, raw, " \x00");
    if (blank.len == 0) return true;
    if (col.tnull) |tn| {
        const a = std.mem.trim(u8, raw, " \x00");
        const b = std.mem.trim(u8, tn, " \x00");
        if (std.mem.eql(u8, a, b)) return true;
    }
    return false;
}

/// Parse a FORTRAN real token (already trimmed of surrounding blanks) into `f64`, per the ASCII
/// `Fw.d`/`Ew.d`/`Dw.d` field rules (FITS 4.0 §7.2.5).
///
/// Accepts an optional mantissa sign, integer and/or fraction digits, and an optional exponent
/// introduced by `E`/`e`/`D`/`d` **or** by a bare `+`/`-` (rule 3a — e.g. `3.14-2`). When the
/// token has no `.`, the implied decimal point is placed `decimals` digits from the right of the
/// integer field (rule 2 — e.g. `314` under `F8.2` is `3.14`). Embedded spaces or any stray
/// character are rejected with `error.BadValueSyntax`; a token with no digits at all is invalid.
fn parseAsciiFloat(tok: []const u8, decimals: u8) errors.HeaderError!f64 {
    if (tok.len == 0 or tok.len > MAX_NUM_FIELD) return error.BadValueSyntax;
    var i: usize = 0;

    // Optional mantissa sign.
    var neg = false;
    if (tok[i] == '+' or tok[i] == '-') {
        neg = tok[i] == '-';
        i += 1;
    }

    // Integer digits, then an optional fraction.
    const int_start = i;
    while (i < tok.len and std.ascii.isDigit(tok[i])) : (i += 1) {}
    const int_part = tok[int_start..i];
    var frac_part: []const u8 = tok[i..i];
    var has_dot = false;
    if (i < tok.len and tok[i] == '.') {
        has_dot = true;
        i += 1;
        const f_start = i;
        while (i < tok.len and std.ascii.isDigit(tok[i])) : (i += 1) {}
        frac_part = tok[f_start..i];
    }
    if (int_part.len == 0 and frac_part.len == 0) return error.BadValueSyntax;

    // Optional exponent: an `E`/`D` letter, or a bare `+`/`-` (rule 3a).
    var exp: i64 = 0;
    if (i < tok.len) {
        const c = tok[i];
        if (c == 'E' or c == 'e' or c == 'D' or c == 'd') {
            i += 1;
        } else if (c != '+' and c != '-') {
            return error.BadValueSyntax; // embedded space or stray character
        }
        var eneg = false;
        if (i < tok.len and (tok[i] == '+' or tok[i] == '-')) {
            eneg = tok[i] == '-';
            i += 1;
        }
        const e_start = i;
        while (i < tok.len and std.ascii.isDigit(tok[i])) : (i += 1) {
            exp = std.math.mul(i64, exp, 10) catch return error.BadValueSyntax;
            exp = std.math.add(i64, exp, tok[i] - '0') catch return error.BadValueSyntax;
        }
        if (i == e_start) return error.BadValueSyntax; // a sign/letter with no exponent digits
        if (eneg) exp = -exp;
    }
    if (i != tok.len) return error.BadValueSyntax; // trailing/embedded garbage

    // With no explicit `.`, the rightmost `decimals` integer digits are fractional (rule 2).
    const decimal_shift: i64 = if (has_dot) @intCast(frac_part.len) else @intCast(decimals);
    // `exp` can be driven to ±i64-max by a crafted exponent, so this subtraction must be
    // checked (was an integer-underflow panic for e.g. `1e-9223372036854775807`).
    const total_exp = std.math.sub(i64, exp, decimal_shift) catch return error.BadValueSyntax;

    // Reassemble the significant digits and a single power-of-ten exponent for `parseFloat`.
    var nbuf: [MAX_NUM_FIELD + 32]u8 = undefined;
    const s = std.fmt.bufPrint(&nbuf, "{s}{s}{s}e{d}", .{
        if (neg) "-" else "",
        int_part,
        frac_part,
        total_exp,
    }) catch return error.BadValueSyntax;
    const v = std.fmt.parseFloat(f64, s) catch return error.BadValueSyntax;
    // An out-of-f64-range field (e.g. "1E400") parses to ±inf; reject it rather than letting a
    // non-finite value flow silently into scaling/WCS math (matches header/value.zig parseFloatTok).
    if (!std.math.isFinite(v)) return error.BadValueSyntax;
    return v;
}

// A FITS integer field: an optional leading sign followed by ≥1 decimal digit and nothing else
// (rejects the underscore separators / base prefixes std.fmt.parseInt would otherwise accept).
fn isFitsIntToken(s: []const u8) bool {
    if (s.len == 0) return false;
    const digits = if (s[0] == '+' or s[0] == '-') s[1..] else s;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Fill `field` for a null write: all blanks, with `TNULLn` placed if defined (right-justified
/// for numerics, left-justified for character columns). `error.Overflow` if `TNULLn` is wider
/// than the field.
fn fillNull(col: *const AsciiColumn, field: []u8, for_string: bool) errors.ConvError!void {
    @memset(field, ' ');
    if (col.tnull) |tn| {
        const t = std.mem.trim(u8, tn, " \x00");
        if (t.len > field.len) return error.Overflow;
        if (for_string)
            @memcpy(field[0..t.len], t)
        else
            @memcpy(field[field.len - t.len ..], t);
    }
}

/// Format `iv` as a right-justified decimal integer in `field`; `error.Overflow` if too wide.
fn formatIntField(iv: i64, field: []u8) errors.ConvError!void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{iv}) catch return error.Overflow;
    if (s.len > field.len) return error.Overflow;
    @memset(field, ' ');
    @memcpy(field[field.len - s.len ..], s);
}

/// Format `v` as fixed-point with `decimals` fractional digits, right-justified in `field`
/// (the `Fw.d` descriptor); `error.Overflow` if the rendered text exceeds the field width.
fn formatDecimalField(v: f64, decimals: u8, field: []u8) errors.ConvError!void {
    // A non-finite value has no conforming Fw.d form; rendering it would emit the literal
    // "nan"/"inf" (≤ 3 chars, fits any field) and silently write a non-round-trippable field.
    // Reject it, matching the Ew.d/Dw.d path and the "never silent corruption" contract.
    if (!std.math.isFinite(v)) return error.Overflow;
    var tmp: [RENDER_BUF]u8 = undefined;
    const s = std.fmt.float.render(&tmp, v, .{ .mode = .decimal, .precision = decimals }) catch return error.Overflow;
    if (s.len > field.len) return error.Overflow;
    @memset(field, ' ');
    @memcpy(field[field.len - s.len ..], s);
}

/// Format `v` in FORTRAN exponential form with `decimals` mantissa digits and an explicit,
/// at-least-two-digit signed exponent (`Ew.d`, or `Dw.d` when `use_d`), right-justified in
/// `field`. `error.Overflow` if the rendered text exceeds the field width.
fn formatExpField(v: f64, decimals: u8, use_d: bool, field: []u8) errors.ConvError!void {
    var tmp: [RENDER_BUF]u8 = undefined;
    const s = std.fmt.float.render(&tmp, v, .{ .mode = .scientific, .precision = decimals }) catch return error.Overflow;
    const epos = std.mem.indexOfScalar(u8, s, 'e') orelse return error.Overflow;
    const mant = s[0..epos];
    var exp_part = s[epos + 1 ..];
    var neg = false;
    if (exp_part.len > 0 and (exp_part[0] == '-' or exp_part[0] == '+')) {
        neg = exp_part[0] == '-';
        exp_part = exp_part[1..];
    }

    var out: [RENDER_BUF]u8 = undefined;
    var j: usize = 0;
    if (mant.len + 2 > out.len) return error.Overflow;
    @memcpy(out[0..mant.len], mant);
    j = mant.len;
    out[j] = if (use_d) 'D' else 'E';
    j += 1;
    out[j] = if (neg) '-' else '+';
    j += 1;
    const pad: usize = if (exp_part.len < 2) 2 - exp_part.len else 0;
    var k: usize = 0;
    while (k < pad) : (k += 1) {
        if (j >= out.len) return error.Overflow;
        out[j] = '0';
        j += 1;
    }
    if (j + exp_part.len > out.len) return error.Overflow;
    @memcpy(out[j .. j + exp_part.len], exp_part);
    j += exp_part.len;

    const final = out[0..j];
    if (final.len > field.len) return error.Overflow;
    @memset(field, ' ');
    @memcpy(field[field.len - final.len ..], final);
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;

/// A column descriptor used by the test header builder.
const TCol = struct {
    tbcol: u64,
    tform: []const u8,
    ttype: ?[]const u8 = null,
    tunit: ?[]const u8 = null,
    tscal: ?f64 = null,
    tzero: ?f64 = null,
    tnull: ?[]const u8 = null,
};

fn buildTableHeader(alloc: Allocator, cols: []const TCol, naxis1: u64, nrows: u64) !Header {
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    try h.appendValue(alloc, "XTENSION", .{ .string = "TABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = @intCast(naxis1) }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = @intCast(nrows) }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = @intCast(cols.len) }, null);
    var nb: [24]u8 = undefined;
    for (cols, 0..) |c, i| {
        const n = i + 1;
        try h.appendValue(alloc, try std.fmt.bufPrint(&nb, "TBCOL{d}", .{n}), .{ .int = @intCast(c.tbcol) }, null);
        try h.appendValue(alloc, try std.fmt.bufPrint(&nb, "TFORM{d}", .{n}), .{ .string = c.tform }, null);
        if (c.ttype) |s| try h.appendValue(alloc, try std.fmt.bufPrint(&nb, "TTYPE{d}", .{n}), .{ .string = s }, null);
        if (c.tunit) |s| try h.appendValue(alloc, try std.fmt.bufPrint(&nb, "TUNIT{d}", .{n}), .{ .string = s }, null);
        if (c.tscal) |v| try h.appendValue(alloc, try std.fmt.bufPrint(&nb, "TSCAL{d}", .{n}), .{ .float = v }, null);
        if (c.tzero) |v| try h.appendValue(alloc, try std.fmt.bufPrint(&nb, "TZERO{d}", .{n}), .{ .float = v }, null);
        if (c.tnull) |s| try h.appendValue(alloc, try std.fmt.bufPrint(&nb, "TNULL{d}", .{n}), .{ .string = s }, null);
    }
    return h;
}

/// Create a 2-HDU file (empty primary + ASCII table) and return the table HDU, current.
fn appendAsciiTable(f: *Fits, alloc: Allocator, cols: []const TCol, naxis1: u64, nrows: u64) !*Hdu {
    if ((try f.hduCount()) == 0) {
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary
    }
    const hdr = try buildTableHeader(alloc, cols, naxis1, nrows);
    return f.appendHdu(hdr);
}

test "of parses per-column metadata and geometry" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const cols = [_]TCol{
        .{ .tbcol = 1, .tform = "I6", .ttype = "COUNT", .tunit = "ct", .tnull = "-1" },
        .{ .tbcol = 7, .tform = "F8.2", .ttype = "FLUX", .tscal = 2.0, .tzero = 5.0 },
    };
    const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 14, 4);
    var t = try AsciiTable.of(&f, hdu);
    defer t.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), t.columnCount());
    try testing.expectEqual(@as(u64, 4), t.rowCount());

    try testing.expectEqualStrings("COUNT", t.columns[0].name.?);
    try testing.expectEqual(@as(u64, 1), t.columns[0].tbcol);
    try testing.expectEqual(common.AsciiType.int, t.columns[0].tform.type);
    try testing.expectEqual(@as(u16, 6), t.columns[0].tform.width);
    try testing.expectEqualStrings("ct", t.columns[0].unit.?);
    try testing.expectEqualStrings("-1", t.columns[0].tnull.?);

    try testing.expectEqualStrings("FLUX", t.columns[1].name.?);
    try testing.expectEqual(common.AsciiType.fixed, t.columns[1].tform.type);
    try testing.expectEqual(@as(u8, 2), t.columns[1].tform.decimals);
    try testing.expectEqual(@as(f64, 2.0), t.columns[1].tscal);
    try testing.expectEqual(@as(f64, 5.0), t.columns[1].tzero);
}

test "round-trip I/F/E/D numeric columns through appendHdu, then reopen" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();

    const counts = [_]?i64{ 10, 20, 30 };
    const valf = [_]?f64{ 1.25, 2.5, -3.75 };
    const vale = [_]?f64{ 1.25, -2.5, 100.0 };
    const vald = [_]?f64{ 0.5, -0.25, 8.0 };

    // Layout: I6 [1,7) | F8.2 [7,15) | E15.7 [15,30) | D23.15 [30,53). NAXIS1=52.
    const cols = [_]TCol{
        .{ .tbcol = 1, .tform = "I6", .ttype = "COUNT" },
        .{ .tbcol = 7, .tform = "F8.2", .ttype = "VALF" },
        .{ .tbcol = 15, .tform = "E15.7", .ttype = "VALE" },
        .{ .tbcol = 30, .tform = "D23.15", .ttype = "VALD" },
    };
    {
        var f = try Fits.create(testing.allocator, mem.device(), .{});
        defer f.deinit();
        const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 52, 3);
        var t = try AsciiTable.of(&f, hdu);
        defer t.deinit(testing.allocator);

        try t.writeColumn(i64, .{ .index = 0 }, 0, &counts);
        try t.writeColumn(f64, .{ .name = "VALF" }, 0, &valf);
        try t.writeColumn(f64, .{ .index = 2 }, 0, &vale);
        try t.writeColumn(f64, .{ .index = 3 }, 0, &vald);
        try f.flush();
    }
    {
        var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
        defer f.deinit();
        const hdu = try f.select(2);
        var t = try AsciiTable.of(&f, hdu);
        defer t.deinit(testing.allocator);

        var oi: [3]?i64 = undefined;
        try t.readColumn(i64, .{ .name = "COUNT" }, 0, &oi);
        for (counts, oi) |want, got| try testing.expectEqual(want.?, got.?);

        var of_: [3]?f64 = undefined;
        try t.readColumn(f64, .{ .index = 1 }, 0, &of_);
        for (valf, of_) |want, got| try testing.expectEqual(want.?, got.?);

        var oe: [3]?f64 = undefined;
        try t.readColumn(f64, .{ .index = 2 }, 0, &oe);
        for (vale, oe) |want, got| try testing.expectEqual(want.?, got.?);

        var od: [3]?f64 = undefined;
        try t.readColumn(f64, .{ .index = 3 }, 0, &od);
        for (vald, od) |want, got| try testing.expectEqual(want.?, got.?);

        // Single-cell read matches the column read.
        try testing.expectEqual(@as(i64, 20), (try t.readCell(i64, .{ .index = 0 }, 1)).?);
        try testing.expectEqual(@as(f64, 100.0), (try t.readCell(f64, .{ .index = 2 }, 2)).?);
    }
}

test "round-trip Aw character cells (string read/write)" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const cols = [_]TCol{.{ .tbcol = 1, .tform = "A8", .ttype = "LABEL" }};
    const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 8, 3);
    var t = try AsciiTable.of(&f, hdu);
    defer t.deinit(testing.allocator);

    const labels = [_][]const u8{ "alpha", "beta", "gamma" };
    for (labels, 0..) |s, i| try t.writeCellStr(.{ .name = "LABEL" }, i, s);

    var buf: [8]u8 = undefined;
    for (labels, 0..) |want, i| {
        const got = (try t.readCellStr(.{ .index = 0 }, i, &buf)).?;
        try testing.expectEqualStrings(want, got);
    }

    // Numeric access to a character column is a typed error.
    try testing.expectError(error.WrongValueType, t.readCell(i64, .{ .index = 0 }, 0));
    try testing.expectError(error.WrongValueType, t.writeCell(i64, .{ .index = 0 }, 0, 1));
}

test "TNULLn and all-blank fields read back as null" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const cols = [_]TCol{.{ .tbcol = 1, .tform = "I6", .ttype = "N", .tnull = "-999" }};
    const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 6, 3);
    var t = try AsciiTable.of(&f, hdu);
    defer t.deinit(testing.allocator);

    try t.writeCell(i64, .{ .index = 0 }, 0, 7);
    try t.writeCell(i64, .{ .index = 0 }, 1, null); // null → writes TNULL "-999"
    // Row 2 left unwritten (appendHdu zero-fills) → all-blank → null.

    try testing.expectEqual(@as(i64, 7), (try t.readCell(i64, .{ .index = 0 }, 0)).?);
    try testing.expectEqual(@as(?i64, null), try t.readCell(i64, .{ .index = 0 }, 1));
    try testing.expectEqual(@as(?i64, null), try t.readCell(i64, .{ .index = 0 }, 2));

    // The null write actually deposited the TNULL token.
    var buf: [6]u8 = undefined;
    const raw = try t.readCellStr(.{ .index = 0 }, 1, &buf);
    try testing.expectEqual(@as(?[]const u8, null), raw); // detected as null via TNULL
}

test "field-width overflow is a typed error, not truncation" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const cols = [_]TCol{
        .{ .tbcol = 1, .tform = "I4", .ttype = "SMALL" }, // width 4
        .{ .tbcol = 5, .tform = "A3", .ttype = "TAG" }, // width 3
    };
    const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 8, 1);
    var t = try AsciiTable.of(&f, hdu);
    defer t.deinit(testing.allocator);

    try testing.expectError(error.Overflow, t.writeCell(i64, .{ .index = 0 }, 0, 123456));
    try testing.expectError(error.Overflow, t.writeCellStr(.{ .index = 1 }, 0, "toolong"));
    // A value that fits writes fine.
    try t.writeCell(i64, .{ .index = 0 }, 0, -123);
    try testing.expectEqual(@as(i64, -123), (try t.readCell(i64, .{ .index = 0 }, 0)).?);
}

test "NAXIS1 may exceed the field extent (inter-field gaps are legal)" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    // Two 4-wide fields with a gap; declared row width 20 > 12 used.
    const cols = [_]TCol{
        .{ .tbcol = 1, .tform = "I4", .ttype = "A" },
        .{ .tbcol = 9, .tform = "I4", .ttype = "B" },
    };
    const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 20, 2);
    var t = try AsciiTable.of(&f, hdu);
    defer t.deinit(testing.allocator);

    try t.writeCell(i64, .{ .index = 0 }, 0, 11);
    try t.writeCell(i64, .{ .index = 1 }, 0, 22);
    try testing.expectEqual(@as(i64, 11), (try t.readCell(i64, .{ .index = 0 }, 0)).?);
    try testing.expectEqual(@as(i64, 22), (try t.readCell(i64, .{ .index = 1 }, 0)).?);
}

test "of rejects a field that extends past NAXIS1" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const cols = [_]TCol{.{ .tbcol = 1, .tform = "I10" }}; // end 10 > NAXIS1 5
    const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 5, 1);
    try testing.expectError(error.BadTbcol, AsciiTable.of(&f, hdu));
}

test "columnByName: not found and ambiguous resolution" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const cols = [_]TCol{
        .{ .tbcol = 1, .tform = "I4", .ttype = "FLUX" },
        .{ .tbcol = 5, .tform = "I4", .ttype = "FLUX" }, // duplicate name
        .{ .tbcol = 9, .tform = "I4", .ttype = "TIME" },
    };
    const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 12, 1);
    var t = try AsciiTable.of(&f, hdu);
    defer t.deinit(testing.allocator);

    try testing.expectError(error.NoSuchColumn, t.readCell(i64, .{ .name = "NOPE" }, 0));
    try testing.expectError(error.AmbiguousColumn, t.readCell(i64, .{ .name = "FLUX" }, 0));
    try testing.expectError(error.NoSuchColumn, t.readCell(i64, .{ .index = 9 }, 0));

    var m: Matches = .{};
    t.columnByName("*", &m);
    try testing.expectEqual(@as(usize, 3), m.len);
    t.columnByName("TIME", &m);
    try testing.expectEqual(@as(usize, 1), m.len);
    try testing.expectEqual(@as(u32, 2), m.at(0));
}

test "TSCALn/TZEROn scaling is applied on read and inverted on write" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    // physical = 5 + 10 * stored  ⇒  stored = (physical - 5) / 10.
    const cols = [_]TCol{.{ .tbcol = 1, .tform = "I6", .ttype = "P", .tscal = 10.0, .tzero = 5.0 }};
    const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 6, 1);
    var t = try AsciiTable.of(&f, hdu);
    defer t.deinit(testing.allocator);

    try t.writeCell(f64, .{ .index = 0 }, 0, 105.0); // stored should be 10
    // Physical round-trips.
    try testing.expectEqual(@as(f64, 105.0), (try t.readCell(f64, .{ .index = 0 }, 0)).?);
    // The stored (unscaled) text proves scaling was actually applied.
    var buf: [6]u8 = undefined;
    const raw = (try t.readCellStr(.{ .index = 0 }, 0, &buf)).?;
    try testing.expectEqualStrings("10", std.mem.trim(u8, raw, " "));
}

test "large i64 round-trips exactly in identity scaling (no f64 detour)" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const cols = [_]TCol{.{ .tbcol = 1, .tform = "I20", .ttype = "BIG" }};
    const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 20, 1);
    var t = try AsciiTable.of(&f, hdu);
    defer t.deinit(testing.allocator);

    const big: i64 = 9_007_199_254_740_993; // 2^53 + 1, not exactly representable in f64
    try t.writeCell(i64, .{ .index = 0 }, 0, big);
    try testing.expectEqual(big, (try t.readCell(i64, .{ .index = 0 }, 0)).?);
}

test "parseAsciiFloat: implied decimal, bare-sign exponent, lowercase d, rejects spaces" {
    // Rule 2: no '.', so the rightmost `decimals` integer digits are fractional.
    try testing.expectEqual(@as(f64, 3.14), try parseAsciiFloat("314", 2));
    // Rule 3a: a bare sign introduces the exponent.
    try testing.expectEqual(@as(f64, 0.0314), try parseAsciiFloat("3.14-2", 0));
    // Lowercase 'd' exponent letter.
    try testing.expectEqual(@as(f64, 1000.0), try parseAsciiFloat("1.0d3", 0));
    // A leading '.' with no integer digits is fine.
    try testing.expectEqual(@as(f64, 0.5), try parseAsciiFloat(".5", 0));
    // A negative mantissa with an explicit point ignores the implied-decimal count.
    try testing.expectEqual(@as(f64, -3.75), try parseAsciiFloat("-3.75", 2));
    // Embedded spaces / stray characters are rejected.
    try testing.expectError(error.BadValueSyntax, parseAsciiFloat("1 2", 0));
    try testing.expectError(error.BadValueSyntax, parseAsciiFloat("abc", 0));
    try testing.expectError(error.BadValueSyntax, parseAsciiFloat("3.14e", 0));
    // Regression: a crafted exponent at i64-min, combined with a decimal shift, underflowed
    // the `exp - decimal_shift` subtraction and panicked. It must be a typed error instead.
    try testing.expectError(error.BadValueSyntax, parseAsciiFloat("1e-9223372036854775807", 2));
    try testing.expectError(error.BadValueSyntax, parseAsciiFloat("1.99e-9223372036854775807", 0));
    // Regression: an out-of-f64-range field overflows to +inf and must be rejected, not returned.
    try testing.expectError(error.BadValueSyntax, parseAsciiFloat("1E400", 0));
    try testing.expectError(error.BadValueSyntax, parseAsciiFloat("1.0E400", 0));
}

test "ASCII integer cell rejects interior-underscore tokens (no silent wrong value)" {
    // std.fmt.parseInt would read "1_000" as 1000; the Iw read path must reject it.
    try testing.expect(!isFitsIntToken("1_000"));
    try testing.expect(!isFitsIntToken("+1_2"));
    try testing.expect(!isFitsIntToken("0x10"));
    try testing.expect(!isFitsIntToken("+"));
    try testing.expect(isFitsIntToken("1000"));
    try testing.expect(isFitsIntToken("-42"));
    try testing.expect(isFitsIntToken("+7"));
}

test "formatDecimalField rejects nan/inf instead of silently writing non-conforming bytes" {
    var field: [10]u8 = undefined;
    // Regression: NaN/Inf rendered as literal "nan"/"inf" (≤ 3 chars) and was silently written
    // into a numeric Fw.d field, producing a value that fails to read back.
    try testing.expectError(error.Overflow, formatDecimalField(std.math.nan(f64), 2, &field));
    try testing.expectError(error.Overflow, formatDecimalField(std.math.inf(f64), 2, &field));
    try testing.expectError(error.Overflow, formatDecimalField(-std.math.inf(f64), 2, &field));
    // A finite value still formats normally.
    try formatDecimalField(3.14, 2, &field);
    try testing.expectEqualStrings("      3.14", &field);
}

test "readCell surfaces BadValueSyntax for non-numeric field bytes" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const cols = [_]TCol{
        .{ .tbcol = 1, .tform = "I6", .ttype = "N" }, // integer field [0,6)
        .{ .tbcol = 7, .tform = "F6.2", .ttype = "X" }, // float field [6,12)
    };
    const hdu = try appendAsciiTable(&f, testing.allocator, &cols, 12, 1);
    var t = try AsciiTable.of(&f, hdu);
    defer t.deinit(testing.allocator);

    // Deposit raw non-numeric bytes directly at each column's field offset.
    try f.dev.writeAll("abc", hdu.data_off);
    try f.dev.writeAll("xyz", hdu.data_off + 6);
    try testing.expectError(error.BadValueSyntax, t.readCell(i64, .{ .index = 0 }, 0));
    try testing.expectError(error.BadValueSyntax, t.readCell(f64, .{ .index = 1 }, 0));
}

test "wrong HDU type is rejected" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    const img = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{4} });
    try testing.expectError(error.WrongHduType, AsciiTable.of(&f, img));
}
