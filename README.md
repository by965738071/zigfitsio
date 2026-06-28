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
The one remaining codec limit is `HCOMPRESS_1` lossy smoothing (`hsmooth`) — lossless only. See
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
