//! Round-trip tests for the C-ABI shim, calling the exported `zf_*` functions directly (no
//! dlopen — the functions are imported as ordinary Zig symbols).
const std = @import("std");
const testing = std.testing;
const capi = @import("capi.zig");
const abi = @import("abi.zig");

const Handle = abi.Handle;

// Datatype codes (mirror `abi.ZfType`).
const F32 = 9;
const F64 = 10;
const I16 = 3;

test "ABI constants stay in sync with bindings/c/zigfitsio.h" {
    // ZfType codes (#define ZF_* in the header).
    try testing.expectEqual(@as(c_int, 1), @intFromEnum(abi.ZfType.uint8));
    try testing.expectEqual(@as(c_int, 9), @intFromEnum(abi.ZfType.float32));
    try testing.expectEqual(@as(c_int, 10), @intFromEnum(abi.ZfType.float64));
    try testing.expectEqual(@as(c_int, 13), @intFromEnum(abi.ZfType.string));
    try testing.expectEqual(@as(c_int, 15), @intFromEnum(abi.ZfType.complex128));
    // HDU kind codes.
    try testing.expectEqual(@as(c_int, 0), abi.kindCode(.primary));
    try testing.expectEqual(@as(c_int, 3), abi.kindCode(.binary_table));
    // Extern struct sizes must stay C-stable (a reorder/resize breaks the header contract).
    try testing.expect(@sizeOf(abi.ZfScaling) >= 24);
    try testing.expect(@typeInfo(abi.ZfOpenOpts).@"struct".layout == .@"extern");
    try testing.expect(@typeInfo(abi.ZfScaling).@"struct".layout == .@"extern");
    try testing.expect(@typeInfo(abi.ZfColInfo).@"struct".layout == .@"extern");
}

test "create in-memory image, write and read back f32" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;

    const axes = [_]c_long{ 4, 3 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, -32, 2, &axes));

    var pixels: [12]f32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @floatFromInt(i);
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, F32, 1, 12, null, null, &pixels));

    var out: [12]f32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(hh, F32, 1, 12, null, null, &out));
    try testing.expectEqualSlices(f32, &pixels, &out);
}

test "geometry and header keyword round-trip" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;

    const axes = [_]c_long{ 8, 6 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 16, 2, &axes));

    var bitpix: c_int = 0;
    var naxis: c_int = 0;
    var got: [9]c_long = undefined;
    var filled: c_int = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_img_param(hh, &bitpix, &naxis, &got, 9, &filled));
    try testing.expectEqual(@as(c_int, 16), bitpix);
    try testing.expectEqual(@as(c_int, 2), naxis);
    try testing.expectEqual(@as(c_long, 8), got[0]);
    try testing.expectEqual(@as(c_long, 6), got[1]);

    const key = "EXPTIME";
    const cmt = "exposure";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_dbl(hh, key, key.len, 2.5, cmt, cmt.len));
    var v: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_dbl(hh, key, key.len, &v));
    try testing.expectEqual(@as(f64, 2.5), v);
    try testing.expectEqual(@as(c_int, 1), capi.zf_key_exists(hh, key, key.len));
}

test "i16 section read" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;

    const axes = [_]c_long{ 4, 4 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 16, 2, &axes));
    var pixels: [16]i16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i);
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, I16, 1, 16, null, null, &pixels));

    const lo = [_]c_long{ 0, 0 };
    const hi = [_]c_long{ 1, 1 };
    var out: [4]i16 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_subset(hh, I16, 2, &lo, &hi, null, 4, null, null, &out));
    // first 2x2 block: rows 0,1 of cols 0,1 → flat indices 0,1,4,5
    try testing.expectEqual(@as(i16, 0), out[0]);
    try testing.expectEqual(@as(i16, 1), out[1]);
    try testing.expectEqual(@as(i16, 4), out[2]);
    try testing.expectEqual(@as(i16, 5), out[3]);
}

const I32 = 5;

test "binary table create, write columns, read back" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    // A primary HDU is required before extensions.
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    const ttype = [_]?[*:0]const u8{ "INDEX", "FLUX", "NAME" };
    const tform = [_]?[*:0]const u8{ "1J", "1E", "8A" };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 0, 3, 3, &ttype, &tform, null, "EVENTS"));

    var t: ?*abi.TableHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
    defer capi.zf_table_close(t);
    const th = t.?;

    var nrows: c_longlong = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_nrows(th, &nrows));
    try testing.expectEqual(@as(c_longlong, 3), nrows);

    var idx = [_]i32{ 10, 20, 30 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col(th, I32, 0, 1, 3, null, &idx));
    var flux = [_]f32{ 1.5, 2.5, 3.5 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col(th, F32, 1, 1, 3, null, &flux));
    var names = "alpha\x00\x00\x00beta\x00\x00\x00\x00gamma\x00\x00\x00".*;
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_str(th, 2, 1, 3, 8, 8, &names));

    var idx_out = [_]i32{ 0, 0, 0 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col(th, I32, 0, 1, 3, null, &idx_out));
    try testing.expectEqualSlices(i32, &idx, &idx_out);
    var flux_out = [_]f32{ 0, 0, 0 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col(th, F32, 1, 1, 3, null, &flux_out));
    try testing.expectEqualSlices(f32, &flux, &flux_out);

    var col: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_colnum(th, "FLUX", 4, &col));
    try testing.expectEqual(@as(c_int, 1), col);

    var name_out: [24]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_str(th, 2, 1, 3, 8, 8, &name_out));
    try testing.expectEqualStrings("alpha", std.mem.trimEnd(u8, name_out[0..8], " \x00"));
    try testing.expectEqualStrings("gamma", std.mem.trimEnd(u8, name_out[16..24], " \x00"));
}

test "read-only ASCII-table writes return READONLY_FILE without mutation" {
    var source: ?*Handle = null;
    defer if (source) |handle| capi.zf_close(handle);
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &source));
    const src = source.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(src, 8, 0, null));

    const ttype = [_]?[*:0]const u8{ "COUNT", "LABEL" };
    const tform = [_]?[*:0]const u8{ "I6", "A8" };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(src, 1, 2, 2, &ttype, &tform, null, "ASCII"));
    {
        var table: ?*abi.TableHandle = null;
        try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(src, &table));
        defer capi.zf_table_close(table);
        const th = table.?;
        var counts = [_]i32{ 11, 22 };
        try testing.expectEqual(@as(c_int, 0), capi.zf_write_col(th, I32, 0, 1, 2, null, &counts));
        var labels = "alpha\x00\x00\x00beta\x00\x00\x00\x00".*;
        try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_str(th, 1, 1, 2, 8, 8, &labels));
    }
    try testing.expectEqual(@as(c_int, 0), capi.zf_flush(src));

    var size: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_data_size(src, &size));
    const serialized = try testing.allocator.alloc(u8, @intCast(size));
    defer testing.allocator.free(serialized);
    var got: usize = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_bytes(src, 0, serialized.ptr, serialized.len, &got));
    try testing.expectEqual(serialized.len, got);
    capi.zf_close(source);
    source = null;

    var opened: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_open_memory(serialized.ptr, serialized.len, 0, null, &opened));
    defer capi.zf_close(opened);
    const ro = opened.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_select(ro, 2));

    const before = try testing.allocator.alloc(u8, serialized.len);
    defer testing.allocator.free(before);
    const after = try testing.allocator.alloc(u8, serialized.len);
    defer testing.allocator.free(after);
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_bytes(ro, 0, before.ptr, before.len, &got));
    try testing.expectEqual(before.len, got);

    var table: ?*abi.TableHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(ro, &table));
    defer capi.zf_table_close(table);
    const th = table.?;
    var count = [_]i32{99};
    try testing.expectEqual(@as(c_int, 112), capi.zf_write_col(th, I32, 0, 1, 1, null, &count));
    var label = "changed\x00".*;
    try testing.expectEqual(@as(c_int, 112), capi.zf_write_col_str(th, 1, 1, 1, 8, 8, &label));

    try testing.expectEqual(@as(c_int, 0), capi.zf_read_bytes(ro, 0, after.ptr, after.len, &got));
    try testing.expectEqual(after.len, got);
    try testing.expectEqualSlices(u8, before, after);
}

