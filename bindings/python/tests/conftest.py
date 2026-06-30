"""Shared pytest fixtures. Points the loader at a dev build under ``<repo>/zig-out`` when no
``ZIGFITSIO_LIBRARY`` is set, and skips the whole suite if the shared library is unavailable."""

import os
import sys
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[3]
_SRC = _REPO / "bindings" / "python" / "src"

if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))

# Prefer a dev build if present and no explicit override was given.
if "ZIGFITSIO_LIBRARY" not in os.environ:
    for name in ("libzigfitsio_capi.dylib", "libzigfitsio_capi.so", "zigfitsio_capi.dll"):
        cand = _REPO / "zig-out" / "lib" / name
        if cand.exists():
            os.environ["ZIGFITSIO_LIBRARY"] = str(cand)
            break

try:
    import zigfitsio  # noqa: F401
except OSError as exc:  # library not built
    pytest.skip(f"zigfitsio_capi not available: {exc}", allow_module_level=True)


@pytest.fixture
def tmp_fits(tmp_path):
    def _path(name="test.fits"):
        return str(tmp_path / name)

    return _path


GOLDEN = _REPO / "test" / "golden"


@pytest.fixture
def golden_dir():
    if not GOLDEN.exists():
        pytest.skip("golden corpus not present")
    return GOLDEN
