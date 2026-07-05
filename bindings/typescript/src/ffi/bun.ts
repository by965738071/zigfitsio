/**
 * bun:ffi backend. Only ever imported at runtime under Bun (`ffi/index.ts`
 * guards on `process.versions.bun`); the `bun:ffi` module itself is required
 * lazily inside `openBunLibrary` so importing this file under Node is safe.
 *
 * ## darwin-arm64 stack-argument workaround
 *
 * Apple's arm64 ABI packs stack-passed arguments at their *natural* size and
 * alignment (two consecutive `int`s share one 8-byte slot), but bun:ffi (as of
 * 1.3.13) writes every stack argument into its own 8-byte slot — standard
 * AAPCS64 behavior, wrong on Apple platforms. Any signature with two
 * adjacent 4-byte stack arguments (here: `zf_write_compressed3`'s
 * `has_quantize_level`/`hcomp_smooth`) has everything after them shifted and
 * the call fails or corrupts.
 *
 * Fix: simulate Apple-arm64 argument classification (8 int registers, 8 fp
 * registers, rest on the stack) and fuse each stack-order-adjacent pair of
 * 4-byte int arguments into a single `u64` whose low half is the earlier
 * argument — byte-identical to the natural-packed layout, and stable even on
 * a future bun that fixes the slot layout (the fused signature's own natural
 * layout is the same bytes). Verified empirically against a probe dylib.
 */
import { createRequire } from "node:module";
import type { NativeArg, NativeFn, NativeLibrary, NativeResult, NativeType, Proto, Ptr } from "./types.js";

const IS_LLP64 = process.platform === "win32";
const NEEDS_DARWIN_ARM64_FIX = process.platform === "darwin" && process.arch === "arm64";

const requireModule = createRequire(import.meta.url);
const encoder = new TextEncoder();

function ffiTypeOf(t: NativeType): string {
  switch (t) {
    case "void":
      return "void";
    case "int":
      return "i32";
    case "u32":
      return "u32";
    case "i64":
      return "i64";
    case "u64":
      return "u64";
    case "f32":
      return "f32";
    case "f64":
      return "f64";
    case "long":
      return IS_LLP64 ? "i32" : "i64";
    case "usize":
      return "u64";
    case "handle":
      return "u64";
    case "buf":
    case "cstr":
    case "cstr_arr":
      return "ptr";
    case "cstring_ret":
      return "cstring";
  }
}

/** Fusions for one proto: [loIndex, hiIndex] pairs into original args. */
interface StackFix {
  readonly pairs: readonly (readonly [number, number])[];
  /** Post-fusion bun type list (lo position becomes "u64", hi dropped). */
  readonly types: readonly string[];
}

const isFpType = (t: NativeType): boolean => t === "f32" || t === "f64";
const argByteSize = (t: NativeType): number => (t === "int" || t === "u32" || t === "f32" ? 4 : 8);

/**
 * Compute the darwin-arm64 fused-pair plan for a signature, or null when
 * bun's 8-byte-slot layout already matches the natural-packed layout.
 * Throws for signatures that cannot be made equivalent (fail loud, never
 * corrupt) — none exist in the zf_* ABI today.
 */
function planDarwinArm64Fix(args: readonly NativeType[]): StackFix | null {
  let intRegs = 8;
  let fpRegs = 8;
  const stackIdx: number[] = [];
  for (let i = 0; i < args.length; i++) {
    if (isFpType(args[i])) {
      if (fpRegs > 0) {
        fpRegs--;
        continue;
      }
    } else if (intRegs > 0) {
      intRegs--;
      continue;
    }
    stackIdx.push(i);
  }
  if (stackIdx.length === 0) return null;

  const pairs: [number, number][] = [];
  let off = 0;
  for (let k = 0; k < stackIdx.length; k++) {
    const i = stackIdx[k];
    const t = args[i];
    const size = argByteSize(t);
    if (size === 8) {
      off = (off + 7) & ~7;
      off += 8;
      continue;
    }
    if (isFpType(t)) {
      throw new Error("bun:ffi darwin-arm64: f32 stack argument is not supported");
    }
    // 4-byte int-class stack arg.
    if (off % 8 !== 0) {
      throw new Error("bun:ffi darwin-arm64: unpairable 4-byte stack argument at odd slot");
    }
    const nk = k + 1;
    if (nk < stackIdx.length && argByteSize(args[stackIdx[nk]]) === 4 && !isFpType(args[stackIdx[nk]])) {
      pairs.push([i, stackIdx[nk]]);
      off += 8;
      k = nk;
    } else {
      // Lone 4-byte arg: the pad to the next 8-byte boundary makes bun's
      // slot layout coincide with the natural one.
      off += 8;
    }
  }
  if (pairs.length === 0) return null;

  const drop = new Set(pairs.map(([, hi]) => hi));
  const lo = new Set(pairs.map(([l]) => l));
  const types: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (drop.has(i)) continue;
    types.push(lo.has(i) ? "u64" : ffiTypeOf(args[i]));
  }
  return { pairs, types };
}