test "packed VLA ABI matches legacy P/Q/complex transfers and rejects invalid buffers" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    const ttype = [_]?[*:0]const u8{ "P", "Q", "C" };
    const tform = [_]?[*:0]const u8{ "1PJ", "1QJ", "1PC" };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl_heap(hh, 0, 4, 3, &ttype, &tform, null, "VLA", 1024));

    var t: ?*abi.TableHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
    defer capi.zf_table_close(t);
    const th = t.?;

    // Seed P/Q cells through the legacy row-at-a-time ABI, including empty cells.
    var dummy_i32 = [_]i32{0};
    var p0 = [_]i32{ 1, 2, 3 };
    var p2 = [_]i32{4};
    var p3 = [_]i32{ 5, 6 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 0, 1, &p0, p0.len));
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 0, 2, &dummy_i32, 0));
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 0, 3, &p2, p2.len));
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 0, 4, &p3, p3.len));

    var q0 = [_]i32{100};
    var q1 = [_]i32{ 200, 300 };
    var q3 = [_]i32{400};
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 1, 1, &q0, q0.len));
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 1, 2, &q1, q1.len));
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 1, 3, &dummy_i32, 0));
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 1, 4, &q3, q3.len));

    // A complex descriptor's logical length is two here, but its packed layout has four f32
    // scalar slots (real/imaginary pairs).
    var complex = [_]f32{ 1.25, -2.5, 3.75, 4.5 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, F32, 2, 1, &complex, complex.len));

    var p_offsets: [5]u64 = undefined;
    var p_total: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_layout(th, 0, 1, 4, &p_offsets, p_offsets.len, &p_total));
    try testing.expectEqualSlices(u64, &.{ 0, 3, 3, 4, 6 }, &p_offsets);
    try testing.expectEqual(@as(u64, 6), p_total);
    var p_packed: [6]i32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_packed(th, I32, 0, 1, 4, &p_packed, p_packed.len));
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 5, 6 }, &p_packed);

    var q_offsets: [5]u64 = undefined;
    var q_total: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_layout(th, 1, 1, 4, &q_offsets, q_offsets.len, &q_total));
    try testing.expectEqualSlices(u64, &.{ 0, 1, 3, 3, 4 }, &q_offsets);
    var q_packed: [4]i32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_packed(th, I32, 1, 1, 4, &q_packed, q_total));
    try testing.expectEqualSlices(i32, &.{ 100, 200, 300, 400 }, &q_packed);

    var c_offsets: [2]u64 = undefined;
    var c_total: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_layout(th, 2, 1, 1, &c_offsets, c_offsets.len, &c_total));
    try testing.expectEqualSlices(u64, &.{ 0, 4 }, &c_offsets);
    var c_packed: [4]f32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_packed(th, F32, 2, 1, 1, &c_packed, c_total));
    try testing.expectEqualSlices(f32, &complex, &c_packed);

    // Packed write, then prove the legacy cell reader observes identical row boundaries/data.
    const replacement_offsets = [_]u64{ 0, 2, 2, 5, 6 };
    var replacement = [_]i32{ 9, 8, 7, 6, 5, 4 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla_packed(
        th,
        I32,
        0,
        1,
        4,
        &replacement_offsets,
        replacement_offsets.len,
        &replacement,
        replacement.len,
    ));
    var legacy_out: [3]i32 = undefined;
    var legacy_n: c_longlong = -1;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla(th, I32, 0, 1, legacy_out.len, &legacy_out, &legacy_n));
    try testing.expectEqual(@as(c_longlong, 2), legacy_n);
    try testing.expectEqualSlices(i32, &.{ 9, 8 }, legacy_out[0..2]);
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla(th, I32, 0, 2, legacy_out.len, &legacy_out, &legacy_n));
    try testing.expectEqual(@as(c_longlong, 0), legacy_n);
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla(th, I32, 0, 3, legacy_out.len, &legacy_out, &legacy_n));
    try testing.expectEqual(@as(c_longlong, 3), legacy_n);
    try testing.expectEqualSlices(i32, &.{ 7, 6, 5 }, &legacy_out);
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla(th, I32, 0, 4, legacy_out.len, &legacy_out, &legacy_n));
    try testing.expectEqual(@as(c_longlong, 1), legacy_n);
    try testing.expectEqual(@as(i32, 4), legacy_out[0]);

    // Zero-row ranges still have the canonical one-entry layout and accept null payloads.
    var empty_layout = [_]u64{99};
    var empty_total: u64 = 99;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_layout(th, 0, 5, 0, &empty_layout, 1, &empty_total));
    try testing.expectEqualSlices(u64, &.{0}, &empty_layout);
    try testing.expectEqual(@as(u64, 0), empty_total);
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_packed(th, I32, 0, 5, 0, null, 0));

    // ABI-side validation must return statuses rather than trapping on bad casts/pointers.
    try testing.expectEqual(@as(c_int, 104), capi.zf_read_col_vla_layout(th, 0, 1, 4, null, 5, &p_total));
    try testing.expectEqual(@as(c_int, 104), capi.zf_read_col_vla_layout(th, 0, 1, 4, &p_offsets, 5, null));
    try testing.expectEqual(@as(c_int, 308), capi.zf_read_col_vla_layout(th, 0, 1, 4, &p_offsets, 4, &p_total));
    try testing.expectEqual(@as(c_int, 307), capi.zf_read_col_vla_layout(th, 0, 0, 4, &p_offsets, 5, &p_total));
    try testing.expectEqual(@as(c_int, 307), capi.zf_read_col_vla_layout(th, 0, 1, -1, &p_offsets, 5, &p_total));
    try testing.expectEqual(@as(c_int, 219), capi.zf_read_col_vla_layout(th, 70000, 1, 4, &p_offsets, 5, &p_total));
    try testing.expectEqual(@as(c_int, 104), capi.zf_read_col_vla_packed(th, I32, 0, 1, 4, null, 1));
    try testing.expectEqual(@as(c_int, 308), capi.zf_read_col_vla_packed(th, I32, 0, 1, 4, &p_packed, 5));
    try testing.expectEqual(@as(c_int, 410), capi.zf_read_col_vla_packed(th, 999, 0, 1, 4, &p_packed, 6));
    try testing.expectEqual(@as(c_int, 104), capi.zf_write_col_vla_packed(th, I32, 0, 1, 4, null, 5, &replacement, 6));
    try testing.expectEqual(@as(c_int, 308), capi.zf_write_col_vla_packed(th, I32, 0, 1, 4, &replacement_offsets, 4, &replacement, 6));
    try testing.expectEqual(@as(c_int, 104), capi.zf_write_col_vla_packed(th, I32, 0, 1, 4, &replacement_offsets, 5, null, 6));

    // A malformed offset vector is rejected before mutation; compare the complete FITS image.
    var data_size: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_data_size(hh, &data_size));
    const before = try testing.allocator.alloc(u8, @intCast(data_size));
    defer testing.allocator.free(before);
    const after = try testing.allocator.alloc(u8, @intCast(data_size));
    defer testing.allocator.free(after);
    var got: usize = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_bytes(hh, 0, before.ptr, before.len, &got));
    try testing.expectEqual(before.len, got);
    const bad_offsets = [_]u64{ 0, 2, 1, 5, 6 };
    try testing.expectEqual(@as(c_int, 308), capi.zf_write_col_vla_packed(th, I32, 0, 1, 4, &bad_offsets, bad_offsets.len, &replacement, replacement.len));
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_bytes(hh, 0, after.ptr, after.len, &got));
    try testing.expectEqualSlices(u8, before, after);
}

