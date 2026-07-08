"""Cross-check that zigfitsio and astropy agree (both directions)."""

import numpy as np
import pytest

import zigfitsio as zf

afits = pytest.importorskip("astropy.io.fits")


def test_astropy_reads_zigfitsio_image(tmp_fits):
    data = np.arange(24, dtype="f4").reshape(4, 6) * 0.5
    p = tmp_fits()
    zf.writeto(p, data, overwrite=True)
    np.testing.assert_array_equal(afits.getdata(p), data)


def test_zigfitsio_reads_astropy_image(tmp_fits):
    data = np.random.default_rng(0).integers(0, 1000, size=(5, 7)).astype("i2")
    p = tmp_fits()
    hdu = afits.PrimaryHDU(data)
    hdu.header["OBJECT"] = ("M31", "target")
    hdu.writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        np.testing.assert_array_equal(hdul[0].data, data)
        assert hdul[0].header["OBJECT"] == "M31"
        assert hdul[0].header.comment_of("OBJECT") == "target"


def test_astropy_reads_zigfitsio_table(tmp_fits):
    cols = [
        zf.Column("INDEX", "J", np.array([10, 20, 30], dtype="i4")),
        zf.Column("FLUX", "E", np.array([1.5, 2.5, 3.5], dtype="f4")),
        zf.Column("NAME", "8A", np.array(["alpha", "beta", "gamma"])),
    ]
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols)]).writeto(p, overwrite=True)
    t = afits.open(p)
    try:
        assert list(t[1].data["INDEX"]) == [10, 20, 30]
        np.testing.assert_allclose(t[1].data["FLUX"], [1.5, 2.5, 3.5])
        assert [s.strip() for s in t[1].data["NAME"]] == ["alpha", "beta", "gamma"]
    finally:
        t.close()


def test_zigfitsio_reads_astropy_table(tmp_fits):
    c1 = afits.Column(name="ID", format="K", array=np.array([1, 2, 3], dtype="i8"))
    c2 = afits.Column(name="VAL", format="D", array=np.array([0.1, 0.2, 0.3]))
    p = tmp_fits()
    afits.BinTableHDU.from_columns([c1, c2]).writeto(p, overwrite=True)
    with zf.open(p) as hdul:
        rec = hdul[1].data
        assert list(rec["ID"]) == [1, 2, 3]
        np.testing.assert_allclose(rec["VAL"], [0.1, 0.2, 0.3])


def test_astropy_decodes_zigfitsio_rice(tmp_fits):
    ramp = np.arange(256, dtype="i4").reshape(16, 16)
    p = tmp_fits()
    zf.HDUList([zf.PrimaryHDU(), zf.CompImageHDU(ramp, compression="RICE_1")]).writeto(p, overwrite=True)
    t = afits.open(p)
    try:
        np.testing.assert_array_equal(t[1].data, ramp)
    finally:
        t.close()


@pytest.mark.parametrize(
    "value",
    [
        ("abc'def&" * 12) + "END",   # quotes and ampersands straddling CONTINUE boundaries
        "A" * 200,                    # spans several CONTINUE cards
        ("it's a path/to/x&" * 6) + "end",
        "no-continuation short'value",
    ],
)
def test_zigfitsio_reads_astropy_long_string(tmp_fits, value):
    hdr = afits.Header()
    hdr["LSTR"] = (value, "provenance")
    p = tmp_fits()
    afits.PrimaryHDU(header=hdr).writeto(p, overwrite=True)
    assert afits.getheader(p)["LSTR"] == value  # astropy reads its own file
    with zf.open(p) as hdul:
        assert hdul[0].header["LSTR"] == value   # so must zigfitsio
        assert hdul[0].header.comment_of("LSTR") == "provenance"


