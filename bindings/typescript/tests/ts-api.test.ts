/**
 * TypeScript-native surface: HDU `kind` discriminant + typed
 * `image()`/`table()` accessors, `ColumnData` discriminated union + typed
 * column accessors, `TableData` row view, Map-style `Header` iteration,
 * `tableFromArrays`/`imageFromArray` factories, `FitsArray` element typing,
 * and `ImageHDU.section()` strided cutouts.
 */
import { afterAll, describe, expect, test } from "./_harness/index.js";
import * as zf from "../src/index.js";
import { fill, tmpFits } from "./_fixtures.js";

const tmp = tmpFits();
afterAll(() => tmp.cleanup());

// ── Compile-time type assertions (checked by `npm run typecheck:tests`) ──
// These never execute; they fail the type-check if the public generics regress.
type Equal<A, B> = (<G>() => G extends A ? 1 : 2) extends <G>() => G extends B ? 1 : 2 ? true : false;
type Expect<T extends true> = T;
function _typeAssertions(hdul: zf.HDUList): void {
  // FitsArray element typing: number vs bigint by backing array.
  const f = new zf.FitsArray(new Float32Array(1));
  const b = new zf.FitsArray(new BigInt64Array(1));
  type _f = Expect<Equal<ReturnType<typeof f.get>, number>>;
  type _b = Expect<Equal<ReturnType<typeof b.get>, bigint>>;
  // set() rejects the wrong scalar type for the backing array.
  // @ts-expect-error a bigint-backed array cannot be set from a number
  b.set(1, 0);
  // @ts-expect-error a number-backed array cannot be set from a bigint
  f.set(1n, 0);
  // image()/table() narrow `.data` (no cast needed).
  type _img = Expect<Equal<ReturnType<typeof hdul.image>["data"], zf.FitsArray | null>>;
  // TableData<T> maps get(name) to the declared column value type.
  const rec = hdul.table<{ INDEX: Int32Array; NAME: string[] }>("EVENTS").data!;
  const idx = rec.get("INDEX");
  type _c2 = Expect<Equal<typeof idx, Int32Array>>;
  const nm = rec.get("NAME");
  type _c3 = Expect<Equal<typeof nm, string[]>>;
  // A name outside the shape falls to the untyped fallback overload.
  const dyn = rec.get("MISSING");
  type _c4 = Expect<Equal<typeof dyn, zf.ColumnValues>>;
  // row() cells: numeric column -> scalar | slice of the declared array type.
  const row = rec.row(0);
  type _r1 = Expect<Equal<typeof row.INDEX, number | Int32Array>>;
  type _r2 = Expect<Equal<typeof row.NAME, string>>;
  // Header iterates [key, value] entries.
  const h = new zf.Header();
  type _h = Expect<Equal<ReturnType<(typeof h)[typeof Symbol.iterator]>, Iterator<[string, zf.HeaderValue]>>>;
  void [f, b, rec, idx, nm, dyn, row, h] as unknown;
}
void _typeAssertions;

const asNums = (a: ArrayLike<number | bigint>): number[] => Array.from(a, (v) => Number(v));

/** A written 3-column table file (INDEX:J, FLUX:E, NAME:8A) with a VLA and complex too. */
function writeSampleTable(): string {
  const p = tmp.path();
  const table = zf.BinTableHDU.fromColumns(
    [
      new zf.Column("INDEX", "J", { array: Int32Array.from([10, 20, 30]) }),
      new zf.Column("FLUX", "E", { array: Float32Array.from([1.5, 2.5, 3.5]), unit: "Jy" }),
      new zf.Column("NAME", "8A", { array: ["alpha", "beta", "gamma"] }),
      new zf.Column("TRACE", "1PJ", { array: [Int32Array.from([1, 2]), Int32Array.from([3]), new Int32Array(0)] }),
      new zf.Column("CPLX", "1C", { array: Float32Array.from([1, 2, -3, 4, 0, -1]) }),
    ],
    { name: "EVENTS" },
  );
  new zf.HDUList([new zf.PrimaryHDU(), table]).writeTo(p, { overwrite: true });
  return p;
}

