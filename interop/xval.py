#!/usr/bin/env python3
"""xval.py — Astropy cross-validation of golden pixel/cell values (CI sidecar).

Independently confirms (with Astropy) that the goldens carry the values the Zig consumer asserts:
the four tile codecs decode to the identity ramp `pixel[i] = i`, the plain images carry their
formula values (and the f32 NaN null), and the inbound tables carry their cell values. A
CROSS-CHECK only — authors no bytes — so Astropy is acceptable.

Exit non-zero on the first mismatch.
"""
import os
import sys

import numpy as np
from astropy.io import fits


def _check(cond, msg, state):
    if cond:
        print("ok:   %s" % msg)
    else:
        print("FAIL: %s" % msg, file=sys.stderr)
        state[0] += 1


def main(root):
    state = [0]
    ramp = np.arange(256).reshape(16, 16)

    for codec in ("rice", "gzip", "hcompress", "plio"):
        path = os.path.join(root, "compress", "tile_%s.fits" % codec)
        with fits.open(path) as hdul:
            data = hdul[1].data  # compressed image is the first extension
        _check(np.array_equal(data.astype(np.int64), ramp), "tile_%s ramp" % codec, state)

    with fits.open(os.path.join(root, "images", "img_i16.fits")) as hdul:
        d = hdul[0].data.astype(np.int64).ravel()
        _check(np.array_equal(d, np.arange(32) - 8), "img_i16 value[i]=i-8", state)

    with fits.open(os.path.join(root, "images", "img_f32.fits")) as hdul:
        d = hdul[0].data.astype(np.float64).ravel()
        _check(np.isnan(d[7]), "img_f32 NaN null @7", state)
        idx = [i for i in range(15) if i != 7]
        _check(np.allclose(d[idx], np.array(idx) * 0.25), "img_f32 value[i]=i*0.25", state)

    with fits.open(os.path.join(root, "tables", "bintable.fits")) as hdul:
        t = hdul[1].data
        _check(list(t["INDEX"]) == [10, 20, 30], "bintable INDEX", state)
        _check(np.allclose(t["DVAL"], [0.25, 0.5, 0.75]), "bintable DVAL", state)
        names = [s.strip() for s in t["NAME"]]
        _check(names == ["alpha", "beta", "gamma"], "bintable NAME", state)

    with fits.open(os.path.join(root, "tables", "ascii.fits")) as hdul:
        t = hdul[1].data
        _check(list(t["ID"]) == [100, 200, 300], "ascii ID", state)

    with fits.open(os.path.join(root, "checksum", "cfitsio_ascii_checksum.fits")) as hdul:
        ds = hdul[1].header["DATASUM"]
        print("info: checksum DATASUM card = %s" % ds)

    print("xval: %d mismatch(es)" % state[0])
    return 1 if state[0] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "../test/golden"))