test "read-only VLA writes reject before lazy heap reconstruction" {
    // Build a minimal VLA table, export its bytes, then forge its sole descriptor so a heap scan
    // would fail with BadDescriptor. The write APIs must return READONLY_FILE before attempting
    // that scan, leaving both the lazy manager and the complete file image untouched.
    var source: ?*Handle = null;
    defer if (source) |handle| capi.zf_close(handle);
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &source));
    const src = source.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(src, 8, 0, null));

    const ttype = [_]?[*:0]const u8{"P"};
    const tform = [_]?[*:0]const u8{"1PJ"};
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl_heap(src, 0, 1, 1, &ttype, &tform, null, "RO", 16));
    const descriptor_off: usize = @intCast(src.fits.current().data_off);

    var size: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_data_size(src, &size));
    const forged = try testing.allocator.alloc(u8, @intCast(size));
    defer testing.allocator.free(forged);
    var got: usize = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_bytes(src, 0, forged.ptr, forged.len, &got));
    try testing.expectEqual(forged.len, got);
    capi.zf_close(source);
    source = null;

    // P descriptor: one J element at a heap-relative offset beyond the reserved 16-byte heap.
    std.mem.writeInt(i32, forged[descriptor_off..][0..4], 1, .big);
    std.mem.writeInt(i32, forged[descriptor_off + 4 ..][0..4], 1024, .big);

    var opened: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_open_memory(forged.ptr, forged.len, 0, null, &opened));
    defer capi.zf_close(opened);
    const ro = opened.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_select(ro, 2));

    const before = try testing.allocator.alloc(u8, forged.len);
    defer testing.allocator.free(before);
    const after = try testing.allocator.alloc(u8, forged.len);
    defer testing.allocator.free(after);
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_bytes(ro, 0, before.ptr, before.len, &got));
    try testing.expectEqual(before.len, got);

    var table: ?*abi.TableHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(ro, &table));
    defer capi.zf_table_close(table);
    const th = table.?;
    try testing.expect(th.mgr == null);

    var value = [_]i32{42};
    try testing.expectEqual(@as(c_int, 112), capi.zf_write_col_vla(th, I32, 0, 1, &value, value.len));
    try testing.expect(th.mgr == null);

    const offsets = [_]u64{ 0, 1 };
    try testing.expectEqual(@as(c_int, 112), capi.zf_write_col_vla_packed(th, I32, 0, 1, 1, &offsets, offsets.len, &value, value.len));
    try testing.expect(th.mgr == null);

    try testing.expectEqual(@as(c_int, 0), capi.zf_read_bytes(ro, 0, after.ptr, after.len, &got));
    try testing.expectEqual(after.len, got);
    try testing.expectEqualSlices(u8, before, after);
}

test "lazy VLA manager preserves every live column when rewriting a populated heap" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    const ttype = [_]?[*:0]const u8{ "A", "B" };
    const tform = [_]?[*:0]const u8{ "1PJ", "1QJ" };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl_heap(hh, 0, 2, 2, &ttype, &tform, null, "LIVE", 256));

    // Populate four distinct live heap extents, then close the table view. Reopening creates a
    // fresh CAPI handle whose lazy HeapManager must reconstruct occupancy from the descriptors.
    {
        var t: ?*abi.TableHandle = null;
        try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
        defer capi.zf_table_close(t);
        const th = t.?;
        var a0 = [_]i32{ 11, 12 };
        var a1 = [_]i32{ 13, 14 };
        var b0 = [_]i32{ 21, 22 };
        var b1 = [_]i32{ 23, 24 };
        try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 0, 1, &a0, a0.len));
        try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 0, 2, &a1, a1.len));
        try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 1, 1, &b0, b0.len));
        try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(th, I32, 1, 2, &b1, b1.len));
    }

    // Reopen and grow B[0] through the packed API. An empty-assuming manager would allocate at
    // heap offset zero and overwrite A; reconstruction must place it after all live extents.
    {
        var t: ?*abi.TableHandle = null;
        try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
        defer capi.zf_table_close(t);
        const no_rows = [_]u64{0};
        try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla_packed(
            t.?,
            I32,
            1,
            3,
            0,
            &no_rows,
            no_rows.len,
            null,
            0,
        ));
        try testing.expect(t.?.mgr == null); // a no-op must not scan/reconstruct the live heap

        const offsets = [_]u64{ 0, 3 };
        var replacement = [_]i32{ 91, 92, 93 };
        try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla_packed(
            t.?,
            I32,
            1,
            1,
            1,
            &offsets,
            offsets.len,
            &replacement,
            replacement.len,
        ));
    }

    // Reopen once more and grow A[1] through the legacy cell API, exercising its independent
    // lazy-manager call site against an already-populated, non-contiguous heap.
    {
        var t: ?*abi.TableHandle = null;
        try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
        defer capi.zf_table_close(t);
        var replacement = [_]i32{ 71, 72, 73 };
        try testing.expectEqual(@as(c_int, 0), capi.zf_write_col_vla(t.?, I32, 0, 2, &replacement, replacement.len));
    }

    // Both rewritten cells and both untouched cells must remain distinct and byte-correct.
    {
        var t: ?*abi.TableHandle = null;
        try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
        defer capi.zf_table_close(t);
        const th = t.?;

        var offsets: [3]u64 = undefined;
        var total: u64 = 0;
        var a: [5]i32 = undefined;
        try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_layout(th, 0, 1, 2, &offsets, offsets.len, &total));
        try testing.expectEqualSlices(u64, &.{ 0, 2, 5 }, &offsets);
        try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_packed(th, I32, 0, 1, 2, &a, total));
        try testing.expectEqualSlices(i32, &.{ 11, 12, 71, 72, 73 }, &a);

        var b: [5]i32 = undefined;
        try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_layout(th, 1, 1, 2, &offsets, offsets.len, &total));
        try testing.expectEqualSlices(u64, &.{ 0, 3, 5 }, &offsets);
        try testing.expectEqual(@as(c_int, 0), capi.zf_read_col_vla_packed(th, I32, 1, 1, 2, &b, total));
        try testing.expectEqualSlices(i32, &.{ 91, 92, 93, 23, 24 }, &b);

        // The four live J payloads must not alias after either rewrite.
        const cells = [_]struct { col: c_int, row: c_longlong }{
            .{ .col = 0, .row = 1 },
            .{ .col = 0, .row = 2 },
            .{ .col = 1, .row = 1 },
            .{ .col = 1, .row = 2 },
        };
        var lens: [cells.len]c_longlong = undefined;
        var offs: [cells.len]c_longlong = undefined;
        for (cells, 0..) |cell, i| {
            try testing.expectEqual(@as(c_int, 0), capi.zf_read_descript(th, cell.col, cell.row, &lens[i], &offs[i]));
            try testing.expect(lens[i] > 0 and offs[i] >= 0);
        }
        for (0..cells.len) |i| {
            const i_start: u64 = @intCast(offs[i]);
            const i_end = i_start + @as(u64, @intCast(lens[i])) * @sizeOf(i32);
            for (i + 1..cells.len) |j| {
                const j_start: u64 = @intCast(offs[j]);
                const j_end = j_start + @as(u64, @intCast(lens[j])) * @sizeOf(i32);
                try testing.expect(i_end <= j_start or j_end <= i_start);
            }
        }
    }
}

test "table view survives owner close without use-after-free; bad indices error, never trap" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));
    const ttype = [_]?[*:0]const u8{"INDEX"};
    const tform = [_]?[*:0]const u8{"1J"};
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 0, 3, 1, &ttype, &tform, null, "T"));

    var t: ?*abi.TableHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
    const th = t.?;

    // Negative / out-of-range indices must return an error status, never trap across the ABI
    // (a Zig panic from an @intCast is uncatchable by a C caller).
    var out_len: c_longlong = 0;
    var out_off: c_longlong = 0;
    try testing.expect(capi.zf_read_descript(th, 0, 0, &out_len, &out_off) != 0); // row 0 (< 1)
    try testing.expect(capi.zf_append_rows(th, -1) != 0); // negative count
    try testing.expect(capi.zf_delete_col(th, 70000) != 0); // > u16 max

    // Close the file while the view is still open: the view must be invalidated, not left dangling.
    capi.zf_close(h);

    var nrows: c_longlong = 0;
    try testing.expect(capi.zf_table_nrows(th, &nrows) != 0); // dead view → error, not use-after-free

    // The (dead) view is still safe to close and free.
    capi.zf_table_close(t);
}

test "tile-compressed image round-trips through zf_read_img" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null)); // primary

    var ramp: [256]i32 = undefined;
    for (&ramp, 0..) |*p, i| p.* = @intCast(i);
    const axes = [_]c_long{ 16, 16 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_compressed(hh, I32, 32, 2, &axes, null, "RICE_1", null, 1, &ramp, 256));

    // The compressed image is HDU 2 (a ZIMAGE BINTABLE); zf_read_img decodes it transparently.
    try testing.expectEqual(@as(c_int, 0), capi.zf_select(hh, 2));
    var out: [256]i32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(hh, I32, 1, 256, null, null, &out));
    try testing.expectEqualSlices(i32, &ramp, &out);
}

