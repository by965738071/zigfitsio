"""High-level, NumPy-first FITS API modeled on ``astropy.io.fits``.

Provides :func:`open` returning an :class:`HDUList`, the HDU classes (:class:`PrimaryHDU`,
:class:`ImageHDU`, :class:`BinTableHDU`, :class:`AsciiTableHDU`, :class:`CompImageHDU`), a
:class:`Column` builder, and the ``getdata``/``getheader``/``writeto``/``verify`` conveniences.
Data is exchanged as native-endian NumPy arrays; image arrays use C-order with reversed axes
(shape ``(NAXIS2, NAXIS1)``), matching astropy.
"""

from __future__ import annotations

import ctypes as c
import os
from typing import Any, Sequence

import numpy as np

from . import _dtypes as dt
from . import lowlevel as ll
from .header import Header, parse_cards

_VOID = c.c_void_p

# BZERO values that encode the unsigned-integer convention for each signed BITPIX.
_UNSIGNED_BZERO = {16: 32768, 32: 2147483648, 64: 9223372036854775808}
_UNSIGNED_DTYPE = {16: np.dtype("u2"), 32: np.dtype("u4"), 64: np.dtype("u8")}

# Table unsigned-integer convention: (signed on-disk dtype, TZERO) -> unsigned numpy dtype.
_UNSIGNED_TZERO = {
    (np.dtype("i2"), 32768): np.dtype("u2"),
    (np.dtype("i4"), 2147483648): np.dtype("u4"),
    (np.dtype("i8"), 9223372036854775808): np.dtype("u8"),
}

# ZfType element code -> binary-table TFORM letter (for rebuilding a column format on copy).
_ZF_TO_TFORM = {
    ll.ZF_BOOL: "L", ll.ZF_BIT: "X", ll.ZF_UINT8: "B", ll.ZF_INT8: "B",
    ll.ZF_INT16: "I", ll.ZF_INT32: "J", ll.ZF_INT64: "K",
    ll.ZF_UINT16: "I", ll.ZF_UINT32: "J", ll.ZF_UINT64: "K",  # unsigned via signed letter + TZERO
    ll.ZF_FLOAT32: "E", ll.ZF_FLOAT64: "D", ll.ZF_COMPLEX64: "C", ll.ZF_COMPLEX128: "M",
}


def _tform_of(info) -> str:
    """Rebuild a binary-table TFORM string from column metadata (for reconstructing an attached
    table on copy). The unsigned-integer convention is reproducible (the read data is unsigned and
    TZERO is re-added on write); fractional/other scaling is not reproducible value-only."""
    if info.typecode == ll.ZF_STRING:
        return f"{max(int(info.width), 1)}A"
    is_unsigned = info.tscal == 1.0 and int(info.tzero) in (32768, 2147483648, 9223372036854775808)
    if (info.tscal != 1.0 or info.tzero != 0.0) and not is_unsigned:
        raise NotImplementedError(
            "cannot reconstruct a scaled table column into a new table; copy the file through the "
            "raw-passthrough path (writeto without checksum on a freshly opened file)"
        )
    letter = _ZF_TO_TFORM.get(int(info.typecode))
    if letter is None:
        raise NotImplementedError(f"cannot reconstruct TFORM for ZfType {info.typecode}")
    if info.is_vla:
        return f"1P{letter}"
    return f"{int(info.repeat)}{letter}"


def _ascii_tform_of(info) -> str:
    """Rebuild an ASCII-table TFORM (``Iw`` / ``Ew.d`` / ``Aw``) from column metadata. ASCII TFORMs
    carry an explicit width, so a copied ASCII table needs these rather than binary ``1J``-style
    formats (which zf_create_tbl(ASCII_TBL, ...) rejects)."""
    code = int(info.typecode)
    w = max(int(info.width), 1)
    if code == ll.ZF_STRING:
        return f"A{w}"
    if code in (ll.ZF_FLOAT32, ll.ZF_FLOAT64):
        return f"E{w}.{max(w - 7, 1)}"  # leave room for sign, decimal point, and E±dd exponent
    return f"I{w}"  # integer column of any width


def _vla_elem_dtype(fmt: str):
    """(numpy element dtype, is_complex) for a VLA TFORM like '1PJ' / '1QE(max)'."""
    marker = "P" if "P" in fmt else "Q"
    letter = next((ch for ch in fmt.split(marker, 1)[1] if ch.isalpha()), "")
    return dt.bin_elem_dtype(ord(letter)) if letter else (np.dtype("f8"), False)


def _ndarray_fp(arr):
    """Content fingerprint of a numeric ndarray (normalized to C-order bytes so the same logical
    array always hashes the same, regardless of memory layout)."""
    return hash(np.ascontiguousarray(arr).tobytes())


def _col_fp(col):
    """A change-detection fingerprint for one materialized table column (object=VLA safe)."""
    if col.dtype == object:
        return hash(tuple(np.asarray(x).tobytes() for x in col))
    return _ndarray_fp(col)


def _vla_heap_bytes(cols) -> int:
    """Total heap bytes to reserve (PCOUNT) for the VLA columns of a to-be-written table."""
    total = 0
    for col in cols:
        fmt = col.format.strip().upper()
        if ("P" in fmt or "Q" in fmt) and col.array is not None:
            elem_dtype, _ = _vla_elem_dtype(fmt)
            esize = elem_dtype.itemsize
            for cell in col.array:
                total += int(np.asarray(cell).size) * esize
    return total


# (array itemsize, signed TFORM letter) -> TZERO for the unsigned-integer column convention.
_UNSIGNED_COL = {(2, "I"): 32768, (4, "J"): 2147483648, (8, "K"): 9223372036854775808}


def _unsigned_col_tzero(col):
    """TZERO for an unsigned column stored under a matching signed TFORM (I/J/K), else None."""
    if col.array is None:
        return None
    a = np.asarray(col.array)
    if a.dtype.kind != "u":
        return None
    letter = next((ch for ch in col.format.strip().upper() if ch.isalpha()), "")
    return _UNSIGNED_COL.get((a.dtype.itemsize, letter))


def _enc(s) -> bytes:
    if isinstance(s, bytes):
        return s
    return os.fspath(s).encode("utf-8")  # accepts str and os.PathLike (e.g. pathlib.Path)


def _carr(values: Sequence[int]):
    return (c.c_long * len(values))(*[int(v) for v in values])


def _fits_value_literal(value) -> str:
    """Serialize a header value to its FITS card literal (for HIERARCH cards written raw)."""
    if isinstance(value, bool):
        return "T" if value else "F"
    if value is None:
        return ""
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def _commentary_card(kw: str, value) -> bytes:
    """An 80-byte COMMENT/HISTORY/blank card: keyword in cols 1-8, free text in cols 9-80."""
    text = "" if value is None else str(value)
    return (kw.upper().ljust(8) + text)[:80].ljust(80).encode("ascii", "replace")


