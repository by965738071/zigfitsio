/**
 * Mirror of `bindings/python/tests/test_bugfixes.py` (JS-adapted).
 *
 * Dropped: the numpy big-endian tests (non-native-endian TypedArrays do not
 * exist) and the pathlib test (paths are strings). The numpy-scalar keyword
 * tests become bigint/number keyword tests.
 */
import { afterAll, describe, expect, test } from "./_harness/index.js";
import * as zf from "../src/index.js";
import * as ll from "../src/lowlevel/index.js";
import { enc } from "../src/util.js";
import { fill, tmpFits } from "./_fixtures.js";
import { readFileSync, existsSync } from "node:fs";

const tmp = tmpFits();
afterAll(() => tmp.cleanup());

const asNums = (a: ArrayLike<number | bigint>): number[] => Array.from(a, (v) => Number(v));

/** Run `build(handle)` against a fresh in-memory FITS handle; return the serialized bytes. */
function bytesFrom(build: (handle: bigint) => void): Uint8Array {
  const out = ll.outU64();
  ll.check(ll.lib.zf_create_memory(null, out));
  const handle = out[0];
  try {
    build(handle);
    ll.check(ll.lib.zf_flush(handle));
    const size = ll.outU64();
    ll.check(ll.lib.zf_data_size(handle, size));
    const buf = new Uint8Array(Number(size[0]));
    const got = ll.outU64();
    ll.check(ll.lib.zf_read_bytes(handle, 0n, buf, buf.length, got));
    return buf.subarray(0, Number(got[0]));
  } finally {
    ll.lib.zf_close(handle);
  }
}

/** A 1-column binary table whose stored ints carry TSCAL/TZERO scaling keywords. */
function scaledColBytes(tform: string, raw: zf.TypedArray, zfCode: number, tscal: number, tzero: number): Uint8Array {
  return bytesFrom((handle) => {
    ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
    ll.check(ll.lib.zf_create_tbl(handle, ll.BINARY_TBL, BigInt(raw.length), 1, ["C1"], [tform], null, null));
    const tout = ll.outU64();
    ll.check(ll.lib.zf_table_open(handle, tout));
    ll.check(ll.lib.zf_write_col(tout[0], zfCode, 0, 1n, BigInt(raw.length), null, raw));
    ll.lib.zf_table_close(tout[0]);
    for (const [kw, val] of [
      ["TSCAL1", tscal],
      ["TZERO1", tzero],
    ] as const) {
      const kb = enc(kw);
      ll.check(ll.lib.zf_write_key_dbl(handle, kb, kb.length, val, null, 0));
    }
  });
}

const filterRows = (rec: zf.TableData, keep: number[]): zf.TableData => {
  const columns = new Map<string, zf.ColumnData>();
  for (const name of rec.names) {
    const col = rec.column(name);
    if (col.kind === "string") {
      columns.set(name, { ...col, values: keep.map((i) => (col.values as string[])[i]) });
    } else if (col.kind === "vla") {
      columns.set(name, { ...col, values: keep.map((i) => (col.values as zf.TypedArray[])[i]) });
    } else {
      const flat = col.values as zf.TypedArray;
      const per = col.kind === "complex" ? col.repeat * 2 : col.repeat;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const out: any = new (flat.constructor as new (n: number) => zf.TypedArray)(keep.length * per);
      keep.forEach((r, k) => out.set(flat.subarray(r * per, (r + 1) * per), k * per));
      columns.set(name, { ...col, values: out });
    }
  }
  return new zf.TableData(rec.names, columns, keep.length);
};

