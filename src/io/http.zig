//! Read-only `Device` backend over `std.http.Client` HTTP(S) Range GETs (FR-RMT-3, §8.1).
//!
//! Serves a remote FITS file as a seekable, read-only `Device`: each `pread` is an
//! HTTP `Range: bytes=a-b` request whose `206 Partial Content` body is copied into the
//! caller's buffer. Writes are unsupported (`error.NotWritable`). Like `io/file.zig` this is
//! an OS/network-backed leaf: it owns a single-threaded `std.Io.Threaded` and a
//! `std.http.Client`, and it is deliberately excluded from the `wasm32-freestanding` build
//! graph (see `src/wasm_check.zig`). All `std.http`/`std.Uri` failures are mapped to the
//! `IoError` set — neither `anyerror` nor `std.http` error types ever escape.
//!
//! Fallback for servers that ignore `Range`: if a ranged GET answers `200 OK` (whole body),
//! the body is downloaded once into an internal `MemoryDevice` and all further `pread`s are
//! served from that in-memory copy.
const std = @import("std");
const IoError = @import("../errors.zig").IoError;
const Device = @import("device.zig").Device;
const MemoryDevice = @import("memory.zig").MemoryDevice;

/// Errors that can occur opening an `HttpDevice`.
pub const OpenError = IoError || std.mem.Allocator.Error;

