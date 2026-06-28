//! Version string and stable per-error message text (FR-UTL-3, §4.3, §19.1).
const std = @import("std");
const errors = @import("errors.zig");

/// The library version (mirrors `build.zig.zon` and `root.version`).
pub const version_string = "0.1.0";

/// Return the library version string (FR-UTL-3).
pub fn version() []const u8 {
    return version_string;
}

/// Return a stable, human-readable message for every `Error` value (FR-UTL-3). The
/// exhaustive switch guarantees a non-empty message per error.
pub fn errorText(err: errors.Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        // I/O
        error.EndOfStream => "unexpected end of stream",
        error.ReadFailed => "device read failed",
        error.WriteFailed => "device write failed",
        error.SeekFailed => "device seek failed",
        error.Unseekable => "device is not seekable",
        error.NotWritable => "device is read-only",
        error.DeviceFull => "device is full",
        error.BlockMisaligned => "access is not 2880-byte block aligned",
        // Header syntax
        error.NonAsciiInHeader => "non-printable-ASCII byte in header card",
        error.BadKeywordName => "malformed keyword name",
        error.BadValueSyntax => "malformed keyword value",
        error.UnterminatedString => "unterminated quoted string value",
        error.MissingEnd => "header has no END card",
        error.BadContinue => "malformed CONTINUE long-string convention",
        error.CardOverflow => "value does not fit in an 80-character card",
        // Value typing
        error.WrongValueType => "keyword value has a different type than requested",
        error.ValueUndefined => "keyword value is undefined (blank value field)",
        error.KeywordNotFound => "keyword not found",
        // Structure
        error.MissingRequiredKeyword => "a mandatory keyword is missing",
        error.KeywordOrder => "mandatory keywords are out of order",
        error.BadBitpix => "invalid BITPIX value",
        error.BadNaxis => "invalid NAXIS value",
        error.BadDimensions => "invalid or oversized dimensions",
        error.WrongHduType => "operation invalid for this HDU type",
        error.BadExtension => "malformed extension header",
        // Tables
        error.NoSuchColumn => "no column matches the given name/number",
        error.AmbiguousColumn => "column name is ambiguous",
        error.BadTform => "malformed TFORM column format",
        error.BadTdim => "malformed TDIM dimension specification",
        error.BadTbcol => "malformed TBCOL/heap geometry",
        error.RowOutOfRange => "row index out of range",
        error.CellOutOfRange => "cell index out of range",
        error.BadDescriptor => "invalid variable-length array descriptor",
        error.HeapOverflow => "heap access out of bounds",
        // Conversion
        error.Overflow => "value out of range for the destination type",
        error.PrecisionLoss => "conversion would lose precision",
        error.NotRepresentable => "value is not representable in the destination type",
        error.NanToInt => "cannot convert NaN to an integer",
        // Checksum
        error.ChecksumMismatch => "CHECKSUM does not match",
        error.DatasumMismatch => "DATASUM does not match",
        // Compression
        error.UnsupportedCodec => "unsupported tile compression codec",
        error.CorruptTile => "corrupt compressed tile",
        error.BadTiling => "invalid tiling geometry",
        error.DataConstraintViolated => "data violates the codec's constraints",
        // WCS
        error.BadWcs => "invalid WCS keyword set",
        error.UnsupportedProjection => "unsupported WCS projection",
        error.NonInvertible => "WCS transform is not invertible",
        // Limits
        error.LimitExceeded => "a declared size exceeded the configured limit",
    };
}

const testing = std.testing;

test "version is non-empty and matches the literal" {
    try testing.expectEqualStrings("0.1.0", version());
}

test "errorText is non-empty for every error value" {
    // Exhaustively touch a representative set across all areas; the switch above is total,
    // so any missing arm is a compile error (the real guarantee).
    inline for (.{
        error.OutOfMemory,        error.EndOfStream,  error.MissingEnd,
        error.KeywordNotFound,    error.BadBitpix,    error.NoSuchColumn,
        error.Overflow,           error.NanToInt,     error.ChecksumMismatch,
        error.UnsupportedCodec,   error.BadWcs,       error.LimitExceeded,
        error.ValueUndefined,     error.BadDescriptor,
    }) |e| {
        try testing.expect(errorText(e).len > 0);
    }
}
