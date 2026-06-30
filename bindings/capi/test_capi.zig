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
