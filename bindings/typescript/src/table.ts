/**
 * Table HDUs (method-for-method port of the Python `core.py` table layer).
 *
 * Data model: columnar. `TableData` maps column name → `ColumnData` where
 * `values` is a flat TypedArray (numeric; `nrows*repeat` elements, complex
 * interleaved re/im), a `string[]`, or a per-row array of TypedArrays (VLA).
 */
import { FitsOverflowError, FitsTableError, FitsTypeError, NotSupportedError } from "./errors.js";
import * as ll from "./lowlevel/index.js";
import * as dt from "./dtypes.js";
import { BaseHDU, DATA_UNSET, writeConventionOffset, writeKeyValue, isTableStructuralKeyword, type HDUOptions } from "./hdu.js";
import type { ElementOf } from "./fitsarray.js";
import { decOut, enc, fnv1a64, viewBytes } from "./util.js";

// ════════════════════════════════════════════════════════════════════════
// Data model
// ════════════════════════════════════════════════════════════════════════

export type ColumnKind = "numeric" | "string" | "complex" | "vla";

/** A fixed-width or scaled numeric column: a flat `nrows*repeat` TypedArray. */
export interface NumericColumn {
  kind: "numeric";
  dtype: dt.Dtype;
  repeat: number;
  values: dt.TypedArray;
}

/** A complex column: interleaved re/im float pairs (2 floats per element). */
export interface ComplexColumn {
  kind: "complex";
  /** `c8` (Float32) or `c16` (Float64). */
  dtype: dt.Dtype;
  repeat: number;
  values: Float32Array | Float64Array;
}

/** A character column: one fixed-width string per row. */
export interface StringColumn {
  kind: "string";
  dtype: dt.Dtype;
  /** The field width in characters. */
  repeat: number;
  values: string[];
}

/** A variable-length-array column: one TypedArray cell per row. */
export interface VlaColumn {
  kind: "vla";
  dtype: dt.Dtype;
  repeat: number;
  values: dt.TypedArray[];
}

/**
 * One materialized table column. Discriminated on `kind`, so a
 * `switch (col.kind)` narrows `values` to the exact array type.
 */
export type ColumnData = NumericColumn | ComplexColumn | StringColumn | VlaColumn;

/** The value array a column exposes, by kind. */
export type ColumnValues = dt.TypedArray | string[] | dt.TypedArray[];

/**
 * A column-name → value-array shape, used as the optional type parameter of
 * `TableData<T>` (and `HDUList.table<T>()`) for typed column/row reads. This
 * is a compile-time contract only — the runtime never checks it.
 */
export type ColumnShape = Record<string, ColumnValues>;

/**
 * The element yielded for one column cell in a `Row<T>` (see `TableData.row`).
 * A numeric column resolves to `ElementOf<V> | V` — a scalar for a repeat-1
 * column, or a (zero-copy) slice of the same TypedArray type for a vector
 * column — a runtime distinction TypeScript cannot see, so both are offered.
 */
export type RowCell<V> = V extends string[]
  ? string
  : V extends (infer E extends dt.TypedArray)[]
    ? E
    : V extends dt.TypedArray
      ? ElementOf<V> | V
      : never;

/**
 * One row as a plain object keyed by column name. Numeric cells are a scalar
 * when the column's repeat is 1, else a (zero-copy) TypedArray slice — a
 * runtime distinction TypeScript cannot see, hence the `ElementOf<V> | V`
 * union. For a statically known shape, prefer the column accessors
 * (`numeric`/`strings`/`vla`/`complex`).
 */
export type Row<T extends ColumnShape = ColumnShape> = { [K in keyof T]: RowCell<T[K]> };

/** Reject names that collapse onto the same high-level lookup key. */
function assertUniqueColumnNames(names: readonly string[]): void {
  const seen = new Set<string>();
  for (let i = 0; i < names.length; i++) {
    const name = names[i].trim() || `col${i + 1}`;
    if (seen.has(name)) throw new FitsTableError(219, `column name is ambiguous: ${name}`);
    seen.add(name);
  }
}

export class TableData<T extends ColumnShape = ColumnShape> implements Iterable<Row<T>> {
  readonly names: readonly string[];
  readonly columns: ReadonlyMap<string, ColumnData>;
  readonly nrows: number;

  constructor(names: readonly string[], columns: ReadonlyMap<string, ColumnData>, nrows: number) {
    assertUniqueColumnNames(names);
    this.names = names;
    this.columns = columns;
    this.nrows = nrows;
  }

  /** Row count (alias of `nrows`, matching Arrow's `Table.numRows`). */
  get numRows(): number {
    return this.nrows;
  }

  /** Column count (matching Arrow's `Table.numCols`). */
  get numCols(): number {
    return this.names.length;
  }

  column(name: string): ColumnData {
    const c = this.columns.get(name);
    if (c === undefined) throw new FitsTableError(302, `no such column: ${name}`);
    return c;
  }

  /** The raw values of one column (typed by the column shape `T` when known). */
  get<K extends keyof T & string>(name: K): T[K];
  get(name: string): ColumnValues;
  get(name: string): ColumnValues {
    return this.column(name).values;
  }

  private _typed<C extends ColumnData>(name: string, kind: C["kind"], expected: string): C["values"] {
    const c = this.column(name);
    if (c.kind !== kind) {
      throw new FitsTypeError(410, `column ${name} is ${c.kind}, expected ${expected}`);
    }
    return (c as C).values;
  }

  /** A fixed-width/scaled numeric column's flat TypedArray (throws otherwise). */
  numeric(name: string): dt.TypedArray {
    return this._typed<NumericColumn>(name, "numeric", "numeric");
  }

  /** A character column's per-row strings (throws otherwise). */
  strings(name: string): string[] {
    return this._typed<StringColumn>(name, "string", "string");
  }

  /** A variable-length-array column's per-row TypedArrays (throws otherwise). */
  vla(name: string): dt.TypedArray[] {
    return this._typed<VlaColumn>(name, "vla", "vla");
  }

  /** A complex column's interleaved re/im floats (throws otherwise). */
  complex(name: string): Float32Array | Float64Array {
    return this._typed<ComplexColumn>(name, "complex", "complex");
  }

  /** One cell of a column for a 0-based row (scalar, slice, string, or VLA). */
  private _cell(cd: ColumnData, r: number): number | bigint | string | dt.TypedArray {
    if (cd.kind === "string") return cd.values[r];
    if (cd.kind === "vla") return cd.values[r];
    if (cd.kind === "complex") {
      const w = cd.repeat * 2; // 2 floats per complex element
      return cd.values.subarray(r * w, (r + 1) * w);
    }
    // numeric: scalar when repeat === 1, else a zero-copy row slice.
    if (cd.repeat === 1) return cd.values[r];
    return cd.values.subarray(r * cd.repeat, (r + 1) * cd.repeat) as dt.TypedArray;
  }

