/**
 * zigfitsio TypeScript quickstart — mirrors bindings/python/examples/quickstart.py.
 * Run from bindings/typescript after `zig build capi`:
 *   bun examples/quickstart.ts
 */
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as zf from "../src/index.js";

const dir = mkdtempSync(join(tmpdir(), "zigfitsio-quickstart-"));

// ── images ──
const imgPath = join(dir, "image.fits");
const data = new zf.FitsArray(Float32Array.from({ length: 24 }, (_, i) => i * 0.25), [4, 6]);
zf.writeTo(imgPath, data, { overwrite: true });

{
  const hdul = zf.open(imgPath);
  try {
    const img = hdul.image(0).data!; // typed FitsArray — no cast
    console.log("image:", img.shape, img.dtype, "->", img.get(2, 3));
    console.log("BITPIX =", hdul.image(0).header.get("BITPIX"));
    // Strided cutout (rows 1..2, cols 2..4) without reading the whole image.
    const cut = hdul.image(0).section({ window: [[1, 3], [2, 5]] });
    console.log("section:", cut.shape, "->", Array.from(cut.data));
  } finally {
    hdul.close();
  }
}

// ── headers (iterate like a Map) ──
{
  const hdul = zf.open(imgPath, "update");
  try {
    hdul.image(0).header.set("OBSERVER", "Hubble", "who observed");
  } finally {
    hdul.close();
  }
  console.log("OBSERVER =", zf.getVal(imgPath, "OBSERVER"));
}

// ── binary tables (typed, string, VLA columns) ──
const tblPath = join(dir, "table.fits");
const table = zf.BinTableHDU.fromColumns(
  [
    new zf.Column("INDEX", "J", { array: Int32Array.from([10, 20, 30]) }),
    new zf.Column("FLUX", "E", { array: Float32Array.from([1.5, 2.5, 3.5]), unit: "Jy" }),
    new zf.Column("NAME", "8A", { array: ["alpha", "beta", "gamma"] }),
    new zf.Column("TRACE", "1PJ", { array: [Int32Array.from([1, 2]), Int32Array.from([3]), new Int32Array(0)] }),
  ],
  { name: "EVENTS" },
);
new zf.HDUList([new zf.PrimaryHDU(), table]).writeTo(tblPath, { overwrite: true });

{
  const hdul = zf.open(tblPath);
  try {
    const rec = hdul.table("EVENTS").data!; // typed TableData — no cast
    console.log("table:", rec.names, `${rec.numRows} rows; FLUX =`, Array.from(rec.numeric("FLUX")));
    // Rows as plain objects.
    for (const row of rec) console.log("  row:", String(row.NAME).trim(), row.FLUX);
  } finally {
    hdul.close();
  }
}

// ── factory: tableFromArrays infers each TFORM ──
const tbl2Path = join(dir, "table2.fits");
new zf.HDUList([
  new zf.PrimaryHDU(),
  zf.tableFromArrays({ ID: Int32Array.from([1, 2]), TAG: ["a", "bb"] }, { name: "T2" }),
]).writeTo(tbl2Path, { overwrite: true });
{
  const hdul = zf.open(tbl2Path);
  try {
    console.log("tableFromArrays:", hdul.table("T2").data!.strings("TAG"));
  } finally {
    hdul.close();
  }
}

// ── tile compression ──
const compPath = join(dir, "compressed.fits");
const ramp = new zf.FitsArray(Int32Array.from({ length: 256 }, (_, i) => i), [16, 16]);
new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: ramp, compression: "RICE_1" })]).writeTo(compPath, {
  overwrite: true,
});
{
  const hdul = zf.open(compPath);
  try {
    const got = hdul.image(1).data!; // transparent decode
    console.log("compressed roundtrip ok:", got.get(15, 15) === 255);
  } finally {
    hdul.close();
  }
}

// ── integrity ──
const chkPath = join(dir, "check.fits");
zf.writeTo(chkPath, data, { overwrite: true, checksum: true });
console.log("verify findings:", zf.verify(chkPath).length);

console.log("\nall outputs under", dir);
