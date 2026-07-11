//! Tiled-compressed image view (`FR-CMP-1`; design §17.1–§17.2; FITS 4.0 §10.1).
//!
//! A tiled-compressed image is a `BINTABLE` carrying `ZIMAGE = T`. The *uncompressed* image
//! geometry lives in keywords (`ZCMPTYPE`, `ZBITPIX`, `ZNAXIS`, `ZNAXISn`, `ZTILEn`, the
//! optional `ZQUANTIZ`/`ZDITHER0` dither method and `ZNAMEn`/`ZVALn` codec parameters); the
//! pixel payload lives in columns: `COMPRESSED_DATA` (a `1P`/`1Q` byte VLA, one row per tile),
//! the optional `GZIP_COMPRESSED_DATA`/`UNCOMPRESSED_DATA` fallbacks, and the per-tile linear
//! `ZSCALE`/`ZZERO` (`ZBLANK` may be either a keyword or a column, with a plain `BLANK`
//! keyword accepted as the fallback spelling — fpack copies the source's `BLANK` unrenamed).
//!
//! `TiledImage` parses that structure and decodes the covering tiles into a normal, row-major
//! image buffer (`readAll`). The image space is tiled row-major with the first axis varying
//! fastest (§10.1); tile `r` is table row `r`. Tiles on an axis whose length is not a multiple
//! of the tile size are clipped to the image bound (edge/partial tiles).
//!
//! The read path decodes `GZIP_1`/`GZIP_2` (`compress/gzip.zig`), `RICE_1` (`compress/rice.zig`),
//! `PLIO_1` (`compress/plio.zig`) and `HCOMPRESS_1` (`compress/hcompress.zig`); only an unrecognized
//! `ZCMPTYPE` yields `error.UnsupportedCodec` from `readAll` — never a silent mis-read
//! (`NFR-INTEROP-1`). The write path (`writeCompressed`) emits GZIP for any BITPIX, RICE/PLIO/
//! HCOMPRESS for integer 8/16/32-bit images, and RICE/HCOMPRESS additionally for QUANTIZED float
//! images (CFITSIO `fits_quantize` parity via `compress/quantize.zig`: `NO_DITHER` or subtractive
//! dithering, per-tile `ZSCALE`/`ZZERO`). All declared sizes are validated against `Limits` and
//! the device length before allocating (`NFR-SAFE-1`); a tile that decodes to the wrong size is
//! `error.CorruptTile`. `PLIO_1` uses the standard pixel-list wire format (FITS 4.0 Table 38)
//! and `HCOMPRESS_1` the standard H-transform stream (White 1992); both round-trip losslessly
//! here, with byte-exact CFITSIO parity pending external tools.
//!
//! Resolved spec ambiguities (no external toolchain here; correctness is proven by lossless
//! write→read round-trips, `NFR-INTEROP-1`):
//!   * `ZBLANK` null substitution on read mirrors the uncompressed image layer — a floating output
//!     type receives NaN; an integer output type (which has no representable null) passes the raw
//!     `ZBLANK` value through unchanged. On the dithered-float path a declared `ZBLANK` overrides
//!     the convention's reserved `null_value` sentinel (§10.2.1).
//!   * The write path records `RICE_1`'s `BLOCKSIZE` (default 32) and stored-value `BYTEPIX`
//!     (= 4 for quantized floats, otherwise |ZBITPIX|/8), and `HCOMPRESS_1`'s `SCALE` (= 0,
//!     lossless) as `ZNAMEn`/`ZVALn` pairs. The RICE read path derives that stored width from the
//!     logical decode path, while `SCALE` is carried in the HCOMPRESS stream header.
const std = @import("std");
const builtin = @import("builtin");
const errors = @import("../errors.zig");
const convert = @import("../convert.zig");
const endian = @import("../endian.zig");
const limits = @import("../limits.zig");
const Fits = @import("../fits.zig").Fits;
const FitsError = @import("../fits.zig").FitsError;
const Hdu = @import("../hdu.zig").Hdu;
const binary = @import("../table/binary.zig");
const BinTable = binary.BinTable;
const ColumnRef = binary.ColumnRef;
const BinaryType = @import("../table/common.zig").BinaryType;
const BinTform = @import("../table/common.zig").BinTform;
const heap = @import("../table/heap.zig");
const HeapManager = heap.HeapManager;
const writeVlaCell = heap.writeVlaCell;
const gzip = @import("gzip.zig");
const rice = @import("rice.zig");
const plio = @import("plio.zig");
const hcompress = @import("hcompress.zig");
const imgstats = @import("imgstats.zig");
const quant = @import("quantize.zig");
const dither = @import("dither.zig");
const Header = @import("../header/header.zig").Header;
const Matches = @import("../header/name.zig").Matches;

const Allocator = std.mem.Allocator;
const native_endian = builtin.cpu.arch.endian();

/// The tile compression algorithm named by `ZCMPTYPE`. `gzip_1`/`gzip_2`, `rice_1`, `plio_1`
/// and `hcompress_1` are all decoded **and** encoded on the tiled path; only an unrecognized
/// name maps to `.unknown` (reported precisely as `error.UnsupportedCodec`).
pub const Codec = enum {
    /// `GZIP_1`: gzip over the raw big-endian stored values.
    gzip_1,
    /// `GZIP_2`: gzip over the MSB-first type-aware byte shuffle of the stored values.
    gzip_2,
    /// `RICE_1`: Rice-coded blocks (`rice.zig`), read+write.
    rice_1,
    /// `PLIO_1`: IRAF pixel-list run encoding in the standard wire format (Table 38, `plio.zig`),
    /// read+write; byte-exact CFITSIO parity pending external tools.
    plio_1,
    /// `HCOMPRESS_1`: H-transform image compression in the standard wire format (White 1992,
    /// `hcompress.zig`), read+write; byte-exact CFITSIO parity pending external tools.
    hcompress_1,
    /// An unrecognized `ZCMPTYPE` value.
    unknown,

    /// Map a `ZCMPTYPE` string (case-insensitive, blank-trimmed) to a `Codec`. An unrecognized
    /// name maps to `.unknown` (which `readAll` reports as `error.UnsupportedCodec`).
    pub fn fromName(s_in: []const u8) Codec {
        const s = std.mem.trim(u8, s_in, " ");
        if (std.ascii.eqlIgnoreCase(s, "GZIP_1")) return .gzip_1;
        if (std.ascii.eqlIgnoreCase(s, "GZIP_2")) return .gzip_2;
        if (std.ascii.eqlIgnoreCase(s, "RICE_1")) return .rice_1;
        if (std.ascii.eqlIgnoreCase(s, "PLIO_1")) return .plio_1;
        if (std.ascii.eqlIgnoreCase(s, "HCOMPRESS_1")) return .hcompress_1;
        return .unknown;
    }

    /// Whether this module can decode tiles compressed with this codec. The read path now
    /// dispatches GZIP_1/GZIP_2 (`gzip.zig`), RICE_1 (`rice.zig`), PLIO_1 (`plio.zig`) and
    /// HCOMPRESS_1 (`hcompress.zig`); only an unrecognized `ZCMPTYPE` (`.unknown`) is
    /// `error.UnsupportedCodec`.
    pub fn isImplemented(self: Codec) bool {
        return switch (self) {
            .gzip_1, .gzip_2, .rice_1, .plio_1, .hcompress_1 => true,
            .unknown => false,
        };
    }

    /// The canonical `ZCMPTYPE` string for this codec (for the write path). `.unknown` has no
    /// name (`null`).
    pub fn name(self: Codec) ?[]const u8 {
        return switch (self) {
            .gzip_1 => "GZIP_1",
            .gzip_2 => "GZIP_2",
            .rice_1 => "RICE_1",
            .plio_1 => "PLIO_1",
            .hcompress_1 => "HCOMPRESS_1",
            .unknown => null,
        };
    }
};

/// The floating-point quantization/dither method named by `ZQUANTIZ` (recorded, not applied on
/// the GZIP read path, which is lossless).
pub const Quantize = enum {
    /// No quantization at all: `ZQUANTIZ` absent or `'NONE'` (CFITSIO `NO_QUANTIZE`). On the
    /// write path float pixels are stored losslessly (raw IEEE bytes under GZIP).
    none,
    /// `NO_DITHER`: quantize floats to scaled integers WITHOUT dithering (`fpack -q0`). On the
    /// write path this selects the CFITSIO quantizer with plain `NINT` rounding.
    no_dither,
    /// `SUBTRACTIVE_DITHER_1`.
    subtractive_dither_1,
    /// `SUBTRACTIVE_DITHER_2`.
    subtractive_dither_2,
    /// An unrecognized `ZQUANTIZ` value.
    unknown,

    /// Map a `ZQUANTIZ` string (case-insensitive, blank-trimmed) to a `Quantize`.
    pub fn fromName(s_in: []const u8) Quantize {
        const s = std.mem.trim(u8, s_in, " ");
        if (std.ascii.eqlIgnoreCase(s, "NONE")) return .none;
        if (std.ascii.eqlIgnoreCase(s, "NO_DITHER")) return .no_dither;
        if (std.ascii.eqlIgnoreCase(s, "SUBTRACTIVE_DITHER_1")) return .subtractive_dither_1;
        if (std.ascii.eqlIgnoreCase(s, "SUBTRACTIVE_DITHER_2")) return .subtractive_dither_2;
        return .unknown;
    }

    /// The canonical `ZQUANTIZ` string for this method (for the write path), or `null` for
    /// `.unknown`.
    pub fn name(self: Quantize) ?[]const u8 {
        return switch (self) {
            .none => "NONE",
            .no_dither => "NO_DITHER",
            .subtractive_dither_1 => "SUBTRACTIVE_DITHER_1",
            .subtractive_dither_2 => "SUBTRACTIVE_DITHER_2",
            .unknown => null,
        };
    }

    /// Map to the codec-agnostic `dither.DitherKind` used by the random-draw cursor.
    fn toDitherKind(self: Quantize) dither.DitherKind {
        return switch (self) {
            .subtractive_dither_1 => .subtractive_1,
            .subtractive_dither_2 => .subtractive_2,
            else => .none,
        };
    }

    /// Whether this method dithers (consuming §10.2 random draws and needing `ZDITHER0`).
    fn isDithered(self: Quantize) bool {
        return self == .subtractive_dither_1 or self == .subtractive_dither_2;
    }

    /// Whether this method quantizes floats to scaled integers at all (dithered or not).
    fn isQuantized(self: Quantize) bool {
        return self == .no_dither or self == .subtractive_dither_1 or self == .subtractive_dither_2;
    }
};

/// A parsed `ZVALn` codec-parameter value (the right-hand side of a `ZNAMEn`/`ZVALn` pair).
pub const ParamValue = union(enum) {
    /// An integer `ZVALn` (e.g. `BLOCKSIZE`, `BYTEPIX`).
    int: i64,
    /// A floating `ZVALn`.
    float: f64,
    /// An owned string `ZVALn`.
    string: []u8,
    /// A present but undefined/blank `ZVALn`.
    undef,
};

/// One `ZNAMEn`/`ZVALn` codec-parameter pair (recorded for inspection).
pub const Param = struct {
    /// Owned parameter name (the `ZNAMEn` string).
    name: []u8,
    /// Parsed `ZVALn` value.
    value: ParamValue,
};

/// Errors from `TiledImage.of`.
pub const OfError = binary.OpenError || errors.CompressError;

/// Errors from `TiledImage.readAll`.
pub const ReadError = heap.ReadError || errors.CompressError || errors.StructError ||
    errors.ConvError || errors.ValueError || errors.HeaderError;