describe("copy preserves data (open → writeTo/toBytes)", () => {
  test("image copy via writeTo", () => {
    const orig = new zf.FitsArray(fill(new Int16Array(6), (i) => i), [2, 3]);
    const src = tmp.path();
    const out = tmp.path();
    zf.writeTo(src, orig);
    const hl = zf.open(src);
    try {
      hl.writeTo(out, { overwrite: true });
    } finally {
      hl.close();
    }
    const got = zf.getData(out) as zf.FitsArray;
    expect(asNums(got.data)).toEqual([0, 1, 2, 3, 4, 5]);
  });

  test("image copy via toBytes", () => {
    const orig = new zf.FitsArray(fill(new Int16Array(6), (i) => i), [2, 3]);
    const src = new zf.HDUList([new zf.PrimaryHDU({ data: orig })]).toBytes();
    const hl = zf.fromBytes(src);
    let copy: Uint8Array;
    try {
      copy = hl.toBytes();
    } finally {
      hl.close();
    }
    const reread = zf.fromBytes(copy);
    try {
      expect(asNums((reread.get(0).data as zf.FitsArray).data)).toEqual([0, 1, 2, 3, 4, 5]);
    } finally {
      reread.close();
    }
  });

  test("table copy preserves rows", () => {
    const col = new zf.Column("X", "1J", { array: fill(new Int32Array(4), (i) => i) });
    const src = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).toBytes();
    const hl = zf.fromBytes(src);
    let copy: Uint8Array;
    try {
      copy = hl.toBytes();
    } finally {
      hl.close();
    }
    const reread = zf.fromBytes(copy);
    try {
      expect(asNums((reread.get(1).data as zf.TableData).get("X") as Int32Array)).toEqual([0, 1, 2, 3]);
    } finally {
      reread.close();
    }
  });
});

describe("closed/detached handles raise, not crash", () => {
  test("use after close raises", () => {
    const src = new zf.HDUList([new zf.PrimaryHDU({ data: fill(new Int16Array(4), (i) => i) })]).toBytes();
    const hl = zf.fromBytes(src);
    const hdu = hl.get(0);
    hl.close();
    expect(() => hdu.data).toThrow(zf.FitsError);
  });

  test("verify of a detached HDUList raises", () => {
    expect(() => zf.verify(new zf.HDUList([new zf.PrimaryHDU({ data: new Int16Array(9) })]))).toThrow(zf.FitsError);
  });
});

describe("unsigned conventions", () => {
  const imgCases: [string, zf.TypedArray][] = [
    ["u2", Uint16Array.from([0, 40000, 65535])],
    ["u4", Uint32Array.from([0, 3000000000, 4294967295])],
    ["u8", BigUint64Array.from([0n, 2n ** 63n, 2n ** 64n - 1n])],
  ];
  for (const [dtype, vals] of imgCases) {
    test(`unsigned ${dtype} image roundtrips`, () => {
      const src = new zf.HDUList([new zf.PrimaryHDU({ data: vals })]).toBytes();
      const hl = zf.fromBytes(src);
      try {
        const got = hl.get(0).data as zf.FitsArray;
        expect(got.dtype).toBe(dtype);
        expect(Array.from(got.data)).toEqual(Array.from(vals));
      } finally {
        hl.close();
      }
    });
  }

  test("fractional scaled column reads float", () => {
    const b = scaledColBytes("1J", Int32Array.from([1, 2, 3, 5]), ll.ZF_INT32, 0.5, 0.25);
    const hl = zf.fromBytes(b);
    try {
      const col = (hl.get(1).data as zf.TableData).column("C1");
      expect(col.dtype).toBe("f8");
      expect(asNums(col.values as Float64Array)).toEqual([0.75, 1.25, 1.75, 2.75]);
    } finally {
      hl.close();
    }
  });

  test("unsigned int16 column reads uint", () => {
    const b = scaledColBytes("1I", Int16Array.from([-32768, 0, 32767]), ll.ZF_INT16, 1.0, 32768.0);
    const hl = zf.fromBytes(b);
    try {
      const col = (hl.get(1).data as zf.TableData).column("C1");
      expect(col.dtype).toBe("u2");
      expect(asNums(col.values as Uint16Array)).toEqual([0, 32768, 65535]);
    } finally {
      hl.close();
    }
  });

  const colCases: [string, string, zf.TypedArray][] = [
    ["u2", "I", Uint16Array.from([0, 40000, 65535])],
    ["u4", "J", Uint32Array.from([0, 3000000000, 4294967295])],
    ["u8", "K", BigUint64Array.from([0n, 2n ** 63n, 2n ** 64n - 1n])],
  ];
  for (const [dtype, tform, vals] of colCases) {
    test(`unsigned ${dtype} column write roundtrips`, () => {
      const src = new zf.HDUList([
        new zf.PrimaryHDU(),
        zf.BinTableHDU.fromColumns([new zf.Column("U", tform, { array: vals })]),
      ]).toBytes();
      const hl = zf.fromBytes(src);
      try {
        const col = (hl.get(1).data as zf.TableData).column("U");
        expect(col.dtype).toBe(dtype);
        expect(Array.from(col.values as zf.TypedArray)).toEqual(Array.from(vals));
      } finally {
        hl.close();
      }
    });
  }
});

