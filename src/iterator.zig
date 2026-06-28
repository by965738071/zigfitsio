//! High-level work-function iterator over image pixels or binary-table columns
//! (FR-ITR-1/2; design §19.2; NFR-PERF-1/3).
//!
//! The iterator drives a caller-supplied *work function* over an HDU's data in bounded,
//! reused chunks, handling buffering and datatype conversion so the callback sees plain typed
//! slices in the caller's own element types. Two entry points are provided:
//!
//!   - `Iterator(Cols, E)` — a binary-table column iterator. `Cols` is a caller-defined
//!     struct of typed column slices (e.g. `struct { flux: []f32, count: []i32 }`), so one
//!     pass can drive a *heterogeneous* column set (an `i32` column beside an `f64` column —
//!     the central column-iterator use case, FR-ITR-2). Each field carries a `Binding` giving
//!     its column reference and an input / output / input-output `Role`. The caller's error
//!     set `E` is threaded through `run` so neither the callback nor `run` ever leaks
//!     `anyerror` (FR-ERR-1, GC-4).
//!   - `forEachImage` — a simpler image-pixel walk over a single comptime element type `T`,
//!     using a caller-provided scratch buffer (zero allocation) and an optional in-place
//!     write-back role.
//!
//! Bounded memory (NFR-PERF-3): the table iterator allocates exactly one reusable buffer per
//! bound column — sized to the chunk, never to the row count — and the image walk allocates
//! nothing at all (the caller owns the scratch). There is **no per-element and no per-chunk
//! allocation**: the buffers are allocated once, before the chunk loop, and reused for every
//! chunk. All declared chunk sizes are validated against `Limits` before any allocation
//! (NFR-SAFE-1). Underlying transfers go through the block-aware `BinTable`/`ImageView` I/O,
//! which already batches device access in block-aligned windows (NFR-PERF-1).
//!
//! Null substitution (FR-IMG-8/FR-ITR-1): both walks expose it. The image walk takes a typed
//! `ImageOpts.null_sentinel`; the table walk takes a per-`Binding` `null_sentinel` — a
//! type-erased `NullSentinel` carried in the runtime `[]const Binding` and narrowed to each
//! column's element type when the per-call `ReadOpts`/`WriteOpts` is built. The same sentinel
//! is applied on both the read (stored null ⇒ sentinel) and write-back (sentinel ⇒ stored null)
//! sides of an `inout` column, so a null round-trips exactly.
//!
//! Generalization notes (design §19.2): ASCII-table iteration remains a documented follow-up.
const std = @import("std");
const errors = @import("errors.zig");
const limits = @import("limits.zig");
const block = @import("io/block.zig");
const binary = @import("table/binary.zig");
const common = @import("table/common.zig");
const image_mod = @import("image.zig");

const Allocator = std.mem.Allocator;
const BinTable = binary.BinTable;
const ColumnRef = binary.ColumnRef;
const Column = binary.Column;
const ImageView = image_mod.ImageView;

/// Default per-pass memory budget for auto chunk sizing (a small multiple of the 2880-byte
/// FITS block). The auto chunk holds as many rows as fit in this budget across all bound
/// columns; an explicit non-zero `group` overrides it (subject to the `Limits` ceiling).
const DEFAULT_CHUNK_BYTES: u64 = 16 * block.BLOCK;

/// Per-row element count of a binary-table column in caller-buffer slots: `repeat` for
/// scalar / `A` / `X` (one slot per byte / per bit), `2×repeat` for complex (real, imaginary).
/// Mirrors the (private) `cellSlots` of `table/binary.zig` so this module can size chunk
/// buffers without reaching into that file's internals.
fn cellSlots(col: *const Column) u64 {
    const r = col.tform.repeat;
    return switch (col.tform.type) {
        .complex32, .complex64 => 2 * r,
        else => r,
    };
}

