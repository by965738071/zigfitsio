//! Block model and buffering (FR-IO-1/2/4, NFR-PERF-1/3, §8.2).
//!
//! FITS is a sequence of 2880-byte logical blocks. `BlockReader` caches a block-aligned
//! window over a `Device` so header scanning never issues a syscall per card (FR-IO-4) and
//! bulk reads stay block-aligned (NFR-PERF-1) in bounded memory (NFR-PERF-3). `BlockWriter`
//! accumulates whole blocks and pads the final partial block with the unit-appropriate fill
//! (FR-IO-2): ASCII space for header units and ASCII-table data, zero for other data.
const std = @import("std");
const IoError = @import("../errors.zig").IoError;
const Device = @import("device.zig").Device;

/// A FITS logical block.
pub const BLOCK: usize = 2880;
/// A header card.
pub const CARD: usize = 80;
/// Cards per block (2880 / 80).
pub const CARDS_PER_BLOCK: usize = BLOCK / CARD;
/// Default read/write window in blocks (~64 KiB rounded to a block multiple).
pub const DEFAULT_WINDOW_BLOCKS: usize = 23;

/// Padding fill kind (FR-IO-2): header units and ASCII-table data pad with space; all other
/// data units pad with zero.
pub const Fill = enum { space, zero };

fn fillByte(f: Fill) u8 {
    return switch (f) {
        .space => ' ',
        .zero => 0,
    };
}

/// Round `n` up to the next multiple of `BLOCK`, saturating at the largest block multiple
/// that fits `u64` instead of overflowing. A data unit declared within `BLOCK-1` of the
/// `u64` ceiling is only reachable from a malformed `GCOUNT`/`PCOUNT`/`NAXISn` (`dataByteCount`),
/// so it yields a huge-but-finite offset that a later read rejects cleanly (EndOfStream /
/// "data extends past EOF") rather than panicking during the eager HDU scan (NFR-SAFE-1/2).
pub fn roundUpBlocks(n: u64) u64 {
    // 64-bit throughout: `BLOCK` is `usize` (32-bit on wasm32), so widen it explicitly rather
    // than let the expression narrow to `usize` and overflow the `u64` ceiling constants.
    const b: u64 = BLOCK;
    if (n > std.math.maxInt(u64) - (b - 1)) return (std.math.maxInt(u64) / b) * b;
    return ((n + b - 1) / b) * b;
}

/// A block-aligned read cache over a `Device`.
pub const BlockReader = struct {
    dev: Device,
    alloc: std.mem.Allocator,
    window: []u8,
    window_off: u64 = 0,
    valid: usize = 0,
    loaded: bool = false,

    /// Create a reader with a window of `window_blocks` blocks (0 ⇒ default).
    pub fn init(allocator: std.mem.Allocator, dev: Device, window_blocks: usize) std.mem.Allocator.Error!BlockReader {
        const wb = if (window_blocks == 0) DEFAULT_WINDOW_BLOCKS else window_blocks;
        const window = try allocator.alloc(u8, wb * BLOCK);
        return .{ .dev = dev, .alloc = allocator, .window = window };
    }

    /// Release the block-aligned read window allocated by `init`.
    pub fn deinit(self: *BlockReader) void {
        self.alloc.free(self.window);
    }

    // Ensure [off, off+len) lies within the loaded window, reloading block-aligned if not.
    fn ensure(self: *BlockReader, off: u64, len: usize) IoError!void {
        if (self.loaded and off >= self.window_off and off + len <= self.window_off + self.valid) return;
        if (len > self.window.len) return error.BlockMisaligned; // request larger than the window
        const aligned = (off / BLOCK) * BLOCK;
        var got: usize = 0;
        while (got < self.window.len) {
            const want = self.window.len - got;
            const n = try self.dev.pread(self.window[got..], aligned + got);
            if (n == 0) break;
            got += n;
            if (n < want) break; // short read ⇒ end of a seekable device; avoids an extra EOF probe
        }
        self.window_off = aligned;
        self.valid = got;
        self.loaded = true;
        if (off + len > self.window_off + self.valid) return error.EndOfStream;
    }

    /// Borrow the 80-byte card at 0-based card index `idx`. Cards never straddle a block (36
    /// per block), so a block-aligned window always contains the whole card.
    pub fn cardAt(self: *BlockReader, idx: u64) IoError!*const [CARD]u8 {
        const off = idx * @as(u64, CARD);
        try self.ensure(off, CARD);
        const rel: usize = @intCast(off - self.window_off);
        return self.window[rel..][0..CARD];
    }

    /// Copy `into.len` bytes starting at device offset `off`. Small ranges use the window;
    /// large bulk ranges read directly from the device to avoid polluting the cache.
    pub fn bytes(self: *BlockReader, off: u64, into: []u8) IoError!void {
        if (into.len > self.window.len) {
            try self.dev.readAll(into, off);
            return;
        }
        try self.ensure(off, into.len);
        const rel: usize = @intCast(off - self.window_off);
        @memcpy(into, self.window[rel..][0..into.len]);
    }
};

