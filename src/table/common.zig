//! Shared table column model: TFORM/TDISP parsing and ASCII column geometry
//! (FR-UTL-2, §12.2, §13.1; FITS 4.0 §7.2.4, §7.3.3, Tables 15–20).
//!
//! Both the ASCII-table and binary-table modules build on these parsers, and structural
//! validation reuses them. The parsers extract the type code, repeat count, field width, and
//! decimal count, and compute byte widths and ASCII column positions.
const std = @import("std");
const TableError = @import("../errors.zig").TableError;

// ── Binary-table TFORM (FITS 4.0 §7.3.3, Table 18) ───────────────────────────────────────

/// Binary-table field type codes. The only valid `TFORMn` letters are `L X B I J K A E D C M
/// P Q`; the unsigned/signed CFITSIO tags `U/V/W/S` are surfaced by the table API but stored
/// on disk as `I/J/K/B` + `TZEROn`, so they are not represented here.
pub const BinaryType = enum {
    logical, // L
    bit, // X
    byte, // B
    int16, // I
    int32, // J
    int64, // K
    char, // A
    float32, // E
    float64, // D
    complex32, // C
    complex64, // M
    vla32, // P (array descriptor, 2×i32)
    vla64, // Q (array descriptor, 2×i64)

    /// Map a `TFORM` letter to its type, or null if not a valid binary code.
    pub fn fromChar(c: u8) ?BinaryType {
        return switch (std.ascii.toUpper(c)) {
            'L' => .logical,
            'X' => .bit,
            'B' => .byte,
            'I' => .int16,
            'J' => .int32,
            'K' => .int64,
            'A' => .char,
            'E' => .float32,
            'D' => .float64,
            'C' => .complex32,
            'M' => .complex64,
            'P' => .vla32,
            'Q' => .vla64,
            else => null,
        };
    }

    /// The `TFORM` letter for this type.
    pub fn toChar(self: BinaryType) u8 {
        return switch (self) {
            .logical => 'L',
            .bit => 'X',
            .byte => 'B',
            .int16 => 'I',
            .int32 => 'J',
            .int64 => 'K',
            .char => 'A',
            .float32 => 'E',
            .float64 => 'D',
            .complex32 => 'C',
            .complex64 => 'M',
            .vla32 => 'P',
            .vla64 => 'Q',
        };
    }

    /// Bytes per element (the on-disk size of one value). For `bit` this is meaningless (use
    /// `BinTform.fieldBytes`); the descriptor sizes for `P`/`Q` are 8 and 16 respectively.
    pub fn elemBytes(self: BinaryType) u16 {
        return switch (self) {
            .logical, .byte, .char, .bit => 1,
            .int16 => 2,
            .int32, .float32 => 4,
            .int64, .float64, .complex32, .vla32 => 8,
            .complex64, .vla64 => 16,
        };
    }

    /// Whether this is a variable-length-array descriptor type.
    pub fn isVla(self: BinaryType) bool {
        return self == .vla32 or self == .vla64;
    }
};

