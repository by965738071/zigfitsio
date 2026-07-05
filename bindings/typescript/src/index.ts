/**
 * zigfitsio — TypeScript/JavaScript bindings for the pure-Zig FITS 4.0 I/O
 * library (Bun via bun:ffi, Node ≥18 via koffi).
 *
 * Layering mirrors the Python bindings: `loader` finds the shared library,
 * `lowlevel` is a 1:1 typed mapping of `bindings/c/zigfitsio.h`, and this
 * module re-exports the high-level astropy-style API.
 */
export { open, fromBytes, getData, getHeader, getVal, writeTo, verify, Finding, type HDUData, type OpenMode } from "./convenience.js";
export { HDUList, type AnyHDU } from "./hdulist.js";
export {
  BaseHDU,
  ImageHDU,
  PrimaryHDU,
  CompImageHDU,
  type CompImageHDUOptions,
  type HDUKind,
  type HDUOptions,
  type ImageHDUOptions,
} from "./hdu.js";
export {
  AsciiTableHDU,
  BinTableHDU,
  Column,
  TableData,
  TableHDU,
  type ColumnData,
  type ColumnKind,
  type ColumnArray,
  type ColumnOptions,
  type ColumnShape,
  type ColumnValues,
  type ComplexColumn,
  type FromColumnsOptions,
  type NumericColumn,
  type Row,
  type RowCell,
  type StringColumn,
  type VlaColumn,
} from "./table.js";
export { Header, parseCard, parseCards, parseValueComment, type CardRec, type HeaderValue } from "./header.js";
export { FitsArray, asFitsArray, type ElementOf } from "./fitsarray.js";
export {
  tableFromArrays,
  imageFromArray,
  inferTform,
  type TableFromArraysOptions,
  type ImageFromArrayOptions,
} from "./factories.js";
export {
  FitsError,
  FitsIOError,
  FitsMemoryError,
  FitsHeaderError,
  KeywordNotFound,
  FitsStructError,
  FitsTableError,
  FitsTypeError,
  FitsOverflowError,
  FitsCompressError,
  FitsWcsError,
  NotSupportedError,
} from "./errors.js";
export { type Dtype, type TypedArray } from "./dtypes.js";
export { type OpenOptions, type Scaling, type ColInfo } from "./lowlevel/index.js";

export * as lowlevel from "./lowlevel/index.js";
export * as dtypes from "./dtypes.js";
export * as loader from "./loader.js";

import { version } from "./lowlevel/index.js";

/** The native library's version string (matches the npm package version). */
export const VERSION: string = version();
