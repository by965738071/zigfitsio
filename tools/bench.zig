//! Throughput benchmarks for `zigfitsio` (X-BENCH, NFR-PERF-1/2/3).
//!
//! Measures bulk image read/write throughput over an in-memory `Device` (no syscalls, so the
//! numbers reflect the library's transfer + endian-conversion paths rather than disk). The hot
//! paths use a single bulk buffer per call — no per-element allocation (NFR-PERF-1/3). This is a
//! reporting tool, not a release gate: it prints MB/s for f32/f64/i16/i32 images and round-trip-
//! checks every transfer so a regression that corrupts data also fails the run.
const std = @import("std");
const fits = @import("zigfitsio");

fn mbPerSec(bytes: u64, ns: u64) f64 {
    if (ns == 0) return 0;
    const secs = @as(f64, @floatFromInt(ns)) / 1e9;
    return (@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)) / secs;
}

// Monotonic elapsed nanoseconds via the std.Io `.awake` clock (Zig 0.16 retired std.time.Timer).
fn elapsedNs(io: std.Io, start: std.Io.Timestamp) u64 {
    const end = std.Io.Timestamp.now(io, .awake);
    return @intCast(end.nanoseconds - start.nanoseconds);
}

fn benchImage(comptime T: type, io: std.Io, a: std.mem.Allocator, bitpix: i64, w: u64, h: u64, reps: usize) !void {
    const n = w * h;
    const src = try a.alloc(T, n);
    defer a.free(src);
    const dst = try a.alloc(T, n);
    defer a.free(dst);
    for (src, 0..) |*p, i| {
        const v = i % 1000;
        p.* = if (@typeInfo(T) == .float) @floatFromInt(v) else @intCast(v);
    }

    var mem = fits.MemoryDevice.init(a);
    defer mem.deinit();
    var f = try fits.create(a, mem.device(), .{});
    defer f.deinit();
    var img = try fits.ImageView.append(&f, .{ .bitpix = bitpix, .axes = &.{ w, h } });

    const bytes_per_rep = n * @sizeOf(T);

    var t0 = std.Io.Timestamp.now(io, .awake);
    var r: usize = 0;
    while (r < reps) : (r += 1) try img.writeAll(T, src, .{});
    const write_ns = elapsedNs(io, t0);

    t0 = std.Io.Timestamp.now(io, .awake);
    r = 0;
    while (r < reps) : (r += 1) try img.readAll(T, dst, .{});
    const read_ns = elapsedNs(io, t0);

    if (!std.mem.eql(T, src, dst)) return error.RoundTripMismatch;

    const abspix: u64 = @intCast(if (bitpix < 0) -bitpix else bitpix); // unsigned: `{d}` would prefix a signed value with '+'
    std.debug.print(
        "  {s:<4} {d:>4}-bit {d}x{d}   write {d:>8.1} MB/s    read {d:>8.1} MB/s\n",
        .{
            @typeName(T),     abspix,
            w,                h,
            mbPerSec(bytes_per_rep * reps, write_ns),
            mbPerSec(bytes_per_rep * reps, read_ns),
        },
    );
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    std.debug.print("zigfitsio {s} — bulk image throughput (in-memory device, no syscalls)\n", .{fits.version});
    // f32/f64 hit the float path (no endian-swap allocation); i16/i32 exercise the big-endian
    // swap on the hot path. 1024x1024 keeps each tile a few MiB so timing is stable.
    try benchImage(f32, io, a, -32, 1024, 1024, 40);
    try benchImage(f64, io, a, -64, 1024, 1024, 20);
    try benchImage(i16, io, a, 16, 1024, 1024, 40);
    try benchImage(i32, io, a, 32, 1024, 1024, 40);
    std.debug.print("ok — all round-trips verified\n", .{});
}