describe("VLA columns", () => {
  test("VLA int32 write and read (incl. empty cell)", () => {
    const vla = [Int32Array.from([1, 2, 3]), Int32Array.from([4]), new Int32Array(0)];
    const src = new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("V", "1PJ", { array: vla })]),
    ]).toBytes();
    const hl = zf.fromBytes(src);
    try {
      const col = (hl.get(1).data as zf.TableData).column("V");
      expect(col.kind).toBe("vla");
      expect(col.dtype).toBe("i4");
      const cells = col.values as zf.TypedArray[];
      expect(asNums(cells[0])).toEqual([1, 2, 3]);
      expect(asNums(cells[1])).toEqual([4]);
      expect(cells[2].length).toBe(0);
    } finally {
      hl.close();
    }
  });
});

describe("keyword values", () => {
  test("typed keyword values roundtrip (float / bigint / bool)", () => {
    const h = new zf.Header();
    h.set("FGAIN", 1.5);
    h.set("IGAIN", 1000n); // bigint in → integer card → safe number out
    h.set("FLAG", true);
    const raw = new zf.HDUList([new zf.PrimaryHDU({ data: new Float32Array(4), header: h })]).toBytes();
    const hl = zf.fromBytes(raw);
    try {
      const hh = hl.get(0).header;
      expect(hh.get("FGAIN")).toBeCloseTo(1.5);
      expect(hh.get("IGAIN")).toBe(1000);
      expect(hh.get("FLAG")).toBe(true);
    } finally {
      hl.close();
    }
  });

  test("out-of-range bigint keyword raises", () => {
    const h = new zf.Header();
    h.set("BIG", 2n ** 70n);
    expect(() => new zf.HDUList([new zf.PrimaryHDU({ data: new Float32Array(4), header: h })]).toBytes()).toThrow(
      zf.FitsError,
    );
  });

  test("structural keyword persist raises in update mode", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(Int16Array.from([1, 2, 3]), [1, 3]));
    const hl = zf.open(p, "update");
    try {
      expect(() => hl.get(0).header.set("BITPIX", 32)).toThrow(zf.FitsHeaderError);
    } finally {
      hl.close();
    }
  });
});

describe("long strings and HIERARCH", () => {
  test("CONTINUE long string reassembled", () => {
    const raw = bytesFrom((handle) => {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      const kb = enc("LONGKEY");
      const vb = enc("X".repeat(120));
      ll.check(ll.lib.zf_write_key_longstr(handle, kb, kb.length, vb, vb.length, null, 0));
    });
    const hl = zf.fromBytes(raw);
    try {
      expect(hl.get(0).header.get("LONGKEY")).toBe("X".repeat(120));
    } finally {
      hl.close();
    }
  });

  test("HIERARCH keyword accessible", () => {
    const raw = bytesFrom((handle) => {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      const card = enc("HIERARCH ESO DET GAIN = 2.15 / detector gain".padEnd(80));
      ll.check(ll.lib.zf_write_record(handle, card));
    });
    const hl = zf.fromBytes(raw);
    try {
      const hh = hl.get(0).header;
      expect(hh.get("ESO DET GAIN")).toBeCloseTo(2.15);
      expect(hh.keys()).toContain("ESO DET GAIN");
    } finally {
      hl.close();
    }
  });
});

describe("construction guards", () => {
  test("ragged fromColumns raises", () => {
    expect(() =>
      zf.BinTableHDU.fromColumns([
        new zf.Column("A", "1J", { array: fill(new Int32Array(5), (i) => i) }),
        new zf.Column("B", "1J", { array: fill(new Int32Array(2), (i) => i) }),
      ]),
    ).toThrow(RangeError);
  });

  test("empty HDUList raises", () => {
    expect(() => new zf.HDUList([]).toBytes()).toThrow();
  });

  test("non-ASCII column raises", () => {
    const col = new zf.Column("S", "8A", { array: ["café", "ok"] });
    expect(() => new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).toBytes()).toThrow(
      zf.FitsError,
    );
  });
});