test "zf_write_compressed2: lossy HCOMPRESS knobs cross the ABI (arg order, ZVAL cards, bounds)" {
    // A misordered/mistyped hcomp_scale or hcomp_smooth argument would either error, record the
    // wrong ZVAL1/ZVAL2, produce a lossless (identical) decode, or blow the error bound — every
    // failure mode below trips. (`zf_write_compressed` delegating with (0, false) is covered by
    // the RICE round-trip above.)
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null)); // primary

    // Curved surface (nonzero curvature ⇒ scale-16 quantization visibly changes pixels).
    var curved: [256]i32 = undefined;
    for (0..16) |r| {
        for (0..16) |c| curved[r * 16 + c] = @intCast(r * r + 2 * c * c + r * c);
    }
    const axes = [_]c_long{ 16, 16 };
    const tile = [_]c_long{ 16, 16 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_compressed2(hh, I32, 32, 2, &axes, &tile, "HCOMPRESS_1", null, 1, -16.0, 1, &curved, 256));

    // The recorded request cards: ZVAL1 = -16.0 (float), ZVAL2 = 1 (smooth).
    try testing.expectEqual(@as(c_int, 0), capi.zf_select(hh, 2));
    var zval1: f64 = 0;
    const k1 = "ZVAL1";
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_dbl(hh, k1, k1.len, &zval1));
    try testing.expectEqual(@as(f64, -16.0), zval1);
    // `zf_read_key_lng` takes a `*c_longlong`; on Windows (LLP64) `c_long` is 32-bit, so a
    // `*c_long` here is a genuine pointer-type mismatch that fails to compile. Match the ABI type.
    var zval2: c_longlong = 0;
    const k2 = "ZVAL2";
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_lng(hh, k2, k2.len, &zval2));
    try testing.expectEqual(@as(c_longlong, 1), zval2);

    // Transparent decode: genuinely lossy, but within the scale-16 quantization bound.
    var out: [256]i32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(hh, I32, 1, 256, null, null, &out));
    var maxerr: i64 = 0;
    for (curved, out) |o, g| {
        const e: i64 = @intCast(@abs(@as(i64, o) - @as(i64, g)));
        if (e > maxerr) maxerr = e;
    }
    try testing.expect(maxerr > 0 and maxerr <= 64 * 16);

    // Knob misuse crosses the ABI as an error status, not an abort: RICE + hcomp_scale.
    try testing.expect(capi.zf_write_compressed2(hh, I32, 32, 2, &axes, &tile, "RICE_1", null, 1, -4.0, 0, &curved, 256) != 0);
}

test "zf_write_compressed3: quantized-float write crosses the ABI (level plumbed, gates fail loud)" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null)); // primary

    // A positive noisy field; absolute step 0.25 so the round-trip bound is deterministic.
    var pix: [256]f32 = undefined;
    var state: u32 = 999;
    for (&pix, 0..) |*v, i| {
        state = state *% 1664525 +% 1013904223;
        v.* = 10.0 + @as(f32, @floatFromInt(i % 16)) + @as(f32, @floatFromInt(state >> 24)) / 64.0;
    }
    const axes = [_]c_long{ 16, 16 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_compressed3(hh, F32, -32, 2, &axes, null, "HCOMPRESS_1", "SUBTRACTIVE_DITHER_1", 1, -0.25, 1, 0.0, 0, &pix, 256));

    // Transparent decode: |err| bounded by the absolute step / 2.
    try testing.expectEqual(@as(c_int, 0), capi.zf_select(hh, 2));
    var out: [256]f32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(hh, F32, 1, 256, null, null, &out));
    for (pix, out) |o, g| try testing.expect(@abs(o - g) <= 0.125 + 1e-5);

    // A set quantize_level on a non-quantizing write is an error status, never silent.
    var ints: [256]i32 = undefined;
    for (&ints, 0..) |*v, i| v.* = @intCast(i);
    try testing.expect(capi.zf_write_compressed3(hh, I32, 32, 2, &axes, null, "RICE_1", null, 1, 4.0, 1, 0.0, 0, &ints, 256) != 0);
    // has_quantize_level = 0 leaves the level unset: the same integer write succeeds.
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_compressed3(hh, I32, 32, 2, &axes, null, "RICE_1", null, 1, 0.0, 0, 0.0, 0, &ints, 256));
}

test "checksum write + verify, and validation pass" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    const axes = [_]c_long{ 4, 4 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, -32, 2, &axes));
    var pix: [16]f32 = undefined;
    for (&pix, 0..) |*p, i| p.* = @floatFromInt(i);
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, F32, 1, 16, null, null, &pix));

    try testing.expectEqual(@as(c_int, 0), capi.zf_write_chksum(hh));
    var csum: c_int = -99;
    var dsum: c_int = -99;
    try testing.expectEqual(@as(c_int, 0), capi.zf_verify_chksum(hh, &csum, &dsum));
    try testing.expectEqual(@as(c_int, 1), csum); // match
    try testing.expectEqual(@as(c_int, 1), dsum);

    var fnd: ?*abi.FindingsHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_validate(hh, &fnd));
    defer capi.zf_findings_free(fnd);
    var count: c_long = -1;
    try testing.expectEqual(@as(c_int, 0), capi.zf_findings_count(fnd.?, &count));
    // No hard errors expected for a well-formed file.
    var i: c_long = 0;
    while (i < count) : (i += 1) {
        var sev: c_int = 0;
        var fhdu: c_int = 0;
        var kwb: [16]u8 = undefined;
        var kwl: usize = 0;
        var msgb: [128]u8 = undefined;
        var msgl: usize = 0;
        _ = capi.zf_findings_get(fnd.?, i, &sev, &fhdu, &kwb, kwb.len, &kwl, &msgb, msgb.len, &msgl);
        try testing.expect(sev != 0); // no .err findings
    }
}

test "WCS celestial round-trip pixel→world→pixel" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    const axes = [_]c_long{ 64, 64 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, -32, 2, &axes));

    const K = struct {
        fn s(hd: *Handle, name: []const u8, val: []const u8) !void {
            try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_str(hd, name.ptr, name.len, val.ptr, val.len, null, 0));
        }
        fn d(hd: *Handle, name: []const u8, val: f64) !void {
            try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_dbl(hd, name.ptr, name.len, val, null, 0));
        }
    };
    try K.s(hh, "CTYPE1", "RA---TAN");
    try K.s(hh, "CTYPE2", "DEC--TAN");
    try K.d(hh, "CRPIX1", 32.0);
    try K.d(hh, "CRPIX2", 32.0);
    try K.d(hh, "CRVAL1", 150.0);
    try K.d(hh, "CRVAL2", 2.0);
    try K.d(hh, "CDELT1", -0.001);
    try K.d(hh, "CDELT2", 0.001);

    var lon: f64 = 0;
    var lat: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_wcs_pix2world(hh, 0, 40.0, 30.0, &lon, &lat));
    var px: f64 = 0;
    var py: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_wcs_world2pix(hh, 0, lon, lat, &px, &py));
    try testing.expectApproxEqAbs(@as(f64, 40.0), px, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 30.0), py, 1e-6);
}

// ════════════════════════════════════════════════════════════════════════════════════════════
// Gap-closure coverage — exercises the 29 `zf_*` exports that had no ABI-boundary test, plus
// `ZfScaling`/`ZfOpenOpts` (test-plan Phase 1). Each block is named for the function group it
// closes so a missing symbol in a future ABI change surfaces as a named failure.
// ════════════════════════════════════════════════════════════════════════════════════════════

test "error introspection: last_status/errmsg agree; zf_free releases a longstr buffer" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    // Force a KeywordNotFound (KEY_NO_EXIST, CFITSIO code 202) and check the thread-local
    // error state agrees between the return code, zf_last_status, and zf_errmsg.
    var v: f64 = 0;
    const key = "NOSUCH";
    const status = capi.zf_read_key_dbl(hh, key, key.len, &v);
    try testing.expectEqual(@as(c_int, 202), status);
    try testing.expectEqual(status, capi.zf_last_status());
    var msgbuf: [128]u8 = undefined;
    var msglen: usize = 0;
    try testing.expectEqual(status, capi.zf_errmsg(&msgbuf, msgbuf.len, &msglen));
    try testing.expect(msglen > 0);

    // Documented current behavior: `Diagnostics.note()` has no call sites anywhere in `src/`
    // today, so the byte-offset/HDU-index/keyword introspection getters always report
    // "unknown" regardless of the failing operation. This pins the actual ABI contract (the
    // plumbing Handle -> Diagnostics -> zf_last_* exists end to end, but nothing feeds it yet)
    // rather than an aspirational one.
    try testing.expectEqual(@as(i64, -1), capi.zf_last_byte_offset());
    try testing.expectEqual(@as(i64, -1), capi.zf_last_hdu_index());
    var kwbuf: [16]u8 = undefined;
    var kwlen: usize = 0;
    capi.zf_last_keyword(&kwbuf, kwbuf.len, &kwlen);
    try testing.expectEqual(@as(usize, 0), kwlen);

    // zf_read_key_longstr is allocate-and-return; verify the round-trip and release with
    // zf_free.
    const name = "LONGSTR";
    const longval = &@as([100]u8, @splat('x'));
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_longstr(hh, name, name.len, longval, longval.len, null, 0));
    var out_ptr: ?[*]u8 = null;
    var out_len: usize = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_longstr(hh, name, name.len, &out_ptr, &out_len));
    try testing.expectEqual(@as(usize, longval.len), out_len);
    try testing.expectEqualStrings(longval, out_ptr.?[0..out_len]);
    capi.zf_free(out_ptr, out_len);
}

