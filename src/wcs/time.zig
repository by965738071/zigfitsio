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
        // Year: an optional leading sign and at least four digits, allowing the expanded
        // ISO-8601 form (signed five-digit years) the time WCS permits (§9.1.1).
        var i: usize = 0;
        var year_neg = false;
        if (t.len > 0 and (t[0] == '+' or t[0] == '-')) {
            year_neg = (t[0] == '-');
            i = 1;
        }
        const year_start = i;
        while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) {}
        if (i - year_start < 4) return error.BadValueSyntax;
        const year_mag = std.fmt.parseInt(i32, t[year_start..i], 10) catch return error.BadValueSyntax;
        const year: i32 = if (year_neg) -year_mag else year_mag;
        // Remainder must be `-mm-dd` (and optionally a time part).
        if (i + 6 > t.len or t[i] != '-' or t[i + 3] != '-') return error.BadValueSyntax;
        const month = parseField(u8, t[i + 1 .. i + 3]) catch return error.BadValueSyntax;
        const day = parseField(u8, t[i + 4 .. i + 6]) catch return error.BadValueSyntax;
        var dt: DateTime = .{ .year = year, .month = month, .day = day };
        const after = i + 6;
        if (after == t.len) {
            try dt.validate();
            return dt;
        }
        // Time part: Thh:mm:ss[.sss]
        if (t[after] != 'T' and t[after] != ' ') return error.BadValueSyntax;
        const time = t[after + 1 ..];
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

    fn isLeapYear(year: i32) bool {
        return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    }

    fn daysInMonth(year: i32, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeapYear(year)) 29 else 28,
            else => 0,
        };
    }

    fn validate(self: *const DateTime) HeaderError!void {
        if (self.month < 1 or self.month > 12) return error.BadValueSyntax;
        // Validate the day against the actual month length (leap-year aware): an impossible
        // calendar date (Feb 31, Apr 31, …) would otherwise pass and be silently rolled over
        // by the JD conversion, mutating the date the caller supplied.
        if (self.day < 1 or self.day > daysInMonth(self.year, self.month)) return error.BadValueSyntax;
        if (self.hour > 23 or self.minute > 59 or self.second > 60) return error.BadValueSyntax; // 60 ⇒ leap second
        // Phrased to also reject NaN (all NaN comparisons are false, so `frac < 0 or frac >= 1`
        // let a NaN frac — from an overlong fractional-seconds string — slip through).
        if (!(self.frac >= 0 and self.frac < 1)) return error.BadValueSyntax;
    }

    /// Write the ISO-8601 representation. Fractional seconds are emitted (to millisecond
    /// precision) only when nonzero, matching common FITS usage.
    pub fn format(self: *const DateTime, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // Years outside 0..9999 use the signed five-digit expanded ISO-8601 form (§9.1.1);
        // otherwise the customary four-digit, sign-free form.
        if (self.year < 0 or self.year > 9999) {
            const sign: u8 = if (self.year < 0) '-' else '+';
            const mag: u32 = @intCast(@abs(self.year));
            try w.print("{c}{d:0>5}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
                sign, mag, self.month, self.day, self.hour, self.minute, self.second,
            });
        } else {
            const year_u: u32 = @intCast(self.year);
            try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
                year_u, self.month, self.day, self.hour, self.minute, self.second,
            });
        }
        if (self.frac > 0) {
            // frac ∈ [0,1), but frac ≥ 0.9995 rounds to 1000, which `{d:0>3}` prints as the
            // malformed 4-digit ".1000". Clamp to 999 so at most 3 fractional digits are emitted.
            var millis: u64 = @intFromFloat(@round(self.frac * 1000.0));
            if (millis > 999) millis = 999;
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
    /// A non-finite or wildly out-of-range `jd` is `error.BadValueSyntax` rather than a panic:
    /// the bare `@intFromFloat(@floor(jd+0.5))` below is illegal behavior (and aborts in safe
    /// builds) for Inf/NaN or any value whose floor exceeds i64.
    pub fn fromJulianDate(jd: f64) HeaderError!DateTime {
        // ±1e15 covers every astronomically meaningful JD (≈ ±2.7e12 years) while keeping
        // `z = floor(jd+0.5)` and the downstream integer math comfortably within i64.
        if (!std.math.isFinite(jd) or @abs(jd) > 1e15) return error.BadValueSyntax;
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
        // The |jd| ≤ 1e15 entry guard keeps the i64 intermediates in range, but `year` (≈ jd/365.25,
        // up to ~2.7e12 for an accepted jd) overflows the i32 `year` field — so the narrowing cast
        // below would still panic. Range-check it and surface the typed error the contract promises.
        if (year < std.math.minInt(i32) or year > std.math.maxInt(i32)) return error.BadValueSyntax;
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

/// Convert a Julian epoch (e.g. `J2000.0`) to a Julian Date:
/// `JD = 2451545.0 + (epoch − 2000.0) × 365.25` (FITS 4.0 §9.2.1, Eq. 31).
pub fn julianEpochToJd(epoch: f64) f64 {
    return 2451545.0 + (epoch - 2000.0) * 365.25;
}

/// Convert a Julian Date to its Julian epoch.
pub fn jdToJulianEpoch(jd: f64) f64 {
    return 2000.0 + (jd - 2451545.0) / 365.25;
}

/// Convert a Besselian epoch (e.g. `B1950.0`) to a Julian Date:
/// `JD = 2415020.31352 + (epoch − 1900.0) × 365.242198781` (FITS 4.0 §9.2.1, Eq. 30).
pub fn besselianEpochToJd(epoch: f64) f64 {
    return 2415020.31352 + (epoch - 1900.0) * 365.242198781;
}

/// Convert a Julian Date to its Besselian epoch.
pub fn jdToBesselianEpoch(jd: f64) f64 {
    return 1900.0 + (jd - 2415020.31352) / 365.242198781;
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
    /// Free-running local clock (`LOCAL`, Table 30).
    local,
    unknown,

    pub fn parse(s: []const u8) TimeSys {
        var t = std.mem.trim(u8, s, " ");
        // Strip an optional realization qualifier, e.g. `UT(NIST)` or `UTC(USNO)` (§9.2.1).
        if (std.mem.indexOfScalar(u8, t, '(')) |p| t = std.mem.trim(u8, t[0..p], " ");
        const map = .{
            .{ "UTC", TimeSys.utc }, .{ "TAI", TimeSys.tai }, .{ "TT", TimeSys.tt },
            .{ "TDB", TimeSys.tdb }, .{ "TCG", TimeSys.tcg }, .{ "TCB", TimeSys.tcb },
            .{ "UT1", TimeSys.ut1 }, .{ "GPS", TimeSys.gps }, .{ "LOCAL", TimeSys.local },
            // Deprecated synonyms (Table 30): TDT/ET ⇒ TT, IAT ⇒ TAI, GMT ⇒ UTC.
            .{ "TDT", TimeSys.tt },  .{ "ET", TimeSys.tt },   .{ "IAT", TimeSys.tai },
            .{ "GMT", TimeSys.utc },
        };
        inline for (map) |e| if (std.ascii.eqlIgnoreCase(t, e[0])) return e[1];
        // A bare `UT` (generic Universal Time) is taken as UT1.
        if (std.ascii.eqlIgnoreCase(t, "UT")) return .ut1;
        return .unknown;
    }

    /// The canonical keyword string for this scale, or `null` for `.unknown`.
    pub fn toString(self: TimeSys) ?[]const u8 {
        return switch (self) {
            .utc => "UTC",
            .tai => "TAI",
            .tt => "TT",
            .tdb => "TDB",
            .tcg => "TCG",
            .tcb => "TCB",
            .ut1 => "UT1",
            .gps => "GPS",
            .local => "LOCAL",
            .unknown => null,
        };
    }
};

/// Recognized time reference positions (`TREFPOS`, Table 31).
pub const RefPos = enum {
    topocenter,
    geocenter,
    barycenter,
    heliocenter,
    relocatable,
    /// User-defined position (`CUSTOM`, Table 31).
    custom,
    /// Galactic centre.
    galactic,
    /// Earth–Moon barycentre (`EMBARYCENTER`).
    embarycenter,
    mercury,
    venus,
    mars,
    jupiter,
    saturn,
    uranus,
    neptune,
    pluto,
    unknown,

    pub fn parse(s: []const u8) RefPos {
        const t = std.mem.trim(u8, s, " ");
        if (t.len < 3) return .unknown;
        // Table 31 values are distinguished by their first three significant characters.
        const pre = t[0..3];
        const map = .{
            .{ "TOP", RefPos.topocenter }, .{ "GEO", RefPos.geocenter },
            .{ "BAR", RefPos.barycenter }, .{ "REL", RefPos.relocatable },
            .{ "CUS", RefPos.custom },     .{ "HEL", RefPos.heliocenter },
            .{ "GAL", RefPos.galactic },   .{ "EMB", RefPos.embarycenter },
            .{ "MER", RefPos.mercury },    .{ "VEN", RefPos.venus },
            .{ "MAR", RefPos.mars },       .{ "JUP", RefPos.jupiter },
            .{ "SAT", RefPos.saturn },     .{ "URA", RefPos.uranus },
            .{ "NEP", RefPos.neptune },    .{ "PLU", RefPos.pluto },
        };
        inline for (map) |e| if (std.ascii.eqlIgnoreCase(pre, e[0])) return e[1];
        return .unknown;
    }

    /// The canonical keyword string for this position, or `null` for `.unknown`.
    pub fn toString(self: RefPos) ?[]const u8 {
        return switch (self) {
            .topocenter => "TOPOCENTER",
            .geocenter => "GEOCENTER",
            .barycenter => "BARYCENTER",
            .heliocenter => "HELIOCENTER",
            .relocatable => "RELOCATABLE",
            .custom => "CUSTOM",
            .galactic => "GALACTIC",
            .embarycenter => "EMBARYCENTER",
            .mercury => "MERCURY",
            .venus => "VENUS",
            .mars => "MARS",
            .jupiter => "JUPITER",
            .saturn => "SATURN",
            .uranus => "URANUS",
            .neptune => "NEPTUNE",
            .pluto => "PLUTO",
            .unknown => null,
        };
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
    /// Time offset applied to all time values (`TIMEOFFS`, §9.2.4).
    timeoffs: ?f64 = null,
    /// `DATE-BEG`/`DATE-AVG`/`DATE-END` parsed (Table 33).
    date_beg: ?DateTime = null,
    date_avg: ?DateTime = null,
    date_end: ?DateTime = null,
    /// `MJD-BEG`/`MJD-AVG`/`MJD-END`.
    mjd_beg: ?f64 = null,
    mjd_avg: ?f64 = null,
    mjd_end: ?f64 = null,

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
        // Reference epoch, resolved with the §9.2.2 precedence JDREF > DATEREF > MJDREF.
        self.mjdref = resolveMjdRef(a, h);
        self.mjd_obs = h.getValue(f64, "MJD-OBS") catch null;
        self.tstart = h.getValue(f64, "TSTART") catch null;
        self.tstop = h.getValue(f64, "TSTOP") catch null;
        self.timeoffs = h.getValue(f64, "TIMEOFFS") catch null;
        self.mjd_beg = h.getValue(f64, "MJD-BEG") catch null;
        self.mjd_avg = h.getValue(f64, "MJD-AVG") catch null;
        self.mjd_end = h.getValue(f64, "MJD-END") catch null;
        self.date_obs = parseDateKw(a, h, "DATE-OBS");
        self.date_beg = parseDateKw(a, h, "DATE-BEG");
        self.date_avg = parseDateKw(a, h, "DATE-AVG");
        self.date_end = parseDateKw(a, h, "DATE-END");
        return self;
    }

    /// Resolve the reference epoch (as an MJD) from the JD/DATE/MJD keyword families, with
    /// the §9.2.2 precedence `JDREF` > `DATEREF` > `MJDREF`. Within each split family the
    /// integer+fraction pair (`*REFI`+`*REFF`) takes precedence over the single keyword, and
    /// the single keyword wins only when at most one split part is present.
    fn resolveMjdRef(a: Allocator, h: *const Header) ?f64 {
        // JDREF family (highest precedence), converted from JD to MJD.
        const ji = h.getValue(f64, "JDREFI") catch null;
        const jf = h.getValue(f64, "JDREFF") catch null;
        if (ji != null and jf != null) return jdToMjd(ji.? + jf.?);
        if (h.getValue(f64, "JDREF")) |v| {
            return jdToMjd(v);
        } else |_| {}
        if (ji != null or jf != null) return jdToMjd((ji orelse 0) + (jf orelse 0));
        // DATEREF (an ISO-8601 calendar date).
        if (parseDateKw(a, h, "DATEREF")) |dt| return dt.toMjd();
        // MJDREF family.
        const mi = h.getValue(f64, "MJDREFI") catch null;
        const mf = h.getValue(f64, "MJDREFF") catch null;
        if (mi != null and mf != null) return mi.? + mf.?;
        if (h.getValue(f64, "MJDREF")) |v| {
            return v;
        } else |_| {}
        if (mi != null or mf != null) return (mi orelse 0) + (mf orelse 0);
        return null;
    }

    /// Read keyword `name` as an ISO-8601 date, returning `null` when absent or malformed.
    fn parseDateKw(a: Allocator, h: *const Header, name: []const u8) ?DateTime {
        const s = h.getString(a, name) catch return null;
        defer a.free(s);
        return DateTime.parse(s) catch null;
    }

    /// Emit the global time-coordinate cards into `h`, mirroring `fromHeader`: `TIMESYS`,
    /// `TREFPOS`, `TIMEUNIT`, `MJDREFI`/`MJDREFF`, `DATE-OBS`, `MJD-OBS`, `TSTART`, `TSTOP`
    /// (FR-WCS-4 SHOULD). Only fields that are set are written. The split `MJDREFI`/`MJDREFF`
    /// pair preserves the full precision of `mjdref` and round-trips through `fromHeader`.
    pub fn toHeader(self: *const TimeCoords, a: Allocator, h: *Header) (HeaderError || Allocator.Error)!void {
        if (self.timesys.toString()) |s| try h.appendValue(a, "TIMESYS", .{ .string = s }, "time scale");
        if (self.trefpos.toString()) |s| try h.appendValue(a, "TREFPOS", .{ .string = s }, "time reference position");
        if (self.timeunit) |u| try h.appendValue(a, "TIMEUNIT", .{ .string = u }, "time unit");
        if (self.mjdref) |m| {
            const whole = @floor(m);
            try h.appendValue(a, "MJDREFI", .{ .float = whole }, "[d] MJD reference, integer part");
            try h.appendValue(a, "MJDREFF", .{ .float = m - whole }, "[d] MJD reference, fractional part");
        }
        if (self.date_obs) |dt| try appendDate(a, h, "DATE-OBS", dt, "observation date");
        if (self.mjd_obs) |v| try h.appendValue(a, "MJD-OBS", .{ .float = v }, "[d] observation MJD");
        if (self.tstart) |v| try h.appendValue(a, "TSTART", .{ .float = v }, "start of exposure");
        if (self.tstop) |v| try h.appendValue(a, "TSTOP", .{ .float = v }, "end of exposure");
    }

    /// Alias of `toHeader`: write the global time-coordinate cards into `h` (FR-WCS-4).
    pub fn writeTime(self: *const TimeCoords, a: Allocator, h: *Header) (HeaderError || Allocator.Error)!void {
        return self.toHeader(a, h);
    }

    /// Format `dt` as an ISO-8601 string and append it as the value of card `name`.
    fn appendDate(a: Allocator, h: *Header, name: []const u8, dt: DateTime, comment_text: ?[]const u8) (HeaderError || Allocator.Error)!void {
        var buf: [40]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        dt.format(&w) catch unreachable; // 40 bytes is ample for any FITS date string
        try h.appendValue(a, name, .{ .string = w.buffered() }, comment_text);
    }

    /// Release the optional allocator-owned time-unit string.
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
        const back = try DateTime.fromJulianDate(dt.toJulianDate());
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

test "impossible calendar days are rejected (month length + leap year)" {
    // Regression: day was only checked 1..31, so these passed and were silently rolled over.
    try testing.expectError(error.BadValueSyntax, DateTime.parse("2019-02-31"));
    try testing.expectError(error.BadValueSyntax, DateTime.parse("2019-02-29")); // 2019 not a leap year
    try testing.expectError(error.BadValueSyntax, DateTime.parse("2018-04-31")); // April has 30
    try testing.expectError(error.BadValueSyntax, DateTime.parse("2018-00-10")); // day 0 / month 0 guards
    // Valid edge cases still parse.
    _ = try DateTime.parse("2020-02-29"); // 2020 is a leap year
    _ = try DateTime.parse("2018-04-30");
    _ = try DateTime.parse("2000-02-29"); // div-by-400 leap year
    try testing.expectError(error.BadValueSyntax, DateTime.parse("1900-02-29")); // div-by-100 non-leap
}

test "fromJulianDate rejects non-finite / out-of-range jd instead of panicking" {
    // Regression: bare @intFromFloat(@floor(jd+0.5)) panicked on Inf / huge / NaN.
    try testing.expectError(error.BadValueSyntax, DateTime.fromJulianDate(std.math.inf(f64)));
    try testing.expectError(error.BadValueSyntax, DateTime.fromJulianDate(-std.math.inf(f64)));
    try testing.expectError(error.BadValueSyntax, DateTime.fromJulianDate(std.math.nan(f64)));
    try testing.expectError(error.BadValueSyntax, DateTime.fromJulianDate(1.0e300));
    // A finite jd within the entry guard (|jd| ≤ 1e15) whose reconstructed year overflows i32
    // must also be a typed error, not an @intCast panic.
    try testing.expectError(error.BadValueSyntax, DateTime.fromJulianDate(1.0e14));
    try testing.expectError(error.BadValueSyntax, DateTime.fromJulianDate(1.0e12));
    _ = try DateTime.fromJulianDate(2451545.0); // a normal JD still works
}

test "format clamps sub-millisecond rounding to 3 digits (no .1000)" {
    // Regression: frac ≥ 0.9995 rounded to 1000 and printed the malformed 4-digit ".1000".
    var buf: [40]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const dt = DateTime{ .year = 2020, .month = 1, .day = 1, .hour = 12, .minute = 0, .second = 0, .frac = 0.9996 };
    try dt.format(&w);
    const out = w.buffered();
    try testing.expect(std.mem.endsWith(u8, out, ".999"));
    try testing.expect(!std.mem.containsAtLeast(u8, out, 1, ".1000"));
}

test "validate rejects a NaN fractional second" {
    const dt = DateTime{ .year = 2020, .month = 1, .day = 1, .frac = std.math.nan(f64) };
    try testing.expectError(error.BadValueSyntax, dt.validate());
}

test "mjd/jd conversions" {
    try testing.expect(@abs(mjdToJd(0.0) - MJD_OFFSET) < 1e-9);
    try testing.expect(@abs(jdToMjd(MJD_OFFSET) - 0.0) < 1e-9);
}

test "TimeCoords parses the global time keyword set" {
    const blk = @import("../io/block.zig");
    const MemoryDevice = @import("../io/memory.zig").MemoryDevice;
    const a = testing.allocator;
    var buf: [blk.BLOCK]u8 = @splat(' ');
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

test "MJDREFI+MJDREFF take precedence over a single MJDREF (§9.2.2)" {
    const a = testing.allocator;
    var h = Header.initEmpty();
    defer h.deinit(a);
    try h.appendValue(a, "MJDREF", .{ .float = 50000.0 }, null);
    try h.appendValue(a, "MJDREFI", .{ .float = 58000.0 }, null);
    try h.appendValue(a, "MJDREFF", .{ .float = 0.25 }, null);
    var tc = try TimeCoords.fromHeader(a, &h);
    defer tc.deinit(a);
    // The split integer+fraction pair wins over the lone MJDREF.
    try testing.expect(@abs(tc.mjdref.? - 58000.25) < 1e-9);
}

test "TimeCoords toHeader/writeTime round-trips through fromHeader" {
    const a = testing.allocator;
    var src: TimeCoords = .{
        .timesys = .tt,
        .trefpos = .geocenter,
        .mjdref = 58000.5,
        .mjd_obs = 58001.25,
        .tstart = 0.0,
        .tstop = 1200.0,
        .date_obs = try DateTime.parse("2018-08-13T09:30:15"),
    };
    src.timeunit = try a.dupe(u8, "s"); // owned per the field contract
    defer src.deinit(a);

    var h = Header.initEmpty();
    defer h.deinit(a);
    try src.writeTime(a, &h);

    var tc = try TimeCoords.fromHeader(a, &h);
    defer tc.deinit(a);
    try testing.expectEqual(TimeSys.tt, tc.timesys);
    try testing.expectEqual(RefPos.geocenter, tc.trefpos);
    try testing.expectEqualStrings("s", tc.timeunit.?);
    try testing.expect(@abs(tc.mjdref.? - 58000.5) < 1e-9);
    try testing.expect(@abs(tc.mjd_obs.? - 58001.25) < 1e-9);
    try testing.expect(@abs(tc.tstop.? - 1200.0) < 1e-9);
    try testing.expectEqual(@as(i32, 2018), tc.date_obs.?.year);
    try testing.expectEqual(@as(u8, 15), tc.date_obs.?.second);
}

test "TimeSys deprecated synonyms, LOCAL, and UT() qualifier" {
    try testing.expectEqual(TimeSys.tt, TimeSys.parse("TDT"));
    try testing.expectEqual(TimeSys.tt, TimeSys.parse("ET"));
    try testing.expectEqual(TimeSys.tai, TimeSys.parse("IAT"));
    try testing.expectEqual(TimeSys.utc, TimeSys.parse("GMT"));
    try testing.expectEqual(TimeSys.local, TimeSys.parse("LOCAL"));
    try testing.expectEqual(TimeSys.ut1, TimeSys.parse("UT"));
    try testing.expectEqual(TimeSys.utc, TimeSys.parse("UTC(USNO)"));
    try testing.expectEqual(TimeSys.ut1, TimeSys.parse("UT1(NIST)"));
    try testing.expectEqual(TimeSys.unknown, TimeSys.parse("FOO"));
    try testing.expectEqualStrings("LOCAL", TimeSys.local.toString().?);
    try testing.expect(TimeSys.unknown.toString() == null);
}

test "RefPos CUSTOM and solar-system positions match on three chars" {
    try testing.expectEqual(RefPos.custom, RefPos.parse("CUSTOM"));
    try testing.expectEqual(RefPos.heliocenter, RefPos.parse("HELIOCENTER"));
    try testing.expectEqual(RefPos.embarycenter, RefPos.parse("EMBARYCENTER"));
    try testing.expectEqual(RefPos.galactic, RefPos.parse("GALACTIC"));
    try testing.expectEqual(RefPos.mars, RefPos.parse("MARS"));
    try testing.expectEqual(RefPos.jupiter, RefPos.parse("JUPITER"));
    try testing.expectEqual(RefPos.pluto, RefPos.parse("PLUTO"));
    try testing.expectEqual(RefPos.topocenter, RefPos.parse("TOPOCENTER"));
    try testing.expectEqual(RefPos.unknown, RefPos.parse("XY"));
    try testing.expectEqualStrings("EMBARYCENTER", RefPos.embarycenter.toString().?);
}

test "reference epoch precedence JDREF > DATEREF > MJDREF" {
    const a = testing.allocator;
    // JDREF wins over both DATEREF and MJDREF.
    {
        var h = Header.initEmpty();
        defer h.deinit(a);
        try h.appendValue(a, "MJDREF", .{ .float = 50000.0 }, null);
        try h.appendValue(a, "DATEREF", .{ .string = "2000-01-01T00:00:00" }, null);
        try h.appendValue(a, "JDREF", .{ .float = mjdToJd(58000.0) }, null);
        var tc = try TimeCoords.fromHeader(a, &h);
        defer tc.deinit(a);
        try testing.expect(@abs(tc.mjdref.? - 58000.0) < 1e-6);
    }
    // DATEREF wins over MJDREF when no JDREF is present.
    {
        var h = Header.initEmpty();
        defer h.deinit(a);
        try h.appendValue(a, "MJDREF", .{ .float = 50000.0 }, null);
        try h.appendValue(a, "DATEREF", .{ .string = "1858-11-17T00:00:00" }, null);
        var tc = try TimeCoords.fromHeader(a, &h);
        defer tc.deinit(a);
        try testing.expect(@abs(tc.mjdref.? - 0.0) < 1e-6); // MJD epoch
    }
    // Split JDREFI+JDREFF take precedence within the JD family.
    {
        var h = Header.initEmpty();
        defer h.deinit(a);
        try h.appendValue(a, "JDREF", .{ .float = mjdToJd(1.0) }, null);
        try h.appendValue(a, "JDREFI", .{ .float = mjdToJd(58000.0) }, null);
        try h.appendValue(a, "JDREFF", .{ .float = 0.25 }, null);
        var tc = try TimeCoords.fromHeader(a, &h);
        defer tc.deinit(a);
        try testing.expect(@abs(tc.mjdref.? - 58000.25) < 1e-6);
    }
}

test "TimeCoords reads DATE/MJD-BEG/AVG/END and TIMEOFFS" {
    const a = testing.allocator;
    var h = Header.initEmpty();
    defer h.deinit(a);
    try h.appendValue(a, "DATE-BEG", .{ .string = "2018-08-13T09:00:00" }, null);
    try h.appendValue(a, "DATE-AVG", .{ .string = "2018-08-13T09:30:00" }, null);
    try h.appendValue(a, "DATE-END", .{ .string = "2018-08-13T10:00:00" }, null);
    try h.appendValue(a, "MJD-BEG", .{ .float = 58343.375 }, null);
    try h.appendValue(a, "MJD-AVG", .{ .float = 58343.395 }, null);
    try h.appendValue(a, "MJD-END", .{ .float = 58343.416 }, null);
    try h.appendValue(a, "TIMEOFFS", .{ .float = 1.5 }, null);
    var tc = try TimeCoords.fromHeader(a, &h);
    defer tc.deinit(a);
    try testing.expectEqual(@as(u8, 9), tc.date_beg.?.hour);
    try testing.expectEqual(@as(u8, 30), tc.date_avg.?.minute);
    try testing.expectEqual(@as(u8, 10), tc.date_end.?.hour);
    try testing.expect(@abs(tc.mjd_beg.? - 58343.375) < 1e-9);
    try testing.expect(@abs(tc.mjd_end.? - 58343.416) < 1e-9);
    try testing.expect(@abs(tc.timeoffs.? - 1.5) < 1e-9);
}

test "signed five-digit ISO-8601 years parse and format" {
    const future = try DateTime.parse("+12345-06-07T01:02:03");
    try testing.expectEqual(@as(i32, 12345), future.year);
    try testing.expectEqual(@as(u8, 6), future.month);
    var buf: [40]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try future.format(&w);
    try testing.expectEqualStrings("+12345-06-07T01:02:03", w.buffered());

    const past = try DateTime.parse("-04713-11-24T12:00:00");
    try testing.expectEqual(@as(i32, -4713), past.year);
    var buf2: [40]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try past.format(&w2);
    try testing.expectEqualStrings("-04713-11-24T12:00:00", w2.buffered());
}

test "Julian and Besselian epoch conversions" {
    // J2000.0 ⇒ JD 2451545.0.
    try testing.expect(@abs(julianEpochToJd(2000.0) - 2451545.0) < 1e-6);
    try testing.expect(@abs(jdToJulianEpoch(2451545.0) - 2000.0) < 1e-9);
    // B1900.0 ⇒ JD 2415020.31352.
    try testing.expect(@abs(besselianEpochToJd(1900.0) - 2415020.31352) < 1e-6);
    try testing.expect(@abs(jdToBesselianEpoch(2415020.31352) - 1900.0) < 1e-9);
    // Round-trip a Besselian epoch through JD.
    try testing.expect(@abs(jdToBesselianEpoch(besselianEpochToJd(1950.0)) - 1950.0) < 1e-9);
}
