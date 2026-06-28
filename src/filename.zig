//! Extended filename syntax + programmatic spec (`FR-EFN-1..5`, design §20.1).
//!
//! A `FileSpec` names a FITS file *and* a selection within it: an HDU (by number or
//! `EXTNAME[,EXTVER]`) and an optional image section. `parse` turns a CFITSIO-style extended
//! name (`"img.fits[1:512:2,1:512]"`) into that struct, but — per `FR-EFN-5` — the string DSL
//! is **never the only path**: `build` constructs the identical, owned `FileSpec` from plain
//! values, so every DSL feature has a non-string equivalent. Both products own copies of all
//! strings/slices and are released with `deinit`.
//!
//! ## Grammar (the bits we support)
//!
//! ```text
//! name      := path ( '[' group ']' )*
//! group     := hdu_index | extname_ver | section
//! hdu_index := <integer>                         (0-based CFITSIO bracket; [0] = primary)
//! extname_ver := <name> [ ',' <integer> ]        (first field is non-numeric)
//! section   := field ( ',' field )*              (all fields numeric / ranges / '*')
//! field     := '*' | <n> | <lo>':'<hi> | <lo>':'<hi>':'<step>
//! ```
//!
//! ### Index conventions (the two base shifts this module performs)
//!
//!   * **HDU bracket → HDU number (`FR-EFN-1`).** The CFITSIO bracket is 0-based, the
//!     programmatic `Fits.select`/`hdu_index` is 1-based: filename `[n]` ↔ `hdu_index = n+1`
//!     (so `[0]` selects the primary, `hdu_index = 1`).
//!   * **Section DSL (1-based, inclusive) → `Section` (0-based, inclusive) (`FR-EFN-2`).** The
//!     CFITSIO section `[a:b:c, …]` counts pixels from 1; `ImageView.readSection` takes 0-based
//!     inclusive `lower`/`upper` with a per-axis `stride`. So `[1:512:2,1:512]` stores
//!     `lower = {0,0}`, `upper = {511,511}`, `stride = {2,1}` — directly passable to
//!     `readSection`. Field order is preserved (field 0 ↔ axis 0, the most-rapidly-varying).
//!     An open upper end (`*`, or the high side of `a:*`) is stored as the `open_end` sentinel;
//!     the caller resolves it against the axis length at read time.
//!
//! ### Scope (`FR-EFN-3/4`)
//!
//! On-the-fly column selection, row filtering (the boolean-calculator / `gtifilter()` /
//! `regfilter()` engine), binning/histogram specifiers, and output/template qualifiers are
//! `MAY` and are **not** implemented here: a bracket group that matches none of the supported
//! shapes is rejected with a typed `ParseError`, never silently ignored (NFR-INTEROP-1). For an
//! `EXTNAME` that itself contains `:`/`,` or starts with a digit (which the DSL cannot express
//! unambiguously), use `build` directly.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// FITS caps `NAXIS` at 999; a section may not name more axes than that.
const MAX_DIMS: usize = 999;

/// Sentinel `Section.upper` value meaning "to the end of this axis" (an open `*`/`a:*` high
/// end). The DSL cannot know the axis length, so the consumer resolves `open_end` against the
/// HDU's `NAXISn` (0-based: `axis_len - 1`) before calling `ImageView.readSection`.
pub const open_end: u64 = std.math.maxInt(u64);

