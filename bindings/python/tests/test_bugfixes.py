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


def test_long_string_quote_split_across_continue():
    """A '' escape pair split across a CONTINUE boundary (as astropy writes) must not truncate.

    astropy splits the *escaped* representation and can cut a ``''`` pair in half at a card
    boundary, so the base card ends with a lone ``'`` before the ``&`` sentinel and the CONTINUE
    starts with the pair's second ``'``. Deterministic, no astropy dependency.
    """
    from zigfitsio.header import parse_cards

    value = ("abc'def&" * 12) + "END"          # 99 chars, quotes and ampersands throughout
    escaped = value.replace("'", "''")          # FITS doubles quotes
    cut = 67                                     # cuts the 8th block's '' pair after its first '
    assert escaped[cut - 1] == "'" and escaped[cut] == "'"  # sanity: split really halves a pair
    base = ("LSTR    = '" + escaped[:cut] + "&'").ljust(80).encode("ascii")
    cont = ("CONTINUE  '" + escaped[cut:] + "'").ljust(80).encode("ascii")
    assert len(base) == 80 and len(cont) == 80

    cards = parse_cards([base, cont])
    got = next(c.value for c in cards if not c.commentary and c.keyword == "LSTR")
    assert got == value


def test_hierarch_long_string_folded_across_continue():
    """A HIERARCH long string continued by CONTINUE must fold, not leak the CONTINUE card.

    The value field of a HIERARCH card starts after ``=`` (not at column 10), so the fold must
    locate it via ``_value_field``. Deterministic, no astropy dependency.
    """
    from zigfitsio.header import parse_cards

    # `HIERARCH ESO LONG STR = '` is a 25-col prefix, so each fragment must fit the remaining columns.
    part1 = "part one is here, " + "x" * 30                 # 48 chars → base card = 75 cols
    part2 = "part two continues " + "y" * 20 + " END"        # 43 chars → cont card = 55 cols
    value = part1 + part2
    base = ("HIERARCH ESO LONG STR = '" + part1 + "&'").ljust(80).encode("ascii")
    cont = ("CONTINUE  '" + part2 + "'").ljust(80).encode("ascii")
    assert len(base) == 80 and len(cont) == 80

    cards = parse_cards([base, cont])
    got = next(c.value for c in cards if not c.commentary and c.keyword == "ESO LONG STR")
    assert got == value
    assert all(c.keyword != "CONTINUE" for c in cards)  # continuation consumed, not leaked


def test_hierarch_long_string_quote_split_across_continue():
    """A ``''`` escape pair split across a CONTINUE boundary must not truncate a HIERARCH value.

    Same split-pair hazard as the standard-keyword case, exercised through the HIERARCH value-field
    path. Deterministic, no astropy dependency.
    """
    from zigfitsio.header import parse_cards

    value = ("abc'def&" * 12) + "END"          # 99 chars, quotes and ampersands throughout
    escaped = value.replace("'", "''")          # FITS doubles quotes
    cut = 49                                     # 6th block's '' pair; keeps base ≤ 80 with the prefix
    assert escaped[cut - 1] == "'" and escaped[cut] == "'"  # sanity: split really halves a pair
    base = ("HIERARCH ESO LSTR = '" + escaped[:cut] + "&'").ljust(80).encode("ascii")
    cont = ("CONTINUE  '" + escaped[cut:] + "'").ljust(80).encode("ascii")
    assert len(base) == 80 and len(cont) == 80

    cards = parse_cards([base, cont])
    got = next(c.value for c in cards if not c.commentary and c.keyword == "ESO LSTR")
    assert got == value
    assert all(c.keyword != "CONTINUE" for c in cards)


def test_hierarch_keyword_accessible():
    def build(handle):
        ll.check(ll.lib.zf_create_img(handle, 8, 0, None))
        card = b"HIERARCH ESO DET GAIN = 2.15 / detector gain".ljust(80)[:80]
        ll.check(ll.lib.zf_write_record(handle, card))
    hh = zf.from_bytes(_bytes_from(build))[0].header
    assert hh["ESO DET GAIN"] == pytest.approx(2.15)
    assert "ESO DET GAIN" in hh.keys()


# ── #11/#26 HIERARCH long-string WRITE (multi-card) ───────────────────────────────────────────
def _header_cards(blob: bytes) -> "list[bytes]":
    """The 80-byte cards of the first header block run, up to and excluding END."""
    cards = []
    for i in range(0, len(blob), 80):
        card = blob[i : i + 80]
        if card[:8].rstrip() == b"END":
            break
        cards.append(card)
    return cards


def test_hierarch_long_string_write_roundtrip():
    """A long HIERARCH string survives writeto/to_bytes exactly (was: silent truncation at 80)."""
    value = ("the quick brown fox " * 12).strip()  # 239 chars
    hdu = zf.PrimaryHDU()
    hdu.header["ESO LONG STR"] = (value, "my provenance comment")
    blob = zf.HDUList([hdu]).to_bytes()

    # Raw layout: HIERARCH base fragment ends with the '&' sentinel, CONTINUE cards follow.
    cards = _header_cards(blob)
    base = [c for c in cards if c.startswith(b"HIERARCH ESO LONG STR = '")]
    assert len(base) == 1 and base[0].rstrip().endswith(b"&'")
    conts = [c for c in cards if c[:8] == b"CONTINUE"]
    assert len(conts) >= 2

    hh = zf.from_bytes(blob)[0].header
    assert hh["ESO LONG STR"] == value
    assert hh.comment_of("ESO LONG STR") == "my provenance comment"


@pytest.mark.parametrize("offset", range(40, 70))
def test_hierarch_long_string_quote_boundary_sweep(offset):
    """Slide a quote across the base-card boundary; every escaped split must round-trip."""
    value = "x" * offset + "'" + "y" * (120 - offset)
    hdu = zf.PrimaryHDU()
    hdu.header["ESO Q W"] = value
    hh = zf.from_bytes(zf.HDUList([hdu]).to_bytes())[0].header
    assert hh["ESO Q W"] == value


def test_hierarch_prefix_not_doubled():
    """A key spelled with an explicit HIERARCH prefix must not emit HIERARCH twice (item 26)."""
    hdu = zf.PrimaryHDU()
    hdu.header["HIERARCH ESO DET ID"] = 42
    blob = zf.HDUList([hdu]).to_bytes()
    card = next(c for c in _header_cards(blob) if b"ESO DET ID" in c)
    assert card.count(b"HIERARCH") == 1
    assert zf.from_bytes(blob)[0].header["ESO DET ID"] == 42


def test_hierarch_float_uppercase_exponent():
    """HIERARCH float literals use the FITS uppercase exponent, not repr()'s lowercase (item 26)."""
    hdu = zf.PrimaryHDU()
    hdu.header["ESO DET EXPTIME"] = 1.5e-07
    blob = zf.HDUList([hdu]).to_bytes()
    card = next(c for c in _header_cards(blob) if b"ESO DET EXPTIME" in c)
    assert b"E-07" in card and b"e-07" not in card
    assert zf.from_bytes(blob)[0].header["ESO DET EXPTIME"] == pytest.approx(1.5e-07)