/// A parsed binary-table `TFORMn = rT[t(emax)]`.
pub const BinTform = struct {
    /// Repeat count `r` (default 1; 0 accepted). For `bit` (`X`) this is the bit count.
    repeat: u64 = 1,
    type: BinaryType,
    /// For `P`/`Q`: the element type of the variable-length array (`t` in `rPt`).
    vla_elem: ?BinaryType = null,
    /// For `P`/`Q`: the optional declared maximum element count `(emax)`.
    emax: ?u64 = null,

    /// Parse a binary `TFORM` value (already unquoted/trimmed). Examples: `1J`, `8A`, `16X`,
    /// `PB`, `1PE(52)`, `0K`. A `P`/`Q` leading repeat must be absent, 0, or 1 (FR-VLA-1).
    pub fn parse(s_in: []const u8) TableError!BinTform {
        const s = std.mem.trim(u8, s_in, " ");
        if (s.len == 0) return error.BadTform;
        var i: usize = 0;
        // Optional leading repeat count.
        var has_repeat = false;
        var repeat: u64 = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            has_repeat = true;
            repeat = std.math.mul(u64, repeat, 10) catch return error.BadTform;
            repeat = std.math.add(u64, repeat, s[i] - '0') catch return error.BadTform;
        }
        if (i >= s.len) return error.BadTform;
        const code = BinaryType.fromChar(s[i]) orelse return error.BadTform;
        i += 1;

        var tform: BinTform = .{ .type = code, .repeat = if (has_repeat) repeat else 1 };

        if (code.isVla()) {
            // Leading repeat for P/Q must be absent, 0, or 1.
            if (has_repeat and repeat > 1) return error.BadTform;
            tform.repeat = if (has_repeat) repeat else 1;
            // Optional element-type letter.
            if (i < s.len and BinaryType.fromChar(s[i]) != null) {
                const elem = BinaryType.fromChar(s[i]).?;
                if (elem.isVla()) return error.BadTform; // no nested descriptors
                tform.vla_elem = elem;
                i += 1;
            }
            // Optional (emax).
            if (i < s.len and s[i] == '(') {
                const close = std.mem.indexOfScalarPos(u8, s, i, ')') orelse return error.BadTform;
                const num = s[i + 1 .. close];
                tform.emax = std.fmt.parseInt(u64, std.mem.trim(u8, num, " "), 10) catch return error.BadTform;
                i = close + 1;
            }
        }
        // Trailing garbage (other than spaces) is invalid.
        while (i < s.len) : (i += 1) if (s[i] != ' ') return error.BadTform;
        return tform;
    }

    /// Number of bytes this field occupies within a table row. `X` packs `repeat` bits into
    /// `ceil(repeat/8)` bytes; `P`/`Q` occupy one descriptor (8 or 16 bytes); others occupy
    /// `repeat × elemBytes`.
    pub fn fieldBytes(self: BinTform) TableError!u64 {
        return switch (self.type) {
            // `repeat` is parsed straight from TFORMn and can reach u64 max, so `repeat + 7`
            // must not overflow (was an integer-overflow panic on a crafted bit count). Divide
            // first, then add the partial-byte, which cannot overflow.
            .bit => (self.repeat / 8) + @intFromBool(self.repeat % 8 != 0),
            .vla32 => 8,
            .vla64 => 16,
            else => std.math.mul(u64, self.repeat, self.type.elemBytes()) catch return error.BadTform,
        };
    }
};

// ── ASCII-table TFORM (FITS 4.0 §7.2.5, Table 15) ────────────────────────────────────────

/// ASCII-table field type codes.
pub const AsciiType = enum {
    char, // Aw
    int, // Iw
    fixed, // Fw.d
    exp_single, // Ew.d
    exp_double, // Dw.d

    /// Map an ASCII-table `TFORM` letter to its field type, or return `null`.
    pub fn fromChar(c: u8) ?AsciiType {
        return switch (std.ascii.toUpper(c)) {
            'A' => .char,
            'I' => .int,
            'F' => .fixed,
            'E' => .exp_single,
            'D' => .exp_double,
            else => null,
        };
    }

    /// Return the ASCII-table `TFORM` letter for this field type.
    pub fn toChar(self: AsciiType) u8 {
        return switch (self) {
            .char => 'A',
            .int => 'I',
            .fixed => 'F',
            .exp_single => 'E',
            .exp_double => 'D',
        };
    }
};

/// A parsed ASCII-table `TFORMn = Tw[.d]`.
pub const AsciiTform = struct {
    type: AsciiType,
    width: u16,
    decimals: u8 = 0,

    /// Parse an ASCII `TFORM` value. `A`/`I` take only a width; `F`/`E`/`D` take `w.d`.
    pub fn parse(s_in: []const u8) TableError!AsciiTform {
        const s = std.mem.trim(u8, s_in, " ");
        if (s.len < 2) return error.BadTform;
        const ty = AsciiType.fromChar(s[0]) orelse return error.BadTform;
        var i: usize = 1;
        const w_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == w_start) return error.BadTform;
        const width = std.fmt.parseInt(u16, s[w_start..i], 10) catch return error.BadTform;
        var decimals: u8 = 0;
        if (i < s.len and s[i] == '.') {
            i += 1;
            const d_start = i;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
            if (i == d_start) return error.BadTform;
            decimals = std.fmt.parseInt(u8, s[d_start..i], 10) catch return error.BadTform;
        }
        while (i < s.len) : (i += 1) if (s[i] != ' ') return error.BadTform;
        if (width == 0) return error.BadTform;
        return .{ .type = ty, .width = width, .decimals = decimals };
    }
};

