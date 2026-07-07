/**
 * HDUList (port of the Python `core.py HDUList`): the ordered HDU sequence
 * behind an open file, with the atomic `writeTo` (pristine byte-copy fast
 * path + reconstruction), `toBytes`, and the flush-on-close lifecycle.
 */
import { existsSync, renameSync, rmSync, writeFile } from "./fsbridge.js";
import { FitsIOError, FitsTypeError } from "./errors.js";
import * as ll from "./lowlevel/index.js";
import { BaseHDU, CompImageHDU, ImageHDU, PrimaryHDU } from "./hdu.js";
import { AsciiTableHDU, BinTableHDU, TableHDU, colFp } from "./table.js";
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
  /**
   * @internal The on-disk path this list was opened from, or null when it was
   * opened from bytes / built in memory. A writable open writes the updated
   * in-memory bytes back here on `close()` (the wasm module has no filesystem,
   * so update-on-close is a JS-side write-back rather than an in-place file edit).
   */
  _path: string | null = null;
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
      // 1) Reconcile the file's HDU layout with the in-memory list — appends,
      //    inserts, deletions, and reorders — so an open+edit+close persists
      //    structure, not just writeTo().
      this._reconcile();
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

  /** @internal Whether list position `i` still holds the HDU attached to this file's slot `i + 1`. */
  private _attachedAt(hdu: AnyHDU, i: number): boolean {
    return hdu instanceof BaseHDU && hdu._hdulist === this && hdu._index === i + 1;
  }

  private _hduCount(): number {
    const count = ll.newLongArray(1);
    ll.check(ll.lib.zf_hdu_count(this._handle as bigint, count));
    return ll.readLongAt(count, 0);
  }

  /**
   * @internal Make the open file's HDU layout match the in-memory list
   * (update/append mode): persist appends, inserts, deletions, and reorders.
   * A shifted-but-attached HDU is byte-copied (zf_copy_hdu) so its user
   * keywords, VLA heap, compression bytes, and checksums survive exactly; a
   * detached or foreign HDU is serialized via _writeTo. The order is
   * load-bearing: copies are APPENDED first (while the source indices are
   * still valid for lazy reads), the displaced originals are deleted after,
   * and bookkeeping is rebound last.
   */
  private _reconcile(): void {
    const handle = this._handle as bigint;
    // Longest leading run of HDUs still in their scanned slots; everything after is rebuilt.
    let prefix = 0;
    for (const [i, hdu] of this.hdus.entries()) {
      if (!this._attachedAt(hdu, i)) break;
      prefix += 1;
    }
    if (prefix === this.hdus.length && prefix === this._scannedCount) {
      return; // layout already matches the file
    }
    // ── pre-flight guards: every rejection fires BEFORE any file mutation. The type check
    // runs first (over the whole list) so a stray object at position 0 reports what it is,
    // not a misleading "primary must remain first". ──
    for (const hdu of this.hdus) {
      if (!(hdu instanceof BaseHDU)) {
        throw new FitsTypeError(410, `HDUList contains a non-HDU object: ${String(hdu)}`);
      }
    }
    if (prefix === 0) {
      throw new NotSupportedError(
        410,
        "the primary HDU of an open file must remain first; use writeTo() to a new file",
      );
    }
    if (new Set(this.hdus).size !== this.hdus.length) {
      throw new FitsTypeError(
        410,
        "the same HDU object appears at more than one position in the HDUList; " +
          "flush cannot bind one object to two slots — insert a copy instead",
      );
    }
    for (const hdu of this.hdus) {
      if (hdu instanceof CompImageHDU && hdu._hdulist === this && hdu._dataChanged()) {
        throw new NotSupportedError(
          410,
          "in-place update of a compressed image is not supported; use writeTo() to a new file",
        );
      }
    }
    const diskCount = this._hduCount(); // authoritative on-disk count (drives cleanup + deletes)
    // ── append phase: the originals are still at their scanned indices, so lazy
    // header/data reads (and _emitColumns' source-table access) stay valid ──
    const serialized = new Set<number>();
    try {
      for (let i = prefix; i < this.hdus.length; i++) {
        const hdu = this.hdus[i];
        if (hdu._hdulist === this && hdu._index !== null && hdu._index >= 2) {
          // Exact byte copy of the HDU's on-disk form. In update mode header
          // edits were already persisted to the source slot, so the copy
          // carries them; pending in-place DATA edits are intentionally not
          // carried — step 2 of flush writes them back at the new index
          // (fingerprints are left untouched below).
          ll.check(ll.lib.zf_copy_hdu(handle, hdu._index));
        } else {
          // Detached, attached to another HDUList, or the primary duplicated
          // into the tail (zf_copy_hdu refuses source 1: the copy must parse
          // as an extension).
          hdu._writeTo(handle, false);
          serialized.add(i);
        }
      }
    } catch (e) {
      // Roll back the partial tail so the file is left byte-identical.
      // Count-driven so a fully-created HDU whose column/data write failed
      // halfway is removed too. A cleanup failure is swallowed: the original
      // error matters more, and the file then merely carries extra trailing
      // HDUs (valid FITS, duplicates — never missing data). JS catch is
      // necessarily catch-all; the Python port swallows only Exception.
      try {
        while (this._hduCount() > diskCount) {
          ll.check(ll.lib.zf_delete_hdu(handle, diskCount + 1));
        }
      } catch {
        /* keep the original error */
      }
      throw e;
    }
    // ── delete phase: drop the displaced originals; the appended tail shifts
    // into place. (Never hold a zf_table_open handle across this loop:
    // zf_delete_hdu frees the *Hdu a table handle wraps.) A failure here
    // leaves duplicates, never missing HDUs.
    for (let k = 0; k < diskCount - prefix; k++) {
      ll.check(ll.lib.zf_delete_hdu(handle, prefix + 1));
    }
    // ── rebind bookkeeping to the new layout ──
    for (let i = prefix; i < this.hdus.length; i++) {
      const hdu = this.hdus[i];
      hdu._hdulist = this;
      hdu._index = i + 1;
      if (serialized.has(i)) {
        // _writeTo serialized the CURRENT in-memory data: baseline it so step 2
        // doesn't re-write it (or, for a foreign table with a pending
        // VLA/scaled-column edit, spuriously raise). Byte-copied HDUs keep
        // their old baseline on purpose — the copy carried the ORIGINAL bytes,
        // so a pending in-place edit must still be detected and written back
        // at the new index.
        if (hdu instanceof ImageHDU && hdu._data !== null) {
          hdu._dataFingerprint = fnv1a64(viewBytes(hdu._data.data));
        } else if (hdu instanceof TableHDU && hdu._data !== null) {
          const rec = hdu._data;
          hdu._colFingerprints = new Map(rec.names.map((n) => [n, colFp(rec.column(n))]));
        }
      }
      if (hdu._header !== null && hdu._header._persist === null) {
        // A header materialized while detached (or under a read-only list) has
        // no persist hook; future edits must reach THIS file's handle like any
        // attached header's do.
        const bound = hdu;
        hdu._header._persist = (key, value, comment) => bound._writeKey(key, value, comment);
        hdu._header._delete = (key) => bound._deleteKey(key);
        hdu._header._dirtyCb = () => bound._markDirty();
      }
    }
    this._scannedCount = this.hdus.length;
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
    return this.hdus.every((h, i) => this._attachedAt(h, i));
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
    // Persist pending edits before closing (astropy flushes on close in update
    // mode). The wasm handle's device is in RAM, so a writable open opened from a
    // path also writes the resulting bytes back to that file here. Always release
    // the handle even if the flush/write-back fails.
    try {
      if (this._mode !== ll.READONLY) {
        this.flush();
        if (this._path !== null) writeFile(this._path, this._sourceBytes());
      }
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
    // Build the bytes in memory (the wasm module has no filesystem), then write
    // to a temp file and atomically rename into place: a failure never leaves a
    // partial/corrupt file at `path`, and overwrite does not destroy the existing
    // file until the new one is complete.
    const tmp = path + ".zigfitsio.tmp";
    try {
      const bytes = !checksum && this._isPristineAttached() ? this._sourceBytes() : this._emitBytes(checksum);
      writeFile(tmp, bytes);
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
    return this._emitBytes(false);
  }

  /**
   * @internal Reconstruct the whole file into a fresh in-memory device and read
   * back its bytes. Shared by `toBytes` and `writeTo` (replacing the old
   * `zf_create_file` path, which the wasm build cannot use).
   */
  _emitBytes(checksum: boolean): Uint8Array {
    const opts = checksum ? ll.encodeOpenOpts({ checksumOnClose: true }) : null;
    const out = ll.outU64();
    ll.check(ll.lib.zf_create_memory(opts, out));
    const handle = out[0];
    try {
      this._emit(handle, checksum);
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