  /**
   * One row as a plain object keyed by column name (0-based). Numeric cells
   * are scalars for repeat-1 columns and (zero-copy) TypedArray slices
   * otherwise; mutating a returned slice mutates the column.
   */
  row(i: number): Row<T> {
    if (i < 0 || i >= this.nrows) throw new RangeError(`row ${i} out of range (${this.nrows} rows)`);
    const out: Record<string, unknown> = {};
    for (const name of this.names) out[name] = this._cell(this.column(name), i);
    return out as Row<T>;
  }

  /** Lazily yield every row as a plain object (see `row`). */
  *rows(): IterableIterator<Row<T>> {
    for (let i = 0; i < this.nrows; i++) yield this.row(i);
  }

  /** Iterating a `TableData` yields rows (matching Arrow's `Table`). */
  [Symbol.iterator](): IterableIterator<Row<T>> {
    return this.rows();
  }

  /** Every row as an array of plain objects. */
  toArray(): Row<T>[] {
    return [...this.rows()];
  }
}

// ════════════════════════════════════════════════════════════════════════
// Column builder (for writing tables)
// ════════════════════════════════════════════════════════════════════════

export type ColumnArray =
  | dt.TypedArray
  | string[]
  | boolean[]
  | number[]
  | bigint[]
  | (dt.TypedArray | number[] | bigint[])[];

export interface ColumnOptions {
  array?: ColumnArray | null;
  unit?: string;
}

/** A table column specification (name + FITS `format` + optional data/unit). */
export class Column {
  readonly name: string;
  readonly format: string;
  readonly unit: string | null;
  readonly array: ColumnArray | null;

  constructor(name: string, format: string, options: ColumnOptions = {}) {
    this.name = name;
    this.format = format;
    this.unit = options.unit ?? null;
    this.array = options.array ?? null;
  }
}

// ── format helpers ──

const firstLetter = (fmt: string): string => {
  for (const ch of fmt) if (/[A-Z]/.test(ch)) return ch;
  return "";
};

const formatDigits = (fmt: string): string => fmt.replace(/[^0-9]/g, "");

/** (element dtype, is_complex) for a VLA TFORM like '1PJ' / '1QE(max)'. */
function vlaElemDtype(fmt: string): { dtype: dt.Dtype; isComplex: boolean } {
  const marker = fmt.includes("P") ? "P" : "Q";
  const after = fmt.slice(fmt.indexOf(marker) + 1);
  const letter = firstLetter(after);
  return letter ? dt.binElemDtype(letter) : { dtype: "f8", isComplex: false };
}

/**
 * Rebuild a binary-table TFORM string from column metadata (for
 * reconstructing an attached table on copy). The unsigned-integer convention
 * is reproducible; fractional/other scaling is not reproducible value-only.
 */
export function tformOf(info: ll.ColInfo): string {
  if (info.typecode === ll.ZF_STRING) return `${Math.max(info.width, 1)}A`;
  const isUnsigned = info.tscal === 1 && (info.tzero === 32768 || info.tzero === 2147483648 || info.tzero === 9223372036854775808);
  if ((info.tscal !== 1 || info.tzero !== 0) && !isUnsigned) {
    throw new NotSupportedError(
      410,
      "cannot reconstruct a scaled table column into a new table; copy the file through the " +
        "raw-passthrough path (writeTo without checksum on a freshly opened file)",
    );
  }
  const letter = dt.ZF_TO_TFORM[info.typecode];
  if (letter === undefined) throw new NotSupportedError(410, `cannot reconstruct TFORM for ZfType ${info.typecode}`);
  if (info.isVla) return `1P${letter}`;
  return `${info.repeat}${letter}`;
}

/**
 * Rebuild an ASCII-table TFORM (`Iw` / `Ew.d` / `Aw`) from column metadata.
 * ASCII TFORMs carry an explicit width, so a copied ASCII table needs these
 * rather than binary `1J`-style formats.
 */
export function asciiTformOf(info: ll.ColInfo): string {
  const w = Math.max(info.width, 1);
  if (info.typecode === ll.ZF_STRING) return `A${w}`;
  if (info.typecode === ll.ZF_FLOAT32 || info.typecode === ll.ZF_FLOAT64) {
    return `E${w}.${Math.max(w - 7, 1)}`; // leave room for sign, decimal point, and E±dd exponent
  }
  return `I${w}`; // integer column of any width
}

/**
 * Synthesize a binary-table TFORM from materialized column data (port of
 * `core.py _tform_from_dtype`, driven by the ColumnData discriminant instead
 * of a numpy dtype). Used to format a column that has no matching file column
 * (a reassigned TableData that added or retyped a column) so its values are
 * never truncated to a stale TFORM.
 */
function tformFromColumnData(cd: ColumnData): string {
  if (cd.kind === "string") return `${Math.max(cd.repeat, 1)}A`; // repeat is the field width
  if (cd.kind === "complex") return `${cd.repeat}${cd.dtype === "c8" ? "C" : "M"}`;
  const letter = dt.DTYPE_TO_TFORM[cd.dtype];
  if (letter === undefined) throw new FitsTypeError(410, `cannot synthesize a table TFORM for dtype ${cd.dtype}`);
  if (cd.kind === "vla") return `1P${letter}`; // a VlaColumn carries its element dtype
  return `${cd.repeat}${letter}`;
}

/** (repeat, uppercase type letter) for a scalar/vector binary TFORM like '1J' or '8A'. */
function tformRepeatLetter(fmt: string): [number, string] {
  const s = fmt.trim().toUpperCase();
  let i = 0;
  while (i < s.length && s[i] >= "0" && s[i] <= "9") i++;
  return [parseInt(s.slice(0, i) || "1", 10), s.slice(i, i + 1)];
}

/**
 * True when a file column's stored TFORM `have` still faithfully represents a
 * column whose data synthesizes to `synth` — same repeat and same element
 * dtype. Distinct letters that decode to the same element dtype (L/X/B all
 * read as u1) are interchangeable, so a logical or bit column keeps its own
 * 'L'/'X' letter instead of being flattened to the generic 'B'. Strings ('A',
 * whose width lives in the repeat) only match letter-for-letter.
 */
function tformInterchangeable(have: string, synth: string): boolean {
  const [rh, lh] = tformRepeatLetter(have);
  const [rs, ls] = tformRepeatLetter(synth);
  if (rh !== rs) return false;
  if (lh === ls) return true;
  if (lh === "A" || ls === "A") return false;
  const dh = dt.binElemDtype(lh);
  const ds = dt.binElemDtype(ls);
  return dh.dtype === ds.dtype && dh.isComplex === ds.isComplex;
}