/// The 0-based, end-exclusive byte range `[start, end)` a field with 1-based `TBCOLn` and
/// `width` occupies. `NAXIS1` MAY exceed `end` (gaps are legal, §7.2); callers validate
/// `end <= NAXIS1`.
pub fn asciiFieldRange(tbcol_1based: u64, width: u16) TableError!struct { start: u64, end: u64 } {
    if (tbcol_1based == 0) return error.BadTbcol;
    const start = tbcol_1based - 1;
    const end = std.math.add(u64, start, width) catch return error.BadTbcol;
    return .{ .start = start, .end = end };
}

// ── TDISP display format (FITS 4.0 §7.2.6 / §7.3.4, Tables 16/20) ─────────────────────────

/// A parsed `TDISPn` display format. Supports the common forms: `Aw`, `Lw`, `Iw[.m]`,
/// `Bw[.m]`, `Ow[.m]`, `Zw[.m]`, `Fw.d`, `Ew.d[Ee]`, `ENw.d`, `ESw.d`, `Gw.d[Ee]`,
/// `Dw.d[Ee]`. Used by TDISP rendering (FR-UTL-5).
pub const Tdisp = struct {
    /// Display code letters (e.g. "I", "F", "EN", "ES", "E", "G", "D", "A", "L", "B", "O", "Z").
    code: [2]u8 = .{ 0, 0 },
    code_len: u8 = 1,
    width: u16,
    decimals: u8 = 0,
    /// Minimum digit count (the `.m` of integer formats), 0 if unspecified.
    min_digits: u8 = 0,
    /// Exponent digit count (the `Ee` suffix), 0 if unspecified.
    exp_digits: u8 = 0,

    /// Return the parsed `TDISP` format code without unused buffer bytes.
    pub fn codeText(self: *const Tdisp) []const u8 {
        return self.code[0..self.code_len];
    }

    /// Parse a FITS `TDISP` display format, including width, precision, and exponent digits.
    pub fn parse(s_in: []const u8) TableError!Tdisp {
        const s = std.mem.trim(u8, s_in, " ");
        if (s.len < 2) return error.BadTform;
        var i: usize = 0;
        var disp: Tdisp = .{ .width = 0 };
        // Two-letter codes EN / ES first, else single letter.
        const c0 = std.ascii.toUpper(s[0]);
        if ((c0 == 'E') and s.len > 1 and (std.ascii.toUpper(s[1]) == 'N' or std.ascii.toUpper(s[1]) == 'S')) {
            disp.code = .{ c0, std.ascii.toUpper(s[1]) };
            disp.code_len = 2;
            i = 2;
        } else {
            if (!std.ascii.isAlphabetic(c0)) return error.BadTform;
            disp.code = .{ c0, 0 };
            disp.code_len = 1;
            i = 1;
        }
        // Width.
        const w_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == w_start) return error.BadTform;
        disp.width = std.fmt.parseInt(u16, s[w_start..i], 10) catch return error.BadTform;
        // Optional .d (decimals or min digits, depending on code).
        if (i < s.len and s[i] == '.') {
            i += 1;
            const d_start = i;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
            if (i == d_start) return error.BadTform;
            const dval = std.fmt.parseInt(u8, s[d_start..i], 10) catch return error.BadTform;
            switch (disp.code[0]) {
                'I', 'B', 'O', 'Z' => disp.min_digits = dval,
                else => disp.decimals = dval,
            }
        }
        // Optional Ee exponent suffix (for E/G/D).
        if (i < s.len and std.ascii.toUpper(s[i]) == 'E') {
            i += 1;
            const e_start = i;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
            if (i == e_start) return error.BadTform;
            disp.exp_digits = std.fmt.parseInt(u8, s[e_start..i], 10) catch return error.BadTform;
        }
        while (i < s.len) : (i += 1) if (s[i] != ' ') return error.BadTform;
        return disp;
    }
};

