//! Image data access: type model and contiguous pixel I/O (FR-IMG-1/2/3/9, §11.1, §11.2).
//!
//! An `ImageView` presents an HDU's image array over all six `BITPIX` values and `NAXIS`
//! 0–999. Pixel transfers are comptime-typed in the caller's element type `T`, with
//! `convert.cast` bridging the stored type and `T` (FR-IMG-9), `endian.swapToNative` handling
//! byte order (GC-5), all in bounded, block-aligned chunks streamed through a fixed scratch
//! buffer (NFR-PERF-1/3). Linear scaling (BSCALE/BZERO), unsigned conventions, and null
//! handling layer on in IMG-2/3/4; this module is the raw-stored transfer core. The
//! whole-array calls are thin wrappers over the chunked `readPixels`/`writePixels`.
const std = @import("std");
const errors = @import("errors.zig");
const convert = @import("convert.zig");
const endian = @import("endian.zig");
const limits = @import("limits.zig");
const Fits = @import("fits.zig").Fits;
const Hdu = @import("hdu.zig").Hdu;

/// Linear scaling state (BSCALE/BZERO/BLANK). The transfer logic is added in IMG-2/IMG-4;
/// IMG-1 carries the struct so the read/write option types are stable.
pub const Scaling = struct {
    bscale: f64 = 1,
    bzero: f64 = 0,
    /// Integer null sentinel (raw, pre-scale).
    blank: ?i64 = null,
    /// Whether scaling is applied (`apply`) or stored values are exposed (`raw`).
    mode: enum { apply, raw } = .apply,
};

/// Per-call read options, element-typed so a null sentinel cannot mismatch the read type.
pub fn ReadOpts(comptime T: type) type {
    return struct {
        /// Replace `BLANK`/NaN values with this sentinel (IMG-4); ignored by IMG-1's raw core.
        null_sentinel: ?T = null,
        /// Override the HDU's scaling (IMG-2); ignored by IMG-1's raw core.
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
        return of(fits, hdu) catch unreachable; // appended HDUs are always image-like
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

    /// Read the entire array into `out` (which must hold exactly `elementCount()` elements),
    /// converting each stored value to `T` (FR-IMG-3/9).
    pub fn readAll(self: *ImageView, comptime T: type, out: []T, opts: ReadOpts(T)) ImageError!void {
        _ = opts;
        if (out.len != self.elementCount()) return error.BadDimensions;
        try self.readLinear(T, 0, out);
    }

    /// Read `out.len` contiguous pixels starting at the N-D coordinate `first` (FR-IMG-3).
    pub fn readPixels(self: *ImageView, comptime T: type, first: []const u64, out: []T, opts: ReadOpts(T)) ImageError!void {
        _ = opts;
        const start = try self.linearIndex(first);
        const total = self.elementCount();
        if (start > total or out.len > total - start) return error.BadDimensions;
        try self.readLinear(T, start, out);
    }

    /// Write the entire array from `in` (must hold exactly `elementCount()` elements).
    pub fn writeAll(self: *ImageView, comptime T: type, in: []const T, opts: WriteOpts(T)) ImageError!void {
        _ = opts;
        if (in.len != self.elementCount()) return error.BadDimensions;
        try self.writeLinear(T, 0, in);
    }

    /// Write `in.len` contiguous pixels starting at the N-D coordinate `first`.
    pub fn writePixels(self: *ImageView, comptime T: type, first: []const u64, in: []const T, opts: WriteOpts(T)) ImageError!void {
        _ = opts;
        const start = try self.linearIndex(first);
        const total = self.elementCount();
        if (start > total or in.len > total - start) return error.BadDimensions;
        try self.writeLinear(T, start, in);
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

    fn readLinear(self: *ImageView, comptime T: type, first_elem: u64, out: []T) ImageError!void {
        return switch (self.hdu.bitpix) {
            8 => self.readTyped(u8, T, first_elem, out),
            16 => self.readTyped(i16, T, first_elem, out),
            32 => self.readTyped(i32, T, first_elem, out),
            64 => self.readTyped(i64, T, first_elem, out),
            -32 => self.readTyped(f32, T, first_elem, out),
            -64 => self.readTyped(f64, T, first_elem, out),
            else => error.BadBitpix,
        };
    }

    fn writeLinear(self: *ImageView, comptime T: type, first_elem: u64, in: []const T) ImageError!void {
        return switch (self.hdu.bitpix) {
            8 => self.writeTyped(u8, T, first_elem, in),
            16 => self.writeTyped(i16, T, first_elem, in),
            32 => self.writeTyped(i32, T, first_elem, in),
            64 => self.writeTyped(i64, T, first_elem, in),
            -32 => self.writeTyped(f32, T, first_elem, in),
            -64 => self.writeTyped(f64, T, first_elem, in),
            else => error.BadBitpix,
        };
    }

    fn readTyped(self: *ImageView, comptime Stored: type, comptime T: type, first_elem: u64, out: []T) ImageError!void {
        const elem = @sizeOf(Stored);
        var scratch: [CHUNK_ELEMS]Stored = undefined;
        var done: usize = 0;
        while (done < out.len) {
            const n = @min(CHUNK_ELEMS, out.len - done);
            const byte_off = self.hdu.data_off + (first_elem + done) * elem;
            const raw = std.mem.sliceAsBytes(scratch[0..n]);
            try self.fits.dev.readAll(raw, byte_off);
            endian.swapToNative(Stored, scratch[0..n]);
            for (scratch[0..n], 0..) |s, i| out[done + i] = try convert.cast(T, s, .bulk);
            done += n;
        }
    }

    fn writeTyped(self: *ImageView, comptime Stored: type, comptime T: type, first_elem: u64, in: []const T) ImageError!void {
        const elem = @sizeOf(Stored);
        var scratch: [CHUNK_ELEMS]Stored = undefined;
        var done: usize = 0;
        while (done < in.len) {
            const n = @min(CHUNK_ELEMS, in.len - done);
            for (in[done .. done + n], 0..) |v, i| scratch[i] = try convert.cast(Stored, v, .bulk);
            endian.swapToBig(Stored, scratch[0..n]);
            const raw = std.mem.sliceAsBytes(scratch[0..n]);
            const byte_off = self.hdu.data_off + (first_elem + done) * elem;
            try self.fits.dev.writeAll(raw, byte_off);
            done += n;
        }
    }
};

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
        try testing.expectEqual(@as(u64, w * h), img.elementCount());
        var out: [w * h]f32 = undefined;
        try img.readAll(f32, &out, .{});
        try testing.expectEqualSlices(f32, &pixels, &out);
    }
}