def _hierarch_card(kw: str, value, comment) -> bytes:
    """A best-effort 80-byte HIERARCH card: ``HIERARCH tokens = value [/ comment]``."""
    body = "HIERARCH " + kw.strip() + " = " + _fits_value_literal(value)
    if comment:
        body += " / " + comment
    return body[:80].ljust(80).encode("ascii", "replace")


def _ptr(arr: np.ndarray) -> _VOID:
    return arr.ctypes.data_as(_VOID)


def _native(arr: np.ndarray) -> np.ndarray:
    """Contiguous, native-byte-order copy/view of ``arr``.

    numpy keeps FITS-native big-endian arrays byte-swapped in place, but the C ABI is told the
    buffer is native-endian (``zf_code`` normalizes the dtype code), so a non-native array must be
    coerced before its raw bytes are handed over — otherwise the values are silently corrupted.
    """
    return np.ascontiguousarray(arr, dtype=np.dtype(arr.dtype).newbyteorder("="))


_INT64_MIN = -(2**63)
_INT64_MAX = 2**63 - 1


def _coerce_kw_value(value: Any) -> Any:
    """Normalize a header value for the C ABI: numpy scalars → Python scalars, and reject integers
    that would silently wrap the ``c_longlong`` keyword slot (ctypes masks out-of-range ints)."""
    if isinstance(value, (bool, np.bool_)):
        return bool(value)
    if isinstance(value, np.integer):
        value = int(value)
    if isinstance(value, np.floating):
        return float(value)
    if isinstance(value, int):  # bool already handled above
        if not (_INT64_MIN <= value <= _INT64_MAX):
            raise ll.FitsOverflowError(412, f"integer keyword value {value} out of signed-64-bit range")
    return value


# Structural keywords the library derives from the data; user header edits must not overwrite them.
_STRUCTURAL = {
    "SIMPLE", "BITPIX", "NAXIS", "EXTEND", "PCOUNT", "GCOUNT", "XTENSION", "END", "BSCALE", "BZERO",
}


def _write_bzero(handle, bzero: int) -> None:
    """Write the BZERO keyword for the unsigned-integer convention (as a double when it exceeds the
    signed-64-bit keyword slot — e.g. 2**63 for uint64, which is exact as an IEEE double)."""
    kb = _enc("BZERO")
    if _INT64_MIN <= bzero <= _INT64_MAX:
        ll.check(ll.lib.zf_write_key_lng(handle, kb, len(kb), bzero, None, 0))
    else:
        ll.check(ll.lib.zf_write_key_dbl(handle, kb, len(kb), float(bzero), None, 0))


# ════════════════════════════════════════════════════════════════════════════════════════════
# Column builder (for writing tables)
# ════════════════════════════════════════════════════════════════════════════════════════════
class Column:
    """A table column specification (name + FITS ``format`` + optional data/unit)."""

    def __init__(self, name: str, format: str, array=None, unit: str | None = None):
        self.name = name
        self.format = format
        self.unit = unit
        self.array = None if array is None else np.asarray(array)


# ════════════════════════════════════════════════════════════════════════════════════════════
# HDU classes
# ════════════════════════════════════════════════════════════════════════════════════════════
class _HDU:
    """Base HDU. Either *attached* (from an open file: ``_hdulist`` + ``_index``) or *detached*
    (built in Python with ``_data``/``_header`` for writing)."""

    is_image = False

    def __init__(self, data=None, header: Header | None = None, name: str | None = None):
        self._hdulist: Any = None
        self._index: int | None = None
        self._data = data
        self._data_fingerprint = None  # baseline for update-mode data write-back
        self._header: Header | None = header if header is not None else Header()
        self._name = name

    # ── attached helpers ──────────────────────────────────────────────────────────────────
    def _select(self):
        hl = self._hdulist
        if hl is None or hl._handle is None:
            raise ll.FitsIOError(104, "operation on a detached or closed HDU")
        ll.check(ll.lib.zf_select(hl._handle, self._index))
        return hl._handle

    def _writable(self) -> bool:
        return self._hdulist is not None and self._hdulist._mode != ll.READONLY

    def _mark_dirty(self):
        # An in-memory edit the open handle doesn't know about — force reconstruction on save.
        if self._hdulist is not None:
            self._hdulist._dirty = True

    def _data_changed(self) -> bool:
        """Whether this HDU's materialized data differs from what was read — catching an in-place
        mutation (`data[:] = x`) that never goes through a setter. Base HDUs hold no data; image and
        table HDUs override this. Consulted by the writeto/to_bytes pristine gate."""
        return False

    # ── header ────────────────────────────────────────────────────────────────────────────
    @property
    def header(self) -> Header:
        if self._header is None:
            self._header = self._read_header()
        return self._header

    def _read_header(self) -> Header:
        h = self._select()
        n = c.c_long()
        ll.check(ll.lib.zf_card_count(h, c.byref(n)))
        raws = []
        buf = c.create_string_buffer(80)
        for i in range(n.value):
            ll.check(ll.lib.zf_read_card(h, i, buf))
            raws.append(buf.raw[:80])
        cards = parse_cards(raws)
        hdr = Header._from_cards(cards)
        if self._writable():
            hdr._persist = self._write_key
            hdr._delete = self._delete_key
        # A read-only header edit is not persisted to the handle; flag it so save reconstructs.
        hdr._dirty_cb = self._mark_dirty
        return hdr

    def _write_key(self, key: str, value: Any, comment: str | None):
        up = key.upper()
        if up in _STRUCTURAL or up.startswith("NAXIS"):
            raise ll.FitsHeaderError(207, f"cannot set structural keyword {key!r} on an open header")
        value = _coerce_kw_value(value)
        h = self._select()
        kb = _enc(key)
        cb = _enc(comment) if comment else None
        cl = len(cb) if cb else 0
        if isinstance(value, bool):
            ll.check(ll.lib.zf_write_key_log(h, kb, len(kb), 1 if value else 0, cb, cl))
        elif isinstance(value, int):
            ll.check(ll.lib.zf_write_key_lng(h, kb, len(kb), value, cb, cl))
        elif isinstance(value, float):
            ll.check(ll.lib.zf_write_key_dbl(h, kb, len(kb), value, cb, cl))
        else:
            vb = _enc(str(value))
            if len(vb) <= 68:
                ll.check(ll.lib.zf_write_key_str(h, kb, len(kb), vb, len(vb), cb, cl))
            else:
                ll.check(ll.lib.zf_write_key_longstr(h, kb, len(kb), vb, len(vb), cb, cl))

    def _delete_key(self, key: str):
        h = self._select()
        kb = _enc(key)
        ll.check(ll.lib.zf_delete_key(h, kb, len(kb)))

    @property
    def name(self) -> str:
        if self._name is not None:
            return self._name
        try:
            ext = self.header.get("EXTNAME", "")
        except Exception:
            ext = ""
        if ext:
            return str(ext)
        # The primary HDU answers to "PRIMARY" (astropy convention) when it has no EXTNAME.
        return "PRIMARY" if isinstance(self, PrimaryHDU) else ""


