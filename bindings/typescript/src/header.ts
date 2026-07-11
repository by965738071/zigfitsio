/**
 * A Map-like, ordered FITS `Header`, modeled on `astropy.io.fits.Header`
 * (direct port of the Python `header.py`).
 *
 * The header is parsed from raw 80-byte cards (read through the C ABI) into
 * an ordered list of records. Edits update the in-memory list and, when the
 * header is attached to a writable open file, are persisted immediately
 * through an injected `_persist` callback (persist-first: a rejected edit
 * must not leave a bogus card that would poison later reads).
 *
 * Integer values parse to `number` when exactly representable as a double,
 * else `bigint` — so `BZERO = 9223372036854775808` (2^63, exact as a double)
 * stays a `number` and the unsigned-convention detection ports 1:1, while
 * larger-than-2^53 odd values stay exact as `bigint`.
 */
import { FitsTypeError, KeywordNotFound } from "./errors.js";

export type HeaderValue = string | number | bigint | boolean | null;

export interface CardRec {
  keyword: string;
  value: HeaderValue;
  comment: string;
  commentary: boolean;
}

const card = (keyword: string, value: HeaderValue, comment = "", commentary = false): CardRec => ({
  keyword,
  value,
  comment,
  commentary,
});

const COMMENTARY_KEYWORDS = new Set(["COMMENT", "HISTORY", ""]);
const isCommentaryKey = (key: string): boolean => COMMENTARY_KEYWORDS.has(key.toUpperCase());

/**
 * Split commentary text into physical-card chunks of ≤72 chars (a COMMENT/HISTORY/blank card holds
 * free text in columns 9-80). Empty text yields one blank card, matching astropy — which splits
 * long commentary into multiple cards at assignment time rather than truncating.
 */
export function wrapCommentary(value: HeaderValue): string[] {
  const text = value === null || value === undefined ? "" : String(value);
  if (text.length === 0) return [""];
  const out: string[] = [];
  for (let i = 0; i < text.length; i += 72) out.push(text.slice(i, i + 72));
  return out;
}

/**
 * A mutable, list-like view over one keyword's COMMENT/HISTORY/blank cards — the TS analogue of the
 * object astropy returns from `header['COMMENT']`. `setAt`/`removeAt`/`append` mutate the owning
 * `Header` and persist to an attached writable file.
 */
export interface CommentaryView extends Iterable<HeaderValue> {
  readonly length: number;
  at(index: number): HeaderValue | undefined;
  toArray(): HeaderValue[];
  setAt(index: number, text: HeaderValue): void;
  removeAt(index: number): void;
  append(text: HeaderValue): void;
}

const INT_TOKEN = /^[+-]?\d+$/;

function parseNumberToken(token: string): HeaderValue | undefined {
  if (INT_TOKEN.test(token)) {
    const big = BigInt(token);
    const num = Number(big);
    return BigInt(num) === big ? num : big;
  }
  // float (accept FORTRAN 'D' exponent)
  const norm = token.replace(/[dD]/g, "E");
  if (norm.length > 0 && /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(norm)) {
    const f = Number(norm);
    if (Number.isFinite(f)) return f;
  }
  return undefined;
}

/** Parse a card value field (card columns 11-80) into [value, comment]. */
export function parseValueComment(field: string): [HeaderValue, string] {
  const s = field;
  let i = 0;
  while (i < s.length && s[i] === " ") i++;
  if (i >= s.length) return [null, ""]; // undefined
  if (s[i] === "/") return [null, s.slice(i + 1).trim()];
  if (s[i] === "'") {
    // String value: consume to the closing quote, honoring '' escapes.
    i++;
    let out = "";
    while (i < s.length) {
      const ch = s[i];
      if (ch === "'") {
        if (i + 1 < s.length && s[i + 1] === "'") {
          out += "'";
          i += 2;
          continue;
        }
        i++;
        break;
      }
      out += ch;
      i++;
    }
    const rest = s.slice(i);
    const slash = rest.indexOf("/");
    const comment = slash >= 0 ? rest.slice(slash + 1).trim() : "";
    return [out.replace(/ +$/, ""), comment];
  }
  // Non-string: token up to an unquoted '/'.
  const slash = s.indexOf("/");
  const token = (slash < 0 ? s : s.slice(0, slash)).trim();
  const comment = slash < 0 ? "" : s.slice(slash + 1).trim();
  if (token === "T") return [true, comment];
  if (token === "F") return [false, comment];
  const num = parseNumberToken(token);
  return [num === undefined ? token : num, comment];
}