describe("HDU kind discriminant + typed accessors", () => {
  test("kind literals on detached HDUs", () => {
    expect(new zf.PrimaryHDU().kind).toBe("primary");
    expect(new zf.ImageHDU().kind).toBe("image");
    expect(new zf.CompImageHDU().kind).toBe("compimage");
    expect(new zf.BinTableHDU().kind).toBe("bintable");
    expect(new zf.AsciiTableHDU().kind).toBe("asciitable");
  });

  test("kind literals on attached HDUs, and narrowing to data", () => {
    const p = writeSampleTable();
    const hdul = zf.open(p);
    try {
      expect(hdul.get(0).kind).toBe("primary");
      expect(hdul.get(1).kind).toBe("bintable");
      // Narrowing on kind gives cast-free `.data`.
      for (const hdu of hdul) {
        if (hdu.kind === "bintable" || hdu.kind === "asciitable") {
          const rec = hdu.data; // TableData | null, no cast
          expect(rec?.names).toContain("INDEX");
        }
      }
    } finally {
      hdul.close();
    }
  });

  test("image()/table() accessors return narrowed HDUs", () => {
    const p = writeSampleTable();
    const hdul = zf.open(p);
    try {
      const img = hdul.image(0).data; // FitsArray | null, no cast
      expect(img).toBeNull(); // empty primary
      const rec = hdul.table("EVENTS").data; // TableData | null, no cast
      expect(rec?.nrows).toBe(3);
    } finally {
      hdul.close();
    }
  });

  test("image()/table() throw FitsTypeError on a kind mismatch", () => {
    const p = writeSampleTable();
    const hdul = zf.open(p);
    try {
      expect(() => hdul.image("EVENTS")).toThrow(zf.FitsTypeError);
      expect(() => hdul.table(0)).toThrow(zf.FitsTypeError);
    } finally {
      hdul.close();
    }
  });

  test("accessors surface out-of-range keys via get()", () => {
    const p = writeSampleTable();
    const hdul = zf.open(p);
    try {
      expect(() => hdul.image(9)).toThrow(RangeError);
      expect(() => hdul.table("NOPE")).toThrow(RangeError);
    } finally {
      hdul.close();
    }
  });
});

describe("ColumnData discriminated union + typed column accessors", () => {
  test("numeric/strings/vla/complex accessors", () => {
    const p = writeSampleTable();
    const hdul = zf.open(p);
    try {
      const rec = hdul.table("EVENTS").data as zf.TableData;
      expect(asNums(rec.numeric("INDEX"))).toEqual([10, 20, 30]);
      expect(rec.strings("NAME").map((s) => s.trim())).toEqual(["alpha", "beta", "gamma"]);
      const trace = rec.vla("TRACE");
      expect(trace.map((c) => asNums(c))).toEqual([[1, 2], [3], []]);
      expect(asNums(rec.complex("CPLX"))).toEqual([1, 2, -3, 4, 0, -1]);
    } finally {
      hdul.close();
    }
  });

  test("typed accessors throw FitsTypeError on a kind mismatch", () => {
    const p = writeSampleTable();
    const hdul = zf.open(p);
    try {
      const rec = hdul.table("EVENTS").data as zf.TableData;
      expect(() => rec.numeric("NAME")).toThrow(zf.FitsTypeError); // string col
      expect(() => rec.strings("INDEX")).toThrow(zf.FitsTypeError); // numeric col
      expect(() => rec.vla("INDEX")).toThrow(zf.FitsTypeError);
      expect(() => rec.complex("INDEX")).toThrow(zf.FitsTypeError);
    } finally {
      hdul.close();
    }
  });

  test("switch on col.kind narrows values", () => {
    const p = writeSampleTable();
    const hdul = zf.open(p);
    try {
      const rec = hdul.table("EVENTS").data as zf.TableData;
      const seen: string[] = [];
      for (const name of rec.names) {
        const col = rec.column(name);
        switch (col.kind) {
          case "numeric":
            seen.push(`${name}:numeric`);
            break;
          case "string":
            seen.push(`${name}:string`);
            break;
          case "vla":
            seen.push(`${name}:vla`);
            break;
          case "complex":
            seen.push(`${name}:complex`);
            break;
        }
      }
      expect(seen).toEqual(["INDEX:numeric", "FLUX:numeric", "NAME:string", "TRACE:vla", "CPLX:complex"]);
    } finally {
      hdul.close();
    }
  });
});

