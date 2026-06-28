//! Freestanding build root for `zig build wasm-check` (NFR-PORT-3, GC-7).
//!
//! Compiles the core of `zigfitsio` for `wasm32-freestanding`, deliberately importing only
//! the freestanding-safe modules and excluding the OS-backed I/O backends (`io/file.zig`,
//! `io/stream.zig`, `io/http.zig`). The in-memory backend (`io/memory.zig`) is the
//! freestanding I/O path. As new modules land, freestanding-safe ones are added here; OS
//! leaves are not.
comptime {
    _ = @import("errors.zig");
    _ = @import("version.zig");
    _ = @import("diag.zig");
    _ = @import("limits.zig");
    _ = @import("endian.zig");
    _ = @import("convert.zig");
    _ = @import("io/device.zig");
    _ = @import("io/memory.zig");
    _ = @import("io/block.zig");
}
