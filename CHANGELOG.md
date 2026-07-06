# Changelog

All notable changes to `zigfitsio` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (`NFR-API-1`).

## [Unreleased]

_Nothing yet._

## [0.1.2] - 2026-07-05

### Added
- **TypeScript/JavaScript bindings** (`bindings/typescript/`, npm package `zigfitsio`):
  full parity with the Python bindings over the same `zf_*` C ABI, mirroring the two-layer
  design — `zigfitsio/lowlevel` (all 85 symbols, typed `FitsError` hierarchy, the
  `ZfOpenOpts`/`ZfScaling`/`ZfColInfo` codecs) under an astropy-style high level
  (`open`/`HDUList`/HDU classes/`Header`/`Column`/`verify`, images as `FitsArray`
  TypedArrays, columnar `TableData` incl. VLA/complex/string columns, all compression codecs
  incl. lossy HCOMPRESS + quantized floats, WCS, checksums, gzip, in-memory files).
  **Distributed as a single, platform-independent WebAssembly module** (`zigfitsio.wasm`, the
  `zf_*` C-ABI shim compiled to a zero-import `wasm32-freestanding` reactor via `zig build
  wasm`) bundled in the one npm package — no native addons, no per-platform packages, and no
  runtime dependencies. A backend-neutral FFI layer marshals the ABI into WebAssembly linear
  memory (`src/ffi/wasm.ts`); on **Node/Bun** the module loads synchronously at import
  (classic no-`await` API), while **browsers** call `await ready()` once. File I/O is a
  JS-side convenience over the in-memory ABI (path-based on Node/Bun; `fromBytes`/`toBytes`
  in the browser). 149 tests mirror the pytest suites (incl. the golden corpus) on both
  runtimes, plus a TS↔Python interop cross-check; published via npm trusted publishing in
  `.github/workflows/typescript.yml`.
- **TypeScript bindings — TS-native ergonomic layer** over the same astropy-shaped classes,
  added so idiomatic TypeScript callers no longer need `as` casts to reach typed data:
  - **HDU discriminant + typed accessors:** every HDU carries a `kind` string literal
    (`"primary"|"image"|"compimage"|"bintable"|"asciitable"`) for narrowing `AnyHDU`, and
    `HDUList.image(key)` / `table<T>(key)` assert the flavor and return a narrowed `.data`
    (`FitsArray | null` / `TableData<T> | null`), throwing `FitsTypeError` on a mismatch.
  - **Discriminated columns + typed reads:** `ColumnData` is now a union
    (`NumericColumn | ComplexColumn | StringColumn | VlaColumn`) so a `switch (col.kind)`
    narrows `values`; `TableData` gains typed `numeric`/`strings`/`vla`/`complex` accessors and
    an optional `TableData<T>` column-shape parameter making `get(name)` return the declared
    array type.
  - **Row view:** `TableData` is iterable over plain per-row objects — `row(i)`, `rows()`,
    `[Symbol.iterator]`, `toArray()` — numeric cells unwrapping to scalars (repeat 1) or
    zero-copy TypedArray slices; adds `numRows`/`numCols`.
  - **`Header` iterates `[keyword, value]` entries** like a JS `Map` (previously yielded bare
    keyword strings), with `forEach`/`size`; `keys()` still returns the keywords. This only
    reshapes the not-yet-released TS binding, so no released API is affected.
  - **Arrow-style factories:** `tableFromArrays({col: TypedArray | string[] | …})` (inferring
    each `TFORM`) and `imageFromArray(data, shape)`.
  - **Element-typed arrays + cutouts:** `FitsArray<T>.get/set` type as `bigint` for 64-bit
    arrays and `number` otherwise, and `ImageHDU.section({ window, step })` reads a strided
    sub-region over the C ABI without materializing the whole image (fail-loud on a
    tile-compressed image — read `.data`; flushes pending in-place edits first in update mode).
  - **Correctness:** in-place table write-back resolves columns by file name, not iteration
    index, so editing a reordered `TableData` writes each column to its true on-disk slot
    (an unknown column name fails loud). The honest boundaries of this surface are documented
    in `CAVEATS.md §3`. 40 TS-specific tests run on both runtimes; the public generics (and two
    `@ts-expect-error` negatives) are type-checked via `tsconfig.test.json`
    (`npm run typecheck:tests`, wired into CI).