/// A read view over a tiled-compressed image stored in a `ZIMAGE` `BINTABLE`.
pub const TiledImage = struct {
    /// The underlying binary-table view (owns the column descriptors).
    base: BinTable,
    /// The owning file handle.
    fits: *Fits,
    /// The compressed-image HDU.
    hdu: *Hdu,
    /// `ZCMPTYPE` codec.
    ztype: Codec,
    /// `ZBITPIX`: BITPIX of the *uncompressed* image (8/16/32/64/-32/-64).
    zbitpix: i64,
    /// `ZNAXIS`: dimensionality of the uncompressed image.
    znaxis: u16,
    /// `ZNAXISn`: the uncompressed image dimensions (most-rapidly-varying first; owned).
    znaxisn: []u64,
    /// `ZTILEn`: the tile size along each axis (defaults `ZTILE1=ZNAXIS1`, rest `1`; owned).
    ztilen: []u64,
    /// Total pixel count (product of `ZNAXISn`).
    npix: u64,
    /// Total tile count (product of `ceil(ZNAXISn/ZTILEn)`).
    ntiles_total: u64,
    /// `ZQUANTIZ` dither method.
    quantize: Quantize,
    /// `ZDITHER0` seed, or `null`.
    zdither0: ?i64,
    /// `ZNAMEn`/`ZVALn` codec parameters (owned).
    params: []Param,
    /// Column index of `COMPRESSED_DATA`, or `null`.
    comp_col: ?u16,
    /// Column index of `GZIP_COMPRESSED_DATA`, or `null`.
    gzip_col: ?u16,
    /// Column index of `UNCOMPRESSED_DATA`, or `null`.
    uncomp_col: ?u16,
    /// Column index of a per-tile `ZSCALE`, or `null`.
    zscale_col: ?u16,
    /// Column index of a per-tile `ZZERO`, or `null`.
    zzero_col: ?u16,
    /// Column index of a per-tile `ZBLANK`, or `null`.
    zblank_col: ?u16,
    /// `ZSCALE` keyword (used when there is no per-tile `ZSCALE` column), or `null`.
    zscale_kw: ?f64,
    /// `ZZERO` keyword (used when there is no per-tile `ZZERO` column), or `null`.
    zzero_kw: ?f64,
    /// `ZBLANK` keyword (used when there is no per-tile `ZBLANK` column), or `null`.
    zblank_kw: ?i64,

    /// Build a tiled-image view over `hdu`. Requires `ZIMAGE = T` (else `error.WrongHduType`)
    /// and a `BINTABLE` (validated by `BinTable.of`). Parses every mandatory `Z*` keyword
    /// (`ZCMPTYPE`, `ZBITPIX`, `ZNAXIS`, `ZNAXISn`) — a missing one is `error.BadTiling`, an
    /// invalid `ZBITPIX` is `error.BadBitpix` — applies the `ZTILEn` defaults, records
    /// `ZQUANTIZ`/`ZDITHER0` and the `ZNAMEn`/`ZVALn` pairs, and resolves the payload columns.
    /// The pixel product is validated against `Limits.max_naxis_product` before any later
    /// allocation. Takes a borrow of `fits`/`hdu`; releases its own owned state in `deinit`.
    pub fn of(fits: *Fits, hdu: *Hdu) OfError!TiledImage {
        const alloc = fits.alloc;

        // Gate on ZIMAGE = T (anything else is not a tiled-compressed image).
        const zimage = hdu.header.getValue(bool, "ZIMAGE") catch return error.WrongHduType;
        if (!zimage) return error.WrongHduType;

        var base = try BinTable.of(fits, hdu);
        errdefer base.deinit(alloc);

        // ZCMPTYPE (mandatory).
        const ztype = blk: {
            const s = hdu.header.getString(alloc, "ZCMPTYPE") catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadTiling,
            };
            defer alloc.free(s);
            break :blk Codec.fromName(s);
        };

        // ZBITPIX (mandatory).
        const zbitpix = hdu.header.getValue(i64, "ZBITPIX") catch return error.BadTiling;
        if (!validBitpix(zbitpix)) return error.BadBitpix;

        // ZNAXIS (mandatory).
        const znaxis_i = hdu.header.getValue(i64, "ZNAXIS") catch return error.BadTiling;
        if (znaxis_i < 0 or znaxis_i > 999) return error.BadTiling;
        const znaxis: u16 = @intCast(znaxis_i);

        // ZNAXISn (mandatory) and ZTILEn (defaulted).
        const znaxisn = try alloc.alloc(u64, znaxis);
        errdefer alloc.free(znaxisn);
        const ztilen = try alloc.alloc(u64, znaxis);
        errdefer alloc.free(ztilen);

        var nb: [16]u8 = undefined;
        for (0..znaxis) |i| {
            const kw = std.fmt.bufPrint(&nb, "ZNAXIS{d}", .{i + 1}) catch unreachable;
            const v = hdu.header.getValue(i64, kw) catch return error.BadTiling;
            if (v < 0) return error.BadTiling;
            znaxisn[i] = @intCast(v);
        }
        for (0..znaxis) |i| {
            const kw = std.fmt.bufPrint(&nb, "ZTILE{d}", .{i + 1}) catch unreachable;
            const def: i64 = if (i == 0) @intCast(znaxisn[0]) else 1;
            const v = hdu.header.getValue(i64, kw) catch def;
            if (v <= 0) return error.BadTiling;
            ztilen[i] = @intCast(v);
        }

        // Validate the pixel product against the configured ceiling before later allocation.
        const npix = try limits.naxisProduct(znaxisn, fits.limits.max_naxis_product);

        // Tile count = product of per-axis covering-tile counts (handles non-multiple sizes). It
        // must equal the table row count: each tile is one BINTABLE row. Validate up front (parity
        // with TileTable.ofTable) so a mismatched geometry fails with a clear BadTiling rather than
        // a later, less-specific RowOutOfRange on the first tile access.
        var ntiles_total: u64 = 1;
        for (0..znaxis) |i| {
            ntiles_total = try limits.mul(ntiles_total, ceilDiv(znaxisn[i], ztilen[i]));
        }
        if (ntiles_total != base.naxis2) return error.BadTiling;

        // ZQUANTIZ / ZDITHER0 (optional, recorded).
        const quantize = blk: {
            const s = hdu.header.getString(alloc, "ZQUANTIZ") catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blk Quantize.none,
            };
            defer alloc.free(s);
            break :blk Quantize.fromName(s);
        };
        const zdither0: ?i64 = hdu.header.getValue(i64, "ZDITHER0") catch null;

        // ZNAMEn / ZVALn (optional, recorded).
        const params = try parseParams(alloc, hdu);
        errdefer freeParams(alloc, params);

        // Payload + scaling columns (case-insensitive, exact names).
        const comp_col = findCol(&base, "COMPRESSED_DATA");
        const gzip_col = findCol(&base, "GZIP_COMPRESSED_DATA");
        const uncomp_col = findCol(&base, "UNCOMPRESSED_DATA");
        const zscale_col = findCol(&base, "ZSCALE");
        const zzero_col = findCol(&base, "ZZERO");
        const zblank_col = findCol(&base, "ZBLANK");

        // Keyword fallbacks for ZSCALE/ZZERO/ZBLANK when there is no per-tile column.
        const zscale_kw: ?f64 = if (zscale_col == null) (hdu.header.getValue(f64, "ZSCALE") catch null) else null;
        const zzero_kw: ?f64 = if (zzero_col == null) (hdu.header.getValue(f64, "ZZERO") catch null) else null;
        // ZBLANK falls back to a plain BLANK keyword: fpack copies the source image's BLANK
        // into the compressed header without renaming it, and CFITSIO's reader
        // (imcomp_get_compressed_image_par) tries ZBLANK then BLANK. Mirror that order.
        const zblank_kw: ?i64 = if (zblank_col == null) blk: {
            const z: ?i64 = hdu.header.getValue(i64, "ZBLANK") catch null;
            break :blk z orelse (hdu.header.getValue(i64, "BLANK") catch null);
        } else null;

        return .{
            .base = base,
            .fits = fits,
            .hdu = hdu,
            .ztype = ztype,
            .zbitpix = zbitpix,
            .znaxis = znaxis,
            .znaxisn = znaxisn,
            .ztilen = ztilen,
            .npix = npix,
            .ntiles_total = ntiles_total,
            .quantize = quantize,
            .zdither0 = zdither0,
            .params = params,
            .comp_col = comp_col,
            .gzip_col = gzip_col,
            .uncomp_col = uncomp_col,
            .zscale_col = zscale_col,
            .zzero_col = zzero_col,
            .zblank_col = zblank_col,
            .zscale_kw = zscale_kw,
            .zzero_kw = zzero_kw,
            .zblank_kw = zblank_kw,
        };
    }

    /// Release all owned state (columns, dimension arrays, codec parameters).
    pub fn deinit(self: *TiledImage, alloc: Allocator) void {
        freeParams(alloc, self.params);
        alloc.free(self.znaxisn);
        alloc.free(self.ztilen);
        self.base.deinit(alloc);
    }

    /// The uncompressed image dimensions (`ZNAXISn`, most-rapidly-varying first).
    pub fn dims(self: *const TiledImage) []const u64 {
        return self.znaxisn;
    }

    /// The number of elements in the uncompressed image (product of `ZNAXISn`).
    pub fn elementCount(self: *const TiledImage) u64 {
        return self.npix;
    }

    /// The number of tiles covering the image (product of `ceil(ZNAXISn/ZTILEn)`); also the
    /// number of table rows.
    pub fn tileCount(self: *const TiledImage) u64 {
        return self.ntiles_total;
    }

    /// Decode every covering tile and place its pixels into `out` (row-major, first axis
    /// fastest), converting each stored value to `T` under the bulk policy and applying the
    /// per-tile `ZSCALE`/`ZZERO` (`physical = ZZERO + ZSCALE × stored`) when present.
    ///
    /// `out.len` must equal `elementCount()` (else `error.BadDimensions`). An unimplemented
    /// `ZCMPTYPE` is `error.UnsupportedCodec`; a tile that decodes to the wrong byte length is
    /// `error.CorruptTile`. Per-tile data is taken from `COMPRESSED_DATA`, falling back to
    /// `GZIP_COMPRESSED_DATA` then `UNCOMPRESSED_DATA` when a tile's `COMPRESSED_DATA` cell is
    /// empty; a tile with no payload at all reads as zeros.
    pub fn readAll(self: *TiledImage, comptime T: type, out: []T) ReadError!void {
        if (out.len != self.npix) return error.BadDimensions;
        if (!self.ztype.isImplemented()) return error.UnsupportedCodec;
        // Lossy float compression: the stored tile values are quantized 32-bit integers, not the
        // raw IEEE floats. The signal that a float image was quantized is the presence of a linear
        // scale (`isScaled()` — a per-tile `ZSCALE` column, as CFITSIO emits, or a global `ZSCALE`
        // keyword, which `tileScale` also honors), NOT the dither method — a `NO_DITHER` file
        // (`fpack -q0`) is quantized too, just without the subtractive offset.
        // Route every quantized float tile through the integer-decode path, which applies the
        // per-tile linear map and (for `SUBTRACTIVE_DITHER_*`) the dither offset; `NO_DITHER`
        // uses `kind == .none`, i.e. the linear map with no offset. An unrecognized `ZQUANTIZ`
        // cannot be decoded safely — error rather than guess (CFITSIO does the same).
        if (self.zbitpix < 0 and self.isScaled()) {
            if (self.quantize == .unknown) return error.UnsupportedCodec;
            return self.readAllDithered(T, out);
        }
        switch (self.zbitpix) {
            8 => try self.readAllTyped(T, u8, out),
            16 => try self.readAllTyped(T, i16, out),
            32 => try self.readAllTyped(T, i32, out),
            64 => try self.readAllTyped(T, i64, out),
            -32 => try self.readAllTyped(T, f32, out),
            -64 => try self.readAllTyped(T, f64, out),
            else => return error.BadBitpix,
        }
    }

    // ── internals ──────────────────────────────────────────────────────────────────────────

    fn readAllTyped(self: *TiledImage, comptime T: type, comptime Stored: type, out: []T) ReadError!void {
        const alloc = self.fits.alloc;
        const n = self.znaxis;
        const w = @sizeOf(Stored);

        // Per-axis covering-tile counts, image strides, and per-tile start/dim scratch.
        const ntiles = try alloc.alloc(u64, n);
        defer alloc.free(ntiles);
        const img_stride = try alloc.alloc(u64, n);
        defer alloc.free(img_stride);
        const tstart = try alloc.alloc(u64, n);
        defer alloc.free(tstart);
        const tdim = try alloc.alloc(u64, n);
        defer alloc.free(tdim);

        var stride: u64 = 1;
        for (0..n) |i| {
            img_stride[i] = stride;
            stride = try limits.mul(stride, self.znaxisn[i]);
        }
        for (0..n) |i| ntiles[i] = ceilDiv(self.znaxisn[i], self.ztilen[i]);

        const scaled = self.isScaled();

        var row: u64 = 0;
        while (row < self.ntiles_total) : (row += 1) {
            // Tile coordinates → covered pixel range (clipped at the image bound for edge tiles).
            var rem = row;
            var npix_tile: u64 = 1;
            for (0..n) |i| {
                const c = rem % ntiles[i];
                rem /= ntiles[i];
                tstart[i] = try limits.mul(c, self.ztilen[i]);
                const end = @min(tstart[i] + self.ztilen[i], self.znaxisn[i]);
                tdim[i] = end - tstart[i];
                npix_tile = try limits.mul(npix_tile, tdim[i]);
            }
            if (npix_tile == 0) continue;

            const zs: f64 = if (scaled) try self.tileScale(row) else 1.0;
            const zz: f64 = if (scaled) try self.tileZero(row) else 0.0;
            // Resolve the per-tile/keyword `ZBLANK` (integer images only; `BLANK` is undefined for
            // floating images). A decoded stored value equal to `ZBLANK` is the null marker.
            const blank: ?i64 = if (@typeInfo(Stored) == .int) try self.tileBlank(row) else null;

            const expected = try limits.mul(npix_tile, w);
            try limits.ensureWithin(expected, self.fits.limits.max_tile_bytes, null);

            const stored_bytes = try self.decodeTile(alloc, row, w, expected, npix_tile, tdim);
            defer alloc.free(stored_bytes);
            if (stored_bytes.len != @as(usize, @intCast(expected))) return error.CorruptTile;

            // Place each tile-local pixel at its full-image position.
            var p: u64 = 0;
            while (p < npix_tile) : (p += 1) {
                var rp = p;
                var full: u64 = 0;
                for (0..n) |i| {
                    const c = rp % tdim[i];
                    rp /= tdim[i];
                    full += (tstart[i] + c) * img_stride[i];
                }
                const byteoff: usize = @intCast(p * w);
                const s = endian.read(Stored, stored_bytes[byteoff..][0..w]);
                // `ZBLANK` null substitution, mirroring the uncompressed image layer: a floating
                // output type receives NaN; an integer output type has no representable null, so the
                // raw `ZBLANK` value passes through unchanged.
                if (@typeInfo(Stored) == .int) {
                    if (blank) |bl| {
                        if (@as(i64, s) == bl) {
                            if (nullSubstitute(T)) |nv| {
                                out[@intCast(full)] = nv;
                                continue;
                            }
                        }
                    }
                }
                const val: T = if (scaled) v: {
                    const sf: f64 = switch (@typeInfo(Stored)) {
                        .int => @floatFromInt(s),
                        .float => @floatCast(s),
                        else => unreachable,
                    };
                    break :v try convert.cast(T, zz + zs * sf, .bulk);
                } else try convert.cast(T, s, .bulk);
                out[@intCast(full)] = val;
            }
        }
    }

    // Lossy-float read path (FITS 4.0 §10.2): the stored tile values are quantized 32-bit
    // integers. Each tile is decoded as `i32`, then every pixel is reconstructed with the
    // per-tile linear map (`physical = ZZERO + ZSCALE × stored`) plus the subtractive-dither
    // offset drawn from the global random table at `tileOffset(ZDITHER0, row)`. The cursor
    // advances one draw per pixel in tile-local order, exactly as the encoder, so the two stay in
    // lock-step. A `null_value`-coded pixel reads back as NaN.
    fn readAllDithered(self: *TiledImage, comptime T: type, out: []T) ReadError!void {
        const alloc = self.fits.alloc;
        const n = self.znaxis;
        const w: usize = 4; // quantized integers are always 32-bit (CFITSIO convention)

        const ntiles = try alloc.alloc(u64, n);
        defer alloc.free(ntiles);
        const img_stride = try alloc.alloc(u64, n);
        defer alloc.free(img_stride);
        const tstart = try alloc.alloc(u64, n);
        defer alloc.free(tstart);
        const tdim = try alloc.alloc(u64, n);
        defer alloc.free(tdim);

        var stride: u64 = 1;
        for (0..n) |i| {
            img_stride[i] = stride;
            stride = try limits.mul(stride, self.znaxisn[i]);
        }
        for (0..n) |i| ntiles[i] = ceilDiv(self.znaxisn[i], self.ztilen[i]);

        const table = try dither.fitsRandom(alloc);
        defer alloc.free(table);
        const kind = self.quantize.toDitherKind();
        // A dithered file missing ZDITHER0 defaults to seed 1 (CFITSIO's default), matching the
        // write path (`CompressSpec.zdither0 = 1`) and how funpack reads such a file.
        const zd = self.zdither0 orelse 1;
        const nan = std.math.nan(f64);

        var row: u64 = 0;
        while (row < self.ntiles_total) : (row += 1) {
            var rem = row;
            var npix_tile: u64 = 1;
            for (0..n) |i| {
                const c = rem % ntiles[i];
                rem /= ntiles[i];
                tstart[i] = try limits.mul(c, self.ztilen[i]);
                const end = @min(tstart[i] + self.ztilen[i], self.znaxisn[i]);
                tdim[i] = end - tstart[i];
                npix_tile = try limits.mul(npix_tile, tdim[i]);
            }
            if (npix_tile == 0) continue;

            const src = try self.tileSource(row);
            if (src == .compressed) {
                // Quantized-integer tile: 32-bit stored values, per-tile linear map + dither.
                const zs = try self.tileScale(row);
                const zz = try self.tileZero(row);
                // The null sentinel is the declared `ZBLANK` when present, otherwise the reserved
                // `null_value` handled inside `unquantizeNext`.
                const blank: ?i64 = try self.tileBlank(row);
                const expected = try limits.mul(npix_tile, w);
                try limits.ensureWithin(expected, self.fits.limits.max_tile_bytes, null);
                const stored_bytes = try self.decodeTile(alloc, row, w, expected, npix_tile, tdim);
                defer alloc.free(stored_bytes);
                if (stored_bytes.len != @as(usize, @intCast(expected))) return error.CorruptTile;
                var cur = dither.Dither.init(table, kind, zd, row);
                var p: u64 = 0;
                while (p < npix_tile) : (p += 1) {
                    var rp = p;
                    var full: u64 = 0;
                    for (0..n) |i| {
                        const c = rp % tdim[i];
                        rp /= tdim[i];
                        full += (tstart[i] + c) * img_stride[i];
                    }
                    const byteoff: usize = @intCast(p * w);
                    const s = endian.read(i32, stored_bytes[byteoff..][0..w]);
                    // `unquantizeNext` always advances the dither cursor (keeping it in lock-step
                    // with the encoder) and maps the reserved `null_value` to NaN; a declared
                    // `ZBLANK` overrides that sentinel so its pixels also read back as NaN.
                    const fval = cur.unquantizeNext(s, zs, zz, nan);
                    const sub: f64 = if (blank) |bl| (if (@as(i64, s) == bl) nan else fval) else fval;
                    out[@intCast(full)] = try convert.cast(T, sub, .bulk);
                }
            } else {
                // Lossless-fallback (GZIP_COMPRESSED_DATA/UNCOMPRESSED_DATA) or an empty tile: the
                // payload is the raw IEEE floats of the original ZBITPIX width, stored verbatim (a
                // tile CFITSIO chose not to quantize — e.g. a constant or ±Inf tile). Read them
                // directly, with no linear map and no dither; NaN passes through unchanged.
                const fw = bitpixWidth(self.zbitpix); // 4 for -32, 8 for -64
                const expected = try limits.mul(npix_tile, fw);
                try limits.ensureWithin(expected, self.fits.limits.max_tile_bytes, null);
                const raw = try self.decodeTile(alloc, row, fw, expected, npix_tile, tdim);
                defer alloc.free(raw);
                if (raw.len != @as(usize, @intCast(expected))) return error.CorruptTile;
                var p: u64 = 0;
                while (p < npix_tile) : (p += 1) {
                    var rp = p;
                    var full: u64 = 0;
                    for (0..n) |i| {
                        const c = rp % tdim[i];
                        rp /= tdim[i];
                        full += (tstart[i] + c) * img_stride[i];
                    }
                    const byteoff: usize = @intCast(p * fw);
                    const fval: f64 = switch (self.zbitpix) {
                        -32 => @as(f64, endian.read(f32, raw[byteoff..][0..4])),
                        -64 => endian.read(f64, raw[byteoff..][0..8]),
                        else => return error.BadBitpix,
                    };
                    out[@intCast(full)] = try convert.cast(T, fval, .bulk);
                }
            }
        }
    }

    // Decode (or read) the stored-value bytes of tile `row`, choosing the payload column per the
    // §10.1 precedence: COMPRESSED_DATA → GZIP_COMPRESSED_DATA → UNCOMPRESSED_DATA → all-zero.
    // The gzip decode ceiling is `expected + 1`: `std`'s bounded reader reports `StreamTooLong`
    // when the stream meets *or exceeds* the limit, so an exact-size tile needs headroom of one
    // byte; the caller's `stored_bytes.len == expected` check still enforces exactness. RICE/PLIO/
    // HCOMPRESS produce stored values that this routine re-encodes big-endian (width `w`) so the
    // common placement loop can read them with `endian.read`.
    fn decodeTile(self: *TiledImage, alloc: Allocator, row: u64, w: usize, expected: u64, npix_tile: u64, tdim: []const u64) ReadError![]u8 {
        const cap = expected + 1;
        if (self.comp_col) |col| {
            if (try self.hasData(col, row)) {
                const cbytes = try self.readDescBytes(alloc, col, row);
                defer alloc.free(cbytes);
                return self.decodeCompressed(alloc, cbytes, w, npix_tile, tdim, cap);
            }
        }
        if (self.gzip_col) |col| {
            if (try self.hasData(col, row)) {
                const cbytes = try self.readDescBytes(alloc, col, row);
                defer alloc.free(cbytes);
                return try gzip.gzipDecode(alloc, cbytes, cap);
            }
        }
        if (self.uncomp_col) |col| {
            if (try self.hasData(col, row)) {
                const rbytes = try self.readDescBytes(alloc, col, row);
                errdefer alloc.free(rbytes);
                if (rbytes.len != @as(usize, @intCast(expected))) return error.CorruptTile;
                return rbytes;
            }
        }
        const z = try alloc.alloc(u8, @intCast(expected));
        @memset(z, 0);
        return z;
    }

    // Dispatch the `COMPRESSED_DATA` cell bytes to the codec named by `ZCMPTYPE`, returning the
    // tile's stored values as **big-endian** width-`w` bytes (the form the placement loop reads).
    // RICE_1 takes `BLOCKSIZE` from the `ZNAMEn`/`ZVALn` parameters and its stored-value width
    // from `w`; HCOMPRESS_1 needs the 2-D tile dims (`tdim[0]` fastest = columns, `tdim[1]` = rows).
    fn decodeCompressed(self: *TiledImage, alloc: Allocator, cbytes: []const u8, w: usize, npix_tile: u64, tdim: []const u64, cap: u64) ReadError![]u8 {
        switch (self.ztype) {
            .gzip_1 => return gzip.gzipDecode(alloc, cbytes, cap),
            .gzip_2 => return gzip.gzip2Decode(alloc, cbytes, w, cap),
            .rice_1 => {
                const bytepix = std.math.cast(u8, w) orelse return error.DataConstraintViolated;
                const bs_i = self.paramInt("BLOCKSIZE") orelse 32;
                const blocksize = std.math.cast(u32, bs_i) orelse return error.BadTiling;
                const native = try rice.decompress(alloc, cbytes, @intCast(npix_tile), bytepix, blocksize);
                defer alloc.free(native);
                return nativeToBig(alloc, native, w);
            },
            .plio_1 => {
                const vals = try plio.decompress(alloc, cbytes, @intCast(npix_tile));
                defer alloc.free(vals);
                return i32ToBig(alloc, vals, w, .strict);
            },
            .hcompress_1 => {
                if (self.znaxis < 2) return error.BadTiling;
                // Validate the stream's declared nx/ny against the KNOWN tile geometry BEFORE the
                // codec allocates from them (it sizes its mag/a arrays by nx*ny). Without this the
                // other codecs are bounded by npix_tile/cap but HCOMPRESS would allocate ~nx*ny*16
                // bytes from an attacker-controlled ~18-byte cell (NFR-SAFE-1 unbounded-alloc DoS).
                // hcompress stores nx then ny big-endian after the 2-byte magic; it returns
                // nx==tdim[1] (rows), ny==tdim[0] (fastest/cols).
                if (cbytes.len < 10 or cbytes[0] != 0xDD or cbytes[1] != 0x99) return error.CorruptTile;
                const sx = std.mem.readInt(u32, cbytes[2..][0..4], .big);
                const sy = std.mem.readInt(u32, cbytes[6..][0..4], .big);
                if (sx != tdim[1] or sy != tdim[0]) return error.CorruptTile;
                // `ZNAME2 = 'SMOOTH'`/`ZVAL2` (FITS 4.0 Table 39) requests decode-side
                // coefficient smoothing (CFITSIO `hcomp_smooth`); absent or zero means none.
                // The quantization scale itself comes from each tile's embedded stream header —
                // `ZVAL1` (SCALE) is advisory, exactly as in CFITSIO.
                // Deliberate divergence: the flag is looked up by NAME ('SMOOTH', any n), while
                // CFITSIO reads ZVAL2 positionally regardless of what ZNAME2 says. Identical on
                // every conforming file (CFITSIO always writes ZNAME2='SMOOTH'); on a
                // hand-crafted header with a mislabeled ZNAME2, honoring the declared name is
                // the safer reading.
                const smooth = (self.paramNum("SMOOTH") orelse 0) != 0;
                const dec = try hcompress.decompress(alloc, cbytes, @intCast(npix_tile), .{ .smooth = smooth });
                defer alloc.free(dec.data);
                if (dec.ny != tdim[0] or dec.nx != tdim[1]) return error.CorruptTile;
                // `.clamp`: a lossy reconstruction may overshoot the ZBITPIX range; CFITSIO
                // clips those values, so funpack-readable files must stay readable here.
                return i32ToBig(alloc, dec.data, w, .clamp);
            },
            .unknown => return error.UnsupportedCodec,
        }
    }

    // The integer value of a `ZNAMEn`/`ZVALn` codec parameter (case-insensitive), or `null`.
    fn paramInt(self: *const TiledImage, key: []const u8) ?i64 {
        for (self.params) |p| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, p.name, " "), key)) {
                return switch (p.value) {
                    .int => |v| v,
                    else => null,
                };
            }
        }
        return null;
    }

    // Like `paramInt`, but also coerces a float-valued card (truncating toward zero). CFITSIO
    // writes HCOMPRESS `ZVAL1` as a float and reads `ZVAL2` with implicit numeric conversion,
    // so both card forms occur in the wild for numeric codec parameters.
    fn paramNum(self: *const TiledImage, key: []const u8) ?i64 {
        for (self.params) |p| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, p.name, " "), key)) {
                return switch (p.value) {
                    .int => |v| v,
                    .float => |v| if (std.math.isFinite(v)) std.math.lossyCast(i64, @trunc(v)) else null,
                    else => null,
                };
            }
        }
        return null;
    }

    // Whether the VLA cell at (`row`, `col`) holds a non-empty payload.
    fn hasData(self: *TiledImage, col: u16, row: u64) heap.DescriptorError!bool {
        const d = try heap.readDescriptor(&self.base, .{ .index = col }, row);
        return d.len > 0;
    }

    // Which column supplies tile `row`'s payload, per the §10.1 precedence. On the quantized-float
    // read path this distinguishes a quantized-integer tile (`.compressed`) from a losslessly-
    // stored raw-float fallback tile (`.gzip`/`.uncompressed`), which must be read as raw IEEE
    // floats rather than unquantized. `.none` is an empty (all-zero) tile.
    const TileSource = enum { compressed, gzip, uncompressed, none };
    fn tileSource(self: *TiledImage, row: u64) heap.DescriptorError!TileSource {
        if (self.comp_col) |col| {
            if (try self.hasData(col, row)) return .compressed;
        }
        if (self.gzip_col) |col| {
            if (try self.hasData(col, row)) return .gzip;
        }
        if (self.uncomp_col) |col| {
            if (try self.hasData(col, row)) return .uncompressed;
        }
        return .none;
    }

    // Read the raw (big-endian, untranslated) payload bytes of the VLA cell at (`row`, `col`):
    // `descriptor.len × elemBytes` bytes, bounds-checked against the heap, the data unit, and
    // the device length before allocating (NFR-SAFE-1).
    fn readDescBytes(self: *TiledImage, alloc: Allocator, col: u16, row: u64) heap.ReadError![]u8 {
        return readVlaRawBytes(&self.base, alloc, col, row);
    }

    // Whether any per-tile scaling (ZSCALE/ZZERO column or keyword) is in effect.
    fn isScaled(self: *const TiledImage) bool {
        return self.zscale_col != null or self.zzero_col != null or
            self.zscale_kw != null or self.zzero_kw != null;
    }

    fn tileScale(self: *TiledImage, row: u64) binary.AccessError!f64 {
        if (self.zscale_col) |col| {
            var buf: [1]f64 = undefined;
            try self.base.readColumn(f64, .{ .index = col }, row, &buf, .{});
            return buf[0];
        }
        return self.zscale_kw orelse 1.0;
    }

    fn tileZero(self: *TiledImage, row: u64) binary.AccessError!f64 {
        if (self.zzero_col) |col| {
            var buf: [1]f64 = undefined;
            try self.base.readColumn(f64, .{ .index = col }, row, &buf, .{});
            return buf[0];
        }
        return self.zzero_kw orelse 0.0;
    }

    // The effective `ZBLANK` for tile `row`: the per-tile column value when a `ZBLANK` column is
    // present, else the `ZBLANK` keyword (or `null` when neither is declared).
    fn tileBlank(self: *TiledImage, row: u64) binary.AccessError!?i64 {
        if (self.zblank_col) |col| {
            var buf: [1]i64 = undefined;
            try self.base.readColumn(i64, .{ .index = col }, row, &buf, .{});
            return buf[0];
        }
        return self.zblank_kw;
    }
};

