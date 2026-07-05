/** Mirror of `bindings/python/tests/test_api_surface.py` (JS-adapted). */
import { afterAll, describe, expect, test } from "./_harness/index.js";
import * as zf from "../src/index.js";
import * as ll from "../src/lowlevel/index.js";
import { enc } from "../src/util.js";
import { fill, goldenPath, hasGoldenFile, tmpFits } from "./_fixtures.js";
import { testIf } from "./_harness/index.js";

const tmp = tmpFits();
afterAll(() => tmp.cleanup());

const asNums = (a: ArrayLike<number | bigint>): number[] => Array.from(a, (v) => Number(v));

/** Deterministic noise (LCG), mirroring the seeded rng in the Python test. */
function noisyField(n: number): Float32Array {
  const out = new Float32Array(n * n);
  let state = 42 >>> 0;
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) {
      state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
      out[r * n + c] = Math.fround(10.0 + (r + c) * 0.5 + ((state >>> 8) / 2 ** 24) * 8.0);
    }
  }
  return out;
}

describe("metadata + conveniences", () => {
  test("VERSION is the lowlevel version string", () => {
    expect(typeof zf.VERSION).toBe("string");
    expect(zf.VERSION).toBe(ll.version());
  });

  test("getHeader", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(4), [2, 2]));
    const hdr = zf.getHeader(p);
    expect(hdr).toBeInstanceOf(zf.Header);
    expect(hdr.get("NAXIS")).toBe(2);
  });

  test("getVal", () => {
    const p = tmp.path();
    const h = new zf.Header();
    h.set("OBSERVER", "Kepler");
    zf.writeTo(p, new zf.FitsArray(new Float32Array(4), [2, 2]), { header: h });
    expect(zf.getVal(p, "OBSERVER")).toBe("Kepler");
  });

  test("getData with header and explicit ext", () => {
    const p = tmp.path();
    const col = new zf.Column("X", "1J", { array: fill(new Int32Array(3), (i) => i) });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col], { name: "T" })]).writeTo(p);
    const { data, header } = zf.getData(p, { ext: 1, header: true });
    expect((data as zf.TableData).names).toContain("X");
    expect(header.get("EXTNAME")).toBe("T");
  });
});

describe("image extensions and ASCII tables", () => {
  test("image extension roundtrip", () => {
    const primaryData = new zf.FitsArray(new Int16Array(4), [2, 2]);
    const extData = new zf.FitsArray(fill(new Float32Array(6), (i) => i), [2, 3]);
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: primaryData }), new zf.ImageHDU({ data: extData, name: "EXT1" })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      expect(hdul.length).toBe(2);
      expect(hdul.get(1)).toBeInstanceOf(zf.ImageHDU);
      expect(hdul.get(1).name).toBe("EXT1");
      expect(asNums((hdul.get(1).data as zf.FitsArray).data)).toEqual([0, 1, 2, 3, 4, 5]);
      expect(asNums((hdul.get(0).data as zf.FitsArray).data)).toEqual([0, 0, 0, 0]);
    } finally {
      hdul.close();
    }
  });

  test("ASCII table write and read", () => {
    const ids = Int32Array.from([1, 2, 3]);
    const flux = Float64Array.from([1.25, 2.5, 3.75]);
    const names = ["alpha", "beta", "gamma"];
    const cols = [
      new zf.Column("ID", "I6", { array: ids }),
      new zf.Column("FLUX", "F12.4", { array: flux }),
      new zf.Column("NAME", "A5", { array: names }),
    ];
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), zf.AsciiTableHDU.fromColumns(cols, { name: "AT" })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      expect(hdul.get(1)).toBeInstanceOf(zf.AsciiTableHDU);
      const rec = hdul.get(1).data as zf.TableData;
      expect(asNums(rec.get("ID") as zf.TypedArray)).toEqual([1, 2, 3]);
      const gotFlux = rec.get("FLUX") as zf.TypedArray;
      for (let i = 0; i < 3; i++) expect(Math.abs(Number(gotFlux[i]) - flux[i])).toBeLessThan(1e-6);
      expect((rec.get("NAME") as string[]).map((s) => s.trim())).toEqual(names);
    } finally {
      hdul.close();
    }
  });
});