/// Failures from `parse`. A local set (`GC-4` / FR-ERR-1 style): the grammar's own syntax
/// errors plus `Allocator.Error` for the owned copies. Unsupported-but-`MAY` constructs
/// (column/row filters) surface as `BadSection`/`BadExtVer` rather than being ignored.
pub const ParseError = error{
    /// The path portion (text before the first `[`) is empty.
    EmptyPath,
    /// A `[` without a matching `]`.
    UnbalancedBracket,
    /// An empty `[]` group.
    EmptyBracket,
    /// A bracket group looked like an HDU index but did not parse as a non-negative count.
    BadHduIndex,
    /// An `EXTNAME` group had a malformed/absent `EXTVER` or too many comma fields.
    BadExtVer,
    /// A malformed image-section field (bad bound, zero/empty index, zero stride, too many
    /// axes, or a `:`/`,` construct that is not a valid section).
    BadSection,
    /// Two HDU selectors, or two sections, in one name.
    DuplicateSelector,
    /// Non-bracket junk after the final `]`.
    TrailingChars,
} || Allocator.Error;

/// A rectangular image section, **0-based and inclusive**, ready for `ImageView.readSection`
/// (`FR-EFN-2`). `lower`/`upper`/`stride` are parallel, one entry per selected axis (axis 0
/// fastest); `stride` defaults to all-ones when the DSL omits the step. An `upper` entry equal
/// to `open_end` denotes an open high end. All three slices are allocator-owned (freed by
/// `FileSpec.deinit`).
pub const Section = struct {
    lower: []u64,
    upper: []u64,
    stride: []u64,

    /// Element-wise equality (same rank and identical bounds/stride).
    pub fn eql(a: Section, b: Section) bool {
        return std.mem.eql(u64, a.lower, b.lower) and
            std.mem.eql(u64, a.upper, b.upper) and
            std.mem.eql(u64, a.stride, b.stride);
    }
};

/// A parsed (or hand-built) file selection. Exactly one HDU selector is set at most: either
/// `hdu_index` (1-based) **or** (`extname`, optional `extver`); `section` is independent. A
/// bare path leaves every selector null. `path` and `extname` and the `section` slices are
/// owned — call `deinit`.
pub const FileSpec = struct {
    /// The filesystem path (text before the first `[`), owned.
    path: []const u8,
    /// 1-based HDU number (CFITSIO bracket `n` ⇒ `n + 1`); null if unset.
    hdu_index: ?usize = null,
    /// `EXTNAME` to select (owned), case sensitivity is the navigator's concern; null if unset.
    extname: ?[]const u8 = null,
    /// `EXTVER` paired with `extname`; null means "any version".
    extver: ?i64 = null,
    /// Image section to read; null means the whole array.
    section: ?Section = null,

    /// Release every owned allocation. Safe on both `parse` and `build` products.
    pub fn deinit(self: *FileSpec, alloc: Allocator) void {
        alloc.free(self.path);
        if (self.extname) |e| alloc.free(e);
        if (self.section) |s| {
            alloc.free(s.lower);
            alloc.free(s.upper);
            alloc.free(s.stride);
        }
        self.* = undefined;
    }

    /// Value equality across every field (used to prove the DSL and the programmatic builder
    /// produce identical specs, `FR-EFN-5`). Slices compare by content, not identity.
    pub fn eql(a: FileSpec, b: FileSpec) bool {
        if (!std.mem.eql(u8, a.path, b.path)) return false;
        if (a.hdu_index != b.hdu_index) return false;
        if (a.extver != b.extver) return false;
        if (!optStrEql(a.extname, b.extname)) return false;
        if ((a.section == null) != (b.section == null)) return false;
        if (a.section) |sa| if (!sa.eql(b.section.?)) return false;
        return true;
    }
};

/// Borrowed inputs for `build` (mirrors `Section`, but the slices are not owned by the caller's
/// `FileSpec` — `build` duplicates them).
pub const SectionInput = struct {
    lower: []const u64,
    upper: []const u64,
    stride: []const u64,
};

/// Plain, borrowed inputs for `build` — the programmatic equivalent of the DSL (`FR-EFN-5`).
pub const Builder = struct {
    path: []const u8,
    hdu_index: ?usize = null,
    extname: ?[]const u8 = null,
    extver: ?i64 = null,
    section: ?SectionInput = null,
};