// ── helpers ──────────────────────────────────────────────────────────────────────────────

fn validBitpix(b: i64) bool {
    return switch (b) {
        8, 16, 32, 64, -32, -64 => true,
        else => false,
    };
}

// The null substitute emitted for a `ZBLANK` pixel decoded into output type `T`: NaN for a floating
// `T`, and `null` (no substitution) for an integer `T`, which cannot represent a null value (the raw
// `ZBLANK` then passes through). Mirrors the uncompressed image layer's null handling.
fn nullSubstitute(comptime T: type) ?T {
    return switch (@typeInfo(T)) {
        .float => std.math.nan(T),
        else => null,
    };
}

// Element byte width for a (valid) BITPIX/ZBITPIX.
fn bitpixWidth(b: i64) usize {
    return switch (b) {
        8 => 1,
        16 => 2,
        32, -32 => 4,
        64, -64 => 8,
        else => unreachable,
    };
}

// Read the raw (big-endian, untranslated) payload bytes of the VLA cell at (`row`, `col`):
// `descriptor.len × elemBytes` bytes, bounds-checked against the heap, the data unit, and the
// device length before allocating (NFR-SAFE-1). Shared by the image and table read paths.
fn readVlaRawBytes(base: *BinTable, alloc: Allocator, col: u16, row: u64) heap.ReadError![]u8 {
    const fits = base.fits;
    const column = &base.columns[col];
    const spec = try heap.VlaSpec.of(column);
    const d = try heap.readDescriptor(base, .{ .index = col }, row);
    if (d.len < 0 or d.off < 0) return error.BadDescriptor;
    const count: u64 = @intCast(d.len);
    const off: u64 = @intCast(d.off);
    const bytes = try limits.mul(count, spec.elem.elemBytes());
    try limits.ensureWithin(bytes, fits.limits.max_heap_bytes, null);

    const geom = try heap.heapGeometry(base);
    const heap_end = std.math.add(u64, off, bytes) catch return error.BadDescriptor;
    if (heap_end > geom.heap_size) return error.BadDescriptor;
    const abs = geom.heap_abs_off + off;
    const abs_end = abs + bytes;
    if (abs_end > geom.data_abs_end) return error.BadDescriptor;
    const dev_size = try fits.dev.getSize();
    if (abs_end > dev_size) return error.BadDescriptor;

    // Narrow FALLIBLY: max_heap_bytes (default 1<<34) exceeds a 32-bit usize, so a plain @intCast
    // could panic on wasm32 for a large heap; reject an out-of-usize-range size instead (NFR-SAFE-1).
    const buf_len = std.math.cast(usize, bytes) orelse return error.LimitExceeded;
    const buf = try alloc.alloc(u8, buf_len);
    errdefer alloc.free(buf);
    try fits.dev.readAll(buf, abs);
    return buf;
}

// Re-encode `native` (native-endian, width `w` per element) as big-endian element bytes so the
// stored-value placement loop can read them uniformly with `endian.read`.
fn nativeToBig(alloc: Allocator, native: []const u8, w: usize) (errors.CompressError || Allocator.Error)![]u8 {
    if (w == 0 or native.len % w != 0) return error.CorruptTile;
    const out = try alloc.alloc(u8, native.len);
    errdefer alloc.free(out);
    var i: usize = 0;
    while (i < native.len) : (i += w) {
        switch (w) {
            1 => out[i] = native[i],
            2 => std.mem.writeInt(u16, out[i..][0..2], std.mem.readInt(u16, native[i..][0..2], native_endian), .big),
            4 => std.mem.writeInt(u32, out[i..][0..4], std.mem.readInt(u32, native[i..][0..4], native_endian), .big),
            8 => std.mem.writeInt(u64, out[i..][0..8], std.mem.readInt(u64, native[i..][0..8], native_endian), .big),
            else => return error.DataConstraintViolated,
        }
    }
    return out;
}

// How `i32ToBig` treats a decoded value that does not fit the declared `ZBITPIX` width.
const RangeMode = enum {
    // Reject with a typed error rather than silently `@truncate` — every other conversion path
    // in the library is checked. Right for PLIO_1, whose decode is lossless: an out-of-spec
    // mask value (> 255 packed as `w == 1`) can only mean a corrupt file.
    strict,
    // Clamp to the width's value range. Right for HCOMPRESS_1, whose LOSSY reconstruction can
    // legitimately overshoot the type range near its boundary — CFITSIO treats that overflow as
    // expected (imcompress.c clips and, "Hcompress is a special case", resets NUM_OVERFLOW), so
    // every `fpack -h -s N` integer file whose reconstruction overshoots decodes fine under
    // funpack; a strict reject would make that whole file class unreadable. Conscious details:
    //  * The clamp applies to EVERY HCOMPRESS_1 stream, including a lossless (scale <= 1) one
    //    that decodes out-of-range — CFITSIO's status reset doesn't inspect the scale either.
    //  * It happens at the ZBITPIX narrowing, so reading with a WIDER output type still yields
    //    the clamped boundary value (funpack's file-level decode, the parity target). CFITSIO's
    //    own API clips at the OUTPUT-type conversion instead: fits_read_img(TINT) on a
    //    ZBITPIX=16 file returns the raw overshot integer.
    //  * For `w == 1` CFITSIO also clips the pixels but leaves the overflow status set (only
    //    its TSHORT branch resets) — we clamp silently for both widths, the consistent reading
    //    of an artifact CFITSIO itself documents as expected.
    //  * A clamped pixel that lands exactly on `ZBLANK` reads as blank (our blank compare runs
    //    on the narrowed value, CFITSIO's pre-clip — reachable only by a lossy file declaring
    //    an in-range ZBLANK).
    clamp,
};

// Pack `vals` as big-endian signed integers of width `w`. Used for PLIO_1 / HCOMPRESS_1, which
// both produce `i32` stored values. Out-of-width values are handled per `mode` (above).
fn i32ToBig(alloc: Allocator, vals: []const i32, w: usize, mode: RangeMode) (errors.CompressError || Allocator.Error)![]u8 {
    const out = try alloc.alloc(u8, vals.len * w);
    errdefer alloc.free(out);
    for (vals, 0..) |v, idx| {
        const off = idx * w;
        switch (w) {
            // BITPIX=8 is UNSIGNED (0..255): accept the full byte range (a bright pixel like 200
            // is valid) and treat only genuinely out-of-range decodes per `mode`, rather than
            // casting to a signed i8 whose 127 ceiling would drop legitimate values 128..255.
            1 => std.mem.writeInt(u8, out[off..][0..1], switch (mode) {
                .strict => std.math.cast(u8, v) orelse return error.DataConstraintViolated,
                .clamp => @intCast(std.math.clamp(v, 0, std.math.maxInt(u8))),
            }, .big),
            2 => std.mem.writeInt(i16, out[off..][0..2], switch (mode) {
                .strict => std.math.cast(i16, v) orelse return error.DataConstraintViolated,
                .clamp => @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16))),
            }, .big),
            4 => std.mem.writeInt(i32, out[off..][0..4], v, .big),
            8 => std.mem.writeInt(i64, out[off..][0..8], v, .big),
            else => return error.DataConstraintViolated,
        }
    }
    return out;
}

// Covering-tile count along one axis: ceil(len/tile), with 0 for a zero-length axis. `tile` is
// guaranteed positive by `of`.
fn ceilDiv(len: u64, tile: u64) u64 {
    if (len == 0) return 0;
    return (len - 1) / tile + 1;
}

// First column index whose TTYPEn matches `name` (case-insensitive), or null.
fn findCol(base: *const BinTable, name: []const u8) ?u16 {
    var m: Matches = .{}; // first match only; internal resolution uses full capacity
    base.columnByName(name, &m);
    if (m.len == 0) return null;
    return @intCast(m.at(0));
}

fn freeParamValue(alloc: Allocator, v: ParamValue) void {
    switch (v) {
        .string => |s| alloc.free(s),
        else => {},
    }
}

fn freeParam(alloc: Allocator, p: *const Param) void {
    alloc.free(p.name);
    freeParamValue(alloc, p.value);
}

fn freeParams(alloc: Allocator, params: []Param) void {
    for (params) |*p| freeParam(alloc, p);
    alloc.free(params);
}

// Parse the contiguous ZNAMEn/ZVALn pairs (n = 1, 2, …) until ZNAMEn is absent. Each ZVALn is
// parsed as int, then float, then string, then recorded as undefined.
fn parseParams(alloc: Allocator, hdu: *Hdu) (errors.ValueError || errors.HeaderError || Allocator.Error)![]Param {
    var list: std.ArrayList(Param) = .empty;
    errdefer {
        for (list.items) |*p| freeParam(alloc, p);
        list.deinit(alloc);
    }
    var nb: [16]u8 = undefined;
    var idx: usize = 1;
    while (true) : (idx += 1) {
        const zname = std.fmt.bufPrint(&nb, "ZNAME{d}", .{idx}) catch unreachable;
        if (!hdu.header.has(zname)) break;
        const name = try hdu.header.getString(alloc, zname);
        errdefer alloc.free(name);

        var vb: [16]u8 = undefined;
        const zval = std.fmt.bufPrint(&vb, "ZVAL{d}", .{idx}) catch unreachable;
        var pv: ParamValue = .undef;
        if (hdu.header.getValue(i64, zval)) |iv| {
            pv = .{ .int = iv };
        } else |_| {
            if (hdu.header.getValue(f64, zval)) |fv| {
                pv = .{ .float = fv };
            } else |_| {
                if (hdu.header.getString(alloc, zval)) |sv| {
                    pv = .{ .string = sv };
                } else |_| {
                    pv = .undef;
                }
            }
        }
        errdefer freeParamValue(alloc, pv);
        try list.append(alloc, .{ .name = name, .value = pv });
    }
    return list.toOwnedSlice(alloc);
}

// ── compressed write (CMP-8) ───────────────────────────────────────────────────────────────

/// What `writeCompressed` should produce: the uncompressed image geometry, the tiling, the codec
/// and (for float images) the dither/quantization method.
pub const CompressSpec = struct {
    /// BITPIX of the uncompressed image (`8/16/32/64/-32/-64`); stored as `ZBITPIX`.
    bitpix: i64,
    /// `ZNAXISn` (most-rapidly-varying first); must be non-empty with non-zero extents.
    axes: []const u64,
    /// `ZTILEn`. `null` selects the default tiling: row strips (full first axis, 1 elsewhere),
    /// except HCOMPRESS_1, which uses CFITSIO's 2-D row-block rule (see `writeCompressed`).
    /// Deliberate divergence for EXPLICIT tiles: CFITSIO's author additionally rejects
    /// HCOMPRESS tiles/images with a dimension under 4 pixels (`imcomp_init_table`); zigfitsio
    /// accepts them (they encode/decode correctly here and in CFITSIO/funpack — the *decoders*
    /// take any dims), but be aware such files sit outside CFITSIO's authoring envelope, and
    /// Astropy refuses HCOMPRESS tiles that squeeze to one dimension (e.g. `{N, 1}`).
    tile: ?[]const u64 = null,
    /// `ZCMPTYPE`. The write path implements `GZIP_1`/`GZIP_2` (any BITPIX), `RICE_1`/`PLIO_1`/
    /// `HCOMPRESS_1` for integer 8/16/32-bit images, and `RICE_1`/`HCOMPRESS_1` additionally for
    /// QUANTIZED float images (`quantize` set to a quantizing method; HCOMPRESS requires
    /// `ZNAXIS ≥ 2` either way). Fail-loud rejections: PLIO + floats (`UnsupportedCodec` — its
    /// 0..2²⁴ range cannot hold quantized output), float + integer codec without quantization
    /// (`UnsupportedCodec` — CFITSIO would silently truncate floats to ints), HCOMPRESS +
    /// `subtractive_dither_2` (`DataConstraintViolated` — CFITSIO silently coerces to DITHER_1),
    /// other invalid codec/BITPIX pairings (`DataConstraintViolated`), and `.unknown`
    /// (`UnsupportedCodec`).
    codec: Codec = .gzip_1,
    /// `ZQUANTIZ`. For a float `bitpix`, `no_dither`/`subtractive_dither_1`/`_2` quantizes
    /// pixels to 32-bit integers with a per-tile linear map (FITS 4.0 §10.2) — the subtractive
    /// kinds add the dither offset — storing per-tile `ZSCALE`/`ZZERO` columns; the quantized
    /// integers then feed the codec (GZIP, RICE, or HCOMPRESS). `.none` stores float pixels
    /// losslessly (GZIP only). Ignored for integer images.
    quantize: Quantize = .none,
    /// `ZDITHER0` seed (used only when dithering).
    zdither0: i64 = 1,
    /// CFITSIO quantization level (`fits_set_quantize_level` / `fpack -q`), used when
    /// `quantize` is a quantizing method: `> 0` sets the per-tile step to `sigma/level` (sigma
    /// = the tile's MAD background noise, `compress/quantize.zig`), `0` means the CFITSIO
    /// default (`sigma/4`), `< 0` is the absolute step `|level|`. `null` selects the default
    /// with one backward-compatibility exception: the pre-existing dithered-GZIP combination
    /// keeps zigfitsio's legacy fixed `(max−min)/100000` per-tile scheme (bytes unchanged for
    /// existing callers) — set `quantize_level` explicitly (e.g. `4.0`) for CFITSIO-parity
    /// quantization there. Non-finite values, or setting this without a quantizing `quantize`
    /// method, are `error.DataConstraintViolated` (never silently ignored).
    quantize_level: ?f32 = null,
    /// HCOMPRESS_1 lossy scale request (CFITSIO `fits_set_hcomp_scale` semantics): `0` (the
    /// default) is lossless; `> 0` is noise-adaptive — each tile's integer scale becomes
    /// `round(request × sigma)` where sigma is the tile's background noise
    /// (`min(noise2, noise3, noise5)` MAD estimates, `imgstats.zig`); `< 0` uses `|request|`
    /// directly as every tile's absolute scale (deterministic, data-independent). The request
    /// is recorded as a float in `ZVAL1` (`ZNAME1 = 'SCALE'`), CFITSIO-identical. Non-finite
    /// values — or setting this on a non-HCOMPRESS codec — are `error.DataConstraintViolated`
    /// (never silently ignored).
    hcomp_scale: f32 = 0,
    /// HCOMPRESS_1 decode-side smoothing request, recorded as `ZNAME2 = 'SMOOTH'`/`ZVAL2`
    /// (CFITSIO `fits_set_hcomp_smooth`): conforming readers (zigfitsio, CFITSIO/funpack,
    /// Astropy) apply `hsmooth` when decompressing lossy tiles. It does not change the
    /// compressed bytes themselves and is a no-op for lossless (`hcomp_scale = 0`) files.
    /// Setting it on a non-HCOMPRESS codec is `error.DataConstraintViolated`.
    hcomp_smooth: bool = false,
};

/// Errors from `writeCompressed`.
pub const WriteCompressError = FitsError || errors.CompressError || errors.TableError;

