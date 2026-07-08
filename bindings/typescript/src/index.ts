/**
 * zigfitsio — TypeScript/JavaScript bindings for the pure-Zig FITS 4.0 I/O
 * library, shipped as a single WebAssembly module (Bun, Node ≥18, and browsers).
 *
 * Layering mirrors the Python bindings: `loader` locates/instantiates the wasm,
 * `lowlevel` is a 1:1 typed mapping of `bindings/c/zigfitsio.h`, and this module
 * re-exports the high-level astropy-style API.
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
export {
  Header,
  parseCard,
  parseCards,
  parseValueComment,
  wrapCommentary,
  type CardRec,
  type CommentaryView,
  type HeaderValue,
} from "./header.js";
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

import { ready as readyLowlevel, isReady, type ReadyOptions } from "./lowlevel/index.js";

export { isReady, type ReadyOptions };

/**
 * The native library's version string (matches the npm package version). Populated
 * synchronously on Node/Bun; empty in the browser until {@link ready} resolves. This is a
 * live binding cached when the wasm module is adopted on any init path.
 */
export { VERSION } from "./lowlevel/index.js";

/**
 * Ensure the WebAssembly module is loaded, then resolve. **Required once in the
 * browser** before any other API call; a no-op on Node and Bun, which load the
 * module synchronously at import. After it resolves, every call is synchronous.
 *
 * ```ts
 * await zf.ready();               // browser: fetches zigfitsio.wasm
 * await zf.ready({ wasm: bytes }); // or supply the bytes / a compiled module yourself
 * ```
 *
 * The `wasm` option only takes effect when the module has not already been loaded
 * (browser, or Node/Bun when the on-disk wasm was not found at import).
 */
export async function ready(options?: ReadyOptions): Promise<void> {
  await readyLowlevel(options);
}