class ImageHDU(_HDU):
    """An image HDU (or extension). ``.data`` is a lazily-read NumPy array."""

    is_image = True
    _kind_name = "ImageHDU"

    @property
    def data(self):
        if self._hdulist is not None and self._data is None:
            self._data = self._read_image()
        return self._data

    @data.setter
    def data(self, value):
        self._data = None if value is None else np.asarray(value)
        self._mark_dirty()  # a replaced array is not in the open handle's bytes

    def _data_changed(self) -> bool:
        return self._data is not None and _ndarray_fp(self._data) != self._data_fingerprint

    @property
    def shape(self):
        d = self.data
        return None if d is None else d.shape

    def _img_param(self):
        h = self._select()
        bitpix = c.c_int()
        naxis = c.c_int()
        axes = (c.c_long * 999)()
        filled = c.c_int()
        ll.check(ll.lib.zf_img_param(h, c.byref(bitpix), c.byref(naxis), axes, 999, c.byref(filled)))
        return bitpix.value, [int(axes[i]) for i in range(filled.value)]

    def _output_dtype(self, header: Header, bitpix: int) -> np.dtype:
        bscale = header.get("BSCALE", 1)
        bzero = header.get("BZERO", 0)
        if bscale in (1, 1.0) and bitpix in _UNSIGNED_BZERO and bzero == _UNSIGNED_BZERO[bitpix]:
            return _UNSIGNED_DTYPE[bitpix]
        if bscale not in (1, 1.0) or bzero not in (0, 0.0):
            return np.dtype("f4") if bitpix == -32 else np.dtype("f8")
        return dt.bitpix_to_dtype(bitpix)

    def _read_image(self):
        bitpix, axes = self._img_param()
        if not axes:
            return None
        out_dtype = self._output_dtype(self.header, bitpix)
        shape = tuple(reversed(axes))  # FITS first-axis-fastest -> C-order reversed
        arr = np.empty(shape, dtype=out_dtype)
        n = int(arr.size)
        if n:
            h = self._select()
            ll.check(ll.lib.zf_read_img(h, dt.zf_code(out_dtype), 1, n, None, None, _ptr(arr)))
        # Baseline in ALL modes so both update-mode write-back and the writeto/to_bytes pristine
        # gate can detect a later edit — including an in-place mutation (`data[:] = x`) that never
        # goes through the data setter and so never sets `_dirty`.
        self._data_fingerprint = _ndarray_fp(arr)
        return arr

    # ── WCS celestial transforms (1-based pixel coords, FITS CRPIX convention) ────────────
    def pix2world(self, x: float, y: float, alt: str = " "):
        h = self._select()
        lon = c.c_double()
        lat = c.c_double()
        ll.check(ll.lib.zf_wcs_pix2world(h, ord(alt[0]) if alt.strip() else 0, x, y, c.byref(lon), c.byref(lat)))
        return lon.value, lat.value

    def world2pix(self, lon: float, lat: float, alt: str = " "):
        h = self._select()
        px = c.c_double()
        py = c.c_double()
        ll.check(ll.lib.zf_wcs_world2pix(h, ord(alt[0]) if alt.strip() else 0, lon, lat, c.byref(px), c.byref(py)))
        return px.value, py.value

    # ── writing ───────────────────────────────────────────────────────────────────────────
    def _write_to(self, handle, primary: bool):
        data = self.data  # lazily materialize attached pixels so a copied HDU keeps its data
        if data is None:
            ll.check(ll.lib.zf_create_img(handle, 8, 0, None))
            self._apply_user_keys(handle)
            return
        data = _native(data)
        plan = dt.unsigned_img_plan(data.dtype)
        if plan is not None:  # unsigned image via the BZERO convention
            bitpix, bzero, _stored_dtype = plan
            axes = list(reversed(data.shape))
            ll.check(ll.lib.zf_create_img(handle, bitpix, len(axes), _carr(axes)))
            self._apply_user_keys(handle)
            _write_bzero(handle, bzero)
            # Write the unsigned values directly; the library applies the header BZERO to store them
            # as signed ints (integer-space, exact for all widths incl. uint64).
            n = int(data.size)
            if n:
                ll.check(ll.lib.zf_write_img(handle, dt.zf_code(data.dtype), 1, n, None, None, _ptr(data)))
            return
        bitpix = dt.dtype_to_bitpix(data.dtype)
        axes = list(reversed(data.shape))  # C-order shape -> FITS axes
        ll.check(ll.lib.zf_create_img(handle, bitpix, len(axes), _carr(axes)))
        self._apply_user_keys(handle)
        n = int(data.size)
        if n:
            ll.check(ll.lib.zf_write_img(handle, dt.zf_code(data.dtype), 1, n, None, None, _ptr(data)))

    def _flush_data(self):
        """Update-mode write-back: if this attached image's materialized data changed, rewrite the
        data unit in place (same geometry only). Uses the HDU's own BSCALE/BZERO so scaled/unsigned
        images round-trip through the library's inverse scaling."""
        data = self._data
        if data is None:
            return
        fp = _ndarray_fp(data)
        if fp == self._data_fingerprint:
            return
        h = self._select()
        _bitpix, axes = self._img_param()
        if tuple(data.shape) != tuple(reversed(axes)):
            raise NotImplementedError(
                "changing image geometry in update mode is not supported; use writeto() instead"
            )
        native = _native(data)
        n = int(native.size)
        if n:
            bscale = self.header.get("BSCALE", 1)
            bzero = self.header.get("BZERO", 0)
            scref = None
            if bscale not in (1, 1.0) or bzero not in (0, 0.0):
                sc = ll.ZfScaling()
                sc.bscale = float(bscale)
                sc.bzero = float(bzero)
                scref = c.byref(sc)
            ll.check(ll.lib.zf_write_img(h, dt.zf_code(native.dtype), 1, n, None, scref, _ptr(native)))
        self._data_fingerprint = fp

    def _apply_user_keys(self, handle):
        for kw, value, comment in self.header.cards():
            up = kw.upper()
            if up in _STRUCTURAL or up.startswith("NAXIS"):
                continue
            # Commentary and HIERARCH/spaced/>8-char keys can't be written as standard 8-char
            # keywords; reconstruct their 80-byte card and write it verbatim so COMMENT/HISTORY
            # provenance and HIERARCH keywords survive the reconstruction (non-pristine) path.
            if up in ("COMMENT", "HISTORY", ""):
                ll.check(ll.lib.zf_write_record(handle, _commentary_card(kw, value)))
                continue
            if " " in kw or len(kw) > 8:
                ll.check(ll.lib.zf_write_record(handle, _hierarch_card(kw, value, comment)))
                continue
            value = _coerce_kw_value(value)
            kb = _enc(kw)
            cb = _enc(comment) if comment else None
            cl = len(cb) if cb else 0
            if isinstance(value, bool):
                ll.check(ll.lib.zf_write_key_log(handle, kb, len(kb), 1 if value else 0, cb, cl))
            elif isinstance(value, int):
                ll.check(ll.lib.zf_write_key_lng(handle, kb, len(kb), value, cb, cl))
            elif isinstance(value, float):
                ll.check(ll.lib.zf_write_key_dbl(handle, kb, len(kb), value, cb, cl))
            elif value is not None:
                vb = _enc(str(value))
                if len(vb) <= 68:
                    ll.check(ll.lib.zf_write_key_str(handle, kb, len(kb), vb, len(vb), cb, cl))
                else:
                    ll.check(ll.lib.zf_write_key_longstr(handle, kb, len(kb), vb, len(vb), cb, cl))
        if self._name:
            nb = _enc(self._name)
            kb = _enc("EXTNAME")
            ll.check(ll.lib.zf_write_key_str(handle, kb, len(kb), nb, len(nb), None, 0))


