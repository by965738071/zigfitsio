//! Image data access: type model, pixel/section I/O, scaling, and nulls
//! (FR-IMG-1..9, §11.1–11.4).
//!
//! An `ImageView` presents an HDU's image array over all six `BITPIX` values and `NAXIS`
//! 0–999. Pixel transfers are comptime-typed in the caller's element type `T`, with
//! `convert.cast` bridging the stored type and `T` (FR-IMG-9), `endian.swapToNative` handling
//! byte order (GC-5), linear `BSCALE`/`BZERO` scaling applied transparently (FR-IMG-5) — the
//! unsigned-integer convention handled in integer space to avoid `f64` precision loss
//! (FR-IMG-6) — and `BLANK`/NaN null substitution against a caller sentinel (FR-IMG-8). All
//! transfers stream through a fixed scratch buffer in bounded, block-aligned chunks
//! (NFR-PERF-1/3). The whole-array calls wrap the chunked `readPixels`/`writePixels`.
const std = @import("std");
const errors = @import("errors.zig");
const convert = @import("convert.zig");
const endian = @import("endian.zig");
const limits = @import("limits.zig");
const Fits = @import("fits.zig").Fits;
const Hdu = @import("hdu.zig").Hdu;

/// The quiet-NaN bit pattern emitted for floating null pixels (FR-IMG-8). Any NaN is
/// recognized as null on read; this specific pattern is written on output. (Byte-for-byte
/// agreement with CFITSIO's emitted NaN is pinned by the X-FIXTURES parity fixture.)
pub const fits_nan_f32: f32 = @bitCast(@as(u32, 0x7FC00000));
pub const fits_nan_f64: f64 = @bitCast(@as(u64, 0x7FF8000000000000));

/// Linear scaling state (BSCALE/BZERO/BLANK), `physical = BZERO + BSCALE × stored`.
pub const Scaling = struct {
    bscale: f64 = 1,
    bzero: f64 = 0,
    /// Integer null sentinel (raw, pre-scale), from `BLANK`.
    blank: ?i64 = null,
    /// Whether scaling is applied (`apply`) or stored values are exposed unscaled (`raw`).
    mode: enum { apply, raw } = .apply,
};

/// Per-call read options, element-typed so a null sentinel cannot mismatch the read type.
pub fn ReadOpts(comptime T: type) type {
    return struct {
        /// `BLANK`/NaN stored values are returned as this sentinel (FR-IMG-8). When null, a
        /// `BLANK` integer is returned scaled and a NaN as NaN (or errors if `T` is integral).
        null_sentinel: ?T = null,
        /// Override the HDU's `BSCALE`/`BZERO`/`BLANK` (e.g. `.{ .mode = .raw }` for stored
        /// values). When null, scaling is taken from the header.
        scaling: ?Scaling = null,
    };
}

/// Per-call write options (symmetric with `ReadOpts`).
pub fn WriteOpts(comptime T: type) type {
    return struct {
        null_sentinel: ?T = null,
        scaling: ?Scaling = null,
    };
}

const CHUNK_ELEMS: usize = 4096; // elements per streamed chunk

/// Transfer direction for the section walk.
const Dir = enum { read, write };

/// Errors produced by image operations.
pub const ImageError = errors.StructError || errors.IoError || errors.ConvError || errors.LimitError;

