//! Celestial coordinate transforms: pixel ↔ world (FR-WCS-2, §18.2; FITS 4.0 §8.3, Table 23).
//!
//! Implements the zenithal (azimuthal) projection family — `TAN` (gnomonic), `SIN`
//! (orthographic), `ARC` (zenithal equidistant), `STG` (stereographic), and `ZEA` (zenithal
//! equal-area) — plus the plate carrée `CAR`, following Calabretta & Greisen (2002). The full
//! pipeline is: pixel → intermediate world coords (CRPIX offset, `PCi_j`/`CDi_j` matrix,
//! `CDELT`) → native spherical (the projection's deprojection) → celestial (spherical rotation
//! by `CRVAL`/`LONPOLE`). An unimplemented projection is `error.UnsupportedProjection`. The
//! registry is extensible; reference-point accuracy against WCSLIB/astropy is pinned by
//! X-FIXTURES, while pixel→world→pixel round-trips are checked here.
const std = @import("std");
const WcsError = @import("../errors.zig").WcsError;
const Wcs = @import("keys.zig").Wcs;

const DEG2RAD: f64 = std.math.pi / 180.0;
const RAD2DEG: f64 = 180.0 / std.math.pi;
const R0: f64 = 180.0 / std.math.pi; // the projection radius scale (degrees per radian)

/// Supported projection codes (the trailing 3 letters of `CTYPEi`).
pub const Projection = enum {
    tan,
    sin,
    arc,
    stg,
    zea,
    car,

    /// Parse the 3-letter projection code from a `CTYPEi` value (e.g. `RA---TAN` → `.tan`).
    pub fn fromCtype(ctype: []const u8) ?Projection {
        if (ctype.len < 3) return null;
        const code = ctype[ctype.len - 3 ..];
        var up: [3]u8 = undefined;
        for (code, 0..) |c, i| up[i] = std.ascii.toUpper(c);
        const s = up[0..];
        if (std.mem.eql(u8, s, "TAN")) return .tan;
        if (std.mem.eql(u8, s, "SIN")) return .sin;
        if (std.mem.eql(u8, s, "ARC")) return .arc;
        if (std.mem.eql(u8, s, "STG")) return .stg;
        if (std.mem.eql(u8, s, "ZEA")) return .zea;
        if (std.mem.eql(u8, s, "CAR")) return .car;
        return null;
    }
};

