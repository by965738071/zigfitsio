//! Sequential stream backend and the materialize-to-`Device` path (FR-IO-3, FR-RMT-1, §8.1).
//!
//! Some sources (stdin, a plain HTTP body, a gzip stream) are sequential-only. Rather than
//! fake `seek`, a sequential `Stream` is **materialized** into an in-memory `Device` so the
//! higher layers get uniform random access (the documented cost of §8.1). The output side of
//! whole-file gzip and stdout writing also live here.
//!
//! This is an OS-adjacent leaf module (it reads `std.Io.Reader`/`Writer`), excluded from the
//! `wasm32-freestanding` build graph.
const std = @import("std");
const IoError = @import("../errors.zig").IoError;
const LimitError = @import("../errors.zig").LimitError;
const MemoryDevice = @import("memory.zig").MemoryDevice;
const Device = @import("device.zig").Device;

/// Read every remaining byte of a sequential `reader` into a fresh in-memory `Device`,
/// bounded by `max_bytes` (NFR-SAFE-1). The returned `MemoryDevice` owns its buffer; call
/// `deinit` on it. This is how stdin and gzip streams gain seekable random access.
pub fn materialize(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_bytes: u64,
) (LimitError || std.mem.Allocator.Error)!MemoryDevice {
    const data = reader.allocRemaining(allocator, std.Io.Limit.limited64(max_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.LimitExceeded,
        else => return error.LimitExceeded, // read failure: surface as a bounded-read failure
    };
    defer allocator.free(data);
    return MemoryDevice.initBytes(allocator, data);
}

/// Write all of `bytes` to a sequential `writer` (e.g. stdout or a gzip sink), flushing.
pub fn drainAll(writer: *std.Io.Writer, bytes: []const u8) IoError!void {
    writer.writeAll(bytes) catch return error.WriteFailed;
    writer.flush() catch return error.WriteFailed;
}

/// Local error for the gzip decode path: a malformed/truncated container or a deflate stream
/// that fails to inflate. The `flate` decoder reports its concrete fault (bad magic, CRC32
/// mismatch, oversubscribed Huffman tree, ...) by surfacing `error.ReadFailed`; we collapse
/// every such fault into one typed value so callers fail-fast (FR-ERR-1/2) instead of
/// panicking on garbage input (NFR-INTEROP-1). Defined locally because `errors.zig`'s
/// `CompressError` is the *tiled*-image codec set, not the whole-file gzip container.
pub const GzipError = error{Corrupt};

/// gzip window size (RFC-1952's deflate body uses the 32 KiB LZ77 history; the decoder needs a
/// double window, `flate.max_window_len`). Allocated, not stack-resident, to keep these I/O
/// leaf functions cheap on stack and to honor the passed allocator.
const window_len = std.compress.flate.max_window_len;

/// Transparently decompress a whole-file gzip stream (`*.fits.gz`, FR-RMT-1) into a fresh
/// in-memory `Device` so the higher layers get the random access they assume (§8.1). The
/// RFC-1952 container (10-byte header, CRC32 + ISIZE footer) is parsed by
/// `std.compress.flate.Decompress` with `Container.gzip` — never hand-rolled.
///
/// The *decompressed* size is bounded by `max_bytes` (NFR-SAFE-1): a payload that inflates to
/// `max_bytes` or more is rejected with `error.LimitExceeded` rather than exhausting memory on
/// a zip-bomb. The returned `MemoryDevice` owns its buffer; call `deinit` on it.
///
/// Errors: `LimitExceeded` (inflated size hit the ceiling), `OutOfMemory`, or `Corrupt`
/// (bad/garbage/truncated gzip — surfaced as a typed error, never a panic).
pub fn materializeGzip(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_bytes: u64,
) (LimitError || std.mem.Allocator.Error || GzipError)!MemoryDevice {
    const window = try allocator.alloc(u8, window_len);
    defer allocator.free(window);

    var decompress = std.compress.flate.Decompress.init(reader, .gzip, window);
    const data = decompress.reader.allocRemaining(
        allocator,
        std.Io.Limit.limited64(max_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.LimitExceeded, // inflated past the ceiling
        // The decoder reports its concrete fault via `decompress.err`; any decode failure or
        // backing-read failure arrives here as `ReadFailed`. Collapse to a typed `Corrupt`.
        error.ReadFailed => return error.Corrupt,
    };
    defer allocator.free(data);
    return MemoryDevice.initBytes(allocator, data);
}

/// gzip-compress `bytes` into `writer` (the output side of whole-file gzip, FR-RMT-1) and
/// flush. The RFC-1952 container is produced by `std.compress.flate.Compress` with
/// `Container.gzip` (header at init, CRC32 + ISIZE footer at `finish`) — never hand-rolled.
///
/// `writer` must be a buffered sink (its buffer must exceed 8 bytes, per `Compress.init`).
/// The 64 KiB deflate window is taken from `allocator`; if that scratch cannot be obtained the
/// compression cannot proceed and is surfaced as `error.WriteFailed` (the only `IoError`-shaped
/// outcome — this function never returns `Allocator.Error`).
pub fn compressToGzip(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    bytes: []const u8,
) IoError!void {
    const window = allocator.alloc(u8, window_len) catch return error.WriteFailed;
    defer allocator.free(window);

    // `init` writes the gzip header straight to `writer`; `compress.writer` is the *plaintext*
    // sink that compresses into `writer`.
    var compress = std.compress.flate.Compress.init(
        writer,
        window,
        .gzip,
        .default,
    ) catch return error.WriteFailed;
    compress.writer.writeAll(bytes) catch return error.WriteFailed;
    compress.finish() catch return error.WriteFailed; // drains the body + writes the footer
    writer.flush() catch return error.WriteFailed; // push the assembled stream to the real sink
}

// --- Fits-facing whole-file gzip open/save (FR-RMT-2) ----------------------------------------

/// Inflate in-memory whole-file gzip bytes (`compressed`) into a fresh seekable `MemoryDevice` —
/// the random-access form the upper FITS layers require (§8.1, FR-RMT-2). This is the wiring used
/// by `Fits.openGzip`: a corrupt or truncated container is mapped to `error.ReadFailed` so callers
/// receive a typed `IoError` instead of the codec-local `GzipError`. The *decompressed* size is
/// bounded by `max_bytes` (NFR-SAFE-1). The returned device owns its buffer; call `deinit`.
pub fn inflateGzipToDevice(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    max_bytes: u64,
) (IoError || LimitError || std.mem.Allocator.Error)!MemoryDevice {
    var reader = std.Io.Reader.fixed(compressed);
    return materializeGzip(allocator, &reader, max_bytes) catch |err| switch (err) {
        error.Corrupt => error.ReadFailed,
        else => |e| e,
    };
}

/// Gzip-compress every byte of `src` (a random-access `Device`) into `writer`, producing a
/// whole-file gzip container (the export side of FR-RMT-2, used by `Fits.saveGzipFile`). The whole
/// device is read into a bounded scratch buffer (`max_bytes`, NFR-SAFE-1) and handed to
/// `compressToGzip`. `writer` must be a buffered sink (see `compressToGzip`).
pub fn compressDeviceToGzip(
    allocator: std.mem.Allocator,
    src: Device,
    writer: *std.Io.Writer,
    max_bytes: u64,
) (IoError || LimitError || std.mem.Allocator.Error)!void {
    const size64 = try src.getSize();
    if (size64 > max_bytes) return error.LimitExceeded;
    const size: usize = @intCast(size64);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    try src.readAll(buf, 0); // a zero-length read is a no-op
    try compressToGzip(allocator, writer, buf);
}

const testing = std.testing;

test "stdin-style stream materializes into a seekable Device and round-trips" {
    const payload = "SIMPLE  =                    T" ** 10; // arbitrary sequential bytes
    var reader = std.Io.Reader.fixed(payload);
    var mem = try materialize(testing.allocator, &reader, 1 << 20);
    defer mem.deinit();

    const dev = mem.device();
    try testing.expectEqual(@as(u64, payload.len), try dev.getSize());
    var buf: [30]u8 = undefined;
    try dev.readAll(&buf, 30); // seek to the 2nd copy, proving random access
    try testing.expectEqualStrings(payload[30..60], &buf);
}

test "materialize enforces the byte ceiling" {
    var reader = std.Io.Reader.fixed("0123456789");
    try testing.expectError(error.LimitExceeded, materialize(testing.allocator, &reader, 4));
}

test "drainAll writes through a writer" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try drainAll(&w, "hello");
    try testing.expectEqualStrings("hello", w.buffered());
}

// --- whole-file gzip (FR-RMT-1) --------------------------------------------------------------

/// Compress `plain` into a heap slice the caller owns (a small helper so the gzip tests can
/// hand realistic compressed bytes to `materializeGzip`).
fn gzipToOwned(plain: []const u8) ![]u8 {
    // The sink must be a *buffered* writer (`Compress.init` asserts buffer > 8); seed the
    // allocating writer with capacity so it satisfies that contract, as a real block/file sink
    // would. It still grows on demand for larger streams.
    var aw: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer aw.deinit();
    try compressToGzip(testing.allocator, &aw.writer, plain);
    return aw.toOwnedSlice();
}

test "gzip round-trips a FITS-ish buffer through materializeGzip" {
    // A representative mix: a header-card prefix, then a long compressible run, then the
    // 2880-byte block zero-fill — exercises both literals and back-references in deflate.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(testing.allocator);
    try plain.appendSlice(testing.allocator, "SIMPLE  =                    T" ** 16);
    try plain.appendSlice(testing.allocator, "BITPIX  =                   16" ** 16);
    try plain.appendNTimes(testing.allocator, ' ', 2880);
    try plain.appendNTimes(testing.allocator, 0, 2880);

    const compressed = try gzipToOwned(plain.items);
    defer testing.allocator.free(compressed);
    // gzip should actually shrink this highly repetitive payload.
    try testing.expect(compressed.len < plain.items.len);

    var reader = std.Io.Reader.fixed(compressed);
    var mem = try materializeGzip(testing.allocator, &reader, 1 << 20);
    defer mem.deinit();

    const dev = mem.device();
    try testing.expectEqual(@as(u64, plain.items.len), try dev.getSize());
    // Content equality + proof of random access: read a window from the middle.
    try testing.expectEqualSlices(u8, plain.items, mem.bytes());
    var probe: [30]u8 = undefined;
    try dev.readAll(&probe, 30);
    try testing.expectEqualSlices(u8, plain.items[30..60], &probe);
}

test "materializeGzip enforces the decompressed-size ceiling" {
    // ~8 KiB of zeros compresses tiny but inflates well past a 1 KiB ceiling -> LimitExceeded.
    const plain = [_]u8{0} ** 8192;
    const compressed = try gzipToOwned(&plain);
    defer testing.allocator.free(compressed);

    var reader = std.Io.Reader.fixed(compressed);
    try testing.expectError(
        error.LimitExceeded,
        materializeGzip(testing.allocator, &reader, 1024),
    );
}

test "materializeGzip rejects garbage with a typed error, not a panic" {
    const garbage = "this is plainly not a gzip stream, just ASCII padded to exceed ten bytes";
    var reader = std.Io.Reader.fixed(garbage);
    try testing.expectError(
        error.Corrupt,
        materializeGzip(testing.allocator, &reader, 1 << 20),
    );
}

test "materializeGzip rejects a truncated gzip container" {
    const compressed = try gzipToOwned("payload that will be cut off mid-stream " ** 8);
    defer testing.allocator.free(compressed);

    // Lop off the trailing CRC32/ISIZE footer (and a few body bytes): the decoder must fault.
    var reader = std.Io.Reader.fixed(compressed[0 .. compressed.len - 6]);
    try testing.expectError(
        error.Corrupt,
        materializeGzip(testing.allocator, &reader, 1 << 20),
    );
}

test "compressToGzip emits a valid RFC-1952 container (magic + CM)" {
    const compressed = try gzipToOwned("zigfitsio");
    defer testing.allocator.free(compressed);
    try testing.expect(compressed.len >= 18); // 10-byte header + 8-byte footer minimum
    try testing.expectEqual(@as(u8, 0x1f), compressed[0]); // ID1
    try testing.expectEqual(@as(u8, 0x8b), compressed[1]); // ID2
    try testing.expectEqual(@as(u8, 0x08), compressed[2]); // CM = deflate
}

test "gzip round-trips an empty payload" {
    const compressed = try gzipToOwned("");
    defer testing.allocator.free(compressed);

    var reader = std.Io.Reader.fixed(compressed);
    var mem = try materializeGzip(testing.allocator, &reader, 1 << 20);
    defer mem.deinit();
    try testing.expectEqual(@as(u64, 0), try mem.device().getSize());
}

test "compressDeviceToGzip + inflateGzipToDevice round-trip a Device end to end" {
    var src = MemoryDevice.init(testing.allocator);
    defer src.deinit();
    const payload = "SIMPLE  =                    T" ** 24 ++ ("\x00" ** 1024);
    try src.device().writeAll(payload, 0);

    var aw: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer aw.deinit();
    try compressDeviceToGzip(testing.allocator, src.device(), &aw.writer, 1 << 20);
    try testing.expect(aw.written().len < payload.len); // the repetitive payload actually shrank

    var dev = try inflateGzipToDevice(testing.allocator, aw.written(), 1 << 20);
    defer dev.deinit();
    try testing.expectEqualSlices(u8, src.bytes(), dev.bytes());
}

test "inflateGzipToDevice maps a corrupt container to a typed ReadFailed" {
    try testing.expectError(
        error.ReadFailed,
        inflateGzipToDevice(testing.allocator, "plainly not a gzip stream, padded past ten bytes", 1 << 20),
    );
}

test "inflateGzipToDevice enforces the decompressed-size ceiling" {
    const plain = [_]u8{0} ** 8192;
    const compressed = try gzipToOwned(&plain);
    defer testing.allocator.free(compressed);
    try testing.expectError(
        error.LimitExceeded,
        inflateGzipToDevice(testing.allocator, compressed, 1024),
    );
}
