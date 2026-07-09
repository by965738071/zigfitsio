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

    # Lossy HCOMPRESS (absolute scale 16; `smooth` carries ZVAL2=1): Astropy's decoder must
    # reproduce funpack's committed expected pixels exactly — three independent decoders
    # (CFITSIO/funpack, Astropy, zigfitsio) agreeing on the same lossy bytes.
    for name in ("lossy16", "lossy32", "smooth"):
        fz = os.path.join(root, "compress", "tile_hcompress_%s.fits" % name)
        exp = os.path.join(root, "compress", "tile_hcompress_%s_expected.fits" % name)
        with fits.open(fz) as hdul:
            data = hdul[1].data
        with fits.open(exp) as hdul:
            want = hdul[0].data
        _check(
            np.array_equal(data.astype(np.int64), want.astype(np.int64)),
            "tile_hcompress_%s == funpack expected" % name,
            state,
        )
    with fits.open(os.path.join(root, "compress", "tile_hcompress_lossy32_expected.fits")) as h0, fits.open(
        os.path.join(root, "compress", "tile_hcompress_smooth_expected.fits")
    ) as h1:
        _check(
            not np.array_equal(h0[0].data, h1[0].data),
            "hcompress smooth expected differs from plain (non-vacuous)",
            state,
        )

    # Quantized-float tiles (q = 4): HCOMPRESS dithered (ZDITHER0=1) / NO_DITHER, RICE dithered.
    # Dequantization is deterministic arithmetic over the shared Park–Miller table, so Astropy
    # must reproduce funpack's committed expected pixels to the exact f32 bit pattern. (The
    # source field is all-positive by design: near-zero reconstructions are FP-contraction
    # knife-edges on which CFITSIO's own builds disagree — see interop/c/gen_sources.c.)
    for name in ("hcompress_fdith", "hcompress_fq0", "rice_fdith"):
        fz = os.path.join(root, "compress", "tile_%s.fits" % name)
        exp = os.path.join(root, "compress", "tile_%s_expected.fits" % name)
        with fits.open(fz) as hdul:
            data = hdul[1].data
        with fits.open(exp) as hdul:
            want = hdul[0].data
        # Normalize byte order before the bit compare (Astropy hands back '>f4' for the plain
        # primary but native for the compressed HDU); astype preserves the f32 bit patterns.
        got_bits = np.ascontiguousarray(data, dtype="<f4").view(np.uint32)
        want_bits = np.ascontiguousarray(want, dtype="<f4").view(np.uint32)
        _check(
            data.dtype.kind == "f"
            and data.dtype.itemsize == 4
            and want.dtype.kind == "f"
            and want.dtype.itemsize == 4
            and np.array_equal(got_bits, want_bits),
            "tile_%s == funpack expected (f32 bit-exact)" % name,
            state,
        )

    # Quantized-DOUBLE tile (RICE dithered, ZBITPIX=-64): full f64-width dequantization.
    # Tolerance is 1 ULP, NOT bit-exact: the final `* ZSCALE + ZZERO` is an FP-contraction
    # point on which CFITSIO's own builds disagree at f64 width (FMA-contracted arm64 vs
    # non-contracted baseline x86-64 — see interop/c/gen_sources.c; the f32 tiles above hide
    # the wobble in their final f32 rounding). The expected file is authored by an
    # FMA-contracted funpack; an Astropy wheel built without FMA lands 1 ULP away on a small
    # fraction of pixels. zigfitsio's own decode is pinned bit-exactly in test/golden.zig
    # (its fused @mulAdd is byte-deterministic on every target).
    fz = os.path.join(root, "compress", "tile_rice_ddith.fits")
    exp = os.path.join(root, "compress", "tile_rice_ddith_expected.fits")
    with fits.open(fz) as hdul:
        data = hdul[1].data
    with fits.open(exp) as hdul:
        want = hdul[0].data
    got64 = np.ascontiguousarray(data, dtype="<f8")
    want64 = np.ascontiguousarray(want, dtype="<f8")
    _check(
        data.dtype.kind == "f"
        and data.dtype.itemsize == 8
        and want.dtype.kind == "f"
        and want.dtype.itemsize == 8
        and bool(np.all(np.abs(got64 - want64) <= np.spacing(np.abs(want64)))),
        "tile_rice_ddith == funpack expected (f64, <= 1 ULP)",
        state,
    )
    # Non-vacuous at double width: the pixels must carry precision beyond the f32 grid
    # (an f32 funnel anywhere in a decoder would zero this count — bug-hunt 2026-07-06 #41).
    _check(
        bool(np.count_nonzero(want64 != want64.astype(np.float32).astype(np.float64)) > 0),
        "tile_rice_ddith expected pixels exceed f32 precision (non-vacuous)",
        state,
    )

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
