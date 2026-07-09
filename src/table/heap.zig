//! Variable-length-array (VLA) descriptors and the binary-table heap
//! (FR-VLA-1/2/3/4; design §14; FITS 4.0 §7.3.5, §7.3.6).
//!
//! `P`/`Q` columns (`rPt(emax)` / `rQt(emax)`, parsed by `common.BinTform`) store a
//! **descriptor** in the main table row and the payload in the **heap** that follows the
//! main rows. A descriptor is a signed element count and a signed byte offset measured from
//! the start of the heap (`THEAP`). `P` descriptors are two big-endian `i32` (8 bytes), `Q`
//! descriptors two big-endian `i64` (16 bytes).
//!
//! Heap geometry (§14.2):
//!   - `main` = `NAXIS1 × NAXIS2` (the main-table byte size).
//!   - `THEAP` = heap start, measured from the data unit start; defaults to `main` and may not
//!     be smaller (a smaller value is a structural `error.BadTbcol`).
//!   - `gap` = `THEAP − main`; `heap_size` = `PCOUNT − gap`. Bounds are checked against
//!     `heap_size`, **not** `PCOUNT`, so a gap can never admit a read past the data unit.
//!
//! Safety (NFR-SAFE-1): every descriptor is validated *before* allocating — a negative length
//! or offset, an `off + len·elem` that escapes the heap (or the data unit, or the device), an
//! element count beyond `Limits.max_vla_elems`, or a byte length beyond `Limits.max_heap_bytes`
//! all yield typed errors and never a panic or out-of-bounds access.
//!
//! Reads (FR-VLA-3) follow the descriptor into the heap and apply `TSCALn`/`TZEROn` scaling
//! and `convert.cast` exactly as the fixed-column path in `binary.zig` (bulk policy, since a
//! VLA cell is an array transfer), returning an owned slice. The `HeapManager` (FR-VLA-4)
//! tracks allocation within the heap, reuses freed extents on rewrite, and supports compaction
//! so repeatedly rewritten cells do not grow the heap unboundedly.
//!
//! Because `binary.zig`'s `BinTable` is read-only for VLA columns, the write side lives here
//! as free functions that operate on a `*BinTable` plus raw `fits.dev` access (all new code in
//! this file). A `HeapManager` created from an *empty* table (`initForTable`) and used for all
//! writes keeps its accounting consistent with the on-disk descriptors.
const std = @import("std");
const errors = @import("../errors.zig");
const convert = @import("../convert.zig");
const endian = @import("../endian.zig");
const limits = @import("../limits.zig");
const Device = @import("../io/device.zig").Device;
const common = @import("common.zig");
const BinaryType = common.BinaryType;
const binary = @import("binary.zig");
const BinTable = binary.BinTable;
const Column = binary.Column;
const ColumnRef = binary.ColumnRef;

const Allocator = std.mem.Allocator;

/// A variable-length-array descriptor as stored in a table row: a **signed** element count and
/// a **signed** byte offset from the heap start (`THEAP`). Both are signed two's-complement on
/// disk; a negative value in either is rejected as `error.BadDescriptor` when followed.
pub const Descriptor = struct {
    /// Number of array elements (for `bit` arrays, the number of bits; for complex arrays, the
    /// number of complex values).
    len: i64,
    /// Byte offset of the payload from the start of the heap.
    off: i64,
};

/// The descriptor width of a `P`/`Q` column.
pub const Width = enum {
    /// `P`: a 32-bit descriptor (two `i32`, 8 bytes).
    p32,
    /// `Q`: a 64-bit descriptor (two `i64`, 16 bytes).
    q64,

    /// On-disk size of one descriptor in bytes.
    pub fn descBytes(self: Width) u64 {
        return switch (self) {
            .p32 => 8,
            .q64 => 16,
        };
    }
};

/// The parsed shape of a VLA column: its element type, descriptor width, and optional declared
/// maximum element count `(emax)`.
pub const VlaSpec = struct {
    /// Element type of the array payload (`t` in `rPt`).
    elem: BinaryType,
    /// Descriptor width (`P` ⇒ `.p32`, `Q` ⇒ `.q64`).
    width: Width,
    /// Declared maximum element count `(emax)`, or `null` if unspecified.
    emax: ?u64,

    /// Extract the `VlaSpec` of `column`. `error.BadDescriptor` if the column is not a `P`/`Q`
    /// column; `error.BadTform` if it is a descriptor column with no element type (e.g. `1P`).
    pub fn of(column: *const Column) errors.TableError!VlaSpec {
        const width: Width = switch (column.tform.type) {
            .vla32 => .p32,
            .vla64 => .q64,
            else => return error.BadDescriptor,
        };
        const elem = column.tform.vla_elem orelse return error.BadTform;
        return .{ .elem = elem, .width = width, .emax = column.tform.emax };
    }
};

/// A contiguous free region within the heap (offsets relative to the heap start).
pub const Extent = struct {
    /// Byte offset from the heap start.
    off: u64,
    /// Length in bytes.
    len: u64,
};

/// Resolved heap geometry for a table (§14.2). All offsets are absolute file offsets except
/// `theap`/`gap`/`heap_size`, which are relative byte counts.
pub const HeapGeometry = struct {
    /// `NAXIS1 × NAXIS2`, the main-table byte size.
    main: u64,
    /// `THEAP`, the heap start measured from the data unit start.
    theap: u64,
    /// `THEAP − main`, the gap between the main table and the heap.
    gap: u64,
    /// `PCOUNT − gap`, the number of bytes available for heap data.
    heap_size: u64,
    /// Absolute file offset of the heap start (`data_off + THEAP`).
    heap_abs_off: u64,
    /// Absolute file offset one past the end of the data unit (`data_off + data_bytes`).
    data_abs_end: u64,
};

/// Errors from resolving heap geometry.
pub const GeomError = errors.TableError || errors.LimitError;

/// Errors from reading or writing a row descriptor.
pub const DescriptorError = errors.TableError || errors.IoError || errors.LimitError;

/// Errors from `readVlaCell`.
pub const ReadError = errors.TableError || errors.IoError || errors.ConvError ||
    errors.LimitError || Allocator.Error;

/// Errors from `writeVlaCell` / `freeVlaCell`.
pub const WriteError = errors.TableError || errors.IoError || errors.ConvError ||
    errors.LimitError || Allocator.Error;

/// Errors from `HeapManager.compact`.
pub const CompactError = errors.TableError || errors.IoError || errors.LimitError ||
    Allocator.Error;

const SCRATCH_BYTES: usize = 8192;

// ── geometry ─────────────────────────────────────────────────────────────────────────────

/// Resolve the heap geometry of `table` from its HDU (`data_off`, `data_bytes`, `pcount`) and
/// the `THEAP` keyword. `THEAP` defaults to `NAXIS1×NAXIS2` and may not be smaller
/// (`error.BadTbcol`); a `THEAP` that would make the heap size negative is likewise
/// `error.BadTbcol`. All arithmetic is checked (`error.LimitExceeded` on overflow).
pub fn heapGeometry(table: *const BinTable) GeomError!HeapGeometry {
    const main = try limits.mul(table.naxis1, table.naxis2);
    const pcount = table.hdu.pcount;
    // An absent THEAP defaults to the minimum legal value; a THEAP that is *present* but cannot
    // be read as a non-negative integer is a structural error (a bare `catch main` would have
    // masked a corrupt value as the default).
    const theap = table.hdu.header.getValue(u64, "THEAP") catch |e| switch (e) {
        error.KeywordNotFound => main,
        else => return error.BadTbcol,
    };
    if (theap < main) return error.BadTbcol;
    const gap = theap - main;
    if (gap > pcount) return error.BadTbcol;
    const heap_size = pcount - gap;
    const heap_abs_off = try limits.add(table.hdu.data_off, theap);
    const data_abs_end = try limits.add(table.hdu.data_off, table.hdu.data_bytes);
    return .{
        .main = main,
        .theap = theap,
        .gap = gap,
        .heap_size = heap_size,
        .heap_abs_off = heap_abs_off,
        .data_abs_end = data_abs_end,
    };
}