/// A celestial transform derived from a 2-axis `Wcs`: the reference pixel/value, the linear
/// transform, the projection, and the rotation parameters. Built by `fromWcs`.
pub const Celestial = struct {
    proj: Projection,
    /// Index of the longitude axis (0) and latitude axis (1) in the WCS.
    lon_axis: usize = 0,
    lat_axis: usize = 1,
    crpix: [2]f64,
    crval: [2]f64, // [lon0, lat0] degrees
    lonpole: f64, // degrees
    /// The 2×2 linear transform (intermediate = M · (pixel − CRPIX)), absorbing CDELT.
    m: [2][2]f64,
    /// Inverse of `m`.
    minv: [2][2]f64,

    /// Build a celestial transform from a parsed `Wcs`. Requires ≥2 axes whose `CTYPEi` carry
    /// a supported projection. `error.UnsupportedProjection` / `error.BadWcs` otherwise.
    pub fn fromWcs(w: *const Wcs) WcsError!Celestial {
        if (w.axes < 2) return error.BadWcs;
        // Identify lon/lat axes by CTYPE prefix; default to (0,1).
        var lon: usize = 0;
        var lat: usize = 1;
        if (isLat(w.ctype[0]) and isLon(w.ctype[1])) {
            lon = 1;
            lat = 0;
        }
        const proj = Projection.fromCtype(w.ctype[lon]) orelse return error.UnsupportedProjection;

        // Build the 2×2 linear transform M absorbing CDELT (PC) or using CD directly.
        var m: [2][2]f64 = undefined;
        switch (w.transform) {
            .cd => |cd| {
                m = .{ .{ cd[lon][lon], cd[lon][lat] }, .{ cd[lat][lon], cd[lat][lat] } };
            },
            .pc => |pc| {
                m = .{
                    .{ w.cdelt[lon] * pc[lon][lon], w.cdelt[lon] * pc[lon][lat] },
                    .{ w.cdelt[lat] * pc[lat][lon], w.cdelt[lat] * pc[lat][lat] },
                };
            },
            .none => {
                m = .{ .{ w.cdelt[lon], 0 }, .{ 0, w.cdelt[lat] } };
            },
        }
        const det = m[0][0] * m[1][1] - m[0][1] * m[1][0];
        if (det == 0) return error.NonInvertible;
        const minv: [2][2]f64 = .{
            .{ m[1][1] / det, -m[0][1] / det },
            .{ -m[1][0] / det, m[0][0] / det },
        };

        return .{
            .proj = proj,
            .lon_axis = lon,
            .lat_axis = lat,
            .crpix = .{ w.crpix[lon], w.crpix[lat] },
            .crval = .{ w.crval[lon], w.crval[lat] },
            .lonpole = w.lonpole orelse 180.0, // zenithal default
            .m = m,
            .minv = minv,
        };
    }

    /// Convert a pixel coordinate `[lon_pix, lat_pix]` (1-based, per FITS CRPIX) to celestial
    /// `[lon_deg, lat_deg]`.
    pub fn pixelToWorld(self: *const Celestial, pix: [2]f64) WcsError![2]f64 {
        // 1. pixel → intermediate world coordinates (degrees).
        const q0 = pix[0] - self.crpix[0];
        const q1 = pix[1] - self.crpix[1];
        const x = self.m[0][0] * q0 + self.m[0][1] * q1;
        const y = self.m[1][0] * q0 + self.m[1][1] * q1;
        // 2. deproject → native (phi, theta) radians.
        const nt = try self.deproject(x, y);
        // 3. native → celestial.
        return self.nativeToCelestial(nt.phi, nt.theta);
    }

    /// Convert celestial `[lon_deg, lat_deg]` to a pixel coordinate `[lon_pix, lat_pix]`.
    pub fn worldToPixel(self: *const Celestial, world: [2]f64) WcsError![2]f64 {
        const nt = self.celestialToNative(world[0], world[1]);
        const xy = try self.project(nt.phi, nt.theta);
        // Invert the linear transform.
        const q0 = self.minv[0][0] * xy.x + self.minv[0][1] * xy.y;
        const q1 = self.minv[1][0] * xy.x + self.minv[1][1] * xy.y;
        return .{ q0 + self.crpix[0], q1 + self.crpix[1] };
    }

    const Native = struct { phi: f64, theta: f64 }; // radians
    const Plane = struct { x: f64, y: f64 }; // degrees

    // Deproject intermediate (x,y) degrees → native (phi, theta) radians.
    fn deproject(self: *const Celestial, x: f64, y: f64) WcsError!Native {
        if (self.proj == .car) {
            return .{ .phi = x * DEG2RAD, .theta = y * DEG2RAD };
        }
        const r = std.math.hypot(x, y); // degrees
        const phi = if (r == 0) 0 else std.math.atan2(x, -y);
        const theta = switch (self.proj) {
            .tan => std.math.atan2(R0, r), // radians
            .sin => std.math.acos(clamp(r / R0, -1, 1)),
            .arc => (90.0 - r) * DEG2RAD,
            .stg => std.math.pi / 2.0 - 2.0 * std.math.atan(r / (2.0 * R0)),
            .zea => std.math.pi / 2.0 - 2.0 * std.math.asin(clamp(r / (2.0 * R0), -1, 1)),
            .car => unreachable,
        };
        return .{ .phi = phi, .theta = theta };
    }

    // Project native (phi, theta) radians → intermediate (x,y) degrees.
    fn project(self: *const Celestial, phi: f64, theta: f64) WcsError!Plane {
        if (self.proj == .car) {
            return .{ .x = phi * RAD2DEG, .y = theta * RAD2DEG };
        }
        const r: f64 = switch (self.proj) {
            .tan => if (theta <= 0) return error.NonInvertible else R0 / std.math.tan(theta),
            .sin => R0 * std.math.cos(theta),
            .arc => 90.0 - theta * RAD2DEG,
            .stg => 2.0 * R0 * std.math.tan((std.math.pi / 2.0 - theta) / 2.0),
            .zea => 2.0 * R0 * std.math.sin((std.math.pi / 2.0 - theta) / 2.0),
            .car => unreachable,
        };
        return .{ .x = r * std.math.sin(phi), .y = -r * std.math.cos(phi) };
    }

    // Native (phi,theta radians) → celestial (deg), rotation about the native pole = reference
    // point for zenithal/CAR with the standard equations.
    fn nativeToCelestial(self: *const Celestial, phi: f64, theta: f64) [2]f64 {
        const ap = self.crval[0] * DEG2RAD;
        const dp = self.crval[1] * DEG2RAD;
        const phip = self.lonpole * DEG2RAD;
        const dphi = phi - phip;
        const sin_t = std.math.sin(theta);
        const cos_t = std.math.cos(theta);
        const dec = std.math.asin(clamp(sin_t * std.math.sin(dp) + cos_t * std.math.cos(dp) * std.math.cos(dphi), -1, 1));
        const ra = ap + std.math.atan2(-cos_t * std.math.sin(dphi), sin_t * std.math.cos(dp) - cos_t * std.math.sin(dp) * std.math.cos(dphi));
        return .{ norm360(ra * RAD2DEG), dec * RAD2DEG };
    }

    // Celestial (deg) → native (phi,theta radians), the inverse rotation.
    fn celestialToNative(self: *const Celestial, lon: f64, lat: f64) Native {
        const ap = self.crval[0] * DEG2RAD;
        const dp = self.crval[1] * DEG2RAD;
        const phip = self.lonpole * DEG2RAD;
        const ra = lon * DEG2RAD;
        const dec = lat * DEG2RAD;
        const dra = ra - ap;
        const sin_d = std.math.sin(dec);
        const cos_d = std.math.cos(dec);
        const theta = std.math.asin(clamp(sin_d * std.math.sin(dp) + cos_d * std.math.cos(dp) * std.math.cos(dra), -1, 1));
        const phi = phip + std.math.atan2(-cos_d * std.math.sin(dra), sin_d * std.math.cos(dp) - cos_d * std.math.sin(dp) * std.math.cos(dra));
        return .{ .phi = phi, .theta = theta };
    }
};

