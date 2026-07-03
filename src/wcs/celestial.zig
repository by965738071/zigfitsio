//! Celestial coordinate transforms: pixel ↔ world (FR-WCS-2, §18.2; FITS 4.0 §8.3, Table 23).
//!
//! Implements the zenithal (azimuthal) projection family — `TAN` (gnomonic), `SIN`
//! (orthographic), `ARC` (zenithal equidistant), `STG` (stereographic), and `ZEA` (zenithal
//! equal-area) — plus the plate carrée `CAR`, following Calabretta & Greisen (2002). The full
//! pipeline is: pixel → intermediate world coords (CRPIX offset, `PCi_j`/`CDi_j` matrix,
//! `CDELT`) → native spherical (the projection's deprojection) → celestial (spherical rotation
//! about the native pole). An unimplemented projection is `error.UnsupportedProjection`. The
//! registry is extensible; reference-point accuracy is verified here by the `CRPIX`→`CRVAL`
//! self-assertion and pixel→world→pixel round-trips, with external WCSLIB/Astropy golden
//! parity still pending.
//!
//! The native→celestial rotation is parameterised by the celestial coordinates of the native
//! pole `(α_p, δ_p)` together with `LONPOLE` (`φ_p`). These are derived from each projection's
//! fiducial native point `(φ0, θ0)` — `(0°, 90°)` for the zenithal family TAN/SIN/ARC/STG/ZEA,
//! `(0°, 0°)` for the plate carrée CAR — and `CRVAL`/`LONPOLE`/`LATPOLE`, following Calabretta &
//! Greisen (2002), Paper II eqs (8)–(10). For zenithal projections the fiducial point *is* the
//! native pole, so `(α_p, δ_p) = CRVAL`; for CAR the pole is offset and is computed properly,
//! so the reference pixel maps back to `CRVAL` (not to a pole).
//!
//! Conventions and limitations:
//!   * Only the **parameter-free** forms of these projections are implemented. `PVi_m` (parsed
//!     into `Wcs.pv` by `keys.zig`) is **not** consumed here — none of TAN/SIN/ARC/STG/ZEA/CAR
//!     in their standard form take projection parameters, so `PVi_m` is silently ignored.
//!   * The legacy `CROTAi` rotation is honoured **only** when no `PCi_j`/`CDi_j` matrix is
//!     present: `CROTA` on the latitude axis (the classic `CROTA2`) is folded into the linear
//!     transform `M` using the AIPS convention. When a `PC`/`CD` matrix is given, `CROTAi` is
//!     ignored (FITS 4.0 forbids combining them).
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
    crval: [2]f64, // reference value [lon0, lat0] degrees (informational)
    /// Native longitude of the celestial pole (`LONPOLE`, `φ_p`), radians.
    phi_p: f64,
    /// Celestial coordinates of the native pole `(α_p, δ_p)`, radians — the axis of the
    /// native→celestial spherical rotation, derived from the projection's reference point.
    alpha_p: f64,
    delta_p: f64,
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
                // No PCi_j/CDi_j: honour the legacy CROTAi rotation (AIPS convention), taken
                // from the latitude axis (the classic CROTA2). With ρ = CROTA[lat]:
                //   M = [ CDELT_lon·cosρ,  −CDELT_lat·sinρ ;
                //         CDELT_lon·sinρ,   CDELT_lat·cosρ ].
                // ρ = 0 reduces to the plain diagonal CDELT scaling.
                const rho = w.crota[lat] * DEG2RAD;
                const cr = std.math.cos(rho);
                const sr = std.math.sin(rho);
                m = .{
                    .{ w.cdelt[lon] * cr, -w.cdelt[lat] * sr },
                    .{ w.cdelt[lon] * sr, w.cdelt[lat] * cr },
                };
            },
        }
        const det = m[0][0] * m[1][1] - m[0][1] * m[1][0];
        if (det == 0) return error.NonInvertible;
        const minv: [2][2]f64 = .{
            .{ m[1][1] / det, -m[0][1] / det },
            .{ -m[1][0] / det, m[0][0] / det },
        };

        const crval: [2]f64 = .{ w.crval[lon], w.crval[lat] };
        // Resolve the spherical-rotation pole from the projection's fiducial point, applying
        // the projection-correct LONPOLE/LATPOLE defaults (Paper II eqs 8–10).
        const pole = computePole(proj, crval, w.lonpole, w.latpole);

        return .{
            .proj = proj,
            .lon_axis = lon,
            .lat_axis = lat,
            .crpix = .{ w.crpix[lon], w.crpix[lat] },
            .crval = crval,
            .phi_p = pole.phi_p,
            .alpha_p = pole.alpha_p,
            .delta_p = pole.delta_p,
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
            // A pixel beyond the projection limb has no sky preimage. `clamp` would silently
            // fold it onto the limb (a finite, wrong, non-round-tripping coordinate); reject it.
            .sin => if (r > R0) return error.NonInvertible else std.math.acos(clamp(r / R0, -1, 1)),
            // ARC's limb is the antipode at r = 180°; beyond it theta < -90° is non-physical and
            // the rotation would silently alias it onto a wrong, non-round-tripping sky position.
            .arc => if (r > 180.0) return error.NonInvertible else (90.0 - r) * DEG2RAD,
            .stg => std.math.pi / 2.0 - 2.0 * std.math.atan(r / (2.0 * R0)),
            .zea => if (r > 2.0 * R0) return error.NonInvertible else std.math.pi / 2.0 - 2.0 * std.math.asin(clamp(r / (2.0 * R0), -1, 1)),
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
            // SIN only images the theta ≥ 0 hemisphere; a back-hemisphere point is unrepresentable
            // (else r = R0·cos(theta) would alias it onto a front-hemisphere pixel).
            .sin => if (theta < 0) return error.NonInvertible else R0 * std.math.cos(theta),
            .arc => 90.0 - theta * RAD2DEG,
            .stg => 2.0 * R0 * std.math.tan((std.math.pi / 2.0 - theta) / 2.0),
            .zea => 2.0 * R0 * std.math.sin((std.math.pi / 2.0 - theta) / 2.0),
            .car => unreachable,
        };
        return .{ .x = r * std.math.sin(phi), .y = -r * std.math.cos(phi) };
    }

    // Native (phi,theta radians) → celestial (deg). Spherical rotation about the native pole
    // (α_p, δ_p) with native longitude of the celestial pole φ_p (Paper II eq 2).
    fn nativeToCelestial(self: *const Celestial, phi: f64, theta: f64) [2]f64 {
        const dphi = phi - self.phi_p;
        const sin_t = std.math.sin(theta);
        const cos_t = std.math.cos(theta);
        const sin_dp = std.math.sin(self.delta_p);
        const cos_dp = std.math.cos(self.delta_p);
        const dec = std.math.asin(clamp(sin_t * sin_dp + cos_t * cos_dp * std.math.cos(dphi), -1, 1));
        const ra = self.alpha_p + std.math.atan2(-cos_t * std.math.sin(dphi), sin_t * cos_dp - cos_t * sin_dp * std.math.cos(dphi));
        return .{ norm360(ra * RAD2DEG), dec * RAD2DEG };
    }

    // Celestial (deg) → native (phi,theta radians), the inverse rotation (Paper II eq 5).
    fn celestialToNative(self: *const Celestial, lon: f64, lat: f64) Native {
        const ra = lon * DEG2RAD;
        const dec = lat * DEG2RAD;
        const dra = ra - self.alpha_p;
        const sin_d = std.math.sin(dec);
        const cos_d = std.math.cos(dec);
        const sin_dp = std.math.sin(self.delta_p);
        const cos_dp = std.math.cos(self.delta_p);
        const theta = std.math.asin(clamp(sin_d * sin_dp + cos_d * cos_dp * std.math.cos(dra), -1, 1));
        const phi = self.phi_p + std.math.atan2(-cos_d * std.math.sin(dra), sin_d * cos_dp - cos_d * sin_dp * std.math.cos(dra));
        return .{ .phi = phi, .theta = theta };
    }
};

