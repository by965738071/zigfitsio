"""A dict-like, ordered FITS :class:`Header`, modeled on ``astropy.io.fits.Header``.

The header is parsed from raw 80-byte cards (read through the C ABI) into an ordered list of
records. Edits update the in-memory list and, when the header is attached to a writable open
file, are persisted immediately through an injected ``_persist`` callback.
"""

from __future__ import annotations

import math
import re
from typing import Any, Callable, Iterator, Optional

_COMMENTARY = ("COMMENT", "HISTORY", "")

# FITS 4.0 §4.2.4 real grammar (with the FORTRAN D exponent). Bare ``float()`` also accepts
# ``nan``/``inf``/``infinity`` and ``1_000.5``, none of which are valid FITS reals — such tokens
# must fall through as strings, matching the TypeScript parser and the strict Zig-core reader.
_FITS_REAL = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[EDed][+-]?\d+)?\Z")


class _Card:
    __slots__ = ("keyword", "value", "comment", "commentary")

    def __init__(self, keyword: str, value: Any, comment: str = "", commentary: bool = False):
        self.keyword = keyword
        self.value = value
        self.comment = comment
        self.commentary = commentary


def _parse_value_comment(field: str):
    """Parse a card value field (card columns 11-80) into (value, comment)."""
    s = field
    i = 0
    while i < len(s) and s[i] == " ":
        i += 1
    if i >= len(s):
        return None, ""  # undefined
    if s[i] == "/":
        return None, s[i + 1 :].strip()
    if s[i] == "'":
        # String value: consume to the closing quote, honoring '' escapes.
        i += 1
        out = []
        while i < len(s):
            ch = s[i]
            if ch == "'":
                if i + 1 < len(s) and s[i + 1] == "'":
                    out.append("'")
                    i += 2
                    continue
                i += 1
                break
            out.append(ch)
            i += 1
        rest = s[i:]
        comment = ""
        slash = rest.find("/")
        if slash >= 0:
            comment = rest[slash + 1 :].strip()
        return "".join(out).rstrip(), comment
    # Non-string: token up to an unquoted '/'.
    slash = s.find("/")
    token = (s if slash < 0 else s[:slash]).strip()
    comment = "" if slash < 0 else s[slash + 1 :].strip()
    if token == "T":
        return True, comment
    if token == "F":
        return False, comment
    # int, then float (accept FORTRAN 'D' exponent).
    try:
        return int(token), comment
    except ValueError:
        pass
    if _FITS_REAL.match(token):
        f = float(token.replace("D", "E").replace("d", "e"))
        if math.isfinite(f):  # a finite FITS real cannot overflow to ±inf (e.g. '1E999')
            return f, comment
    return token, comment


def _extract_raw_string(field: str):
    """Locate a quoted string in a value field without unescaping ``''`` pairs.

    Returns ``(raw_escaped, comment, is_string)`` where ``raw_escaped`` is the substring between
    the opening and closing quotes with escapes left intact. The closing quote is the first ``'``
    that is not part of a ``''`` pair and is followed only by spaces then end-of-field or a ``/``
    comment; a lone ``'`` followed by anything else is content (astropy splits ``''`` escape pairs
    across ``CONTINUE`` cards, leaving a lone ``'&`` at a card boundary). Returns
    ``(None, "", False)`` when the field does not hold a string value.
    """
    s = field
    i = 0
    while i < len(s) and s[i] == " ":
        i += 1
    if i >= len(s) or s[i] != "'":
        return None, "", False
    i += 1
    start = i
    while i < len(s):
        if s[i] == "'":
            if i + 1 < len(s) and s[i + 1] == "'":
                i += 2  # escaped quote → content
                continue
            stripped = s[i + 1 :].lstrip(" ")
            if stripped == "" or stripped[0] == "/":
                comment = stripped[1:].strip() if stripped[:1] == "/" else ""
                return s[start:i], comment, True
            i += 1  # lone quote, not a terminator → content
        else:
            i += 1
    return s[start:], "", True  # unterminated (defensive)


def _value_field(text: str) -> "str | None":
    """Raw value field (escapes intact) for a card, or ``None`` when it has no value field.

    Mirrors the value-field selection in :func:`parse_card`: a standard ``KEY = `` card's value
    starts at column 10; a ``HIERARCH`` card's value starts after the first ``=``. The naive
    ``find("=")`` matches ``parse_card`` exactly so the folded value never disagrees with the
    single-card parse. Kept in sync with ``parse_card`` by construction.
    """
    if text[8:10] == "= ":
        return text[10:]
    if text[0:8].rstrip() == "HIERARCH":
        rest = text[8:]
        eq = rest.find("=")
        if eq >= 0:
            return rest[eq + 1 :]
    return None


