"""High-level, NumPy-first FITS API modeled on ``astropy.io.fits``.

Provides :func:`open` returning an :class:`HDUList`, the HDU classes (:class:`PrimaryHDU`,
:class:`ImageHDU`, :class:`BinTableHDU`, :class:`AsciiTableHDU`, :class:`CompImageHDU`), a
:class:`Column` builder, and the ``getdata``/``getheader``/``writeto``/``verify`` conveniences.
Data is exchanged as native-endian NumPy arrays; image arrays use C-order with reversed axes
(shape ``(NAXIS2, NAXIS1)``), matching astropy.
"""

from __future__ import annotations

import ctypes as c
from typing import Any, Sequence

import numpy as np

from . import _dtypes as dt
from . import lowlevel as ll
from .header import Header, parse_card

_VOID = c.c_void_p

# BZERO values that encode the unsigned-integer convention for each signed BITPIX.
_UNSIGNED_BZERO = {16: 32768, 32: 2147483648, 64: 9223372036854775808}
_UNSIGNED_DTYPE = {16: np.dtype("u2"), 32: np.dtype("u4"), 64: np.dtype("u8")}


def _enc(s: str | bytes) -> bytes:
    return s if isinstance(s, bytes) else s.encode("utf-8")


def _carr(values: Sequence[int]):
    return (c.c_long * len(values))(*[int(v) for v in values])


def _ptr(arr: np.ndarray) -> _VOID:
    return arr.ctypes.data_as(_VOID)


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
        self._header: Header | None = header if header is not None else Header()
        self._name = name

    # ── attached helpers ──────────────────────────────────────────────────────────────────
    def _select(self):
        hl = self._hdulist
        ll.check(ll.lib.zf_select(hl._handle, self._index))
        return hl._handle

    def _writable(self) -> bool:
        return self._hdulist is not None and self._hdulist._mode != ll.READONLY

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
        cards = []
        buf = c.create_string_buffer(80)
        for i in range(n.value):
            ll.check(ll.lib.zf_read_card(h, i, buf))
            card = parse_card(buf.raw[:80])
            if card is not None:
                cards.append(card)
        hdr = Header._from_cards(cards)
        if self._writable():
            hdr._persist = self._write_key
            hdr._delete = self._delete_key
        return hdr

    def _write_key(self, key: str, value: Any, comment: str | None):
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
            return str(self.header.get("EXTNAME", ""))
        except Exception:
            return ""


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
        data = self._data
        if data is None:
            ll.check(ll.lib.zf_create_img(handle, 8, 0, None))
            self._apply_user_keys(handle)
            return
        data = np.ascontiguousarray(data)
        bitpix = dt.dtype_to_bitpix(data.dtype)
        axes = list(reversed(data.shape))  # C-order shape -> FITS axes
        ll.check(ll.lib.zf_create_img(handle, bitpix, len(axes), _carr(axes)))
        self._apply_user_keys(handle)
        n = int(data.size)
        if n:
            ll.check(ll.lib.zf_write_img(handle, dt.zf_code(data.dtype), 1, n, None, None, _ptr(data)))

    _STRUCTURAL = {
        "SIMPLE", "BITPIX", "NAXIS", "EXTEND", "PCOUNT", "GCOUNT", "XTENSION", "END", "BSCALE", "BZERO",
    }

    def _apply_user_keys(self, handle):
        for kw, value, comment in self.header.cards():
            up = kw.upper()
            if up in self._STRUCTURAL or up.startswith("NAXIS"):
                continue
            if up in ("COMMENT", "HISTORY", ""):
                continue
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

    def __init__(self, data=None, header=None, name=None, compression="RICE_1", tile=None, quantize=None):
        super().__init__(data=data, header=header, name=name)
        self._comp = compression
        self._tile = tile
        self._quantize = quantize

    def _write_to(self, handle, primary: bool):
        data = np.ascontiguousarray(self._data)
        bitpix = dt.dtype_to_bitpix(data.dtype)
        axes = list(reversed(data.shape))
        tile = _carr(self._tile) if self._tile else None
        q = _enc(self._quantize) if self._quantize else None
        ll.check(ll.lib.zf_write_compressed(handle, dt.zf_code(data.dtype), bitpix, len(axes), _carr(axes), tile, _enc(self._comp), q, 1, _ptr(data), int(data.size)))


