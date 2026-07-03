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

## 3. Language bindings (Python / C ABI) — scope & known gaps

The bindings under `bindings/` are **additive**: a `zf_*` C-ABI shim (`bindings/capi/`, built by
`zig build capi`) over the public Zig module, a low-level `ctypes` binding, and a high-level
NumPy/Astropy-style API. `src/` is unchanged and contains **no C** (the `.h` contract lives under
`bindings/c/`, outside the `GC-1` guard's `src tools test` scope). Interoperability is verified
both directions against Astropy and the committed golden corpus. Honest limits as delivered:

- **Not a CFITSIO drop-in.** The exported symbols are `zf_*`, not `fits_*`/`ff*`; the ABI is
  purpose-built for bindings (opaque handles + runtime datatype codes), not a CFITSIO replacement.
- **Integer null masks.** Float nulls surface as NaN; for integer images/columns the raw `BLANK`/
  `TNULLn` values are readable (and exposed via `zf_table_col_info`), but the high-level API does
  not yet return `numpy.ma` masked arrays for them — masking integer nulls is a follow-up.
- **VLA writing.** The high-level `from_columns`/`writeto` path writes variable-length-array
  columns, reserving the heap (`PCOUNT`) up front via `zf_create_tbl_heap`; reading VLAs is
  complete. The lower-level `zf_write_col_vla` still assumes the heap is reserved (create the table
  with `zf_create_tbl_heap`). Writing *complex* VLAs is not supported.
- **Unsigned-integer writing.** The high-level write path maps `u1/i2/i4/i8/f4/f8` directly and
  writes `u2/u4/u8` images and columns via the `BZERO`/`TZEROn` convention (integer-space, exact for
  all widths incl. `uint64`); reading the same convention (`BZERO`/`TZEROn` → `u2/u4/u8`) is handled.
- **Iterator and the raw `Device` vtable** are intentionally not exposed 1:1; the Python layer
  provides NumPy-native equivalents (column/section reads) and the file/memory/gzip open paths.
- **Toolchain for wheels.** The `ziglang` PyPI package can lag the 0.16 toolchain this project
  targets, so wheel builds use a real Zig 0.16 (CI `setup-zig` / the in-container installer); the
  hatch build hook falls back to a system `zig` when `ziglang` is absent.

None of these require ABI changes to address — they are extension points, not design constraints.

## 4. Bug-hunt fixes (branch `fix/bug-hunt-2026-07-02`) — known limitations & deferrals

This branch fixes ~30 confirmed bugs across the compression interop, core safety, the C-ABI, and
the Python bindings (see `CHANGELOG.md`). Everything below is a deliberate, documented boundary of
that work — each is *fail-loud* (a clear error), never silent data loss.

- **Python: in-place update of a *compressed* image is not supported.** Mutating a materialized
  `CompImageHDU`'s pixels and then `flush()`/`close()` (update mode) raises `NotImplementedError`
  rather than attempting in-place recompression (the tile heap would have to be resized in place).
  Use `writeto()`, which reconstructs the file and recompresses correctly, preserving the source
  codec/tiling/quantization.
- **Python: in-place table update is limited to fixed-geometry cell edits.** `flush()`/`close()`
  write back changed cell values of ordinary (fixed-width, unscaled) columns. Changing the row
  count, or editing a variable-length-array (`P`/`Q`) or `TSCAL`/`TZERO`-scaled column in place,
  raises `NotImplementedError` — use `writeto()` to a new file (which reconstructs) for those.
- **Python: `append` and structural table edits go through the file, not a scratch copy.** Appending
  an HDU to an update-mode list serializes it to the open file on `flush()`/`close()`; there is no
  transactional rollback of a partial in-place structural edit if the device write fails midway
  (the same is true at the Zig layer — see the append/copy rollback that *is* implemented, versus
  the header-rewrite path which validates-before-mutating but does not un-shift relocated bytes on a
  mid-write I/O error).
- **Header `update()`/`modify()` do not support HIERARCH long-keyword cards.** Reading a HIERARCH
  card by its hierarchical name is correct (`get`/`has`/`comment`/`getValue`/`getHierarch`), but the
  *write* helpers build a fixed-format 8-char card (`Card.buildValue`) and cannot construct a
  HIERARCH card, so updating a HIERARCH keyword's value in place is unsupported. Rebuild the card via
  the HIERARCH builder (`src/header/hierarch.zig`) instead.
- **Dithered/quantized-float compression interop is verified but not yet golden-committed.** The
  fix was validated against real `fpack`/`funpack` (zigfitsio decodes an `fpack SUBTRACTIVE_DITHER_1`
  file bit-for-bit identically to `funpack` — max pixel diff 0) and is covered by hermetic
  round-trip unit tests (`NO_DITHER`, `SUBTRACTIVE_DITHER_2`, lossless-fallback/±Inf tiles, ZBLANK).
  A CFITSIO-authored dithered `.fz` **golden fixture** under `test/golden/` plus an `fpack`
  cross-check wired into the toolchain-gated `interop` CI job is a follow-up (the §1 golden corpus
  is integer-tile only).
- **ASCII-table float TFORM is reconstructed heuristically on copy.** When a *modified* ASCII table
  is re-serialized, a float column's `Ew.d` precision is derived as `E{w}.{w-7}` from the column
  width, because the C ABI's `ZfColInfo` exposes width and typecode but not the original `TDISP`/
  format string — a re-written ASCII float column may not preserve the source's exact displayed
  precision. Integer (`Iw`) and character (`Aw`) ASCII columns reconstruct exactly. Reading ASCII
  columns (including wide `I11`-style integers) is exact.

### Delivery status (point-in-time)

The work lives on branch `fix/bug-hunt-2026-07-02`, organized as area-staged, individually-green
commits (compression interop, core memory-safety/DoS, C-ABI, low-severity hardening, Python
data-loss+correctness, Python features, and a self-review fixup). All suites pass: **519/519 Zig
tests in both Debug and ReleaseFast**, `zig build capi-test`, `zig build wasm-check`, and the
Python suite (`pytest bindings/python/tests`). This section is moot once the branch is merged.
