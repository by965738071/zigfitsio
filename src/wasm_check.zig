//! Freestanding build root for `zig build wasm-check` (NFR-PORT-3, GC-7).
//!
//! Compiles the core of `zigfitsio` for `wasm32-freestanding`, deliberately excluding the
//! OS-backed I/O backends (`io/file.zig`, `io/stream.zig`, `io/http.zig`). The in-memory
//! backend (`io/memory.zig`) is the freestanding I/O path. As OS-backed leaf modules are
//! added, they must stay out of this import graph.
const root = @import("root.zig");

comptime {
    // Force analysis of the freestanding-safe public surface.
    _ = root;
}