describe("typed errors", () => {
  test("FitsIOError on missing file", () => {
    expect(() => zf.open(tmp.path() + "-does-not-exist.fits")).toThrow(zf.FitsIOError);
  });

  test("FitsHeaderError on an undefined keyword value (lowlevel)", () => {
    const out = ll.outU64();
    ll.check(ll.lib.zf_create_memory(null, out));
    const handle = out[0];
    try {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      ll.check(ll.lib.zf_write_record(handle, enc("UNDEF   = ".padEnd(80))));
      const v = ll.outF64();
      const key = enc("UNDEF");
      expect(() => ll.check(ll.lib.zf_read_key_dbl(handle, key, key.length, v))).toThrow(zf.FitsHeaderError);
    } finally {
      ll.lib.zf_close(handle);
    }
  });

  test("FitsTableError on a missing column (lowlevel)", () => {
    const p = tmp.path();
    const col = new zf.Column("X", "1J", { array: fill(new Int32Array(3), (i) => i) });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const h = hdul.get(1)._select();
      const tout = ll.outU64();
      ll.check(ll.lib.zf_table_open(h, tout));
      try {
        const colnum = ll.outI32();
        const name = enc("NOSUCH");
        expect(() => ll.check(ll.lib.zf_table_colnum(tout[0], name, name.length, colnum))).toThrow(zf.FitsTableError);
      } finally {
        ll.lib.zf_table_close(tout[0]);
      }
    } finally {
      hdul.close();
    }
  });

  test("FitsWcsError when no WCS is present", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(16), [4, 4]));
    const hdul = zf.open(p);
    try {
      expect(() => (hdul.get(0) as zf.ImageHDU).pix2world(1.0, 1.0)).toThrow(zf.FitsWcsError);
    } finally {
      hdul.close();
    }
  });

  test("i1 image write is a documented unsupported dtype", () => {
    expect(() => new zf.HDUList([new zf.PrimaryHDU({ data: Int8Array.from([-1, 0, 1]) })]).toBytes()).toThrow(
      zf.FitsTypeError,
    );
  });
});

describe("Header surface", () => {
  test("mapping protocol on a detached header", () => {
    const h = new zf.Header();
    h.set("A", 1);
    h.set("B", "two", "a comment");

    expect(h.get("A")).toBe(1);
    expect(h.get("NOSUCH", "fallback")).toBe("fallback");
    expect([...h]).toEqual([
      ["A", 1],
      ["B", "two"],
    ]);
    expect(h.keys()).toEqual(["A", "B"]);
    expect(h.length).toBe(2);
    expect(h.entries()).toEqual([
      ["A", 1],
      ["B", "two"],
    ]);
    expect(h.values()).toEqual([1, "two"]);
    expect(h.cards().map((c) => c[0])).toEqual(["A", "B"]);
    expect(h.toString()).toContain("A");
    expect(h.toString()).toContain("B");

    h.delete("A");
    expect(h.has("A")).toBe(false);
    expect(h.length).toBe(1);
    expect(() => h.delete("NOSUCH")).toThrow(zf.KeywordNotFound);
  });

  test("header delete persists on a writable open file", () => {
    const p = tmp.path();
    const hdr = new zf.Header();
    hdr.set("TEMP", 42);
    zf.writeTo(p, new zf.FitsArray(new Float32Array(4), [2, 2]), { header: hdr });
    {
      const hdul = zf.open(p, "update");
      try {
        expect(hdul.get(0).header.has("TEMP")).toBe(true);
        hdul.get(0).header.delete("TEMP");
      } finally {
        hdul.close();
      }
    }
    const hdul = zf.open(p);
    try {
      expect(hdul.get(0).header.has("TEMP")).toBe(false);
    } finally {
      hdul.close();
    }
  });

  test("comments and history properties", () => {
    const out = ll.outU64();
    ll.check(ll.lib.zf_create_memory(null, out));
    const handle = out[0];
    let raw: Uint8Array;
    try {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      for (const text of ["HISTORY first step", "HISTORY second step", "COMMENT a note"]) {
        ll.check(ll.lib.zf_write_record(handle, enc(text.padEnd(80))));
      }
      ll.check(ll.lib.zf_flush(handle));
      const size = ll.outU64();
      ll.check(ll.lib.zf_data_size(handle, size));
      raw = new Uint8Array(Number(size[0]));
      const got = ll.outU64();
      ll.check(ll.lib.zf_read_bytes(handle, 0n, raw, raw.length, got));
    } finally {
      ll.lib.zf_close(handle);
    }
    const hdul = zf.fromBytes(raw);
    try {
      const hh = hdul.get(0).header;
      expect(hh.history).toEqual(["first step", "second step"]);
      expect(hh.comments).toEqual(["a note"]);
    } finally {
      hdul.close();
    }
  });
});

