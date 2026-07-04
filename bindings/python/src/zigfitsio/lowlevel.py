"""Low-level ctypes bindings for the ``zigfitsio_capi`` C ABI.

This module is an almost 1:1 mapping of ``bindings/c/zigfitsio.h``: it loads the shared library,
declares every ``zf_*`` prototype, mirrors the C structs/enum codes, and turns nonzero status
returns into a typed :class:`FitsError`. It is numpy-free and does no high-level reshaping — that
is the job of the package's high-level API. Power users can call ``lib.zf_*`` directly.
"""

from __future__ import annotations

import ctypes as _c

from ._loader import load_library

lib = load_library()

# ── ctypes shorthands ────────────────────────────────────────────────────────────────────────
VOID = _c.c_void_p
INT = _c.c_int
LONG = _c.c_long
LL = _c.c_longlong
SZ = _c.c_size_t
FLT = _c.c_float
DBL = _c.c_double
U32 = _c.c_uint32
U64 = _c.c_uint64
I64 = _c.c_int64
CHARP = _c.c_char_p
PSZ = _c.POINTER(_c.c_size_t)
PVOID = _c.POINTER(_c.c_void_p)
PINT = _c.POINTER(_c.c_int)
PLONG = _c.POINTER(_c.c_long)
PLL = _c.POINTER(_c.c_longlong)
PDBL = _c.POINTER(_c.c_double)
PU64 = _c.POINTER(_c.c_uint64)
PCHARP = _c.POINTER(_c.c_char_p)

# ── Datatype codes (ZfType) ──────────────────────────────────────────────────────────────────
ZF_UINT8 = 1
ZF_INT8 = 2
ZF_INT16 = 3
ZF_UINT16 = 4
ZF_INT32 = 5
ZF_UINT32 = 6
ZF_INT64 = 7
ZF_UINT64 = 8
ZF_FLOAT32 = 9
ZF_FLOAT64 = 10
ZF_BOOL = 11
ZF_BIT = 12
ZF_STRING = 13
ZF_COMPLEX64 = 14
ZF_COMPLEX128 = 15

# Open modes.
READONLY = 0
READWRITE = 1
CREATE = 2

# HDU kinds.
HDU_PRIMARY = 0
HDU_IMAGE = 1
HDU_ASCII_TABLE = 2
HDU_BINARY_TABLE = 3
HDU_RANDOM_GROUPS = 4

# Table types.
BINARY_TBL = 0
ASCII_TBL = 1


# ── C structs (must match bindings/c/zigfitsio.h) ────────────────────────────────────────────
class ZfOpenOpts(_c.Structure):
    _fields_ = [
        ("checksum_on_close", INT),
        ("max_header_blocks", U32),
        ("max_hdu_count", U32),
        ("max_naxis_product", U64),
        ("max_heap_bytes", U64),
        ("max_vla_elems", U64),
        ("max_string_value", U32),
        ("max_tile_bytes", U64),
        ("max_open_alloc", U64),
        ("max_matches", U32),
    ]


class ZfScaling(_c.Structure):
    _fields_ = [
        ("bscale", DBL),
        ("bzero", DBL),
        ("blank", I64),
        ("has_blank", INT),
        ("raw", INT),
    ]


class ZfColInfo(_c.Structure):
    _fields_ = [
        ("typecode", INT),
        ("repeat", I64),
        ("width", I64),
        ("is_vla", INT),
        ("tform_char", INT),
        ("tscal", DBL),
        ("tzero", DBL),
        ("tnull", I64),
        ("has_tnull", INT),
    ]


# ── Error hierarchy ──────────────────────────────────────────────────────────────────────────
class FitsError(Exception):
    """Base class for all errors from the FITS library. Carries the CFITSIO ``status`` code."""

    def __init__(self, status: int, message: str = ""):
        self.status = status
        self.message = message or f"FITS error (status {status})"
        super().__init__(f"[{status}] {self.message}")


class FitsIOError(FitsError):
    pass


class FitsMemoryError(FitsError, MemoryError):
    pass


class FitsHeaderError(FitsError):
    pass


class KeywordNotFound(FitsHeaderError, KeyError):
    """A header keyword does not exist (status 202). Also a ``KeyError`` for dict-like use."""


class FitsStructError(FitsError):
    pass


class FitsTableError(FitsError):
    pass


class FitsTypeError(FitsError, TypeError):
    pass


class FitsOverflowError(FitsError):
    pass


class FitsCompressError(FitsError):
    pass


class FitsWcsError(FitsError):
    pass