fn isLon(ct: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(ct, "RA") or std.ascii.startsWithIgnoreCase(ct, "GLON") or std.ascii.startsWithIgnoreCase(ct, "ELON");
}
fn isLat(ct: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(ct, "DEC") or std.ascii.startsWithIgnoreCase(ct, "GLAT") or std.ascii.startsWithIgnoreCase(ct, "ELAT");
}
fn clamp(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(hi, v));
}
fn norm360(d: f64) f64 {
    var x = @mod(d, 360.0);
    if (x < 0) x += 360.0;
    return x;
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const Header = @import("../header/header.zig").Header;
const block = @import("../io/block.zig");
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;

fn wcsFromCards(a: std.mem.Allocator, cards: []const []const u8) !struct { w: Wcs, h: Header, mem: *MemoryDevice, reader: *block.BlockReader } {
    const mem = try a.create(MemoryDevice);
    var buf: [block.BLOCK]u8 = [_]u8{' '} ** block.BLOCK;
    for (cards, 0..) |c, i| @memcpy(buf[i * 80 ..][0..c.len], c);
    @memcpy(buf[cards.len * 80 ..][0..3], "END");
    mem.* = try MemoryDevice.initBytes(a, &buf);
    const reader = try a.create(block.BlockReader);
    reader.* = try block.BlockReader.init(a, mem.device(), 0);
    const res = try Header.parse(a, reader, 0, 36);
    var h = res.header;
    const w = try Wcs.fromHeader(a, &h, ' ');
    return .{ .w = w, .h = h, .mem = mem, .reader = reader };
}

fn cleanup(a: std.mem.Allocator, p: anytype) void {
    var w = p.w;
    w.deinit(a);
    var h = p.h;
    h.deinit(a);
    p.reader.deinit();
    a.destroy(p.reader);
    p.mem.deinit();
    a.destroy(p.mem);
}

test "TAN: reference pixel maps to CRVAL; pixel→world→pixel round-trips" {
    var p = try wcsFromCards(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---TAN'",
        "CTYPE2  = 'DEC--TAN'",
        "CRPIX1  =                256.0",
        "CRPIX2  =                256.0",
        "CRVAL1  =                150.0",
        "CRVAL2  =                  2.5",
        "CDELT1  =            -0.000277",
        "CDELT2  =             0.000277",
    });
    defer cleanup(testing.allocator, p);
    var c = try Celestial.fromWcs(&p.w);

    // Reference pixel → CRVAL.
    const w0 = try c.pixelToWorld(.{ 256.0, 256.0 });
    try testing.expect(@abs(w0[0] - 150.0) < 1e-9);
    try testing.expect(@abs(w0[1] - 2.5) < 1e-9);

    // Round-trip several off-center pixels.
    const pts = [_][2]f64{ .{ 100, 100 }, .{ 300, 400 }, .{ 256, 1 }, .{ 511, 511 } };
    for (pts) |pt| {
        const world = try c.pixelToWorld(pt);
        const back = try c.worldToPixel(world);
        try testing.expect(@abs(back[0] - pt[0]) < 1e-6);
        try testing.expect(@abs(back[1] - pt[1]) < 1e-6);
    }
}

