# zigfitsio

A pure-[Zig](https://ziglang.org) implementation of a [FITS](https://fits.gsfc.nasa.gov)
(Flexible Image Transport System) 4.0 input/output library, with feature parity goals
against [CFITSIO](https://heasarc.gsfc.nasa.gov/docs/software/fitsio/fitsio.html) — written
with **no C imports and no C sources** (`GC-1`).

- **Conformance target:** *Definition of the FITS Standard*, Version 4.0 (2018-08-13).
- **Toolchain:** Zig **0.16.0**, standard library only (`GC-2`, `GC-3`).
- **License:** MIT (see [`LICENSE`](./LICENSE)).

See [`requirements.md`](./requirements.md), [`design.md`](./design.md), and
[`tasks.md`](./tasks.md) for the full specification, architecture, and implementation
backlog.

## Build

```sh
zig build              # build the static library
zig build test         # run the test suite
zig build capi         # build the C-ABI shared library (for the Python/C bindings)
zig build capi-test    # test the C-ABI shim
zig build bench        # throughput benchmarks
zig build fitsverify   # run the structural-validation CLI demo
zig build fuzz         # fuzz the header/table parsers
zig build wasm-check   # compile the core for wasm32-freestanding
```

## Use as a dependency

```sh
zig fetch --save git+https://github.com/anhydrous99/zigfitsio
```

```zig
// build.zig
const fits = b.dependency("zigfitsio", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zigfitsio", fits.module("zigfitsio"));
```

## Language bindings (C ABI + Python)

A stable **C ABI** and a **Python** package live under [`bindings/`](./bindings). They are
additive — the pure-Zig library in `src/` is unchanged — and are layered:

- **C-ABI shim** ([`bindings/capi/`](./bindings/capi), `zig build capi`): a dynamic library
  `zigfitsio_capi` exporting `zf_*` symbols. The comptime-generic Zig API is monomorphized behind
  runtime datatype codes, and Zig errors are surfaced as CFITSIO-compatible status ints via
  `errors.cfitsioStatus`. The hand-written contract is [`bindings/c/zigfitsio.h`](./bindings/c/zigfitsio.h).
  This is **not** a CFITSIO `fits_*`/`ff*` drop-in — it is a purpose-built ABI for bindings.
- **Low-level Python** (`zigfitsio.lowlevel`): a 1:1 `ctypes` binding over the C ABI, with a typed
  `FitsError` hierarchy. Pure Python — no C compiler needed at install.
- **High-level Python** (`zigfitsio`): a NumPy-first API modeled on `astropy.io.fits` — `open`,
  `HDUList`, the HDU classes, `Column`, a dict-like `Header`, `getdata`/`getheader`/`writeto`/
  `verify`, and celestial WCS transforms. Interoperability is verified **both directions** against
  Astropy and the committed CFITSIO golden corpus.

```python
import numpy as np, zigfitsio as zf

zf.writeto("img.fits", np.arange(12, dtype="f4").reshape(3, 4), overwrite=True)
with zf.open("img.fits") as hdul:
    print(hdul[0].data, hdul[0].header["NAXIS1"])
```

See [`bindings/python/README.md`](./bindings/python/README.md) for install, the full API, and the
packaging/wheel workflow.

## Status

Feature-complete and tested (459 tests green), with cross-tool interoperability verified against
**CFITSIO 4.6.4 + Astropy** (see below). Implemented end to end:

- **Foundation:** I/O layer (in-memory, file, stream/gzip, and HTTP backends), typed
  error sets, big-endian access, numeric-conversion policy, resource limits.
- **Headers:** value parsing (null/empty/undefined distinction), 80-byte cards, full
  read + edit operations, header-space pre-allocation, `CONTINUE` long strings,
  `HIERARCH` long names, and complex-valued cards.
- **HDUs & data:** HDU model with navigation/mutation; `ImageView` over all six `BITPIX`
  with scaling, nulls, and strided sections; ASCII and binary tables (all `TFORM` codes,
  `TDIM`, scaling, nulls); variable-length arrays with a compacting heap.
- **WCS:** keyword set parse/serialize plus celestial (`TAN`/`SIN`/`ARC`/`STG`/`ZEA`/`CAR`),
  spectral, and time-coordinate transforms.
- **Compression:** GZIP_1/2, RICE_1, PLIO_1, and HCOMPRESS_1 tiled read **and** write,
  with subtractive dithering; tile-compressed-table (`ZTABLE`) reading.
- **Integrity & validation:** `DATASUM`/`CHECKSUM` compute/update/verify; a
  `fitsverify`-style structural pass.
- **Convenience:** CFITSIO-style extended filenames, ASCII header templates, hierarchical
  grouping tables, and a transparent `.fits.gz` open path.

**Cross-tool interoperability is verified**, not just self-consistent: a committed
**CFITSIO 4.6.4 + `fpack`** golden corpus (`test/golden/`, generators under `interop/`) is decoded
hermetically by `test/golden.zig` on every CI cell (including big-endian s390x), an in-house
full-feature round-trip (`test/e2e.zig`) mirrors CFITSIO's `testprog.c`, and a dedicated `interop`
CI job opens every zigfitsio-written file with CFITSIO `funpack`, Astropy, and `fitsverify`.
Authoring this corpus closed two real interop bugs that self-round-trips could not catch (the PLIO
line-list header + `COMPRESSED_DATA` `1PB`→`1PI`, and an unregistered `checksum_on_close` hook).
`HCOMPRESS_1` is complete including the lossy path: decode-side smoothing (`hsmooth`) reproduces
`funpack` bit-for-bit on committed lossy/smoothed goldens, and the write path supports CFITSIO's
absolute and noise-adaptive lossy scaling (`CompressSpec.hcomp_scale`/`.hcomp_smooth`). See
`CAVEATS.md` and `tasks.md`.

## Examples

### Read an image into `[]f32`

```zig
const fits = @import("zigfitsio");

var f = try fits.openFile(allocator, "img.fits", .read_only, .{});
defer f.deinit();

var img = try fits.ImageView.of(&f, f.current());
const buf = try allocator.alloc(f32, @intCast(img.elementCount()));
defer allocator.free(buf);

// BSCALE/BZERO applied, NaN → 0 substituted, stored → f32 converted, in bounded chunks.
try img.readAll(f32, buf, .{ .null_sentinel = 0.0 });
```

### Create an image (the programmatic builder is the primary path)

```zig
var f = try fits.createFile(allocator, "out.fits", .{});
defer f.deinit();

var img = try fits.ImageView.append(&f, .{ .bitpix = -32, .axes = &.{ 256, 256 } });
try img.writeAll(f32, pixels, .{});
try f.flush();
```

### Navigate HDUs and read a strided section

```zig
const n = try f.hduCount();
var img = try fits.ImageView.of(&f, try f.select(2)); // 1-based HDU number
var tile: [256 * 256]f32 = undefined;
try img.readSection(f32, &.{ 0, 0 }, &.{ 511, 511 }, &.{ 2, 2 }, &tile, .{});
```

In-memory and stdin/stdout back-ends are first-class: build a `fits.MemoryDevice` and pass
`mem.device()` to `fits.open`/`fits.create` for a freestanding-capable, file-less path.