/**
 * Choose a binary-table TFORM for a TableData column on write-back/copy (port
 * of `core.py _binary_tform_for`). Reuse the same-named file column's stored
 * TFORM when it still describes the data — the only way to reproduce VLA,
 * unsigned, logical/bit, or exact-width string columns — otherwise synthesize
 * one from the column data so a new or retyped column is never written under
 * a stale (truncating) format. `info` is the matching file column (or
 * undefined when the column has no counterpart).
 */
function binaryTformFor(info: ll.ColInfo | undefined, cd: ColumnData): string {
  if (info !== undefined && (info.isVla || cd.kind === "vla")) {
    return tformOf(info); // VLA: only the file descriptor can describe it
  }
  const synth = tformFromColumnData(cd);
  if (info === undefined) return synth; // added/renamed column with no file counterpart
  const have = tformOf(info); // a scaled column throws here (unreconstructable) — preserved as today
  return tformInterchangeable(have, synth) ? have : synth;
}

// ── write-side array normalization ──

const isTypedArray = (v: unknown): v is dt.TypedArray => ArrayBuffer.isView(v) && !(v instanceof DataView);

// Keep any one host↔Wasm staging allocation comfortably below wasm32's address-space limit.
// A row containing more than this budget is still transferred alone (provided it is < 4 GiB),
// because the packed ABI deliberately chunks on row boundaries.
const WASM_STAGE_BUDGET = 64 * 1024 * 1024;
const MAX_LAYOUT_ROWS_PER_CALL = Math.floor(WASM_STAGE_BUDGET / BigUint64Array.BYTES_PER_ELEMENT) - 1;
const MAX_WASM_BUFFER_BYTES = 0x1_0000_0000n;
const MAX_SAFE_BIGINT = BigInt(Number.MAX_SAFE_INTEGER);
const MAX_U64 = 0xffff_ffff_ffff_ffffn;
// `values` is a normal JS Array and `offsets` needs one extra entry.
const MAX_MATERIALIZED_ROWS = 0xffff_fffen;

function safeMaterializedRows(value: bigint, what = "table row count"): number {
  if (value < 0n || value > MAX_MATERIALIZED_ROWS) {
    throw new FitsOverflowError(412, `${what} ${value} cannot be materialized as a JavaScript array`);
  }
  return Number(value);
}

function safeSlotCount(value: bigint, scalarBytes: number, what: string): number {
  if (value < 0n || value > MAX_SAFE_BIGINT || value * BigInt(scalarBytes) > MAX_SAFE_BIGINT) {
    throw new FitsOverflowError(412, `${what} ${value} is too large to materialize as a TypedArray`);
  }
  return Number(value);
}

function requireWasmBufferSize(slots: bigint, scalarBytes: number, what: string): void {
  const bytes = slots * BigInt(scalarBytes);
  if (bytes < 0n || bytes >= MAX_WASM_BUFFER_BYTES) {
    throw new FitsOverflowError(412, `${what} requires ${bytes} bytes, which cannot be staged in wasm32`);
  }
}

function allocTransferArray(dtype: dt.Dtype, slots: number, what: string): dt.TypedArray {
  try {
    return dt.allocDtype(dtype, slots);
  } catch (e) {
    if (e instanceof RangeError) {
      throw new FitsOverflowError(412, `${what} with ${slots} scalar slots is too large to allocate`);
    }
    throw e;
  }
}

/** Row ranges whose offsets and payload can each be staged in bounded wasm32 buffers. */
function* vlaTransferChunks(
  offsets: BigUint64Array,
  scalarBytes: number,
): IterableIterator<{ first: number; end: number; firstSlot: bigint; endSlot: bigint }> {
  const nrows = offsets.length - 1;
  const budgetSlots = BigInt(Math.max(Math.floor(WASM_STAGE_BUDGET / scalarBytes), 1));
  let first = 0;
  while (first < nrows) {
    const firstSlot = offsets[first];
    const rowLimit = Math.min(first + MAX_LAYOUT_ROWS_PER_CALL, nrows);
    let end = first + 1; // a single large cell is indivisible; transfer it alone
    while (end < rowLimit && offsets[end + 1] - firstSlot <= budgetSlots) end++;
    const endSlot = offsets[end];
    requireWasmBufferSize(endSlot - firstSlot, scalarBytes, "packed VLA row range");
    yield { first, end, firstSlot, endSlot };
    first = end;
  }
}

/** Measure all VLA cells through bounded layout calls and rebase them to one global offset array. */
function readVlaLayout(t: bigint, col: number, nrows: number): BigUint64Array {
  const offsets = new BigUint64Array(nrows + 1);
  if (nrows === 0) {
    const total = ll.outU64();
    ll.check(ll.lib.zf_read_col_vla_layout(t, col, 1n, 0n, offsets, offsets.length, total));
    if (offsets[0] !== 0n || total[0] !== 0n) {
      throw new FitsTableError(264, "packed VLA layout for an empty row range was not [0]");
    }
    return offsets;
  }

  let base = 0n;
  for (let first = 0; first < nrows; first += MAX_LAYOUT_ROWS_PER_CALL) {
    const end = Math.min(first + MAX_LAYOUT_ROWS_PER_CALL, nrows);
    const local = offsets.subarray(first, end + 1);
    const total = ll.outU64();
    ll.check(
      ll.lib.zf_read_col_vla_layout(
        t,
        col,
        BigInt(first + 1),
        BigInt(end - first),
        local,
        local.length,
        total,
      ),
    );
    if (local[0] !== 0n || local[local.length - 1] !== total[0]) {
      throw new FitsTableError(264, "packed VLA layout returned inconsistent terminal offsets");
    }
    let previous = 0n;
    for (let k = 1; k < local.length; k++) {
      const value = local[k];
      if (value < previous) throw new FitsTableError(264, "packed VLA layout offsets are not monotonic");
      if (value > MAX_U64 - base) throw new FitsOverflowError(412, "packed VLA layout total exceeds uint64");
      previous = value;
      local[k] = base + value;
    }
    local[0] = base;
    base += total[0];
  }
  return offsets;
}

/**
 * A plain JS value destined for an int64 slot: rounds (the same net behavior
 * as Python routing floats through the library's float→int conversion) and
 * fails loud on non-finite/out-of-range instead of BigInt64Array wrap-around.
 */
function numToBigInt(v: number | bigint): bigint {
  if (typeof v === "bigint") return v;
  if (typeof v !== "number") throw new FitsTypeError(410, `non-numeric value ${JSON.stringify(v)} in a numeric column`);
  const r = Math.round(v);
  if (!Number.isFinite(r) || r < -(2 ** 63) || r >= 2 ** 63) {
    throw new FitsOverflowError(412, `integer column value ${v} out of signed-64-bit range`);
  }
  return BigInt(r);
}