// Number of caller-buffer slots a VLA cell of `len` elements occupies: `2×len` for complex
// (real, imaginary), `len` otherwise (one slot per element / per bit / per char byte).
fn slotCount(elem: BinaryType, len: u64) errors.LimitError!u64 {
    return switch (elem) {
        .complex32, .complex64 => limits.mul(2, len),
        else => len,
    };
}

// On-disk byte length of a VLA payload of `len` elements: `ceil(len/8)` for bits, `len×elem`
// otherwise (the complex per-element sizes 8/16 already cover the real+imaginary pair).
fn byteLen(elem: BinaryType, len: u64) errors.LimitError!u64 {
    return switch (elem) {
        .bit => (len + 7) / 8,
        else => limits.mul(len, elem.elemBytes()),
    };
}

// ── descriptors ──────────────────────────────────────────────────────────────────────────

fn descAbsOffset(table: *const BinTable, column: *const Column, row: u64) DescriptorError!u64 {
    if (!column.tform.type.isVla()) return error.BadDescriptor;
    if (row >= table.naxis2) return error.RowOutOfRange;
    const row_off = try limits.mul(row, table.naxis1);
    const base = try limits.add(table.hdu.data_off, row_off);
    return limits.add(base, column.byte_offset);
}

fn readDescAt(table: *BinTable, column: *const Column, row: u64) DescriptorError!Descriptor {
    const off = try descAbsOffset(table, column, row);
    var buf: [16]u8 = undefined;
    switch (column.tform.type) {
        .vla32 => {
            try table.fits.dev.readAll(buf[0..8], off);
            return .{ .len = endian.read(i32, buf[0..4]), .off = endian.read(i32, buf[4..8]) };
        },
        .vla64 => {
            try table.fits.dev.readAll(buf[0..16], off);
            return .{ .len = endian.read(i64, buf[0..8]), .off = endian.read(i64, buf[8..16]) };
        },
        else => unreachable,
    }
}

fn writeDescAt(table: *BinTable, column: *const Column, row: u64, desc: Descriptor) DescriptorError!void {
    if (table.fits.mode == .read_only or !table.fits.dev.isWritable()) return error.NotWritable;
    const off = try descAbsOffset(table, column, row);
    var buf: [16]u8 = undefined;
    switch (column.tform.type) {
        .vla32 => {
            const l = std.math.cast(i32, desc.len) orelse return error.BadDescriptor;
            const o = std.math.cast(i32, desc.off) orelse return error.BadDescriptor;
            endian.write(i32, l, buf[0..4]);
            endian.write(i32, o, buf[4..8]);
            try table.fits.dev.writeAll(buf[0..8], off);
        },
        .vla64 => {
            endian.write(i64, desc.len, buf[0..8]);
            endian.write(i64, desc.off, buf[8..16]);
            try table.fits.dev.writeAll(buf[0..16], off);
        },
        else => unreachable,
    }
}

/// Read the raw (unvalidated) descriptor stored at (`row`, `col`). `error.BadDescriptor` if the
/// column is not a `P`/`Q` column; `error.RowOutOfRange` if `row` is past `NAXIS2`.
pub fn readDescriptor(table: *BinTable, col: ColumnRef, row: u64) DescriptorError!Descriptor {
    const column = &table.columns[try table.resolve(col)];
    return readDescAt(table, column, row);
}

/// Write `desc` into the row descriptor at (`row`, `col`). For a `P` column the length and
/// offset must fit in `i32` (else `error.BadDescriptor`). `error.NotWritable` on a read-only
/// handle. This is a low-level primitive; prefer `writeVlaCell` for payload + descriptor.
pub fn setDescriptor(table: *BinTable, col: ColumnRef, row: u64, desc: Descriptor) DescriptorError!void {
    const column = &table.columns[try table.resolve(col)];
    return writeDescAt(table, column, row, desc);
}

// ── reading ──────────────────────────────────────────────────────────────────────────────

/// Read the variable-length array at (`row`, `col`) into a freshly allocated, owned `[]T`
/// (caller frees with `alloc`). The descriptor is followed into the heap and every value is
/// converted to `T` with `TSCALn`/`TZEROn` scaling applied under the bulk policy, exactly as
/// fixed columns (FR-VLA-3). For a complex element type the result holds `2×len` slots (real,
/// imaginary); for a `bit` array, `len` slots (one per bit); otherwise `len` slots.
///
/// `error.BadDescriptor` for a non-VLA column, a negative length/offset, or a payload that
/// escapes the heap / data unit / device; `error.BadTform` for a `P`/`Q` column without an
/// element type; `error.LimitExceeded` when the element count or byte length exceeds the
/// configured limits (checked before allocating).
pub fn readVlaCell(alloc: Allocator, table: *BinTable, col: ColumnRef, row: u64, comptime T: type) ReadError![]T {
    const column = &table.columns[try table.resolve(col)];
    const spec = try VlaSpec.of(column);
    const desc = try readDescAt(table, column, row);
    if (desc.len < 0) return error.BadDescriptor;

    // Resolve the (table-level, structural) heap geometry first so a bad THEAP/PCOUNT surfaces
    // for every read, even a zero-length one.
    const geom = try heapGeometry(table);

    // §7.3.5: when the element count is zero the byte offset is undefined, so a zero-length cell
    // short-circuits to an empty slice BEFORE the offset is validated — a garbage (out of range
    // or negative) offset on a zero-length cell is legal and must not be rejected.
    if (desc.len == 0) return alloc.alloc(T, 0);
    if (desc.off < 0) return error.BadDescriptor;
    const len: u64 = @intCast(desc.len);
    const off: u64 = @intCast(desc.off);

    const bytes = try byteLen(spec.elem, len);

    // Validate against the configured limits BEFORE allocating (NFR-SAFE-1).
    try limits.ensureWithin(len, table.fits.limits.max_vla_elems, null);
    try limits.ensureWithin(bytes, table.fits.limits.max_heap_bytes, null);

    // Bounds-check the payload against the heap size, the data unit, and the device length.
    const heap_end = std.math.add(u64, off, bytes) catch return error.BadDescriptor;
    if (heap_end > geom.heap_size) return error.BadDescriptor;
    const abs = geom.heap_abs_off + off;
    const abs_end = abs + bytes;
    if (abs_end > geom.data_abs_end) return error.BadDescriptor;
    const dev_size = try table.fits.dev.getSize();
    if (abs_end > dev_size) return error.BadDescriptor;

    const slots = try slotCount(spec.elem, len);
    const n: usize = std.math.cast(usize, slots) orelse return error.LimitExceeded;
    const out = try alloc.alloc(T, n);
    errdefer alloc.free(out);
    try fillFromHeap(T, table.fits.dev, abs, spec.elem, out, column);
    return out;
}

fn fillFromHeap(comptime T: type, dev: Device, abs: u64, elem: BinaryType, out: []T, column: *const Column) (errors.IoError || errors.ConvError)!void {
    switch (elem) {
        .logical => try readLogicalRun(T, dev, abs, out),
        .bit => try readBitRun(T, dev, abs, out),
        .char => try readCharRun(T, dev, abs, out),
        .byte => try readStoredRun(u8, T, dev, abs, out, column),
        .int16 => try readStoredRun(i16, T, dev, abs, out, column),
        .int32 => try readStoredRun(i32, T, dev, abs, out, column),
        .int64 => try readStoredRun(i64, T, dev, abs, out, column),
        .float32 => try readStoredRun(f32, T, dev, abs, out, column),
        .float64 => try readStoredRun(f64, T, dev, abs, out, column),
        .complex32 => try readStoredRun(f32, T, dev, abs, out, column),
        .complex64 => try readStoredRun(f64, T, dev, abs, out, column),
        .vla32, .vla64 => unreachable,
    }
}

// ── writing ──────────────────────────────────────────────────────────────────────────────

