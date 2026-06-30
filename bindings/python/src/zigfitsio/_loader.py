"""Locate and load the ``zigfitsio_capi`` shared library.

Search order:
  1. ``ZIGFITSIO_LIBRARY`` env var (an explicit path to the shared library).
  2. The bundled library shipped inside this package (the wheel layout).
  3. A development build under ``<repo>/zig-out/lib`` discovered by walking parents.
"""

from __future__ import annotations

import ctypes
import os
import sys
from pathlib import Path


def _lib_filename() -> str:
    if sys.platform == "darwin":
        return "libzigfitsio_capi.dylib"
    if sys.platform == "win32":
        return "zigfitsio_capi.dll"
    return "libzigfitsio_capi.so"


def _candidate_paths() -> list[Path]:
    name = _lib_filename()
    candidates: list[Path] = []

    env = os.environ.get("ZIGFITSIO_LIBRARY")
    if env:
        candidates.append(Path(env))

    here = Path(__file__).resolve().parent
    # Bundled next to the package (wheel data) or in a `_lib` subdir.
    candidates.append(here / name)
    candidates.append(here / "_lib" / name)

    # Development fallback: a `zig-out/lib` somewhere above this file.
    for parent in here.parents:
        cand = parent / "zig-out" / "lib" / name
        if cand.exists():
            candidates.append(cand)
            break

    return candidates


def load_library() -> ctypes.CDLL:
    """Return the loaded ``CDLL``, raising ``OSError`` with the searched paths on failure."""
    tried: list[str] = []
    for path in _candidate_paths():
        tried.append(str(path))
        if path.exists():
            return ctypes.CDLL(str(path))
    raise OSError(
        "could not locate the zigfitsio_capi shared library. Build it with "
        "`zig build capi` or set ZIGFITSIO_LIBRARY. Searched:\n  "
        + "\n  ".join(tried)
    )