const asciiDecoder = new TextDecoder("ascii");

function cardText(raw: Uint8Array | string): string {
  return typeof raw === "string" ? raw : asciiDecoder.decode(raw);
}

/**
 * Locate a quoted string in a value field WITHOUT unescaping `''` pairs (port of the Python
 * `_extract_raw_string`).
 *
 * Returns the substring between the opening and true closing quote with escapes left intact.
 * The closing quote is the first `'` that is not part of a `''` pair and is followed only by
 * spaces then end-of-field or a `/` comment; a lone `'` followed by anything else is content
 * (astropy splits `''` escape pairs across CONTINUE cards, leaving a lone `'&` at a card
 * boundary). `raw` is null when the field does not hold a string value.
 */
function extractRawString(field: string): { raw: string | null; comment: string; isString: boolean } {
  const s = field;
  let i = 0;
  while (i < s.length && s[i] === " ") i++;
  if (i >= s.length || s[i] !== "'") return { raw: null, comment: "", isString: false };
  i++;
  const start = i;
  while (i < s.length) {
    if (s[i] === "'") {
      if (i + 1 < s.length && s[i + 1] === "'") {
        i += 2; // escaped quote → content
        continue;
      }
      const stripped = s.slice(i + 1).replace(/^ +/, "");
      if (stripped === "" || stripped[0] === "/") {
        const comment = stripped[0] === "/" ? stripped.slice(1).trim() : "";
        return { raw: s.slice(start, i), comment, isString: true };
      }
      i++; // lone quote, not a terminator → content
    } else {
      i++;
    }
  }
  return { raw: s.slice(start), comment: "", isString: true }; // unterminated (defensive)
}

/**
 * Raw value field (escapes intact) for a card, or null when it has no value field (port of the
 * Python `_value_field`). Mirrors `parseCard`'s value-field selection: a standard `KEY = `
 * card's value starts at column 10; a HIERARCH card's value starts after the first `=`.
 */
function rawValueField(text: string): string | null {
  if (text.slice(8, 10) === "= ") return text.slice(10);
  if (text.slice(0, 8).trimEnd() === "HIERARCH") {
    const rest = text.slice(8);
    const eq = rest.indexOf("=");
    if (eq >= 0) return rest.slice(eq + 1);
  }
  return null;
}

/** Parse one 80-byte card; return null for END. */
export function parseCard(raw: Uint8Array | string): CardRec | null {
  const text = cardText(raw);
  const name = text.slice(0, 8).trimEnd();
  if (name === "END") return null;
  if (name === "COMMENT" || name === "HISTORY" || text.slice(0, 8) === "        ") {
    return card(name, text.slice(8).trimEnd(), "", true);
  }
  if (text.slice(8, 10) === "= ") {
    const [value, comment] = parseValueComment(text.slice(10));
    return card(name, value, comment);
  }
  if (name === "HIERARCH") {
    // `HIERARCH keyword tokens = value / comment`; the spaced token string is the keyword.
    const rest = text.slice(8);
    const eq = rest.indexOf("=");
    if (eq >= 0) {
      const keyword = rest.slice(0, eq).trim();
      if (keyword) {
        const [value, comment] = parseValueComment(rest.slice(eq + 1));
        return card(keyword, value, comment);
      }
    }
  }
  // other: keep the raw remainder as a commentary-style record.
  return card(name, text.slice(8).trimEnd(), "", true);
}

/**
 * Parse a sequence of physical 80-byte cards, folding CONTINUE long-string
 * continuations (port of the fixed Python `parse_cards`).
 *
 * Continuation is folded on the RAW escaped text before unescaping: astropy
 * splits the escaped representation and can cut a `''` escape pair across a
 * card boundary, so unescaping each card independently would misread the
 * split `'` as a closing quote and truncate. The raw fragments (each `&`
 * continuation sentinel dropped) are concatenated and `''`→`'` unescaped
 * exactly once, with the comment taken from the last fragment. A lone
 * `&`-terminated value with no following CONTINUE keeps the `&` literally.
 * Both standard `KEY = ` cards and HIERARCH long strings are folded (their
 * value field is located by `rawValueField`).
 */