/// Write a variable-length array `in` into the heap at (`row`, `col`) and set the row
/// descriptor. Space is reserved through `mgr`; any extent previously referenced by this cell
/// is freed first so a rewrite reuses freed space and does not grow the heap unboundedly
/// (FR-VLA-4). Values are converted from `T` to the stored element type with inverse
/// `TSCALn`/`TZEROn` scaling under the bulk policy (FR-VLA-3). For a complex element type
/// `in.len` must be even (`2×len` real/imaginary slots).
///
/// `error.NotWritable` on a read-only handle; `error.HeapOverflow` when the heap has no room;
/// `error.LimitExceeded` when the element count or byte length exceeds the configured limits.
pub fn writeVlaCell(alloc: Allocator, table: *BinTable, mgr: *HeapManager, col: ColumnRef, row: u64, comptime T: type, in: []const T) WriteError!void {
    if (table.fits.mode == .read_only or !table.fits.dev.isWritable()) return error.NotWritable;
    const column = &table.columns[try table.resolve(col)];
    const spec = try VlaSpec.of(column);
    if (row >= table.naxis2) return error.RowOutOfRange;

    const len: u64 = switch (spec.elem) {
        .complex32, .complex64 => blk: {
            if (in.len % 2 != 0) return error.CellOutOfRange;
            break :blk in.len / 2;
        },
        else => in.len,
    };
    try limits.ensureWithin(len, table.fits.limits.max_vla_elems, null);
    const bytes = try byteLen(spec.elem, len);
    try limits.ensureWithin(bytes, table.fits.limits.max_heap_bytes, null);

    const geom = try heapGeometry(table);

    // Release any extent this cell currently references (rewrite reuse, FR-VLA-4).
    try freeExisting(alloc, table, mgr, column, row, spec.elem, &geom);

    if (len == 0) {
        try writeDescAt(table, column, row, .{ .len = 0, .off = 0 });
        return;
    }

    const heap_off = try mgr.alloc(bytes);
    if ((std.math.add(u64, heap_off, bytes) catch return error.HeapOverflow) > geom.heap_size) {
        return error.HeapOverflow;
    }
    const abs = try limits.add(geom.heap_abs_off, heap_off);
    try drainToHeap(T, table.fits.dev, abs, spec.elem, in, column);
    try writeDescAt(table, column, row, .{ .len = @intCast(len), .off = @intCast(heap_off) });
}

/// Mark the variable-length cell at (`row`, `col`) empty: free its heap extent through `mgr`
/// and zero its descriptor. A subsequent `readVlaCell` returns an empty slice. `compact` will
/// then skip the cell. `error.NotWritable` on a read-only handle.
pub fn freeVlaCell(alloc: Allocator, table: *BinTable, mgr: *HeapManager, col: ColumnRef, row: u64) WriteError!void {
    if (table.fits.mode == .read_only or !table.fits.dev.isWritable()) return error.NotWritable;
    const column = &table.columns[try table.resolve(col)];
    const spec = try VlaSpec.of(column);
    if (row >= table.naxis2) return error.RowOutOfRange;
    const geom = try heapGeometry(table);
    try freeExisting(alloc, table, mgr, column, row, spec.elem, &geom);
    try writeDescAt(table, column, row, .{ .len = 0, .off = 0 });
}

// Free the extent currently referenced by the row descriptor, if it is a valid, in-heap
// region. A corrupt descriptor is ignored (not trusted to free arbitrary bytes).
fn freeExisting(alloc: Allocator, table: *BinTable, mgr: *HeapManager, column: *const Column, row: u64, elem: BinaryType, geom: *const HeapGeometry) WriteError!void {
    const d = try readDescAt(table, column, row);
    if (d.len > 0 and d.off >= 0) {
        const old_len: u64 = @intCast(d.len);
        const old_off: u64 = @intCast(d.off);
        const old_bytes = byteLen(elem, old_len) catch return;
        const end = std.math.add(u64, old_off, old_bytes) catch return;
        if (end <= geom.heap_size) try mgr.free(alloc, old_off, old_bytes);
    }
}

fn drainToHeap(comptime T: type, dev: Device, abs: u64, elem: BinaryType, in: []const T, column: *const Column) (errors.IoError || errors.ConvError)!void {
    switch (elem) {
        .logical => try writeLogicalRun(T, dev, abs, in),
        .bit => try writeBitRun(T, dev, abs, in),
        .char => try writeCharRun(T, dev, abs, in),
        .byte => try writeStoredRun(u8, T, dev, abs, in, column),
        .int16 => try writeStoredRun(i16, T, dev, abs, in, column),
        .int32 => try writeStoredRun(i32, T, dev, abs, in, column),
        .int64 => try writeStoredRun(i64, T, dev, abs, in, column),
        .float32 => try writeStoredRun(f32, T, dev, abs, in, column),
        .float64 => try writeStoredRun(f64, T, dev, abs, in, column),
        .complex32 => try writeStoredRun(f32, T, dev, abs, in, column),
        .complex64 => try writeStoredRun(f64, T, dev, abs, in, column),
        .vla32, .vla64 => unreachable,
    }
}

// ── HeapManager ──────────────────────────────────────────────────────────────────────────