def test_hierarch_comment_dedicated_card():
    """A comment that cannot ride the last data fragment gets astropy's CONTINUE '' card."""
    from zigfitsio.core import _hierarch_cards

    # base takes 53 chars, the next CONTINUE 67; the final 60 exceed the comment-reserving
    # terminal window (49) so they fill their own card and the comment spills to a '' card.
    value = "A" * 180
    cards = _hierarch_cards("ESO LONG STR", value, "trailing comment")
    assert cards[-1].startswith(b"CONTINUE  '' / trailing comment")
    hdu = zf.PrimaryHDU()
    hdu.header["ESO LONG STR"] = (value, "trailing comment")
    hh = zf.from_bytes(zf.HDUList([hdu]).to_bytes())[0].header
    assert hh["ESO LONG STR"] == value
    assert hh.comment_of("ESO LONG STR") == "trailing comment"


def test_hierarch_nonstring_overflow():
    """Non-string HIERARCH cards never CONTINUE: the comment is cut, a value never is (item 11)."""
    from zigfitsio.core import _hierarch_cards

    # Comment overflow: the integer value survives intact, the comment is truncated at col 80.
    kw = "ESO DET " + "LONG NAME " * 4
    [card] = _hierarch_cards(kw.strip(), 123456, "c" * 60)
    assert b"= 123456 / " in card
    # Value overflow (absurd keyword): loud error instead of silent truncation.
    with pytest.raises(ValueError):
        _hierarch_cards("ESO " + "X" * 76, 1, None)


def test_hierarch_numpy_scalar_value():
    """numpy scalars normalize before HIERARCH serialization (no 'np.float64(...)' literals)."""
    hdu = zf.PrimaryHDU()
    hdu.header["ESO DET GAIN2"] = np.float64(2.5)
    hdu.header["ESO DET NX"] = np.int32(1024)
    hh = zf.from_bytes(zf.HDUList([hdu]).to_bytes())[0].header
    assert hh["ESO DET GAIN2"] == pytest.approx(2.5)
    assert hh["ESO DET NX"] == 1024


def _file_continue_count(path) -> int:
    with open(path, "rb") as fh:
        return sum(1 for c in _header_cards(fh.read()) if c[:8] == b"CONTINUE")


def test_hierarch_update_mode_write_and_replace(tmp_fits):
    """Update-mode HIERARCH set + replace: no Name.parse error, no orphaned CONTINUE run."""
    p = tmp_fits()
    zf.writeto(p, np.zeros((4, 4), dtype="f4"))
    long_value = ("it's long " * 20).strip()
    with zf.open(p, mode="update") as hdul:
        hdul[0].header["ESO LONG KEY"] = (long_value, "note")  # was: BadKeywordName from Zig
    with zf.open(p) as hdul:
        assert hdul[0].header["ESO LONG KEY"] == long_value
        assert hdul[0].header.comment_of("ESO LONG KEY") == "note"
    assert _file_continue_count(p) >= 2

    with zf.open(p, mode="update") as hdul:
        hdul[0].header["ESO LONG KEY"] = "short"  # replacement must remove the old run
    with zf.open(p) as hdul:
        assert hdul[0].header["ESO LONG KEY"] == "short"
    assert _file_continue_count(p) == 0


def test_update_mode_standard_longstr_replace_no_orphans(tmp_fits):
    """Replacing a standard-key long string in update mode leaves no orphan CONTINUE (item 24)."""
    p = tmp_fits()
    zf.writeto(p, np.zeros((4, 4), dtype="f4"))
    with zf.open(p, mode="update") as hdul:
        hdul[0].header["LSTR"] = "z" * 150
    assert _file_continue_count(p) >= 2
    with zf.open(p, mode="update") as hdul:
        hdul[0].header["LSTR"] = "tiny"
    with zf.open(p) as hdul:
        assert hdul[0].header["LSTR"] == "tiny"
    assert _file_continue_count(p) == 0


def test_update_mode_longstr_delete_removes_run(tmp_fits):
    """Deleting a long-string key in update mode removes its whole CONTINUE run (item 34)."""
    p = tmp_fits()
    zf.writeto(p, np.zeros((4, 4), dtype="f4"))
    with zf.open(p, mode="update") as hdul:
        hdul[0].header["LSTR"] = "z" * 150
    with zf.open(p, mode="update") as hdul:
        del hdul[0].header["LSTR"]
    with zf.open(p) as hdul:
        assert "LSTR" not in hdul[0].header.keys()
    assert _file_continue_count(p) == 0


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


def test_commentary_accumulates_detached(tmp_fits):
    """BUGHUNT #6: repeated header['COMMENT']/['HISTORY'] must ACCUMULATE, not overwrite."""
    h = zf.PrimaryHDU(data=np.ones((2, 2), dtype="i2"))
    h.header["COMMENT"] = "first note"
    h.header["COMMENT"] = "second note"
    h.header["HISTORY"] = "step 1"
    h.header["HISTORY"] = "step 2"
    # In-memory: both cards present, and commentary is NOT counted as a keyword.
    assert h.header.comments == ["first note", "second note"]
    assert h.header.history == ["step 1", "step 2"]
    assert "COMMENT" not in h.header.keys()
    assert "HISTORY" not in h.header.keys()
    assert "COMMENT" in h.header and "HISTORY" in h.header
    # And they survive a round trip.
    out = tmp_fits("acc.fits")
    zf.HDUList([h]).writeto(out, overwrite=True)
    with zf.open(out) as chk:
        assert chk[0].header.comments == ["first note", "second note"]
        assert chk[0].header.history == ["step 1", "step 2"]


def test_commentary_accumulates_update_mode(tmp_fits):
    """Eager (update-mode) commentary writes accumulate through the C ABI and persist on close."""
    p = tmp_fits()
    zf.writeto(p, np.zeros((3, 3), dtype="f4"))
    with zf.open(p, mode="update") as hdul:
        hdul[0].header["COMMENT"] = "a"
        hdul[0].header["COMMENT"] = "b"
        hdul[0].header.add_history("h1")
        hdul[0].header.add_history("h2")
    with zf.open(p) as hdul:
        assert hdul[0].header.comments == ["a", "b"]
        assert hdul[0].header.history == ["h1", "h2"]
    # The malformed valued form (COMMENT = 'text') must never be written.
    with open(p, "rb") as fh:
        assert b"COMMENT = '" not in fh.read()


def test_commentary_long_text_wraps(tmp_fits):
    """Text longer than the 72-char free-text field splits across cards instead of truncating."""
    long_text = "".join(str(i % 10) for i in range(100))  # 100 chars
    h = zf.PrimaryHDU(data=np.ones((2, 2), dtype="i2"))
    h.header["COMMENT"] = long_text
    assert h.header.comments == [long_text[:72], long_text[72:]]  # in-memory, already split
    out = tmp_fits("wrap.fits")
    zf.HDUList([h]).writeto(out, overwrite=True)
    with zf.open(out) as chk:
        chunks = chk[0].header.comments
        assert all(len(c) <= 72 for c in chunks)
        assert "".join(chunks) == long_text