test "spaced keyword names are rejected with status 207 on the write path (BUGHUNT 62)" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    // BadKeywordName maps to CFITSIO 207 (BAD_KEYCHAR) across the whole write ABI.
    const bad = "AB CD";
    try testing.expectEqual(@as(c_int, 207), capi.zf_write_key_lng(hh, bad, bad.len, 5, null, 0));
    try testing.expectEqual(@as(c_int, 207), capi.zf_last_status());
    const longval = "x" ** 100;
    try testing.expectEqual(@as(c_int, 207), capi.zf_write_key_longstr(hh, bad, bad.len, longval, longval.len, null, 0));

    const good = "GOODKEY";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, good, good.len, 7, null, 0));
    try testing.expectEqual(@as(c_int, 207), capi.zf_rename_key(hh, good, good.len, bad, bad.len));
    var v: c_longlong = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_lng(hh, good, good.len, &v));
    try testing.expectEqual(@as(c_longlong, 7), v); // untouched by the failed rename
}

test "non-finite float keyword values are rejected with status 207 on the write path (BUGHUNT 25/27)" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    // BadValueSyntax maps to CFITSIO 207, mirroring the read path's rejection of nan/inf tokens.
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const name = "KNAN";
    try testing.expectEqual(@as(c_int, 207), capi.zf_write_key_dbl(hh, name, name.len, nan, null, 0));
    try testing.expectEqual(@as(c_int, 207), capi.zf_last_status());
    try testing.expectEqual(@as(c_int, 207), capi.zf_write_key_dbl(hh, name, name.len, inf, null, 0));
    try testing.expectEqual(@as(c_int, 207), capi.zf_write_key_dbl(hh, name, name.len, -inf, null, 0));

    // The failed writes left nothing behind: the keyword is absent...
    var v: f64 = 0;
    try testing.expect(capi.zf_read_key_dbl(hh, name, name.len, &v) != 0);
    // ...and a finite value still writes fine afterwards.
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_dbl(hh, name, name.len, 1.5, null, 0));
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_dbl(hh, name, name.len, &v));
    try testing.expectEqual(@as(f64, 1.5), v);

    // Updating an existing key with NaN fails and keeps the old value.
    try testing.expectEqual(@as(c_int, 207), capi.zf_write_key_dbl(hh, name, name.len, nan, null, 0));
    v = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_dbl(hh, name, name.len, &v));
    try testing.expectEqual(@as(f64, 1.5), v);
}

test "BLANK integer nulls substitute a caller-supplied NaN nulval, before scaling (BUGHUNT 28)" {
    // Pins the exact ABI contract the Python/TS bindings rely on: `nulval` is dereferenced as
    // the OUTPUT dtype, and a stored value equal to the header BLANK becomes the sentinel
    // instead of being scaled through BSCALE/BZERO.
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;

    const axes = [_]c_long{4};
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 16, 1, &axes));
    const kb = "BLANK";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, kb, kb.len, -32768, null, 0));
    const sb = "BSCALE";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_dbl(hh, sb, sb.len, 2.0, null, 0));
    const zb = "BZERO";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_dbl(hh, zb, zb.len, 100.0, null, 0));

    // Store the raw shorts verbatim (identity scaling override), incl. the sentinel at index 1.
    const pixels = [_]i16{ 1, -32768, 3, 4 };
    const identity: abi.ZfScaling = .{};
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, I16, 1, 4, null, &identity, &pixels));

    const nan = std.math.nan(f64);
    var out: [4]f64 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(hh, F64, 1, 4, &nan, null, &out));
    try testing.expectEqual(@as(f64, 102.0), out[0]); // 2*1 + 100
    try testing.expect(std.math.isNan(out[1])); // the sentinel, NOT 2*(-32768) + 100
    try testing.expectEqual(@as(f64, 106.0), out[2]);
    try testing.expectEqual(@as(f64, 108.0), out[3]);
}

fn putRecord(hh: *Handle, text: []const u8) !void {
    var card: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(card[0..text.len], text);
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_record(hh, &card));
}

fn countContinueCards(hh: *Handle) !usize {
    var n: c_long = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_card_count(hh, &n));
    var found: usize = 0;
    var i: c_long = 0;
    while (i < n) : (i += 1) {
        var got: [80]u8 = undefined;
        try testing.expectEqual(@as(c_int, 0), capi.zf_read_card(hh, i, &got));
        if (std.mem.eql(u8, got[0..8], "CONTINUE")) found += 1;
    }
    return found;
}

test "zf_write_key_longstr replace does not orphan the old CONTINUE run (BUGHUNT 24)" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    const name = "LONGSTR";
    const longval = "x" ** 150; // base + 2 CONTINUE cards
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_longstr(hh, name, name.len, longval, longval.len, null, 0));
    try testing.expect(try countContinueCards(hh) >= 2);
    var n_before: c_long = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_card_count(hh, &n_before));

    // Replacing with a short value must remove the whole old run, not just the base card.
    const short = "short";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_longstr(hh, name, name.len, short, short.len, null, 0));
    try testing.expectEqual(@as(usize, 0), try countContinueCards(hh));
    var n_after: c_long = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_card_count(hh, &n_after));
    try testing.expectEqual(n_before - 2, n_after); // 3 cards → 1

    var out_ptr: ?[*]u8 = null;
    var out_len: usize = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_longstr(hh, name, name.len, &out_ptr, &out_len));
    defer capi.zf_free(out_ptr, out_len);
    try testing.expectEqualStrings(short, out_ptr.?[0..out_len]);
}

test "zf_delete_key removes a HIERARCH+CONTINUE run inserted via zf_write_record" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));
    var n_base: c_long = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_card_count(hh, &n_base));

    try putRecord(hh, "HIERARCH ESO LONG STR = 'aaaa&'");
    try putRecord(hh, "CONTINUE  'bbbb&'");
    try putRecord(hh, "CONTINUE  'cccc'");

    const q = "ESO LONG STR"; // HIERARCH names resolve through matchName
    try testing.expectEqual(@as(c_int, 0), capi.zf_delete_key(hh, q, q.len));
    try testing.expectEqual(@as(usize, 0), try countContinueCards(hh));
    var n_after: c_long = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_card_count(hh, &n_after));
    try testing.expectEqual(n_base, n_after); // header back to its baseline
}

test "header scalar reads: lng, log, str, and key_comment" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    const ikey = "MYINT";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, ikey, ikey.len, 42, null, 0));
    var iv: c_longlong = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_lng(hh, ikey, ikey.len, &iv));
    try testing.expectEqual(@as(c_longlong, 42), iv);

    const lkey = "OBSGOOD";
    const cmt = "a flag";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_log(hh, lkey, lkey.len, 1, cmt, cmt.len));
    var lv: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_log(hh, lkey, lkey.len, &lv));
    try testing.expectEqual(@as(c_int, 1), lv);
    var cbuf: [80]u8 = undefined;
    var clen: usize = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_key_comment(hh, lkey, lkey.len, &cbuf, cbuf.len, &clen));
    try testing.expectEqualStrings(cmt, cbuf[0..clen]);

    const skey = "OBSERVER";
    const sval = "Tycho Brahe";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_str(hh, skey, skey.len, sval, sval.len, null, 0));
    var sbuf: [32]u8 = undefined;
    var slen: usize = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_str(hh, skey, skey.len, &sbuf, sbuf.len, &slen));
    try testing.expectEqualStrings(sval, sbuf[0..slen]);

    // A key with no comment: zf_key_comment reports zero length, status 0 (not an error).
    var clen2: usize = 99;
    try testing.expectEqual(@as(c_int, 0), capi.zf_key_comment(hh, skey, skey.len, &cbuf, cbuf.len, &clen2));
    try testing.expectEqual(@as(usize, 0), clen2);
}