describe("TableData row view", () => {
  test("row() unwraps scalars, strings, VLA cells; numCols/numRows", () => {
    const p = writeSampleTable();
    const hdul = zf.open(p);
    try {
      const rec = hdul.table("EVENTS").data as zf.TableData;
      expect(rec.numRows).toBe(3);
      expect(rec.numCols).toBe(5);
      const r0 = rec.row(0);
      expect(Number(r0.INDEX)).toBe(10);
      expect(Math.abs(Number(r0.FLUX) - 1.5)).toBeLessThan(1e-6);
      expect(String(r0.NAME).trim()).toBe("alpha");
      expect(asNums(r0.TRACE as zf.TypedArray)).toEqual([1, 2]);
      // complex cell: 2 interleaved floats for repeat-1
      expect(asNums(r0.CPLX as zf.TypedArray)).toEqual([1, 2]);
    } finally {
      hdul.close();
    }
  });

  test("vector (repeat>1) numeric cell is a zero-copy slice", () => {
    const p = tmp.path();
    // 2 rows, repeat-3 int column.
    const col = new zf.Column("VEC", "3J", { array: Int32Array.from([1, 2, 3, 4, 5, 6]) });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const rec = hdul.table(1).data as zf.TableData;
      expect(asNums(rec.row(0).VEC as zf.TypedArray)).toEqual([1, 2, 3]);
      expect(asNums(rec.row(1).VEC as zf.TypedArray)).toEqual([4, 5, 6]);
    } finally {
      hdul.close();
    }
  });

  test("rows()/[Symbol.iterator]/toArray and out-of-range row()", () => {
    const p = writeSampleTable();
    const hdul = zf.open(p);
    try {
      const rec = hdul.table("EVENTS").data as zf.TableData;
      const viaIter = [...rec].map((r) => Number(r.INDEX));
      expect(viaIter).toEqual([10, 20, 30]);
      expect(rec.toArray().length).toBe(3);
      expect([...rec.rows()].length).toBe(3);
      expect(() => rec.row(3)).toThrow(RangeError);
      expect(() => rec.row(-1)).toThrow(RangeError);
    } finally {
      hdul.close();
    }
  });

  test("zero-row table iterates empty", () => {
    const p = tmp.path();
    const col = new zf.Column("X", "1J", { array: new Int32Array(0) });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col], { nrows: 0 })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const rec = hdul.table(1).data as zf.TableData;
      expect(rec.nrows).toBe(0);
      expect(rec.toArray()).toEqual([]);
    } finally {
      hdul.close();
    }
  });
});

describe("Header Map-style iteration", () => {
  test("iterates [key, value] entries; keys()/forEach/size", () => {
    const h = new zf.Header();
    h.set("A", 1);
    h.set("B", "two", "a comment");
    h.set("C", true);
    expect([...h]).toEqual([
      ["A", 1],
      ["B", "two"],
      ["C", true],
    ]);
    expect(h.keys()).toEqual(["A", "B", "C"]);
    expect(h.size).toBe(3);
    const seen: Record<string, zf.HeaderValue> = {};
    h.forEach((value, key) => {
      seen[key] = value;
    });
    expect(seen).toEqual({ A: 1, B: "two", C: true });
    // Destructuring the entries works like a Map.
    const asMap = new Map([...h]);
    expect(asMap.get("B")).toBe("two");
  });
});

