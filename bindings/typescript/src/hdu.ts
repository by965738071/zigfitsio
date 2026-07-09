/**
 * HDU classes (method-for-method port of the Python `core.py` HDU layer).
 * An HDU is either *attached* (from an open file: `_hdulist` + `_index`) or
 * *detached* (built in JS with `_data`/`_header` for writing).
 */
import { FitsHeaderError, FitsIOError, FitsOverflowError, FitsTypeError, KeywordNotFound, NotSupportedError } from "./errors.js";
import * as ll from "./lowlevel/index.js";
import * as dt from "./dtypes.js";
import { FitsArray, asFitsArray } from "./fitsarray.js";
import { Header, parseCards, wrapCommentary, type HeaderValue } from "./header.js";
import { enc, fnv1a64, viewBytes } from "./util.js";
import type { HDUList } from "./hdulist.js";

/**
 * @internal "Data never materialized" marker for `_data`. Distinct from `null`,
 * which is an EXPLICIT `hdu.data = null` clear: the lazy getter re-reads only on
 * DATA_UNSET, so a clear is never silently resurrected from the open file.
 * Exported for table.ts/hdulist.ts only — not part of the public API surface.
 */
export const DATA_UNSET: unique symbol = Symbol("zigfitsio.data.unset");

// Structural keywords the library derives from the data; user header edits must not overwrite them.
const STRUCTURAL = new Set([
  "SIMPLE",
  "BITPIX",
  "NAXIS",
  "EXTEND",
  "PCOUNT",
  "GCOUNT",
  "XTENSION",
  "END",
  "BSCALE",
  "BZERO",
]);

export function isStructuralKeyword(kw: string): boolean {
  const up = kw.toUpperCase();
  return STRUCTURAL.has(up) || up.startsWith("NAXIS");
}

// Keywords the table write path itself produces, which must NOT be copied back
// from the source header or they would duplicate / conflict with the freshly
// written cards. Matched (skipped): TFIELDS, THEAP, and TFORMn/TTYPEn/TUNITn/
// TBCOLn/TSCALn/TZEROn. Not matched (preserved as user metadata): everything
// else, notably TNULLn/TDISPn/TDIMn.
//   - column descriptors (TFORMn/TTYPEn/TUNITn/TBCOLn) are emitted by zf_create_tbl;
//   - the scaling pair (TSCALn/TZEROn) is skipped like image BSCALE/BZERO, because
//     scaled columns are read as physical f64 and re-written physical, so copying
//     the scaling back would double-apply it on the next read;
//   - THEAP is skipped ON PURPOSE (it is derived from the default heap layout the
//     write path uses; a stale source THEAP would point at the wrong offset) — this
//     is why it sits with the skipped group and NOT with the preserved TNULL/TDISP/TDIM.
// Filtering TNULLn/TDISPn/TDIMn would re-create the very keyword-loss bug, since
// the write path never emits them. Argument is already uppercased.
export function isTableStructuralKeyword(up: string): boolean {
  return up === "TFIELDS" || up === "THEAP" || /^T(FORM|TYPE|UNIT|BCOL|SCAL|ZERO)\d+$/.test(up);
}

// A tile-compressed image is stored as a BINTABLE carrying the ZIMAGE
// convention; the compressed HDU already emits these cards. Enumerated rather
// than a broad /^Z/ so real user keywords like ZP/ZENITH/ZDEC survive. Argument
// is already uppercased.
export function isCompStructuralKeyword(up: string): boolean {
  return (
    isTableStructuralKeyword(up) ||
    /^Z(IMAGE|SIMPLE|EXTEND|BITPIX|NAXIS\d*|PCOUNT|GCOUNT|TILE\d+|CMPTYPE|NAME\d+|VAL\d+|MASKCMP|QUANTIZ|DITHER0|BLANK|HECKSUM|DATASUM|THEAP)$/.test(up)
  );
}

const INT64_MIN = -(2n ** 63n);
const INT64_MAX = 2n ** 63n - 1n;

/** ASCII bytes with non-ASCII replaced by '?' (Python encode("ascii", "replace")). */
function asciiBytes(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    out[i] = c < 128 ? c : 63;
  }
  return out;
}

/** An 80-byte COMMENT/HISTORY/blank card: keyword in cols 1-8, free text in cols 9-80. */
function commentaryCard(kw: string, value: HeaderValue): Uint8Array {
  const text = value === null || value === undefined ? "" : String(value);
  return asciiBytes((kw.toUpperCase().padEnd(8) + text).slice(0, 80).padEnd(80));
}

/** Serialize a header value to its FITS card literal (for HIERARCH cards written raw). */
function fitsValueLiteral(value: HeaderValue): string {
  if (typeof value === "boolean") return value ? "T" : "F";
  if (value === null || value === undefined) return "";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      // FITS has no NaN/Inf spelling; `String(NaN)` would stamp a literal "NaN" token no
      // reader accepts. This raw-card path bypasses the Zig-core guard, so reject here.
      throw new FitsHeaderError(207, `non-finite float keyword value ${value}: FITS headers cannot represent NaN/Inf`);
    }
    return String(value).replace("e", "E"); // FITS exponents are uppercase
  }
  if (typeof value === "bigint") return String(value);
  return "'" + String(value).replace(/'/g, "''") + "'";
}