class PrimaryHDU(ImageHDU):
    _kind_name = "PrimaryHDU"


class CompImageHDU(ImageHDU):
    """A tile-compressed image. Reading is transparent; writing uses the codec in ``_comp``."""

    _kind_name = "CompImageHDU"

    def __init__(self, data=None, header=None, name=None, compression="RICE_1", tile=None, quantize=None,
                 quantize_level=None, hcomp_scale=0.0, hcomp_smooth=False):
        super().__init__(data=data, header=header, name=name)
        self._comp = compression
        self._tile = tile
        self._quantize = quantize
        # CFITSIO quantization level (fits_set_quantize_level / fpack -q semantics) for float
        # data with a quantizing method ("NO_DITHER"/"SUBTRACTIVE_DITHER_1"/"_2"): > 0 sets the
        # per-tile step to sigma/level (sigma = MAD background noise), 0 the CFITSIO default
        # (sigma/4), < 0 the absolute step |level|. None leaves the library default.
        self._quantize_level = None if quantize_level is None else float(quantize_level)
        # HCOMPRESS_1 lossy knobs (astropy-compatible names; CFITSIO fits_set_hcomp_scale/
        # fits_set_hcomp_smooth semantics): scale 0 = lossless, > 0 = noise-adaptive
        # (per-tile round(scale x background sigma)), < 0 = |scale| absolute; smooth records
        # the ZNAME2='SMOOTH' decode-side smoothing request.
        self._hcomp_scale = float(hcomp_scale)
        self._hcomp_smooth = bool(hcomp_smooth)

    def _write_to(self, handle, primary: bool):
        if self.data is None:  # lazily materializes attached data (so a copy keeps its pixels)
            raise ValueError("CompImageHDU requires data to write")
        data = _native(self.data)
        bitpix = dt.dtype_to_bitpix(data.dtype)
        axes = list(reversed(data.shape))
        comp, tile_spec, quant = self._comp, self._tile, self._quantize
        hscale, hsmooth = self._hcomp_scale, self._hcomp_smooth
        if self._hdulist is not None:
            # A scanned compressed image: reuse its own ZCMPTYPE/ZTILEn/ZQUANTIZ so re-emitting does
            # not silently change the codec (or fail outright for a float image that was GZIP-stored
            # without quantization) by recompressing with the constructor's RICE_1 default.
            hdr = self.header
            comp = str(hdr.get("ZCMPTYPE", comp))
            quant = hdr.get("ZQUANTIZ", quant)
            tiles = []
            i = 1
            while hdr.get(f"ZTILE{i}") is not None:
                tiles.append(int(hdr.get(f"ZTILE{i}")))
                i += 1
            if tiles:
                tile_spec = tiles  # ZTILEn and axes are both fastest-axis-first
            # Likewise reuse the recorded HCOMPRESS lossy request (ZNAMEn='SCALE'/'SMOOTH'):
            # re-emitting a lossy file must not silently recompress it as lossless (or drop the
            # readers' smoothing request).
            if comp.strip().upper() == "HCOMPRESS_1":
                i = 1
                while hdr.get(f"ZNAME{i}") is not None:
                    zname = str(hdr.get(f"ZNAME{i}")).strip().upper()
                    zval = hdr.get(f"ZVAL{i}")
                    try:  # a nonstandard (e.g. string-valued) ZVALn falls back to the defaults
                        if zname == "SCALE" and zval is not None:
                            hscale = float(zval)
                        elif zname == "SMOOTH" and zval is not None:
                            hsmooth = bool(int(float(zval)))
                    except (TypeError, ValueError):
                        pass
                    i += 1
        tile = _carr(tile_spec) if tile_spec else None
        q = _enc(quant) if quant else None
        qlevel = self._quantize_level
        ll.check(ll.lib.zf_write_compressed3(
            handle, dt.zf_code(data.dtype), bitpix, len(axes), _carr(axes), tile, _enc(comp), q, 1,
            0.0 if qlevel is None else qlevel, 0 if qlevel is None else 1,
            hscale, int(hsmooth), _ptr(data), int(data.size)))
        # Preserve EXTNAME (the general image path writes it via _apply_user_keys, which this
        # override does not call because the scanned header carries the compression machinery).
        nm = self.name
        if nm and nm != "PRIMARY":
            nb = _enc(nm)
            kb = _enc("EXTNAME")
            ll.check(ll.lib.zf_write_key_str(handle, kb, len(kb), nb, len(nb), None, 0))


