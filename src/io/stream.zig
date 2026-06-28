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
