//! Spectral coordinate keyword handling (FR-WCS-3, §18.2; FITS 4.0 §8.4, Tables 25–27).
//!
//! Parses the spectral WCS keywords for the spectral axis of a header: the spectral `CTYPEi`
//! code and unit, the rest frequency/wavelength (`RESTFRQ`/`RESTWAV`), and the reference frame
//! (`SPECSYS`, plus `SSYSOBS`/`VELOSYS`). It exposes the recognized spectral variable and a
//! linear pixel↔spectral-value mapping (the common case where the chosen spectral variable is
//! linear along the axis). Non-linear spectral algorithm codes (e.g. `FREQ-F2W`) are parsed and
//! their type reported, but resampling between variables is left to higher layers.
const std = @import("std");
const WcsError = @import("../errors.zig").WcsError;
const Header = @import("../header/header.zig").Header;

const Allocator = std.mem.Allocator;

/// The primary spectral variable a `CTYPEi` denotes (the first 4 characters of the code).
pub const SpectralType = enum {
    freq, // FREQ — frequency
    ener, // ENER — energy
    wavn, // WAVN — wavenumber
    vrad, // VRAD — radio velocity
    wave, // WAVE — vacuum wavelength
    vopt, // VOPT — optical velocity
    zopt, // ZOPT — redshift
    awav, // AWAV — air wavelength
    velo, // VELO — apparent radial velocity
    beta, // BETA — beta (v/c)
    unknown,

    pub fn fromCtype(ctype: []const u8) SpectralType {
        if (ctype.len < 4) return .unknown;
        var head: [4]u8 = undefined;
        for (ctype[0..4], 0..) |c, i| head[i] = std.ascii.toUpper(c);
        const s = head[0..];
        const map = .{
            .{ "FREQ", SpectralType.freq }, .{ "ENER", SpectralType.ener },
            .{ "WAVN", SpectralType.wavn }, .{ "VRAD", SpectralType.vrad },
            .{ "WAVE", SpectralType.wave }, .{ "VOPT", SpectralType.vopt },
            .{ "ZOPT", SpectralType.zopt }, .{ "AWAV", SpectralType.awav },
            .{ "VELO", SpectralType.velo }, .{ "BETA", SpectralType.beta },
        };
        inline for (map) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
        return .unknown;
    }

    pub fn isSpectral(ctype: []const u8) bool {
        return fromCtype(ctype) != .unknown;
    }
};

/// A recognized standard spectral reference frame (`SPECSYS`).
pub const RefFrame = enum {
    topocent,
    geocentr,
    barycent,
    heliocen,
    lsrk,
    lsrd,
    galactoc,
    localgrp,
    cmbdipol,
    source,
    unknown,

    pub fn parse(s: []const u8) RefFrame {
        const t = std.mem.trim(u8, s, " ");
        const map = .{
            .{ "TOPOCENT", RefFrame.topocent }, .{ "GEOCENTR", RefFrame.geocentr },
            .{ "BARYCENT", RefFrame.barycent }, .{ "HELIOCEN", RefFrame.heliocen },
            .{ "LSRK", RefFrame.lsrk },         .{ "LSRD", RefFrame.lsrd },
            .{ "GALACTOC", RefFrame.galactoc }, .{ "LOCALGRP", RefFrame.localgrp },
            .{ "CMBDIPOL", RefFrame.cmbdipol }, .{ "SOURCE", RefFrame.source },
        };
        inline for (map) |e| if (std.ascii.eqlIgnoreCase(t, e[0])) return e[1];
        return .unknown;
    }
};

/// Parsed spectral coordinate description for one axis.
pub const Spectral = struct {
    axis: usize, // 0-based axis index of the spectral axis
    type: SpectralType,
    /// The full `CTYPEi` code (owned), e.g. `FREQ` or `VOPT-F2W`.
    ctype: []u8,
    unit: ?[]u8 = null, // CUNITi
    crpix: f64 = 1,
    crval: f64 = 0,
    cdelt: f64 = 1,
    restfrq: ?f64 = null, // Hz
    restwav: ?f64 = null, // m
    specsys: RefFrame = .unknown,
    velosys: ?f64 = null, // m/s

    /// Find and parse the spectral axis of a header (the first axis whose `CTYPEi` is a
    /// recognized spectral type). `error.BadWcs` if there is none.
    pub fn fromHeader(a: Allocator, h: *const Header) (WcsError || std.mem.Allocator.Error)!Spectral {
        const naxis = h.getValue(u16, "WCSAXES") catch (h.getValue(u16, "NAXIS") catch 0);
        var i: usize = 1;
        var buf: [8]u8 = undefined;
        while (i <= naxis) : (i += 1) {
            const name = std.fmt.bufPrint(&buf, "CTYPE{d}", .{i}) catch unreachable;
            const ct = h.getString(a, name) catch continue;
            if (SpectralType.isSpectral(ct)) {
                var self: Spectral = .{
                    .axis = i - 1,
                    .type = SpectralType.fromCtype(ct),
                    .ctype = ct,
                };
                errdefer a.free(self.ctype);
                self.crpix = getIdx(h, "CRPIX", i) orelse 1;
                self.crval = getIdx(h, "CRVAL", i) orelse 0;
                self.cdelt = getIdx(h, "CDELT", i) orelse 1;
                self.unit = getIdxStr(a, h, "CUNIT", i);
                self.restfrq = h.getValue(f64, "RESTFRQ") catch null;
                self.restwav = h.getValue(f64, "RESTWAV") catch null;
                self.velosys = h.getValue(f64, "VELOSYS") catch null;
                if (h.getString(a, "SPECSYS")) |ss| {
                    defer a.free(ss);
                    self.specsys = RefFrame.parse(ss);
                } else |_| {}
                return self;
            } else {
                a.free(ct);
            }
        }
        return error.BadWcs;
    }

    pub fn deinit(self: *Spectral, a: Allocator) void {
        a.free(self.ctype);
        if (self.unit) |u| a.free(u);
    }

    /// The spectral value at 1-based pixel `pix` along the axis (linear: `crval + cdelt*(pix −
    /// crpix)`), in the axis's `CUNITi`.
    pub fn valueAt(self: *const Spectral, pix: f64) f64 {
        return self.crval + self.cdelt * (pix - self.crpix);
    }

    /// The pixel for a given spectral value (inverse of `valueAt`).
    pub fn pixelAt(self: *const Spectral, value: f64) WcsError!f64 {
        if (self.cdelt == 0) return error.NonInvertible;
        return self.crpix + (value - self.crval) / self.cdelt;
    }
};

