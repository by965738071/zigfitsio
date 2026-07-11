/**
 * Mirror of `bindings/python/tests/test_golden.py`: read the committed
 * CFITSIO/Astropy golden corpus (inbound interop). Skips per-file when the
 * corpus is absent.
 */
import { describe, expect, testIf } from "./_harness/index.js";
import * as zf from "../src/index.js";
import { goldenPath, hasGoldenFile } from "./_fixtures.js";

const asNums = (a: ArrayLike<number | bigint>): number[] => Array.from(a, (v) => Number(v));

function readImage(path: string, ext: number): zf.FitsArray {
  const hdul = zf.open(path);
  try {
    return hdul.get(ext).data as zf.FitsArray;
  } finally {
    hdul.close();
  }
}

describe("golden tile codecs", () => {
  for (const codec of ["rice", "gzip", "hcompress", "plio"]) {
    testIf(hasGoldenFile("compress", `tile_${codec}.fits`))(`tile_${codec} decodes to the ramp`, () => {
      const data = readImage(goldenPath("compress", `tile_${codec}.fits`), 1);
      expect(asNums(data.data)).toEqual([...Array(256).keys()]);
    });
  }

  for (const name of ["lossy16", "lossy32", "smooth"]) {
    testIf(
      hasGoldenFile("compress", `tile_hcompress_${name}.fits`) &&
        hasGoldenFile("compress", `tile_hcompress_${name}_expected.fits`),
    )(`lossy HCOMPRESS ${name} matches funpack`, () => {
      const data = readImage(goldenPath("compress", `tile_hcompress_${name}.fits`), 1);
      const want = readImage(goldenPath("compress", `tile_hcompress_${name}_expected.fits`), 0);
      expect(asNums(data.data)).toEqual(asNums(want.data));
    });
  }

  for (const name of ["hcompress_fdith", "hcompress_fq0", "rice_fdith"]) {
    testIf(
      hasGoldenFile("compress", `tile_${name}.fits`) && hasGoldenFile("compress", `tile_${name}_expected.fits`),
    )(`quantized float ${name} dequantizes bit-exactly like funpack`, () => {
      const data = readImage(goldenPath("compress", `tile_${name}.fits`), 1);
      const want = readImage(goldenPath("compress", `tile_${name}_expected.fits`), 0);
      expect(data.dtype).toBe("f4");
      expect(want.dtype).toBe("f4");
      // Bit-pattern equality: the dequantization must be funpack-identical, not merely close.
      const gotBits = new Uint32Array(data.data.buffer, data.data.byteOffset, data.size);
      const wantBits = new Uint32Array(want.data.buffer, want.data.byteOffset, want.size);
      expect(Array.from(gotBits)).toEqual(Array.from(wantBits));
    });
  }
});

describe("golden images", () => {
  testIf(hasGoldenFile("images", "img_i16.fits"))("img_i16 reads the offset ramp", () => {
    const d = readImage(goldenPath("images", "img_i16.fits"), 0);
    expect(asNums(d.data)).toEqual([...Array(32).keys()].map((i) => i - 8));
  });

  testIf(hasGoldenFile("images", "img_i16_blank.fits"))("img_i16_blank promotes to NaN-masked f4", () => {
    const d = readImage(goldenPath("images", "img_i16_blank.fits"), 0);
    expect(d.dtype).toBe("f4"); // astropy width for BITPIX 16 + BLANK
    const vals = d.data as Float32Array;
    for (let i = 0; i < 32; i++) {
      if (i === 3 || i === 17 || i === 31) expect(Number.isNaN(vals[i])).toBe(true);
      else expect(vals[i]).toBe(i - 8);
    }
  });

  testIf(hasGoldenFile("images", "img_i16_blank_scaled.fits"))(
    "img_i16_blank_scaled substitutes NaN BEFORE BSCALE/BZERO scaling",
    () => {
      const d = readImage(goldenPath("images", "img_i16_blank_scaled.fits"), 0);
      const vals = d.data as Float32Array;
      for (let i = 0; i < 32; i++) {
        if (i === 3 || i === 17 || i === 31) expect(Number.isNaN(vals[i])).toBe(true); // NOT 2*(-32768)+100
        else expect(vals[i]).toBe(2 * (i - 8) + 100);
      }
    },
  );

  testIf(hasGoldenFile("compress", "tile_rice_i16_blank.fits"))(
    "tile_rice_i16_blank decodes NaN from the plain BLANK spelling (fpack keeps BLANK, not ZBLANK)",
    () => {
      const d = readImage(goldenPath("compress", "tile_rice_i16_blank.fits"), 1);
      expect(d.dtype).toBe("f4");
      const vals = d.data as Float32Array;
      for (let i = 0; i < 32; i++) {
        if (i === 3 || i === 17 || i === 31) expect(Number.isNaN(vals[i])).toBe(true);
        else expect(vals[i]).toBe(i - 8);
      }
    },
  );

  testIf(hasGoldenFile("images", "img_f32.fits"))("img_f32 exposes the NaN null", () => {
    const d = readImage(goldenPath("images", "img_f32.fits"), 0);
    const vals = d.data as Float32Array;
    expect(Number.isNaN(vals[7])).toBe(true);
    for (let i = 0; i < 15; i++) {
      if (i === 7) continue;
      expect(Math.abs(vals[i] - i * 0.25)).toBeLessThan(1e-6);
    }
  });
});

describe("golden tables", () => {
  testIf(hasGoldenFile("tables", "bintable.fits"))("bintable columns read", () => {
    const hdul = zf.open(goldenPath("tables", "bintable.fits"));
    try {
      const rec = hdul.get(1).data as zf.TableData;
      expect(asNums(rec.get("INDEX") as zf.TypedArray)).toEqual([10, 20, 30]);
      const dval = rec.get("DVAL") as zf.TypedArray;
      [0.25, 0.5, 0.75].forEach((w, i) => expect(Math.abs(Number(dval[i]) - w)).toBeLessThan(1e-9));
      expect((rec.get("NAME") as string[]).map((s) => s.trim())).toEqual(["alpha", "beta", "gamma"]);
    } finally {
      hdul.close();
    }
  });

  testIf(hasGoldenFile("tables", "ascii.fits"))("ascii table reads", () => {
    const hdul = zf.open(goldenPath("tables", "ascii.fits"));
    try {
      const rec = hdul.get(1).data as zf.TableData;
      expect(asNums(rec.get("ID") as zf.TypedArray)).toEqual([100, 200, 300]);
    } finally {
      hdul.close();
    }
  });
});
