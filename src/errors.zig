//! Error sets for `zigfitsio` (FR-ERR-1, FR-ERR-2, GC-4).
//!
//! Errors are **narrow, area-scoped sets** that compose with `||`. No public function ever
//! returns `anyerror`; each declares the union of exactly the sets it can produce. There is
//! **no integer status parameter and no inherited-status idiom** — `try` and error
//! propagation provide fail-fast behavior naturally (FR-ERR-2). `std.mem.Allocator.Error`
//! is folded into the umbrella `Error` wherever allocation occurs.
const std = @import("std");

/// Low-level byte source/sink and block-structure failures (§8).
pub const IoError = error{
    EndOfStream,
    ReadFailed,
    WriteFailed,
    SeekFailed,
    Unseekable,
    NotWritable,
    DeviceFull,
    BlockMisaligned,
};

/// Header/card syntax failures (§9).
pub const HeaderError = error{
    NonAsciiInHeader,
    BadKeywordName,
    BadValueSyntax,
    UnterminatedString,
    MissingEnd,
    BadContinue,
    CardOverflow,
};

/// Keyword value lookup/typing failures (§9.2). The three-way null/empty/undefined
/// distinction of FR-HDR-3 surfaces here: an absent keyword is `KeywordNotFound`; a present
/// indicator with a blank value field is `ValueUndefined`.
pub const ValueError = error{
    WrongValueType,
    ValueUndefined,
    KeywordNotFound,
};

/// HDU structural failures: mandatory keyword presence/order/type, bad geometry (§10).
pub const StructError = error{
    MissingRequiredKeyword,
    KeywordOrder,
    BadBitpix,
    BadNaxis,
    BadDimensions,
    WrongHduType,
    BadExtension,
};

/// Table and column failures, including the VLA heap (§12–§14).
pub const TableError = error{
    NoSuchColumn,
    AmbiguousColumn,
    BadTform,
    BadTdim,
    BadTbcol,
    RowOutOfRange,
    CellOutOfRange,
    BadDescriptor,
    HeapOverflow,
};

/// Numeric-conversion failures, per the single conversion policy (§6, FR-CONV-1/2).
pub const ConvError = error{
    Overflow,
    PrecisionLoss,
    NotRepresentable,
    NanToInt,
};

/// Checksum verification mismatches (§16, FR-SUM-2).
pub const ChecksumError = error{
    ChecksumMismatch,
    DatasumMismatch,
};

/// Tiled-compression failures (§17). An unimplemented codec is `UnsupportedCodec`, never a
/// silent mis-read (NFR-INTEROP-1).
pub const CompressError = error{
    UnsupportedCodec,
    CorruptTile,
    BadTiling,
    DataConstraintViolated,
};

/// World-coordinate-system failures (§18).
pub const WcsError = error{
    BadWcs,
    UnsupportedProjection,
    NonInvertible,
};

/// Resource-limit guard failures (§7.2, NFR-SAFE-1). A declared size exceeded the
/// configured `Limits` or the actual stream length, or checked arithmetic overflowed.
pub const LimitError = error{LimitExceeded};

/// The umbrella set, for callers who want one catch-all. Library functions still declare
/// the narrowest set they actually produce (FR-ERR-1).
pub const Error = IoError || HeaderError || ValueError || StructError || TableError ||
    ConvError || ChecksumError || CompressError || WcsError || LimitError ||
    std.mem.Allocator.Error;