/// Construct a `FileSpec` programmatically — the non-string path that `FR-EFN-5` requires.
/// Every string/slice in `in` is duplicated into `alloc`, yielding a fully-owned spec that is
/// `eql` to the one `parse` would build for the same selection and is released with `deinit`.
pub fn build(alloc: Allocator, in: Builder) Allocator.Error!FileSpec {
    var spec: FileSpec = .{ .path = try alloc.dupe(u8, in.path) };
    errdefer spec.deinit(alloc);
    spec.hdu_index = in.hdu_index;
    spec.extver = in.extver;
    if (in.extname) |e| spec.extname = try alloc.dupe(u8, e);
    if (in.section) |s| {
        const lo = try alloc.dupe(u64, s.lower);
        errdefer alloc.free(lo);
        const up = try alloc.dupe(u64, s.upper);
        errdefer alloc.free(up);
        const st = try alloc.dupe(u64, s.stride);
        spec.section = .{ .lower = lo, .upper = up, .stride = st };
    }
    return spec;
}

/// Parse a CFITSIO-style extended name into an owned `FileSpec` (`FR-EFN-1/2`). The text before
/// the first `[` is the path; each following `[...]` group is one selector (HDU index, name+ver,
/// or section). Malformed brackets, unsupported `MAY` constructs, and conflicting selectors all
/// return a typed `ParseError`; the result owns its memory (free with `deinit`).
pub fn parse(alloc: Allocator, name: []const u8) ParseError!FileSpec {
    if (name.len == 0) return error.EmptyPath;

    const lb = std.mem.indexOfScalar(u8, name, '[');
    const path_slice = if (lb) |i| name[0..i] else name;
    if (path_slice.len == 0) return error.EmptyPath;

    var spec: FileSpec = .{ .path = try alloc.dupe(u8, path_slice) };
    errdefer spec.deinit(alloc);

    var i = lb orelse return spec; // no brackets ⇒ bare path
    while (i < name.len) {
        if (name[i] != '[') return error.TrailingChars;
        const rel = std.mem.indexOfScalar(u8, name[i + 1 ..], ']') orelse return error.UnbalancedBracket;
        const close = i + 1 + rel;
        try applyGroup(alloc, &spec, name[i + 1 .. close]);
        i = close + 1;
    }
    return spec;
}

// ── group classification & application ───────────────────────────────────────────────────────

// Classify one bracket group's content and fold it into `spec`.
fn applyGroup(alloc: Allocator, spec: *FileSpec, content_raw: []const u8) ParseError!void {
    const content = std.mem.trim(u8, content_raw, " ");
    if (content.len == 0) return error.EmptyBracket;

    var n: usize = 1;
    for (content) |c| {
        if (c == ',') n += 1;
    }
    var it = std.mem.splitScalar(u8, content, ',');
    const f0 = std.mem.trim(u8, it.next().?, " ");

    if (n == 1) {
        // A single field is an HDU index (bare integer) unless it is a 1-axis section.
        if (std.mem.eql(u8, f0, "*") or hasColon(f0)) {
            return applySection(alloc, spec, content, n);
        } else if (isInteger(f0)) {
            return applyHduIndex(spec, f0);
        } else {
            return applyExtname(alloc, spec, f0, null);
        }
    }

    // Multiple fields: a section iff every field is numeric / a range / '*', else EXTNAME,EXTVER.
    if (allSectionFields(content)) {
        return applySection(alloc, spec, content, n);
    }
    if (n != 2) return error.BadExtVer; // EXTNAME takes at most one EXTVER
    if (f0.len == 0 or isInteger(f0) or hasColon(f0) or std.mem.eql(u8, f0, "*")) return error.BadSection;
    const f1 = std.mem.trim(u8, it.next().?, " ");
    const ver = std.fmt.parseInt(i64, f1, 10) catch return error.BadExtVer;
    return applyExtname(alloc, spec, f0, ver);
}

