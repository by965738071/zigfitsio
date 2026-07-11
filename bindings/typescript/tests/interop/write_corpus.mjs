/**
 * Write the TS-authored interop corpus (`ts_corpus.fits` in argv[2]) for the
 * Python bindings to read back (see py_interop.py). Imports the BUILT package
 * (dist/) — run `npm run build` first. Keep contents in sync with
 * read_corpus.mjs / py_interop.py.
 */
import { join } from "node:path";
import * as zf from "../../dist/index.js";

const outDir = process.argv[2];
if (!outDir) {
  console.error("usage: write_corpus.mjs <outdir>");
  process.exit(2);
}

const f4 = Float32Array.from({ length: 12 }, (_, i) => i * 0.5);
const u2 = Uint16Array.from([0, 40000, 65535]);
const ramp = Int32Array.from({ length: 256 }, (_, i) => i);

const table = zf.BinTableHDU.fromColumns(
  [
    new zf.Column("INDEX", "1J", { array: Int32Array.from([10, 20, 30]) }),
    new zf.Column("FLUX", "1E", { array: Float32Array.from([1.5, 2.5, 3.5]), unit: "Jy" }),
    new zf.Column("NAME", "8A", { array: ["alpha", "beta", "gamma"] }),
    new zf.Column("VLA", "1PJ", { array: [Int32Array.from([1, 2, 3]), Int32Array.from([4]), new Int32Array(0)] }),
    new zf.Column("CPLX", "1C", { array: Float32Array.from([1, 2, -3, 4, 0, -1]) }),
  ],
  { name: "T" },
);

new zf.HDUList([
  new zf.PrimaryHDU({ data: new zf.FitsArray(f4, [3, 4]) }),
  new zf.ImageHDU({ data: u2, name: "UIMG" }),
  table,
  new zf.CompImageHDU({ data: new zf.FitsArray(ramp, [16, 16]), compression: "RICE_1", name: "COMP" }),
]).writeTo(join(outDir, "ts_corpus.fits"), { overwrite: true });

console.log("wrote", join(outDir, "ts_corpus.fits"));
