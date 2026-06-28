#!/usr/bin/env python3
"""gen_wcs_refpoints.py — Astropy reference points for the TAN WCS golden (cross-check sidecar).

Reads the CFITSIO-authored `wcs/wcs_tan.fits` and tabulates, for a fixed set of pixel positions,
the world (RA, Dec) coordinates that `astropy.wcs` computes, into `wcs/wcs_refpoints.csv`. The Zig
consumer (`test/golden.zig`) loads the same FITS through `fits.Wcs`/`fits.Celestial` and must match
each row within ~1e-6 deg.

This script does NOT author committed FITS bytes — the CSV is a cross-check reference, so Astropy
(whose version may vary) is acceptable here. Pixel coordinates are written in the **1-based** FITS
CRPIX convention that `fits.Celestial.pixelToWorld` uses (so the same row's `px,py` feed directly
into the Zig transform); Astropy is therefore queried with `wcs_pix2world(..., 1)`.
"""
import csv
import os
import sys

from astropy.io import fits
from astropy.wcs import WCS

# 1-based pixel positions to tabulate (CRPIX = 32 ⇒ pixel (32,32) is the reference ⇒ CRVAL).
PIXELS = [
    (32.0, 32.0),    # reference pixel ⇒ CRVAL
    (1.0, 1.0),
    (11.0, 51.0),
    (64.0, 64.0),
    (21.5, 41.25),   # fractional ⇒ exercises interpolation
]


def main(root):
    path = os.path.join(root, "wcs", "wcs_tan.fits")
    with fits.open(path) as hdul:
        w = WCS(hdul[0].header)
    out = os.path.join(root, "wcs", "wcs_refpoints.csv")
    with open(out, "w", newline="") as fh:
        wr = csv.writer(fh)
        wr.writerow(["px", "py", "ra_deg", "dec_deg"])
        for px, py in PIXELS:
            world = w.wcs_pix2world([[px, py]], 1)[0]  # 1-based (FITS) origin
            wr.writerow([
                "%.6f" % px, "%.6f" % py,
                "%.10f" % world[0], "%.10f" % world[1],
            ])
    print("wrote", out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "../test/golden"))