describe("update-mode write-back and lifecycle", () => {
  test("update mode writes image data back on flush", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(6), [2, 3]));
    const hl = zf.open(p, "update");
    try {
      (hl.get(0).data as zf.FitsArray).set(999.0, 0, 0);
      hl.flush();
    } finally {
      hl.close();
    }
    expect((zf.getData(p) as zf.FitsArray).get(0, 0)).toBe(999.0);
  });

  test("update mode flushes on close (no explicit flush)", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(4), [2, 2]));
    const hl = zf.open(p, "update");
    const img = hl.get(0).data as zf.FitsArray;
    (img.data as Float32Array).fill(7.0);
    hl.close();
    expect((zf.getData(p) as zf.FitsArray).get(0, 0)).toBe(7.0);
  });

  test("update-mode table write-back on close", () => {
    const p = tmp.path();
    const col = new zf.Column("FLUX", "1E", { array: Float32Array.from([1, 2, 3]) });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).writeTo(p);
    const hl = zf.open(p, "update");
    ((hl.get(1).data as zf.TableData).get("FLUX") as Float32Array).fill(99.0);
    hl.close();
    const chk = zf.open(p);
    try {
      expect(asNums((chk.get(1).data as zf.TableData).get("FLUX") as Float32Array)).toEqual([99, 99, 99]);
    } finally {
      chk.close();
    }
  });

  test("appended HDU persists on close", () => {
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(fill(new Int16Array(4), () => 1), [2, 2]) })]).writeTo(p);
    const hl = zf.open(p, "update");
    hl.append(new zf.ImageHDU({ data: fill(new Int16Array(4), (i) => i), name: "NEW" }));
    hl.close();
    const chk = zf.open(p);
    try {
      expect(chk.length).toBe(2);
      expect(asNums((chk.get("NEW").data as zf.FitsArray).data)).toEqual([0, 1, 2, 3]);
    } finally {
      chk.close();
    }
  });

  test("in-place compressed update fails loud", () => {
    const p = tmp.path();
    const img = new zf.FitsArray(fill(new Int16Array(16), (i) => i), [4, 4]);
    new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: img, compression: "RICE_1" })]).writeTo(p);
    const hl = zf.open(p, "update");
    (hl.get(1).data as zf.FitsArray).set(123, 0, 0);
    expect(() => hl.close()).toThrow(zf.NotSupportedError);
  });
});

describe("readonly-open edits and the pristine fast path", () => {
  test("readonly edit reflected in writeTo (reconstruction)", () => {
    const src = tmp.path();
    const out = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(fill(new Int16Array(12), () => 1), [3, 4]) })]).writeTo(src);
    const hl = zf.open(src); // default read-only
    const scaled = (hl.get(0).data as zf.FitsArray).clone();
    (scaled.data as Int16Array).forEach((v, i) => ((scaled.data as Int16Array)[i] = v * 10));
    (hl.get(0) as zf.ImageHDU).data = scaled;
    hl.get(0).header.set("MYKEY", 42);
    hl.writeTo(out, { overwrite: true });
    hl.close();
    const chk = zf.open(out);
    try {
      expect((chk.get(0).data as zf.FitsArray).get(0, 1)).toBe(10);
      expect(chk.get(0).header.get("MYKEY")).toBe(42);
    } finally {
      chk.close();
    }
  });

  test("in-place mutation of a readonly open is saved (no stale fast path)", () => {
    const src = tmp.path();
    const out = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(fill(new Int16Array(12), () => 1), [3, 4]) })]).writeTo(src);
    const hl = zf.open(src); // read-only
    ((hl.get(0).data as zf.FitsArray).data as Int16Array).fill(7); // in-place; does NOT call the setter
    hl.writeTo(out, { overwrite: true });
    hl.close();
    const chk = zf.open(out);
    try {
      expect((chk.get(0).data as zf.FitsArray).get(0, 0)).toBe(7);
    } finally {
      chk.close();
    }

    // In-place table cell edit on a read-only open, via toBytes.
    const src2 = tmp.path();
    const col = new zf.Column("FLUX", "1E", { array: Float32Array.from([1, 2, 3]) });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).writeTo(src2);
    const h2 = zf.open(src2);
    ((h2.get(1).data as zf.TableData).get("FLUX") as Float32Array).fill(42.0);
    const reread = zf.fromBytes(h2.toBytes());
    h2.close();
    try {
      expect(asNums((reread.get(1).data as zf.TableData).get("FLUX") as Float32Array)).toEqual([42, 42, 42]);
    } finally {
      reread.close();
    }
  });

  test("unchanged readonly open still copies verbatim (data preserved)", () => {
    const src = tmp.path();
    const out = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(fill(new Int16Array(12), (i) => i), [3, 4]) })]).writeTo(src);
    const hl = zf.open(src);
    void hl.get(0).data; // materialize, but do not edit
    hl.writeTo(out, { overwrite: true });
    hl.close();
    // Verbatim copy: byte-identical to the source.
    expect(Buffer.compare(readFileSync(out), readFileSync(src))).toBe(0);
  });

  test("failed writeTo leaves no partial file", () => {
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: fill(new Int16Array(3), () => 1) })]).writeTo(p);
    const before = readFileSync(p);

    class Boom extends zf.PrimaryHDU {
      override _writeTo(): void {
        throw new Error("boom");
      }
    }
    expect(() => new zf.HDUList([new Boom({ data: new Int16Array(2) })]).writeTo(p, { overwrite: true })).toThrow("boom");
    expect(Buffer.compare(readFileSync(p), before)).toBe(0); // original intact
    expect(existsSync(p + ".zigfitsio.tmp")).toBe(false);
  });
});