def parse_card(raw: bytes) -> "_Card | None":
    """Parse one 80-byte card; return None for END."""
    text = raw.decode("ascii", "replace")
    name = text[0:8].rstrip()
    if name == "END":
        return None
    if name in ("COMMENT", "HISTORY") or text[0:8] == "        ":
        return _Card(name, text[8:].rstrip(), "", commentary=True)
    if text[8:10] == "= ":
        value, comment = _parse_value_comment(text[10:])
        return _Card(name, value, comment)
    if name == "HIERARCH":
        # `HIERARCH keyword tokens = value / comment`; the spaced token string is the keyword.
        rest = text[8:]
        eq = rest.find("=")
        if eq >= 0:
            keyword = rest[:eq].strip()
            if keyword:
                value, comment = _parse_value_comment(rest[eq + 1 :])
                return _Card(keyword, value, comment)
    # other: keep the raw remainder as a commentary-style record.
    return _Card(name, text[8:].rstrip(), "", commentary=True)


def parse_cards(raws: "list[bytes]") -> "list[_Card]":
    """Parse a sequence of physical 80-byte cards, folding CONTINUE long-string continuations.

    Continuation is folded on the *raw* escaped text before unescaping: astropy splits the escaped
    representation and can cut a ``''`` escape pair across a card boundary, so unescaping each card
    independently would misread the split ``'`` as a closing quote and truncate. The raw fragments
    (each ``&`` continuation sentinel dropped) are concatenated and ``''``→``'`` unescaped exactly
    once, with the comment taken from the last fragment. A lone ``&``-terminated value with no
    following CONTINUE keeps the ``&`` literally. Both standard ``KEY = `` cards and ``HIERARCH``
    long strings are folded (their value field is located by :func:`_value_field`).
    """
    cards: "list[_Card]" = []
    i = 0
    n = len(raws)
    while i < n:
        card = parse_card(raws[i])
        base = i
        i += 1
        if card is None:  # END
            continue
        field = _value_field(raws[base].decode("ascii", "replace")) if not card.commentary else None
        if isinstance(card.value, str) and field is not None:
            raw, comment, is_string = _extract_raw_string(field)
            if (
                is_string
                and raw.endswith("&")
                and i < n
                and raws[i][0:8].rstrip() == b"CONTINUE"
            ):
                parts = [raw[:-1]]
                while i < n and raws[i][0:8].rstrip() == b"CONTINUE":
                    frag, cont_comment, _ = _extract_raw_string(raws[i][8:].decode("ascii", "replace"))
                    i += 1
                    if cont_comment:
                        comment = cont_comment
                    frag = frag if isinstance(frag, str) else ""
                    if frag.endswith("&"):
                        parts.append(frag[:-1])
                    else:
                        parts.append(frag)
                        break
                card.value = "".join(parts).replace("''", "'").rstrip()
                card.comment = comment
        cards.append(card)
    return cards


def _wrap_commentary(value: Any) -> "list[str]":
    """Split commentary text into physical-card chunks of ≤72 chars (a COMMENT/HISTORY/blank card
    holds free text in columns 9-80). Empty text yields one blank card, matching astropy — which
    splits long commentary into multiple cards at assignment time rather than truncating."""
    text = "" if value is None else str(value)
    if not text:
        return [""]
    return [text[i : i + 72] for i in range(0, len(text), 72)]