def test_commentary_mutable_view_and_replace(tmp_fits):
    """header['COMMENT'] is a mutable, astropy-like view: index, assign, replace-all, delete."""
    p = tmp_fits()
    zf.writeto(p, np.zeros((3, 3), dtype="f4"))
    with zf.open(p, mode="update") as hdul:
        hdr = hdul[0].header
        hdr.add_comment("one")
        hdr.add_comment("two")
        view = hdr["COMMENT"]
        assert len(view) == 2 and view[0] == "one" and list(view) == ["one", "two"]
        assert view == ["one", "two"]
        view[0] = "ONE"  # in-place edit persists
    with zf.open(p) as hdul:
        assert hdul[0].header.comments == ["ONE", "two"]
    # Replace-all via list assignment, then delete-all.
    with zf.open(p, mode="update") as hdul:
        hdul[0].header["COMMENT"] = ["x", "y", "z"]
    with zf.open(p) as hdul:
        assert hdul[0].header.comments == ["x", "y", "z"]
    with zf.open(p, mode="update") as hdul:
        del hdul[0].header["COMMENT"]
    with zf.open(p) as hdul:
        assert hdul[0].header.comments == []


def test_commentary_blank_keyword_persists(tmp_fits):
    """Blank-keyword ('') commentary append/edit/delete persist in update mode, consistently (finding 1)."""
    p = tmp_fits()
    zf.writeto(p, np.zeros((3, 3), dtype="f4"))
    blanks = lambda hdr: [c.value for c in hdr._cards if c.commentary and c.keyword == ""]
    with zf.open(p, mode="update") as hdul:
        hdul[0].header[""] = "blank one"
        hdul[0].header[""] = "blank two"
    with zf.open(p) as hdul:
        assert blanks(hdul[0].header) == ["blank one", "blank two"]
    with zf.open(p, mode="update") as hdul:
        hdul[0].header[""][0] = "EDITED"  # in-place edit routes through the resync path
    with zf.open(p) as hdul:
        assert blanks(hdul[0].header) == ["EDITED", "blank two"]
    with zf.open(p, mode="update") as hdul:
        del hdul[0].header[""]  # removes every blank-name card
    with zf.open(p) as hdul:
        assert blanks(hdul[0].header) == []


def test_commentary_tuple_is_value_comment_not_replace():
    """A 2-tuple on a commentary key is (text, comment) — one card, not two (finding 2)."""
    h = zf.PrimaryHDU(data=np.ones((2, 2), dtype="i2")).header
    h["COMMENT"] = ("the note", "ignored comment")
    assert h.comments == ["the note"]
    h["COMMENT"] = ["x", "y"]  # a list still replaces all
    assert h.comments == ["x", "y"]


def test_commentary_view_slice_assignment_raises():
    """Slice assignment/deletion on the commentary view gives a clear TypeError (finding 3)."""
    h = zf.PrimaryHDU(data=np.ones((2, 2), dtype="i2")).header
    h.add_comment("a")
    h.add_comment("b")
    assert h["COMMENT"][0:2] == ["a", "b"]  # read-slicing still works
    with pytest.raises(TypeError):
        h["COMMENT"][0:1] = ["z"]
    with pytest.raises(TypeError):
        del h["COMMENT"][0:1]


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


def _abc_table(p):
    """Write a 3-column i8 binary table A/B/C for the column-identity tests."""
    cols = [zf.Column("A", "1K", array=np.array([1, 2, 3], dtype="i8")),
            zf.Column("B", "1K", array=np.array([10, 20, 30], dtype="i8")),
            zf.Column("C", "1K", array=np.array([100, 200, 300], dtype="i8"))]
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols)]).writeto(p, overwrite=True)


def test_update_mode_table_reorder_writes_to_named_columns(tmp_fits):
    # BUGHUNT-2026-07-06 #2: in-place table write-back must match columns to the file by name, not by
    # the recarray's positional order. Reassigning a reordered recarray must write each column back
    # to its OWN cells (pre-fix, a changed column's values landed in whatever column sat at index 0).
    p = tmp_fits("reorder.fits")
    _abc_table(p)
    with zf.open(p, mode="update") as h:
        reordered = h[1].data[["C", "B", "A"]].copy()  # same column set, reversed order
        reordered["C"][:] = [111, 222, 333]
        h[1].data = reordered
    with zf.open(p) as chk:
        np.testing.assert_array_equal(chk[1].data["C"], [111, 222, 333])
        np.testing.assert_array_equal(chk[1].data["A"], [1, 2, 3])
        np.testing.assert_array_equal(chk[1].data["B"], [10, 20, 30])


def test_update_mode_table_column_set_change_fails_loud(tmp_fits):
    # BUGHUNT-2026-07-06 #2: reassigning a recarray whose column SET differs (here only "C") to a
    # 3-column file must fail loud and leave the file intact — not silently write "C"'s values into
    # column "A". This is the exact reported trigger.
    p = tmp_fits("colset.fits")
    _abc_table(p)
    with pytest.raises(NotImplementedError):
        with zf.open(p, mode="update") as h:
            _ = h[1].data
            h[1].data = np.array([(111,), (222,), (333,)], dtype=[("C", "i8")])
    with zf.open(p) as chk:  # nothing was written
        np.testing.assert_array_equal(chk[1].data["A"], [1, 2, 3])
        np.testing.assert_array_equal(chk[1].data["C"], [100, 200, 300])


def test_writeto_reassigned_widened_dtype_not_truncated(tmp_fits):
    # BUGHUNT-2026-07-06 #3: after reassigning a column with a wider dtype, writeto must synthesize a
    # matching TFORM instead of reusing the old (narrow) one by index and truncating the values.
    src, out = tmp_fits("wsrc.fits"), tmp_fits("wout.fits")
    col = zf.Column("V", "1I", array=np.array([1, 2, 3], dtype="i2"))  # int16 on disk
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).writeto(src, overwrite=True)
    h = zf.open(src)
    h[1].data = np.array([(40000,), (50000,), (60000,)], dtype=[("V", "i8")])  # exceed int16 range
    h.writeto(out, overwrite=True)
    h.close()
    with zf.open(out) as chk:
        np.testing.assert_array_equal(chk[1].data["V"], [40000, 50000, 60000])


def test_writeto_reassigned_reorder_keeps_column_types(tmp_fits):
    # BUGHUNT-2026-07-06 #3: a reordered recarray must reconstruct each column with its OWN format;
    # pre-fix the float column was emitted under the int column's TFORM (by position) and corrupted.
    src, out = tmp_fits("rsrc.fits"), tmp_fits("rout.fits")
    cols = [zf.Column("I", "1J", array=np.array([1, 2, 3], dtype="i4")),
            zf.Column("F", "1D", array=np.array([1.5, 2.5, 3.5], dtype="f8"))]
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols)]).writeto(src, overwrite=True)
    h = zf.open(src)
    h[1].data = h[1].data[["F", "I"]].copy()  # reversed field order
    h.writeto(out, overwrite=True)
    h.close()
    with zf.open(out) as chk:
        np.testing.assert_array_equal(chk[1].data["F"], [1.5, 2.5, 3.5])
        np.testing.assert_array_equal(chk[1].data["I"], [1, 2, 3])


