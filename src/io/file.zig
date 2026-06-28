//! On-disk `Device` backend over `std.Io.File` (FR-IO-3/5/6, §8.1).
//!
//! Wraps a `std.Io.File` with positioned 64-bit reads/writes. Zig 0.16 threads a `std.Io`
//! instance through file operations; that instance is owned here (a single-threaded
//! `std.Io.Threaded`) so the rest of the library only ever sees the `Device` vtable and
//! never the OS. This is an OS-backed leaf module: it is excluded from the
//! `wasm32-freestanding` build graph (the in-memory backend is the freestanding path).
const std = @import("std");
const IoError = @import("../errors.zig").IoError;
const Device = @import("device.zig").Device;

/// How to open a path.
pub const Access = enum {
    /// Open an existing file read-only (write operations return `error.NotWritable`).
    read_only,
    /// Open an existing file read/write.
    read_write,
    /// Create (or truncate) a file read/write.
    create,
};

/// Errors that can occur opening a `FileDevice`.
pub const OpenError = IoError || std.mem.Allocator.Error;

/// A heap-allocated, pinned `Device` backed by an on-disk file. Created by `open`/`openPath`;
/// released by `Device.close` (which frees this struct), so the owner just holds the
/// `Device`.
pub const FileDevice = struct {
    alloc: std.mem.Allocator,
    threaded: std.Io.Threaded,
    file: std.Io.File,

    fn io(self: *FileDevice) std.Io {
        return self.threaded.io();
    }

    /// Open `path` relative to `dir` with the given access mode.
    pub fn open(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, access: Access) OpenError!Device {
        const self = try allocator.create(FileDevice);
        errdefer allocator.destroy(self);
        self.* = .{ .alloc = allocator, .threaded = .init_single_threaded, .file = undefined };
        self.file = switch (access) {
            .read_only => dir.openFile(self.io(), path, .{ .mode = .read_only }),
            .read_write => dir.openFile(self.io(), path, .{ .mode = .read_write }),
            .create => dir.createFile(self.io(), path, .{ .read = true, .truncate = true }),
        } catch return error.ReadFailed;
        return .{ .ptr = self, .vtable = if (access == .read_only) &ro_vtable else &rw_vtable };
    }

    /// Open `path` relative to the current working directory.
    pub fn openPath(allocator: std.mem.Allocator, path: []const u8, access: Access) OpenError!Device {
        return open(allocator, std.Io.Dir.cwd(), path, access);
    }

    fn pread(ctx: *anyopaque, buf: []u8, offset: u64) IoError!usize {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        return self.file.readPositionalAll(self.io(), buf, offset) catch error.ReadFailed;
    }

    fn pwrite(ctx: *anyopaque, buf: []const u8, offset: u64) IoError!usize {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        self.file.writePositionalAll(self.io(), buf, offset) catch return error.WriteFailed;
        return buf.len;
    }

    fn getSize(ctx: *anyopaque) IoError!u64 {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        return self.file.length(self.io()) catch error.ReadFailed;
    }

    fn setSize(ctx: *anyopaque, size: u64) IoError!void {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        self.file.setLength(self.io(), size) catch return error.WriteFailed;
    }

    fn syncFn(ctx: *anyopaque) IoError!void {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        self.file.sync(self.io()) catch return error.WriteFailed;
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        self.file.close(self.io());
        self.alloc.destroy(self);
    }

    const ro_vtable: Device.VTable = .{
        .pread = pread,
        .pwrite = null,
        .getSize = getSize,
        .setSize = null,
        .sync = syncFn,
        .close = closeFn,
    };
    const rw_vtable: Device.VTable = .{
        .pread = pread,
        .pwrite = pwrite,
        .getSize = getSize,
        .setSize = setSize,
        .sync = syncFn,
        .close = closeFn,
    };
};

const testing = std.testing;

test "file device create→write→reopen→read round-trip; read-only rejects writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const dev = try FileDevice.open(testing.allocator, tmp.dir, "rt.fits", .create);
        defer dev.close();
        try testing.expect(dev.isWritable());
        try dev.writeAll("FITS-DATA", 0);
        try dev.sync();
        try testing.expectEqual(@as(u64, 9), try dev.getSize());
    }
    {
        const dev = try FileDevice.open(testing.allocator, tmp.dir, "rt.fits", .read_only);
        defer dev.close();
        try testing.expect(!dev.isWritable());
        try testing.expectError(error.NotWritable, dev.writeAll("x", 0));
        var buf: [9]u8 = undefined;
        try dev.readAll(&buf, 0);
        try testing.expectEqualStrings("FITS-DATA", &buf);
    }
    {
        const dev = try FileDevice.open(testing.allocator, tmp.dir, "rt.fits", .read_write);
        defer dev.close();
        try dev.setSize(2880); // grow to a block boundary
        try testing.expectEqual(@as(u64, 2880), try dev.getSize());
    }
}