fn applyHduIndex(spec: *FileSpec, field: []const u8) ParseError!void {
    if (hasHduSelector(spec)) return error.DuplicateSelector;
    const n = std.fmt.parseInt(usize, field, 10) catch return error.BadHduIndex;
    if (n == std.math.maxInt(usize)) return error.BadHduIndex; // n+1 would overflow
    spec.hdu_index = n + 1; // CFITSIO 0-based bracket → 1-based HDU number (FR-EFN-1)
}

fn applyExtname(alloc: Allocator, spec: *FileSpec, name: []const u8, ver: ?i64) ParseError!void {
    if (hasHduSelector(spec)) return error.DuplicateSelector;
    const owned = try alloc.dupe(u8, name);
    spec.extname = owned;
    spec.extver = ver;
}

fn applySection(alloc: Allocator, spec: *FileSpec, content: []const u8, n: usize) ParseError!void {
    if (spec.section != null) return error.DuplicateSelector;
    if (n > MAX_DIMS) return error.BadSection;

    const lo = try alloc.alloc(u64, n);
    errdefer alloc.free(lo);
    const up = try alloc.alloc(u64, n);
    errdefer alloc.free(up);
    const st = try alloc.alloc(u64, n);
    errdefer alloc.free(st);

    var it = std.mem.splitScalar(u8, content, ',');
    var ax: usize = 0;
    while (it.next()) |field| : (ax += 1) {
        const r = try parseSectionField(field);
        lo[ax] = r.lo;
        up[ax] = r.hi;
        st[ax] = r.st;
    }
    spec.section = .{ .lower = lo, .upper = up, .stride = st };
}

// ── section-field parsing (1-based DSL → 0-based inclusive) ─────────────────────────────────────

const Range = struct { lo: u64, hi: u64, st: u64 };

// Parse one `*` / `n` / `lo:hi` / `lo:hi:step` field into a 0-based inclusive range + stride.
fn parseSectionField(field_raw: []const u8) ParseError!Range {
    const field = std.mem.trim(u8, field_raw, " ");
    if (field.len == 0) return error.BadSection;

    var parts: [3][]const u8 = undefined;
    var np: usize = 0;
    var it = std.mem.splitScalar(u8, field, ':');
    while (it.next()) |p| {
        if (np == 3) return error.BadSection; // more than two colons
        parts[np] = std.mem.trim(u8, p, " ");
        np += 1;
    }

    switch (np) {
        1 => {
            if (std.mem.eql(u8, parts[0], "*")) return .{ .lo = 0, .hi = open_end, .st = 1 };
            const v = try indexToZero(parts[0]);
            return .{ .lo = v, .hi = v, .st = 1 };
        },
        2 => return .{ .lo = try lowBound(parts[0]), .hi = try highBound(parts[1]), .st = 1 },
        3 => return .{ .lo = try lowBound(parts[0]), .hi = try highBound(parts[1]), .st = try strideOf(parts[2]) },
        else => unreachable,
    }
}

// `*` ⇒ 0 (axis start); otherwise a 1-based index mapped to 0-based.
fn lowBound(s: []const u8) ParseError!u64 {
    if (std.mem.eql(u8, s, "*")) return 0;
    return indexToZero(s);
}

// `*` ⇒ open_end; otherwise a 1-based index mapped to 0-based.
fn highBound(s: []const u8) ParseError!u64 {
    if (std.mem.eql(u8, s, "*")) return open_end;
    return indexToZero(s);
}

// A 1-based DSL index → 0-based; rejects empty, non-numeric, and 0 (1-based has no pixel 0).
fn indexToZero(s: []const u8) ParseError!u64 {
    const v = std.fmt.parseInt(u64, s, 10) catch return error.BadSection;
    if (v == 0) return error.BadSection;
    return v - 1;
}