/// Compress `pixels` (row-major, first axis fastest) into a new compressed-image `BINTABLE` HDU
/// appended to `fits`, returning the created HDU (read it back with `TiledImage.of`/`readAll`).
///
/// The mandatory `Z*` keywords are emitted (`ZIMAGE`, `ZCMPTYPE`, `ZBITPIX`, `ZNAXIS`, `ZNAXISn`,
/// `ZTILEn`, plus `ZQUANTIZ`/`ZDITHER0` for a dithered float image); the image is tiled and each
/// tile compressed and stored in the `COMPRESSED_DATA` (`1P`) heap column. For a dithered float
/// image the per-tile `ZSCALE`/`ZZERO` are stored as columns. RICE_1/PLIO_1/HCOMPRESS_1 dispatch
/// through `encodeRaw` for integer 8/16/32-bit images and emit their `ZNAMEn`/`ZVALn` parameters.
/// `error.UnsupportedCodec` for `.unknown`, `error.DataConstraintViolated` for an invalid codec/
/// BITPIX pairing, `error.BadDimensions` when `pixels.len` ≠ ∏`axes`.
pub fn writeCompressed(comptime T: type, fits: *Fits, spec: CompressSpec, pixels: []const T) WriteCompressError!*Hdu {
    const alloc = fits.alloc;
    if (fits.mode == .read_only or !fits.dev.isWritable()) return error.NotWritable;
    if (!validBitpix(spec.bitpix)) return error.BadBitpix;
    const codec_name = spec.codec.name() orelse return error.UnsupportedCodec;
    const znaxis = spec.axes.len;
    if (znaxis == 0 or znaxis > 999) return error.BadNaxis;

    var npix: u64 = 1;
    for (spec.axes) |a| {
        if (a == 0) return error.BadDimensions;
        npix = try limits.mul(npix, a);
    }
    if (pixels.len != npix) return error.BadDimensions;

    const w = bitpixWidth(spec.bitpix);
    const do_quantize = spec.bitpix < 0 and spec.quantize.isQuantized();
    const do_dither = spec.bitpix < 0 and spec.quantize.isDithered();
    // Quantizer selection: the CFITSIO fits_quantize port runs whenever the caller sets an
    // explicit `quantize_level`, uses `NO_DITHER`, or pairs quantization with an integer codec
    // (RICE/HCOMPRESS — new capability, CFITSIO-parity from day one). Only the pre-existing
    // combination — dithered GZIP with no `quantize_level` — keeps the legacy fixed
    // `(max−min)/100000` per-tile scheme, so existing callers' bytes are unchanged.
    const legacy_quant = do_dither and spec.quantize_level == null and
        (spec.codec == .gzip_1 or spec.codec == .gzip_2);
    // ZDITHER0 must be a positive integer 1..10000 (FITS 4.0 §10.2). An out-of-range seed writes a
    // non-conformant file and drives a CFITSIO reader's `fits_rand_value[]` index out of bounds.
    if (do_dither and (spec.zdither0 < 1 or spec.zdither0 > 10000)) return error.DataConstraintViolated;
    // The quantization knobs must never be silently ignored (fail loud): a `quantize_level` is
    // meaningful only when float pixels are being quantized, and must be finite.
    if (spec.quantize_level) |q| {
        if (!std.math.isFinite(q)) return error.DataConstraintViolated;
        if (!do_quantize) return error.DataConstraintViolated;
    }

    // Validate the codec/BITPIX pairing (CMP-8 write path). GZIP_1/GZIP_2 accept any BITPIX (they
    // store raw big-endian bytes). RICE_1/PLIO_1/HCOMPRESS_1 encode integer stored values, so they
    // take an integer image of 8/16/32 bits or a QUANTIZED float image (RICE/HCOMPRESS only;
    // 32-bit stored integers), and HCOMPRESS additionally requires a 2-D image.
    switch (spec.codec) {
        .gzip_1, .gzip_2 => {},
        .rice_1, .plio_1, .hcompress_1 => {
            if (spec.bitpix < 0) {
                // Float pixels reach an integer codec only through quantization. PLIO stays
                // excluded: its 0..2²⁴ range cannot hold the quantizer's output (CFITSIO permits
                // the attempt and errors per tile at runtime; zigfitsio rejects it up front).
                // A float image with `quantize = .none` is rejected too — CFITSIO would silently
                // TRUNCATE the floats to integers there (imcomp_nullfloats), a data-corrupting
                // implicit conversion zigfitsio refuses to perform.
                if (!do_quantize or spec.codec == .plio_1) return error.UnsupportedCodec;
                // CFITSIO forbids SUBTRACTIVE_DITHER_2 with HCOMPRESS and silently coerces it to
                // DITHER_1 (with an stderr warning); zigfitsio fails loud instead — never a
                // silent rewrite of the caller's stated method.
                if (spec.codec == .hcompress_1 and spec.quantize == .subtractive_dither_2)
                    return error.DataConstraintViolated;
            } else switch (spec.bitpix) {
                8, 16, 32 => {},
                else => return error.DataConstraintViolated,
            }
            if (spec.codec == .hcompress_1 and znaxis < 2) return error.BadTiling;
        },
        .unknown => return error.UnsupportedCodec,
    }
    // The HCOMPRESS lossy knobs must never be silently ignored: a non-finite scale request is
    // meaningless, and setting either knob with a different codec would produce a file that does
    // not honor the caller's stated intent (fail loud — never a silent mis-write).
    if (!std.math.isFinite(spec.hcomp_scale)) return error.DataConstraintViolated;
    if (spec.codec != .hcompress_1 and (spec.hcomp_scale != 0 or spec.hcomp_smooth))
        return error.DataConstraintViolated;

    const tile = try alloc.alloc(u64, znaxis);
    defer alloc.free(tile);
    if (spec.tile) |tl| {
        if (tl.len != znaxis) return error.BadTiling;
        for (tl, 0..) |v, i| {
            if (v == 0) return error.BadTiling;
            tile[i] = v;
        }
    } else {
        tile[0] = spec.axes[0];
        for (1..znaxis) |i| tile[i] = 1;
        if (spec.codec == .hcompress_1) {
            // CFITSIO's HCOMPRESS default tiling (`imcomp_init_table`): the codec is inherently
            // 2-D, so row-by-row strips (which Astropy even refuses to decode) are replaced by
            // row *blocks* — the whole image when it has ≤ 30 rows, otherwise the first block
            // height in CFITSIO's preference order whose last tile keeps at least 4 rows
            // (divides evenly or leaves a remainder > 3), falling back to 17.
            const nrows = spec.axes[1]; // znaxis ≥ 2 was validated above for HCOMPRESS
            if (nrows <= 30) {
                tile[1] = nrows;
            } else {
                tile[1] = 17;
                for ([_]u64{ 16, 24, 20, 30, 28, 26, 22, 18, 14 }) |cand| {
                    if (nrows % cand == 0 or nrows % cand > 3) {
                        tile[1] = cand;
                        break;
                    }
                }
            }
        }
    }

    const ntiles = try alloc.alloc(u64, znaxis);
    defer alloc.free(ntiles);
    const img_stride = try alloc.alloc(u64, znaxis);
    defer alloc.free(img_stride);
    const tstart = try alloc.alloc(u64, znaxis);
    defer alloc.free(tstart);
    const tdim = try alloc.alloc(u64, znaxis);
    defer alloc.free(tdim);

    var stride: u64 = 1;
    for (0..znaxis) |i| {
        img_stride[i] = stride;
        stride = try limits.mul(stride, spec.axes[i]);
    }
    var ntiles_total: u64 = 1;
    var tile_prod: u64 = 1;
    for (0..znaxis) |i| {
        ntiles[i] = ceilDiv(spec.axes[i], tile[i]);
        ntiles_total = try limits.mul(ntiles_total, ntiles[i]);
        tile_prod = try limits.mul(tile_prod, tile[i]);
    }

    const idxs = try alloc.alloc(u64, @intCast(tile_prod));
    defer alloc.free(idxs);

    const table: ?[]f32 = if (do_dither) try dither.fitsRandom(alloc) else null;
    defer if (table) |t| alloc.free(t);
    const kind = spec.quantize.toDitherKind();

    // Scratch for the CFITSIO-parity quantizer (allocated once, reused per tile): the tile's
    // pixels at their native float width plus the quantized 32-bit stored values.
    const use_cq = do_quantize and !legacy_quant;
    const eff_qlevel: f32 = spec.quantize_level orelse 4.0; // fpack's float default (-q 4)
    const fq32: ?[]f32 = if (use_cq and spec.bitpix == -32) try alloc.alloc(f32, @intCast(tile_prod)) else null;
    defer if (fq32) |b| alloc.free(b);
    const fq64: ?[]f64 = if (use_cq and spec.bitpix == -64) try alloc.alloc(f64, @intCast(tile_prod)) else null;
    defer if (fq64) |b| alloc.free(b);
    const iq: ?[]i32 = if (use_cq) try alloc.alloc(i32, @intCast(tile_prod)) else null;
    defer if (iq) |b| alloc.free(b);

    var enc_list: std.ArrayList([]u8) = .empty;
    defer {
        for (enc_list.items) |e| alloc.free(e);
        enc_list.deinit(alloc);
    }
    // Per-tile flag (dithered path only): true when tile `r` could not be quantized and is stored
    // losslessly as raw gzipped floats in GZIP_COMPRESSED_DATA instead of quantized COMPRESSED_DATA.
    var enc_lossless: std.ArrayList(bool) = .empty;
    defer enc_lossless.deinit(alloc);
    // Whether any tile produced a null (NaN → the reserved sentinel), which requires a ZBLANK card.
    var any_null = false;
    var zscales: std.ArrayList(f64) = .empty;
    defer zscales.deinit(alloc);
    var zzeros: std.ArrayList(f64) = .empty;
    defer zzeros.deinit(alloc);

    var total_bytes: u64 = 0;
    var row: u64 = 0;
    while (row < ntiles_total) : (row += 1) {
        var rem = row;
        var npix_tile: u64 = 1;
        for (0..znaxis) |i| {
            const c = rem % ntiles[i];
            rem /= ntiles[i];
            tstart[i] = try limits.mul(c, tile[i]);
            const end = @min(tstart[i] + tile[i], spec.axes[i]);
            tdim[i] = end - tstart[i];
            npix_tile = try limits.mul(npix_tile, tdim[i]);
        }
        var p: u64 = 0;
        while (p < npix_tile) : (p += 1) {
            var rp = p;
            var full: u64 = 0;
            for (0..znaxis) |i| {
                const c = rp % tdim[i];
                rp /= tdim[i];
                full += (tstart[i] + c) * img_stride[i];
            }
            idxs[@intCast(p)] = full;
        }
        const tile_idx = idxs[0..@intCast(npix_tile)];

        var this_lossless = false;
        const enc = blk: {
            if (use_cq) {
                // CFITSIO-parity quantization (compress/quantize.zig — the fits_quantize_float/
                // _double port): per-tile noise-based or absolute step, iqfactor-fudged ZZERO,
                // NINT rounding, §10.2 dither draws. The tile geometry is collapsed to
                // (fastest-axis extent × everything else), CFITSIO's fits_calc_tile_rows.
                const nxpix: usize = @intCast(tdim[0]);
                const nypix: usize = @intCast(npix_tile / tdim[0]);
                const ivals = iq.?[0..@intCast(npix_tile)];
                const res = switch (spec.bitpix) {
                    -32 => res32: {
                        const fv = fq32.?[0..@intCast(npix_tile)];
                        for (tile_idx, fv) |full, *v| v.* = anyToF32(T, pixels[@intCast(full)]);
                        break :res32 try quant.quantizeTile(f32, alloc, fv, nxpix, nypix, eff_qlevel, kind, table, spec.zdither0, row, ivals);
                    },
                    -64 => res64: {
                        const fv = fq64.?[0..@intCast(npix_tile)];
                        for (tile_idx, fv) |full, *v| v.* = anyToF64(T, pixels[@intCast(full)]);
                        break :res64 try quant.quantizeTile(f64, alloc, fv, nxpix, nypix, eff_qlevel, kind, table, spec.zdither0, row, ivals);
                    },
                    else => unreachable, // do_quantize requires a float bitpix
                };
                switch (res) {
                    .not_quantized => {
                        // CFITSIO's fallback for an unquantizable tile (0/1 pixels, zero noise,
                        // range overflow, ±Inf): store the raw floats losslessly, gzipped, in
                        // GZIP_COMPRESSED_DATA. Its ZSCALE/ZZERO are unused placeholders.
                        this_lossless = true;
                        try zscales.append(alloc, 1.0);
                        try zzeros.append(alloc, 0.0);
                        const raw_f = try buildRawBytes(T, alloc, spec.bitpix, pixels, tile_idx);
                        defer alloc.free(raw_f);
                        break :blk try gzip.gzipEncode(alloc, raw_f);
                    },
                    .quantized => |qp| {
                        if (qp.has_null) any_null = true;
                        try zscales.append(alloc, qp.bscale);
                        try zzeros.append(alloc, qp.bzero);
                        const raw = try alloc.alloc(u8, @intCast(npix_tile * 4));
                        defer alloc.free(raw);
                        for (ivals, 0..) |code, j| endian.write(i32, code, raw[j * 4 ..][0..4]);
                        // The quantized integers feed the codec exactly as CFITSIO's
                        // imcomp_compress_tile: RICE at bytepix 4, HCOMPRESS through the same
                        // noise-adaptive/absolute scale mapping over the QUANTIZED values.
                        break :blk try encodeRaw(alloc, spec.codec, raw, .{ .w = 4, .tdim = tdim, .znaxis = @intCast(znaxis), .hcomp_scale = spec.hcomp_scale });
                    },
                }
            }
            if (do_dither) {
                // Legacy zigfitsio scheme (pre-existing dithered-GZIP combination with no
                // `quantize_level`; kept so existing callers' bytes are unchanged).
                // Per-tile min/max over FINITE pixels only: NaN is excluded (it maps to the null
                // sentinel), and ±Inf is excluded so one infinite pixel can't poison the scale.
                var mn: f64 = 0;
                var mx: f64 = 0;
                var have = false;
                var has_inf = false;
                for (tile_idx) |full| {
                    const v: f64 = anyToF64(T, pixels[@intCast(full)]);
                    if (std.math.isNan(v)) continue;
                    if (!std.math.isFinite(v)) {
                        has_inf = true;
                        continue;
                    }
                    if (!have) {
                        mn = v;
                        mx = v;
                        have = true;
                    } else {
                        mn = @min(mn, v);
                        mx = @max(mx, v);
                    }
                }
                var zs: f64 = 1.0;
                var zz: f64 = 0.0;
                if (have and mx > mn) {
                    zs = (mx - mn) / 100000.0;
                    zz = (mn + mx) / 2.0;
                } else if (have) {
                    zz = mn;
                }
                // A tile that cannot be faithfully quantized — it holds ±Inf, has no finite pixel,
                // or its range overflows f64 so the scale/zero go non-finite — is stored losslessly
                // as raw gzipped floats in GZIP_COMPRESSED_DATA (CFITSIO's fallback), rather than
                // quantized to garbage. Its ZSCALE/ZZERO are unused, so any placeholder will do.
                if (has_inf or !have or !std.math.isFinite(zs) or !std.math.isFinite(zz)) {
                    this_lossless = true;
                    try zscales.append(alloc, 1.0);
                    try zzeros.append(alloc, 0.0);
                    const raw_f = try buildRawBytes(T, alloc, spec.bitpix, pixels, tile_idx);
                    defer alloc.free(raw_f);
                    break :blk try gzip.gzipEncode(alloc, raw_f);
                }
                const raw = try alloc.alloc(u8, @intCast(npix_tile * 4));
                defer alloc.free(raw);
                var cur = dither.Dither.init(table.?, kind, spec.zdither0, row);
                for (tile_idx, 0..) |full, j| {
                    const fv: f32 = anyToF32(T, pixels[@intCast(full)]);
                    if (std.math.isNan(fv)) any_null = true; // NaN → the reserved null sentinel
                    const code = cur.quantizeNext(fv, zs, zz);
                    endian.write(i32, code, raw[j * 4 ..][0..4]);
                }
                try zscales.append(alloc, zs);
                try zzeros.append(alloc, zz);
                // The dithered path is GZIP-only (validated above), so `tdim`/`znaxis` are unused.
                break :blk try encodeRaw(alloc, spec.codec, raw, .{ .w = 4, .tdim = tdim, .znaxis = @intCast(znaxis) });
            } else {
                const raw = try buildRawBytes(T, alloc, spec.bitpix, pixels, tile_idx);
                defer alloc.free(raw);
                break :blk try encodeRaw(alloc, spec.codec, raw, .{ .w = w, .tdim = tdim, .znaxis = @intCast(znaxis), .hcomp_scale = spec.hcomp_scale });
            }
        };
        {
            errdefer alloc.free(enc);
            // Append the parallel lossless flag FIRST (while `enc` is still owned by `errdefer`),
            // then hand `enc` to `enc_list` as the last fallible op: if either append OOMs, `enc` is
            // freed exactly once (by the errdefer, since it is not yet in `enc_list`). Doing the
            // `enc_list` append first would let a failing `enc_lossless` append double-free `enc`.
            if (do_quantize) try enc_lossless.append(alloc, this_lossless);
            try enc_list.append(alloc, enc);
        }
        total_bytes = try limits.add(total_bytes, enc.len);
    }

    const ncols: u64 = if (do_quantize) 4 else 1;
    const h = try buildCompressedHeader(alloc, spec, codec_name, ncols * 8, ntiles_total, total_bytes, do_quantize, tile, w, any_null);
    const hdu = try fits.appendHdu(h); // takes ownership of `h` (frees it on its own error)

    var bt = try BinTable.of(fits, hdu);
    defer bt.deinit(alloc);
    var mgr = try HeapManager.initForTable(&bt);
    defer mgr.deinit(alloc);
    for (enc_list.items, 0..) |enc, r| {
        if (do_quantize) {
            // Route each tile to its column: quantized tiles fill COMPRESSED_DATA (index 0),
            // lossless-fallback tiles fill GZIP_COMPRESSED_DATA (index 3). The unused column gets
            // an explicit empty cell so its descriptor is length-0 and the reader's precedence
            // (COMPRESSED_DATA → GZIP_COMPRESSED_DATA) selects the right payload per tile.
            if (enc_lossless.items[r]) {
                try writeVlaCell(alloc, &bt, &mgr, .{ .index = 3 }, r, u8, enc);
                try writeVlaCell(alloc, &bt, &mgr, .{ .index = 0 }, r, u8, &[_]u8{});
            } else {
                try writeVlaCell(alloc, &bt, &mgr, .{ .index = 0 }, r, u8, enc);
                try writeVlaCell(alloc, &bt, &mgr, .{ .index = 3 }, r, u8, &[_]u8{});
            }
        } else if (spec.codec == .plio_1) {
            // COMPRESSED_DATA is a `1PI` (16-bit word) VLA for PLIO_1. `plio.compress` always emits
            // whole big-endian words, so `enc.len` is even; the descriptor's element count must be
            // the *word* count (`enc.len / 2`), not the byte count. Decode each big-endian word to a
            // native `i16` and write it through the I-typed column, which re-encodes it big-endian —
            // the on-disk heap bytes stay byte-identical to `enc`, only the declared count changes.
            std.debug.assert(enc.len % 2 == 0);
            const words = try alloc.alloc(i16, enc.len / 2);
            defer alloc.free(words);
            for (words, 0..) |*word, i| word.* = std.mem.readInt(i16, enc[i * 2 ..][0..2], .big);
            try writeVlaCell(alloc, &bt, &mgr, .{ .index = 0 }, r, i16, words);
        } else {
            try writeVlaCell(alloc, &bt, &mgr, .{ .index = 0 }, r, u8, enc);
        }
    }
    if (do_quantize) {
        try bt.writeColumn(f64, .{ .index = 1 }, 0, zscales.items, .{});
        try bt.writeColumn(f64, .{ .index = 2 }, 0, zzeros.items, .{});
    }
    return hdu;
}

// Build the compressed-image BINTABLE header. Has its own errdefer; on success the caller passes
// the returned header to `appendHdu`, which then owns (and on its own error frees) it.
fn buildCompressedHeader(alloc: Allocator, spec: CompressSpec, codec_name: []const u8, naxis1: u64, ntiles_total: u64, total_bytes: u64, do_quantize: bool, tile: []const u64, w: usize, any_null: bool) (errors.HeaderError || errors.ValueError || Allocator.Error)!Header {
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = @intCast(naxis1) }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = @intCast(ntiles_total) }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = @intCast(total_bytes) }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = if (do_quantize) 4 else 1 }, null);
    // PLIO_1's COMPRESSED_DATA is a list of 16-bit words: CFITSIO stores it as `1PI` (signed
    // 16-bit VLA) so the big-endian on-disk words are byte-swapped to native on read. The other
    // codecs (GZIP/RICE/HCOMPRESS) produce an opaque byte stream stored as `1PB`. Emitting `1PB`
    // for PLIO mis-decodes on little-endian readers (the words are read unswapped) — see the write
    // loop in `writeCompressed`, which stores the descriptor length in word units to match.
    try h.appendValue(alloc, "TFORM1", .{ .string = if (spec.codec == .plio_1) "1PI" else "1PB" }, null);
    try h.appendValue(alloc, "TTYPE1", .{ .string = "COMPRESSED_DATA" }, null);
    if (do_quantize) {
        try h.appendValue(alloc, "TFORM2", .{ .string = "1D" }, null);
        try h.appendValue(alloc, "TTYPE2", .{ .string = "ZSCALE" }, null);
        try h.appendValue(alloc, "TFORM3", .{ .string = "1D" }, null);
        try h.appendValue(alloc, "TTYPE3", .{ .string = "ZZERO" }, null);
        // Lossless-fallback column: tiles that couldn't be quantized store raw gzipped floats here
        // (COMPRESSED_DATA is left empty for those tiles). Column order is irrelevant to a reader,
        // which resolves payload columns by TTYPE name and applies the §10.1 precedence.
        try h.appendValue(alloc, "TFORM4", .{ .string = "1PB" }, null);
        try h.appendValue(alloc, "TTYPE4", .{ .string = "GZIP_COMPRESSED_DATA" }, null);
    }
    try h.appendValue(alloc, "ZIMAGE", .{ .logical = true }, null);
    try h.appendValue(alloc, "ZCMPTYPE", .{ .string = codec_name }, null);
    try h.appendValue(alloc, "ZBITPIX", .{ .int = spec.bitpix }, null);
    try h.appendValue(alloc, "ZNAXIS", .{ .int = @intCast(spec.axes.len) }, null);
    var nb: [16]u8 = undefined;
    for (spec.axes, 0..) |a, i| {
        try h.appendValue(alloc, std.fmt.bufPrint(&nb, "ZNAXIS{d}", .{i + 1}) catch unreachable, .{ .int = @intCast(a) }, null);
    }
    for (tile, 0..) |tv, i| {
        try h.appendValue(alloc, std.fmt.bufPrint(&nb, "ZTILE{d}", .{i + 1}) catch unreachable, .{ .int = @intCast(tv) }, null);
    }
    // Codec parameters (ZNAMEn/ZVALn), contiguous from n=1 so the read path's `parseParams` finds
    // them. RICE_1 records BLOCKSIZE/BYTEPIX; HCOMPRESS_1 records SCALE. GZIP_1/2 and PLIO_1 take no
    // parameters.
    switch (spec.codec) {
        .rice_1 => {
            try h.appendValue(alloc, "ZNAME1", .{ .string = "BLOCKSIZE" }, null);
            try h.appendValue(alloc, "ZVAL1", .{ .int = @intCast(default_rice_blocksize) }, null);
            try h.appendValue(alloc, "ZNAME2", .{ .string = "BYTEPIX" }, null);
            // Quantized floating-point tiles are stored as 32-bit integers regardless of the
            // logical ZBITPIX width. BYTEPIX describes those stored RICE elements, not the
            // uncompressed floating-point pixels.
            try h.appendValue(alloc, "ZVAL2", .{ .int = if (do_quantize) 4 else @intCast(w) }, null);
        },
        .hcompress_1 => {
            // ZVAL1 records the float scale REQUEST (CFITSIO `request_hcomp_scale`, ffpkye) —
            // the authoritative per-tile integer scale lives in each tile's embedded stream
            // header. ZVAL2 records the SMOOTH decode request (ffpkyj), always present.
            try h.appendValue(alloc, "ZNAME1", .{ .string = "SCALE" }, null);
            try h.appendValue(alloc, "ZVAL1", .{ .float = spec.hcomp_scale }, null);
            try h.appendValue(alloc, "ZNAME2", .{ .string = "SMOOTH" }, null);
            try h.appendValue(alloc, "ZVAL2", .{ .int = @intFromBool(spec.hcomp_smooth) }, null);
        },
        else => {},
    }
    if (do_quantize) {
        try h.appendValue(alloc, "ZQUANTIZ", .{ .string = spec.quantize.name().? }, null);
        // ZDITHER0 accompanies only the dithered methods (CFITSIO writes no seed for
        // NO_DITHER — there are no random draws to reproduce).
        if (spec.quantize.isDithered())
            try h.appendValue(alloc, "ZDITHER0", .{ .int = spec.zdither0 }, null);
        // Declare the null sentinel so third-party readers substitute NaN for null-coded pixels;
        // without ZBLANK a CFITSIO reader leaves them as the raw reserved value (§10.2 step 5).
        if (any_null) try h.appendValue(alloc, "ZBLANK", .{ .int = dither.null_value }, null);
    }
    try h.ensureEnd(alloc);
    return h;
}

/// The default RICE_1 block size emitted on the write path (CFITSIO default; also the read-path
/// fallback when no `BLOCKSIZE` parameter is present). Recorded as the `BLOCKSIZE` `ZVALn`.
pub const default_rice_blocksize: u32 = 32;