/// The native pole `(α_p, δ_p)` and `φ_p` (LONPOLE) that define the native→celestial rotation,
/// all in radians.
const Pole = struct { phi_p: f64, alpha_p: f64, delta_p: f64 };

/// A projection's fiducial native point `(φ0, θ0)` in **degrees** (Calabretta & Greisen 2002,
/// Paper II, Table 1): `(0, 90)` for the zenithal family, `(0, 0)` for the plate carrée.
fn referencePoint(proj: Projection) struct { phi0: f64, theta0: f64 } {
    return switch (proj) {
        .car => .{ .phi0 = 0, .theta0 = 0 },
        .tan, .sin, .arc, .stg, .zea => .{ .phi0 = 0, .theta0 = 90 },
    };
}

/// Compute the native pole `(α_p, δ_p)` and `φ_p` from the projection's fiducial point
/// `(φ0, θ0)` / `(α0, δ0)=CRVAL` and the optional `LONPOLE`/`LATPOLE`, per Paper II eqs (8)–(10).
/// Projection-correct defaults are applied: `LONPOLE = 0°` if `δ0 ≥ θ0` else `180°`; `LATPOLE
/// = +90°` (which disambiguates the pole toward the north when eq (8) has two roots). Pure trig,
/// never fails — a fully degenerate configuration falls back to `LATPOLE`.
fn computePole(proj: Projection, crval: [2]f64, lonpole: ?f64, latpole: ?f64) Pole {
    const ref = referencePoint(proj);
    const phi0 = ref.phi0 * DEG2RAD;
    const theta0 = ref.theta0 * DEG2RAD;
    const alpha0 = crval[0] * DEG2RAD;
    const delta0 = crval[1] * DEG2RAD;

    // Default LONPOLE: 0° if δ0 ≥ θ0, else 180° (Paper II §2.4).
    const lonpole_deg = lonpole orelse (if (crval[1] >= ref.theta0) @as(f64, 0) else 180.0);
    const phi_p = lonpole_deg * DEG2RAD;

    // Zenithal family: the fiducial point IS the native pole — no solving needed (and this keeps
    // the rotation identical to the classic CRVAL-as-pole formulation).
    if (ref.theta0 == 90) {
        return .{ .phi_p = phi_p, .alpha_p = alpha0, .delta_p = delta0 };
    }

    // Default LATPOLE: +90° (choose the northerly pole when eq (8) is two-valued).
    const latpole_rad = (latpole orelse 90.0) * DEG2RAD;
    const sin_t0 = std.math.sin(theta0);
    const cos_t0 = std.math.cos(theta0);
    const dphi = phi_p - phi0;

    // Solve sin δ0 = sinθ0·sinδp + cosθ0·cosδp·cos(φp−φ0) for δp (Paper II eq 8):
    //   = R·cos(δp − ψ),  R = hypot(sinθ0, cosθ0·cos(φp−φ0)),  ψ = arg(cosθ0·cos·, sinθ0).
    var delta_p: f64 = latpole_rad;
    const mu = sin_t0;
    const lam = cos_t0 * std.math.cos(dphi);
    const rr = std.math.hypot(mu, lam);
    if (rr != 0) {
        const psi = std.math.atan2(mu, lam);
        const omega = std.math.acos(clamp(std.math.sin(delta0) / rr, -1, 1));
        const c1 = wrapPi(psi + omega);
        const c2 = wrapPi(psi - omega);
        const half_pi = std.math.pi / 2.0;
        const v1 = @abs(c1) <= half_pi + 1e-9; // valid declination root?
        const v2 = @abs(c2) <= half_pi + 1e-9;
        if (v1 and v2) {
            const d1 = @abs(c1 - latpole_rad);
            const d2 = @abs(c2 - latpole_rad);
            delta_p = if (d1 < d2) c1 else if (d2 < d1) c2 else @max(c1, c2);
        } else if (v1) {
            delta_p = c1;
        } else if (v2) {
            delta_p = c2;
        }
    }

    // Solve for α_p from the fiducial point (Paper II eq 10):
    //   α0 − αp = arg(sinθ0·cosδp − cosθ0·sinδp·cos(φ0−φp), −cosθ0·sin(φ0−φp)).
    const yy = -cos_t0 * std.math.sin(phi0 - phi_p);
    const xx = sin_t0 * std.math.cos(delta_p) - cos_t0 * std.math.sin(delta_p) * std.math.cos(phi0 - phi_p);
    const alpha_p = if (yy == 0 and xx == 0) alpha0 else alpha0 - std.math.atan2(yy, xx);

    return .{ .phi_p = phi_p, .alpha_p = alpha_p, .delta_p = delta_p };
}