/// Tracks byte allocation within the heap so rewritten variable cells reuse freed space and do
/// not grow the heap unboundedly (FR-VLA-4). A bump pointer (`top`) hands out fresh space up to
/// `capacity` (the heap size), and a free list holds released extents for reuse. Compaction
/// repacks the live payloads to the front of the heap and rewrites their descriptors.
///
/// Create one from an empty table with `initForTable` and route every VLA write through
/// `writeVlaCell`/`freeVlaCell` so the accounting matches the on-disk descriptors.
pub const HeapManager = struct {
    /// Released extents available for reuse (offsets relative to the heap start).
    free_list: std.ArrayList(Extent) = .empty,
    /// Bump pointer: the first never-yet-allocated heap offset (the live high-water mark).
    top: u64 = 0,
    /// Heap capacity in bytes (`PCOUNT − gap`); allocations beyond it are `error.HeapOverflow`.
    capacity: u64,

    /// A manager for a heap of `capacity` bytes (a freshly reserved, empty heap).
    pub fn init(capacity: u64) HeapManager {
        return .{ .capacity = capacity };
    }

    /// A manager sized to `table`'s heap (`capacity = heap_size`), assuming the heap starts
    /// empty. Resolves the geometry, so a bad `THEAP`/`PCOUNT` surfaces here.
    pub fn initForTable(table: *const BinTable) GeomError!HeapManager {
        const geom = try heapGeometry(table);
        return .{ .capacity = geom.heap_size };
    }

    /// Release the free list.
    pub fn deinit(self: *HeapManager, gpa: Allocator) void {
        self.free_list.deinit(gpa);
    }

    /// Reset to an empty heap (clears the free list and the bump pointer).
    pub fn reset(self: *HeapManager) void {
        self.free_list.clearRetainingCapacity();
        self.top = 0;
    }

    /// Reserve `bytes` and return the heap-relative offset. Reuses the smallest free extent that
    /// fits (best-fit), else bumps `top`. `error.HeapOverflow` if there is no room within
    /// `capacity`. A zero-byte request returns `top` without consuming space.
    pub fn alloc(self: *HeapManager, bytes: u64) errors.TableError!u64 {
        if (bytes == 0) return self.top;
        // Best-fit reuse from the free list.
        var best: ?usize = null;
        for (self.free_list.items, 0..) |ext, i| {
            if (ext.len >= bytes) {
                if (best == null or ext.len < self.free_list.items[best.?].len) best = i;
            }
        }
        if (best) |bi| {
            const ext = self.free_list.items[bi];
            if (ext.len == bytes) {
                _ = self.free_list.orderedRemove(bi);
            } else {
                self.free_list.items[bi] = .{ .off = ext.off + bytes, .len = ext.len - bytes };
            }
            return ext.off;
        }
        // Bump the high-water mark.
        const new_top = std.math.add(u64, self.top, bytes) catch return error.HeapOverflow;
        if (new_top > self.capacity) return error.HeapOverflow;
        const off = self.top;
        self.top = new_top;
        return off;
    }

    /// Return the extent `[off, off+bytes)` to the free list, coalescing with adjacent free
    /// extents; if the result abuts `top`, the bump pointer is simply lowered (no list entry).
    /// Needs an allocator because the free list may grow (the design sketch's infallible `free`
    /// cannot be leak-safe without one).
    pub fn free(self: *HeapManager, gpa: Allocator, off: u64, bytes: u64) Allocator.Error!void {
        if (bytes == 0) return;
        var start = off;
        var end = off +| bytes;
        // Coalesce with any adjacent free extents (repeat until stable).
        var changed = true;
        while (changed) {
            changed = false;
            var i: usize = 0;
            while (i < self.free_list.items.len) : (i += 1) {
                const e = self.free_list.items[i];
                if (e.off +| e.len == start) {
                    start = e.off;
                    _ = self.free_list.orderedRemove(i);
                    changed = true;
                    break;
                } else if (end == e.off) {
                    end = e.off +| e.len;
                    _ = self.free_list.orderedRemove(i);
                    changed = true;
                    break;
                }
            }
        }
        // If the region now abuts the bump pointer, lower it and absorb any further chain.
        if (end == self.top) {
            self.top = start;
            var again = true;
            while (again) {
                again = false;
                var i: usize = 0;
                while (i < self.free_list.items.len) : (i += 1) {
                    const e = self.free_list.items[i];
                    if (e.off +| e.len == self.top) {
                        self.top = e.off;
                        _ = self.free_list.orderedRemove(i);
                        again = true;
                        break;
                    }
                }
            }
            return;
        }
        try self.free_list.append(gpa, .{ .off = start, .len = end - start });
    }

    const Reloc = struct { column: *const Column, row: u64, src: u64, len: u64 };

    // A unique heap byte-extent `[src, src+len)` and the packed offset it is relocated to. Several
    // rows may reference the same extent (aliasing); they all collapse onto one `Group`.
    const Group = struct { src: u64, len: u64, dst: u64 };

    fn lessThanGroup(_: void, a: Group, b: Group) bool {
        if (a.src != b.src) return a.src < b.src;
        return a.len < b.len;
    }

    /// Compact the heap: repack every live VLA payload contiguously from the heap start, rewrite
    /// the affected descriptors, drop the free list, and reset `top` to the packed size
    /// (FR-VLA-4). Live cells are those with a positive descriptor length; empty/freed cells are
    /// skipped.
    ///
    /// On hostile input several descriptors may *alias* the same heap extent. Rows whose
    /// `(src, len)` match exactly are de-aliased: the extent is moved once and all rows are
    /// remapped to that single packed offset, so a relocation never reads bytes another row
    /// already moved. The cumulative packed size is bounded against `heap_size` before every
    /// move, so a forged set of overlapping distinct extents (whose double-counted bytes would
    /// total more than the heap) is rejected with `error.BadDescriptor` instead of writing the
    /// repacked payload past the data unit.
    pub fn compact(self: *HeapManager, gpa: Allocator, table: *BinTable) CompactError!void {
        const geom = try heapGeometry(table);

        var relocs: std.ArrayList(Reloc) = .empty;
        defer relocs.deinit(gpa);

        for (table.columns) |*column| {
            if (!column.tform.type.isVla()) continue;
            const elem = column.tform.vla_elem orelse continue;
            var row: u64 = 0;
            while (row < table.naxis2) : (row += 1) {
                const d = try readDescAt(table, column, row);
                if (d.len <= 0) continue; // empty cell, nothing to relocate
                if (d.off < 0) return error.BadDescriptor;
                const len: u64 = @intCast(d.len);
                const src: u64 = @intCast(d.off);
                const bytes = try byteLen(elem, len);
                const end = std.math.add(u64, src, bytes) catch return error.BadDescriptor;
                if (end > geom.heap_size) return error.BadDescriptor;
                try relocs.append(gpa, .{ .column = column, .row = row, .src = src, .len = bytes });
            }
        }

        // Collapse aliasing rows onto unique `(src, len)` extents.
        var groups: std.ArrayList(Group) = .empty;
        defer groups.deinit(gpa);
        for (relocs.items) |r| {
            var seen = false;
            for (groups.items) |g| {
                if (g.src == r.src and g.len == r.len) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try groups.append(gpa, .{ .src = r.src, .len = r.len, .dst = 0 });
        }

        std.mem.sort(Group, groups.items, {}, lessThanGroup);

        // Pack each unique extent to the front, recording its new offset. The cumulative packed
        // size is bounded against heap_size BEFORE each move: distinct extents that overlap
        // double-count their bytes, so without this check `bump` could exceed heap_size and
        // moveBytes would write the payload past the data unit (OOB write / next-HDU corruption).
        var bump: u64 = 0;
        for (groups.items, 0..) |*g, i| {
            const packed_end = std.math.add(u64, bump, g.len) catch return error.BadDescriptor;
            if (packed_end > geom.heap_size) return error.BadDescriptor;
            if (g.src != bump) {
                // Reject if this relocation's DESTINATION [bump, packed_end) would overwrite a
                // not-yet-moved extent's SOURCE — a cross-extent clobber that silently corrupts
                // that later cell (it relocates the already-overwritten bytes). Only reachable on a
                // forged/corrupt heap with partially overlapping DISTINCT extents; exact aliases
                // were collapsed above, and a move that merely self-overlaps its own source is safe
                // (`moveBytes` copies back-to-front for it). The earlier `packed_end > heap_size`
                // guard bounds OOB writes but not this in-heap clobber.
                for (groups.items[i + 1 ..]) |later| {
                    const later_end = later.src + later.len; // ≤ heap_size by the per-row bound above
                    if (bump < later_end and later.src < packed_end) return error.BadDescriptor;
                }
                try moveBytes(table, geom.heap_abs_off + g.src, geom.heap_abs_off + bump, g.len);
            }
            g.dst = bump;
            bump = packed_end;
        }

        // Rewrite each row's descriptor offset to its extent's packed offset (length unchanged).
        for (relocs.items) |r| {
            const dst = for (groups.items) |g| {
                if (g.src == r.src and g.len == r.len) break g.dst;
            } else unreachable;
            const d = try readDescAt(table, r.column, r.row);
            try writeDescAt(table, r.column, r.row, .{ .len = d.len, .off = @intCast(dst) });
        }

        self.free_list.clearRetainingCapacity();
        self.top = bump;
    }
};

// Copy `len` bytes from `src` to `dst` within the device, overlap-safe in either direction: a
// downward move (`dst < src`, the normal compaction case) copies front-to-back, an upward move
// (`dst > src`, only reachable on a malformed file whose heap extents overlap) copies
// back-to-front, so the source is never clobbered before it is read.
fn moveBytes(table: *BinTable, src: u64, dst: u64, len: u64) errors.IoError!void {
    if (src == dst or len == 0) return;
    var buf: [SCRATCH_BYTES]u8 = undefined;
    if (dst < src) {
        var done: u64 = 0;
        while (done < len) {
            const m: usize = @intCast(@min(@as(u64, buf.len), len - done));
            try table.fits.dev.readAll(buf[0..m], src + done);
            try table.fits.dev.writeAll(buf[0..m], dst + done);
            done += m;
        }
    } else {
        var remaining = len;
        while (remaining > 0) {
            const m: usize = @intCast(@min(@as(u64, buf.len), remaining));
            const o = remaining - m;
            try table.fits.dev.readAll(buf[0..m], src + o);
            try table.fits.dev.writeAll(buf[0..m], dst + o);
            remaining -= m;
        }
    }
}

// ── scaling / conversion (mirrors binary.zig's fixed-column policy, bulk, no null sentinel) ──

// Stored→physical→T: applies TZERO/TSCAL scaling. The integer-space path (`zero_int`) preserves
// the CFITSIO unsigned conventions near 2^63 without f64 precision loss.
fn convertFromStored(comptime Stored: type, comptime T: type, s: Stored, column: *const Column) errors.ConvError!T {
    const sinfo = @typeInfo(Stored);
    if (T == bool) {
        return s != 0;
    } else if (column.scal == 1.0 and column.zero == 0.0) {
        return convert.cast(T, s, .bulk);
    } else if (sinfo == .int and @typeInfo(T) == .int and column.zero_int != null) {
        const phys: i128 = @as(i128, s) + column.zero_int.?;
        return convert.cast(T, phys, .bulk);
    } else {
        const sf: f64 = if (sinfo == .int) @floatFromInt(s) else @as(f64, s);
        const phys: f64 = column.zero + column.scal * sf;
        return convert.cast(T, phys, .bulk);
    }
}

// T→physical→Stored: the inverse scaling for writes.
fn convertToStored(comptime Stored: type, comptime T: type, v: T, column: *const Column) errors.ConvError!Stored {
    if (T == bool) {
        return if (v) @as(Stored, 1) else @as(Stored, 0);
    } else if (column.scal == 1.0 and column.zero == 0.0) {
        return convert.cast(Stored, v, .bulk);
    } else if (@typeInfo(Stored) == .int and @typeInfo(T) == .int and column.zero_int != null) {
        const phys: i128 = @as(i128, v) - column.zero_int.?;
        return convert.cast(Stored, phys, .bulk);
    } else {
        const vf: f64 = switch (@typeInfo(T)) {
            .int => @floatFromInt(v),
            .float => @floatCast(v),
            else => unreachable,
        };
        const stored_f: f64 = (vf - column.zero) / column.scal;
        return convert.cast(Stored, stored_f, .bulk);
    }
}

// ── per-type transfer cores (heap payload; chunked, byte-swapped, scaled) ────────────────────

fn readStoredRun(comptime Stored: type, comptime T: type, dev: Device, off: u64, out: []T, column: *const Column) (errors.IoError || errors.ConvError)!void {
    const cap = @max(1, SCRATCH_BYTES / @sizeOf(Stored));
    var scratch: [cap]Stored = undefined;
    var done: usize = 0;
    while (done < out.len) {
        const m = @min(scratch.len, out.len - done);
        const raw = std.mem.sliceAsBytes(scratch[0..m]);
        try dev.readAll(raw, off + @as(u64, done) * @sizeOf(Stored));
        endian.swapToNative(Stored, scratch[0..m]);
        for (scratch[0..m], 0..) |s, i| out[done + i] = try convertFromStored(Stored, T, s, column);
        done += m;
    }
}

fn writeStoredRun(comptime Stored: type, comptime T: type, dev: Device, off: u64, in: []const T, column: *const Column) (errors.IoError || errors.ConvError)!void {
    const cap = @max(1, SCRATCH_BYTES / @sizeOf(Stored));
    var scratch: [cap]Stored = undefined;
    var done: usize = 0;
    while (done < in.len) {
        const m = @min(scratch.len, in.len - done);
        for (0..m) |i| scratch[i] = try convertToStored(Stored, T, in[done + i], column);
        endian.swapToBig(Stored, scratch[0..m]);
        const raw = std.mem.sliceAsBytes(scratch[0..m]);
        try dev.writeAll(raw, off + @as(u64, done) * @sizeOf(Stored));
        done += m;
    }
}

// L: 'T'/'F' bytes ↔ bool/numeric; a 0 byte reads as false/0 (the logical null, no sentinel).
fn readLogicalRun(comptime T: type, dev: Device, off: u64, out: []T) (errors.IoError || errors.ConvError)!void {
    var scratch: [SCRATCH_BYTES]u8 = undefined;
    var done: usize = 0;
    while (done < out.len) {
        const m = @min(scratch.len, out.len - done);
        try dev.readAll(scratch[0..m], off + done);
        for (scratch[0..m], 0..) |b, i| {
            if (T == bool) {
                out[done + i] = (b == 'T' or b == 't');
            } else {
                const tv: u8 = if (b == 'T' or b == 't') 1 else 0;
                out[done + i] = try convert.cast(T, tv, .bulk);
            }
        }
        done += m;
    }
}

fn writeLogicalRun(comptime T: type, dev: Device, off: u64, in: []const T) (errors.IoError || errors.ConvError)!void {
    var scratch: [SCRATCH_BYTES]u8 = undefined;
    var done: usize = 0;
    while (done < in.len) {
        const m = @min(scratch.len, in.len - done);
        for (0..m) |i| {
            const truth: bool = if (T == bool) in[done + i] else (in[done + i] != 0);
            scratch[i] = if (truth) 'T' else 'F';
        }
        try dev.writeAll(scratch[0..m], off + done);
        done += m;
    }
}

// X: MSB-first packed bits ↔ one element per bit. `out.len` is the bit count.
fn readBitRun(comptime T: type, dev: Device, off: u64, out: []T) (errors.IoError || errors.ConvError)!void {
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
                out[bit_index] = if (T == bool) (bitval == 1) else try convert.cast(T, bitval, .bulk);
            }
        }
        byte_done += m;
    }
}