// Per-tile encode context: the stored element width, the tile geometry HCOMPRESS needs, and
// the HCOMPRESS lossy scale request (`CompressSpec.hcomp_scale`; 0 = lossless).
const EncodeCtx = struct {
    w: usize,
    tdim: []const u64,
    znaxis: u16,
    hcomp_scale: f32 = 0,
};

// Map the float HCOMPRESS scale REQUEST to this tile's integer codec scale — the exact CFITSIO
// `imcomp_compress_tile` logic: `request > 0` ⇒ `request × sigma` where sigma is the tile's
// background noise (noise3, replaced by a smaller non-zero noise2/noise5); `request < 0` ⇒
// `|request|` (absolute); then NINT via `(int)(x + 0.5)`. `row_len` is the tile's fastest-axis
// extent (CFITSIO `tilenx`), `nrows` the rest. A result outside `0..maxInt(i32)` is a caller
// error (`DataConstraintViolated`) — CFITSIO would silently wrap; zigfitsio fails loud.
fn hcompressTileScale(alloc: Allocator, vals: []const i32, row_len: usize, nrows: usize, request: f32) (errors.CompressError || Allocator.Error)!i32 {
    var hcompscale: f32 = request;
    if (hcompscale > 0) {
        const noise = try imgstats.noiseEstimates(alloc, vals, row_len, nrows);
        var sigma = noise.noise3;
        if (noise.noise2 != 0 and noise.noise2 < sigma) sigma = noise.noise2;
        if (noise.noise5 != 0 and noise.noise5 < sigma) sigma = noise.noise5;
        hcompscale = @floatCast(@as(f64, hcompscale) * sigma);
    } else if (hcompscale < 0) {
        hcompscale = -hcompscale;
    }
    const rounded = @trunc(@as(f64, hcompscale) + 0.5);
    if (!(rounded >= 0 and rounded <= std.math.maxInt(i32))) return error.DataConstraintViolated;
    return @intFromFloat(rounded);
}

// Encode one tile's big-endian stored values (`raw`, width `ctx.w`) with `codec`, returning the
// compressed cell bytes the read path's `decodeCompressed` consumes. RICE_1 re-derives native-endian
// element bytes; PLIO_1/HCOMPRESS_1 unpack the big-endian values to `i32` (matching `i32ToBig` on
// read). The codec error sets (`{DataConstraintViolated, CorruptTile, OutOfMemory}`) are a subset of
// the declared return set, so they propagate directly.
fn encodeRaw(alloc: Allocator, codec: Codec, raw: []const u8, ctx: EncodeCtx) (errors.CompressError || Allocator.Error)![]u8 {
    switch (codec) {
        .gzip_1 => return gzip.gzipEncode(alloc, raw),
        .gzip_2 => return gzip.gzip2Encode(alloc, raw, ctx.w),
        .rice_1 => {
            const bytepix = std.math.cast(u8, ctx.w) orelse return error.DataConstraintViolated;
            const native = try bigToNative(alloc, raw, ctx.w);
            defer alloc.free(native);
            return rice.compress(alloc, native, bytepix, default_rice_blocksize);
        },
        .plio_1 => {
            const vals = try bigToI32(alloc, raw, ctx.w);
            defer alloc.free(vals);
            return plio.compress(alloc, vals);
        },
        .hcompress_1 => {
            if (ctx.znaxis < 2) return error.BadTiling;
            const vals = try bigToI32(alloc, raw, ctx.w);
            defer alloc.free(vals);
            // tdim[0] is the fastest axis = columns = ny; tdim[1] = rows = nx (see `decodeCompressed`).
            const ny = std.math.cast(usize, ctx.tdim[0]) orelse return error.DataConstraintViolated;
            const nx = std.math.cast(usize, ctx.tdim[1]) orelse return error.DataConstraintViolated;
            // HCOMPRESS is strictly 2-D: a tile with a non-unit higher dimension has
            // vals.len != nx*ny and must fail loud HERE — before `hcompressTileScale`, whose
            // noise estimator asserts this exact geometry precondition — mirroring the check
            // `hcompress.compress` itself applies on the lossless path.
            const npix = std.math.mul(usize, nx, ny) catch return error.DataConstraintViolated;
            if (vals.len != npix) return error.DataConstraintViolated;
            // Per-tile integer scale from the float request (0 = lossless; CFITSIO-identical
            // noise-adaptive/absolute mapping — the scale is embedded in the tile stream).
            const scale = try hcompressTileScale(alloc, vals, ny, nx, ctx.hcomp_scale);
            return hcompress.compress(alloc, vals, nx, ny, scale);
        },
        .unknown => return error.UnsupportedCodec,
    }
}

// Re-encode `raw` (big-endian element bytes, width `w`) as native-endian element bytes — the inverse
// of `nativeToBig` — so it can be fed to `rice.compress`.
fn bigToNative(alloc: Allocator, raw: []const u8, w: usize) (errors.CompressError || Allocator.Error)![]u8 {
    if (w == 0 or raw.len % w != 0) return error.CorruptTile;
    const out = try alloc.alloc(u8, raw.len);
    errdefer alloc.free(out);
    var i: usize = 0;
    while (i < raw.len) : (i += w) {
        switch (w) {
            1 => out[i] = raw[i],
            2 => std.mem.writeInt(u16, out[i..][0..2], std.mem.readInt(u16, raw[i..][0..2], .big), native_endian),
            4 => std.mem.writeInt(u32, out[i..][0..4], std.mem.readInt(u32, raw[i..][0..4], .big), native_endian),
            8 => std.mem.writeInt(u64, out[i..][0..8], std.mem.readInt(u64, raw[i..][0..8], .big), native_endian),
            else => return error.DataConstraintViolated,
        }
    }
    return out;
}

// Unpack `raw` (big-endian signed element bytes, width `w`) to `i32` values, the form PLIO_1 and
// HCOMPRESS_1 compress. A width-8 value outside the `i32` range is `error.DataConstraintViolated`.
fn bigToI32(alloc: Allocator, raw: []const u8, w: usize) (errors.CompressError || Allocator.Error)![]i32 {
    if (w == 0 or raw.len % w != 0) return error.CorruptTile;
    const out = try alloc.alloc(i32, raw.len / w);
    errdefer alloc.free(out);
    for (out, 0..) |*o, idx| {
        const off = idx * w;
        o.* = switch (w) {
            1 => std.mem.readInt(u8, raw[off..][0..1], .big), // BITPIX=8 is unsigned (0..255), not i8
            2 => std.mem.readInt(i16, raw[off..][0..2], .big),
            4 => std.mem.readInt(i32, raw[off..][0..4], .big),
            8 => std.math.cast(i32, std.mem.readInt(i64, raw[off..][0..8], .big)) orelse return error.DataConstraintViolated,
            else => return error.DataConstraintViolated,
        };
    }
    return out;
}

// Widen any numeric pixel value to f32/f64 (the dither branch is runtime-gated but still compiled
// for integer `T`, so the cast must be polymorphic).
fn anyToF32(comptime T: type, v: T) f32 {
    return switch (@typeInfo(T)) {
        .float => @floatCast(v),
        .int, .comptime_int => @floatFromInt(v),
        else => @compileError("writeCompressed: unsupported pixel type"),
    };
}

fn anyToF64(comptime T: type, v: T) f64 {
    return switch (@typeInfo(T)) {
        .float => @floatCast(v),
        .int, .comptime_int => @floatFromInt(v),
        else => @compileError("writeCompressed: unsupported pixel type"),
    };
}

fn buildRawBytes(comptime T: type, alloc: Allocator, bitpix: i64, pixels: []const T, idxs: []const u64) (errors.ConvError || Allocator.Error)![]u8 {
    return switch (bitpix) {
        8 => buildRawTyped(u8, T, alloc, pixels, idxs),
        16 => buildRawTyped(i16, T, alloc, pixels, idxs),
        32 => buildRawTyped(i32, T, alloc, pixels, idxs),
        64 => buildRawTyped(i64, T, alloc, pixels, idxs),
        -32 => buildRawTyped(f32, T, alloc, pixels, idxs),
        -64 => buildRawTyped(f64, T, alloc, pixels, idxs),
        else => unreachable,
    };
}

fn buildRawTyped(comptime Stored: type, comptime T: type, alloc: Allocator, pixels: []const T, idxs: []const u64) (errors.ConvError || Allocator.Error)![]u8 {
    const wdt = @sizeOf(Stored);
    const raw = try alloc.alloc(u8, idxs.len * wdt);
    errdefer alloc.free(raw);
    for (idxs, 0..) |full, j| {
        const s: Stored = try convert.cast(Stored, pixels[@intCast(full)], .bulk);
        endian.write(Stored, s, raw[j * wdt ..][0..wdt]);
    }
    return raw;
}

// ── tile-compressed table read (CMP-9; FITS 4.0 §10.3) ──────────────────────────────────────

/// One original column of a tile-compressed table: its decoded element type, repeat count, the
/// per-column codec (`ZCTYPn`), and the index of the `BINTABLE` column carrying the compressed
/// per-tile byte stream.
pub const TableColInfo = struct {
    elem: BinaryType,
    repeat: u64,
    codec: Codec,
    data_col: u16,
};

/// A read view over a tile-compressed binary table (`ZTABLE = T`, FITS 4.0 §10.3). The original
/// table's rows are grouped into tiles of `ZTILELEN` rows; each tile's per-column data is
/// compressed and stored in the matching `BINTABLE` column's variable-length cell. `readColumn`
/// decompresses every tile of a column back to the original row values.
pub const TileTable = struct {
    base: BinTable,
    fits: *Fits,
    hdu: *Hdu,
    /// `ZNAXIS2`: original (uncompressed) row count.
    orig_rows: u64,
    /// `ZTILELEN`: rows per tile (defaults to `orig_rows`, i.e. a single tile).
    tilelen: u64,
    /// Number of tiles (`= NAXIS2`).
    ntiles: u64,
    /// Per original-column metadata (owned).
    cols: []TableColInfo,

    /// Parse a tile-compressed table over `hdu`. Requires `ZTABLE = T` (else `error.WrongHduType`)
    /// and the original-column descriptors `ZFORMn` (`error.BadTiling` if missing). `ZCTYPn`
    /// defaults to `GZIP_1`.
    pub fn ofTable(fits: *Fits, hdu: *Hdu) OfError!TileTable {
        const alloc = fits.alloc;
        const ztable = hdu.header.getValue(bool, "ZTABLE") catch return error.WrongHduType;
        if (!ztable) return error.WrongHduType;

        var base = try BinTable.of(fits, hdu);
        errdefer base.deinit(alloc);

        const orig_rows = hdu.header.getValue(u64, "ZNAXIS2") catch return error.BadTiling;
        const tl_i: i64 = hdu.header.getValue(i64, "ZTILELEN") catch @intCast(@min(orig_rows, @as(u64, std.math.maxInt(i64))));
        if (tl_i <= 0) return error.BadTiling;
        const tilelen: u64 = @intCast(tl_i);
        const ntiles = ceilDiv(orig_rows, tilelen);
        if (ntiles != base.naxis2) return error.BadTiling;

        const tfields = base.columns.len;
        const cols = try alloc.alloc(TableColInfo, tfields);
        errdefer alloc.free(cols);

        var nb: [16]u8 = undefined;
        for (0..tfields) |i| {
            const zf_name = std.fmt.bufPrint(&nb, "ZFORM{d}", .{i + 1}) catch unreachable;
            const fs = hdu.header.getString(alloc, zf_name) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadTiling,
            };
            defer alloc.free(fs);
            const tf = BinTform.parse(fs) catch return error.BadTiling;

            var codec: Codec = .gzip_1;
            var nb2: [16]u8 = undefined;
            const zc_name = std.fmt.bufPrint(&nb2, "ZCTYP{d}", .{i + 1}) catch unreachable;
            if (hdu.header.getString(alloc, zc_name)) |cs| {
                defer alloc.free(cs);
                codec = Codec.fromName(cs);
            } else |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
            cols[i] = .{ .elem = tf.type, .repeat = tf.repeat, .codec = codec, .data_col = @intCast(i) };
        }

        return .{
            .base = base,
            .fits = fits,
            .hdu = hdu,
            .orig_rows = orig_rows,
            .tilelen = tilelen,
            .ntiles = ntiles,
            .cols = cols,
        };
    }

    /// Release owned state.
    pub fn deinit(self: *TileTable, alloc: Allocator) void {
        alloc.free(self.cols);
        self.base.deinit(alloc);
    }

    /// Decompress column `col_index` of every tile into `out` (length `ZNAXIS2 × repeat`,
    /// row-major). Only `GZIP_1`/`GZIP_2` columns are decoded (CMP-9); another `ZCTYPn` is
    /// `error.UnsupportedCodec`. An empty tile cell reads as zeros.
    pub fn readColumn(self: *TileTable, comptime T: type, col_index: u16, out: []T) ReadError!void {
        if (col_index >= self.cols.len) return error.NoSuchColumn;
        const c = self.cols[col_index];
        if (c.codec != .gzip_1 and c.codec != .gzip_2) return error.UnsupportedCodec;
        const w = c.elem.elemBytes();
        const total = try limits.mul(self.orig_rows, c.repeat);
        if (out.len != total) return error.BadDimensions;
        const alloc = self.fits.alloc;

        var tile: u64 = 0;
        while (tile < self.ntiles) : (tile += 1) {
            const first = try limits.mul(tile, self.tilelen);
            const k = @min(self.tilelen, self.orig_rows - first);
            const nelem = try limits.mul(k, c.repeat);
            const expected = try limits.mul(nelem, w);
            const out_off: usize = @intCast(try limits.mul(first, c.repeat));
            const slot = out[out_off..][0..@intCast(nelem)];

            if (try cellHasData(&self.base, c.data_col, tile)) {
                const cbytes = try readVlaRawBytes(&self.base, alloc, c.data_col, tile);
                defer alloc.free(cbytes);
                const stored = switch (c.codec) {
                    .gzip_1 => try gzip.gzipDecode(alloc, cbytes, expected + 1),
                    .gzip_2 => try gzip.gzip2Decode(alloc, cbytes, w, expected + 1),
                    else => unreachable,
                };
                defer alloc.free(stored);
                if (stored.len != @as(usize, @intCast(expected))) return error.CorruptTile;
                try convertTableTile(T, c.elem, stored, slot);
            } else {
                for (slot) |*o| o.* = try convert.cast(T, @as(u8, 0), .bulk);
            }
        }
    }
};

fn cellHasData(base: *BinTable, col: u16, row: u64) heap.DescriptorError!bool {
    const d = try heap.readDescriptor(base, .{ .index = col }, row);
    return d.len > 0;
}

fn convertTableTile(comptime T: type, elem: BinaryType, stored_be: []const u8, out: []T) errors.ConvError!void {
    switch (elem) {
        .byte => try convertRun(u8, T, stored_be, out),
        .int16 => try convertRun(i16, T, stored_be, out),
        .int32 => try convertRun(i32, T, stored_be, out),
        .int64 => try convertRun(i64, T, stored_be, out),
        .float32 => try convertRun(f32, T, stored_be, out),
        .float64 => try convertRun(f64, T, stored_be, out),
        else => return error.NotRepresentable,
    }
}

fn convertRun(comptime Stored: type, comptime T: type, src_be: []const u8, out: []T) errors.ConvError!void {
    const wdt = @sizeOf(Stored);
    for (out, 0..) |*o, i| {
        o.* = try convert.cast(T, endian.read(Stored, src_be[i * wdt ..][0..wdt]), .bulk);
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;

// A handle + memory device with a primary HDU already in place.
const Fixture = struct {
    mem: *MemoryDevice,
    f: Fits,

    fn init(alloc: Allocator) !Fixture {
        const mem = try alloc.create(MemoryDevice);
        mem.* = MemoryDevice.init(alloc);
        var f = try Fits.create(alloc, mem.device(), .{});
        errdefer f.deinit();
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary
        return .{ .mem = mem, .f = f };
    }

    fn deinit(self: *Fixture, alloc: Allocator) void {
        self.f.deinit();
        self.mem.deinit();
        alloc.destroy(self.mem);
    }
};

const ZSpec = struct {
    ztype: []const u8,
    zbitpix: i64,
    znaxisn: []const u64,
    ztilen: ?[]const u64 = null,
    nrows: u64, // NAXIS2 (= tile count)
    pcount: u64,
    tforms: []const []const u8,
    ttypes: []const []const u8,
    zquantiz: ?[]const u8 = null,
    zscale: ?f64 = null,
    zzero: ?f64 = null,
    zblank: ?i64 = null,
    /// Optional `ZNAMEn` codec-parameter names (paired with `zvals`, n = 1..).
    znames: []const []const u8 = &.{},
    /// Optional `ZVALn` integer values (paired with `znames`).
    zvals: []const i64 = &.{},
};

fn buildZHeader(alloc: Allocator, spec: ZSpec) !Header {
    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    var naxis1: u64 = 0;
    for (spec.tforms) |tf| naxis1 += try (try BinTform.parse(tf)).fieldBytes();

    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = @intCast(naxis1) }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = @intCast(spec.nrows) }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = @intCast(spec.pcount) }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = @intCast(spec.tforms.len) }, null);
    var nb: [16]u8 = undefined;
    for (spec.tforms, 0..) |tf, i| {
        try h.appendValue(alloc, std.fmt.bufPrint(&nb, "TFORM{d}", .{i + 1}) catch unreachable, .{ .string = tf }, null);
        try h.appendValue(alloc, std.fmt.bufPrint(&nb, "TTYPE{d}", .{i + 1}) catch unreachable, .{ .string = spec.ttypes[i] }, null);
    }
    try h.appendValue(alloc, "ZIMAGE", .{ .logical = true }, null);
    try h.appendValue(alloc, "ZCMPTYPE", .{ .string = spec.ztype }, null);
    try h.appendValue(alloc, "ZBITPIX", .{ .int = spec.zbitpix }, null);
    try h.appendValue(alloc, "ZNAXIS", .{ .int = @intCast(spec.znaxisn.len) }, null);
    for (spec.znaxisn, 0..) |v, i| {
        try h.appendValue(alloc, std.fmt.bufPrint(&nb, "ZNAXIS{d}", .{i + 1}) catch unreachable, .{ .int = @intCast(v) }, null);
    }
    if (spec.ztilen) |zt| {
        for (zt, 0..) |v, i| {
            try h.appendValue(alloc, std.fmt.bufPrint(&nb, "ZTILE{d}", .{i + 1}) catch unreachable, .{ .int = @intCast(v) }, null);
        }
    }
    if (spec.zquantiz) |q| try h.appendValue(alloc, "ZQUANTIZ", .{ .string = q }, null);
    if (spec.zscale) |s| try h.appendValue(alloc, "ZSCALE", .{ .float = s }, null);
    if (spec.zzero) |z| try h.appendValue(alloc, "ZZERO", .{ .float = z }, null);
    if (spec.zblank) |b| try h.appendValue(alloc, "ZBLANK", .{ .int = b }, null);
    for (spec.znames, spec.zvals, 1..) |name, val, idx| {
        try h.appendValue(alloc, std.fmt.bufPrint(&nb, "ZNAME{d}", .{idx}) catch unreachable, .{ .string = name }, null);
        try h.appendValue(alloc, std.fmt.bufPrint(&nb, "ZVAL{d}", .{idx}) catch unreachable, .{ .int = val }, null);
    }
    try h.ensureEnd(alloc);
    return h;
}

// Encode `vals` (tile-local row-major) as big-endian i16, gzip (GZIP_1 if not shuffled, else
// GZIP_2 with width 2), and write them into the COMPRESSED_DATA cell of tile `row`.
fn writeTileI16(alloc: Allocator, t: *BinTable, mgr: *HeapManager, col: u16, row: u64, vals: []const i16, gzip2: bool) !void {
    const raw = try alloc.alloc(u8, vals.len * 2);
    defer alloc.free(raw);
    for (vals, 0..) |v, i| endian.write(i16, v, raw[i * 2 ..][0..2]);
    const enc = if (gzip2) try gzip.gzip2Encode(alloc, raw, 2) else try gzip.gzipEncode(alloc, raw);
    defer alloc.free(enc);
    try writeVlaCell(alloc, t, mgr, .{ .index = col }, row, u8, enc);
}

