"""Regression tests for the 2026-06-30 Python-binding bug hunt (task wj50gv2ry).

Each test pins one confirmed defect that the pre-existing suite did not exercise. Everything runs
in-memory (``to_bytes``/``from_bytes`` or the low-level ``zf_*`` API) so no disk or astropy is
needed. The comment on each test references the finding it guards.
"""

import ctypes as c

import numpy as np
import pytest

import zigfitsio as zf
from zigfitsio import lowlevel as ll


# ── helpers ──────────────────────────────────────────────────────────────────────────────────
def _bytes_from(build):
    """Run `build(handle)` against a fresh in-memory FITS handle and return the serialized bytes."""
    handle = c.c_void_p()
    ll.check(ll.lib.zf_create_memory(None, c.byref(handle)))
    try:
        build(handle)
        ll.check(ll.lib.zf_flush(handle))
        size = c.c_uint64()
        ll.check(ll.lib.zf_data_size(handle, c.byref(size)))
        buf = c.create_string_buffer(int(size.value))
        got = c.c_size_t()
        ll.check(ll.lib.zf_read_bytes(handle, 0, buf, size.value, c.byref(got)))
        return buf.raw[: got.value]
    finally:
        ll.lib.zf_close(handle)


def _scaled_col_bytes(tform, raw, zf_code, tscal, tzero):
    """A 1-column binary table whose stored ints carry TSCAL/TZERO scaling keywords."""
    def build(handle):
        ll.check(ll.lib.zf_create_img(handle, 8, 0, None))
        arr = np.array(raw)
        ttype = (c.c_char_p * 1)(b"C1")
        tform_a = (c.c_char_p * 1)(tform.encode())
        tunit = (c.c_char_p * 1)(None)
        ll.check(ll.lib.zf_create_tbl(handle, ll.BINARY_TBL, len(raw), 1, ttype, tform_a, tunit, None))
        t = c.c_void_p()
        ll.check(ll.lib.zf_table_open(handle, c.byref(t)))
        ll.check(ll.lib.zf_write_col(t, zf_code, 0, 1, arr.size, None, arr.ctypes.data_as(c.c_void_p)))
        ll.lib.zf_table_close(t)
        for kw, val in ((b"TSCAL1", tscal), (b"TZERO1", tzero)):
            ll.check(ll.lib.zf_write_key_dbl(handle, kw, len(kw), float(val), None, 0))
    return _bytes_from(build)


# ── #1 critical: open -> writeto / to_bytes must not drop data ────────────────────────────────
def test_copy_image_preserves_data(tmp_fits):
    orig = np.arange(6, dtype="i2").reshape(2, 3)
    zf.writeto(tmp_fits("in.fits"), orig, overwrite=True)
    with zf.open(tmp_fits("in.fits")) as hl:
        hl.writeto(tmp_fits("out.fits"), overwrite=True)
    assert np.array_equal(zf.getdata(tmp_fits("out.fits")), orig)


def test_copy_to_bytes_preserves_data():
    orig = np.arange(6, dtype="i2").reshape(2, 3)
    src = zf.HDUList([zf.PrimaryHDU(data=orig)]).to_bytes()
    with zf.from_bytes(src) as hl:
        copy = hl.to_bytes()
    assert np.array_equal(zf.from_bytes(copy)[0].data, orig)


def test_copy_table_preserves_rows():
    col = zf.Column("X", "1J", array=np.arange(4, dtype="i4"))
    src = zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).to_bytes()
    with zf.from_bytes(src) as hl:
        copy = hl.to_bytes()
    assert np.array_equal(zf.from_bytes(copy)[1].data["X"], np.arange(4))


# ── #2 / #3 crashes: NULL handle must raise, not segfault ─────────────────────────────────────
def test_use_after_close_raises():
    src = zf.HDUList([zf.PrimaryHDU(np.arange(4, dtype="i2"))]).to_bytes()
    hl = zf.from_bytes(src)
    hdu = hl[0]
    hl.close()
    with pytest.raises(zf.FitsError):
        _ = hdu.data


def test_verify_detached_raises():
    with pytest.raises(zf.FitsError):
        zf.verify(zf.HDUList([zf.PrimaryHDU(data=np.zeros((3, 3), dtype="i2"))]))


