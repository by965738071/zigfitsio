/** Stable ABI codes (mirror of `bindings/c/zigfitsio.h` / Python `lowlevel.py`). */

// ── Element datatype codes (ZfType) ──
export const ZF_UINT8 = 1;
export const ZF_INT8 = 2;
export const ZF_INT16 = 3;
export const ZF_UINT16 = 4;
export const ZF_INT32 = 5;
export const ZF_UINT32 = 6;
export const ZF_INT64 = 7;
export const ZF_UINT64 = 8;
export const ZF_FLOAT32 = 9;
export const ZF_FLOAT64 = 10;
export const ZF_BOOL = 11;
export const ZF_BIT = 12;
export const ZF_STRING = 13;
export const ZF_COMPLEX64 = 14;
export const ZF_COMPLEX128 = 15;

// ── Open modes ──
export const READONLY = 0;
export const READWRITE = 1;
export const CREATE = 2;

// ── HDU kinds ──
export const HDU_PRIMARY = 0;
export const HDU_IMAGE = 1;
export const HDU_ASCII_TABLE = 2;
export const HDU_BINARY_TABLE = 3;
export const HDU_RANDOM_GROUPS = 4;

// ── Table types ──
export const BINARY_TBL = 0;
export const ASCII_TBL = 1;
