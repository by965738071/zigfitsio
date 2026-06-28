//! Optional diagnostics context (FR-ERR-3, §4.3).
//!
//! A typed error loses the *where/what*. `Diagnostics` records human-readable detail for the
//! most recent failure as a replacement for CFITSIO's global message stack. It is **opt-in**
//! (a `?*Diagnostics` threaded into operations, or held on the `Fits` handle) and **never
//! required**: the idiom is `errdefer if (diag) |d| d.note(.{...})` at the throwing site, so
//! the cost is zero when no `Diagnostics` is supplied.
const std = @import("std");
const Error = @import("errors.zig").Error;

/// Records the most-recent failure. Uses a plain fixed-capacity array + length for the card
/// text (`std.BoundedArray` was removed in Zig 0.15.1).
pub const Diagnostics = struct {
    last: ?Record = null,

    /// One captured failure: the error plus optional location context.
    pub const Record = struct {
        err: Error,
        /// Byte offset in the stream where the failure occurred.
        byte_offset: ?u64 = null,
        /// The keyword/column name involved (space-padded, ≤ 8 chars).
        keyword: ?[8]u8 = null,
        /// 1-based HDU index involved.
        hdu_index: ?u32 = null,
        /// Inline buffer for the offending card text (or other detail).
        detail_buf: [160]u8 = undefined,
        detail_len: usize = 0,

        /// Borrow the captured detail text.
        pub fn detail(self: *const Record) []const u8 {
            return self.detail_buf[0..self.detail_len];
        }

        /// Build a record, copying `detail_text` (truncated to the inline capacity).
        pub fn init(err: Error, detail_text: []const u8) Record {
            var rec: Record = .{ .err = err };
            const n = @min(detail_text.len, rec.detail_buf.len);
            @memcpy(rec.detail_buf[0..n], detail_text[0..n]);
            rec.detail_len = n;
            return rec;
        }
    };

    /// Record the most-recent failure, overwriting any previous one.
    pub fn note(self: *Diagnostics, rec: Record) void {
        self.last = rec;
    }

    /// Render the last record (if any) as a human-readable line.
    pub fn render(self: *const Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const rec = self.last orelse {
            try w.writeAll("no diagnostics recorded\n");
            return;
        };
        try w.print("error: {s}", .{@import("version.zig").errorText(rec.err)});
        if (rec.hdu_index) |h| try w.print(" [HDU {d}]", .{h});
        if (rec.keyword) |k| try w.print(" keyword='{s}'", .{std.mem.trimEnd(u8, &k, " ")});
        if (rec.byte_offset) |off| try w.print(" @byte {d}", .{off});
        if (rec.detail_len != 0) try w.print(": {s}", .{rec.detail()});
        try w.writeByte('\n');
    }
};

const testing = std.testing;

test "zero cost when no diagnostics: note path skipped" {
    const diag: ?*Diagnostics = null;
    // Mirrors the throwing-site idiom; with a null Diagnostics nothing is recorded.
    if (diag) |d| d.note(Diagnostics.Record.init(error.MissingEnd, "x"));
    try testing.expect(diag == null);
}

test "render a populated record" {
    var diag: Diagnostics = .{};
    var rec = Diagnostics.Record.init(error.BadValueSyntax, "EXPTIME = bad");
    rec.hdu_index = 2;
    rec.byte_offset = 5760;
    rec.keyword = "EXPTIME ".*;
    diag.note(rec);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try diag.render(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "HDU 2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "EXPTIME") != null);
    try testing.expect(std.mem.indexOf(u8, out, "5760") != null);
    try testing.expect(std.mem.indexOf(u8, out, "EXPTIME = bad") != null);
}

test "render with no record" {
    const diag: Diagnostics = .{};
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try diag.render(&w);
    try testing.expectEqualStrings("no diagnostics recorded\n", w.buffered());
}
