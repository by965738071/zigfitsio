"""Coverage for public API surface (``__all__``) and observed edge-case behavior that the
pre-existing suite did not exercise (test-plan Phase 2).

Each test targets one previously-untested export, method, or dtype path. Where the library has a
real, documented limitation (e.g. a Python-layer gap distinct from the underlying Zig core), the
test pins the *actual* current behavior rather than an aspirational one — matching the style of
``test_bugfixes.py``.
"""

import ctypes as c

import numpy as np
import pytest

import zigfitsio as zf
from zigfitsio import lowlevel as ll


# ── package metadata: __version__ (exported in __all__) is a real version string ───────────────
def test_dunder_version():
    assert isinstance(zf.__version__, str) and zf.__version__
    assert zf.__version__ == ll.version()


# ── module-level conveniences: getheader / getval / getdata(header=True, ext=n) ────────────────
def test_getheader(tmp_fits):
    p = tmp_fits()
    zf.writeto(p, np.zeros((2, 2), dtype="f4"), overwrite=True)
    hdr = zf.getheader(p)
    assert isinstance(hdr, zf.Header)
    assert hdr["NAXIS"] == 2


def test_getval(tmp_fits):
    p = tmp_fits()
    h = zf.Header()
    h["OBSERVER"] = "Kepler"
    zf.writeto(p, np.zeros((2, 2), dtype="f4"), header=h, overwrite=True)
    assert zf.getval(p, "OBSERVER") == "Kepler"


def test_getdata_with_header_and_explicit_ext(tmp_fits):
    p = tmp_fits()
    col = zf.Column("X", "1J", array=np.arange(3, dtype="i4"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col], name="T")]).writeto(p, overwrite=True)
    data, hdr = zf.getdata(p, ext=1, header=True)
    assert "X" in data.dtype.names
    assert hdr["EXTNAME"] == "T"


# ── ImageHDU: an image *extension* (not just the primary) round-trips through Python ───────────
def test_image_extension_roundtrip(tmp_fits):
    primary_data = np.zeros((2, 2), dtype="i2")
    ext_data = np.arange(6, dtype="f4").reshape(2, 3)
    p = tmp_fits()
    zf.HDUList([
        zf.PrimaryHDU(data=primary_data),
        zf.ImageHDU(data=ext_data, name="EXT1"),
    ]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        assert len(hdul) == 2
        assert isinstance(hdul[1], zf.ImageHDU)
        assert hdul[1].name == "EXT1"
        np.testing.assert_array_equal(hdul[1].data, ext_data)
        np.testing.assert_array_equal(hdul[0].data, primary_data)


# ── AsciiTableHDU: write path (read path only had a single-column smoke test via golden) ───────
def test_ascii_table_hdu_write_and_read(tmp_fits):
    ids = np.array([1, 2, 3], dtype="i4")
    flux = np.array([1.25, 2.5, 3.75], dtype="f8")
    name = np.array(["alpha", "beta", "gamma"])
    cols = [
        zf.Column("ID", "I6", ids),
        zf.Column("FLUX", "F12.4", flux),
        zf.Column("NAME", "A5", name),
    ]
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(), zf.AsciiTableHDU.from_columns(cols, name="AT")]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        assert isinstance(hdul[1], zf.AsciiTableHDU)
        rec = hdul[1].data
        np.testing.assert_array_equal(rec["ID"], ids)
        np.testing.assert_allclose(rec["FLUX"], flux)
        names = [s.decode().strip() if isinstance(s, bytes) else s.strip() for s in rec["NAME"]]
        assert names == ["alpha", "beta", "gamma"]


# ── exception classes: each is reachable and correctly typed, not just FitsError/KeywordNotFound ─
def test_fits_io_error_on_missing_file(tmp_fits):
    with pytest.raises(zf.FitsIOError):
        zf.open(tmp_fits("does-not-exist.fits"))


