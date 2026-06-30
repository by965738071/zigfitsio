"""Quickstart for the zigfitsio Python bindings: write and read images and tables, edit a
header, build a tile-compressed image, and run structural validation.

Run with the bindings importable, e.g.::

    PYTHONPATH=bindings/python/src \
    ZIGFITSIO_LIBRARY=$PWD/zig-out/lib/libzigfitsio_capi.dylib \
    python bindings/python/examples/quickstart.py
"""

import tempfile
from pathlib import Path

import numpy as np

import zigfitsio as zf


def main() -> None:
    tmp = Path(tempfile.mkdtemp())

    # ── Image ─────────────────────────────────────────────────────────────────────────────
    img = np.arange(24, dtype="f4").reshape(4, 6) * 0.5
    img_path = str(tmp / "image.fits")
    zf.writeto(img_path, img, overwrite=True)

    with zf.open(img_path, mode="update") as hdul:
        hdu = hdul[0]
        print("image:", hdu.data.shape, hdu.data.dtype)
        hdu.header["OBSERVER"] = ("Hubble", "the observer")
        print("OBSERVER:", hdu.header["OBSERVER"], "/", hdu.header.comment_of("OBSERVER"))

    # ── Binary table ──────────────────────────────────────────────────────────────────────
    cols = [
        zf.Column("INDEX", "J", np.array([10, 20, 30], dtype="i4")),
        zf.Column("FLUX", "E", np.array([1.5, 2.5, 3.5], dtype="f4"), unit="Jy"),
        zf.Column("NAME", "8A", np.array(["alpha", "beta", "gamma"])),
    ]
    tab_path = str(tmp / "table.fits")
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols, name="EVENTS")]).writeto(
        tab_path, overwrite=True
    )
    with zf.open(tab_path) as hdul:
        rec = hdul["EVENTS"].data
        print("table INDEX:", list(rec["INDEX"]))
        print("table NAME :", [s.decode().strip() for s in rec["NAME"]])

    # ── Tile-compressed image (RICE_1) ────────────────────────────────────────────────────
    ramp = np.arange(256, dtype="i4").reshape(16, 16)
    comp_path = str(tmp / "comp.fits")
    zf.HDUList([zf.PrimaryHDU(), zf.CompImageHDU(ramp, compression="RICE_1")]).writeto(
        comp_path, overwrite=True
    )
    with zf.open(comp_path) as hdul:
        print("compressed decodes equal:", np.array_equal(hdul[1].data, ramp))

    # ── Validation ────────────────────────────────────────────────────────────────────────
    findings = zf.verify(img_path)
    print("validation findings:", len(findings))


if __name__ == "__main__":
    main()