export function parseCards(raws: readonly (Uint8Array | string)[]): CardRec[] {
  const cards: CardRec[] = [];
  let i = 0;
  const n = raws.length;
  const isContinue = (raw: Uint8Array | string): boolean => cardText(raw).slice(0, 8).trimEnd() === "CONTINUE";
  while (i < n) {
    const base = i;
    const c = parseCard(raws[i]);
    i++;
    if (c === null) continue; // END
    const field = !c.commentary && typeof c.value === "string" ? rawValueField(cardText(raws[base])) : null;
    if (field !== null) {
      const { raw, comment: baseComment, isString } = extractRawString(field);
      if (isString && raw !== null && raw.endsWith("&") && i < n && isContinue(raws[i])) {
        const parts = [raw.slice(0, -1)];
        let comment = baseComment;
        while (i < n && isContinue(raws[i])) {
          const cont = extractRawString(cardText(raws[i]).slice(8));
          i++;
          if (cont.comment) comment = cont.comment;
          const frag = cont.raw ?? "";
          if (frag.endsWith("&")) {
            parts.push(frag.slice(0, -1));
          } else {
            parts.push(frag);
            break;
          }
        }
        c.value = parts.join("").replace(/''/g, "'").replace(/ +$/, "");
        c.comment = comment;
      }
    }
    cards.push(c);
  }
  return cards;
}

/** An ordered, case-insensitive collection of FITS keyword records. */
export class Header implements Iterable<[string, HeaderValue]> {
  private _cards: CardRec[] = [];
  /** @internal Persist-first write hook (attached writable headers). */
  _persist: ((key: string, value: HeaderValue, comment: string | null) => void) | null = null;
  /** @internal Persist-first delete hook. */
  _delete: ((key: string) => void) | null = null;
  /**
   * @internal Rewrite-all hook for commentary edits/deletes/replace-all on an attached writable
   * handle (delete-all-by-name then re-append). Null on read-only/detached headers.
   */
  _resync: ((keyword: string, texts: HeaderValue[]) => void) | null = null;
  /**
   * @internal Called after an edit that is NOT persisted to an open handle
   * (read-only mode), so the owning HDUList can flag itself dirty and
   * reconstruct rather than copy stale bytes on save.
   */
  _dirtyCb: (() => void) | null = null;

  /** @internal */
  static fromCards(cards: CardRec[]): Header {
    const h = new Header();
    h._cards = cards;
    return h;
  }

  private _find(key: string): number {
    const ku = key.toUpperCase();
    for (let i = 0; i < this._cards.length; i++) {
      const c = this._cards[i];
      if (!c.commentary && c.keyword.toUpperCase() === ku) return i;
    }
    return -1;
  }

  has(key: string): boolean {
    if (isCommentaryKey(key)) {
      const ku = key.toUpperCase();
      return this._cards.some((c) => c.commentary && c.keyword.toUpperCase() === ku);
    }
    return this._find(key) >= 0;
  }

  get(key: string): HeaderValue | undefined;
  get(key: string, dflt: HeaderValue): HeaderValue;
  get(key: string, dflt?: HeaderValue): HeaderValue | undefined {
    const i = this._find(key);
    return i >= 0 ? this._cards[i].value : dflt;
  }

  /** Like `get`, but throws `KeywordNotFound` when the keyword is absent. */
  value(key: string): HeaderValue {
    const i = this._find(key);
    if (i < 0) throw new KeywordNotFound(202, `keyword ${key} not found in header`);
    return this._cards[i].value;
  }

  set(key: string, value: HeaderValue | readonly HeaderValue[], comment?: string): void {
    // Commentary keywords accumulate (append), never overwrite; a passed array replaces all of
    // them. Handled first — the (key, value, comment) valued path does not apply to commentary.
    if (isCommentaryKey(key)) {
      this._setCommentary(key.toUpperCase(), value);
      return;
    }
    if (Array.isArray(value)) {
      // An array is a commentary replace-all; for a valued keyword it would stamp a malformed card.
      throw new FitsTypeError(410, `array values are only valid for commentary keywords, not '${key}'`);
    }
    const v = value as HeaderValue;
    const i = this._find(key);
    const resolvedComment = comment !== undefined ? comment : i >= 0 ? this._cards[i].comment : "";
    // Persist FIRST: a rejected edit (a structural keyword, or a read-only
    // device) must not leave a bogus card in the in-memory header.
    if (this._persist !== null) this._persist(key, v, resolvedComment);
    if (i >= 0) {
      this._cards[i].value = v;
      if (comment !== undefined) this._cards[i].comment = comment;
    } else {
      this._cards.push(card(key.toUpperCase(), v, comment ?? ""));
    }
    if (this._persist === null && this._dirtyCb !== null) {
      this._dirtyCb(); // read-only edit → not in the handle's bytes; reconstruct on save
    }
  }

