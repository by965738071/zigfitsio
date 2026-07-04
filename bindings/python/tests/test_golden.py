"""Read the committed CFITSIO/Astropy golden corpus through zigfitsio (inbound interop)."""

import os

import numpy as np
import pytest

import zigfitsio as zf


@pytest.mark.parametrize("codec", ["rice", "gzip", "hcompress", "plio"])
def test_golden_tile_codecs_decode_to_ramp(golden_dir, codec):
    path = os.path.join(str(golden_dir), "compress", f"tile_{codec}.fits")
    if not os.path.exists(path):
        pytest.skip(f"missing {path}")
    ramp = np.arange(256).reshape(16, 16)
    with zf.open(path) as hdul:
        data = hdul[1].data  # compressed image is the first extension
        np.testing.assert_array_equal(data.astype(np.int64), ramp)


@pytest.mark.parametrize("name", ["lossy16", "lossy32", "smooth"])
def test_golden_lossy_hcompress_matches_funpack(golden_dir, name):
    """Lossy HCOMPRESS tiles (incl. the ZVAL2=1 hsmooth request) decode exactly like funpack."""
    fz = os.path.join(str(golden_dir), "compress", f"tile_hcompress_{name}.fits")
    exp = os.path.join(str(golden_dir), "compress", f"tile_hcompress_{name}_expected.fits")
    if not (os.path.exists(fz) and os.path.exists(exp)):
        pytest.skip(f"missing tile_hcompress_{name}")
    with zf.open(fz) as hdul:
        data = hdul[1].data
    with zf.open(exp) as hdul:
        want = hdul[0].data
    np.testing.assert_array_equal(data.astype(np.int64), want.astype(np.int64))


@pytest.mark.parametrize("name", ["hcompress_fdith", "hcompress_fq0", "rice_fdith"])
def test_golden_quantized_float_matches_funpack(golden_dir, name):
    """Quantized-float tiles (SUBTRACTIVE_DITHER_1 / NO_DITHER, q=4) dequantize exactly like funpack."""
    fz = os.path.join(str(golden_dir), "compress", f"tile_{name}.fits")
    exp = os.path.join(str(golden_dir), "compress", f"tile_{name}_expected.fits")
    if not (os.path.exists(fz) and os.path.exists(exp)):
        pytest.skip(f"missing tile_{name}")
    with zf.open(fz) as hdul:
        data = hdul[1].data
    with zf.open(exp) as hdul:
        want = hdul[0].data
    assert data.dtype == np.float32 and want.dtype == np.float32
    # Bit-pattern equality: the dequantization must be funpack-identical, not merely close.
    np.testing.assert_array_equal(data.view(np.uint32), want.view(np.uint32))


def test_golden_image_i16(golden_dir):
    path = os.path.join(str(golden_dir), "images", "img_i16.fits")
    if not os.path.exists(path):
        pytest.skip("missing img_i16")
    with zf.open(path) as hdul:
        d = hdul[0].data.astype(np.int64).ravel()
        np.testing.assert_array_equal(d, np.arange(32) - 8)


def test_golden_image_f32_nan_null(golden_dir):
    path = os.path.join(str(golden_dir), "images", "img_f32.fits")
    if not os.path.exists(path):
        pytest.skip("missing img_f32")
    with zf.open(path) as hdul:
        d = hdul[0].data.astype(np.float64).ravel()
        assert np.isnan(d[7])
        idx = [i for i in range(15) if i != 7]
        np.testing.assert_allclose(d[idx], np.array(idx) * 0.25)


def test_golden_bintable(golden_dir):
    path = os.path.join(str(golden_dir), "tables", "bintable.fits")
    if not os.path.exists(path):
        pytest.skip("missing bintable")
    with zf.open(path) as hdul:
        rec = hdul[1].data
        assert list(rec["INDEX"]) == [10, 20, 30]
        np.testing.assert_allclose(rec["DVAL"], [0.25, 0.5, 0.75])
        names = [s.decode().strip() if isinstance(s, bytes) else s.strip() for s in rec["NAME"]]
        assert names == ["alpha", "beta", "gamma"]


def test_golden_ascii_table(golden_dir):
    path = os.path.join(str(golden_dir), "tables", "ascii.fits")
    if not os.path.exists(path):
        pytest.skip("missing ascii table")
    with zf.open(path) as hdul:
        rec = hdul[1].data
        assert list(rec["ID"]) == [100, 200, 300]
