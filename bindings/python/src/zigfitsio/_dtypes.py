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
