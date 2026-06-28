//! FITS date/time helpers and the Julian-Date core (FR-UTL-1, §19.1; FITS 4.0 §4.2.7, §9.1.1).
//!
//! Parses and formats `DATE`/`DATE-OBS` in ISO-8601 (`yyyy-mm-ddThh:mm:ss[.sss]`), accepts the
//! deprecated `DD/MM/YY` form on read (year interpreted as 19YY per §4.4.2.1), and converts
//! to/from Julian and Modified-Julian dates. The global time-coordinate keyword handling
//! (WCS-4) builds on these helpers.
const std = @import("std");
const HeaderError = @import("../errors.zig").HeaderError;

/// Modified Julian Date offset: `MJD = JD - 2_400_000.5`.
pub const MJD_OFFSET: f64 = 2_400_000.5;

/// A calendar date and time of day, with sub-second precision carried as a fraction of a
/// second in `[0, 1)`.
pub const DateTime = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    /// Fractional seconds in `[0, 1)`.
    frac: f64 = 0,

    /// Parse a FITS date string. Accepts:
    ///   - `yyyy-mm-dd`                         (date only)
    ///   - `yyyy-mm-ddThh:mm:ss[.sss]`          (full ISO-8601)
    ///   - `dd/mm/yy`                           (deprecated; year → 19yy, §4.4.2.1)
    /// Malformed input returns `error.BadValueSyntax`.
    pub fn parse(s: []const u8) HeaderError!DateTime {
        const t = std.mem.trim(u8, s, " ");
        if (t.len == 0) return error.BadValueSyntax;
        // Deprecated dd/mm/yy form.
        if (std.mem.indexOfScalar(u8, t, '/') != null) return parseOldStyle(t);
        return parseIso(t);
    }

    fn parseOldStyle(t: []const u8) HeaderError!DateTime {
        var it = std.mem.splitScalar(u8, t, '/');
        const dd = it.next() orelse return error.BadValueSyntax;
        const mm = it.next() orelse return error.BadValueSyntax;
        const yy = it.next() orelse return error.BadValueSyntax;
        if (it.next() != null) return error.BadValueSyntax;
        const day = parseField(u8, dd) catch return error.BadValueSyntax;
        const month = parseField(u8, mm) catch return error.BadValueSyntax;
        const year2 = parseField(u32, yy) catch return error.BadValueSyntax;
        if (year2 > 99) return error.BadValueSyntax;
        var dt: DateTime = .{ .year = @intCast(1900 + year2), .month = month, .day = day };
        try dt.validate();
        return dt;
    }

    fn parseIso(t: []const u8) HeaderError!DateTime {
        // Date part: yyyy-mm-dd
        if (t.len < 10) return error.BadValueSyntax;
        if (t[4] != '-' or t[7] != '-') return error.BadValueSyntax;
        const year = parseField(i32, t[0..4]) catch return error.BadValueSyntax;
        const month = parseField(u8, t[5..7]) catch return error.BadValueSyntax;
        const day = parseField(u8, t[8..10]) catch return error.BadValueSyntax;
        var dt: DateTime = .{ .year = year, .month = month, .day = day };
        if (t.len == 10) {
            try dt.validate();
            return dt;
        }
        // Time part: Thh:mm:ss[.sss]
        if (t[10] != 'T' and t[10] != ' ') return error.BadValueSyntax;
        const time = t[11..];
        if (time.len < 8 or time[2] != ':' or time[5] != ':') return error.BadValueSyntax;
        dt.hour = parseField(u8, time[0..2]) catch return error.BadValueSyntax;
        dt.minute = parseField(u8, time[3..5]) catch return error.BadValueSyntax;
        dt.second = parseField(u8, time[6..8]) catch return error.BadValueSyntax;
        if (time.len > 8) {
            if (time[8] != '.') return error.BadValueSyntax;
            const frac_digits = time[9..];
            if (frac_digits.len == 0) return error.BadValueSyntax;
            for (frac_digits) |c| if (!std.ascii.isDigit(c)) return error.BadValueSyntax;
            const num = std.fmt.parseFloat(f64, frac_digits) catch return error.BadValueSyntax;
            dt.frac = num / std.math.pow(f64, 10, @floatFromInt(frac_digits.len));
        }
        try dt.validate();
        return dt;
    }

    fn parseField(comptime T: type, s: []const u8) !T {
        for (s) |c| if (!std.ascii.isDigit(c) and c != '-') return error.BadValueSyntax;
        return std.fmt.parseInt(T, s, 10);
    }

    fn validate(self: *const DateTime) HeaderError!void {
        if (self.month < 1 or self.month > 12) return error.BadValueSyntax;
        if (self.day < 1 or self.day > 31) return error.BadValueSyntax;
        if (self.hour > 23 or self.minute > 59 or self.second > 60) return error.BadValueSyntax; // 60 ⇒ leap second
        if (self.frac < 0 or self.frac >= 1) return error.BadValueSyntax;
    }

    /// Write the ISO-8601 representation. Fractional seconds are emitted (to millisecond
    /// precision) only when nonzero, matching common FITS usage.
    pub fn format(self: *const DateTime, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // FITS years are non-negative; format unsigned so zero-padding does not emit a sign.
        const year_u: u32 = @intCast(@max(self.year, 0));
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            year_u, self.month, self.day, self.hour, self.minute, self.second,
        });
        if (self.frac > 0) {
            const millis: u64 = @intFromFloat(@round(self.frac * 1000.0));
            if (millis > 0) try w.print(".{d:0>3}", .{millis});
        }
    }

    /// The Julian Date of this instant (Gregorian calendar; Fliegel–Van Flandern).
    pub fn toJulianDate(self: *const DateTime) f64 {
        const a = @divFloor(@as(i64, 14) - self.month, 12);
        const y = @as(i64, self.year) + 4800 - a;
        const m = @as(i64, self.month) + 12 * a - 3;
        const jdn = self.day + @divFloor(153 * m + 2, 5) + 365 * y +
            @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) - 32045;
        const day_frac = (@as(f64, @floatFromInt(self.hour)) - 12.0) / 24.0 +
            @as(f64, @floatFromInt(self.minute)) / 1440.0 +
            (@as(f64, @floatFromInt(self.second)) + self.frac) / 86400.0;
        return @as(f64, @floatFromInt(jdn)) + day_frac;
    }

    /// The Modified Julian Date of this instant.
    pub fn toMjd(self: *const DateTime) f64 {
        return self.toJulianDate() - MJD_OFFSET;
    }

    /// Reconstruct a calendar date/time from a Julian Date (Gregorian; Richards' algorithm).
    pub fn fromJulianDate(jd: f64) DateTime {
        // Split into integer day number (at noon boundary) and fraction of day from midnight.
        const jd_plus = jd + 0.5;
        const z: i64 = @intFromFloat(@floor(jd_plus));
        var day_fraction = jd_plus - @floor(jd_plus);

        const aa: i64 = blk: {
            const alpha = @divFloor(z * 100 - 186721625, 3652425);
            break :blk z + 1 + alpha - @divFloor(alpha, 4);
        };
        const b = aa + 1524;
        const c = @divFloor(b * 100 - 12210, 36525);
        const d = @divFloor(36525 * c, 100);
        const e = @divFloor((b - d) * 10000, 306001);

        const day: i64 = b - d - @divFloor(306001 * e, 10000);
        const month: i64 = if (e < 14) e - 1 else e - 13;
        const year: i64 = if (month > 2) c - 4716 else c - 4715;

        // Time of day from the fraction.
        var total_seconds = day_fraction * 86400.0;
        var hour: i64 = @intFromFloat(@floor(total_seconds / 3600.0));
        total_seconds -= @as(f64, @floatFromInt(hour)) * 3600.0;
        var minute: i64 = @intFromFloat(@floor(total_seconds / 60.0));
        total_seconds -= @as(f64, @floatFromInt(minute)) * 60.0;
        var second: i64 = @intFromFloat(@floor(total_seconds));
        const frac = total_seconds - @as(f64, @floatFromInt(second));
        // Guard against floating drift pushing fields to their ceilings.
        if (second >= 60) {
            second -= 60;
            minute += 1;
        }
        if (minute >= 60) {
            minute -= 60;
            hour += 1;
        }
        _ = &day_fraction;
        return .{
            .year = @intCast(year),
            .month = @intCast(month),
            .day = @intCast(day),
            .hour = @intCast(hour),
            .minute = @intCast(minute),
            .second = @intCast(second),
            .frac = frac,
        };
    }
};