class _TableHDU(_HDU):
    _table_type = ll.BINARY_TBL
    _columns: list = []
    _nrows: int = 0
    _col_fingerprints = None  # per-column baselines for update-mode in-place write-back

    @property
    def data(self):
        if self._hdulist is not None and self._data is None:
            self._data = self._read_table()
        return self._data

    @data.setter
    def data(self, value):
        # Replace the table's rows wholesale (e.g. `hdu.data = hdu.data[mask]` to filter rows).
        # `writeto`/`to_bytes` reconstruct from this via _emit_columns; an in-place update-mode
        # flush of a row-count change fails loud (see _flush_data). If the table was never read,
        # there is no per-column baseline, so treat every column as changed on the next flush.
        self._data = None if value is None else np.asarray(value)
        if self._data is not None and self._col_fingerprints is None:
            self._col_fingerprints = {}
        self._mark_dirty()

    def _data_changed(self) -> bool:
        if self._data is None or self._col_fingerprints is None or self._data.dtype.names is None:
            return False
        return any(_col_fp(self._data[n]) != self._col_fingerprints.get(n) for n in self._data.dtype.names)

    def _flush_data(self):
        """Write back in-place edits to a materialized table's cell values (update mode). Only
        changed columns are rewritten; changing the row count or editing a VLA/scaled column in
        place is not supported (use writeto() to a new file, which reconstructs)."""
        if self._data is None or self._col_fingerprints is None:
            return
        rec = self._data
        if rec.dtype.names is None:
            return
        h = self._select()
        t = _VOID()
        ll.check(ll.lib.zf_table_open(h, c.byref(t)))
        try:
            nrows_ = c.c_longlong()
            ll.check(ll.lib.zf_table_nrows(t, c.byref(nrows_)))
            nrows = int(nrows_.value)
            for i, name in enumerate(rec.dtype.names):
                new_fp = _col_fp(rec[name])
                if new_fp == self._col_fingerprints.get(name):
                    continue  # column unchanged
                if nrows != len(rec):
                    raise NotImplementedError(
                        "in-place table update cannot change the row count; use writeto() to a new file"
                    )
                info = ll.ZfColInfo()
                ll.check(ll.lib.zf_table_col_info(t, i, c.byref(info)))
                if info.is_vla:
                    raise NotImplementedError(
                        "in-place update of a variable-length-array column is not supported; use writeto()"
                    )
                if info.tscal != 1.0 or info.tzero != 0.0:
                    raise NotImplementedError(
                        "in-place update of a scaled/unsigned (TSCAL/TZERO) column is not supported; use writeto()"
                    )
                fmt = _ascii_tform_of(info) if self._table_type == ll.ASCII_TBL else _tform_of(info)
                _TableHDU._write_column(t, i, Column(name, fmt, array=rec[name]), nrows)
                self._col_fingerprints[name] = new_fp
        finally:
            ll.lib.zf_table_close(t)

    @property
    def columns(self):
        return self._read_columns_meta() if self._hdulist is not None else self._columns

    def _read_columns_meta(self):
        h = self._select()
        t = _VOID()
        ll.check(ll.lib.zf_table_open(h, c.byref(t)))
        try:
            ncols = c.c_int()
            ll.check(ll.lib.zf_table_ncols(t, c.byref(ncols)))
            cols = []
            for i in range(ncols.value):
                cols.append(self._col_name(t, i))
            return cols
        finally:
            ll.lib.zf_table_close(t)

    @staticmethod
    def _col_name(t, i):
        buf = c.create_string_buffer(80)
        out = c.c_size_t()
        ll.check(ll.lib.zf_table_col_name(t, i, buf, 80, c.byref(out)))
        return buf.raw[: out.value].decode("ascii", "replace").strip()

    def _read_table(self):
        h = self._select()
        t = _VOID()
        ll.check(ll.lib.zf_table_open(h, c.byref(t)))
        try:
            nrows_ = c.c_longlong()
            ll.check(ll.lib.zf_table_nrows(t, c.byref(nrows_)))
            nrows = int(nrows_.value)
            ncols_ = c.c_int()
            ll.check(ll.lib.zf_table_ncols(t, c.byref(ncols_)))
            ncols = ncols_.value

            fields = []
            readers = []
            for col in range(ncols):
                info = ll.ZfColInfo()
                ll.check(ll.lib.zf_table_col_info(t, col, c.byref(info)))
                name = self._col_name(t, col) or f"col{col + 1}"
                field_dtype, reader = self._column_plan(t, col, info, nrows)
                fields.append((name, field_dtype))
                readers.append(reader)

            rec = np.empty(max(nrows, 0), dtype=np.dtype(fields))
            for (name, _), reader in zip(fields, readers):
                rec[name] = reader()
            if rec.dtype.names:  # baselines for write-back AND the writeto pristine gate (all modes)
                self._col_fingerprints = {name: _col_fp(rec[name]) for name in rec.dtype.names}
            return rec
        finally:
            ll.lib.zf_table_close(t)

    def _column_plan(self, t, col, info, nrows):
        tform = info.tform_char
        repeat = int(info.repeat)
        # Character column -> fixed-width bytes.
        if info.typecode == ll.ZF_STRING:
            width = int(info.width)
            field_dtype = f"S{max(width, 1)}"

            def read_str():
                buf = c.create_string_buffer(max(nrows * width, 1))
                if nrows:
                    ll.check(ll.lib.zf_read_col_str(t, col, 1, nrows, width, width, buf))
                raw = buf.raw
                return np.array([raw[i * width:(i + 1) * width].rstrip(b" \x00") for i in range(nrows)], dtype=field_dtype)

            return field_dtype, read_str

        # VLA column -> object array of per-row 1-D arrays. Element type comes from info.typecode
        # (the TFORM char is 'P'/'Q', the descriptor kind — not the element type).
        if info.is_vla:
            code = int(info.typecode)
            is_complex = code in (ll.ZF_COMPLEX64, ll.ZF_COMPLEX128)
            if is_complex:
                float_dtype = np.dtype("f4") if code == ll.ZF_COMPLEX64 else np.dtype("f8")
                cdtype = np.dtype("c8") if code == ll.ZF_COMPLEX64 else np.dtype("c16")
                read_code = dt.zf_code(float_dtype)
            else:
                elem_dtype = dt.zf_to_dtype(code)
                read_code = dt.zf_code(elem_dtype)

            def read_vla():
                out = np.empty(nrows, dtype=object)
                for r in range(nrows):
                    ln = c.c_longlong()
                    off = c.c_longlong()
                    ll.check(ll.lib.zf_read_descript(t, col, r + 1, c.byref(ln), c.byref(off)))
                    count = int(ln.value)
                    if count < 0:
                        raise ll.FitsError(412, f"corrupt VLA descriptor: negative length {count}")
                    got = c.c_longlong()
                    if is_complex:
                        cap = count * 2  # ABI returns 2 float slots per complex element
                        cell_f = np.empty(max(cap, 1), dtype=float_dtype)
                        if count:
                            ll.check(ll.lib.zf_read_col_vla(t, read_code, col, r + 1, cap, _ptr(cell_f), c.byref(got)))
                        out[r] = cell_f[: int(got.value)].view(cdtype)
                    else:
                        cell = np.empty(count, dtype=elem_dtype)
                        if count:
                            ll.check(ll.lib.zf_read_col_vla(t, read_code, col, r + 1, count, _ptr(cell), c.byref(got)))
                        out[r] = cell
                return out

            return object, read_vla

        # ASCII-table columns: the TFORM letter (I/F/E/D) does not encode width, so the binary
        # letter map mis-sizes them (e.g. 'I11' -> int16, overflowing values > 32767 — the library
        # could not read back its own ASCII output). Take the element dtype from the authoritative
        # typecode instead. ASCII columns are scalar and never complex/VLA (handled above).
        if self._table_type == ll.ASCII_TBL:
            elem_dtype = dt.zf_to_dtype(int(info.typecode))
            if elem_dtype.kind in ("i", "u") and (info.tscal != 1.0 or info.tzero != 0.0):
                elem_dtype = np.dtype("f8")

            def read_ascii():
                flat = np.empty(nrows, dtype=elem_dtype)
                if flat.size:
                    ll.check(ll.lib.zf_read_col(t, dt.zf_code(elem_dtype), col, 1, flat.size, None, _ptr(flat)))
                return flat

            return elem_dtype, read_ascii

        elem_dtype, is_complex = dt.bin_elem_dtype(tform)
        if is_complex:
            cdtype = np.dtype("c8") if elem_dtype == np.dtype("f4") else np.dtype("c16")
            field_dtype = cdtype if repeat == 1 else (cdtype, repeat)

            def read_cplx():
                flat = np.empty(nrows * repeat * 2, dtype=elem_dtype)
                if flat.size:
                    ll.check(ll.lib.zf_read_col(t, dt.zf_code(elem_dtype), col, 1, flat.size, None, _ptr(flat)))
                view = flat.view(cdtype)
                return view.reshape(nrows) if repeat == 1 else view.reshape(nrows, repeat)

            return field_dtype, read_cplx

        # Honor per-column scaling (TSCAL/TZERO): the unsigned-integer convention widens to an
        # unsigned dtype; any other non-trivial linear scaling reads as physical float64. The C
        # layer applies the scaling; we only choose a destination dtype wide enough to hold it.
        if elem_dtype.kind in ("i", "u"):
            uns = _UNSIGNED_TZERO.get((elem_dtype, int(info.tzero))) if info.tscal == 1.0 else None
            if uns is not None:
                elem_dtype = uns
            elif info.tscal != 1.0 or info.tzero != 0.0:
                elem_dtype = np.dtype("f8")

        field_dtype = elem_dtype if repeat == 1 else (elem_dtype, repeat)

        def read_num():
            flat = np.empty(nrows * repeat, dtype=elem_dtype)
            if flat.size:
                ll.check(ll.lib.zf_read_col(t, dt.zf_code(elem_dtype), col, 1, flat.size, None, _ptr(flat)))
            return flat.reshape(nrows) if repeat == 1 else flat.reshape(nrows, repeat)

        return field_dtype, read_num

    # ── writing ───────────────────────────────────────────────────────────────────────────
    def _emit_columns(self):
        """(columns, nrows) to serialize: the builder columns for a detached HDU, or columns
        reconstructed from the live table for an attached one (so a copied table keeps its rows)."""
        if self._columns or self._hdulist is None:
            return list(self._columns), self._nrows
        data = self.data
        if data is None or data.dtype.names is None:
            return [], 0
        nrows = len(data)
        h = self._select()
        t = _VOID()
        ll.check(ll.lib.zf_table_open(h, c.byref(t)))
        try:
            cols = []
            for i, name in enumerate(data.dtype.names):
                info = ll.ZfColInfo()
                ll.check(ll.lib.zf_table_col_info(t, i, c.byref(info)))
                fmt = _ascii_tform_of(info) if self._table_type == ll.ASCII_TBL else _tform_of(info)
                cols.append(Column(name, fmt, array=data[name]))
            return cols, nrows
        finally:
            ll.lib.zf_table_close(t)

    def _write_to(self, handle, primary: bool):
        cols, nrows = self._emit_columns()
        n = len(cols)
        ttype = (c.c_char_p * n)(*[_enc(col.name) for col in cols])
        tform = (c.c_char_p * n)(*[_enc(col.format) for col in cols])
        tunit = (c.c_char_p * n)(*[_enc(col.unit) if col.unit else None for col in cols])
        extname = _enc(self._name) if self._name else None
        pcount = _vla_heap_bytes(cols)
        if pcount > 0:  # reserve heap up front so VLA cells can be written
            ll.check(ll.lib.zf_create_tbl_heap(handle, self._table_type, nrows, n, ttype, tform, tunit, extname, pcount))
        else:
            ll.check(ll.lib.zf_create_tbl(handle, self._table_type, nrows, n, ttype, tform, tunit, extname))

        # Unsigned columns use the TZEROn convention; set it before opening the table view so the
        # write path stores (value − TZERO) as a signed int (integer-space, exact for all widths).
        for i, col in enumerate(cols):
            tz = _unsigned_col_tzero(col)
            if tz is not None:
                kw = _enc(f"TZERO{i + 1}")
                if _INT64_MIN <= tz <= _INT64_MAX:
                    ll.check(ll.lib.zf_write_key_lng(handle, kw, len(kw), tz, None, 0))
                else:
                    ll.check(ll.lib.zf_write_key_dbl(handle, kw, len(kw), float(tz), None, 0))

        t = _VOID()
        ll.check(ll.lib.zf_table_open(handle, c.byref(t)))
        try:
            for i, col in enumerate(cols):
                if col.array is None:
                    continue
                self._write_column(t, i, col, nrows)
        finally:
            ll.lib.zf_table_close(t)

    @staticmethod
    def _write_column(t, i, col, nrows):
        arr = col.array
        fmt = col.format.strip().upper()
        # Variable-length array column 'rP<t>(max)' / 'rQ<t>(max)'.
        if "P" in fmt or "Q" in fmt:
            _TableHDU._write_vla_column(t, i, col, nrows)
            return
        # Character column 'wA' or 'Aw'. Non-ASCII is not representable in a FITS string field.
        if "A" in fmt:
            width = int("".join(ch for ch in fmt if ch.isdigit()) or "1")
            buf = c.create_string_buffer(max(nrows * width, 1))
            for r in range(nrows):
                s = arr[r]
                b = s if isinstance(s, bytes) else str(s).encode("ascii")
                buf[r * width:(r + 1) * width] = b[:width].ljust(width, b" ")
            ll.check(ll.lib.zf_write_col_str(t, i, 1, nrows, width, width, buf))
            return
        a = _native(np.asarray(arr))
        if np.iscomplexobj(a):
            base = np.dtype("f4") if a.dtype == np.dtype("c8") else np.dtype("f8")
            flat = _native(a.view(base).reshape(-1))
            ll.check(ll.lib.zf_write_col(t, dt.zf_code(base), i, 1, flat.size, None, _ptr(flat)))
            return
        flat = np.ascontiguousarray(a).reshape(-1)
        if flat.dtype == np.bool_:
            flat = flat.astype(np.uint8)  # a logical (L) column transfers as 0/1 bytes (ZF_UINT8)
        ll.check(ll.lib.zf_write_col(t, dt.zf_code(flat.dtype), i, 1, flat.size, None, _ptr(flat)))

    @staticmethod
    def _write_vla_column(t, i, col, nrows):
        elem_dtype, is_complex = _vla_elem_dtype(col.format.strip().upper())
        if is_complex:
            raise NotImplementedError("writing complex VLA columns is not supported")
        arr = col.array
        for r in range(nrows):
            cell = _native(np.asarray(arr[r]).astype(elem_dtype, copy=False)).reshape(-1)
            ll.check(ll.lib.zf_write_col_vla(t, dt.zf_code(elem_dtype), i, r + 1, _ptr(cell), int(cell.size)))

    @classmethod
    def from_columns(cls, columns: Sequence[Column], nrows: int | None = None, name: str | None = None):
        hdu = cls(name=name)
        hdu._columns = list(columns)
        present = [len(col.array) for col in columns if col.array is not None]
        if present and len(set(present)) > 1:
            raise ValueError(f"columns have differing lengths {sorted(set(present))}; all must match")
        data_len = present[0] if present else 0
        if nrows is None:
            nrows = data_len
        elif present and nrows != data_len:
            raise ValueError(f"nrows={nrows} does not match the {data_len}-row column data")
        hdu._nrows = nrows
        return hdu