/**
 * Largest cut ≤ `want` that does not split a `''` escape pair. `esc` always
 * starts on a pair boundary (callers only advance by pair-safe takes), so a
 * left-to-right walk decides pair membership unambiguously.
 */
function pairSafeTake(esc: string, want: number): number {
  let j = 0;
  while (j < want) {
    if (esc[j] === "'") {
      if (j + 1 === want) return want - 1;
      j += 2;
    } else {
      j++;
    }
  }
  return want;
}

/**
 * The 80-byte card run for a HIERARCH keyword: one card when it fits, else
 * HIERARCH+CONTINUE (port of the Python `_hierarch_cards`; astropy's layout).
 *
 * Long string values continue across CONTINUE cards: the base fragment fills
 * to column 80 with the `&` sentinel inside the quotes, and the comment rides
 * the last fragment or a dedicated `CONTINUE  '' / comment` card. The escaped
 * text is chunked so a `''` escape pair is never split across cards. A
 * non-string value never continues (the convention applies to strings only):
 * its comment may be truncated, but a value that cannot fit throws instead of
 * being silently cut (the old single-card builder truncated at 80 bytes).
 */
function hierarchCards(kw: string, value: HeaderValue, comment: string): Uint8Array[] {
  let tokens = kw.trim();
  if (/^hierarch /i.test(tokens)) tokens = tokens.slice(9).replace(/^ +/, ""); // never double the prefix
  const prefix = "HIERARCH " + tokens + " = ";
  const lit = fitsValueLiteral(value);
  const body = prefix + lit + (comment ? " / " + comment : "");
  if (body.length <= 80) return [asciiBytes(body.padEnd(80))]; // fast path: identical to the single-card form
  if (typeof value !== "string") {
    if ((prefix + lit).length <= 80) return [asciiBytes(body.slice(0, 80).padEnd(80))]; // only the comment is cut
    throw new FitsHeaderError(207, `HIERARCH card for '${tokens}' does not fit in 80 columns`);
  }
  const esc = value.replace(/'/g, "''");
  if (esc.length === 0) {
    // Empty string value: only the comment overflows — truncate it.
    return [asciiBytes((prefix + "'' / " + comment).slice(0, 80).padEnd(80))];
  }
  const ccost = comment ? 3 + comment.length : 0;
  const cards: string[] = [];
  let pos = 0;
  let first = true;
  let commentDone = !comment;
  while (pos < esc.length) {
    const head = first ? prefix : "CONTINUE  ";
    const cap = 80 - head.length - 2; // columns between the quotes (incl. a possible '&')
    const remaining = esc.length - pos;
    const terminal = remaining <= cap - ccost;
    const take = terminal ? remaining : pairSafeTake(esc.slice(pos), Math.min(cap - 1, remaining));
    if (take <= 0) throw new FitsHeaderError(207, `HIERARCH keyword '${tokens}' leaves no room for a value`);
    const frag = esc.slice(pos, pos + take);
    pos += take;
    first = false;
    if (terminal) {
      cards.push(head + "'" + frag + "'" + (comment ? " / " + comment : ""));
      commentDone = true;
      break;
    }
    cards.push(head + "'" + frag + "&'");
  }
  if (!commentDone) cards.push(("CONTINUE  '' / " + comment).slice(0, 80)); // astropy's dedicated comment card
  return cards.map((t) => asciiBytes(t.padEnd(80)));
}

/**
 * Write one keyword through the type-dispatched ABI calls. Normalizes JS
 * values: safe-integer `number` → integer card, other finite `number` →
 * double card, `bigint` (range-checked) → integer card, `string` →
 * string/long-string card.
 */
export function writeKeyValue(handle: bigint, key: string, value: HeaderValue, comment: string | null): void {
  const kb = enc(key);
  const cb = comment ? enc(comment) : null;
  const cl = cb ? cb.length : 0;
  if (typeof value === "boolean") {
    ll.check(ll.lib.zf_write_key_log(handle, kb, kb.length, value ? 1 : 0, cb, cl));
    return;
  }
  if (typeof value === "bigint") {
    if (value < INT64_MIN || value > INT64_MAX) {
      throw new FitsOverflowError(412, `integer keyword value ${value} out of signed-64-bit range`);
    }
    ll.check(ll.lib.zf_write_key_lng(handle, kb, kb.length, value, cb, cl));
    return;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      // NaN/±Infinity fail Number.isInteger and would flow to zf_write_key_dbl, producing a
      // card no reader parses (the FITS real grammar has no NaN/Inf spelling). Fail fast.
      throw new FitsHeaderError(207, `non-finite float keyword value ${value} for ${key}: FITS headers cannot represent NaN/Inf`);
    }
    // Any exact-integer double in i64 range writes as an integer card, so a
    // parsed integer keyword (numbers up to 2^63 parse exactly) round-trips
    // as the same card type. Beyond the range (or non-integer) → double card.
    if (Number.isInteger(value) && value >= -(2 ** 63) && value < 2 ** 63) {
      ll.check(ll.lib.zf_write_key_lng(handle, kb, kb.length, BigInt(value), cb, cl));
    } else {
      ll.check(ll.lib.zf_write_key_dbl(handle, kb, kb.length, value, cb, cl));
    }
    return;
  }
  if (typeof value === "string") {
    const vb = enc(value);
    if (vb.length <= 68) {
      ll.check(ll.lib.zf_write_key_str(handle, kb, kb.length, vb, vb.length, cb, cl));
    } else {
      ll.check(ll.lib.zf_write_key_longstr(handle, kb, kb.length, vb, vb.length, cb, cl));
    }
    return;
  }
  if (value === null) {
    // An undefined-value card (blank value field) — the FITS way to say "no value".
    ll.check(ll.lib.zf_write_key_undef(handle, kb, kb.length, cb, cl));
    return;
  }
  throw new FitsTypeError(410, `cannot write an undefined value for keyword ${key}`);
}