/// A heap-allocated, pinned read-only `Device` backed by a remote HTTP(S) URL. Created by
/// `open`; released by `Device.close` (which frees this struct), so the owner just holds the
/// `Device`.
pub const HttpDevice = struct {
    alloc: std.mem.Allocator,
    threaded: std.Io.Threaded,
    client: std.http.Client,
    /// Owned copy of the target URL (re-parsed per request; `std.Uri` borrows this string).
    url: []u8,
    /// Whole-file cache, populated when the server ignores `Range` (200 fallback) or when
    /// the size can only be learned by downloading the body.
    cache: ?MemoryDevice = null,
    /// Upper bound on a whole-body download into `cache`, so a server that ignores `Range` and
    /// streams a huge/endless `200 OK` body cannot grow memory without limit (NFR-SAFE-1).
    /// Defaults to the `Limits.max_open_alloc` default (4 GiB); tune on the struct if needed.
    max_cache_bytes: u64 = 1 << 32,
    /// Scratch for `receiveHead` redirect following.
    redirect_buf: [16 * 1024]u8 = undefined,
    /// Scratch for the body reader.
    transfer_buf: [64 * 1024]u8 = undefined,

    /// Open `url` (http or https) as a read-only device. No request is issued here; the first
    /// connection is made lazily on the first `pread`/`getSize`. A malformed URL is
    /// `error.ReadFailed`.
    pub fn open(allocator: std.mem.Allocator, url: []const u8) OpenError!Device {
        _ = std.Uri.parse(url) catch return error.ReadFailed;
        const self = try allocator.create(HttpDevice);
        errdefer allocator.destroy(self);
        const url_copy = try allocator.dupe(u8, url);
        errdefer allocator.free(url_copy);
        self.* = .{
            .alloc = allocator,
            .threaded = .init_single_threaded,
            .client = undefined,
            .url = url_copy,
        };
        self.client = .{ .allocator = allocator, .io = self.threaded.io() };
        return .{ .ptr = self, .vtable = &ro_vtable };
    }

    fn uri(self: *HttpDevice) IoError!std.Uri {
        return std.Uri.parse(self.url) catch error.ReadFailed;
    }

    // ── Device vtable ──────────────────────────────────────────────────────────────────

    fn pread(ctx: *anyopaque, buf: []u8, offset: u64) IoError!usize {
        const self: *HttpDevice = @ptrCast(@alignCast(ctx));
        if (buf.len == 0) return 0;
        if (self.cache) |*c| return cachePread(c, buf, offset);
        // An offset whose byte range would overflow u64 is past any possible EOF; report 0
        // (end-of-stream) like the other backends rather than overflowing in formatRange.
        if (offset > std.math.maxInt(u64) - buf.len) return 0;

        var range_buf: [64]u8 = undefined;
        const range = formatRange(&range_buf, offset, buf.len);
        const u = try self.uri();
        var req = self.client.request(.GET, u, .{
            .keep_alive = true,
            .extra_headers = &.{.{ .name = "range", .value = range }},
        }) catch return error.ReadFailed;
        defer req.deinit();
        req.sendBodiless() catch return error.ReadFailed;
        var resp = req.receiveHead(&self.redirect_buf) catch return error.ReadFailed;
        switch (resp.head.status) {
            // The expected case: the body is exactly the requested byte range.
            .partial_content => {
                const r = resp.reader(&self.transfer_buf);
                return r.readSliceShort(buf) catch error.ReadFailed;
            },
            // The server ignored `Range` and sent the whole file: cache it and serve locally.
            .ok => {
                try self.fillCacheFrom(&resp);
                return cachePread(&self.cache.?, buf, offset);
            },
            // Requested range starts past end-of-file: report end-of-stream as a 0 count.
            .range_not_satisfiable => return 0,
            else => return error.ReadFailed,
        }
    }

    fn getSize(ctx: *anyopaque) IoError!u64 {
        const self: *HttpDevice = @ptrCast(@alignCast(ctx));
        if (self.cache) |*c| return c.bytes().len;
        const u = try self.uri();

        // Primary: a HEAD request and its Content-Length.
        {
            var req = self.client.request(.HEAD, u, .{ .keep_alive = true }) catch return error.ReadFailed;
            defer req.deinit();
            req.sendBodiless() catch return error.ReadFailed;
            const resp = req.receiveHead(&self.redirect_buf) catch return error.ReadFailed;
            if (resp.head.status == .ok) {
                // Reject a size beyond what this backend can cache/serve rather than admitting an
                // attacker-chosen ~2^64 Content-Length that would feed unbounded offset arithmetic.
                if (resp.head.content_length) |len| {
                    if (len > self.max_cache_bytes) return error.DeviceFull;
                    return len;
                }
            }
        }

        // Secondary: a one-byte ranged GET and the total in its Content-Range header.
        {
            var range_buf: [64]u8 = undefined;
            const range = formatRange(&range_buf, 0, 1);
            var req = self.client.request(.GET, u, .{
                .keep_alive = true,
                .extra_headers = &.{.{ .name = "range", .value = range }},
            }) catch return error.ReadFailed;
            defer req.deinit();
            req.sendBodiless() catch return error.ReadFailed;
            var resp = req.receiveHead(&self.redirect_buf) catch return error.ReadFailed;
            if (resp.head.status == .partial_content) {
                if (contentRangeTotal(&resp)) |total| {
                    if (total > self.max_cache_bytes) return error.DeviceFull;
                    return total;
                }
            }
        }

        // Fallback: download the whole body once and report its length.
        try self.fetchFull();
        return self.cache.?.bytes().len;
    }

    fn syncFn(_: *anyopaque) IoError!void {}

    fn closeFn(ctx: *anyopaque) void {
        const self: *HttpDevice = @ptrCast(@alignCast(ctx));
        if (self.cache) |*c| c.deinit();
        self.client.deinit();
        self.threaded.deinit();
        self.alloc.free(self.url);
        self.alloc.destroy(self);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────────────

    /// Issue a plain (un-ranged) GET and buffer the whole body into `self.cache`.
    fn fetchFull(self: *HttpDevice) IoError!void {
        const u = try self.uri();
        var req = self.client.request(.GET, u, .{ .keep_alive = true }) catch return error.ReadFailed;
        defer req.deinit();
        req.sendBodiless() catch return error.ReadFailed;
        var resp = req.receiveHead(&self.redirect_buf) catch return error.ReadFailed;
        switch (resp.head.status) {
            .ok, .partial_content => {},
            else => return error.ReadFailed,
        }
        try self.fillCacheFrom(&resp);
    }

    /// Drain the remaining body of `resp` into a fresh `MemoryDevice` stored in `self.cache`.
    fn fillCacheFrom(self: *HttpDevice, resp: *std.http.Client.Response) IoError!void {
        var mem = MemoryDevice.init(self.alloc);
        errdefer mem.deinit();
        const dev = mem.device();
        const r = resp.reader(&self.transfer_buf);
        var tmp: [16 * 1024]u8 = undefined;
        var pos: u64 = 0;
        while (true) {
            const n = r.readSliceShort(&tmp) catch return error.ReadFailed;
            if (n == 0) break;
            // Bound the download: a server that ignores Range and streams a huge/endless body
            // must not grow the cache without limit (NFR-SAFE-1).
            if (pos + n > self.max_cache_bytes) return error.DeviceFull;
            try dev.writeAll(tmp[0..n], pos);
            pos += n;
        }
        self.cache = mem; // ownership moves into self; errdefer above no longer fires
    }

    /// Serve a `pread` from the in-memory cache.
    fn cachePread(mem: *MemoryDevice, buf: []u8, offset: u64) IoError!usize {
        return mem.device().pread(buf, offset);
    }

    const ro_vtable: Device.VTable = .{
        .pread = pread,
        .pwrite = null,
        .getSize = getSize,
        .setSize = null,
        .sync = syncFn,
        .close = closeFn,
    };
};

// ── Deterministic, network-free logic (unit-tested directly) ───────────────────────────

/// Format an HTTP byte-range header value `"bytes=<offset>-<offset+len-1>"` into `buf`.
/// Asserts `len > 0`; `buf` must hold at least 47 bytes (it always does at the call sites).
fn formatRange(buf: []u8, offset: u64, len: usize) []const u8 {
    std.debug.assert(len > 0);
    // Saturating: a near-u64-max offset+len must not integer-overflow panic. The resulting
    // range lies past any real EOF, so the server answers range_not_satisfiable → pread 0.
    const end = (offset +| @as(u64, len)) -| 1;
    return std.fmt.bufPrint(buf, "bytes={d}-{d}", .{ offset, end }) catch unreachable;
}

/// Parse the total resource size out of an HTTP `Content-Range` value of the form
/// `"bytes <start>-<end>/<total>"`. Returns `null` when the total is unknown (`"*"`) or the
/// value is malformed.
fn parseContentRangeTotal(value: []const u8) ?u64 {
    const slash = std.mem.lastIndexOfScalar(u8, value, '/') orelse return null;
    const total = std.mem.trim(u8, value[slash + 1 ..], " \t");
    if (total.len == 0 or std.mem.eql(u8, total, "*")) return null;
    return std.fmt.parseInt(u64, total, 10) catch null;
}

/// Scan a response's headers for `Content-Range` and return its parsed total size, if any.
/// Must be called before `resp.reader(...)` (which invalidates the header bytes).
fn contentRangeTotal(resp: *std.http.Client.Response) ?u64 {
    var it = std.http.HeaderIterator.init(resp.head.bytes);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-range"))
            return parseContentRangeTotal(h.value);
    }
    return null;
}

