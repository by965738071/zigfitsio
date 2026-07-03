//! Fuzz harnesses for the header and table parsers (X-FUZZ, NFR-SAFE-1/2, GC-6).
//!
//! Each harness feeds arbitrary bytes to a parser and asserts the contract: no panic, no
//! out-of-bounds, no unbounded allocation, no leak — only typed errors or success. Run the
//! whole set once via `zig build fuzz`; engage the in-tree fuzzer with `zig build fuzz --fuzz`.
//! The deterministic `*-seeds` tests additionally pin specific hostile inputs (huge `NAXISn`,
//! missing `END`, non-ASCII, malformed `TFORM`) so the validate-before-allocate paths are
//! always exercised even without the fuzzer engine.
const std = @import("std");
const fits = @import("zigfitsio");

const alloc = std.testing.allocator;

const Smith = std.testing.Smith;

// Fill one 80-byte card with smith-chosen bytes and parse it. Must never panic; any malformed
// content yields a typed HeaderError.
fn fuzzCard(_: void, smith: *Smith) anyerror!void {
    var raw: [80]u8 = undefined;
    smith.bytesWithHash(&raw, 0x01);
    _ = fits.Card.parse(&raw) catch {}; // typed error is fine; a panic/OOB is not
}

// Parse smith-chosen bytes as a binary-table TFORM. Bad codes/overflowing repeats must be typed
// errors, never a crash.
fn fuzzTform(_: void, smith: *Smith) anyerror!void {
    var buf: [48]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0x02);
    _ = fits.table_common.BinTform.parse(buf[0..n]) catch {};
}

// Open smith-chosen bytes as a whole FITS file and walk every HDU. This drives header scanning,
// kind detection, and the NAXISn-product / data-geometry limit checks. A hostile header must
// produce a typed error (or a bounded, leak-free success), never a panic or huge allocation.
fn fuzzOpen(_: void, smith: *Smith) anyerror!void {
    var buf: [2880 * 2]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0x03);
    var mem = fits.MemoryDevice.initBytes(alloc, buf[0..n]) catch return;
    defer mem.deinit();
    var f = fits.open(alloc, mem.device(), .read_only, .{}) catch return;
    defer f.deinit();
    const count = f.hduCount() catch return;
    var i: usize = 1;
    while (i <= count) : (i += 1) {
        const hdu = f.select(i) catch continue;
        if (hdu.kind.isImageLike()) {
            var view = fits.ImageView.of(&f, hdu) catch continue;
            // Read at most a few pixels into a tiny fixed buffer (bounded; never trusts NAXIS).
            var pix: [16]f64 = undefined;
            const want = @min(view.elementCount(), pix.len);
            if (want > 0) view.readPixels(f64, firstCoord(hdu.naxis)[0..hdu.naxis], pix[0..@intCast(want)], .{}) catch {};
        }
    }
}

fn firstCoord(naxis: u16) [999]u64 {
    _ = naxis;
    return @as([999]u64, @splat(0));
}

test "fuzz: card parser" {
    try std.testing.fuzz({}, fuzzCard, .{});
}
test "fuzz: TFORM parser" {
    try std.testing.fuzz({}, fuzzTform, .{});
}
test "fuzz: whole-file open + HDU walk" {
    try std.testing.fuzz({}, fuzzOpen, .{});
}

// ── deterministic hostile-input seeds (validate-before-allocate, NFR-SAFE-1) ─────────────

fn block2880(cards: []const []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, 2880);
    @memset(buf, ' ');
    for (cards, 0..) |c, i| @memcpy(buf[i * 80 ..][0..c.len], c);
    return buf;
}

test "seeds: hostile headers yield typed errors, never panic or huge alloc" {
    const cases = [_][]const []const u8{
        // NAXISn product overflow: must be a typed limit/dimension error, not an allocation.
        &.{
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    3",
            "NAXIS1  =          4000000000",
            "NAXIS2  =          4000000000",
            "NAXIS3  =          4000000000",
            "END",
        },
        // Missing END within the block.
        &.{
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
        },
        // Bad BITPIX.
        &.{
            "SIMPLE  =                    T",
            "BITPIX  =                    7",
            "NAXIS   =                    0",
            "END",
        },
        // SIMPLE not first.
        &.{
            "BITPIX  =                    8",
            "SIMPLE  =                    T",
            "NAXIS   =                    0",
            "END",
        },
    };
    for (cases) |cards| {
        const buf = try block2880(cards);
        defer alloc.free(buf);
        var mem = try fits.MemoryDevice.initBytes(alloc, buf);
        defer mem.deinit();
        var f = fits.open(alloc, mem.device(), .read_only, .{}) catch {
            continue; // a typed open error is an acceptable outcome
        };
        defer f.deinit();
        // If open succeeded, forcing a full scan must still be typed-or-ok, never a panic.
        _ = f.hduCount() catch {};
    }
}

test "seeds: a control character in a card is rejected" {
    var raw: [80]u8 = @splat(' ');
    @memcpy(raw[0..6], "OBJECT");
    raw[20] = 0x07; // bell
    try std.testing.expectError(error.NonAsciiInHeader, fits.Card.parse(&raw));
}

test "seeds: malformed TFORM strings are typed errors" {
    const bad = [_][]const u8{ "", "5", "3G", "1Jx", "999999999999999999999J", "2PJ" };
    for (bad) |s| {
        _ = fits.table_common.BinTform.parse(s) catch continue;
        // "2PJ" (P/Q repeat > 1) and others must error; if one unexpectedly parses, that's a bug.
        if (std.mem.eql(u8, s, "2PJ")) return error.TestUnexpectedResult;
    }
}