/// A typed view over an HDU's image data array.
pub const ImageView = struct {
    fits: *Fits,
    hdu: *Hdu,

    /// Wrap an image-like HDU (primary, IMAGE, or random groups). `error.WrongHduType` for a
    /// table HDU.
    pub fn of(fits: *Fits, hdu: *Hdu) errors.StructError!ImageView {
        if (!hdu.kind.isImageLike()) return error.WrongHduType;
        return .{ .fits = fits, .hdu = hdu };
    }

    /// Append a new image HDU to `fits` and return a view over it (FR-TPL-2 convenience).
    pub fn append(fits: *Fits, spec: @import("fits.zig").ImageSpec) (@import("fits.zig").FitsError)!ImageView {
        const hdu = try fits.appendImageHdu(spec);
        return of(fits, hdu) catch unreachable;
    }

    /// `BITPIX` of the underlying array.
    pub fn bitpix(self: *const ImageView) i64 {
        return self.hdu.bitpix;
    }

    /// Per-axis sizes (most-rapidly-varying first).
    pub fn dims(self: *const ImageView) []const u64 {
        return self.hdu.axes;
    }

    /// Total number of pixels (product of axes; 0 when `NAXIS == 0`).
    pub fn elementCount(self: *const ImageView) u64 {
        if (self.hdu.naxis == 0) return 0;
        var n: u64 = 1;
        for (self.hdu.axes) |a| n *= a;
        return n;
    }

    /// Resolve the effective scaling: an explicit override, else the header's BSCALE/BZERO/BLANK.
    fn scalingOf(self: *const ImageView, override: ?Scaling) Scaling {
        if (override) |s| return s;
        return .{
            .bscale = self.hdu.header.getValue(f64, "BSCALE") catch 1,
            .bzero = self.hdu.header.getValue(f64, "BZERO") catch 0,
            .blank = self.hdu.header.getValue(i64, "BLANK") catch null,
        };
    }

    /// Read the entire array into `out` (exactly `elementCount()` elements) (FR-IMG-3/9).
    pub fn readAll(self: *ImageView, comptime T: type, out: []T, opts: ReadOpts(T)) ImageError!void {
        if (out.len != self.elementCount()) return error.BadDimensions;
        try self.readLinear(T, 0, out, self.scalingOf(opts.scaling), opts.null_sentinel);
    }

    /// Read `out.len` contiguous pixels starting at the N-D coordinate `first` (FR-IMG-3).
    pub fn readPixels(self: *ImageView, comptime T: type, first: []const u64, out: []T, opts: ReadOpts(T)) ImageError!void {
        const start = try self.linearIndex(first);
        const total = self.elementCount();
        if (start > total or out.len > total - start) return error.BadDimensions;
        try self.readLinear(T, start, out, self.scalingOf(opts.scaling), opts.null_sentinel);
    }

    /// Write the entire array from `in` (exactly `elementCount()` elements).
    pub fn writeAll(self: *ImageView, comptime T: type, in: []const T, opts: WriteOpts(T)) ImageError!void {
        if (in.len != self.elementCount()) return error.BadDimensions;
        try self.writeLinear(T, 0, in, self.scalingOf(opts.scaling), opts.null_sentinel);
    }

    /// Write `in.len` contiguous pixels starting at the N-D coordinate `first`.
    pub fn writePixels(self: *ImageView, comptime T: type, first: []const u64, in: []const T, opts: WriteOpts(T)) ImageError!void {
        const start = try self.linearIndex(first);
        const total = self.elementCount();
        if (start > total or in.len > total - start) return error.BadDimensions;
        try self.writeLinear(T, start, in, self.scalingOf(opts.scaling), opts.null_sentinel);
    }

    /// Read a rectangular section (`lower..=upper` inclusive per axis, optional per-axis
    /// `stride`) into `out`, walking one innermost row at a time (FR-IMG-4). `out.len` must
    /// equal the product of per-axis selected counts `(upper-lower)/stride + 1`.
    pub fn readSection(self: *ImageView, comptime T: type, lower: []const u64, upper: []const u64, stride: ?[]const u64, out: []T, opts: ReadOpts(T)) ImageError!void {
        try self.section(T, lower, upper, stride, out, .read, self.scalingOf(opts.scaling), opts.null_sentinel);
    }

    /// Write a rectangular section (symmetric with `readSection`).
    pub fn writeSection(self: *ImageView, comptime T: type, lower: []const u64, upper: []const u64, stride: ?[]const u64, in: []T, opts: WriteOpts(T)) ImageError!void {
        try self.section(T, lower, upper, stride, in, .write, self.scalingOf(opts.scaling), opts.null_sentinel);
    }

    // Column-major (first axis fastest) linear index of an N-D coordinate, bounds-checked.
    fn linearIndex(self: *const ImageView, first: []const u64) ImageError!u64 {
        if (first.len != self.hdu.naxis) return error.BadDimensions;
        var idx: u64 = 0;
        var stride: u64 = 1;
        for (first, self.hdu.axes) |coord, axis| {
            if (coord >= axis) return error.BadDimensions;
            idx = try limits.add(idx, try limits.mul(coord, stride));
            stride = try limits.mul(stride, axis);
        }
        return idx;
    }

    fn readLinear(self: *ImageView, comptime T: type, first_elem: u64, out: []T, sc: Scaling, sentinel: ?T) ImageError!void {
        return switch (self.hdu.bitpix) {
            8 => self.transferRead(u8, T, first_elem, out, sc, sentinel),
            16 => self.transferRead(i16, T, first_elem, out, sc, sentinel),
            32 => self.transferRead(i32, T, first_elem, out, sc, sentinel),
            64 => self.transferRead(i64, T, first_elem, out, sc, sentinel),
            -32 => self.transferRead(f32, T, first_elem, out, sc, sentinel),
            -64 => self.transferRead(f64, T, first_elem, out, sc, sentinel),
            else => error.BadBitpix,
        };
    }

    fn writeLinear(self: *ImageView, comptime T: type, first_elem: u64, in: []const T, sc: Scaling, sentinel: ?T) ImageError!void {
        return switch (self.hdu.bitpix) {
            8 => self.transferWrite(u8, T, first_elem, in, sc, sentinel),
            16 => self.transferWrite(i16, T, first_elem, in, sc, sentinel),
            32 => self.transferWrite(i32, T, first_elem, in, sc, sentinel),
            64 => self.transferWrite(i64, T, first_elem, in, sc, sentinel),
            -32 => self.transferWrite(f32, T, first_elem, in, sc, sentinel),
            -64 => self.transferWrite(f64, T, first_elem, in, sc, sentinel),
            else => error.BadBitpix,
        };
    }

    fn transferRead(self: *ImageView, comptime Stored: type, comptime T: type, first_elem: u64, out: []T, sc: Scaling, sentinel: ?T) ImageError!void {
        const elem = @sizeOf(Stored);
        var scratch: [CHUNK_ELEMS]Stored = undefined;
        var done: usize = 0;
        while (done < out.len) {
            const n = @min(CHUNK_ELEMS, out.len - done);
            const byte_off = self.hdu.data_off + (first_elem + done) * elem;
            try self.fits.dev.readAll(std.mem.sliceAsBytes(scratch[0..n]), byte_off);
            endian.swapToNative(Stored, scratch[0..n]);
            for (scratch[0..n], 0..) |s, i| out[done + i] = try transformRead(Stored, T, s, sc, sentinel);
            done += n;
        }
    }

    fn transferWrite(self: *ImageView, comptime Stored: type, comptime T: type, first_elem: u64, in: []const T, sc: Scaling, sentinel: ?T) ImageError!void {
        const elem = @sizeOf(Stored);
        var scratch: [CHUNK_ELEMS]Stored = undefined;
        var done: usize = 0;
        while (done < in.len) {
            const n = @min(CHUNK_ELEMS, in.len - done);
            for (in[done .. done + n], 0..) |v, i| scratch[i] = try transformWrite(Stored, T, v, sc, sentinel);
            endian.swapToBig(Stored, scratch[0..n]);
            const byte_off = self.hdu.data_off + (first_elem + done) * elem;
            try self.fits.dev.writeAll(std.mem.sliceAsBytes(scratch[0..n]), byte_off);
            done += n;
        }
    }

    // Rectangular section walk: enumerate the outer-axis coordinates and transfer each
    // innermost row (axis 0) as a unit, honoring per-axis stride.
    fn section(self: *ImageView, comptime T: type, lower: []const u64, upper: []const u64, stride_opt: ?[]const u64, buf: []T, comptime dir: Dir, sc: Scaling, sentinel: ?T) ImageError!void {
        const nd = self.hdu.naxis;
        if (lower.len != nd or upper.len != nd) return error.BadDimensions;
        if (stride_opt) |st| if (st.len != nd) return error.BadDimensions;
        if (nd == 0) return; // scalar image: nothing to section

        var counts: [999]u64 = undefined;
        var total: u64 = 1;
        for (0..nd) |i| {
            const stp = if (stride_opt) |st| st[i] else 1;
            if (stp == 0) return error.BadDimensions;
            if (upper[i] >= self.hdu.axes[i] or lower[i] > upper[i]) return error.BadDimensions;
            counts[i] = (upper[i] - lower[i]) / stp + 1;
            total = try limits.mul(total, counts[i]);
        }
        if (buf.len != total) return error.BadDimensions;

        const stride0 = if (stride_opt) |st| st[0] else 1;
        const row_len = counts[0];
        // A scratch row of stored elements for the innermost axis span (contiguous on disk).
        const span = upper[0] - lower[0] + 1; // contiguous element count covering the strided row
        if (span > CHUNK_ELEMS) return error.BadDimensions; // a single row must fit the scratch

        var coord: [999]u64 = undefined;
        for (0..nd) |i| coord[i] = lower[i];

        var out_idx: usize = 0;
        while (true) {
            // Linear index of the row start (coord with axis 0 = lower[0]).
            coord[0] = lower[0];
            const base = try self.linearIndexArr(coord[0..nd]);
            try self.transferRow(T, base, span, stride0, row_len, buf[out_idx .. out_idx + row_len], dir, sc, sentinel);
            out_idx += row_len;

            // Increment the outer coordinates (axes 1..nd-1) with their strides.
            var carry = true;
            var ax: usize = 1;
            while (ax < nd) : (ax += 1) {
                const stp = if (stride_opt) |st| st[ax] else 1;
                coord[ax] += stp;
                if (coord[ax] <= upper[ax]) {
                    carry = false;
                    break;
                }
                coord[ax] = lower[ax];
            }
            if (carry) break; // wrapped past the last outer axis
        }
    }

    fn linearIndexArr(self: *const ImageView, coord: []const u64) ImageError!u64 {
        var idx: u64 = 0;
        var stride: u64 = 1;
        for (coord, self.hdu.axes) |c, axis| {
            idx = try limits.add(idx, try limits.mul(c, stride));
            stride = try limits.mul(stride, axis);
        }
        return idx;
    }

    // Transfer one innermost row: read `span` contiguous stored elements at `base`, then pick
    // every `stride0`-th into `row` (or the inverse for writes).
    fn transferRow(self: *ImageView, comptime T: type, base: u64, span: u64, stride0: u64, row_len: u64, row: []T, comptime dir: Dir, sc: Scaling, sentinel: ?T) ImageError!void {
        return switch (self.hdu.bitpix) {
            8 => self.transferRowTyped(u8, T, base, span, stride0, row_len, row, dir, sc, sentinel),
            16 => self.transferRowTyped(i16, T, base, span, stride0, row_len, row, dir, sc, sentinel),
            32 => self.transferRowTyped(i32, T, base, span, stride0, row_len, row, dir, sc, sentinel),
            64 => self.transferRowTyped(i64, T, base, span, stride0, row_len, row, dir, sc, sentinel),
            -32 => self.transferRowTyped(f32, T, base, span, stride0, row_len, row, dir, sc, sentinel),
            -64 => self.transferRowTyped(f64, T, base, span, stride0, row_len, row, dir, sc, sentinel),
            else => error.BadBitpix,
        };
    }

    fn transferRowTyped(self: *ImageView, comptime Stored: type, comptime T: type, base: u64, span: u64, stride0: u64, row_len: u64, row: []T, comptime dir: Dir, sc: Scaling, sentinel: ?T) ImageError!void {
        const elem = @sizeOf(Stored);
        var scratch: [CHUNK_ELEMS]Stored = undefined;
        const sp: usize = @intCast(span);
        const byte_off = self.hdu.data_off + base * elem;
        if (dir == .read) {
            try self.fits.dev.readAll(std.mem.sliceAsBytes(scratch[0..sp]), byte_off);
            endian.swapToNative(Stored, scratch[0..sp]);
            var j: usize = 0;
            while (j < row_len) : (j += 1) {
                row[j] = try transformRead(Stored, T, scratch[@intCast(j * stride0)], sc, sentinel);
            }
        } else {
            // Read-modify-write the span so strided gaps are preserved.
            try self.fits.dev.readAll(std.mem.sliceAsBytes(scratch[0..sp]), byte_off);
            endian.swapToNative(Stored, scratch[0..sp]);
            var j: usize = 0;
            while (j < row_len) : (j += 1) {
                scratch[@intCast(j * stride0)] = try transformWrite(Stored, T, row[j], sc, sentinel);
            }
            endian.swapToBig(Stored, scratch[0..sp]);
            try self.fits.dev.writeAll(std.mem.sliceAsBytes(scratch[0..sp]), byte_off);
        }
    }
};