const testing = std.testing;

test "formatRange builds a correct bytes= header" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("bytes=0-99", formatRange(&buf, 0, 100));
    try testing.expectEqualStrings("bytes=2880-5759", formatRange(&buf, 2880, 2880));
    // Single-byte range (used by the size probe).
    try testing.expectEqualStrings("bytes=0-0", formatRange(&buf, 0, 1));
    // 64-bit offset is not truncated.
    const huge: u64 = (3 << 30) + 5;
    try testing.expectEqualStrings("bytes=3221225477-3221225484", formatRange(&buf, huge, 8));
    // Regression: a near-u64-max offset+len must saturate, not integer-overflow panic.
    const max = std.math.maxInt(u64);
    _ = formatRange(&buf, max, 1);
    _ = formatRange(&buf, max - 2, 8);
}

test "parseContentRangeTotal extracts the size after the slash" {
    try testing.expectEqual(@as(?u64, 12345), parseContentRangeTotal("bytes 0-99/12345"));
    try testing.expectEqual(@as(?u64, 1), parseContentRangeTotal("bytes 0-0/1"));
    // Unknown total or malformed input yields null (caller then falls back).
    try testing.expectEqual(@as(?u64, null), parseContentRangeTotal("bytes 0-99/*"));
    try testing.expectEqual(@as(?u64, null), parseContentRangeTotal("12345"));
    try testing.expectEqual(@as(?u64, null), parseContentRangeTotal("bytes 0-99/"));
    try testing.expectEqual(@as(?u64, null), parseContentRangeTotal("bytes 0-99/abc"));
}

test "open/close round-trip is leak-free and read-only (no network)" {
    // `open` only parses the URL; no request is issued until the first read, so this
    // exercises the allocate/free + vtable wiring without touching the network.
    const dev = try HttpDevice.open(testing.allocator, "http://example.invalid/data.fits");
    defer dev.close();
    try testing.expect(!dev.isWritable());
    try testing.expectError(error.NotWritable, dev.writeAll("x", 0));
    try testing.expectError(error.NotWritable, dev.setSize(0));
}

test "open rejects a malformed URL" {
    try testing.expectError(error.ReadFailed, HttpDevice.open(testing.allocator, "http://[::bad"));
}

// NOTE: a `std.http.Server` loopback integration test (bind 127.0.0.1:0, serve a fixed body,
// assert a ranged read) is intentionally deferred as blocked-external: the deterministic
// pieces that must be exact — the range-header builder and the Content-Range size
// derivation — are covered by the pure-function tests above, and a live socket server risks
// flakiness/slowness in this suite.
