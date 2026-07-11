//! Seekable, position-explicit byte device (FR-IO-3/5/6, §8.1).
//!
//! FITS editing requires random access. The `Device` is a small vtable abstraction with
//! `pread`/`pwrite`-style positioned I/O and 64-bit offsets. Position-explicit access makes
//! random access the natural case, removes hidden seek state, makes the memory backend a
//! trivial `@memcpy`, and is the friendliest shape for concurrent distinct-range reads
//! (NFR-CONC-1). A `null` `pwrite` marks a read-only device; write operations then return
//! `error.NotWritable`.
const std = @import("std");
const IoError = @import("../errors.zig").IoError;

/// A seekable byte source/sink behind a vtable. Backends (memory, file, http) supply the
/// vtable; the rest of the library uses only these methods, so it never sees the OS.
pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Backend operations used by the type-erased random-access device handle.
    pub const VTable = struct {
        /// Read up to `buf.len` bytes at `offset`; returns the count read (0 ⇒ end).
        pread: *const fn (ctx: *anyopaque, buf: []u8, offset: u64) IoError!usize,
        /// Write up to `buf.len` bytes at `offset`; `null` marks the device read-only.
        pwrite: ?*const fn (ctx: *anyopaque, buf: []const u8, offset: u64) IoError!usize,
        /// Current logical size in bytes.
        getSize: *const fn (ctx: *anyopaque) IoError!u64,
        /// Grow/truncate to `size`; `null` if the device cannot be resized.
        setSize: ?*const fn (ctx: *anyopaque, size: u64) IoError!void,
        /// Flush any buffered writes to the underlying medium.
        sync: *const fn (ctx: *anyopaque) IoError!void,
        /// Release backend resources. Idempotent is not required; call once.
        close: *const fn (ctx: *anyopaque) void,
    };

    /// One positioned read; may return a short count.
    pub fn pread(self: Device, buf: []u8, offset: u64) IoError!usize {
        return self.vtable.pread(self.ptr, buf, offset);
    }

    /// Read exactly `buf.len` bytes at `offset`, looping over short reads; a premature end
    /// is `error.EndOfStream`.
    pub fn readAll(self: Device, buf: []u8, offset: u64) IoError!void {
        var done: usize = 0;
        while (done < buf.len) {
            const n = try self.vtable.pread(self.ptr, buf[done..], offset + done);
            if (n == 0) return error.EndOfStream;
            done += n;
        }
    }

    /// Whether the device accepts writes.
    pub fn isWritable(self: Device) bool {
        return self.vtable.pwrite != null;
    }

    /// One positioned write; may return a short count. `error.NotWritable` on a read-only
    /// device.
    pub fn pwrite(self: Device, buf: []const u8, offset: u64) IoError!usize {
        const pw = self.vtable.pwrite orelse return error.NotWritable;
        return pw(self.ptr, buf, offset);
    }

    /// Write exactly `buf.len` bytes at `offset`, looping over short writes.
    pub fn writeAll(self: Device, buf: []const u8, offset: u64) IoError!void {
        const pw = self.vtable.pwrite orelse return error.NotWritable;
        var done: usize = 0;
        while (done < buf.len) {
            const n = try pw(self.ptr, buf[done..], offset + done);
            if (n == 0) return error.WriteFailed;
            done += n;
        }
    }

    /// Current logical size in bytes.
    pub fn getSize(self: Device) IoError!u64 {
        return self.vtable.getSize(self.ptr);
    }

    /// Grow/truncate the device. `error.NotWritable` if unsupported.
    pub fn setSize(self: Device, size: u64) IoError!void {
        const ss = self.vtable.setSize orelse return error.NotWritable;
        return ss(self.ptr, size);
    }

    /// Flush buffered writes.
    pub fn sync(self: Device) IoError!void {
        return self.vtable.sync(self.ptr);
    }

    /// Release backend resources.
    pub fn close(self: Device) void {
        self.vtable.close(self.ptr);
    }
};

const testing = std.testing;

// A read-only mock backed by a deterministic pattern, used to exercise short reads,
// EndOfStream, NotWritable, and 64-bit (>2 GiB) offsets without allocating large buffers.
const PatternDevice = struct {
    size: u64,
    fn pread(ctx: *anyopaque, buf: []u8, offset: u64) IoError!usize {
        const self: *PatternDevice = @ptrCast(@alignCast(ctx));
        if (offset >= self.size) return 0;
        const avail = self.size - offset;
        const n: usize = @intCast(@min(@as(u64, buf.len), avail));
        for (buf[0..n], 0..) |*b, i| b.* = @truncate(offset + i);
        return n;
    }
    fn getSize(ctx: *anyopaque) IoError!u64 {
        const self: *PatternDevice = @ptrCast(@alignCast(ctx));
        return self.size;
    }
    fn sync(_: *anyopaque) IoError!void {}
    fn close(_: *anyopaque) void {}
    const vtable: Device.VTable = .{
        .pread = pread,
        .pwrite = null,
        .getSize = getSize,
        .setSize = null,
        .sync = sync,
        .close = close,
    };
    fn device(self: *PatternDevice) Device {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "read-only device rejects writes with NotWritable" {
    var p: PatternDevice = .{ .size = 16 };
    const dev = p.device();
    try testing.expect(!dev.isWritable());
    try testing.expectError(error.NotWritable, dev.writeAll("x", 0));
    try testing.expectError(error.NotWritable, dev.setSize(0));
}

test "readAll loops and reports EndOfStream past size" {
    var p: PatternDevice = .{ .size = 4 };
    const dev = p.device();
    var buf: [4]u8 = undefined;
    try dev.readAll(&buf, 0);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3 }, &buf);
    var over: [8]u8 = undefined;
    try testing.expectError(error.EndOfStream, dev.readAll(&over, 0));
}

test "64-bit offsets beyond 2 GiB are not truncated" {
    const huge: u64 = (3 << 30) + 5; // 3 GiB + 5
    var p: PatternDevice = .{ .size = huge + 16 };
    const dev = p.device();
    try testing.expectEqual(huge + 16, try dev.getSize());
    var buf: [4]u8 = undefined;
    try dev.readAll(&buf, huge);
    // bytes equal low 8 bits of the absolute offset, proving no 32-bit truncation.
    try testing.expectEqual(@as(u8, @truncate(huge)), buf[0]);
    try testing.expectEqual(@as(u8, @truncate(huge + 3)), buf[3]);
}