function numToNumber(v: number | bigint): number {
  if (typeof v !== "number" && typeof v !== "bigint") {
    throw new FitsTypeError(410, `non-numeric value ${JSON.stringify(v)} in a numeric column`);
  }
  return Number(v);
}

/** Convert a per-cell/plain JS array to a TypedArray of `elem`. */
function toTypedArray(values: readonly (number | bigint)[] | dt.TypedArray, elem: dt.Dtype): dt.TypedArray {
  if (isTypedArray(values)) return values;
  const out = dt.allocDtype(elem, values.length);
  const big = dt.usesBigInt(elem);
  for (let i = 0; i < values.length; i++) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (out as any)[i] = big ? numToBigInt(values[i]) : numToNumber(values[i]);
  }
  return out;
}

/** Element-wise cast of a TypedArray/plain array to exactly `elem` (bigint-safe). */
function castTypedArray(values: readonly (number | bigint)[] | dt.TypedArray, elem: dt.Dtype): dt.TypedArray {
  const src = toTypedArray(values, elem);
  if (dt.dtypeOf(src) === elem) return src;
  const out = dt.allocDtype(elem, src.length);
  const big = dt.usesBigInt(elem);
  for (let k = 0; k < src.length; k++) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (out as any)[k] = big ? numToBigInt(src[k]) : Number(src[k]);
  }
  return out;
}

/** Rows represented by a column's array, given its format. */
function colRowCount(col: Column): number {
  const arr = col.array;
  if (arr === null) return 0;
  const fmt = col.format.trim().toUpperCase();
  if (fmt.includes("P") || fmt.includes("Q")) return arr.length; // VLA: one cell per row
  if (fmt.includes("A")) return arr.length; // string rows
  // One entry per row only for rows-of-arrays / boolean rows (mirroring
  // writeColumn's dispatch); a flat plain numeric array must fall through to
  // the per-row division like a TypedArray.
  if (Array.isArray(arr) && (arr.length === 0 || Array.isArray(arr[0]) || isTypedArray(arr[0]) || typeof arr[0] === "boolean")) {
    return arr.length;
  }
  // A binary repeat is the LEADING digits ("3J"); ASCII formats are
  // letter-first ("I6", "F12.4") with width digits and always one per row.
  const m = fmt.match(/^(\d+)/);
  const repeat = m ? Math.max(parseInt(m[1], 10), 1) : 1;
  const perRow = dt.binElemDtype(firstLetter(fmt)).isComplex ? repeat * 2 : repeat;
  if (arr.length % perRow !== 0) {
    throw new RangeError(
      `column ${col.name}: array length ${arr.length} is not a multiple of the ${perRow} elements per '${col.format}' row`,
    );
  }
  return arr.length / perRow;
}

/** Total heap bytes to reserve (PCOUNT) for the VLA columns of a to-be-written table. */
function vlaHeapBytes(cols: readonly Column[]): number {
  let total = 0;
  for (const col of cols) {
    const fmt = col.format.trim().toUpperCase();
    if ((fmt.includes("P") || fmt.includes("Q")) && col.array !== null) {
      const { dtype } = vlaElemDtype(fmt);
      const esize = dt.itemBytes(dtype);
      for (const cell of col.array as readonly (dt.TypedArray | readonly number[])[]) {
        total += cell.length * esize;
      }
    }
  }
  return total;
}

/** TZERO for an unsigned column stored under a matching signed TFORM (I/J/K), else null. */
function unsignedColTzeroOf(col: Column): number | null {
  if (col.array === null || !isTypedArray(col.array)) return null;
  return dt.unsignedColTzero(dt.dtypeOf(col.array), firstLetter(col.format.trim().toUpperCase()));
}

// ── fingerprints ──

const FNV_PRIME = 0x100000001b3n;
const U64_MASK = 0xffffffffffffffffn;

const mix = (h: bigint, v: bigint): bigint => (((h ^ (v & U64_MASK)) * FNV_PRIME) & U64_MASK);

/** A change-detection fingerprint for one materialized table column. */
export function colFp(cd: ColumnData): bigint {
  if (cd.kind === "string") {
    // NUL separator (written as an escape — a literal NUL byte here made the
    // file read as binary and was one accidental "cleanup" away from
    // fingerprint collisions).
    return fnv1a64(enc((cd.values as string[]).join("\u0000")));
  }
  if (cd.kind === "vla") {
    let h = 0xcbf29ce484222325n;
    for (const cell of cd.values as dt.TypedArray[]) {
      h = mix(h, BigInt(cell.length));
      h = mix(h, fnv1a64(viewBytes(cell)));
    }
    return h;
  }
  return fnv1a64(viewBytes(cd.values as dt.TypedArray));
}

// ════════════════════════════════════════════════════════════════════════
// Table HDU base
// ════════════════════════════════════════════════════════════════════════

/**
 * Runtime guard for table-data assignments from untyped JS: anything that is
 * not a TableData has no columns to serialize — accepting it used to write an
 * EMPTY table silently (or blow up much later, far from the bad assignment).
 */
function validatedTableData(value: unknown): TableData {
  if (!(value instanceof TableData)) {
    throw new FitsTypeError(410, "table data must be a TableData instance");
  }
  return value;
}

/** Run `fn` with an open table view over the current HDU, closing it after. */
function withTable<T>(handle: bigint, fn: (t: bigint) => T): T {
  const tout = ll.outU64();
  ll.check(ll.lib.zf_table_open(handle, tout));
  const t = tout[0];
  try {
    return fn(t);
  } finally {
    ll.lib.zf_table_close(t);
  }
}

function colName(t: bigint, i: number): string {
  const buf = new Uint8Array(80);
  const out = ll.outU64();
  ll.check(ll.lib.zf_table_col_name(t, i, buf, 80, out));
  return decOut(buf, out[0]).trim();
}

function readColInfo(t: bigint, i: number): ll.ColInfo {
  const buf = ll.newColInfoBuf();
  ll.check(ll.lib.zf_table_col_info(t, i, buf));
  return ll.decodeColInfo(buf);
}

export interface FromColumnsOptions {
  nrows?: number;
  name?: string;
}

export interface TableHDUOptions<T extends ColumnShape = ColumnShape> extends HDUOptions {
  /** Row data for a detached table HDU (TFORMs are synthesized from the column data on write). */
  data?: TableData<T> | null;
}

export abstract class TableHDU<T extends ColumnShape = ColumnShape> extends BaseHDU {
  // Abstract + widened to the table subtree: every concrete subclass must
  // supply its own narrower literal (no silently-wrong default), while callers
  // can still discriminate on the union (TS override-variance requirement).
  abstract override readonly kind: "bintable" | "asciitable";
  /** @internal */ abstract readonly _tableType: number;