/**
 * Write an integer-convention keyword (BZERO/TZEROn) — as a double when it
 * exceeds the signed-64-bit keyword slot (2^63 for uint64, exact as a double).
 */
export function writeConventionOffset(handle: bigint, key: string, value: number): void {
  const kb = enc(key);
  if (value >= -(2 ** 63) && value <= 2 ** 63 - 1024) {
    ll.check(ll.lib.zf_write_key_lng(handle, kb, kb.length, BigInt(value), null, 0));
  } else {
    ll.check(ll.lib.zf_write_key_dbl(handle, kb, kb.length, value, null, 0));
  }
}

/**
 * `v` (a header value) equals the number `n` exactly, treating a MISSING
 * keyword as `dflt`. A present card with an undefined value (`null`) is NOT
 * the default — Python's `None in (1, 1.0)` is False, so e.g. a valueless
 * `BSCALE =` card marks the image as scaled.
 */
function eqNum(v: HeaderValue | undefined, dflt: number, n: number): boolean {
  if (v === undefined) return dflt === n;
  if (typeof v === "number") return v === n;
  if (typeof v === "bigint") return Number(v) === n && BigInt(n) === v;
  return false;
}

function headerNum(v: HeaderValue | undefined, dflt: number): number {
  if (typeof v === "number") return v;
  if (typeof v === "bigint") return Number(v);
  return dflt;
}

// ════════════════════════════════════════════════════════════════════════
// Base HDU
// ════════════════════════════════════════════════════════════════════════

export interface HDUOptions {
  header?: Header;
  name?: string;
}

/**
 * The concrete HDU flavor, as a string-literal discriminant. Narrow `AnyHDU`
 * on `hdu.kind` (or use the typed `HDUList.image()`/`table()` accessors) to
 * avoid `as` casts when reaching for `.data`.
 *
 * Narrowing precision, because `PrimaryHDU`/`CompImageHDU` extend `ImageHDU`
 * (and both table classes extend `TableHDU`): `"image"`, `"bintable"`, and
 * `"asciitable"` narrow `AnyHDU` to exactly one class; `"primary"` narrows to
 * `PrimaryHDU | ImageHDU` and `"compimage"` to `CompImageHDU | ImageHDU`. That
 * imprecision is harmless — every image kind shares the same `FitsArray | null`
 * `.data` — and the typed `HDUList.image()`/`table()` accessors sidestep it.
 */
export type HDUKind = "primary" | "image" | "compimage" | "bintable" | "asciitable";

export abstract class BaseHDU {
  /** The concrete HDU flavor (discriminant for narrowing `AnyHDU`). */
  abstract readonly kind: HDUKind;
  readonly isImage: boolean = false;

  /** @internal */ _hdulist: HDUList | null = null;
  /** @internal */ _index: number | null = null;
  /** @internal */ _header: Header | null;
  /** @internal */ _name: string | null;

  constructor(options: HDUOptions = {}) {
    this._header = options.header ?? new Header();
    this._name = options.name ?? null;
  }

  // ── attached helpers ──
  /** @internal */
  _select(): bigint {
    const hl = this._hdulist;
    if (hl === null || hl._handle === null) {
      throw new FitsIOError(104, "operation on a detached or closed HDU");
    }
    ll.check(ll.lib.zf_select(hl._handle, this._index as number));
    return hl._handle;
  }

  /** @internal */
  _writable(): boolean {
    return this._hdulist !== null && this._hdulist._mode !== ll.READONLY;
  }

  /** @internal An in-memory edit the open handle doesn't know about — force reconstruction on save. */
  _markDirty(): void {
    if (this._hdulist !== null) this._hdulist._dirty = true;
  }

  /**
   * @internal Whether this HDU's materialized data differs from what was
   * read — catching an in-place mutation that never goes through a setter.
   * Consulted by the writeTo/toBytes pristine gate.
   */
  _dataChanged(): boolean {
    return false;
  }

