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

// ── I/O layer (§8) ─────────────────────────────────────────────────────────────────────
pub const Device = @import("io/device.zig").Device;
pub const MemoryDevice = @import("io/memory.zig").MemoryDevice;
pub const FileDevice = @import("io/file.zig").FileDevice;
pub const block = @import("io/block.zig");

// ── Header layer (§9) ──────────────────────────────────────────────────────────────────
/// Wildcard match accumulator with the explicit multi-match contract (FR-UTL-4).
pub const Matches = @import("header/name.zig").Matches;
/// A parsed FITS keyword value (FR-HDR-3).
pub const KeywordValue = @import("header/value.zig").KeywordValue;
/// An 80-byte header card with byte-exact round-trip (FR-HDR-1).
pub const Card = @import("header/card.zig").Card;
/// HIERARCH long-keyword convention helpers (FR-HDR-9).
pub const hierarch = @import("header/hierarch.zig");
/// The ordered cards of one HDU header (FR-HDR-5/7/11).
pub const Header = @import("header/header.zig").Header;

// ── HDU model & file handle (§10) ──────────────────────────────────────────────────────
const fits_mod = @import("fits.zig");
/// The FITS file handle (open/create/navigate/build).
pub const Fits = fits_mod.Fits;
/// Open mode for a file handle.
pub const Mode = fits_mod.Mode;
/// Options for `open`/`create`.
pub const OpenOpts = fits_mod.OpenOpts;
/// Specification for a programmatically-built image HDU (FR-TPL-2).
pub const ImageSpec = fits_mod.ImageSpec;
/// One Header/Data Unit (FR-HDU-1/2).
pub const Hdu = @import("hdu.zig").Hdu;
/// The kind of an HDU.
pub const HduKind = @import("hdu.zig").HduKind;

/// Open an existing FITS file over a device (FR-HDU-1).
pub const open = Fits.open;
/// Create a new FITS file over a device.
pub const create = Fits.create;
/// Open an on-disk FITS file by path (the handle owns the device).
pub const openFile = Fits.openFile;
/// Create a new on-disk FITS file by path.
pub const createFile = Fits.createFile;

// ── Images (§11) ───────────────────────────────────────────────────────────────────────
const image_mod = @import("image.zig");
/// A typed view over an HDU's image data array (FR-IMG-*).
pub const ImageView = image_mod.ImageView;
/// Linear scaling state (BSCALE/BZERO/BLANK).
pub const Scaling = image_mod.Scaling;

// ── Tables (§12–§14) ───────────────────────────────────────────────────────────────────
/// Binary-table column view (FR-BTB-*).
pub const BinTable = @import("table/binary.zig").BinTable;
/// ASCII-table column view (FR-ATB-*).
pub const AsciiTable = @import("table/ascii.zig").AsciiTable;
/// Column reference (by index or name) shared by the table views.
pub const ColumnRef = @import("table/binary.zig").ColumnRef;
/// Variable-length-array heap access (FR-VLA-*).
pub const heap = @import("table/heap.zig");

// ── Random groups (§15) ────────────────────────────────────────────────────────────────
/// Random-groups structure access (FR-RG-*).
pub const RandomGroups = @import("groups.zig").RandomGroups;

// ── Data integrity (§16) ───────────────────────────────────────────────────────────────
/// DATASUM/CHECKSUM computation and verification (FR-SUM-*).
pub const checksum = @import("checksum.zig");

// ── Tiled compression (§17) ────────────────────────────────────────────────────────────
/// Tiled-compressed-image read view (FR-CMP-1/2).
pub const TiledImage = @import("compress/tiled.zig").TiledImage;

// ── Iterator (§19.2) ───────────────────────────────────────────────────────────────────
/// High-level work-function iterator over columns/pixels (FR-ITR-*).
pub const Iterator = @import("iterator.zig").Iterator;

// ── Structural validation (§19.3) ──────────────────────────────────────────────────────
/// fitsverify-style conformance pass (FR-VAL-*).
pub const validate = @import("validate.zig");

// ── World Coordinate System (§18) ──────────────────────────────────────────────────────
/// The WCS keyword set parse/serialize (FR-WCS-1).
pub const Wcs = @import("wcs/keys.zig").Wcs;
/// Celestial pixel<->world transforms (FR-WCS-2).
pub const Celestial = @import("wcs/celestial.zig").Celestial;
/// Spectral coordinate keywords (FR-WCS-3).
pub const Spectral = @import("wcs/spectral.zig").Spectral;
/// Global time-coordinate keywords (FR-WCS-4).
pub const TimeCoords = @import("wcs/time.zig").TimeCoords;

// ── Utilities (§19.1) ──────────────────────────────────────────────────────────────────
/// FITS date/time + Julian-Date helpers (FR-UTL-1).
pub const DateTime = @import("wcs/time.zig").DateTime;
/// Shared table column model: TFORM/TDISP parsing (FR-UTL-2).
pub const table_common = @import("table/common.zig");

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
    _ = @import("io/device.zig");
    _ = @import("io/memory.zig");
    _ = @import("io/file.zig");
    _ = @import("io/stream.zig");
    _ = @import("io/block.zig");
    _ = @import("header/name.zig");
    _ = @import("header/value.zig");
    _ = @import("header/card.zig");
    _ = @import("header/header.zig");
    _ = @import("header/continue.zig");
    _ = @import("header/hierarch.zig");
    _ = @import("hdu.zig");
    _ = @import("fits.zig");
    _ = @import("image.zig");
    _ = @import("wcs/keys.zig");
    _ = @import("wcs/celestial.zig");
    _ = @import("wcs/spectral.zig");
    _ = @import("wcs/time.zig");
    _ = @import("compress/shuffle.zig");
    _ = @import("compress/gzip.zig");
    _ = @import("table/common.zig");
    _ = @import("table/binary.zig");
    _ = @import("table/ascii.zig");
    _ = @import("table/heap.zig");
    _ = @import("checksum.zig");
    _ = @import("groups.zig");
    _ = @import("iterator.zig");
    _ = @import("validate.zig");
    _ = @import("compress/tiled.zig");
}

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}