def test_fits_header_error_on_undefined_value(tmp_fits):
    # `Header` (the Python dict-like wrapper) parses cards leniently and never raises on read; a
    # genuine `FitsHeaderError` (status 204, ValueUndefined) comes from the low-level ABI reading
    # a keyword whose value indicator is present but the value field is blank.
    handle = c.c_void_p()
    ll.check(ll.lib.zf_create_memory(None, c.byref(handle)))
    ll.check(ll.lib.zf_create_img(handle, 8, 0, None))
    card = b"UNDEF   = ".ljust(80)
    ll.check(ll.lib.zf_write_record(handle, card))
    try:
        v = c.c_double()
        key = b"UNDEF"
        with pytest.raises(zf.FitsHeaderError):
            ll.check(ll.lib.zf_read_key_dbl(handle, key, len(key), c.byref(v)))
    finally:
        ll.lib.zf_close(handle)


def test_fits_table_error_on_missing_column(tmp_fits):
    p = tmp_fits()
    col = zf.Column("X", "1J", array=np.arange(3, dtype="i4"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        h = hdul[1]._select()
        t = c.c_void_p()
        ll.check(ll.lib.zf_table_open(h, c.byref(t)))
        try:
            colnum = c.c_int()
            with pytest.raises(zf.FitsTableError):
                name = b"NOSUCH"
                ll.check(ll.lib.zf_table_colnum(t, name, len(name), c.byref(colnum)))
        finally:
            ll.lib.zf_table_close(t)


def test_fits_type_error_on_unsupported_dtype(tmp_fits):
    # bool arrays have no direct ZfType mapping (see _dtypes._DTYPE_TO_ZF): writing one raises
    # FitsTypeError, a documented Python-layer limitation (write a uint8 0/1 array instead).
    with pytest.raises(zf.FitsTypeError):
        zf.HDUList([zf.PrimaryHDU(data=np.array([True, False]))]).to_bytes()


def test_fits_wcs_error_on_missing_wcs(tmp_fits):
    p = tmp_fits()
    zf.writeto(p, np.zeros((4, 4), dtype="f4"), overwrite=True)
    with zf.open(p) as hdul:
        with pytest.raises(zf.FitsWcsError):
            hdul[0].pix2world(1.0, 1.0)


# ── Header mapping protocol: the ops test_highlevel.py never exercises ──────────────────────────
def test_header_mapping_protocol_detached():
    h = zf.Header()
    h["A"] = 1
    h["B"] = ("two", "a comment")

    assert h.get("A") == 1
    assert h.get("NOSUCH", "fallback") == "fallback"
    assert list(iter(h)) == ["A", "B"]
    assert len(h) == 2
    assert h.items() == [("A", 1), ("B", "two")]
    assert h.values() == [1, "two"]
    assert [c[0] for c in h.cards()] == ["A", "B"]
    assert "A" in repr(h) and "B" in repr(h)

    del h["A"]
    assert "A" not in h
    assert len(h) == 1
    with pytest.raises(KeyError):
        del h["NOSUCH"]


def test_header_delete_persists_on_a_writable_open_file(tmp_fits):
    p = tmp_fits()
    hdr = zf.Header()
    hdr["TEMP"] = 42
    zf.writeto(p, np.zeros((2, 2), dtype="f4"), header=hdr, overwrite=True)
    with zf.open(p, mode="update") as hdul:
        assert "TEMP" in hdul[0].header
        del hdul[0].header["TEMP"]
    with zf.open(p) as hdul:
        assert "TEMP" not in hdul[0].header


def test_header_comments_and_history_properties():
    def build(handle):
        ll.check(ll.lib.zf_create_img(handle, 8, 0, None))
        for text in (b"HISTORY first step", b"HISTORY second step", b"COMMENT a note"):
            card = text.ljust(80)[:80]
            ll.check(ll.lib.zf_write_record(handle, card))

    handle = c.c_void_p()
    ll.check(ll.lib.zf_create_memory(None, c.byref(handle)))
    build(handle)
    ll.check(ll.lib.zf_flush(handle))
    size = c.c_uint64()
    ll.check(ll.lib.zf_data_size(handle, c.byref(size)))
    buf = c.create_string_buffer(int(size.value))
    got = c.c_size_t()
    ll.check(ll.lib.zf_read_bytes(handle, 0, buf, size.value, c.byref(got)))
    ll.lib.zf_close(handle)
    hh = zf.from_bytes(buf.raw[: got.value])[0].header
    assert hh.history == ["first step", "second step"]
    assert hh.comments == ["a note"]


# ── HDUList.info() ───────────────────────────────────────────────────────────────────────────
def test_hdulist_info(tmp_fits):
    p = tmp_fits()
    col = zf.Column("X", "1J", array=np.arange(3, dtype="i4"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col], name="EVENTS")]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        info = hdul.info()
        assert "PRIMARY" in info
        assert "EVENTS" in info
        assert len(info.splitlines()) == 2


# ── CompImageHDU: codecs other than the RICE_1 smoke test ───────────────────────────────────────
@pytest.mark.parametrize("codec", ["GZIP_1", "PLIO_1", "HCOMPRESS_1"])
def test_compimage_other_codecs_roundtrip(tmp_fits, codec):
    ramp = np.arange(256, dtype="i4").reshape(16, 16)
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(), zf.CompImageHDU(ramp, compression=codec)]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        np.testing.assert_array_equal(hdul[1].data, ramp)