- **`HCOMPRESS_1` lossy is complete — the last codec gap is closed** (was: lossless-only decode,
  no `hsmooth`). All CFITSIO-parity, verified bit-exact:
  - **Decode smoothing (`hsmooth`):** the CFITSIO coefficient-interpolation pass now runs inside
    the inverse H-transform when a file requests it (`ZNAME2='SMOOTH'`/`ZVAL2`), reproducing
    `fits_hdecompress`/`funpack` bit-for-bit. The committed, reproducible evidence is the new
    golden pairs — `tile_hcompress_{lossy16,lossy32,smooth}.fits` + funpack-authored
    `*_expected` pixel files, exact-match asserted with a non-vacuousness gate — plus the CI
    `interop` job (Astropy agrees on the same bytes); broader authoring-time verification
    against the CFITSIO 4.6.4 dylib (10 shape/scale/pattern decode cases) used a local harness
    that is not committed. Adversarial streams keep the fail-loud contract
    (`error.CorruptTile`, never a panic/overflow).
  - **Lossy write:** `CompressSpec.hcomp_scale` (CFITSIO `fits_set_hcomp_scale` semantics —
    `0` lossless default, `< 0` absolute per-tile scale, `> 0` noise-adaptive
    `round(request × background sigma)`) and `CompressSpec.hcomp_smooth` (records the SMOOTH
    request). The noise estimators are an exact port of CFITSIO `FnNoise5_int`/
    `quick_select_longlong` (`src/compress/imgstats.zig`, quirks included and documented);
    two committed reference vectors pin `fits_img_stats_int` bit-exactness at the f64-bit
    level (broader 12-case authoring-time verification used the uncommitted harness). `ZVAL1`
    is now the float request card and `ZNAME2/ZVAL2` are always written for HCOMPRESS,
    matching CFITSIO's header layout. `funpack` decodes zigfitsio's lossy output to exactly
    the pixels zigfitsio itself decodes (`interop/check_funpack.py`), and Astropy agrees.
  - **Bindings:** `zf_write_compressed2` (ABI-additive C entry point with the two knobs) and
    `CompImageHDU(..., hcomp_scale=, hcomp_smooth=)` (astropy-compatible kwargs); re-emitting a
    scanned lossy HCOMPRESS image preserves its recorded SCALE/SMOOTH request.

### Changed
- **HCOMPRESS default tiling** now follows CFITSIO's `imcomp_init_table` row-block rule (whole
  image ≤ 30 rows, else the 16/24/…/14→17 preference keeping the last tile ≥ 4 rows) instead of
  row-by-row strips — the codec is inherently 2-D, and Astropy refuses 1-row HCOMPRESS tiles.
  Explicit `tile=` specifications are unaffected — with the documented asterisk that zigfitsio
  deliberately keeps accepting explicit HCOMPRESS tiles CFITSIO's *author* would reject
  (dimensions under 4 pixels): they decode correctly everywhere tested (zigfitsio, funpack),
  but sit outside CFITSIO's authoring envelope, and Astropy refuses tiles that squeeze to 1-D
  (see `CompressSpec.tile`).
- Misusing the HCOMPRESS lossy knobs (non-finite scale, or either knob with a non-HCOMPRESS
  codec) is `error.DataConstraintViolated` — never silently ignored.
- **Python support:** dropped end-of-life CPython 3.9 and added CPython 3.14 wheels, including
  the free-threaded (no-GIL) `cp314t` build. Minimum supported Python is now 3.10. The
  `cp314t` wheel is built and shipped but its test suite is skipped in CI until free-threaded
  `numpy`/`astropy` wheels are available on the built platforms.

## [0.1.1] - 2026-07-02

### Fixed
A swarm bug hunt over the ctypes bindings + C-ABI boundary fixed 27 confirmed defects (the prior
suite exercised none of these paths; `bindings/python/tests/test_bugfixes.py` now pins them):
- **Critical:** `open()` → `writeto()`/`to_bytes()` no longer silently drops image/table data — an
  attached HDU list is copied byte-faithfully (raw device passthrough), and the reconstruction path
  serializes materialized data for detached/mixed lists.
- **Crashes:** using an attached HDU after `close()`, and `verify()` on a Python-built HDU list, now
  raise `FitsError` instead of segfaulting; the C-ABI `zf_*` exports null-check their handle
  argument (`NULL_INPUT_PTR`, 104).
- **Silent corruption:** non-native-endian arrays are coerced to native before write; numpy scalar
  header values (`np.int64/np.float32/np.bool_`) are written with the correct FITS type; out-of-range
  integer keywords raise instead of wrapping; non-ASCII table strings and ragged/empty tables raise.
- **Reads:** binary-table columns honor `TSCAL`/`TZERO` (fractional scaling → float; unsigned
  `TZEROn` → `u2/u4/u8`, no more overflow); VLA columns decode with their real element type (not
  always `float64`); long-string `CONTINUE` values and `HIERARCH` keywords are parsed.
- **Writes (feature completion):** unsigned `u2/u4/u8` images and columns, and variable-length-array
  columns, are now writable; update-mode image data edits are written back on `flush()`.