describe("HDUList.info", () => {
  test("lists PRIMARY and named extensions", () => {
    const p = tmp.path();
    const col = new zf.Column("X", "1J", { array: fill(new Int32Array(3), (i) => i) });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col], { name: "EVENTS" })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const info = hdul.info();
      expect(info).toContain("PRIMARY");
      expect(info).toContain("EVENTS");
      expect(info.split("\n")).toHaveLength(2);
    } finally {
      hdul.close();
    }
  });
});

describe("CompImageHDU codecs and knobs", () => {
  const ramp = (): zf.FitsArray => new zf.FitsArray(fill(new Int32Array(256), (i) => i), [16, 16]);

  for (const codec of ["GZIP_1", "PLIO_1", "HCOMPRESS_1"]) {
    test(`codec ${codec} roundtrips`, () => {
      const p = tmp.path();
      new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: ramp(), compression: codec })]).writeTo(p);
      const hdul = zf.open(p);
      try {
        expect(asNums((hdul.get(1).data as zf.FitsArray).data)).toEqual(asNums(ramp().data));
      } finally {
        hdul.close();
      }
    });
  }

  const curved = (): zf.FitsArray => {
    const a = new Int32Array(32 * 32);
    for (let r = 0; r < 32; r++) for (let c = 0; c < 32; c++) a[r * 32 + c] = r * r + 2 * c * c + r * c;
    return new zf.FitsArray(a, [32, 32]);
  };

  test("HCOMPRESS lossy kwargs (hcompScale / hcompSmooth)", () => {
    const pPlain = tmp.path();
    const pSmooth = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      new zf.CompImageHDU({ data: curved(), compression: "HCOMPRESS_1", hcompScale: -16 }),
    ]).writeTo(pPlain);
    new zf.HDUList([
      new zf.PrimaryHDU(),
      new zf.CompImageHDU({ data: curved(), compression: "HCOMPRESS_1", hcompScale: -16, hcompSmooth: true }),
    ]).writeTo(pSmooth);

    const orig = curved().data as Int32Array;
    let plain: Int32Array;
    {
      const hdul = zf.open(pPlain);
      try {
        plain = (hdul.get(1).data as zf.FitsArray).data as Int32Array;
        expect(Number(hdul.get(1).header.get("ZVAL1"))).toBe(-16.0); // the recorded float request
        expect(Number(hdul.get(1).header.get("ZVAL2"))).toBe(0);
      } finally {
        hdul.close();
      }
    }
    let smooth: Int32Array;
    {
      const hdul = zf.open(pSmooth);
      try {
        smooth = (hdul.get(1).data as zf.FitsArray).data as Int32Array;
        expect(Number(hdul.get(1).header.get("ZVAL2"))).toBe(1);
      } finally {
        hdul.close();
      }
    }
    let maxPlain = 0;
    let maxSmooth = 0;
    let differ = false;
    for (let i = 0; i < orig.length; i++) {
      maxPlain = Math.max(maxPlain, Math.abs(plain[i] - orig[i]));
      maxSmooth = Math.max(maxSmooth, Math.abs(smooth[i] - orig[i]));
      if (plain[i] !== smooth[i]) differ = true;
    }
    // Lossy but bounded; the smoothing request visibly changes the decode (non-vacuous).
    expect(maxPlain).toBeGreaterThan(0);
    expect(maxPlain).toBeLessThanOrEqual(64 * 16);
    expect(maxSmooth).toBeLessThanOrEqual(64 * 16);
    expect(differ).toBe(true);
  });

  const quantCases: [string, string][] = [
    ["HCOMPRESS_1", "SUBTRACTIVE_DITHER_1"],
    ["HCOMPRESS_1", "NO_DITHER"],
    ["RICE_1", "SUBTRACTIVE_DITHER_1"],
  ];
  for (const [codec, quantize] of quantCases) {
    test(`quantized float roundtrip: ${codec} + ${quantize}`, () => {
      const field = noisyField(32);
      const p = tmp.path();
      new zf.HDUList([
        new zf.PrimaryHDU(),
        new zf.CompImageHDU({
          data: new zf.FitsArray(field, [32, 32]),
          compression: codec,
          quantize,
          quantizeLevel: -0.25,
        }),
      ]).writeTo(p);
      const hdul = zf.open(p);
      try {
        const hdr = hdul.get(1).header;
        expect(String(hdr.get("ZQUANTIZ")).trim()).toBe(quantize);
        // ZDITHER0 accompanies only the dithered methods.
        expect(hdr.get("ZDITHER0") !== undefined).toBe(quantize !== "NO_DITHER");
        const out = (hdul.get(1).data as zf.FitsArray).data as Float32Array;
        // Absolute step 0.25 ⇒ |err| ≤ 0.125 (+ f32 rounding slack).
        for (let i = 0; i < field.length; i++) {
          expect(Math.abs(out[i] - field[i])).toBeLessThanOrEqual(0.125 + 1e-5);
        }
      } finally {
        hdul.close();
      }
    });
  }

  test("quantizeLevel rejected without quantization", () => {
    expect(() =>
      new zf.HDUList([
        new zf.PrimaryHDU(),
        new zf.CompImageHDU({ data: ramp(), compression: "RICE_1", quantizeLevel: 4.0 }),
      ]).writeTo(tmp.path()),
    ).toThrow(zf.FitsError);
  });

  test("lossy re-emit preserves the SCALE/SMOOTH request", () => {
    const p1 = tmp.path();
    const p2 = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      new zf.CompImageHDU({ data: curved(), compression: "HCOMPRESS_1", hcompScale: -16, hcompSmooth: true }),
    ]).writeTo(p1);
    {
      const hdul = zf.open(p1);
      try {
        hdul.writeTo(p2, { overwrite: true });
      } finally {
        hdul.close();
      }
    }
    const hdul = zf.open(p2);
    try {
      expect(String(hdul.get(1).header.get("ZCMPTYPE")).trim()).toBe("HCOMPRESS_1");
      expect(Number(hdul.get(1).header.get("ZVAL1"))).toBe(-16.0);
      expect(Number(hdul.get(1).header.get("ZVAL2"))).toBe(1);
    } finally {
      hdul.close();
    }
  });

  test("hcomp kwargs rejected for non-HCOMPRESS codecs", () => {
    expect(() =>
      new zf.HDUList([
        new zf.PrimaryHDU(),
        new zf.CompImageHDU({ data: ramp(), compression: "RICE_1", hcompScale: -4 }),
      ]).writeTo(tmp.path()),
    ).toThrow(zf.FitsError);
  });

  test("explicit tile shape roundtrips", () => {
    const p = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      new zf.CompImageHDU({ data: ramp(), compression: "RICE_1", tile: [16, 4] }),
    ]).writeTo(p);
    const hdul = zf.open(p);
    try {
      expect(asNums((hdul.get(1).data as zf.FitsArray).data)).toEqual(asNums(ramp().data));
    } finally {
      hdul.close();
    }
  });
});