def test_compimage_explicit_tile_shape(tmp_fits):
    ramp = np.arange(256, dtype="i4").reshape(16, 16)
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(), zf.CompImageHDU(ramp, compression="RICE_1", tile=[16, 4])]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        np.testing.assert_array_equal(hdul[1].data, ramp)


# ── open(): mode="append", .fits.gz path; from_bytes(mode="update") ─────────────────────────────
def test_open_mode_append_can_add_an_hdu(tmp_fits):
    p = tmp_fits()
    zf.writeto(p, np.zeros((2, 2), dtype="i2"), overwrite=True)
    with zf.open(p, mode="append") as hdul:
        col = zf.Column("X", "1J", array=np.arange(3, dtype="i4"))
        hdul.append(zf.BinTableHDU.from_columns([col], name="NEW"))
        hdul.writeto(tmp_fits("appended.fits"), overwrite=True)
    with zf.open(tmp_fits("appended.fits")) as hdul2:
        assert len(hdul2) == 2
        assert hdul2[1].name == "NEW"


def test_open_dotgz_path(tmp_fits):
    p = tmp_fits("plain.fits")
    data = np.arange(6, dtype="i2").reshape(2, 3)
    zf.writeto(p, data, overwrite=True)

    gz_path = tmp_fits("out.fits.gz").encode()
    handle = c.c_void_p()
    pb = p.encode()
    ll.check(ll.lib.zf_open_file(pb, len(pb), ll.READONLY, None, c.byref(handle)))
    ll.check(ll.lib.zf_save_gzip(handle, gz_path, len(gz_path)))
    ll.lib.zf_close(handle)

    with zf.open(gz_path.decode()) as hdul:
        np.testing.assert_array_equal(hdul[0].data, data)


def test_from_bytes_mode_update_persists_edits():
    src = zf.HDUList([zf.PrimaryHDU(data=np.zeros((2, 2), dtype="f4"))]).to_bytes()
    with zf.from_bytes(src, mode="update") as hdul:
        hdul[0].header["OBSERVER"] = "Update-mode"
        hdul.flush()
        out = hdul.to_bytes()
    with zf.from_bytes(out) as hdul2:
        assert hdul2[0].header["OBSERVER"] == "Update-mode"


# ── Finding: fields beyond .severity, produced by a real malformed file ─────────────────────────
def test_finding_fields_on_malformed_golden(golden_dir):
    path = golden_dir / "conformance" / "malformed" / "blank_on_float.fits"
    if not path.exists():
        pytest.skip("malformed conformance fixture not present")
    findings = zf.verify(str(path))
    errs = [f for f in findings if f.severity == "error"]
    assert errs, "expected at least one error finding on a deliberately malformed file"
    f = errs[0]
    assert f.hdu == 1
    assert f.keyword == "BLANK"
    assert "BITPIX" in f.message or "positive" in f.message
    assert repr(f).startswith("<error HDU 1")


