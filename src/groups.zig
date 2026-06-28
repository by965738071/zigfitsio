//! Random-groups data access: per-group parameters and the per-group data array
//! (FR-RG-1/2, design §15; FITS 4.0 §6).
//!
//! The random-groups structure is a deprecated primary-HDU form that predates binary tables
//! (it survives mainly in radio-interferometry `uv` data). Its header carries the §6-ordered
//! mandatory keywords — `SIMPLE=T`, `BITPIX`, `NAXIS`, `NAXIS1=0`, `NAXIS2…NAXISn`,
//! `GROUPS=T`, `PCOUNT`, `GCOUNT`, with no keyword intervening between `SIMPLE` and the last
//! `NAXISn` (FR-RG-1) — plus the reserved per-parameter keywords `PTYPEn`/`PSCALn`/`PZEROn`.
//!
//! The data unit is `GCOUNT` groups laid out back to back; each group is `PCOUNT` parameters
//! followed by a data array of `Π NAXIS2…NAXISn` elements, every element `|BITPIX|/8` bytes
//! and stored big-endian on disk (read through `endian`, GC-5). Parameters are returned with
//! `PSCALn`/`PZEROn` scaling applied and the data array with `BSCALE`/`BZERO` — the same linear
//! `physical = zero + scale × stored` math as `image.zig`, with the unsigned-integer
//! convention kept in integer space to avoid `f64` precision loss (FR-RG-2). Transfers stream
//! through a fixed scratch buffer in bounded chunks. Writing is supported (a `MAY` in FR-RG-2,
//! since the format is deprecated for new files), routed through the same scaling machinery so
//! a write→read round-trip is exact.
const std = @import("std");
const errors = @import("errors.zig");
const convert = @import("convert.zig");
const endian = @import("endian.zig");
const limits = @import("limits.zig");
const Fits = @import("fits.zig").Fits;
const Hdu = @import("hdu.zig").Hdu;

const Allocator = std.mem.Allocator;

const CHUNK_ELEMS: usize = 4096; // elements per streamed chunk

/// Error set for building a `RandomGroups` view from an HDU (validation, geometry, and the
/// per-parameter metadata allocation).
pub const OpenError = errors.StructError || errors.IoError || errors.LimitError || Allocator.Error;

/// Error set for the parameter/data read and write operations.
pub const AccessError = errors.StructError || errors.IoError || errors.ConvError || errors.LimitError;