fn writeBitRun(comptime T: type, dev: Device, off: u64, in: []const T) (errors.IoError || errors.ConvError)!void {
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

// A: decode terminates at the first NUL (rest → spaces); leading NUL ⇒ null (all spaces). For
// non-`u8` `T`, each byte is converted with no string semantics.
fn readCharRun(comptime T: type, dev: Device, off: u64, out: []T) (errors.IoError || errors.ConvError)!void {
    var scratch: [SCRATCH_BYTES]u8 = undefined;
    var done: usize = 0;
    var hit_nul = false;
    while (done < out.len) {
        const m = @min(scratch.len, out.len - done);
        try dev.readAll(scratch[0..m], off + done);
        for (scratch[0..m], 0..) |b, i| {
            if (T == u8) {
                if (hit_nul) {
                    out[done + i] = ' ';
                } else if (b == 0) {
                    hit_nul = true;
                    out[done + i] = ' ';
                } else {
                    out[done + i] = b;
                }
            } else {
                out[done + i] = try convert.cast(T, b, .bulk);
            }
        }
        done += m;
    }
}

// A: encode pads with spaces; once an input NUL is seen the remainder of the field is spaces.
fn writeCharRun(comptime T: type, dev: Device, off: u64, in: []const T) (errors.IoError || errors.ConvError)!void {
    var scratch: [SCRATCH_BYTES]u8 = undefined;
    var done: usize = 0;
    var hit_nul = false;
    while (done < in.len) {
        const m = @min(scratch.len, in.len - done);
        for (0..m) |i| {
            if (T == u8) {
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
                scratch[i] = try convert.cast(u8, in[done + i], .bulk);
            }
        }
        try dev.writeAll(scratch[0..m], off + done);
        done += m;
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const Fits = @import("../fits.zig").Fits;
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;
const Header = @import("../header/header.zig").Header;
const Hdu = @import("../hdu.zig").Hdu;
const BinTform = common.BinTform;
const KeywordValue = @import("../header/value.zig").KeywordValue;

const HdrOpts = struct {
    tscal: ?f64 = null,
    tzero: ?f64 = null,
    theap: ?u64 = null,
    /// A non-integer THEAP value (to exercise the present-but-unparseable path).
    theap_str: ?[]const u8 = null,
};

fn vlaHeader(alloc: Allocator, tform: []const u8, nrows: u64, pcount: u64, opts: HdrOpts) !Header {
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    const naxis1 = try (try BinTform.parse(tform)).fieldBytes();
    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = @intCast(naxis1) }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = @intCast(nrows) }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = @intCast(pcount) }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFORM1", .{ .string = tform }, null);
    try h.appendValue(alloc, "TTYPE1", .{ .string = "VLA" }, null);
    if (opts.theap) |t| try h.appendValue(alloc, "THEAP", .{ .int = @intCast(t) }, null);
    if (opts.theap_str) |s| try h.appendValue(alloc, "THEAP", .{ .string = s }, null);
    if (opts.tscal) |s| try h.appendValue(alloc, "TSCAL1", .{ .float = s }, null);
    if (opts.tzero) |z| try h.appendValue(alloc, "TZERO1", .{ .float = z }, null);
    try h.ensureEnd(alloc);
    return h;
}