  delete(key: string): void {
    // Deleting a commentary keyword removes ALL of its cards (astropy semantics).
    if (isCommentaryKey(key)) {
      const ku = key.toUpperCase();
      const idxs = this._commentaryIndices(ku);
      if (idxs.length === 0) throw new KeywordNotFound(202, `keyword ${key} not found in header`);
      for (let j = idxs.length - 1; j >= 0; j--) this._cards.splice(idxs[j], 1);
      this._resyncKeyword(ku); // empty texts → delete-all in the handle (or mark dirty)
      return;
    }
    const i = this._find(key);
    if (i < 0) throw new KeywordNotFound(202, `keyword ${key} not found in header`);
    if (this._delete !== null) this._delete(key); // persist first; on failure the in-memory card is retained
    this._cards.splice(i, 1);
    if (this._delete === null && this._dirtyCb !== null) this._dirtyCb();
  }

  /** Append a COMMENT card (astropy-compatible). Long text spans multiple cards. */
  addComment(value: HeaderValue): void {
    this._setCommentary("COMMENT", value);
  }

  /** Append a HISTORY card (astropy-compatible). Long text spans multiple cards. */
  addHistory(value: HeaderValue): void {
    this._setCommentary("HISTORY", value);
  }

  /**
   * A mutable, list-like view over the COMMENT/HISTORY/blank cards of `keyword` (astropy's
   * `header['COMMENT']`). Absent keyword → an empty view. Mutations persist to an attached file.
   *
   * `append` is O(1); a single `setAt`/`removeAt` rewrites all k cards of the keyword to persist,
   * so replacing many at once via `set(keyword, [...])` is cheaper than a loop of per-index edits.
   */
  commentary(keyword: string): CommentaryView {
    const kw = keyword.toUpperCase();
    const self = this; // read self._cards fresh each call (a replace-all mutates it in place)
    const indices = (): number[] => self._commentaryIndices(kw);
    const resolve = (index: number, len: number): number => {
      const p = index < 0 ? index + len : index;
      if (p < 0 || p >= len) throw new RangeError(`commentary index ${index} out of range`);
      return p;
    };
    return {
      get length(): number {
        return indices().length;
      },
      at(index: number): HeaderValue | undefined {
        const idx = indices();
        const p = index < 0 ? index + idx.length : index;
        return p >= 0 && p < idx.length ? self._cards[idx[p]].value : undefined;
      },
      toArray(): HeaderValue[] {
        return indices().map((i) => self._cards[i].value);
      },
      setAt(index: number, text: HeaderValue): void {
        const idx = indices();
        const pos = idx[resolve(index, idx.length)];
        const chunks = wrapCommentary(text);
        self._cards[pos].value = chunks[0];
        for (let off = 1; off < chunks.length; off++) {
          // over-long text spills into new cards after this one
          self._cards.splice(pos + off, 0, card(kw, chunks[off], "", true));
        }
        self._resyncKeyword(kw);
      },
      removeAt(index: number): void {
        const idx = indices();
        self._cards.splice(idx[resolve(index, idx.length)], 1);
        self._resyncKeyword(kw);
      },
      append(text: HeaderValue): void {
        self._setCommentary(kw, text);
      },
      [Symbol.iterator](): Iterator<HeaderValue> {
        return indices()
          .map((i) => self._cards[i].value)
          [Symbol.iterator]();
      },
    };
  }

  /** @internal Ordered indices of the commentary cards for `keyword` (already uppercased). */
  private _commentaryIndices(keyword: string): number[] {
    const out: number[] = [];
    for (let i = 0; i < this._cards.length; i++) {
      const c = this._cards[i];
      if (c.commentary && c.keyword.toUpperCase() === keyword) out.push(i);
    }
    return out;
  }