describe("review regressions (2026-07-04)", () => {
  test("complex column write derives the transfer code from the buffer, not the TFORM", () => {
    // Float32Array into a 1M (c16) column: the old code declared f64 over an
    // f32 buffer — a 2x heap overread. Both mixed-width directions must
    // round-trip by value.
    const f32into1M = new zf.Column("C", "1M", { array: Float32Array.from([1, 2, -3, 4]) });
    const src1 = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([f32into1M])]).toBytes();
    const hl1 = zf.fromBytes(src1);
    try {
      const col = (hl1.get(1).data as zf.TableData).column("C");
      expect(col.dtype).toBe("c16");
      expect(asNums(col.values as Float64Array)).toEqual([1, 2, -3, 4]);
    } finally {
      hl1.close();
    }

    const f64into1C = new zf.Column("C", "1C", { array: Float64Array.from([1.5, -2, 3, 4.25]) });
    const src2 = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([f64into1C])]).toBytes();
    const hl2 = zf.fromBytes(src2);
    try {
      const col = (hl2.get(1).data as zf.TableData).column("C");
      expect(col.dtype).toBe("c8");
      const got = col.values as Float32Array;
      [1.5, -2, 3, 4.25].forEach((w, i) => expect(Math.abs(got[i] - w)).toBeLessThan(1e-6));
    } finally {
      hl2.close();
    }
  });

  test("plain number[] into a K column: rounds via f8, overflows loudly (no BigInt wrap)", () => {
    const ok = new zf.Column("X", "1K", { array: [1.4, 2.6] });
    const src = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([ok])]).toBytes();
    const hl = zf.fromBytes(src);
    try {
      expect(Array.from((hl.get(1).data as zf.TableData).get("X") as BigInt64Array)).toEqual([1n, 3n]);
    } finally {
      hl.close();
    }

    const big = new zf.Column("X", "1K", { array: [1e20] });
    expect(() => new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([big])]).toBytes()).toThrow(
      zf.FitsError,
    );
  });

  test("non-integer / out-of-range VLA K cells: typed rounding and overflow", () => {
    const ok = new zf.Column("V", "1PK", { array: [[1.4], [2.6]] });
    const src = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([ok])]).toBytes();
    const hl = zf.fromBytes(src);
    try {
      const cells = (hl.get(1).data as zf.TableData).get("V") as zf.TypedArray[];
      expect(Array.from(cells[0] as BigInt64Array)).toEqual([1n]);
      expect(Array.from(cells[1] as BigInt64Array)).toEqual([3n]);
    } finally {
      hl.close();
    }

    const over = new zf.Column("V", "1PK", { array: [[1e20]] });
    expect(() => new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([over])]).toBytes()).toThrow(
      zf.FitsOverflowError,
    );
  });

  test("non-numeric values in a numeric column throw FitsTypeError, not silent NaN", () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const bad = new zf.Column("X", "1J", { array: ["a", "b"] as any });
    expect(() => new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([bad])]).toBytes()).toThrow(
      zf.FitsTypeError,
    );
  });

  test("integer keywords in (2^53, 2^63) stay integer cards through reconstruction", () => {
    const h = new zf.Header();
    h.set("OBSID", 9007199254740994); // 2^53+2, exact as a double
    const raw = new zf.HDUList([new zf.PrimaryHDU({ data: new Int16Array(4), header: h })]).toBytes();
    const hl = zf.fromBytes(raw);
    try {
      expect(hl.get(0).header.get("OBSID")).toBe(9007199254740994);
      const handle = hl._handle as bigint;
      ll.check(ll.lib.zf_select(handle, 1));
      const n = ll.newLongArray(1);
      ll.check(ll.lib.zf_card_count(handle, n));
      let card = "";
      for (let i = 0; i < ll.readLongAt(n, 0); i++) {
        const buf = new Uint8Array(80);
        ll.check(ll.lib.zf_read_card(handle, i, buf));
        const s = new TextDecoder().decode(buf);
        if (s.startsWith("OBSID")) card = s;
      }
      expect(card).toContain("9007199254740994");
      expect(card.includes("E")).toBe(false); // an integer card, not 9.00719...E15
    } finally {
      hl.close();
    }
  });

  test("a valueless BSCALE card marks the image as scaled (reads f8, mirroring Python)", () => {
    const raw = bytesFrom((handle) => {
      const axes = ll.longArray([4]);
      ll.check(ll.lib.zf_create_img(handle, 16, 1, axes));
      const pix = Int16Array.from([1, 2, 3, 4]);
      ll.check(ll.lib.zf_write_img(handle, ll.ZF_INT16, 1n, 4n, null, null, pix));
      ll.check(ll.lib.zf_write_record(handle, enc("BSCALE  = ".padEnd(80))));
    });
    const hl = zf.fromBytes(raw);
    try {
      const img = hl.get(0).data as zf.FitsArray;
      expect(img.dtype).toBe("f8");
      expect(asNums(img.data)).toEqual([1, 2, 3, 4]);
    } finally {
      hl.close();
    }
  });

  test("a zero-width (0A) string column reads as empty strings, not an error", () => {
    const raw = bytesFrom((handle) => {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      ll.check(ll.lib.zf_create_tbl(handle, ll.BINARY_TBL, 2n, 1, ["S"], ["0A"], null, null));
    });
    const hl = zf.fromBytes(raw);
    try {
      expect((hl.get(1).data as zf.TableData).get("S")).toEqual(["", ""]);
    } finally {
      hl.close();
    }
  });
});