/// A typed view over a random-groups HDU's data unit (FR-RG-1/2).
pub const RandomGroups = struct {
    /// The owning file handle (provides the device and allocator).
    fits: *Fits,
    /// The underlying random-groups HDU.
    hdu: *Hdu,
    /// `GCOUNT`: number of groups.
    gcount: u64,
    /// `PCOUNT`: number of parameters preceding each group's data array.
    pcount: u64,
    /// Per-axis lengths of the group data array, `NAXIS2…NAXISn` (owned; empty when `NAXIS==1`).
    group_axes: []u64,
    /// Owned `PTYPEn` parameter names (length == `pcount`; an absent or non-string name is the
    /// empty slice). Index `i` holds `PTYPE{i+1}`.
    ptype: [][]u8,
    /// `PSCALn` per-parameter scales (length == `pcount`; default 1). Index `i` holds `PSCAL{i+1}`.
    pscal: []f64,
    /// `PZEROn` per-parameter zero offsets (length == `pcount`; default 0). Index `i` is `PZERO{i+1}`.
    pzero: []f64,
    /// `BSCALE` applied to the data array (default 1).
    bscale: f64,
    /// `BZERO` applied to the data array (default 0).
    bzero: f64,
    /// `|BITPIX|/8`: bytes per stored element (parameters and data share the element width).
    elem_bytes: u64,
    /// Number of elements in one group's data array (product of `group_axes`; 1 when empty).
    data_elems: u64,
    /// Byte stride from one group to the next: `elem_bytes × (pcount + data_elems)`.
    stride_bytes: u64,

    /// Build a view over a random-groups HDU: validate the kind, that `NAXIS1==0`, and that
    /// `GROUPS==T`, compute the group geometry, confirm the declared data unit fits the device,
    /// then read each parameter's `PTYPEn`/`PSCALn`/`PZEROn`. `error.WrongHduType` for a
    /// non-random-groups HDU (or a missing `GROUPS=T`); `error.BadDimensions` when `NAXIS1!=0`;
    /// `error.LimitExceeded` when the declared data exceeds the device length.
    pub fn of(fits: *Fits, hdu: *Hdu) OpenError!RandomGroups {
        if (hdu.kind != .random_groups) return error.WrongHduType;
        if (hdu.naxis < 1) return error.BadDimensions;
        if (hdu.axes[0] != 0) return error.BadDimensions; // NAXIS1 must be 0
        const groups_flag = hdu.header.getValue(bool, "GROUPS") catch false;
        if (!groups_flag) return error.WrongHduType;

        const alloc = fits.alloc;
        const pcount = hdu.pcount;
        const gcount = hdu.gcount;
        const elem_bytes = hdu.elemBytes();

        // Geometry (checked arithmetic) — validate sizes BEFORE allocating anything.
        const data_elems = try limits.naxisProduct(hdu.axes[1..], fits.limits.max_naxis_product);
        const stride_elems = try limits.add(pcount, data_elems);
        const stride_bytes = try limits.mul(elem_bytes, stride_elems);

        // The declared data unit must fit the device (bounds the per-parameter metadata, whose
        // size tracks PCOUNT, to a real file length rather than an untrusted header count).
        const dev_size = try fits.dev.getSize();
        const data_end = try limits.add(hdu.data_off, hdu.data_bytes);
        if (data_end > dev_size) return error.LimitExceeded;

        if (pcount > std.math.maxInt(usize)) return error.LimitExceeded;
        const pc: usize = @intCast(pcount);

        const group_axes = try alloc.dupe(u64, hdu.axes[1..]);
        errdefer alloc.free(group_axes);

        const ptype = try alloc.alloc([]u8, pc);
        var init_count: usize = 0;
        errdefer {
            for (ptype[0..init_count]) |s| alloc.free(s);
            alloc.free(ptype);
        }
        const pscal = try alloc.alloc(f64, pc);
        errdefer alloc.free(pscal);
        const pzero = try alloc.alloc(f64, pc);
        errdefer alloc.free(pzero);

        var name_buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < pc) : (i += 1) {
            const tkey = std.fmt.bufPrint(&name_buf, "PTYPE{d}", .{i + 1}) catch unreachable;
            ptype[i] = hdu.header.getString(alloc, tkey) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => try alloc.alloc(u8, 0), // absent or non-string ⇒ unnamed parameter
            };
            init_count = i + 1;
            const skey = std.fmt.bufPrint(&name_buf, "PSCAL{d}", .{i + 1}) catch unreachable;
            pscal[i] = hdu.header.getValue(f64, skey) catch 1;
            const zkey = std.fmt.bufPrint(&name_buf, "PZERO{d}", .{i + 1}) catch unreachable;
            pzero[i] = hdu.header.getValue(f64, zkey) catch 0;
        }

        return .{
            .fits = fits,
            .hdu = hdu,
            .gcount = gcount,
            .pcount = pcount,
            .group_axes = group_axes,
            .ptype = ptype,
            .pscal = pscal,
            .pzero = pzero,
            .bscale = hdu.header.getValue(f64, "BSCALE") catch 1,
            .bzero = hdu.header.getValue(f64, "BZERO") catch 0,
            .elem_bytes = elem_bytes,
            .data_elems = data_elems,
            .stride_bytes = stride_bytes,
        };
    }

    /// Release the owned geometry and per-parameter metadata.
    pub fn deinit(self: *RandomGroups, alloc: Allocator) void {
        alloc.free(self.group_axes);
        for (self.ptype) |s| alloc.free(s);
        alloc.free(self.ptype);
        alloc.free(self.pscal);
        alloc.free(self.pzero);
    }

    /// Number of groups (`GCOUNT`).
    pub fn groupCount(self: *const RandomGroups) u64 {
        return self.gcount;
    }

    /// Number of parameters per group (`PCOUNT`).
    pub fn paramCount(self: *const RandomGroups) u64 {
        return self.pcount;
    }

    /// Read the `PCOUNT` parameters of group `group` (0-based) into `out` (exactly `pcount`
    /// elements), with each parameter's `PSCALn`/`PZEROn` scaling applied (FR-RG-2).
    /// `error.BadDimensions` for an out-of-range group or a wrong-length `out`.
    pub fn readParams(self: *RandomGroups, comptime T: type, group: u64, out: []T) AccessError!void {
        if (group >= self.gcount) return error.BadDimensions;
        if (@as(u64, out.len) != self.pcount) return error.BadDimensions;
        const base = try self.paramByteOffset(group);
        switch (self.hdu.bitpix) {
            8 => try self.paramsTyped(u8, T, .read, base, out),
            16 => try self.paramsTyped(i16, T, .read, base, out),
            32 => try self.paramsTyped(i32, T, .read, base, out),
            64 => try self.paramsTyped(i64, T, .read, base, out),
            -32 => try self.paramsTyped(f32, T, .read, base, out),
            -64 => try self.paramsTyped(f64, T, .read, base, out),
            else => return error.BadBitpix,
        }
    }

    /// Read the data array of group `group` (0-based) into `out` (exactly `data_elems`
    /// elements), with `BSCALE`/`BZERO` scaling applied (FR-RG-2). `error.BadDimensions` for an
    /// out-of-range group or a wrong-length `out`.
    pub fn readGroup(self: *RandomGroups, comptime T: type, group: u64, out: []T) AccessError!void {
        if (group >= self.gcount) return error.BadDimensions;
        if (@as(u64, out.len) != self.data_elems) return error.BadDimensions;
        const base = try self.dataByteOffset(group);
        switch (self.hdu.bitpix) {
            8 => try self.arrayTyped(u8, T, .read, base, out, self.bscale, self.bzero),
            16 => try self.arrayTyped(i16, T, .read, base, out, self.bscale, self.bzero),
            32 => try self.arrayTyped(i32, T, .read, base, out, self.bscale, self.bzero),
            64 => try self.arrayTyped(i64, T, .read, base, out, self.bscale, self.bzero),
            -32 => try self.arrayTyped(f32, T, .read, base, out, self.bscale, self.bzero),
            -64 => try self.arrayTyped(f64, T, .read, base, out, self.bscale, self.bzero),
            else => return error.BadBitpix,
        }
    }

    /// Write the `PCOUNT` parameters of group `group` from `in` (exactly `pcount` elements),
    /// inverting each parameter's `PSCALn`/`PZEROn` scaling (FR-RG-2 write `MAY`).
    /// `error.NotWritable` on a read-only handle; `error.BadDimensions` as for `readParams`.
    pub fn writeParams(self: *RandomGroups, comptime T: type, group: u64, in: []const T) AccessError!void {
        if (self.fits.mode == .read_only or !self.fits.dev.isWritable()) return error.NotWritable;
        if (group >= self.gcount) return error.BadDimensions;
        if (@as(u64, in.len) != self.pcount) return error.BadDimensions;
        const base = try self.paramByteOffset(group);
        switch (self.hdu.bitpix) {
            8 => try self.paramsTyped(u8, T, .write, base, @constCast(in)),
            16 => try self.paramsTyped(i16, T, .write, base, @constCast(in)),
            32 => try self.paramsTyped(i32, T, .write, base, @constCast(in)),
            64 => try self.paramsTyped(i64, T, .write, base, @constCast(in)),
            -32 => try self.paramsTyped(f32, T, .write, base, @constCast(in)),
            -64 => try self.paramsTyped(f64, T, .write, base, @constCast(in)),
            else => return error.BadBitpix,
        }
    }

    /// Write the data array of group `group` from `in` (exactly `data_elems` elements),
    /// inverting `BSCALE`/`BZERO` scaling (FR-RG-2 write `MAY`). `error.NotWritable` on a
    /// read-only handle; `error.BadDimensions` as for `readGroup`.
    pub fn writeGroup(self: *RandomGroups, comptime T: type, group: u64, in: []const T) AccessError!void {
        if (self.fits.mode == .read_only or !self.fits.dev.isWritable()) return error.NotWritable;
        if (group >= self.gcount) return error.BadDimensions;
        if (@as(u64, in.len) != self.data_elems) return error.BadDimensions;
        const base = try self.dataByteOffset(group);
        switch (self.hdu.bitpix) {
            8 => try self.arrayTyped(u8, T, .write, base, @constCast(in), self.bscale, self.bzero),
            16 => try self.arrayTyped(i16, T, .write, base, @constCast(in), self.bscale, self.bzero),
            32 => try self.arrayTyped(i32, T, .write, base, @constCast(in), self.bscale, self.bzero),
            64 => try self.arrayTyped(i64, T, .write, base, @constCast(in), self.bscale, self.bzero),
            -32 => try self.arrayTyped(f32, T, .write, base, @constCast(in), self.bscale, self.bzero),
            -64 => try self.arrayTyped(f64, T, .write, base, @constCast(in), self.bscale, self.bzero),
            else => return error.BadBitpix,
        }
    }

    // ── byte offsets ───────────────────────────────────────────────────────────────────────

    // Byte offset of group `group`'s first parameter (the start of the group).
    fn paramByteOffset(self: *const RandomGroups, group: u64) errors.LimitError!u64 {
        const g_off = try limits.mul(group, self.stride_bytes);
        return limits.add(self.hdu.data_off, g_off);
    }

    // Byte offset of group `group`'s data array (just past its parameters).
    fn dataByteOffset(self: *const RandomGroups, group: u64) errors.LimitError!u64 {
        const start = try self.paramByteOffset(group);
        const pbytes = try limits.mul(self.pcount, self.elem_bytes);
        return limits.add(start, pbytes);
    }

    // ── chunked transfers ────────────────────────────────────────────────────────────────

    const Dir = enum { read, write };

    // Transfer the parameters, applying per-parameter `pscal[i]`/`pzero[i]` scaling.
    fn paramsTyped(self: *RandomGroups, comptime Stored: type, comptime T: type, comptime dir: Dir, base: u64, buf: []T) AccessError!void {
        const eb: u64 = @sizeOf(Stored);
        var scratch: [CHUNK_ELEMS]Stored = undefined;
        var done: u64 = 0;
        const total: u64 = self.pcount;
        while (done < total) {
            const n: usize = @intCast(@min(@as(u64, CHUNK_ELEMS), total - done));
            const off = try limits.add(base, try limits.mul(done, eb));
            if (dir == .read) {
                try self.fits.dev.readAll(std.mem.sliceAsBytes(scratch[0..n]), off);
                endian.swapToNative(Stored, scratch[0..n]);
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    const idx: usize = @intCast(done + @as(u64, k));
                    buf[idx] = try applyScaleRead(Stored, T, scratch[k], self.pscal[idx], self.pzero[idx]);
                }
            } else {
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    const idx: usize = @intCast(done + @as(u64, k));
                    scratch[k] = try applyScaleWrite(Stored, T, buf[idx], self.pscal[idx], self.pzero[idx]);
                }
                endian.swapToBig(Stored, scratch[0..n]);
                try self.fits.dev.writeAll(std.mem.sliceAsBytes(scratch[0..n]), off);
            }
            done += n;
        }
    }

    // Transfer a data array with uniform `scale`/`zero`.
    fn arrayTyped(self: *RandomGroups, comptime Stored: type, comptime T: type, comptime dir: Dir, base: u64, buf: []T, scale: f64, zero: f64) AccessError!void {
        const eb: u64 = @sizeOf(Stored);
        var scratch: [CHUNK_ELEMS]Stored = undefined;
        var done: u64 = 0;
        const total: u64 = self.data_elems;
        while (done < total) {
            const n: usize = @intCast(@min(@as(u64, CHUNK_ELEMS), total - done));
            const off = try limits.add(base, try limits.mul(done, eb));
            if (dir == .read) {
                try self.fits.dev.readAll(std.mem.sliceAsBytes(scratch[0..n]), off);
                endian.swapToNative(Stored, scratch[0..n]);
                var k: usize = 0;
                while (k < n) : (k += 1) buf[@intCast(done + @as(u64, k))] = try applyScaleRead(Stored, T, scratch[k], scale, zero);
            } else {
                var k: usize = 0;
                while (k < n) : (k += 1) scratch[k] = try applyScaleWrite(Stored, T, buf[@intCast(done + @as(u64, k))], scale, zero);
                endian.swapToBig(Stored, scratch[0..n]);
                try self.fits.dev.writeAll(std.mem.sliceAsBytes(scratch[0..n]), off);
            }
            done += n;
        }
    }
};