/// Map a `zigfitsio` error to the nearest CFITSIO numeric status code, for tooling that
/// must emit compatible codes (FR-ERR-4). This is a pure lookup, not a control-flow
/// mechanism. Codes follow `fitsio.h`; where no exact CFITSIO equivalent exists the nearest
/// documented code is used (e.g. `MissingEnd` → 210 `NO_END`).
pub fn cfitsioStatus(err: Error) c_int {
    return switch (err) {
        // Allocation
        error.OutOfMemory => 113, // MEMORY_ALLOCATION
        // I/O
        error.EndOfStream => 107, // END_OF_FILE
        error.ReadFailed => 108, // READ_ERROR
        error.WriteFailed => 106, // WRITE_ERROR
        error.DeviceFull => 106, // WRITE_ERROR
        error.SeekFailed => 116, // SEEK_ERROR
        error.Unseekable => 116, // SEEK_ERROR
        error.NotWritable => 112, // READONLY_FILE
        error.BlockMisaligned => 116, // SEEK_ERROR
        // Header syntax
        error.NonAsciiInHeader => 207, // BAD_KEYCHAR
        error.BadKeywordName => 207, // BAD_KEYCHAR
        error.BadValueSyntax => 207, // BAD_KEYCHAR
        error.UnterminatedString => 205, // NO_QUOTE
        error.MissingEnd => 210, // NO_END
        error.BadContinue => 207, // BAD_KEYCHAR
        error.CardOverflow => 207, // BAD_KEYCHAR
        // Value typing
        error.WrongValueType => 410, // BAD_DATATYPE
        error.ValueUndefined => 204, // VALUE_UNDEFINED
        error.KeywordNotFound => 202, // KEY_NO_EXIST
        // Structure
        error.MissingRequiredKeyword => 225, // NO_XTENSION (representative mandatory-kw miss)
        error.KeywordOrder => 208, // BAD_ORDER
        error.BadBitpix => 211, // BAD_BITPIX
        error.BadNaxis => 212, // BAD_NAXIS
        error.BadDimensions => 213, // BAD_NAXES
        error.WrongHduType => 235, // NOT_IMAGE
        error.BadExtension => 225, // NO_XTENSION
        // Tables
        error.NoSuchColumn => 219, // COL_NOT_FOUND
        error.AmbiguousColumn => 219, // COL_NOT_FOUND
        error.BadTform => 261, // BAD_TFORM
        error.BadTdim => 263, // BAD_TDIM
        error.BadTbcol => 262, // BAD_TFORM_DTYPE (nearest)
        error.RowOutOfRange => 307, // BAD_ROW_NUM
        error.CellOutOfRange => 308, // BAD_ELEM_NUM
        error.BadDescriptor => 264, // BAD_HEAP_PTR
        error.HeapOverflow => 264, // BAD_HEAP_PTR
        // Conversion
        error.Overflow => 412, // OVERFLOW_ERR
        error.PrecisionLoss => 412, // OVERFLOW_ERR (nearest)
        error.NotRepresentable => 412, // OVERFLOW_ERR (nearest)
        error.NanToInt => 412, // OVERFLOW_ERR (nearest)
        // Checksum (CFITSIO reports these via verify flags, not a status code)
        error.ChecksumMismatch => 412,
        error.DatasumMismatch => 412,
        // Compression
        error.UnsupportedCodec => 413, // DATA_COMPRESSION_ERR
        error.CorruptTile => 414, // DATA_DECOMPRESSION_ERR
        error.BadTiling => 413, // DATA_COMPRESSION_ERR
        error.DataConstraintViolated => 413, // DATA_COMPRESSION_ERR
        // WCS
        error.BadWcs => 502, // BAD_WCS_VAL
        error.UnsupportedProjection => 504, // BAD_WCS_PROJ
        error.NonInvertible => 503, // WCS_ERROR
        // Limits
        error.LimitExceeded => 412, // OVERFLOW_ERR (nearest: declared size too large)
    };
}

const testing = std.testing;

test "error sets compose with || into Error" {
    // A signature can declare a narrow union without anyerror.
    const Narrow = HeaderError || ValueError;
    const e: Narrow = error.MissingEnd;
    const wide: Error = e; // narrow coerces into the umbrella
    try testing.expectEqual(Error.MissingEnd, wide);
}

test "cfitsioStatus maps representative values" {
    try testing.expectEqual(@as(c_int, 210), cfitsioStatus(error.MissingEnd));
    try testing.expectEqual(@as(c_int, 202), cfitsioStatus(error.KeywordNotFound));
    try testing.expectEqual(@as(c_int, 113), cfitsioStatus(error.OutOfMemory));
    try testing.expectEqual(@as(c_int, 112), cfitsioStatus(error.NotWritable));
    try testing.expectEqual(@as(c_int, 211), cfitsioStatus(error.BadBitpix));
}