class Header:
    """An ordered, case-insensitive collection of FITS keyword records."""

    def __init__(self):
        self._cards: list[_Card] = []
        self._persist: Optional[Callable[[str, Any, Optional[str]], None]] = None
        self._delete: Optional[Callable[[str], None]] = None
        # Rewrites every commentary card of a keyword in an attached writable handle to the given
        # texts (delete-all-by-name then re-append). Used by in-place commentary edits/deletes and
        # list replace-all, where a single append is not enough. None on read-only/detached headers.
        self._resync: Optional[Callable[[str, "list[Any]"], None]] = None
        # Called after an edit that is NOT persisted to an open handle (read-only mode), so the
        # owning HDUList can flag itself dirty and reconstruct rather than copy stale bytes on save.
        self._dirty_cb: Optional[Callable[[], None]] = None

    # ── construction ──────────────────────────────────────────────────────────────────────
    @classmethod
    def _from_cards(cls, cards: list[_Card]) -> "Header":
        h = cls()
        h._cards = cards
        return h

    # ── mapping protocol ──────────────────────────────────────────────────────────────────
    def _find(self, key: str) -> int:
        ku = key.upper()
        for i, c in enumerate(self._cards):
            if not c.commentary and c.keyword.upper() == ku:
                return i
        return -1

    def _is_commentary_key(self, key: Any) -> bool:
        return isinstance(key, str) and key.upper() in _COMMENTARY

    def __contains__(self, key: str) -> bool:
        if self._is_commentary_key(key):
            ku = key.upper()
            return any(c.commentary and c.keyword.upper() == ku for c in self._cards)
        return self._find(key) >= 0

    def __getitem__(self, key: str) -> Any:
        # A commentary keyword returns a mutable list-like view over all of its cards (astropy's
        # ``header['COMMENT']`` behavior), never raising: an absent keyword yields an empty view.
        if self._is_commentary_key(key):
            return _CommentaryCards(self, key.upper())
        i = self._find(key)
        if i < 0:
            raise KeyError(key)
        return self._cards[i].value

    def get(self, key: str, default: Any = None) -> Any:
        if self._is_commentary_key(key):
            return _CommentaryCards(self, key.upper())
        i = self._find(key)
        return self._cards[i].value if i >= 0 else default

    def __setitem__(self, key: str, value: Any) -> None:
        # Commentary keywords accumulate (append), never overwrite; a list/tuple replaces all of
        # them. Handled before the (value, comment) unpack, which does not apply to commentary.
        if self._is_commentary_key(key):
            self._set_commentary(key.upper(), value)
            return
        comment = None
        if isinstance(value, tuple) and len(value) == 2:
            value, comment = value
        i = self._find(key)
        resolved_comment = comment if comment is not None else (self._cards[i].comment if i >= 0 else "")
        # Persist FIRST: a rejected edit (a structural keyword, or a read-only device) must not
        # leave a bogus card in the in-memory header, which would poison every later read.
        if self._persist is not None:
            self._persist(key, value, resolved_comment)
        if i >= 0:
            self._cards[i].value = value
            if comment is not None:
                self._cards[i].comment = comment
        else:
            self._cards.append(_Card(key.upper(), value, comment or ""))
        if self._persist is None and self._dirty_cb is not None:
            self._dirty_cb()  # read-only edit → not in the handle's bytes; reconstruct on save

    def __delitem__(self, key: str) -> None:
        # Deleting a commentary keyword removes ALL of its cards (astropy semantics).
        if self._is_commentary_key(key):
            ku = key.upper()
            idxs = [i for i, c in enumerate(self._cards) if c.commentary and c.keyword.upper() == ku]
            if not idxs:
                raise KeyError(key)
            for i in reversed(idxs):
                del self._cards[i]
            self._resync_keyword(ku)  # empty texts → delete-all in the handle (or mark dirty)
            return
        i = self._find(key)
        if i < 0:
            raise KeyError(key)
        if self._delete is not None:
            self._delete(key)  # persist first; on failure the in-memory card is retained
        del self._cards[i]
        if self._delete is None and self._dirty_cb is not None:
            self._dirty_cb()

    # ── commentary (COMMENT / HISTORY / blank) ────────────────────────────────────────────
    def _set_commentary(self, keyword: str, value: Any) -> None:
        """Append (scalar) or replace-all (``list``) commentary cards for ``keyword``.

        A ``list`` replaces every card of the keyword; anything else appends. A 2-tuple is read as
        the valued-keyword ``(value, comment)`` form and only its text is kept (commentary cards
        have no comment field) — so ``header['COMMENT'] = ('note', 'ignored')`` adds one card, not
        two. Each logical entry is split into ≤72-char physical cards. Appending persists eagerly
        one card at a time (O(1) per card — cheap for long HISTORY chains); replace-all rewrites
        every card of the keyword through ``_resync``.
        """
        if isinstance(value, list):
            self._cards[:] = [
                c for c in self._cards if not (c.commentary and c.keyword.upper() == keyword)
            ]
            for item in value:
                for chunk in _wrap_commentary(item):
                    self._cards.append(_Card(keyword, chunk, "", commentary=True))
            self._resync_keyword(keyword)
            return
        if isinstance(value, tuple) and len(value) == 2:
            value = value[0]  # (text, comment): keep the text, drop the meaningless comment
        for chunk in _wrap_commentary(value):
            # Persist FIRST so a rejected write leaves no bogus in-memory card (mirrors valued keys).
            if self._persist is not None:
                self._persist(keyword, chunk, None)
            self._cards.append(_Card(keyword, chunk, "", commentary=True))
        if self._persist is None and self._dirty_cb is not None:
            self._dirty_cb()

    def _resync_keyword(self, keyword: str) -> None:
        """Push the current in-memory commentary cards of ``keyword`` to an attached writable handle
        (rewrite-all), or flag the list dirty so a read-only edit reconstructs on save."""
        if self._resync is not None:
            texts = [c.value for c in self._cards if c.commentary and c.keyword.upper() == keyword]
            self._resync(keyword, texts)
        elif self._dirty_cb is not None:
            self._dirty_cb()

    def add_comment(self, value: Any) -> None:
        """Append a COMMENT card (astropy-compatible). Long text spans multiple cards."""
        self._set_commentary("COMMENT", value)

    def add_history(self, value: Any) -> None:
        """Append a HISTORY card (astropy-compatible). Long text spans multiple cards."""
        self._set_commentary("HISTORY", value)

    def __iter__(self) -> Iterator[str]:
        for c in self._cards:
            if not c.commentary:
                yield c.keyword

    def __len__(self) -> int:
        return sum(1 for c in self._cards if not c.commentary)

    def keys(self):
        return list(self.__iter__())

    def items(self):
        return [(c.keyword, c.value) for c in self._cards if not c.commentary]

    def values(self):
        return [c.value for c in self._cards if not c.commentary]

    def comment_of(self, key: str) -> str:
        i = self._find(key)
        return self._cards[i].comment if i >= 0 else ""

    def cards(self) -> list[tuple[str, Any, str]]:
        return [(c.keyword, c.value, c.comment) for c in self._cards]

    @property
    def comments(self) -> list[str]:
        """COMMENT card text (in order)."""
        return [c.value for c in self._cards if c.commentary and c.keyword == "COMMENT"]

    @property
    def history(self) -> list[str]:
        """HISTORY card text (in order)."""
        return [c.value for c in self._cards if c.commentary and c.keyword == "HISTORY"]

    def __repr__(self) -> str:
        rows = []
        for c in self._cards:
            if c.commentary:
                rows.append(f"{c.keyword:<8}{c.value}")
            else:
                v = repr(c.value)
                tail = f" / {c.comment}" if c.comment else ""
                rows.append(f"{c.keyword:<8}= {v}{tail}")
        return "\n".join(rows)


