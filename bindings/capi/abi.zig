//! Shared support for the `zigfitsio` C-ABI shim (`capi.zig`).
//!
//! This module holds everything the exported `zf_*` functions need but that is not itself an
//! `export fn`: the opaque handle type, the process-global allocator, the thread-local
//! last-error record, the small C-layout option/scaling structs, and the enum/limit
//! translation helpers. Keeping the `export fn` surface in `capi.zig` and the plumbing here
//! keeps the ABI boundary readable.
//!
//! The library itself is consumed purely as the `zigfitsio` Zig module; nothing here reaches
//! into private state beyond the documented handle fields (`Fits` exposes no field visibility
//! modifiers, so the lazily-scanned HDU list is reachable for the current-HDU guard).
const std = @import("std");
const builtin = @import("builtin");
const fits = @import("zigfitsio");

/// True for the `wasm32-freestanding` build (the single-package WebAssembly binding). There is
/// no OS there, so the thread-backed `smp_allocator` is unavailable; `wasm_allocator`
/// (`@wasmMemoryGrow`-backed) is the freestanding heap.
const freestanding_wasm = builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .freestanding;

/// Process-global, thread-safe allocator for everything the shim allocates (handles, decode
/// scratch, returned strings). `smp_allocator` needs no libc, so the shared library stays
/// self-contained. Each `Fits` handle is single-threaded by contract, but distinct handles on
/// distinct threads share only this allocator, which is itself thread-safe. On
/// wasm32-freestanding (single-threaded, no OS) the WebAssembly heap allocator is used instead.
pub const gpa: std.mem.Allocator = if (freestanding_wasm) std.heap.wasm_allocator else std.heap.smp_allocator;

// ── Opaque handles ─────────────────────────────────────────────────────────────────────────

/// The object behind a `ZfFits*`. Owns the `Fits` value, a `Diagnostics` sink wired into every
/// operation (so failures carry where/what), and — for the in-memory backends — the pinned
/// `MemoryDevice` the handle must free on close.
pub const Handle = struct {
    fits: fits.Fits,
    diag: fits.Diagnostics = .{},
    /// Heap-pinned in-memory device backing `open_memory`/`create_memory`; freed on close.
    mem_dev: ?*fits.MemoryDevice = null,
    /// Open `TableHandle` views over this file. `zf_close` invalidates each (releases its resources
    /// and marks it `dead`) before freeing the `Fits`, so a later `zf_table_*` on a still-held
    /// `ZfTable*` cannot use-after-free the freed `Fits`/`Hdu` it borrows. `zf_table_open` registers
    /// a view here; `zf_table_close` removes it.
    tables: std.ArrayList(*TableHandle) = .empty,

    /// The current HDU, or `error.WrongHduType` when the file has no HDU yet (a freshly
    /// `create`d handle before the first `zf_create_img`/table builder). Mirrors the contract
    /// that `Fits.current()` is only valid once at least one HDU exists.
    pub fn cur(self: *Handle) fits.Error!*fits.Hdu {
        if (self.fits.hdus.items.len == 0) return error.WrongHduType;
        return self.fits.current();
    }
};

/// The object behind a `ZfTable*`: a parsed table view over a specific HDU plus the owning
/// handle (for the allocator and device). Either the binary or the ASCII variant is active.
/// A binary table lazily builds a `HeapManager` the first time a VLA cell is written.
pub const TableHandle = struct {
    owner: *Handle,
    kind: enum { binary, ascii },
    bin: ?fits.BinTable = null,
    asc: ?fits.AsciiTable = null,
    mgr: ?fits.heap.HeapManager = null,
    /// Set when the owning `Handle` was closed while this view was still open: the borrowed
    /// `Fits`/`Hdu` are freed, so every `zf_table_*` op must reject before dereferencing them.
    dead: bool = false,

    pub fn deinit(self: *TableHandle) void {
        // Idempotent: `zf_close` deinits open views (while the `Fits` is still alive) and nulls the
        // fields, so the caller's later `zf_table_close` frees the handle without a double-free.
        if (self.mgr) |*m| {
            m.deinit(gpa);
            self.mgr = null;
        }
        if (self.bin) |*b| {
            b.deinit(gpa);
            self.bin = null;
        }
        if (self.asc) |*a| {
            a.deinit(gpa);
            self.asc = null;
        }
    }
};