/// A block-aligned write accumulator over a `Device`.
pub const BlockWriter = struct {
    dev: Device,
    alloc: std.mem.Allocator,
    buf: []u8,
    len: usize = 0,
    base: u64,

    /// Create a writer staging into `window_blocks` blocks (0 ⇒ default), starting at
    /// device offset `start_off`.
    pub fn init(allocator: std.mem.Allocator, dev: Device, start_off: u64, window_blocks: usize) std.mem.Allocator.Error!BlockWriter {
        const wb = if (window_blocks == 0) DEFAULT_WINDOW_BLOCKS else window_blocks;
        const buf = try allocator.alloc(u8, wb * BLOCK);
        return .{ .dev = dev, .alloc = allocator, .buf = buf, .base = start_off };
    }

    /// Release the staging buffer allocated by `init`.
    pub fn deinit(self: *BlockWriter) void {
        self.alloc.free(self.buf);
    }

    /// Append `data`, flushing complete blocks as the staging buffer fills.
    pub fn write(self: *BlockWriter, data: []const u8) IoError!void {
        var rem = data;
        while (rem.len > 0) {
            const space = self.buf.len - self.len;
            const n = @min(space, rem.len);
            @memcpy(self.buf[self.len..][0..n], rem[0..n]);
            self.len += n;
            rem = rem[n..];
            if (self.len == self.buf.len) try self.flushComplete();
        }
    }

    // Flush all complete blocks, retaining any partial-block tail at the front.
    fn flushComplete(self: *BlockWriter) IoError!void {
        const complete = (self.len / BLOCK) * BLOCK;
        if (complete == 0) return;
        try self.dev.writeAll(self.buf[0..complete], self.base);
        self.base += complete;
        const tail = self.len - complete;
        if (tail != 0) std.mem.copyForwards(u8, self.buf[0..tail], self.buf[complete..self.len]);
        self.len = tail;
    }

    /// Pad the current unit to a block boundary with `fill` and flush everything staged.
    /// After this the writer is block-aligned for the next unit.
    pub fn pad(self: *BlockWriter, fill: Fill) IoError!void {
        const rem = self.len % BLOCK;
        if (rem != 0) {
            const padding = BLOCK - rem;
            @memset(self.buf[self.len..][0..padding], fillByte(fill));
            self.len += padding;
        }
        if (self.len != 0) {
            try self.dev.writeAll(self.buf[0..self.len], self.base);
            self.base += self.len;
            self.len = 0;
        }
    }

    /// Device offset where the next written byte will land.
    pub fn tell(self: *const BlockWriter) u64 {
        return self.base + self.len;
    }
};

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("memory.zig").MemoryDevice;