// ── scaling / null transforms ────────────────────────────────────────────────────────────

fn isIntegral(f: f64) bool {
    return std.math.isFinite(f) and @floor(f) == f;
}

fn transformRead(comptime Stored: type, comptime T: type, s: Stored, sc: Scaling, sentinel: ?T) errors.ConvError!T {
    if (sentinel) |snt| {
        switch (@typeInfo(Stored)) {
            .int => if (sc.blank) |bl| {
                if (@as(i128, s) == @as(i128, bl)) return snt;
            },
            .float => if (std.math.isNan(s)) return snt,
            else => {},
        }
    }
    return applyScaleRead(Stored, T, s, sc);
}

fn transformWrite(comptime Stored: type, comptime T: type, v: T, sc: Scaling, sentinel: ?T) errors.ConvError!Stored {
    if (sentinel) |snt| {
        if (v == snt) {
            switch (@typeInfo(Stored)) {
                .int => if (sc.blank) |bl| return convert.cast(Stored, bl, .bulk),
                .float => return if (Stored == f32) fits_nan_f32 else fits_nan_f64,
                else => {},
            }
        }
    }
    return applyScaleWrite(Stored, T, v, sc);
}

fn applyScaleRead(comptime Stored: type, comptime T: type, s: Stored, sc: Scaling) errors.ConvError!T {
    if (sc.mode == .raw) return convert.cast(T, s, .bulk);
    if (sc.bscale == 1 and @typeInfo(Stored) == .int and @typeInfo(T) == .int and isIntegral(sc.bzero)) {
        const bz: i128 = @intFromFloat(sc.bzero);
        return convert.cast(T, @as(i128, s) + bz, .bulk); // unsigned convention in integer space
    }
    const sf: f64 = switch (@typeInfo(Stored)) {
        .int => @floatFromInt(s),
        .float => @floatCast(s),
        else => unreachable,
    };
    return convert.cast(T, sc.bzero + sc.bscale * sf, .bulk);
}

