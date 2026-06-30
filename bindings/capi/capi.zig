//! zigfitsio C-ABI shim — the `export fn zf_*` surface consumed by the Python (ctypes)
//! bindings and any other C caller.
//!
//! Design (see `bindings/c/zigfitsio.h` for the matching contract):
//!   * Opaque handles: `ZfFits*` (a `*abi.Handle`) and `ZfTable*` (a `*abi.TableHandle`).
//!   * The comptime-generic library calls are monomorphized behind runtime `ZfType` codes.
//!   * Every fallible call returns a CFITSIO-compatible `c_int` status (0 = OK); the thread
//!     local last-error (message + diagnostics) is readable via `zf_errmsg`/`zf_last_*`.
//!   * Strings use caller-buffer + length-query, except genuinely variable values which are
//!     allocate-and-return and released with `zf_free`.
//!
//! This file holds only `export fn`s and their private generic helpers; the handle/allocator/
//! option plumbing lives in `abi.zig`.
const std = @import("std");
const fits = @import("zigfitsio");
const abi = @import("abi.zig");

const Handle = abi.Handle;
const ZfType = abi.ZfType;
const ZfScaling = abi.ZfScaling;
const ZfOpenOpts = abi.ZfOpenOpts;
const gpa = abi.gpa;

// ════════════════════════════════════════════════════════════════════════════════════════════
// Version & error introspection
// ════════════════════════════════════════════════════════════════════════════════════════════

/// Library version string (NUL-terminated, static).
pub export fn zf_version() [*:0]const u8 {
    return fits.version;
}

/// The most-recent error status on this thread (0 if the last call succeeded).
pub export fn zf_last_status() c_int {
    return abi.last_err.status;
}

/// Copy the most-recent error message into `buf`; returns the status code. `out_len` receives
/// the full message length (may exceed `buf_len`).
pub export fn zf_errmsg(buf: [*]u8, buf_len: usize, out_len: *usize) c_int {
    abi.copyOut(abi.last_err.msg[0..abi.last_err.msg_len], buf, buf_len, out_len);
    return abi.last_err.status;
}

/// Copy the keyword/column name associated with the last error (empty if none).
pub export fn zf_last_keyword(buf: [*]u8, buf_len: usize, out_len: *usize) void {
    abi.copyOut(abi.last_err.keyword[0..abi.last_err.keyword_len], buf, buf_len, out_len);
}

/// Byte offset of the last error, or -1 if unknown.
pub export fn zf_last_byte_offset() i64 {
    return abi.last_err.byte_offset;
}

/// 1-based HDU index of the last error, or -1 if unknown.
pub export fn zf_last_hdu_index() i64 {
    return abi.last_err.hdu_index;
}

/// Release a buffer returned by an allocate-and-return getter (e.g. `zf_read_key_longstr`).
pub export fn zf_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| gpa.free(p[0..len]);
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// Lifecycle
// ════════════════════════════════════════════════════════════════════════════════════════════

fn allocHandle() ?*Handle {
    const h = gpa.create(Handle) catch return null;
    h.* = .{ .fits = undefined, .diag = .{}, .mem_dev = null };
    return h;
}

/// Open an on-disk FITS file by path. `mode`: 0 read-only, 1 read-write, 2 create.
pub export fn zf_open_file(path_ptr: [*]const u8, path_len: usize, mode: c_int, opts: ?*const ZfOpenOpts, out: *?*Handle) c_int {
    out.* = null;
    const h = allocHandle() orelse return abi.fail(null, error.OutOfMemory);
    const o = abi.optsFrom(opts, &h.diag);
    h.fits = fits.Fits.openFile(gpa, path_ptr[0..path_len], abi.modeFrom(mode), o) catch |e| {
        const code = abi.fail(&h.diag, e);
        gpa.destroy(h);
        return code;
    };
    out.* = h;
    return 0;
}

/// Create a new on-disk FITS file by path (truncating any existing file).
pub export fn zf_create_file(path_ptr: [*]const u8, path_len: usize, opts: ?*const ZfOpenOpts, out: *?*Handle) c_int {
    out.* = null;
    const h = allocHandle() orelse return abi.fail(null, error.OutOfMemory);
    const o = abi.optsFrom(opts, &h.diag);
    h.fits = fits.Fits.createFile(gpa, path_ptr[0..path_len], o) catch |e| {
        const code = abi.fail(&h.diag, e);
        gpa.destroy(h);
        return code;
    };
    out.* = h;
    return 0;
}

/// Open a FITS file held in memory (the bytes are copied into a handle-owned buffer). `mode`
/// 2 (create) is treated as read-write; use `zf_create_memory` to build a new in-RAM file.
pub export fn zf_open_memory(buf_ptr: [*]const u8, buf_len: usize, mode: c_int, opts: ?*const ZfOpenOpts, out: *?*Handle) c_int {
    out.* = null;
    const h = allocHandle() orelse return abi.fail(null, error.OutOfMemory);
    const md = gpa.create(fits.MemoryDevice) catch {
        gpa.destroy(h);
        return abi.fail(null, error.OutOfMemory);
    };
    md.* = fits.MemoryDevice.initBytes(gpa, buf_ptr[0..buf_len]) catch |e| {
        gpa.destroy(md);
        gpa.destroy(h);
        return abi.fail(null, e);
    };
    h.mem_dev = md;
    const o = abi.optsFrom(opts, &h.diag);
    const m: fits.Mode = if (abi.modeFrom(mode) == .read_write) .read_write else .read_only;
    h.fits = fits.Fits.open(gpa, md.device(), m, o) catch |e| {
        const code = abi.fail(&h.diag, e);
        md.deinit();
        gpa.destroy(md);
        gpa.destroy(h);
        return code;
    };
    out.* = h;
    return 0;
}

/// Create a new, empty FITS file in memory. Read the resulting bytes back with `zf_data_size`
/// + `zf_read_bytes`.
pub export fn zf_create_memory(opts: ?*const ZfOpenOpts, out: *?*Handle) c_int {
    out.* = null;
    const h = allocHandle() orelse return abi.fail(null, error.OutOfMemory);
    const md = gpa.create(fits.MemoryDevice) catch {
        gpa.destroy(h);
        return abi.fail(null, error.OutOfMemory);
    };
    md.* = fits.MemoryDevice.init(gpa);
    h.mem_dev = md;
    const o = abi.optsFrom(opts, &h.diag);
    h.fits = fits.Fits.create(gpa, md.device(), o) catch |e| {
        const code = abi.fail(&h.diag, e);
        md.deinit();
        gpa.destroy(md);
        gpa.destroy(h);
        return code;
    };
    out.* = h;
    return 0;
}

/// Open a whole-file gzip-compressed FITS image already in memory (`*.fits.gz` bytes).
pub export fn zf_open_gzip(buf_ptr: [*]const u8, buf_len: usize, opts: ?*const ZfOpenOpts, out: *?*Handle) c_int {
    out.* = null;
    const h = allocHandle() orelse return abi.fail(null, error.OutOfMemory);
    const o = abi.optsFrom(opts, &h.diag);
    h.fits = fits.Fits.openGzip(gpa, buf_ptr[0..buf_len], o) catch |e| {
        const code = abi.fail(&h.diag, e);
        gpa.destroy(h);
        return code;
    };
    out.* = h;
    return 0;
}