/// Convert a Modified Julian Date to a Julian Date.
pub fn mjdToJd(mjd: f64) f64 {
    return mjd + MJD_OFFSET;
}

/// Convert a Julian Date to a Modified Julian Date.
pub fn jdToMjd(jd: f64) f64 {
    return jd - MJD_OFFSET;
}

// ── Time coordinates (WCS-4, FR-WCS-4; FITS 4.0 §9, Tables 30–35) ─────────────────────────

const Header = @import("../header/header.zig").Header;
const Allocator = std.mem.Allocator;

/// Recognized time reference scales (`TIMESYS`, Table 30).
pub const TimeSys = enum {
    utc,
    tai,
    tt,
    tdb,
    tcg,
    tcb,
    ut1,
    gps,
    unknown,

    pub fn parse(s: []const u8) TimeSys {
        const t = std.mem.trim(u8, s, " ");
        const map = .{
            .{ "UTC", TimeSys.utc }, .{ "TAI", TimeSys.tai }, .{ "TT", TimeSys.tt },
            .{ "TDB", TimeSys.tdb }, .{ "TCG", TimeSys.tcg }, .{ "TCB", TimeSys.tcb },
            .{ "UT1", TimeSys.ut1 }, .{ "GPS", TimeSys.gps },
        };
        inline for (map) |e| if (std.ascii.eqlIgnoreCase(t, e[0])) return e[1];
        return .unknown;
    }
};