# ── #4 byte order: non-native input must round-trip, not corrupt ──────────────────────────────
@pytest.mark.parametrize("dtype", [">i2", ">i4", ">f4", ">f8"])
def test_big_endian_image_round_trips(dtype):
    a = np.array([[1, 2, 3], [4, 5, 6]], dtype=dtype)
    src = zf.HDUList([zf.PrimaryHDU(data=a)]).to_bytes()
    assert np.array_equal(zf.from_bytes(src)[0].data, a.astype(np.dtype(dtype).newbyteorder("=")))


def test_big_endian_column_round_trips():
    a = np.array([1.5, 2.5, 3.5], dtype=">f8")
    src = zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([zf.Column("BE", "D", array=a)])]).to_bytes()
    assert np.allclose(zf.from_bytes(src)[1].data["BE"], [1.5, 2.5, 3.5])


# ── unsigned image write (closes the CAVEATS §3 gap) ──────────────────────────────────────────
@pytest.mark.parametrize("dtype,vals", [
    ("u2", [0, 40000, 65535]),
    ("u4", [0, 3000000000, 4294967295]),
    ("u8", [0, 2**63, 2**64 - 1]),
])
def test_unsigned_image_round_trips(dtype, vals):
    a = np.array(vals, dtype=dtype)
    src = zf.HDUList([zf.PrimaryHDU(data=a)]).to_bytes()
    got = zf.from_bytes(src)[0].data
    assert got.dtype == np.dtype(dtype) and np.array_equal(got, a)


# ── #5/#6 scaled + #12 unsigned column reads ──────────────────────────────────────────────────
def test_fractional_scaled_column_reads_float():
    b = _scaled_col_bytes("1J", np.array([1, 2, 3, 5], dtype="i4"), ll.ZF_INT32, 0.5, 0.25)
    col = zf.from_bytes(b)[1].data["C1"]
    assert col.dtype.kind == "f" and np.allclose(col, [0.75, 1.25, 1.75, 2.75])


def test_unsigned_int16_column_reads_uint():
    b = _scaled_col_bytes("1I", np.array([-32768, 0, 32767], dtype="i2"), ll.ZF_INT16, 1.0, 32768.0)
    col = zf.from_bytes(b)[1].data["C1"]
    assert col.dtype == np.dtype("u2") and np.array_equal(col, [0, 32768, 65535])


@pytest.mark.parametrize("dtype,tform,vals", [
    ("u2", "I", [0, 40000, 65535]),
    ("u4", "J", [0, 3000000000, 4294967295]),
    ("u8", "K", [0, 2**63, 2**64 - 1]),
])
def test_unsigned_column_write_round_trips(dtype, tform, vals):
    a = np.array(vals, dtype=dtype)
    src = zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([zf.Column("U", tform, array=a)])]).to_bytes()
    got = zf.from_bytes(src)[1].data["U"]
    assert got.dtype == np.dtype(dtype) and np.array_equal(got, a)


# ── #7 / #23 VLA columns: element type honored on read, writable on write ─────────────────────
def test_vla_int32_write_and_read():
    vla = np.empty(3, dtype=object)
    vla[0] = np.array([1, 2, 3], dtype="i4")
    vla[1] = np.array([4], dtype="i4")
    vla[2] = np.array([], dtype="i4")
    src = zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([zf.Column("V", "1PJ", array=vla)])]).to_bytes()
    got = zf.from_bytes(src)[1].data["V"]
    assert got[0].dtype == np.dtype("i4")
    assert np.array_equal(got[0], [1, 2, 3]) and np.array_equal(got[1], [4]) and got[2].size == 0


# ── #8 numpy scalar keywords; #13 out-of-range int ───────────────────────────────────────────
def test_numpy_scalar_keywords_typed():
    h = zf.Header()
    hdu = zf.PrimaryHDU(data=np.arange(4, dtype="f4"), header=h)
    h["FGAIN"] = np.float32(1.5)
    h["IGAIN"] = np.int64(1000)
    h["FLAG"] = np.bool_(True)
    hh = zf.from_bytes(zf.HDUList([hdu]).to_bytes())[0].header
    assert isinstance(hh["FGAIN"], float) and hh["FGAIN"] == pytest.approx(1.5)
    assert isinstance(hh["IGAIN"], int) and hh["IGAIN"] == 1000
    assert isinstance(hh["FLAG"], bool) and hh["FLAG"] is True


def test_out_of_range_int_keyword_raises():
    h = zf.Header()
    h["BIG"] = 2**70
    with pytest.raises(zf.FitsError):
        zf.HDUList([zf.PrimaryHDU(data=np.arange(4, dtype="f4"), header=h)]).to_bytes()