  // Stored untyped (default shape); the column-shape `T` is a compile-time
  // contract surfaced only at the public `data` boundary.
  /** @internal */ _data: TableData | null | typeof DATA_UNSET = DATA_UNSET;
  /** @internal */ _columns: Column[] = [];
  /** @internal */ _nrows = 0;
  /** @internal Per-column baselines for update-mode in-place write-back. */
  _colFingerprints: Map<string, bigint> | null = null;

  constructor(options: TableHDUOptions<T> = {}) {
    super(options);
    if (options.data != null) {
      this._data = validatedTableData(options.data);
      this._colFingerprints = new Map();
    }
  }

  get data(): TableData<T> | null {
    const d = this._data;
    if (d !== DATA_UNSET) return d as TableData<T> | null;
    if (this._hdulist === null) return null;
    const rec = this._readTable();
    this._data = rec;
    return rec as TableData<T>;
  }

  /**
   * Replace the table's rows wholesale (e.g. a filtered TableData).
   * writeTo/toBytes reconstruct from this; an in-place update-mode flush of
   * a row-count change fails loud. If the table was never read, there is no
   * per-column baseline, so every column counts as changed on the next flush.
   */
  set data(value: TableData<T> | null) {
    this._data = value === null ? null : validatedTableData(value);
    if (value !== null && this._colFingerprints === null) this._colFingerprints = new Map();
    this._markDirty();
  }

  override _dataChanged(): boolean {
    const d = this._data;
    if (d === DATA_UNSET || d === null || this._colFingerprints === null) return false;
    for (const name of d.names) {
      if (colFp(d.column(name)) !== this._colFingerprints.get(name)) return true;
    }
    return false;
  }

  /**
   * @internal Write back in-place edits to a materialized table's cell values
   * (update mode). Only changed columns are rewritten; changing the row count
   * or editing a VLA/scaled column in place is not supported.
   */
  override _flushData(): void {
    if (this._data === DATA_UNSET) return;
    if (this._data === null) {
      let empty = false;
      withTable(this._select(), (t) => {
        const nrowsOut = ll.outI64();
        ll.check(ll.lib.zf_table_nrows(t, nrowsOut));
        const ncolsOut = ll.outI32();
        ll.check(ll.lib.zf_table_ncols(t, ncolsOut));
        empty = Number(nrowsOut[0]) === 0 && ncolsOut[0] === 0;
      });
      if (empty) return; // already empty on disk; nothing to clear
      throw new NotSupportedError(
        410,
        "clearing table data cannot be written back to the open file in update mode; restore .data or save with writeTo() to a new file",
      );
    }
    if (this._colFingerprints === null) return;
    const rec = this._data;
    const h = this._select();
    withTable(h, (t) => {
      const nrowsOut = ll.outI64();
      ll.check(ll.lib.zf_table_nrows(t, nrowsOut));
      const nrows = safeMaterializedRows(nrowsOut[0]);
      // Resolve each column to its unique slot in the FILE, not its position in this
      // (possibly reordered) TableData. Duplicate effective names are rejected before any
      // write because a name cannot identify either physical slot.
      const ncolsOut = ll.outI32();
      ll.check(ll.lib.zf_table_ncols(t, ncolsOut));
      const fileNames: string[] = [];
      for (let j = 0; j < ncolsOut[0]; j++) fileNames.push(colName(t, j) || `col${j + 1}`);
      assertUniqueColumnNames(fileNames);
      const fileIndex = new Map<string, number>();
      for (let j = 0; j < fileNames.length; j++) fileIndex.set(fileNames[j], j);
      for (let i = 0; i < rec.names.length; i++) {
        const name = rec.names[i];
        const newFp = colFp(rec.column(name));
        if (newFp === this._colFingerprints!.get(name)) continue; // column unchanged
        if (nrows !== rec.nrows) {
          throw new NotSupportedError(
            410,
            "in-place table update cannot change the row count; use writeTo() to a new file",
          );
        }
        const j = fileIndex.get(name);
        if (j === undefined) {
          throw new NotSupportedError(
            410,
            `in-place update cannot add column '${name}' (not present in the file); use writeTo() to a new file`,
          );
        }
        const info = readColInfo(t, j);
        if (info.isVla) {
          throw new NotSupportedError(
            410,
            "in-place update of a variable-length-array column is not supported; use writeTo()",
          );
        }
        if (info.tscal !== 1 || info.tzero !== 0) {
          throw new NotSupportedError(
            410,
            "in-place update of a scaled/unsigned (TSCAL/TZERO) column is not supported; use writeTo()",
          );
        }
        const fmt = this._tableType === ll.ASCII_TBL ? asciiTformOf(info) : tformOf(info);
        writeColumn(t, j, new Column(name, fmt, { array: rec.get(name) as ColumnArray }), nrows);
        this._colFingerprints!.set(name, newFp);
      }
    });
  }

  /** Column names for an attached table; the builder `Column`s for a detached one. */
  get columns(): string[] | Column[] {
    return this._hdulist !== null ? this._readColumnsMeta() : this._columns;
  }

  private _readColumnsMeta(): string[] {
    const h = this._select();
    return withTable(h, (t) => {
      const ncols = ll.outI32();
      ll.check(ll.lib.zf_table_ncols(t, ncols));
      const names: string[] = [];
      for (let i = 0; i < ncols[0]; i++) names.push(colName(t, i));
      return names;
    });
  }

  /** @internal */
  _readTable(): TableData {
    const h = this._select();
    return withTable(h, (t) => {
      const nrowsOut = ll.outI64();
      ll.check(ll.lib.zf_table_nrows(t, nrowsOut));
      const nrows = safeMaterializedRows(nrowsOut[0]);
      const ncolsOut = ll.outI32();
      ll.check(ll.lib.zf_table_ncols(t, ncolsOut));
      const ncols = ncolsOut[0];

      const names: string[] = [];
      const infos: ll.ColInfo[] = [];
      for (let col = 0; col < ncols; col++) {
        const name = colName(t, col) || `col${col + 1}`;
        names.push(name);
        infos.push(readColInfo(t, col));
      }
      assertUniqueColumnNames(names);
      const columns = new Map<string, ColumnData>();
      for (let col = 0; col < ncols; col++) columns.set(names[col], this._columnPlan(t, col, infos[col], nrows));
      const data = new TableData(names, columns, nrows);
      // Baselines for write-back AND the writeTo pristine gate (all modes).
      this._colFingerprints = new Map(names.map((n) => [n, colFp(data.column(n))]));
      return data;
    });
  }

