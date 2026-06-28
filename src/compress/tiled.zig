//! Tiled-compressed image view (`FR-CMP-1`; design §17.1–§17.2; FITS 4.0 §10.1).
//!
//! A tiled-compressed image is a `BINTABLE` carrying `ZIMAGE = T`. The *uncompressed* image
//! geometry lives in keywords (`ZCMPTYPE`, `ZBITPIX`, `ZNAXIS`, `ZNAXISn`, `ZTILEn`, the
//! optional `ZQUANTIZ`/`ZDITHER0` dither method and `ZNAMEn`/`ZVALn` codec parameters); the
//! pixel payload lives in columns: `COMPRESSED_DATA` (a `1P`/`1Q` byte VLA, one row per tile),
//! the optional `GZIP_COMPRESSED_DATA`/`UNCOMPRESSED_DATA` fallbacks, and the per-tile linear
//! `ZSCALE`/`ZZERO` (`ZBLANK` may be either a keyword or a column).
//!
//! `TiledImage` parses that structure and decodes the covering tiles into a normal, row-major
//! image buffer (`readAll`). The image space is tiled row-major with the first axis varying
//! fastest (§10.1); tile `r` is table row `r`. Tiles on an axis whose length is not a multiple
//! of the tile size are clipped to the image bound (edge/partial tiles).
//!
//! This is the **read** path and supports **GZIP only** for now: `GZIP_1` (plain gzip over the
//! big-endian stored values) and `GZIP_2` (gzip over the MSB-first type-aware byte shuffle, see
//! `compress/gzip.zig`). Any other `ZCMPTYPE` (`RICE_1`/`PLIO_1`/`HCOMPRESS_1`/unknown) yields
//! `error.UnsupportedCodec` from `readAll` — never a silent mis-read (`NFR-INTEROP-1`). All
//! declared sizes are validated against `Limits` and the device length before allocating
//! (`NFR-SAFE-1`); a tile that decodes to the wrong size is `error.CorruptTile`.
const std = @import("std");
const errors = @import("../errors.zig");
const convert = @import("../convert.zig");
const endian = @import("../endian.zig");
const limits = @import("../limits.zig");
const Fits = @import("../fits.zig").Fits;
const Hdu = @import("../hdu.zig").Hdu;
const binary = @import("../table/binary.zig");
const BinTable = binary.BinTable;
const ColumnRef = binary.ColumnRef;
const heap = @import("../table/heap.zig");
const gzip = @import("gzip.zig");
const Matches = @import("../header/name.zig").Matches;

const Allocator = std.mem.Allocator;

/// The tile compression algorithm named by `ZCMPTYPE`. Only `gzip_1`/`gzip_2` are decoded by
/// this module; the rest are recognized (so they can be reported precisely) but unimplemented.
pub const Codec = enum {
    /// `GZIP_1`: gzip over the raw big-endian stored values.
    gzip_1,
    /// `GZIP_2`: gzip over the MSB-first type-aware byte shuffle of the stored values.
    gzip_2,
    /// `RICE_1` (unimplemented in the read path — M3).
    rice_1,
    /// `PLIO_1` (unimplemented in the read path — M3).
    plio_1,
    /// `HCOMPRESS_1` (unimplemented in the read path — M3).
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

    /// Whether this module can decode tiles compressed with this codec (GZIP only).
    pub fn isImplemented(self: Codec) bool {
        return self == .gzip_1 or self == .gzip_2;
    }
};