def test_writeto_reassigned_added_column_synthesizes_tform(tmp_fits):
    # BUGHUNT-2026-07-06 #3: a field with no matching file column synthesizes its TFORM from the
    # numpy dtype (there is no stale format to reuse).
    src, out = tmp_fits("asrc.fits"), tmp_fits("aout.fits")
    col = zf.Column("A", "1J", array=np.array([1, 2, 3], dtype="i4"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).writeto(src, overwrite=True)
    h = zf.open(src)
    grown = np.empty(3, dtype=[("A", "i4"), ("Z", "f8")])
    grown["A"] = h[1].data["A"]
    grown["Z"] = [0.25, 0.5, 0.75]
    h[1].data = grown
    h.writeto(out, overwrite=True)
    h.close()
    with zf.open(out) as chk:
        assert set(chk[1].columns) == {"A", "Z"}
        np.testing.assert_array_equal(chk[1].data["A"], [1, 2, 3])
        np.testing.assert_array_equal(chk[1].data["Z"], [0.25, 0.5, 0.75])


def test_writeto_logical_column_keeps_l_tform(tmp_fits):
    # PR #28 review #1: a logical (L) column reads back as u1, but a reconstructing writeto must keep
    # TFORM 'L' -- not flatten it to the generic 'B'. Values survive either way, so assert the TFORM
    # letter, not just the values.
    src, out = tmp_fits("lsrc.fits"), tmp_fits("lout.fits")
    col = zf.Column("FLAG", "1L", array=np.array([True, False, True]))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).writeto(src, overwrite=True)
    h = zf.open(src)
    h[1].data = h[1].data.copy()  # dirty the list -> writeto reconstructs via _emit_columns
    h.writeto(out, overwrite=True)
    h.close()
    with zf.open(out) as chk:
        assert chk[1].header["TFORM1"].strip() == "1L"
        np.testing.assert_array_equal(chk[1].data["FLAG"].astype(bool), [True, False, True])


def test_writeto_bit_column_keeps_x_tform(tmp_fits):
    # PR #28 review #1 (bit variant): an X column also reads back as u1 and must keep TFORM 'X'.
    src, out = tmp_fits("xsrc.fits"), tmp_fits("xout.fits")
    col = zf.Column("BITS", "1X", array=np.array([1, 0, 1], dtype="u1"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).writeto(src, overwrite=True)
    h = zf.open(src)
    h[1].data = h[1].data.copy()
    h.writeto(out, overwrite=True)
    h.close()
    with zf.open(out) as chk:
        assert chk[1].header["TFORM1"].strip() == "1X"
        np.testing.assert_array_equal(chk[1].data["BITS"], [1, 0, 1])


def test_update_mode_unnamed_column_roundtrips(tmp_fits):
    # PR #28 review #2: a column lacking TTYPE reads back as "col1". The update-mode column-set guard
    # must use that same synthetic name, so (a) a clean read+close does NOT falsely raise, and (b) an
    # in-place edit persists (matched by the synthetic name), not corrupts or crashes.
    p = tmp_fits("unnamed.fits")
    col = zf.Column("", "1J", array=np.array([1, 2, 3], dtype="i4"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).writeto(p, overwrite=True)
    with zf.open(p) as chk:
        assert chk[1].data.dtype.names == ("col1",)  # unnamed -> synthetic name

    with zf.open(p, mode="update") as h:  # clean no-op close must not raise
        _ = h[1].data
    with zf.open(p) as chk:
        np.testing.assert_array_equal(chk[1].data["col1"], [1, 2, 3])

    with zf.open(p, mode="update") as h:  # in-place edit persists by synthetic name
        h[1].data["col1"][:] = [10, 20, 30]
    with zf.open(p) as chk:
        np.testing.assert_array_equal(chk[1].data["col1"], [10, 20, 30])


def test_writeto_unnamed_column_reconstruction_roundtrips(tmp_fits):
    # PR #28 review #2 (emit mirror): reconstructing writeto must key file columns by the same
    # synthetic name so an unnamed column reuses its file format rather than collapsing under "".
    # The VLA column is the genuine guard: pre-fix it collapses to the "" key, has no counterpart to
    # reuse, and the synthesis path raises (object dtype has no TFORM) -- so writeto crashes.
    src, out = tmp_fits("usrc.fits"), tmp_fits("uout.fits")
    vla = np.empty(3, dtype=object)
    vla[0] = np.array([1, 2, 3], dtype="i4"); vla[1] = np.array([4], dtype="i4"); vla[2] = np.array([], dtype="i4")
    cols = [zf.Column("", "1J", array=np.array([10, 20, 30], dtype="i4")),
            zf.Column("", "1PJ", array=vla)]
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols)]).writeto(src, overwrite=True)
    h = zf.open(src)
    h[1].data = h[1].data.copy()  # force reconstruction through _emit_columns
    h.writeto(out, overwrite=True)
    h.close()
    with zf.open(out) as chk:
        assert chk[1].header["TFORM1"].strip() == "1J"
        assert chk[1].header["TFORM2"].strip() == "1PJ"  # VLA descriptor reused, not synthesized
        np.testing.assert_array_equal(chk[1].data["col1"], [10, 20, 30])
        got = chk[1].data["col2"]
        assert np.array_equal(got[0], [1, 2, 3]) and np.array_equal(got[1], [4]) and got[2].size == 0


def test_writeto_added_vla_column_fails_loud(tmp_fits):
    # PR #28 review minor: a brand-new object/VLA field (no file counterpart) can't synthesize a
    # TFORM, so writeto raises a clear error rather than emitting a broken column.
    src, out = tmp_fits("vsrc.fits"), tmp_fits("vout.fits")
    col = zf.Column("A", "1J", array=np.array([1, 2, 3], dtype="i4"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col])]).writeto(src, overwrite=True)
    h = zf.open(src)
    grown = np.empty(3, dtype=[("A", "i4"), ("V", object)])
    grown["A"] = h[1].data["A"]
    grown["V"] = [np.array([1]), np.array([2, 3]), np.array([4])]
    h[1].data = grown
    with pytest.raises(ll.FitsError):
        h.writeto(out, overwrite=True)
    h.close()


# ════════════════════════════════════════════════════════════════════════════════════════════
# 2026-07-07: BUGHUNT-2026-07-06 item 4 — flush()/close() must persist structural HDUList
# mutations (insert/delete/reorder), not just pure appends. Shifted attached HDUs travel as
# exact byte copies (zf_copy_hdu) so keywords/VLA heaps/compression bytes survive verbatim.
# ════════════════════════════════════════════════════════════════════════════════════════════
def _file_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def _three_hdu_file(tmp_fits, name="s.fits"):
    p = tmp_fits(name)
    zf.HDUList([
        zf.PrimaryHDU(data=np.arange(4, dtype="i2")),
        zf.ImageHDU(data=np.arange(6, dtype="i2"), name="A"),
        zf.ImageHDU(data=np.arange(8, dtype="i4"), name="B"),
    ]).writeto(p, overwrite=True)
    return p