  /** @internal Read one column (port of `core.py _column_plan`, executed eagerly). */
  _columnPlan(t: bigint, col: number, info: ll.ColInfo, nrows: number): ColumnData {
    // Character column -> fixed-width strings.
    if (info.typecode === ll.ZF_STRING) {
      const width = info.width; // may be 0: a '0A' column reads as empty strings
      const buf = new Uint8Array(Math.max(nrows * width, 1));
      if (nrows > 0) {
        ll.check(ll.lib.zf_read_col_str(t, col, 1n, BigInt(nrows), BigInt(width), BigInt(width), buf));
      }
      const values: string[] = [];
      const decoder = new TextDecoder("ascii");
      for (let r = 0; r < nrows; r++) {
        let end = (r + 1) * width;
        while (end > r * width && (buf[end - 1] === 0x20 || buf[end - 1] === 0x00)) end--;
        values.push(decoder.decode(buf.subarray(r * width, end)));
      }
      return { kind: "string", dtype: "u1", repeat: Math.max(width, 1), values };
    }

    // VLA column -> zero-copy row views into one JS-owned flat array. The core measures and
    // validates all descriptors in packed ranges, then fills each range without per-cell ABI
    // crossings or allocations. Element type comes from info.typecode (the TFORM char itself is
    // 'P'/'Q', the descriptor kind — not the element type).
    if (info.isVla) {
      const code = info.typecode;
      const isComplex = code === ll.ZF_COMPLEX64 || code === ll.ZF_COMPLEX128;
      const elem: dt.Dtype = isComplex ? (code === ll.ZF_COMPLEX64 ? "c8" : "c16") : dt.zfToDtype(code);
      const floatElem: dt.Dtype = code === ll.ZF_COMPLEX64 ? "f4" : "f8";
      const scalarElem = isComplex ? floatElem : elem;
      const scalarBytes = dt.itemBytes(scalarElem);
      const readCode = dt.zfCode(scalarElem);
      const offsets = readVlaLayout(t, col, nrows);
      const total = offsets[offsets.length - 1];
      const flat = allocTransferArray(scalarElem, safeSlotCount(total, scalarBytes, "packed VLA payload"), "packed VLA payload");

      for (const chunk of vlaTransferChunks(offsets, scalarBytes)) {
        const firstSlot = Number(chunk.firstSlot);
        const endSlot = Number(chunk.endSlot);
        const out = flat.subarray(firstSlot, endSlot) as dt.TypedArray;
        ll.check(
          ll.lib.zf_read_col_vla_packed(
            t,
            readCode,
            col,
            BigInt(chunk.first + 1),
            BigInt(chunk.end - chunk.first),
            out,
            chunk.endSlot - chunk.firstSlot,
          ),
        );
      }

      const values = new Array<dt.TypedArray>(nrows);
      for (let r = 0; r < nrows; r++) {
        values[r] = flat.subarray(Number(offsets[r]), Number(offsets[r + 1])) as dt.TypedArray;
      }
      return { kind: "vla", dtype: elem, repeat: 1, values };
    }

    // ASCII-table columns: the TFORM letter does not encode width, so take
    // the element dtype from the authoritative typecode. Scalar, never
    // complex/VLA (handled above); scaled ints read as physical float64.
    if (this._tableType === ll.ASCII_TBL) {
      let elem = dt.zfToDtype(info.typecode);
      if (dt.isIntegerDtype(elem) && (info.tscal !== 1 || info.tzero !== 0)) elem = "f8";
      const flat = dt.allocDtype(elem, nrows);
      if (nrows > 0) {
        ll.check(ll.lib.zf_read_col(t, dt.zfCode(elem), col, 1n, BigInt(nrows), null, flat));
      }
      return { kind: "numeric", dtype: elem, repeat: 1, values: flat };
    }

    const { dtype: binElem, isComplex } = dt.binElemDtype(info.tformChar);
    const repeat = Math.max(info.repeat, 0);
    if (isComplex) {
      const cdtype: dt.Dtype = binElem === "f4" ? "c8" : "c16";
      // c8/c16 allocate a Float32Array/Float64Array (2 floats per element).
      const flat = dt.allocDtype(cdtype, nrows * repeat) as Float32Array | Float64Array;
      if (flat.length > 0) {
        ll.check(ll.lib.zf_read_col(t, dt.zfCode(binElem), col, 1n, BigInt(nrows * repeat * 2), null, flat));
      }
      return { kind: "complex", dtype: cdtype, repeat, values: flat };
    }

    // Honor per-column scaling (TSCAL/TZERO): the unsigned convention widens
    // to an unsigned dtype; any other non-trivial linear scaling reads as
    // physical float64. The C layer applies the scaling; we only choose a
    // destination dtype wide enough to hold it.
    let elem = binElem;
    if (dt.isIntegerDtype(elem)) {
      const uns = info.tscal === 1 ? dt.unsignedColDtype(elem, info.tzero) : null;
      if (uns !== null) elem = uns;
      else if (info.tscal !== 1 || info.tzero !== 0) elem = "f8";
    }
    const flat = dt.allocDtype(elem, nrows * repeat);
    if (flat.length > 0) {
      ll.check(ll.lib.zf_read_col(t, dt.zfCode(elem), col, 1n, BigInt(nrows * repeat), null, flat));
    }
    return { kind: "numeric", dtype: elem, repeat, values: flat };
  }

  // ── writing ──