export function openBunLibrary(libPath: string, protos: readonly Proto[]): NativeLibrary {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const bunFfi: any = requireModule("bun:ffi");
  const { dlopen, ptr, CString } = bunFfi;

  const fixes = new Map<string, StackFix>();
  const spec: Record<string, { args: readonly string[]; returns: string }> = {};
  for (const p of protos) {
    const fix = NEEDS_DARWIN_ARM64_FIX ? planDarwinArm64Fix(p.args) : null;
    if (fix) fixes.set(p.name, fix);
    spec[p.name] = { args: fix ? fix.types : p.args.map(ffiTypeOf), returns: ffiTypeOf(p.returns) };
  }
  const lib = dlopen(libPath, spec);

  const convertArg = (kind: NativeType, v: NativeArg, keepAlive: unknown[]): unknown => {
    switch (kind) {
      case "buf":
        return v === null ? null : (v as ArrayBufferView);
      case "cstr": {
        if (v === null) return null;
        const bytes = encoder.encode(v as string);
        const buf = new Uint8Array(bytes.length + 1);
        buf.set(bytes);
        keepAlive.push(buf);
        return buf;
      }
      case "cstr_arr": {
        if (v === null) return null;
        const entries = v as readonly (string | null)[];
        const ptrs = new BigUint64Array(entries.length);
        for (let i = 0; i < entries.length; i++) {
          const e = entries[i];
          if (e === null) {
            ptrs[i] = 0n;
          } else {
            const bytes = encoder.encode(e);
            const buf = new Uint8Array(bytes.length + 1);
            buf.set(bytes);
            keepAlive.push(buf);
            ptrs[i] = BigInt(ptr(buf));
          }
        }
        keepAlive.push(ptrs);
        return ptrs;
      }
      case "handle":
        return v === null ? 0n : (v as bigint);
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
        return typeof out === "bigint" ? out : BigInt(out as number);
      case "cstring_ret":
        return out == null ? "" : String(out);
      default:
        return Number(out);
    }
  };

  const fusePack = (loVal: unknown, hiVal: unknown): bigint =>
    BigInt.asUintN(32, BigInt(loVal as number)) | (BigInt.asUintN(32, BigInt(hiVal as number)) << 32n);

  const fn: Record<string, NativeFn> = {};
  for (const p of protos) {
    const raw = lib.symbols[p.name];
    if (typeof raw !== "function") {
      throw new Error(`symbol ${p.name} missing from ${libPath}`);
    }
    const argKinds = p.args;
    const retKind = p.returns;
    const fix = fixes.get(p.name) ?? null;
    fn[p.name] = (...args: NativeArg[]): NativeResult => {
      // keepAlive pins buffers that are only referenced by raw addresses
      // (cstr_arr entries) for the duration of the synchronous call.
      const keepAlive: unknown[] = [];
      const conv = new Array(args.length);
      for (let i = 0; i < args.length; i++) conv[i] = convertArg(argKinds[i], args[i], keepAlive);
      let callArgs = conv;
      if (fix) {
        const drop = new Set(fix.pairs.map(([, hi]) => hi));
        const loOf = new Map(fix.pairs);
        callArgs = [];
        for (let i = 0; i < conv.length; i++) {
          if (drop.has(i)) continue;
          const hi = loOf.get(i);
          callArgs.push(hi === undefined ? conv[i] : fusePack(conv[i], conv[hi]));
        }
      }
      const out = raw(...callArgs);
      if (keepAlive.length > 0) keepAlive.length = 0;
      return convertRet(retKind, out);
    };
  }

  return {
    backend: "bun",
    fn,
    readCString(p: Ptr, len: number): string {
      if (p === 0n || len === 0) return "";
      return new CString(Number(p), 0, len).toString();
    },
    close() {
      lib.close();
    },
  };
}