/// A type-erased per-`Binding` null sentinel, the table-iterator analogue of
/// `ImageOpts.null_sentinel`. Because the bindings live in a runtime `[]const Binding`, the
/// sentinel cannot itself be element-typed; instead the caller picks the variant matching the
/// bound column's element kind, and it is narrowed to each column's element type when the
/// per-call `ReadOpts`/`WriteOpts` is built (`.none` ⇒ raw nulls, the previous behaviour).
pub const NullSentinel = union(enum) {
    /// No sentinel: stored nulls (`TNULLn` / NaN / a `0` logical byte) pass through raw.
    none,
    /// Sentinel for a signed-integer column element.
    signed: i64,
    /// Sentinel for an unsigned-integer column element.
    unsigned: u64,
    /// Sentinel for a floating-point column element.
    float: f64,
    /// Sentinel for a logical (`L`) column element.
    boolean: bool,
};

/// Narrow a runtime `NullSentinel` to a column element type `Elem`, yielding the `?Elem` a
/// `ReadOpts(Elem)`/`WriteOpts(Elem)` expects. Returns `null` when no sentinel is set or the
/// chosen variant cannot be represented in `Elem` (e.g. an out-of-range or mismatched value),
/// degrading gracefully to raw-null behaviour rather than trapping.
fn sentinelFor(comptime Elem: type, s: NullSentinel) ?Elem {
    return switch (s) {
        .none => null,
        .signed => |x| castSentinel(Elem, x),
        .unsigned => |x| castSentinel(Elem, x),
        .float => |x| castSentinel(Elem, x),
        .boolean => |x| if (Elem == bool) x else null,
    };
}

// Convert a numeric sentinel `value` to `Elem` without trapping: integer targets use a checked
// cast (out-of-range ⇒ null); float targets accept any numeric source.
fn castSentinel(comptime Elem: type, value: anytype) ?Elem {
    if (Elem == bool) return value != 0;
    return switch (@typeInfo(Elem)) {
        .int => switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int => std.math.cast(Elem, value),
            else => null, // a float sentinel for an integer column: unsupported
        },
        .float => switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int => @floatFromInt(value),
            .float => @floatCast(value),
            else => null,
        },
        else => null,
    };
}

