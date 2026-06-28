//! zigfitsio — a pure-Zig implementation of FITS (Flexible Image Transport System) 4.0
//! input/output, with no C imports or C sources (GC-1/2).
//!
//! This is the only file a consumer imports. It re-exports the public surface and nothing
//! internal (NFR-API-2). Internal fields of `Fits`, `Header`, etc. are not part of the
//! public contract.
const std = @import("std");

// ── Cross-cutting foundation (§4, §6, §7) ──────────────────────────────────────────────
pub const errors = @import("errors.zig");
pub const Error = errors.Error;
pub const Diagnostics = @import("diag.zig").Diagnostics;
pub const Limits = @import("limits.zig").Limits;
pub const convert = @import("convert.zig");
pub const endian = @import("endian.zig");

const version_mod = @import("version.zig");
/// Library version string (NFR-API-1, FR-UTL-3). Mirrors `build.zig.zon`.
pub const version = version_mod.version_string;
/// Return a stable, human-readable message for every `Error` value (FR-UTL-3).
pub const errorText = version_mod.errorText;
/// Map an `Error` to the nearest CFITSIO numeric status code (FR-ERR-4).
pub const cfitsioStatus = errors.cfitsioStatus;

test {
    // Pull every module's tests into the suite (`zig build test`). Each module is listed
    // explicitly: `_ = @import(...)` makes its tests reachable from the root. New modules
    // append a line here as they land.
    _ = @import("errors.zig");
    _ = @import("version.zig");
    _ = @import("diag.zig");
    _ = @import("limits.zig");
    _ = @import("endian.zig");
    _ = @import("convert.zig");
}

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}