fn applyScaleWrite(comptime Stored: type, comptime T: type, v: T, sc: Scaling) errors.ConvError!Stored {
    if (sc.mode == .raw) return convert.cast(Stored, v, .bulk);
    if (sc.bscale == 1 and @typeInfo(Stored) == .int and @typeInfo(T) == .int and isIntegral(sc.bzero)) {
        const bz: i128 = @intFromFloat(sc.bzero);
        return convert.cast(Stored, @as(i128, v) - bz, .bulk);
    }
    const vf: f64 = switch (@typeInfo(T)) {
        .int => @floatFromInt(v),
        .float => @floatCast(v),
        else => unreachable,
    };
    return convert.cast(Stored, (vf - sc.bzero) / sc.bscale, .bulk);
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("io/memory.zig").MemoryDevice;
const ImageSpec = @import("fits.zig").ImageSpec;

test "round-trip: create f32 image, write pixels, reopen, read back" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    const w = 16;
    const h = 8;
    var pixels: [w * h]f32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @floatFromInt(i);
    {
        var f = try Fits.create(testing.allocator, mem.device(), .{});
        defer f.deinit();
        var img = try ImageView.append(&f, .{ .bitpix = -32, .axes = &.{ w, h } });
        try img.writeAll(f32, &pixels, .{});
        try f.flush();
    }
    {
        var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
        defer f.deinit();
        var img = try ImageView.of(&f, f.current());
        var out: [w * h]f32 = undefined;
        try img.readAll(f32, &out, .{});
        try testing.expectEqualSlices(f32, &pixels, &out);
    }
}