fn getIdx(h: *const Header, comptime base: []const u8, i: usize) ?f64 {
    var buf: [8]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}{d}", .{ base, i }) catch return null;
    return h.getValue(f64, name) catch null;
}

fn getIdxStr(a: Allocator, h: *const Header, comptime base: []const u8, i: usize) ?[]u8 {
    var buf: [8]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}{d}", .{ base, i }) catch return null;
    return h.getString(a, name) catch null;
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const block = @import("../io/block.zig");
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;

fn headerFrom(a: Allocator, cards: []const []const u8) !struct { h: Header, mem: *MemoryDevice, reader: *block.BlockReader } {
    const mem = try a.create(MemoryDevice);
    var buf: [block.BLOCK]u8 = [_]u8{' '} ** block.BLOCK;
    for (cards, 0..) |c, i| @memcpy(buf[i * 80 ..][0..c.len], c);
    @memcpy(buf[cards.len * 80 ..][0..3], "END");
    mem.* = try MemoryDevice.initBytes(a, &buf);
    const reader = try a.create(block.BlockReader);
    reader.* = try block.BlockReader.init(a, mem.device(), 0);
    const res = try Header.parse(a, reader, 0, 36);
    return .{ .h = res.header, .mem = mem, .reader = reader };
}

fn cleanup(a: Allocator, p: anytype) void {
    var h = p.h;
    h.deinit(a);
    p.reader.deinit();
    a.destroy(p.reader);
    p.mem.deinit();
    a.destroy(p.mem);
}

test "parse a frequency spectral axis and map pixel<->value" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    3",
        "CTYPE1  = 'RA---TAN'",
        "CTYPE2  = 'DEC--TAN'",
        "CTYPE3  = 'FREQ'",
        "CRPIX3  =                  1.0",
        "CRVAL3  =          1.4204058E9",
        "CDELT3  =              62500.0",
        "CUNIT3  = 'Hz'",
        "RESTFRQ =          1.4204058E9",
        "SPECSYS = 'LSRK'",
    });
    defer cleanup(testing.allocator, p);
    var s = try Spectral.fromHeader(testing.allocator, &p.h);
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), s.axis); // 0-based: CTYPE3
    try testing.expectEqual(SpectralType.freq, s.type);
    try testing.expectEqualStrings("Hz", s.unit.?);
    try testing.expectEqual(RefFrame.lsrk, s.specsys);
    try testing.expect(@abs(s.restfrq.? - 1.4204058e9) < 1.0);

    try testing.expect(@abs(s.valueAt(1.0) - 1.4204058e9) < 1.0); // reference pixel
    try testing.expect(@abs(s.valueAt(3.0) - (1.4204058e9 + 2 * 62500.0)) < 1.0);
    const px = try s.pixelAt(1.4204058e9 + 62500.0);
    try testing.expect(@abs(px - 2.0) < 1e-9);
}

test "spectral type and frame recognition" {
    try testing.expectEqual(SpectralType.wave, SpectralType.fromCtype("WAVE-F2W"));
    try testing.expectEqual(SpectralType.vopt, SpectralType.fromCtype("VOPT"));
    try testing.expect(SpectralType.isSpectral("FREQ"));
    try testing.expect(!SpectralType.isSpectral("RA---TAN"));
    try testing.expectEqual(RefFrame.barycent, RefFrame.parse("BARYCENT"));
    try testing.expectEqual(RefFrame.unknown, RefFrame.parse("NOPE"));
}

test "pixelAt with zero cdelt is NonInvertible" {
    // A degenerate spectral axis (CDELT=0) maps every pixel to the same value, so the inverse
    // pixel-from-value map has no solution and must surface error.NonInvertible rather than divide
    // by zero. The forward valueAt is still well-defined (the constant CRVAL).
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    1",
        "CTYPE1  = 'FREQ'",
        "CRPIX1  =                  1.0",
        "CRVAL1  =                  5.0",
        "CDELT1  =                  0.0",
    });
    defer cleanup(testing.allocator, p);
    var s = try Spectral.fromHeader(testing.allocator, &p.h);
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 0), s.cdelt);
    try testing.expectError(error.NonInvertible, s.pixelAt(5.0));
    try testing.expectEqual(@as(f64, 5.0), s.valueAt(42.0)); // forward map stays constant
}

test "no spectral axis is BadWcs" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---TAN'",
        "CTYPE2  = 'DEC--TAN'",
    });
    defer cleanup(testing.allocator, p);
    try testing.expectError(error.BadWcs, Spectral.fromHeader(testing.allocator, &p.h));
}