  /** @internal Update-mode in-place write-back (image/table HDUs override). */
  _flushData(): void {}

  /** @internal Serialize this HDU into `handle` (subclasses implement). */
  abstract _writeTo(handle: bigint, primary: boolean): void;

  // ── header ──
  get header(): Header {
    if (this._header === null) this._header = this._readHeader();
    return this._header;
  }

  /** @internal */
  _readHeader(): Header {
    const h = this._select();
    const n = ll.newLongArray(1);
    ll.check(ll.lib.zf_card_count(h, n));
    const raws: Uint8Array[] = [];
    const count = ll.readLongAt(n, 0);
    for (let i = 0; i < count; i++) {
      const buf = new Uint8Array(80);
      ll.check(ll.lib.zf_read_card(h, i, buf));
      raws.push(buf);
    }
    const hdr = Header.fromCards(parseCards(raws));
    if (this._writable()) {
      hdr._persist = (key, value, comment) => this._writeKey(key, value, comment);
      hdr._delete = (key) => this._deleteKey(key);
      hdr._resync = (keyword, texts) => this._resyncCommentary(keyword, texts);
    }
    // A read-only header edit is not persisted to the handle; flag it so save reconstructs.
    hdr._dirtyCb = () => this._markDirty();
    return hdr;
  }

  /** @internal */
  _writeKey(key: string, value: HeaderValue, comment: string | null): void {
    const up = key.toUpperCase();
    if (up === "COMMENT" || up === "HISTORY" || up === "") {
      // Commentary cards are appended verbatim (insert-before-END) as raw records, never written
      // as valued keywords. Callers pre-split long text into ≤72-char chunks.
      ll.check(ll.lib.zf_write_record(this._select(), commentaryCard(up, value)));
      return;
    }
    if (isStructuralKeyword(key)) {
      throw new FitsHeaderError(207, `cannot set structural keyword '${key}' on an open header`);
    }
    const keyS = key.trim();
    if (keyS.includes(" ") || keyS.length > 8) {
      // HIERARCH-convention keyword: the fixed-format ABI cannot express it (>8 chars fails
      // Name.parse; an embedded space would stamp a spec-invalid keyword). Build the cards
      // FIRST so a bad value cannot delete the old card and then fail; the Zig-side delete
      // also removes an old CONTINUE run, so replacement never orphans continuations.
      const cards = hierarchCards(keyS, value, comment ?? "");
      const h = this._select();
      const kb = enc(keyS);
      try {
        ll.check(ll.lib.zf_delete_key(h, kb, kb.length)); // matches HIERARCH names in Zig
      } catch (e) {
        if (!(e instanceof KeywordNotFound)) throw e;
      }
      for (const card of cards) ll.check(ll.lib.zf_write_record(h, card)); // insert-before-END keeps order
      return;
    }
    writeKeyValue(this._select(), key, value, comment);
  }

  /** @internal */
  _deleteKey(key: string): void {
    const h = this._select();
    const kb = enc(key);
    ll.check(ll.lib.zf_delete_key(h, kb, kb.length));
  }

  /**
   * @internal Rewrite every commentary card of `keyword` in the open handle to `texts`: delete all
   * by name, then re-append (before END) as raw records. Used for in-place commentary edits,
   * deletions, and array replace-all, where a single append cannot express the new state. Same
   * delete-then-write-records idiom as the HIERARCH replacement path in `_writeKey`. For the blank
   * keyword this also rewrites blank separator cards (they share the empty name), so an in-place
   * edit/delete of blank commentary reorders every blank card — same as astropy.
   */
  _resyncCommentary(keyword: string, texts: HeaderValue[]): void {
    const h = this._select();
    const kb = enc(keyword);
    for (;;) {
      try {
        ll.check(ll.lib.zf_delete_key(h, kb, kb.length));
      } catch (e) {
        if (e instanceof KeywordNotFound) break;
        throw e;
      }
    }
    const up = keyword.toUpperCase();
    for (const t of texts) ll.check(ll.lib.zf_write_record(h, commentaryCard(up, t)));
  }

  get name(): string {
    if (this._name !== null) return this._name;
    let ext: HeaderValue | undefined = "";
    try {
      ext = this.header.get("EXTNAME", "");
    } catch {
      ext = "";
    }
    if (ext) return String(ext);
    // The primary HDU answers to "PRIMARY" (astropy convention) when it has no EXTNAME.
    return this instanceof PrimaryHDU ? "PRIMARY" : "";
  }