fn makeVlaHdu(f: *Fits, alloc: Allocator, tform: []const u8, nrows: u64, pcount: u64, opts: HdrOpts) !*Hdu {
    const h = try vlaHeader(alloc, tform, nrows, pcount, opts);
    return f.appendHdu(h);
}

// A handle + memory device packaged so tests can build a one-column VLA table quickly.
const Fixture = struct {
    mem: *MemoryDevice,
    f: Fits,

    fn init(alloc: Allocator, lim: limits.Limits) !Fixture {
        const mem = try alloc.create(MemoryDevice);
        mem.* = MemoryDevice.init(alloc);
        var f = try Fits.create(alloc, mem.device(), .{ .limits = lim });
        errdefer f.deinit();
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary
        return .{ .mem = mem, .f = f };
    }

    fn deinit(self: *Fixture, alloc: Allocator) void {
        self.f.deinit();
        self.mem.deinit();
        alloc.destroy(self.mem);
    }
};

test "round-trip: write heap, set descriptor, read VLA cell (1PJ)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 2, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);

    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);
    try testing.expectEqual(@as(u64, 64), mgr.capacity);

    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 10, 20, 30 });
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 1, i32, &[_]i32{ 7, 8 });

    // Descriptors landed contiguously from the heap start.
    const d0 = try readDescriptor(&t, .{ .index = 0 }, 0);
    const d1 = try readDescriptor(&t, .{ .index = 0 }, 1);
    try testing.expectEqual(@as(i64, 3), d0.len);
    try testing.expectEqual(@as(i64, 0), d0.off);
    try testing.expectEqual(@as(i64, 2), d1.len);
    try testing.expectEqual(@as(i64, 12), d1.off);

    const r0 = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r0);
    const r1 = try readVlaCell(alloc, &t, .{ .name = "vla" }, 1, i32);
    defer alloc.free(r1);
    try testing.expectEqualSlices(i32, &[_]i32{ 10, 20, 30 }, r0);
    try testing.expectEqualSlices(i32, &[_]i32{ 7, 8 }, r1);

    // Cross-type read (J stored, widened to i64 / f64 under bulk).
    const r0_64 = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i64);
    defer alloc.free(r0_64);
    try testing.expectEqualSlices(i64, &[_]i64{ 10, 20, 30 }, r0_64);
}

test "rewrites reuse freed space and do not grow the heap (FR-VLA-4)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 1, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 1, 2, 3 });
    try testing.expectEqual(@as(u64, 12), mgr.top);

    // Rewriting the same cell with an equal-size array reuses the extent: top stays bounded.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 4, 5, 6 });
        try testing.expectEqual(@as(u64, 12), mgr.top);
        try testing.expectEqual(@as(usize, 0), mgr.free_list.items.len);
    }
    const r = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r);
    try testing.expectEqualSlices(i32, &[_]i32{ 4, 5, 6 }, r);
}

test "compaction repacks live cells, drops the gap, preserves data" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 3, 128, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 1, 2, 3 }); // off 0,  12B
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 1, i32, &[_]i32{ 10, 20 }); // off 12,  8B
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 2, i32, &[_]i32{ 100, 200, 300, 400 }); // off 20, 16B
    try testing.expectEqual(@as(u64, 36), mgr.top);

    // Free the middle cell, leaving a gap.
    try freeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 1);
    try testing.expect(mgr.top == 36); // freed extent is interior, recorded in the free list

    try mgr.compact(alloc, &t);
    try testing.expectEqual(@as(u64, 28), mgr.top); // 12 + 16, gap removed
    try testing.expectEqual(@as(usize, 0), mgr.free_list.items.len);

    // Live cells still read back; row 2 moved from off 20 → 12.
    const d2 = try readDescriptor(&t, .{ .index = 0 }, 2);
    try testing.expectEqual(@as(i64, 12), d2.off);

    const r0 = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r0);
    const r1 = try readVlaCell(alloc, &t, .{ .index = 0 }, 1, i32);
    defer alloc.free(r1);
    const r2 = try readVlaCell(alloc, &t, .{ .index = 0 }, 2, i32);
    defer alloc.free(r2);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, r0);
    try testing.expectEqual(@as(usize, 0), r1.len); // freed → empty
    try testing.expectEqualSlices(i32, &[_]i32{ 100, 200, 300, 400 }, r2);
}

test "TSCAL/TZERO scaling applies on VLA read/write (1PE)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // physical = TZERO + TSCAL × stored ⇒ stored = (physical − 1) / 2.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PE", 1, 64, .{ .tscal = 2.0, .tzero = 1.0 });
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, f64, &[_]f64{ 3.0, 5.0, 9.0 });

    // Raw stored f32 in the heap must be the de-scaled values 1, 2, 4.
    const geom = try heapGeometry(&t);
    var raw: [12]u8 = undefined;
    try fx.f.dev.readAll(&raw, geom.heap_abs_off);
    try testing.expectEqual(@as(f32, 1.0), endian.read(f32, raw[0..4]));
    try testing.expectEqual(@as(f32, 2.0), endian.read(f32, raw[4..8]));
    try testing.expectEqual(@as(f32, 4.0), endian.read(f32, raw[8..12]));

    const r = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, f64);
    defer alloc.free(r);
    try testing.expectEqualSlices(f64, &[_]f64{ 3.0, 5.0, 9.0 }, r);
}

test "Q (64-bit) descriptor round-trips (1QK)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1QK", 1, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    const vals = [_]i64{ 1, -2, 1 << 40, std.math.maxInt(i64) };
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i64, &vals);
    const d = try readDescriptor(&t, .{ .index = 0 }, 0);
    try testing.expectEqual(@as(i64, 4), d.len);

    const r = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i64);
    defer alloc.free(r);
    try testing.expectEqualSlices(i64, &vals, r);
}

test "complex VLA (1PC) round-trips as paired slots" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PC", 1, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    // Two complex values: (1.5, -2.5) and (3.0, 4.0) ⇒ 4 f32 slots, len = 2.
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, f32, &[_]f32{ 1.5, -2.5, 3.0, 4.0 });
    const d = try readDescriptor(&t, .{ .index = 0 }, 0);
    try testing.expectEqual(@as(i64, 2), d.len);

    const r = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, f32);
    defer alloc.free(r);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.5, -2.5, 3.0, 4.0 }, r);
}

test "char VLA (1PA) heap string round-trips with NUL/space semantics" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PA", 1, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, u8, "hello");
    const r = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, u8);
    defer alloc.free(r);
    try testing.expectEqualStrings("hello", r);
}

test "explicit THEAP gap is honored; heap_size excludes the gap" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // NAXIS1=8, NAXIS2=2 ⇒ main=16. THEAP=24 ⇒ gap=8. PCOUNT=72 ⇒ heap_size=64.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 2, 72, .{ .theap = 24 });
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    const geom = try heapGeometry(&t);
    try testing.expectEqual(@as(u64, 16), geom.main);
    try testing.expectEqual(@as(u64, 24), geom.theap);
    try testing.expectEqual(@as(u64, 8), geom.gap);
    try testing.expectEqual(@as(u64, 64), geom.heap_size);

    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 42, 43 });
    const r = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r);
    try testing.expectEqualSlices(i32, &[_]i32{ 42, 43 }, r);
}

test "negative descriptor length/offset is rejected" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 1, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);

    try setDescriptor(&t, .{ .index = 0 }, 0, .{ .len = -1, .off = 0 });
    try testing.expectError(error.BadDescriptor, readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32));
    try setDescriptor(&t, .{ .index = 0 }, 0, .{ .len = 1, .off = -4 });
    try testing.expectError(error.BadDescriptor, readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32));
}

