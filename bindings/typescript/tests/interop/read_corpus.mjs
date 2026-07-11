/**
 * Read the Python-authored interop corpus (`py_corpus.fits` in argv[2]) and
 * assert its contents (see py_interop.py). Imports the BUILT package (dist/)
 * — run `npm run build` first. Exits nonzero on any mismatch.
 */
import { join } from "node:path";
import * as zf from "../../dist/index.js";

const dir = process.argv[2];
if (!dir) {
  console.error("usage: read_corpus.mjs <dir>");
  process.exit(2);
}

function assertEq(label, got, want) {
  const g = JSON.stringify(got);
  const w = JSON.stringify(want);
  if (g !== w) {
    console.error(`MISMATCH ${label}: got ${g}, want ${w}`);
    process.exit(1);
  }
}

const asNums = (a) => Array.from(a, (v) => Number(v));

const hdul = zf.open(join(dir, "py_corpus.fits"));
try {
  const img = hdul.get(0).data;
  assertEq("primary shape", img.shape, [3, 4]);
  assertEq("primary dtype", img.dtype, "f4");
  assertEq(
    "primary values",
    asNums(img.data),
    Array.from({ length: 12 }, (_, i) => i * 0.5),
  );

  const uimg = hdul.get("UIMG").data;
  assertEq("u2 dtype", uimg.dtype, "u2");
  assertEq("u2 values", asNums(uimg.data), [0, 40000, 65535]);

  const rec = hdul.get("T").data;
  assertEq("INDEX", asNums(rec.get("INDEX")), [10, 20, 30]);
  assertEq("FLUX", asNums(rec.get("FLUX")), [1.5, 2.5, 3.5]);
  assertEq("NAME", rec.get("NAME"), ["alpha", "beta", "gamma"]);
  const vla = rec.get("VLA");
  assertEq("VLA0", asNums(vla[0]), [1, 2, 3]);
  assertEq("VLA1", asNums(vla[1]), [4]);
  assertEq("VLA2 len", vla[2].length, 0);
  assertEq("CPLX", asNums(rec.get("CPLX")), [1, 2, -3, 4, 0, -1]);

  const comp = hdul.get("COMP").data;
  assertEq("comp shape", comp.shape, [16, 16]);
  assertEq(
    "comp values",
    asNums(comp.data),
    Array.from({ length: 256 }, (_, i) => i),
  );
} finally {
  hdul.close();
}

console.log("py_corpus.fits verified OK");