/// Build a binary-table column iterator over a caller-defined `Cols` struct of typed column
/// slices, threading the caller's error set `E` (so no public function returns `anyerror`).
///
/// `Cols` must be a struct whose every field is a slice type (`[]T`); each field is matched to
/// a `Binding` by name. `E` is the work function's error set; `run` returns `Error || E`.
pub fn Iterator(comptime Cols: type, comptime E: type) type {
    const ti = @typeInfo(Cols);
    if (ti != .@"struct") @compileError("Iterator: Cols must be a struct of typed column slices");
    const fields = ti.@"struct".fields;
    if (fields.len == 0) @compileError("Iterator: Cols must have at least one field");

    return struct {
        const Self = @This();

        /// How a bound column participates in each work call: read into the buffer before
        /// (`in`), written back from the buffer after (`out`), or both (`inout`).
        pub const Role = enum { in, out, inout };

        /// One field-to-column binding: which column (`ref`), its `role`, and the name of the
        /// `Cols` field it fills (`field`). Provide one per field of `Cols`.
        pub const Binding = struct {
            /// The table column, by 0-based index or (wildcard-capable) name.
            ref: ColumnRef,
            /// Input / output / input-output participation.
            role: Role,
            /// The `Cols` field name this binding drives (matched by `std.mem.eql`).
            field: []const u8,
            /// Optional null substitution for this column, applied symmetrically on read
            /// (stored null ⇒ sentinel) and write-back (sentinel ⇒ stored null). The variant
            /// should match the column's element kind; `.none` ⇒ raw nulls (the default).
            null_sentinel: NullSentinel = .none,
        };

        /// The bindings, one per field of `Cols` (order-independent; matched by `field`).
        bindings: []const Binding,

        /// The error set produced by `run`: every library error plus the caller's `E`.
        pub const RunError = errors.Error || E;

        /// Drive `work(n, *Cols)` over the table in chunks. For each chunk of up to `group`
        /// rows (`group == 0` ⇒ a bounded, memory-budgeted default), the iterator reads every
        /// `in`/`inout` column into its reused buffer, re-slices the `Cols` view to the chunk's
        /// `n` rows, invokes `work`, then writes every `out`/`inout` column back. `n` is the
        /// row count for the call (the last chunk may be short). A `work` error of type `E`
        /// propagates with its concrete type; library failures surface as their narrow
        /// `Error` members. Buffers are allocated once and reused — no per-element or per-chunk
        /// allocation (NFR-PERF-1/3).
        pub fn run(self: *Self, table: *BinTable, group: usize, work: *const fn (n: usize, cols: *Cols) E!void) RunError!void {
            const alloc = table.fits.alloc;
            const total_rows = table.rowCount();

            // Resolve each field's column once: index, role, and per-row slot count.
            var col_idx: [fields.len]u16 = undefined;
            var roles: [fields.len]Role = undefined;
            var slots: [fields.len]u64 = undefined;
            var sentinels: [fields.len]NullSentinel = undefined;
            inline for (fields, 0..) |f, i| {
                const b = self.findBinding(f.name) orelse return error.NoSuchColumn;
                const idx = try table.resolve(b.ref);
                col_idx[i] = idx;
                roles[i] = b.role;
                slots[i] = cellSlots(&table.columns[idx]);
                sentinels[i] = b.null_sentinel;
            }

            if (total_rows == 0) return; // empty table: nothing to drive

            // Choose the chunk size in rows: caller's `group`, else a memory-budgeted default.
            var per_row_bytes: u64 = 0;
            inline for (fields, 0..) |f, i| {
                const Elem = std.meta.Elem(f.type);
                per_row_bytes = try limits.add(per_row_bytes, try limits.mul(slots[i], @sizeOf(Elem)));
            }
            const auto_rows: u64 = if (per_row_bytes == 0)
                total_rows
            else
                @max(@as(u64, 1), DEFAULT_CHUNK_BYTES / per_row_bytes);
            const requested: u64 = if (group == 0) auto_rows else @as(u64, group);
            var rows_per_chunk: u64 = @min(requested, total_rows);
            if (rows_per_chunk == 0) rows_per_chunk = 1;

            // Validate the total buffer footprint against the per-handle ceiling BEFORE
            // allocating anything (NFR-SAFE-1).
            var total_bytes: u64 = 0;
            inline for (fields, 0..) |f, i| {
                const Elem = std.meta.Elem(f.type);
                const cnt = try limits.mul(rows_per_chunk, slots[i]);
                total_bytes = try limits.add(total_bytes, try limits.mul(cnt, @sizeOf(Elem)));
            }
            try limits.ensureWithin(total_bytes, table.fits.limits.max_open_alloc, null);

            // Allocate one reusable full-chunk buffer per column. `nready` lets the single
            // `defer` free exactly the buffers that were successfully allocated, even on a
            // mid-loop allocation failure.
            var owned: Cols = undefined;
            var nready: usize = 0;
            defer {
                inline for (fields, 0..) |f, i| {
                    if (i < nready) alloc.free(@field(owned, f.name));
                }
            }
            inline for (fields, 0..) |f, i| {
                const Elem = std.meta.Elem(f.type);
                const cnt: usize = @intCast(rows_per_chunk * slots[i]);
                @field(owned, f.name) = try alloc.alloc(Elem, cnt);
                nready = i + 1;
            }

            // Drive the chunks. The `Cols` view is re-sliced to the chunk's `n` rows each pass;
            // the owned buffers are never reallocated.
            var first_row: u64 = 0;
            while (first_row < total_rows) {
                const n: usize = @intCast(@min(rows_per_chunk, total_rows - first_row));
                var view: Cols = undefined;
                inline for (fields, 0..) |f, i| {
                    const Elem = std.meta.Elem(f.type);
                    const want: usize = @intCast(@as(u64, n) * slots[i]);
                    const v = @field(owned, f.name)[0..want];
                    if (roles[i] == .in or roles[i] == .inout) {
                        try table.readColumn(Elem, .{ .index = col_idx[i] }, first_row, v, .{ .null_sentinel = sentinelFor(Elem, sentinels[i]) });
                    }
                    @field(view, f.name) = v;
                }

                try work(n, &view);

                inline for (fields, 0..) |f, i| {
                    const Elem = std.meta.Elem(f.type);
                    if (roles[i] == .out or roles[i] == .inout) {
                        try table.writeColumn(Elem, .{ .index = col_idx[i] }, first_row, @field(view, f.name), .{ .null_sentinel = sentinelFor(Elem, sentinels[i]) });
                    }
                }
                first_row += n;
            }
        }

        // Find the binding driving the `Cols` field named `name`, or null if unbound.
        fn findBinding(self: *const Self, name: []const u8) ?Binding {
            for (self.bindings) |b| {
                if (std.mem.eql(u8, b.field, name)) return b;
            }
            return null;
        }
    };
}

