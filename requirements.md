# zigfitsio — Requirements

A pure-[Zig](https://ziglang.org) implementation of a FITS (Flexible Image Transport
System) input/output library with feature parity to
[CFITSIO](https://heasarc.gsfc.nasa.gov/docs/software/fitsio/fitsio.html), written
without any C imports or C source.

---

## 1. Introduction

### 1.1 Purpose

`zigfitsio` is a library for reading and writing FITS files. It targets functional
parity with CFITSIO while exposing an **idiomatic Zig API** (error unions, explicit
allocators, slices, tagged enums, comptime generics) rather than mirroring the C
calling conventions. It must allow Zig programs to create, inspect, manipulate, and
validate FITS data structures defined by the **FITS Standard, Version 4.0**.

### 1.2 Conformance Target

The authoritative reference is the *Definition of the Flexible Image Transport System
(FITS)*, Version 4.0 (13 August 2018), endorsed by the IAU FITS Working Group. The
secondary reference for the API surface and behavioral expectations is the *CFITSIO
User's Reference Guide*.

### 1.3 Intended Users

Astronomy/astrophysics tooling authors, data-pipeline developers, and any Zig
application needing to consume or produce FITS data without linking a C library.

### 1.4 Requirement Conventions

- Each requirement has a stable ID of the form `FR-<AREA>-<n>` (functional) or
  `NFR-<AREA>-<n>` (non-functional).
- Keywords **MUST**, **MUST NOT**, **SHOULD**, **MAY** are used per RFC 2119.
- Every functional area carries a **priority tier**:
  - **P0** — Foundational; nothing works without it.
  - **P1** — Core; required for a usable general-purpose FITS library.
  - **P2** — Important; needed for full standard coverage and common workflows.
  - **P3** — Extended; CFITSIO convenience features and niche/remote capabilities.

---

## 2. Guiding Principles & Global Constraints

| ID | Requirement | Priority |
|----|-------------|----------|
| GC-1 | The library **MUST** be implemented entirely in Zig. `@cImport`, C headers, C source files, and linking against CFITSIO or any C library **MUST NOT** be used. | P0 |
| GC-2 | The library **MUST** depend only on the Zig standard library. No third-party package dependencies are permitted in the core. | P0 |
| GC-3 | The baseline toolchain is **Zig 0.16.0**. The build **MUST** succeed with this version. | P0 |
| GC-4 | The public API **MUST** be idiomatic Zig: fallible operations return error unions over typed error sets; all allocation goes through a caller-supplied `std.mem.Allocator`; bulk data is exchanged via slices; FITS datatype codes are modeled as Zig `enum`/`union(enum)` and comptime type parameters, not integer "datatype" codes plus `anyopaque`. | P0 |
| GC-5 | The library **MUST** treat the FITS byte stream as big-endian and produce/consume correct results on hosts of any endianness. | P0 |
| GC-6 | The library **MUST NOT** invoke undefined behavior on malformed, truncated, or hostile input; parsing **MUST** fail with a typed error instead of crashing. | P0 |
| GC-7 | The core read/write paths **MUST NOT** require libc. Use of OS facilities **MUST** go through `std` abstractions so freestanding/WASM targets remain feasible where I/O is provided. | P1 |
| GC-8 | The library **MUST NOT** leak memory: every allocation has a defined owner and release path; helper types provide `deinit`. | P0 |

---

## 3. Functional Requirements

### 3.1 Low-Level I/O & File Model — P0

| ID | Requirement |
|----|-------------|
| FR-IO-1 | The library **MUST** model a FITS file as a sequence of 2880-byte logical blocks; all header and data units **MUST** be read/written as integral multiples of 2880 bytes. |
| FR-IO-2 | Header units **MUST** be padded with ASCII spaces (0x20) and data units padded with the type-appropriate fill (ASCII space for ASCII tables, zero bytes otherwise) to the next block boundary. |
| FR-IO-3 | I/O **MUST** be abstracted over a pluggable byte source/sink so that at minimum the following back-ends are supported: on-disk file, in-memory buffer. The abstraction **MUST** support sequential and seekable random access. |
| FR-IO-4 | Reading **MUST** be buffered and block-aligned to avoid per-keyword syscalls. |
| FR-IO-5 | The library **MUST** support opening in read-only and read-write modes, and creating new files; write mode **MUST** preserve the block structure when editing in place. |
| FR-IO-6 | The library **MUST** support files larger than 2 GiB (64-bit offsets throughout). |

### 3.2 Headers & Keyword Records — P0–P2

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-HDR-1 | The library **MUST** parse and serialize 80-character keyword records ("cards"). Header data **MUST** be restricted to printable ASCII (0x20–0x7E); control characters **MUST** be rejected. | P0 |
| FR-HDR-2 | Keyword names of up to 8 characters using `[A-Z0-9_-]` **MUST** be supported, including the value-indicator `= ` in columns 9–10 for valued keywords. | P0 |
| FR-HDR-3 | The library **MUST** parse and produce all standard keyword value types: integer, floating point, complex (integer and floating pairs), logical (`T`/`F`), single-quoted character string (with `''` escape for embedded quotes and trailing-blank rules), and the **undefined** value (value indicator present but the value field blank). On read, the API **MUST** distinguish a null string, an empty string, and an undefined value. | P0 |
| FR-HDR-4 | Both **fixed-format** and **free-format** value fields **MUST** be supported on read; mandatory keywords **MUST** be written in fixed format per the standard. | P1 |
| FR-HDR-5 | Optional `/ comment` fields **MUST** be parsed and preserved; round-tripping a header **SHOULD** preserve comments and value formatting where feasible. | P1 |
| FR-HDR-6 | Commentary keywords (`COMMENT`, `HISTORY`, and the blank keyword) **MUST** be supported with free-text columns 9–80 and no value indicator. More generally, a card is a *value* card **iff** bytes 9–10 are exactly `= ` (0x3D, 0x20) **and** its name is not a commentary keyword; any other card — no value indicator, or a `COMMENT`/`HISTORY`/blank name even when `= ` appears — **MUST** be treated as commentary (bytes 9–80 free text) and preserved, not rejected. | P1 |
| FR-HDR-7 | The `END` keyword **MUST** terminate every header; the library **MUST** locate it and **MUST** reject headers lacking it. | P0 |
| FR-HDR-8 | The `CONTINUE` long-string convention **MUST** be supported for reading and writing string values exceeding 68 characters (using the `&` continuation marker). | P1 |
| FR-HDR-9 | The `HIERARCH` convention for extended/long keyword names **SHOULD** be supported (read and write). | P2 |
| FR-HDR-10 | Keyword units strings (the `[unit]` convention in comments) **SHOULD** be parseable. | P2 |
| FR-HDR-11 | The header API **MUST** provide: read keyword by name, read nth keyword/card, write/append, update (replace value/comment, create if absent), insert at position, modify in place, delete, and rename. | P1 |
| FR-HDR-12 | The library **MUST** support the header-space pre-allocation convention (reserving blank cards for later in-place additions). | P2 |
| FR-HDR-13 | Numeric keyword reads **MUST** support implicit conversion between the on-card representation and the requested Zig type, with overflow/precision-loss reported as errors per the numeric-conversion policy (FR-CONV-1). | P1 |
| FR-HDR-14 | The `INHERIT` convention **SHOULD** be supported: when explicitly enabled, keyword look-ups on an extension header fall through to the primary header for keywords absent from the extension, excluding the structural keywords (`XTENSION`, `BITPIX`, `NAXIS`, `NAXISn`, `PCOUNT`, `GCOUNT`, `TFIELDS`, `EXTEND`, `END`). Inheritance **MUST** be opt-in and **MUST NOT** alter the bytes written. | P2 |

### 3.3 HDU Management — P0

| ID | Requirement |
|----|-------------|
| FR-HDU-1 | The library **MUST** enumerate HDUs and report the total count; the first HDU is the primary HDU (number 1). |
| FR-HDU-2 | The library **MUST** identify HDU type: primary array, IMAGE extension, ASCII TABLE, BINARY TABLE, and random groups. |
| FR-HDU-3 | The library **MUST** support absolute and relative navigation to a target HDU, and selection by `EXTNAME`/`EXTVER`; the navigated-to HDU becomes the current HDU (CHDU). |
| FR-HDU-4 | The library **MUST** support creating, appending, copying (header and/or data), and deleting HDUs, maintaining correct block alignment and primary/extension invariants. |
| FR-HDU-5 | Required-keyword validation for the current HDU type **MUST** be enforced when finalizing/writing an HDU (e.g. `SIMPLE` first in primary; `XTENSION`/`BITPIX`/`NAXIS`/`NAXISn`/`PCOUNT`/`GCOUNT` order in extensions). |
| FR-HDU-6 | The `EXTEND = T` keyword **SHOULD** be written in the primary header when extensions are present (after the last `NAXISn`, or after `NAXIS` when `NAXIS=0`). Per FITS 4.0 §4.4.2.1 `EXTEND` is advisory and optional, so validation (FR-HDU-5/FR-VAL-1) **MUST NOT** flag a missing or non-adjacent `EXTEND` as an error. |

### 3.4 Primary Array & IMAGE Extensions — P0–P2

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-IMG-1 | The library **MUST** support all standard `BITPIX` values: 8 (unsigned byte), 16, 32, 64 (two's-complement signed integers), −32, −64 (IEEE single/double float). | P0 |
| FR-IMG-2 | The library **MUST** support `NAXIS` from 0 to 999 and the corresponding `NAXISn` axis lengths. | P0 |
| FR-IMG-3 | The library **MUST** read and write the entire data array and **MUST** support reading/writing an arbitrary contiguous run of pixels starting at an N-dimensional pixel coordinate (`first pixel` + element count). | P0 |
| FR-IMG-4 | The library **MUST** support reading/writing a rectangular subset/section (`first`..`last` per axis, with optional stride). | P1 |
| FR-IMG-5 | Linear scaling via `BSCALE`/`BZERO` (`physical = BZERO + BSCALE × stored`) **MUST** be applied transparently on read and inverted on write, with a mechanism to disable it and access raw stored values. | P1 |
| FR-IMG-6 | The unsigned-integer convention (`BITPIX` 16/32/64 with `BZERO` = 2^15 / 2^31 / 2^63, `BSCALE` = 1) **MUST** be supported for both reading and writing unsigned image data. | P1 |
| FR-IMG-7 | The signed-byte convention (`BITPIX` = 8 with `BZERO` = −128) **MUST** be supported. | P2 |
| FR-IMG-8 | Integer null values via `BLANK` and floating null values via IEEE NaN **MUST** be honored. On read, the **raw stored** value (before `BSCALE`/`BZERO`) **MUST** be compared against `BLANK` and matched elements replaced with a caller-provided null sentinel (unscaled); on write, sentinel elements **MUST** be stored as the raw `BLANK` value. For floating data the emitted null **MUST** be a specific documented NaN bit pattern (recommended: match CFITSIO), while *any* NaN **MUST** be recognized as null on read. | P1 |
| FR-IMG-9 | The API **MUST** report image type, dimensionality, and per-axis sizes; type-checked typed accessors (e.g. read into `[]f32`) **MUST** perform on-the-fly datatype conversion per the numeric-conversion policy (FR-CONV-1). | P1 |
| FR-IMG-10 | Resizing/redefining an existing image (changing `BITPIX`/`NAXISn`) **SHOULD** be supported. | P2 |

### 3.5 ASCII Table Extensions — P1

| ID | Requirement |
|----|-------------|
| FR-ATB-1 | The library **MUST** support `XTENSION='TABLE'` with `BITPIX=8`, `NAXIS=2`, `NAXIS1` (row width in bytes), `NAXIS2` (row count), `PCOUNT=0`, `GCOUNT=1`, `TFIELDS`. |
| FR-ATB-2 | Per-column metadata **MUST** be supported: `TBCOLn` (1-based byte start), `TFORMn` (`Aw`, `Iw`, `Fw.d`, `Ew.d`, `Dw.d`), `TTYPEn`, `TUNITn`, `TSCALn`, `TZEROn`, `TNULLn` (null string). |
| FR-ATB-3 | The library **MUST** read and write field values with correct FORTRAN-style fixed-width formatting and parsing, including blank/null fields. |
| FR-ATB-4 | Column values **MUST** be exchangeable as Zig scalar types and strings with datatype conversion (per FR-CONV-1) and `TSCALn`/`TZEROn` scaling applied. |

### 3.6 Binary Table Extensions — P1

| ID | Requirement |
|----|-------------|
| FR-BTB-1 | The library **MUST** support `XTENSION='BINTABLE'` with `BITPIX=8`, `NAXIS=2`, `NAXIS1` (row byte width), `NAXIS2` (rows), `PCOUNT` (heap size), `GCOUNT=1`, `TFIELDS`. |
| FR-BTB-2 | All standard `TFORMn` field type codes **MUST** be supported with repeat counts: `L` (logical), `X` (bit), `B` (unsigned byte), `I` (16-bit), `J` (32-bit), `K` (64-bit), `A` (char), `E` (single float), `D` (double float), `C` (single complex), `M` (double complex), plus `P`/`Q` array descriptors (see 3.7). A repeat count of 0 **MUST** be accepted. |
| FR-BTB-3 | The multi-dimensional array convention `TDIMn` **MUST** be supported to reshape a field's repeat count into an N-D array. |
| FR-BTB-4 | Per-column scaling/nulls **MUST** be supported: `TSCALn`, `TZEROn` (including the unsigned-int codes `U`/`V`/`W` and signed-byte `S` mapped to `I`/`J`/`K`/`B` with appropriate `TZEROn`), and `TNULLn` for integer nulls; IEEE NaN for floating nulls (using the documented NaN pattern from FR-IMG-8). |
| FR-BTB-5 | The API **MUST** support: locate column by name (case-insensitive, with the wildcard semantics and multi-match contract of FR-UTL-4) and by number; read/write whole columns, cell ranges, and individual elements; with datatype conversion (per FR-CONV-1) to/from Zig types. |
| FR-BTB-6 | Row operations **MUST** be supported: append, insert at position, delete range, and select/copy rows. Column operations **MUST** be supported: insert, append, delete, copy. |
| FR-BTB-7 | `A`-format string handling **MUST** define decode/encode semantics: within the repeat count, terminate at the first ASCII NUL, pad with spaces (NUL also accepted) on write, and treat a leading NUL as a null string. The distinct array conventions **SHOULD** be supported and named: `TDIMn` arrays-of-strings (see FR-BTB-3) and heap strings via `rPA`/`rQA` (see 3.7); the non-standard CFITSIO `rAw` substring shorthand is out of scope (see §7.1). |

### 3.7 Variable-Length Arrays & Heap — P1

| ID | Requirement |
|----|-------------|
| FR-VLA-1 | The library **MUST** support variable-length array columns declared with `TFORMn = rPt(emax)` (32-bit descriptors) and `rQt(emax)` (64-bit descriptors). The leading repeat count `r` on a `P`/`Q` field **MUST** be absent, `0`, or `1`; any other value **MUST** be rejected. |
| FR-VLA-2 | The heap area **MUST** be managed correctly: descriptors store a *signed* element count and a *signed* byte offset (measured from the start of the heap; negatives rejected, and offset+length bounds-checked against `[0, PCOUNT)`). `PCOUNT` **MUST** reflect the total supplemental-data length = (`THEAP` − `NAXIS1`×`NAXIS2`) gap + heap data. `THEAP` **MUST** be honored; when absent it defaults to `NAXIS1`×`NAXIS2`, which is also its minimum legal value (smaller **MUST** be rejected). |
| FR-VLA-3 | Reading and writing variable-length cells **MUST** transparently follow descriptors into the heap, applying datatype conversion and scaling as for fixed columns. |
| FR-VLA-4 | Writing **SHOULD** support heap compaction/garbage handling so rewritten variable cells do not unboundedly grow the heap. |

### 3.8 Random Groups — P2

| ID | Requirement |
|----|-------------|
| FR-RG-1 | The library **MUST** read the random-groups structure: mandatory keywords `SIMPLE=T`, `BITPIX`, `NAXIS`, `NAXIS1=0`, `NAXIS2`…`NAXISn`, `GROUPS=T`, `PCOUNT`, `GCOUNT` (in the FITS 4.0 §6 order, with no keywords intervening between `SIMPLE` and the last `NAXISn`), plus the reserved group keywords `PTYPEn`, `PSCALn`, `PZEROn`. |
| FR-RG-2 | Group parameters and the per-group data array **MUST** be accessible with scaling applied. Writing random groups **MAY** be supported (the format is deprecated for new files). |

### 3.9 World Coordinate System (WCS) — P2

| ID | Requirement |
|----|-------------|
| FR-WCS-1 | The library **MUST** parse and write WCS keyword sets: `WCSAXES`, `CTYPEn`, `CRPIXn`, `CRVALn`, `CDELTn`, `CUNITn`, the `CDi_j`/`PCi_j` matrices (mutually exclusive within an HDU), `PVi_m`, `PSi_m`, `LONPOLEa`/`LATPOLEa`, `RADESYSa`, `EQUINOXa`, and alternate WCS descriptions (`...a` suffix). The legacy `CROTAn` keyword **MUST** be read, but is deprecated and **MUST NOT** be written together with `PCi_j`/`PVi_m`/`PSi_m`. |
| FR-WCS-2 | Celestial coordinate transforms (pixel ↔ world) for the common projections defined by the standard (e.g. TAN, SIN, ARC, STG, ZEA, AIT, CAR, MER) **SHOULD** be provided, using `LONPOLEa`/`LATPOLEa` for the spherical-rotation step and `RADESYSa`/`EQUINOXa` for the reference frame. |
| FR-WCS-3 | Spectral coordinate keyword handling (`CTYPEn` spectral types, `RESTFRQ`, `RESTWAV`, `SPECSYS`) **SHOULD** be supported. |
| FR-WCS-4 | Time coordinate representation (`MJDREF`/`MJDREFI`/`MJDREFF`, `TIMESYS`, `TIMEUNIT`, `TREFPOS`, `DATE-OBS`, etc.) per FITS 4.0 Chapter 9 **SHOULD** be parseable and writable. |

### 3.10 Data Integrity — `CHECKSUM`/`DATASUM` — P1

| ID | Requirement |
|----|-------------|
| FR-SUM-1 | The library **MUST** compute and write `DATASUM` (the 32-bit 1's-complement checksum of the data unit, written as an **unsigned decimal character string**) and `CHECKSUM` (the whole-HDU 1's-complement checksum encoded in the standard 16-character ASCII form). `DATASUM` **MUST** be written/updated **before** `CHECKSUM` is accumulated. |
| FR-SUM-2 | The library **MUST** verify `DATASUM`/`CHECKSUM` on demand and report match / mismatch / not-present. |
| FR-SUM-3 | Checksum update **MUST** be available as an explicit operation and **MAY** be applied automatically on close when requested. |

### 3.11 Image & Table Compression — P2/P3

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-CMP-1 | The library **MUST** read tiled-compressed images (compressed image stored in a `BINTABLE` with `ZIMAGE=T`, `ZCMPTYPE`, `ZTILEn`, `ZNAXISn`, `ZBITPIX`, etc.), transparently decompressing to a normal image view. | P2 |
| FR-CMP-2 | The library **MUST** support the `GZIP_1` and `GZIP_2` tile compression algorithms. Both use the gzip container (RFC 1952 header / CRC32 / ISIZE) over DEFLATE (`std.compress`). `GZIP_2` additionally applies a type-aware byte shuffle (bytes reordered in decreasing significance, MSB-first; integer/float values only — **not** logical/bit/character) before compression; `std` does not provide this, so it (and its exact inverse on read) **MUST** be implemented in `zigfitsio`. | P2 |
| FR-CMP-3 | The library **SHOULD** support `RICE_1`, `PLIO_1`, and `HCOMPRESS_1` tile compression for read and write, honoring each algorithm's data constraints (`RICE_1`/`PLIO_1` integer-only; `PLIO_1` values in 0…2^24; `HCOMPRESS_1` 2-D tiles only) and rejecting invalid data/algorithm pairings with a typed error. | P3 |
| FR-CMP-4 | Writing tiled-compressed images **MUST** be supported for at least one algorithm, including the subtractive dithering options (`NO_DITHER`, `SUBTRACTIVE_DITHER_1/2`) for floating data. | P3 |
| FR-CMP-5 | Tiled-*table* compression (FITS 4.0 §10.3, which supersedes the earlier registered convention) **SHOULD** be supported (read at minimum). | P3 |

### 3.12 Extended Filename Syntax — P3

| ID | Requirement |
|----|-------------|
| FR-EFN-1 | The library **SHOULD** support CFITSIO-style extended filename parsing: HDU selection by number or `[extname,extver]`. The CFITSIO bracket index is **0-based** (`[0]` = primary), mapping to the 1-based programmatic HDU number (filename `[n]` ↔ HDU `n+1`). |
| FR-EFN-2 | Image-section specifiers (`img.fits[1:512:2, 1:512]`) **SHOULD** be supported. |
| FR-EFN-3 | On-the-fly column selection, row filtering (boolean expression calculator, including the `gtifilter()` and `regfilter()` GTI/SAO-region functions), and binning/histogram specifiers **MAY** be supported. |
| FR-EFN-4 | Output-file and template-file qualifiers in the extended name **MAY** be supported. |
| FR-EFN-5 | If implemented, the filename grammar **MUST** be documented and a programmatic (non-string) equivalent **MUST** also exist so the string DSL is never the only path. |

### 3.13 Iterator / Bulk Access — P2

| ID | Requirement |
|----|-------------|
| FR-ITR-1 | The library **SHOULD** provide a high-level iterator that drives a caller-supplied work function over image pixels or table columns in block-aligned chunks sized to satisfy NFR-PERF-1 (block-aligned, no per-element syscalls) and NFR-PERF-3 (bounded memory), handling buffering, datatype conversion, and null substitution. |
| FR-ITR-2 | The iterator **MUST** support input, output, and input/output column roles and per-call element-grouping control. |

### 3.14 Utility Routines — P1/P2

| ID | Requirement |
|----|-------------|
| FR-UTL-1 | The library **MUST** provide FITS date/time helpers: format and parse `DATE`/`DATE-OBS` (`yyyy-mm-ddThh:mm:ss[.sss]`), accept the deprecated `DD/MM/YY` form on read (year interpreted as 19YY, per FITS 4.0 §4.4.2.1), and convert to/from Julian/Modified-Julian dates. |
| FR-UTL-2 | The library **MUST** expose parsing/inspection helpers for `TFORM`/`TDISP` (type code, repeat, width, decimals) and ASCII-table column-position computation. |
| FR-UTL-3 | The library **MUST** expose its version and a human-readable message for every error value. |
| FR-UTL-4 | Case-insensitive keyword/column name comparison with `*` (any run), `?` (one character), and `#` (a run of digits) wildcards **MUST** be available. The match API **MUST** define its result contract — zero matches, exactly one, and the ordered list of all matches for multi-match queries — without relying on the CFITSIO status-iteration idiom (per FR-ERR-2). |
| FR-UTL-5 | The library **SHOULD** apply `TDISPn`/`TDISP` display formats to render column and keyword values as text and to compute the corresponding display width (equivalent to CFITSIO `fits_get_col_display_width`). |

### 3.15 Error-Handling Model — P0

| ID | Requirement |
|----|-------------|
| FR-ERR-1 | All fallible operations **MUST** return Zig error unions over well-defined error sets categorized by area (I/O, header syntax, keyword type/value, HDU structure, table/column, compression, checksum, conversion). |
| FR-ERR-2 | The library **MUST NOT** use the CFITSIO integer-status / inherited-status pattern in its public API; equivalent fail-fast behavior is provided naturally by `try`/error propagation. |
| FR-ERR-3 | The library **MUST** offer an optional diagnostic context object that records human-readable detail (file offset, keyword, card text) for the most recent failure, as a replacement for the CFITSIO error-message stack. |
| FR-ERR-4 | A stable mapping from `zigfitsio` errors to CFITSIO numeric status codes **SHOULD** be provided for tooling that reports compatible codes. |

### 3.16 Alternate & Remote Access — P3

| ID | Requirement |
|----|-------------|
| FR-RMT-1 | The library **MUST** support reading/writing via in-memory buffers and standard input/output streams. |
| FR-RMT-2 | The library **SHOULD** support transparently reading and writing whole-file gzip-compressed FITS (`.fits.gz`) using `std.compress`. |
| FR-RMT-3 | Remote read over HTTP/HTTPS via `std.http` **MAY** be supported (note: `std`'s TLS is TLS-1.3-only); FTP, if offered, requires a separate client, as `std` has no FTP module. |

### 3.17 Template-Based Creation — P3

| ID | Requirement |
|----|-------------|
| FR-TPL-1 | The library **MAY** support creating a FITS file from a CFITSIO-style ASCII header template (keyword lines, auto-indexing, parser directives). |
| FR-TPL-2 | A programmatic builder API **MUST** be the primary, fully supported way to construct HDUs; templates are a convenience layer over it. |

### 3.18 Structural Validation — P2

| ID | Requirement |
|----|-------------|
| FR-VAL-1 | The library **MUST** provide a verification pass that checks structural conformance to FITS 4.0: block sizing, mandatory keyword presence/order/type, value ranges, table geometry (binary tables: `NAXIS1` equals the summed `TFORM` field widths; ASCII tables: each `TBCOLn`+field width fits within `NAXIS1`, which **MAY** exceed the field extent), declared-vs-actual data sizes, and `END`/padding correctness. |
| FR-VAL-2 | Verification **MUST** report all findings (not just the first) classified as error vs warning, suitable for a `fitsverify`-style report. |

### 3.19 Numeric Conversion & Rounding — P1

| ID | Requirement |
|----|-------------|
| FR-CONV-1 | The library **MUST** define a single, documented numeric-conversion policy, applied wherever an on-disk value is converted to a differently-typed Zig value (and the reverse), and referenced by FR-HDR-13, FR-IMG-9, FR-ATB-4, and FR-BTB-5: (a) integer→integer and float→integer results outside the destination range **MUST** fail with a typed `Overflow` error; (b) float→integer rounding **MUST** be round-half-away-from-zero (matching CFITSIO); (c) widening that loses precision (e.g. `i64`/`u64`→`f64`) is permitted silently for **bulk** array/column transfers, but for **scalar keyword and single-cell** reads precision loss **MUST** be reported as a typed error. Any per-site deviation **MUST** be documented at that site. |
| FR-CONV-2 | Conversions **MUST NOT** invoke undefined behavior; range/overflow checks **MUST** occur before any truncation or wraparound. |

### 3.20 Hierarchical Grouping — P3

| ID | Requirement |
|----|-------------|
| FR-GRP-1 | The library **MUST** (within the P3 tier) read FITS *grouping tables* (the Hierarchical Grouping convention: a grouping `BINTABLE` carrying `GRPNAME` and the member-pointer columns `MEMBER_XTENSION`, `MEMBER_NAME`, `MEMBER_VERSION`, `MEMBER_POSITION`, `MEMBER_LOCATION`, together with the member-side `GRPIDn`/`GRPLCn` keywords) and resolve group membership to the referenced HDUs. |
| FR-GRP-2 | Creating and editing grouping tables (add/remove members; maintain `GRPIDn`/`GRPLCn`) **SHOULD** be supported. |

---

## 4. Non-Functional Requirements

### 4.1 Performance

| ID | Requirement |
|----|-------------|
| NFR-PERF-1 | Bulk image/column I/O **MUST** operate on block-aligned buffers and avoid per-element syscalls. As an explicit, non-binding goal (measured by the benchmark suite, not a release gate), throughput **SHOULD** be within ~2× of CFITSIO for equivalent bulk operations on the same hardware. |
| NFR-PERF-2 | Datatype conversion and byte-swapping **SHOULD** be vectorizable and **MUST NOT** allocate per element. |
| NFR-PERF-3 | Large files **MUST** be processable in bounded memory via streaming/chunked access; reading a multi-GB image **MUST NOT** require loading it entirely into RAM. |

### 4.2 Memory

| ID | Requirement |
|----|-------------|
| NFR-MEM-1 | Every allocation **MUST** use a caller-provided `Allocator`; the library **MUST NOT** use hidden global allocators. |
| NFR-MEM-2 | All owning types **MUST** provide `deinit`; the test suite **MUST** pass under `std.testing.allocator` / a leak-checking allocator with zero leaks. |

### 4.3 Safety & Robustness

| ID | Requirement |
|----|-------------|
| NFR-SAFE-1 | Parsing untrusted input **MUST NOT** cause panics, out-of-bounds access, integer overflow UB, or unbounded allocation. Resource limits (e.g. max header size, max HDU count, max heap/VLA size, max `NAXISn` product) **MUST** be enforceable, with documented defaults and a caller override API. Before allocating, declared sizes (product of `NAXISn`; `PCOUNT`/heap; each VLA descriptor's length+offset) **MUST** be validated against the actual stream length and the configured limits, failing with a typed error. |
| NFR-SAFE-2 | A fuzzing harness **MUST** exist for the header and table parsers; crashes/leaks found by fuzzing are release blockers. |

### 4.4 Portability

| ID | Requirement |
|----|-------------|
| NFR-PORT-1 | The library **MUST** build and pass tests on Linux, macOS, and Windows for x86_64 and aarch64. |
| NFR-PORT-2 | Correct behavior **MUST** be independent of host endianness. |
| NFR-PORT-3 | The core (excluding all OS-backed back-ends — on-disk file, stdin/stdout streams (FR-RMT-1), and remote/HTTP) **SHOULD** compile for `wasm32` / freestanding targets, with the in-memory buffer back-end as the freestanding I/O path; a `wasm32`-freestanding build **SHOULD** be exercised in CI. |

### 4.5 Concurrency

| ID | Requirement |
|----|-------------|
| NFR-CONC-1 | Library state **MUST** be confined to explicit handle objects; there **MUST** be no shared mutable global state. Distinct handles **MUST** be usable concurrently from different threads. A single handle is not required to be thread-safe; this **MUST** be documented. |

### 4.6 Interoperability

| ID | Requirement |
|----|-------------|
| NFR-INTEROP-1 | Files written by `zigfitsio` **MUST** be readable by CFITSIO and Astropy. Files written by those tools **MUST** be readable by `zigfitsio` to the extent of the implemented feature set; an HDU using an unimplemented `ZCMPTYPE`, convention, or extension **MUST** fail with a typed error rather than be silently mis-read. |
| NFR-INTEROP-2 | Round-trip (read → write → read) of standard sample files **MUST** preserve data and mandatory/reserved keyword semantics; byte-for-byte preservation is a goal where the format permits. |

### 4.7 API Stability & Versioning

| ID | Requirement |
|----|-------------|
| NFR-API-1 | The library **MUST** follow semantic versioning; public API changes **MUST** be reflected in version bumps and a changelog. |
| NFR-API-2 | Internal representations (handle fields) **MUST NOT** be part of the public contract. |

### 4.8 Build & Packaging

| ID | Requirement |
|----|-------------|
| NFR-BUILD-1 | The project **MUST** build with `zig build` and expose a Zig module consumable via `build.zig.zon` / `zig fetch`. |
| NFR-BUILD-2 | `zig build test` **MUST** run the full unit/integration suite; `zig build` **MUST** produce a static library artifact. |

### 4.9 Testing & Conformance

| ID | Requirement |
|----|-------------|
| NFR-TEST-1 | Unit tests **MUST** cover header parsing/formatting, each `BITPIX`, each `TFORM` code, scaling, nulls, var-length arrays, and checksums. |
| NFR-TEST-2 | A corpus of real/standard sample FITS files (images, ASCII tables, binary tables, var-length, compressed) **MUST** be exercised for read and round-trip. |
| NFR-TEST-3 | Cross-validation tests **SHOULD** compare `zigfitsio` output against CFITSIO/Astropy output for the same inputs. |
| NFR-TEST-4 | Conformance to FITS 4.0 structural rules **MUST** be tested with both valid and deliberately malformed fixtures. |
| NFR-TEST-5 | The suite **MUST** include (a) a multi-threaded test exercising distinct handles concurrently plus a documentation-presence check for the single-handle caveat (NFR-CONC-1), and (b) a fixed-corpus interoperability test that reads files written by CFITSIO/Astropy (the inbound leg of NFR-INTEROP-1). |

### 4.10 Documentation & Licensing

| ID | Requirement |
|----|-------------|
| NFR-DOC-1 | Every public declaration **MUST** carry doc comments; a usage guide with examples (create image, read table, etc.) **MUST** be provided. |
| NFR-DOC-2 | A license **MUST** be chosen and applied; it **MUST** be compatible with redistribution and independent of CFITSIO's terms (no CFITSIO code is used). |

---

## 5. Data Type Mapping (Reference)

### 5.1 Image `BITPIX` ↔ Zig

| BITPIX | FITS meaning | Zig stored type | Notes |
|-------:|--------------|-----------------|-------|
| 8 | unsigned byte | `u8` | signed-byte via `BZERO=-128` |
| 16 | signed 16-bit int | `i16` | unsigned via `BZERO=32768` |
| 32 | signed 32-bit int | `i32` | unsigned via `BZERO=2^31` |
| 64 | signed 64-bit int | `i64` | unsigned via `BZERO=2^63` |
| −32 | IEEE single | `f32` | NaN = null |
| −64 | IEEE double | `f64` | NaN = null |

### 5.2 Binary-table `TFORM` ↔ Zig

| Code | FITS type | Zig element type |
|------|-----------|------------------|
| `L` | logical | `bool` |
| `X` | bit | packed bits → `u1`/`[]u8` |
| `B` | unsigned byte | `u8` |
| `I` | 16-bit int | `i16` |
| `J` | 32-bit int | `i32` |
| `K` | 64-bit int | `i64` |
| `A` | character | `u8` / string |
| `E` | single float | `f32` |
| `D` | double float | `f64` |
| `C` | single complex | `[2]f32` |
| `M` | double complex | `[2]f64` |
| `P` | array descriptor (32-bit) | `{ len: i32, off: i32 }` (signed two's-complement; negatives rejected) |
| `Q` | array descriptor (64-bit) | `{ len: i64, off: i64 }` (signed two's-complement; negatives rejected) |
| `U`/`V`/`W` | unsigned 16/32/64 (CFITSIO ext.) | `u16`/`u32`/`u64` (stored as `I`/`J`/`K` + `TZERO`) |
| `S` | signed byte (CFITSIO ext.) | `i8` (stored as `B` + `TZERO=-128`) |

### 5.3 ASCII-table `TFORM` ↔ Zig

| Code | Meaning | Zig type |
|------|---------|----------|
| `Aw` | character string | string |
| `Iw` | integer | `i64` |
| `Fw.d` | fixed-point float | `f64` |
| `Ew.d` | exponential float | `f64` |
| `Dw.d` | exponential double | `f64` |

### 5.4 Keyword value ↔ Zig

| FITS value type | Zig representation |
|-----------------|--------------------|
| integer | `i64` |
| floating | `f64` |
| complex integer/float | `[2]i64` / `[2]f64` |
| logical | `bool` |
| string | `[]const u8` (allocator-owned) |
| commentary/blank | free text `[]const u8` |
| undefined (blank value field) | `.undefined` tag (no payload) |

---

## 6. Priority / Phasing Summary

| Tier | Areas |
|------|-------|
| **P0** | GC-* constraints; 3.1 Low-level I/O; 3.2 Headers (core); 3.3 HDU management; 3.4 Images (core types & full/partial pixel I/O); 3.15 Error model. |
| **P1** | 3.2 Headers (CONTINUE, full edit ops); 3.4 Images (scaling, unsigned, nulls, subsets); 3.5 ASCII tables; 3.6 Binary tables; 3.7 Variable-length arrays; 3.10 Checksum; 3.14 Utilities; 3.19 Numeric conversion. |
| **P2** | 3.2 HIERARCH/units/header-space/INHERIT; 3.4 Images (signed-byte, resize/redefine); 3.8 Random groups; 3.9 WCS; 3.11 Compression (read, GZIP); 3.13 Iterator; 3.14 TDISP formatting; 3.18 Validation. |
| **P3** | 3.11 Compression (Rice/PLIO/HCOMPRESS/write, tiled tables); 3.12 Extended filename syntax; 3.16 Remote/gzip access; 3.17 Templates; 3.20 Hierarchical grouping. |

---

## 7. Out of Scope & Open Questions

### 7.1 Out of Scope (initial)

- `@cImport` usage, bundling CFITSIO C source, or a C-ABI drop-in shim exporting `fits_*`/`ff*` symbols (a C-export layer **MAY** be reconsidered later but is explicitly excluded now).
- GUI/visualization, image display, and plotting.
- Non-FITS input formats that CFITSIO can ingest (e.g. IRAF `.imh/.pix`, raw/foreign-file encapsulation) — candidate for a much later, optional add-on.
- The full CFITSIO row-filter expression calculator is **MAY**-only (FR-EFN-3); a complete expression engine is not committed.
- The non-standard CFITSIO `rAw` substring-array shorthand for `A`-format columns (FR-BTB-7) is excluded; standard `TDIMn` arrays-of-strings and heap strings cover the use case.

### 7.2 Open Questions

1. Should a CFITSIO C-compatible export layer be added as a later, separate module (for drop-in replacement use cases)?
2. Which license (e.g. MIT, Apache-2.0, BSD-3) should apply?
3. Target breadth for WCS transforms — full projection set vs. the most common subset?
4. Minimum set of compression algorithms required for a 1.0 release (GZIP-only vs. also Rice/HCOMPRESS)?
5. Should whole-file gzip and remote HTTP access ship in 1.0 or be deferred to an extension package?

---

## 8. References

- *Definition of the Flexible Image Transport System (FITS)*, Version 4.0 (2018). IAU FITS Working Group. <https://fits.gsfc.nasa.gov/standard40/fits_standard40aa-le.pdf>
- *CFITSIO User's Reference Guide*. HEASARC/NASA GSFC. <https://heasarc.gsfc.nasa.gov/docs/software/fitsio/c/c_user/>
- *CFITSIO Quick Start Guide*. HEASARC/NASA GSFC.
- *A Primer on the FITS Data Format*. HEASARC/NASA GSFC.
- Registry of FITS Conventions. <https://fits.gsfc.nasa.gov/fits_registry.html>

---

## 9. Glossary

| Term | Definition |
|------|------------|
| **HDU** | Header/Data Unit: a header followed by an optional data unit. |
| **Primary HDU** | The first HDU (primary array) in a FITS file. |
| **Extension** | Any HDU after the primary HDU. |
| **CHDU** | Current Header/Data Unit — the HDU a handle is positioned on. |
| **Card** | An 80-character keyword record in a header. |
| **Block** | A 2880-byte logical record; all units are integral multiples of it. |
| **Heap** | Area after a binary table's main rows holding variable-length array data. |
| **Descriptor** | `P`/`Q` entry giving the length and heap offset of a variable-length array. |
| **BITPIX** | Keyword giving the per-pixel data type/size of an image. |
| **TFORM** | Keyword giving the data type/repeat of a table column. |
| **WCS** | World Coordinate System: mapping array pixels to physical/world coordinates. |
