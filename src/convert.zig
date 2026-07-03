//! The single numeric-conversion policy (FR-CONV-1/2, §6).
//!
//! Every site that crosses a type boundary — keyword reads, image pixels, table cells —
//! calls `cast`, so the policy is defined once. All range checks happen **before** any
//! truncation or wraparound, so there is no UB on out-of-range input (FR-CONV-2, GC-6).
//!
//! Policy:
//!   - int→int / float→int out of `Dst` range → `error.Overflow` (range checked first).
//!   - float→int rounding is **round half away from zero** (`@round`). This differs from
//!     CFITSIO's `(int)(x ± 0.5)` only for a float within ~0.5 ULP of N.5 (vanishingly rare
//!     in real data). `NaN → int` is `error.NanToInt`.
//!   - precision-losing widening (`i64`/`u64`→`f64`, `f64`→`f32`, …): `scalar` mode reports
//!     `error.PrecisionLoss` when the value is not exactly representable; `bulk` mode allows
//!     it silently (FR-CONV-1(c)).
//!   - same type / lossless widening: direct.
const std = @import("std");
const ConvError = @import("errors.zig").ConvError;

/// Conversion context. `scalar` is for keyword reads and single cells (precision loss is an
/// error); `bulk` is for array/column transfers (precision-losing widening is silent).
pub const Mode = enum { scalar, bulk };

/// Convert `src` (any runtime int or float) to `Dst` (int or float) under the policy.
pub fn cast(comptime Dst: type, src: anytype, mode: Mode) ConvError!Dst {
    const Src = @TypeOf(src);
    if (Src == Dst) return src;
    const dinfo = @typeInfo(Dst);
    const sinfo = @typeInfo(Src);
    switch (dinfo) {
        .int => switch (sinfo) {
            .int => return castIntInt(Dst, src),
            .float => return castFloatInt(Dst, src),
            else => @compileError("convert: src must be a runtime int or float, got " ++ @typeName(Src)),
        },
        .float => switch (sinfo) {
            .int => return castIntFloat(Dst, src, mode),
            .float => return castFloatFloat(Dst, src, mode),
            else => @compileError("convert: src must be a runtime int or float, got " ++ @typeName(Src)),
        },
        else => @compileError("convert: Dst must be an int or float, got " ++ @typeName(Dst)),
    }
}

fn castIntInt(comptime Dst: type, src: anytype) ConvError!Dst {
    // Comparisons widen to a type that holds both operands, so this is value-correct even
    // when the ranges differ in width or signedness.
    if (src < std.math.minInt(Dst) or src > std.math.maxInt(Dst)) return error.Overflow;
    return @intCast(src);
}

fn castFloatInt(comptime Dst: type, src: anytype) ConvError!Dst {
    const F = @TypeOf(src);
    if (std.math.isNan(src)) return error.NanToInt;
    const r = @round(src); // round half away from zero; result is integral-valued
    // Range-check against exact power-of-two float bounds (exactly representable for the
    // widths we use), so `@intFromFloat` below can never see an out-of-range value.
    const di = @typeInfo(Dst).int;
    const order: u8 = if (di.signedness == .signed) di.bits - 1 else di.bits;
    const two_pow: u128 = @as(u128, 1) << @intCast(order);
    const limit: F = @floatFromInt(two_pow);
    if (di.signedness == .signed) {
        if (!(r >= -limit and r < limit)) return error.Overflow;
    } else {
        if (!(r >= 0 and r < limit)) return error.Overflow;
    }
    return @intFromFloat(r);
}

fn castIntFloat(comptime Dst: type, src: anytype, mode: Mode) ConvError!Dst {
    const f: Dst = @floatFromInt(src);
    if (mode == .scalar) {
        // `f` is integral-valued; round-trip through i128 (which holds any value our floats can
        // carry) to detect mantissa precision loss without risking an out-of-range cast. Guard
        // against a non-finite intermediate first: an integer too large for a narrow `Dst` (e.g.
        // a value > 65504 into `f16`) saturates to ±inf, and `@intFromFloat(inf)` traps — a
        // saturated result is by definition not exactly representable, so report precision loss.
        if (!std.math.isFinite(f)) return error.PrecisionLoss;
        const back: i128 = @intFromFloat(f);
        if (back != @as(i128, src)) return error.PrecisionLoss;
    }
    return f;
}