def test_insert_hdu_persists_on_close(tmp_fits):
    p = _three_hdu_file(tmp_fits)
    with zf.open(p, mode="update") as h:
        h.insert(1, zf.ImageHDU(data=np.arange(3, dtype="f4"), name="NEW"))
    with zf.open(p) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "NEW", "A", "B"]
        np.testing.assert_array_equal(chk[1].data, [0.0, 1.0, 2.0])
        np.testing.assert_array_equal(chk["A"].data, np.arange(6, dtype="i2"))
        np.testing.assert_array_equal(chk["B"].data, np.arange(8, dtype="i4"))


def test_delete_hdu_persists_on_close(tmp_fits):
    p = _three_hdu_file(tmp_fits)
    with zf.open(p, mode="update") as h:
        del h[1]
    with zf.open(p) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "B"]
        np.testing.assert_array_equal(chk["B"].data, np.arange(8, dtype="i4"))


def test_delete_last_hdu_truncates_only(tmp_fits):
    # Pure truncation: zero copies, one delete — the untouched head of the file stays byte-identical.
    p = _three_hdu_file(tmp_fits)
    before = _file_bytes(p)
    with zf.open(p, mode="update") as h:
        del h[-1]
    after = _file_bytes(p)
    assert len(after) < len(before) and after == before[: len(after)]
    with zf.open(p) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "A"]


def test_reorder_extensions_persists(tmp_fits):
    p = _three_hdu_file(tmp_fits)
    with zf.open(p, mode="update") as h:
        h[1], h[2] = h[2], h[1]
    with zf.open(p) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "B", "A"]
        np.testing.assert_array_equal(chk[1].data, np.arange(8, dtype="i4"))
        np.testing.assert_array_equal(chk[2].data, np.arange(6, dtype="i2"))


def test_shifted_table_keeps_keywords_scaling_and_vla(tmp_fits):
    # A shifted-but-unedited table must travel as an exact byte copy: its user keywords, TSCAL
    # scaling, and VLA heap all survive. (The reconstruct path would drop the keywords and raise
    # on the scaled column — this test proves the copy route is taken.)
    p = tmp_fits("tk.fits")
    cols = [
        zf.Column("A", "1J", array=np.array([1, 2, 3], dtype="i4")),
        zf.Column("V", "1PJ", array=np.array([np.array([1], dtype="i4"),
                                              np.array([2, 3], dtype="i4"),
                                              np.array([], dtype="i4")], dtype=object)),
    ]
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols, name="T")]).writeto(p, overwrite=True)
    with zf.open(p, mode="update") as h:
        h[1].header["OBSNOTE"] = "keepme"
        h[1].header["TSCAL1"] = 2.0  # makes the column unreconstructable via _write_to
    with zf.open(p, mode="update") as h:
        h.insert(1, zf.ImageHDU(data=np.zeros(2, dtype="i2"), name="NEW"))
    with zf.open(p) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "NEW", "T"]
        assert chk[2].header["OBSNOTE"] == "keepme"
        assert float(chk[2].header["TSCAL1"]) == 2.0
        got = chk[2].data["V"]
        assert np.array_equal(got[0], [1]) and np.array_equal(got[1], [2, 3]) and got[2].size == 0


def test_shifted_compressed_image_bytes_survive_exactly(tmp_fits):
    # A quantized float CompImageHDU shifted by an insert must be byte-copied, NOT recompressed
    # (recompression would re-quantize/re-dither to different bytes).
    p = tmp_fits("ck.fits")
    rng_data = (np.arange(64, dtype="f4").reshape(8, 8) * 1.37 + 0.1)
    zf.HDUList([
        zf.PrimaryHDU(),
        zf.CompImageHDU(data=rng_data, compression="RICE_1", quantize="SUBTRACTIVE_DITHER_1"),
    ]).writeto(p, overwrite=True)
    orig = _file_bytes(p)
    comp_block = orig[2880:]  # empty primary is exactly one block; the rest is the compressed HDU
    with zf.open(p, mode="update") as h:
        h.insert(1, zf.ImageHDU(data=np.zeros(2, dtype="i2"), name="NEW"))
    after = _file_bytes(p)
    assert after[-len(comp_block):] == comp_block  # exact bytes, no requantization
    with zf.open(p) as chk:
        assert len(chk) == 3 and chk[1].name == "NEW"  # ...and the insert really landed


def test_edits_on_shifted_hdu_persist(tmp_fits):
    # Header edits persist live at the old slot (carried by the byte copy); a pending in-place
    # data edit must be written back at the NEW index by the flush write-back pass.
    p = _three_hdu_file(tmp_fits)
    with zf.open(p, mode="update") as h:
        h["A"].header["NEWKEY"] = 5
        h["A"].data[0] = 42
        h.insert(1, zf.ImageHDU(data=np.zeros(2, dtype="i2"), name="NEW"))
    with zf.open(p) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "NEW", "A", "B"]
        assert chk["A"].header["NEWKEY"] == 5
        assert int(chk["A"].data[0]) == 42


def test_checksummed_hdu_survives_shift(tmp_fits):
    # CHECKSUM/DATASUM are position-independent; an exact byte copy keeps them valid.
    p = tmp_fits("sum.fits")
    zf.HDUList([
        zf.PrimaryHDU(data=np.arange(4, dtype="i2")),
        zf.ImageHDU(data=np.arange(6, dtype="i2"), name="A"),
    ]).writeto(p, overwrite=True, checksum=True)
    with zf.open(p, mode="update") as h:
        h.insert(1, zf.ImageHDU(data=np.zeros(2, dtype="i2"), name="NEW"))
    with zf.open(p) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "NEW", "A"]
        assert chk["A"].header.get("CHECKSUM") is not None
    assert not [f for f in zf.verify(p) if "sum" in str(f).lower()]  # DATASUM/CHECKSUM still valid


def test_foreign_hdu_append_persists(tmp_fits):
    # An HDU attached to ANOTHER open file must be serialized on flush (today: silently skipped).
    p1, p2 = _three_hdu_file(tmp_fits, "f1.fits"), tmp_fits("f2.fits")
    zf.HDUList([zf.PrimaryHDU(), zf.ImageHDU(data=np.arange(5, dtype="i4"), name="DONOR")]).writeto(p2, overwrite=True)
    with zf.open(p2) as other:
        with zf.open(p1, mode="update") as h:
            h.append(other[1])
    with zf.open(p1) as chk:
        assert chk[3].name == "DONOR"
        np.testing.assert_array_equal(chk[3].data, np.arange(5, dtype="i4"))


def test_foreign_table_with_edit_flushes_current_data(tmp_fits):
    # A foreign table's CURRENT data is serialized; its fingerprints are rebaselined so the
    # write-back pass neither re-writes nor spuriously raises.
    p1, p2 = _three_hdu_file(tmp_fits, "g1.fits"), tmp_fits("g2.fits")
    col = zf.Column("X", "1J", array=np.array([1, 2, 3], dtype="i4"))
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns([col], name="T")]).writeto(p2, overwrite=True)
    with zf.open(p2) as other:
        other[1].data["X"][:] = [7, 8, 9]  # in-place edit while attached to the read-only donor
        with zf.open(p1, mode="update") as h:
            h.append(other[1])
    with zf.open(p1) as chk:
        np.testing.assert_array_equal(chk[3].data["X"], [7, 8, 9])