describe("factories", () => {
  test("tableFromArrays infers TFORMs and units; roundtrips", () => {
    const p = tmp.path();
    const hdu = zf.tableFromArrays(
      {
        INDEX: Int32Array.from([10, 20, 30]),
        FLUX: Float32Array.from([1.5, 2.5, 3.5]),
        NAME: ["alpha", "beta", "gamma"],
        FLAG: [true, false, true],
      },
      { name: "EVENTS", units: { FLUX: "Jy" } },
    );
    expect(hdu).toBeInstanceOf(zf.BinTableHDU);
    new zf.HDUList([new zf.PrimaryHDU(), hdu]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const rec = hdul.table("EVENTS").data as zf.TableData;
      expect(asNums(rec.numeric("INDEX"))).toEqual([10, 20, 30]);
      expect(rec.strings("NAME").map((s) => s.trim())).toEqual(["alpha", "beta", "gamma"]);
      expect(asNums(rec.numeric("FLAG"))).toEqual([1, 0, 1]);
    } finally {
      hdul.close();
    }
  });

  test("tableFromArrays: unsigned convention roundtrips (Uint16Array -> u2)", () => {
    const p = tmp.path();
    const hdu = zf.tableFromArrays({ U: Uint16Array.from([0, 40000, 65535]) });
    new zf.HDUList([new zf.PrimaryHDU(), hdu]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const col = (hdul.table(1).data as zf.TableData).column("U");
      expect(col.dtype).toBe("u2");
      expect(asNums(col.values as zf.TypedArray)).toEqual([0, 40000, 65535]);
    } finally {
      hdul.close();
    }
  });

  test("tableFromArrays: equal-length cells -> fixed repeat; ragged -> VLA", () => {
    const p = tmp.path();
    const hdu = zf.tableFromArrays({
      FIXED: [Int32Array.from([1, 2]), Int32Array.from([3, 4])],
      RAGGED: [Int32Array.from([1, 2]), Int32Array.from([3])],
    });
    new zf.HDUList([new zf.PrimaryHDU(), hdu]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const rec = hdul.table(1).data as zf.TableData;
      expect(rec.column("FIXED").kind).toBe("numeric"); // 2J
      expect(rec.column("FIXED").repeat).toBe(2);
      expect(rec.column("RAGGED").kind).toBe("vla"); // 1PJ
      expect(rec.vla("RAGGED").map((c) => asNums(c))).toEqual([[1, 2], [3]]);
    } finally {
      hdul.close();
    }
  });

  test("tableFromArrays rejects Int8Array; enforces equal column lengths", () => {
    expect(() => zf.tableFromArrays({ BAD: Int8Array.from([1, 2, 3]) })).toThrow(zf.FitsTypeError);
    expect(() =>
      zf.tableFromArrays({ A: Int32Array.from([1, 2]), B: Int32Array.from([1, 2, 3]) }),
    ).toThrow(RangeError);
  });

  test("imageFromArray wraps a TypedArray + shape and roundtrips", () => {
    const p = tmp.path();
    const hdu = zf.imageFromArray(fill(new Float32Array(24), (i) => i * 0.25), [4, 6], { name: "IMG" });
    expect(hdu).toBeInstanceOf(zf.ImageHDU);
    new zf.HDUList([new zf.PrimaryHDU(), hdu]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const img = hdul.image("IMG").data as zf.FitsArray;
      expect(img.shape).toEqual([4, 6]);
      expect(Number(img.get(2, 3))).toBeCloseTo((2 * 6 + 3) * 0.25, 6);
    } finally {
      hdul.close();
    }
  });
});

describe("FitsArray element typing", () => {
  test("get/set roundtrip for number- and bigint-backed arrays", () => {
    const f = new zf.FitsArray(Float32Array.from([0, 0, 0, 0]), [2, 2]);
    f.set(3.5, 1, 0);
    expect(f.get(1, 0)).toBeCloseTo(3.5, 6);

    const b = new zf.FitsArray(BigInt64Array.from([0n, 0n]), [2]);
    b.set(42n, 1);
    expect(b.get(1)).toBe(42n);
  });
});