// ── TDISP value rendering (FR-UTL-5, §19.1) ──────────────────────────────────────────────

/// The display width of a `TDISP` format — the field width `w` (≡ CFITSIO
/// `fits_get_col_display_width`).
pub fn displayWidth(disp: Tdisp) u16 {
    return disp.width;
}

/// Render a floating value per `disp` (`F`/`E`/`D`/`G`/`EN`/`ES`) right-justified into `out`,
/// returning the used slice. `error.BadTform` if `out` is too small for the field width.
///
/// `F` is fixed-point. `E`/`D`/`ES` are scientific with a normalised `1 <= |mantissa| < 10`
/// mantissa (`D` writes a `D` exponent letter). `EN` is engineering notation: the exponent is a
/// multiple of three and `1 <= |mantissa| < 1000`. `G` selects fixed or scientific by magnitude
/// (Table 20). When `disp.exp_digits` is nonzero the exponent is zero-padded to exactly that many
/// digits (the `Ee` suffix); otherwise it is at least two digits.
pub fn renderFloat(disp: Tdisp, out: []u8, v: f64) error{BadTform}![]const u8 {
    const code = disp.codeText();
    if (code.len == 1 and code[0] == 'F') {
        var tmp: [80]u8 = undefined;
        const s = std.fmt.float.render(&tmp, v, .{ .mode = .decimal, .precision = disp.decimals }) catch return error.BadTform;
        return rightJustify(out, s, disp.width);
    }
    if (code.len == 1 and code[0] == 'G') return renderG(disp, out, v);
    const engineering = code.len == 2 and code[0] == 'E' and code[1] == 'N';
    const exp_letter: u8 = if (code.len == 1 and code[0] == 'D') 'D' else 'E';
    return renderScientific(disp, out, v, engineering, exp_letter);
}

// The integer `e` with `1 <= |v|/10^e < 10` (0 for a zero or non-finite `v`). `std.math.log10`
// is corrected at decade boundaries where its rounding could land one power off.
fn decimalDecade(v: f64) i64 {
    const av = @abs(v);
    if (!(av > 0) or !std.math.isFinite(av)) return 0;
    var e: i64 = @intFromFloat(std.math.floor(std.math.log10(av)));
    const m = av / std.math.pow(f64, 10, @as(f64, @floatFromInt(e)));
    if (m >= 10) e += 1 else if (m < 1) e -= 1;
    return e;
}

// Render `v` in scientific form: a `precision`-digit mantissa (engineering ⇒ exponent a multiple
// of three), the `exp_letter`, an explicit exponent sign, and a zero-padded exponent.
fn renderScientific(disp: Tdisp, out: []u8, v: f64, engineering: bool, exp_letter: u8) error{BadTform}![]const u8 {
    var decade = decimalDecade(v);
    if (engineering) decade -= @mod(decade, 3); // @mod ≥ 0, so floors toward −∞ to a multiple of 3
    const mant: f64 = if (v == 0 or !std.math.isFinite(v))
        v
    else
        v / std.math.pow(f64, 10, @as(f64, @floatFromInt(decade)));

    var mbuf: [80]u8 = undefined;
    const ms = std.fmt.float.render(&mbuf, mant, .{ .mode = .decimal, .precision = disp.decimals }) catch return error.BadTform;

    var obuf: [96]u8 = undefined;
    if (ms.len + 2 > obuf.len) return error.BadTform;
    @memcpy(obuf[0..ms.len], ms);
    var n: usize = ms.len;
    obuf[n] = exp_letter;
    n += 1;
    obuf[n] = if (decade < 0) '-' else '+';
    n += 1;

    var dbuf: [24]u8 = undefined;
    const ds = std.fmt.bufPrint(&dbuf, "{d}", .{@abs(decade)}) catch return error.BadTform;
    const min_digits: usize = if (disp.exp_digits > 0) disp.exp_digits else 2;
    const pad: usize = if (ds.len < min_digits) min_digits - ds.len else 0;
    if (n + pad + ds.len > obuf.len) return error.BadTform;
    @memset(obuf[n .. n + pad], '0');
    n += pad;
    @memcpy(obuf[n .. n + ds.len], ds);
    n += ds.len;

    return rightJustify(out, obuf[0..n], disp.width);
}