test "zf_write_key_undef writes an undefined card and updates in place" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    // Create: undefined value with a comment.
    const ukey = "UNDEF";
    const cmt = "no value";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_undef(hh, ukey, ukey.len, cmt, cmt.len));
    try testing.expectEqual(@as(c_int, 1), capi.zf_key_exists(hh, ukey, ukey.len));
    var iv: c_longlong = 0;
    try testing.expectEqual(@as(c_int, 204), capi.zf_read_key_lng(hh, ukey, ukey.len, &iv)); // VALUE_UNDEFINED
    var cbuf: [80]u8 = undefined;
    var clen: usize = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_key_comment(hh, ukey, ukey.len, &cbuf, cbuf.len, &clen));
    try testing.expectEqualStrings(cmt, cbuf[0..clen]);

    // The card bytes are astropy's compact undefined form: blank value field, then `/ comment`.
    var count: c_long = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_card_count(hh, &count));
    var found = false;
    var got: [80]u8 = undefined;
    var i: c_long = 0;
    while (i < count) : (i += 1) {
        try testing.expectEqual(@as(c_int, 0), capi.zf_read_card(hh, i, &got));
        if (std.mem.startsWith(u8, &got, "UNDEF   ")) {
            try testing.expectEqualStrings("UNDEF   =  / no value", std.mem.trimEnd(u8, &got, " "));
            found = true;
        }
    }
    try testing.expect(found);

    // Overwriting an existing valued key updates in place: card count unchanged, value blank,
    // and a null comment preserves the old one (same contract as the other zf_write_key_*).
    const kkey = "MYINT";
    const kcmt = "kept";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, kkey, kkey.len, 42, kcmt, kcmt.len));
    var n_before: c_long = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_card_count(hh, &n_before));
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_undef(hh, kkey, kkey.len, null, 0));
    var n_after: c_long = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_card_count(hh, &n_after));
    try testing.expectEqual(n_before, n_after);
    try testing.expectEqual(@as(c_int, 204), capi.zf_read_key_lng(hh, kkey, kkey.len, &iv));
    try testing.expectEqual(@as(c_int, 0), capi.zf_key_comment(hh, kkey, kkey.len, &cbuf, cbuf.len, &clen));
    try testing.expectEqualStrings(kcmt, cbuf[0..clen]);
}

test "rename_key and insert_record" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    const old = "OLDNAME";
    const new = "NEWNAME";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, old, old.len, 7, null, 0));
    try testing.expectEqual(@as(c_int, 0), capi.zf_rename_key(hh, old, old.len, new, new.len));
    try testing.expectEqual(@as(c_int, 0), capi.zf_key_exists(hh, old, old.len));
    try testing.expectEqual(@as(c_int, 1), capi.zf_key_exists(hh, new, new.len));
    var v: c_longlong = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_lng(hh, new, new.len, &v));
    try testing.expectEqual(@as(c_longlong, 7), v);

    // insert_record: build a raw 80-byte card and insert it just before END (the last card).
    var idx_count: c_long = -1;
    try testing.expectEqual(@as(c_int, 0), capi.zf_card_count(hh, &idx_count));
    const end_idx = idx_count - 1;
    var card: [80]u8 = @splat(' ');
    const text = "HISTORY inserted via zf_insert_record";
    @memcpy(card[0..text.len], text);
    try testing.expectEqual(@as(c_int, 0), capi.zf_insert_record(hh, end_idx, &card));
    var got: [80]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_card(hh, end_idx, &got));
    try testing.expectEqualStrings(text, std.mem.trimEnd(u8, &got, " "));
}

test "HDU navigation: move, select_by_name (default EXTVER=1), and current_hdu" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null)); // HDU 1

    const ttype = [_]?[*:0]const u8{"A"};
    const tform = [_]?[*:0]const u8{"1J"};
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 0, 1, 1, &ttype, &tform, null, "ONE")); // HDU 2
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 0, 1, 1, &ttype, &tform, null, "TWO")); // HDU 3

    var cur: c_long = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_current_hdu(hh, &cur));
    try testing.expectEqual(@as(c_long, 3), cur); // appendHdu leaves the new HDU current

    try testing.expectEqual(@as(c_int, 0), capi.zf_move(hh, -2));
    try testing.expectEqual(@as(c_int, 0), capi.zf_current_hdu(hh, &cur));
    try testing.expectEqual(@as(c_long, 1), cur);

    const name = "TWO";
    try testing.expectEqual(@as(c_int, 0), capi.zf_select_by_name(hh, name, name.len, 1, 1)); // EXTVER defaults to 1 when absent
    try testing.expectEqual(@as(c_int, 0), capi.zf_current_hdu(hh, &cur));
    try testing.expectEqual(@as(c_long, 3), cur);

    // Moving past the first HDU is a typed error, not UB.
    try testing.expectEqual(@as(c_int, 0), capi.zf_select(hh, 1));
    try testing.expect(capi.zf_move(hh, -1) != 0);
}

test "copy_hdu duplicates a table HDU; delete_hdu removes one and preserves survivors' data" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null)); // HDU 1

    const ttype = [_]?[*:0]const u8{"V"};
    const tform = [_]?[*:0]const u8{"1J"};
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 0, 2, 1, &ttype, &tform, null, "SRC")); // HDU 2
    var t: ?*abi.TableHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
    var vals = [_]i32{ 11, 22 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col(t.?, I32, 0, 1, 2, null, &vals));
    capi.zf_table_close(t);

    // Copy HDU 2 to the end -> HDU 3, an exact duplicate.
    try testing.expectEqual(@as(c_int, 0), capi.zf_copy_hdu(hh, 2));
    var count: c_long = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_hdu_count(hh, &count));
    try testing.expectEqual(@as(c_long, 3), count);

    try testing.expectEqual(@as(c_int, 0), capi.zf_select(hh, 3));
    var t2: ?*abi.TableHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t2));
    var out = [_]i32{ 0, 0 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col(t2.?, I32, 0, 1, 2, null, &out));
    try testing.expectEqualSlices(i32, &vals, &out);
    capi.zf_table_close(t2);

    // Copying/deleting the primary HDU is rejected.
    try testing.expect(capi.zf_copy_hdu(hh, 1) != 0);
    try testing.expect(capi.zf_delete_hdu(hh, 1) != 0);

    // Delete the original HDU 2; HDU 3's data (now HDU 2) must survive intact.
    try testing.expectEqual(@as(c_int, 0), capi.zf_delete_hdu(hh, 2));
    try testing.expectEqual(@as(c_int, 0), capi.zf_hdu_count(hh, &count));
    try testing.expectEqual(@as(c_long, 2), count);
    try testing.expectEqual(@as(c_int, 0), capi.zf_select(hh, 2));
    var t3: ?*abi.TableHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t3));
    var out2 = [_]i32{ 0, 0 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col(t3.?, I32, 0, 1, 2, null, &out2));
    try testing.expectEqualSlices(i32, &vals, &out2);
    capi.zf_table_close(t3);
}

test "resize_img redefines geometry; the reshaped image accepts fresh pixel data" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    const axes = [_]c_long{ 2, 2 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 16, 2, &axes));
    var small = [_]i16{ 1, 2, 3, 4 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, I16, 1, 4, null, null, &small));

    const new_axes = [_]c_long{ 3, 3 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_resize_img(hh, 32, 2, &new_axes));

    var bitpix: c_int = 0;
    var naxis: c_int = 0;
    var got: [9]c_long = undefined;
    var filled: c_int = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_img_param(hh, &bitpix, &naxis, &got, 9, &filled));
    try testing.expectEqual(@as(c_int, 32), bitpix);
    try testing.expectEqual(@as(c_long, 3), got[0]);
    try testing.expectEqual(@as(c_long, 3), got[1]);

    var big: [9]i32 = undefined;
    for (&big, 0..) |*p, i| p.* = @intCast(100 + i);
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, I32, 1, 9, null, null, &big));
    var out: [9]i32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(hh, I32, 1, 9, null, null, &out));
    try testing.expectEqualSlices(i32, &big, &out);
}

test "write_subset round-trips a rectangular section" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    const axes = [_]c_long{ 4, 4 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 32, 2, &axes));
    var zero: [16]i32 = @splat(0);
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, I32, 1, 16, null, null, &zero));

    const lo = [_]c_long{ 1, 1 };
    const hi = [_]c_long{ 2, 2 };
    var patch = [_]i32{ 100, 101, 102, 103 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_subset(hh, I32, 2, &lo, &hi, null, 4, null, null, &patch));

    var full: [16]i32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(hh, I32, 1, 16, null, null, &full));
    // 4x4, axis 0 fastest-varying: rows 1,2 of cols 1,2 -> flat indices 5,6,9,10.
    try testing.expectEqual(@as(i32, 100), full[5]);
    try testing.expectEqual(@as(i32, 101), full[6]);
    try testing.expectEqual(@as(i32, 102), full[9]);
    try testing.expectEqual(@as(i32, 103), full[10]);
    try testing.expectEqual(@as(i32, 0), full[0]); // untouched corner stays zero
}

