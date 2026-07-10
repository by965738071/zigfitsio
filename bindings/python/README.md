# zigfitsio

[![Python wheels](https://github.com/anhydrous99/zigfitsio/actions/workflows/python-wheels.yml/badge.svg)](https://github.com/anhydrous99/zigfitsio/actions/workflows/python-wheels.yml)
[![PyPI](https://img.shields.io/pypi/v/zigfitsio)](https://pypi.org/project/zigfitsio/)
[![Python versions](https://img.shields.io/pypi/pyversions/zigfitsio)](https://pypi.org/project/zigfitsio/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](https://github.com/anhydrous99/zigfitsio/blob/main/LICENSE)

**Read and write FITS files with a NumPy-first, astropy.io.fits-style API — no C compiler, no CFITSIO required.**

Python bindings for [zigfitsio](https://github.com/anhydrous99/zigfitsio), a pure-Zig FITS 4.0
I/O library. The native code is a Zig-built shared library loaded via `ctypes`, in two layers:

- **High-level** (`zigfitsio`) — modeled on `astropy.io.fits`: `open`, `HDUList`, the HDU classes, `Column`, `Header`, and `getdata`/`getheader`/`writeto`/`verify`.
- **Low-level** (`zigfitsio.lowlevel`) — a 1:1 `ctypes` binding over the C ABI, for power users.

## Install

```sh
pip install zigfitsio
```

Prebuilt wheels need no compiler. Building from source requires a Zig 0.16 toolchain (supplied
automatically by the `ziglang` build dependency, or a system `zig` on `PATH`).

## Quickstart

```python
import numpy as np
import zigfitsio as zf

# Write an image
zf.writeto("image.fits", np.arange(12, dtype="f4").reshape(3, 4), overwrite=True)

# Read it back (NumPy array, shape (NAXIS2, NAXIS1), C-order — like astropy)
with zf.open("image.fits") as hdul:
    data = hdul[0].data
    print(data.shape, hdul[0].header["NAXIS1"])
```

### Tables

```python
cols = [
    zf.Column("INDEX", "J", np.array([10, 20, 30], dtype="i4")),
    zf.Column("FLUX",  "E", np.array([1.5, 2.5, 3.5], dtype="f4"), unit="Jy"),
    zf.Column("NAME",  "8A", np.array(["alpha", "beta", "gamma"])),
]
zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols, name="EVENTS")]).writeto(
    "table.fits", overwrite=True
)
```

### Compressed images

```python
ramp = np.arange(256, dtype="i4").reshape(16, 16)
zf.HDUList([zf.PrimaryHDU(), zf.CompImageHDU(ramp, compression="RICE_1")]).writeto(
    "comp.fits", overwrite=True
)
```

### Headers (dict-like)

```python
with zf.open("image.fits", mode="update") as hdul:
    h = hdul[0].header
    h["OBSERVER"] = ("Hubble", "the observer")  # value + comment
    print(h["OBSERVER"], "/", h.comment_of("OBSERVER"))
    print("BITPIX" in h, list(h.keys()))
```

### WCS (celestial)

```python
with zf.open("wcs.fits") as hdul:
    lon, lat = hdul[0].pix2world(40.0, 30.0)   # 1-based pixel (FITS CRPIX convention)
    px, py = hdul[0].world2pix(lon, lat)
```

### Validation

```python
for finding in zf.verify("image.fits"):   # fitsverify-style structural checks
    print(finding)
```

### Low-level (ctypes)

```python
import ctypes as c
import zigfitsio.lowlevel as ll

h = c.c_void_p()
ll.check(ll.lib.zf_create_memory(None, c.byref(h)))
ll.check(ll.lib.zf_create_img(h, -32, 2, (c.c_long * 2)(4, 3)))
ll.lib.zf_close(h)
```

## Conventions

- Image and table data is exchanged as **native-endian** NumPy arrays; non-native (byte-swapped)
  input is coerced automatically before writing. Image shape is the reversed FITS axis order
  (`(NAXIS2, NAXIS1)`), C-contiguous — identical memory layout to `astropy.io.fits`.
- `BSCALE`/`BZERO` and `TSCAL`/`TZERO` scaling and the unsigned-integer convention are applied
  automatically on read (images and table columns) and honored on write; the output dtype is
  widened to float when real scaling is present, or to `u2/u4/u8` for the unsigned convention.
- Errors are raised as typed `FitsError` subclasses (`KeywordNotFound` is also a `KeyError`).

## Known limitations

- Not a CFITSIO drop-in — the ABI is purpose-built `zf_*` symbols, not `fits_*`.
- Integer `BLANK`/`TNULLn` values are not auto-masked (no `numpy.ma`); float nulls surface as NaN.
- In-place update of compressed images, VLA or scaled columns, or a changed row count raises —
  use `writeto()` to a new file instead.
- Tables with duplicate effective column names can be inspected as metadata or copied verbatim,
  but high-level data access/reconstruction raises `FitsTableError` (status 219); use low-level
  indexed column reads when duplicates must be addressed.
- `writeto()` of a *scanned* quantized-float compressed image re-quantizes at the default level
  (the FITS header does not record the level).

The full list lives in
[CAVEATS.md](https://github.com/anhydrous99/zigfitsio/blob/main/CAVEATS.md).

## Development

```sh
zig build capi                    # build the shared library into zig-out/lib
pip install -e .[test]            # editable install (builds the lib via the hook)
pytest bindings/python/tests -q   # run the suite (incl. astropy cross-checks)
```

## License

MIT — see [LICENSE](https://github.com/anhydrous99/zigfitsio/blob/main/LICENSE).