/// Per-call options for `forEachImage`, element-typed so the null sentinel cannot mismatch the
/// pixel type `T`.
pub fn ImageOpts(comptime T: type) type {
    return struct {
        /// When set, the (possibly modified) chunk is written back to the image after each
        /// `work` call — the image equivalent of an `inout` column role.
        write_back: bool = false,
        /// `BLANK`/NaN stored pixels are delivered as this sentinel, and (when `write_back`)
        /// equal pixels are re-encoded as the null on write (FR-IMG-8). `null` ⇒ raw nulls.
        null_sentinel: ?T = null,
    };
}

/// Drive `work(ctx, first_elem, pixels)` over an image's pixels in contiguous chunks, using
/// the caller-provided `scratch` buffer as the (bounded, reused) chunk — so the walk allocates
/// nothing (NFR-PERF-3). Pixels are converted to `T` and null-substituted per `opts`
/// (FR-ITR-1); when `opts.write_back` is set the chunk is written back after each call (an
/// in-place `inout` role). `first_elem` is the column-major linear index of the chunk's first
/// pixel. The caller's error set `E` is threaded through, so no `anyerror` escapes
/// (FR-ERR-1). The chunk size is `scratch.len` pixels; it must be non-empty for a non-empty
/// image.
pub fn forEachImage(
    comptime T: type,
    comptime Ctx: type,
    comptime E: type,
    view: *ImageView,
    scratch: []T,
    ctx: Ctx,
    work: *const fn (ctx: Ctx, first_elem: u64, pixels: []T) E!void,
    opts: ImageOpts(T),
) (image_mod.ImageError || E)!void {
    const total = view.elementCount();
    if (total == 0) return; // scalar / NAXIS=0 image: nothing to walk
    if (scratch.len == 0) return error.BadDimensions; // a non-empty image needs a chunk buffer

    const axes = view.dims();
    const naxis = axes.len;
    var coord: [999]u64 = undefined;

    var done: u64 = 0;
    while (done < total) {
        const n: usize = @intCast(@min(@as(u64, scratch.len), total - done));
        unravel(done, axes, coord[0..naxis]);
        const chunk = scratch[0..n];
        try view.readPixels(T, coord[0..naxis], chunk, .{ .null_sentinel = opts.null_sentinel });
        try work(ctx, done, chunk);
        if (opts.write_back) {
            try view.writePixels(T, coord[0..naxis], chunk, .{ .null_sentinel = opts.null_sentinel });
        }
        done += n;
    }
}

// Convert a column-major linear index into its N-D coordinate (axis 0 fastest). All axes are
// positive here (a zero axis makes `elementCount` zero, handled by the caller's early return).
fn unravel(linear: u64, axes: []const u64, out: []u64) void {
    var rem = linear;
    for (axes, 0..) |ax, i| {
        out[i] = rem % ax;
        rem /= ax;
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("io/memory.zig").MemoryDevice;
const Fits = @import("fits.zig").Fits;
const Hdu = @import("hdu.zig").Hdu;
const Header = @import("header/header.zig").Header;

const ColSpec = struct { tform: []const u8, ttype: []const u8, tnull: ?i64 = null };

fn kwName(buf: []u8, comptime prefix: []const u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "{d}", .{n}) catch unreachable;
}

// Build and append a minimal BINTABLE HDU with the given columns and row count.
fn appendTable(f: *Fits, alloc: Allocator, specs: []const ColSpec, nrows: u64) !*Hdu {
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    var rowbytes: u64 = 0;
    for (specs) |s| rowbytes += try (try common.BinTform.parse(s.tform)).fieldBytes();

    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = @intCast(rowbytes) }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = @intCast(nrows) }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = @intCast(specs.len) }, null);
    var buf: [16]u8 = undefined;
    for (specs, 0..) |s, i| {
        const n = i + 1;
        try h.appendValue(alloc, kwName(&buf, "TFORM", n), .{ .string = s.tform }, null);
        try h.appendValue(alloc, kwName(&buf, "TTYPE", n), .{ .string = s.ttype }, null);
        if (s.tnull) |tn| try h.appendValue(alloc, kwName(&buf, "TNULL", n), .{ .int = tn }, null);
    }
    try h.ensureEnd(alloc);
    return f.appendHdu(h);
}