/// The floating-point quantization/dither method named by `ZQUANTIZ` (recorded, not applied on
/// the GZIP read path, which is lossless).
pub const Quantize = enum {
    /// No dithering (`NO_DITHER`) or `ZQUANTIZ` absent.
    none,
    /// `SUBTRACTIVE_DITHER_1`.
    subtractive_dither_1,
    /// `SUBTRACTIVE_DITHER_2`.
    subtractive_dither_2,
    /// An unrecognized `ZQUANTIZ` value.
    unknown,

    /// Map a `ZQUANTIZ` string (case-insensitive, blank-trimmed) to a `Quantize`.
    pub fn fromName(s_in: []const u8) Quantize {
        const s = std.mem.trim(u8, s_in, " ");
        if (std.ascii.eqlIgnoreCase(s, "NO_DITHER")) return .none;
        if (std.ascii.eqlIgnoreCase(s, "SUBTRACTIVE_DITHER_1")) return .subtractive_dither_1;
        if (std.ascii.eqlIgnoreCase(s, "SUBTRACTIVE_DITHER_2")) return .subtractive_dither_2;
        return .unknown;
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

        // Tile count = product of per-axis covering-tile counts (handles non-multiple sizes).
        var ntiles_total: u64 = 1;
        for (0..znaxis) |i| {
            ntiles_total = try limits.mul(ntiles_total, ceilDiv(znaxisn[i], ztilen[i]));
        }

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
        const zblank_kw: ?i64 = if (zblank_col == null) (hdu.header.getValue(i64, "ZBLANK") catch null) else null;

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

            const expected = try limits.mul(npix_tile, w);
            try limits.ensureWithin(expected, self.fits.limits.max_tile_bytes, null);

            const stored_bytes = try self.decodeTile(alloc, row, w, expected);
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

    // Decode (or read) the stored-value bytes of tile `row`, choosing the payload column per the
    // §10.1 precedence: COMPRESSED_DATA → GZIP_COMPRESSED_DATA → UNCOMPRESSED_DATA → all-zero.
    // The gzip decode ceiling is `expected + 1`: `std`'s bounded reader reports `StreamTooLong`
    // when the stream meets *or exceeds* the limit, so an exact-size tile needs headroom of one
    // byte; the caller's `stored_bytes.len == expected` check still enforces exactness.
    fn decodeTile(self: *TiledImage, alloc: Allocator, row: u64, w: usize, expected: u64) ReadError![]u8 {
        const cap = expected + 1;
        if (self.comp_col) |col| {
            if (try self.hasData(col, row)) {
                const cbytes = try self.readDescBytes(alloc, col, row);
                defer alloc.free(cbytes);
                return switch (self.ztype) {
                    .gzip_1 => try gzip.gzipDecode(alloc, cbytes, cap),
                    .gzip_2 => try gzip.gzip2Decode(alloc, cbytes, w, cap),
                    else => error.UnsupportedCodec,
                };
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

    // Whether the VLA cell at (`row`, `col`) holds a non-empty payload.
    fn hasData(self: *TiledImage, col: u16, row: u64) heap.DescriptorError!bool {
        const d = try heap.readDescriptor(&self.base, .{ .index = col }, row);
        return d.len > 0;
    }

    // Read the raw (big-endian, untranslated) payload bytes of the VLA cell at (`row`, `col`):
    // `descriptor.len × elemBytes` bytes, bounds-checked against the heap, the data unit, and
    // the device length before allocating (NFR-SAFE-1).
    fn readDescBytes(self: *TiledImage, alloc: Allocator, col: u16, row: u64) heap.ReadError![]u8 {
        const column = &self.base.columns[col];
        const spec = try heap.VlaSpec.of(column);
        const d = try heap.readDescriptor(&self.base, .{ .index = col }, row);
        if (d.len < 0 or d.off < 0) return error.BadDescriptor;
        const count: u64 = @intCast(d.len);
        const off: u64 = @intCast(d.off);
        const bytes = try limits.mul(count, spec.elem.elemBytes());
        try limits.ensureWithin(bytes, self.fits.limits.max_heap_bytes, null);

        const geom = try heap.heapGeometry(&self.base);
        const heap_end = std.math.add(u64, off, bytes) catch return error.BadDescriptor;
        if (heap_end > geom.heap_size) return error.BadDescriptor;
        const abs = geom.heap_abs_off + off;
        const abs_end = abs + bytes;
        if (abs_end > geom.data_abs_end) return error.BadDescriptor;
        const dev_size = try self.fits.dev.getSize();
        if (abs_end > dev_size) return error.BadDescriptor;

        const buf = try alloc.alloc(u8, @intCast(bytes));
        errdefer alloc.free(buf);
        try self.fits.dev.readAll(buf, abs);
        return buf;
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
};

// ── helpers ──────────────────────────────────────────────────────────────────────────────

fn validBitpix(b: i64) bool {
    return switch (b) {
        8, 16, 32, 64, -32, -64 => true,
        else => false,
    };
}

// Covering-tile count along one axis: ceil(len/tile), with 0 for a zero-length axis. `tile` is
// guaranteed positive by `of`.
fn ceilDiv(len: u64, tile: u64) u64 {
    if (len == 0) return 0;
    return (len - 1) / tile + 1;
}

// First column index whose TTYPEn matches `name` (case-insensitive), or null.
fn findCol(base: *const BinTable, name: []const u8) ?u16 {
    var m: Matches = .{};
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

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;
const Header = @import("../header/header.zig").Header;
const common = @import("../table/common.zig");
const BinTform = common.BinTform;
const HeapManager = heap.HeapManager;
const writeVlaCell = heap.writeVlaCell;

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
    try testing.expectEqual(Quantize.none, ti.quantize);

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

test "unsupported ZCMPTYPE gates readAll with UnsupportedCodec" {
    const alloc = testing.allocator;

    for ([_][]const u8{ "RICE_1", "PLIO_1", "HCOMPRESS_1", "BOGUS_9" }) |name| {
        var fx = try Fixture.init(alloc);
        defer fx.deinit(alloc);
        const spec = ZSpec{
            .ztype = name,
            .zbitpix = 16,
            .znaxisn = &.{ 4, 3 },
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