/// The object behind a `ZfFindings*`: the owned result list of a `zf_validate` pass.
pub const FindingsHandle = struct {
    list: fits.validate.Findings,
};

/// Per-column metadata returned by `zf_table_col_info` (names/units come via separate buffer
/// getters to keep this POD). `typecode` is the natural element `ZfType`; `repeat` is the
/// element count per cell (bytes for character `A`, bits for `X`), `width` the field byte width
/// (binary tables) or text width (ASCII).
pub const ZfColInfo = extern struct {
    typecode: c_int = 0,
    repeat: i64 = 0,
    width: i64 = 0,
    is_vla: c_int = 0,
    tform_char: c_int = 0,
    tscal: f64 = 1,
    tzero: f64 = 0,
    tnull: i64 = 0,
    has_tnull: c_int = 0,
};

// ── Thread-local last error ──────────────────────────────────────────────────────────────────

/// The most recent failure on the calling thread. CFITSIO keeps a global error stack; this is
/// the single-slot, thread-local equivalent, populated by `fail` and read by `zf_errmsg` etc.
pub const ErrState = struct {
    status: c_int = 0,
    msg: [256]u8 = [_]u8{0} ** 256,
    msg_len: usize = 0,
    keyword: [9]u8 = [_]u8{0} ** 9,
    keyword_len: usize = 0,
    byte_offset: i64 = -1,
    hdu_index: i64 = -1,
};

pub threadlocal var last_err: ErrState = .{};

/// Reset the thread-local error before a call that is expected to succeed (optional; `fail`
/// fully overwrites it on the error path).
pub fn clearErr() void {
    last_err = .{};
}

/// Record `err` (plus any `Diagnostics` detail) into the thread-local slot and return its
/// CFITSIO-compatible status code. The idiom at every call site is
/// `something() catch |e| return fail(&h.diag, e);`. A narrow error set coerces to the
/// umbrella `fits.Error` parameter.
pub fn fail(diag: ?*const fits.Diagnostics, err: fits.Error) c_int {
    var st: ErrState = .{};
    st.status = fits.cfitsioStatus(err);
    const text = fits.errorText(err);
    const n = @min(text.len, st.msg.len - 1);
    @memcpy(st.msg[0..n], text[0..n]);
    st.msg_len = n;
    if (diag) |d| if (d.last) |rec| {
        if (rec.byte_offset) |off| st.byte_offset = @intCast(@min(off, std.math.maxInt(i64)));
        if (rec.hdu_index) |hx| st.hdu_index = @intCast(hx);
        if (rec.keyword) |k| {
            const trimmed = std.mem.trimEnd(u8, &k, " ");
            const m = @min(trimmed.len, st.keyword.len - 1);
            @memcpy(st.keyword[0..m], trimmed[0..m]);
            st.keyword_len = m;
        }
    };
    last_err = st;
    return st.status;
}

/// Record a null-input-pointer failure (a C caller passed a null handle/table/findings pointer)
/// into the thread-local slot and return CFITSIO's `NULL_INPUT_PTR` (104). The exported `zf_*`
/// functions guard their handle parameters with `orelse return abi.failNull()`.
pub fn failNull() c_int {
    var st: ErrState = .{};
    st.status = 104;
    const text = "null input pointer";
    @memcpy(st.msg[0..text.len], text);
    st.msg_len = text.len;
    last_err = st;
    return 104;
}

// ── C-layout option / scaling structs ───────────────────────────────────────────────────────