def test_foreign_hdu_from_closed_list_fails_and_restores(tmp_fits):
    p1, p2 = _three_hdu_file(tmp_fits, "h1.fits"), tmp_fits("h2.fits")
    zf.HDUList([zf.PrimaryHDU(), zf.ImageHDU(data=np.arange(5, dtype="i4"), name="D")]).writeto(p2, overwrite=True)
    other = zf.open(p2)
    donor = other[1]
    other.close()
    before = _file_bytes(p1)
    h = zf.open(p1, mode="update")
    h.append(donor)
    with pytest.raises(zf.FitsError):
        h.flush()
    del h[-1]  # restore the layout so close() flushes cleanly
    h.close()
    assert _file_bytes(p1) == before


def test_mid_append_failure_restores_file(tmp_fits):
    # A failure AFTER the destination HDU was created (complex VLA columns are unwritable) must
    # roll the partial tail back; a corrected list must then flush cleanly on the same handle.
    p = _three_hdu_file(tmp_fits, "mid.fits")
    before = _file_bytes(p)
    bad = zf.BinTableHDU.from_columns(
        [zf.Column("C", "1PC", array=np.array([np.array([1 + 2j])], dtype=object))], name="BAD")
    h = zf.open(p, mode="update")
    h.insert(1, bad)
    with pytest.raises(NotImplementedError):
        h.flush()
    assert _file_bytes(p) == before  # partial tail rolled back
    h[1] = zf.ImageHDU(data=np.arange(3, dtype="i2"), name="GOOD")  # corrected retry
    h.close()
    with zf.open(p) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "GOOD", "A", "B"]


@pytest.mark.parametrize("mutate", [
    lambda h: h.insert(0, zf.PrimaryHDU(data=np.zeros(2, dtype="i2"))),
    lambda h: h.__delitem__(0),
    lambda h: h.reverse(),
])
def test_primary_slot_change_fails_loud(tmp_fits, mutate):
    p = _three_hdu_file(tmp_fits, "prim.fits")
    before = _file_bytes(p)
    h = zf.open(p, mode="update")
    mutate(h)
    with pytest.raises(NotImplementedError):
        h.close()
    assert _file_bytes(p) == before  # nothing was mutated


def test_aliased_hdu_object_fails_loud(tmp_fits):
    # One object cannot be bound to two file slots; fail loud instead of silently dropping one.
    p = _three_hdu_file(tmp_fits, "alias.fits")
    before = _file_bytes(p)
    h = zf.open(p, mode="update")
    h.append(h[1])
    with pytest.raises(ValueError):
        h.close()
    assert _file_bytes(p) == before


def test_compressed_replaced_data_raises_before_restructure(tmp_fits):
    # A CompImageHDU with replaced data + a structural change: the pre-flight guard must fire
    # BEFORE the file is restructured, leaving it byte-identical.
    p = tmp_fits("cpre.fits")
    img = np.arange(16, dtype="i2").reshape(4, 4)
    zf.HDUList([zf.PrimaryHDU(), zf.CompImageHDU(data=img, compression="RICE_1"),
                zf.ImageHDU(data=np.zeros(2, dtype="i2"), name="A")]).writeto(p, overwrite=True)
    before = _file_bytes(p)
    h = zf.open(p, mode="update")
    h[1].data = img * 2
    del h[2]
    with pytest.raises(NotImplementedError):
        h.close()
    assert _file_bytes(p) == before


def test_double_flush_is_idempotent(tmp_fits):
    p = _three_hdu_file(tmp_fits, "dbl.fits")
    with zf.open(p, mode="update") as h:
        h.insert(1, zf.ImageHDU(data=np.arange(3, dtype="f4"), name="NEW"))
        h.flush()
        first = _file_bytes(p)
        assert [hdu.name for hdu in zf.from_bytes(first)] == ["PRIMARY", "NEW", "A", "B"]
        h.flush()  # second flush must take the no-op fast path
        assert _file_bytes(p) == first
    assert _file_bytes(p) == first  # close() flush is a no-op too


def test_from_bytes_update_mode_reconciles(tmp_fits):
    p = _three_hdu_file(tmp_fits, "mem.fits")
    h = zf.from_bytes(_file_bytes(p), mode="update")
    h.insert(1, zf.ImageHDU(data=np.arange(3, dtype="i2"), name="NEW"))
    h.flush()
    assert h._is_pristine_attached()  # the handle's own bytes now match the list
    out = h.to_bytes()  # ...so this is the verbatim byte-copy path
    h.close()
    with zf.from_bytes(out) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "NEW", "A", "B"]


def test_writeto_of_unflushed_structural_list_leaves_source_intact(tmp_fits):
    # writeto() reconstructs from the in-memory list without flushing; the source file must not
    # be restructured until flush/close.
    p, out = _three_hdu_file(tmp_fits, "wsrc.fits"), tmp_fits("wout.fits")
    before = _file_bytes(p)
    h = zf.open(p, mode="update")
    h.insert(1, zf.ImageHDU(data=np.arange(3, dtype="i2"), name="NEW"))
    h.writeto(out, overwrite=True)
    assert _file_bytes(p) == before  # source untouched so far
    h.close()  # now the structural change lands
    with zf.open(out) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "NEW", "A", "B"]
    with zf.open(p) as chk:
        assert [hdu.name for hdu in chk] == ["PRIMARY", "NEW", "A", "B"]


def test_foreign_checksummed_hdu_drops_stale_checksum_on_flush(tmp_fits):
    # Review follow-up (PR #29): a foreign HDU serialized through the reconstruct path must not
    # carry its source file's CHECKSUM/DATASUM — those describe the ORIGINAL bytes and would no
    # longer verify. (Byte-copied shifted HDUs keep theirs, which stay valid.)
    p1, p2 = _three_hdu_file(tmp_fits, "ck1.fits"), tmp_fits("ck2.fits")
    zf.HDUList([zf.PrimaryHDU(), zf.ImageHDU(data=np.arange(5, dtype="i4"), name="D")]).writeto(
        p2, overwrite=True, checksum=True)
    with zf.open(p2) as other:
        assert other[1].header.get("CHECKSUM") is not None  # donor really is checksummed
        with zf.open(p1, mode="update") as h:
            h.append(other[1])
    with zf.open(p1) as chk:
        assert chk[3].header.get("CHECKSUM") is None  # stale card dropped, not copied
        assert chk[3].header.get("DATASUM") is None
    assert not [f for f in zf.verify(p1) if "sum" in str(f).lower()]


def test_reconstruction_drops_stale_checksum_cards(tmp_fits):
    # Same rule on the writeto reconstruct path: stale CHECKSUM/DATASUM are stripped (astropy
    # semantics); writeto(checksum=True) regenerates fresh valid ones instead.
    src, out, out2 = tmp_fits("cs.fits"), tmp_fits("cs_out.fits"), tmp_fits("cs_out2.fits")
    zf.HDUList([zf.PrimaryHDU(data=np.arange(4, dtype="i2"))]).writeto(src, overwrite=True, checksum=True)
    hdul = zf.open(src)
    hdul[0].data = hdul[0].data * 3  # dirty -> writeto reconstructs
    hdul.writeto(out, overwrite=True)
    hdul.writeto(out2, overwrite=True, checksum=True)
    hdul.close()
    with zf.open(out) as chk:
        assert chk[0].header.get("CHECKSUM") is None  # stripped, not stale
    with zf.open(out2) as chk:
        assert chk[0].header.get("CHECKSUM") is not None  # regenerated on request
    assert not [f for f in zf.verify(out2) if "sum" in str(f).lower()]