  /**
   * @internal Write the non-structural user header cards into a freshly created
   * HDU. `skip` filters keywords the caller's write path already emitted (table
   * column descriptors, ZIMAGE-convention cards) so they are not duplicated or
   * double-applied; it receives the uppercased keyword.
   */
  _applyUserKeys(handle: bigint, skip?: (up: string) => boolean): void {
    for (const [kw, value, comment] of this.header.cards()) {
      const up = kw.toUpperCase();
      if (isStructuralKeyword(kw)) continue;
      // A scanned header's CHECKSUM/DATASUM describe the ORIGINAL bytes; copying
      // them onto a reconstructed HDU yields a card that no longer verifies. Drop
      // them here (as astropy strips them on modification) — the correct values
      // are regenerated by zf_write_chksum only when writeTo({checksum:true}) is
      // requested. Applies to every _writeTo path (image, table, compressed).
      if (up === "CHECKSUM" || up === "DATASUM") continue;
      if (skip?.(up)) continue;
      // Commentary and HIERARCH/spaced/>8-char keys can't be written as
      // standard 8-char keywords; reconstruct their 80-byte card and write it
      // verbatim so COMMENT/HISTORY provenance and HIERARCH keywords survive
      // the reconstruction (non-pristine) path.
      if (up === "COMMENT" || up === "HISTORY" || up === "") {
        // Wrap so a >72-char commentary card (e.g. built via Header.fromCards) spans multiple
        // records instead of truncating; set-time cards are already ≤72.
        for (const chunk of wrapCommentary(value)) {
          ll.check(ll.lib.zf_write_record(handle, commentaryCard(kw, chunk)));
        }
        continue;
      }
      if (kw.includes(" ") || kw.length > 8) {
        for (const card of hierarchCards(kw, value, comment)) {
          ll.check(ll.lib.zf_write_record(handle, card));
        }
        continue;
      }
      if (value === undefined) continue;
      writeKeyValue(handle, kw, value, comment || null); // null → undefined-value card
    }
    if (this._name) {
      const nb = enc(this._name);
      const kb = enc("EXTNAME");
      ll.check(ll.lib.zf_write_key_str(handle, kb, kb.length, nb, nb.length, null, 0));
    }
  }
}

// ════════════════════════════════════════════════════════════════════════
// Image HDUs
// ════════════════════════════════════════════════════════════════════════

export interface ImageHDUOptions extends HDUOptions {
  data?: FitsArray | dt.TypedArray | null;
}

export class ImageHDU extends BaseHDU {
  // Widened to the whole image subtree so `PrimaryHDU`/`CompImageHDU` can
  // override with a narrower literal (TS override-variance requirement).
  readonly kind: "image" | "primary" | "compimage" = "image";
  override readonly isImage: boolean = true;

  /** @internal */ _data: FitsArray | null | typeof DATA_UNSET = DATA_UNSET;
  /** @internal Baseline for update-mode data write-back + the pristine gate. */
  _dataFingerprint: bigint | null = null;

  constructor(options: ImageHDUOptions = {}) {
    super(options);
    this._data = options.data == null ? DATA_UNSET : asFitsArray(options.data);
  }

  get data(): FitsArray | null {
    const d = this._data;
    if (d !== DATA_UNSET) return d;
    if (this._hdulist === null) return null;
    const arr = this._readImage();
    if (arr === null) return null; // empty (NAXIS=0) HDU: stay unset, a mere read is not a clear
    this._data = arr;
    return arr;
  }

  set data(value: FitsArray | dt.TypedArray | null) {
    this._data = value == null ? null : asFitsArray(value);
    this._markDirty(); // a replaced array is not in the open handle's bytes
  }

  override _dataChanged(): boolean {
    const d = this._data;
    if (d === DATA_UNSET || d === null) return false;
    return fnv1a64(viewBytes(d.data)) !== this._dataFingerprint;
  }

  get shape(): readonly number[] | null {
    const d = this.data;
    return d === null ? null : d.shape;
  }

  /** @internal */
  _imgParam(): { bitpix: number; axes: number[] } {
    const h = this._select();
    const bitpix = ll.outI32();
    const naxis = ll.outI32();
    const axes = ll.newLongArray(999);
    const filled = ll.outI32();
    ll.check(ll.lib.zf_img_param(h, bitpix, naxis, axes, 999, filled));
    const out: number[] = [];
    for (let i = 0; i < filled[0]; i++) out.push(ll.readLongAt(axes, i));
    return { bitpix: bitpix[0], axes: out };
  }

  /** @internal Read dtype from BITPIX + BSCALE/BZERO (unsigned convention, scaled → float). */
  _outputDtype(header: Header, bitpix: number): dt.Dtype {
    const bscale = header.get("BSCALE");
    const bzero = header.get("BZERO");
    const unsignedBzero = dt.UNSIGNED_BZERO[bitpix];
    if (eqNum(bscale, 1, 1) && unsignedBzero !== undefined && eqNum(bzero, 0, unsignedBzero)) {
      return dt.UNSIGNED_DTYPE[bitpix];
    }
    if (!eqNum(bscale, 1, 1) || !eqNum(bzero, 0, 0)) {
      return bitpix === -32 ? "f4" : "f8";
    }
    return dt.bitpixToDtype(bitpix);
  }