  /**
   * @internal Append (scalar) or replace-all (array) commentary cards for `keyword`. Each logical
   * entry is split into ≤72-char physical cards. Appending persists eagerly one card at a time
   * (O(1) per card); replace-all rewrites every card of the keyword through `_resync`.
   */
  private _setCommentary(keyword: string, value: HeaderValue | readonly HeaderValue[]): void {
    if (Array.isArray(value)) {
      // Drop existing cards of this keyword in place (don't rebind _cards; a live view holds it).
      for (let i = this._cards.length - 1; i >= 0; i--) {
        const c = this._cards[i];
        if (c.commentary && c.keyword.toUpperCase() === keyword) this._cards.splice(i, 1);
      }
      for (const item of value as readonly HeaderValue[]) {
        for (const chunk of wrapCommentary(item)) this._cards.push(card(keyword, chunk, "", true));
      }
      this._resyncKeyword(keyword);
      return;
    }
    for (const chunk of wrapCommentary(value as HeaderValue)) {
      // Persist FIRST so a rejected write leaves no bogus in-memory card (mirrors valued keys).
      if (this._persist !== null) this._persist(keyword, chunk, null);
      this._cards.push(card(keyword, chunk, "", true));
    }
    if (this._persist === null && this._dirtyCb !== null) this._dirtyCb();
  }

  /**
   * @internal Push the current in-memory commentary cards of `keyword` to an attached writable
   * handle (rewrite-all), or flag the list dirty so a read-only edit reconstructs on save.
   */
  private _resyncKeyword(keyword: string): void {
    if (this._resync !== null) {
      const texts = this._cards.filter((c) => c.commentary && c.keyword.toUpperCase() === keyword).map((c) => c.value);
      this._resync(keyword, texts);
    } else if (this._dirtyCb !== null) {
      this._dirtyCb();
    }
  }

  /**
   * Iterating a `Header` yields `[keyword, value]` entries, like a JS `Map`.
   * Commentary cards (COMMENT/HISTORY/blank) are excluded; use
   * `.comments`/`.history` for those, and `.keys()` for the keyword strings.
   *
   * A parsed header may contain the same keyword on more than one card;
   * iteration yields every such card, while `get()` returns the first and
   * `size` counts them all.
   */
  *[Symbol.iterator](): Iterator<[string, HeaderValue]> {
    for (const c of this._cards) if (!c.commentary) yield [c.keyword, c.value];
  }

  get length(): number {
    let n = 0;
    for (const c of this._cards) if (!c.commentary) n++;
    return n;
  }

  /** Alias of `length`, matching JS `Map.size`. */
  get size(): number {
    return this.length;
  }

  keys(): string[] {
    const out: string[] = [];
    for (const c of this._cards) if (!c.commentary) out.push(c.keyword);
    return out;
  }

  /** Call `cb` for each keyword/value entry, in order (like `Map.forEach`). */
  forEach(cb: (value: HeaderValue, key: string, header: Header) => void, thisArg?: unknown): void {
    for (const c of this._cards) if (!c.commentary) cb.call(thisArg, c.value, c.keyword, this);
  }

  entries(): [string, HeaderValue][] {
    return this._cards.filter((c) => !c.commentary).map((c) => [c.keyword, c.value]);
  }

  values(): HeaderValue[] {
    return this._cards.filter((c) => !c.commentary).map((c) => c.value);
  }

  commentOf(key: string): string {
    const i = this._find(key);
    return i >= 0 ? this._cards[i].comment : "";
  }

  /** Every record as (keyword, value, comment) — commentary included. */
  cards(): [string, HeaderValue, string][] {
    return this._cards.map((c) => [c.keyword, c.value, c.comment]);
  }

  /** COMMENT card text (in order). */
  get comments(): string[] {
    return this._cards.filter((c) => c.commentary && c.keyword === "COMMENT").map((c) => String(c.value ?? ""));
  }

  /** HISTORY card text (in order). */
  get history(): string[] {
    return this._cards.filter((c) => c.commentary && c.keyword === "HISTORY").map((c) => String(c.value ?? ""));
  }

  toString(): string {
    const rows: string[] = [];
    for (const c of this._cards) {
      if (c.commentary) {
        rows.push(`${c.keyword.padEnd(8)}${c.value ?? ""}`);
      } else {
        const v = typeof c.value === "string" ? `'${c.value}'` : String(c.value);
        const tail = c.comment ? ` / ${c.comment}` : "";
        rows.push(`${c.keyword.padEnd(8)}= ${v}${tail}`);
      }
    }
    return rows.join("\n");
  }
}