describe("ImageHDU.section (strided cutouts)", () => {
  const ramp = (): string => {
    const p = tmp.path();
    // 4x6 C-order ramp: data[r*6 + c] = r*6 + c.
    const img = new zf.FitsArray(fill(new Int32Array(24), (i) => i), [4, 6]);
    zf.writeTo(p, img, { overwrite: true });
    return p;
  };

  test("interior window matches a manual slice of the full read", () => {
    const p = ramp();
    const hdul = zf.open(p);
    try {
      const img = hdul.image(0);
      const cut = img.section({ window: [[1, 3], [2, 5]] }); // rows 1..2, cols 2..4
      expect(cut.shape).toEqual([2, 3]);
      expect(asNums(cut.data)).toEqual([8, 9, 10, 14, 15, 16]);
    } finally {
      hdul.close();
    }
  });

  test("step strides both axes", () => {
    const p = ramp();
    const hdul = zf.open(p);
    try {
      const cut = hdul.image(0).section({ window: [[0, 4], [0, 6]], step: [2, 2] });
      expect(cut.shape).toEqual([2, 3]);
      // rows 0,2 × cols 0,2,4 of the 6-wide ramp (data[r*6+c] = r*6+c)
      expect(asNums(cut.data)).toEqual([0, 2, 4, 12, 14, 16]);
    } finally {
      hdul.close();
    }
  });

  test("1-D and 3-D sections", () => {
    const p1 = tmp.path();
    zf.writeTo(p1, new zf.FitsArray(fill(new Int32Array(10), (i) => i), [10]), { overwrite: true });
    let hdul = zf.open(p1);
    try {
      const cut = hdul.image(0).section({ window: [[2, 8]], step: [2] });
      expect(cut.shape).toEqual([3]);
      expect(asNums(cut.data)).toEqual([2, 4, 6]);
    } finally {
      hdul.close();
    }

    const p3 = tmp.path();
    // shape [2,3,4] C-order: data[i*12 + j*4 + k] = that flat index.
    zf.writeTo(p3, new zf.FitsArray(fill(new Int32Array(24), (i) => i), [2, 3, 4]), { overwrite: true });
    hdul = zf.open(p3);
    try {
      const cut = hdul.image(0).section({ window: [[0, 1], [1, 3], [0, 4]] });
      expect(cut.shape).toEqual([1, 2, 4]);
      // i=0, j in {1,2}, k in {0..3}
      expect(asNums(cut.data)).toEqual([4, 5, 6, 7, 8, 9, 10, 11]);
    } finally {
      hdul.close();
    }
  });

  test("validates rank, bounds, and step", () => {
    const p = ramp();
    const hdul = zf.open(p);
    try {
      const img = hdul.image(0);
      expect(() => img.section({ window: [[0, 4]] })).toThrow(RangeError); // wrong rank
      expect(() => img.section({ window: [[0, 4], [0, 6]], step: [2] })).toThrow(RangeError);
      expect(() => img.section({ window: [[0, 5], [0, 6]] })).toThrow(RangeError); // OOB (5 > 4)
      expect(() => img.section({ window: [[2, 2], [0, 6]] })).toThrow(RangeError); // empty
      expect(() => img.section({ window: [[0, 4], [0, 6]], step: [0, 1] })).toThrow(RangeError);
    } finally {
      hdul.close();
    }
  });

  test("section on a tile-compressed image fails loud (use .data instead)", () => {
    const p = tmp.path();
    const img = new zf.FitsArray(fill(new Int32Array(256), (i) => i), [16, 16]);
    new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: img, compression: "RICE_1" })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const chdu = hdul.image(1);
      expect(() => chdu.section({ window: [[0, 2], [0, 3]] })).toThrow(zf.NotSupportedError);
      // The whole-array transparent decode still works.
      expect(asNums((chdu.data as zf.FitsArray).data).slice(0, 3)).toEqual([0, 1, 2]);
    } finally {
      hdul.close();
    }
  });

  test("update mode: section() reflects an unflushed in-place .data edit (F1)", () => {
    const p = ramp();
    const hdul = zf.open(p, "update");
    try {
      const img = hdul.image(0);
      (img.data as zf.FitsArray).data[8] = 777; // in-place edit, not yet flushed
      // section() flushes first, so it sees 777 (not the stale on-disk 8).
      const cut = img.section({ window: [[1, 2], [2, 3]] }); // the single pixel (1,2) = flat 8
      expect(asNums(cut.data)).toEqual([777]);
    } finally {
      hdul.close();
    }
  });

  test("read-only: section() reads the file as opened, ignoring an in-memory edit (F1)", () => {
    const p = ramp();
    const hdul = zf.open(p); // read-only
    try {
      const img = hdul.image(0);
      (img.data as zf.FitsArray).data[8] = 777; // cannot be persisted in read-only mode
      const cut = img.section({ window: [[1, 2], [2, 3]] });
      expect(asNums(cut.data)).toEqual([8]); // the original file byte
    } finally {
      hdul.close();
    }
  });

  test("section() applies the unsigned (u2) convention like a full read (gap 1)", () => {
    // The unsigned BZERO convention is the scaling path expressible through the
    // high-level write API (arbitrary BSCALE/BZERO are derived from dtype, not
    // settable via the header); section() must honor it exactly as .data does.
    const pu = tmp.path();
    zf.writeTo(pu, new zf.FitsArray(Uint16Array.from([0, 40000, 1, 65535, 2, 3]), [2, 3]), { overwrite: true });
    const hdul = zf.open(pu);
    try {
      const cut = hdul.image(0).section({ window: [[0, 2], [0, 1]] }); // col 0 of both rows
      expect(cut.dtype).toBe("u2");
      expect(asNums(cut.data)).toEqual([0, 65535]);
      // Consistent with the whole-array read.
      expect(asNums((hdul.image(0).data as zf.FitsArray).data)).toEqual([0, 40000, 1, 65535, 2, 3]);
    } finally {
      hdul.close();
    }
  });
});