// Stride must be a positive integer (reverse `-step` flips are out of scope, FR-EFN-2).
fn strideOf(s: []const u8) ParseError!u64 {
    const v = std.fmt.parseInt(u64, s, 10) catch return error.BadSection;
    if (v == 0) return error.BadSection;
    return v;
}

// ── small predicates ───────────────────────────────────────────────────────────────────────

fn hasHduSelector(spec: *const FileSpec) bool {
    return spec.hdu_index != null or spec.extname != null;
}

fn hasColon(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, ':') != null;
}

fn isInteger(s: []const u8) bool {
    _ = std.fmt.parseInt(i64, s, 10) catch return false;
    return true;
}

// A field that can appear in an image section: '*', a colon range, or a bare integer.
fn looksLikeSectionField(s: []const u8) bool {
    return std.mem.eql(u8, s, "*") or hasColon(s) or isInteger(s);
}

// True iff every comma-field of `content` looks like a section field.
fn allSectionFields(content: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, ',');
    while (it.next()) |f| {
        if (!looksLikeSectionField(std.mem.trim(u8, f, " "))) return false;
    }
    return true;
}

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

// ── tests ──────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "image section maps to 0-based inclusive bounds/stride (FR-EFN-2)" {
    var spec = try parse(testing.allocator, "img.fits[1:512:2,1:512]");
    defer spec.deinit(testing.allocator);

    try testing.expectEqualStrings("img.fits", spec.path);
    try testing.expectEqual(@as(?usize, null), spec.hdu_index);
    try testing.expectEqual(@as(?[]const u8, null), spec.extname);
    const sec = spec.section.?;
    try testing.expectEqualSlices(u64, &.{ 0, 0 }, sec.lower);
    try testing.expectEqualSlices(u64, &.{ 511, 511 }, sec.upper);
    try testing.expectEqualSlices(u64, &.{ 2, 1 }, sec.stride); // default stride 1 on axis 1
}

test "0-based bracket [0] selects the primary as hdu_index 1 (FR-EFN-1)" {
    var spec = try parse(testing.allocator, "x.fits[0]");
    defer spec.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 1), spec.hdu_index);
    try testing.expectEqual(@as(?Section, null), spec.section);
}

test "bracket [3] selects HDU 4 (n -> n+1)" {
    var spec = try parse(testing.allocator, "x.fits[3]");
    defer spec.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 4), spec.hdu_index);
}

test "EXTNAME,EXTVER selector" {
    var spec = try parse(testing.allocator, "x.fits[SCI,2]");
    defer spec.deinit(testing.allocator);
    try testing.expectEqualStrings("SCI", spec.extname.?);
    try testing.expectEqual(@as(?i64, 2), spec.extver);
    try testing.expectEqual(@as(?usize, null), spec.hdu_index);
}

test "EXTNAME without EXTVER" {
    var spec = try parse(testing.allocator, "x.fits[SCI]");
    defer spec.deinit(testing.allocator);
    try testing.expectEqualStrings("SCI", spec.extname.?);
    try testing.expectEqual(@as(?i64, null), spec.extver);
}

test "bare path has no selectors" {
    var spec = try parse(testing.allocator, "/data/run.fits");
    defer spec.deinit(testing.allocator);
    try testing.expectEqualStrings("/data/run.fits", spec.path);
    try testing.expectEqual(@as(?usize, null), spec.hdu_index);
    try testing.expectEqual(@as(?[]const u8, null), spec.extname);
    try testing.expectEqual(@as(?i64, null), spec.extver);
    try testing.expectEqual(@as(?Section, null), spec.section);
}