test "every BITPIX round-trips through the stored type" {
    inline for (.{ 8, 16, 32, 64, -32, -64 }) |bp| {
        var mem = MemoryDevice.init(testing.allocator);
        defer mem.deinit();
        const n = 100;
        var src: [n]i64 = undefined;
        for (&src, 0..) |*s, i| s.* = @intCast(i + 1);
        var f = try Fits.create(testing.allocator, mem.device(), .{});
        defer f.deinit();
        var img = try ImageView.append(&f, .{ .bitpix = bp, .axes = &.{n} });
        try img.writeAll(i64, &src, .{});
        var out: [n]i64 = undefined;
        try img.readAll(i64, &out, .{});
        try testing.expectEqualSlices(i64, &src, &out);
    }
}

test "BSCALE/BZERO scaling applied on read, inverted on write (IMG-2)" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 16, .axes = &.{4} });
    const sc: Scaling = .{ .bscale = 2.0, .bzero = 100.0 };
    const physical = [_]f64{ 100, 102, 200, 300 }; // stored = (p-100)/2 = 0,1,50,100
    try img.writeAll(f64, &physical, .{ .scaling = sc });

    // Raw stored values:
    var raw: [4]i16 = undefined;
    try img.readAll(i16, &raw, .{ .scaling = .{ .mode = .raw } });
    try testing.expectEqualSlices(i16, &[_]i16{ 0, 1, 50, 100 }, &raw);
    // Scaled physical values:
    var phys: [4]f64 = undefined;
    try img.readAll(f64, &phys, .{ .scaling = sc });
    try testing.expectEqualSlices(f64, &physical, &phys);
}

