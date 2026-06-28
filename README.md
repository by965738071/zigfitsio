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

Usage examples (read an image, create an image, read a table column, verify checksums)
appear here as the corresponding APIs land.