# CFITSIO status code → exception class (nearest mapping; default FitsError).
_CODE_TO_CLASS = {
    104: FitsIOError,  # null input pointer (defensive C-ABI guard)
    113: FitsMemoryError,
    106: FitsIOError,
    107: FitsIOError,
    108: FitsIOError,
    112: FitsIOError,
    116: FitsIOError,
    202: KeywordNotFound,
    204: FitsHeaderError,
    205: FitsHeaderError,
    207: FitsHeaderError,
    208: FitsStructError,
    210: FitsHeaderError,
    211: FitsStructError,
    212: FitsStructError,
    213: FitsStructError,
    225: FitsStructError,
    235: FitsStructError,
    219: FitsTableError,
    261: FitsTableError,
    262: FitsTableError,
    263: FitsTableError,
    264: FitsTableError,
    307: FitsTableError,
    308: FitsTableError,
    410: FitsTypeError,
    412: FitsOverflowError,
    413: FitsCompressError,
    414: FitsCompressError,
    502: FitsWcsError,
    503: FitsWcsError,
    504: FitsWcsError,
}


def last_error_message() -> str:
    """Read the thread-local last-error message set by the most recent failing call."""
    buf = _c.create_string_buffer(256)
    out_len = SZ()
    lib.zf_errmsg(buf, SZ(256), _c.byref(out_len))
    return buf.raw[: out_len.value].decode("utf-8", "replace")


def check(status: int) -> int:
    """Raise the mapped :class:`FitsError` subclass if ``status`` is nonzero; else return it."""
    if status != 0:
        msg = last_error_message()
        cls = _CODE_TO_CLASS.get(status, FitsError)
        raise cls(status, msg)
    return status