// `Gw.d`: fixed-point when `0.1 <= |v| < 10^d` (so the `d` significant digits fit a fixed field),
// otherwise scientific with `d-1` mantissa fraction digits (Table 20).
fn renderG(disp: Tdisp, out: []u8, v: f64) error{BadTform}![]const u8 {
    const d: i64 = disp.decimals;
    var use_fixed = v == 0;
    var frac: u8 = if (d > 0) @intCast(d - 1) else 0;
    if (v != 0 and std.math.isFinite(v)) {
        const e = decimalDecade(v);
        if (e >= -1 and e <= d - 1) {
            use_fixed = true;
            const f = d - 1 - e; // d significant digits ⇒ (d-1-e) fractional digits
            frac = if (f > 0) @intCast(f) else 0;
        }
    }
    if (use_fixed) {
        var tmp: [80]u8 = undefined;
        const s = std.fmt.float.render(&tmp, v, .{ .mode = .decimal, .precision = frac }) catch return error.BadTform;
        return rightJustify(out, s, disp.width);
    }
    var sdisp = disp;
    sdisp.decimals = if (d > 0) @intCast(d - 1) else 0;
    return renderScientific(sdisp, out, v, false, 'E');
}

/// Render an integer value per `disp` (`I`/`B`/`O`/`Z` with optional minimum digits `.m`)
/// right-justified into `out`.
pub fn renderInt(disp: Tdisp, out: []u8, v: i64) error{BadTform}![]const u8 {
    const base: u8 = switch (disp.code[0]) {
        'O' => 8,
        'Z' => 16,
        'B' => 2,
        else => 10,
    };
    var digits: [80]u8 = undefined;
    var dw = std.Io.Writer.fixed(&digits);
    const mag: u64 = @abs(v);
    dw.printInt(mag, base, .upper, .{}) catch return error.BadTform;
    const body = dw.buffered();

    var tmp: [80]u8 = undefined;
    var n: usize = 0;
    if (v < 0) {
        tmp[n] = '-';
        n += 1;
    }
    // Zero-pad the magnitude to the minimum digit count.
    if (disp.min_digits > body.len) {
        const pad = disp.min_digits - body.len;
        if (n + pad > tmp.len) return error.BadTform;
        @memset(tmp[n .. n + pad], '0');
        n += pad;
    }
    if (n + body.len > tmp.len) return error.BadTform;
    @memcpy(tmp[n .. n + body.len], body);
    n += body.len;
    return rightJustify(out, tmp[0..n], disp.width);
}

/// Render a string value per an `Aw` `disp`, left-justified and blank-padded into `out`.
pub fn renderString(disp: Tdisp, out: []u8, s: []const u8) error{BadTform}![]const u8 {
    const w: usize = disp.width;
    if (w > out.len) return error.BadTform;
    @memset(out[0..w], ' ');
    const n = @min(s.len, w);
    @memcpy(out[0..n], s[0..n]); // truncates to the field width (left-justified)
    return out[0..w];
}

