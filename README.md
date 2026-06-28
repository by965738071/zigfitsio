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

Under active development. The foundation (I/O layer, errors, endianness, numeric
conversion, headers, HDU model, image core) lands first (milestone **M0**); core tables,
variable-length arrays, scaling, and checksums follow (**M1**). See `tasks.md` for the
milestone breakdown.

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