/// Wrap an angle (radians) into `(−π, π]`.
fn wrapPi(a: f64) f64 {
    const two_pi = 2.0 * std.math.pi;
    var x = @mod(a + std.math.pi, two_pi);
    if (x < 0) x += two_pi;
    return x - std.math.pi;
}

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
    var buf: [block.BLOCK]u8 = @splat(' ');
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
        // Reference pixel → CRVAL (true for every projection after the native-pole fix).
        const ref = try c.pixelToWorld(.{ 100.0, 100.0 });
        try testing.expect(@abs(ref[0] - 80.0) < 1e-9);
        try testing.expect(@abs(ref[1] - 45.0) < 1e-9);
        const pt: [2]f64 = .{ 120.0, 130.0 };
        const world = try c.pixelToWorld(pt);
        const back = try c.worldToPixel(world);
        try testing.expect(@abs(back[0] - pt[0]) < 1e-5);
        try testing.expect(@abs(back[1] - pt[1]) < 1e-5);
    }
}

test "SIN/ZEA reject a pixel beyond the projection limb instead of folding it (regression)" {
    // SIN limb 57.3°, ZEA limb 114.6°, ARC limb 180° — at 0.05°/px that is ~1146/2292/3600 px.
    // (r = 180° exactly is the valid antipode, so push the ARC probe well past it.)
    inline for (.{ .{ "SIN", 1401.0 }, .{ "ZEA", 3001.0 }, .{ "ARC", 3801.0 } }) |cfg| {
        const code = cfg[0];
        var p = try wcsFromCards(testing.allocator, &.{
            "WCSAXES =                    2",
            "CTYPE1  = 'RA---" ++ code ++ "'",
            "CTYPE2  = 'DEC--" ++ code ++ "'",
            "CRPIX1  =                  1.0",
            "CRPIX2  =                  1.0",
            "CRVAL1  =                150.0",
            "CRVAL2  =                  2.5",
            "CDELT1  =                 0.05",
            "CDELT2  =                 0.05",
        });
        defer cleanup(testing.allocator, p);
        var c = try Celestial.fromWcs(&p.w);
        // SIN: r≈70°>57.3° limb; ZEA: r≈150°>114.6° limb. Both were silently folded onto the
        // boundary (a finite, non-round-tripping coordinate); now they are NonInvertible.
        try testing.expectError(error.NonInvertible, c.pixelToWorld(.{ cfg[1], 1.0 }));
        // An in-bounds pixel still round-trips.
        const world = try c.pixelToWorld(.{ 5.0, 5.0 });
        const back = try c.worldToPixel(world);
        try testing.expect(@abs(back[0] - 5.0) < 1e-4);
        try testing.expect(@abs(back[1] - 5.0) < 1e-4);
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
    // Reference pixel → CRVAL=(0,0). Before the native-pole fix CAR mapped CRPIX to dec=−90;
    // it must now land on the reference value like every other projection.
    const ref = try c.pixelToWorld(.{ 1.0, 1.0 });
    try testing.expect(@abs(ref[0] - 0.0) < 1e-9);
    try testing.expect(@abs(ref[1] - 0.0) < 1e-9);
    const pt: [2]f64 = .{ 5.0, 7.0 };
    const world = try c.pixelToWorld(pt);
    const back = try c.worldToPixel(world);
    try testing.expect(@abs(back[0] - pt[0]) < 1e-6);
    try testing.expect(@abs(back[1] - pt[1]) < 1e-6);
}

test "CAR with off-equator CRVAL: reference pixel maps to CRVAL and round-trips" {
    var p = try wcsFromCards(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---CAR'",
        "CTYPE2  = 'DEC--CAR'",
        "CRPIX1  =                 50.0",
        "CRPIX2  =                 50.0",
        "CRVAL1  =                120.0",
        "CRVAL2  =                 30.0",
        "CDELT1  =                 -0.05",
        "CDELT2  =                  0.05",
    });
    defer cleanup(testing.allocator, p);
    var c = try Celestial.fromWcs(&p.w);
    const ref = try c.pixelToWorld(.{ 50.0, 50.0 });
    try testing.expect(@abs(ref[0] - 120.0) < 1e-9);
    try testing.expect(@abs(ref[1] - 30.0) < 1e-9);
    // A nearby pixel offset purely in the latitude direction stays near the meridian.
    const w_up = try c.pixelToWorld(.{ 50.0, 60.0 });
    try testing.expect(@abs(w_up[0] - 120.0) < 1e-7); // longitude unchanged on the central meridian
    try testing.expect(@abs(w_up[1] - 30.5) < 1e-7); // +10 px · 0.05 deg
    for ([_][2]f64{ .{ 10, 20 }, .{ 80, 95 }, .{ 50, 1 } }) |pt| {
        const world = try c.pixelToWorld(pt);
        const back = try c.worldToPixel(world);
        try testing.expect(@abs(back[0] - pt[0]) < 1e-6);
        try testing.expect(@abs(back[1] - pt[1]) < 1e-6);
    }
}