test "of: structure parse + single-tile GZIP_1 round-trip (i16 stored → i32 out)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const spec = ZSpec{
        .ztype = "GZIP_1",
        .zbitpix = 16,
        .znaxisn = &.{ 4, 3 },
        .ztilen = &.{ 4, 3 }, // single tile covering the whole image
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
        .zquantiz = "NO_DITHER",
    };
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));

    var t = try BinTable.of(&fx.f, hdu);
    var mgr = try HeapManager.initForTable(&t);
    const full = [_]i16{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    try writeTileI16(alloc, &t, &mgr, 0, 0, &full, false);
    mgr.deinit(alloc);
    t.deinit(alloc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);

    try testing.expectEqual(Codec.gzip_1, ti.ztype);
    try testing.expectEqual(@as(i64, 16), ti.zbitpix);
    try testing.expectEqual(@as(u16, 2), ti.znaxis);
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, ti.dims());
    try testing.expectEqual(@as(u64, 12), ti.elementCount());
    try testing.expectEqual(@as(u64, 1), ti.tileCount());
    try testing.expectEqual(Quantize.no_dither, ti.quantize); // ZQUANTIZ='NO_DITHER'

    var out: [12]i32 = undefined;
    try ti.readAll(i32, &out);
    const exp = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    try testing.expectEqualSlices(i32, &exp, &out);
}

test "GZIP_1 multi-tile decode places edge/partial tiles per row-major geometry" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // 3×2 image, 2×2 tiles ⇒ tiles along axis1 = ceil(3/2)=2, axis2 = ceil(2/2)=1 ⇒ 2 tiles.
    //   tile 0: x∈[0,2) y∈[0,2) → full indices 0,1,3,4 (tile-local order)
    //   tile 1: x=2      y∈[0,2) → full indices 2,5      (partial: tdim = 1×2)
    const spec = ZSpec{
        .ztype = "GZIP_1",
        .zbitpix = 16,
        .znaxisn = &.{ 3, 2 },
        .ztilen = &.{ 2, 2 },
        .nrows = 2,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
    };
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));

    var t = try BinTable.of(&fx.f, hdu);
    var mgr = try HeapManager.initForTable(&t);
    // Hand-laid tile-local value lists (independent of the decoder's geometry).
    try writeTileI16(alloc, &t, &mgr, 0, 0, &[_]i16{ 10, 11, 13, 14 }, false);
    try writeTileI16(alloc, &t, &mgr, 0, 1, &[_]i16{ 12, 15 }, false);
    mgr.deinit(alloc);
    t.deinit(alloc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(u64, 2), ti.tileCount());

    var out: [6]i16 = undefined;
    try ti.readAll(i16, &out);
    try testing.expectEqualSlices(i16, &[_]i16{ 10, 11, 12, 13, 14, 15 }, &out);
}

test "single-tile GZIP_2 (shuffled) round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const spec = ZSpec{
        .ztype = "GZIP_2",
        .zbitpix = 16,
        .znaxisn = &.{ 4, 2 },
        .ztilen = &.{ 4, 2 },
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
    };
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));

    var t = try BinTable.of(&fx.f, hdu);
    var mgr = try HeapManager.initForTable(&t);
    const full = [_]i16{ 100, -200, 300, -400, 500, -600, 700, -800 };
    try writeTileI16(alloc, &t, &mgr, 0, 0, &full, true); // GZIP_2 (shuffled)
    mgr.deinit(alloc);
    t.deinit(alloc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Codec.gzip_2, ti.ztype);

    var out: [8]i16 = undefined;
    try ti.readAll(i16, &out);
    try testing.expectEqualSlices(i16, &full, &out);
}

test "unrecognized ZCMPTYPE gates readAll with UnsupportedCodec" {
    const alloc = testing.allocator;

    // RICE_1/PLIO_1/HCOMPRESS_1 are now decoded (CMP-4/5/6); only an unrecognized name remains
    // UnsupportedCodec (the read aborts before touching any tile).
    for ([_][]const u8{ "BOGUS_9", "FOO", "PLIO_2" }) |name| {
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        const spec = ZSpec{
            .ztype = name,
            .zbitpix = 16,
            .znaxisn = &.{ 4, 3 },
            .ztilen = &.{ 4, 3 },
            .nrows = 1,
            .pcount = 64,
            .tforms = &.{"1PB"},
            .ttypes = &.{"COMPRESSED_DATA"},
        };
        const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));
        var ti = try TiledImage.of(&fx.f, hdu);
        defer ti.deinit(alloc);
        var out: [12]i16 = undefined;
        try testing.expectError(error.UnsupportedCodec, ti.readAll(i16, &out));
        try testing.expectEqual(Codec.unknown, ti.ztype);
    }
}

test "tile geometry: covering-tile count for non-multiple dimensions and ZTILE defaults" {
    const alloc = testing.allocator;

    {
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        // 5×3, 2×2 tiles ⇒ ceil(5/2)=3, ceil(3/2)=2 ⇒ 6 tiles; 15 pixels.
        const spec = ZSpec{
            .ztype = "GZIP_1",
            .zbitpix = 16,
            .znaxisn = &.{ 5, 3 },
            .ztilen = &.{ 2, 2 },
            .nrows = 6,
            .pcount = 64,
            .tforms = &.{"1PB"},
            .ttypes = &.{"COMPRESSED_DATA"},
        };
        const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));
        var ti = try TiledImage.of(&fx.f, hdu);
        defer ti.deinit(alloc);
        try testing.expectEqual(@as(u64, 6), ti.tileCount());
        try testing.expectEqual(@as(u64, 15), ti.elementCount());
    }
    {
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        // No ZTILEn ⇒ default ZTILE1 = ZNAXIS1 = 5, ZTILE2 = 1 ⇒ ceil(5/5)=1, ceil(3/1)=3 ⇒ 3.
        const spec = ZSpec{
            .ztype = "GZIP_1",
            .zbitpix = 16,
            .znaxisn = &.{ 5, 3 },
            .ztilen = null,
            .nrows = 3,
            .pcount = 64,
            .tforms = &.{"1PB"},
            .ttypes = &.{"COMPRESSED_DATA"},
        };
        const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));
        var ti = try TiledImage.of(&fx.f, hdu);
        defer ti.deinit(alloc);
        try testing.expectEqualSlices(u64, &.{ 5, 1 }, ti.ztilen);
        try testing.expectEqual(@as(u64, 3), ti.tileCount());
    }
}

test "UNCOMPRESSED_DATA fallback when COMPRESSED_DATA cell is empty" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const spec = ZSpec{
        .ztype = "GZIP_1",
        .zbitpix = 16,
        .znaxisn = &.{3},
        .ztilen = &.{3},
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{ "1PB", "1PI" },
        .ttypes = &.{ "COMPRESSED_DATA", "UNCOMPRESSED_DATA" },
    };
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));

    var t = try BinTable.of(&fx.f, hdu);
    var mgr = try HeapManager.initForTable(&t);
    // Leave COMPRESSED_DATA (col 0) empty; store raw stored values in UNCOMPRESSED_DATA (col 1).
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 1 }, 0, i16, &[_]i16{ 7, 8, 9 });
    mgr.deinit(alloc);
    t.deinit(alloc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [3]i16 = undefined;
    try ti.readAll(i16, &out);
    try testing.expectEqualSlices(i16, &[_]i16{ 7, 8, 9 }, &out);
}

test "per-tile keyword ZSCALE/ZZERO applied on read" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // physical = ZZERO + ZSCALE × stored = 10 + 2 × stored.
    const spec = ZSpec{
        .ztype = "GZIP_1",
        .zbitpix = 16,
        .znaxisn = &.{3},
        .ztilen = &.{3},
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
        .zscale = 2.0,
        .zzero = 10.0,
    };
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));

    var t = try BinTable.of(&fx.f, hdu);
    var mgr = try HeapManager.initForTable(&t);
    try writeTileI16(alloc, &t, &mgr, 0, 0, &[_]i16{ 1, 2, 3 }, false);
    mgr.deinit(alloc);
    t.deinit(alloc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expect(ti.isScaled());

    var out: [3]f64 = undefined;
    try ti.readAll(f64, &out);
    try testing.expectEqualSlices(f64, &[_]f64{ 12.0, 14.0, 16.0 }, &out);
}

test "keyword ZBLANK pixels decode to the null substitute (NaN for float output)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // ZBLANK = 2: the second stored value is the null marker.
    const spec = ZSpec{
        .ztype = "GZIP_1",
        .zbitpix = 16,
        .znaxisn = &.{3},
        .ztilen = &.{3},
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
        .zblank = 2,
    };
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));

    var t = try BinTable.of(&fx.f, hdu);
    var mgr = try HeapManager.initForTable(&t);
    try writeTileI16(alloc, &t, &mgr, 0, 0, &[_]i16{ 1, 2, 3 }, false);
    mgr.deinit(alloc);
    t.deinit(alloc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(?i64, 2), ti.zblank_kw);

    var out: [3]f32 = undefined;
    try ti.readAll(f32, &out);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    try testing.expect(std.math.isNan(out[1])); // ZBLANK → NaN
    try testing.expectEqual(@as(f32, 3.0), out[2]);
}

test "no ZBLANK control: every pixel decodes to its value (no substitution)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const spec = ZSpec{
        .ztype = "GZIP_1",
        .zbitpix = 16,
        .znaxisn = &.{3},
        .ztilen = &.{3},
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
        // no .zblank
    };
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));

    var t = try BinTable.of(&fx.f, hdu);
    var mgr = try HeapManager.initForTable(&t);
    try writeTileI16(alloc, &t, &mgr, 0, 0, &[_]i16{ 1, 2, 3 }, false);
    mgr.deinit(alloc);
    t.deinit(alloc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(?i64, null), ti.zblank_kw);

    var out: [3]f32 = undefined;
    try ti.readAll(f32, &out);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.0, 2.0, 3.0 }, &out); // 2.0 is NOT null here
}

test "ZNAMEn/ZVALn codec parameters and ZDITHER0 are recorded" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var h = try buildZHeader(alloc, .{
        .ztype = "GZIP_1",
        .zbitpix = 16,
        .znaxisn = &.{4},
        .ztilen = &.{4},
        .nrows = 1,
        .pcount = 64,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
    });
    // Append codec parameters before END is re-ensured by appendHdu.
    // (buildZHeader already appended END; insert the params via update which inserts before END.)
    try h.update(alloc, "ZNAME1", .{ .string = "BLOCKSIZE" }, null);
    try h.update(alloc, "ZVAL1", .{ .int = 32 }, null);
    try h.update(alloc, "ZNAME2", .{ .string = "BYTEPIX" }, null);
    try h.update(alloc, "ZVAL2", .{ .int = 4 }, null);
    try h.update(alloc, "ZDITHER0", .{ .int = 5773 }, null);
    const hdu = try fx.f.appendHdu(h);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), ti.params.len);
    try testing.expectEqualStrings("BLOCKSIZE", ti.params[0].name);
    try testing.expectEqual(@as(i64, 32), ti.params[0].value.int);
    try testing.expectEqualStrings("BYTEPIX", ti.params[1].name);
    try testing.expectEqual(@as(i64, 4), ti.params[1].value.int);
    try testing.expectEqual(@as(?i64, 5773), ti.zdither0);
}

test "non-ZIMAGE binary table is rejected with WrongHduType" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = 4 }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = 1 }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFORM1", .{ .string = "1J" }, null);
    try h.ensureEnd(alloc);
    const hdu = try fx.f.appendHdu(h);

    try testing.expectError(error.WrongHduType, TiledImage.of(&fx.f, hdu));
}

test "missing mandatory Z* keyword (ZBITPIX) is BadTiling" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS2", .{ .int = 1 }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = 0 }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFORM1", .{ .string = "1PB" }, null);
    try h.appendValue(alloc, "TTYPE1", .{ .string = "COMPRESSED_DATA" }, null);
    try h.appendValue(alloc, "ZIMAGE", .{ .logical = true }, null);
    try h.appendValue(alloc, "ZCMPTYPE", .{ .string = "GZIP_1" }, null);
    // ZBITPIX intentionally omitted.
    try h.appendValue(alloc, "ZNAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "ZNAXIS1", .{ .int = 4 }, null);
    try h.appendValue(alloc, "ZNAXIS2", .{ .int = 3 }, null);
    try h.ensureEnd(alloc);
    const hdu = try fx.f.appendHdu(h);

    try testing.expectError(error.BadTiling, TiledImage.of(&fx.f, hdu));
}

test "corrupt tile (wrong decoded length) is CorruptTile" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const spec = ZSpec{
        .ztype = "GZIP_1",
        .zbitpix = 16,
        .znaxisn = &.{4},
        .ztilen = &.{4},
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
    };
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));

    var t = try BinTable.of(&fx.f, hdu);
    var mgr = try HeapManager.initForTable(&t);
    // Tile should decode to 4×2 = 8 bytes; write only 2 values (4 bytes) ⇒ short tile.
    try writeTileI16(alloc, &t, &mgr, 0, 0, &[_]i16{ 1, 2 }, false);
    mgr.deinit(alloc);
    t.deinit(alloc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [4]i16 = undefined;
    try testing.expectError(error.CorruptTile, ti.readAll(i16, &out));
}

test "readAll rejects a wrong-length output buffer" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const spec = ZSpec{
        .ztype = "GZIP_1",
        .zbitpix = 16,
        .znaxisn = &.{ 4, 3 },
        .ztilen = &.{ 4, 3 },
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
    };
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));
    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);

    var out: [10]i16 = undefined; // image has 12 pixels
    try testing.expectError(error.BadDimensions, ti.readAll(i16, &out));
}

// ── CMP-4/5/6 decode wiring ──────────────────────────────────────────────────────────────────

// Write a tile already compressed by one of the Phase-2 codecs into COMPRESSED_DATA of a
// synthetic compressed-image HDU, then assert TiledImage decodes it back to `expected`.
fn writeRawTileCell(alloc: Allocator, fx: *Fixture, spec: ZSpec, enc: []const u8) !*Hdu {
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));
    var t = try BinTable.of(&fx.f, hdu);
    var mgr = try HeapManager.initForTable(&t);
    try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, 0, u8, enc);
    mgr.deinit(alloc);
    t.deinit(alloc);
    return hdu;
}

test "RICE_1 tile produced by the codec decodes via TiledImage" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // Single 4×3 tile of i16 stored values, RICE-coded by the project codec.
    const vals = [_]i16{ 7, 9, 11, 13, 100, 99, 98, 97, -5, -4, -3, -2 };
    var native: [vals.len * 2]u8 = undefined;
    for (vals, 0..) |v, i| std.mem.writeInt(i16, native[i * 2 ..][0..2], v, native_endian);
    const enc = try rice.compress(alloc, &native, 2, 32);
    defer alloc.free(enc);

    const spec = ZSpec{
        .ztype = "RICE_1",
        .zbitpix = 16,
        .znaxisn = &.{ 4, 3 },
        .ztilen = &.{ 4, 3 },
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
    };
    const hdu = try writeRawTileCell(alloc, &fx, spec, enc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Codec.rice_1, ti.ztype);
    var out: [12]i16 = undefined;
    try ti.readAll(i16, &out);
    try testing.expectEqualSlices(i16, &vals, &out);
}

test "PLIO_1 tile produced by the codec decodes via TiledImage" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // A mask line (mostly background with sparse label runs), 4×3 single tile, i32 stored.
    const mask = [_]i32{ 0, 0, 5, 5, 5, 0, 3, 0, 0, 7, 7, 0 };
    const enc = try plio.compress(alloc, &mask);
    defer alloc.free(enc);

    const spec = ZSpec{
        .ztype = "PLIO_1",
        .zbitpix = 32,
        .znaxisn = &.{ 4, 3 },
        .ztilen = &.{ 4, 3 },
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
    };
    const hdu = try writeRawTileCell(alloc, &fx, spec, enc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Codec.plio_1, ti.ztype);
    var out: [12]i32 = undefined;
    try ti.readAll(i32, &out);
    try testing.expectEqualSlices(i32, &mask, &out);
}

test "HCOMPRESS_1 tile produced by the codec decodes via TiledImage" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // 4 (fast=cols=ny) × 3 (rows=nx) single tile; tile-local order p = c + r*ny matches the
    // codec's row-major data[r*ny + c].
    const vals = [_]i32{ 1, 2, 3, 4, 10, 11, 12, 13, -7, -6, -5, -4 };
    const enc = try hcompress.compress(alloc, &vals, 3, 4, 0); // nx=3 rows, ny=4 cols, lossless
    defer alloc.free(enc);

    const spec = ZSpec{
        .ztype = "HCOMPRESS_1",
        .zbitpix = 32,
        .znaxisn = &.{ 4, 3 },
        .ztilen = &.{ 4, 3 },
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
    };
    const hdu = try writeRawTileCell(alloc, &fx, spec, enc);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Codec.hcompress_1, ti.ztype);
    var out: [12]i32 = undefined;
    try ti.readAll(i32, &out);
    try testing.expectEqualSlices(i32, &vals, &out);
}

test "HCOMPRESS_1 lossy tile: ZNAME2='SMOOTH'/ZVAL2 drives decode-side hsmooth" {
    const alloc = testing.allocator;

    // A curved 16×16 surface, lossy scale 16 — a stream where smoothing visibly changes pixels.
    const nx = 16; // rows
    const ny = 16; // cols (fastest)
    var vals: [nx * ny]i32 = undefined;
    for (0..nx) |r| {
        for (0..ny) |c| vals[r * ny + c] = @intCast(r * r + 2 * c * c + r * c);
    }
    const enc = try hcompress.compress(alloc, &vals, nx, ny, 16);
    defer alloc.free(enc);

    // Codec-level references for both decode modes.
    const plain = try hcompress.decompress(alloc, enc, nx * ny, .{});
    defer alloc.free(plain.data);
    const smoothed = try hcompress.decompress(alloc, enc, nx * ny, .{ .smooth = true });
    defer alloc.free(smoothed.data);
    try testing.expect(!std.mem.eql(i32, plain.data, smoothed.data)); // non-vacuous fixture

    // ZVAL2 = 1 → the container decode must produce the SMOOTHED pixels…
    {
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        const hdu = try writeRawTileCell(alloc, &fx, .{
            .ztype = "HCOMPRESS_1",
            .zbitpix = 32,
            .znaxisn = &.{ ny, nx },
            .ztilen = &.{ ny, nx },
            .nrows = 1,
            .pcount = 4096,
            .tforms = &.{"1PB"},
            .ttypes = &.{"COMPRESSED_DATA"},
            .znames = &.{ "SCALE", "SMOOTH" },
            .zvals = &.{ 16, 1 },
        }, enc);
        var ti = try TiledImage.of(&fx.f, hdu);
        defer ti.deinit(alloc);
        var out: [nx * ny]i32 = undefined;
        try ti.readAll(i32, &out);
        try testing.expectEqualSlices(i32, smoothed.data, &out);
    }
    // …ZVAL2 = 0 (and the absent-param default) must produce the PLAIN pixels.
    {
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        const hdu = try writeRawTileCell(alloc, &fx, .{
            .ztype = "HCOMPRESS_1",
            .zbitpix = 32,
            .znaxisn = &.{ ny, nx },
            .ztilen = &.{ ny, nx },
            .nrows = 1,
            .pcount = 4096,
            .tforms = &.{"1PB"},
            .ttypes = &.{"COMPRESSED_DATA"},
            .znames = &.{ "SCALE", "SMOOTH" },
            .zvals = &.{ 16, 0 },
        }, enc);
        var ti = try TiledImage.of(&fx.f, hdu);
        defer ti.deinit(alloc);
        var out: [nx * ny]i32 = undefined;
        try ti.readAll(i32, &out);
        try testing.expectEqualSlices(i32, plain.data, &out);
    }
    {
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        const hdu = try writeRawTileCell(alloc, &fx, .{
            .ztype = "HCOMPRESS_1",
            .zbitpix = 32,
            .znaxisn = &.{ ny, nx },
            .ztilen = &.{ ny, nx },
            .nrows = 1,
            .pcount = 4096,
            .tforms = &.{"1PB"},
            .ttypes = &.{"COMPRESSED_DATA"},
        }, enc);
        var ti = try TiledImage.of(&fx.f, hdu);
        defer ti.deinit(alloc);
        var out: [nx * ny]i32 = undefined;
        try ti.readAll(i32, &out);
        try testing.expectEqualSlices(i32, plain.data, &out);
    }
}

test "HCOMPRESS_1 tile with forged oversized nx/ny is CorruptTile, not an unbounded allocation" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    const vals = [_]i32{ 1, 2, 3, 4, 10, 11, 12, 13, -7, -6, -5, -4 };
    const enc = try hcompress.compress(alloc, &vals, 3, 4, 0);
    defer alloc.free(enc);
    // Forge the stream's declared geometry to 65535×65535 (~34 GB if the codec allocated from
    // it). The tile-geometry pre-check must reject this against the known 4×3 tile dims BEFORE
    // hcompress.decompress sizes any buffer from the header (regression: unbounded-alloc DoS).
    std.mem.writeInt(u32, enc[2..][0..4], 65535, .big); // nx
    std.mem.writeInt(u32, enc[6..][0..4], 65535, .big); // ny
    const spec = ZSpec{
        .ztype = "HCOMPRESS_1",
        .zbitpix = 32,
        .znaxisn = &.{ 4, 3 },
        .ztilen = &.{ 4, 3 },
        .nrows = 1,
        .pcount = 2048,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
    };
    const hdu = try writeRawTileCell(alloc, &fx, spec, enc);
    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [12]i32 = undefined;
    try testing.expectError(error.CorruptTile, ti.readAll(i32, &out));
}

