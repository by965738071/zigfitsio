//! Resource limits and the validate-before-allocate helpers (NFR-SAFE-1, GC-6, §7.2).
//!
//! Untrusted input declares sizes (the product of `NAXISn`, `PCOUNT`/heap, each VLA
//! descriptor length+offset). **Before any allocation**, those declared sizes are validated
//! against both these limits and the actual stream length, using checked arithmetic. This is
//! the single mechanism behind "validated before allocation"; it is the direct target of the
//! fuzzers (X-FUZZ).
const std = @import("std");
const LimitError = @import("errors.zig").LimitError;

/// Per-handle, overridable resource ceilings with documented defaults. `max_matches` is the
/// runtime ceiling for a wildcard match list and **must be ≤** `name.MAX_MATCHES`, the
/// comptime inline-buffer capacity (§19.1).
pub const Limits = struct {
    /// Maximum header size in 2880-byte blocks (≈ 460k cards at the default).
    max_header_blocks: u32 = 1 << 14,
    /// Maximum number of HDUs scanned in one file.
    max_hdu_count: u32 = 100_000,
    /// Maximum pixel count (product of `NAXISn`); guards `NAXISn` overflow.
    max_naxis_product: u64 = 1 << 40,
    /// Maximum `PCOUNT`/heap size in bytes.
    max_heap_bytes: u64 = 1 << 34,
    /// Maximum element count of a single VLA descriptor.
    max_vla_elems: u64 = 1 << 30,
    /// Maximum assembled `CONTINUE` string length in bytes.
    max_string_value: u32 = 1 << 20,
    /// Maximum size of a single decompression tile in bytes.
    max_tile_bytes: u64 = 1 << 30,
    /// Ceiling on a single allocation request.
    max_open_alloc: u64 = 1 << 32,
    /// Runtime ceiling for a wildcard `Matches` list; must be ≤ `name.MAX_MATCHES`.
    max_matches: u32 = 4096,
};

/// Multiply two sizes, mapping overflow to `LimitExceeded` (never UB).
pub fn mul(a: u64, b: u64) LimitError!u64 {
    return std.math.mul(u64, a, b) catch error.LimitExceeded;
}

/// Add two sizes, mapping overflow to `LimitExceeded` (never UB).
pub fn add(a: u64, b: u64) LimitError!u64 {
    return std.math.add(u64, a, b) catch error.LimitExceeded;
}

/// Product of axis lengths, guarded against arithmetic overflow and the configured pixel
/// ceiling. An empty `axes` slice yields 1 (the scalar/`NAXIS=0` case). Returns
/// `LimitExceeded` before any caller allocation if the product overflows or exceeds
/// `max_product`.
pub fn naxisProduct(axes: []const u64, max_product: u64) LimitError!u64 {
    var product: u64 = 1;
    for (axes) |axis| {
        product = try mul(product, axis);
        if (product > max_product) return error.LimitExceeded;
    }
    return product;
}

/// Ensure a declared byte size is within `ceiling` and — when known — does not exceed the
/// actual `stream_len`. Call this with the relevant `Limits` field as `ceiling` immediately
/// before allocating or reading the declared region (NFR-SAFE-1).
pub fn ensureWithin(declared: u64, ceiling: u64, stream_len: ?u64) LimitError!void {
    if (declared > ceiling) return error.LimitExceeded;
    if (stream_len) |len| {
        if (declared > len) return error.LimitExceeded;
    }
}

const testing = std.testing;

test "defaults are sane and overridable" {
    const d: Limits = .{};
    // Invariant: max_matches must stay ≤ name.MAX_MATCHES (4096), the comptime inline
    // capacity. That cross-module assertion lives in header/name.zig once it exists.
    try testing.expect(d.max_matches <= 4096);
    const custom: Limits = .{ .max_naxis_product = 1024 };
    try testing.expectEqual(@as(u64, 1024), custom.max_naxis_product);
}

test "naxisProduct overflows and ceilings yield typed errors before allocation" {
    try testing.expectEqual(@as(u64, 1), try naxisProduct(&.{}, 100));
    try testing.expectEqual(@as(u64, 200), try naxisProduct(&.{ 10, 20 }, 1 << 40));
    try testing.expectError(error.LimitExceeded, naxisProduct(&.{ 10, 20 }, 100));
    try testing.expectError(error.LimitExceeded, naxisProduct(&.{ std.math.maxInt(u64), 2 }, std.math.maxInt(u64)));
}

test "ensureWithin guards ceiling and stream length" {
    try ensureWithin(100, 1000, 200);
    try testing.expectError(error.LimitExceeded, ensureWithin(2000, 1000, null));
    try testing.expectError(error.LimitExceeded, ensureWithin(150, 1000, 100));
}