test "heterogeneous Cols driven in one pass (inout + out), chunked" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary

    const specs = [_]ColSpec{
        .{ .tform = "1E", .ttype = "FLUX" },
        .{ .tform = "1J", .ttype = "COUNT" },
    };
    const hdu = try appendTable(&f, alloc, &specs, 5);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    try t.writeColumn(f32, .{ .name = "FLUX" }, 0, &[_]f32{ 1, 2, 3, 4, 5 }, .{});

    const Cols = struct { flux: []f32, count: []i32 };
    const W = struct {
        fn work(n: usize, cols: *Cols) error{}!void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                cols.count[i] = @intFromFloat(cols.flux[i]); // out: derived from input
                cols.flux[i] = cols.flux[i] * 2; // inout: modified in place
            }
        }
    };

    var iter = Iterator(Cols, error{}){ .bindings = &.{
        .{ .ref = .{ .name = "FLUX" }, .role = .inout, .field = "flux" },
        .{ .ref = .{ .name = "COUNT" }, .role = .out, .field = "count" },
    } };
    try iter.run(&t, 2, W.work); // group=2 → chunks of 2,2,1 in one pass

    var flux_out: [5]f32 = undefined;
    var count_out: [5]i32 = undefined;
    try t.readColumn(f32, .{ .name = "FLUX" }, 0, &flux_out, .{});
    try t.readColumn(i32, .{ .name = "COUNT" }, 0, &count_out, .{});
    try testing.expectEqualSlices(f32, &[_]f32{ 2, 4, 6, 8, 10 }, &flux_out);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4, 5 }, &count_out);
}

test "auto chunk size (group=0) covers all rows in one pass" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "V" }};
    const hdu = try appendTable(&f, alloc, &specs, 17);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    const Cols = struct { v: []i32 };
    const W = struct {
        fn work(n: usize, cols: *Cols) error{}!void {
            var i: usize = 0;
            while (i < n) : (i += 1) cols.v[i] = @intCast(i + 1);
        }
    };
    var iter = Iterator(Cols, error{}){ .bindings = &.{
        .{ .ref = .{ .index = 0 }, .role = .out, .field = "v" },
    } };
    try iter.run(&t, 0, W.work); // auto chunk

    var out: [17]i32 = undefined;
    try t.readColumn(i32, .{ .index = 0 }, 0, &out, .{});
    // A single auto chunk holds all 17 rows, so `i` runs 0..16 across the whole table.
    var expect: [17]i32 = undefined;
    for (&expect, 0..) |*e, i| e.* = @intCast(i + 1);
    try testing.expectEqualSlices(i32, &expect, &out);
}

test "pure-input role reads existing column values" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "ID" }};
    const hdu = try appendTable(&f, alloc, &specs, 4);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);
    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 10, 20, 30, 40 }, .{});

    const Cols = struct { id: []i32 };
    const Acc = struct {
        var sum: i64 = 0;
        fn work(n: usize, cols: *Cols) error{}!void {
            var i: usize = 0;
            while (i < n) : (i += 1) sum += cols.id[i];
        }
    };
    Acc.sum = 0;
    var iter = Iterator(Cols, error{}){ .bindings = &.{
        .{ .ref = .{ .name = "ID" }, .role = .in, .field = "id" },
    } };
    try iter.run(&t, 3, Acc.work); // chunks of 3 then 1
    try testing.expectEqual(@as(i64, 100), Acc.sum);
}

test "caller error propagates with its concrete type" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "V" }};
    const hdu = try appendTable(&f, alloc, &specs, 3);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    const Cols = struct { v: []i32 };
    const E = error{Boom};
    const W = struct {
        fn work(n: usize, cols: *Cols) E!void {
            _ = n;
            _ = cols;
            return error.Boom;
        }
    };
    var iter = Iterator(Cols, E){ .bindings = &.{
        .{ .ref = .{ .name = "V" }, .role = .in, .field = "v" },
    } };
    // The concrete `error.Boom` (not a widened anyerror) flows out of `run`.
    try testing.expectError(error.Boom, iter.run(&t, 0, W.work));
}