  /**
   * @internal (columns, nrows) to serialize: the builder columns for a
   * detached HDU, or columns reconstructed from the live table for an
   * attached one (so a copied table keeps its rows). For the attached path,
   * `srcIndex[i]` is the FILE column index whose stored format the emitted
   * column `i` still uses (null for an added/renamed/retyped column), so
   * _writeTo can move that column's indexed metadata cards (TNULLn/TDISPn/
   * TDIMn) to the column's new position; null srcIndex = detached path,
   * where indexed cards already refer to the emitted order.
   */
  _emitColumns(): { cols: Column[]; nrows: number; srcIndex: (number | null)[] | null } {
    if (this._columns.length > 0) {
      assertUniqueColumnNames(this._columns.map((col) => col.name));
      return { cols: [...this._columns], nrows: this._nrows, srcIndex: null };
    }
    const data = this.data;
    if (data === null) return { cols: [], nrows: 0, srcIndex: null };
    if (this._hdulist === null) {
      // A detached HDU carrying a TableData: synthesize every TFORM from the
      // column data (there is no file column to reuse). Previously this fell
      // into the builder-columns early-return and silently emitted an EMPTY table.
      if (this._tableType === ll.ASCII_TBL) {
        throw new NotSupportedError(
          410,
          "cannot synthesize ASCII-table formats from TableData; build the table with AsciiTableHDU.fromColumns(...)",
        );
      }
      const cols = data.names.map(
        (name) => new Column(name, binaryTformFor(undefined, data.column(name)), { array: data.get(name) as ColumnArray }),
      );
      return { cols, nrows: data.nrows, srcIndex: null };
    }
    const h = this._select();
    return withTable(h, (t) => {
      const ncolsOut = ll.outI32();
      ll.check(ll.lib.zf_table_ncols(t, ncolsOut));
      // Map file columns by unique effective NAME so a reassigned TableData
      // keeps each column's true format even when reordered/filtered. The
      // `col${j+1}` fallback matches _readTable for a column lacking TTYPE.
      const fileNames: string[] = [];
      for (let j = 0; j < ncolsOut[0]; j++) fileNames.push(colName(t, j) || `col${j + 1}`);
      assertUniqueColumnNames(fileNames);
      const fileInfo = new Map<string, { info: ll.ColInfo; index: number }>();
      for (let j = 0; j < fileNames.length; j++) fileInfo.set(fileNames[j], { info: readColInfo(t, j), index: j });
      const cols: Column[] = [];
      const srcIndex: (number | null)[] = [];
      for (const name of data.names) {
        const entry = fileInfo.get(name);
        let fmt: string;
        if (this._tableType === ll.ASCII_TBL) {
          if (entry === undefined) {
            throw new NotSupportedError(
              410,
              `writeTo() cannot add or rename an ASCII-table column ('${name}') from a reassigned ` +
                "TableData; rebuild the table with AsciiTableHDU.fromColumns(...)",
            );
          }
          fmt = asciiTformOf(entry.info);
        } else {
          fmt = binaryTformFor(entry?.info, data.column(name));
        }
        // The unit rides the COLUMN, not its position: thread the source
        // TUNITn through the builder Column so zf_create_tbl re-emits it at
        // the column's new index (TUNITn itself is structural-skipped). A
        // retyped column keeps its unit — the physical quantity is unchanged.
        const unit = entry !== undefined ? this.header.get(`TUNIT${entry.index + 1}`) : undefined;
        cols.push(new Column(name, fmt, { array: data.get(name) as ColumnArray, unit: typeof unit === "string" ? unit : undefined }));
        // Indexed metadata describes the STORED cells, so it only survives
        // when the emitted format is still the file column's own (a retyped
        // column's old TNULL sentinel / display / shape no longer apply).
        const fileFmt = entry === undefined ? null : this._tableType === ll.ASCII_TBL ? asciiTformOf(entry.info) : tformOf(entry.info);
        srcIndex.push(entry !== undefined && fmt === fileFmt ? entry.index : null);
      }
      return { cols, nrows: data.nrows, srcIndex };
    });
  }

  /** @internal */
  _writeTo(handle: bigint, _primary: boolean): void {
    const { cols, nrows, srcIndex } = this._emitColumns();
    const n = cols.length;
    const ttype = cols.map((c) => c.name);
    const tform = cols.map((c) => c.format);
    const tunit = cols.map((c) => c.unit);
    const extname = this._name ?? null;
    const pcount = vlaHeapBytes(cols);
    if (pcount > 0) {
      // Reserve heap up front so VLA cells can be written.
      ll.check(
        ll.lib.zf_create_tbl_heap(handle, this._tableType, BigInt(nrows), n, ttype, tform, tunit, extname, BigInt(pcount)),
      );
    } else {
      ll.check(ll.lib.zf_create_tbl(handle, this._tableType, BigInt(nrows), n, ttype, tform, tunit, extname));
    }

    // Unsigned columns use the TZEROn convention; set it before opening the
    // table view so the write path stores (value − TZERO) as a signed int.
    for (let i = 0; i < cols.length; i++) {
      const tz = unsignedColTzeroOf(cols[i]);
      if (tz !== null) writeConventionOffset(handle, `TZERO${i + 1}`, tz);
    }

    // Re-emit the user header cards (science keywords, COMMENT/HISTORY, HIERARCH)
    // that zf_create_tbl does not carry, skipping the column descriptors it
    // already wrote — mirroring ImageHDU._writeTo so a reconstruction save does
    // not silently drop table metadata. On the attached reconstruction path
    // (srcIndex set), indexed per-column cards are skipped from the verbatim
    // pass too: their index refers to the SOURCE column order, and a by-name
    // reorder/subset would leave them labeling the wrong column (a TNULLn on a
    // float column is even spec-invalid). They are re-emitted below at each
    // column's new position instead.
    const indexedMeta = /^T(NULL|DISP|DIM)\d+$/;
    this._applyUserKeys(handle, (up) => isTableStructuralKeyword(up) || (srcIndex !== null && indexedMeta.test(up)));
    if (srcIndex !== null) {
      for (let i = 0; i < srcIndex.length; i++) {
        const j = srcIndex[i];
        if (j === null) continue; // added/renamed/retyped: the old cards no longer describe it
        for (const base of ["TNULL", "TDISP", "TDIM"] as const) {
          const v = this.header.get(`${base}${j + 1}`);
          if (v === undefined || v === null) continue;
          writeKeyValue(handle, `${base}${i + 1}`, v, this.header.commentOf(`${base}${j + 1}`) || null);
        }
      }
    }

    withTable(handle, (t) => {
      for (let i = 0; i < cols.length; i++) {
        if (cols[i].array === null) continue;
        writeColumn(t, i, cols[i], nrows);
      }
    });
  }

  static fromColumnsInto<H extends TableHDU<ColumnShape>>(hdu: H, columns: readonly Column[], options: FromColumnsOptions = {}): H {
    assertUniqueColumnNames(columns.map((col) => col.name));
    hdu._columns = [...columns];
    hdu._name = options.name ?? hdu._name;
    const present = columns.filter((c) => c.array !== null).map((c) => colRowCount(c));
    const distinct = [...new Set(present)];
    if (distinct.length > 1) {
      throw new RangeError(`columns have differing lengths [${distinct.sort((a, b) => a - b).join(", ")}]; all must match`);
    }
    const dataLen = present.length > 0 ? present[0] : 0;
    let nrows = options.nrows;
    if (nrows === undefined) nrows = dataLen;
    else if (present.length > 0 && nrows !== dataLen) {
      throw new RangeError(`nrows=${nrows} does not match the ${dataLen}-row column data`);
    }
    hdu._nrows = nrows;
    return hdu;
  }
}