test "open-ended sections: '*' whole axis and 'a:*' open high end" {
    {
        var spec = try parse(testing.allocator, "c.fits[*]");
        defer spec.deinit(testing.allocator);
        const sec = spec.section.?;
        try testing.expectEqualSlices(u64, &.{0}, sec.lower);
        try testing.expectEqualSlices(u64, &.{open_end}, sec.upper);
        try testing.expectEqualSlices(u64, &.{1}, sec.stride);
    }
    {
        var spec = try parse(testing.allocator, "c.fits[*,10:*:3]");
        defer spec.deinit(testing.allocator);
        const sec = spec.section.?;
        try testing.expectEqualSlices(u64, &.{ 0, 9 }, sec.lower); // 10 -> 9 (0-based)
        try testing.expectEqualSlices(u64, &.{ open_end, open_end }, sec.upper);
        try testing.expectEqualSlices(u64, &.{ 1, 3 }, sec.stride);
    }
}

test "single-pixel and all-numeric multi-field sections" {
    // A 2-D all-numeric group is a section of single pixels (documented ambiguity vs EXTNAME).
    var spec = try parse(testing.allocator, "p.fits[10,20]");
    defer spec.deinit(testing.allocator);
    const sec = spec.section.?;
    try testing.expectEqualSlices(u64, &.{ 9, 19 }, sec.lower);
    try testing.expectEqualSlices(u64, &.{ 9, 19 }, sec.upper);
    try testing.expectEqualSlices(u64, &.{ 1, 1 }, sec.stride);
}

test "separate HDU and section brackets combine" {
    var spec = try parse(testing.allocator, "m.fits[2][1:4,1:4]");
    defer spec.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 3), spec.hdu_index); // [2] -> HDU 3
    const sec = spec.section.?;
    try testing.expectEqualSlices(u64, &.{ 0, 0 }, sec.lower);
    try testing.expectEqualSlices(u64, &.{ 3, 3 }, sec.upper);
}

test "malformed brackets and unsupported constructs are typed errors" {
    try testing.expectError(error.EmptyPath, parse(testing.allocator, ""));
    try testing.expectError(error.EmptyPath, parse(testing.allocator, "[1]"));
    try testing.expectError(error.UnbalancedBracket, parse(testing.allocator, "a.fits[1:2"));
    try testing.expectError(error.EmptyBracket, parse(testing.allocator, "a.fits[]"));
    try testing.expectError(error.EmptyBracket, parse(testing.allocator, "a.fits[   ]"));
    try testing.expectError(error.TrailingChars, parse(testing.allocator, "a.fits[1]junk"));
    try testing.expectError(error.BadSection, parse(testing.allocator, "a.fits[1:abc]"));
    try testing.expectError(error.BadSection, parse(testing.allocator, "a.fits[0:5]")); // 1-based, no pixel 0
    try testing.expectError(error.BadSection, parse(testing.allocator, "a.fits[1:10:0]")); // zero stride
    try testing.expectError(error.BadSection, parse(testing.allocator, "a.fits[1:2:3:4]")); // too many colons
    try testing.expectError(error.BadExtVer, parse(testing.allocator, "a.fits[SCI,bad]"));
    try testing.expectError(error.BadExtVer, parse(testing.allocator, "a.fits[SCI,1,2]"));
    try testing.expectError(error.DuplicateSelector, parse(testing.allocator, "a.fits[1][2]"));
    try testing.expectError(error.DuplicateSelector, parse(testing.allocator, "a.fits[SCI,1][2]"));
    try testing.expectError(error.DuplicateSelector, parse(testing.allocator, "a.fits[1:2][3:4]"));
}

test "parse failure leaks nothing (path/extname/section freed on error)" {
    // Errors after the path (and after a name) is duped exercise the errdefer cleanup.
    try testing.expectError(error.DuplicateSelector, parse(testing.allocator, "leak.fits[SCI,1][2]"));
    try testing.expectError(error.UnbalancedBracket, parse(testing.allocator, "leak.fits[1:2,3:4"));
}

