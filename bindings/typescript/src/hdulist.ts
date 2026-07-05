/**
 * HDUList (port of the Python `core.py HDUList`): the ordered HDU sequence
 * behind an open file, with the atomic `writeTo` (pristine byte-copy fast
 * path + reconstruction), `toBytes`, and the flush-on-close lifecycle.
 */
import { existsSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { FitsIOError, FitsTypeError } from "./errors.js";
import * as ll from "./lowlevel/index.js";
import { BaseHDU, CompImageHDU, ImageHDU, PrimaryHDU } from "./hdu.js";
import { AsciiTableHDU, BinTableHDU, TableHDU } from "./table.js";
import type { ColumnShape } from "./table.js";
import { enc, fnv1a64, viewBytes } from "./util.js";
import { NotSupportedError } from "./errors.js";

/** Any concrete HDU — `.data` narrows to `FitsArray | TableData | null`. */
export type AnyHDU = PrimaryHDU | ImageHDU | CompImageHDU | BinTableHDU | AsciiTableHDU;

export class HDUList implements Iterable<AnyHDU> {
  readonly hdus: AnyHDU[] = [];

  /** @internal */ _handle: bigint | null = null;
  /** @internal */ _mode: number = ll.READONLY;
  /** @internal */ _owns = false;
  /** @internal HDUs scanned from the source (for the pristine-copy fast path). */
  _scannedCount = 0;
  /**
   * @internal Set when an in-memory edit is NOT reflected in the open C
   * handle's bytes (a data replacement, or a header edit in read-only mode).
   * Such an edit disqualifies the verbatim byte-copy fast path so
   * writeTo/toBytes reconstruct instead of emitting stale original bytes.
   */
  _dirty = false;

  constructor(hdus?: readonly AnyHDU[]) {
    if (hdus) this.hdus.push(...hdus);
  }

  // ── opening ──
  /** @internal */
  static _fromHandle(handle: bigint, mode: number): HDUList {
    const hl = new HDUList();
    hl._handle = handle;
    hl._mode = mode;
    hl._owns = true;
    try {
      hl._scan();
    } catch (e) {
      // Never leak a freshly opened native handle when the scan fails.
      hl._handle = null;
      ll.lib.zf_close(handle);
      throw e;
    }
    return hl;
  }

  private _scan(): void {
    const handle = this._handle as bigint;
    const count = ll.newLongArray(1);
    ll.check(ll.lib.zf_hdu_count(handle, count));
    const n = ll.readLongAt(count, 0);
    this._scannedCount = n;
    for (let i = 1; i <= n; i++) {
      ll.check(ll.lib.zf_select(handle, i));
      const kind = ll.outI32();
      ll.check(ll.lib.zf_hdu_type(handle, kind));
      const hdu = this._makeHdu(kind[0], i);
      hdu._hdulist = this;
      hdu._index = i;
      hdu._header = null; // lazily read
      this.hdus.push(hdu);
    }
  }

  private _makeHdu(kind: number, index: number): AnyHDU {
    if (kind === ll.HDU_BINARY_TABLE) {
      // A ZIMAGE BINTABLE is a tile-compressed image.
      const name = enc("ZIMAGE");
      if (Number(ll.lib.zf_key_exists(this._handle as bigint, name, name.length)) === 1) {
        return new CompImageHDU();
      }
      return new BinTableHDU();
    }
    if (kind === ll.HDU_ASCII_TABLE) return new AsciiTableHDU();
    return index === 1 ? new PrimaryHDU() : new ImageHDU();
  }

  // ── access ──
  get length(): number {
    return this.hdus.length;
  }

  [Symbol.iterator](): Iterator<AnyHDU> {
    return this.hdus[Symbol.iterator]();
  }

  /** The HDU at `key`: an index (negative counts from the end) or a case-insensitive EXTNAME. */
  get(key: number | string): AnyHDU {
    if (typeof key === "string") {
      for (const hdu of this.hdus) {
        if (hdu.name.toUpperCase() === key.toUpperCase()) return hdu;
      }
      throw new RangeError(`no HDU named ${JSON.stringify(key)}`);
    }
    const i = key < 0 ? this.hdus.length + key : key;
    if (i < 0 || i >= this.hdus.length) throw new RangeError(`HDU index ${key} out of range (${this.hdus.length} HDUs)`);
    return this.hdus[i];
  }

  at(i: number): AnyHDU | undefined {
    return this.hdus.at(i);
  }

  /**
   * The HDU at `key`, asserted to be an image HDU (`ImageHDU`, `PrimaryHDU`,
   * or `CompImageHDU`) so `.data` narrows to `FitsArray | null` with no cast.
   * `key` defaults to `0` (the primary HDU is always an image); `table()` has
   * no default because HDU 0 is never a table. Throws `FitsTypeError` if the
   * HDU is a table.
   */
  image(key: number | string = 0): ImageHDU {
    const hdu = this.get(key);
    if (!(hdu instanceof ImageHDU)) {
      throw new FitsTypeError(410, `HDU ${JSON.stringify(key)} is a ${hdu.kind} HDU, not an image HDU`);
    }
    return hdu;
  }

  /**
   * The HDU at `key`, asserted to be a table HDU (`BinTableHDU` or
   * `AsciiTableHDU`) so `.data` narrows to `TableData<T> | null` with no cast.
   * The optional type parameter `T` names the column shape for typed reads
   * (compile-time only). Throws `FitsTypeError` if the HDU is an image.
   */
  table<T extends ColumnShape = ColumnShape>(key: number | string): TableHDU<T> {
    const hdu = this.get(key);
    if (!(hdu instanceof TableHDU)) {
      throw new FitsTypeError(410, `HDU ${JSON.stringify(key)} is a ${hdu.kind} HDU, not a table HDU`);
    }
    return hdu as unknown as TableHDU<T>;
  }

  append(hdu: AnyHDU): void {
    this.hdus.push(hdu);
  }

  info(): string {
    return this.hdus.map((hdu, i) => `${String(i).padStart(3)}  ${hdu.name.padEnd(12)}  ${hdu.constructor.name}`).join("\n");
  }

  // ── lifecycle ──
  flush(): void {
    if (this._handle === null) return;
    if (this._mode !== ll.READONLY) {
      // 1) Serialize any newly-appended (detached) HDUs to the open file, in
      //    order — so an open+append+close (or +flush) actually writes them.
      for (let i = this._scannedCount; i < this.hdus.length; i++) {
        const hdu = this.hdus[i];
        if (hdu._hdulist === null) {
          hdu._writeTo(this._handle, i === 0);
          hdu._hdulist = this;
          hdu._index = i + 1;
          if (hdu instanceof ImageHDU && hdu._data !== null) {
            // Baseline so the next flush (and pristine check) treats the
            // just-appended pixels as unchanged rather than re-writing them.
            hdu._dataFingerprint = fnv1a64(viewBytes(hdu._data.data));
          }
        }
      }
      if (this.hdus.length > this._scannedCount) this._scannedCount = this.hdus.length;
      // 2) Write back in-place edits to attached image/table data.
      for (const hdu of this.hdus) {
        if (hdu._hdulist !== this) continue;
        if (hdu instanceof CompImageHDU) {
          // In-place recompression isn't supported; fail loud rather than silently drop.
          if (hdu._dataChanged()) {
            throw new NotSupportedError(
              410,
              "in-place update of a compressed image is not supported; use writeTo() to a new file",
            );
          }
        } else if (hdu instanceof ImageHDU || hdu instanceof TableHDU) {
          hdu._flushData();
        }
      }
    }
    ll.check(ll.lib.zf_flush(this._handle));
  }

  /**
   * @internal True when this list is exactly what was scanned from an open
   * file — every HDU still attached in its original slot, nothing
   * appended/removed — so it can be copied verbatim.
   */
  _isPristineAttached(): boolean {
    if (this._handle === null || !this._owns || this._dirty || this.hdus.length !== this._scannedCount) {
      return false;
    }
    if (this.hdus.some((hdu) => hdu._dataChanged())) return false; // in-place edits don't set _dirty
    return this.hdus.every((h, i) => h._hdulist === this && h._index === i + 1);
  }

  /** @internal */
  _sourceBytes(): Uint8Array {
    this.flush(); // persist pending header/data edits so the raw bytes are current
    const handle = this._handle as bigint;
    const size = ll.outU64();
    ll.check(ll.lib.zf_data_size(handle, size));
    const buf = new Uint8Array(Number(size[0]));
    const got = ll.outU64();
    ll.check(ll.lib.zf_read_bytes(handle, 0n, buf, buf.length, got));
    return buf.subarray(0, Number(got[0]));
  }

  close(): void {
    if (this._handle === null) return;
    // Persist pending edits before closing (astropy flushes on close in
    // update mode); always release the handle even if the flush fails.
    try {
      if (this._mode !== ll.READONLY) this.flush();
    } finally {
      ll.lib.zf_close(this._handle);
      this._handle = null;
    }
  }

  // ── writing ──
  writeTo(path: string, options: { overwrite?: boolean; checksum?: boolean } = {}): void {
    const overwrite = options.overwrite ?? false;
    const checksum = options.checksum ?? false;
    if (existsSync(path) && !overwrite) {
      throw new FitsIOError(105, `file exists: ${path} (use overwrite: true)`);
    }
    // Write to a temp file in the same directory, then atomically rename into
    // place: a failure never leaves a partial/corrupt file at `path`, and
    // overwrite does not destroy the existing file until the new one is done.
    const tmp = path + ".zigfitsio.tmp";
    try {
      if (!checksum && this._isPristineAttached()) {
        writeFileSync(tmp, this._sourceBytes());
      } else {
        const opts = checksum ? ll.encodeOpenOpts({ checksumOnClose: true }) : null;
        const out = ll.outU64();
        const pb = enc(tmp);
        ll.check(ll.lib.zf_create_file(pb, pb.length, opts, out));
        const handle = out[0];
        try {
          this._emit(handle, checksum);
          ll.check(ll.lib.zf_flush(handle));
        } finally {
          ll.lib.zf_close(handle);
        }
      }
      renameSync(tmp, path);
    } catch (e) {
      try {
        rmSync(tmp);
      } catch {
        /* tmp may not exist */
      }
      throw e;
    }
  }

  /** Serialize the HDU list to an in-memory FITS byte buffer. */
  toBytes(): Uint8Array {
    if (this._isPristineAttached()) return this._sourceBytes();
    const out = ll.outU64();
    ll.check(ll.lib.zf_create_memory(null, out));
    const handle = out[0];
    try {
      this._emit(handle, false);
      ll.check(ll.lib.zf_flush(handle));
      const size = ll.outU64();
      ll.check(ll.lib.zf_data_size(handle, size));
      const buf = new Uint8Array(Number(size[0]));
      const got = ll.outU64();
      ll.check(ll.lib.zf_read_bytes(handle, 0n, buf, buf.length, got));
      return buf.subarray(0, Number(got[0]));
    } finally {
      ll.lib.zf_close(handle);
    }
  }

  /** @internal */
  _emit(handle: bigint, checksum: boolean): void {
    const hdus = this.hdus;
    if (hdus.length === 0) {
      throw new FitsIOError(104, "cannot serialize an empty HDUList (a FITS file needs a primary HDU)");
    }
    // Tables and tile-compressed images both serialize as BINTABLE
    // extensions, so they need a real primary HDU before them. CompImageHDU
    // is an image subclass, so it must be handled explicitly.
    if (!hdus[0].isImage || hdus[0] instanceof CompImageHDU) {
      new PrimaryHDU()._writeTo(handle, true);
    }
    for (let i = 0; i < hdus.length; i++) {
      hdus[i]._writeTo(handle, i === 0);
      if (checksum) ll.check(ll.lib.zf_write_chksum(handle));
    }
  }
}

// `using hdul = open(...)` support where the runtime provides Symbol.dispose
// (Node ≥20.4, Bun). Assigned conditionally so Node 18 still imports cleanly.
export interface HDUList {
  [Symbol.dispose](): void;
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const disposeSym: symbol | undefined = (Symbol as any).dispose;
if (typeof disposeSym === "symbol") {
  Object.defineProperty(HDUList.prototype, disposeSym, {
    value(this: HDUList) {
      this.close();
    },
    writable: true,
    configurable: true,
  });
}