/** @internal Write one column's cells into an open table view. */
function writeColumn(t: bigint, i: number, col: Column, nrows: number): void {
  const arr = col.array;
  if (arr === null) return;
  const fmt = col.format.trim().toUpperCase();
  // Variable-length array column 'rP<t>(max)' / 'rQ<t>(max)'.
  if (fmt.includes("P") || fmt.includes("Q")) {
    writeVlaColumn(t, i, col, nrows);
    return;
  }
  // Character column 'wA' or 'Aw'. Non-ASCII is not representable in a FITS string field.
  if (fmt.includes("A")) {
    const width = Math.max(parseInt(formatDigits(fmt) || "1", 10), 1);
    const buf = new Uint8Array(Math.max(nrows * width, 1)).fill(0x20);
    const rows = arr as readonly string[];
    for (let r = 0; r < nrows; r++) {
      const s = String(rows[r] ?? "");
      for (let k = 0; k < Math.min(s.length, width); k++) {
        const code = s.charCodeAt(k);
        if (code > 127) throw new FitsTableError(310, `non-ASCII string in column ${col.name}: ${JSON.stringify(s)}`);
        buf[r * width + k] = code;
      }
    }
    ll.check(ll.lib.zf_write_col_str(t, i, 1n, BigInt(nrows), BigInt(width), BigInt(width), buf));
    return;
  }
  const { dtype: elem, isComplex } = dt.binElemDtype(firstLetter(fmt));
  if (isComplex) {
    // Interleaved float pairs (2*nrows*repeat floats). The transfer code MUST
    // describe the actual buffer: keep a float buffer's own width (the library
    // converts to the column's disk type, mirroring Python's a.view(base));
    // cast anything else to the column's element type.
    let flat = isTypedArray(arr) ? arr : toTypedArray(arr as readonly (number | bigint)[], elem);
    const own = dt.dtypeOf(flat);
    if (own !== "f4" && own !== "f8") flat = castTypedArray(flat, elem);
    ll.check(ll.lib.zf_write_col(t, dt.zfCode(dt.dtypeOf(flat)), i, 1n, BigInt(flat.length), null, flat));
    return;
  }
  let flat: dt.TypedArray;
  if (isTypedArray(arr)) {
    flat = arr;
  } else if (Array.isArray(arr) && arr.length > 0 && typeof arr[0] === "boolean") {
    // A logical (L) column transfers as 0/1 bytes.
    flat = Uint8Array.from(arr as boolean[], (b) => (b ? 1 : 0));
  } else if (Array.isArray(arr) && arr.length > 0 && (isTypedArray(arr[0]) || Array.isArray(arr[0]))) {
    // Rows-of-arrays for a vector column: flatten into the column's element type.
    const cells = (arr as readonly (dt.TypedArray | readonly number[])[]).map((c) => castTypedArray(c, elem));
    const total = cells.reduce((a, c) => a + c.length, 0);
    flat = dt.allocDtype(elem, total);
    let off = 0;
    for (const cell of cells) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (flat as any).set(cell, off);
      off += cell.length;
    }
  } else {
    // Plain scalar array: exact (safe) integers → i8, everything else → f8 so
    // the library's float→int conversion rounds and range-checks (a value like
    // 1e20 raises FitsOverflowError instead of wrapping in a BigInt64Array).
    const plain = arr as readonly (number | bigint)[];
    const allInts = plain.every((v) => typeof v === "bigint" || (typeof v === "number" && Number.isSafeInteger(v)));
    flat = toTypedArray(plain, allInts ? "i8" : "f8");
  }
  ll.check(ll.lib.zf_write_col(t, dt.zfCode(dt.dtypeOf(flat)), i, 1n, BigInt(flat.length), null, flat));
}

/** @internal */
function writeVlaColumn(t: bigint, i: number, col: Column, nrows: number): void {
  const { dtype: elem, isComplex } = vlaElemDtype(col.format.trim().toUpperCase());
  if (isComplex) throw new NotSupportedError(410, "writing complex VLA columns is not supported");
  const arr = col.array as readonly (dt.TypedArray | readonly number[])[];
  const offsets = new BigUint64Array(nrows + 1);
  const cells = new Array<dt.TypedArray>(nrows);
  let total = 0n;
  for (let r = 0; r < nrows; r++) {
    const cell = castTypedArray(arr[r], elem);
    cells[r] = cell;
    const length = BigInt(cell.length);
    if (length > MAX_U64 - total) throw new FitsOverflowError(412, "packed VLA payload exceeds uint64 slots");
    total += length;
    offsets[r + 1] = total;
  }

  const scalarBytes = dt.itemBytes(elem);
  const flat = allocTransferArray(elem, safeSlotCount(total, scalarBytes, "packed VLA payload"), "packed VLA payload");
  let at = 0;
  for (const cell of cells) {
    // All cells and `flat` have exactly `elem`, but the TypedArray union does not expose a
    // common bigint/number-safe `set` overload.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (flat as any).set(cell, at);
    at += cell.length;
  }

  // The zero-row case is a useful ABI no-op and keeps all VLA writes on the packed path.
  if (nrows === 0) {
    ll.check(ll.lib.zf_write_col_vla_packed(t, dt.zfCode(elem), i, 1n, 0n, offsets, offsets.length, flat, 0n));
    return;
  }

  for (const chunk of vlaTransferChunks(offsets, scalarBytes)) {
    const localOffsets = new BigUint64Array(chunk.end - chunk.first + 1);
    for (let k = 0; k < localOffsets.length; k++) {
      localOffsets[k] = offsets[chunk.first + k] - chunk.firstSlot;
    }
    const values = flat.subarray(Number(chunk.firstSlot), Number(chunk.endSlot)) as dt.TypedArray;
    ll.check(
      ll.lib.zf_write_col_vla_packed(
        t,
        dt.zfCode(elem),
        i,
        BigInt(chunk.first + 1),
        BigInt(chunk.end - chunk.first),
        localOffsets,
        localOffsets.length,
        values,
        chunk.endSlot - chunk.firstSlot,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Concrete table HDUs
// ════════════════════════════════════════════════════════════════════════

export class BinTableHDU<T extends ColumnShape = ColumnShape> extends TableHDU<T> {
  override readonly kind = "bintable" as const;
  readonly _tableType = ll.BINARY_TBL;

  static fromColumns<T extends ColumnShape = ColumnShape>(
    columns: readonly Column[],
    options: FromColumnsOptions = {},
  ): BinTableHDU<T> {
    return TableHDU.fromColumnsInto(new BinTableHDU<T>(), columns, options);
  }
}

export class AsciiTableHDU<T extends ColumnShape = ColumnShape> extends TableHDU<T> {
  override readonly kind = "asciitable" as const;
  readonly _tableType = ll.ASCII_TBL;

  static fromColumns<T extends ColumnShape = ColumnShape>(
    columns: readonly Column[],
    options: FromColumnsOptions = {},
  ): AsciiTableHDU<T> {
    return TableHDU.fromColumnsInto(new AsciiTableHDU<T>(), columns, options);
  }
}

export type { HDUOptions };
