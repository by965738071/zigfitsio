"""A dict-like, ordered FITS :class:`Header`, modeled on ``astropy.io.fits.Header``.

The header is parsed from raw 80-byte cards (read through the C ABI) into an ordered list of
records. Edits update the in-memory list and, when the header is attached to a writable open
file, are persisted immediately through an injected ``_persist`` callback.
"""

from __future__ import annotations

from typing import Any, Callable, Iterator, Optional

_COMMENTARY = ("COMMENT", "HISTORY", "")


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
    try:
        return float(token.replace("D", "E").replace("d", "e")), comment
    except ValueError:
        return token, comment


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

    A string value whose text ends in ``&`` is continued by the following ``CONTINUE`` cards; the
    fragments are concatenated (each ``&`` sentinel dropped) and the comment taken from the last
    fragment. A lone ``&``-terminated value with no following CONTINUE keeps the ``&`` literally.
    """
    cards: "list[_Card]" = []
    i = 0
    n = len(raws)
    while i < n:
        card = parse_card(raws[i])
        i += 1
        if card is None:  # END
            continue
        if (
            not card.commentary
            and isinstance(card.value, str)
            and card.value.endswith("&")
            and i < n
            and raws[i][0:8].rstrip() == b"CONTINUE"
        ):
            parts = [card.value[:-1]]
            comment = card.comment
            while i < n and raws[i][0:8].rstrip() == b"CONTINUE":
                text = raws[i].decode("ascii", "replace")
                frag, cont_comment = _parse_value_comment(text[8:])
                i += 1
                if cont_comment:
                    comment = cont_comment
                frag = frag if isinstance(frag, str) else ""
                if frag.endswith("&"):
                    parts.append(frag[:-1])
                else:
                    parts.append(frag)
                    break
            card.value = "".join(parts)
            card.comment = comment
        cards.append(card)
    return cards


class Header:
    """An ordered, case-insensitive collection of FITS keyword records."""

    def __init__(self):
        self._cards: list[_Card] = []
        self._persist: Optional[Callable[[str, Any, Optional[str]], None]] = None
        self._delete: Optional[Callable[[str], None]] = None
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

    def __contains__(self, key: str) -> bool:
        return self._find(key) >= 0

    def __getitem__(self, key: str) -> Any:
        i = self._find(key)
        if i < 0:
            raise KeyError(key)
        return self._cards[i].value

    def get(self, key: str, default: Any = None) -> Any:
        i = self._find(key)
        return self._cards[i].value if i >= 0 else default

    def __setitem__(self, key: str, value: Any) -> None:
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
        i = self._find(key)
        if i < 0:
            raise KeyError(key)
        if self._delete is not None:
            self._delete(key)  # persist first; on failure the in-memory card is retained
        del self._cards[i]
        if self._delete is None and self._dirty_cb is not None:
            self._dirty_cb()

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