# ── #9 structural keyword must not silently corrupt a writable file ───────────────────────────
def test_structural_keyword_persist_raises(tmp_fits):
    zf.writeto(tmp_fits("s.fits"), np.array([[1, 2, 3]], dtype="i2"), overwrite=True)
    with pytest.raises(zf.FitsError):
        with zf.open(tmp_fits("s.fits"), mode="update") as h:
            h[0].header["BITPIX"] = 32


# ── #10 CONTINUE long strings; #14 HIERARCH ──────────────────────────────────────────────────
def test_long_string_reassembled():
    def build(handle):
        ll.check(ll.lib.zf_create_img(handle, 8, 0, None))
        kb, vb = b"LONGKEY", b"X" * 120
        ll.check(ll.lib.zf_write_key_longstr(handle, kb, len(kb), vb, len(vb), None, 0))
    hh = zf.from_bytes(_bytes_from(build))[0].header
    assert hh["LONGKEY"] == "X" * 120


def test_hierarch_keyword_accessible():
    def build(handle):
        ll.check(ll.lib.zf_create_img(handle, 8, 0, None))
        card = b"HIERARCH ESO DET GAIN = 2.15 / detector gain".ljust(80)[:80]
        ll.check(ll.lib.zf_write_record(handle, card))
    hh = zf.from_bytes(_bytes_from(build))[0].header
    assert hh["ESO DET GAIN"] == pytest.approx(2.15)
    assert "ESO DET GAIN" in hh.keys()


# ── #11 ragged; #21 empty; #26 non-ASCII ─────────────────────────────────────────────────────
def test_ragged_from_columns_raises():
    with pytest.raises(ValueError):
        zf.BinTableHDU.from_columns([
            zf.Column("A", "1J", array=np.arange(5)),
            zf.Column("B", "1J", array=np.arange(2)),
        ])


def test_empty_hdulist_raises():
    with pytest.raises(ValueError):
        zf.HDUList([]).to_bytes()


def test_non_ascii_column_raises():
    col = zf.Column("S", "8A", array=np.array(["café", "ok"]))
    with pytest.raises((UnicodeEncodeError, zf.FitsError)):
        zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).to_bytes()


# ── #15 update-mode data write-back ───────────────────────────────────────────────────────────
def test_update_mode_writes_data_back(tmp_fits):
    zf.writeto(tmp_fits("u.fits"), np.zeros((2, 3), dtype="f4"), overwrite=True)
    with zf.open(tmp_fits("u.fits"), mode="update") as h:
        h[0].data[0, 0] = 999.0
        h.flush()
    assert zf.getdata(tmp_fits("u.fits"))[0, 0] == 999.0


# ── #16 getdata fallthrough; #22 PRIMARY name ────────────────────────────────────────────────
def test_getdata_falls_through_empty_primary(tmp_fits):
    hdus = zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([zf.Column("X", "1J", array=np.arange(3))])])
    hdus.writeto(tmp_fits("ep.fits"), overwrite=True)
    data = zf.getdata(tmp_fits("ep.fits"))
    assert data is not None and "X" in data.dtype.names


def test_primary_name_alias(tmp_fits):
    zf.writeto(tmp_fits("p.fits"), np.array([[1, 2]], dtype="i2"), overwrite=True)
    with zf.open(tmp_fits("p.fits")) as hl:
        assert hl["PRIMARY"] is hl[0]


# ── refuted finding: bit 'X' columns DO round-trip under the one-byte-per-bit convention ──────
def test_bit_column_round_trips():
    bits = np.array([[1, 0, 1, 0, 1, 0, 1, 0]], dtype="u1")
    src = zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([zf.Column("B", "8X", array=bits)])]).to_bytes()
    got = zf.from_bytes(src)[1].data["B"]
    assert np.array_equal(got.reshape(1, 8), bits)


# ════════════════════════════════════════════════════════════════════════════════════════════
# 2026-07-03 hunt: lifecycle data-loss + reconstruction/dtype correctness (disk round-trips)
# ════════════════════════════════════════════════════════════════════════════════════════════
def test_readonly_edit_reflected_in_writeto(tmp_fits):
    # A read-only open, edited in memory, must reconstruct on writeto — not copy the stale bytes.
    src, out = tmp_fits("src.fits"), tmp_fits("out.fits")
    zf.HDUList([zf.PrimaryHDU(data=np.ones((3, 4), dtype="i2"))]).writeto(src, overwrite=True)
    hdul = zf.open(src)  # default read-only
    hdul[0].data = hdul[0].data * 10
    hdul[0].header["MYKEY"] = 42
    hdul.writeto(out, overwrite=True)
    hdul.close()
    with zf.open(out) as chk:
        assert int(chk[0].data[0, 1]) == 10
        assert chk[0].header.get("MYKEY") == 42


