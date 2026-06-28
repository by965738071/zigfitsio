//! Throughput benchmarks for `zigfitsio` (X-BENCH, NFR-PERF-1/2/3).
//!
//! Stub: filled in once the image/column bulk paths land. Measures bulk image and column
//! throughput against the non-binding ~2× CFITSIO goal and asserts no per-element
//! allocation on the hot paths. Not a release gate.
const std = @import("std");
const fits = @import("zigfitsio");

pub fn main() !void {
    var stdout_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&stdout_buf);
    try w.print("zigfitsio {s} — benchmarks not yet implemented\n", .{fits.version});
    // Intentionally no output sink wired yet; this is a buildable placeholder (SETUP-1).
}