// ── scaling math (mirrors image.zig: physical = zero + scale × stored) ──────────────────────

fn isIntegral(f: f64) bool {
    return std.math.isFinite(f) and @floor(f) == f;
}

fn applyScaleRead(comptime Stored: type, comptime T: type, s: Stored, scale: f64, zero: f64) errors.ConvError!T {
    // Integer offset (scale == 1, integral zero) stays in integer space so the unsigned/signed
    // conventions carry no f64 precision loss near 2^63.
    if (scale == 1 and @typeInfo(Stored) == .int and @typeInfo(T) == .int and isIntegral(zero)) {
        const z: i128 = @intFromFloat(zero);
        return convert.cast(T, @as(i128, s) + z, .bulk);
    }
    const sf: f64 = switch (@typeInfo(Stored)) {
        .int => @floatFromInt(s),
        .float => @floatCast(s),
        else => unreachable,
    };
    return convert.cast(T, zero + scale * sf, .bulk);
}

fn applyScaleWrite(comptime Stored: type, comptime T: type, v: T, scale: f64, zero: f64) errors.ConvError!Stored {
    if (scale == 1 and @typeInfo(Stored) == .int and @typeInfo(T) == .int and isIntegral(zero)) {
        const z: i128 = @intFromFloat(zero);
        return convert.cast(Stored, @as(i128, v) - z, .bulk);
    }
    const vf: f64 = switch (@typeInfo(T)) {
        .int => @floatFromInt(v),
        .float => @floatCast(v),
        else => unreachable,
    };
    return convert.cast(Stored, (vf - zero) / scale, .bulk);
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("io/memory.zig").MemoryDevice;
const Header = @import("header/header.zig").Header;
const ImageSpec = @import("fits.zig").ImageSpec;

// Build a random-groups primary header and append it to `f`, returning the new HDU. The header
// follows the §6 order: SIMPLE, BITPIX, NAXIS, NAXIS1=0, NAXIS2…, GROUPS, PCOUNT, GCOUNT, then
// the reserved PTYPE/PSCAL/PZERO cards.
fn appendRandomGroups(
    f: *Fits,
    bitpix: i64,
    group_axes: []const u64, // NAXIS2..NAXISn
    pcount: u64,
    gcount: u64,
    pscal1: f64,
    pzero1: f64,
) !*Hdu {
    const alloc = f.alloc;
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    try h.appendValue(alloc, "SIMPLE", .{ .logical = true }, "random groups");
    try h.appendValue(alloc, "BITPIX", .{ .int = bitpix }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = @intCast(group_axes.len + 1) }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = 0 }, "no first axis (random groups)");
    var name_buf: [32]u8 = undefined;
    for (group_axes, 0..) |ax, i| {
        const kw = std.fmt.bufPrint(&name_buf, "NAXIS{d}", .{i + 2}) catch unreachable;
        try h.appendValue(alloc, kw, .{ .int = @intCast(ax) }, null);
    }
    try h.appendValue(alloc, "GROUPS", .{ .logical = true }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = @intCast(pcount) }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = @intCast(gcount) }, null);
    if (pcount >= 1) {
        try h.appendValue(alloc, "PTYPE1", .{ .string = "UU---SIN" }, null);
        try h.appendValue(alloc, "PSCAL1", .{ .float = pscal1 }, null);
        try h.appendValue(alloc, "PZERO1", .{ .float = pzero1 }, null);
    }
    if (pcount >= 2) {
        try h.appendValue(alloc, "PTYPE2", .{ .string = "VV---SIN" }, null);
    }
    return f.appendHdu(h); // takes ownership of the header
}