// ── CMP-8 compressed write ───────────────────────────────────────────────────────────────────

test "writeCompressed GZIP_1 round-trips a single-tile image" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const src = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const hdu = try writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 4, 3 },
        .tile = &.{ 4, 3 },
        .codec = .gzip_1,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Codec.gzip_1, ti.ztype);
    try testing.expectEqual(@as(u64, 1), ti.tileCount());
    var out: [12]i32 = undefined;
    try ti.readAll(i32, &out);
    try testing.expectEqualSlices(i32, &src, &out);
}

test "writeCompressed GZIP_1 non-multiple tiling round-trips across multiple tiles" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // 5×4 image, 2×3 tiles ⇒ ceil(5/2)=3, ceil(4/3)=2 ⇒ 6 tiles, several of them partial.
    var src: [20]i32 = undefined;
    for (&src, 0..) |*v, i| v.* = @intCast(@as(i64, @intCast(i)) * 3 - 7);
    const hdu = try writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 5, 4 },
        .tile = &.{ 2, 3 },
        .codec = .gzip_1,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(u64, 6), ti.tileCount());
    var out: [20]i32 = undefined;
    try ti.readAll(i32, &out); // spans all 6 tiles
    try testing.expectEqualSlices(i32, &src, &out);
}

test "writeCompressed GZIP_2 (default row-strip tiling) round-trips i16" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const src = [_]i16{ 100, -200, 300, -400, 500, -600, 700, -800 };
    const hdu = try writeCompressed(i16, &fx.f, .{
        .bitpix = 16,
        .axes = &.{ 4, 2 }, // default tile ⇒ {4,1} ⇒ 2 row strips
        .codec = .gzip_2,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Codec.gzip_2, ti.ztype);
    try testing.expectEqual(@as(u64, 2), ti.tileCount());
    var out: [8]i16 = undefined;
    try ti.readAll(i16, &out);
    try testing.expectEqualSlices(i16, &src, &out);
}

test "writeCompressed rejects an unknown codec, a bad codec/BITPIX pairing, and a wrong-length buffer" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const src = [_]i32{ 1, 2, 3, 4 };
    // An unrecognized codec has no canonical name ⇒ UnsupportedCodec.
    try testing.expectError(error.UnsupportedCodec, writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 2, 2 },
        .codec = .unknown,
    }, &src));
    // RICE_1 on a 64-bit image: bytepix 8 is not a RICE width ⇒ DataConstraintViolated.
    const src64 = [_]i64{ 1, 2, 3, 4 };
    try testing.expectError(error.DataConstraintViolated, writeCompressed(i64, &fx.f, .{
        .bitpix = 64,
        .axes = &.{ 2, 2 },
        .codec = .rice_1,
    }, &src64));
    // HCOMPRESS_1 on a 1-D image ⇒ BadTiling (it is 2-D only).
    try testing.expectError(error.BadTiling, writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{4},
        .codec = .hcompress_1,
    }, &src));
    // Wrong-length pixel buffer ⇒ BadDimensions.
    try testing.expectError(error.BadDimensions, writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 2, 2 },
        .codec = .gzip_1,
    }, src[0..3]));
}

test "writeCompressed RICE_1 round-trips an integer image" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const src = [_]i16{ 7, 9, 11, 13, 100, 99, 98, 97, -5, -4, -3, -2 };
    const hdu = try writeCompressed(i16, &fx.f, .{
        .bitpix = 16,
        .axes = &.{ 4, 3 },
        .tile = &.{ 4, 3 },
        .codec = .rice_1,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Codec.rice_1, ti.ztype);
    // Codec parameters were emitted.
    try testing.expectEqual(@as(?i64, default_rice_blocksize), ti.paramInt("BLOCKSIZE"));
    try testing.expectEqual(@as(?i64, 2), ti.paramInt("BYTEPIX"));

    var out: [12]i16 = undefined;
    try ti.readAll(i16, &out);
    try testing.expectEqualSlices(i16, &src, &out);
}

test "writeCompressed PLIO_1 round-trips a mask image" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // PLIO mask values in 0..2^24-1.
    const src = [_]i32{ 0, 0, 5, 5, 5, 0, 3, 0, 0, 7, 7, 0 };
    const hdu = try writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 4, 3 },
        .tile = &.{ 4, 3 },
        .codec = .plio_1,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Codec.plio_1, ti.ztype);

    var out: [12]i32 = undefined;
    try ti.readAll(i32, &out);
    try testing.expectEqualSlices(i32, &src, &out);
}

test "writeCompressed PLIO_1 round-trips an 8-bit image with values >= 128 (unsigned BITPIX=8)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // BITPIX=8 is UNSIGNED 0..255: bright values 128..255 must survive. i32ToBig packs the stored
    // byte as u8, not signed i8 (a signed cast would reject everything above 127).
    const src = [_]u8{ 0, 128, 200, 255, 1, 127, 254, 130 };
    const hdu = try writeCompressed(u8, &fx.f, .{
        .bitpix = 8,
        .axes = &.{ 4, 2 },
        .tile = &.{ 4, 2 },
        .codec = .plio_1,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [8]u8 = undefined;
    try ti.readAll(u8, &out);
    try testing.expectEqualSlices(u8, &src, &out);
}

test "PLIO_1 stored value outside the declared ZBITPIX width still rejects (strict, not clamp)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // Author a VALID ZBITPIX=32 PLIO tile holding mask values > 255 (PLIO's own range is
    // 0..2^24-1), then narrow the declared ZBITPIX to 8: the stored values no longer fit the
    // width. PLIO decode is lossless, so this can only be a corrupt/mislabeled file — the read
    // must fail loud with the strict reject, NOT clamp like the lossy HCOMPRESS path.
    const src = [_]i32{ 0, 300, 5, 5, 5, 0, 3, 0, 0, 7, 7, 0 };
    const hdu = try writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 4, 3 },
        .tile = &.{ 4, 3 },
        .codec = .plio_1,
    }, &src);
    try hdu.header.update(fx.f.alloc, "ZBITPIX", .{ .int = 8 }, null);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [12]u8 = undefined;
    try testing.expectError(error.DataConstraintViolated, ti.readAll(u8, &out));
}

test "writeCompressed HCOMPRESS_1 round-trips a 2-D integer image (lossless)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const src = [_]i32{ 1, 2, 3, 4, 10, 11, 12, 13, -7, -6, -5, -4 };
    const hdu = try writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 4, 3 },
        .tile = &.{ 4, 3 },
        .codec = .hcompress_1,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Codec.hcompress_1, ti.ztype);
    // ZVAL1 records the float scale request (0.0 = lossless, CFITSIO card form); ZVAL2 the
    // SMOOTH request. Both are coerced by paramNum.
    try testing.expectEqual(@as(?i64, 0), ti.paramNum("SCALE"));
    try testing.expectEqual(@as(?i64, 0), ti.paramNum("SMOOTH"));

    var out: [12]i32 = undefined;
    try ti.readAll(i32, &out);
    try testing.expectEqualSlices(i32, &src, &out);
}

test "writeCompressed HCOMPRESS_1 round-trips across multiple 2-D tiles" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // 5×4 image, 2×3 tiling ⇒ 6 tiles, several partial — exercises per-tile nx/ny.
    var src: [20]i32 = undefined;
    for (&src, 0..) |*v, i| v.* = @intCast(@as(i64, @intCast(i)) * 2 - 9);
    const hdu = try writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 5, 4 },
        .tile = &.{ 2, 3 },
        .codec = .hcompress_1,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(u64, 6), ti.tileCount());
    var out: [20]i32 = undefined;
    try ti.readAll(i32, &out);
    try testing.expectEqualSlices(i32, &src, &out);
}

test "writeCompressed HCOMPRESS_1 lossy (absolute scale): bounded round-trip, ZVAL1/ZVAL2 recorded" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // Curved 16×16 surface; hcomp_scale = -16 ⇒ every tile uses absolute scale 16.
    var src: [256]i32 = undefined;
    for (0..16) |r| {
        for (0..16) |c| src[r * 16 + c] = @intCast(r * r + 2 * c * c + r * c);
    }
    const hdu = try writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 16, 16 },
        .tile = &.{ 16, 16 },
        .codec = .hcompress_1,
        .hcomp_scale = -16,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(?i64, -16), ti.paramNum("SCALE")); // the float REQUEST, as CFITSIO records it
    try testing.expectEqual(@as(?i64, 0), ti.paramNum("SMOOTH"));

    var out: [256]i32 = undefined;
    try ti.readAll(i32, &out);
    var maxerr: i64 = 0;
    var ndiff: usize = 0;
    for (src, out) |o, g| {
        const e: i64 = @intCast(@abs(@as(i64, o) - @as(i64, g)));
        if (e > maxerr) maxerr = e;
        if (o != g) ndiff += 1;
    }
    try testing.expect(maxerr > 0 and maxerr <= 64 * 16); // genuinely lossy, but bounded
    try testing.expect(ndiff > 0);
}

test "writeCompressed HCOMPRESS_1 hcomp_smooth: readers smooth, and it changes pixels" {
    const alloc = testing.allocator;
    var src: [256]i32 = undefined;
    for (0..16) |r| {
        for (0..16) |c| src[r * 16 + c] = @intCast(r * r + 2 * c * c + r * c);
    }
    const spec_base = CompressSpec{
        .bitpix = 32,
        .axes = &.{ 16, 16 },
        .tile = &.{ 16, 16 },
        .codec = .hcompress_1,
        .hcomp_scale = -16,
    };

    var plain: [256]i32 = undefined;
    {
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        const hdu = try writeCompressed(i32, &fx.f, spec_base, &src);
        var ti = try TiledImage.of(&fx.f, hdu);
        defer ti.deinit(alloc);
        try ti.readAll(i32, &plain);
    }
    var smoothed: [256]i32 = undefined;
    {
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        var spec = spec_base;
        spec.hcomp_smooth = true;
        const hdu = try writeCompressed(i32, &fx.f, spec, &src);
        var ti = try TiledImage.of(&fx.f, hdu);
        defer ti.deinit(alloc);
        try testing.expectEqual(@as(?i64, 1), ti.paramNum("SMOOTH"));
        try ti.readAll(i32, &smoothed);
    }
    // Identical compressed pixels, differing only in the recorded SMOOTH request ⇒ the smoothed
    // read must differ (hsmooth engaged) yet stay within the same quantization bound.
    try testing.expect(!std.mem.eql(i32, &plain, &smoothed));
    for (src, smoothed) |o, g| {
        try testing.expect(@abs(@as(i64, o) - @as(i64, g)) <= 64 * 16);
    }
}

// ── HCOMPRESS_1 lossy overshoot: reconstructions past the ZBITPIX range CLAMP, not error ───
//
// A lossy H-transform reconstruction can legitimately land outside the declared integer range
// (quantization error near the type boundary). CFITSIO treats that overflow as EXPECTED for
// HCOMPRESS_1 — imcompress.c clips the value to the type range and resets NUM_OVERFLOW — so
// every `fpack -h -s N` integer file whose smoothed reconstruction overshoots is readable by
// funpack. A strict reject would make that whole file class unreadable (413). Each test field
// is an in-range noisy plateau at the type boundary with sharp holes punched in: the holes'
// high-frequency edges make the large-absolute-scale reconstruction overshoot. The source never
// touches the boundary value itself, so a boundary pixel in the decode proves the clamp fired.

test "HCOMPRESS_1 lossy decode overshooting maxInt(i16) clamps to 32767 like funpack" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [1024]i16 = undefined;
    var rng: u32 = 42;
    for (0..32) |r| {
        for (0..32) |c| {
            rng = rng *% 1103515245 +% 12345;
            var v: i16 = @intCast(32500 + (rng >> 16) % 201); // 32500..32700 < 32767
            if (c % 16 < 2 and r % 16 < 2) v = 2000;
            src[r * 32 + c] = v;
        }
    }
    const hdu = try writeCompressed(i16, &fx.f, .{
        .bitpix = 16,
        .axes = &.{ 32, 32 },
        .tile = &.{ 32, 32 },
        .codec = .hcompress_1,
        .hcomp_scale = -800,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [1024]i16 = undefined;
    try ti.readAll(i16, &out);
    var clamped: usize = 0;
    for (out) |v| {
        if (v == std.math.maxInt(i16)) clamped += 1;
    }
    try testing.expect(clamped > 0);
}

test "HCOMPRESS_1 lossy decode undershooting minInt(i16) clamps to -32768 like funpack" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [1024]i16 = undefined;
    var rng: u32 = 42;
    for (0..32) |r| {
        for (0..32) |c| {
            rng = rng *% 1103515245 +% 12345;
            var v: i16 = @intCast(-32500 - @as(i32, @intCast((rng >> 16) % 201))); // -32700..-32500
            if (c % 16 < 2 and r % 16 < 2) v = -2000;
            src[r * 32 + c] = v;
        }
    }
    const hdu = try writeCompressed(i16, &fx.f, .{
        .bitpix = 16,
        .axes = &.{ 32, 32 },
        .tile = &.{ 32, 32 },
        .codec = .hcompress_1,
        .hcomp_scale = -800,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [1024]i16 = undefined;
    try ti.readAll(i16, &out);
    var clamped: usize = 0;
    for (out) |v| {
        if (v == std.math.minInt(i16)) clamped += 1;
    }
    try testing.expect(clamped > 0);
}

test "HCOMPRESS_1 lossy decode below a BITPIX=8 image's 0 floor clamps to 0" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // Bright noisy plateau with near-zero holes. Empirically this field's reconstruction
    // crosses only the FLOOR (hole-edge ringing below 0); nothing reaches 255 — the plateau's
    // small noise smooths flat at this scale rather than ringing upward. The mirrored test
    // below covers the 255 ceiling.
    var src: [1024]u8 = undefined;
    var rng: u32 = 42;
    for (0..32) |r| {
        for (0..32) |c| {
            rng = rng *% 1103515245 +% 12345;
            var v: u8 = @intCast(230 + (rng >> 16) % 21); // 230..250, holes at 5: 0 never occurs
            if (c % 16 < 2 and r % 16 < 2) v = 5;
            src[r * 32 + c] = v;
        }
    }
    const hdu = try writeCompressed(u8, &fx.f, .{
        .bitpix = 8,
        .axes = &.{ 32, 32 },
        .tile = &.{ 32, 32 },
        .codec = .hcompress_1,
        .hcomp_scale = -100,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [1024]u8 = undefined;
    try ti.readAll(u8, &out);
    var clamped: usize = 0;
    for (out) |v| {
        if (v == 0) clamped += 1;
    }
    try testing.expect(clamped > 0);
}

test "HCOMPRESS_1 lossy decode above a BITPIX=8 image's 255 ceiling clamps to 255" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // Mirror of the floor test: dark noisy plateau with near-white holes, so the hole-edge
    // ringing overshoots ABOVE 255 — pinning the w == 1 clamp's upper bound, which the floor
    // field never reaches.
    var src: [1024]u8 = undefined;
    var rng: u32 = 42;
    for (0..32) |r| {
        for (0..32) |c| {
            rng = rng *% 1103515245 +% 12345;
            var v: u8 = @intCast(5 + (rng >> 16) % 21); // 5..25, holes at 250: 255 never occurs
            if (c % 16 < 2 and r % 16 < 2) v = 250;
            src[r * 32 + c] = v;
        }
    }
    const hdu = try writeCompressed(u8, &fx.f, .{
        .bitpix = 8,
        .axes = &.{ 32, 32 },
        .tile = &.{ 32, 32 },
        .codec = .hcompress_1,
        .hcomp_scale = -100,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [1024]u8 = undefined;
    try ti.readAll(u8, &out);
    var clamped: usize = 0;
    for (out) |v| {
        if (v == 255) clamped += 1;
    }
    try testing.expect(clamped > 0);
}

test "writeCompressed HCOMPRESS_1 noise-adaptive scale (request > 0) matches the CFITSIO mapping" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // Noisy 16×16 field (deterministic LCG) — background sigma is well above zero, so a
    // request of 4.0 must select a per-tile integer scale of round(4 × min-noise) > 1.
    var src: [256]i32 = undefined;
    var seed: u64 = 0xFEEDFACE12345678;
    for (&src) |*v| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        v.* = @rem(@as(i32, @bitCast(@as(u32, @truncate(seed >> 32)))), 20000);
    }
    const hdu = try writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 16, 16 },
        .tile = &.{ 16, 16 }, // single tile ⇒ one noise estimate over the whole image
        .codec = .hcompress_1,
        .hcomp_scale = 4.0,
    }, &src);

    // The expected integer scale, computed independently via the same public estimators.
    const noise = try imgstats.noiseEstimates(alloc, &src, 16, 16);
    var sigma = noise.noise3;
    if (noise.noise2 != 0 and noise.noise2 < sigma) sigma = noise.noise2;
    if (noise.noise5 != 0 and noise.noise5 < sigma) sigma = noise.noise5;
    const expect_scale: i64 = @intFromFloat(@trunc(@as(f64, @floatCast(@as(f32, @floatCast(4.0 * sigma)))) + 0.5));
    try testing.expect(expect_scale > 1);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(@as(?i64, 4), ti.paramNum("SCALE")); // request recorded, not the per-tile value

    // The authoritative per-tile scale is embedded in the tile stream (bytes 10..14, big-endian).
    var t = try BinTable.of(&fx.f, hdu);
    defer t.deinit(alloc);
    const cell = try readVlaRawBytes(&t, alloc, 0, 0);
    defer alloc.free(cell);
    const stream_scale = std.mem.readInt(u32, cell[10..][0..4], .big);
    try testing.expectEqual(@as(u32, @intCast(expect_scale)), stream_scale);

    // And the decode stays within the derived bound.
    var out: [256]i32 = undefined;
    try ti.readAll(i32, &out);
    for (src, out) |o, g| {
        try testing.expect(@abs(@as(i64, o) - @as(i64, g)) <= 64 * expect_scale);
    }

    // Drift pin: the CFITSIO-dylib-derived literal for this exact field. The re-derivation
    // above is self-consistent (it would move if the estimator chain drifted); this literal —
    // authored by calling the real fits_img_stats_int over the same data and applying
    // (int)(float(4 × sigma) + 0.5) — cannot. It pins the FULL noise → f32-cast → NINT chain,
    // FP knife edges included, against any future regression.
    try testing.expectEqual(@as(i64, 39478), expect_scale);
}

test "hcompressTileScale: absolute-mode rounding boundaries pin the (int)(x + 0.5) truncation" {
    const alloc = testing.allocator;
    const vals = [_]i32{ 0, 1, 2, 3 }; // noise path unused for request <= 0
    // request < 0 ⇒ |request|, then trunc(x + 0.5): half-integers round AWAY from zero (2.5→3,
    // 0.5→1 — a round-to-nearest-even port would give 2 and 0), and the largest f32 below 0.5
    // (0x3EFFFFFF ≈ 0.49999997) truncates to 0 — the f64 sum 0.99999997… does NOT round up.
    try testing.expectEqual(@as(i32, 3), try hcompressTileScale(alloc, &vals, 2, 2, -2.5));
    try testing.expectEqual(@as(i32, 1), try hcompressTileScale(alloc, &vals, 2, 2, -0.5));
    try testing.expectEqual(@as(i32, 0), try hcompressTileScale(alloc, &vals, 2, 2, -@as(f32, @bitCast(@as(u32, 0x3EFFFFFF)))));
    try testing.expectEqual(@as(i32, 0), try hcompressTileScale(alloc, &vals, 2, 2, 0.0));
}

test "writeCompressed HCOMPRESS_1 default tiling follows CFITSIO's row-block rule" {
    const alloc = testing.allocator;
    // ≤ 30 rows ⇒ whole image (24 → 24); > 30 ⇒ CFITSIO's preference order: 64 % 16 == 0 ⇒ 16,
    // 37 % 16 == 5 > 3 (last tile keeps ≥ 4 rows) ⇒ 16, and 51 rejects 16 (51 % 16 == 3) and
    // 24 (51 % 24 == 3) before accepting 20 (51 % 20 == 11) — pinning the chain ORDER, not just
    // the first candidate. Asserted through the written header (ZTILEn) — the authoritative
    // record — plus an exact lossless round-trip.
    inline for (.{ .{ 24, 24 }, .{ 64, 16 }, .{ 37, 16 }, .{ 51, 20 } }) |tc| {
        const rows = tc[0];
        const want: i64 = tc[1];
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        var src: [8 * rows]i32 = undefined;
        for (&src, 0..) |*v, i| v.* = @intCast(i % 97);
        const hdu = try writeCompressed(i32, &fx.f, .{
            .bitpix = 32,
            .axes = &.{ 8, rows },
            .codec = .hcompress_1, // no .tile: the default rule applies
        }, &src);
        try testing.expectEqual(@as(i64, 8), try hdu.header.getValue(i64, "ZTILE1"));
        try testing.expectEqual(want, try hdu.header.getValue(i64, "ZTILE2"));
        var ti = try TiledImage.of(&fx.f, hdu);
        defer ti.deinit(alloc);
        var out: [8 * rows]i32 = undefined;
        try ti.readAll(i32, &out);
        try testing.expectEqualSlices(i32, &src, &out);
    }
}