class BinTableHDU(_TableHDU):
    _table_type = ll.BINARY_TBL
    _kind_name = "BinTableHDU"


class AsciiTableHDU(_TableHDU):
    _table_type = ll.ASCII_TBL
    _kind_name = "AsciiTableHDU"


# ════════════════════════════════════════════════════════════════════════════════════════════
# HDUList
# ════════════════════════════════════════════════════════════════════════════════════════════
class HDUList(list):
    """A sequence of HDUs. Open one with :func:`open`, or build one for writing from HDU objects."""

    def __init__(self, hdus=None):
        super().__init__(hdus or [])
        self._handle = None
        self._mode = ll.READONLY
        self._owns = False
        self._scanned_count = 0  # HDUs scanned from the source (for the pristine-copy fast path)
        # Set when an in-memory edit is NOT reflected in the open C handle's bytes (a data
        # replacement, or a header edit in read-only mode where nothing is persisted). Such an edit
        # disqualifies the verbatim byte-copy fast path so writeto()/to_bytes() reconstruct instead
        # of silently emitting the stale original bytes.
        self._dirty = False

    # ── opening ───────────────────────────────────────────────────────────────────────────
    @classmethod
    def _from_handle(cls, handle, mode):
        hl = cls()
        hl._handle = handle
        hl._mode = mode
        hl._owns = True
        hl._scan()
        return hl

    def _scan(self):
        count = c.c_long()
        ll.check(ll.lib.zf_hdu_count(self._handle, c.byref(count)))
        self._scanned_count = count.value
        for i in range(1, count.value + 1):
            ll.check(ll.lib.zf_select(self._handle, i))
            kind = c.c_int()
            ll.check(ll.lib.zf_hdu_type(self._handle, c.byref(kind)))
            hdu = self._make_hdu(kind.value, i)
            hdu._hdulist = self
            hdu._index = i
            hdu._header = None  # lazily read
            self.append(hdu)

    def _make_hdu(self, kind: int, index: int) -> _HDU:
        if kind == ll.HDU_BINARY_TABLE:
            # A ZIMAGE BINTABLE is a tile-compressed image.
            name = _enc("ZIMAGE")
            if ll.lib.zf_key_exists(self._handle, name, len(name)) == 1:
                return CompImageHDU()
            return BinTableHDU()
        if kind == ll.HDU_ASCII_TABLE:
            return AsciiTableHDU()
        return PrimaryHDU() if index == 1 else ImageHDU()

    # ── access ────────────────────────────────────────────────────────────────────────────
    def __getitem__(self, key):
        if isinstance(key, str):
            for hdu in self:
                if hdu.name.upper() == key.upper():
                    return hdu
            raise KeyError(key)
        return super().__getitem__(key)

    def info(self):
        rows = []
        for i, hdu in enumerate(self):
            rows.append(f"{i:>3}  {hdu.name:<12}  {type(hdu).__name__}")
        return "\n".join(rows)

    # ── lifecycle ─────────────────────────────────────────────────────────────────────────
    def flush(self):
        if self._handle is None:
            return
        if self._mode != ll.READONLY:
            # 1) Serialize any newly-appended (detached) HDUs to the open file, in order — so an
            #    open+append+close (or +flush) actually writes them, not just writeto().
            for i in range(self._scanned_count, len(self)):
                hdu = self[i]
                if hdu._hdulist is None:
                    hdu._write_to(self._handle, primary=(i == 0))
                    hdu._hdulist = self
                    hdu._index = i + 1
                    if isinstance(hdu, ImageHDU) and hdu._data is not None:
                        # Baseline so the next flush (and pristine check) treats the just-appended
                        # pixels as unchanged rather than re-writing them.
                        hdu._data_fingerprint = _ndarray_fp(hdu._data)
            if len(self) > self._scanned_count:
                self._scanned_count = len(self)
            # 2) Write back in-place edits to attached image/table data.
            for hdu in self:
                if hdu._hdulist is not self:
                    continue
                if isinstance(hdu, CompImageHDU):
                    # In-place recompression isn't supported; fail loud rather than silently drop.
                    if hdu._data_changed():
                        raise NotImplementedError(
                            "in-place update of a compressed image is not supported; use writeto() to a new file"
                        )
                elif isinstance(hdu, (ImageHDU, _TableHDU)):
                    hdu._flush_data()
        ll.check(ll.lib.zf_flush(self._handle))

    def _is_pristine_attached(self) -> bool:
        """True when this list is exactly what was scanned from an open file — every HDU still
        attached in its original slot, nothing appended/removed — so it can be copied verbatim."""
        if self._handle is None or not self._owns or self._dirty or len(self) != self._scanned_count:
            return False
        if any(hdu._data_changed() for hdu in self):  # in-place edits don't set _dirty
            return False
        return all(
            isinstance(h, _HDU) and h._hdulist is self and h._index == i + 1
            for i, h in enumerate(self)
        )

    def _source_bytes(self) -> bytes:
        self.flush()  # persist pending header/data edits so the raw bytes are current
        size = c.c_uint64()
        ll.check(ll.lib.zf_data_size(self._handle, c.byref(size)))
        buf = c.create_string_buffer(int(size.value))
        got = c.c_size_t()
        ll.check(ll.lib.zf_read_bytes(self._handle, 0, buf, size.value, c.byref(got)))
        return buf.raw[: got.value]

    def close(self):
        if self._handle is None:
            return
        # Persist pending edits before closing (astropy flushes on close in update mode); always
        # release the handle even if the flush fails, so the file descriptor is never leaked.
        try:
            if self._mode != ll.READONLY:
                self.flush()
        finally:
            ll.lib.zf_close(self._handle)
            self._handle = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    # ── writing ───────────────────────────────────────────────────────────────────────────
    def writeto(self, path, overwrite: bool = False, checksum: bool = False):
        path = os.fspath(path)
        if os.path.exists(path) and not overwrite:
            raise OSError(f"file exists: {path} (use overwrite=True)")
        # Write to a temp file in the same directory, then atomically rename into place: a failure
        # never leaves a partial/corrupt file at `path`, and overwrite=True does not destroy the
        # existing file until the new one is complete.
        tmp = path + ".zigfitsio.tmp"
        try:
            if not checksum and self._is_pristine_attached():
                with __import__("builtins").open(tmp, "wb") as fh:
                    fh.write(self._source_bytes())
            else:
                opts = ll.ZfOpenOpts()
                if checksum:
                    opts.checksum_on_close = 1
                handle = _VOID()
                pb = _enc(tmp)
                ll.check(ll.lib.zf_create_file(pb, len(pb), c.byref(opts) if checksum else None, c.byref(handle)))
                try:
                    self._emit(handle.value, checksum)
                    ll.check(ll.lib.zf_flush(handle))
                finally:
                    ll.lib.zf_close(handle)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise

    def to_bytes(self) -> bytes:
        """Serialize the HDU list to an in-memory FITS byte string."""
        if self._is_pristine_attached():
            return self._source_bytes()
        handle = _VOID()
        ll.check(ll.lib.zf_create_memory(None, c.byref(handle)))
        try:
            self._emit(handle.value, False)
            ll.check(ll.lib.zf_flush(handle))
            size = c.c_uint64()
            ll.check(ll.lib.zf_data_size(handle, c.byref(size)))
            buf = c.create_string_buffer(int(size.value))
            got = c.c_size_t()
            ll.check(ll.lib.zf_read_bytes(handle, 0, buf, size.value, c.byref(got)))
            return buf.raw[: got.value]
        finally:
            ll.lib.zf_close(handle)

    def _emit(self, handle, checksum: bool):
        hdus = list(self)
        if not hdus:
            raise ValueError("cannot serialize an empty HDUList (a FITS file needs a primary HDU)")
        # Tables and tile-compressed images both serialize as BINTABLE extensions, so they need a
        # real primary HDU before them. CompImageHDU.is_image is True (it subclasses ImageHDU), so
        # it must be handled explicitly alongside the non-image case.
        if hdus and (not hdus[0].is_image or isinstance(hdus[0], CompImageHDU)):
            PrimaryHDU()._write_to(handle, primary=True)
        for i, hdu in enumerate(hdus):
            hdu._write_to(handle, primary=(i == 0))
            if checksum:
                ll.check(ll.lib.zf_write_chksum(handle))


