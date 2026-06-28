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
- **Images:** `ImageView` over all six `BITPIX`; full/contiguous/strided-section pixel I/O;
  `BSCALE`/`BZERO` scaling; unsigned-integer convention; `BLANK`/NaN nulls.
- **Tables:** ASCII and binary tables (all `TFORM` codes, scaling, nulls, `A`-format,
  `TDIM`), variable-length arrays with a compacting heap.
- **Integrity:** `DATASUM`/`CHECKSUM` compute/update/verify.
- **WCS:** keyword set parse/serialize; celestial transforms (zenithal family + `CAR`);
  spectral and time-coordinate keywords.
- **Compression:** GZIP_1/GZIP_2 codecs and the type-aware byte shuffle.
- **Utilities:** date/time + Julian-Date helpers; `TFORM`/`TDISP` parsing.
- **Cross-cutting:** fuzz harnesses for the parsers; a CI portability matrix
  (incl. a big-endian QEMU cell and a wasm32-freestanding build).
