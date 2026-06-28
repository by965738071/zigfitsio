# Caveats & Known Limitations

Honest caveats for the FITS-conformance hardening work delivered on branch
`finish-fits-conformance` (commits `1c0c244`…`a7f4fb3`). The library builds clean and
passes **429/429 tests**, `zig build wasm-check`, `zig build fuzz`, and `zig build bench`,
with **zero `@cImport`** (pure Zig std, `GC-1`/`GC-2`).

There are two caveats worth stating plainly.

## 1. Tile-codec interoperability is not byte-exact-verified

The `PLIO_1` and `HCOMPRESS_1` tile codecs were rewritten from bespoke,
non-interoperable encodings to their **documented standard wire formats**:

- **`PLIO_1`** — FITS 4.0 §10.4.3 / Table 38 line-list instruction encoding (16-bit
  `sign|opcode|data` words). The standard text prints opcode `05` for **both** `PN` and
  `SH`, which is impossible; this implementation resolves the clash by assigning `SH` the
  otherwise-unused opcode `1`, matching the IRAF/CFITSIO `pl_p2li` convention. The
  resolution is documented in the `src/compress/plio.zig` module header.
- **`HCOMPRESS_1`** — White (1992) integer H-transform + quadtree nibble coding, ported
  from the published algorithm and the CFITSIO `fits_hcompress.c` structure. This is a
  **best-effort reimplementation**; lossy decode smoothing (`hsmooth`) is not implemented
  (the lossless path only).

**What _is_ verified:** both codecs pass **lossless self round-trip** tests (this library's
encoder → this library's decoder) across randomized and edge-case inputs, as do `RICE_1`,
`GZIP_1`/`GZIP_2`, and the tiled write path.

**What is _not_ verified:** **byte-exact parity against CFITSIO 4.6.4 / Astropy / IRAF.**
Confirming true cross-tool interoperability requires generating reference tiles with an
external CFITSIO + Astropy toolchain, which is **not available in this environment**. Until
that golden-corpus parity is established, treat the cross-tool interoperability of
`PLIO_1`/`HCOMPRESS_1` output as **unconfirmed** — round-trip-correct within zigfitsio, but
not yet proven byte-identical to the reference implementations.

The same external-toolchain limitation applies to:

- byte-exact `CHECKSUM`/`DATASUM` parity over CFITSIO-authored bytes (the algorithm is
  pinned against the FITS Appendix J.3 vector; the differential space-fill property is
  tested), and
- WCS reference-point parity vs WCSLIB/Astropy (meanwhile checked by `CRPIX→CRVAL` and
  pixel→world→pixel round-trips).

These are tracked as the `X-FIXTURES` / `X-SUM` / interop-CI tasks in `tasks.md`, marked
`blocked` because they depend on a CFITSIO 4.6.4 + Astropy environment.

## 2. Delivery status — unmerged branch (point-in-time)

As of this commit, the conformance-hardening work lives on branch
`finish-fits-conformance` and has **not been merged to `main` or pushed to `origin`**. It
is organized as four self-contained, individually-green commits, so it can be reviewed,
merged, or reset at batch granularity:

| Commit | Scope |
|--------|-------|
| `1c0c244` | FITS-conformance correctness bugs (ASCII space-fill, CONTINUE/HIERARCH/complex header API, §4.2.4 float exponent, CAR/LATPOLE WCS, MJDREF precedence, copyHdu rollback, write-path keyword-order validation, image-section streaming, TDIM string arrays, heap hardening, group-table fixes) |
| `2f0aadb` | Standard-format `PLIO_1`/`HCOMPRESS_1` rewrites + tiled `ZBLANK`/transparent/write-codec wiring |
| `3271d65` | HTTP range-GET backend, `.fits.gz` open path, iterator null substitution, committed sample corpus, failure-path tests |
| `a7f4fb3` | Doc/status reconciliation (README, CHANGELOG, design.md, tasks.md, code comments, CI) |

This section is a snapshot of the delivery state and becomes moot once the branch is
merged.