test "out-of-bounds descriptor (past heap) is rejected" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 1, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);

    // len=100 ⇒ 400 bytes, well past heap_size=64.
    try setDescriptor(&t, .{ .index = 0 }, 0, .{ .len = 100, .off = 0 });
    try testing.expectError(error.BadDescriptor, readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32));
    // offset near the end with a small length still overruns.
    try setDescriptor(&t, .{ .index = 0 }, 0, .{ .len = 1, .off = 62 });
    try testing.expectError(error.BadDescriptor, readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32));
}

test "THEAP smaller than NAXIS1*NAXIS2 is a structural error" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // main = 8*1 = 8; THEAP=4 < main ⇒ BadTbcol.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 1, 64, .{ .theap = 4 });
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    try testing.expectError(error.BadTbcol, heapGeometry(&t));
    try testing.expectError(error.BadTbcol, readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32));
}

test "THEAP present but unparseable is a structural error (not the default)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // A THEAP whose value is a string (not a non-negative integer) must surface BadTbcol rather
    // than be silently masked as the default heap start.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 1, 64, .{ .theap_str = "oops" });
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    try testing.expectError(error.BadTbcol, heapGeometry(&t));
    try testing.expectError(error.BadTbcol, readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32));
}

test "structural row edits rewrite an explicit default THEAP (grow: appendRows)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // Explicit THEAP equal to its default (main = 8*2 = 16) is conforming; a row append must
    // rewrite it to the new default alongside the relocated heap, or every later VLA read
    // trips the theap < main structural check.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 2, 64, .{ .theap = 16 });
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 111, 222, 333 });
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 1, i32, &[_]i32{ 444, 555 });

    try t.appendRows(1);

    try testing.expectEqual(@as(i64, 24), try t.hdu.header.getValue(i64, "THEAP"));
    const r0 = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r0);
    const r1 = try readVlaCell(alloc, &t, .{ .index = 0 }, 1, i32);
    defer alloc.free(r1);
    try testing.expectEqualSlices(i32, &[_]i32{ 111, 222, 333 }, r0);
    try testing.expectEqualSlices(i32, &[_]i32{ 444, 555 }, r1);

    // A fresh open sees the rewritten card and the same VLA bytes on the device.
    var f2 = try Fits.open(alloc, fx.mem.device(), .read_only, .{});
    defer f2.deinit();
    const hdu2 = try f2.select(2);
    try testing.expectEqual(@as(i64, 24), try hdu2.header.getValue(i64, "THEAP"));
    var t2 = try BinTable.of(&f2, hdu2);
    defer t2.deinit(alloc);
    const rr = try readVlaCell(alloc, &t2, .{ .index = 0 }, 0, i32);
    defer alloc.free(rr);
    try testing.expectEqualSlices(i32, &[_]i32{ 111, 222, 333 }, rr);
}

test "structural row edits rewrite an explicit default THEAP (shrink: deleteRows)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // main = 8*3 = 24. After deleting a row the heap slides down to the new default (16); a
    // stale THEAP=24 would silently read the heap 8 bytes off.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 3, 64, .{ .theap = 24 });
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 111, 222, 333 });
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 1, i32, &[_]i32{ 444, 555 });
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 2, i32, &[_]i32{7});

    try t.deleteRows(0, 1);

    try testing.expectEqual(@as(i64, 16), try t.hdu.header.getValue(i64, "THEAP"));
    const r0 = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r0);
    const r1 = try readVlaCell(alloc, &t, .{ .index = 0 }, 1, i32);
    defer alloc.free(r1);
    try testing.expectEqualSlices(i32, &[_]i32{ 444, 555 }, r0);
    try testing.expectEqualSlices(i32, &[_]i32{7}, r1);
}

test "structural column edits rewrite an explicit default THEAP (insert/delete column)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // main = 8*1 = 8.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 1, 64, .{ .theap = 8 });
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 9, 8, 7 });

    // Grow: a 1J column widens NAXIS1 to 12.
    try t.insertColumn(alloc, 0, "1J", "PAD");
    try testing.expectEqual(@as(i64, 12), try t.hdu.header.getValue(i64, "THEAP"));
    const r0 = try readVlaCell(alloc, &t, .{ .name = "VLA" }, 0, i32);
    defer alloc.free(r0);
    try testing.expectEqualSlices(i32, &[_]i32{ 9, 8, 7 }, r0);

    // Shrink back: NAXIS1 returns to 8.
    try t.deleteColumn(0);
    try testing.expectEqual(@as(i64, 8), try t.hdu.header.getValue(i64, "THEAP"));
    const r1 = try readVlaCell(alloc, &t, .{ .name = "VLA" }, 0, i32);
    defer alloc.free(r1);
    try testing.expectEqualSlices(i32, &[_]i32{ 9, 8, 7 }, r1);
}

test "structural edits do not invent a THEAP card when none exists" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 2, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 1, 2 });

    try t.appendRows(1);

    try testing.expectError(error.KeywordNotFound, t.hdu.header.getValue(i64, "THEAP"));
    const r0 = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r0);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2 }, r0);
}

test "structural edits on a genuine THEAP gap are rejected without touching the table" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // Same geometry as the gap-read test: main = 8*2 = 16, THEAP=24 ⇒ gap=8, heap_size=64.
    // Every heap-relocating edit assumes the default heap position, so a real gap must be a
    // clean BadTbcol — and the rejected edit must leave the (readable) table fully intact.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 2, 72, .{ .theap = 24 });
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 42, 43 });

    try testing.expectError(error.BadTbcol, t.appendRows(1));
    try testing.expectError(error.BadTbcol, t.deleteRows(0, 1));
    try testing.expectError(error.BadTbcol, t.insertColumn(alloc, 0, "1J", "PAD"));
    try testing.expectError(error.BadTbcol, t.deleteColumn(0));

    try testing.expectEqual(@as(i64, 24), try t.hdu.header.getValue(i64, "THEAP"));
    try testing.expectEqual(@as(i64, 2), try t.hdu.header.getValue(i64, "NAXIS2"));
    const r = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r);
    try testing.expectEqualSlices(i32, &[_]i32{ 42, 43 }, r);
}

test "structural edits on an unparseable THEAP are rejected like reads are" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // heapGeometry treats a present-but-unparseable THEAP as BadTbcol; edits must agree
    // rather than silently relocating a heap whose declared position is unreadable.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 1, 64, .{ .theap_str = "oops" });
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);

    try testing.expectError(error.BadTbcol, t.appendRows(1));
    try testing.expectError(error.BadTbcol, t.deleteRows(0, 1));
    try testing.expectError(error.BadTbcol, t.insertColumn(alloc, 0, "1J", "PAD"));
    try testing.expectError(error.BadTbcol, t.deleteColumn(0));
}

test "zero-length VLA cell ignores its (undefined) descriptor offset (§7.3.5)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 1, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);

    // len == 0 with an out-of-heap offset: the offset is undefined per §7.3.5, so the read must
    // short-circuit to an empty slice instead of bounds-rejecting the garbage offset.
    try setDescriptor(&t, .{ .index = 0 }, 0, .{ .len = 0, .off = 1000 });
    const r = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r);
    try testing.expectEqual(@as(usize, 0), r.len);

    // len == 0 with a negative offset is likewise accepted.
    try setDescriptor(&t, .{ .index = 0 }, 0, .{ .len = 0, .off = -7 });
    const r2 = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r2);
    try testing.expectEqual(@as(usize, 0), r2.len);

    // A negative *length* is still rejected.
    try setDescriptor(&t, .{ .index = 0 }, 0, .{ .len = -1, .off = 0 });
    try testing.expectError(error.BadDescriptor, readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32));
}