/// Flush buffered writes (and update checksums if `checksum_on_close` was set).
pub export fn zf_flush(h: *Handle) c_int {
    h.fits.flush() catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Export the handle's current bytes as a whole-file gzip stream written to `path`.
pub export fn zf_save_gzip(h: *Handle, path_ptr: [*]const u8, path_len: usize) c_int {
    h.fits.saveGzipFile(path_ptr[0..path_len]) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Total logical size in bytes of the handle's underlying device.
pub export fn zf_data_size(h: *Handle, out: *u64) c_int {
    out.* = h.fits.device().getSize() catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Read up to `len` raw bytes at `offset` from the device into `dst`; `out_read` gets the count.
pub export fn zf_read_bytes(h: *Handle, offset: u64, dst: [*]u8, len: usize, out_read: *usize) c_int {
    out_read.* = h.fits.device().pread(dst[0..len], offset) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Close a handle and free all associated resources. Safe to call with null.
pub export fn zf_close(h: ?*Handle) void {
    const hh = h orelse return;
    hh.fits.deinit();
    if (hh.mem_dev) |md| {
        md.deinit();
        gpa.destroy(md);
    }
    gpa.destroy(hh);
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// HDU navigation
// ════════════════════════════════════════════════════════════════════════════════════════════

/// Total number of HDUs (forces a full scan).
pub export fn zf_hdu_count(h: *Handle, out: *c_long) c_int {
    const n = h.fits.hduCount() catch |e| return abi.fail(&h.diag, e);
    out.* = @intCast(n);
    return 0;
}

/// Select HDU `n` (1-based) as the current HDU.
pub export fn zf_select(h: *Handle, n: c_long) c_int {
    if (n < 1) return abi.fail(&h.diag, error.WrongHduType);
    _ = h.fits.select(@intCast(n)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Move the current HDU by `delta` (relative navigation).
pub export fn zf_move(h: *Handle, delta: c_long) c_int {
    _ = h.fits.move(@intCast(delta)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Select the first extension matching `EXTNAME` (case-insensitive); if `has_extver` is set,
/// also match `EXTVER`.
pub export fn zf_select_by_name(h: *Handle, name_ptr: [*]const u8, name_len: usize, extver: c_long, has_extver: c_int) c_int {
    const ev: ?i64 = if (has_extver != 0) @intCast(extver) else null;
    _ = h.fits.selectByName(name_ptr[0..name_len], ev) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// The current HDU number (1-based).
pub export fn zf_current_hdu(h: *Handle, out: *c_long) c_int {
    if (h.fits.hdus.items.len == 0) return abi.fail(&h.diag, error.WrongHduType);
    out.* = @intCast(h.fits.chdu + 1);
    return 0;
}

/// The current HDU's kind: 0 primary, 1 image, 2 ascii_table, 3 binary_table, 4 random_groups.
pub export fn zf_hdu_type(h: *Handle, out: *c_int) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    out.* = abi.kindCode(hdu.kind);
    return 0;
}

/// Image geometry of the current HDU. Reports the uncompressed `Z*` geometry for a
/// tile-compressed image. `axes` is filled most-rapidly-varying first up to `axes_cap`;
/// `naxis_out` gets the true NAXIS, `filled` the number written.
pub export fn zf_img_param(h: *Handle, bitpix_out: *c_int, naxis_out: *c_int, axes: [*]c_long, axes_cap: c_int, filled: *c_int) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const cap: usize = if (axes_cap > 0) @intCast(axes_cap) else 0;
    const compressed = hdu.kind == .binary_table and (hdu.header.getValue(bool, "ZIMAGE") catch false);
    if (compressed) {
        bitpix_out.* = @intCast(hdu.header.getValue(i64, "ZBITPIX") catch hdu.bitpix);
        const zn = hdu.header.getValue(i64, "ZNAXIS") catch 0;
        const nax: usize = if (zn > 0 and zn <= 999) @intCast(zn) else 0;
        naxis_out.* = @intCast(nax);
        const n = @min(nax, cap);
        var name_buf: [16]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const kw = std.fmt.bufPrint(&name_buf, "ZNAXIS{d}", .{i + 1}) catch unreachable;
            axes[i] = @intCast(hdu.header.getValue(i64, kw) catch 0);
        }
        filled.* = @intCast(n);
    } else {
        bitpix_out.* = @intCast(hdu.bitpix);
        naxis_out.* = @intCast(hdu.naxis);
        const n = @min(@as(usize, hdu.naxis), cap);
        for (0..n) |i| axes[i] = @intCast(hdu.axes[i]);
        filled.* = @intCast(n);
    }
    return 0;
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// Images
// ════════════════════════════════════════════════════════════════════════════════════════════

fn axesFrom(naxis: c_int, axes: ?[*]const c_long, buf: *[999]u64) []const u64 {
    const nax: usize = if (naxis > 0) @intCast(@min(naxis, 999)) else 0;
    if (axes) |ax| {
        for (0..nax) |i| buf[i] = @intCast(ax[i]);
    }
    return buf[0..nax];
}

/// Append a new image HDU (primary if the file is empty, else an IMAGE extension).
pub export fn zf_create_img(h: *Handle, bitpix: c_int, naxis: c_int, axes: ?[*]const c_long) c_int {
    var buf: [999]u64 = undefined;
    const spec = fits.ImageSpec{ .bitpix = @intCast(bitpix), .axes = axesFrom(naxis, axes, &buf) };
    _ = h.fits.appendImageHdu(spec) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Resize / redefine the current image HDU in place.
pub export fn zf_resize_img(h: *Handle, bitpix: c_int, naxis: c_int, axes: ?[*]const c_long) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    var view = fits.ImageView.of(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    var buf: [999]u64 = undefined;
    view.reshape(@intCast(bitpix), axesFrom(naxis, axes, &buf)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

fn sentinelOf(comptime T: type, nulval: ?*const anyopaque) ?T {
    if (nulval) |nv| return @as(*const T, @ptrCast(@alignCast(nv))).*;
    return null;
}

fn flatToCoord(axes: []const u64, flat: u64, coord: []u64) void {
    var rem = flat;
    for (axes, 0..) |ax, i| {
        if (ax == 0) {
            coord[i] = 0;
            continue;
        }
        coord[i] = rem % ax;
        rem /= ax;
    }
}

fn imgReadT(comptime T: type, view: *fits.ImageView, first0: u64, ptr: *anyopaque, nelem: usize, nulval: ?*const anyopaque, sc: ?fits.Scaling) fits.Error!void {
    const out = @as([*]T, @ptrCast(@alignCast(ptr)))[0..nelem];
    const sentinel = sentinelOf(T, nulval);
    if (view.isCompressed() or (first0 == 0 and nelem == view.elementCount())) {
        return view.readAll(T, out, .{ .null_sentinel = sentinel, .scaling = sc });
    }
    var coord_buf: [999]u64 = undefined;
    const coord = coord_buf[0..view.hdu.naxis];
    flatToCoord(view.hdu.axes, first0, coord);
    return view.readPixels(T, coord, out, .{ .null_sentinel = sentinel, .scaling = sc });
}

fn imgWriteT(comptime T: type, view: *fits.ImageView, first0: u64, ptr: *const anyopaque, nelem: usize, nulval: ?*const anyopaque, sc: ?fits.Scaling) fits.Error!void {
    if (view.isCompressed()) return error.UnsupportedCodec;
    const in = @as([*]const T, @ptrCast(@alignCast(ptr)))[0..nelem];
    const sentinel = sentinelOf(T, nulval);
    if (first0 == 0 and nelem == view.elementCount()) {
        return view.writeAll(T, in, .{ .null_sentinel = sentinel, .scaling = sc });
    }
    var coord_buf: [999]u64 = undefined;
    const coord = coord_buf[0..view.hdu.naxis];
    flatToCoord(view.hdu.axes, first0, coord);
    return view.writePixels(T, coord, in, .{ .null_sentinel = sentinel, .scaling = sc });
}

fn imgRead(view: *fits.ImageView, ty: ZfType, first0: u64, ptr: *anyopaque, nelem: usize, nulval: ?*const anyopaque, sc: ?fits.Scaling) fits.Error!void {
    return switch (ty) {
        .uint8 => imgReadT(u8, view, first0, ptr, nelem, nulval, sc),
        .int8 => imgReadT(i8, view, first0, ptr, nelem, nulval, sc),
        .int16 => imgReadT(i16, view, first0, ptr, nelem, nulval, sc),
        .uint16 => imgReadT(u16, view, first0, ptr, nelem, nulval, sc),
        .int32 => imgReadT(i32, view, first0, ptr, nelem, nulval, sc),
        .uint32 => imgReadT(u32, view, first0, ptr, nelem, nulval, sc),
        .int64 => imgReadT(i64, view, first0, ptr, nelem, nulval, sc),
        .uint64 => imgReadT(u64, view, first0, ptr, nelem, nulval, sc),
        .float32 => imgReadT(f32, view, first0, ptr, nelem, nulval, sc),
        .float64 => imgReadT(f64, view, first0, ptr, nelem, nulval, sc),
        else => error.WrongValueType,
    };
}

fn imgWrite(view: *fits.ImageView, ty: ZfType, first0: u64, ptr: *const anyopaque, nelem: usize, nulval: ?*const anyopaque, sc: ?fits.Scaling) fits.Error!void {
    return switch (ty) {
        .uint8 => imgWriteT(u8, view, first0, ptr, nelem, nulval, sc),
        .int8 => imgWriteT(i8, view, first0, ptr, nelem, nulval, sc),
        .int16 => imgWriteT(i16, view, first0, ptr, nelem, nulval, sc),
        .uint16 => imgWriteT(u16, view, first0, ptr, nelem, nulval, sc),
        .int32 => imgWriteT(i32, view, first0, ptr, nelem, nulval, sc),
        .uint32 => imgWriteT(u32, view, first0, ptr, nelem, nulval, sc),
        .int64 => imgWriteT(i64, view, first0, ptr, nelem, nulval, sc),
        .uint64 => imgWriteT(u64, view, first0, ptr, nelem, nulval, sc),
        .float32 => imgWriteT(f32, view, first0, ptr, nelem, nulval, sc),
        .float64 => imgWriteT(f64, view, first0, ptr, nelem, nulval, sc),
        else => error.WrongValueType,
    };
}

/// Read `nelem` pixels of the current image starting at 1-based flat `firstelem`, converting
/// to `dtype`. `nulval` (or null) is the substituted null sentinel; `scaling` (or null)
/// overrides BSCALE/BZERO/BLANK.
pub export fn zf_read_img(h: *Handle, dtype: c_int, firstelem: c_long, nelem: c_long, nulval: ?*const anyopaque, scaling: ?*const ZfScaling, array: *anyopaque) c_int {
    if (nelem <= 0) return 0;
    if (firstelem < 1) return abi.fail(&h.diag, error.BadDimensions);
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    var view = fits.ImageView.of(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    const sc: ?fits.Scaling = if (scaling) |s| abi.toScaling(s.*) else null;
    imgRead(&view, @enumFromInt(dtype), @intCast(firstelem - 1), array, @intCast(nelem), nulval, sc) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Write `nelem` pixels to the current image starting at 1-based flat `firstelem`.
pub export fn zf_write_img(h: *Handle, dtype: c_int, firstelem: c_long, nelem: c_long, nulval: ?*const anyopaque, scaling: ?*const ZfScaling, array: *const anyopaque) c_int {
    if (nelem <= 0) return 0;
    if (firstelem < 1) return abi.fail(&h.diag, error.BadDimensions);
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    var view = fits.ImageView.of(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    const sc: ?fits.Scaling = if (scaling) |s| abi.toScaling(s.*) else null;
    imgWrite(&view, @enumFromInt(dtype), @intCast(firstelem - 1), array, @intCast(nelem), nulval, sc) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

const Dir = enum { read, write };

fn sectionT(comptime T: type, comptime dir: Dir, view: *fits.ImageView, lower: []const u64, upper: []const u64, stride: ?[]const u64, ptr: *anyopaque, nelem: usize, nulval: ?*const anyopaque, sc: ?fits.Scaling) fits.Error!void {
    const sentinel = sentinelOf(T, nulval);
    if (dir == .read) {
        const out = @as([*]T, @ptrCast(@alignCast(ptr)))[0..nelem];
        return view.readSection(T, lower, upper, stride, out, .{ .null_sentinel = sentinel, .scaling = sc });
    } else {
        const in = @as([*]const T, @ptrCast(@alignCast(ptr)))[0..nelem];
        return view.writeSection(T, lower, upper, stride, in, .{ .null_sentinel = sentinel, .scaling = sc });
    }
}

fn sectionDispatch(comptime dir: Dir, view: *fits.ImageView, ty: ZfType, lower: []const u64, upper: []const u64, stride: ?[]const u64, ptr: *anyopaque, nelem: usize, nulval: ?*const anyopaque, sc: ?fits.Scaling) fits.Error!void {
    return switch (ty) {
        .uint8 => sectionT(u8, dir, view, lower, upper, stride, ptr, nelem, nulval, sc),
        .int8 => sectionT(i8, dir, view, lower, upper, stride, ptr, nelem, nulval, sc),
        .int16 => sectionT(i16, dir, view, lower, upper, stride, ptr, nelem, nulval, sc),
        .uint16 => sectionT(u16, dir, view, lower, upper, stride, ptr, nelem, nulval, sc),
        .int32 => sectionT(i32, dir, view, lower, upper, stride, ptr, nelem, nulval, sc),
        .uint32 => sectionT(u32, dir, view, lower, upper, stride, ptr, nelem, nulval, sc),
        .int64 => sectionT(i64, dir, view, lower, upper, stride, ptr, nelem, nulval, sc),
        .uint64 => sectionT(u64, dir, view, lower, upper, stride, ptr, nelem, nulval, sc),
        .float32 => sectionT(f32, dir, view, lower, upper, stride, ptr, nelem, nulval, sc),
        .float64 => sectionT(f64, dir, view, lower, upper, stride, ptr, nelem, nulval, sc),
        else => error.WrongValueType,
    };
}

fn fillBounds(naxis: c_int, lower: [*]const c_long, upper: [*]const c_long, inc: ?[*]const c_long, lo: *[999]u64, hi: *[999]u64, st: *[999]u64) usize {
    const nax: usize = if (naxis > 0) @intCast(@min(naxis, 999)) else 0;
    for (0..nax) |i| {
        lo[i] = @intCast(lower[i]);
        hi[i] = @intCast(upper[i]);
        st[i] = if (inc) |c| @intCast(c[i]) else 1;
    }
    return nax;
}

/// Read a rectangular section (0-based inclusive `lower..upper`, optional per-axis `inc`).
pub export fn zf_read_subset(h: *Handle, dtype: c_int, naxis: c_int, lower: [*]const c_long, upper: [*]const c_long, inc: ?[*]const c_long, nelem: c_long, nulval: ?*const anyopaque, scaling: ?*const ZfScaling, array: *anyopaque) c_int {
    if (nelem < 0) return abi.fail(&h.diag, error.BadDimensions);
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    var view = fits.ImageView.of(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    var lo: [999]u64 = undefined;
    var hi: [999]u64 = undefined;
    var stb: [999]u64 = undefined;
    const n = fillBounds(naxis, lower, upper, inc, &lo, &hi, &stb);
    const stride: ?[]const u64 = if (inc != null) stb[0..n] else null;
    const sc: ?fits.Scaling = if (scaling) |s| abi.toScaling(s.*) else null;
    sectionDispatch(.read, &view, @enumFromInt(dtype), lo[0..n], hi[0..n], stride, array, @intCast(nelem), nulval, sc) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Write a rectangular section (symmetric with `zf_read_subset`).
pub export fn zf_write_subset(h: *Handle, dtype: c_int, naxis: c_int, lower: [*]const c_long, upper: [*]const c_long, inc: ?[*]const c_long, nelem: c_long, nulval: ?*const anyopaque, scaling: ?*const ZfScaling, array: *anyopaque) c_int {
    if (nelem < 0) return abi.fail(&h.diag, error.BadDimensions);
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    var view = fits.ImageView.of(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    var lo: [999]u64 = undefined;
    var hi: [999]u64 = undefined;
    var stb: [999]u64 = undefined;
    const n = fillBounds(naxis, lower, upper, inc, &lo, &hi, &stb);
    const stride: ?[]const u64 = if (inc != null) stb[0..n] else null;
    const sc: ?fits.Scaling = if (scaling) |s| abi.toScaling(s.*) else null;
    sectionDispatch(.write, &view, @enumFromInt(dtype), lo[0..n], hi[0..n], stride, array, @intCast(nelem), nulval, sc) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// Header
// ════════════════════════════════════════════════════════════════════════════════════════════

fn endIndex(hdr: *const fits.Header) usize {
    var i: usize = 0;
    while (i < hdr.count()) : (i += 1) if (hdr.at(i).kind == .end) return i;
    return hdr.count();
}

fn commentOf(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    return if (ptr) |p| p[0..len] else null;
}

/// Number of header cards in the current HDU (including END).
pub export fn zf_card_count(h: *Handle, out: *c_long) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    out.* = @intCast(hdu.header.count());
    return 0;
}

/// Copy the raw 80 bytes of card `index` (0-based) into `buf80`.
pub export fn zf_read_card(h: *Handle, index: c_long, buf80: [*]u8) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    if (index < 0 or @as(usize, @intCast(index)) >= hdu.header.count()) return abi.fail(&h.diag, error.KeywordNotFound);
    const card = hdu.header.at(@intCast(index));
    @memcpy(buf80[0..80], card.bytes()[0..80]);
    return 0;
}

/// Whether keyword `name` exists in the current header.
pub export fn zf_key_exists(h: *Handle, name_ptr: [*]const u8, name_len: usize) c_int {
    const hdu = h.cur() catch return 0;
    return if (hdu.header.has(name_ptr[0..name_len])) 1 else 0;
}

/// Read an integer-valued keyword.
pub export fn zf_read_key_lng(h: *Handle, name_ptr: [*]const u8, name_len: usize, out: *c_longlong) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    out.* = @intCast(hdu.header.getValue(i64, name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e));
    return 0;
}

/// Read a floating-valued keyword.
pub export fn zf_read_key_dbl(h: *Handle, name_ptr: [*]const u8, name_len: usize, out: *f64) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    out.* = hdu.header.getValue(f64, name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Read a logical (boolean) keyword as 0/1.
pub export fn zf_read_key_log(h: *Handle, name_ptr: [*]const u8, name_len: usize, out: *c_int) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const b = hdu.header.getValue(bool, name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e);
    out.* = if (b) 1 else 0;
    return 0;
}

/// Read a string-valued keyword into `buf`; `out_len` gets the full length.
pub export fn zf_read_key_str(h: *Handle, name_ptr: [*]const u8, name_len: usize, buf: [*]u8, buf_len: usize, out_len: *usize) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const s = hdu.header.getString(gpa, name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e);
    defer gpa.free(s);
    abi.copyOut(s, buf, buf_len, out_len);
    return 0;
}

/// Read a (possibly CONTINUE-continued) long string. On success `out_ptr`/`out_len` own a
/// buffer the caller must release with `zf_free`.
pub export fn zf_read_key_longstr(h: *Handle, name_ptr: [*]const u8, name_len: usize, out_ptr: *?[*]u8, out_len: *usize) c_int {
    out_ptr.* = null;
    out_len.* = 0;
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const s = hdu.header.getLongString(gpa, name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e);
    out_ptr.* = s.ptr;
    out_len.* = s.len;
    return 0;
}

/// Copy keyword `name`'s comment into `buf` (empty if none).
pub export fn zf_key_comment(h: *Handle, name_ptr: [*]const u8, name_len: usize, buf: [*]u8, buf_len: usize, out_len: *usize) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const c = hdu.header.comment(name_ptr[0..name_len]) orelse {
        out_len.* = 0;
        return 0;
    };
    abi.copyOut(c, buf, buf_len, out_len);
    return 0;
}

fn writeKey(h: *Handle, name: []const u8, v: fits.KeywordValue, comment: ?[]const u8) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    hdu.header.update(gpa, name, v, comment) catch |e| return abi.fail(&h.diag, e);
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Create or update an integer keyword.
pub export fn zf_write_key_lng(h: *Handle, name_ptr: [*]const u8, name_len: usize, value: c_longlong, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    return writeKey(h, name_ptr[0..name_len], .{ .int = @intCast(value) }, commentOf(comment_ptr, comment_len));
}

/// Create or update a floating keyword.
pub export fn zf_write_key_dbl(h: *Handle, name_ptr: [*]const u8, name_len: usize, value: f64, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    return writeKey(h, name_ptr[0..name_len], .{ .float = value }, commentOf(comment_ptr, comment_len));
}

/// Create or update a logical keyword.
pub export fn zf_write_key_log(h: *Handle, name_ptr: [*]const u8, name_len: usize, value: c_int, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    return writeKey(h, name_ptr[0..name_len], .{ .logical = value != 0 }, commentOf(comment_ptr, comment_len));
}

/// Create or update a string keyword (single card; ≤ 68 chars).
pub export fn zf_write_key_str(h: *Handle, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    return writeKey(h, name_ptr[0..name_len], .{ .string = value_ptr[0..value_len] }, commentOf(comment_ptr, comment_len));
}

/// Append a long string keyword using the CONTINUE convention (inserts before END).
pub export fn zf_write_key_longstr(h: *Handle, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const name = name_ptr[0..name_len];
    hdu.header.delete(name) catch {}; // replace if present
    const cards = fits.continuation.split(gpa, name, value_ptr[0..value_len], commentOf(comment_ptr, comment_len)) catch |e| return abi.fail(&h.diag, e);
    defer gpa.free(cards);
    var idx = endIndex(&hdu.header);
    for (cards) |c| {
        hdu.header.insert(gpa, idx, c) catch |e| return abi.fail(&h.diag, e);
        idx += 1;
    }
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Delete the first card named `name`.
pub export fn zf_delete_key(h: *Handle, name_ptr: [*]const u8, name_len: usize) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    hdu.header.delete(name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e);
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Rename keyword `old` to `new`.
pub export fn zf_rename_key(h: *Handle, old_ptr: [*]const u8, old_len: usize, new_ptr: [*]const u8, new_len: usize) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    hdu.header.rename(old_ptr[0..old_len], new_ptr[0..new_len]) catch |e| return abi.fail(&h.diag, e);
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Insert a raw 80-byte card before END.
pub export fn zf_write_record(h: *Handle, card80: [*]const u8) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const card = fits.Card.parse(card80[0..80]) catch |e| return abi.fail(&h.diag, e);
    hdu.header.insert(gpa, endIndex(&hdu.header), card) catch |e| return abi.fail(&h.diag, e);
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Insert a raw 80-byte card at `index` (0-based).
pub export fn zf_insert_record(h: *Handle, index: c_long, card80: [*]const u8) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    if (index < 0 or @as(usize, @intCast(index)) > hdu.header.count()) return abi.fail(&h.diag, error.KeywordNotFound);
    const card = fits.Card.parse(card80[0..80]) catch |e| return abi.fail(&h.diag, e);
    hdu.header.insert(gpa, @intCast(index), card) catch |e| return abi.fail(&h.diag, e);
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// Tables (binary + ASCII) and VLAs
// ════════════════════════════════════════════════════════════════════════════════════════════

const TableHandle = abi.TableHandle;
const ZfColInfo = abi.ZfColInfo;
const tc = fits.table_common;

fn kwName(buf: *[16]u8, comptime prefix: []const u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "{d}", .{n}) catch unreachable;
}

fn binTypeCode(t: tc.BinaryType) abi.ZfType {
    return switch (t) {
        .logical => .boolean,
        .bit => .bit,
        .byte => .uint8,
        .int16 => .int16,
        .int32 => .int32,
        .int64 => .int64,
        .char => .string,
        .float32 => .float32,
        .float64 => .float64,
        .complex32 => .complex64,
        .complex64 => .complex128,
        .vla32, .vla64 => .uint8,
    };
}

fn asciiTypeCode(t: tc.AsciiType) abi.ZfType {
    return switch (t) {
        .char => .string,
        .int => .int64,
        .fixed, .exp_single, .exp_double => .float64,
    };
}

fn createTbl(h: *Handle, table_type: c_int, nrows: c_longlong, ncols: c_int, ttype: [*]const ?[*:0]const u8, tform: [*]const ?[*:0]const u8, tunit: ?[*]const ?[*:0]const u8, extname: ?[*:0]const u8) fits.Error!void {
    const nc: usize = if (ncols > 0) @intCast(ncols) else 0;
    const ascii = table_type == 1;

    var hdr = fits.Header.initEmpty();
    var owned = true;
    errdefer if (owned) hdr.deinit(gpa);

    const tbcols = try gpa.alloc(u64, nc);
    defer gpa.free(tbcols);
    var naxis1: u64 = 0;
    if (ascii) {
        var off: u64 = 1;
        for (0..nc) |i| {
            const at = try tc.AsciiTform.parse(std.mem.span(tform[i].?));
            tbcols[i] = off;
            naxis1 = off + at.width - 1;
            off = off + at.width + 1; // one-space gap between fields
        }
    } else {
        for (0..nc) |i| {
            const bt = try tc.BinTform.parse(std.mem.span(tform[i].?));
            naxis1 = try @import("std").math.add(u64, naxis1, try bt.fieldBytes());
        }
    }

    try hdr.appendValue(gpa, "XTENSION", .{ .string = if (ascii) "TABLE" else "BINTABLE" }, null);
    try hdr.appendValue(gpa, "BITPIX", .{ .int = 8 }, null);
    try hdr.appendValue(gpa, "NAXIS", .{ .int = 2 }, null);
    try hdr.appendValue(gpa, "NAXIS1", .{ .int = @intCast(naxis1) }, null);
    try hdr.appendValue(gpa, "NAXIS2", .{ .int = nrows }, null);
    try hdr.appendValue(gpa, "PCOUNT", .{ .int = 0 }, null);
    try hdr.appendValue(gpa, "GCOUNT", .{ .int = 1 }, null);
    try hdr.appendValue(gpa, "TFIELDS", .{ .int = @intCast(nc) }, null);
    var buf: [16]u8 = undefined;
    for (0..nc) |i| {
        const n = i + 1;
        try hdr.appendValue(gpa, kwName(&buf, "TFORM", n), .{ .string = std.mem.span(tform[i].?) }, null);
        if (ttype[i]) |tt| try hdr.appendValue(gpa, kwName(&buf, "TTYPE", n), .{ .string = std.mem.span(tt) }, null);
        if (ascii) try hdr.appendValue(gpa, kwName(&buf, "TBCOL", n), .{ .int = @intCast(tbcols[i]) }, null);
        if (tunit) |tu| {
            if (tu[i]) |u| try hdr.appendValue(gpa, kwName(&buf, "TUNIT", n), .{ .string = std.mem.span(u) }, null);
        }
    }
    if (extname) |en| try hdr.appendValue(gpa, "EXTNAME", .{ .string = std.mem.span(en) }, null);
    try hdr.ensureEnd(gpa);

    owned = false; // appendHdu takes ownership (and frees on its own error)
    _ = try h.fits.appendHdu(hdr);
}

/// Create and append a new table HDU. `table_type`: 0 binary, 1 ASCII. `ttype`/`tform` are
/// arrays of `ncols` NUL-terminated C strings; `tunit` is an optional array; `extname` optional.
pub export fn zf_create_tbl(h: *Handle, table_type: c_int, nrows: c_longlong, ncols: c_int, ttype: [*]const ?[*:0]const u8, tform: [*]const ?[*:0]const u8, tunit: ?[*]const ?[*:0]const u8, extname: ?[*:0]const u8) c_int {
    createTbl(h, table_type, nrows, ncols, ttype, tform, tunit, extname) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Open a table view over the current HDU.
pub export fn zf_table_open(h: *Handle, out: *?*TableHandle) c_int {
    out.* = null;
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const th = gpa.create(TableHandle) catch return abi.fail(null, error.OutOfMemory);
    th.* = .{ .owner = h, .kind = .binary };
    switch (hdu.kind) {
        .binary_table => {
            th.kind = .binary;
            th.bin = fits.BinTable.of(&h.fits, hdu) catch |e| {
                gpa.destroy(th);
                return abi.fail(&h.diag, e);
            };
        },
        .ascii_table => {
            th.kind = .ascii;
            th.asc = fits.AsciiTable.of(&h.fits, hdu) catch |e| {
                gpa.destroy(th);
                return abi.fail(&h.diag, e);
            };
        },
        else => {
            gpa.destroy(th);
            return abi.fail(&h.diag, error.WrongHduType);
        },
    }
    out.* = th;
    return 0;
}

/// Close a table view.
pub export fn zf_table_close(t: ?*TableHandle) void {
    const th = t orelse return;
    th.deinit();
    gpa.destroy(th);
}

/// Number of rows in the table.
pub export fn zf_table_nrows(t: *TableHandle, out: *c_longlong) c_int {
    out.* = @intCast(switch (t.kind) {
        .binary => t.bin.?.rowCount(),
        .ascii => t.asc.?.rowCount(),
    });
    return 0;
}

/// Number of columns in the table.
pub export fn zf_table_ncols(t: *TableHandle, out: *c_int) c_int {
    out.* = @intCast(switch (t.kind) {
        .binary => t.bin.?.columnCount(),
        .ascii => t.asc.?.columnCount(),
    });
    return 0;
}

fn resolveCol(t: *TableHandle, name: []const u8) fits.Error!u16 {
    switch (t.kind) {
        .binary => return t.bin.?.resolve(.{ .name = name }),
        .ascii => {
            var m: fits.Matches = .{};
            t.asc.?.columnByName(name, &m);
            if (m.len == 0) return error.NoSuchColumn;
            if (m.len > 1) return error.AmbiguousColumn;
            return @intCast(m.at(0));
        },
    }
}

/// Resolve a column name (case-insensitive, wildcards) to a 0-based index.
pub export fn zf_table_colnum(t: *TableHandle, name_ptr: [*]const u8, name_len: usize, out: *c_int) c_int {
    const idx = resolveCol(t, name_ptr[0..name_len]) catch |e| return abi.fail(&t.owner.diag, e);
    out.* = @intCast(idx);
    return 0;
}

/// Fill `info` with metadata for 0-based column `col`.
pub export fn zf_table_col_info(t: *TableHandle, col: c_int, info: *ZfColInfo) c_int {
    const ci: usize = if (col >= 0) @intCast(col) else return abi.fail(&t.owner.diag, error.NoSuchColumn);
    info.* = .{};
    switch (t.kind) {
        .binary => {
            if (ci >= t.bin.?.columns.len) return abi.fail(&t.owner.diag, error.NoSuchColumn);
            const c = &t.bin.?.columns[ci];
            info.tform_char = c.tform.type.toChar();
            info.tscal = c.scal;
            info.tzero = c.zero;
            if (c.tnull) |tn| {
                info.has_tnull = 1;
                info.tnull = tn;
            }
            info.width = @intCast(c.tform.fieldBytes() catch 0);
            if (c.tform.type.isVla()) {
                info.is_vla = 1;
                info.typecode = @intFromEnum(binTypeCode(c.tform.vla_elem orelse .byte));
                info.repeat = -1; // variable
            } else {
                info.typecode = @intFromEnum(binTypeCode(c.tform.type));
                info.repeat = @intCast(c.tform.repeat);
            }
        },
        .ascii => {
            if (ci >= t.asc.?.columns.len) return abi.fail(&t.owner.diag, error.NoSuchColumn);
            const c = &t.asc.?.columns[ci];
            info.tform_char = c.tform.type.toChar();
            info.tscal = c.tscal;
            info.tzero = c.tzero;
            info.typecode = @intFromEnum(asciiTypeCode(c.tform.type));
            info.width = @intCast(c.tform.width);
            info.repeat = if (c.tform.type == .char) @intCast(c.tform.width) else 1;
        },
    }
    return 0;
}

fn colNameUnit(t: *TableHandle, col: usize, want_unit: bool) ?[]const u8 {
    switch (t.kind) {
        .binary => {
            if (col >= t.bin.?.columns.len) return null;
            return if (want_unit) null else t.bin.?.columns[col].name;
        },
        .ascii => {
            if (col >= t.asc.?.columns.len) return null;
            const c = &t.asc.?.columns[col];
            return if (want_unit) c.unit else c.name;
        },
    }
}

/// Copy 0-based column `col`'s name (`TTYPEn`) into `buf`.
pub export fn zf_table_col_name(t: *TableHandle, col: c_int, buf: [*]u8, buf_len: usize, out_len: *usize) c_int {
    const ci: usize = if (col >= 0) @intCast(col) else return abi.fail(&t.owner.diag, error.NoSuchColumn);
    abi.copyOut(colNameUnit(t, ci, false) orelse "", buf, buf_len, out_len);
    return 0;
}

/// Copy 0-based column `col`'s unit (`TUNITn`) into `buf`.
pub export fn zf_table_col_unit(t: *TableHandle, col: c_int, buf: [*]u8, buf_len: usize, out_len: *usize) c_int {
    const ci: usize = if (col >= 0) @intCast(col) else return abi.fail(&t.owner.diag, error.NoSuchColumn);
    abi.copyOut(colNameUnit(t, ci, true) orelse "", buf, buf_len, out_len);
    return 0;
}

fn defaultFill(comptime T: type, sentinel: ?T) T {
    if (sentinel) |s| return s;
    return switch (@typeInfo(T)) {
        .float => std.math.nan(T),
        else => 0,
    };
}

fn colT(comptime T: type, comptime dir: Dir, t: *TableHandle, col: u16, first_row: u64, ptr: *anyopaque, nelem: usize, nulval: ?*const anyopaque) fits.Error!void {
    switch (t.kind) {
        .binary => {
            const tbl = &t.bin.?;
            if (dir == .read) {
                const out = @as([*]T, @ptrCast(@alignCast(ptr)))[0..nelem];
                try tbl.readColumn(T, .{ .index = col }, first_row, out, .{ .null_sentinel = sentinelOf(T, nulval) });
            } else {
                const in = @as([*]const T, @ptrCast(@alignCast(ptr)))[0..nelem];
                try tbl.writeColumn(T, .{ .index = col }, first_row, in, .{ .null_sentinel = sentinelOf(T, nulval) });
            }
        },
        .ascii => {
            const tbl = &t.asc.?;
            const tmp = try gpa.alloc(?T, nelem);
            defer gpa.free(tmp);
            if (dir == .read) {
                try tbl.readColumn(T, .{ .index = col }, first_row, tmp);
                const out = @as([*]T, @ptrCast(@alignCast(ptr)))[0..nelem];
                const sentinel = sentinelOf(T, nulval);
                for (out, tmp) |*o, v| o.* = v orelse defaultFill(T, sentinel);
            } else {
                const in = @as([*]const T, @ptrCast(@alignCast(ptr)))[0..nelem];
                const sentinel = sentinelOf(T, nulval);
                for (tmp, in) |*slot, v| slot.* = if (sentinel) |s| (if (v == s) null else v) else v;
                try tbl.writeColumn(T, .{ .index = col }, first_row, tmp);
            }
        },
    }
}

fn colDispatch(comptime dir: Dir, t: *TableHandle, ty: ZfType, col: u16, first_row: u64, ptr: *anyopaque, nelem: usize, nulval: ?*const anyopaque) fits.Error!void {
    return switch (ty) {
        .uint8 => colT(u8, dir, t, col, first_row, ptr, nelem, nulval),
        .int8 => colT(i8, dir, t, col, first_row, ptr, nelem, nulval),
        .int16 => colT(i16, dir, t, col, first_row, ptr, nelem, nulval),
        .uint16 => colT(u16, dir, t, col, first_row, ptr, nelem, nulval),
        .int32 => colT(i32, dir, t, col, first_row, ptr, nelem, nulval),
        .uint32 => colT(u32, dir, t, col, first_row, ptr, nelem, nulval),
        .int64 => colT(i64, dir, t, col, first_row, ptr, nelem, nulval),
        .uint64 => colT(u64, dir, t, col, first_row, ptr, nelem, nulval),
        .float32 => colT(f32, dir, t, col, first_row, ptr, nelem, nulval),
        .float64 => colT(f64, dir, t, col, first_row, ptr, nelem, nulval),
        else => error.WrongValueType,
    };
}

/// Read `nelem` elements of 0-based column `col` starting at 1-based `firstrow`, as `dtype`.
pub export fn zf_read_col(t: *TableHandle, dtype: c_int, col: c_int, firstrow: c_longlong, nelem: c_longlong, nulval: ?*const anyopaque, array: *anyopaque) c_int {
    if (nelem <= 0) return 0;
    if (col < 0 or firstrow < 1) return abi.fail(&t.owner.diag, error.CellOutOfRange);
    colDispatch(.read, t, @enumFromInt(dtype), @intCast(col), @intCast(firstrow - 1), array, @intCast(nelem), nulval) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Write `nelem` elements to 0-based column `col` starting at 1-based `firstrow`, from `dtype`.
pub export fn zf_write_col(t: *TableHandle, dtype: c_int, col: c_int, firstrow: c_longlong, nelem: c_longlong, nulval: ?*const anyopaque, array: *anyopaque) c_int {
    if (nelem <= 0) return 0;
    if (col < 0 or firstrow < 1) return abi.fail(&t.owner.diag, error.CellOutOfRange);
    colDispatch(.write, t, @enumFromInt(dtype), @intCast(col), @intCast(firstrow - 1), array, @intCast(nelem), nulval) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Read `nrows` text cells of character column `col` (0-based) starting at 1-based `firstrow`,
/// each into `buf[i*stride .. i*stride+width]` (raw fixed-width field bytes).
pub export fn zf_read_col_str(t: *TableHandle, col: c_int, firstrow: c_longlong, nrows: c_longlong, width: c_longlong, stride: c_longlong, buf: [*]u8) c_int {
    if (nrows <= 0) return 0;
    if (col < 0 or firstrow < 1 or width < 0 or stride < width) return abi.fail(&t.owner.diag, error.CellOutOfRange);
    const w: usize = @intCast(width);
    const st: usize = @intCast(stride);
    const c: u16 = @intCast(col);
    var i: usize = 0;
    while (i < @as(usize, @intCast(nrows))) : (i += 1) {
        const row: u64 = @intCast(firstrow - 1 + @as(c_longlong, @intCast(i)));
        const dst = buf[i * st ..][0..w];
        switch (t.kind) {
            .binary => t.bin.?.readCell(u8, .{ .index = c }, row, dst, .{}) catch |e| return abi.fail(&t.owner.diag, e),
            .ascii => {
                _ = t.asc.?.readCellStr(.{ .index = c }, row, dst) catch |e| return abi.fail(&t.owner.diag, e);
            },
        }
    }
    return 0;
}

/// Write `nrows` text cells of character column `col` (0-based) starting at 1-based `firstrow`,
/// each from `buf[i*stride .. i*stride+width]`.
pub export fn zf_write_col_str(t: *TableHandle, col: c_int, firstrow: c_longlong, nrows: c_longlong, width: c_longlong, stride: c_longlong, buf: [*]const u8) c_int {
    if (nrows <= 0) return 0;
    if (col < 0 or firstrow < 1 or width < 0 or stride < width) return abi.fail(&t.owner.diag, error.CellOutOfRange);
    const w: usize = @intCast(width);
    const st: usize = @intCast(stride);
    const c: u16 = @intCast(col);
    var i: usize = 0;
    while (i < @as(usize, @intCast(nrows))) : (i += 1) {
        const row: u64 = @intCast(firstrow - 1 + @as(c_longlong, @intCast(i)));
        const src = buf[i * st ..][0..w];
        switch (t.kind) {
            .binary => t.bin.?.writeCell(u8, .{ .index = c }, row, src, .{}) catch |e| return abi.fail(&t.owner.diag, e),
            .ascii => t.asc.?.writeCellStr(.{ .index = c }, row, std.mem.trimEnd(u8, src, " \x00")) catch |e| return abi.fail(&t.owner.diag, e),
        }
    }
    return 0;
}

// ── Structural row/column editing (binary tables) ─────────────────────────────────────────────

fn requireBinary(t: *TableHandle) fits.Error!*fits.BinTable {
    if (t.kind != .binary) return error.WrongHduType;
    return &t.bin.?;
}

/// Append `n` empty rows to a binary table.
pub export fn zf_append_rows(t: *TableHandle, n: c_longlong) c_int {
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    tbl.appendRows(@intCast(n)) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Insert `n` empty rows before 0-based `before_row` in a binary table.
pub export fn zf_insert_rows(t: *TableHandle, before_row: c_longlong, n: c_longlong) c_int {
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    tbl.insertRows(@intCast(before_row), @intCast(n)) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Delete `n` rows starting at 0-based `first_row` in a binary table.
pub export fn zf_delete_rows(t: *TableHandle, first_row: c_longlong, n: c_longlong) c_int {
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    tbl.deleteRows(@intCast(first_row), @intCast(n)) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Insert a new column at 0-based `at` in a binary table.
pub export fn zf_insert_col(t: *TableHandle, at: c_int, tform: [*:0]const u8, ttype: ?[*:0]const u8) c_int {
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    const tt: ?[]const u8 = if (ttype) |p| std.mem.span(p) else null;
    tbl.insertColumn(gpa, @intCast(at), std.mem.span(tform), tt) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Delete 0-based column `col` from a binary table.
pub export fn zf_delete_col(t: *TableHandle, col: c_int) c_int {
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    tbl.deleteColumn(@intCast(col)) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

// ── Variable-length arrays ────────────────────────────────────────────────────────────────────

/// Read the (len, offset) descriptor of a VLA cell (1-based `row`).
pub export fn zf_read_descript(t: *TableHandle, col: c_int, row: c_longlong, out_len: *c_longlong, out_off: *c_longlong) c_int {
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    const d = fits.heap.readDescriptor(tbl, .{ .index = @intCast(col) }, @intCast(row - 1)) catch |e| return abi.fail(&t.owner.diag, e);
    out_len.* = d.len;
    out_off.* = d.off;
    return 0;
}

fn vlaReadT(comptime T: type, tbl: *fits.BinTable, col: u16, row: u64, array: *anyopaque, cap: usize, out_nelem: *c_longlong) fits.Error!void {
    const data = try fits.heap.readVlaCell(gpa, tbl, .{ .index = col }, row, T);
    defer gpa.free(data);
    out_nelem.* = @intCast(data.len);
    const n = @min(data.len, cap);
    if (n != 0) @memcpy(@as([*]T, @ptrCast(@alignCast(array)))[0..n], data[0..n]);
}

fn vlaRead(ty: ZfType, tbl: *fits.BinTable, col: u16, row: u64, array: *anyopaque, cap: usize, out_nelem: *c_longlong) fits.Error!void {
    return switch (ty) {
        .uint8 => vlaReadT(u8, tbl, col, row, array, cap, out_nelem),
        .int8 => vlaReadT(i8, tbl, col, row, array, cap, out_nelem),
        .int16 => vlaReadT(i16, tbl, col, row, array, cap, out_nelem),
        .uint16 => vlaReadT(u16, tbl, col, row, array, cap, out_nelem),
        .int32 => vlaReadT(i32, tbl, col, row, array, cap, out_nelem),
        .uint32 => vlaReadT(u32, tbl, col, row, array, cap, out_nelem),
        .int64 => vlaReadT(i64, tbl, col, row, array, cap, out_nelem),
        .uint64 => vlaReadT(u64, tbl, col, row, array, cap, out_nelem),
        .float32 => vlaReadT(f32, tbl, col, row, array, cap, out_nelem),
        .float64 => vlaReadT(f64, tbl, col, row, array, cap, out_nelem),
        else => error.WrongValueType,
    };
}

/// Read a VLA cell (1-based `row`) into `array` (capacity `cap` elements); `out_nelem` gets the
/// true element count (may exceed `cap`).
pub export fn zf_read_col_vla(t: *TableHandle, dtype: c_int, col: c_int, row: c_longlong, cap: c_longlong, array: *anyopaque, out_nelem: *c_longlong) c_int {
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (col < 0 or row < 1 or cap < 0) return abi.fail(&t.owner.diag, error.CellOutOfRange);
    vlaRead(@enumFromInt(dtype), tbl, @intCast(col), @intCast(row - 1), array, @intCast(cap), out_nelem) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

fn vlaWriteT(comptime T: type, tbl: *fits.BinTable, mgr: *fits.heap.HeapManager, col: u16, row: u64, array: *const anyopaque, nelem: usize) fits.Error!void {
    const in = @as([*]const T, @ptrCast(@alignCast(array)))[0..nelem];
    try fits.heap.writeVlaCell(gpa, tbl, mgr, .{ .index = col }, row, T, in);
}

fn vlaWrite(ty: ZfType, tbl: *fits.BinTable, mgr: *fits.heap.HeapManager, col: u16, row: u64, array: *const anyopaque, nelem: usize) fits.Error!void {
    return switch (ty) {
        .uint8 => vlaWriteT(u8, tbl, mgr, col, row, array, nelem),
        .int8 => vlaWriteT(i8, tbl, mgr, col, row, array, nelem),
        .int16 => vlaWriteT(i16, tbl, mgr, col, row, array, nelem),
        .uint16 => vlaWriteT(u16, tbl, mgr, col, row, array, nelem),
        .int32 => vlaWriteT(i32, tbl, mgr, col, row, array, nelem),
        .uint32 => vlaWriteT(u32, tbl, mgr, col, row, array, nelem),
        .int64 => vlaWriteT(i64, tbl, mgr, col, row, array, nelem),
        .uint64 => vlaWriteT(u64, tbl, mgr, col, row, array, nelem),
        .float32 => vlaWriteT(f32, tbl, mgr, col, row, array, nelem),
        .float64 => vlaWriteT(f64, tbl, mgr, col, row, array, nelem),
        else => error.WrongValueType,
    };
}

/// Write a VLA cell (1-based `row`) from `nelem` elements of `array`. Uses a heap manager
/// created lazily for the table (assumes the heap starts empty / PCOUNT was reserved).
pub export fn zf_write_col_vla(t: *TableHandle, dtype: c_int, col: c_int, row: c_longlong, array: *const anyopaque, nelem: c_longlong) c_int {
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (col < 0 or row < 1 or nelem < 0) return abi.fail(&t.owner.diag, error.CellOutOfRange);
    if (t.mgr == null) {
        t.mgr = fits.heap.HeapManager.initForTable(tbl) catch |e| return abi.fail(&t.owner.diag, e);
    }
    vlaWrite(@enumFromInt(dtype), tbl, &t.mgr.?, @intCast(col), @intCast(row - 1), array, @intCast(nelem)) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// HDU management (delete / copy)
// ════════════════════════════════════════════════════════════════════════════════════════════

/// Delete HDU `n` (1-based).
pub export fn zf_delete_hdu(h: *Handle, n: c_long) c_int {
    if (n < 1) return abi.fail(&h.diag, error.WrongHduType);
    h.fits.deleteHdu(@intCast(n)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Copy HDU `src_n` (1-based) to the end of the file and make it current.
pub export fn zf_copy_hdu(h: *Handle, src_n: c_long) c_int {
    if (src_n < 1) return abi.fail(&h.diag, error.WrongHduType);
    _ = h.fits.copyHdu(@intCast(src_n)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// Data integrity (DATASUM / CHECKSUM)
// ════════════════════════════════════════════════════════════════════════════════════════════

/// Compute and write `DATASUM` + `CHECKSUM` for the current HDU.
pub export fn zf_write_chksum(h: *Handle) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    fits.checksum.ensureCards(&hdu.header, gpa) catch |e| return abi.fail(&h.diag, e);
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    fits.checksum.update(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Recompute and rewrite the integrity keywords for every HDU that already has them.
pub export fn zf_update_chksum_all(h: *Handle) c_int {
    fits.checksum.updateAll(&h.fits) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Verify the current HDU's integrity. `out_checksum`/`out_datasum`: 1 match, 0 absent, -1 mismatch.
pub export fn zf_verify_chksum(h: *Handle, out_checksum: *c_int, out_datasum: *c_int) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const r = fits.checksum.verify(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    out_checksum.* = verifyCode(r.sum);
    out_datasum.* = verifyCode(r.data);
    return 0;
}

fn verifyCode(v: fits.checksum.Verify) c_int {
    return switch (v) {
        .match => 1,
        .not_present => 0,
        .mismatch => -1,
    };
}

/// Compute the data-unit `DATASUM` of the current HDU (32-bit FITS 1's-complement sum).
pub export fn zf_datasum(h: *Handle, out: *u64) c_int {
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    out.* = fits.checksum.datasum(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// Structural validation (fitsverify-style)
// ════════════════════════════════════════════════════════════════════════════════════════════

const FindingsHandle = abi.FindingsHandle;

/// Run the structural validation pass; the result is an opaque list released with
/// `zf_findings_free`.
pub export fn zf_validate(h: *Handle, out: *?*FindingsHandle) c_int {
    out.* = null;
    const fh = gpa.create(FindingsHandle) catch return abi.fail(null, error.OutOfMemory);
    fh.* = .{ .list = fits.validate.verify(gpa, &h.fits) catch |e| {
        gpa.destroy(fh);
        return abi.fail(&h.diag, e);
    } };
    out.* = fh;
    return 0;
}

/// Number of findings.
pub export fn zf_findings_count(fh: *FindingsHandle, out: *c_long) c_int {
    out.* = @intCast(fh.list.items.len);
    return 0;
}

/// Get finding `i`: `severity` (0 error, 1 warning), 1-based `hdu` (0 = whole file), the keyword
/// (empty if none), and the message.
pub export fn zf_findings_get(fh: *FindingsHandle, i: c_long, severity: *c_int, hdu: *c_int, kw_buf: [*]u8, kw_len: usize, kw_out: *usize, msg_buf: [*]u8, msg_len: usize, msg_out: *usize) c_int {
    if (i < 0 or @as(usize, @intCast(i)) >= fh.list.items.len) return abi.fail(null, error.CellOutOfRange);
    const f = fh.list.items[@intCast(i)];
    severity.* = switch (f.severity) {
        .err => 0,
        .warning => 1,
    };
    hdu.* = @intCast(f.hdu);
    abi.copyOut(f.kw orelse "", kw_buf, kw_len, kw_out);
    abi.copyOut(f.msg, msg_buf, msg_len, msg_out);
    return 0;
}

/// Release a findings list.
pub export fn zf_findings_free(fh: ?*FindingsHandle) void {
    const h = fh orelse return;
    fits.validate.deinitFindings(gpa, &h.list);
    gpa.destroy(h);
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// World Coordinate System (celestial transforms)
// ════════════════════════════════════════════════════════════════════════════════════════════

fn celestialOf(h: *Handle, alt: c_int) fits.Error!fits.Celestial {
    const hdu = try h.cur();
    const a: u8 = if (alt <= ' ') ' ' else @intCast(alt);
    var w = try fits.Wcs.fromHeader(gpa, &hdu.header, a);
    defer w.deinit(gpa);
    return fits.Celestial.fromWcs(&w);
}

/// Convert a 1-based pixel coordinate `(px, py)` to celestial `(lon, lat)` degrees using the
/// current HDU's WCS (`alt` selects an alternate WCS letter; 0/space = primary).
pub export fn zf_wcs_pix2world(h: *Handle, alt: c_int, px: f64, py: f64, out_lon: *f64, out_lat: *f64) c_int {
    const cel = celestialOf(h, alt) catch |e| return abi.fail(&h.diag, e);
    const world = cel.pixelToWorld(.{ px, py }) catch |e| return abi.fail(&h.diag, e);
    out_lon.* = world[0];
    out_lat.* = world[1];
    return 0;
}

/// Convert celestial `(lon, lat)` degrees to a 1-based pixel coordinate `(px, py)`.
pub export fn zf_wcs_world2pix(h: *Handle, alt: c_int, lon: f64, lat: f64, out_px: *f64, out_py: *f64) c_int {
    const cel = celestialOf(h, alt) catch |e| return abi.fail(&h.diag, e);
    const pix = cel.worldToPixel(.{ lon, lat }) catch |e| return abi.fail(&h.diag, e);
    out_px.* = pix[0];
    out_py.* = pix[1];
    return 0;
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// Tiled-compressed image write
// ════════════════════════════════════════════════════════════════════════════════════════════

fn writeCompressedT(comptime T: type, h: *Handle, spec: fits.CompressSpec, ptr: *const anyopaque, nelem: usize) fits.Error!void {
    const pixels = @as([*]const T, @ptrCast(@alignCast(ptr)))[0..nelem];
    _ = try fits.writeCompressed(T, &h.fits, spec, pixels);
}

fn writeCompressedDispatch(ty: ZfType, h: *Handle, spec: fits.CompressSpec, ptr: *const anyopaque, nelem: usize) fits.Error!void {
    return switch (ty) {
        .uint8 => writeCompressedT(u8, h, spec, ptr, nelem),
        .int16 => writeCompressedT(i16, h, spec, ptr, nelem),
        .int32 => writeCompressedT(i32, h, spec, ptr, nelem),
        .int64 => writeCompressedT(i64, h, spec, ptr, nelem),
        .float32 => writeCompressedT(f32, h, spec, ptr, nelem),
        .float64 => writeCompressedT(f64, h, spec, ptr, nelem),
        else => error.WrongValueType,
    };
}

/// Append a tile-compressed image HDU. `codec`/`quantize` are NUL-terminated names
/// (`"GZIP_1"`, `"RICE_1"`, `"SUBTRACTIVE_DITHER_1"`, ...). `tile` (or null) overrides the
/// default row-strip tiling.
pub export fn zf_write_compressed(h: *Handle, dtype: c_int, bitpix: c_int, naxis: c_int, axes: [*]const c_long, tile: ?[*]const c_long, codec: [*:0]const u8, quantize: ?[*:0]const u8, zdither0: c_longlong, pixels: *const anyopaque, nelem: c_longlong) c_int {
    if (nelem < 0 or naxis <= 0) return abi.fail(&h.diag, error.BadDimensions);
    var axbuf: [999]u64 = undefined;
    var tilebuf: [999]u64 = undefined;
    const nax: usize = @intCast(@min(naxis, 999));
    for (0..nax) |i| axbuf[i] = @intCast(axes[i]);
    var spec = fits.CompressSpec{
        .bitpix = @intCast(bitpix),
        .axes = axbuf[0..nax],
        .zdither0 = @intCast(zdither0),
    };
    // `Codec`/`Quantize` are not re-exported at the package root; reach their `fromName` through
    // the `CompressSpec` field types so the shim needs no extra exports.
    spec.codec = @TypeOf(spec.codec).fromName(std.mem.span(codec));
    if (tile) |tl| {
        for (0..nax) |i| tilebuf[i] = @intCast(tl[i]);
        spec.tile = tilebuf[0..nax];
    }
    if (quantize) |q| spec.quantize = @TypeOf(spec.quantize).fromName(std.mem.span(q));
    writeCompressedDispatch(@enumFromInt(dtype), h, spec, pixels, @intCast(nelem)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}