test "parse a created random-groups HDU: kind, counts, axes, ptype names" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const hdu = try appendRandomGroups(&f, -32, &.{ 3, 2 }, 2, 4, 1.0, 0.0);
    try testing.expectEqual(@import("hdu.zig").HduKind.random_groups, hdu.kind);

    var rg = try RandomGroups.of(&f, hdu);
    defer rg.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 4), rg.groupCount());
    try testing.expectEqual(@as(u64, 2), rg.paramCount());
    try testing.expectEqualSlices(u64, &.{ 3, 2 }, rg.group_axes);
    try testing.expectEqual(@as(u64, 6), rg.data_elems); // 3 × 2
    try testing.expectEqualStrings("UU---SIN", rg.ptype[0]);
    try testing.expectEqualStrings("VV---SIN", rg.ptype[1]);
}

test "non-random-groups HDU is rejected with WrongHduType" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    const hdu = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 4 } });
    try testing.expectError(error.WrongHduType, RandomGroups.of(&f, hdu));
}

test "float round-trip: params (with PSCAL/PZERO) and data (BSCALE/BZERO default) per group" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();

    const gcount = 4;
    const dn = 3; // data elements per group (NAXIS2)
    // Physical parameter values; param 1 is scaled by PSCAL1=2, offset by PZERO1=10.
    const p1 = [gcount]f32{ 14, 16, 20, 100 }; // stored = (p-10)/2 ⇒ 2,3,5,45 (exact)
    const p2 = [gcount]f32{ 0.5, 1.5, 2.5, 3.5 }; // unscaled
    var data: [gcount][dn]f32 = undefined;
    for (0..gcount) |g| for (0..dn) |i| {
        data[g][i] = @floatFromInt(g * 10 + i);
    };

    {
        var f = try Fits.create(testing.allocator, mem.device(), .{});
        defer f.deinit();
        const hdu = try appendRandomGroups(&f, -32, &.{dn}, 2, gcount, 2.0, 10.0);
        var rg = try RandomGroups.of(&f, hdu);
        defer rg.deinit(testing.allocator);
        for (0..gcount) |g| {
            var params = [_]f32{ p1[g], p2[g] };
            try rg.writeParams(f32, g, &params);
            try rg.writeGroup(f32, g, &data[g]);
        }
        try f.flush();
    }

    // Reopen from disk and read everything back with scaling applied.
    var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
    defer f.deinit();
    var rg = try RandomGroups.of(&f, f.current());
    defer rg.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, gcount), rg.groupCount());

    for (0..gcount) |g| {
        var params: [2]f32 = undefined;
        try rg.readParams(f32, g, &params);
        try testing.expectEqual(p1[g], params[0]); // physical, proves PSCAL/PZERO applied
        try testing.expectEqual(p2[g], params[1]);
        var out: [dn]f32 = undefined;
        try rg.readGroup(f32, g, &out);
        try testing.expectEqualSlices(f32, &data[g], &out);
    }
}

