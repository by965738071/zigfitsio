/** Mirror of `bindings/python/tests/test_highlevel.py`. */
import { afterAll, describe, expect, test } from "./_harness/index.js";
import * as zf from "../src/index.js";
import * as ll from "../src/lowlevel/index.js";
import { fill, tmpFits } from "./_fixtures.js";

const tmp = tmpFits();
afterAll(() => tmp.cleanup());

const asNums = (a: ArrayLike<number | bigint>): number[] => Array.from(a, (v) => Number(v));

describe("images", () => {
  test("image write/read roundtrip", () => {
    const data = new zf.FitsArray(fill(new Float32Array(24), (i) => i * 0.25), [4, 6]);
    const p = tmp.path();
    zf.writeTo(p, data);
    const hdul = zf.open(p);
    try {
      const got = hdul.get(0).data as zf.FitsArray;
      expect(got.shape).toEqual([4, 6]);
      expect(got.dtype).toBe("f4");
      expect(asNums(got.data)).toEqual(asNums(data.data));
    } finally {
      hdul.close();
    }
  });

  const cases: [zf.Dtype, zf.TypedArray][] = [
    ["u1", fill(new Uint8Array(12), (i) => i)],
    ["i2", fill(new Int16Array(12), (i) => i)],
    ["i4", fill(new Int32Array(12), (i) => i)],
    ["i8", fill(new BigInt64Array(12), (i) => BigInt(i))],
    ["f4", fill(new Float32Array(12), (i) => i)],
    ["f8", fill(new Float64Array(12), (i) => i)],
  ];
  for (const [dtype, arr] of cases) {
    test(`image all-BITPIX roundtrip: ${dtype}`, () => {
      const p = tmp.path();
      zf.writeTo(p, new zf.FitsArray(arr, [3, 4]));
      const hdul = zf.open(p);
      try {
        const got = hdul.get(0).data as zf.FitsArray;
        expect(got.dtype).toBe(dtype);
        expect(asNums(got.data)).toEqual(asNums(arr));
      } finally {
        hdul.close();
      }
    });
  }

  test("image section via lowlevel zf_read_subset", () => {
    const data = new zf.FitsArray(fill(new Int16Array(16), (i) => i), [4, 4]);
    const p = tmp.path();
    zf.writeTo(p, data);
    const hdul = zf.open(p);
    try {
      const h = hdul._handle as bigint;
      ll.check(ll.lib.zf_select(h, 1));
      const lower = ll.longArray([0, 0]);
      const upper = ll.longArray([1, 1]);
      const out = new Int16Array(4);
      ll.check(ll.lib.zf_read_subset(h, ll.ZF_INT16, 2, lower, upper, null, 4n, null, null, out));
      // FITS section (x:0..1, y:0..1) → flat 0,1,4,5
      expect(Array.from(out)).toEqual([0, 1, 4, 5]);
    } finally {
      hdul.close();
    }
  });
});

describe("headers", () => {
  test("header dict access and edit", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(9), [3, 3]));
    {
      const hdul = zf.open(p, "update");
      try {
        const hdr = hdul.get(0).header;
        expect(hdr.get("NAXIS")).toBe(2);
        expect(hdr.has("BITPIX")).toBe(true);
        hdr.set("OBSERVER", "Hubble", "who");
      } finally {
        hdul.close();
      }
    }
    const hdul = zf.open(p);
    try {
      expect(hdul.get(0).header.get("OBSERVER")).toBe("Hubble");
      expect(hdul.get(0).header.commentOf("OBSERVER")).toBe("who");
    } finally {
      hdul.close();
    }
  });
});

describe("tables", () => {
  test("binary table roundtrip", () => {
    const idx = Int32Array.from([10, 20, 30]);
    const flux = Float32Array.from([1.5, 2.5, 3.5]);
    const names = ["alpha", "beta", "gamma"];
    const cols = [
      new zf.Column("INDEX", "J", { array: idx }),
      new zf.Column("FLUX", "E", { array: flux, unit: "Jy" }),
      new zf.Column("NAME", "8A", { array: names }),
    ];
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns(cols, { name: "EVENTS" })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      expect(hdul.get(1).name).toBe("EVENTS");
      const rec = hdul.get(1).data as zf.TableData;
      expect(asNums(rec.get("INDEX") as Int32Array)).toEqual([10, 20, 30]);
      const gotFlux = rec.get("FLUX") as Float32Array;
      for (let i = 0; i < 3; i++) expect(Math.abs(gotFlux[i] - flux[i])).toBeLessThan(1e-6);
      expect(rec.get("NAME")).toEqual(names);
    } finally {
      hdul.close();
    }
  });

  test("vector column", () => {
    const vec = fill(new Int32Array(9), (i) => i);
    const cols = [new zf.Column("VEC", "3J", { array: vec })];
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns(cols)]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const col = (hdul.get(1).data as zf.TableData).column("VEC");
      expect(col.repeat).toBe(3);
      expect(asNums(col.values as Int32Array)).toEqual(asNums(vec));
    } finally {
      hdul.close();
    }
  });
});

describe("compression / bytes / integrity / wcs", () => {
  test("RICE compression roundtrip", () => {
    const ramp = new zf.FitsArray(fill(new Int32Array(256), (i) => i), [16, 16]);
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: ramp, compression: "RICE_1" })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const got = hdul.get(1).data as zf.FitsArray;
      expect(got.shape).toEqual([16, 16]);
      expect(asNums(got.data)).toEqual(asNums(ramp.data));
    } finally {
      hdul.close();
    }
  });

  test("toBytes / fromBytes roundtrip", () => {
    const data = new zf.FitsArray(fill(new Float64Array(20), (i) => i), [4, 5]);
    const raw = new zf.HDUList([new zf.PrimaryHDU({ data })]).toBytes();
    expect(new TextDecoder().decode(raw.subarray(0, 6))).toBe("SIMPLE");
    const hdul = zf.fromBytes(raw);
    try {
      expect(asNums((hdul.get(0).data as zf.FitsArray).data)).toEqual(asNums(data.data));
    } finally {
      hdul.close();
    }
  });

  test("checksum write + verify has no error findings", () => {
    const data = new zf.FitsArray(fill(new Float32Array(16), (i) => i), [4, 4]);
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data })]).writeTo(p, { checksum: true });
    const findings = zf.verify(p);
    expect(findings.filter((f) => f.severity === "error")).toEqual([]);
  });

  test("WCS pix2world/world2pix roundtrip", () => {
    const hdr = new zf.Header();
    hdr.set("CTYPE1", "RA---TAN");
    hdr.set("CTYPE2", "DEC--TAN");
    hdr.set("CRPIX1", 32.0);
    hdr.set("CRPIX2", 32.0);
    hdr.set("CRVAL1", 150.0);
    hdr.set("CRVAL2", 2.0);
    hdr.set("CDELT1", -0.001);
    hdr.set("CDELT2", 0.001);
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(new Float32Array(64 * 64), [64, 64]), header: hdr })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const img = hdul.get(0) as zf.ImageHDU;
      const [lon, lat] = img.pix2world(40.0, 30.0);
      const [px, py] = img.world2pix(lon, lat);
      expect(Math.abs(px - 40.0)).toBeLessThan(1e-6);
      expect(Math.abs(py - 30.0)).toBeLessThan(1e-6);
    } finally {
      hdul.close();
    }
  });
});