  /** @internal */
  _readImage(): FitsArray | null {
    const { bitpix, axes } = this._imgParam();
    if (axes.length === 0) return null;
    const outDtype = this._outputDtype(this.header, bitpix);
    const shape = [...axes].reverse(); // FITS first-axis-fastest -> C-order reversed
    const n = shape.reduce((a, b) => a * b, 1);
    const buf = dt.allocDtype(outDtype, n);
    if (n > 0) {
      const h = this._select();
      ll.check(ll.lib.zf_read_img(h, dt.zfCode(outDtype), 1n, BigInt(n), null, null, buf));
    }
    const arr = new FitsArray(buf, shape);
    // Baseline in ALL modes so both update-mode write-back and the pristine
    // gate can detect a later edit — including an in-place mutation that
    // never goes through the data setter and so never sets `_dirty`.
    this._dataFingerprint = fnv1a64(viewBytes(buf));
    return arr;
  }

  /**
   * Read a rectangular sub-region (a "cutout") without materializing the whole
   * image — a strided read over the C ABI (`fits_read_subset`-style), the
   * geotiff.js `readRasters({ window })` shape.
   *
   * `window` is one `[start, stop)` pair per axis in **C order** (`[NAXIS2,
   * NAXIS1]` for a 2-D image — same axis order as `.shape`/`.data`): 0-based and
   * half-open, but (unlike `Array.slice`) negative indices are rejected, bounds
   * are not clamped, and an empty window (`start >= stop`) throws. `step` is an
   * optional per-axis stride (default 1). Scaling/unsigned/NaN handling matches
   * a full `.data` read.
   *
   * In update mode, pending in-place `.data` edits are flushed to the file
   * first, so a section is always consistent with `.data` — a pending clear
   * (`data = null`) cannot be flushed, so it throws like a pending geometry
   * change. In read-only mode the file is read as it was opened — unflushed
   * in-memory edits (including a clear) are not visible. Only valid on an
   * image HDU opened from a file/bytes.
   */
  section(options: { window: readonly (readonly [number, number])[]; step?: readonly number[] }): FitsArray {
    if (this._hdulist === null) {
      throw new FitsIOError(104, "section() requires an image HDU opened from a file or bytes");
    }
    if (this.kind === "compimage") {
      // The strided subset path reads a plain image data unit; a tile-
      // compressed image stores a BINTABLE, so there is no subset to read.
      throw new NotSupportedError(
        410,
        "section() is not supported on a tile-compressed image; read the whole array with .data",
      );
    }
    // section() reads the file bytes; persist any pending in-place edit first
    // (mirrors HDUList._sourceBytes) so it never returns data staler than .data.
    // A pending clear cannot be flushed — reading the stale pixels would break
    // the consistency promise, so fail like a pending geometry change does.
    if (this._writable()) {
      if (this._data === null) {
        throw new NotSupportedError(
          410,
          "cannot read a section of a cleared image (data = null is pending); restore .data or use writeTo() to a new file",
        );
      }
      if (this._dataChanged()) this._flushData();
    }
    const { bitpix, axes } = this._imgParam(); // axes: FITS order (fastest first)
    const ndim = axes.length;
    if (ndim === 0) throw new FitsIOError(104, "cannot read a section of a data-less image");
    const cShapeFull = [...axes].reverse(); // C-order axis lengths
    const window = options.window;
    const step = options.step ?? new Array(ndim).fill(1);
    if (window.length !== ndim) {
      throw new RangeError(`window has ${window.length} axes; image has ${ndim}`);
    }
    if (step.length !== ndim) {
      throw new RangeError(`step has ${step.length} axes; image has ${ndim}`);
    }

    // Per C-order axis: validate, then compute output length and the FITS
    // 1-based-inclusive lower/upper/inc for that axis.
    const outShape: number[] = []; // C order
    const lowerC: number[] = [];
    const upperC: number[] = [];
    const incC: number[] = [];
    for (let d = 0; d < ndim; d++) {
      const [start, stop] = window[d];
      const s = step[d];
      const len = cShapeFull[d];
      if (!Number.isInteger(start) || !Number.isInteger(stop) || start < 0 || stop > len || start >= stop) {
        throw new RangeError(`window[${d}] = [${start}, ${stop}) out of bounds for axis length ${len}`);
      }
      if (!Number.isInteger(s) || s < 1) throw new RangeError(`step[${d}] = ${s} must be a positive integer`);
      const nOut = Math.ceil((stop - start) / s);
      const last0 = start + (nOut - 1) * s; // last index actually read
      outShape.push(nOut);
      // zf_read_subset uses 0-based, inclusive lower/upper bounds.
      lowerC.push(start);
      upperC.push(last0);
      incC.push(s);
    }

    const outDtype = this._outputDtype(this.header, bitpix);
    const nelem = outShape.reduce((a, b) => a * b, 1);
    const buf = dt.allocDtype(outDtype, nelem);
    // The ABI wants fastest-axis-first (FITS) order: reverse the C-order arrays.
    const lower = ll.longArray([...lowerC].reverse());
    const upper = ll.longArray([...upperC].reverse());
    const inc = ll.longArray([...incC].reverse());
    const h = this._select();
    ll.check(
      ll.lib.zf_read_subset(h, dt.zfCode(outDtype), ndim, lower, upper, inc, BigInt(nelem), null, null, buf),
    );
    // The returned flat buffer is fastest-first == C-order for `outShape`
    // (the standard FITS↔numpy reinterpretation; no transpose needed).
    return new FitsArray(buf, outShape);
  }