test "integer round-trip preserves group data and parameters (BITPIX=32)" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    const gcount = 3;
    const dn = 4;

    {
        var f = try Fits.create(testing.allocator, mem.device(), .{});
        defer f.deinit();
        const hdu = try appendRandomGroups(&f, 32, &.{dn}, 1, gcount, 1.0, 0.0);
        var rg = try RandomGroups.of(&f, hdu);
        defer rg.deinit(testing.allocator);
        for (0..gcount) |g| {
            var params = [_]i32{@intCast(@as(i64, @intCast(g)) * 1000 - 500)};
            try rg.writeParams(i32, g, &params);
            var d: [dn]i32 = undefined;
            for (0..dn) |i| d[i] = @intCast(@as(i64, @intCast(g * dn + i)) - 6);
            try rg.writeGroup(i32, g, &d);
        }
        try f.flush();
    }

    var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
    defer f.deinit();
    var rg = try RandomGroups.of(&f, f.current());
    defer rg.deinit(testing.allocator);
    for (0..gcount) |g| {
        var params: [1]i32 = undefined;
        try rg.readParams(i32, g, &params);
        try testing.expectEqual(@as(i32, @intCast(@as(i64, @intCast(g)) * 1000 - 500)), params[0]);
        var out: [dn]i32 = undefined;
        try rg.readGroup(i32, g, &out);
        for (0..dn) |i| try testing.expectEqual(@as(i32, @intCast(@as(i64, @intCast(g * dn + i)) - 6)), out[i]);
    }
}

