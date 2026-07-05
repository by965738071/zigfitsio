"""Python side of the TS<->Python interop check.

Usage:
  python py_interop.py write <dir>   # write py_corpus.fits for read_corpus.ts
  python py_interop.py read <dir>    # read + assert ts_corpus.fits from write_corpus.ts

Requires the Python bindings on PYTHONPATH and the capi library discoverable
(ZIGFITSIO_LIBRARY or a zig-out dev build). Keep contents in sync with
write_corpus.ts / read_corpus.ts.
"""

import os
import sys

import numpy as np

import zigfitsio as zf


def build_hdulist():
    f4 = (np.arange(12, dtype="f4") * 0.5).reshape(3, 4)
    u2 = np.array([0, 40000, 65535], dtype="u2")
    ramp = np.arange(256, dtype="i4").reshape(16, 16)
    vla = np.empty(3, dtype=object)
    vla[0] = np.array([1, 2, 3], dtype="i4")
    vla[1] = np.array([4], dtype="i4")
    vla[2] = np.array([], dtype="i4")
    cols = [
        zf.Column("INDEX", "1J", array=np.array([10, 20, 30], dtype="i4")),
        zf.Column("FLUX", "1E", array=np.array([1.5, 2.5, 3.5], dtype="f4"), unit="Jy"),
        zf.Column("NAME", "8A", array=np.array(["alpha", "beta", "gamma"])),
        zf.Column("VLA", "1PJ", array=vla),
        zf.Column("CPLX", "1C", array=np.array([1 + 2j, -3 + 4j, 0 - 1j], dtype="c8")),
    ]
    return zf.HDUList([
        zf.PrimaryHDU(data=f4),
        zf.ImageHDU(data=u2, name="UIMG"),
        zf.BinTableHDU.from_columns(cols, name="T"),
        zf.CompImageHDU(data=ramp, compression="RICE_1", name="COMP"),
    ])


def write(dir_):
    path = os.path.join(dir_, "py_corpus.fits")
    build_hdulist().writeto(path, overwrite=True)
    print("wrote", path)


def read(dir_):
    path = os.path.join(dir_, "ts_corpus.fits")
    with zf.open(path) as hdul:
        img = hdul[0].data
        assert img.shape == (3, 4) and img.dtype == np.dtype("f4"), img
        np.testing.assert_array_equal(img.ravel(), np.arange(12) * 0.5)

        uimg = hdul["UIMG"].data
        assert uimg.dtype == np.dtype("u2"), uimg.dtype
        np.testing.assert_array_equal(uimg.ravel(), [0, 40000, 65535])

        rec = hdul["T"].data
        np.testing.assert_array_equal(rec["INDEX"], [10, 20, 30])
        np.testing.assert_allclose(rec["FLUX"], [1.5, 2.5, 3.5])
        names = [s.decode().strip() if isinstance(s, bytes) else s.strip() for s in rec["NAME"]]
        assert names == ["alpha", "beta", "gamma"], names
        np.testing.assert_array_equal(rec["VLA"][0], [1, 2, 3])
        np.testing.assert_array_equal(rec["VLA"][1], [4])
        assert rec["VLA"][2].size == 0
        np.testing.assert_allclose(rec["CPLX"], [1 + 2j, -3 + 4j, 0 - 1j])

        comp = hdul["COMP"].data
        assert comp.shape == (16, 16)
        np.testing.assert_array_equal(comp.ravel(), np.arange(256))
    print("ts_corpus.fits verified OK")


if __name__ == "__main__":
    cmd, dir_ = sys.argv[1], sys.argv[2]
    {"write": write, "read": read}[cmd](dir_)