  // ── WCS celestial transforms (1-based pixel coords, FITS CRPIX convention) ──
  pix2world(x: number, y: number, alt = " "): [number, number] {
    const h = this._select();
    const lon = ll.outF64();
    const lat = ll.outF64();
    const altCode = alt.trim() ? alt.charCodeAt(0) : 0;
    ll.check(ll.lib.zf_wcs_pix2world(h, altCode, x, y, lon, lat));
    return [lon[0], lat[0]];
  }

  world2pix(lon: number, lat: number, alt = " "): [number, number] {
    const h = this._select();
    const px = ll.outF64();
    const py = ll.outF64();
    const altCode = alt.trim() ? alt.charCodeAt(0) : 0;
    ll.check(ll.lib.zf_wcs_world2pix(h, altCode, lon, lat, px, py));
    return [px[0], py[0]];
  }

  // ── writing ──
  /** @internal */
  _writeTo(handle: bigint, _primary: boolean): void {
    // Materialize the header BEFORE creating the destination HDU: a lazy header
    // read _select()s the source HDU, and when an attached HDU is serialized to
    // its OWN handle that would snap the current HDU back to the source
    // mid-write, landing the user keys in the source's header instead.
    void this.header;
    const data = this.data; // lazily materialize attached pixels so a copied HDU keeps its data
    if (data === null) {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      this._applyUserKeys(handle);
      return;
    }
    const dtype = data.dtype;
    const axes = [...data.shape].reverse(); // C-order shape -> FITS axes
    const plan = dt.unsignedImgPlan(dtype);
    if (plan !== null) {
      // Unsigned image via the BZERO convention: write the unsigned values
      // directly; the library applies the header BZERO to store them as
      // signed ints (integer-space, exact for all widths incl. uint64).
      ll.check(ll.lib.zf_create_img(handle, plan.bitpix, axes.length, ll.longArray(axes)));
      this._applyUserKeys(handle);
      writeConventionOffset(handle, "BZERO", plan.bzero);
      if (data.size > 0) {
        ll.check(ll.lib.zf_write_img(handle, dt.zfCode(dtype), 1n, BigInt(data.size), null, null, data.data));
      }
      return;
    }
    const bitpix = dt.dtypeToBitpix(dtype);
    ll.check(ll.lib.zf_create_img(handle, bitpix, axes.length, ll.longArray(axes)));
    this._applyUserKeys(handle);
    if (data.size > 0) {
      ll.check(ll.lib.zf_write_img(handle, dt.zfCode(dtype), 1n, BigInt(data.size), null, null, data.data));
    }
  }

  /**
   * @internal Update-mode write-back: if this attached image's materialized
   * data changed, rewrite the data unit in place (same geometry only). Uses
   * the HDU's own BSCALE/BZERO so scaled/unsigned images round-trip through
   * the library's inverse scaling.
   */
  override _flushData(): void {
    const data = this._data;
    if (data === DATA_UNSET) return;
    if (data === null) {
      const { axes } = this._imgParam();
      if (axes.length === 0) return; // already empty on disk; nothing to clear
      throw new NotSupportedError(
        410,
        "clearing image data cannot be written back to the open file in update mode; restore .data or save with writeTo() to a new file",
      );
    }
    const fp = fnv1a64(viewBytes(data.data));
    if (fp === this._dataFingerprint) return;
    const h = this._select();
    const { axes } = this._imgParam();
    const expected = [...axes].reverse();
    if (data.shape.length !== expected.length || data.shape.some((s, i) => s !== expected[i])) {
      throw new NotSupportedError(410, "changing image geometry in update mode is not supported; use writeTo() instead");
    }
    if (data.size > 0) {
      const bscale = headerNum(this.header.get("BSCALE"), 1);
      const bzero = headerNum(this.header.get("BZERO"), 0);
      const scaling = bscale !== 1 || bzero !== 0 ? ll.encodeScaling({ bscale, bzero }) : null;
      ll.check(ll.lib.zf_write_img(h, dt.zfCode(data.dtype), 1n, BigInt(data.size), null, scaling, data.data));
    }
    this._dataFingerprint = fp;
  }
}

export class PrimaryHDU extends ImageHDU {
  override readonly kind = "primary" as const;
}

// ════════════════════════════════════════════════════════════════════════
// Tile-compressed images
// ════════════════════════════════════════════════════════════════════════