test "unsigned-integer convention near 2^63 (IMG-3, no f64 precision loss)" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 64, .axes = &.{3} });
    const bz: f64 = 9223372036854775808.0; // 2^63
    const sc: Scaling = .{ .bscale = 1, .bzero = bz };
    const vals = [_]u64{ 0, std.math.maxInt(u64), (1 << 63) + 12345 };
    try img.writeAll(u64, &vals, .{ .scaling = sc });
    var out: [3]u64 = undefined;
    try img.readAll(u64, &out, .{ .scaling = sc });
    try testing.expectEqualSlices(u64, &vals, &out); // exact through the 2^63 boundary
}

test "BLANK integer nulls and NaN float nulls map to the sentinel (IMG-4)" {
    // Integer BLANK.
    {
        var mem = MemoryDevice.init(testing.allocator);
        defer mem.deinit();
        var f = try Fits.create(testing.allocator, mem.device(), .{});
        defer f.deinit();
        var img = try ImageView.append(&f, .{ .bitpix = 16, .axes = &.{4} });
        const sc: Scaling = .{ .blank = -32768 };
        const vals = [_]i32{ 1, -999, 2, 3 }; // -999 is the null sentinel
        try img.writeAll(i32, &vals, .{ .scaling = sc, .null_sentinel = -999 });
        var raw: [4]i16 = undefined;
        try img.readAll(i16, &raw, .{ .scaling = .{ .mode = .raw } });
        try testing.expectEqual(@as(i16, -32768), raw[1]); // stored as BLANK
        var out: [4]i32 = undefined;
        try img.readAll(i32, &out, .{ .scaling = sc, .null_sentinel = -999 });
        try testing.expectEqualSlices(i32, &vals, &out);
    }
    // Float NaN.
    {
        var mem = MemoryDevice.init(testing.allocator);
        defer mem.deinit();
        var f = try Fits.create(testing.allocator, mem.device(), .{});
        defer f.deinit();
        var img = try ImageView.append(&f, .{ .bitpix = -32, .axes = &.{3} });
        const vals = [_]f32{ 1.5, -1.0, 3.5 };
        try img.writeAll(f32, &vals, .{ .null_sentinel = -1.0 });
        var raw: [3]f32 = undefined;
        try img.readAll(f32, &raw, .{ .scaling = .{ .mode = .raw } });
        try testing.expect(std.math.isNan(raw[1])); // stored as NaN
        var out: [3]f32 = undefined;
        try img.readAll(f32, &out, .{ .null_sentinel = -1.0 });
        try testing.expectEqualSlices(f32, &vals, &out);
    }
}

test "readPixels reads a contiguous N-D run (column-major offset)" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    const w = 5;
    const h = 4;
    var pixels: [w * h]i32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i * 10);
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 32, .axes = &.{ w, h } });
    try img.writeAll(i32, &pixels, .{});
    var run: [5]i32 = undefined;
    try img.readPixels(i32, &.{ 0, 2 }, &run, .{}); // linear index 10
    try testing.expectEqualSlices(i32, pixels[10..15], &run);
}