describe("misc parity", () => {
  test("getData falls through an empty primary", () => {
    const p = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("X", "1J", { array: fill(new Int32Array(3), (i) => i) })]),
    ]).writeTo(p);
    const data = zf.getData(p);
    expect(data).not.toBeNull();
    expect((data as zf.TableData).names).toContain("X");
  });

  test("PRIMARY name alias", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(Int16Array.from([1, 2]), [1, 2]));
    const hl = zf.open(p);
    try {
      expect(hl.get("PRIMARY")).toBe(hl.get(0));
    } finally {
      hl.close();
    }
  });

  test("unknown open mode raises", () => {
    const p = tmp.path();
    zf.writeTo(p, new Int16Array(2));
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(() => zf.open(p, "rw" as any)).toThrow();
  });

  test("bit 'X' column roundtrips under the one-byte-per-bit convention", () => {
    const bits = Uint8Array.from([1, 0, 1, 0, 1, 0, 1, 0]);
    const src = new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("B", "8X", { array: bits })]),
    ]).toBytes();
    const hl = zf.fromBytes(src);
    try {
      const col = (hl.get(1).data as zf.TableData).column("B");
      expect(col.repeat).toBe(8);
      expect(asNums(col.values as Uint8Array)).toEqual([1, 0, 1, 0, 1, 0, 1, 0]);
    } finally {
      hl.close();
    }
  });

  test("table data setter replaces rows (filter / same-count update / count-change fails loud)", () => {
    const mk = (p: string, n: number): void => {
      const cols = [
        new zf.Column("IDX", "1J", { array: fill(new Int32Array(n), (i) => i) }),
        new zf.Column("V", "1E", { array: fill(new Float32Array(n), (i) => i * 1.5) }),
      ];
      new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns(cols)]).writeTo(p, { overwrite: true });
    };

    // Filter rows via the setter; writeTo reconstructs.
    const src = tmp.path();
    const out = tmp.path();
    mk(src, 6);
    const h = zf.open(src);
    const rec = h.get(1).data as zf.TableData;
    const idx = rec.get("IDX") as Int32Array;
    const keep = [...idx.keys()].filter((i) => idx[i] % 2 === 0);
    (h.get(1) as zf.BinTableHDU).data = filterRows(rec, keep);
    h.writeTo(out, { overwrite: true });
    h.close();
    const chk = zf.open(out);
    try {
      expect(asNums((chk.get(1).data as zf.TableData).get("IDX") as Int32Array)).toEqual([0, 2, 4]);
    } finally {
      chk.close();
    }

    // update-mode assignment with the SAME row count persists on close.
    const u = tmp.path();
    mk(u, 4);
    {
      const hu = zf.open(u, "update");
      const r = hu.get(1).data as zf.TableData;
      const filtered = filterRows(r, [0, 1, 2, 3]);
      (filtered.get("IDX") as Int32Array).set([10, 20, 30, 40]);
      (hu.get(1) as zf.BinTableHDU).data = filtered;
      hu.close();
    }
    const chk2 = zf.open(u);
    try {
      expect(asNums((chk2.get(1).data as zf.TableData).get("IDX") as Int32Array)).toEqual([10, 20, 30, 40]);
    } finally {
      chk2.close();
    }

    // update-mode row-count change in place is unsupported -> fail loud, file intact.
    const r2 = tmp.path();
    mk(r2, 5);
    {
      const hr = zf.open(r2, "update");
      const rec5 = hr.get(1).data as zf.TableData;
      (hr.get(1) as zf.BinTableHDU).data = filterRows(rec5, [0, 1, 2]);
      expect(() => hr.close()).toThrow(zf.NotSupportedError);
    }
    const chk3 = zf.open(r2);
    try {
      expect((chk3.get(1).data as zf.TableData).nrows).toBe(5);
    } finally {
      chk3.close();
    }
  });
});

