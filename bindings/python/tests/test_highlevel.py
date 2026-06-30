"""High-level NumPy API tests (images, tables, headers, sections, compression, WCS, integrity)."""

import numpy as np
import pytest

import zigfitsio as zf


def test_image_write_read_roundtrip(tmp_fits):
    data = np.arange(24, dtype="f4").reshape(4, 6) * 0.25
    p = tmp_fits()
    zf.writeto(p, data, overwrite=True)
    with zf.open(p) as hdul:
        got = hdul[0].data
        assert got.shape == (4, 6)
        assert got.dtype == np.dtype("f4")
        np.testing.assert_array_equal(got, data)


@pytest.mark.parametrize("dtype", ["u1", "i2", "i4", "i8", "f4", "f8"])
def test_image_all_bitpix(tmp_fits, dtype):
    data = (np.arange(12).reshape(3, 4)).astype(dtype)
    p = tmp_fits()
    zf.writeto(p, data, overwrite=True)
    with zf.open(p) as hdul:
        np.testing.assert_array_equal(hdul[0].data, data)


def test_image_section_via_lowlevel(tmp_fits):
    import ctypes as c
    import zigfitsio.lowlevel as ll

    data = np.arange(16, dtype="i2").reshape(4, 4)
    p = tmp_fits()
    zf.writeto(p, data, overwrite=True)
    with zf.open(p) as hdul:
        h = hdul._handle
        ll.check(ll.lib.zf_select(h, 1))
        lower = (c.c_long * 2)(0, 0)
        upper = (c.c_long * 2)(1, 1)
        out = np.empty(4, dtype="i2")
        ll.check(ll.lib.zf_read_subset(h, ll.ZF_INT16, 2, lower, upper, None, 4, None, None, out.ctypes.data_as(c.c_void_p)))
        # FITS section (x:0..1, y:0..1) → flat 0,1,4,5
        np.testing.assert_array_equal(out, [0, 1, 4, 5])


def test_header_dict_access_and_edit(tmp_fits):
    data = np.zeros((3, 3), dtype="f4")
    p = tmp_fits()
    zf.writeto(p, data, overwrite=True)
    with zf.open(p, mode="update") as hdul:
        hdr = hdul[0].header
        assert hdr["NAXIS"] == 2
        assert "BITPIX" in hdr
        hdr["OBSERVER"] = ("Hubble", "who")
    with zf.open(p) as hdul:
        assert hdul[0].header["OBSERVER"] == "Hubble"
        assert hdul[0].header.comment_of("OBSERVER") == "who"


def test_binary_table_roundtrip(tmp_fits):
    idx = np.array([10, 20, 30], dtype="i4")
    flux = np.array([1.5, 2.5, 3.5], dtype="f4")
    name = np.array(["alpha", "beta", "gamma"])
    cols = [
        zf.Column("INDEX", "J", idx),
        zf.Column("FLUX", "E", flux, unit="Jy"),
        zf.Column("NAME", "8A", name),
    ]
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols, name="EVENTS")]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        assert hdul[1].name == "EVENTS"
        rec = hdul[1].data
        np.testing.assert_array_equal(rec["INDEX"], idx)
        np.testing.assert_allclose(rec["FLUX"], flux)
        names = [s.decode().strip() if isinstance(s, bytes) else s for s in rec["NAME"]]
        assert names == ["alpha", "beta", "gamma"]


def test_vector_column(tmp_fits):
    vec = np.arange(9, dtype="i4").reshape(3, 3)
    cols = [zf.Column("VEC", "3J", vec)]
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols)]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        rec = hdul[1].data
        assert rec["VEC"].shape == (3, 3)
        np.testing.assert_array_equal(rec["VEC"], vec)


def test_compression_roundtrip(tmp_fits):
    ramp = np.arange(256, dtype="i4").reshape(16, 16)
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(), zf.CompImageHDU(ramp, compression="RICE_1")]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        np.testing.assert_array_equal(hdul[1].data, ramp)


def test_to_bytes_and_from_bytes_roundtrip():
    data = np.arange(20, dtype="f8").reshape(4, 5)
    raw = zf.HDUList([zf.PrimaryHDU(data=data)]).to_bytes()
    assert raw[:6] == b"SIMPLE"
    with zf.from_bytes(raw) as hdul:
        np.testing.assert_array_equal(hdul[0].data, data)


def test_checksum_and_validate(tmp_fits):
    data = np.arange(16, dtype="f4").reshape(4, 4)
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(data=data)]).writeto(p, overwrite=True, checksum=True)
    findings = zf.verify(p)
    assert [f for f in findings if f.severity == "error"] == []


def test_wcs_roundtrip(tmp_fits):
    data = np.zeros((64, 64), dtype="f4")
    hdr = zf.Header()
    for k, v in [
        ("CTYPE1", "RA---TAN"), ("CTYPE2", "DEC--TAN"),
        ("CRPIX1", 32.0), ("CRPIX2", 32.0),
        ("CRVAL1", 150.0), ("CRVAL2", 2.0),
        ("CDELT1", -0.001), ("CDELT2", 0.001),
    ]:
        hdr[k] = v
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(data=data, header=hdr)]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        lon, lat = hdul[0].pix2world(40.0, 30.0)
        px, py = hdul[0].world2pix(lon, lat)
        assert abs(px - 40.0) < 1e-6
        assert abs(py - 30.0) < 1e-6
