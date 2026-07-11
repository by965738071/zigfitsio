/**
 * Zero-dependency n-dimensional image wrapper: a flat native-endian
 * TypedArray plus a C-order shape (`[NAXIS2, NAXIS1]` for a 2-D image —
 * reversed FITS axis order, matching astropy/numpy layout).
 */
import { dtypeOf, type Dtype, type TypedArray } from "./dtypes.js";

/** The scalar element type a TypedArray holds: `bigint` for 64-bit int arrays, else `number`. */
export type ElementOf<T extends TypedArray> = T extends BigInt64Array | BigUint64Array ? bigint : number;

export class FitsArray<T extends TypedArray = TypedArray> {
  readonly data: T;
  readonly shape: readonly number[];

  constructor(data: T, shape?: readonly number[]) {
    this.data = data;
    this.shape = shape === undefined ? [data.length] : [...shape];
    const n = this.shape.reduce((a, b) => a * b, 1);
    if (n !== data.length) {
      throw new RangeError(`shape [${this.shape.join(", ")}] does not match ${data.length} elements`);
    }
  }

  get dtype(): Dtype {
    return dtypeOf(this.data);
  }

  get size(): number {
    return this.data.length;
  }

  get ndim(): number {
    return this.shape.length;
  }

  /** Flat offset of a C-order (row-major) index tuple. */
  offset(...idx: number[]): number {
    if (idx.length !== this.shape.length) {
      throw new RangeError(`expected ${this.shape.length} indices, got ${idx.length}`);
    }
    let off = 0;
    for (let d = 0; d < idx.length; d++) {
      const i = idx[d];
      if (i < 0 || i >= this.shape[d]) throw new RangeError(`index ${i} out of bounds for axis ${d} (size ${this.shape[d]})`);
      off = off * this.shape[d] + i;
    }
    return off;
  }

  get(...idx: number[]): ElementOf<T> {
    return this.data[this.offset(...idx)] as ElementOf<T>;
  }

  set(value: ElementOf<T>, ...idx: number[]): void {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (this.data as any)[this.offset(...idx)] = value;
  }

  /** A deep copy (same dtype and shape). */
  clone(): FitsArray<T> {
    return new FitsArray(this.data.slice() as T, this.shape);
  }
}

/** Normalize a data argument: TypedArray → 1-D FitsArray; FitsArray passes through. */
export function asFitsArray(value: FitsArray | TypedArray): FitsArray {
  return value instanceof FitsArray ? value : new FitsArray(value);
}