# ── Prototype declarations ───────────────────────────────────────────────────────────────────
# (name, restype, [argtypes...]) mirroring bindings/c/zigfitsio.h exactly.
_PROTOS = [
    # version & errors
    ("zf_version", CHARP, []),
    ("zf_last_status", INT, []),
    ("zf_errmsg", INT, [CHARP, SZ, PSZ]),
    ("zf_last_keyword", None, [CHARP, SZ, PSZ]),
    ("zf_last_byte_offset", I64, []),
    ("zf_last_hdu_index", I64, []),
    ("zf_free", None, [VOID, SZ]),
    # lifecycle
    ("zf_open_file", INT, [CHARP, SZ, INT, VOID, PVOID]),
    ("zf_create_file", INT, [CHARP, SZ, VOID, PVOID]),
    ("zf_open_memory", INT, [CHARP, SZ, INT, VOID, PVOID]),
    ("zf_create_memory", INT, [VOID, PVOID]),
    ("zf_open_gzip", INT, [CHARP, SZ, VOID, PVOID]),
    ("zf_flush", INT, [VOID]),
    ("zf_save_gzip", INT, [VOID, CHARP, SZ]),
    ("zf_data_size", INT, [VOID, PU64]),
    ("zf_read_bytes", INT, [VOID, U64, CHARP, SZ, PSZ]),
    ("zf_close", None, [VOID]),
    # navigation
    ("zf_hdu_count", INT, [VOID, PLONG]),
    ("zf_select", INT, [VOID, LONG]),
    ("zf_move", INT, [VOID, LONG]),
    ("zf_select_by_name", INT, [VOID, CHARP, SZ, LONG, INT]),
    ("zf_current_hdu", INT, [VOID, PLONG]),
    ("zf_hdu_type", INT, [VOID, PINT]),
    ("zf_img_param", INT, [VOID, PINT, PINT, PLONG, INT, PINT]),
    # images
    ("zf_create_img", INT, [VOID, INT, INT, PLONG]),
    ("zf_resize_img", INT, [VOID, INT, INT, PLONG]),
    ("zf_read_img", INT, [VOID, INT, LL, LL, VOID, VOID, VOID]),
    ("zf_write_img", INT, [VOID, INT, LL, LL, VOID, VOID, VOID]),
    ("zf_read_subset", INT, [VOID, INT, INT, PLONG, PLONG, PLONG, LL, VOID, VOID, VOID]),
    ("zf_write_subset", INT, [VOID, INT, INT, PLONG, PLONG, PLONG, LL, VOID, VOID, VOID]),
    # header
    ("zf_card_count", INT, [VOID, PLONG]),
    ("zf_read_card", INT, [VOID, LONG, CHARP]),
    ("zf_key_exists", INT, [VOID, CHARP, SZ]),
    ("zf_read_key_lng", INT, [VOID, CHARP, SZ, PLL]),
    ("zf_read_key_dbl", INT, [VOID, CHARP, SZ, PDBL]),
    ("zf_read_key_log", INT, [VOID, CHARP, SZ, PINT]),
    ("zf_read_key_str", INT, [VOID, CHARP, SZ, CHARP, SZ, PSZ]),
    ("zf_read_key_longstr", INT, [VOID, CHARP, SZ, PVOID, PSZ]),
    ("zf_key_comment", INT, [VOID, CHARP, SZ, CHARP, SZ, PSZ]),
    ("zf_write_key_lng", INT, [VOID, CHARP, SZ, LL, CHARP, SZ]),
    ("zf_write_key_dbl", INT, [VOID, CHARP, SZ, DBL, CHARP, SZ]),
    ("zf_write_key_log", INT, [VOID, CHARP, SZ, INT, CHARP, SZ]),
    ("zf_write_key_str", INT, [VOID, CHARP, SZ, CHARP, SZ, CHARP, SZ]),
    ("zf_write_key_longstr", INT, [VOID, CHARP, SZ, CHARP, SZ, CHARP, SZ]),
    ("zf_delete_key", INT, [VOID, CHARP, SZ]),
    ("zf_rename_key", INT, [VOID, CHARP, SZ, CHARP, SZ]),
    ("zf_write_record", INT, [VOID, CHARP]),
    ("zf_insert_record", INT, [VOID, LONG, CHARP]),
    # hdu management
    ("zf_delete_hdu", INT, [VOID, LONG]),
    ("zf_copy_hdu", INT, [VOID, LONG]),
    # tables
    ("zf_create_tbl", INT, [VOID, INT, LL, INT, PCHARP, PCHARP, PCHARP, CHARP]),
    ("zf_create_tbl_heap", INT, [VOID, INT, LL, INT, PCHARP, PCHARP, PCHARP, CHARP, LL]),
    ("zf_table_open", INT, [VOID, PVOID]),
    ("zf_table_close", None, [VOID]),
    ("zf_table_nrows", INT, [VOID, PLL]),
    ("zf_table_ncols", INT, [VOID, PINT]),
    ("zf_table_colnum", INT, [VOID, CHARP, SZ, PINT]),
    ("zf_table_col_info", INT, [VOID, INT, _c.POINTER(ZfColInfo)]),
    ("zf_table_col_name", INT, [VOID, INT, CHARP, SZ, PSZ]),
    ("zf_table_col_unit", INT, [VOID, INT, CHARP, SZ, PSZ]),
    ("zf_read_col", INT, [VOID, INT, INT, LL, LL, VOID, VOID]),
    ("zf_write_col", INT, [VOID, INT, INT, LL, LL, VOID, VOID]),
    ("zf_read_col_str", INT, [VOID, INT, LL, LL, LL, LL, CHARP]),
    ("zf_write_col_str", INT, [VOID, INT, LL, LL, LL, LL, CHARP]),
    ("zf_append_rows", INT, [VOID, LL]),
    ("zf_insert_rows", INT, [VOID, LL, LL]),
    ("zf_delete_rows", INT, [VOID, LL, LL]),
    ("zf_insert_col", INT, [VOID, INT, CHARP, CHARP]),
    ("zf_delete_col", INT, [VOID, INT]),
    # VLA
    ("zf_read_descript", INT, [VOID, INT, LL, PLL, PLL]),
    ("zf_read_col_vla", INT, [VOID, INT, INT, LL, LL, VOID, PLL]),
    ("zf_write_col_vla", INT, [VOID, INT, INT, LL, VOID, LL]),
    # integrity
    ("zf_write_chksum", INT, [VOID]),
    ("zf_update_chksum_all", INT, [VOID]),
    ("zf_verify_chksum", INT, [VOID, PINT, PINT]),
    ("zf_datasum", INT, [VOID, PU64]),
    # validation
    ("zf_validate", INT, [VOID, PVOID]),
    ("zf_findings_count", INT, [VOID, PLONG]),
    ("zf_findings_get", INT, [VOID, LONG, PINT, PINT, CHARP, SZ, PSZ, CHARP, SZ, PSZ]),
    ("zf_findings_free", None, [VOID]),
    # wcs
    ("zf_wcs_pix2world", INT, [VOID, INT, DBL, DBL, PDBL, PDBL]),
    ("zf_wcs_world2pix", INT, [VOID, INT, DBL, DBL, PDBL, PDBL]),
    # compression
    ("zf_write_compressed", INT, [VOID, INT, INT, INT, PLONG, PLONG, CHARP, CHARP, LL, VOID, LL]),
    ("zf_write_compressed2", INT, [VOID, INT, INT, INT, PLONG, PLONG, CHARP, CHARP, LL, FLT, INT, VOID, LL]),
    ("zf_write_compressed3", INT, [VOID, INT, INT, INT, PLONG, PLONG, CHARP, CHARP, LL, FLT, INT, FLT, INT, VOID, LL]),
]


def _declare() -> None:
    for name, restype, argtypes in _PROTOS:
        fn = getattr(lib, name)
        fn.restype = restype
        fn.argtypes = argtypes


_declare()


def version() -> str:
    """The library version string."""
    return lib.zf_version().decode("ascii")