// An allocator that counts `alloc` calls, to prove the chunked run does no per-element or
// per-chunk allocation (exactly one buffer per bound column, regardless of row/chunk count).
const CountingAllocator = struct {
    child: Allocator,
    n_alloc: usize = 0,
    const Self = @This();
    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.n_alloc += 1;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }
    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
    const vtable: Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };
    fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "chunked run does no per-element allocation" {
    var counting = CountingAllocator{ .child = testing.allocator };
    const alloc = counting.allocator();
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{
        .{ .tform = "1E", .ttype = "FLUX" },
        .{ .tform = "1J", .ttype = "COUNT" },
    };
    const hdu = try appendTable(&f, alloc, &specs, 64);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    const Cols = struct { flux: []f32, count: []i32 };
    const W = struct {
        fn work(n: usize, cols: *Cols) error{}!void {
            var i: usize = 0;
            while (i < n) : (i += 1) cols.count[i] = @intFromFloat(cols.flux[i]);
        }
    };
    var iter = Iterator(Cols, error{}){ .bindings = &.{
        .{ .ref = .{ .name = "FLUX" }, .role = .in, .field = "flux" },
        .{ .ref = .{ .name = "COUNT" }, .role = .out, .field = "count" },
    } };

    const before = counting.n_alloc;
    try iter.run(&t, 4, W.work); // 64 rows / 4 = 16 chunks
    const delta = counting.n_alloc - before;
    // Exactly two buffers (one per bound column) for 16 chunks ⇒ no per-chunk allocation.
    try testing.expectEqual(@as(usize, 2), delta);
}

test "unbound Cols field is a typed error" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "V" }};
    const hdu = try appendTable(&f, alloc, &specs, 2);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    const Cols = struct { a: []i32, b: []i32 };
    const W = struct {
        fn work(n: usize, cols: *Cols) error{}!void {
            _ = n;
            _ = cols;
        }
    };
    // Only `a` is bound; `b` has no binding ⇒ NoSuchColumn.
    var iter = Iterator(Cols, error{}){ .bindings = &.{
        .{ .ref = .{ .index = 0 }, .role = .in, .field = "a" },
    } };
    try testing.expectError(error.NoSuchColumn, iter.run(&t, 0, W.work));
}

test "forEachImage sums pixels across multiple chunks" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 32, .axes = &.{ 5, 4 } }); // 20 pixels
    var pixels: [20]i32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i);
    try img.writeAll(i32, &pixels, .{});

    const Acc = struct {
        var sum: i64 = 0;
        var calls: usize = 0;
        fn work(_: void, first: u64, px: []i32) error{}!void {
            _ = first;
            calls += 1;
            for (px) |p| sum += p;
        }
    };
    Acc.sum = 0;
    Acc.calls = 0;

    var scratch: [7]i32 = undefined; // 20 pixels / 7 ⇒ 3 chunks (7,7,6)
    try forEachImage(i32, void, error{}, &img, &scratch, {}, Acc.work, .{});
    try testing.expectEqual(@as(i64, 190), Acc.sum); // 0+1+...+19
    try testing.expectEqual(@as(usize, 3), Acc.calls);
}

test "forEachImage writes modified pixels back when write_back is set" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 32, .axes = &.{ 4, 3 } }); // 12 pixels
    var pixels: [12]i32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i + 1);
    try img.writeAll(i32, &pixels, .{});

    const W = struct {
        fn work(_: void, first: u64, px: []i32) error{}!void {
            _ = first;
            for (px) |*p| p.* *= 10;
        }
    };
    var scratch: [5]i32 = undefined; // forces 3 chunks (5,5,2)
    try forEachImage(i32, void, error{}, &img, &scratch, {}, W.work, .{ .write_back = true });

    var out: [12]i32 = undefined;
    try img.readAll(i32, &out, .{});
    var expect: [12]i32 = undefined;
    for (&expect, 0..) |*e, i| e.* = @intCast((i + 1) * 10);
    try testing.expectEqualSlices(i32, &expect, &out);
}

