//! Fuzz harnesses for the header and table parsers (X-FUZZ, NFR-SAFE-1/2, GC-6).
//!
//! Stub: real harnesses are seeded from the corpus and target validate-before-allocate
//! once the header (HDR-3a) and table (BTB-1, VLA-1) parsers land. Run via `zig build fuzz`
//! (add `--fuzz` to engage the in-tree fuzzer).
const std = @import("std");
const fits = @import("zigfitsio");

test "fuzz harness placeholder builds" {
    try std.testing.expect(fits.version.len > 0);
}