def test_non_hdu_at_primary_slot_raises_typeerror(tmp_fits):
    # Review follow-up (PR #29): garbage at position 0 must report what it is (TypeError), not
    # the misleading "primary must remain first" NotImplementedError.
    p = _three_hdu_file(tmp_fits, "junk.fits")
    before = _file_bytes(p)
    h = zf.open(p, mode="update")
    h[0] = "not an hdu"
    with pytest.raises(TypeError):
        h.close()
    assert _file_bytes(p) == before


# ── BUGHUNT-2026-07-06 #47: hostile Z* geometry must raise, never abort the process ──────────
def _zimage_bytes(**zkeys):
    """A binary table posing as a tile-compressed image (ZIMAGE=T) with the given Z* integers."""
    def build(handle):
        ll.check(ll.lib.zf_create_img(handle, 8, 0, None))
        ttype = (c.c_char_p * 1)(b"COMPRESSED_DATA")
        tform = (c.c_char_p * 1)(b"1J")
        ll.check(ll.lib.zf_create_tbl(handle, ll.BINARY_TBL, 1, 1, ttype, tform, None, None))
        kw = b"ZIMAGE"
        ll.check(ll.lib.zf_write_key_log(handle, kw, len(kw), 1, None, 0))
        for name, val in zkeys.items():
            kw = name.encode()
            ll.check(ll.lib.zf_write_key_lng(handle, kw, len(kw), val, None, 0))
    return _bytes_from(build)


def test_hostile_zbitpix_raises_instead_of_aborting():
    # #47: ZBITPIX outside i32 hit an unchecked @intCast in zf_img_param — a panic (abort) in
    # safety-checked builds, silent truncation in ReleaseFast wheels. Must raise instead.
    hl = zf.from_bytes(_zimage_bytes(ZBITPIX=1 << 40))
    hdu = hl[1]
    assert isinstance(hdu, zf.CompImageHDU)
    with pytest.raises(zf.FitsError):
        _ = hdu.shape


def test_illegal_zbitpix_raises():
    # #47 follow-up: an in-range but illegal BITPIX code must also error, not be reported as-is.
    hl = zf.from_bytes(_zimage_bytes(ZBITPIX=7))
    with pytest.raises(zf.FitsError):
        _ = hl[1].shape


def test_negative_znaxisn_raises():
    # #47 follow-up: a negative ZNAXISn errors on every platform (mirrors the decompression
    # path's BadTiling) instead of flowing into the geometry out-params.
    hl = zf.from_bytes(_zimage_bytes(ZBITPIX=16, ZNAXIS=1, ZNAXIS1=-5))
    with pytest.raises(ll.FitsCompressError):
        _ = hl[1].shape


def test_out_of_range_znaxis_raises():
    # #47 review round: ZNAXIS present but out of range used to be treated like missing — a
    # silent zero-axis report (shape None) for a file the decompression path rejects outright.
    hl = zf.from_bytes(_zimage_bytes(ZBITPIX=16, ZNAXIS=5000))
    with pytest.raises(ll.FitsCompressError):
        _ = hl[1].shape


# ── 2026-07 findings 13-15: None header values, data=None clears, table data validation ──────
def test_none_header_value_round_trips_as_undefined_card(tmp_fits):
    # Finding 13: header['KEY'] = None must write a FITS *undefined* card (blank value field),
    # not the literal string 'None' — and reconstruction (writeto/to_bytes) must preserve it
    # instead of silently dropping the card.
    hdu = zf.PrimaryHDU()
    hdu.header["UNDEF"] = (None, "no value")
    blob = zf.HDUList([hdu]).to_bytes()
    assert b"'None'" not in blob
    hh = zf.from_bytes(blob)[0].header
    assert hh["UNDEF"] is None
    assert hh.comment_of("UNDEF") == "no value"

    # Attached update-mode set goes through the C ABI write path.
    p = tmp_fits("undef.fits")
    zf.writeto(p, np.zeros((2, 2), dtype="i4"), overwrite=True)
    with zf.open(p, mode="update") as hl:
        hl[0].header["UNDEF2"] = (None, "cleared")
    assert b"'None'" not in _file_bytes(p)
    with zf.open(p) as hl:
        assert hl[0].header["UNDEF2"] is None
        assert hl[0].header.comment_of("UNDEF2") == "cleared"

    # Reconstruction: a read-only header edit forces writeto to rebuild every card via
    # _apply_user_keys, which used to skip value-None cards entirely.
    out = tmp_fits("undef_recon.fits")
    with zf.open(p) as hl:
        hl[0].header["OTHER"] = 1
        hl.writeto(out, overwrite=True)
    with zf.open(out) as hl:
        assert hl[0].header["UNDEF2"] is None
        assert hl[0].header.comment_of("UNDEF2") == "cleared"

    # Overwriting a CONTINUE'd long-string key with None drops the whole run (Header.update
    # removes the orphaned CONTINUE cards), not just the base card.
    with zf.open(p, mode="update") as hl:
        hl[0].header["LNG"] = "x" * 100
    assert b"CONTINUE" in _file_bytes(p)
    with zf.open(p, mode="update") as hl:
        hl[0].header["LNG"] = None
    assert b"CONTINUE" not in _file_bytes(p)
    with zf.open(p) as hl:
        assert hl[0].header["LNG"] is None


def test_data_none_clears_attached_image_hdu(tmp_fits):
    # Finding 14: hdu.data = None on an attached HDU must stick — writeto/to_bytes emit an
    # empty (NAXIS=0) HDU like astropy — instead of being silently resurrected by the lazy
    # getter; in update mode the clear fails loud instead of silently no-oping.
    p = tmp_fits("full.fits")
    zf.writeto(p, np.arange(6, dtype="i4").reshape(2, 3), overwrite=True)

    out = tmp_fits("cleared.fits")
    with zf.open(p) as hl:
        hl[0].data = None
        assert hl[0].data is None  # the assignment sticks; no lazy re-read
        hl.writeto(out, overwrite=True)
    with zf.open(out) as hl:
        assert hl[0].data is None
        assert hl[0].header["NAXIS"] == 0

    with zf.open(p) as hl:
        hl[0].data = None
        blob = hl.to_bytes()
    assert zf.from_bytes(blob)[0].data is None

    # Update mode: clearing is a geometry change — fail loud, leaving the file intact.
    # Saving the clear to a NEW file works, but the clear stays pending on the OPEN
    # handle, so close() still refuses (its message says how to unblock: restore).
    before = _file_bytes(p)
    h = zf.open(p, mode="update")
    orig = h[0].data.copy()
    h[0].data = None
    out2 = tmp_fits("cleared_via_update.fits")
    h.writeto(out2, overwrite=True)
    assert zf.getheader(out2)["NAXIS"] == 0
    with pytest.raises(NotImplementedError, match="restore"):
        h.close()
    h[0].data = orig  # restoring the data unblocks close()
    h.close()
    assert _file_bytes(p) == before

    # Regression guards: reading an ALREADY-empty HDU's data (None), or clearing it, is not
    # an update-mode error — there is nothing on disk to clear.
    pe = tmp_fits("empty.fits")
    zf.HDUList([zf.PrimaryHDU()]).writeto(pe, overwrite=True)
    with zf.open(pe, mode="update") as hl:
        assert hl[0].data is None
    with zf.open(pe, mode="update") as hl:
        hl[0].data = None


