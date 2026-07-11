/**
 * Typed error hierarchy (mirror of Python `lowlevel.py:112-196`). Every
 * nonzero ABI status raises the mapped subclass via `check()`; `status`
 * carries the CFITSIO-compatible code.
 *
 * Divergence from Python: `KeywordNotFound` cannot also be a `KeyError`
 * (JS has no such class) — catch `FitsHeaderError`/`KeywordNotFound` instead.
 */

export class FitsError extends Error {
  readonly status: number;

  constructor(status: number, message = "") {
    const text = message || `FITS error (status ${status})`;
    super(`[${status}] ${text}`);
    this.status = status;
    this.name = new.target.name;
  }
}

export class FitsIOError extends FitsError {}
export class FitsMemoryError extends FitsError {}
export class FitsHeaderError extends FitsError {}
/** A header keyword does not exist (status 202). */
export class KeywordNotFound extends FitsHeaderError {}
export class FitsStructError extends FitsError {}
export class FitsTableError extends FitsError {}
export class FitsTypeError extends FitsError {}
export class FitsOverflowError extends FitsError {}
export class FitsCompressError extends FitsError {}
export class FitsWcsError extends FitsError {}
/** A documented fail-loud boundary (no data-lossy fallback exists). */
export class NotSupportedError extends FitsError {}

type FitsErrorClass = new (status: number, message?: string) => FitsError;

/** CFITSIO status code → error class (nearest mapping; default FitsError). */
export const CODE_TO_CLASS: ReadonlyMap<number, FitsErrorClass> = new Map<number, FitsErrorClass>([
  [104, FitsIOError], // null input pointer (defensive C-ABI guard)
  [113, FitsMemoryError],
  [106, FitsIOError],
  [107, FitsIOError],
  [108, FitsIOError],
  [112, FitsIOError],
  [116, FitsIOError],
  [202, KeywordNotFound],
  [204, FitsHeaderError],
  [205, FitsHeaderError],
  [207, FitsHeaderError],
  [208, FitsStructError],
  [210, FitsHeaderError],
  [211, FitsStructError],
  [212, FitsStructError],
  [213, FitsStructError],
  [225, FitsStructError],
  [235, FitsStructError],
  [219, FitsTableError],
  [261, FitsTableError],
  [262, FitsTableError],
  [263, FitsTableError],
  [264, FitsTableError],
  [307, FitsTableError],
  [308, FitsTableError],
  [410, FitsTypeError],
  [412, FitsOverflowError],
  [413, FitsCompressError],
  [414, FitsCompressError],
  [502, FitsWcsError],
  [503, FitsWcsError],
  [504, FitsWcsError],
]);