class _TableHDU(_HDU):
    _table_type = ll.BINARY_TBL
    _columns: list = []
    _nrows: int = 0

    @property
    def data(self):
        if self._hdulist is not None and self._data is None:
            self._data = self._read_table()
        return self._data

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

        # VLA column -> object array of per-row 1-D arrays.
        if info.is_vla:
            elem_dtype, is_complex = dt.bin_elem_dtype(tform)

            def read_vla():
                out = np.empty(nrows, dtype=object)
                for r in range(nrows):
                    ln = c.c_longlong()
                    off = c.c_longlong()
                    ll.check(ll.lib.zf_read_descript(t, col, r + 1, c.byref(ln), c.byref(off)))
                    count = int(ln.value)
                    cell = np.empty(count, dtype=elem_dtype)
                    got = c.c_longlong()
                    if count:
                        ll.check(ll.lib.zf_read_col_vla(t, dt.zf_code(elem_dtype), col, r + 1, count, _ptr(cell), c.byref(got)))
                    out[r] = cell
                return out

            return object, read_vla

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

        field_dtype = elem_dtype if repeat == 1 else (elem_dtype, repeat)

        def read_num():
            flat = np.empty(nrows * repeat, dtype=elem_dtype)
            if flat.size:
                ll.check(ll.lib.zf_read_col(t, dt.zf_code(elem_dtype), col, 1, flat.size, None, _ptr(flat)))
            return flat.reshape(nrows) if repeat == 1 else flat.reshape(nrows, repeat)

        return field_dtype, read_num

    # ── writing ───────────────────────────────────────────────────────────────────────────
    def _write_to(self, handle, primary: bool):
        cols = self._columns
        nrows = self._nrows
        n = len(cols)
        ttype = (c.c_char_p * n)(*[_enc(col.name) for col in cols])
        tform = (c.c_char_p * n)(*[_enc(col.format) for col in cols])
        tunit = (c.c_char_p * n)(*[_enc(col.unit) if col.unit else None for col in cols])
        extname = _enc(self._name) if self._name else None
        ll.check(ll.lib.zf_create_tbl(handle, self._table_type, nrows, n, ttype, tform, tunit, extname))

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
        # Character column 'wA' or 'Aw'.
        if "A" in fmt and not any(ch in fmt for ch in "PQ"):
            width = int("".join(ch for ch in fmt if ch.isdigit()) or "1")
            buf = c.create_string_buffer(max(nrows * width, 1))
            for r in range(nrows):
                s = arr[r]
                b = s if isinstance(s, bytes) else str(s).encode("ascii", "replace")
                buf[r * width:(r + 1) * width] = b[:width].ljust(width, b" ")
            ll.check(ll.lib.zf_write_col_str(t, i, 1, nrows, width, width, buf))
            return
        a = np.ascontiguousarray(arr)
        if np.iscomplexobj(a):
            base = np.dtype("f4") if a.dtype == np.dtype("c8") else np.dtype("f8")
            flat = a.view(base).reshape(-1)
            ll.check(ll.lib.zf_write_col(t, dt.zf_code(base), i, 1, flat.size, None, _ptr(flat)))
            return
        flat = a.reshape(-1)
        ll.check(ll.lib.zf_write_col(t, dt.zf_code(flat.dtype), i, 1, flat.size, None, _ptr(flat)))

    @classmethod
    def from_columns(cls, columns: Sequence[Column], nrows: int | None = None, name: str | None = None):
        hdu = cls(name=name)
        hdu._columns = list(columns)
        if nrows is None:
            nrows = max((len(col.array) for col in columns if col.array is not None), default=0)
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
        if self._handle is not None:
            ll.check(ll.lib.zf_flush(self._handle))

    def close(self):
        if self._handle is not None:
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
    def writeto(self, path: str, overwrite: bool = False, checksum: bool = False):
        import os

        if os.path.exists(path) and not overwrite:
            raise OSError(f"file exists: {path} (use overwrite=True)")
        opts = ll.ZfOpenOpts()
        if checksum:
            opts.checksum_on_close = 1
        handle = _VOID()
        pb = _enc(path)
        ll.check(ll.lib.zf_create_file(pb, len(pb), c.byref(opts) if checksum else None, c.byref(handle)))
        try:
            self._emit(handle.value, checksum)
            ll.check(ll.lib.zf_flush(handle))
        finally:
            ll.lib.zf_close(handle)

    def to_bytes(self) -> bytes:
        """Serialize the HDU list to an in-memory FITS byte string."""
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
        if hdus and not hdus[0].is_image:
            PrimaryHDU()._write_to(handle, primary=True)  # tables need a primary first
        for i, hdu in enumerate(hdus):
            hdu._write_to(handle, primary=(i == 0))
            if checksum:
                ll.check(ll.lib.zf_write_chksum(handle))


# ════════════════════════════════════════════════════════════════════════════════════════════
# Module-level conveniences (astropy-compatible names)
# ════════════════════════════════════════════════════════════════════════════════════════════
def open(path: str, mode: str = "readonly", opts: ll.ZfOpenOpts | None = None) -> HDUList:
    """Open a FITS file. ``mode``: ``"readonly"``, ``"update"`` (read-write), or ``"append"``."""
    mode_code = {"readonly": ll.READONLY, "update": ll.READWRITE, "append": ll.READWRITE}.get(mode, ll.READONLY)
    handle = _VOID()
    pb = _enc(path)
    optref = c.byref(opts) if opts is not None else None
    if path.endswith(".gz"):
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