export interface CompImageHDUOptions extends ImageHDUOptions {
  /** Codec: "RICE_1" (default), "GZIP_1", "PLIO_1", "HCOMPRESS_1". */
  compression?: string;
  /** Tile shape, fastest-axis-first (ZTILEn order). Default: library tiling. */
  tile?: readonly number[];
  /** Quantization method for float data: "NO_DITHER", "SUBTRACTIVE_DITHER_1", "SUBTRACTIVE_DITHER_2". */
  quantize?: string;
  /**
   * CFITSIO quantization level (fits_set_quantize_level / fpack -q semantics)
   * for float data with a quantizing method: > 0 sets the per-tile step to
   * sigma/level, 0 the CFITSIO default (sigma/4), < 0 the absolute step
   * |level|. Undefined leaves the library default.
   */
  quantizeLevel?: number;
  /**
   * HCOMPRESS_1 lossy scale (fits_set_hcomp_scale semantics): 0 = lossless,
   * > 0 = noise-adaptive (per-tile round(scale × background sigma)),
   * < 0 = |scale| absolute.
   */
  hcompScale?: number;
  /** Records the ZNAME='SMOOTH' decode-side smoothing request. */
  hcompSmooth?: boolean;
}

export class CompImageHDU extends ImageHDU {
  override readonly kind = "compimage" as const;
  /** @internal */ _comp: string;
  /** @internal */ _tile: readonly number[] | null;
  /** @internal */ _quantize: string | null;
  /** @internal */ _quantizeLevel: number | null;
  /** @internal */ _hcompScale: number;
  /** @internal */ _hcompSmooth: boolean;

  constructor(options: CompImageHDUOptions = {}) {
    super(options);
    this._comp = options.compression ?? "RICE_1";
    this._tile = options.tile ?? null;
    this._quantize = options.quantize ?? null;
    this._quantizeLevel = options.quantizeLevel === undefined ? null : options.quantizeLevel;
    this._hcompScale = options.hcompScale ?? 0;
    this._hcompSmooth = options.hcompSmooth ?? false;
  }

  /** @internal */
  override _writeTo(handle: bigint, _primary: boolean): void {
    const data = this.data; // lazily materializes attached data (so a copy keeps its pixels)
    if (data === null) throw new FitsTypeError(410, "CompImageHDU requires data to write");
    const dtype = data.dtype;
    const bitpix = dt.dtypeToBitpix(dtype);
    const axes = [...data.shape].reverse();
    let comp = this._comp;
    let tileSpec: readonly number[] | null = this._tile;
    let quant: string | null = this._quantize;
    let hscale = this._hcompScale;
    let hsmooth = this._hcompSmooth;
    if (this._hdulist !== null) {
      // A scanned compressed image: reuse its own ZCMPTYPE/ZTILEn/ZQUANTIZ so
      // re-emitting does not silently change the codec (or fail outright for
      // a float image GZIP-stored without quantization) by recompressing with
      // the constructor's RICE_1 default.
      const hdr = this.header;
      comp = String(hdr.get("ZCMPTYPE", comp));
      const zq = hdr.get("ZQUANTIZ");
      // An empty scanned ZQUANTIZ means "no quantization" (Python's falsy
      // check passes NULL), never an empty C string.
      if (zq !== undefined && zq !== null) quant = String(zq) || null;
      const tiles: number[] = [];
      for (let i = 1; ; i++) {
        const zt = hdr.get(`ZTILE${i}`);
        if (zt === undefined || zt === null) break;
        tiles.push(Number(zt));
      }
      if (tiles.length > 0) tileSpec = tiles; // ZTILEn and axes are both fastest-axis-first
      // Likewise reuse the recorded HCOMPRESS lossy request (ZNAMEn =
      // 'SCALE'/'SMOOTH'): re-emitting a lossy file must not silently
      // recompress it as lossless (or drop the readers' smoothing request).
      if (comp.trim().toUpperCase() === "HCOMPRESS_1") {
        for (let i = 1; ; i++) {
          const zname = hdr.get(`ZNAME${i}`);
          if (zname === undefined || zname === null) break;
          const zval = hdr.get(`ZVAL${i}`);
          const nm = String(zname).trim().toUpperCase();
          const v = zval === undefined || zval === null ? NaN : Number(zval);
          // A nonstandard (e.g. string-valued) ZVALn falls back to the defaults.
          if (Number.isFinite(v)) {
            if (nm === "SCALE") hscale = v;
            else if (nm === "SMOOTH") hsmooth = Math.trunc(v) !== 0;
          }
        }
      }
    }
    const tile = tileSpec && tileSpec.length > 0 ? ll.longArray([...tileSpec]) : null;
    const qlevel = this._quantizeLevel;
    ll.check(
      ll.lib.zf_write_compressed3(
        handle,
        dt.zfCode(dtype),
        bitpix,
        axes.length,
        ll.longArray(axes),
        tile,
        comp,
        quant || null,
        1n,
        qlevel === null ? 0 : qlevel,
        qlevel === null ? 0 : 1,
        hscale,
        hsmooth ? 1 : 0,
        data.data,
        BigInt(data.size),
      ),
    );
    // Re-emit the user header cards (EXTNAME, provenance COMMENT/HISTORY, and
    // any science keywords), skipping the compression machinery and binary-table
    // structurals that zf_write_compressed3 already wrote — mirroring the plain
    // image path so a reconstruction save does not silently drop metadata.
    this._applyUserKeys(handle, isCompStructuralKeyword);
  }
}