# ── WCS: the alt (alternate WCS) parameter ──────────────────────────────────────────────────────
def test_wcs_alt_parameter(tmp_fits):
    data = np.zeros((64, 64), dtype="f4")
    hdr = zf.Header()
    for k, v in [
        ("CTYPE1A", "RA---TAN"), ("CTYPE2A", "DEC--TAN"),
        ("CRPIX1A", 32.0), ("CRPIX2A", 32.0),
        ("CRVAL1A", 10.0), ("CRVAL2A", -5.0),
        ("CDELT1A", -0.002), ("CDELT2A", 0.002),
    ]:
        hdr[k] = v
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(data=data, header=hdr)]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        lon, lat = hdul[0].pix2world(20.0, 10.0, alt="A")
        px, py = hdul[0].world2pix(lon, lat, alt="A")
        assert abs(px - 20.0) < 1e-6
        assert abs(py - 10.0) < 1e-6
        # The default (primary) WCS is untouched/absent -> a plain pix2world() call fails.
        with pytest.raises(zf.FitsWcsError):
            hdul[0].pix2world(20.0, 10.0)


# ── Column.unit: write-only from the high-level API today (documented gap) ─────────────────────
def test_column_unit_is_not_exposed_by_the_high_level_columns_property(tmp_fits):
    # `Column(unit=...)` is written to TUNITn (verified below via the low-level escape hatch), but
    # `_TableHDU.columns` only returns column *names* today -- there is no high-level accessor for
    # a column's unit. This pins the actual, currently write-only behavior.
    p = tmp_fits()
    col = zf.Column("FLUX", "E14.7", array=np.array([1.0, 2.0], dtype="f8"), unit="Jy")
    zf.HDUList([zf.PrimaryHDU(), zf.AsciiTableHDU.from_columns([col])]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        assert hdul[1].columns == ["FLUX"]  # names only, no unit
        # The TUNIT1 card really was written; read it back through the low-level ASCII-table path
        # (zf_table_col_unit surfaces TUNITn for ASCII tables; see the Zig capi test-plan Phase 1
        # finding that binary tables do not).
        h = hdul[1]._select()
        t = c.c_void_p()
        ll.check(ll.lib.zf_table_open(h, c.byref(t)))
        try:
            buf = c.create_string_buffer(16)
            out_len = c.c_size_t()
            ll.check(ll.lib.zf_table_col_unit(t, 0, buf, 16, c.byref(out_len)))
            assert buf.raw[: out_len.value] == b"Jy"
        finally:
            ll.lib.zf_table_close(t)


# ── dtype edges: i1 images (unsupported), complex columns, logical 'L' columns ──────────────────
def test_i1_image_write_is_a_documented_unsupported_dtype(tmp_fits):
    # `_dtypes.DTYPE_TO_BITPIX` has no entry for signed-byte (`i1`): the Zig core supports the
    # BITPIX=8 + BZERO=-128 signed-byte convention (FR-IMG-7), but the Python high-level image
    # write path does not map to it yet. Pin the actual (typed-error) behavior.
    with pytest.raises(zf.FitsTypeError):
        zf.HDUList([zf.PrimaryHDU(data=np.array([[-1, 0, 1]], dtype="i1"))]).to_bytes()


def test_complex_column_roundtrip(tmp_fits):
    vals = np.array([1 + 2j, -3 + 4j, 0 - 1j], dtype="c8")
    p = tmp_fits()
    col = zf.Column("CPLX", "1C", array=vals)
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        got = hdul[1].data["CPLX"]
        assert got.dtype == np.dtype("c8")
        np.testing.assert_allclose(got, vals)


def test_logical_column_write_requires_uint8_not_bool(tmp_fits):
    # `zf_code` has no ZfType mapping for numpy `bool`, so a native bool array cannot be passed
    # directly for an 'L' (logical) TFORM -- pin that typed error, then show the documented
    # workaround (a uint8 0/1 array) round-trips, and that the read dtype today is uint8, not
    # bool (bin_elem_dtype maps 'L' -> u1, per _dtypes.py).
    with pytest.raises(zf.FitsTypeError):
        col = zf.Column("FLAG", "1L", array=np.array([True, False, True]))
        zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).to_bytes()

    p = tmp_fits()
    workaround = zf.Column("FLAG", "1L", array=np.array([1, 0, 1], dtype="u1"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([workaround])]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        got = hdul[1].data["FLAG"]
        assert got.dtype == np.dtype("u1")
        np.testing.assert_array_equal(got, [1, 0, 1])
