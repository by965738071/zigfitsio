# zigfitsio

[![TypeScript bindings](https://github.com/anhydrous99/zigfitsio/actions/workflows/typescript.yml/badge.svg)](https://github.com/anhydrous99/zigfitsio/actions/workflows/typescript.yml)
[![npm](https://img.shields.io/npm/v/zigfitsio)](https://www.npmjs.com/package/zigfitsio)
[![node](https://img.shields.io/node/v/zigfitsio)](https://www.npmjs.com/package/zigfitsio)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](https://github.com/anhydrous99/zigfitsio/blob/main/LICENSE)

**Astropy-style FITS I/O for Node, Bun, and the browser — one WebAssembly package, no native addons, no runtime dependencies.**

TypeScript bindings for [zigfitsio](https://github.com/anhydrous99/zigfitsio), a pure-Zig FITS 4.0
I/O library, in two layers: a high-level astropy-style API (`open`, `HDUList`, HDU classes,
`Header`, `Column`, `verify`) and a low-level 1:1 mapping of the C ABI (`zigfitsio/lowlevel`).

## Install

```sh
npm install zigfitsio     # or: bun add zigfitsio
```

On **Node and Bun** the WebAssembly module loads synchronously at import, so the API is fully
synchronous and ready immediately. In the **browser**, call `await zf.ready()` once first:

```ts
import * as zf from "zigfitsio";

await zf.ready();  // browser: fetches + compiles zigfitsio.wasm (no-op on Node/Bun)
// ...then every call below is synchronous.
```

## Quickstart

### Images

```ts
import * as zf from "zigfitsio";

// Shape is C-order, [NAXIS2, NAXIS1] — same layout as numpy/astropy.
const pixels = new zf.FitsArray(Float32Array.from({ length: 24 }, (_, i) => i * 0.25), [4, 6]);
zf.writeTo("image.fits", pixels, { overwrite: true });

using hdul = zf.open("image.fits"); // `using` closes at scope exit (or call hdul.close())
const img = hdul.image(0).data;     // FitsArray | null — typed, no `as` cast
console.log(img?.shape, img?.dtype, img?.get(2, 3));

// Read a strided cutout without materializing the whole image.
const cut = hdul.image(0).section({ window: [[1, 3], [2, 5]], step: [1, 1] });
console.log(cut.shape); // [2, 3]
```

### Tables

```ts
// `tableFromArrays` infers each TFORM from the array type.
const table = zf.tableFromArrays(
  {
    INDEX: Int32Array.from([10, 20, 30]),
    FLUX: Float32Array.from([1.5, 2.5, 3.5]),
    NAME: ["alpha", "beta", "gamma"],
  },
  { name: "EVENTS", units: { FLUX: "Jy" } },
);
// (Explicit TFORMs — complex, VLA, hand-tuned widths: `BinTableHDU.fromColumns` + `new Column(...)`.)
new zf.HDUList([new zf.PrimaryHDU(), table]).writeTo("table.fits", { overwrite: true });

using hdul = zf.open("table.fits");
const rec = hdul.table("EVENTS").data; // TableData | null (columnar)
console.log(rec?.names, rec?.numRows, rec?.numeric("FLUX"));
for (const row of rec ?? []) console.log(row.NAME, row.FLUX); // ...or iterate rows
```

### Compression & checksums

```ts
// Tile compression: RICE/GZIP/PLIO/HCOMPRESS, incl. lossy + quantized floats.
const ramp = new zf.FitsArray(Int32Array.from({ length: 256 }, (_, i) => i), [16, 16]);
new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: ramp, compression: "RICE_1" })])
  .writeTo("compressed.fits", { overwrite: true });

zf.writeTo("check.fits", new zf.FitsArray(new Float32Array(24), [4, 6]), { overwrite: true, checksum: true });
console.log(zf.verify("check.fits")); // [] when clean
```

### WCS

```ts
using hdul = zf.open("wcs.fits");
const [lon, lat] = hdul.image(0).pix2world(40.0, 30.0); // 1-based FITS pixel convention
const [px, py] = hdul.image(0).world2pix(lon, lat);
```

### Typed access without casts

```ts
using hdul = zf.open("table.fits");

// 1) Typed accessors assert the HDU flavor (throw FitsTypeError on mismatch).
const img = hdul.image(0).data;        // FitsArray | null
const rec = hdul.table("EVENTS").data; // TableData | null

// 2) Narrow the AnyHDU union on the `kind` discriminant.
for (const hdu of hdul) {
  if (hdu.kind === "bintable" || hdu.kind === "asciitable") console.log(hdu.data?.numRows);
  else console.log(hdu.data?.shape); // image kinds
}

// 3) Name the column shape for fully-typed column/row reads.
const t = hdul.table<{ INDEX: Int32Array; NAME: string[] }>("EVENTS").data!;
const idx = t.get("INDEX"); // Int32Array
const first = t.row(0);     // { INDEX: …, NAME: string }
```

## Browser usage

There is no filesystem in the browser, so the path-based `open()`/`writeTo()` are unavailable
there — use `fromBytes`/`toBytes` with your own `fetch`/`File` I/O:

```ts
import * as zf from "zigfitsio";

await zf.ready(); // or await zf.ready({ wasm: myBytesOrModule }) to host the .wasm yourself

const bytes = new Uint8Array(await (await fetch("/data/image.fits")).arrayBuffer());
const hdul = zf.fromBytes(bytes);
const img = hdul.image(0).data;
hdul.close();
```

Bundlers (Vite, webpack 5, esbuild, Rollup) resolve the `.wasm` asset automatically via the
package's `new URL(..., import.meta.url)` reference and `browser` export condition — nothing to
mark external, in browsers or Electron. Gzipped `.fits.gz` is a Node/Bun convenience; in the
browser, inflate with `DecompressionStream("gzip")` and pass the result to `fromBytes`.

## Conventions

- **Arrays are native-endian TypedArrays.** Images are a flat TypedArray + C-order shape
  (`FitsArray`); tables are columnar (`TableData`, iterable by row); complex values are
  interleaved float pairs (dtype `c8`/`c16`); `Header` iterates like a `Map`.
- **64-bit integers use BigInt64Array/BigUint64Array** (values are `bigint`). Header integers
  parse to `number` when exactly representable as a double, else `bigint`.
- **Scaling is automatic.** `BSCALE`/`BZERO` and `TSCAL`/`TZEROn` are applied on read (scaled
  data reads as floats); the unsigned convention maps to/from `u2`/`u4`/`u8` exactly.
- **Close your handles.** `hdul.close()` (flushes first in update/append modes), or
  `using hdul = zf.open(...)` — TypeScript transpiles `using` everywhere; plain JavaScript needs
  Bun or Node ≥24. There is no GC-based freeing.
- **Errors are typed** `FitsError` subclasses carrying the CFITSIO-compatible `status` (e.g.
  `KeywordNotFound` 202). Unlike Python, `KeywordNotFound` is not a `KeyError` — catch the class.

## Performance

The FFI calls are **synchronous and blocking** by design (like better-sqlite3) — simpler and
faster for CPU-bound work, at the cost of blocking the event loop during a large read/write.
Read only what you need with `ImageHDU.section()` (bounded memory and time; not available on
tile-compressed images), and offload multi-hundred-MB jobs to a `Worker`, transferring the
resulting TypedArray's `ArrayBuffer` back zero-copy.

## Low-level API

`zigfitsio/lowlevel` exposes every `zf_*` symbol
(see [zigfitsio.h](https://github.com/anhydrous99/zigfitsio/blob/main/bindings/c/zigfitsio.h))
with typed marshalling, `check(status)`, and the struct codecs:

```ts
import { lowlevel as ll } from "zigfitsio";
const out = ll.outU64();
ll.check(ll.lib.zf_create_memory(null, out));
// ... raw zf_* calls ...
ll.lib.zf_close(out[0]);
```

## Known limitations

- Not a CFITSIO drop-in (`zf_*`, not `fits_*`).
- Runs in WebAssembly: the compute-heavy codecs are ~1.5–3× slower than a native build; the
  module is single-threaded and its heap never shrinks while loaded.
- In-place update of compressed images, VLA or scaled columns, or a changed row count throws
  `NotSupportedError` — use `writeTo()` to a new file.
- Tables with duplicate effective column names can be inspected as metadata or copied verbatim,
  but high-level data access/reconstruction throws `FitsTableError` (status 219); use low-level
  indexed column reads when duplicates must be addressed.
- Integer `BLANK`/`TNULLn` values are not auto-masked; float nulls surface as NaN.
- `table<T>()` column shapes are compile-time only — the runtime-checked reads are
  `numeric()`/`strings()`/`vla()`/`complex()` (throw on kind mismatch).

The full list, including every TS-native-surface boundary, lives in
[CAVEATS.md §3](https://github.com/anhydrous99/zigfitsio/blob/main/CAVEATS.md).

## Development

```sh
zig build wasm          # build zigfitsio.wasm into zig-out/bin/ (ReleaseSmall)
cd bindings/typescript
npm ci
bun test tests          # Bun lane
npx vitest run          # Node lane
npm run build           # clean + tsc -> dist/ + build & copy zigfitsio.wasm
```

The dev loader honors `ZIGFITSIO_WASM` and falls back to a `zig-out/bin` build.

## License

MIT — see [LICENSE](https://github.com/anhydrous99/zigfitsio/blob/main/LICENSE).
