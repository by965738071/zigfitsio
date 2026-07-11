/**
 * Ergonomic factory helpers (Arrow-style construction) layered over the
 * astropy-shaped HDU classes. These never replace the classes — they just
 * remove boilerplate for the common "I have some TypedArrays" case.
 */
import { FitsTypeError } from "./errors.js";
import * as dt from "./dtypes.js";
import { FitsArray } from "./fitsarray.js";
import type { Header } from "./header.js";
import { ImageHDU } from "./hdu.js";
import { BinTableHDU, Column, type ColumnArray, type ColumnShape } from "./table.js";

const isTypedArray = (v: unknown): v is dt.TypedArray => ArrayBuffer.isView(v) && !(v instanceof DataView);

/** Longest string length in a `string[]` (min 1, for a `0A`-free width). */
function maxStrLen(rows: readonly string[]): number {
  let w = 1;
  for (const s of rows) w = Math.max(w, String(s ?? "").length);
  return w;
}

/**
 * Infer a binary-table `TFORM` from a column's JS array. Mirrors the dtype↔
 * code maps used elsewhere; the unsigned convention is emitted as the signed
 * letter (the write path adds the `TZEROn` offset). `Int8Array` and complex
 * values have no unambiguous single-array inference — pass an explicit
 * `Column` with a `C`/`M` (complex) or documented `i1` format instead.
 */
export function inferTform(name: string, array: ColumnArray): string {
  if (isTypedArray(array)) {
    const d = dt.dtypeOf(array);
    switch (d) {
      case "u1":
        return "B";
      case "i2":
        return "I";
      case "u2":
        return "I"; // unsigned via TZERO=32768
      case "i4":
        return "J";
      case "u4":
        return "J"; // unsigned via TZERO=2147483648
      case "i8":
        return "K";
      case "u8":
        return "K"; // unsigned via TZERO=2^63
      case "f4":
        return "E";
      case "f8":
        return "D";
      case "i1":
        throw new FitsTypeError(
          410,
          `column ${name}: Int8Array (i1) has no FITS binary column type; use an explicit Column`,
        );
      default:
        throw new FitsTypeError(410, `column ${name}: cannot infer a TFORM for dtype ${d}`);
    }
  }
  if (Array.isArray(array)) {
    if (array.length === 0) return "1J"; // empty → default int column
    const first = array[0];
    if (typeof first === "string") return `${maxStrLen(array as string[])}A`;
    if (typeof first === "boolean") return "L";
    if (isTypedArray(first) || Array.isArray(first)) {
      // A per-row array column: fixed repeat when every cell matches, else VLA.
      // Uniformly-empty cells (len0 === 0) become a VLA rather than a 0-repeat
      // fixed column — preserving "empty now, may grow" semantics.
      const cells = array as readonly (dt.TypedArray | readonly unknown[])[];
      const elem = isTypedArray(first) ? dt.dtypeOf(first) : "i8";
      const letter = tformLetterForElem(elem);
      const len0 = cells[0].length;
      const uniform = cells.every((c) => c.length === len0);
      return uniform && len0 > 0 ? `${len0}${letter}` : `1P${letter}`;
    }
    // Plain number/bigint scalars: exact safe ints → K, else D (matches the
    // write path's rounding + range-checking behavior).
    const plain = array as readonly (number | bigint)[];
    const allInts = plain.every((v) => typeof v === "bigint" || (typeof v === "number" && Number.isSafeInteger(v)));
    return allInts ? "K" : "D";
  }
  throw new FitsTypeError(410, `column ${name}: unsupported array kind for TFORM inference`);
}

function tformLetterForElem(elem: dt.Dtype): string {
  const letter = dt.ZF_TO_TFORM[dt.zfCode(elem)];
  return letter ?? "D";
}

export interface TableFromArraysOptions {
  /** EXTNAME for the table extension. */
  name?: string;
  /** Physical units per column (written as `TUNITn`). */
  units?: Record<string, string>;
  /**
   * Row count. When any column carries data it must equal that shared column
   * length (a mismatch throws), so this is only meaningful for a column-less
   * table — pass an empty `columns` record with `nrows` to reserve empty rows.
   */
  nrows?: number;
}

/**
 * Build a `BinTableHDU` from a `{ columnName: array }` record — the Arrow
 * `tableFromArrays` shape. `TFORM`s are inferred per `inferTform`; pass an
 * explicit `Column[]` via `BinTableHDU.fromColumns` when you need complex,
 * signed-byte, or hand-tuned formats.
 */
export function tableFromArrays<T extends ColumnShape = ColumnShape>(
  columns: Record<string, ColumnArray>,
  options: TableFromArraysOptions = {},
): BinTableHDU<T> {
  const units = options.units ?? {};
  const cols = Object.entries(columns).map(
    ([name, array]) => new Column(name, inferTform(name, array), { array, unit: units[name] }),
  );
  return BinTableHDU.fromColumns<T>(cols, { name: options.name, nrows: options.nrows });
}

export interface ImageFromArrayOptions {
  header?: Header;
  name?: string;
}

/**
 * Build an `ImageHDU` from a flat TypedArray (+ optional C-order shape) or an
 * existing `FitsArray`, skipping the explicit `new FitsArray(...)` wrap. Place
 * it first in an `HDUList` to serialize it as the primary HDU.
 *
 * Passing a `shape` alongside a `FitsArray` reshapes it (the underlying data is
 * reused); a shape whose product does not match the element count throws
 * `RangeError`.
 */
export function imageFromArray(
  data: dt.TypedArray | FitsArray,
  shape?: readonly number[],
  options: ImageFromArrayOptions = {},
): ImageHDU {
  let arr: FitsArray;
  if (data instanceof FitsArray) {
    arr = shape === undefined ? data : new FitsArray(data.data, shape);
  } else {
    arr = new FitsArray(data, shape);
  }
  return new ImageHDU({ data: arr, header: options.header, name: options.name });
}