describe("open modes and gzip", () => {
  test("append mode can add an HDU", () => {
    const p = tmp.path();
    const p2 = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Int16Array(4), [2, 2]));
    {
      const hdul = zf.open(p, "append");
      try {
        const col = new zf.Column("X", "1J", { array: fill(new Int32Array(3), (i) => i) });
        hdul.append(zf.BinTableHDU.fromColumns([col], { name: "NEW" }));
        hdul.writeTo(p2, { overwrite: true });
      } finally {
        hdul.close();
      }
    }
    const hdul = zf.open(p2);
    try {
      expect(hdul.length).toBe(2);
      expect(hdul.get(1).name).toBe("NEW");
    } finally {
      hdul.close();
    }
  });

  test(".fits.gz opens through the in-memory inflate path", () => {
    const p = tmp.path();
    const data = new zf.FitsArray(fill(new Int16Array(6), (i) => i), [2, 3]);
    zf.writeTo(p, data);

    const gzPath = p + ".out.fits.gz";
    const out = ll.outU64();
    const pb = enc(p);
    ll.check(ll.lib.zf_open_file(pb, pb.length, ll.READONLY, null, out));
    const gb = enc(gzPath);
    ll.check(ll.lib.zf_save_gzip(out[0], gb, gb.length));
    ll.lib.zf_close(out[0]);

    const hdul = zf.open(gzPath);
    try {
      expect(asNums((hdul.get(0).data as zf.FitsArray).data)).toEqual([0, 1, 2, 3, 4, 5]);
    } finally {
      hdul.close();
    }

    // A writable mode on a .gz is rejected up front.
    expect(() => zf.open(gzPath, "update")).toThrow(zf.FitsIOError);
  });

  test("fromBytes update mode persists edits", () => {
    const src = new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(new Float32Array(4), [2, 2]) })]).toBytes();
    const hdul = zf.fromBytes(src, "update");
    let out: Uint8Array;
    try {
      hdul.get(0).header.set("OBSERVER", "Update-mode");
      hdul.flush();
      out = hdul.toBytes();
    } finally {
      hdul.close();
    }
    const reread = zf.fromBytes(out);
    try {
      expect(reread.get(0).header.get("OBSERVER")).toBe("Update-mode");
    } finally {
      reread.close();
    }
  });
});

