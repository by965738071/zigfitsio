//! In-memory `Device` backend (FR-IO-3, FR-RMT-1, NFR-PORT-3, §8.1).
//!
//! A growable byte buffer behind the `Device` vtable. This is the freestanding/WASM I/O
//! path (no OS file access) and the in-memory buffer of FR-RMT-1. Reads/writes are a plain
//! `@memcpy`; writing past the end grows the buffer, zero-filling any gap (the FITS data
//! fill) so reads of unwritten regions are well-defined.
const std = @import("std");
const IoError = @import("../errors.zig").IoError;
const Device = @import("device.zig").Device;

/// A `Device` backed by an owned, growable `[]u8`. Pin it (stable address) before taking a
/// `Device`, since the `Device` stores a pointer to it.
pub const MemoryDevice = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8),

    /// An empty, growable in-memory device.
    pub fn init(allocator: std.mem.Allocator) MemoryDevice {
        return .{ .alloc = allocator, .buf = .empty };
    }

    /// An in-memory device pre-loaded with a copy of `initial` (e.g. an in-RAM FITS file).
    pub fn initBytes(allocator: std.mem.Allocator, initial: []const u8) std.mem.Allocator.Error!MemoryDevice {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        try list.appendSlice(allocator, initial);
        return .{ .alloc = allocator, .buf = list };
    }

    /// Free the backing buffer.
    pub fn deinit(self: *MemoryDevice) void {
        self.buf.deinit(self.alloc);
    }

    /// Borrow the current contents (valid until the next mutating call).
    pub fn bytes(self: *const MemoryDevice) []const u8 {
        return self.buf.items;
    }

    fn pread(ctx: *anyopaque, dst: []u8, offset: u64) IoError!usize {
        const self: *MemoryDevice = @ptrCast(@alignCast(ctx));
        const off = std.math.cast(usize, offset) orelse return 0;
        if (off >= self.buf.items.len) return 0;
        const avail = self.buf.items.len - off;
        const n = @min(dst.len, avail);
        @memcpy(dst[0..n], self.buf.items[off..][0..n]);
        return n;
    }

    fn pwrite(ctx: *anyopaque, src: []const u8, offset: u64) IoError!usize {
        const self: *MemoryDevice = @ptrCast(@alignCast(ctx));
        const off = std.math.cast(usize, offset) orelse return error.DeviceFull;
        const end = std.math.add(usize, off, src.len) catch return error.DeviceFull;
        if (end > self.buf.items.len) {
            const old_len = self.buf.items.len;
            self.buf.resize(self.alloc, end) catch return error.DeviceFull;
            if (off > old_len) @memset(self.buf.items[old_len..off], 0); // zero-fill the gap
        }
        @memcpy(self.buf.items[off..][0..src.len], src);
        return src.len;
    }

    fn getSize(ctx: *anyopaque) IoError!u64 {
        const self: *MemoryDevice = @ptrCast(@alignCast(ctx));
        return self.buf.items.len;
    }

    fn setSize(ctx: *anyopaque, size: u64) IoError!void {
        const self: *MemoryDevice = @ptrCast(@alignCast(ctx));
        const new_len = std.math.cast(usize, size) orelse return error.DeviceFull;
        const old_len = self.buf.items.len;
        self.buf.resize(self.alloc, new_len) catch return error.DeviceFull;
        if (new_len > old_len) @memset(self.buf.items[old_len..new_len], 0);
    }

    fn syncFn(_: *anyopaque) IoError!void {}
    fn closeFn(_: *anyopaque) void {}

    const vtable: Device.VTable = .{
        .pread = pread,
        .pwrite = pwrite,
        .getSize = getSize,
        .setSize = setSize,
        .sync = syncFn,
        .close = closeFn,
    };

    /// A `Device` view of this buffer. The buffer must outlive the `Device` and stay pinned.
    pub fn device(self: *MemoryDevice) Device {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

const testing = std.testing;

test "memory device read/write round-trip and growth" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    const dev = mem.device();
    try testing.expect(dev.isWritable());

    try dev.writeAll("HELLO", 0);
    try testing.expectEqual(@as(u64, 5), try dev.getSize());
    var buf: [5]u8 = undefined;
    try dev.readAll(&buf, 0);
    try testing.expectEqualStrings("HELLO", &buf);
}

test "writing past the end zero-fills the gap" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    const dev = mem.device();
    try dev.writeAll("AB", 0);
    try dev.writeAll("YZ", 6); // gap at [2,6)
    try testing.expectEqual(@as(u64, 8), try dev.getSize());
    var buf: [8]u8 = undefined;
    try dev.readAll(&buf, 0);
    try testing.expectEqualSlices(u8, "AB\x00\x00\x00\x00YZ", &buf);
}

test "initBytes and setSize" {
    var mem = try MemoryDevice.initBytes(testing.allocator, "0123456789");
    defer mem.deinit();
    const dev = mem.device();
    try testing.expectEqual(@as(u64, 10), try dev.getSize());
    var b: [4]u8 = undefined;
    try dev.readAll(&b, 3);
    try testing.expectEqualStrings("3456", &b);
    try dev.setSize(4);
    try testing.expectEqual(@as(u64, 4), try dev.getSize());
    try dev.setSize(6); // grow zero-filled
    var z: [2]u8 = undefined;
    try dev.readAll(&z, 4);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, &z);
}

test "reads past end return short / zero" {
    var mem = try MemoryDevice.initBytes(testing.allocator, "abc");
    defer mem.deinit();
    const dev = mem.device();
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try dev.pread(&buf, 0));
    try testing.expectEqual(@as(usize, 0), try dev.pread(&buf, 3));
}
