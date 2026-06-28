# zigfitsio — Design

A pure-[Zig](https://ziglang.org) implementation of a FITS (Flexible Image Transport
System) I/O library with feature parity to
[CFITSIO](https://heasarc.gsfc.nasa.gov/docs/software/fitsio/fitsio.html), built with
no C imports or C source.

- **Companion document:** [`requirements.md`](./requirements.md). Every requirement ID
  (`FR-*`, `NFR-*`, `GC-*`) referenced here is defined there.
- **Conformance target:** *Definition of the FITS Standard*, Version 4.0 (2018-08-13).
- **Toolchain:** Zig **0.16.0** (`GC-3`). Standard library only (`GC-2`).
- **Status:** Design baseline, revised per the adversarial review in
  [`design-review.md`](./design-review.md) (4 Majors + all Minors/Nits resolved); the
  highest-risk Zig-API and checksum claims were then validated by execution against
  **Zig 0.16.0** + **CFITSIO 4.6.4** (§16, §23). Section §22 is the
  requirements-traceability matrix; if a requirement is not reachable from that table, the
  design is incomplete.

---

## Table of Contents

1. [Design Goals & Principles](#1-design-goals--principles)
2. [Architectural Overview](#2-architectural-overview)
3. [Source Tree & Module Layout](#3-source-tree--module-layout)
4. [Cross-Cutting: Errors & Diagnostics](#4-cross-cutting-errors--diagnostics)
5. [Cross-Cutting: Memory & Ownership](#5-cross-cutting-memory--ownership)
6. [Cross-Cutting: Numeric Conversion](#6-cross-cutting-numeric-conversion)
7. [Cross-Cutting: Endianness & Limits](#7-cross-cutting-endianness--limits)
8. [I/O Layer: Devices, Streams, Blocks](#8-io-layer-devices-streams-blocks)
9. [Header & Card Model](#9-header--card-model)
10. [HDU Model & File Handle](#10-hdu-model--file-handle)
11. [Images & Primary Array](#11-images--primary-array)
12. [ASCII Tables](#12-ascii-tables)
13. [Binary Tables](#13-binary-tables)
14. [Variable-Length Arrays & Heap](#14-variable-length-arrays--heap)
15. [Random Groups](#15-random-groups)
16. [Checksums: DATASUM & CHECKSUM](#16-checksums-datasum--checksum)
17. [Tiled Compression](#17-tiled-compression)
18. [World Coordinate System](#18-world-coordinate-system)
19. [Utilities, Iterator, Validation](#19-utilities-iterator-validation)
20. [Extended Filenames, Remote, Templates](#20-extended-filenames-remote-templates)
21. [Public API Surface & Examples](#21-public-api-surface--examples)
22. [Requirements Traceability Matrix](#22-requirements-traceability-matrix)
23. [Testing & Fuzzing Strategy](#23-testing--fuzzing-strategy)
24. [Build, Packaging & Portability](#24-build-packaging--portability)
25. [Concurrency & Thread-Safety](#25-concurrency--thread-safety)
26. [Phasing & Milestones](#26-phasing--milestones)
27. [Key Design Decisions & Open Questions](#27-key-design-decisions--open-questions)

---

## 1. Design Goals & Principles

The requirements impose a small number of hard invariants that shape every module. They
are restated here as the rules the design is checked against:

| Principle | Source | Design consequence |
|-----------|--------|--------------------|
| **Idiomatic Zig, not a C transliteration** | `GC-4`, `FR-ERR-2` | Error unions over typed error sets; comptime type parameters instead of integer datatype codes + `anyopaque`; tagged unions for keyword/column values; slices for bulk data. No global status integer. |
| **No C anywhere** | `GC-1`, `GC-2` | No `@cImport`, no C sources, no third-party deps. Compression, byte-shuffle, checksum, WCS math all implemented in Zig. |
| **Big-endian wire, host-neutral** | `GC-5`, `NFR-PORT-2` | A single `endian` module mediates every multi-byte read/write via `@byteSwap`/`std.mem.readInt(..., .big)`. No struct is `@bitCast` directly off disk except through endian-aware helpers. |
| **No UB on hostile input** | `GC-6`, `NFR-SAFE-1` | All declared sizes validated against stream length and `Limits` *before* allocation; parsers return typed errors, never panic. Fuzzed (`NFR-SAFE-2`). |
| **No hidden allocation / no leaks** | `GC-8`, `NFR-MEM-1/2` | Every allocating call takes an `Allocator`; every owning type has `deinit`; the suite runs under `std.testing.allocator`. |
| **Bounded memory, block-aligned** | `NFR-PERF-1/3` | Streaming/chunked data paths; the whole-array convenience calls are thin wrappers over the chunked core, never the other way around. |
| **Freestanding-capable core** | `GC-7`, `NFR-PORT-3` | I/O is a vtable abstraction; the file/stdio/HTTP backends live in leaf modules that the core never imports. The in-memory backend is the freestanding I/O path. |

**Design philosophy.** Three layers, strictly bottom-up in dependency:

1. A **mechanical layer** that knows bytes, blocks, endianness, and conversion but
   nothing about astronomy.
2. A **structural layer** that knows cards, headers, HDUs, and the FITS grammar.
3. A **semantic layer** that knows images, tables, heaps, WCS, compression, checksums.

Each public entry point is a thin, well-documented façade over these layers. Convenience
features (extended filenames, templates) are *strictly* sugar over a programmatic API
that is always sufficient on its own (`FR-EFN-5`, `FR-TPL-2`).

---

## 2. Architectural Overview

```
                         ┌─────────────────────────────────────────────┐
   Public façade  ──────▶│  Fits (file handle) · Hdu · ImageView ·      │
   (root.zig)            │  AsciiTable · BinTable · Wcs · Verifier      │
                         └───────────────┬─────────────────────────────┘
                                         │
        ┌────────────────────────────────┼────────────────────────────────┐
        ▼                                ▼                                  ▼
  ┌───────────┐  ┌──────────────────────────────────────┐   ┌──────────────────────┐
  │  header   │  │  image / table_ascii / table_bin /    │   │  compress (tiled) ·   │
  │  (cards,  │  │  heap (VLA) / groups                  │   │  wcs · checksum ·     │
  │  values)  │  │  — semantic data paths               │   │  validate · iterator  │
  └─────┬─────┘  └──────────────────┬───────────────────┘   └──────────┬───────────┘
        │                           │                                   │
        └───────────────┬──────────┴───────────────┬───────────────────┘
                        ▼                           ▼
                 ┌──────────────┐          ┌──────────────────┐
                 │  convert     │          │  limits · diag   │   ← cross-cutting
                 │  endian      │          │  errors          │
                 └──────┬───────┘          └──────────────────┘
                        ▼
        ┌───────────────────────────────────────────────┐
        │  io: Device (seekable) · Stream (sequential)   │
        │  BlockReader/BlockWriter (2880-aligned cache)  │
        └───────┬───────────────┬───────────────┬────────┘
                ▼               ▼               ▼
        ┌────────────┐  ┌────────────┐  ┌──────────────┐    ← I/O backends (leaf;
        │ file (fs)  │  │ memory buf │  │ stream/gzip/ │      core never imports
        │            │  │            │  │ http         │      OS-backed ones)
        └────────────┘  └────────────┘  └──────────────┘
```

**Dependency rule.** Arrows point in the only legal direction of `@import`. The semantic
layer may use `header`, `convert`, `endian`, `io`; the `io` backends may use `std.fs` /
`std.http` / `std.compress` but nothing above them. `errors` and `limits` import only
`std`; `convert` and `endian` import only `std` plus the leaf `errors` module (for
`ConvError`/`LimitError`), so the graph stays acyclic with `errors` a true leaf. This
keeps `NFR-PORT-3` mechanical: a freestanding build
excludes `io/file.zig`, `io/stream.zig`, `io/http.zig` from the module graph and keeps
`io/memory.zig`.

---

## 3. Source Tree & Module Layout

```
zigfitsio/
├── build.zig                 # static lib + module + test/fuzz/bench steps
├── build.zig.zon             # package manifest (name, version, fingerprint)
├── src/
│   ├── root.zig              # public re-exports; the only file consumers import
│   ├── errors.zig            # all error sets + CFITSIO status mapping (FR-ERR-*)
│   ├── diag.zig              # Diagnostics context (FR-ERR-3)
│   ├── limits.zig            # Limits struct + defaults (NFR-SAFE-1)
│   ├── endian.zig            # big-endian read/write, vectorized byteswap (GC-5)
│   ├── convert.zig           # numeric-conversion policy (FR-CONV-1/2)
│   ├── io/
│   │   ├── device.zig        # Device vtable (seekable pread/pwrite)
│   │   ├── stream.zig        # Stream vtable (sequential) + std adapters
│   │   ├── block.zig         # BlockReader / BlockWriter (2880-aligned cache)
│   │   ├── memory.zig        # in-memory backend (freestanding path)
│   │   ├── file.zig          # std.fs.File backend
│   │   └── http.zig          # std.http range-GET backend (P3)
│   ├── header/
│   │   ├── card.zig          # Card parse/serialize, value FSM
│   │   ├── value.zig         # KeywordValue union, fixed/free formatting
│   │   ├── header.zig        # Header container, index, edit ops
│   │   ├── continue.zig      # CONTINUE long-string assembly/splitting
│   │   ├── hierarch.zig      # HIERARCH name handling (P2)
│   │   └── name.zig          # keyword normalization + wildcard matcher (FR-UTL-4)
│   ├── hdu.zig               # Hdu union, kind detection, required-kw validation
│   ├── fits.zig              # Fits handle: open/create/navigate/close
│   ├── image.zig             # ImageView: pixel/section I/O, scaling, nulls
│   ├── table/
│   │   ├── common.zig        # Column model, TFORM/TDISP parse (FR-UTL-2)
│   │   ├── ascii.zig         # ASCII TABLE
│   │   ├── binary.zig        # BINTABLE
│   │   └── heap.zig          # VLA descriptors + heap manager
│   ├── groups.zig            # random groups (P2)
│   ├── checksum.zig          # DATASUM/CHECKSUM (FR-SUM-*)
│   ├── compress/
│   │   ├── tiled.zig         # tiled-image HDU view (ZIMAGE) read/write
│   │   ├── shuffle.zig       # GZIP_2 byte shuffle + inverse (in-house)
│   │   ├── gzip.zig          # GZIP_1/2 over std.compress.flate
│   │   ├── rice.zig          # RICE_1 (P3)
│   │   ├── plio.zig          # PLIO_1 (P3)
│   │   ├── hcompress.zig     # HCOMPRESS_1 (P3)
│   │   └── dither.zig        # subtractive dithering (P3)
│   ├── wcs/
│   │   ├── keys.zig          # WCS keyword set parse/serialize
│   │   ├── celestial.zig     # projections + spherical rotation
│   │   ├── spectral.zig      # spectral keyword handling
│   │   └── time.zig          # time-coordinate keywords + date/JD helpers
│   ├── iterator.zig          # high-level work-function iterator (FR-ITR-*)
│   ├── validate.zig          # fitsverify-style structural pass (FR-VAL-*)
│   ├── filename.zig          # extended filename grammar + programmatic spec (P3)
│   ├── template.zig          # ASCII header template loader (P3)
│   ├── group_table.zig       # hierarchical grouping tables (P3)
│   └── version.zig           # version string + error-message text (FR-UTL-3)
├── test/                     # integration tests, corpus, cross-validation
│   ├── corpus/               # sample FITS files (images, tables, VLA, compressed)
│   └── fuzz/                  # fuzz harness entry points
└── tools/
    ├── fitsverify.zig        # CLI demo over validate.zig
    └── bench.zig             # throughput benchmarks vs goals (NFR-PERF-1)
```

`root.zig` re-exports the public types and nothing internal (`NFR-API-2`). Internal
fields of `Fits`, `Header`, etc. are not part of the contract.

---

## 4. Cross-Cutting: Errors & Diagnostics

### 4.1 Error sets by area (`FR-ERR-1`, `FR-ERR-2`)

Errors are **narrow, area-scoped sets** that compose with `||`. No public function ever
returns `anyerror`; each returns the union of exactly the sets it can produce. There is
**no integer status parameter and no inherited-status idiom** — `try` and error
propagation provide fail-fast behavior naturally (`FR-ERR-2`).

```zig
// errors.zig
pub const IoError       = error{ EndOfStream, ReadFailed, WriteFailed, SeekFailed,
                                 Unseekable, NotWritable, DeviceFull, BlockMisaligned };
pub const HeaderError   = error{ NonAsciiInHeader, BadKeywordName, BadValueSyntax,
                                 UnterminatedString, MissingEnd, BadContinue,
                                 CardOverflow };
pub const ValueError    = error{ WrongValueType, ValueUndefined, KeywordNotFound };
pub const StructError   = error{ MissingRequiredKeyword, KeywordOrder, BadBitpix,
                                 BadNaxis, BadDimensions, WrongHduType, BadExtension };
pub const TableError    = error{ NoSuchColumn, AmbiguousColumn, BadTform, BadTdim,
                                 BadTbcol, RowOutOfRange, CellOutOfRange, BadDescriptor,
                                 HeapOverflow };
pub const ConvError     = error{ Overflow, PrecisionLoss, NotRepresentable, NanToInt };
pub const ChecksumError = error{ ChecksumMismatch, DatasumMismatch };
pub const CompressError = error{ UnsupportedCodec, CorruptTile, BadTiling,
                                 DataConstraintViolated };
pub const WcsError      = error{ BadWcs, UnsupportedProjection, NonInvertible };
pub const LimitError    = error{ LimitExceeded };

/// The umbrella set, for callers who want one catch-all. Library functions still
/// declare the narrowest set they actually produce.
pub const Error = IoError || HeaderError || ValueError || StructError || TableError ||
                  ConvError || ChecksumError || CompressError || WcsError ||
                  LimitError || std.mem.Allocator.Error;
```

`std.mem.Allocator.Error` (`error{OutOfMemory}`) is folded in wherever allocation occurs,
satisfying `GC-8` ergonomics without hiding the allocation.

### 4.2 CFITSIO status mapping (`FR-ERR-4`)

A pure function maps each error value to the nearest CFITSIO numeric status code, for
tooling that must emit compatible codes. This is a lookup, not a control-flow mechanism:

```zig
pub fn cfitsioStatus(err: Error) c_int { ... }   // e.g. MissingEnd -> 210 (NO_END)
```

### 4.3 Diagnostics context (`FR-ERR-3`)

Because a typed error loses the *where/what*, an **optional** `Diagnostics` object
records human-readable detail for the most recent failure. It is opt-in (a `?*Diagnostics`
threaded into operations, or held on the `Fits` handle), never required, and replaces
CFITSIO's global message stack.

```zig
// diag.zig
pub const Diagnostics = struct {
    last: ?Record = null,
    pub const Record = struct {
        err: Error,
        byte_offset: ?u64 = null,   // where in the stream
        keyword: ?[8]u8 = null,     // which keyword/column
        hdu_index: ?u32 = null,
        // inline fixed-capacity buffer for the offending card text. (std.BoundedArray was
        // removed in Zig 0.15.1; the idiom is now a plain array + length.)
        detail_buf: [160]u8 = undefined,
        detail_len: usize = 0,
    };
    pub fn note(self: *Diagnostics, rec: Record) void { self.last = rec; }
    pub fn render(self: *const Diagnostics, w: *std.Io.Writer) !void { ... }
};
```

Internally, the pattern is `errdefer if (diag) |d| d.note(.{...})` at the throwing site,
so the cost is zero when no `Diagnostics` is supplied. `version.zig` additionally exposes
`errorText(err) []const u8` for a stable message per error value (`FR-UTL-3`).

---

## 5. Cross-Cutting: Memory & Ownership

**Rules** (`GC-8`, `NFR-MEM-1/2`):

- Every allocating function takes `allocator: std.mem.Allocator` explicitly. No module
  holds a hidden/global allocator.
- Every owning type exposes `deinit(self, allocator)` (or `deinit(self)` when it captured
  the allocator at construction — the design captures it on the *top-level* `Fits` handle
  only, and passes it down explicitly elsewhere to keep ownership visible).
- Ownership is documented at each boundary: functions that **return owned memory** are
  named with verbs that imply allocation (`readString`, `dupColumn`, `toOwnedSlice`) and
  document the release path; functions that **borrow** return slices into caller- or
  handle-owned buffers and document the borrow's lifetime.

**Allocation strategy.**

- The `Fits` handle holds a long-lived allocator for structural metadata (the card
  arrays, column descriptors) that lives as long as the handle.
- Bulk pixel/column transfers write into **caller-provided slices** — the library does
  not allocate the big buffers (`NFR-PERF-3`); the caller controls chunk size.
- Where a transient working buffer is unavoidable (e.g. a decompression tile, a
  CONTINUE reassembly), an internal **arena** scoped to that operation is used and freed
  on return, so partial failure cannot leak.
- Header reads that must return variable-length owned data (string values, comment text)
  allocate from the supplied allocator and are released by the value's `deinit` or by the
  owning `Header.deinit`.

The test suite runs under `std.testing.allocator`; any leak fails the test (`NFR-MEM-2`).
`errdefer` is used pervasively so that a failure mid-construction frees everything
already acquired.

---

## 6. Cross-Cutting: Numeric Conversion

`convert.zig` is the **single** implementation of the conversion policy (`FR-CONV-1/2`);
every site that crosses a type boundary calls it, so the policy is defined once and cited
by `FR-HDR-13`, `FR-IMG-9`, `FR-ATB-4`, `FR-BTB-5`.

```zig
pub const Mode = enum {
    scalar, // keyword reads & single cells: precision loss is an error
    bulk,   // array/column transfers: precision-losing widening is silently allowed
};

/// Convert `src` (any int/float) to `Dst` (any int/float) under the policy.
pub fn cast(comptime Dst: type, src: anytype, mode: Mode) ConvError!Dst { ... }
```

Policy, enforced **before** any truncation or wraparound (`FR-CONV-2`, no UB):

| Case | Rule |
|------|------|
| int→int, float→int out of `Dst` range | `error.Overflow` (range checked first). |
| float→int rounding | **round half away from zero** (`@round`; the `FR-CONV-1(b)` rule). Differs from CFITSIO's `(int)(x±0.5)` only within ~0.5 ULP of a half — see note. NaN→int is `error.NanToInt`. |
| precision-losing widening (`i64`/`u64`→`f64`, etc.) | **scalar mode:** `error.PrecisionLoss` if the value isn't exactly representable. **bulk mode:** allowed silently. |
| same type / lossless widening | direct. |

Implementation notes: range checks use comptime `std.math.maxInt/minInt` of `Dst`;
round-half-away-from-zero is `@round` (which rounds halves away from zero) followed by a
checked cast; exact-representability for the scalar float case is verified by round-trip
(`@as(f64, v)` back to the integer compares equal). All branches are `comptime`-specialized
on `Dst`/`@TypeOf(src)` so the hot path is branch-free per call site (`NFR-PERF-2`).
CFITSIO truncates `x ± 0.5` (which double-rounds near half-integers); `zigfitsio`'s `@round`
is the exact round-half-away-from-zero variant, so the two agree except for a float within
~0.5 ULP of *N*.5 (vanishingly rare in real data). If byte-exact CFITSIO cross-validation
is ever required, the conversion site replicates the `(x ± 0.5)` idiom; either way the
per-site choice is documented at the call, per `FR-CONV-1`.

---

## 7. Cross-Cutting: Endianness & Limits

### 7.1 Endianness (`GC-5`, `NFR-PORT-2`, `NFR-PERF-2`)

All wire values are big-endian. `endian.zig` is the only place that knows this:

```zig
pub inline fn read(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return @bitCast(std.mem.readInt(IntOf(T), bytes, .big)); // floats via their int repr
}
pub inline fn write(comptime T: type, v: T, out: *[@sizeOf(T)]u8) void { ... }

/// Vectorized in-place swap of a big-endian buffer to native, used by bulk paths.
pub fn swapToNative(comptime T: type, items: []T) void {
    if (native_endian == .big or @sizeOf(T) == 1) return;
    // @Vector batches of @byteSwap; tail handled scalar. No per-element allocation.
}
```

Floats are swapped through their same-width integer representation (IEEE 754 byte order
follows the integer byte order), never by arithmetic. Bulk transfers swap **in place** in
the caller's slice after a block read, so byte-swapping costs one vectorized pass and zero
allocation (`NFR-PERF-2`).

### 7.2 Resource limits (`NFR-SAFE-1`)

A `Limits` struct carries documented defaults and is overridable per handle. **Before any
allocation**, declared sizes are validated against both these limits and the actual stream
length.

```zig
pub const Limits = struct {
    max_header_blocks: u32   = 1 << 14,        // 16384 blocks ≈ 460k cards
    max_hdu_count:     u32   = 100_000,
    max_naxis_product: u64   = 1 << 40,        // pixels; guards NAXISn overflow
    max_heap_bytes:    u64   = 1 << 34,        // PCOUNT ceiling
    max_vla_elems:     u64   = 1 << 30,        // single descriptor length
    max_string_value:  u32   = 1 << 20,        // assembled CONTINUE length
    max_tile_bytes:    u64   = 1 << 30,
    max_open_alloc:    u64   = 1 << 32,        // single-call allocation ceiling
    max_matches:       u32   = 4096,           // runtime ceiling for a wildcard Matches; must be ≤ name.MAX_MATCHES (the comptime inline capacity, §19.1)
};
```

The size-validation helper is used uniformly: compute the declared size with **checked**
arithmetic (`std.math.mul`/`add` returning `error.Overflow` → mapped to
`error.LimitExceeded` or `BadDimensions`), compare against `Limits` and against
`device.getSize()`, and only then allocate. This is the concrete mechanism behind
"validated before allocation" in `NFR-SAFE-1` and is exercised directly by the fuzzers.

---

## 8. I/O Layer: Devices, Streams, Blocks

### 8.1 Two capabilities, two interfaces (`FR-IO-3`)

FITS editing requires random access, but some sources (stdin, a plain HTTP body, a gzip
stream) are sequential-only. Rather than fake `seek` everywhere, the design exposes two
small vtable interfaces and a documented capability boundary:

```zig
// io/device.zig — seekable, position-explicit (pread/pwrite style)
pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        pread:   *const fn (*anyopaque, buf: []u8,       offset: u64) IoError!usize,
        pwrite:  ?*const fn (*anyopaque, buf: []const u8, offset: u64) IoError!usize, // null ⇒ read-only
        getSize: *const fn (*anyopaque) IoError!u64,
        setSize: ?*const fn (*anyopaque, u64) IoError!void, // grow/truncate
        sync:    *const fn (*anyopaque) IoError!void,
        close:   *const fn (*anyopaque) void,
    };
    // thin methods forwarding to vtable, asserting full reads/writes
};

// io/stream.zig — sequential only: free functions over std.Io.Reader/Writer, no struct.
// e.g. materialize(reader)→[]u8, drainAll(writer, bytes), and the gzip helpers
// materializeGzip / compressToGzip / inflateGzipToDevice / compressDeviceToGzip.
pub fn materialize(alloc: Allocator, reader: *std.Io.Reader, max_bytes: u64) ![]u8 { ... }
pub fn drainAll(writer: *std.Io.Writer, bytes: []const u8) IoError!void { ... }
```

**Why position-explicit (pread/pwrite) rather than stateful seek+read?** It makes random
access the natural case (the image/table paths compute a byte offset and read it directly),
removes hidden seek state, and lets the memory backend be a trivial `@memcpy`. It is also
the friendliest shape for concurrent reads of distinct ranges from one file
(`NFR-CONC-1`).

**Backends:**

| Backend | File | Capability | Notes |
|---------|------|-----------|-------|
| memory | `io/memory.zig` | `Device` (r/w, growable) | `[]u8` or `ArrayList`-backed; the **freestanding/WASM** path (`NFR-PORT-3`); also the in-memory buffer of `FR-RMT-1`. |
| file | `io/file.zig` | `Device` (r/w) | wraps `std.Io.File` (`readPositionalAll`/`writePositionalAll`/`length`/`setLength`) driven by a `std.Io.Threaded` implementation; 64-bit offsets (`FR-IO-6`). |
| stream | `io/stream.zig` | free functions over `std.Io.Reader`/`Writer` | stdin/stdout (`FR-RMT-1`); also the output side of whole-file gzip. |
| gzip-file | `io/stream.zig` + `std.compress.flate` | `Stream` in, materialize to `Device` | `.fits.gz` (`FR-RMT-2`): decompress into a memory `Device` for random access; compress on flush. |
| http | `io/http.zig` | `Device` (read-only) via Range GET | `std.http` (TLS 1.3 only); falls back to full download into memory `Device` if server lacks range support (`FR-RMT-3`). |

A `Stream`-only source that the higher layers need to seek over is **materialized** into a
memory `Device` (documented cost). This keeps the seekable code paths uniform and is how
gzip/stdin reads gain random access.

### 8.2 Block model & buffering (`FR-IO-1/2/4`)

FITS is a sequence of 2880-byte logical blocks. `io/block.zig` provides a cache over a
`Device` that reads/writes in **multiples of 2880** (default 64 KiB = 22.75 blocks rounded
to a block multiple, i.e. a 23×2880 = 66240-byte window) so that header scanning never
issues a syscall per card (`FR-IO-4`) and bulk data is block-aligned (`NFR-PERF-1`).

```zig
pub const BlockReader = struct {
    dev: Device, window: []u8, window_off: u64, valid: usize, alloc: Allocator,
    pub fn cardAt(self: *BlockReader, idx: u64) IoError!*const [80]u8 { ... }
    pub fn bytes(self: *BlockReader, off: u64, into: []u8) IoError!void { ... }
};
pub const BlockWriter = struct {
    // accumulates whole blocks; pad() fills the final partial block then flushes.
    pub fn pad(self: *BlockWriter, fill: enum { space, zero }) IoError!void { ... }
};
```

Padding rule (`FR-IO-2`): header units pad with ASCII space `0x20`; data units pad with
**zero** bytes, except ASCII-table data which pads with ASCII space. `pad()` takes the
fill kind so the data path picks the correct one. In-place edit mode (`FR-IO-5`) writes
only the touched blocks back through `pwrite`, preserving surrounding structure and
64-bit offsets throughout (`FR-IO-6`).

---

## 9. Header & Card Model

### 9.1 Card (`FR-HDR-1/2`)

A card is exactly 80 bytes of printable ASCII (`0x20`–`0x7E`); any control character is
`error.NonAsciiInHeader`. Layout: name in bytes 1–8, optional value indicator `= ` in
bytes 9–10, value/comment in 11–80.

```zig
// header/card.zig
pub const Card = struct {
    raw: [80]u8,            // canonical on-disk bytes; round-trip source of truth
    name: Name,             // normalized (upper, ≤8) or HIERARCH long name
    kind: Kind,
    pub const Kind = enum { value, commentary, blank, end, continuation };
};
```

The single most error-prone rule in the format is "is this a value card?" The design
encodes `FR-HDR-6` **exactly**: a card is a *value* card **iff** bytes 9–10 are `= `
(`0x3D 0x20`) **and** the name is not a commentary keyword (`COMMENT`, `HISTORY`, blank).
Anything else — no indicator, or a commentary name even with `= ` present — is commentary
with free text in bytes 9–80 and is **preserved, never rejected**.

```zig
fn classify(name: Name, b9: u8, b10: u8) Card.Kind {
    if (name.isEnd()) return .end;
    if (name.isContinue()) return .continuation;         // CONTINUE long-string card
    if (name.isCommentaryName()) return .commentary;     // COMMENT/HISTORY/blank
    if (b9 == '=' and b10 == ' ') return .value;
    if (name.isBlank()) return .blank;
    return .commentary;
}
```

### 9.2 Value parsing & the undefined/empty/null distinction (`FR-HDR-3/4`)

`value.zig` parses the value field with a small state machine that accepts **both**
fixed-format and free-format on read (`FR-HDR-4`), and produces the tagged value:

```zig
pub const KeywordValue = union(enum) {
    int: i64,
    float: f64,
    complex_int: [2]i64,
    complex_float: [2]f64,
    logical: bool,
    string: []const u8,   // allocator-owned; '' un-escaped; trailing blanks trimmed
    undefined,            // indicator present, value field blank
};
```

The three-way distinction required by `FR-HDR-3` is represented at the API boundary, not
just internally:

| On-disk | Parsed result | Read-API result |
|---------|---------------|-----------------|
| keyword absent | — | `error.KeywordNotFound` (or `?T` = `null`) — the **null** case |
| `= ''` | `.string` with `len == 0` | empty string |
| `= ` then blanks | `.undefined` | `error.ValueUndefined` (or a `.undefined` tag for the union accessor) |

String parsing handles the `''`→`'` escape and the standard trailing-blank rule (trailing
spaces inside the quotes are not significant, except a single all-blank `' '` denotes one
space). Mandatory keywords are **written** fixed-format (`FR-HDR-4`); free-format is
read-only-tolerant. Round-tripping preserves the original `raw` bytes when a card is read
and not modified (`FR-HDR-5`), so comments and formatting survive unless the caller edits
the value.

### 9.3 CONTINUE, HIERARCH, units (`FR-HDR-8/9/10`)

- **CONTINUE** (`FR-HDR-8`): wired into the `Header` long-string API. On read,
  `Header.getLongString` assembles a string value whose card ends with `&` across the
  following `CONTINUE` cards into one logical owned string (bounded by
  `Limits.max_string_value`). On write, `Header.appendLongString` uses `continue.zig` to
  split a >68-char string back into a primary card + `CONTINUE` cards. The raw cards remain
  available for byte-exact round-trip.
- **HIERARCH** (`FR-HDR-9`, P2): `hierarch.zig` parses `HIERARCH a b c = val` long/hierarchical
  names. `Name` carries an optional long form; lookups accept either the HIERARCH spelling
  or the spaced token form.
- **Units** (`FR-HDR-10`, P2): the `[unit]` leading-comment convention is parsed into an
  optional `units: ?[]const u8` accessor without disturbing the comment text.

### 9.4 Header container, lookups, edits (`FR-HDR-7/11/12`)

```zig
// header/header.zig
pub const Header = struct {
    cards: std.ArrayList(Card) = .empty,        // ordered; round-trip fidelity; lookups linear-scan it
    inherit: ?*const Header = null,                      // INHERIT fall-through (FR-HDR-14)

    // read
    pub fn get(self, name: []const u8) ValueError!*const Card;
    pub fn getValue(self, comptime T: type, name: []const u8) (ValueError||ConvError)!T;
    pub fn getLongString(self, a: Allocator, name: []const u8) ![]u8; // assembles CONTINUE (FR-HDR-8)
    pub fn at(self, n: usize) *const Card;               // nth card (FR-HDR-11)
    pub fn find(self, pattern: []const u8, out: *Matches) void;  // wildcards; sets out.overflow if truncated
    // write
    pub fn append(self, a: Allocator, c: Card) !void;
    pub fn appendLongString(self, a: Allocator, name: []const u8, str: []const u8, comment: ?[]const u8) !void; // splits to CONTINUE (FR-HDR-8)
    pub fn update(self, a: Allocator, name: []const u8, v: KeywordValue, comment: ?[]const u8) !void; // create-if-absent
    pub fn insert(self, a: Allocator, at: usize, c: Card) !void;
    pub fn delete(self, name: []const u8) ValueError!void;
    pub fn rename(self, old: []const u8, new: []const u8) ValueError!void;
    pub fn reserveSpace(self, a: Allocator, n_blank: usize) !void;  // header-space pre-alloc (FR-HDR-12)
};
```

`END` is mandatory: the scanner reads cards until it finds the `END` card; a header that
reaches its block budget without one is `error.MissingEnd` (`FR-HDR-7`). Lookups are a
case-insensitive **linear scan** of the (typically small) ordered card list — no separate
name index — which keeps the model simple and serialization order authoritative. Numeric reads go through
`convert.cast(T, …, .scalar)` (`FR-HDR-13`). Header-space pre-allocation
(`reserveSpace`, `FR-HDR-12`) appends blank cards before `END` so later `update` calls can
fill them in place without rewriting following HDUs.

**INHERIT** (`FR-HDR-14`, P2) is **opt-in** and **read-only in effect**: when enabled, a
miss on an extension header falls through to `inherit` (the primary header), **excluding**
the structural keywords (`XTENSION/BITPIX/NAXIS/NAXISn/PCOUNT/GCOUNT/TFIELDS/EXTEND/END`).
It never changes bytes written.

---

## 10. HDU Model & File Handle

### 10.1 HDU (`FR-HDU-1/2/5`)

```zig
// hdu.zig
pub const HduKind = enum { primary, image, ascii_table, binary_table, random_groups };

pub const Hdu = struct {
    kind: HduKind,
    header: Header,
    header_off: u64,      // block offset of this HDU's first card
    data_off: u64,        // block offset of the data unit
    data_bytes: u64,      // logical data length (pre-padding; checksums use the padded length, §16)
    // typed views; each validates the kind and required keywords first
    pub fn image(self: *Hdu, fits: *Fits) StructError!ImageView;
    pub fn asciiTable(self: *Hdu, fits: *Fits) StructError!AsciiTable;
    pub fn binTable(self: *Hdu, fits: *Fits) StructError!BinTable;
    pub fn group(self: *Hdu, fits: *Fits) StructError!RandomGroups;
};
```

Kind detection: HDU 1 with `SIMPLE=T` is `primary` (or `random_groups` if `NAXIS1=0` and
`GROUPS=T`); extensions dispatch on `XTENSION` ∈ {`IMAGE`, `TABLE`, `BINTABLE`}. A
compressed image (`BINTABLE` with `ZIMAGE=T`) is recognized by the tiled-compression layer
and presented as an image view (§17), but its underlying kind remains `binary_table` for
validation.

### 10.2 Required-keyword validation (`FR-HDU-5/6`)

When an HDU is **finalized/written**, `hdu.zig` enforces the mandatory keyword set and
order for its kind:

- Primary: `SIMPLE` first, then `BITPIX`, `NAXIS`, `NAXIS1..NAXISn`.
- Extension: `XTENSION` first, then `BITPIX`, `NAXIS`, `NAXISn`, `PCOUNT`, `GCOUNT`, then
  `TFIELDS` for tables.

Critically, per `FR-HDU-6`, **`EXTEND` is advisory**: it is *written* (after the last
`NAXISn`, or after `NAXIS` when `NAXIS=0`) when extensions are present, but a missing or
non-adjacent `EXTEND` is **never** flagged by validation (`FR-HDU-5`/`FR-VAL-1`).

### 10.3 File handle & navigation (`FR-HDU-1/3/4`, `FR-IO-5`)

```zig
// fits.zig
pub const Mode = enum { read_only, read_write, create };

pub const Fits = struct {
    alloc: Allocator,
    dev: Device,
    mode: Mode,
    limits: Limits,
    diag: ?*Diagnostics,
    hdus: std.ArrayList(*Hdu),           // lazily scanned; each *Hdu is individually
                                         // allocated, so the pointer a view holds stays
                                         // valid as this list grows/reallocates
    chdu: usize,                         // current-HDU index (renamed from `current` to
                                         // avoid a field/method name collision)

    pub fn open(a: Allocator, dev: Device, mode: Mode, opts: OpenOpts) !Fits;
    pub fn create(a: Allocator, dev: Device, opts: OpenOpts) !Fits;
    pub fn deinit(self: *Fits) void;

    pub fn hduCount(self: *Fits) !usize;                 // FR-HDU-1
    pub fn select(self: *Fits, n: usize) !*Hdu;          // absolute (1-based)
    pub fn move(self: *Fits, delta: isize) !*Hdu;        // relative
    pub fn selectByName(self: *Fits, extname: []const u8, extver: ?i64) !*Hdu; // FR-HDU-3
    pub fn current(self: *Fits) *Hdu;                    // the CHDU (returns hdus.items[chdu])

    pub fn appendHdu(self: *Fits, spec: HduSpec) !*Hdu;  // create/append (FR-HDU-4)
    pub fn copyHdu(self: *Fits, src: *Hdu, what: enum { header, header_data }) !*Hdu;
    pub fn deleteHdu(self: *Fits, n: usize) !void;
    pub fn flush(self: *Fits) !void;
};
```

HDUs are **scanned lazily**: opening parses HDU 1's header and records its data extent,
then computes the next HDU offset (header blocks + ⌈data/2880⌉ blocks) and stops; further
HDUs are parsed on demand as the caller navigates, so opening a many-HDU file is cheap and
bounded; because each `Hdu` is individually allocated, a `*Hdu` held by a live view stays
valid as the `hdus` list grows and reallocates — a view remains usable until its handle is
closed or its own HDU is deleted (documented per-view, §11.1). Navigation sets the CHDU.
Structural edits (`appendHdu`, `deleteHdu`) maintain
block alignment and the primary/extension invariant (only HDU 1 is primary), rewriting
following blocks only when an in-place edit cannot absorb the change. Read-write vs
read-only vs create is the `Mode` (`FR-IO-5`); a read-only `Device` (null `pwrite`) makes
write operations `error.NotWritable`.

---

## 11. Images & Primary Array

### 11.1 Type model (`FR-IMG-1/2/9`)

`BITPIX` maps to a stored Zig type; the *physical* type the caller reads/writes is chosen
by a comptime parameter, with `convert` bridging the two (`FR-IMG-9`).

| BITPIX | stored | | BITPIX | stored |
|------:|--------|---|------:|--------|
| 8 | `u8` | | −32 | `f32` |
| 16 | `i16` | | −64 | `f64` |
| 32 | `i32` | | | |
| 64 | `i64` | | | |

```zig
// image.zig
pub const ImageView = struct {
    fits: *Fits, hdu: *Hdu,                       // a thin delegating view; *Hdu is stable
                                                  // (individually allocated, §10.3) — valid
                                                  // until close or HDU delete
    pub fn of(fits: *Fits, hdu: *Hdu) StructError!ImageView; // also resolves a tiled-compressed
                                                  // BINTABLE to a transparent compressed-image view (§17)
    pub fn bitpix(self) i64;                       // structural keywords read on demand from hdu.header
    pub fn dims(self) []const u64;                 // per-axis sizes, NAXIS 0..999 (FR-IMG-2/9)
    pub fn elementCount(self) u64;                 // product of dims()
};
```

`NAXIS` ranges 0–999 with the per-axis `NAXISn`; the pixel-count product is computed with
checked arithmetic against `Limits.max_naxis_product` (`FR-IMG-2`, `NFR-SAFE-1`).

### 11.2 Pixel access (`FR-IMG-3/4`)

Three layered operations, all comptime-typed in the caller's element type `T`:

```zig
// whole array
pub fn readAll(self: *ImageView, comptime T: type, out: []T, opts: ReadOpts(T)) !void;
// contiguous run of N pixels from an N-D start coordinate (FR-IMG-3)
pub fn readPixels(self: *ImageView, comptime T: type, first: []const u64, out: []T, opts: ReadOpts(T)) !void;
// rectangular section with optional per-axis stride (FR-IMG-4)
pub fn readSection(self: *ImageView, comptime T: type,
                   lower: []const u64, upper: []const u64, stride: ?[]const u64,
                   out: []T, opts: ReadOpts(T)) !void;
// symmetric writers: writeAll / writePixels / writeSection
```

`readAll`/`readPixels` are the contiguous fast path: compute the byte offset of `first`,
read block-aligned chunks into a scratch window, byte-swap in place (`endian.swapToNative`),
apply scaling/null substitution, and `convert.cast` into `out` — all in bounded memory,
streaming chunk by chunk (`NFR-PERF-1/3`). `readSection` walks the rectangular region one
contiguous innermost row at a time (honoring `stride`), reusing the same chunk machinery.
The convenience whole-array calls are wrappers over the chunked core, never vice-versa.

### 11.3 Scaling, unsigned & signed-byte conventions (`FR-IMG-5/6/7`)

```zig
pub const Scaling = struct {
    bscale: f64 = 1, bzero: f64 = 0,
    blank: ?i64 = null,                 // integer null sentinel (raw, pre-scale)
    mode: enum { apply, raw } = .apply, // FR-IMG-5 disable switch
};
```

`physical = BZERO + BSCALE × stored`, applied transparently on read and inverted on write
(`FR-IMG-5`); `mode = .raw` exposes stored values unscaled. The **unsigned-int convention**
(`FR-IMG-6`) is the special case `BSCALE=1`, `BZERO=2^15/2^31/2^63` for BITPIX 16/32/64; the
design recognizes it and lets the caller read/write `u16`/`u32`/`u64` directly, doing the
offset in integer space to avoid `f64` precision loss at the 2^63 boundary. The
**signed-byte convention** (`FR-IMG-7`, P2) is BITPIX 8 with `BZERO=−128`, read/written as
`i8`.

### 11.4 Null handling (`FR-IMG-8`)

The rule is precise and the design follows it literally: on read, the **raw stored** value
(before BSCALE/BZERO) is compared against `BLANK`; matches are replaced with a
caller-provided null sentinel (passed unscaled). On write, sentinel elements are stored as
the raw `BLANK`. For floating data, *any* NaN is recognized as null on read, and the
emitted null is a **single documented quiet-NaN bit pattern** exported as
`image.fits_nan_f32`/`fits_nan_f64`; the exact constant is pinned during implementation to
match CFITSIO's emitted null (`FR-IMG-8` recommends, but does not mandate, byte-for-byte
agreement, since any NaN reads back as null).

```zig
// Element-typed so the null sentinel cannot mismatch the read type `T` (it is checked at
// the call site, not via a runtime union).
pub fn ReadOpts(comptime T: type) type {
    return struct { null_sentinel: ?T = null, scaling: ?Scaling = null };
}
```

### 11.5 Resize/redefine (`FR-IMG-10`, P2)

`reshape(bitpix, axes)` rewrites the structural keywords and adjusts the data unit; when
the new data size differs, following HDUs are shifted with block re-alignment. Supported
as a P2 convenience over the primitive header-edit + data-rewrite operations.

---

## 12. ASCII Tables

### 12.1 Structure (`FR-ATB-1/2`)

`XTENSION='TABLE'`, `BITPIX=8`, `NAXIS=2`, `NAXIS1`=row width in bytes, `NAXIS2`=row count,
`PCOUNT=0`, `GCOUNT=1`, `TFIELDS`. Each column carries `TBCOLn` (1-based byte start),
`TFORMn` ∈ {`Aw`, `Iw`, `Fw.d`, `Ew.d`, `Dw.d`}, and optional `TTYPEn`, `TUNITn`,
`TSCALn`, `TZEROn`, `TNULLn` (a null *string*).

```zig
// table/ascii.zig
pub const AsciiColumn = struct {
    index: u16, name: ?[]const u8,
    tbcol: u64, width: u16, dtype: AsciiType, decimals: u8,
    unit: ?[]const u8, tscal: f64, tzero: f64, tnull: ?[]const u8,
};
```

### 12.2 Field formatting & values (`FR-ATB-3/4`)

ASCII tables store every field as fixed-width FORTRAN-style text. `table/common.zig` owns
the formatter/parser shared with `TDISP` (`FR-UTL-2/5`):

- **Read:** slice the field `[TBCOLn-1, TBCOLn-1+width)`, trim per format, parse to the
  stored numeric/string; a field equal to `TNULLn` (or all-blank) is a null
  (`FR-ATB-3`). Apply `TSCALn`/`TZEROn`, then `convert.cast(T, …)` (`FR-ATB-4`).
- **Write:** inverse — scale out, format to exactly `width` columns with `decimals`,
  right-justified for numerics, NUL/space rules for `Aw`; overflow of the field width is a
  typed error, not silent truncation.

Column position helpers (compute/validate `TBCOLn` against `NAXIS1`) are exposed per
`FR-UTL-2`. Note `NAXIS1` MAY exceed the field extent (gaps are legal); validation checks
each `TBCOLn`+width fits within `NAXIS1` (`FR-VAL-1`).

---

## 13. Binary Tables

### 13.1 Structure & TFORM codes (`FR-BTB-1/2`)

`XTENSION='BINTABLE'`, `BITPIX=8`, `NAXIS=2`, `NAXIS1`=row byte width, `NAXIS2`=rows,
`PCOUNT`=heap size, `GCOUNT=1`, `TFIELDS`. Every standard `TFORMn = rT` code is supported
with its repeat count `r` (including `r=0`, accepted):

| Code | type | elem | Code | type | elem |
|------|------|------|------|------|------|
| `L` | logical | `bool` | `A` | char | `u8`/string |
| `X` | bit | packed → `u1`/`[]u8` | `E` | f32 | `f32` |
| `B` | u8 | `u8` | `D` | f64 | `f64` |
| `I` | i16 | `i16` | `C` | complex f32 | `[2]f32` |
| `J` | i32 | `i32` | `M` | complex f64 | `[2]f64` |
| `K` | i64 | `i64` | `P`/`Q` | array descriptor | §14 |

```zig
// table/binary.zig
pub const BinColumn = struct {
    index: u16, name: ?[]const u8,
    code: TformCode, repeat: u64, byte_offset: u64, // offset within a row
    elem_bytes: u16, tdim: ?[]const u64,            // TDIMn reshape (FR-BTB-3)
    scal: Scaling, tnull: ?i64, unit: ?[]const u8,
    vla: ?VlaSpec,                                   // set for P/Q (§14)
};
```

`X` (bit) columns pack/unpack MSB-first into bytes. `TDIMn` (`FR-BTB-3`) reshapes a field's
repeat count into an N-D array (`(w,h,…)` parsing, product must equal `repeat`).

### 13.2 Scaling, nulls, unsigned/signed codes (`FR-BTB-4`)

Per-column `TSCALn`/`TZEROn` scaling and `TNULLn` integer nulls; IEEE NaN for floating
nulls using the same documented pattern as `FR-IMG-8`. The CFITSIO unsigned/signed
extension codes are modeled as base codes plus a `TZEROn` offset, surfaced as the natural
Zig unsigned/`i8` types:

| Surfaced | Stored as | TZERO |
|----------|-----------|-------|
| `u16` (`U`) | `I` | 32768 |
| `u32` (`V`) | `J` | 2147483648 |
| `u64` (`W`) | `K` | 2^63 |
| `i8` (`S`) | `B` | −128 |

### 13.3 Column/row access & A-format (`FR-BTB-5/6/7`)

```zig
pub const ColumnRef = union(enum) { index: u16, name: []const u8 };

pub fn columnByName(self: *BinTable, pat: []const u8, out: *Matches) void; // FR-UTL-4 contract
pub fn readColumn(self: *BinTable, comptime T: type, col: ColumnRef,
                  first_row: u64, out: []T, opts: CellOpts) !void;
pub fn readCell(self: *BinTable, comptime T: type, col: ColumnRef, row: u64, out: []T, opts: CellOpts) !void;
// writeColumn / writeCell symmetric
// row ops (FR-BTB-6):
pub fn appendRows(self, n: u64) !void;
pub fn insertRows(self, at: u64, n: u64) !void;
pub fn deleteRows(self, at: u64, n: u64) !void;
pub fn copyRows(self, dst: *BinTable, src_first: u64, n: u64) !void;
// column ops (FR-BTB-6): insertColumn / appendColumn / deleteColumn / copyColumn
```

Column lookup is case-insensitive with the `*`/`?`/`#` wildcards and the **explicit
multi-match contract** of `FR-UTL-4` (zero → `error.NoSuchColumn`; one → that column;
many → the ordered `Matches` list) — never the CFITSIO status-iteration idiom.

`A`-format semantics (`FR-BTB-7`) are defined precisely: within the repeat count, decode
terminates at the first ASCII NUL; encode pads with spaces (NUL also accepted) up to the
width; a leading NUL is a null string. Arrays-of-strings come from `TDIMn` (§13.1) and heap
strings from `rPA`/`rQA` (§14). The non-standard CFITSIO `rAw` substring shorthand is
**out of scope** (requirements §7.1).

### 13.4 Row buffering & MultiArrayList

Row data is read in block-aligned spans of whole rows into a scratch window; columnar
extraction strides across rows in that window. A `std.MultiArrayList`-backed row staging
buffer for column-wise builders is a **future** convenience — it is **not implemented**
(no `MultiArrayList` is used today); variable-length payloads are handled separately by the
heap manager in `table/heap.zig` (§14).

---

## 14. Variable-Length Arrays & Heap

### 14.1 Descriptors (`FR-VLA-1`)

`P`/`Q` columns store a descriptor in the row and the payload in the heap after the main
table. The leading repeat `r` on a `P`/`Q` field must be absent, `0`, or `1`; anything else
is `error.BadTform` (`FR-VLA-1`).

```zig
// table/heap.zig
pub const Descriptor = struct { len: i64, off: i64 };   // signed two's-complement
pub const VlaSpec = struct { elem: TformCode, width: enum { p32, q64 }, emax: ?u64 };
```

Descriptors are **signed** (`P`: two `i32`, `Q`: two `i64`); a **negative length or offset
is rejected** (`error.BadDescriptor`). The offset is measured from the **heap start**
(`THEAP`), so `off + len*elem_bytes` is bounds-checked against the **heap size**
`PCOUNT − (THEAP − NAXIS1×NAXIS2)` — **not** `PCOUNT`, which when a gap is present would
admit a read up to the gap length past the data unit — and the resulting absolute file
offset is additionally verified to lie within the data unit (`FR-VLA-2`, `NFR-SAFE-1`).

### 14.2 Heap geometry (`FR-VLA-2`)

`PCOUNT` = total supplemental length = (`THEAP` − `NAXIS1`×`NAXIS2`) gap + heap data.
`THEAP` is honored; absent, it defaults to `NAXIS1`×`NAXIS2`, which is also its **minimum
legal** value (smaller → `error.BadTbcol`/structural error). All of these are validated
with checked arithmetic against `Limits.max_heap_bytes` and the device length **before**
any heap allocation (`NFR-SAFE-1`).

### 14.3 Read/write & compaction (`FR-VLA-3/4`)

Reading a VLA cell follows the descriptor into the heap, applies datatype conversion and
scaling exactly as for fixed columns (`FR-VLA-3`), returning an owned slice. The
`HeapManager` tracks allocation within the heap; on rewrite it reuses freed extents and
supports **compaction** so repeatedly rewritten cells do not grow the heap unboundedly
(`FR-VLA-4`):

```zig
pub const HeapManager = struct {
    free: std.ArrayList(Extent),
    pub fn alloc(self, bytes: u64) TableError!u64;       // returns heap offset
    pub fn free(self, off: u64, bytes: u64) void;
    pub fn compact(self, table: *BinTable) !void;        // rewrites descriptors
};
```

---

## 15. Random Groups (P2)

`groups.zig` reads the random-groups structure: `SIMPLE=T`, `BITPIX`, `NAXIS`, `NAXIS1=0`,
`NAXIS2…NAXISn`, `GROUPS=T`, `PCOUNT`, `GCOUNT` in the FITS 4.0 §6 order with **no keywords
intervening** between `SIMPLE` and the last `NAXISn` (`FR-RG-1`), plus reserved
`PTYPEn`/`PSCALn`/`PZEROn`. Each group is `PCOUNT` parameters followed by the group's data
array; parameters and array are accessed with `PSCALn`/`PZEROn` (and `BSCALE`/`BZERO`)
scaling applied (`FR-RG-2`). Writing is supported as a `MAY` (the format is deprecated for
new files), routed through the same block/scaling machinery.

---

## 16. Checksums: DATASUM & CHECKSUM

`checksum.zig` implements the standard 1's-complement checksum (`FR-SUM-1/2/3`):

- **`DATASUM`** = 32-bit 1's-complement sum over the **whole padded data unit** — through
  the 2880-byte block boundary, **including the trailing fill**. The fill is zero for
  images/binary tables (no effect) but ASCII space `0x20` for ASCII-table data (`FR-IO-2`,
  §8.2); space is non-zero and **must be summed**, or the result disagrees with
  CFITSIO/Astropy for every ASCII table. Written as an **unsigned decimal character string**
  in a **string-valued keyword card** — value indicator `= ` in cols 9–10, single-quoted
  value (e.g. `DATASUM = '2503531142'`) — **not** a commentary card.
- **`CHECKSUM`** = the whole-HDU (header + padded data) 1's-complement checksum encoded in
  the standard 16-character ASCII form (the Seaman–Pence alphabet/encoding), chosen so the
  accumulated sum of the complete HDU is all-ones. It too is a **string-valued keyword**,
  written in **fixed format** with the quotes in **columns 11–28**, because the card's own
  byte placement is part of the accumulated checksum.

```zig
pub fn datasum(fits: *Fits, hdu: *Hdu) IoError!u32;          // sums the padded data unit, fill included
pub fn encodeChecksum(value: u32, out: *[16]u8) void;        // ASCII form
pub fn decodeChecksum(card16: *const [16]u8) u32;
pub const Verify = enum { match, mismatch, not_present };
pub const Report = struct { sum: Verify, data: Verify };     // CHECKSUM / DATASUM outcomes
pub fn verify(fits: *Fits, hdu: *Hdu) VerifyError!Report;
pub fn update(fits: *Fits, hdu: *Hdu) UpdateError!void;      // writes DATASUM then CHECKSUM (FR-SUM-3)
```

**Accumulation.** The 32-bit sum is the CFITSIO `ff_csum` form: walk the (padded) unit in
4-byte groups (each group read big-endian through `endian.read`, per §7.1 — never a raw
bitcast off disk), add each group's high 16-bit half into `hi` and its low half into
`lo`, then fold the carries until both fit in 16 bits → `(hi << 16) + lo`. `DATASUM` stores
that value as an unsigned decimal string; `CHECKSUM` stores the 16-character ASCII encoding
of its one's-complement, so the complete HDU sums to all-ones.

> **Verified golden vector — CFITSIO 4.6.4.** A CFITSIO-written `TABLE` HDU with `NAXIS1=26`,
> `NAXIS2=3` (78 logical data bytes; one 2880-byte block, hence 2802 trailing `0x20` spaces)
> emits `DATASUM = 628729719`. An independent recompute over the **space-padded** data unit
> reproduces `628729719`; over the same data **zero-padded** it gives `1302441855`. This
> locks `FR-SUM-1`'s rule that the ASCII-table space fill is summed (the original
> pre-padding length would be wrong) and is committed as a parity fixture (§23).

Ordering is enforced: **`DATASUM` is written/updated before `CHECKSUM` is accumulated**
(`FR-SUM-1`), because `CHECKSUM` covers the `DATASUM` card text. The checksum is computed
incrementally over block-aligned reads so verifying a multi-GB HDU stays in bounded memory.
`update` is an explicit operation and MAY run automatically on close when the handle is
opened with `checksum_on_close = true` (`FR-SUM-3`).

---

## 17. Tiled Compression

### 17.1 Compressed-image view (`FR-CMP-1`)

A tiled-compressed image is a `BINTABLE` with `ZIMAGE=T` carrying the **keywords**
`ZCMPTYPE`, `ZBITPIX`, `ZNAXISn`, `ZTILEn`; the quantize/dither method `ZQUANTIZ`
(`NO_DITHER` / `SUBTRACTIVE_DITHER_1` / `SUBTRACTIVE_DITHER_2`) with integer seed
`ZDITHER0`; and the codec-parameter pairs `ZNAMEn`/`ZVALn` (e.g. `RICE_1` `BLOCKSIZE`,
`BYTEPIX`). The pixel payload lives in **columns**: `COMPRESSED_DATA` (`1P`/`1Q` VLA), the
optional `GZIP_COMPRESSED_DATA` / `UNCOMPRESSED_DATA` fallbacks, and the per-tile linear
`ZSCALE`/`ZZERO` columns (`ZBLANK` may be either a keyword or a column). `compress/tiled.zig`
presents this as a normal `ImageView` (§11) by decompressing tiles on demand:

```zig
pub const TiledImage = struct {
    base: BinTable, ztype: Codec, zbitpix: i8, znaxis: []u64, ztile: []u64, ...
    pub fn view(self: *TiledImage) ImageView;   // transparent decompress on read
};
```

The tile that covers a requested pixel range is located via the row/descriptor, fed to the
codec, un-shuffled/un-dithered, scaled, and delivered through the same image conversion
path — so callers use one image API whether or not the HDU is compressed (`FR-CMP-1`). An
unimplemented `ZCMPTYPE` is `error.UnsupportedCodec`, never a silent mis-read
(`NFR-INTEROP-1`).

### 17.2 Codec registry & GZIP (`FR-CMP-2`)

```zig
pub const Codec = enum { gzip_1, gzip_2, rice_1, plio_1, hcompress_1 };
pub const TileCodec = struct {
    decode: *const fn (Allocator, in: []const u8, out_elems: u64, elem: StoredType) CompressError![]u8,
    encode: *const fn (Allocator, in: []const u8, elem: StoredType) CompressError![]u8,
};
```

`GZIP_1`/`GZIP_2` (`FR-CMP-2`) use the gzip container (RFC 1952 header / CRC32 / ISIZE)
over DEFLATE via `std.compress.flate`. `GZIP_2` additionally applies a **type-aware byte
shuffle** — bytes reordered in decreasing significance, MSB-first, for integer/float
elements only (**not** logical/bit/char) — before compression. `std` does not provide the
shuffle, so `compress/shuffle.zig` implements it and its exact inverse on read:

```zig
// shuffle.zig — split N values of W bytes into W planes (plane k = byte k of every value)
pub fn shuffle(comptime W: usize, items: []const u8, out: []u8) void;   // MSB-first
pub fn unshuffle(comptime W: usize, planes: []const u8, out: []u8) void;
```

### 17.3 Rice/PLIO/HCOMPRESS, dithering, tiled tables (`FR-CMP-3/4/5`, P3)

- `RICE_1`, `PLIO_1`, `HCOMPRESS_1` (`FR-CMP-3`): integer-only for Rice/PLIO; `PLIO_1`
  values in `0…2^24`; `HCOMPRESS_1` 2-D tiles only. Invalid data/algorithm pairings →
  `error.DataConstraintViolated`.
- Writing tiled-compressed images (`FR-CMP-4`) is supported for at least `GZIP`, including
  the floating-point **subtractive dithering** options `NO_DITHER`,
  `SUBTRACTIVE_DITHER_1/2` (recorded in `ZQUANTIZ`, seeded by `ZDITHER0`;
  `compress/dither.zig`, with the standard random sequence).
- Tiled-**table** compression (FITS 4.0 §10.3, `FR-CMP-5`) — read at minimum.

---

## 18. World Coordinate System (P2)

### 18.1 Keyword model (`FR-WCS-1`)

`wcs/keys.zig` parses and serializes the WCS keyword set: `WCSAXES`, `CTYPEn`, `CRPIXn`,
`CRVALn`, `CDELTn`, `CUNITn`, the **mutually exclusive** `CDi_j` / `PCi_j` matrices,
`PVi_m`, `PSi_m`, `LONPOLEa`/`LATPOLEa`, `RADESYSa`, `EQUINOXa`, and alternate descriptions
(the `…a` letter suffix, `a` ∈ `A`–`Z`). Legacy `CROTAn` is **read** but deprecated and
**not written together with** `PCi_j`/`PVi_m`/`PSi_m` (`FR-WCS-1`).

```zig
// wcs/keys.zig
pub const Wcs = struct {
    axes: u16, ctype: [][]const u8, crpix: []f64, crval: []f64, cdelt: []f64,
    transform: union(enum) { pc: [][]f64, cd: [][]f64, none },
    pv: []PvTerm, lonpole: ?f64, latpole: ?f64, radesys: ?[]const u8, equinox: ?f64,
    pub fn fromHeader(a: Allocator, h: *const Header, alt: u8) WcsError!Wcs;
    pub fn writeTo(self, a: Allocator, h: *Header) !void;
};
```

### 18.2 Transforms (`FR-WCS-2/3/4`)

`wcs/celestial.zig` provides pixel↔world transforms for the implemented projections — the
zenithal family `TAN`, `SIN`, `ARC`, `STG`, `ZEA` plus the plate carrée `CAR` — using the
linear `PC/CD`+`CDELT` step, the projection's plane↔native-spherical math, then the
spherical rotation parameterized by `LONPOLEa`/`LATPOLEa`, with `RADESYSa`/`EQUINOXa`
selecting the frame (`FR-WCS-2`). Other projections (e.g. `AIT`, `MER`) are **future** work
behind the same extensible registry; an unimplemented code is `error.UnsupportedProjection`.
The transforms hang off a `Celestial` value built from a parsed `Wcs`:

```zig
pub const Celestial = struct {
    pub fn fromWcs(w: *const Wcs) WcsError!Celestial;
    pub fn pixelToWorld(self: *const Celestial, pix: [2]f64) WcsError![2]f64;
    pub fn worldToPixel(self: *const Celestial, world: [2]f64) WcsError![2]f64;
};
```

Spectral keywords (`CTYPEn` spectral types, `RESTFRQ`, `RESTWAV`, `SPECSYS`) are handled in
`wcs/spectral.zig` (`FR-WCS-3`); time-coordinate representation (`MJDREF[I|F]`, `TIMESYS`,
`TIMEUNIT`, `TREFPOS`, `DATE-OBS`, FITS 4.0 Ch. 9) in `wcs/time.zig`, sharing the date/JD
helpers of `FR-UTL-1` (`FR-WCS-4`). All `SHOULD`-tier; unsupported projections →
`error.UnsupportedProjection`.

---

## 19. Utilities, Iterator, Validation

### 19.1 Utilities (`FR-UTL-1..5`)

- **Date/time** (`FR-UTL-1`): format/parse `DATE`/`DATE-OBS`
  (`yyyy-mm-ddThh:mm:ss[.sss]`), accept the deprecated `DD/MM/YY` on read (year → 19YY per
  §4.4.2.1), and convert to/from Julian / Modified-Julian dates.
- **TFORM/TDISP parsing** (`FR-UTL-2`): extract type code, repeat, width, decimals;
  compute ASCII-table column positions. Shared by ASCII/binary tables and validation.
- **Version & messages** (`FR-UTL-3`): `version()` string and `errorText(err)` for every
  error value.
- **Wildcard name matching** (`FR-UTL-4`): case-insensitive compare with `*` (any run),
  `?` (one char), `#` (a run of digits). The **match API defines its result contract** —
  zero / exactly-one / ordered-all — via a `Matches` out-parameter, never the CFITSIO
  status-iteration idiom:

  ```zig
  // name.zig — fixed-capacity match accumulator; no allocation on the common path.
  // The inline buffer length MUST be a top-level constant: a struct's *runtime* field
  // (`Limits.max_matches`) cannot serve as a type-name-qualified comptime array bound on
  // Zig 0.16 (`error: struct 'Limits' has no member named 'max_matches'`). So the comptime
  // capacity lives here as MAX_MATCHES, and `Limits.max_matches` (§7.2) is the *runtime*
  // ceiling, constrained to `<= MAX_MATCHES`.
  pub const MAX_MATCHES: usize = 4096;
  pub const Matches = struct {
      buf: [MAX_MATCHES]u32 = undefined,        // 0-based indices; columns ≤ TFIELDS ≤ 999
      len: usize = 0,
      overflow: bool = false,                   // set when more matches existed than fit
      pub fn slice(self: *const Matches) []const u32 { return self.buf[0..self.len]; }
      pub fn at(self: *const Matches, i: usize) u32 { return self.buf[i]; }
  };
  ```

  Column lookups (`columnByName`) cannot overflow (`TFIELDS ≤ 999 < MAX_MATCHES`) so they
  stay `void`-returning with an out-param. `Header.find` over an unbounded card list sets
  `overflow = true` on truncation; an allocating `Header.findAlloc(allocator, …)` variant
  returns the complete list when a caller needs every match.
- **TDISP rendering** (`FR-UTL-5`, P2): apply `TDISPn`/`TDISP` to render values as text and
  compute display width (≡ `fits_get_col_display_width`).

### 19.2 Iterator (`FR-ITR-1/2`, P2)

`iterator.zig` drives a caller-supplied work function over image pixels or **binary-table**
columns (the `Cols`/`ColumnRef` model is binary-table-specific; ASCII-table iteration is a
documented follow-up) in block-aligned chunks, handling buffering, datatype conversion, and
null substitution
(`FR-ITR-1`), with per-column **input / output / input-output** roles and per-call
element-grouping control (`FR-ITR-2`). Chunk sizing satisfies `NFR-PERF-1` (block-aligned,
no per-element syscalls) and `NFR-PERF-3` (bounded memory).

```zig
// `Cols` is a caller-defined struct of typed column buffers, so one pass can drive a
// heterogeneous column set (e.g. `struct { flux: []f32, count: []i32 }`). `E` is the
// caller's own error set, threaded through so the callback — and `run` — keep typed errors;
// no public function returns `anyerror` (§4.1, FR-ERR-1).
pub fn Iterator(comptime Cols: type, comptime E: type) type {
    return struct {
        pub const Role = enum { in, out, inout };
        pub const Binding = struct { ref: ColumnRef, role: Role, field: []const u8 };
        bindings: []const Binding,                          // one per field of `Cols`
        pub fn run(self: *@This(), group: usize,
                   work: *const fn (n: usize, cols: *Cols) E!void) (Error || E)!void;
    };
}
```

A single `comptime T` could not drive a heterogeneous column set (an `i32` column beside an
`f64` column — the central column-iterator use case, `FR-ITR-2`); a `Cols` struct of typed
slices fixes that, and the `comptime E` error set replaces the `anyerror!void` callback that
would otherwise force `run` to leak `anyerror`, restoring the `FR-ERR-1` typed-error mandate.

### 19.3 Structural validation (`FR-VAL-1/2`, P2)

`validate.zig` is a `fitsverify`-style pass that **reports all findings, not just the
first**, each classified **error vs warning** (`FR-VAL-2`):

```zig
pub const Finding = struct { severity: enum { err, warning }, hdu: u32, kw: ?[8]u8, msg: []const u8 };
pub fn verify(a: Allocator, fits: *Fits) !std.ArrayList(Finding);
```

Checks (`FR-VAL-1`): block sizing; mandatory keyword presence/order/type; value ranges;
table geometry (**binary**: `NAXIS1` equals the summed `TFORM` field widths; **ASCII**:
each `TBCOLn`+width fits within `NAXIS1`, which MAY exceed the field extent);
declared-vs-actual data sizes; `END`/padding correctness. Consistent with `FR-HDU-6`, a
missing/non-adjacent `EXTEND` is **not** a finding.

---

## 20. Extended Filenames, Remote, Templates (P3)

### 20.1 Extended filename syntax (`FR-EFN-1..5`)

`filename.zig` parses CFITSIO-style extended names but, per `FR-EFN-5`, the grammar is
**documented and every feature has a programmatic, non-string equivalent** — the string DSL
is never the only path.

- HDU selection by number or `[extname,extver]`. The CFITSIO bracket index is **0-based**
  (`[0]`=primary) ↔ the 1-based programmatic HDU number (filename `[n]` ↔ HDU `n+1`)
  (`FR-EFN-1`).
- Image-section specifiers `img.fits[1:512:2, 1:512]` map to `readSection` bounds/stride
  (`FR-EFN-2`).
- Column selection / row filtering (boolean calculator incl. `gtifilter()`/`regfilter()`)
  and binning/histogram specifiers are `MAY` (`FR-EFN-3`); the full row-filter expression
  engine is **not committed** (requirements §7.1).
- Output-file/template qualifiers are `MAY` (`FR-EFN-4`).

```zig
pub const FileSpec = struct {                 // the programmatic equivalent (FR-EFN-5)
    path: []const u8, hdu: ?HduSelect = null, section: ?Section = null,
    columns: ?[]const []const u8 = null, row_filter: ?[]const u8 = null,
    pub fn parse(a: Allocator, ext: []const u8) !FileSpec;   // the DSL → this struct
};
```

### 20.2 Remote & alternate access (`FR-RMT-1/2/3`)

In-memory buffers and stdin/stdout are first-class backends (`FR-RMT-1`, §8.1). Whole-file
gzip (`.fits.gz`) is read/written transparently via `std.compress.flate` (`FR-RMT-2`).
Remote read over HTTP/HTTPS via `std.http` is a `MAY` (`FR-RMT-3`); `std`'s TLS is TLS-1.3
only, and FTP is out (no `std` FTP module). HTTP uses Range requests for random access,
falling back to a full in-memory download.

### 20.3 Templates (`FR-TPL-1/2`)

`template.zig` MAY create a FITS file from a CFITSIO-style ASCII header template (keyword
lines, auto-indexing, parser directives). The **programmatic builder API is the primary,
fully supported construction path**; templates are a thin convenience layer over it
(`FR-TPL-2`).

### 20.4 Hierarchical grouping (`FR-GRP-1/2`)

`group_table.zig` reads FITS *grouping tables* (a `BINTABLE` with `GRPNAME` and the
`MEMBER_XTENSION/NAME/VERSION/POSITION/LOCATION` columns plus member-side `GRPIDn`/`GRPLCn`)
and resolves membership to referenced HDUs (`FR-GRP-1`). Creating/editing grouping tables
is `SHOULD` (`FR-GRP-2`).

---

## 21. Public API Surface & Examples

`root.zig` exposes a compact, idiomatic surface. Representative end-to-end usage:

### 21.1 Read an image into `[]f32`

```zig
const fits = @import("zigfitsio");

var f = try fits.open(allocator, fits.fileDevice("img.fits"), .read_only, .{});
defer f.deinit();

var img = try f.current().image(&f);
const npix = img.elementCount();
const buf = try allocator.alloc(f32, npix);
defer allocator.free(buf);

// BSCALE/BZERO applied, NaN→0 substituted, i16→f32 converted, all in bounded chunks.
// opts is ReadOpts(f32), so the sentinel is a plain f32 checked against the read type.
try img.readAll(f32, buf, .{ .null_sentinel = 0.0 });
```

### 21.2 Create an image (programmatic builder is primary — FR-TPL-2)

```zig
var f = try fits.create(allocator, fits.fileDevice("out.fits"), .{});
defer f.deinit();

var img = try f.appendImage(.{ .bitpix = -32, .axes = &.{ 256, 256 } });
try img.writeAll(f32, pixels, .{});
try f.flush();                       // pads blocks, optionally updates CHECKSUM
```

### 21.3 Read a binary-table column by name, with wildcard contract (FR-UTL-4)

```zig
// `select` returns `!*Hdu`; unwrap it before calling `.binTable` (a method cannot be
// reached through an un-unwrapped error union).
var tbl = try (try f.select(2)).binTable(&f);

var matches: fits.Matches = .{};
tbl.columnByName("FLUX*", &matches);          // fills the ordered match list
const col: u16 = switch (matches.len) {
    0 => return error.NoSuchColumn,
    1 => @intCast(matches.at(0)),
    else => @intCast(matches.at(0)),           // caller decides; no status iteration
};

const flux = try allocator.alloc(f64, tbl.rowCount());
defer allocator.free(flux);
try tbl.readColumn(f64, .{ .index = col }, 0, flux, .{ .scaling = .apply });
```

### 21.4 Verify checksums (FR-SUM-2)

```zig
const r = try fits.checksum.verify(&f, f.current());
if (r.sum == .mismatch or r.data == .mismatch) return error.ChecksumMismatch;
```

---

## 22. Requirements Traceability Matrix

Every `FR`/`NFR`/`GC` ID maps to the design section(s) that realize it. (Read the cited
section for the mechanism; this table is the completeness check.)

### Global constraints

| ID | Design |
|----|--------|
| GC-1 No C | §1, §3 (pure-Zig modules; `std.compress`/own shuffle, §17.2) |
| GC-2 std-only | §3, §24 (`build.zig.zon` with no deps) |
| GC-3 Zig 0.16.0 | §24 |
| GC-4 Idiomatic API | §4.1, §6, §9.2, §21 (error unions, comptime types, tagged unions) |
| GC-5 Big-endian | §7.1 |
| GC-6 No UB | §4.1, §6, §7.2 |
| GC-7 No-libc core | §2, §8.1 (vtable I/O; OS backends are leaf) |
| GC-8 No leaks | §5 |

### Functional — I/O & headers

| ID | Design | ID | Design |
|----|--------|----|--------|
| FR-IO-1 | §8.2 | FR-HDR-1 | §9.1 |
| FR-IO-2 | §8.2 (pad kinds) | FR-HDR-2 | §9.1 |
| FR-IO-3 | §8.1 | FR-HDR-3 | §9.2 |
| FR-IO-4 | §8.2 | FR-HDR-4 | §9.2 |
| FR-IO-5 | §8.2, §10.3 | FR-HDR-5 | §9.2 |
| FR-IO-6 | §8.1 (64-bit) | FR-HDR-6 | §9.1 (`classify`) |
| FR-HDR-7 | §9.4 | FR-HDR-8 | §9.3 |
| FR-HDR-9 | §9.3 | FR-HDR-10 | §9.3 |
| FR-HDR-11 | §9.4 | FR-HDR-12 | §9.4 (`reserveSpace`) |
| FR-HDR-13 | §9.4, §6 | FR-HDR-14 | §9.4 (INHERIT) |

### Functional — HDUs, images, tables

| ID | Design | ID | Design |
|----|--------|----|--------|
| FR-HDU-1 | §10.3 | FR-IMG-1 | §11.1 |
| FR-HDU-2 | §10.1 | FR-IMG-2 | §11.1 |
| FR-HDU-3 | §10.3 | FR-IMG-3 | §11.2 |
| FR-HDU-4 | §10.3 | FR-IMG-4 | §11.2 |
| FR-HDU-5 | §10.2 | FR-IMG-5 | §11.3 |
| FR-HDU-6 | §10.2, §19.3 | FR-IMG-6 | §11.3 |
| FR-ATB-1 | §12.1 | FR-IMG-7 | §11.3 |
| FR-ATB-2 | §12.1 | FR-IMG-8 | §11.4 |
| FR-ATB-3 | §12.2 | FR-IMG-9 | §11.1/§11.2 |
| FR-ATB-4 | §12.2, §6 | FR-IMG-10 | §11.5 |
| FR-BTB-1 | §13.1 | FR-BTB-2 | §13.1 |
| FR-BTB-3 | §13.1 (TDIM) | FR-BTB-4 | §13.2 |
| FR-BTB-5 | §13.3, §6 | FR-BTB-6 | §13.3 |
| FR-BTB-7 | §13.3 | | |

### Functional — VLA, groups, integrity, compression

| ID | Design | ID | Design |
|----|--------|----|--------|
| FR-VLA-1 | §14.1 | FR-CMP-1 | §17.1 |
| FR-VLA-2 | §14.2 | FR-CMP-2 | §17.2 |
| FR-VLA-3 | §14.3 | FR-CMP-3 | §17.3 |
| FR-VLA-4 | §14.3 | FR-CMP-4 | §17.3 |
| FR-RG-1 | §15 | FR-CMP-5 | §17.3 |
| FR-RG-2 | §15 | FR-SUM-1 | §16 |
| FR-SUM-2 | §16 | FR-SUM-3 | §16 |

### Functional — WCS, utilities, iterator, validation, extended

| ID | Design | ID | Design |
|----|--------|----|--------|
| FR-WCS-1 | §18.1 | FR-UTL-1 | §19.1 |
| FR-WCS-2 | §18.2 | FR-UTL-2 | §19.1 |
| FR-WCS-3 | §18.2 | FR-UTL-3 | §19.1, §4.3 |
| FR-WCS-4 | §18.2 | FR-UTL-4 | §19.1, §13.3 |
| FR-ITR-1 | §19.2 | FR-UTL-5 | §19.1 |
| FR-ITR-2 | §19.2 | FR-VAL-1 | §19.3 |
| FR-EFN-1..5 | §20.1 | FR-VAL-2 | §19.3 |
| FR-RMT-1..3 | §20.2, §8.1 | FR-CONV-1 | §6 |
| FR-TPL-1/2 | §20.3 | FR-CONV-2 | §6 |
| FR-GRP-1/2 | §20.4 | FR-ERR-1..4 | §4 |

### Non-functional

| ID | Design | ID | Design |
|----|--------|----|--------|
| NFR-PERF-1 | §8.2, §11.2, §13.4 | NFR-API-1 | §24 |
| NFR-PERF-2 | §6, §7.1 | NFR-API-2 | §3 (root re-exports) |
| NFR-PERF-3 | §5, §11.2, §16 | NFR-BUILD-1 | §24 |
| NFR-MEM-1 | §5 | NFR-BUILD-2 | §24 |
| NFR-MEM-2 | §5, §23 | NFR-TEST-1..5 | §23 |
| NFR-SAFE-1 | §7.2 | NFR-DOC-1 | §3, §24 |
| NFR-SAFE-2 | §23 (fuzz) | NFR-DOC-2 | §27 |
| NFR-PORT-1 | §24 | NFR-CONC-1 | §25 |
| NFR-PORT-2 | §7.1 | NFR-INTEROP-1 | §17.1 (inbound), §23 (outbound + inbound) |
| NFR-PORT-3 | §2, §8.1, §24 | NFR-INTEROP-2 | §9.2, §23 |

---

## 23. Testing & Fuzzing Strategy

| Layer | Coverage | Requirement |
|-------|----------|-------------|
| **Unit** | header parse/format; each `BITPIX`; each `TFORM` code; scaling; nulls; VLA; checksums; `convert` policy edge cases (overflow, half-rounding, precision loss); endian swap on both host endiannesses (forced). | `NFR-TEST-1` |
| **Corpus** | `test/corpus/` real sample files — images, ASCII & binary tables, VLA, compressed — exercised read + round-trip. | `NFR-TEST-2`, `NFR-INTEROP-2` |
| **Cross-validation** | compare `zigfitsio` output vs CFITSIO/Astropy for the same inputs (golden files committed; an optional CI job regenerates them where those tools are available). | `NFR-TEST-3` |
| **Conformance** | valid **and** deliberately malformed fixtures assert FITS 4.0 structural rules and that `validate.zig` reports the right error/warning set. | `NFR-TEST-4` |
| **Concurrency** | a multi-threaded test driving **distinct handles** concurrently, plus a doc-presence check for the single-handle caveat. | `NFR-TEST-5a`, `NFR-CONC-1` |
| **Interop (inbound)** | fixed corpus of CFITSIO/Astropy-written files read by `zigfitsio`. | `NFR-TEST-5b`, `NFR-INTEROP-1` (inbound) |
| **Interop (outbound)** | a CI job opens **every `zigfitsio`-written corpus file with CFITSIO and Astropy** and asserts success — the explicit check for the outbound MUST (beyond the implicit conformance/round-trip guarantee). | `NFR-INTEROP-1` (outbound) |
| **Fuzz** | `test/fuzz/` harnesses for the **header** and **table** parsers; crashes/leaks are release blockers. Run under `zig build fuzz`; seeds from the corpus. | `NFR-SAFE-2` |
| **Leak** | the whole suite runs under `std.testing.allocator`; zero leaks required. | `NFR-MEM-2` |
| **Checksum parity (golden)** | committed vector: a CFITSIO-written ASCII table with `DATASUM = 628729719`; the suite recomputes and must match, **and** must differ under zero-fill — locking the `FR-SUM-1` space-fill rule (§16). | `NFR-TEST-1`, `NFR-INTEROP-1` |
| **API regression (Zig 0.16)** | compile-fixtures asserting the corrected snippets build and the three original defects do **not** (field/method collision, method-on-error-union, removed `std.BoundedArray`). | `GC-3`, `GC-4` |

**Realized (this branch).** The cross-validation, conformance, both interop legs, and the
checksum-golden layers above are now implemented against a committed **CFITSIO 4.6.4 + `fpack`**
golden corpus (`test/golden/`, generators under `interop/`): `test/e2e.zig` is the in-house
full-feature "`testprog.c`-equivalent" round-trip (every BITPIX/TFORM, all four tile codecs, VLA,
WCS, CONTINUE/HIERARCH, checksums, a byte-snapshot tripwire), `test/golden.zig` decodes the
reference goldens hermetically on every cell (including big-endian s390x), and the `interop` CI
job opens every zigfitsio-written file with `funpack`/Astropy/`fitsverify`. Authoring the corpus
closed two real interop bugs the prior self-round-trips could not catch — the PLIO line-list
header + `COMPRESSED_DATA` `1PB`→`1PI`, and the unregistered `checksum_on_close` flush hook (see
`CAVEATS.md §1`).

The fuzzers specifically target the `NFR-SAFE-1` invariant: declared sizes (`NAXISn`
product, `PCOUNT`, VLA descriptor length+offset) are fed hostile values to confirm
validation-before-allocation and typed-error (not panic) behavior.

**Validation status (pre-implementation).** The design's highest-risk claims were exercised
on the baseline toolchain before any library code was written, and seeded the two golden
fixtures above:

- **Zig 0.16.0.** The corrected `Fits` / `ImageView` / `Iterator(Cols, E)` / `Matches` /
  `ReadOpts(T)` snippets compile and pass — including a test that holds a `*Hdu` across 1000
  reallocating appends (a use-after-free if HDUs were stored by value, confirming the
  stable-pointer fix) and one that propagates a caller's typed error through `Iterator.run`
  (confirming the `anyerror` leak is gone). The three original defects fail to compile with
  the expected diagnostics (`duplicate struct member name 'current'`; `no field or member
  function named 'z' in 'error{…}!B'`; `'std' has no member named 'BoundedArray'`).
  **Two corrections were required to make these literally build on 0.16, and the snippets
  above already incorporate them:** (1) `Matches` must size its inline buffer from the
  top-level `MAX_MATCHES` constant (§19.1), not the runtime field `Limits.max_matches` — a
  struct's instance field cannot be a type-name-qualified comptime array bound; (2) the
  `build.zig.zon` `fingerprint` (§24.2) must be the value `zig build` emits on first run, as
  the printed literal is rejected until regenerated (its low 32 bits checksum `.name`).
- **CFITSIO 4.6.4.** The §16 checksum reproduces CFITSIO's authoritative ASCII-table
  `DATASUM` only when the `0x20` space fill is summed (golden vector above), and CFITSIO's
  own `fits_verify_chksum` confirms the generated HDU.

---

## 24. Build, Packaging & Portability

### 24.1 `build.zig` (Zig 0.16 API)

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zigfitsio", .{                 // consumable via zig fetch
        .root_source_file = b.path("src/root.zig"),
        .target = target, .optimize = optimize,
    });

    const lib = b.addLibrary(.{                            // static artifact (NFR-BUILD-2)
        .linkage = .static, .name = "zigfitsio", .root_module = mod,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = mod });      // zig build test (NFR-BUILD-2)
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit/integration tests").dependOn(&run_tests.step);

    // bench + fuzz + a wasm32-freestanding check step (NFR-PORT-3) wired similarly.
}
```

### 24.2 `build.zig.zon`

```zig
.{
    .name = .zigfitsio,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    // .fingerprint is REQUIRED but MUST be the value `zig build` prints on first run — its
    // low 32 bits checksum `.name`, so a hand-picked literal is rejected (and 0x0 is reserved).
    .fingerprint = 0x0, // PLACEHOLDER: run `zig build` once and paste the value it reports here
    .dependencies = .{},           // none — std only (GC-2)
    .paths = .{ "build.zig", "build.zig.zon", "src", "LICENSE", "README.md" },
}
```

### 24.3 Portability & CI (`NFR-PORT-1/3`)

- CI matrix: {Linux, macOS, Windows} × {x86_64, aarch64}, `zig build test` (`NFR-PORT-1`),
  **plus a big-endian cell** (`s390x-linux` or `powerpc64-linux` under QEMU) running
  `zig build test`.
- A `wasm32-freestanding` build **compiles the core** (excluding `io/file.zig`,
  `io/stream.zig`, `io/http.zig`; the memory backend is the freestanding I/O path) and is
  exercised in CI (`NFR-PORT-3`).
- Endian-independence is asserted by forcing the swap path in unit tests **and** by the
  big-endian CI cell above — the `{x86_64, aarch64}` hosts are all little-endian and cannot,
  by themselves, exercise a native big-endian read path (`NFR-PORT-2`).
- SemVer + changelog; public API changes bump the version (`NFR-API-1`). Every public decl
  carries a doc comment, and a usage guide with the §21 examples ships in `README.md`
  (`NFR-DOC-1`).

---

## 25. Concurrency & Thread-Safety

Per `NFR-CONC-1`: all library state lives in explicit handle objects (`Fits`, and the
views derived from it); there is **no shared mutable global state** — error reporting is
return-value based (§4), allocators are caller-supplied (§5), and there are no global
caches. Therefore **distinct `Fits` handles are usable concurrently from different
threads**. A **single handle is not thread-safe** (it mutates its block cache, CHDU
pointer, and lazily-grown HDU list); this is **documented** on `Fits` and verified by the
`NFR-TEST-5a` multi-thread test. The position-explicit `Device` interface (§8.1) makes the
per-handle confinement natural and would also permit a future internally-synchronized
shared-reader mode without changing the wire layer.

---

## 26. Phasing & Milestones

Milestones follow the requirement priority tiers (requirements §6). Each milestone's exit
criterion is "its requirements pass unit + corpus tests under the leak checker."

| Milestone | Scope | Key sections |
|-----------|-------|--------------|
| **M0 — Foundation (P0)** | `GC-*`; I/O layer (device/memory/file, block model); errors + diagnostics; endian; convert; header + card parse/serialize; HDU model + navigation; primary/IMAGE core types with full + contiguous pixel I/O. | §4–§11 |
| **M1 — Core library (P1)** | CONTINUE; full header edits; image scaling/unsigned/nulls/sections; ASCII tables; binary tables; VLA + heap; checksums; utilities; numeric-conversion sites wired. | §9.3, §11.2–4, §12, §13, §14, §16, §19.1 |
| **M2 — Full standard (P2)** | HIERARCH/units/header-space/INHERIT; image signed-byte + resize; random groups; WCS; tiled-image **read** + GZIP_1/2 (+ shuffle); iterator; TDISP; structural validation. | §9.3–4, §11.3/5, §15, §17.1–2, §18, §19.2–3 |
| **M3 — Extended (P3)** | Rice/PLIO/HCOMPRESS + compressed **write** + dithering; tiled tables; extended filename syntax; whole-file gzip + HTTP; templates; hierarchical grouping; CFITSIO status-code map polish. | §17.3, §20 |

Cross-cutting tracks run continuously from M0: fuzzing (§23), the CI portability matrix
(§24.3), and interoperability checks against CFITSIO/Astropy (§23).

---

## 27. Key Design Decisions & Open Questions

**Decisions made in this design:**

1. **Position-explicit (`pread`/`pwrite`) I/O vtable with two interfaces** (seekable
   `Device` vs sequential `Stream`), rather than a single stateful seek+read object. Makes
   random access natural, memory/WASM backends trivial, and concurrent distinct-range reads
   sound (§8.1, §25).
2. **Comptime-typed data transfer** (`readColumn(f64, …)`) instead of runtime datatype
   codes + `anyopaque`. The conversion policy lives in one `convert` module cited
   everywhere (§6) — the idiomatic-Zig mandate of `GC-4`.
3. **Round-trip fidelity via raw card preservation**: a `Card` keeps its 80 on-disk bytes
   and only re-serializes when edited, giving byte-stable round-trips where the format
   permits (§9.2, `NFR-INTEROP-2`) without a separate "preserve formatting" mode.
4. **Compression presented behind the normal `ImageView`**: tiled-compressed HDUs decode on
   demand so callers use one image API; unsupported codecs fail typed, never silently
   mis-read (§17.1, `NFR-INTEROP-1`).
5. **Validation-before-allocation as a shared helper** keyed off one `Limits` struct, so
   `NFR-SAFE-1` is enforced uniformly and is the direct target of the fuzzers (§7.2, §23).

**Open questions inherited from requirements §7.2 (to resolve before 1.0):**

1. CFITSIO C-compatible export layer as a later separate module? (Explicitly out of scope
   now; the design keeps `errors.cfitsioStatus` so a future shim has a code map ready.)
2. **License** (MIT / Apache-2.0 / BSD-3) — must be CFITSIO-independent (`NFR-DOC-2`).
   Pending; gates the `LICENSE` path in `build.zig.zon`.
3. WCS transform breadth — full projection set vs. common subset (§18.2 implements the
   common set first; extensible registry).
4. Minimum compression set for 1.0 — GZIP-only vs. also Rice/HCOMPRESS (M2 ships GZIP; M3
   adds the rest).
5. Whether whole-file gzip + HTTP ship in 1.0 or move to an extension package (§20.2 keeps
   them as leaf backends so either choice is a build-graph decision, not a refactor).
