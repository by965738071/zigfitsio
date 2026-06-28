# Caveats & Known Limitations

Honest caveats for the FITS-conformance hardening work delivered on branch
`finish-fits-conformance`. The library builds clean and passes **459/459 tests**,
`zig build wasm-check`, `zig build fuzz`, and `zig build bench`, with **zero `@cImport`**
(pure Zig std, `GC-1`/`GC-2`).

The cross-tool interoperability previously listed here as *unconfirmed* is now **verified
against CFITSIO 4.6.4 + Astropy** (§1); the genuinely-remaining limits are stated plainly below.

## 1. Tile-codec & checksum interoperability — now verified against CFITSIO 4.6.4

This was previously the headline caveat: `PLIO_1`/`HCOMPRESS_1` and the `CHECKSUM`/`DATASUM`
parity were round-trip-correct *within* zigfitsio but **not proven byte-identical to the
reference implementations**, because no CFITSIO/Astropy toolchain was available.

That gap is now closed. A committed **golden corpus authored by CFITSIO 4.6.4 + `fpack`** lives
under `test/golden/` (generators under `interop/`), consumed hermetically by `test/golden.zig`
on every CI cell, plus a dedicated **`interop` CI job** that opens every zigfitsio-written file
with CFITSIO `funpack`, Astropy, and `fitsverify`. Authoring this corpus surfaced — and this
branch fixes — **two real interop bugs** that the prior self-round-trip tests could not catch:

- **`PLIO_1` was not CFITSIO-interoperable in either direction.** The codec omitted the
  CFITSIO/IRAF **7-word line-list header** and stored `COMPRESSED_DATA` as `1PB` (byte VLA)
  rather than `1PI` (16-bit-integer VLA, which CFITSIO byte-swaps on read). Both are fixed in
  `src/compress/{plio,tiled}.zig`: zigfitsio now decodes genuine CFITSIO PLIO tiles **and**
  emits tiles `funpack`/Astropy read back to the exact pixels. (The opcode set was already
  correct — `SH = 1`, per `pl_p2li` — which is why only the header/TFORM were wrong.)
- **`checksum_on_close` was a silent no-op.** The flush hook (`Fits.checksum_hook`) was declared
  but never registered, so `checksum_on_close = true` wrote no `DATASUM`/`CHECKSUM`. It is now
  wired (`src/fits.zig` reserves the cards at HDU-build time; `src/checksum.zig` registers
  `updateAll` and `flush` invokes it), and a reopened file verifies `match`.

**What is now verified (committed goldens + the `interop` CI job):**

- `RICE_1`, `GZIP_1`/`GZIP_2`, `PLIO_1`, and lossless `HCOMPRESS_1` decode committed CFITSIO
  tiles to the exact pixels (inbound) **and** `funpack`/CFITSIO read zigfitsio's compressed
  output back to the exact pixels (outbound).
- `DATASUM` recomputes to a CFITSIO-authored golden vector (`X-SUM`).
- WCS TAN `pixel→world` agrees with Astropy reference points within tolerance.

**Genuinely-remaining limits:**

- **`HCOMPRESS_1` lossy** (`scale > 0`) decode smoothing (`hsmooth`) is still not implemented —
  the **lossless** (`scale = 0`) path only (the path the goldens exercise).
- The **byte-exact regeneration drift-guard** in the `interop` CI job assumes CFITSIO exactly
  **4.6.4** (the version the committed bytes were authored with); it runs *informationally* so a
  distro CFITSIO version skew cannot red the build — the *semantic* interop checks (funpack
  decodes to the exact pixels; Astropy opens every file) are the authoritative gate.

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