/// Open/create options (mirrors `fits.OpenOpts` + `Limits`). A `0` limit field means "use the
/// library default"; a null `ZfOpenOpts*` means all defaults with checksums off.
pub const ZfOpenOpts = extern struct {
    checksum_on_close: c_int = 0,
    max_header_blocks: u32 = 0,
    max_hdu_count: u32 = 0,
    max_naxis_product: u64 = 0,
    max_heap_bytes: u64 = 0,
    max_vla_elems: u64 = 0,
    max_string_value: u32 = 0,
    max_tile_bytes: u64 = 0,
    max_open_alloc: u64 = 0,
    max_matches: u32 = 0,
};

/// Per-call scaling override (mirrors `image.Scaling`). `has_blank == 0` ⇒ no integer null
/// sentinel; `raw != 0` ⇒ expose stored values unscaled.
pub const ZfScaling = extern struct {
    bscale: f64 = 1,
    bzero: f64 = 0,
    blank: i64 = 0,
    has_blank: c_int = 0,
    raw: c_int = 0,
};

pub fn toScaling(s: ZfScaling) fits.Scaling {
    return .{
        .bscale = s.bscale,
        .bzero = s.bzero,
        .blank = if (s.has_blank != 0) s.blank else null,
        .mode = if (s.raw != 0) .raw else .apply,
    };
}

// ── Enum / limit translation ─────────────────────────────────────────────────────────────────

/// Element datatype codes shared by image and table transfers. The shim `switch`es one of
/// these to the matching monomorphization of the comptime-generic library call.
pub const ZfType = enum(c_int) {
    uint8 = 1,
    int8 = 2,
    int16 = 3,
    uint16 = 4,
    int32 = 5,
    uint32 = 6,
    int64 = 7,
    uint64 = 8,
    float32 = 9,
    float64 = 10,
    boolean = 11,
    bit = 12,
    string = 13,
    complex64 = 14,
    complex128 = 15,
    _,
};

/// FITS open mode codes: 0 read-only, 1 read-write, 2 create.
pub fn modeFrom(m: c_int) fits.Mode {
    return switch (m) {
        1 => .read_write,
        2 => .create,
        else => .read_only,
    };
}

/// HDU kind → stable C code (kept in sync with `bindings/c/zigfitsio.h`).
pub fn kindCode(k: fits.HduKind) c_int {
    return switch (k) {
        .primary => 0,
        .image => 1,
        .ascii_table => 2,
        .binary_table => 3,
        .random_groups => 4,
    };
}

/// Build `fits.OpenOpts` from the C options, wiring `diag` and honoring non-zero limit
/// overrides. A null `o` yields library defaults.
pub fn optsFrom(o: ?*const ZfOpenOpts, diag: *fits.Diagnostics) fits.OpenOpts {
    var lim: fits.Limits = .{};
    var checksum = false;
    if (o) |opt| {
        checksum = opt.checksum_on_close != 0;
        if (opt.max_header_blocks != 0) lim.max_header_blocks = opt.max_header_blocks;
        if (opt.max_hdu_count != 0) lim.max_hdu_count = opt.max_hdu_count;
        if (opt.max_naxis_product != 0) lim.max_naxis_product = opt.max_naxis_product;
        if (opt.max_heap_bytes != 0) lim.max_heap_bytes = opt.max_heap_bytes;
        if (opt.max_vla_elems != 0) lim.max_vla_elems = opt.max_vla_elems;
        if (opt.max_string_value != 0) lim.max_string_value = opt.max_string_value;
        if (opt.max_tile_bytes != 0) lim.max_tile_bytes = opt.max_tile_bytes;
        if (opt.max_open_alloc != 0) lim.max_open_alloc = opt.max_open_alloc;
        if (opt.max_matches != 0) lim.max_matches = opt.max_matches;
    }
    return .{ .diag = diag, .limits = lim, .checksum_on_close = checksum };
}

/// Copy `src` into the caller's fixed buffer (`dst[0..dst_len]`), reporting the full required
/// length in `out_len` so the caller can re-query with a larger buffer. Used by every
/// fixed-buffer string getter.
pub fn copyOut(src: []const u8, dst: [*]u8, dst_len: usize, out_len: *usize) void {
    out_len.* = src.len;
    const n = @min(src.len, dst_len);
    if (n != 0) @memcpy(dst[0..n], src[0..n]);
}