@pytest.mark.parametrize(
    "value",
    [
        ("the quick brown fox " * 10).strip(),  # plain multi-card
        ("abc'def&" * 12) + "END",              # quotes and ampersands straddling boundaries
    ],
)
def test_astropy_reads_zigfitsio_hierarch_long_string(tmp_fits, value):
    """astropy must read our HIERARCH+CONTINUE output exactly (value, comment, verify clean)."""
    p = tmp_fits()
    hdu = zf.PrimaryHDU()
    hdu.header["ESO LONG STR"] = (value, "provenance")
    zf.HDUList([hdu]).writeto(p, overwrite=True)
    hdr = afits.getheader(p)
    assert hdr["ESO LONG STR"] == value
    assert hdr.comments["ESO LONG STR"] == "provenance"
    with afits.open(p) as h:
        h.verify("exception")


def test_zigfitsio_reads_astropy_hierarch_long_string(tmp_fits):
    """We must read astropy's HIERARCH+CONTINUE output (incl. its split '' escape pairs)."""
    value = ("it's a 'long' tale & so on " * 8).strip()
    hdr = afits.Header()
    hdr["HIERARCH ESO LONG STR"] = (value, "provenance")
    p = tmp_fits()
    try:
        afits.PrimaryHDU(header=hdr).writeto(p, overwrite=True)
    except ValueError:
        # astropy <7.1 cannot *write* HIERARCH values via the CONTINUE long-string
        # convention (it raises "keyword ... with its value is too long"). Without
        # such a file there is nothing to cross-check, so skip. Reading HIERARCH+
        # CONTINUE (this test's actual subject) is supported by those versions.
        pytest.skip("astropy <7.1 cannot write HIERARCH long strings via CONTINUE")
    assert afits.getheader(p)["ESO LONG STR"] == value  # astropy reads its own file
    with zf.open(p) as hdul:
        assert hdul[0].header["ESO LONG STR"] == value
        assert hdul[0].header.comment_of("ESO LONG STR") == "provenance"


def test_astropy_reads_accumulated_commentary(tmp_fits):
    """astropy must read back every accumulated COMMENT/HISTORY card, wrapping long text (BUGHUNT #6)."""
    # A space-free token: FITS commentary right-strips trailing spaces per card (standard, done by
    # astropy and our reader alike), so a boundary space would not survive — use unbroken text.
    long_note = "abcdefghij0123456789" * 6  # 120 chars → two ≤72-char cards
    p = tmp_fits()
    hdu = zf.PrimaryHDU(data=np.ones((3, 3), dtype="i2"))
    hdu.header["COMMENT"] = "note one"
    hdu.header["COMMENT"] = "note two"
    hdu.header.add_history("did a thing")
    hdu.header.add_history("did another thing")
    hdu.header["COMMENT"] = long_note  # spans multiple 72-char cards
    zf.HDUList([hdu]).writeto(p, overwrite=True)
    hdr = afits.getheader(p)
    assert list(hdr["COMMENT"])[:2] == ["note one", "note two"]
    assert list(hdr["HISTORY"]) == ["did a thing", "did another thing"]
    # The long comment is split into ≤72-char cards; astropy joins them back to the original.
    assert "".join(list(hdr["COMMENT"])[2:]) == long_note
    with afits.open(p) as h:
        h.verify("exception")


def test_wcs_matches_astropy(tmp_fits):
    WCS = pytest.importorskip("astropy.wcs").WCS
    data = np.zeros((64, 64), dtype="f4")
    hdr = afits.Header()
    for k, v in [
        ("CTYPE1", "RA---TAN"), ("CTYPE2", "DEC--TAN"),
        ("CRPIX1", 32.0), ("CRPIX2", 32.0),
        ("CRVAL1", 150.0), ("CRVAL2", 2.0),
        ("CDELT1", -0.001), ("CDELT2", 0.001),
    ]:
        hdr[k] = v
    p = tmp_fits()
    afits.PrimaryHDU(data, header=hdr).writeto(p, overwrite=True)
    w = WCS(afits.getheader(p))
    ap = w.all_pix2world([[39.0, 29.0]], 0)[0]  # 0-based
    with zf.open(p) as hdul:
        lon, lat = hdul[0].pix2world(40.0, 30.0)  # 1-based
    np.testing.assert_allclose([lon, lat], ap, atol=1e-6)