def test_update_mode_flushes_on_close(tmp_fits):
    # An update-mode data edit must persist even without an explicit flush() (close flushes).
    p = tmp_fits("upd.fits")
    zf.HDUList([zf.PrimaryHDU(data=np.zeros((2, 2), dtype="f4"))]).writeto(p, overwrite=True)
    with zf.open(p, mode="update") as h:
        h[0].data[:] = 7.0
    with zf.open(p) as chk:
        assert float(chk[0].data[0, 0]) == 7.0


def test_ascii_wide_int_column_roundtrips(tmp_fits):
    # An ASCII 'I11' column must read back at full width (was mis-sized to int16 -> overflow).
    p = tmp_fits("ascii.fits")
    col = zf.Column("BIGINT", "I11", array=np.array([100000, 2000000, -3000000], dtype="i8"))
    zf.HDUList([zf.PrimaryHDU(), zf.AsciiTableHDU.from_columns([col])]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        np.testing.assert_array_equal(hdul[1].data["BIGINT"], [100000, 2000000, -3000000])


def test_commentary_preserved_through_reconstruction(tmp_fits):
    # A COMMENT card must survive the reconstruction (non-pristine) write path.
    src, out = tmp_fits("c.fits"), tmp_fits("c_out.fits")
    h = zf.PrimaryHDU(data=np.ones((2, 2), dtype="i2"))
    h.header["COMMENT"] = "provenance note"
    zf.HDUList([h]).writeto(src, overwrite=True)
    hdul = zf.open(src)
    hdul.append(zf.ImageHDU(data=np.zeros(3, dtype="i2"), name="X"))  # forces reconstruction
    hdul.writeto(out, overwrite=True)
    hdul.close()
    with zf.open(out) as chk:
        assert any("provenance" in cc for cc in chk[0].header.comments)


def test_unknown_open_mode_raises(tmp_fits):
    p = tmp_fits("m.fits")
    zf.HDUList([zf.PrimaryHDU(data=np.zeros(2, dtype="i2"))]).writeto(p, overwrite=True)
    with pytest.raises(ValueError):
        zf.open(p, mode="rw")  # a typo must error, not silently fall back to read-only


def test_pathlib_path_accepted(tmp_fits):
    import pathlib
    p = pathlib.Path(tmp_fits("path.fits"))
    zf.HDUList([zf.PrimaryHDU(data=np.arange(4, dtype="i2"))]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:  # both writeto and open accept a Path
        np.testing.assert_array_equal(hdul[0].data, [0, 1, 2, 3])


def test_failed_writeto_leaves_no_partial_file(tmp_fits):
    import os
    p = tmp_fits("dest.fits")
    zf.HDUList([zf.PrimaryHDU(data=np.ones(3, dtype="i2"))]).writeto(p, overwrite=True)
    before = open(p, "rb").read()

    class Boom(zf.PrimaryHDU):
        def _write_to(self, handle, primary):
            raise RuntimeError("boom")

    with pytest.raises(RuntimeError):
        zf.HDUList([Boom(data=np.zeros(2, dtype="i2"))]).writeto(p, overwrite=True)
    assert open(p, "rb").read() == before  # original intact, no partial temp left behind
    assert not os.path.exists(str(p) + ".zigfitsio.tmp")


def test_update_mode_table_writeback(tmp_fits):
    # An in-place edit to a materialized table column must persist on close (update mode).
    p = tmp_fits("tbl.fits")
    col = zf.Column("FLUX", "1E", array=np.array([1.0, 2.0, 3.0], dtype="f4"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).writeto(p, overwrite=True)
    with zf.open(p, mode="update") as h:
        h[1].data["FLUX"][:] = 99.0
    with zf.open(p) as chk:
        np.testing.assert_array_equal(chk[1].data["FLUX"], [99.0, 99.0, 99.0])


def test_append_hdu_persists_on_close(tmp_fits):
    # An HDU appended to an update-mode list must be serialized to the file on close.
    p = tmp_fits("app.fits")
    zf.HDUList([zf.PrimaryHDU(data=np.ones((2, 2), dtype="i2"))]).writeto(p, overwrite=True)
    with zf.open(p, mode="update") as h:
        h.append(zf.ImageHDU(data=np.arange(4, dtype="i2"), name="NEW"))
    with zf.open(p) as chk:
        assert len(chk) == 2
        np.testing.assert_array_equal(chk["NEW"].data, [0, 1, 2, 3])


def test_inplace_compressed_update_fails_loud(tmp_fits):
    # In-place recompression is unsupported; it must raise (not silently drop the edit).
    p = tmp_fits("comp.fits")
    img = np.arange(16, dtype="i2").reshape(4, 4)
    zf.HDUList([zf.PrimaryHDU(), zf.CompImageHDU(data=img, compression="RICE_1")]).writeto(p, overwrite=True)
    with pytest.raises(NotImplementedError):
        with zf.open(p, mode="update") as h:
            h[1].data[0, 0] = 123


def test_inplace_mutation_of_readonly_open_is_saved(tmp_fits):
    # An in-place array mutation (no setter call) of a read-only-opened HDU must be written by
    # writeto/to_bytes, not silently dropped by the verbatim pristine fast-path.
    src, out = tmp_fits("ip_src.fits"), tmp_fits("ip_out.fits")
    zf.HDUList([zf.PrimaryHDU(data=np.ones((3, 4), dtype="i2"))]).writeto(src, overwrite=True)
    hdul = zf.open(src)  # read-only
    hdul[0].data[:] = 7  # in-place; does NOT call the data setter
    hdul.writeto(out, overwrite=True)
    hdul.close()
    with zf.open(out) as chk:
        assert int(chk[0].data[0, 0]) == 7

    # In-place table cell edit on a read-only open, via to_bytes.
    src2 = tmp_fits("ip_tbl.fits")
    col = zf.Column("FLUX", "1E", array=np.array([1.0, 2.0, 3.0], dtype="f4"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).writeto(src2, overwrite=True)
    h2 = zf.open(src2)
    h2[1].data["FLUX"][:] = 42.0
    reread = zf.from_bytes(h2.to_bytes())
    h2.close()
    np.testing.assert_array_equal(reread[1].data["FLUX"], [42.0, 42.0, 42.0])


def test_unchanged_readonly_open_still_uses_fast_path(tmp_fits):
    # Reading data without editing must not disable the verbatim copy (data preserved either way).
    src, out = tmp_fits("fp_src.fits"), tmp_fits("fp_out.fits")
    zf.HDUList([zf.PrimaryHDU(data=np.arange(12, dtype="i2").reshape(3, 4))]).writeto(src, overwrite=True)
    hdul = zf.open(src)
    _ = hdul[0].data  # materialize, but do not edit
    hdul.writeto(out, overwrite=True)
    hdul.close()
    with zf.open(out) as chk:
        np.testing.assert_array_equal(chk[0].data, np.arange(12).reshape(3, 4))


def test_table_data_setter_replaces_rows(tmp_fits):
    # Wholesale table-data replacement (e.g. row filtering) via the .data setter round-trips
    # through writeto; an in-place update-mode row-count change fails loud (no silent loss).
    def mk(p, n):
        cols = [zf.Column("IDX", "1J", array=np.arange(n, dtype="i4")),
                zf.Column("V", "1E", array=(np.arange(n) * 1.5).astype("f4"))]
        zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols)]).writeto(p, overwrite=True)

    src, out = tmp_fits("tds.fits"), tmp_fits("tdso.fits")
    mk(src, 6)
    h = zf.open(src)
    h[1].data = h[1].data[h[1].data["IDX"] % 2 == 0]  # keep even rows -> [0,2,4]
    h.writeto(out, overwrite=True)
    h.close()
    with zf.open(out) as chk:
        np.testing.assert_array_equal(chk[1].data["IDX"], [0, 2, 4])

    # update-mode assignment with the SAME row count persists on close.
    u = tmp_fits("tdu.fits"); mk(u, 4)
    with zf.open(u, mode="update") as h:
        rec = h[1].data.copy(); rec["IDX"][:] = [10, 20, 30, 40]; h[1].data = rec
    with zf.open(u) as chk:
        np.testing.assert_array_equal(chk[1].data["IDX"], [10, 20, 30, 40])

    # update-mode row-count change in place is unsupported -> fail loud, file left intact.
    r = tmp_fits("tdr.fits"); mk(r, 5)
    with pytest.raises(NotImplementedError):
        with zf.open(r, mode="update") as h:
            h[1].data = h[1].data[:3]
    with zf.open(r) as chk:
        assert len(chk[1].data) == 5