describe("verify findings + WCS alt", () => {
  testIf(hasGoldenFile("conformance", "malformed", "blank_on_float.fits"))(
    "Finding fields on a malformed golden file",
    () => {
      const findings = zf.verify(goldenPath("conformance", "malformed", "blank_on_float.fits"));
      const errs = findings.filter((f) => f.severity === "error");
      expect(errs.length).toBeGreaterThan(0);
      const f = errs[0];
      expect(f.hdu).toBe(1);
      expect(f.keyword).toBe("BLANK");
      expect(f.message.includes("BITPIX") || f.message.includes("positive")).toBe(true);
      expect(f.toString().startsWith("<error HDU 1")).toBe(true);
    },
  );

  test("WCS alt parameter", () => {
    const hdr = new zf.Header();
    hdr.set("CTYPE1A", "RA---TAN");
    hdr.set("CTYPE2A", "DEC--TAN");
    hdr.set("CRPIX1A", 32.0);
    hdr.set("CRPIX2A", 32.0);
    hdr.set("CRVAL1A", 10.0);
    hdr.set("CRVAL2A", -5.0);
    hdr.set("CDELT1A", -0.002);
    hdr.set("CDELT2A", 0.002);
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(new Float32Array(64 * 64), [64, 64]), header: hdr })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const img = hdul.get(0) as zf.ImageHDU;
      const [lon, lat] = img.pix2world(20.0, 10.0, "A");
      const [px, py] = img.world2pix(lon, lat, "A");
      expect(Math.abs(px - 20.0)).toBeLessThan(1e-6);
      expect(Math.abs(py - 10.0)).toBeLessThan(1e-6);
      // The default (primary) WCS is absent -> a plain pix2world() call fails.
      expect(() => img.pix2world(20.0, 10.0)).toThrow(zf.FitsWcsError);
    } finally {
      hdul.close();
    }
  });
});

describe("column dtype edges", () => {
  test("Column unit is written (TUNITn) but not exposed by .columns (documented gap)", () => {
    const p = tmp.path();
    const col = new zf.Column("FLUX", "E14.7", { array: Float64Array.from([1.0, 2.0]), unit: "Jy" });
    new zf.HDUList([new zf.PrimaryHDU(), zf.AsciiTableHDU.fromColumns([col])]).writeTo(p);
    const hdul = zf.open(p);
    try {
      expect(hdul.get(1).columns).toEqual(["FLUX"]); // names only, no unit
      const h = hdul.get(1)._select();
      const tout = ll.outU64();
      ll.check(ll.lib.zf_table_open(h, tout));
      try {
        const buf = new Uint8Array(16);
        const outLen = ll.outU64();
        ll.check(ll.lib.zf_table_col_unit(tout[0], 0, buf, 16, outLen));
        expect(new TextDecoder().decode(buf.subarray(0, Number(outLen[0])))).toBe("Jy");
      } finally {
        ll.lib.zf_table_close(tout[0]);
      }
    } finally {
      hdul.close();
    }
  });

  test("complex column roundtrip (interleaved re/im)", () => {
    // (1+2i), (-3+4i), (0-1i)
    const vals = Float32Array.from([1, 2, -3, 4, 0, -1]);
    const p = tmp.path();
    const col = new zf.Column("CPLX", "1C", { array: vals });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const got = (hdul.get(1).data as zf.TableData).column("CPLX");
      expect(got.kind).toBe("complex");
      expect(got.dtype).toBe("c8");
      expect(asNums(got.values as Float32Array)).toEqual([1, 2, -3, 4, 0, -1]);
    } finally {
      hdul.close();
    }
  });

  test("logical column accepts boolean[] or Uint8Array; reads back u1", () => {
    const p = tmp.path();
    const col = new zf.Column("FLAG", "1L", { array: [true, false, true] });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).writeTo(p);
    {
      const hdul = zf.open(p);
      try {
        const got = (hdul.get(1).data as zf.TableData).column("FLAG");
        expect(got.dtype).toBe("u1");
        expect(asNums(got.values as Uint8Array)).toEqual([1, 0, 1]);
      } finally {
        hdul.close();
      }
    }
    const p2 = tmp.path();
    const workaround = new zf.Column("FLAG", "1L", { array: Uint8Array.from([1, 0, 1]) });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([workaround])]).writeTo(p2);
    const hdul = zf.open(p2);
    try {
      const got = (hdul.get(1).data as zf.TableData).column("FLAG");
      expect(got.dtype).toBe("u1");
      expect(asNums(got.values as Uint8Array)).toEqual([1, 0, 1]);
    } finally {
      hdul.close();
    }
  });
});