test "legacy CROTA2 rotation is folded into M when no PC/CD" {
    var p = try wcsFromCards(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---TAN'",
        "CTYPE2  = 'DEC--TAN'",
        "CRPIX1  =                 50.0",
        "CRPIX2  =                 50.0",
        "CRVAL1  =                 30.0",
        "CRVAL2  =                 10.0",
        "CDELT1  =               -0.001",
        "CDELT2  =                0.001",
        "CROTA2  =                 90.0",
    });
    defer cleanup(testing.allocator, p);
    var c = try Celestial.fromWcs(&p.w);
    // ρ=90°: M = [[ -d1·0, -d2·1 ],[ -d1·1, d2·0 ]] = [[0,-0.001],[-0.001,0]].
    try testing.expect(@abs(c.m[0][0] - 0.0) < 1e-12);
    try testing.expect(@abs(c.m[0][1] - (-0.001)) < 1e-12);
    try testing.expect(@abs(c.m[1][0] - (-0.001)) < 1e-12);
    try testing.expect(@abs(c.m[1][1] - 0.0) < 1e-12);
    // Reference pixel still maps to CRVAL, and the rotated frame round-trips.
    const ref = try c.pixelToWorld(.{ 50.0, 50.0 });
    try testing.expect(@abs(ref[0] - 30.0) < 1e-9);
    try testing.expect(@abs(ref[1] - 10.0) < 1e-9);
    const pt: [2]f64 = .{ 70.0, 40.0 };
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