test "each zenithal projection round-trips pixel→world→pixel" {
    inline for (.{ "TAN", "SIN", "ARC", "STG", "ZEA" }) |code| {
        var p = try wcsFromCards(testing.allocator, &.{
            "WCSAXES =                    2",
            "CTYPE1  = 'RA---" ++ code ++ "'",
            "CTYPE2  = 'DEC--" ++ code ++ "'",
            "CRPIX1  =                100.0",
            "CRPIX2  =                100.0",
            "CRVAL1  =                 80.0",
            "CRVAL2  =                 45.0",
            "CDELT1  =               -0.001",
            "CDELT2  =                0.001",
        });
        defer cleanup(testing.allocator, p);
        var c = try Celestial.fromWcs(&p.w);
        const pt: [2]f64 = .{ 120.0, 130.0 };
        const world = try c.pixelToWorld(pt);
        const back = try c.worldToPixel(world);
        try testing.expect(@abs(back[0] - pt[0]) < 1e-5);
        try testing.expect(@abs(back[1] - pt[1]) < 1e-5);
    }
}

test "CAR plate carrée and axis order detection (DEC first)" {
    var p = try wcsFromCards(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'DEC--CAR'",
        "CTYPE2  = 'RA---CAR'",
        "CRPIX1  =                  1.0",
        "CRPIX2  =                  1.0",
        "CRVAL1  =                  0.0",
        "CRVAL2  =                  0.0",
        "CDELT1  =                  1.0",
        "CDELT2  =                  1.0",
    });
    defer cleanup(testing.allocator, p);
    var c = try Celestial.fromWcs(&p.w);
    try testing.expectEqual(@as(usize, 1), c.lon_axis); // RA is axis 2 (index 1)
    const pt: [2]f64 = .{ 5.0, 7.0 };
    const world = try c.pixelToWorld(pt);
    const back = try c.worldToPixel(world);
    try testing.expect(@abs(back[0] - pt[0]) < 1e-6);
    try testing.expect(@abs(back[1] - pt[1]) < 1e-6);
}

test "unsupported projection is a typed error" {
    var p = try wcsFromCards(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---AIT'",
        "CTYPE2  = 'DEC--AIT'",
        "CRVAL1  =                  0.0",
        "CRVAL2  =                  0.0",
    });
    defer cleanup(testing.allocator, p);
    try testing.expectError(error.UnsupportedProjection, Celestial.fromWcs(&p.w));
}