test "writeCompressed rejects misused/invalid HCOMPRESS lossy knobs (fail loud)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    const src = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };

    // Knobs on a non-HCOMPRESS codec would be silently ignored — refuse instead.
    try testing.expectError(error.DataConstraintViolated, writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 4, 3 },
        .codec = .gzip_1,
        .hcomp_scale = -4,
    }, &src));
    try testing.expectError(error.DataConstraintViolated, writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 4, 3 },
        .codec = .rice_1,
        .hcomp_smooth = true,
    }, &src));
    // A non-finite scale request is meaningless.
    try testing.expectError(error.DataConstraintViolated, writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 4, 3 },
        .tile = &.{ 4, 3 },
        .codec = .hcompress_1,
        .hcomp_scale = std.math.nan(f32),
    }, &src));
}

test "writeCompressed HCOMPRESS_1 with a 3-D tile fails loud, even on the lossy path" {
    // Regression (review M1): a tile with a non-unit higher dimension used to reach the noise
    // estimator's geometry assert when hcomp_scale > 0 (SIGABRT in Debug/ReleaseSafe) instead
    // of erroring; the lossless path already returned DataConstraintViolated. Both must error.
    const alloc = testing.allocator;
    var src: [4 * 4 * 2]i32 = undefined;
    for (&src, 0..) |*v, i| v.* = @intCast(i);
    inline for (.{ 0.0, 4.0, -8.0 }) |scale| {
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        try testing.expectError(error.DataConstraintViolated, writeCompressed(i32, &fx.f, .{
            .bitpix = 32,
            .axes = &.{ 4, 4, 2 },
            .tile = &.{ 4, 4, 2 },
            .codec = .hcompress_1,
            .hcomp_scale = scale,
        }, &src));
    }
}

// ── CMP-7 subtractive dithering on the write→read float path ──────────────────────────────────

test "writeCompressed float SUBTRACTIVE_DITHER_1 round-trips within tolerance" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [24]f32 = undefined;
    for (&src, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 1.5 - 5.0;
    const hdu = try writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 6, 4 }, // default tile ⇒ {6,1} ⇒ 4 row strips
        .codec = .gzip_1,
        .quantize = .subtractive_dither_1,
        .zdither0 = 1,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Quantize.subtractive_dither_1, ti.quantize);
    try testing.expectEqual(@as(?i64, 1), ti.zdither0);

    var out: [24]f32 = undefined;
    try ti.readAll(f32, &out);
    for (src, out) |s, o| try testing.expect(@abs(o - s) <= 0.01);
}

test "writeCompressed dithered: a tile holding ±Inf is stored losslessly and round-trips exactly" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // axes {6,4}, default tiling ⇒ 4 row-strips of 6. +Inf in row 0 makes tile 0 un-quantizable,
    // so it is stored as raw gzipped floats and must round-trip bit-exact (Inf plus its finite
    // neighbours), while the remaining tiles quantize normally. Before the fix, one Inf drove the
    // whole tile's ZSCALE/ZZERO to Inf and quantized every pixel to garbage.
    var src: [24]f32 = undefined;
    for (&src, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 1.5 - 5.0;
    src[3] = std.math.inf(f32);
    const hdu = try writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 6, 4 },
        .codec = .gzip_1,
        .quantize = .subtractive_dither_1,
        .zdither0 = 1,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [24]f32 = undefined;
    try ti.readAll(f32, &out);
    for (0..6) |i| {
        if (std.math.isInf(src[i])) {
            try testing.expect(std.math.isInf(out[i]));
        } else {
            try testing.expectEqual(src[i], out[i]); // lossless ⇒ exact
        }
    }
    for (6..24) |i| try testing.expect(@abs(out[i] - src[i]) <= 0.01);
}

test "writeCompressed dithered: NaN pixels emit ZBLANK and read back as NaN" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [24]f32 = undefined;
    for (&src, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 1.5 - 5.0;
    src[10] = std.math.nan(f32); // tile 1 (indices 6..12), still quantizable via its finite pixels
    const hdu = try writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 6, 4 },
        .codec = .gzip_1,
        .quantize = .subtractive_dither_1,
        .zdither0 = 1,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    // A ZBLANK card must have been emitted so third-party readers substitute NaN for the sentinel.
    try testing.expect(ti.zblank_kw != null or ti.zblank_col != null);

    var out: [24]f32 = undefined;
    try ti.readAll(f32, &out);
    try testing.expect(std.math.isNan(out[10]));
    for (src, out, 0..) |s, o, i| {
        if (i == 10) continue;
        try testing.expect(@abs(o - s) <= 0.01);
    }
}

test "writeCompressed float SUBTRACTIVE_DITHER_2 round-trips (exact zero preserved)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [24]f32 = undefined;
    for (&src, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) * 1.5 - 5.0;
    src[7] = 0.0; // exact zero must survive DITHER_2 losslessly (§10.2.1)
    const hdu = try writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 6, 4 },
        .codec = .gzip_1,
        .quantize = .subtractive_dither_2,
        .zdither0 = 5,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Quantize.subtractive_dither_2, ti.quantize);
    var out: [24]f32 = undefined;
    try ti.readAll(f32, &out);
    try testing.expectEqual(@as(f32, 0.0), out[7]);
    for (src, out, 0..) |s, o, i| {
        if (i == 7) continue;
        try testing.expect(@abs(o - s) <= 0.01);
    }
}

// ── CMP-8 quantized-float writes through the integer codecs (CFITSIO fits_quantize parity) ──

// Deterministic noise+gradient field (the same LCG family as the golden generator).
fn fillNoiseField(comptime FT: type, out: []FT, w: usize, base: f64) void {
    var state: u32 = 12345;
    for (out, 0..) |*v, i| {
        state = state *% 1664525 +% 1013904223;
        const u = @as(f64, @floatFromInt(state >> 8)) / 16777216.0;
        const r: f64 = @floatFromInt(i / w);
        const c: f64 = @floatFromInt(i % w);
        const x = base + (r + c) * 0.5 + (u - 0.5) * 8.0;
        v.* = if (FT == f32) @floatCast(x) else x;
    }
}

test "writeCompressed quantized-float HCOMPRESS_1: dithered write round-trips within the absolute step" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [32 * 32]f32 = undefined;
    fillNoiseField(f32, &src, 32, 10.0);
    const hdu = try writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 32, 32 }, // default HCOMPRESS tiling ⇒ 32×32 (≤ 30 rows rule ⇒ whole image? 32 > 30 ⇒ 16-row blocks)
        .codec = .hcompress_1,
        .quantize = .subtractive_dither_1,
        .zdither0 = 1,
        .quantize_level = -0.25, // absolute step ⇒ deterministic |err| ≤ 0.125 bound
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Codec.hcompress_1, ti.ztype);
    try testing.expectEqual(Quantize.subtractive_dither_1, ti.quantize);
    try testing.expectEqual(@as(?i64, 1), ti.zdither0);
    var out: [32 * 32]f32 = undefined;
    try ti.readAll(f32, &out);
    for (src, out) |s, o| try testing.expect(@abs(o - s) <= 0.125 + 1e-5);
}

test "writeCompressed quantized-float RICE_1: NO_DITHER write emits no ZDITHER0 and round-trips" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [16 * 8]f32 = undefined;
    fillNoiseField(f32, &src, 16, 50.0);
    const hdu = try writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 16, 8 },
        .codec = .rice_1,
        .quantize = .no_dither,
        .quantize_level = -0.5,
    }, &src);

    // NO_DITHER: ZQUANTIZ present, ZDITHER0 absent (no draws to reproduce — CFITSIO writes none).
    const zq = try hdu.header.getString(alloc, "ZQUANTIZ");
    defer alloc.free(zq);
    try testing.expectEqualStrings("NO_DITHER", std.mem.trim(u8, zq, " "));
    try testing.expect(!hdu.header.has("ZDITHER0"));

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Quantize.no_dither, ti.quantize);
    var out: [16 * 8]f32 = undefined;
    try ti.readAll(f32, &out);
    for (src, out) |s, o| try testing.expect(@abs(o - s) <= 0.25 + 1e-5);
}

test "writeCompressed quantized-float: noise-based default level, f64 pixels, lossy HCOMPRESS stage" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [32 * 32]f64 = undefined;
    fillNoiseField(f64, &src, 32, 10.0);
    // Default quantize_level (fpack -q 4) + an additional lossy HCOMPRESS stage over the
    // quantized integers (hcomp_scale > 0, noise-adaptive) — both CFITSIO-parity paths.
    const hdu = try writeCompressed(f64, &fx.f, .{
        .bitpix = -64,
        .axes = &.{ 32, 32 },
        .codec = .hcompress_1,
        .quantize = .subtractive_dither_1,
        .zdither0 = 7,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    var out: [32 * 32]f64 = undefined;
    try ti.readAll(f64, &out);
    // Noise-based q=4 ⇒ step ≈ sigma/4 where sigma ≈ the (u−0.5)·8 noise MAD; generous sanity
    // bound (the exact step is pinned separately by the quantizer's reference vectors).
    for (src, out) |s, o| try testing.expect(@abs(o - s) <= 1.5);
}

test "writeCompressed quantized f64: dequantization keeps full double precision (no f32 funnel)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    // Values ~1000 make the f32 grid spacing (2^-14 ≈ 6.1e-5) far coarser than the dither
    // term's contribution, so an f32 funnel anywhere in the dequantization is observable.
    var src: [32 * 32]f64 = undefined;
    fillNoiseField(f64, &src, 32, 1000.0);
    const hdu = try writeCompressed(f64, &fx.f, .{
        .bitpix = -64,
        .axes = &.{ 32, 32 },
        .codec = .rice_1,
        .quantize = .subtractive_dither_1,
        .zdither0 = 1,
        .quantize_level = -0.25, // absolute step ⇒ deterministic |err| ≤ 0.125 bound
    }, &src);

    const bytepix_name = try hdu.header.getString(alloc, "ZNAME2");
    defer alloc.free(bytepix_name);
    try testing.expectEqualStrings("BYTEPIX", std.mem.trim(u8, bytepix_name, " "));
    try testing.expectEqual(@as(i64, 4), try hdu.header.getValue(i64, "ZVAL2"));

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expectEqual(Quantize.subtractive_dither_1, ti.quantize);
    var out: [32 * 32]f64 = undefined;
    try ti.readAll(f64, &out);
    // Canary: the dequantized `(stored − r + 0.5)·ZSCALE + ZZERO` values carry the f32 dither
    // draw's low bits, so virtually none of them sit on the f32 grid. If the read path is ever
    // funneled through f32 again, every pixel becomes f32-representable and this fails.
    var beyond_f32: usize = 0;
    var lossy: usize = 0;
    for (src, out) |s, o| {
        try testing.expect(@abs(o - s) <= 0.125 + 1e-9);
        if (o != @as(f64, @as(f32, @floatCast(o)))) beyond_f32 += 1;
        if (o != s) lossy += 1;
    }
    try testing.expect(beyond_f32 > 0);
    // Guard the canary itself: the source values are not f32-representable either, so a silent
    // lossless fallback (raw f64s stored verbatim, `out == src`) would pass the check above
    // without the dequantization ever running. Quantization is lossy — some pixel must differ.
    try testing.expect(lossy > 0);
}

test "writeCompressed quantized-float: NaN emits ZBLANK, ±Inf tile falls back lossless (HCOMPRESS)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [32 * 32]f32 = undefined;
    fillNoiseField(f32, &src, 32, 10.0);
    src[40] = std.math.nan(f32); // in the first 16-row tile block
    src[32 * 20 + 3] = std.math.inf(f32); // second tile ⇒ whole tile stored losslessly
    const hdu = try writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 32, 32 },
        .codec = .hcompress_1,
        .quantize = .subtractive_dither_1,
        .zdither0 = 3,
        .quantize_level = -0.25,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    try testing.expect(ti.zblank_kw != null or ti.zblank_col != null);
    var out: [32 * 32]f32 = undefined;
    try ti.readAll(f32, &out);
    try testing.expect(std.math.isNan(out[40]));
    try testing.expect(std.math.isInf(out[32 * 20 + 3]));
    for (src, out, 0..) |s, o, i| {
        if (i == 40) continue;
        if (i / (32 * 16) == 1) {
            // The ±Inf tile is a lossless raw-float fallback: bit-exact, Inf included.
            if (!std.math.isInf(s)) try testing.expectEqual(s, o);
        } else {
            try testing.expect(@abs(o - s) <= 0.125 + 1e-5);
        }
    }
}

test "writeCompressed quantized-float GZIP: explicit quantize_level engages the CFITSIO quantizer" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [16 * 16]f32 = undefined;
    fillNoiseField(f32, &src, 16, 10.0);
    const hdu = try writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 16, 16 }, // default GZIP tiling ⇒ 16 row strips
        .codec = .gzip_2,
        .quantize = .subtractive_dither_1,
        .zdither0 = 1,
        .quantize_level = -0.25,
    }, &src);

    var ti = try TiledImage.of(&fx.f, hdu);
    defer ti.deinit(alloc);
    // The CFITSIO quantizer records the ABSOLUTE step as ZSCALE — the legacy scheme would have
    // written (max−min)/100000 (a far smaller value); this distinguishes the two paths.
    var bt = try BinTable.of(&fx.f, hdu);
    defer bt.deinit(alloc);
    var zs: [1]f64 = undefined;
    try bt.readColumn(f64, .{ .name = "ZSCALE" }, 0, &zs, .{});
    try testing.expectEqual(@as(f64, 0.25), zs[0]);
    var out: [16 * 16]f32 = undefined;
    try ti.readAll(f32, &out);
    for (src, out) |s, o| try testing.expect(@abs(o - s) <= 0.125 + 1e-5);
}

test "writeCompressed quantized-float: fail-loud gates (PLIO, DITHER_2+HCOMPRESS, truncation, stray knobs)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    var src: [64]f32 = undefined;
    fillNoiseField(f32, &src, 8, 10.0);
    // PLIO cannot hold the quantizer's output range: rejected up front.
    try testing.expectError(error.UnsupportedCodec, writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 8, 8 },
        .codec = .plio_1,
        .quantize = .subtractive_dither_1,
    }, &src));
    // CFITSIO silently coerces DITHER_2→DITHER_1 under HCOMPRESS; zigfitsio fails loud.
    try testing.expectError(error.DataConstraintViolated, writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 8, 8 },
        .codec = .hcompress_1,
        .quantize = .subtractive_dither_2,
    }, &src));
    // Float RICE/HCOMPRESS without quantization would be CFITSIO's silent float→int
    // truncation; zigfitsio refuses.
    try testing.expectError(error.UnsupportedCodec, writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 8, 8 },
        .codec = .rice_1,
    }, &src));
    // quantize_level on a non-quantizing write is never silently ignored.
    var ints: [64]i32 = undefined;
    for (&ints, 0..) |*v, i| v.* = @intCast(i);
    try testing.expectError(error.DataConstraintViolated, writeCompressed(i32, &fx.f, .{
        .bitpix = 32,
        .axes = &.{ 8, 8 },
        .codec = .rice_1,
        .quantize_level = 4.0,
    }, &ints));
    // Non-finite quantize_level is meaningless.
    try testing.expectError(error.DataConstraintViolated, writeCompressed(f32, &fx.f, .{
        .bitpix = -32,
        .axes = &.{ 8, 8 },
        .codec = .hcompress_1,
        .quantize = .subtractive_dither_1,
        .quantize_level = std.math.nan(f32),
    }, &src));
}

// ── CMP-9 tile-compressed table read ─────────────────────────────────────────────────────────

test "ofTable decompresses GZIP_2 per-tile column data back to rows" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const col0 = [_]i32{ 10, 20, 30, 40, 50 };
    const col1 = [_]f32{ 1.5, 2.5, 3.5, 4.5, 5.5 };
    const orig_rows: u64 = 5;
    const tilelen: u64 = 2; // ⇒ 3 tiles: rows {0,1},{2,3},{4}
    const ntiles: u64 = 3;

    var h = Header.initEmpty();
    errdefer h.deinit(alloc);
    try h.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, null);
    try h.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
    try h.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "NAXIS1", .{ .int = 16 }, null); // two 1PB descriptors
    try h.appendValue(alloc, "NAXIS2", .{ .int = @intCast(ntiles) }, null);
    try h.appendValue(alloc, "PCOUNT", .{ .int = 4096 }, null);
    try h.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
    try h.appendValue(alloc, "TFIELDS", .{ .int = 2 }, null);
    try h.appendValue(alloc, "TFORM1", .{ .string = "1PB" }, null);
    try h.appendValue(alloc, "TTYPE1", .{ .string = "X" }, null);
    try h.appendValue(alloc, "TFORM2", .{ .string = "1PB" }, null);
    try h.appendValue(alloc, "TTYPE2", .{ .string = "Y" }, null);
    try h.appendValue(alloc, "ZTABLE", .{ .logical = true }, null);
    try h.appendValue(alloc, "ZNAXIS1", .{ .int = 8 }, null);
    try h.appendValue(alloc, "ZNAXIS2", .{ .int = @intCast(orig_rows) }, null);
    try h.appendValue(alloc, "ZTILELEN", .{ .int = @intCast(tilelen) }, null);
    try h.appendValue(alloc, "ZFORM1", .{ .string = "1J" }, null);
    try h.appendValue(alloc, "ZFORM2", .{ .string = "1E" }, null);
    try h.appendValue(alloc, "ZCTYP1", .{ .string = "GZIP_2" }, null);
    try h.appendValue(alloc, "ZCTYP2", .{ .string = "GZIP_2" }, null);
    try h.ensureEnd(alloc);
    const hdu = try fx.f.appendHdu(h);

    var t = try BinTable.of(&fx.f, hdu);
    var mgr = try HeapManager.initForTable(&t);
    {
        var tile: u64 = 0;
        while (tile < ntiles) : (tile += 1) {
            const first = tile * tilelen;
            const k: usize = @intCast(@min(tilelen, orig_rows - first));
            // col0 (i32) big-endian, gzip2 width 4.
            const fb: usize = @intCast(first);
            var raw0: [tilelen * 4]u8 = undefined;
            for (0..k) |j| std.mem.writeInt(i32, raw0[j * 4 ..][0..4], col0[fb + j], .big);
            const e0 = try gzip.gzip2Encode(alloc, raw0[0 .. k * 4], 4);
            defer alloc.free(e0);
            try writeVlaCell(alloc, &t, &mgr, .{ .index = 0 }, tile, u8, e0);
            // col1 (f32) big-endian, gzip2 width 4.
            var raw1: [tilelen * 4]u8 = undefined;
            for (0..k) |j| endian.write(f32, col1[fb + j], raw1[j * 4 ..][0..4]);
            const e1 = try gzip.gzip2Encode(alloc, raw1[0 .. k * 4], 4);
            defer alloc.free(e1);
            try writeVlaCell(alloc, &t, &mgr, .{ .index = 1 }, tile, u8, e1);
        }
    }
    mgr.deinit(alloc);
    t.deinit(alloc);

    var tt = try TileTable.ofTable(&fx.f, hdu);
    defer tt.deinit(alloc);
    try testing.expectEqual(@as(u64, 5), tt.orig_rows);
    try testing.expectEqual(@as(u64, 3), tt.ntiles);

    var o0: [5]i32 = undefined;
    try tt.readColumn(i32, 0, &o0);
    try testing.expectEqualSlices(i32, &col0, &o0);

    var o1: [5]f32 = undefined;
    try tt.readColumn(f32, 1, &o1);
    try testing.expectEqualSlices(f32, &col1, &o1);
}

test "ofTable rejects a non-ZTABLE binary table" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);

    const spec = ZSpec{
        .ztype = "GZIP_1",
        .zbitpix = 16,
        .znaxisn = &.{4},
        .ztilen = &.{4},
        .nrows = 1,
        .pcount = 64,
        .tforms = &.{"1PB"},
        .ttypes = &.{"COMPRESSED_DATA"},
    };
    const hdu = try fx.f.appendHdu(try buildZHeader(alloc, spec));
    try testing.expectError(error.WrongHduType, TileTable.ofTable(&fx.f, hdu));
}
