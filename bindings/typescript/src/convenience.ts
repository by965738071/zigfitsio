/** Module-level conveniences (port of the Python `core.py` module functions). */
import { gunzip, readFile } from "./fsbridge.js";
import { FitsIOError, FitsTypeError } from "./errors.js";
import * as ll from "./lowlevel/index.js";
import { FitsArray } from "./fitsarray.js";
import type { TypedArray } from "./dtypes.js";
import { Header } from "./header.js";
import { PrimaryHDU } from "./hdu.js";
import { HDUList } from "./hdulist.js";
import { TableData } from "./table.js";
import { decOut } from "./util.js";

export type OpenMode = "readonly" | "update" | "append";

const MODE_CODES: Record<OpenMode, number> = {
  readonly: ll.READONLY,
  update: ll.READWRITE,
  append: ll.READWRITE,
};

/**
 * Open a FITS file. `mode`: "readonly", "update" (read-write), or "append".
 * A `.fits.gz` path opens read-only through an in-memory inflate.
 *
 * The bytes are read on the JS side and handed to the in-memory ABI (the wasm
 * module has no filesystem); a writable open remembers the path and writes the
 * updated bytes back to it on `close()` (astropy update-on-close semantics).
 */
export function open(path: string, mode: OpenMode = "readonly", opts?: ll.OpenOptions): HDUList {
  const modeCode = MODE_CODES[mode];
  if (modeCode === undefined) {
    throw new FitsTypeError(410, `invalid mode ${JSON.stringify(mode)}: expected 'readonly', 'update', or 'append'`);
  }
  const optBuf = opts === undefined ? null : ll.encodeOpenOpts(opts);
  const out = ll.outU64();
  let bytes: Uint8Array;
  try {
    bytes = readFile(path);
  } catch (e) {
    // Surface a missing/unreadable file as a typed FITS error (parity with the old
    // path-based zf_open_file, which returned a FITS status rather than a raw fs error).
    throw new FitsIOError(104, `could not open file ${JSON.stringify(path)}: ${(e as Error).message}`);
  }
  if (path.endsWith(".gz")) {
    // A .gz opens into an in-memory handle that cannot write back to the
    // compressed file; reject a writable mode up front rather than failing
    // mid-edit with a device-read-only error.
    if (modeCode !== ll.READONLY) {
      throw new FitsIOError(112, "a .gz file can only be opened in 'readonly' mode");
    }
    const plain = gunzip(bytes);
    ll.check(ll.lib.zf_open_memory(plain, plain.length, ll.READONLY, optBuf, out));
    return HDUList._fromHandle(out[0], modeCode);
  }
  ll.check(ll.lib.zf_open_memory(bytes, bytes.length, modeCode, optBuf, out));
  const hdul = HDUList._fromHandle(out[0], modeCode);
  hdul._path = path; // origin for update/append write-back on close()
  return hdul;
}

/** Open a FITS file held in a byte buffer. */
export function fromBytes(data: Uint8Array, mode: "readonly" | "update" = "readonly"): HDUList {
  const modeCode = mode === "readonly" ? ll.READONLY : ll.READWRITE;
  const out = ll.outU64();
  ll.check(ll.lib.zf_open_memory(data, data.length, modeCode, null, out));
  return HDUList._fromHandle(out[0], modeCode);
}

export function getHeader(path: string, ext: number | string = 0): Header {
  const hdul = open(path);
  try {
    return hdul.get(ext).header;
  } finally {
    hdul.close();
  }
}

export type HDUData = FitsArray | TableData | null;

export function getData(path: string, options?: { ext?: number | string; header?: false }): HDUData;
export function getData(path: string, options: { ext?: number | string; header: true }): { data: HDUData; header: Header };
export function getData(
  path: string,
  options: { ext?: number | string; header?: boolean } = {},
): HDUData | { data: HDUData; header: Header } {
  const ext = options.ext ?? 0;
  const hdul = open(path);
  try {
    let hdu = hdul.get(ext);
    // astropy convention: an empty primary (ext 0) falls through to the first HDU with data.
    if (ext === 0 && hdu.data === null) {
      for (const cand of hdul) {
        if (cand.data !== null) {
          hdu = cand;
          break;
        }
      }
    }
    const data: HDUData = hdu.data;
    if (options.header) return { data, header: hdu.header };
    return data;
  } finally {
    hdul.close();
  }
}

export function getVal(path: string, keyword: string, ext: number | string = 0): ReturnType<Header["value"]> {
  const hdul = open(path);
  try {
    return hdul.get(ext).header.value(keyword);
  } finally {
    hdul.close();
  }
}

export function writeTo(
  path: string,
  data: FitsArray | TypedArray | null,
  options: { header?: Header; overwrite?: boolean; checksum?: boolean } = {},
): void {
  new HDUList([new PrimaryHDU({ data, header: options.header })]).writeTo(path, {
    overwrite: options.overwrite,
    checksum: options.checksum,
  });
}

/** One structural validation finding. */
export class Finding {
  constructor(
    readonly severity: "error" | "warning",
    readonly hdu: number,
    readonly keyword: string | null,
    readonly message: string,
  ) {}

  toString(): string {
    const kw = this.keyword ? ` ${this.keyword}` : "";
    return `<${this.severity} HDU ${this.hdu}${kw}: ${this.message}>`;
  }
}

/** Run the fitsverify-style structural pass; return the findings. */
export function verify(source: string | HDUList): Finding[] {
  const own = typeof source === "string";
  const hdul = own ? open(source) : source;
  try {
    const handle = hdul._handle;
    if (handle === null) {
      throw new FitsIOError(104, "verify() requires an HDUList opened from a file or bytes");
    }
    const fout = ll.outU64();
    ll.check(ll.lib.zf_validate(handle, fout));
    const fh = fout[0];
    try {
      const count = ll.newLongArray(1);
      ll.check(ll.lib.zf_findings_count(fh, count));
      const n = ll.readLongAt(count, 0);
      const out: Finding[] = [];
      const kwb = new Uint8Array(80);
      const msgb = new Uint8Array(256);
      for (let i = 0; i < n; i++) {
        const sev = ll.outI32();
        const hd = ll.outI32();
        const kwl = ll.outU64();
        const msgl = ll.outU64();
        ll.check(ll.lib.zf_findings_get(fh, i, sev, hd, kwb, 80, kwl, msgb, 256, msgl));
        const kw = decOut(kwb, kwl[0]);
        out.push(new Finding(sev[0] === 0 ? "error" : "warning", hd[0], kw || null, decOut(msgb, msgl[0])));
      }
      return out;
    } finally {
      ll.lib.zf_findings_free(fh);
    }
  } finally {
    if (own) (hdul as HDUList).close();
  }
}
