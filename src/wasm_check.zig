//! Freestanding build root for `zig build wasm-check` (NFR-PORT-3, GC-7).
//!
//! Compiles `zigfitsio` for `wasm32-freestanding`, importing every freestanding-safe module —
//! the full header/HDU/image/table/WCS/compression/validation stack — and deliberately
//! excluding only the OS-backed I/O leaves: `io/file.zig` and `io/stream.zig` (and the future
//! `io/http.zig`). The in-memory backend (`io/memory.zig`) is the freestanding I/O path; the
//! file-handle layer (`fits.zig`) gates `FileDevice` out under freestanding so the rest of the
//! handle still compiles. As new modules land, freestanding-safe ones are added here; OS leaves
//! are not.
comptime {
    // Cross-cutting foundation.
    _ = @import("errors.zig");
    _ = @import("version.zig");
    _ = @import("diag.zig");
    _ = @import("limits.zig");
    _ = @import("endian.zig");
    _ = @import("convert.zig");

    // I/O core (in-memory backend only; file/stream are OS leaves).
    _ = @import("io/device.zig");
    _ = @import("io/memory.zig");
    _ = @import("io/block.zig");

    // Header layer.
    _ = @import("header/name.zig");
    _ = @import("header/value.zig");
    _ = @import("header/card.zig");
    _ = @import("header/header.zig");
    _ = @import("header/continue.zig");
    _ = @import("header/hierarch.zig");

    // HDU model + file handle (FileDevice gated out under freestanding).
    _ = @import("hdu.zig");
    _ = @import("fits.zig");

    // Images.
    _ = @import("image.zig");

    // Tables.
    _ = @import("table/common.zig");
    _ = @import("table/binary.zig");
    _ = @import("table/ascii.zig");
    _ = @import("table/heap.zig");

    // World Coordinate System.
    _ = @import("wcs/keys.zig");
    _ = @import("wcs/celestial.zig");
    _ = @import("wcs/spectral.zig");
    _ = @import("wcs/time.zig");

    // Compression (tiled + codecs + dither).
    _ = @import("compress/shuffle.zig");
    _ = @import("compress/gzip.zig");
    _ = @import("compress/tiled.zig");
    _ = @import("compress/rice.zig");
    _ = @import("compress/plio.zig");
    _ = @import("compress/hcompress.zig");
    _ = @import("compress/dither.zig");
    _ = @import("compress/quantize.zig");

    // Integrity, random groups, iterator, validation.
    _ = @import("checksum.zig");
    _ = @import("groups.zig");
    _ = @import("iterator.zig");
    _ = @import("validate.zig");

    // Extended filenames, templates, grouping tables.
    _ = @import("filename.zig");
    _ = @import("template.zig");
    _ = @import("group_table.zig");
}