- **API/packaging:** `getdata` falls through an empty primary and `hdul['PRIMARY']` resolves
  (astropy parity); the wheel build hook and dev loader find the Windows DLL under `zig-out/bin` and
  derive the library name + wheel tag from `ZIG_TARGET`; image element-count ABI widened to 64-bit.

Core-library and build fixes in the same window:
- **WCS:** `altSuffix` no longer returns a dangling stack temporary — alternate-WCS keyword
  lookups misbehaved in ReleaseFast builds (Debug's stack layout masked it).
- **I/O:** `appendHdu` rolls back device growth when it fails after the header write; `sync` on a
  read-only file device is a no-op (Windows `FlushFileBuffers` fails on read-only handles, which
  POSIX `fsync` had masked).
- **Packaging/CI:** wheel builds fixed on Windows (skip 32-bit `*-win32`) and macOS (pin the 11.0
  deployment target); the retired `macos-13` runner replaced with `macos-15-intel`.

### Added
- `zf_create_tbl_heap` C-ABI entry point (reserves `PCOUNT` heap for VLA writes).

## [0.1.0] - 2026-06-30

### Added
- Build scaffolding: `zig build` (static library), `test`, `bench`, `fuzz`, and
  `wasm-check` steps; dependency-free `build.zig.zon` (`SETUP-1`).
- MIT license; README usage examples and changelog (`X-DOC`).
- **M0 foundation:** error sets + CFITSIO status map, diagnostics, version/`errorText`,
  resource limits with validate-before-allocate, big-endian access, numeric-conversion policy.
- **I/O layer:** `Device` vtable; in-memory, file, and stream backends; 2880-byte block
  buffering with the correct pad kinds.
- **Header layer:** keyword name normalization + wildcard matching, value parsing (the
  null/empty/undefined distinction, `CONTINUE`, `HIERARCH`), 80-byte cards, the header
  container with read + full edit operations and header-space pre-allocation.
- **HDU model & `Fits` handle:** kind detection, mandatory-keyword validation, lazy HDU scan,
  navigation, and the programmatic image/HDU builders.
- **HDU editing (`FITS-1b`):** a block-aligned data-resize + following-HDU shift primitive
  (`resizeHduData`/`refreshGeometry`/`rewriteHeaderInPlace`), plus `deleteHdu`/`copyHdu`.
- **Images:** `ImageView` over all six `BITPIX`; full/contiguous/strided-section pixel I/O;
  `BSCALE`/`BZERO` scaling; unsigned-integer convention; `BLANK`/NaN nulls; `reshape` (`IMG-7`).
- **Tables:** ASCII and binary tables (all `TFORM` codes, scaling, nulls, `A`-format,
  `TDIM`), variable-length arrays with a compacting heap; binary-table row/column structural
  operations — append/insert/delete/copy rows and columns (`BTB-3b`).
- **Integrity:** `DATASUM`/`CHECKSUM` compute/update/verify.
- **WCS:** keyword set parse/serialize; celestial transforms (zenithal family + `CAR`);
  spectral and time-coordinate keywords.
- **Compression:** GZIP_1/GZIP_2 codecs and the type-aware byte shuffle; RICE_1, PLIO_1, and
  HCOMPRESS_1 tile codecs; subtractive dithering with the Park–Miller generator; a tiled
  compressed-image **write** path; and tile-compressed-table (`ZTABLE`) reading.
- **Extended I/O & convenience:** CFITSIO-style extended-filename DSL → `FileSpec` (`EFN-1`);
  whole-file gzip backend (`RMT-1`); ASCII header-template loader (`TPL-1`); hierarchical
  grouping tables, read and edit (`GRP-1`).
- **Utilities:** date/time + Julian-Date helpers; `TFORM`/`TDISP` parsing.
- **Cross-cutting:** fuzz harnesses for the parsers; a CI portability matrix
  (incl. a big-endian QEMU cell and a wasm32-freestanding build); real bulk-image throughput
  benchmarks (`X-BENCH`); and the **full** upper-layer stack now compiles for
  wasm32-freestanding (`X-WASM`).
- **HTTP(S) range-GET backend (`RMT-2`):** `src/io/http.zig`'s `HttpDevice` serves a remote
  FITS file as a seekable read-only `Device` via Range GETs, falling back to a full in-memory
  download when the server lacks range support; excluded from the freestanding build graph.
- A transparent `.fits.gz` open path and a committed sample FITS corpus.
- **In-house end-to-end harness (`test/e2e.zig`):** a CFITSIO `testprog.c`-equivalent that builds a
  maximal multi-HDU file exercising every `BITPIX`/`TFORM`, all four tile codecs, VLA, WCS,
  `CONTINUE`/`HIERARCH`, and checksums, then reopens and asserts — plus a deterministic
  byte-snapshot regression tripwire. New `zig build e2e` step.
- **CFITSIO 4.6.4 golden corpus (`test/golden/`, `X-FIXTURES`):** reference tiles
  (RICE/GZIP/PLIO/HCOMPRESS), a checksum vector, images, tables, WCS, and conformance fixtures,
  authored by `fpack` + a CFITSIO C generator under `interop/` (`MANIFEST.json` with sha256),
  consumed hermetically by `test/golden.zig` on every cell (incl. big-endian s390x).
- **`interop` CI job (`X-XVAL`/`X-INTEROP`/`X-CONF`):** opens every zigfitsio-written file with
  CFITSIO `funpack`, Astropy, and `fitsverify` (`tools/emit_fixtures.zig`, `zig build
  emit-fixtures`); path-gated and toolchain-isolated from the hermetic matrix.
- **C-ABI shim (`bindings/capi/`, `zig build capi`):** a dynamic library `zigfitsio_capi`
  exporting `zf_*` symbols over the public Zig module. The comptime-generic API is monomorphized
  behind runtime datatype codes; Zig errors map to CFITSIO-compatible status ints via
  `errors.cfitsioStatus`, with a thread-local last-error (message + `Diagnostics` detail). Covers
  the full surface: lifecycle (file/memory/gzip), HDU navigation + delete/copy, header read/edit,
  images (read/write/section/reshape with scaling + nulls), binary & ASCII tables, VLAs, tiled
  compression write, checksum, structural validation, and WCS celestial transforms. The
  hand-written contract is `bindings/c/zigfitsio.h`; `zig build capi-test` round-trips the ABI.
  This is **not** a CFITSIO `fits_*`/`ff*` drop-in — it is a purpose-built ABI for bindings.
- **Python bindings (`bindings/python/`):** a low-level `ctypes` 1:1 binding (`zigfitsio.lowlevel`)
  with a typed `FitsError` hierarchy, and a high-level NumPy-first API (`zigfitsio`) modeled on
  `astropy.io.fits` — `open`, `HDUList`, `Primary`/`Image`/`CompImage`/`BinTable`/`AsciiTable`
  HDUs, `Column`, a dict-like `Header`, `getdata`/`getheader`/`getval`/`writeto`/`verify`, and
  celestial WCS. Includes a pytest suite (low + high level, **Astropy cross-checks both
  directions**, and the committed golden corpus), packaging (`pyproject.toml` + a hatch build hook
  that compiles and bundles the shared library), and a cibuildwheel matrix workflow.

### Fixed
- **FITS-conformance correctness pass:** ASCII-table fields now space-fill (not NUL/zero) per
  `FR-IO-2`; the `CONTINUE`/`HIERARCH`/complex-value header API is wired through
  `getLongString`/`appendLongString`/`getHierarch`/`getComplex`; float-exponent formatting
  follows §4.2.4 and FORTRAN-real parsing accepts `D`/`E` exponents; `TDISP` `EN`/`ES`/`G`
  rendering; `copyHdu` rolls back cleanly on partial failure; write-path keyword-order
  validation; WCS `CAR`/`LATPOLE` pole rotation corrected; `MJDREF` precedence + a time-keyword
  writer and completeness fixes; image-section streaming; `TDIM` string arrays; heap-bounds
  hardening; and grouping-table fixes.
- **Standard-wire-format codec rewrites:** `PLIO_1` now follows the FITS Table 38 instruction
  set and `HCOMPRESS_1` the White-1992 quadtree wire format; tiled `ZBLANK`, transparent
  compressed-image reads (`ImageView.of`), and the write-side codec wiring are all in place.
- **Iterator** null substitution.
- **`PLIO_1` was not CFITSIO-interoperable in either direction:** the codec omitted the IRAF/CFITSIO
  7-word line-list header and stored `COMPRESSED_DATA` as `1PB` instead of `1PI`. Both fixed —
  zigfitsio now reads genuine CFITSIO PLIO tiles and writes tiles `funpack`/Astropy decode to the
  exact pixels (caught by the golden corpus).
- **`checksum_on_close` was a silent no-op:** the `flush` hook was declared but never registered, so
  no `DATASUM`/`CHECKSUM` was written. Now wired (`src/fits.zig` reserves the cards at HDU-build
  time; `src/checksum.zig` registers `updateAll`).

### Notes
- The HTTP(S) range-GET backend (`RMT-2`) is **done**.
- **Byte-exact CFITSIO 4.6.4 / Astropy golden-corpus parity is now done** (`X-FIXTURES`/`X-SUM`/
  `X-XVAL`/`X-CONF`/`X-INTEROP`): the tile codecs and checksum are verified against committed CFITSIO
  tiles both inbound and outbound. The then-remaining codec limit — `HCOMPRESS_1` lossy `hsmooth`
  (lossless only at the time) — has since been closed (see `[Unreleased]`); `CAVEATS.md §1`.