test "ZfScaling: an explicit override changes both write encoding and read decoding" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    const axes = [_]c_long{4};
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 32, 1, &axes));

    // Write with BSCALE=2, BZERO=10 (per-call override, not persisted to the header): physical
    // = 10 + 2*stored, so physical {10,12,14,16} stores as {0,1,2,3}.
    const sc = abi.ZfScaling{ .bscale = 2, .bzero = 10 };
    var phys = [_]f64{ 10, 12, 14, 16 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, F64, 1, 4, null, &sc, &phys));

    // No BSCALE/BZERO cards exist on this image, so a default (no-override) read resolves to
    // identity scaling and returns the raw stored ints unscaled.
    var raw: [4]i32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(hh, I32, 1, 4, null, null, &raw));
    try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3 }, &raw);

    // Reading with the same override recovers the physical values.
    var out: [4]f64 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(hh, F64, 1, 4, null, &sc, &out));
    try testing.expectEqualSlices(f64, &phys, &out);

    // raw != 0 forces stored-value exposure even when a BSCALE/BZERO override is also given.
    const sc_raw = abi.ZfScaling{ .bscale = 2, .bzero = 10, .raw = 1 };
    var out_raw: [4]f64 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(hh, F64, 1, 4, null, &sc_raw, &out_raw));
    try testing.expectEqualSlices(f64, &.{ 0, 1, 2, 3 }, &out_raw);
}

test "table row mutation: append_rows, insert_rows, delete_rows" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    const ttype = [_]?[*:0]const u8{"V"};
    const tform = [_]?[*:0]const u8{"1J"};
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 0, 3, 1, &ttype, &tform, null, "T"));
    var t: ?*abi.TableHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
    defer capi.zf_table_close(t);
    const th = t.?;

    var init_vals = [_]i32{ 1, 2, 3 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col(th, I32, 0, 1, 3, null, &init_vals));

    try testing.expectEqual(@as(c_int, 0), capi.zf_append_rows(th, 2));
    var nrows: c_longlong = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_nrows(th, &nrows));
    try testing.expectEqual(@as(c_longlong, 5), nrows);
    var appended = [_]i32{ 40, 50 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col(th, I32, 0, 4, 2, null, &appended));

    // Insert 1 empty row before 0-based row 1 (between values 1 and 2).
    try testing.expectEqual(@as(c_int, 0), capi.zf_insert_rows(th, 1, 1));
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_nrows(th, &nrows));
    try testing.expectEqual(@as(c_longlong, 6), nrows);
    var mid = [_]i32{99};
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col(th, I32, 0, 2, 1, null, &mid));

    var all: [6]i32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col(th, I32, 0, 1, 6, null, &all));
    try testing.expectEqualSlices(i32, &.{ 1, 99, 2, 3, 40, 50 }, &all);

    // Delete 2 rows starting at 0-based row 0 (drop the first two).
    try testing.expectEqual(@as(c_int, 0), capi.zf_delete_rows(th, 0, 2));
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_nrows(th, &nrows));
    try testing.expectEqual(@as(c_longlong, 4), nrows);
    var remaining: [4]i32 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col(th, I32, 0, 1, 4, null, &remaining));
    try testing.expectEqualSlices(i32, &.{ 2, 3, 40, 50 }, &remaining);
}

test "table column mutation: insert_col and delete_col" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    const ttype = [_]?[*:0]const u8{ "A", "B" };
    const tform = [_]?[*:0]const u8{ "1J", "1E" };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 0, 2, 2, &ttype, &tform, null, "T"));
    var t: ?*abi.TableHandle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
    defer capi.zf_table_close(t);
    const th = t.?;

    var a = [_]i32{ 1, 2 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col(th, I32, 0, 1, 2, null, &a));
    var b = [_]f32{ 1.5, 2.5 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_col(th, F32, 1, 1, 2, null, &b));

    // Insert a new 16-bit column at position 1 (between A and B).
    try testing.expectEqual(@as(c_int, 0), capi.zf_insert_col(th, 1, "1I", "C"));
    var ncols: c_int = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_ncols(th, &ncols));
    try testing.expectEqual(@as(c_int, 3), ncols);
    var col: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_colnum(th, "B", 1, &col));
    try testing.expectEqual(@as(c_int, 2), col); // B shifted from 1 -> 2

    // A and B's data survive the insert untouched.
    var a_out = [_]i32{ 0, 0 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col(th, I32, 0, 1, 2, null, &a_out));
    try testing.expectEqualSlices(i32, &a, &a_out);
    var b_out = [_]f32{ 0, 0 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_col(th, F32, 2, 1, 2, null, &b_out));
    try testing.expectEqualSlices(f32, &b, &b_out);

    // Delete the inserted column; back to 2 columns, B is again column 1.
    try testing.expectEqual(@as(c_int, 0), capi.zf_delete_col(th, 1));
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_ncols(th, &ncols));
    try testing.expectEqual(@as(c_int, 2), ncols);
    try testing.expectEqual(@as(c_int, 0), capi.zf_table_colnum(th, "B", 1, &col));
    try testing.expectEqual(@as(c_int, 1), col);
}

test "zf_table_col_unit: ASCII tables surface TUNITn; binary tables do not (documented gap)" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null));

    // ASCII table with a unit.
    {
        const ttype = [_]?[*:0]const u8{"FLUX"};
        const tform = [_]?[*:0]const u8{"F10.3"};
        const tunit = [_]?[*:0]const u8{"Jy"};
        try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 1, 1, 1, &ttype, &tform, &tunit, "AT"));
        var t: ?*abi.TableHandle = null;
        try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
        defer capi.zf_table_close(t);
        var buf: [16]u8 = undefined;
        var len: usize = 0;
        try testing.expectEqual(@as(c_int, 0), capi.zf_table_col_unit(t.?, 0, &buf, buf.len, &len));
        try testing.expectEqualStrings("Jy", buf[0..len]);
    }

    // Binary table: `createTbl` writes TUNITn to the header for both table kinds, but
    // `BinTable`'s column model does not currently parse/expose TUNITn, so
    // `zf_table_col_unit` always reports an empty string for binary tables (status 0, not an
    // error). This is a real limitation in the library, not a bug in this test — it pins the
    // actual observed behavior so a silent regression (or fix) is visible.
    {
        const ttype = [_]?[*:0]const u8{"FLUX"};
        const tform = [_]?[*:0]const u8{"1E"};
        const tunit = [_]?[*:0]const u8{"Jy"};
        try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 0, 1, 1, &ttype, &tform, &tunit, "BT"));
        var t: ?*abi.TableHandle = null;
        try testing.expectEqual(@as(c_int, 0), capi.zf_table_open(hh, &t));
        defer capi.zf_table_close(t);
        var buf: [16]u8 = undefined;
        var len: usize = 99;
        try testing.expectEqual(@as(c_int, 0), capi.zf_table_col_unit(t.?, 0, &buf, buf.len, &len));
        try testing.expectEqual(@as(usize, 0), len);

        // Confirm TUNIT1 really was written to the header: the gap is in the column-model
        // read path (zf_table_col_unit), not in table creation.
        var v: [16]u8 = undefined;
        var vlen: usize = 0;
        const key = "TUNIT1";
        try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_str(hh, key, key.len, &v, v.len, &vlen));
        try testing.expectEqualStrings("Jy", v[0..vlen]);
    }
}