# ════════════════════════════════════════════════════════════════════════════════════════════
# Module-level conveniences (astropy-compatible names)
# ════════════════════════════════════════════════════════════════════════════════════════════
def open(path, mode: str = "readonly", opts: ll.ZfOpenOpts | None = None) -> HDUList:
    """Open a FITS file. ``mode``: ``"readonly"``, ``"update"`` (read-write), or ``"append"``.
    ``path`` may be a str or an ``os.PathLike`` (e.g. ``pathlib.Path``)."""
    path = os.fspath(path)
    try:
        mode_code = {"readonly": ll.READONLY, "update": ll.READWRITE, "append": ll.READWRITE}[mode]
    except KeyError:
        raise ValueError(f"invalid mode {mode!r}: expected 'readonly', 'update', or 'append'")
    handle = _VOID()
    pb = _enc(path)
    optref = c.byref(opts) if opts is not None else None
    if path.endswith(".gz"):
        # A .gz opens into an in-memory handle that cannot write back to the compressed file;
        # reject a writable mode up front rather than failing mid-edit with a device-read-only error.
        if mode_code != ll.READONLY:
            raise ValueError("a .gz file can only be opened in 'readonly' mode")
        with __import__("builtins").open(path, "rb") as fh:
            raw = fh.read()
        ll.check(ll.lib.zf_open_gzip(raw, len(raw), optref, c.byref(handle)))
    else:
        ll.check(ll.lib.zf_open_file(pb, len(pb), mode_code, optref, c.byref(handle)))
    return HDUList._from_handle(handle, mode_code)


