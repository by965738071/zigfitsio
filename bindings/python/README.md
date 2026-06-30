# zigfitsio (Python)

Python bindings for [**zigfitsio**](https://github.com/anhydrous99/zigfitsio) — a pure-[Zig](https://ziglang.org)
implementation of [FITS](https://fits.gsfc.nasa.gov) 4.0 I/O with feature parity goals against
CFITSIO, and **no C dependencies**.

Two layers are provided:

- **High-level**, NumPy-first API modeled on `astropy.io.fits` — `open`, `HDUList`, the HDU
  classes, `Column`, `Header`, and the `getdata`/`getheader`/`writeto`/`verify` conveniences.
- **Low-level** 1:1 `ctypes` binding under `zigfitsio.lowlevel` (the C ABI from
  `bindings/c/zigfitsio.h`) for power users.

The native code is a Zig-built shared library loaded via `ctypes`; there is **no C compiler
requirement** at install time when using a prebuilt wheel.

## Install

```sh
pip install zigfitsio          # prebuilt wheel (recommended)
```

Building from source requires a Zig toolchain (supplied automatically by the `ziglang` build
dependency, or a system `zig` 0.16 on `PATH`).

## Quickstart

```python
import numpy as np
import zigfitsio as zf

# Write an image
zf.writeto("image.fits", np.arange(12, dtype="f4").reshape(3, 4), overwrite=True)

# Read it back (NumPy array, shape (NAXIS2, NAXIS1), C-order — like astropy)
with zf.open("image.fits") as hdul:
    data = hdul[0].data
    hdr = hdul[0].header
    print(data.shape, hdr["NAXIS1"])

# Build a binary table
cols = [
    zf.Column("INDEX", "J", np.array([10, 20, 30], dtype="i4")),
    zf.Column("FLUX",  "E", np.array([1.5, 2.5, 3.5], dtype="f4"), unit="Jy"),
    zf.Column("NAME",  "8A", np.array(["alpha", "beta", "gamma"])),
]
zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols, name="EVENTS")]).writeto(
    "table.fits", overwrite=True
)

# Tile-compressed image (RICE_1)
ramp = np.arange(256, dtype="i4").reshape(16, 16)
zf.HDUList([zf.PrimaryHDU(), zf.CompImageHDU(ramp, compression="RICE_1")]).writeto(
    "comp.fits", overwrite=True
)

# Structural validation (fitsverify-style)
for f in zf.verify("image.fits"):
    print(f)
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

- Image data is exchanged as **native-endian** NumPy arrays. Array shape is the reversed FITS
  axis order (`(NAXIS2, NAXIS1)`), C-contiguous — identical memory layout to `astropy.io.fits`.
- `BSCALE`/`BZERO` scaling and the unsigned-integer convention are applied automatically; the
  output dtype is widened to float when real scaling is present.
- Errors are raised as typed `FitsError` subclasses (`KeywordNotFound` is also a `KeyError`).

## Development

```sh
zig build capi                                   # build the shared library into zig-out/lib
pip install -e .[test]                           # editable install (builds the lib via the hook)
pytest bindings/python/tests -q                  # run the suite (incl. astropy cross-checks)
```

When running tests against an uninstalled checkout, point the loader at the dev build:

```sh
ZIGFITSIO_LIBRARY=$PWD/zig-out/lib/libzigfitsio_capi.dylib \
PYTHONPATH=bindings/python/src pytest bindings/python/tests -q
```

## License

MIT — see [`LICENSE`](../../LICENSE).