def test_data_none_clears_attached_table_hdu(tmp_fits):
    # Finding 14 (table twin): data = None on an attached table empties it on writeto and
    # fails loud in update mode.
    p = tmp_fits("tbl.fits")
    cols = [zf.Column("X", "J", np.arange(4, dtype="i4"))]
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols, name="T")]).writeto(p, overwrite=True)

    out = tmp_fits("tbl_cleared.fits")
    with zf.open(p) as hl:
        hl[1].data = None
        assert hl[1].data is None
        hl.writeto(out, overwrite=True)
    with zf.open(out) as hl:
        assert hl[1].header["TFIELDS"] == 0
        assert hl[1].header["NAXIS2"] == 0

    before = _file_bytes(p)
    h = zf.open(p, mode="update")
    h[1].data = None
    with pytest.raises(NotImplementedError):
        h.close()
    assert _file_bytes(p) == before


def test_table_data_rejects_non_structured_arrays(tmp_fits):
    # Finding 15: a non-structured array assigned to table data must raise TypeError instead
    # of silently serializing an EMPTY table (TFIELDS=0 — total silent data loss).
    with pytest.raises(TypeError):
        zf.BinTableHDU(data=np.arange(5))
    hdu = zf.BinTableHDU()
    with pytest.raises(TypeError):
        hdu.data = np.arange(5)
    p = tmp_fits("t.fits")
    cols = [zf.Column("X", "J", np.arange(4, dtype="i4"))]
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols)]).writeto(p, overwrite=True)
    with zf.open(p) as hl:
        with pytest.raises(TypeError):
            hl[1].data = np.arange(5)


def test_detached_bintable_data_writes_rows():
    # Finding 15 (adjacent silent loss): BinTableHDU(data=rec) — and a detached .data
    # assignment — previously emitted an EMPTY table via the _columns early-return; the rows
    # must serialize, with every TFORM synthesized from the structured dtype.
    rec = np.zeros(3, dtype=[("A", "i4"), ("B", "f8"), ("S", "S4"), ("V", "f4", (3,)), ("U", "u2")])
    rec["A"] = [1, 2, 3]
    rec["B"] = [0.5, 1.5, 2.5]
    rec["S"] = [b"ab", b"cd", b"ef"]
    rec["V"] = np.arange(9, dtype="f4").reshape(3, 3)
    rec["U"] = [0, 32768, 65535]
    blob = zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU(data=rec, name="D")]).to_bytes()
    hl = zf.from_bytes(blob)
    got = hl[1].data
    assert list(got["A"]) == [1, 2, 3]
    np.testing.assert_allclose(got["B"], [0.5, 1.5, 2.5])
    assert list(got["S"]) == [b"ab", b"cd", b"ef"]
    np.testing.assert_array_equal(got["V"], rec["V"])
    assert list(got["U"]) == [0, 32768, 65535]  # unsigned via the TZERO convention
    assert str(hl[1].header["TFORM4"]).strip() == "3E"  # subarray field -> vector column

    # The .data-setter path on a detached HDU serializes the same way.
    hdu2 = zf.BinTableHDU(name="D2")
    hdu2.data = rec
    hl2 = zf.from_bytes(zf.HDUList([zf.PrimaryHDU(), hdu2]).to_bytes())
    assert list(hl2[1].data["A"]) == [1, 2, 3]

    # Detached ASCII tables cannot synthesize formats; fail loud toward from_columns.
    arec = np.zeros(2, dtype=[("A", "i4")])
    with pytest.raises(NotImplementedError):
        zf.HDUList([zf.PrimaryHDU(), zf.AsciiTableHDU(data=arec)]).to_bytes()


# ── #25/#27 non-finite float header values must be rejected on write ──────────────────────────
def test_nonfinite_float_keyword_raises_create_mode():
    # NaN/Inf would format as bare 'nan'/'inf' tokens — cards no reader (including this
    # library's own parser) accepts. The write must fail fast instead.
    for bad in (float("nan"), float("inf"), float("-inf")):
        h = zf.Header()
        h["KNAN"] = bad
        with pytest.raises(zf.FitsError):
            zf.HDUList([zf.PrimaryHDU(data=np.arange(4, dtype="f4"), header=h)]).to_bytes()


def test_nonfinite_float_keyword_raises_update_mode(tmp_fits):
    p = tmp_fits("nf.fits")
    zf.writeto(p, np.arange(4, dtype="f4"), overwrite=True)
    with zf.open(p, mode="update") as hdul:
        with pytest.raises(zf.FitsError):
            hdul[0].header["KINF"] = float("inf")
    with zf.open(p) as hdul:  # the failed write left the file readable and unchanged
        assert "KINF" not in hdul[0].header


def test_nonfinite_numpy_float_keyword_raises():
    h = zf.Header()
    h["KNAN32"] = np.float32("nan")
    with pytest.raises(zf.FitsError):
        zf.HDUList([zf.PrimaryHDU(data=np.arange(4, dtype="f4"), header=h)]).to_bytes()


def test_nonfinite_hierarch_float_raises():
    # The HIERARCH path builds raw 80-byte cards client-side (zf_write_record), bypassing the
    # Zig-core builder — the Python-level guard must cover it too.
    h = zf.Header()
    h["ESO DET BAD GAIN"] = float("-inf")
    with pytest.raises(zf.FitsError):
        zf.HDUList([zf.PrimaryHDU(data=np.arange(4, dtype="f4"), header=h)]).to_bytes()


def test_bare_nan_token_reads_as_string_not_float():
    # A hostile file carrying an invalid bare 'nan'/'inf' value token: bare float() used to turn
    # it into float('nan'). It must fall through as a string (matching the TypeScript parser),
    # while the typed C-ABI read keeps rejecting it with status 207.
    cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "BADF    =                  nan / not a FITS real",
        "BADI    =                  inf",
        "GOODF   =                 1.5E2",
        "END",
    ]
    raw = "".join(s.ljust(80) for s in cards).ljust(2880).encode("ascii")
    with zf.from_bytes(raw) as hdul:
        hh = hdul[0].header
        assert hh["BADF"] == "nan" and isinstance(hh["BADF"], str)
        assert hh["BADI"] == "inf" and isinstance(hh["BADI"], str)
        assert hh["GOODF"] == pytest.approx(150.0)  # legit reals still parse
        out = c.c_double()
        kb = b"BADF"
        assert ll.lib.zf_read_key_dbl(hdul[0]._select(), kb, len(kb), c.byref(out)) == 207