def from_bytes(data: bytes, mode: str = "readonly") -> HDUList:
    """Open a FITS file held in a Python ``bytes`` object."""
    mode_code = ll.READONLY if mode == "readonly" else ll.READWRITE
    handle = _VOID()
    ll.check(ll.lib.zf_open_memory(data, len(data), mode_code, None, c.byref(handle)))
    return HDUList._from_handle(handle, mode_code)


def getheader(path: str, ext: int = 0) -> Header:
    with open(path) as hdul:
        return hdul[ext].header


def getdata(path: str, ext: int = 0, header: bool = False):
    with open(path) as hdul:
        hdu = hdul[ext]
        # astropy convention: an empty primary (ext 0) falls through to the first HDU with data.
        if ext == 0 and hdu.data is None:
            for cand in hdul:
                if cand.data is not None:
                    hdu = cand
                    break
        data = hdu.data
        if header:
            return data, hdu.header
        return data


def getval(path: str, keyword: str, ext: int = 0):
    with open(path) as hdul:
        return hdul[ext].header[keyword]


def writeto(path: str, data, header: Header | None = None, overwrite: bool = False, checksum: bool = False):
    HDUList([PrimaryHDU(data=data, header=header)]).writeto(path, overwrite=overwrite, checksum=checksum)


class Finding:
    """One structural validation finding."""

    __slots__ = ("severity", "hdu", "keyword", "message")

    def __init__(self, severity, hdu, keyword, message):
        self.severity = severity  # "error" or "warning"
        self.hdu = hdu
        self.keyword = keyword
        self.message = message

    def __repr__(self):
        kw = f" {self.keyword}" if self.keyword else ""
        return f"<{self.severity} HDU {self.hdu}{kw}: {self.message}>"


def verify(source) -> list[Finding]:
    """Run the fitsverify-style structural pass; return a list of :class:`Finding`."""
    own = isinstance(source, str)
    hdul = open(source) if own else source
    try:
        handle = hdul._handle
        if handle is None:
            raise ll.FitsIOError(104, "verify() requires an HDUList opened from a file or bytes")
        fh = _VOID()
        ll.check(ll.lib.zf_validate(handle, c.byref(fh)))
        try:
            count = c.c_long()
            ll.check(ll.lib.zf_findings_count(fh, c.byref(count)))
            out = []
            kwb = c.create_string_buffer(80)
            msgb = c.create_string_buffer(256)
            for i in range(count.value):
                sev = c.c_int()
                hd = c.c_int()
                kwl = c.c_size_t()
                msgl = c.c_size_t()
                ll.check(ll.lib.zf_findings_get(fh, i, c.byref(sev), c.byref(hd), kwb, 80, c.byref(kwl), msgb, 256, c.byref(msgl)))
                out.append(Finding(
                    "error" if sev.value == 0 else "warning",
                    int(hd.value),
                    kwb.raw[: kwl.value].decode("ascii", "replace") or None,
                    msgb.raw[: msgl.value].decode("ascii", "replace"),
                ))
            return out
        finally:
            ll.lib.zf_findings_free(fh)
    finally:
        if own:
            hdul.close()