test "build is the non-DSL equivalent: equals the parsed spec (FR-EFN-5)" {
    // Section equivalence.
    {
        var parsed = try parse(testing.allocator, "img.fits[1:512:2,1:512]");
        defer parsed.deinit(testing.allocator);
        var made = try build(testing.allocator, .{
            .path = "img.fits",
            .section = .{ .lower = &.{ 0, 0 }, .upper = &.{ 511, 511 }, .stride = &.{ 2, 1 } },
        });
        defer made.deinit(testing.allocator);
        try testing.expect(parsed.eql(made));
        try testing.expect(made.eql(parsed)); // symmetric
    }
    // HDU-index equivalence.
    {
        var parsed = try parse(testing.allocator, "x.fits[3]");
        defer parsed.deinit(testing.allocator);
        var made = try build(testing.allocator, .{ .path = "x.fits", .hdu_index = 4 });
        defer made.deinit(testing.allocator);
        try testing.expect(parsed.eql(made));
    }
    // EXTNAME,EXTVER equivalence.
    {
        var parsed = try parse(testing.allocator, "x.fits[SCI,2]");
        defer parsed.deinit(testing.allocator);
        var made = try build(testing.allocator, .{ .path = "x.fits", .extname = "SCI", .extver = 2 });
        defer made.deinit(testing.allocator);
        try testing.expect(parsed.eql(made));
    }
    // Open-ended section equivalence.
    {
        var parsed = try parse(testing.allocator, "c.fits[*]");
        defer parsed.deinit(testing.allocator);
        var made = try build(testing.allocator, .{
            .path = "c.fits",
            .section = .{ .lower = &.{0}, .upper = &.{open_end}, .stride = &.{1} },
        });
        defer made.deinit(testing.allocator);
        try testing.expect(parsed.eql(made));
    }
}

test "eql distinguishes differing specs" {
    var a = try build(testing.allocator, .{ .path = "a.fits", .hdu_index = 1 });
    defer a.deinit(testing.allocator);
    var b = try build(testing.allocator, .{ .path = "a.fits", .hdu_index = 2 });
    defer b.deinit(testing.allocator);
    var c = try build(testing.allocator, .{ .path = "b.fits", .hdu_index = 1 });
    defer c.deinit(testing.allocator);
    var d = try build(testing.allocator, .{ .path = "a.fits", .extname = "SCI" });
    defer d.deinit(testing.allocator);

    try testing.expect(!a.eql(b)); // hdu_index differs
    try testing.expect(!a.eql(c)); // path differs
    try testing.expect(!a.eql(d)); // selector kind differs
    try testing.expect(a.eql(a)); // reflexive
}

test "whitespace inside brackets is tolerated" {
    var spec = try parse(testing.allocator, "w.fits[ SCI , 2 ]");
    defer spec.deinit(testing.allocator);
    try testing.expectEqualStrings("SCI", spec.extname.?);
    try testing.expectEqual(@as(?i64, 2), spec.extver);

    var spec2 = try parse(testing.allocator, "w.fits[ 1 : 8 : 2 ]");
    defer spec2.deinit(testing.allocator);
    const sec = spec2.section.?;
    try testing.expectEqualSlices(u64, &.{0}, sec.lower);
    try testing.expectEqualSlices(u64, &.{7}, sec.upper);
    try testing.expectEqualSlices(u64, &.{2}, sec.stride);
}

test "high-rank section up to the FITS axis cap, and over-cap rejection" {
    // 3 axes round-trips cleanly.
    var spec = try parse(testing.allocator, "cube.fits[1:2,1:3,1:4]");
    defer spec.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), spec.section.?.lower.len);

    // Build a 1000-axis section string ("1," * 999 + "1") and expect rejection.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "big.fits[");
    var k: usize = 0;
    while (k < MAX_DIMS + 1) : (k += 1) {
        if (k != 0) try buf.append(testing.allocator, ',');
        try buf.append(testing.allocator, '1');
    }
    try buf.append(testing.allocator, ']');
    try testing.expectError(error.BadSection, parse(testing.allocator, buf.items));
}
