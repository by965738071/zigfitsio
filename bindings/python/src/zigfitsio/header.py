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
    # HIERARCH or other: keep the raw remainder as a commentary-style record.
    return _Card(name, text[8:].rstrip(), "", commentary=True)


class Header:
    """An ordered, case-insensitive collection of FITS keyword records."""

    def __init__(self):
        self._cards: list[_Card] = []
        self._persist: Optional[Callable[[str, Any, Optional[str]], None]] = None
        self._delete: Optional[Callable[[str], None]] = None

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
        if i >= 0:
            self._cards[i].value = value
            if comment is not None:
                self._cards[i].comment = comment
            else:
                comment = self._cards[i].comment
        else:
            self._cards.append(_Card(key.upper(), value, comment or ""))
        if self._persist is not None:
            self._persist(key, value, comment)

    def __delitem__(self, key: str) -> None:
        i = self._find(key)
        if i < 0:
            raise KeyError(key)
        del self._cards[i]
        if self._delete is not None:
            self._delete(key)

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