test "forEachImage threads the caller's error type" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 16, .axes = &.{6} });
    var pixels: [6]i16 = .{ 1, 2, 3, 4, 5, 6 };
    try img.writeAll(i16, &pixels, .{});

    const E = error{Stop};
    const W = struct {
        fn work(_: void, _: u64, _: []i16) E!void {
            return error.Stop;
        }
    };
    var scratch: [3]i16 = undefined;
    try testing.expectError(error.Stop, forEachImage(i16, void, E, &img, &scratch, {}, W.work, .{}));
}

test "FR-ITR-1: per-binding null sentinel round-trips a table column's nulls" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "VAL", .tnull = -1 }};
    const hdu = try appendTable(&f, alloc, &specs, 4);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    // Store raw values: rows 1 and 3 hold the stored null (TNULL = -1).
    try t.writeColumn(i32, .{ .index = 0 }, 0, &[_]i32{ 7, -1, 9, -1 }, .{});

    const Cols = struct { v: []i32 };
    const Seen = struct {
        var nulls: usize = 0;
        var raw_nulls: usize = 0;
        fn work(n: usize, cols: *Cols) error{}!void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                // The stored TNULL is delivered as the sentinel 999, never the raw -1.
                if (cols.v[i] == 999) nulls += 1;
                if (cols.v[i] == -1) raw_nulls += 1;
            }
        }
    };
    Seen.nulls = 0;
    Seen.raw_nulls = 0;

    // `inout` with a sentinel: nulls read as 999, and writing 999 back re-encodes the TNULL.
    var iter = Iterator(Cols, error{}){ .bindings = &.{
        .{ .ref = .{ .index = 0 }, .role = .inout, .field = "v", .null_sentinel = .{ .signed = 999 } },
    } };
    try iter.run(&t, 0, Seen.work);
    try testing.expectEqual(@as(usize, 2), Seen.nulls);
    try testing.expectEqual(@as(usize, 0), Seen.raw_nulls); // no raw TNULL ever surfaced

    // Round-trip: the stored layout is unchanged because the same sentinel governs write-back.
    var raw: [4]i32 = undefined;
    try t.readColumn(i32, .{ .index = 0 }, 0, &raw, .{}); // raw read: TNULL visible again
    try testing.expectEqualSlices(i32, &[_]i32{ 7, -1, 9, -1 }, &raw);
}

test "FR-ITR-1: chunk footprint over max_open_alloc trips the limit guard" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    const specs = [_]ColSpec{.{ .tform = "1J", .ttype = "V" }};
    const hdu = try appendTable(&f, alloc, &specs, 3);
    var t = try BinTable.of(&f, hdu);
    defer t.deinit(alloc);

    // A 1-byte ceiling cannot fit even a single i32 chunk slot ⇒ the pre-allocation guard fires.
    f.limits.max_open_alloc = 1;

    const Cols = struct { v: []i32 };
    const W = struct {
        fn work(n: usize, cols: *Cols) error{}!void {
            _ = n;
            _ = cols;
            unreachable; // never reached: the limit guard rejects the run before any chunk
        }
    };
    var iter = Iterator(Cols, error{}){ .bindings = &.{
        .{ .ref = .{ .index = 0 }, .role = .out, .field = "v" },
    } };
    try testing.expectError(error.LimitExceeded, iter.run(&t, 0, W.work));
}

test "FR-ITR-1: empty scratch over a non-empty image is BadDimensions" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 32, .axes = &.{4} });
    var pixels: [4]i32 = .{ 1, 2, 3, 4 };
    try img.writeAll(i32, &pixels, .{});

    const W = struct {
        fn work(_: void, _: u64, _: []i32) error{}!void {
            unreachable; // never called: a zero-length chunk cannot make progress
        }
    };
    var scratch: [0]i32 = undefined; // empty chunk buffer over 4 real pixels
    try testing.expectError(error.BadDimensions, forEachImage(i32, void, error{}, &img, &scratch, {}, W.work, .{}));
}

test "forEachImage on a scalar (NAXIS=0) image is a no-op" {
    const alloc = testing.allocator;
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    var img = try ImageView.append(&f, .{ .bitpix = 8, .axes = &.{} });

    const W = struct {
        fn work(_: void, _: u64, _: []u8) error{}!void {
            unreachable; // never called: no pixels
        }
    };
    var scratch: [0]u8 = undefined;
    try forEachImage(u8, void, error{}, &img, &scratch, {}, W.work, .{});
}
