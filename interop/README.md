# interop/ — golden-corpus authoring (external reference toolchain)

The committed reference FITS files under `../test/golden/**` are **authored here**, by the real
reference toolchain, so that the pure-Zig `zigfitsio` library can be cross-checked against bytes
it did not write itself (codec interop, checksum parity, inbound reads, WCS, conformance). The
hermetic consumer of those bytes is `../test/golden.zig` (it runs on every `zig build test`).

Nothing in this directory is part of the Zig build or a Zig dependency. The C and Python
generators live **only** here — the CI `guards` job greps `src tools test` for C imports / `.c` /
`.h`, so generators must never live under those trees.

## Pinned toolchain

| Tool        | Version                        | Role                                             |
|-------------|--------------------------------|--------------------------------------------------|
| CFITSIO     | **4.6.4** (Homebrew)           | authors **every committed `.fits`** + `fpack`    |
| fpack/funpack | 1.7.0 (CFITSIO 4.060)        | tile-compresses the codec sources (`.fz` tiles)  |
| fitsverify  | (Homebrew)                     | conformance check of each golden                 |
| Astropy     | `<6` (+ `numpy<2`), venv       | **cross-check only** — never authors committed bytes |

CFITSIO prefix defaults to `/opt/homebrew/Cellar/cfitsio/4.6.4`; override with
`make golden CFITSIO_PREFIX=/path/to/cfitsio`.

## Determinism contract (why CFITSIO, not Astropy, writes the bytes)

Committed binary goldens must be **byte-identical across regenerations** or the CI drift-guard
(per-file SHA-256 in `MANIFEST.json`) breaks. Astropy's bytes vary by Python/Astropy version, so
it is used **only** for cross-checks (`gen_wcs_refpoints.py`, `verify_outbound.py`, `xval.py`) —
never to write a committed `.fits`. To stay reproducible:

* the C generator writes **no** wall-clock card (never calls `fits_write_date`);
* the checksum vector's `DATASUM`/`CHECKSUM` cards are written with **fixed** comments via the
  public `fits_get_chksum` / `fits_encode_chksum` (CFITSIO's `fits_write_chksum` embeds a
  timestamp in the card *comment*, which we therefore avoid — the *values* are identical);
* `fpack -C` suppresses the timestamped checksum cards `fpack` would otherwise inject;
* `normalize_fits.py` is a final, offset-preserving sweep that blanks any stray `DATE` card and
  any ISO timestamp left in a header (a no-op on the clean pipeline — it makes a regression fail
  loudly instead of committing nondeterministic bytes).

## Regenerate

```sh
make golden            # build C gen, author sources, fpack the tiles, normalize
make golden && git status --porcelain ../test/golden   # determinism: second run is a no-op
make verify            # optional Astropy cross-check (needs the venv below)
make clean             # drop build/ and any stray intermediate sources
```

Astropy venv (cross-check only):

```sh
python3 -m venv /tmp/astropy-venv && /tmp/astropy-venv/bin/pip install -r requirements.txt
/tmp/astropy-venv/bin/python gen_wcs_refpoints.py ../test/golden   # writes wcs/wcs_refpoints.csv
/tmp/astropy-venv/bin/python verify_outbound.py  ../test/golden
/tmp/astropy-venv/bin/python xval.py             ../test/golden
```

## Files produced (see `../test/golden/MANIFEST.json` for sha256 + expected values)

* `compress/tile_{rice,gzip,hcompress,plio}.fits` — tile-compressed 16×16 identity ramp
  (`pixel[i] = i`); decodes back to the ramp by formula. (`fpack`)
* `images/img_i16.fits`, `images/img_f32.fits` (NaN null) — plain inbound images. (C gen)
* `tables/bintable.fits`, `tables/ascii.fits` — inbound tables. (C gen)
* `checksum/cfitsio_ascii_checksum.fits` — 26-byte-row ASCII table + integrity cards. (C gen)
* `wcs/wcs_tan.fits` (+ `wcs/wcs_refpoints.csv`) — TAN WCS image + Astropy reference points.
* `conformance/valid/*.fits`, `conformance/malformed/*.fits` (+ `conformance/expected.json`).