describe("update-mode table flush (F2)", () => {
  function writeAB(): string {
    const p = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns(
        [
          new zf.Column("A", "1J", { array: Int32Array.from([1, 2, 3]) }),
          new zf.Column("B", "1J", { array: Int32Array.from([10, 20, 30]) }),
        ],
        { name: "T" },
      ),
    ]).writeTo(p, { overwrite: true });
    return p;
  }

  test("a reordered TableData writes each column to its true file slot", () => {
    const p = writeAB();
    {
      const hdul = zf.open(p, "update");
      try {
        // Reversed column order; B is changed, A is unchanged.
        const cols = new Map<string, zf.ColumnData>([
          ["B", { kind: "numeric", dtype: "i4", repeat: 1, values: Int32Array.from([77, 88, 99]) }],
          ["A", { kind: "numeric", dtype: "i4", repeat: 1, values: Int32Array.from([1, 2, 3]) }],
        ]);
        hdul.table(1).data = new zf.TableData(["B", "A"], cols, 3);
      } finally {
        hdul.close(); // flushes
      }
    }
    const hdul = zf.open(p);
    try {
      const rec = hdul.table(1).data!;
      expect(asNums(rec.numeric("A"))).toEqual([1, 2, 3]); // NOT overwritten by B
      expect(asNums(rec.numeric("B"))).toEqual([77, 88, 99]);
    } finally {
      hdul.close();
    }
  });

  test("flushing a column absent from the file fails loud", () => {
    const p = writeAB();
    const hdul = zf.open(p, "update");
    try {
      const cols = new Map<string, zf.ColumnData>([
        ["C", { kind: "numeric", dtype: "i4", repeat: 1, values: Int32Array.from([1, 2, 3]) }],
      ]);
      hdul.table(1).data = new zf.TableData(["C"], cols, 3);
      expect(() => hdul.flush()).toThrow(zf.NotSupportedError);
      // Clear the offending edit so close()'s implicit flush doesn't re-throw.
      hdul.table(1).data = null;
    } finally {
      hdul.close();
    }
  });

  test("mutating a zero-copy row() slice persists on flush (gap 7)", () => {
    const p = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("VEC", "3J", { array: Int32Array.from([1, 2, 3, 4, 5, 6]) })]),
    ]).writeTo(p, { overwrite: true });
    {
      const hdul = zf.open(p, "update");
      try {
        const rec = hdul.table(1).data!;
        (rec.row(0).VEC as zf.TypedArray)[0] = 100; // aliases the column buffer
        hdul.flush();
      } finally {
        hdul.close();
      }
    }
    const hdul = zf.open(p);
    try {
      expect(asNums(hdul.table(1).data!.numeric("VEC"))).toEqual([100, 2, 3, 4, 5, 6]);
    } finally {
      hdul.close();
    }
  });
});

