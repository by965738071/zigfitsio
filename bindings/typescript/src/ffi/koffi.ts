/**
 * koffi backend (Node). koffi is a regular dependency but is required lazily
 * inside `openKoffiLibrary`, so Bun never loads its native addon.
 *
 * koffi ≥3 represents pointers as BigInt; because every handle crosses the
 * boundary as `uint64_t` (see `ffi/types.ts`), this backend works identically
 * on koffi 2.x (External pointers) and 3.x.
 */
import { createRequire } from "node:module";
import type { NativeArg, NativeFn, NativeLibrary, NativeResult, NativeType, Proto, Ptr } from "./types.js";

const requireModule = createRequire(import.meta.url);

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function koffiTypeOf(koffi: any, t: NativeType): unknown {
  switch (t) {
    case "void":
      return "void";
    case "int":
      return "int";
    case "u32":
      return "uint32_t";
    case "i64":
      return "int64_t";
    case "u64":
      return "uint64_t";
    case "f32":
      return "float32";
    case "f64":
      return "float64";
    case "long":
      return "long"; // koffi's long is platform-correct (LLP64 on win32)
    case "usize":
      return "uint64_t";
    case "handle":
      return "uint64_t";
    case "buf":
      return koffi.pointer("void");
    case "cstr":
      return "str";
    case "cstr_arr":
      return koffi.pointer("str");
    case "cstring_ret":
      return "str";
  }
}

let stackConfigured = false;

export function openKoffiLibrary(libPath: string, protos: readonly Proto[]): NativeLibrary {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const koffi: any = requireModule("koffi");
  // koffi runs synchronous calls on its own preallocated stack (default 1 MiB
  // — `koffi.config().sync_stack_size`), not the JS thread's ~8 MiB one. The
  // library's file-device paths overflow that in Debug builds on Windows
  // (fat Debug frames; the process dies with no JS error). Give the sync
  // stack normal thread-stack headroom; bun:ffi calls on the real thread
  // stack and needs nothing. Config is process-global and locked at the
  // first koffi.load — set it once, and tolerate a host app that already
  // loaded another koffi library (its configuration governs then).
  if (!stackConfigured) {
    try {
      koffi.config({ sync_stack_size: 8 * 1024 * 1024 });
    } catch {
      /* koffi already in use by the host application */
    }
    stackConfigured = true;
  }
  const lib = koffi.load(libPath);

  const convertArg = (kind: NativeType, v: NativeArg): unknown => {
    switch (kind) {
      case "handle":
        return v === null ? 0n : v;
      case "cstr_arr":
        // koffi marshals (string | null)[] for a `str *` parameter itself.
        return v;
      default:
        return v;
    }
  };

  const convertRet = (kind: NativeType, out: unknown): NativeResult => {
    switch (kind) {
      case "void":
        return undefined;
      case "handle":
      case "i64":
      case "u64":
      case "usize":
        // koffi returns 64-bit integers as number when exactly representable,
        // else BigInt — normalize to bigint.
        return typeof out === "bigint" ? out : BigInt(out as number);
      case "cstring_ret":
        return out == null ? "" : String(out);
      default:
        return Number(out);
    }
  };

  const fn: Record<string, NativeFn> = {};
  for (const p of protos) {
    const raw = lib.func(
      p.name,
      koffiTypeOf(koffi, p.returns),
      p.args.map((a) => koffiTypeOf(koffi, a)),
    );
    const argKinds = p.args;
    const retKind = p.returns;
    fn[p.name] = (...args: NativeArg[]): NativeResult => {
      const conv = new Array(args.length);
      for (let i = 0; i < args.length; i++) conv[i] = convertArg(argKinds[i], args[i]);
      return convertRet(retKind, raw(...conv));
    };
  }

  return {
    backend: "koffi",
    fn,
    readCString(p: Ptr, len: number): string {
      if (p === 0n || len === 0) return "";
      return String(koffi.decode(p, "char", len));
    },
    close() {
      lib.unload();
    },
  };
}
