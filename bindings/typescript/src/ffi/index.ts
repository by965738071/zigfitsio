/** Runtime sniff + backend dispatch. */
import type { NativeLibrary, Proto } from "./types.js";
import { openBunLibrary } from "./bun.js";
import { openKoffiLibrary } from "./koffi.js";

export type { NativeArg, NativeFn, NativeLibrary, NativeResult, NativeType, Proto, Ptr } from "./types.js";

export const isBun: boolean = typeof process !== "undefined" && !!process.versions?.bun;

export function openNativeLibrary(libPath: string, protos: readonly Proto[]): NativeLibrary {
  return isBun ? openBunLibrary(libPath, protos) : openKoffiLibrary(libPath, protos);
}