// BUGHUNT-2026-07-06 CRIT #1 (table) and HIGH #7 (compressed image): the
// reconstruction write path rebuilt the HDU via the C ABI but never re-emitted
// the user's non-structural header cards, so every writeTo/toBytes silently
// erased scientific metadata while the data survived. Mirrors the image path,
// which has always called _applyUserKeys.
describe("user header keywords survive reconstruction (table + compressed image)", () => {
  const dup = (h: zf.Header, kw: string): number => h.keys().filter((k) => k === kw).length;

  test("#1 detached table: user keyword + COMMENT + HISTORY survive writeTo", () => {
    const idx = Int32Array.from([10, 20, 30]);
    const hdu = zf.BinTableHDU.fromColumns([new zf.Column("INDEX", "J", { array: idx })], { name: "EVENTS" });
    hdu.header.set("OBSERVER", "Hubble", "who");
    hdu.header.set("COMMENT", "provenance note");
    hdu.header.set("HISTORY", "reduced with pipeline");
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), hdu]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const h = hdul.get(1).header;
      expect(h.get("OBSERVER")).toBe("Hubble");
      expect(h.commentOf("OBSERVER")).toBe("who");
      expect(h.comments).toContain("provenance note");
      expect(h.history).toContain("reduced with pipeline");
      // Data still round-trips, and the structural cards zf_create_tbl emits are
      // not duplicated by the re-applied user header.
      expect(asNums((hdul.get(1).data as zf.TableData).get("INDEX") as Int32Array)).toEqual([10, 20, 30]);
      expect(dup(h, "EXTNAME")).toBe(1);
      expect(dup(h, "TFORM1")).toBe(1);
      expect(dup(h, "TTYPE1")).toBe(1);
    } finally {
      hdul.close();
    }
  });

  test("#1 attached table: checksum:true on an untouched file reconstructs without dropping keys", () => {
    // Fixture: a plain table (the columns/EXTNAME path was never broken), then
    // add OBSERVER in update mode — an in-place write independent of the
    // reconstruction path, so the source provably carries the keyword.
    const src = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([new zf.Column("INDEX", "J", { array: Int32Array.from([1, 2, 3]) })], { name: "EVENTS" })]).writeTo(src);
    {
      const up = zf.open(src, "update");
      up.get(1).header.set("OBSERVER", "Kepler", "who");
      up.close();
    }
    const out = tmp.path();
    const ro = zf.open(src); // read-only, untouched
    try {
      expect(ro.get(1).header.get("OBSERVER")).toBe("Kepler"); // sanity: fixture carries it
      ro.writeTo(out, { checksum: true, overwrite: true }); // checksum bypasses the pristine fast path
    } finally {
      ro.close();
    }
    const chk = zf.open(out);
    try {
      expect(chk.get(1).header.get("OBSERVER")).toBe("Kepler");
      expect(chk.get(1).header.commentOf("OBSERVER")).toBe("who");
      expect(dup(chk.get(1).header, "EXTNAME")).toBe(1);
    } finally {
      chk.close();
    }
  });

  test("#7 attached compressed image: a header edit reconstructs, keeps EXTNAME, and does not duplicate Z* cards", () => {
    const ramp = new zf.FitsArray(fill(new Int32Array(256), (i) => i), [16, 16]);
    const src = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: ramp, compression: "RICE_1", name: "COMP" })]).writeTo(src);
    const out = tmp.path();
    const hl = zf.open(src);
    hl.get(1).header.set("MYKEY", 7); // read-only edit → dirty → reconstruction
    hl.writeTo(out, { overwrite: true });
    hl.close();
    const chk = zf.open(out);
    try {
      const h = chk.get(1).header;
      expect(h.get("MYKEY")).toBe(7); // the edit survives reconstruction
      expect(chk.get(1).name).toBe("COMP"); // EXTNAME preserved (no manual block needed)
      expect(dup(h, "ZCMPTYPE")).toBe(1); // the ZIMAGE-convention cards are not re-emitted
      const got = chk.get(1).data as zf.FitsArray; // still a decompressable image
      expect(got.shape).toEqual([16, 16]);
      expect(asNums(got.data)).toEqual(asNums(ramp.data));
    } finally {
      chk.close();
    }
  });

  test("#7 detached compressed image: a header keyword survives writeTo", () => {
    const ramp = new zf.FitsArray(fill(new Int32Array(256), (i) => i), [16, 16]);
    const hdr = new zf.Header();
    hdr.set("BUNIT", "adu", "brightness unit");
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: ramp, compression: "RICE_1", header: hdr, name: "COMP" })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const h = hdul.get(1).header;
      expect(h.get("BUNIT")).toBe("adu");
      expect(h.commentOf("BUNIT")).toBe("brightness unit");
      expect(hdul.get(1).name).toBe("COMP");
      expect(dup(h, "ZCMPTYPE")).toBe(1);
    } finally {
      hdul.close();
    }
  });

  test("stale CHECKSUM/DATASUM are dropped on checksum:false reconstruction (verify stays clean)", () => {
    // A checksummed table file; an unrelated header edit then forces the
    // reconstruction path with checksum:false (the default). The source's
    // per-HDU CHECKSUM/DATASUM describe the original bytes and must not be
    // carried forward — a copied one no longer verifies.
    const src = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("INDEX", "J", { array: Int32Array.from([1, 2, 3]) })], { name: "EVENTS" }),
    ]).writeTo(src, { checksum: true });
    expect(zf.verify(src).filter((f) => f.severity === "error")).toEqual([]); // sanity: source is clean

    const out = tmp.path();
    const hl = zf.open(src);
    hl.get(1).header.set("OBSERVER", "Rubin"); // edit → dirty → reconstruction
    hl.writeTo(out, { overwrite: true }); // checksum:false (default)
    hl.close();

    const chk = zf.open(out);
    try {
      expect(chk.get(1).header.keys()).not.toContain("CHECKSUM"); // stale card not copied
      expect(chk.get(1).header.keys()).not.toContain("DATASUM");
      expect(chk.get(1).header.get("OBSERVER")).toBe("Rubin"); // the edit still survives
    } finally {
      chk.close();
    }
    expect(zf.verify(out).filter((f) => f.severity === "error")).toEqual([]); // no invalid-checksum error
  });
});