describe("imageFromArray reshape (F5)", () => {
  test("a shape reshapes an existing FitsArray; a bad shape throws", () => {
    const flat = new zf.FitsArray(fill(new Int32Array(6), (i) => i)); // shape [6]
    const hdu = zf.imageFromArray(flat, [2, 3]);
    expect(hdu.data!.shape).toEqual([2, 3]);
    expect(asNums(hdu.data!.data)).toEqual([0, 1, 2, 3, 4, 5]);
    expect(() => zf.imageFromArray(flat, [2, 4])).toThrow(RangeError);
    // Passing a FitsArray with no shape leaves it untouched.
    expect(zf.imageFromArray(flat).data!.shape).toEqual([6]);
  });
});

describe("tableFromArrays inference (F6/F7, gap 4)", () => {
  test("inferTform edge cases", () => {
    expect(zf.inferTform("x", [])).toBe("1J"); // empty plain array
    expect(zf.inferTform("x", [[]])).toBe("1PK"); // uniformly-empty cells -> VLA (F7)
    expect(zf.inferTform("x", [1, 2n] as zf.ColumnArray)).toBe("K"); // mixed safe-int/bigint
    expect(zf.inferTform("x", [NaN])).toBe("D"); // non-integer float
    expect(zf.inferTform("x", ["a", "bb"])).toBe("2A");
    expect(zf.inferTform("x", Int32Array.from([1]))).toBe("J");
    expect(() => zf.inferTform("x", Int8Array.from([1]))).toThrow(zf.FitsTypeError);
  });

  test("nrows must match column data length (else RangeError); empty record allowed", () => {
    expect(() => zf.tableFromArrays({ A: Int32Array.from([1, 2, 3]) }, { nrows: 5 })).toThrow(RangeError);
    // Matching nrows is fine.
    expect(zf.tableFromArrays({ A: Int32Array.from([1, 2, 3]) }, { nrows: 3 })).toBeInstanceOf(zf.BinTableHDU);
    // A column-less table is the only case where nrows is meaningful.
    expect(zf.tableFromArrays({}, { nrows: 2 })).toBeInstanceOf(zf.BinTableHDU);
  });

  test("uniformly-empty cells roundtrip as an (empty) VLA column (F7)", () => {
    const p = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.tableFromArrays({ E: [new Int32Array(0), new Int32Array(0)] }),
    ]).writeTo(p, { overwrite: true });
    const hdul = zf.open(p);
    try {
      const col = hdul.table(1).data!.column("E");
      expect(col.kind).toBe("vla");
      expect((col.values as zf.TypedArray[]).map((c) => c.length)).toEqual([0, 0]);
    } finally {
      hdul.close();
    }
  });

  test("bigint/number/float inference and unsigned TZERO roundtrip (gap 4)", () => {
    const p = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.tableFromArrays({
        BI: BigInt64Array.from([1n, 2n]),
        BL: [10n, 20n],
        NI: [1, 2],
        NF: [1.5, 2.5],
        U4: Uint32Array.from([0, 4000000000]),
        U8: BigUint64Array.from([0n, 18000000000000000000n]),
      }),
    ]).writeTo(p, { overwrite: true });
    const hdul = zf.open(p);
    try {
      const rec = hdul.table(1).data!;
      expect(rec.column("BI").dtype).toBe("i8");
      expect(asNums(rec.numeric("BI"))).toEqual([1, 2]);
      expect(rec.column("BL").dtype).toBe("i8"); // bigint[] -> K
      expect(rec.column("NI").dtype).toBe("i8"); // safe-int number[] -> K
      expect(rec.column("NF").dtype).toBe("f8"); // float number[] -> D
      expect(rec.column("U4").dtype).toBe("u4"); // Uint32Array -> J + TZERO
      expect(Array.from(rec.numeric("U4") as Uint32Array)).toEqual([0, 4000000000]);
      expect(rec.column("U8").dtype).toBe("u8"); // BigUint64Array -> K + TZERO
      expect(Array.from(rec.numeric("U8") as BigUint64Array)).toEqual([0n, 18000000000000000000n]);
    } finally {
      hdul.close();
    }
  });

  test("a non-ASCII string column fails loud at write", () => {
    const p = tmp.path();
    const bad = new zf.HDUList([new zf.PrimaryHDU(), zf.tableFromArrays({ S: ["café"] })]);
    expect(() => bad.writeTo(p, { overwrite: true })).toThrow(zf.FitsTableError);
  });
});

