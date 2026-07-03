"""NumPy dtype <-> FITS/ZfType mapping helpers."""

from __future__ import annotations

import numpy as np

from . import lowlevel as ll

# BITPIX -> native numpy dtype (the C ABI already returns native-endian, converted values).
BITPIX_TO_DTYPE = {
    8: np.dtype("u1"),
    16: np.dtype("i2"),
    32: np.dtype("i4"),
    64: np.dtype("i8"),
    -32: np.dtype("f4"),
    -64: np.dtype("f8"),
}

DTYPE_TO_BITPIX = {
    np.dtype("u1"): 8,
    np.dtype("i2"): 16,
    np.dtype("i4"): 32,
    np.dtype("i8"): 64,
    np.dtype("f4"): -32,
    np.dtype("f8"): -64,
}

# numpy dtype -> ZfType element code (for image/column transfers).
_DTYPE_TO_ZF = {
    np.dtype("u1"): ll.ZF_UINT8,
    np.dtype("i1"): ll.ZF_INT8,
    np.dtype("i2"): ll.ZF_INT16,
    np.dtype("u2"): ll.ZF_UINT16,
    np.dtype("i4"): ll.ZF_INT32,
    np.dtype("u4"): ll.ZF_UINT32,
    np.dtype("i8"): ll.ZF_INT64,
    np.dtype("u8"): ll.ZF_UINT64,
    np.dtype("f4"): ll.ZF_FLOAT32,
    np.dtype("f8"): ll.ZF_FLOAT64,
}


def zf_code(dtype) -> int:
    """ZfType element code for a numpy dtype (native byte order)."""
    dt = np.dtype(dtype).newbyteorder("=")
    try:
        return _DTYPE_TO_ZF[dt]
    except KeyError as exc:
        raise ll.FitsTypeError(410, f"unsupported numpy dtype {dtype!r}") from exc


# ZfType element code -> numpy dtype (inverse of _DTYPE_TO_ZF, plus the two complex codes which
# have no distinct numpy entry in _DTYPE_TO_ZF). Used to pick a read dtype from a column's
# reported typecode instead of guessing from the TFORM letter.
ZF_TO_DTYPE = {code: dt for dt, code in _DTYPE_TO_ZF.items()}
ZF_TO_DTYPE[ll.ZF_COMPLEX64] = np.dtype("c8")
ZF_TO_DTYPE[ll.ZF_COMPLEX128] = np.dtype("c16")
# Logical/bit codes read back as bytes (0/1) — the C ABI transfers one byte per element. This makes
# a logical (PL) or bit (PX) VLA column readable instead of raising on an unmapped typecode. (These
# explicit entries override the ZF_BOOL->bool inverse from the write map above.)
ZF_TO_DTYPE[ll.ZF_BOOL] = np.dtype("u1")
ZF_TO_DTYPE[ll.ZF_BIT] = np.dtype("u1")


def zf_to_dtype(code: int) -> np.dtype:
    """numpy dtype for a ZfType element code (the inverse of :func:`zf_code`)."""
    try:
        return ZF_TO_DTYPE[int(code)]
    except KeyError as exc:
        raise ll.FitsTypeError(410, f"unsupported ZfType code {code}") from exc


# numpy unsigned dtype -> (signed BITPIX, BZERO offset, on-disk signed dtype) for writing images
# via the FITS unsigned-integer convention (store value-BZERO as a signed int, record BZERO).
_UNSIGNED_IMG_WRITE = {
    np.dtype("u2"): (16, 32768, np.dtype("i2")),
    np.dtype("u4"): (32, 2147483648, np.dtype("i4")),
    np.dtype("u8"): (64, 9223372036854775808, np.dtype("i8")),
}


def unsigned_img_plan(dtype):
    """(bitpix, bzero, stored_dtype) if ``dtype`` writes via the BZERO convention, else ``None``."""
    return _UNSIGNED_IMG_WRITE.get(np.dtype(dtype).newbyteorder("="))


def bitpix_to_dtype(bitpix: int) -> np.dtype:
    try:
        return BITPIX_TO_DTYPE[int(bitpix)]
    except KeyError as exc:
        raise ll.FitsStructError(211, f"invalid BITPIX {bitpix}") from exc


def dtype_to_bitpix(dtype) -> int:
    dt = np.dtype(dtype).newbyteorder("=")
    try:
        return DTYPE_TO_BITPIX[dt]
    except KeyError as exc:
        raise ll.FitsTypeError(410, f"dtype {dtype!r} has no FITS BITPIX") from exc


# Binary-table TFORM letter -> (numpy element dtype, is_complex). Repeat/width handled by caller.
_TFORM_BIN = {
    ord("L"): (np.dtype("u1"), False),  # logical (0/1)
    ord("X"): (np.dtype("u1"), False),  # bit -> one byte per bit element
    ord("B"): (np.dtype("u1"), False),
    ord("I"): (np.dtype("i2"), False),
    ord("J"): (np.dtype("i4"), False),
    ord("K"): (np.dtype("i8"), False),
    ord("E"): (np.dtype("f4"), False),
    ord("D"): (np.dtype("f8"), False),
    ord("C"): (np.dtype("f4"), True),
    ord("M"): (np.dtype("f8"), True),
}


def bin_elem_dtype(tform_char: int):
    """Return (numpy element dtype, is_complex) for a binary-table TFORM letter."""
    return _TFORM_BIN.get(tform_char, (np.dtype("f8"), False))