/// Recognized time reference positions (`TREFPOS`, Table 31).
pub const RefPos = enum {
    topocenter,
    geocenter,
    barycenter,
    heliocenter,
    relocatable,
    unknown,

    pub fn parse(s: []const u8) RefPos {
        const t = std.mem.trim(u8, s, " ");
        const map = .{
            .{ "TOPOCENTER", RefPos.topocenter }, .{ "GEOCENTER", RefPos.geocenter },
            .{ "BARYCENTER", RefPos.barycenter }, .{ "HELIOCENTER", RefPos.heliocenter },
            .{ "RELOCATABLE", RefPos.relocatable },
        };
        inline for (map) |e| if (std.ascii.eqlIgnoreCase(t, e[0])) return e[1];
        return .unknown;
    }
};

/// The global time-coordinate keywords of a header (FITS 4.0 §9.2).
pub const TimeCoords = struct {
    timesys: TimeSys = .unknown,
    trefpos: RefPos = .unknown,
    /// Time unit string (`TIMEUNIT`), default `s` per §9.2.2 (owned).
    timeunit: ?[]u8 = null,
    /// Reference epoch as an MJD, from `MJDREF` or `MJDREFI`+`MJDREFF` (Table 32).
    mjdref: ?f64 = null,
    /// `DATE-OBS` parsed (Table 33).
    date_obs: ?DateTime = null,
    /// `MJD-OBS`.
    mjd_obs: ?f64 = null,
    /// Exposure window relative to `MJDREF` (`TSTART`/`TSTOP`).
    tstart: ?f64 = null,
    tstop: ?f64 = null,

    /// Parse the global time keywords from `h`.
    pub fn fromHeader(a: Allocator, h: *const Header) std.mem.Allocator.Error!TimeCoords {
        var self: TimeCoords = .{};
        errdefer self.deinit(a);
        if (h.getString(a, "TIMESYS")) |s| {
            defer a.free(s);
            self.timesys = TimeSys.parse(s);
        } else |_| {}
        if (h.getString(a, "TREFPOS")) |s| {
            defer a.free(s);
            self.trefpos = RefPos.parse(s);
        } else |_| {}
        self.timeunit = h.getString(a, "TIMEUNIT") catch null;
        // MJDREF, or MJDREFI + MJDREFF (the split integer/fraction form for precision).
        if (h.getValue(f64, "MJDREF")) |v| {
            self.mjdref = v;
        } else |_| {
            const mi = h.getValue(f64, "MJDREFI") catch null;
            const mf = h.getValue(f64, "MJDREFF") catch null;
            if (mi != null or mf != null) self.mjdref = (mi orelse 0) + (mf orelse 0);
        }
        self.mjd_obs = h.getValue(f64, "MJD-OBS") catch null;
        self.tstart = h.getValue(f64, "TSTART") catch null;
        self.tstop = h.getValue(f64, "TSTOP") catch null;
        if (h.getString(a, "DATE-OBS")) |s| {
            defer a.free(s);
            self.date_obs = DateTime.parse(s) catch null;
        } else |_| {}
        return self;
    }

    pub fn deinit(self: *TimeCoords, a: Allocator) void {
        if (self.timeunit) |u| a.free(u);
    }
};

const testing = std.testing;

test "ISO-8601 parse + round-trip including fractional seconds" {
    const dt = try DateTime.parse("2018-08-13T09:30:15.250");
    try testing.expectEqual(@as(i32, 2018), dt.year);
    try testing.expectEqual(@as(u8, 8), dt.month);
    try testing.expectEqual(@as(u8, 13), dt.day);
    try testing.expectEqual(@as(u8, 15), dt.second);
    try testing.expect(@abs(dt.frac - 0.25) < 1e-9);

    var buf: [40]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dt.format(&w);
    try testing.expectEqualStrings("2018-08-13T09:30:15.250", w.buffered());
}

