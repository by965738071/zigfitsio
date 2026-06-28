# Changelog

All notable changes to `zigfitsio` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (`NFR-API-1`).

## [Unreleased]

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

### Fixed / changed
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

### Added (this batch)
- **HTTP(S) range-GET backend (`RMT-2`):** `src/io/http.zig`'s `HttpDevice` serves a remote
  FITS file as a seekable read-only `Device` via Range GETs, falling back to a full in-memory
  download when the server lacks range support; excluded from the freestanding build graph.
- A transparent `.fits.gz` open path and a committed sample FITS corpus.

### Added (e2e & interop batch)
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

### Fixed (interop bugs caught by the golden corpus)
- **`PLIO_1` was not CFITSIO-interoperable in either direction:** the codec omitted the IRAF/CFITSIO
  7-word line-list header and stored `COMPRESSED_DATA` as `1PB` instead of `1PI`. Both fixed —
  zigfitsio now reads genuine CFITSIO PLIO tiles and writes tiles `funpack`/Astropy decode to the
  exact pixels.
- **`checksum_on_close` was a silent no-op:** the `flush` hook was declared but never registered, so
  no `DATASUM`/`CHECKSUM` was written. Now wired (`src/fits.zig` reserves the cards at HDU-build
  time; `src/checksum.zig` registers `updateAll`).

### Notes
- The HTTP(S) range-GET backend (`RMT-2`) is **done**.
- **Byte-exact CFITSIO 4.6.4 / Astropy golden-corpus parity is now done** (`X-FIXTURES`/`X-SUM`/
  `X-XVAL`/`X-CONF`/`X-INTEROP`): the tile codecs and checksum are verified against committed CFITSIO
  tiles both inbound and outbound. The one remaining codec limit is `HCOMPRESS_1` lossy `hsmooth`
  (lossless only); see `CAVEATS.md §1`.