// A Device wrapper that counts pread calls, to prove windowed scanning batches I/O.
const CountingDevice = struct {
    inner: Device,
    reads: usize = 0,
    fn pread(ctx: *anyopaque, buf: []u8, offset: u64) IoError!usize {
        const self: *CountingDevice = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        return self.inner.pread(buf, offset);
    }
    fn getSize(ctx: *anyopaque) IoError!u64 {
        const self: *CountingDevice = @ptrCast(@alignCast(ctx));
        return self.inner.getSize();
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
    fn device(self: *CountingDevice) Device {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "multi-block header scan issues one windowed read" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    // Three blocks of cards: card i holds its index in the first bytes.
    const total = 3 * BLOCK;
    const blob = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(blob);
    @memset(blob, ' ');
    var i: usize = 0;
    while (i < total / CARD) : (i += 1) {
        _ = std.fmt.bufPrint(blob[i * CARD ..][0..CARD], "CARD{d:0>4}", .{i}) catch {};
    }
    try mem.device().writeAll(blob, 0);

    var counter: CountingDevice = .{ .inner = mem.device() };
    var br = try BlockReader.init(testing.allocator, counter.device(), 0); // default 23-block window
    defer br.deinit();

    // Read cards spanning all three blocks (indices 0..107).
    var idx: u64 = 0;
    while (idx < 3 * CARDS_PER_BLOCK) : (idx += 1) {
        const card = try br.cardAt(idx);
        try testing.expect(std.mem.startsWith(u8, card, "CARD"));
    }
    try testing.expectEqual(@as(usize, 1), counter.reads); // all 108 cards, one device read
}

test "roundUpBlocks saturates instead of overflowing on a near-u64-max length" {
    try testing.expectEqual(@as(u64, 0), roundUpBlocks(0));
    try testing.expectEqual(BLOCK, roundUpBlocks(1));
    try testing.expectEqual(BLOCK, roundUpBlocks(BLOCK));
    try testing.expectEqual(@as(u64, 2) * BLOCK, roundUpBlocks(BLOCK + 1));
    // Lengths within BLOCK-1 of the ceiling must saturate, not integer-overflow panic
    // (regression: a crafted GCOUNT made data_bytes ≈ 2^64, crashing the HDU scan).
    const sat = (std.math.maxInt(u64) / BLOCK) * BLOCK;
    try testing.expectEqual(sat, roundUpBlocks(std.math.maxInt(u64)));
    try testing.expectEqual(sat, roundUpBlocks(std.math.maxInt(u64) - 1));
    try testing.expectEqual(sat, roundUpBlocks(std.math.maxInt(u64) - (BLOCK - 1) + 1));
}

test "block writer pads with the correct fill and flushes block-aligned" {
    inline for (.{ Fill.space, Fill.zero }) |fill| {
        var mem = MemoryDevice.init(testing.allocator);
        defer mem.deinit();
        var bw = try BlockWriter.init(testing.allocator, mem.device(), 0, 0);
        defer bw.deinit();
        try bw.write("ABC");
        try testing.expectEqual(@as(u64, 3), bw.tell());
        try bw.pad(fill);
        try testing.expectEqual(@as(u64, BLOCK), bw.tell());
        try testing.expectEqual(@as(u64, BLOCK), try mem.device().getSize());
        const expect: u8 = if (fill == .space) ' ' else 0;
        try testing.expectEqual(@as(u8, 'A'), mem.bytes()[0]);
        try testing.expectEqual(expect, mem.bytes()[3]);
        try testing.expectEqual(expect, mem.bytes()[BLOCK - 1]);
    }
}

test "writer streams multiple blocks then a partial padded tail" {
    var mem = MemoryDevice.init(testing.allocator);
    defer mem.deinit();
    var bw = try BlockWriter.init(testing.allocator, mem.device(), 0, 2); // small window forces flushes
    defer bw.deinit();
    const payload = try testing.allocator.alloc(u8, BLOCK * 5 + 100);
    defer testing.allocator.free(payload);
    for (payload, 0..) |*b, k| b.* = @truncate(k);
    try bw.write(payload);
    try bw.pad(.zero);
    try testing.expectEqual(roundUpBlocks(payload.len), try mem.device().getSize());
    var check: [BLOCK * 5 + 100]u8 = undefined;
    try mem.device().readAll(&check, 0);
    try testing.expectEqualSlices(u8, payload, &check);
}