test "zf_update_chksum_all recomputes every HDU's integrity keywords; zf_datasum agrees with DATASUM" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    const axes = [_]c_long{4};
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 32, 1, &axes)); // HDU 1
    var pix = [_]i32{ 1, 2, 3, 4 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, I32, 1, 4, null, null, &pix));
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_chksum(hh)); // seed integrity cards on HDU 1

    const ttype = [_]?[*:0]const u8{"V"};
    const tform = [_]?[*:0]const u8{"1J"};
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 0, 1, 1, &ttype, &tform, null, "T")); // HDU 2
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_chksum(hh)); // seed integrity cards on HDU 2

    // Mutate HDU 1's data after its checksum was written, so the stale cards now mismatch,
    // then let zf_update_chksum_all recompute every HDU that already carries them.
    try testing.expectEqual(@as(c_int, 0), capi.zf_select(hh, 1));
    var pix2 = [_]i32{ 9, 9, 9, 9 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, I32, 1, 4, null, null, &pix2));

    var csum: c_int = -99;
    var dsum: c_int = -99;
    try testing.expectEqual(@as(c_int, 0), capi.zf_verify_chksum(hh, &csum, &dsum));
    try testing.expectEqual(@as(c_int, -1), dsum); // stale: mismatch after the mutation

    try testing.expectEqual(@as(c_int, 0), capi.zf_update_chksum_all(hh));
    try testing.expectEqual(@as(c_int, 0), capi.zf_verify_chksum(hh, &csum, &dsum));
    try testing.expectEqual(@as(c_int, 1), csum);
    try testing.expectEqual(@as(c_int, 1), dsum);

    // zf_datasum reports the raw 32-bit data-unit sum directly; DATASUM is written as an
    // unsigned *decimal string* card (FR-SUM-1), so read it back with zf_read_key_str (not
    // zf_read_key_lng, which cannot parse a quoted-string-valued card) and compare.
    var raw_sum: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), capi.zf_datasum(hh, &raw_sum));
    var dsbuf: [24]u8 = undefined;
    var dslen: usize = 0;
    const dskey = "DATASUM";
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_key_str(hh, dskey, dskey.len, &dsbuf, dsbuf.len, &dslen));
    const card_sum = try std.fmt.parseUnsigned(u64, dsbuf[0..dslen], 10);
    try testing.expectEqual(raw_sum, card_sum);

    try testing.expectEqual(@as(c_int, 0), capi.zf_select(hh, 2));
    try testing.expectEqual(@as(c_int, 0), capi.zf_verify_chksum(hh, &csum, &dsum));
    try testing.expectEqual(@as(c_int, 1), csum);
    try testing.expectEqual(@as(c_int, 1), dsum);
}

fn readFileAllocForTest(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const size = try file.length(io);
    const buf = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

test "zf_save_gzip writes a real .fits.gz that zf_open_gzip reads back byte-for-byte" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    const hh = h.?;
    const axes = [_]c_long{ 3, 2 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 16, 2, &axes));
    var pix = [_]i16{ 10, 20, 30, 40, 50, 60 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_img(hh, I16, 1, 6, null, null, &pix));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, ".zig-cache/tmp/{s}/capi_out.fits.gz", .{tmp.sub_path});
    try testing.expectEqual(@as(c_int, 0), capi.zf_save_gzip(hh, path.ptr, path.len));
    capi.zf_close(hh);

    const bytes = try readFileAllocForTest(testing.allocator, path);
    defer testing.allocator.free(bytes);

    var h2: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_open_gzip(bytes.ptr, bytes.len, null, &h2));
    defer capi.zf_close(h2);
    try testing.expectEqual(@as(c_int, 0), capi.zf_select(h2.?, 1));
    var out: [6]i16 = undefined;
    try testing.expectEqual(@as(c_int, 0), capi.zf_read_img(h2.?, I16, 1, 6, null, null, &out));
    try testing.expectEqualSlices(i16, &pix, &out);
}

test "ZfOpenOpts.max_naxis_product rejects an oversized image before allocation" {
    var opts = abi.ZfOpenOpts{ .max_naxis_product = 10 };
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(&opts, &h));
    defer capi.zf_close(h);
    const hh = h.?;

    // 4x4 = 16 pixels exceeds the 10-pixel ceiling: rejected before any allocation.
    const axes = [_]c_long{ 4, 4 };
    try testing.expect(capi.zf_create_img(hh, 16, 2, &axes) != 0);
    try testing.expectEqual(@as(c_int, 412), capi.zf_last_status()); // OVERFLOW_ERR (nearest: LimitExceeded)

    // A within-limit image (3x3 = 9 <= 10) is accepted.
    const small_axes = [_]c_long{ 3, 3 };
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 16, 2, &small_axes));
}

test "zf_img_param rejects hostile Z* geometry keywords with an error, never a trap" {
    var h: ?*Handle = null;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_memory(null, &h));
    defer capi.zf_close(h);
    const hh = h.?;
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_img(hh, 8, 0, null)); // primary

    // A binary table posing as a tile-compressed image: ZIMAGE = T with hostile Z* geometry.
    const ttype = [_]?[*:0]const u8{"COMPRESSED_DATA"};
    const tform = [_]?[*:0]const u8{"1J"};
    try testing.expectEqual(@as(c_int, 0), capi.zf_create_tbl(hh, 0, 1, 1, &ttype, &tform, null, "COMP"));
    const zim = "ZIMAGE";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_log(hh, zim, zim.len, 1, null, 0));

    var bitpix: c_int = 0;
    var naxis: c_int = 0;
    var got: [9]c_long = undefined;
    var filled: c_int = 0;

    // ZBITPIX far outside i32: the c_int out-param cannot hold it — error, not a trap
    // (nor ReleaseFast truncation).
    const zbp = "ZBITPIX";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, zbp, zbp.len, 1 << 40, null, 0));
    try testing.expect(capi.zf_img_param(hh, &bitpix, &naxis, &got, 9, &filled) != 0);
    try testing.expectEqual(@as(c_int, 211), capi.zf_last_status()); // BAD_BITPIX

    // In-range but illegal BITPIX value.
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, zbp, zbp.len, 7, null, 0));
    try testing.expect(capi.zf_img_param(hh, &bitpix, &naxis, &got, 9, &filled) != 0);
    try testing.expectEqual(@as(c_int, 211), capi.zf_last_status()); // BAD_BITPIX

    // Legal ZBITPIX from here on; hostile axes next.
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, zbp, zbp.len, 16, null, 0));
    const zn = "ZNAXIS";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, zn, zn.len, 1, null, 0));

    // Negative ZNAXISn: error on every platform (mirrors the decompression path's BadTiling).
    const zn1 = "ZNAXIS1";
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, zn1, zn1.len, -5, null, 0));
    try testing.expect(capi.zf_img_param(hh, &bitpix, &naxis, &got, 9, &filled) != 0);
    try testing.expectEqual(@as(c_int, 413), capi.zf_last_status()); // DATA_COMPRESSION_ERR

    // ZNAXIS present but out of range: error like the decompression path, not a silent
    // zero-axis report.
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, zn, zn.len, -1, null, 0));
    try testing.expect(capi.zf_img_param(hh, &bitpix, &naxis, &got, 9, &filled) != 0);
    try testing.expectEqual(@as(c_int, 413), capi.zf_last_status()); // DATA_COMPRESSION_ERR
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, zn, zn.len, 5000, null, 0));
    try testing.expect(capi.zf_img_param(hh, &bitpix, &naxis, &got, 9, &filled) != 0);
    try testing.expectEqual(@as(c_int, 413), capi.zf_last_status()); // DATA_COMPRESSION_ERR

    // ZNAXIS = 0 stays legal (zero-dimensional): success with zero axes reported.
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, zn, zn.len, 0, null, 0));
    try testing.expectEqual(@as(c_int, 0), capi.zf_img_param(hh, &bitpix, &naxis, &got, 9, &filled));
    try testing.expectEqual(@as(c_int, 0), naxis);
    try testing.expectEqual(@as(c_int, 0), filled);

    // Restore a valid ZNAXIS for the wide-axis case below.
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, zn, zn.len, 1, null, 0));

    // ZNAXISn above 2^31: reported faithfully where c_long is 64-bit, an error where it is
    // 32-bit (Windows LLP64, wasm32) — the ABI cannot represent the value there.
    try testing.expectEqual(@as(c_int, 0), capi.zf_write_key_lng(hh, zn1, zn1.len, 1 << 40, null, 0));
    if (@sizeOf(c_long) == 8) {
        try testing.expectEqual(@as(c_int, 0), capi.zf_img_param(hh, &bitpix, &naxis, &got, 9, &filled));
        try testing.expectEqual(@as(c_int, 16), bitpix);
        try testing.expectEqual(@as(c_int, 1), naxis);
        try testing.expectEqual(@as(c_long, 1 << 40), got[0]);
    } else {
        try testing.expect(capi.zf_img_param(hh, &bitpix, &naxis, &got, 9, &filled) != 0);
        try testing.expectEqual(@as(c_int, 213), capi.zf_last_status()); // BAD_NAXES
    }
}