test "compact de-aliases descriptors that share one heap extent" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 2, 128, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    // Row 0 holds a real 12-byte payload at offset 0; row 1's descriptor is forged to ALIAS the
    // very same extent (hostile input). Compaction must move the extent once and remap both rows
    // to the single packed offset — never issuing a `dst > src` move that would corrupt the heap.
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 7, 8, 9 });
    try setDescriptor(&t, .{ .index = 0 }, 1, .{ .len = 3, .off = 0 });

    try mgr.compact(alloc, &t);

    try testing.expectEqual(@as(u64, 12), mgr.top); // one extent survives, not two
    const d0 = try readDescriptor(&t, .{ .index = 0 }, 0);
    const d1 = try readDescriptor(&t, .{ .index = 0 }, 1);
    try testing.expectEqual(d0.off, d1.off);

    const r0 = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r0);
    const r1 = try readVlaCell(alloc, &t, .{ .index = 0 }, 1, i32);
    defer alloc.free(r1);
    try testing.expectEqualSlices(i32, &[_]i32{ 7, 8, 9 }, r0);
    try testing.expectEqualSlices(i32, &[_]i32{ 7, 8, 9 }, r1);
}

test "compact tolerates distinct overlapping extents without OOB (overlap-safe move)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 2, 128, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    // Row 0: a 4-element payload at offset 0 (16 bytes). Row 1 is forged to a DISTINCT but
    // overlapping extent at the same offset with a shorter length (8 bytes). Sorted packing then
    // forces an upward (dst > src) move for the longer extent; the overlap-safe `moveBytes` must
    // copy it without clobbering source bytes early.
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 11, 22, 33, 44 });
    try setDescriptor(&t, .{ .index = 0 }, 1, .{ .len = 2, .off = 0 });

    try mgr.compact(alloc, &t);

    // Both extents packed: 8 (row 1) + 16 (row 0) = 24 bytes, no overlap, no panic.
    try testing.expectEqual(@as(u64, 24), mgr.top);
    const r1 = try readVlaCell(alloc, &t, .{ .index = 0 }, 1, i32);
    defer alloc.free(r1);
    try testing.expectEqualSlices(i32, &[_]i32{ 11, 22 }, r1);
    const r0 = try readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32);
    defer alloc.free(r0);
    try testing.expectEqualSlices(i32, &[_]i32{ 11, 22, 33, 44 }, r0);
}

test "compact rejects forged overlapping extents whose packed size exceeds the heap (no OOB write)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // heap_size = 24 bytes. Row 0 = 5 i32 (20 bytes) at off 0. Row 1 forged to a DISTINCT extent
    // {off=4,len=5} (20 bytes, end=24 ≤ heap_size, passes the per-row bound). Packing puts row 0
    // at 0 (bump→20); row 1's distinct src=4 would then move to [20,40) — 16 bytes past the
    // 24-byte data unit. The cumulative-size guard must reject this with BadDescriptor.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 2, 24, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 1, 2, 3, 4, 5 });
    try setDescriptor(&t, .{ .index = 0 }, 1, .{ .len = 5, .off = 4 });

    try testing.expectError(error.BadDescriptor, mgr.compact(alloc, &t));
}

test "compact rejects partially-overlapping interleaved extents that would clobber a later source" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // heap_size = 32. Three DISTINCT byte extents that interleave: {off=0,len=4}, {off=2,len=4},
    // {off=4,len=4} — each end ≤ heap_size (passes the per-row bound) and packed size 12 fits.
    // Packing {0,4}→0 then {2,4}→4 would overwrite [4,8) — which is {4,4}'s source — BEFORE {4,4}
    // is relocated, so row 2 would silently read back the wrong (already-overwritten) bytes. No OOB
    // (all within the heap), so the earlier size guard doesn't catch it; the cross-extent-clobber
    // check must reject with BadDescriptor.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1PB", 3, 32, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, u8, &[_]u8{ 10, 11, 12, 13 });
    try setDescriptor(&t, .{ .index = 0 }, 1, .{ .len = 4, .off = 2 });
    try setDescriptor(&t, .{ .index = 0 }, 2, .{ .len = 4, .off = 4 });

    try testing.expectError(error.BadDescriptor, mgr.compact(alloc, &t));
}

test "max_vla_elems limit is enforced before allocation" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{ .max_vla_elems = 2 });
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 1, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);

    // A 3-element descriptor fits the heap but exceeds the element-count limit.
    try setDescriptor(&t, .{ .index = 0 }, 0, .{ .len = 3, .off = 0 });
    try testing.expectError(error.LimitExceeded, readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32));
}

test "HeapOverflow when the heap has no room" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    const hdu = try makeVlaHdu(&fx.f, alloc, "1PJ", 1, 8, .{}); // heap_size = 8 bytes
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    // 3 × i32 = 12 bytes > 8.
    try testing.expectError(error.HeapOverflow, writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 1, 2, 3 }));
}

test "readVlaCell on a non-VLA column errors" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // A plain fixed column: build a BINTABLE with a single 1J column.
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = 4 }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = 1 }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFORM1", .{ .string = "1J" }, null);
    try h.ensureEnd(alloc);
    const hdu = try fx.f.appendHdu(h);

    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    try testing.expectError(error.BadDescriptor, readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32));
}

test "HeapManager alloc/free/coalesce bookkeeping" {
    const alloc = testing.allocator;
    var mgr = HeapManager.init(100);
    defer mgr.deinit(alloc);

    const a = try mgr.alloc(10);
    const b = try mgr.alloc(20);
    const c = try mgr.alloc(30);
    try testing.expectEqual(@as(u64, 0), a);
    try testing.expectEqual(@as(u64, 10), b);
    try testing.expectEqual(@as(u64, 30), c);
    try testing.expectEqual(@as(u64, 60), mgr.top);

    // Free the middle extent → reusable from the free list.
    try mgr.free(alloc, b, 20);
    try testing.expectEqual(@as(usize, 1), mgr.free_list.items.len);
    const b2 = try mgr.alloc(20);
    try testing.expectEqual(@as(u64, 10), b2); // exact reuse
    try testing.expectEqual(@as(usize, 0), mgr.free_list.items.len);

    // Freeing the top extent lowers the bump pointer (no free-list entry).
    try mgr.free(alloc, c, 30);
    try testing.expectEqual(@as(u64, 30), mgr.top);
    try testing.expectEqual(@as(usize, 0), mgr.free_list.items.len);

    // Coalescing: free two adjacent regions, then allocate their combined size.
    const d = try mgr.alloc(10); // off 30
    const e = try mgr.alloc(10); // off 40
    try testing.expectEqual(@as(u64, 30), d);
    try testing.expectEqual(@as(u64, 40), e);
    try mgr.free(alloc, d, 10);
    try mgr.free(alloc, e, 10); // abuts top (50) → lowers top, absorbs d's extent too
    try testing.expectEqual(@as(u64, 30), mgr.top);
    try testing.expectEqual(@as(usize, 0), mgr.free_list.items.len);

    // Overflow guard.
    try testing.expectError(error.HeapOverflow, mgr.alloc(1000));
}

test "a typeless P descriptor column (1P, no element type) is BadTform" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, .{});
    defer fx.deinit(alloc);

    // `1P` parses as a `P` descriptor with no element type; following it into the heap cannot know
    // the payload type, so `VlaSpec.of` (via `readVlaCell`) must reject it with `error.BadTform`
    // rather than guess.
    const hdu = try makeVlaHdu(&fx.f, alloc, "1P", 1, 64, .{});
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    try testing.expectError(error.BadTform, readVlaCell(alloc, &t, .{ .index = 0 }, 0, i32));
}

test "read-only handle rejects all heap writes (NotWritable)" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();

    // Build a valid VLA table, flush it, then reopen read-only. Every write entry point
    // (`setDescriptor`, `writeVlaCell`, `freeVlaCell`) must refuse the read-only handle before
    // touching the device.
    {
        var f = try Fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary
        const h = try vlaHeader(alloc, "1PJ", 1, 64, .{});
        _ = try f.appendHdu(h);
        try f.flush();
    }

    var f = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f.deinit();
    const hdu = try f.select(2);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);
    var mgr = try HeapManager.initForTable(&t);
    defer mgr.deinit(alloc);

    try testing.expectError(error.NotWritable, setDescriptor(&t, .{ .index = 0 }, 0, .{ .len = 1, .off = 0 }));
    try testing.expectError(error.NotWritable, writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, i32, &[_]i32{ 1, 2, 3 }));
    try testing.expectError(error.NotWritable, freeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0));
}