test "every BITPIX round-trips through the stored type" {
    const cases = [_]i64{ 8, 16, 32, 64, -32, -64 };
    inline for (cases) |bp| {
        var mem = MemoryDevice.init(testing.allocator);
        defer mem.deinit();
        const n = 100;
        var src: [n]i64 = undefined;
        for (&src, 0..) |*s, i| s.* = @intCast(i + 1);

        var f = try Fits.create(testing.allocator, mem.device(), .{});
        defer f.deinit();
        var img = try ImageView.append(&f, .{ .bitpix = bp, .axes = &.{n} });
        // Write as i64; the view converts to the stored type (bulk).
        try img.writeAll(i64, &src, .{});
        var out: [n]i64 = undefined;
        try img.readAll(i64, &out, .{});
        try testing.expectEqualSlices(i64, &src, &out);
    }
}

test "readPixels reads a contiguous N-D run with correct column-major offset" {
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

    // Read 5 pixels starting at (0,2): linear index = 0 + 2*5 = 10.
    var run: [5]i32 = undefined;
    try img.readPixels(i32, &.{ 0, 2 }, &run, .{});
    try testing.expectEqualSlices(i32, pixels[10..15], &run);

    // A single pixel at (3,1): index 3 + 1*5 = 8.
    var one: [1]i32 = undefined;
    try img.readPixels(i32, &.{ 3, 1 }, &one, .{});
    try testing.expectEqual(@as(i32, 80), one[0]);
}

test "out-of-range coordinates and wrong-length buffers are typed errors" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 16, .axes = &.{ 4, 4 } });

    var buf: [4]i16 = undefined;
    try testing.expectError(error.BadDimensions, img.readPixels(i16, &.{ 4, 0 }, &buf, .{})); // x out of range
    try testing.expectError(error.BadDimensions, img.readPixels(i16, &.{0}, &buf, .{})); // wrong dimensionality
    var wrong: [10]i16 = undefined;
    try testing.expectError(error.BadDimensions, img.readAll(i16, &wrong, .{})); // wrong total length
}

test "multi-chunk transfer stays correct across the chunk boundary" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    const n = CHUNK_ELEMS * 2 + 37; // forces 3 chunks
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

test "wrong HDU type for an image view" {
    // A binary-table HDU cannot be viewed as an image (constructed minimally here is overkill;
    // instead assert the kind gate directly via a fabricated table-like Hdu is not trivial, so
    // this is covered by table tests). Placeholder asserts the gate compiles.
    try testing.expect(@import("hdu.zig").HduKind.binary_table.isImageLike() == false);
}
