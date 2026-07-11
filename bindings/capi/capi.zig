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

// ── Foreign scratch allocator ────────────────────────────────────────────────────────────────
// A caller that shares no address space with the shim — the WebAssembly binding, which must
// stage every string/buffer/out-parameter *inside* the module's own linear memory — needs to
// allocate through this allocator (picking arbitrary offsets would clobber the shim heap). Both
// are no-ops for a native ctypes/koffi caller, which passes real pointers directly, but they are
// exported unconditionally so the ABI surface is identical across targets.

/// Allocate `len` bytes of 16-byte-aligned scratch (enough for every ABI struct and any
/// `f64`/`i64` buffer). The block carries a length header so `zf_wfree` needs only the pointer.
/// Returns null on out-of-memory (or `len == 0`).
pub export fn zf_walloc(len: usize) ?[*]u8 {
    const total = std.mem.alignForward(usize, len + 16, 16);
    const slice = gpa.alignedAlloc(u8, .@"16", total) catch return null;
    std.mem.writeInt(u64, slice.ptr[0..8], total, .little);
    return slice.ptr + 16;
}

/// Free a block returned by `zf_walloc`. Safe to call with null.
pub export fn zf_wfree(ptr: ?[*]u8) void {
    const p = ptr orelse return;
    const base = p - 16;
    const total: usize = @intCast(std.mem.readInt(u64, base[0..8], .little));
    const aligned: [*]align(16) u8 = @alignCast(base);
    gpa.free(aligned[0..total]);
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
pub export fn zf_flush(h_opt: ?*Handle) c_int {
    const h = h_opt orelse return abi.failNull();
    h.fits.flush() catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Export the handle's current bytes as a whole-file gzip stream written to `path`.
pub export fn zf_save_gzip(h_opt: ?*Handle, path_ptr: [*]const u8, path_len: usize) c_int {
    const h = h_opt orelse return abi.failNull();
    h.fits.saveGzipFile(path_ptr[0..path_len]) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Total logical size in bytes of the handle's underlying device.
pub export fn zf_data_size(h_opt: ?*Handle, out: *u64) c_int {
    const h = h_opt orelse return abi.failNull();
    out.* = h.fits.device().getSize() catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Read up to `len` raw bytes at `offset` from the device into `dst`; `out_read` gets the count.
pub export fn zf_read_bytes(h_opt: ?*Handle, offset: u64, dst: [*]u8, len: usize, out_read: *usize) c_int {
    const h = h_opt orelse return abi.failNull();
    out_read.* = h.fits.device().pread(dst[0..len], offset) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Close a handle and free all associated resources. Safe to call with null.
pub export fn zf_close(h: ?*Handle) void {
    const hh = h orelse return;
    // Invalidate any open table views first: release their resources (while the `Fits` is still
    // alive) and mark them dead, so a later `zf_table_*`/`zf_table_close` on a still-held `ZfTable*`
    // cannot use-after-free the freed `Fits`/`Hdu` they borrow. The `TableHandle` memory itself is
    // caller-owned and freed by `zf_table_close`.
    for (hh.tables.items) |th| {
        th.deinit();
        th.dead = true;
    }
    hh.tables.deinit(gpa);
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
pub export fn zf_hdu_count(h_opt: ?*Handle, out: *c_long) c_int {
    const h = h_opt orelse return abi.failNull();
    const n = h.fits.hduCount() catch |e| return abi.fail(&h.diag, e);
    out.* = @intCast(n);
    return 0;
}

/// Select HDU `n` (1-based) as the current HDU.
pub export fn zf_select(h_opt: ?*Handle, n: c_long) c_int {
    const h = h_opt orelse return abi.failNull();
    if (n < 1) return abi.fail(&h.diag, error.WrongHduType);
    _ = h.fits.select(@intCast(n)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Move the current HDU by `delta` (relative navigation).
pub export fn zf_move(h_opt: ?*Handle, delta: c_long) c_int {
    const h = h_opt orelse return abi.failNull();
    _ = h.fits.move(@intCast(delta)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Select the first extension matching `EXTNAME` (case-insensitive); if `has_extver` is set,
/// also match `EXTVER`.
pub export fn zf_select_by_name(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, extver: c_long, has_extver: c_int) c_int {
    const h = h_opt orelse return abi.failNull();
    const ev: ?i64 = if (has_extver != 0) @intCast(extver) else null;
    _ = h.fits.selectByName(name_ptr[0..name_len], ev) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// The current HDU number (1-based).
pub export fn zf_current_hdu(h_opt: ?*Handle, out: *c_long) c_int {
    const h = h_opt orelse return abi.failNull();
    if (h.fits.hdus.items.len == 0) return abi.fail(&h.diag, error.WrongHduType);
    out.* = @intCast(h.fits.chdu + 1);
    return 0;
}

/// The current HDU's kind: 0 primary, 1 image, 2 ascii_table, 3 binary_table, 4 random_groups.
pub export fn zf_hdu_type(h_opt: ?*Handle, out: *c_int) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    out.* = abi.kindCode(hdu.kind);
    return 0;
}

/// Image geometry of the current HDU. Reports the uncompressed `Z*` geometry for a
/// tile-compressed image. `axes` is filled most-rapidly-varying first up to `axes_cap`;
/// `naxis_out` gets the true NAXIS, `filled` the number written.
pub export fn zf_img_param(h_opt: ?*Handle, bitpix_out: *c_int, naxis_out: *c_int, axes: [*]c_long, axes_cap: c_int, filled: *c_int) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const cap: usize = if (axes_cap > 0) @intCast(axes_cap) else 0;
    const compressed = hdu.kind == .binary_table and (hdu.header.getValue(bool, "ZIMAGE") catch false);
    if (compressed) {
        // Z* values come straight from an untrusted header (only the real decompression open
        // validates them), so narrow with checked casts — an error status, never a trap.
        const zbp = hdu.header.getValue(i64, "ZBITPIX") catch hdu.bitpix;
        bitpix_out.* = switch (zbp) {
            8, 16, 32, 64, -32, -64 => @intCast(zbp),
            else => return abi.fail(&h.diag, error.BadBitpix),
        };
        const zn = hdu.header.getValue(i64, "ZNAXIS") catch 0; // missing → zero axes, like ZBITPIX's fallback
        if (zn < 0 or zn > 999) return abi.fail(&h.diag, error.BadTiling);
        const nax: usize = @intCast(zn);
        naxis_out.* = @intCast(nax);
        const n = @min(nax, cap);
        var name_buf: [16]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const kw = std.fmt.bufPrint(&name_buf, "ZNAXIS{d}", .{i + 1}) catch unreachable;
            const v = hdu.header.getValue(i64, kw) catch 0;
            if (v < 0) return abi.fail(&h.diag, error.BadTiling);
            axes[i] = std.math.cast(c_long, v) orelse return abi.fail(&h.diag, error.BadDimensions);
        }
        filled.* = @intCast(n);
    } else {
        bitpix_out.* = @intCast(hdu.bitpix);
        naxis_out.* = @intCast(hdu.naxis);
        const n = @min(@as(usize, hdu.naxis), cap);
        // A parse-valid axis can still exceed a 32-bit `c_long` (LLP64 Windows, wasm32).
        for (0..n) |i| axes[i] = std.math.cast(c_long, hdu.axes[i]) orelse return abi.fail(&h.diag, error.BadDimensions);
        filled.* = @intCast(n);
    }
    return 0;
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// Images
// ════════════════════════════════════════════════════════════════════════════════════════════

// `null` when any axis element is negative (a plain `@intCast` of a negative `c_long` would trap
// across the C boundary); the caller maps that to `error.BadDimensions`.
fn axesFrom(naxis: c_int, axes: ?[*]const c_long, buf: *[999]u64) ?[]const u64 {
    const nax: usize = if (naxis > 0) @intCast(@min(naxis, 999)) else 0;
    if (axes) |ax| {
        for (0..nax) |i| buf[i] = std.math.cast(u64, ax[i]) orelse return null;
    }
    return buf[0..nax];
}

/// Append a new image HDU (primary if the file is empty, else an IMAGE extension).
pub export fn zf_create_img(h_opt: ?*Handle, bitpix: c_int, naxis: c_int, axes: ?[*]const c_long) c_int {
    const h = h_opt orelse return abi.failNull();
    var buf: [999]u64 = undefined;
    const ax = axesFrom(naxis, axes, &buf) orelse return abi.fail(&h.diag, error.BadDimensions);
    const spec = fits.ImageSpec{ .bitpix = @intCast(bitpix), .axes = ax };
    _ = h.fits.appendImageHdu(spec) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Resize / redefine the current image HDU in place.
pub export fn zf_resize_img(h_opt: ?*Handle, bitpix: c_int, naxis: c_int, axes: ?[*]const c_long) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    var view = fits.ImageView.of(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    var buf: [999]u64 = undefined;
    const ax = axesFrom(naxis, axes, &buf) orelse return abi.fail(&h.diag, error.BadDimensions);
    view.reshape(@intCast(bitpix), ax) catch |e| return abi.fail(&h.diag, e);
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
pub export fn zf_read_img(h_opt: ?*Handle, dtype: c_int, firstelem: c_longlong, nelem: c_longlong, nulval: ?*const anyopaque, scaling: ?*const ZfScaling, array: *anyopaque) c_int {
    const h = h_opt orelse return abi.failNull();
    if (nelem <= 0) return 0;
    if (firstelem < 1) return abi.fail(&h.diag, error.BadDimensions);
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    var view = fits.ImageView.of(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    const sc: ?fits.Scaling = if (scaling) |s| abi.toScaling(s.*) else null;
    imgRead(&view, @enumFromInt(dtype), @intCast(firstelem - 1), array, @intCast(nelem), nulval, sc) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Write `nelem` pixels to the current image starting at 1-based flat `firstelem`.
pub export fn zf_write_img(h_opt: ?*Handle, dtype: c_int, firstelem: c_longlong, nelem: c_longlong, nulval: ?*const anyopaque, scaling: ?*const ZfScaling, array: *const anyopaque) c_int {
    const h = h_opt orelse return abi.failNull();
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

// `null` when any bound/stride element is negative (a plain `@intCast` of a negative `c_long`
// would trap across the C boundary); the caller maps that to `error.BadDimensions`.
fn fillBounds(naxis: c_int, lower: [*]const c_long, upper: [*]const c_long, inc: ?[*]const c_long, lo: *[999]u64, hi: *[999]u64, st: *[999]u64) ?usize {
    const nax: usize = if (naxis > 0) @intCast(@min(naxis, 999)) else 0;
    for (0..nax) |i| {
        lo[i] = std.math.cast(u64, lower[i]) orelse return null;
        hi[i] = std.math.cast(u64, upper[i]) orelse return null;
        st[i] = if (inc) |c| (std.math.cast(u64, c[i]) orelse return null) else 1;
    }
    return nax;
}

/// Read a rectangular section (0-based inclusive `lower..upper`, optional per-axis `inc`).
pub export fn zf_read_subset(h_opt: ?*Handle, dtype: c_int, naxis: c_int, lower: [*]const c_long, upper: [*]const c_long, inc: ?[*]const c_long, nelem: c_longlong, nulval: ?*const anyopaque, scaling: ?*const ZfScaling, array: *anyopaque) c_int {
    const h = h_opt orelse return abi.failNull();
    if (nelem < 0) return abi.fail(&h.diag, error.BadDimensions);
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    var view = fits.ImageView.of(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    var lo: [999]u64 = undefined;
    var hi: [999]u64 = undefined;
    var stb: [999]u64 = undefined;
    const n = fillBounds(naxis, lower, upper, inc, &lo, &hi, &stb) orelse return abi.fail(&h.diag, error.BadDimensions);
    const stride: ?[]const u64 = if (inc != null) stb[0..n] else null;
    const sc: ?fits.Scaling = if (scaling) |s| abi.toScaling(s.*) else null;
    sectionDispatch(.read, &view, @enumFromInt(dtype), lo[0..n], hi[0..n], stride, array, @intCast(nelem), nulval, sc) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Write a rectangular section (symmetric with `zf_read_subset`).
pub export fn zf_write_subset(h_opt: ?*Handle, dtype: c_int, naxis: c_int, lower: [*]const c_long, upper: [*]const c_long, inc: ?[*]const c_long, nelem: c_longlong, nulval: ?*const anyopaque, scaling: ?*const ZfScaling, array: *anyopaque) c_int {
    const h = h_opt orelse return abi.failNull();
    if (nelem < 0) return abi.fail(&h.diag, error.BadDimensions);
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    var view = fits.ImageView.of(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    var lo: [999]u64 = undefined;
    var hi: [999]u64 = undefined;
    var stb: [999]u64 = undefined;
    const n = fillBounds(naxis, lower, upper, inc, &lo, &hi, &stb) orelse return abi.fail(&h.diag, error.BadDimensions);
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
pub export fn zf_card_count(h_opt: ?*Handle, out: *c_long) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    out.* = @intCast(hdu.header.count());
    return 0;
}

/// Copy the raw 80 bytes of card `index` (0-based) into `buf80`.
pub export fn zf_read_card(h_opt: ?*Handle, index: c_long, buf80: [*]u8) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    if (index < 0 or @as(usize, @intCast(index)) >= hdu.header.count()) return abi.fail(&h.diag, error.KeywordNotFound);
    const card = hdu.header.at(@intCast(index));
    @memcpy(buf80[0..80], card.bytes()[0..80]);
    return 0;
}

/// Whether keyword `name` exists in the current header.
pub export fn zf_key_exists(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch return 0;
    return if (hdu.header.has(name_ptr[0..name_len])) 1 else 0;
}

/// Read an integer-valued keyword.
pub export fn zf_read_key_lng(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, out: *c_longlong) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    out.* = @intCast(hdu.header.getValue(i64, name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e));
    return 0;
}

/// Read a floating-valued keyword.
pub export fn zf_read_key_dbl(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, out: *f64) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    out.* = hdu.header.getValue(f64, name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Read a logical (boolean) keyword as 0/1.
pub export fn zf_read_key_log(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, out: *c_int) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const b = hdu.header.getValue(bool, name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e);
    out.* = if (b) 1 else 0;
    return 0;
}

/// Read a string-valued keyword into `buf`; `out_len` gets the full length.
pub export fn zf_read_key_str(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, buf: [*]u8, buf_len: usize, out_len: *usize) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const s = hdu.header.getString(gpa, name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e);
    defer gpa.free(s);
    abi.copyOut(s, buf, buf_len, out_len);
    return 0;
}

/// Read a (possibly CONTINUE-continued) long string. On success `out_ptr`/`out_len` own a
/// buffer the caller must release with `zf_free`.
pub export fn zf_read_key_longstr(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, out_ptr: *?[*]u8, out_len: *usize) c_int {
    const h = h_opt orelse return abi.failNull();
    out_ptr.* = null;
    out_len.* = 0;
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const s = hdu.header.getLongString(gpa, name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e);
    out_ptr.* = s.ptr;
    out_len.* = s.len;
    return 0;
}

/// Copy keyword `name`'s comment into `buf` (empty if none).
pub export fn zf_key_comment(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, buf: [*]u8, buf_len: usize, out_len: *usize) c_int {
    const h = h_opt orelse return abi.failNull();
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
pub export fn zf_write_key_lng(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, value: c_longlong, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    const h = h_opt orelse return abi.failNull();
    return writeKey(h, name_ptr[0..name_len], .{ .int = @intCast(value) }, commentOf(comment_ptr, comment_len));
}

/// Create or update a floating keyword.
pub export fn zf_write_key_dbl(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, value: f64, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    const h = h_opt orelse return abi.failNull();
    return writeKey(h, name_ptr[0..name_len], .{ .float = value }, commentOf(comment_ptr, comment_len));
}

/// Create or update a logical keyword.
pub export fn zf_write_key_log(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, value: c_int, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    const h = h_opt orelse return abi.failNull();
    return writeKey(h, name_ptr[0..name_len], .{ .logical = value != 0 }, commentOf(comment_ptr, comment_len));
}

/// Create or update a string keyword (single card; ≤ 68 chars).
pub export fn zf_write_key_str(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    const h = h_opt orelse return abi.failNull();
    return writeKey(h, name_ptr[0..name_len], .{ .string = value_ptr[0..value_len] }, commentOf(comment_ptr, comment_len));
}

/// Append a long string keyword using the CONTINUE convention (inserts before END).
pub export fn zf_write_key_longstr(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    const h = h_opt orelse return abi.failNull();
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

/// Create or update a keyword with an undefined (blank) value field (FITS 4.0 §4.1.2.3).
pub export fn zf_write_key_undef(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize, comment_ptr: ?[*]const u8, comment_len: usize) c_int {
    const h = h_opt orelse return abi.failNull();
    return writeKey(h, name_ptr[0..name_len], .undefined, commentOf(comment_ptr, comment_len));
}

/// Delete the first card named `name`.
pub export fn zf_delete_key(h_opt: ?*Handle, name_ptr: [*]const u8, name_len: usize) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    hdu.header.delete(name_ptr[0..name_len]) catch |e| return abi.fail(&h.diag, e);
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Rename keyword `old` to `new`.
pub export fn zf_rename_key(h_opt: ?*Handle, old_ptr: [*]const u8, old_len: usize, new_ptr: [*]const u8, new_len: usize) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    hdu.header.rename(old_ptr[0..old_len], new_ptr[0..new_len]) catch |e| return abi.fail(&h.diag, e);
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Insert a raw 80-byte card before END. Like CFITSIO's `ffprec`, the value field is NOT
/// validated (only printable-ASCII and the keyword name are) — callers building raw cards
/// must guard their own values (e.g. the bindings reject non-finite reals before this call).
pub export fn zf_write_record(h_opt: ?*Handle, card80: [*]const u8) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    const card = fits.Card.parse(card80[0..80]) catch |e| return abi.fail(&h.diag, e);
    hdu.header.insert(gpa, endIndex(&hdu.header), card) catch |e| return abi.fail(&h.diag, e);
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Insert a raw 80-byte card at `index` (0-based).
pub export fn zf_insert_record(h_opt: ?*Handle, index: c_long, card80: [*]const u8) c_int {
    const h = h_opt orelse return abi.failNull();
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

fn createTbl(h: *Handle, table_type: c_int, nrows: c_longlong, ncols: c_int, ttype: [*]const ?[*:0]const u8, tform: [*]const ?[*:0]const u8, tunit: ?[*]const ?[*:0]const u8, extname: ?[*:0]const u8, pcount: c_longlong) fits.Error!void {
    const nc: usize = if (ncols > 0) @intCast(ncols) else 0;
    const ascii = table_type == 1;
    // TFORM is mandatory for every column; a null entry (caller under-populated the array) must
    // error cleanly rather than force-unwrap-panic across the C boundary at `tform[i].?` below.
    for (0..nc) |i| if (tform[i] == null) return error.MissingRequiredKeyword;

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
    try hdr.appendValue(gpa, "PCOUNT", .{ .int = if (pcount > 0) pcount else 0 }, null);
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
pub export fn zf_create_tbl(h_opt: ?*Handle, table_type: c_int, nrows: c_longlong, ncols: c_int, ttype: [*]const ?[*:0]const u8, tform: [*]const ?[*:0]const u8, tunit: ?[*]const ?[*:0]const u8, extname: ?[*:0]const u8) c_int {
    const h = h_opt orelse return abi.failNull();
    createTbl(h, table_type, nrows, ncols, ttype, tform, tunit, extname, 0) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Like `zf_create_tbl` but reserves `pcount` bytes of heap (PCOUNT) up front so a binary table's
/// variable-length-array cells can be written with `zf_write_col_vla`.
pub export fn zf_create_tbl_heap(h_opt: ?*Handle, table_type: c_int, nrows: c_longlong, ncols: c_int, ttype: [*]const ?[*:0]const u8, tform: [*]const ?[*:0]const u8, tunit: ?[*]const ?[*:0]const u8, extname: ?[*:0]const u8, pcount: c_longlong) c_int {
    const h = h_opt orelse return abi.failNull();
    createTbl(h, table_type, nrows, ncols, ttype, tform, tunit, extname, pcount) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Open a table view over the current HDU.
pub export fn zf_table_open(h_opt: ?*Handle, out: *?*TableHandle) c_int {
    const h = h_opt orelse return abi.failNull();
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
    // Register the view so `zf_close` can invalidate it (preventing a use-after-free if the file is
    // closed while the view is still held).
    h.tables.append(gpa, th) catch {
        th.deinit();
        gpa.destroy(th);
        return abi.fail(null, error.OutOfMemory);
    };
    out.* = th;
    return 0;
}

/// Close a table view.
pub export fn zf_table_close(t: ?*TableHandle) void {
    const th = t orelse return;
    // Deregister from the owner's live-view list — unless the owner was already closed, which marked
    // this view dead and dropped the list (so `th.owner` must not be dereferenced).
    if (!th.dead) {
        for (th.owner.tables.items, 0..) |v, i| {
            if (v == th) {
                _ = th.owner.tables.swapRemove(i);
                break;
            }
        }
    }
    th.deinit();
    gpa.destroy(th);
}

// A table handle that is non-null and still live (its owning file open). `zf_close` marks a view
// `dead` and frees the `Fits`/`Hdu` it borrows, so every table op must reject a dead handle before
// dereferencing it — otherwise it is a use-after-free. A dead view yields the null-handle status
// (from the caller's perspective it is no longer usable).
fn liveTable(t_opt: ?*TableHandle) ?*TableHandle {
    const t = t_opt orelse return null;
    return if (t.dead) null else t;
}

/// Number of rows in the table.
pub export fn zf_table_nrows(t_opt: ?*TableHandle, out: *c_longlong) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    out.* = @intCast(switch (t.kind) {
        .binary => t.bin.?.rowCount(),
        .ascii => t.asc.?.rowCount(),
    });
    return 0;
}

/// Number of columns in the table.
pub export fn zf_table_ncols(t_opt: ?*TableHandle, out: *c_int) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
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
pub export fn zf_table_colnum(t_opt: ?*TableHandle, name_ptr: [*]const u8, name_len: usize, out: *c_int) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const idx = resolveCol(t, name_ptr[0..name_len]) catch |e| return abi.fail(&t.owner.diag, e);
    out.* = @intCast(idx);
    return 0;
}

/// Fill `info` with metadata for 0-based column `col`.
pub export fn zf_table_col_info(t_opt: ?*TableHandle, col: c_int, info: *ZfColInfo) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
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
pub export fn zf_table_col_name(t_opt: ?*TableHandle, col: c_int, buf: [*]u8, buf_len: usize, out_len: *usize) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const ci: usize = if (col >= 0) @intCast(col) else return abi.fail(&t.owner.diag, error.NoSuchColumn);
    abi.copyOut(colNameUnit(t, ci, false) orelse "", buf, buf_len, out_len);
    return 0;
}

/// Copy 0-based column `col`'s unit (`TUNITn`) into `buf`.
pub export fn zf_table_col_unit(t_opt: ?*TableHandle, col: c_int, buf: [*]u8, buf_len: usize, out_len: *usize) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
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
pub export fn zf_read_col(t_opt: ?*TableHandle, dtype: c_int, col: c_int, firstrow: c_longlong, nelem: c_longlong, nulval: ?*const anyopaque, array: *anyopaque) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    if (nelem <= 0) return 0;
    if (col < 0 or firstrow < 1) return abi.fail(&t.owner.diag, error.CellOutOfRange);
    colDispatch(.read, t, @enumFromInt(dtype), @intCast(col), @intCast(firstrow - 1), array, @intCast(nelem), nulval) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Write `nelem` elements to 0-based column `col` starting at 1-based `firstrow`, from `dtype`.
pub export fn zf_write_col(t_opt: ?*TableHandle, dtype: c_int, col: c_int, firstrow: c_longlong, nelem: c_longlong, nulval: ?*const anyopaque, array: *anyopaque) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    if (nelem <= 0) return 0;
    if (col < 0 or firstrow < 1) return abi.fail(&t.owner.diag, error.CellOutOfRange);
    colDispatch(.write, t, @enumFromInt(dtype), @intCast(col), @intCast(firstrow - 1), array, @intCast(nelem), nulval) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Read `nrows` text cells of character column `col` (0-based) starting at 1-based `firstrow`,
/// each into `buf[i*stride .. i*stride+width]` (raw fixed-width field bytes).
pub export fn zf_read_col_str(t_opt: ?*TableHandle, col: c_int, firstrow: c_longlong, nrows: c_longlong, width: c_longlong, stride: c_longlong, buf: [*]u8) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
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
pub export fn zf_write_col_str(t_opt: ?*TableHandle, col: c_int, firstrow: c_longlong, nrows: c_longlong, width: c_longlong, stride: c_longlong, buf: [*]const u8) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
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
pub export fn zf_append_rows(t_opt: ?*TableHandle, n: c_longlong) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (n < 0) return abi.fail(&t.owner.diag, error.RowOutOfRange);
    tbl.appendRows(@intCast(n)) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Insert `n` empty rows before 0-based `before_row` in a binary table.
pub export fn zf_insert_rows(t_opt: ?*TableHandle, before_row: c_longlong, n: c_longlong) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (before_row < 0 or n < 0) return abi.fail(&t.owner.diag, error.RowOutOfRange);
    tbl.insertRows(@intCast(before_row), @intCast(n)) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Delete `n` rows starting at 0-based `first_row` in a binary table.
pub export fn zf_delete_rows(t_opt: ?*TableHandle, first_row: c_longlong, n: c_longlong) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (first_row < 0 or n < 0) return abi.fail(&t.owner.diag, error.RowOutOfRange);
    tbl.deleteRows(@intCast(first_row), @intCast(n)) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Insert a new column at 0-based `at` in a binary table.
pub export fn zf_insert_col(t_opt: ?*TableHandle, at: c_int, tform: [*:0]const u8, ttype: ?[*:0]const u8) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (at < 0 or at > std.math.maxInt(u16)) return abi.fail(&t.owner.diag, error.NoSuchColumn);
    const tt: ?[]const u8 = if (ttype) |p| std.mem.span(p) else null;
    tbl.insertColumn(gpa, @intCast(at), std.mem.span(tform), tt) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Delete 0-based column `col` from a binary table.
pub export fn zf_delete_col(t_opt: ?*TableHandle, col: c_int) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (col < 0 or col > std.math.maxInt(u16)) return abi.fail(&t.owner.diag, error.NoSuchColumn);
    tbl.deleteColumn(@intCast(col)) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

// ── Variable-length arrays ────────────────────────────────────────────────────────────────────

/// Read the (len, offset) descriptor of a VLA cell (1-based `row`).
pub export fn zf_read_descript(t_opt: ?*TableHandle, col: c_int, row: c_longlong, out_len: *c_longlong, out_off: *c_longlong) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (col < 0 or row < 1) return abi.fail(&t.owner.diag, error.CellOutOfRange); // mirror zf_read_col_vla
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
pub export fn zf_read_col_vla(t_opt: ?*TableHandle, dtype: c_int, col: c_int, row: c_longlong, cap: c_longlong, array: *anyopaque, out_nelem: *c_longlong) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
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

/// Write a VLA cell (1-based `row`) from `nelem` elements of `array`. The heap manager is
/// created lazily and reconstructs its high-water mark from every live VLA descriptor in the
/// table, so opening and rewriting an already-populated heap cannot overlap another cell.
pub export fn zf_write_col_vla(t_opt: ?*TableHandle, dtype: c_int, col: c_int, row: c_longlong, array: *const anyopaque, nelem: c_longlong) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (col < 0 or row < 1 or nelem < 0) return abi.fail(&t.owner.diag, error.CellOutOfRange);
    // Match the core write predicate before lazily reconstructing the heap. A read-only write is
    // guaranteed to fail, so it must not scan or allocate based on untrusted live descriptors.
    if (tbl.fits.mode == .read_only or !tbl.fits.dev.isWritable()) return abi.fail(&t.owner.diag, error.NotWritable);
    if (t.mgr == null) {
        t.mgr = fits.heap.HeapManager.initForTable(tbl) catch |e| return abi.fail(&t.owner.diag, e);
    }
    vlaWrite(@enumFromInt(dtype), tbl, &t.mgr.?, @intCast(col), @intCast(row - 1), array, @intCast(nelem)) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

fn alignedMutSlice(comptime T: type, ptr: *anyopaque, len: usize) fits.Error![]T {
    if (@intFromPtr(ptr) % @alignOf(T) != 0) return error.WrongValueType;
    return @as([*]T, @ptrCast(@alignCast(ptr)))[0..len];
}

fn alignedConstSlice(comptime T: type, ptr: *const anyopaque, len: usize) fits.Error![]const T {
    if (@intFromPtr(ptr) % @alignOf(T) != 0) return error.WrongValueType;
    return @as([*]const T, @ptrCast(@alignCast(ptr)))[0..len];
}

fn vlaPackedReadT(
    comptime T: type,
    tbl: *fits.BinTable,
    col: u16,
    first_row: u64,
    nrows: u64,
    array: ?*anyopaque,
    cap: usize,
) fits.Error!void {
    var empty: [0]T = .{};
    const out: []T = if (cap == 0)
        empty[0..]
    else
        try alignedMutSlice(T, array orelse return error.CellOutOfRange, cap);
    try fits.heap.readVlaColumnInto(T, tbl, .{ .index = col }, first_row, nrows, out);
}

fn vlaPackedRead(
    ty: ZfType,
    tbl: *fits.BinTable,
    col: u16,
    first_row: u64,
    nrows: u64,
    array: ?*anyopaque,
    cap: usize,
) fits.Error!void {
    return switch (ty) {
        .uint8 => vlaPackedReadT(u8, tbl, col, first_row, nrows, array, cap),
        .int8 => vlaPackedReadT(i8, tbl, col, first_row, nrows, array, cap),
        .int16 => vlaPackedReadT(i16, tbl, col, first_row, nrows, array, cap),
        .uint16 => vlaPackedReadT(u16, tbl, col, first_row, nrows, array, cap),
        .int32 => vlaPackedReadT(i32, tbl, col, first_row, nrows, array, cap),
        .uint32 => vlaPackedReadT(u32, tbl, col, first_row, nrows, array, cap),
        .int64 => vlaPackedReadT(i64, tbl, col, first_row, nrows, array, cap),
        .uint64 => vlaPackedReadT(u64, tbl, col, first_row, nrows, array, cap),
        .float32 => vlaPackedReadT(f32, tbl, col, first_row, nrows, array, cap),
        .float64 => vlaPackedReadT(f64, tbl, col, first_row, nrows, array, cap),
        else => error.WrongValueType,
    };
}

fn vlaPackedWriteT(
    comptime T: type,
    tbl: *fits.BinTable,
    mgr: *fits.heap.HeapManager,
    col: u16,
    first_row: u64,
    offsets: []const u64,
    array: ?*const anyopaque,
    nelem: usize,
) fits.Error!void {
    const in: []const T = if (nelem == 0)
        &.{}
    else
        try alignedConstSlice(T, array orelse return error.CellOutOfRange, nelem);
    try fits.heap.writeVlaColumn(T, gpa, tbl, mgr, .{ .index = col }, first_row, offsets, in);
}

fn vlaPackedWrite(
    ty: ZfType,
    tbl: *fits.BinTable,
    mgr: *fits.heap.HeapManager,
    col: u16,
    first_row: u64,
    offsets: []const u64,
    array: ?*const anyopaque,
    nelem: usize,
) fits.Error!void {
    return switch (ty) {
        .uint8 => vlaPackedWriteT(u8, tbl, mgr, col, first_row, offsets, array, nelem),
        .int8 => vlaPackedWriteT(i8, tbl, mgr, col, first_row, offsets, array, nelem),
        .int16 => vlaPackedWriteT(i16, tbl, mgr, col, first_row, offsets, array, nelem),
        .uint16 => vlaPackedWriteT(u16, tbl, mgr, col, first_row, offsets, array, nelem),
        .int32 => vlaPackedWriteT(i32, tbl, mgr, col, first_row, offsets, array, nelem),
        .uint32 => vlaPackedWriteT(u32, tbl, mgr, col, first_row, offsets, array, nelem),
        .int64 => vlaPackedWriteT(i64, tbl, mgr, col, first_row, offsets, array, nelem),
        .uint64 => vlaPackedWriteT(u64, tbl, mgr, col, first_row, offsets, array, nelem),
        .float32 => vlaPackedWriteT(f32, tbl, mgr, col, first_row, offsets, array, nelem),
        .float64 => vlaPackedWriteT(f64, tbl, mgr, col, first_row, offsets, array, nelem),
        else => error.WrongValueType,
    };
}

/// Measure a VLA row range for packed transfer. Rows are 1-based at the ABI; `offsets`
/// receives `nrows + 1` scalar-slot offsets beginning at zero.
pub export fn zf_read_col_vla_layout(
    t_opt: ?*TableHandle,
    col: c_int,
    firstrow: c_longlong,
    nrows: c_longlong,
    offsets_opt: ?*anyopaque,
    offsets_cap: usize,
    out_nslots_opt: ?*anyopaque,
) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (col < 0 or col > std.math.maxInt(u16)) return abi.fail(&t.owner.diag, error.NoSuchColumn);
    if (firstrow < 1 or nrows < 0) return abi.fail(&t.owner.diag, error.RowOutOfRange);

    const offsets_raw = offsets_opt orelse return abi.failNull();
    const out_raw = out_nslots_opt orelse return abi.failNull();
    if (@intFromPtr(offsets_raw) % @alignOf(u64) != 0 or @intFromPtr(out_raw) % @alignOf(u64) != 0) {
        return abi.fail(&t.owner.diag, error.WrongValueType);
    }

    const nr: u64 = @intCast(nrows);
    const needed_u64 = std.math.add(u64, nr, 1) catch return abi.fail(&t.owner.diag, error.LimitExceeded);
    const needed = std.math.cast(usize, needed_u64) orelse return abi.fail(&t.owner.diag, error.LimitExceeded);
    if (offsets_cap < needed) return abi.fail(&t.owner.diag, error.CellOutOfRange);

    const offsets_ptr: [*]u64 = @ptrCast(@alignCast(offsets_raw));
    const out_nslots: *u64 = @ptrCast(@alignCast(out_raw));
    const total = fits.heap.vlaColumnLayout(tbl, .{ .index = @intCast(col) }, @intCast(firstrow - 1), offsets_ptr[0..needed]) catch |e| return abi.fail(&t.owner.diag, e);
    out_nslots.* = total;
    return 0;
}

/// Read a VLA row range into one contiguous scalar-slot buffer. `cap` must exactly match the
/// measured layout. A null `array` is valid only for a zero-slot transfer.
pub export fn zf_read_col_vla_packed(
    t_opt: ?*TableHandle,
    dtype: c_int,
    col: c_int,
    firstrow: c_longlong,
    nrows: c_longlong,
    array: ?*anyopaque,
    cap: u64,
) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (col < 0 or col > std.math.maxInt(u16)) return abi.fail(&t.owner.diag, error.NoSuchColumn);
    if (firstrow < 1 or nrows < 0) return abi.fail(&t.owner.diag, error.RowOutOfRange);
    if (cap != 0 and array == null) return abi.failNull();
    const n: usize = std.math.cast(usize, cap) orelse return abi.fail(&t.owner.diag, error.LimitExceeded);
    vlaPackedRead(@enumFromInt(dtype), tbl, @intCast(col), @intCast(firstrow - 1), @intCast(nrows), array, n) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

/// Write a VLA row range from one contiguous scalar-slot buffer. The offset vector must have
/// exactly `nrows + 1` entries and terminate at `nelem`.
pub export fn zf_write_col_vla_packed(
    t_opt: ?*TableHandle,
    dtype: c_int,
    col: c_int,
    firstrow: c_longlong,
    nrows: c_longlong,
    offsets_opt: ?*const anyopaque,
    offsets_len: usize,
    array: ?*const anyopaque,
    nelem: u64,
) c_int {
    const t = liveTable(t_opt) orelse return abi.failNull();
    const tbl = requireBinary(t) catch |e| return abi.fail(&t.owner.diag, e);
    if (col < 0 or col > std.math.maxInt(u16)) return abi.fail(&t.owner.diag, error.NoSuchColumn);
    if (firstrow < 1 or nrows < 0) return abi.fail(&t.owner.diag, error.RowOutOfRange);
    const offsets_raw = offsets_opt orelse return abi.failNull();
    if (nelem != 0 and array == null) return abi.failNull();
    if (@intFromPtr(offsets_raw) % @alignOf(u64) != 0) return abi.fail(&t.owner.diag, error.WrongValueType);

    const nr: u64 = @intCast(nrows);
    const needed_u64 = std.math.add(u64, nr, 1) catch return abi.fail(&t.owner.diag, error.LimitExceeded);
    const needed = std.math.cast(usize, needed_u64) orelse return abi.fail(&t.owner.diag, error.LimitExceeded);
    if (offsets_len != needed) return abi.fail(&t.owner.diag, error.CellOutOfRange);
    const n: usize = std.math.cast(usize, nelem) orelse return abi.fail(&t.owner.diag, error.LimitExceeded);
    const offsets_ptr: [*]const u64 = @ptrCast(@alignCast(offsets_raw));

    // Preserve ABI pointer/range validation precedence, then reject the guaranteed failure before
    // either the temporary zero-row manager or full live-heap reconstruction can do any work.
    if (tbl.fits.mode == .read_only or !tbl.fits.dev.isWritable()) return abi.fail(&t.owner.diag, error.NotWritable);

    // Preserve the core's full dtype/column/range/offset validation for a zero-row write without
    // reconstructing and sorting a populated heap merely to perform a no-op. No allocation can
    // reach this temporary zero-capacity manager because the validated range contains no cells.
    if (nr == 0 and t.mgr == null) {
        var empty_mgr = fits.heap.HeapManager.init(0);
        defer empty_mgr.deinit(gpa);
        vlaPackedWrite(@enumFromInt(dtype), tbl, &empty_mgr, @intCast(col), @intCast(firstrow - 1), offsets_ptr[0..needed], array, n) catch |e| return abi.fail(&t.owner.diag, e);
        return 0;
    }

    if (t.mgr == null) {
        t.mgr = fits.heap.HeapManager.initForTable(tbl) catch |e| return abi.fail(&t.owner.diag, e);
    }
    vlaPackedWrite(@enumFromInt(dtype), tbl, &t.mgr.?, @intCast(col), @intCast(firstrow - 1), offsets_ptr[0..needed], array, n) catch |e| return abi.fail(&t.owner.diag, e);
    return 0;
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// HDU management (delete / copy)
// ════════════════════════════════════════════════════════════════════════════════════════════

/// Delete HDU `n` (1-based).
pub export fn zf_delete_hdu(h_opt: ?*Handle, n: c_long) c_int {
    const h = h_opt orelse return abi.failNull();
    if (n < 1) return abi.fail(&h.diag, error.WrongHduType);
    h.fits.deleteHdu(@intCast(n)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Copy HDU `src_n` (1-based) to the end of the file and make it current.
pub export fn zf_copy_hdu(h_opt: ?*Handle, src_n: c_long) c_int {
    const h = h_opt orelse return abi.failNull();
    if (src_n < 1) return abi.fail(&h.diag, error.WrongHduType);
    _ = h.fits.copyHdu(@intCast(src_n)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// Data integrity (DATASUM / CHECKSUM)
// ════════════════════════════════════════════════════════════════════════════════════════════

/// Compute and write `DATASUM` + `CHECKSUM` for the current HDU.
pub export fn zf_write_chksum(h_opt: ?*Handle) c_int {
    const h = h_opt orelse return abi.failNull();
    const hdu = h.cur() catch |e| return abi.fail(&h.diag, e);
    fits.checksum.ensureCards(&hdu.header, gpa) catch |e| return abi.fail(&h.diag, e);
    h.fits.rewriteHeaderInPlace(hdu) catch |e| return abi.fail(&h.diag, e);
    fits.checksum.update(&h.fits, hdu) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Recompute and rewrite the integrity keywords for every HDU that already has them.
pub export fn zf_update_chksum_all(h_opt: ?*Handle) c_int {
    const h = h_opt orelse return abi.failNull();
    fits.checksum.updateAll(&h.fits) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Verify the current HDU's integrity. `out_checksum`/`out_datasum`: 1 match, 0 absent, -1 mismatch.
pub export fn zf_verify_chksum(h_opt: ?*Handle, out_checksum: *c_int, out_datasum: *c_int) c_int {
    const h = h_opt orelse return abi.failNull();
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
pub export fn zf_datasum(h_opt: ?*Handle, out: *u64) c_int {
    const h = h_opt orelse return abi.failNull();
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
pub export fn zf_validate(h_opt: ?*Handle, out: *?*FindingsHandle) c_int {
    const h = h_opt orelse return abi.failNull();
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
pub export fn zf_findings_count(fh_opt: ?*FindingsHandle, out: *c_long) c_int {
    const fh = fh_opt orelse return abi.failNull();
    out.* = @intCast(fh.list.items.len);
    return 0;
}

/// Get finding `i`: `severity` (0 error, 1 warning), 1-based `hdu` (0 = whole file), the keyword
/// (empty if none), and the message.
pub export fn zf_findings_get(fh_opt: ?*FindingsHandle, i: c_long, severity: *c_int, hdu: *c_int, kw_buf: [*]u8, kw_len: usize, kw_out: *usize, msg_buf: [*]u8, msg_len: usize, msg_out: *usize) c_int {
    const fh = fh_opt orelse return abi.failNull();
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
    if (alt < 0 or alt > std.math.maxInt(u8)) return error.BadWcs; // guard the u8 cast (alt > 255 traps)
    const a: u8 = if (alt <= ' ') ' ' else @intCast(alt);
    var w = try fits.Wcs.fromHeader(gpa, &hdu.header, a);
    defer w.deinit(gpa);
    return fits.Celestial.fromWcs(&w);
}

/// Convert a 1-based pixel coordinate `(px, py)` to celestial `(lon, lat)` degrees using the
/// current HDU's WCS (`alt` selects an alternate WCS letter; 0/space = primary).
pub export fn zf_wcs_pix2world(h_opt: ?*Handle, alt: c_int, px: f64, py: f64, out_lon: *f64, out_lat: *f64) c_int {
    const h = h_opt orelse return abi.failNull();
    const cel = celestialOf(h, alt) catch |e| return abi.fail(&h.diag, e);
    const world = cel.pixelToWorld(.{ px, py }) catch |e| return abi.fail(&h.diag, e);
    out_lon.* = world[0];
    out_lat.* = world[1];
    return 0;
}

/// Convert celestial `(lon, lat)` degrees to a 1-based pixel coordinate `(px, py)`.
pub export fn zf_wcs_world2pix(h_opt: ?*Handle, alt: c_int, lon: f64, lat: f64, out_px: *f64, out_py: *f64) c_int {
    const h = h_opt orelse return abi.failNull();
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

// Shared body of `zf_write_compressed`/`zf_write_compressed2`/`zf_write_compressed3`.
fn writeCompressedImpl(h_opt: ?*Handle, dtype: c_int, bitpix: c_int, naxis: c_int, axes: [*]const c_long, tile: ?[*]const c_long, codec: [*:0]const u8, quantize: ?[*:0]const u8, zdither0: c_longlong, quantize_level: ?f32, hcomp_scale: f32, hcomp_smooth: bool, pixels: *const anyopaque, nelem: c_longlong) c_int {
    const h = h_opt orelse return abi.failNull();
    if (nelem < 0 or naxis <= 0) return abi.fail(&h.diag, error.BadDimensions);
    var axbuf: [999]u64 = undefined;
    var tilebuf: [999]u64 = undefined;
    const nax: usize = @intCast(@min(naxis, 999));
    for (0..nax) |i| axbuf[i] = std.math.cast(u64, axes[i]) orelse return abi.fail(&h.diag, error.BadDimensions);
    var spec = fits.CompressSpec{
        .bitpix = @intCast(bitpix),
        .axes = axbuf[0..nax],
        .zdither0 = @intCast(zdither0),
        .quantize_level = quantize_level,
        .hcomp_scale = hcomp_scale,
        .hcomp_smooth = hcomp_smooth,
    };
    // `Codec`/`Quantize` are not re-exported at the package root; reach their `fromName` through
    // the `CompressSpec` field types so the shim needs no extra exports.
    spec.codec = @TypeOf(spec.codec).fromName(std.mem.span(codec));
    if (tile) |tl| {
        for (0..nax) |i| tilebuf[i] = std.math.cast(u64, tl[i]) orelse return abi.fail(&h.diag, error.BadTiling);
        spec.tile = tilebuf[0..nax];
    }
    if (quantize) |q| spec.quantize = @TypeOf(spec.quantize).fromName(std.mem.span(q));
    writeCompressedDispatch(@enumFromInt(dtype), h, spec, pixels, @intCast(nelem)) catch |e| return abi.fail(&h.diag, e);
    return 0;
}

/// Append a tile-compressed image HDU. `codec`/`quantize` are NUL-terminated names
/// (`"GZIP_1"`, `"RICE_1"`, `"SUBTRACTIVE_DITHER_1"`, ...). `tile` (or null) overrides the
/// default row-strip tiling.
pub export fn zf_write_compressed(h_opt: ?*Handle, dtype: c_int, bitpix: c_int, naxis: c_int, axes: [*]const c_long, tile: ?[*]const c_long, codec: [*:0]const u8, quantize: ?[*:0]const u8, zdither0: c_longlong, pixels: *const anyopaque, nelem: c_longlong) c_int {
    return writeCompressedImpl(h_opt, dtype, bitpix, naxis, axes, tile, codec, quantize, zdither0, null, 0, false, pixels, nelem);
}

/// `zf_write_compressed` plus the HCOMPRESS_1 lossy knobs (CFITSIO `fits_set_hcomp_scale`/
/// `fits_set_hcomp_smooth` semantics): `hcomp_scale` 0 = lossless, > 0 = per-tile
/// `round(scale × background-noise sigma)`, < 0 = `|scale|` absolute; `hcomp_smooth` non-zero
/// records the `ZNAME2='SMOOTH'` decode-side smoothing request. Setting either knob with a
/// non-HCOMPRESS codec fails (`DataConstraintViolated`) rather than being silently ignored.
/// ABI-additive: existing `zf_write_compressed` callers are unaffected.
pub export fn zf_write_compressed2(h_opt: ?*Handle, dtype: c_int, bitpix: c_int, naxis: c_int, axes: [*]const c_long, tile: ?[*]const c_long, codec: [*:0]const u8, quantize: ?[*:0]const u8, zdither0: c_longlong, hcomp_scale: f32, hcomp_smooth: c_int, pixels: *const anyopaque, nelem: c_longlong) c_int {
    return writeCompressedImpl(h_opt, dtype, bitpix, naxis, axes, tile, codec, quantize, zdither0, null, hcomp_scale, hcomp_smooth != 0, pixels, nelem);
}

/// `zf_write_compressed2` plus the CFITSIO quantization level (`fits_set_quantize_level` /
/// `fpack -q` semantics) for float images with a quantizing `quantize` method (`"NO_DITHER"`,
/// `"SUBTRACTIVE_DITHER_1"`, `"SUBTRACTIVE_DITHER_2"`): `quantize_level` > 0 sets the per-tile
/// step to `sigma/level` (sigma = MAD background noise), 0 the CFITSIO default (`sigma/4`),
/// < 0 the absolute step `|level|`. Pass `has_quantize_level = 0` to leave the level unset
/// (the library default; the pre-existing dithered-GZIP combination then keeps its legacy
/// scheme). A set level with a non-quantizing write fails (`DataConstraintViolated`) rather
/// than being silently ignored. ABI-additive: existing callers are unaffected.
pub export fn zf_write_compressed3(h_opt: ?*Handle, dtype: c_int, bitpix: c_int, naxis: c_int, axes: [*]const c_long, tile: ?[*]const c_long, codec: [*:0]const u8, quantize: ?[*:0]const u8, zdither0: c_longlong, quantize_level: f32, has_quantize_level: c_int, hcomp_scale: f32, hcomp_smooth: c_int, pixels: *const anyopaque, nelem: c_longlong) c_int {
    const qlevel: ?f32 = if (has_quantize_level != 0) quantize_level else null;
    return writeCompressedImpl(h_opt, dtype, bitpix, naxis, axes, tile, codec, quantize, zdither0, qlevel, hcomp_scale, hcomp_smooth != 0, pixels, nelem);
}