fn castFloatFloat(comptime Dst: type, src: anytype, mode: Mode) ConvError!Dst {
    const Src = @TypeOf(src);
    const f: Dst = @floatCast(src);
    if (mode == .scalar) {
        // Widening (f32→f64) is exact; narrowing may lose precision. NaN is "representable".
        if (!std.math.isNan(src) and @as(Src, @floatCast(f)) != src) return error.PrecisionLoss;
    }
    return f;
}

const testing = std.testing;

test "int→int overflow at each boundary" {
    try testing.expectError(error.Overflow, cast(i8, @as(i32, 128), .scalar));
    try testing.expectError(error.Overflow, cast(i8, @as(i32, -129), .scalar));
    try testing.expectEqual(@as(i8, 127), try cast(i8, @as(i32, 127), .scalar));
    try testing.expectError(error.Overflow, cast(u8, @as(i32, -1), .bulk));
    try testing.expectError(error.Overflow, cast(u16, @as(i64, 65536), .bulk));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), try cast(u64, @as(u64, std.math.maxInt(u64)), .scalar));
}

test "float→int rounds half away from zero" {
    try testing.expectEqual(@as(i32, 3), try cast(i32, @as(f64, 2.5), .scalar));
    try testing.expectEqual(@as(i32, -3), try cast(i32, @as(f64, -2.5), .scalar));
    try testing.expectEqual(@as(i32, 2), try cast(i32, @as(f64, 2.4), .scalar));
    try testing.expectEqual(@as(i32, 1), try cast(i32, @as(f64, 0.5), .scalar));
    try testing.expectEqual(@as(i64, 0), try cast(i64, @as(f64, -0.4), .scalar));
}

test "float→int overflow and NaN" {
    try testing.expectError(error.Overflow, cast(i8, @as(f64, 200.0), .scalar));
    try testing.expectError(error.Overflow, cast(i8, @as(f64, -200.0), .scalar));
    try testing.expectError(error.NanToInt, cast(i32, std.math.nan(f64), .scalar));
    // boundary: i64 max+1 must overflow, not wrap.
    try testing.expectError(error.Overflow, cast(i64, @as(f64, 9.3e18), .scalar));
    try testing.expectEqual(@as(u8, 255), try cast(u8, @as(f64, 255.0), .bulk));
}

test "int→float exact vs inexact (scalar errors, bulk silent)" {
    const big: i64 = (@as(i64, 1) << 53) + 1; // not exactly representable in f64
    try testing.expectError(error.PrecisionLoss, cast(f64, big, .scalar));
    _ = try cast(f64, big, .bulk); // silent in bulk
    const exact: i64 = (@as(i64, 1) << 52) + 1; // representable
    try testing.expectEqual(@as(f64, @floatFromInt(exact)), try cast(f64, exact, .scalar));
}

test "int→narrow-float overflow reports PrecisionLoss, never traps on @intFromFloat(inf)" {
    // A value beyond f16's finite range saturates to +inf; the scalar round-trip check must not
    // reach `@intFromFloat(inf)` (a trap). Reproduces reading a large integer column cell as f16.
    try testing.expectError(error.PrecisionLoss, cast(f16, @as(i64, 70000), .scalar));
    try testing.expectError(error.PrecisionLoss, cast(f16, @as(i64, -70000), .scalar));
    _ = try cast(f16, @as(i64, 70000), .bulk); // bulk still saturates silently (documented)
    // In-range values still round-trip exactly.
    try testing.expectEqual(@as(f16, 1024.0), try cast(f16, @as(i64, 1024), .scalar));
}

test "float→float narrowing precision policy" {
    const v: f64 = 1.0000000001;
    try testing.expectError(error.PrecisionLoss, cast(f32, v, .scalar));
    _ = try cast(f32, v, .bulk);
    try testing.expectEqual(@as(f64, 1.5), try cast(f64, @as(f32, 1.5), .scalar)); // widening exact
    // NaN narrows without error.
    try testing.expect(std.math.isNan(try cast(f32, std.math.nan(f64), .scalar)));
}