test "readSection extracts a strided 2-D sub-rectangle (IMG-5)" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    const w = 6;
    const h = 6;
    var pixels: [w * h]i32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i);
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 32, .axes = &.{ w, h } });
    try img.writeAll(i32, &pixels, .{});

    // Section x in {0,2,4}, y in {1,3}: counts 3×2 = 6 elements.
    var out: [6]i32 = undefined;
    try img.readSection(i32, &.{ 0, 1 }, &.{ 4, 3 }, &.{ 2, 2 }, &out, .{});
    // Expected (column-major: value = x + y*6): y=1 -> 6,8,10 ; y=3 -> 18,20,22
    try testing.expectEqualSlices(i32, &[_]i32{ 6, 8, 10, 18, 20, 22 }, &out);

    // Manual gather cross-check.
    var manual: [6]i32 = undefined;
    var k: usize = 0;
    var y: usize = 1;
    while (y <= 3) : (y += 2) {
        var x: usize = 0;
        while (x <= 4) : (x += 2) {
            manual[k] = pixels[x + y * w];
            k += 1;
        }
    }
    try testing.expectEqualSlices(i32, &manual, &out);
}

test "writeSection writes a strided sub-rectangle, preserving gaps" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    const w = 4;
    const h = 3;
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 32, .axes = &.{ w, h } });
    var zeros = [_]i32{0} ** (w * h);
    try img.writeAll(i32, &zeros, .{});

    // Write 9s into x in {0,2}, y in {0,2}.
    var nines = [_]i32{ 9, 9, 9, 9 };
    try img.writeSection(i32, &.{ 0, 0 }, &.{ 2, 2 }, &.{ 2, 2 }, &nines, .{});
    var out: [w * h]i32 = undefined;
    try img.readAll(i32, &out, .{});
    try testing.expectEqual(@as(i32, 9), out[0]); // (0,0)
    try testing.expectEqual(@as(i32, 9), out[2]); // (2,0)
    try testing.expectEqual(@as(i32, 9), out[0 + 2 * w]); // (0,2)
    try testing.expectEqual(@as(i32, 9), out[2 + 2 * w]); // (2,2)
    try testing.expectEqual(@as(i32, 0), out[1]); // gap preserved
    try testing.expectEqual(@as(i32, 0), out[1 + 1 * w]); // (1,1) untouched
}

test "out-of-range coordinates and wrong-length buffers are typed errors" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 16, .axes = &.{ 4, 4 } });
    var buf: [4]i16 = undefined;
    try testing.expectError(error.BadDimensions, img.readPixels(i16, &.{ 4, 0 }, &buf, .{}));
    try testing.expectError(error.BadDimensions, img.readPixels(i16, &.{0}, &buf, .{}));
    var wrong: [10]i16 = undefined;
    try testing.expectError(error.BadDimensions, img.readAll(i16, &wrong, .{}));
}

test "signed-byte convention: BITPIX=8 + BZERO=-128 round-trips as i8 (IMG-6)" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 8, .axes = &.{5} });
    const sc: Scaling = .{ .bscale = 1, .bzero = -128 }; // signed-byte convention
    const vals = [_]i8{ -128, -1, 0, 1, 127 };
    try img.writeAll(i8, &vals, .{ .scaling = sc });
    // Raw stored bytes are the unsigned biased values 0..255.
    var raw: [5]u8 = undefined;
    try img.readAll(u8, &raw, .{ .scaling = .{ .mode = .raw } });
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 127, 128, 129, 255 }, &raw);
    var out: [5]i8 = undefined;
    try img.readAll(i8, &out, .{ .scaling = sc });
    try testing.expectEqualSlices(i8, &vals, &out); // full i8 range round-trips
}

test "multi-chunk transfer stays correct across the chunk boundary" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    const n = CHUNK_ELEMS * 2 + 37;
    const src = try testing.allocator.alloc(i32, n);
    defer testing.allocator.free(src);
    for (src, 0..) |*s, i| s.* = @intCast(@as(i64, @intCast(i)) - 1000);
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 32, .axes = &.{n} });
    try img.writeAll(i32, src, .{});
    const out = try testing.allocator.alloc(i32, n);
    defer testing.allocator.free(out);
    try img.readAll(i32, out, .{});
    try testing.expectEqualSlices(i32, src, out);
}