describe("row() degenerate cells + negative indices (gap 3, gap 8)", () => {
  test("complex repeat>1 cell is the 2*repeat interleaved slice", () => {
    const p = tmp.path();
    // 1 row, repeat-2 complex: two complex numbers (1+2i),(3+4i) = 4 floats.
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("C", "2C", { array: Float32Array.from([1, 2, 3, 4]) })]),
    ]).writeTo(p, { overwrite: true });
    const hdul = zf.open(p);
    try {
      const cell = hdul.table(1).data!.row(0).C as zf.TypedArray;
      expect(asNums(cell)).toEqual([1, 2, 3, 4]);
    } finally {
      hdul.close();
    }
  });

  test("a repeat-0 numeric cell is an empty slice (in-memory TableData)", () => {
    const cols = new Map<string, zf.ColumnData>([
      ["Z", { kind: "numeric", dtype: "i4", repeat: 0, values: new Int32Array(0) }],
    ]);
    const rec = new zf.TableData(["Z"], cols, 1);
    const cell = rec.row(0).Z as zf.TypedArray;
    expect(cell.length).toBe(0);
  });

  test("image()/table() accept negative indices (counted from the end)", () => {
    const p = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU({ data: new zf.FitsArray(new Int16Array(4), [2, 2]) }),
      zf.BinTableHDU.fromColumns([new zf.Column("X", "1J", { array: Int32Array.from([1]) })], { name: "T" }),
    ]).writeTo(p, { overwrite: true });
    const hdul = zf.open(p);
    try {
      expect(hdul.table(-1).name).toBe("T"); // last HDU is the table
      expect(hdul.image(-2).kind).toBe("primary"); // first HDU is the image
      expect(() => hdul.image(-1)).toThrow(zf.FitsTypeError); // last is a table
    } finally {
      hdul.close();
    }
  });
});

describe("Header duplicate keywords (gap 10)", () => {
  test("iteration yields every card; get() is first; size counts all", () => {
    const cards = zf.parseCards([
      "DUP     =                    1 / first".padEnd(80),
      "DUP     =                    2 / second".padEnd(80),
    ]);
    const h = zf.Header.fromCards(cards);
    expect(h.get("DUP")).toBe(1); // first wins
    expect(h.size).toBe(2); // counts both
    expect([...h]).toEqual([
      ["DUP", 1],
      ["DUP", 2],
    ]);
    expect(new Map([...h]).size).toBe(1); // Map de-dupes (keeps last)
  });
});