test "date-only parse and format" {
    const dt = try DateTime.parse("1999-12-31");
    var buf: [40]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try dt.format(&w);
    try testing.expectEqualStrings("1999-12-31T00:00:00", w.buffered());
}

test "deprecated dd/mm/yy maps year to 19yy" {
    const dt = try DateTime.parse("13/08/95");
    try testing.expectEqual(@as(i32, 1995), dt.year);
    try testing.expectEqual(@as(u8, 8), dt.month);
    try testing.expectEqual(@as(u8, 13), dt.day);
}

test "Julian Date matches known epochs" {
    // J2000.0 = 2000-01-01T12:00:00 UT = JD 2451545.0
    const j2000 = try DateTime.parse("2000-01-01T12:00:00");
    try testing.expect(@abs(j2000.toJulianDate() - 2451545.0) < 1e-6);
    // MJD epoch = 1858-11-17T00:00:00 = MJD 0
    const mjd0 = try DateTime.parse("1858-11-17T00:00:00");
    try testing.expect(@abs(mjd0.toMjd() - 0.0) < 1e-6);
    // Unix epoch 1970-01-01T00:00:00 = JD 2440587.5
    const unix = try DateTime.parse("1970-01-01T00:00:00");
    try testing.expect(@abs(unix.toJulianDate() - 2440587.5) < 1e-6);
}

test "fromJulianDate inverts toJulianDate" {
    const cases = [_][]const u8{
        "2000-01-01T12:00:00", "1858-11-17T00:00:00", "2018-08-13T09:30:15", "1999-12-31T23:59:59",
    };
    for (cases) |s| {
        const dt = try DateTime.parse(s);
        const back = DateTime.fromJulianDate(dt.toJulianDate());
        try testing.expectEqual(dt.year, back.year);
        try testing.expectEqual(dt.month, back.month);
        try testing.expectEqual(dt.day, back.day);
        try testing.expectEqual(dt.hour, back.hour);
        try testing.expectEqual(dt.minute, back.minute);
        try testing.expect(@abs(@as(f64, @floatFromInt(dt.second)) + dt.frac -
            (@as(f64, @floatFromInt(back.second)) + back.frac)) < 1e-3);
    }
}

test "malformed dates are rejected" {
    try testing.expectError(error.BadValueSyntax, DateTime.parse(""));
    try testing.expectError(error.BadValueSyntax, DateTime.parse("2018/13"));
    try testing.expectError(error.BadValueSyntax, DateTime.parse("2018-13-01")); // bad month
    try testing.expectError(error.BadValueSyntax, DateTime.parse("2018-08-13X09:30:15"));
    try testing.expectError(error.BadValueSyntax, DateTime.parse("2018-08-13T9:3:1"));
}

test "mjd/jd conversions" {
    try testing.expect(@abs(mjdToJd(0.0) - MJD_OFFSET) < 1e-9);
    try testing.expect(@abs(jdToMjd(MJD_OFFSET) - 0.0) < 1e-9);
}

test "TimeCoords parses the global time keyword set" {
    const blk = @import("../io/block.zig");
    const MemoryDevice = @import("../io/memory.zig").MemoryDevice;
    const a = testing.allocator;
    var buf: [blk.BLOCK]u8 = [_]u8{' '} ** blk.BLOCK;
    const cards = [_][]const u8{
        "TIMESYS = 'TT'",
        "TREFPOS = 'GEOCENTER'",
        "TIMEUNIT= 's'",
        "MJDREFI =                58000",
        "MJDREFF =                  0.5",
        "DATE-OBS= '2018-08-13T09:30:15'",
        "TSTART  =                  0.0",
        "TSTOP   =               1200.0",
    };
    for (cards, 0..) |c, i| @memcpy(buf[i * 80 ..][0..c.len], c);
    @memcpy(buf[cards.len * 80 ..][0..3], "END");
    var mem = try MemoryDevice.initBytes(a, &buf);
    defer mem.deinit();
    var reader = try blk.BlockReader.init(a, mem.device(), 0);
    defer reader.deinit();
    const res = try Header.parse(a, &reader, 0, 36);
    var h = res.header;
    defer h.deinit(a);

    var tc = try TimeCoords.fromHeader(a, &h);
    defer tc.deinit(a);
    try testing.expectEqual(TimeSys.tt, tc.timesys);
    try testing.expectEqual(RefPos.geocenter, tc.trefpos);
    try testing.expectEqualStrings("s", tc.timeunit.?);
    try testing.expect(@abs(tc.mjdref.? - 58000.5) < 1e-9); // I + F combined
    try testing.expect(@abs(tc.tstop.? - 1200.0) < 1e-9);
    try testing.expectEqual(@as(i32, 2018), tc.date_obs.?.year);
}