test "out-of-range group and wrong-length buffers are typed errors" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    const hdu = try appendRandomGroups(&f, 16, &.{4}, 1, 2, 1.0, 0.0);
    var rg = try RandomGroups.of(&f, hdu);
    defer rg.deinit(testing.allocator);

    var pbuf: [1]i32 = undefined;
    var dbuf: [4]i32 = undefined;
    try testing.expectError(error.BadDimensions, rg.readParams(i32, 2, &pbuf)); // group ≥ gcount
    try testing.expectError(error.BadDimensions, rg.readGroup(i32, 2, &dbuf)); // group ≥ gcount
    var wrong: [3]i32 = undefined;
    try testing.expectError(error.BadDimensions, rg.readGroup(i32, 0, &wrong)); // wrong length
    var wrong_p: [2]i32 = undefined;
    try testing.expectError(error.BadDimensions, rg.readParams(i32, 0, &wrong_p)); // wrong length
}

test "raw stored values reveal the applied scaling (PSCAL1=2, PZERO1=10)" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();
    const hdu = try appendRandomGroups(&f, -32, &.{1}, 1, 1, 2.0, 10.0);
    var rg = try RandomGroups.of(&f, hdu);
    defer rg.deinit(testing.allocator);

    var params = [_]f32{20}; // physical 20 ⇒ stored (20-10)/2 = 5
    try rg.writeParams(f32, 0, &params);

    // Read the raw stored value straight off the device at the group's parameter offset.
    var raw_bytes: [4]u8 = undefined;
    try f.dev.readAll(&raw_bytes, rg.hdu.data_off);
    try testing.expectEqual(@as(f32, 5), endian.read(f32, &raw_bytes));

    var back: [1]f32 = undefined;
    try rg.readParams(f32, 0, &back);
    try testing.expectEqual(@as(f32, 20), back[0]); // scaled back to physical
}

test "read-only handle rejects writes" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    {
        var f = try Fits.create(testing.allocator, mem.device(), .{});
        defer f.deinit();
        _ = try appendRandomGroups(&f, 16, &.{4}, 1, 2, 1.0, 0.0);
        try f.flush();
    }
    var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
    defer f.deinit();
    var rg = try RandomGroups.of(&f, f.current());
    defer rg.deinit(testing.allocator);
    var params = [_]i32{1};
    try testing.expectError(error.NotWritable, rg.writeParams(i32, 0, &params));
}