// Right-justify `body` into a `width`-column field at the start of `out` (blank-padded left).
fn rightJustify(out: []u8, body: []const u8, width: u16) error{BadTform}![]const u8 {
    const w: usize = width;
    if (w > out.len) return error.BadTform;
    if (body.len >= w) {
        // Value does not fit the field width: surface as a typed error, not truncation.
        if (body.len > w) return error.BadTform;
        @memcpy(out[0..w], body);
        return out[0..w];
    }
    const pad = w - body.len;
    @memset(out[0..pad], ' ');
    @memcpy(out[pad .. pad + body.len], body);
    return out[0..w];
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "binary TFORM: each code parses with repeat and byte width" {
    const J = try BinTform.parse("1J");
    try testing.expectEqual(BinaryType.int32, J.type);
    try testing.expectEqual(@as(u64, 1), J.repeat);
    try testing.expectEqual(@as(u64, 4), try J.fieldBytes());

    const A = try BinTform.parse("8A");
    try testing.expectEqual(BinaryType.char, A.type);
    try testing.expectEqual(@as(u64, 8), try A.fieldBytes());

    const X = try BinTform.parse("16X"); // 16 bits → 2 bytes
    try testing.expectEqual(BinaryType.bit, X.type);
    try testing.expectEqual(@as(u64, 2), try X.fieldBytes());

    const K = try BinTform.parse("3K");
    try testing.expectEqual(@as(u64, 24), try K.fieldBytes());

    const M = try BinTform.parse("M"); // implicit repeat 1, double complex = 16 bytes
    try testing.expectEqual(@as(u64, 16), try M.fieldBytes());

    const zero = try BinTform.parse("0J"); // r=0 accepted
    try testing.expectEqual(@as(u64, 0), try zero.fieldBytes());
}

test "bit field byte rounding" {
    try testing.expectEqual(@as(u64, 2), try (try BinTform.parse("9X")).fieldBytes());
    try testing.expectEqual(@as(u64, 1), try (try BinTform.parse("8X")).fieldBytes());
    try testing.expectEqual(@as(u64, 1), try (try BinTform.parse("1X")).fieldBytes());
    // Regression: a near-u64-max bit count must not overflow `repeat + 7` (was a panic on a
    // crafted TFORMn when opening a BINTABLE). Now it computes the byte width without overflow.
    // ceil((2^64-1)/8) = 2^61 ; ceil((2^64-8)/8) = 2^61-1 (exactly divisible).
    try testing.expectEqual(@as(u64, 1) << 61, try (try BinTform.parse("18446744073709551615X")).fieldBytes());
    try testing.expectEqual((@as(u64, 1) << 61) - 1, try (try BinTform.parse("18446744073709551608X")).fieldBytes());
}

test "binary VLA descriptors P/Q with element type and emax" {
    const p = try BinTform.parse("1PE(52)");
    try testing.expectEqual(BinaryType.vla32, p.type);
    try testing.expectEqual(BinaryType.float32, p.vla_elem.?);
    try testing.expectEqual(@as(u64, 52), p.emax.?);
    try testing.expectEqual(@as(u64, 8), try p.fieldBytes());

    const q = try BinTform.parse("QD");
    try testing.expectEqual(BinaryType.vla64, q.type);
    try testing.expectEqual(BinaryType.float64, q.vla_elem.?);
    try testing.expectEqual(@as(u64, 16), try q.fieldBytes());

    // Leading repeat > 1 on P/Q is invalid.
    try testing.expectError(error.BadTform, BinTform.parse("2PJ"));
    try testing.expectEqual(@as(u64, 0), (try BinTform.parse("0PJ")).repeat);
}

test "invalid binary TFORM" {
    try testing.expectError(error.BadTform, BinTform.parse(""));
    try testing.expectError(error.BadTform, BinTform.parse("5"));
    try testing.expectError(error.BadTform, BinTform.parse("3G"));
    try testing.expectError(error.BadTform, BinTform.parse("1Jx"));
}

test "ASCII TFORM parsing" {
    const a = try AsciiTform.parse("A20");
    try testing.expectEqual(AsciiType.char, a.type);
    try testing.expectEqual(@as(u16, 20), a.width);

    const f = try AsciiTform.parse("F8.2");
    try testing.expectEqual(AsciiType.fixed, f.type);
    try testing.expectEqual(@as(u16, 8), f.width);
    try testing.expectEqual(@as(u8, 2), f.decimals);

    const e = try AsciiTform.parse("E15.7");
    try testing.expectEqual(AsciiType.exp_single, e.type);
    try testing.expectEqual(@as(u8, 7), e.decimals);

    try testing.expectError(error.BadTform, AsciiTform.parse("I"));
    try testing.expectError(error.BadTform, AsciiTform.parse("Q5"));
    try testing.expectError(error.BadTform, AsciiTform.parse("A0"));
}

test "ASCII column range" {
    const r = try asciiFieldRange(1, 10);
    try testing.expectEqual(@as(u64, 0), r.start);
    try testing.expectEqual(@as(u64, 10), r.end);
    const r2 = try asciiFieldRange(11, 5);
    try testing.expectEqual(@as(u64, 10), r2.start);
    try testing.expectEqual(@as(u64, 15), r2.end);
    try testing.expectError(error.BadTbcol, asciiFieldRange(0, 5));
}

test "TDISP rendering and display width (FR-UTL-5)" {
    var buf: [32]u8 = undefined;
    // Iw.m: integer width 6, min 3 digits, right-justified.
    try testing.expectEqualStrings("   042", try renderInt(try Tdisp.parse("I6.3"), &buf, 42));
    try testing.expectEqualStrings("  -042", try renderInt(try Tdisp.parse("I6.3"), &buf, -42));
    try testing.expectEqualStrings("     7", try renderInt(try Tdisp.parse("I6"), &buf, 7));
    // Z (hex), B (binary).
    try testing.expectEqualStrings("    FF", try renderInt(try Tdisp.parse("Z6"), &buf, 255));
    try testing.expectEqualStrings("  1010", try renderInt(try Tdisp.parse("B6"), &buf, 10));
    // Fw.d fixed-point, right-justified.
    try testing.expectEqualStrings("  3.14", try renderFloat(try Tdisp.parse("F6.2"), &buf, 3.14159));
    // Aw string, left-justified blank-padded.
    try testing.expectEqualStrings("M31     ", try renderString(try Tdisp.parse("A8"), &buf, "M31"));
    // display width is the field width.
    try testing.expectEqual(@as(u16, 15), displayWidth(try Tdisp.parse("E15.7")));
    // overflow is a typed error, not truncation.
    try testing.expectError(error.BadTform, renderInt(try Tdisp.parse("I2"), &buf, 12345));
}

test "TDISP renderFloat: ES/EN/G branches and the Ee exponent suffix (FR-UTL-5)" {
    var buf: [32]u8 = undefined;

    // ES: scientific, mantissa normalised to [1,10).
    try testing.expectEqualStrings(" 1.250E+02", try renderFloat(try Tdisp.parse("ES10.3"), &buf, 125.0));
    // EN: engineering, exponent forced to a multiple of three (mantissa in [1,1000)).
    try testing.expectEqualStrings(" 125.000E+00", try renderFloat(try Tdisp.parse("EN12.3"), &buf, 125.0));
    // EN with a negative-decade value: exponent stays a multiple of three.
    try testing.expectEqualStrings(" 500.000E-06", try renderFloat(try Tdisp.parse("EN12.3"), &buf, 0.0005));

    // G: fixed-point inside [0.1, 10^d), scientific outside it.
    try testing.expectEqualStrings("      3.14", try renderFloat(try Tdisp.parse("G10.3"), &buf, 3.14159));
    try testing.expectEqualStrings("  3.14E+04", try renderFloat(try Tdisp.parse("G10.3"), &buf, 31415.9));
    try testing.expectEqualStrings("  1.23E-04", try renderFloat(try Tdisp.parse("G10.3"), &buf, 0.0001234));

    // Explicit Ee suffix zero-pads the exponent to that many digits.
    try testing.expectEqualStrings(" 1.5000E+005", try renderFloat(try Tdisp.parse("E12.4E3"), &buf, 150000.0));
    // D uses a 'D' exponent letter.
    try testing.expectEqualStrings("  1.500D+05", try renderFloat(try Tdisp.parse("D11.3"), &buf, 150000.0));
}

test "TDISP parsing" {
    const i = try Tdisp.parse("I5.3");
    try testing.expectEqualStrings("I", i.codeText());
    try testing.expectEqual(@as(u16, 5), i.width);
    try testing.expectEqual(@as(u8, 3), i.min_digits);

    const f = try Tdisp.parse("F8.2");
    try testing.expectEqualStrings("F", f.codeText());
    try testing.expectEqual(@as(u8, 2), f.decimals);

    const en = try Tdisp.parse("EN15.6");
    try testing.expectEqualStrings("EN", en.codeText());
    try testing.expectEqual(@as(u16, 15), en.width);
    try testing.expectEqual(@as(u8, 6), en.decimals);

    const e = try Tdisp.parse("E20.10E3");
    try testing.expectEqualStrings("E", e.codeText());
    try testing.expectEqual(@as(u8, 10), e.decimals);
    try testing.expectEqual(@as(u8, 3), e.exp_digits);

    const z = try Tdisp.parse("Z8");
    try testing.expectEqualStrings("Z", z.codeText());
    try testing.expectEqual(@as(u16, 8), z.width);
}