class _CommentaryCards:
    """A mutable, list-like view over one keyword's COMMENT/HISTORY/blank cards, mirroring the
    object astropy returns from ``header['COMMENT']``. Indexing, assignment, deletion, and
    ``append`` mutate the owning :class:`Header` and persist to an attached writable file.

    ``append`` is O(1). A single-card ``view[i] = x`` / ``del view[i]`` rewrites all *k* cards of
    the keyword (O(k)) to persist, so replacing many at once is cheaper as one assignment,
    ``header['COMMENT'] = [...]``, than as a loop of per-index edits.
    """

    __slots__ = ("_header", "_keyword")

    def __init__(self, header: "Header", keyword: str):
        self._header = header
        self._keyword = keyword

    def _indices(self) -> "list[int]":
        ku = self._keyword
        return [i for i, c in enumerate(self._header._cards) if c.commentary and c.keyword.upper() == ku]

    def __len__(self) -> int:
        return len(self._indices())

    def __iter__(self) -> Iterator[Any]:
        cards = self._header._cards
        return (cards[i].value for i in self._indices())

    def __getitem__(self, index):
        idxs = self._indices()
        cards = self._header._cards
        if isinstance(index, slice):
            return [cards[i].value for i in idxs[index]]
        return cards[idxs[index]].value

    def __setitem__(self, index: int, text: Any) -> None:
        if not isinstance(index, int):
            raise TypeError("commentary index must be an integer (slice assignment is not supported)")
        cards = self._header._cards
        pos = self._indices()[index]  # raises IndexError like a list for a bad index
        chunks = _wrap_commentary(text)
        cards[pos].value = chunks[0]
        for off, chunk in enumerate(chunks[1:], start=1):  # over-long text spills into new cards
            cards.insert(pos + off, _Card(self._keyword, chunk, "", commentary=True))
        self._header._resync_keyword(self._keyword)

    def __delitem__(self, index: int) -> None:
        if not isinstance(index, int):
            raise TypeError("commentary index must be an integer (slice deletion is not supported)")
        pos = self._indices()[index]
        del self._header._cards[pos]
        self._header._resync_keyword(self._keyword)

    def append(self, text: Any) -> None:
        self._header._set_commentary(self._keyword, text)

    def __eq__(self, other: Any) -> bool:
        try:
            return list(self) == list(other)
        except TypeError:
            return NotImplemented

    def __repr__(self) -> str:
        return "\n".join(str(v) for v in self)

    __str__ = __repr__
