//! `fitsverify` — a small CLI demo over `validate.zig` that prints a classified structural
//! report (X-TOOL, FR-VAL-2). It builds a representative FITS file in memory, runs the
//! verification pass, and prints the findings (or "OK"). The in-memory sample keeps the demo
//! self-contained; pointing it at a real file is a thin change once a path/stdin source is
//! wired (the library already supports `fits.openFile` and the stdin→memory materialize path).
const std = @import("std");
const fits = @import("zigfitsio");

pub fn main() !void {
    const a = std.heap.page_allocator;

    // Build a sample file: a primary (NAXIS=0) + a 2-D f32 image extension.
    var mem = fits.MemoryDevice.init(a);
    defer mem.deinit();
    {
        var f = try fits.create(a, mem.device(), .{});
        defer f.deinit();
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
        var img = try fits.ImageView.append(&f, .{ .bitpix = -32, .axes = &.{ 16, 16 } });
        var px: [256]f32 = undefined;
        for (&px, 0..) |*p, i| p.* = @floatFromInt(i);
        try img.writeAll(f32, &px, .{});
        try f.flush();
    }

    // Verify it and print a fitsverify-style report.
    var f = try fits.open(a, mem.device(), .read_only, .{});
    defer f.deinit();
    var findings = try fits.validate.verify(a, &f);
    defer fits.validate.deinitFindings(a, &findings);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const count = f.hduCount() catch 0;
    try w.print("fitsverify (zigfitsio {s}) — {d} HDU(s)\n", .{ fits.version, count });
    var errs: usize = 0;
    if (findings.items.len == 0) {
        try w.writeAll("  OK — no structural problems found\n");
    } else {
        for (findings.items) |fd| {
            const sev = switch (fd.severity) {
                .err => "ERROR",
                .warning => "WARN ",
            };
            if (fd.severity == .err) errs += 1;
            if (fd.kw) |kw| {
                try w.print("  [{s}] HDU {d} {s}: {s}\n", .{ sev, fd.hdu, kw, fd.msg });
            } else {
                try w.print("  [{s}] HDU {d}: {s}\n", .{ sev, fd.hdu, fd.msg });
            }
        }
        try w.print("  {d} error(s), {d} finding(s) total\n", .{ errs, findings.items.len });
    }
    std.debug.print("{s}", .{w.buffered()});
}
