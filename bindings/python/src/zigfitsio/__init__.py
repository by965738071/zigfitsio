"""zigfitsio — Python bindings for the pure-Zig zigfitsio FITS library.

Two layers are provided:

* A **high-level**, NumPy-first API modeled on ``astropy.io.fits`` (this namespace): ``open``,
  ``HDUList``, ``PrimaryHDU``/``ImageHDU``/``BinTableHDU``/``AsciiTableHDU``/``CompImageHDU``,
  ``Column``, ``Header``, and the ``getdata``/``getheader``/``getval``/``writeto``/``verify``
  conveniences.
* A **low-level** 1:1 ctypes binding under ``zigfitsio.lowlevel`` for power users.

Example::

    import numpy as np, zigfitsio as zf
    zf.writeto("img.fits", np.arange(12, dtype="f4").reshape(3, 4), overwrite=True)
    with zf.open("img.fits") as hdul:
        print(hdul[0].data)
"""

from __future__ import annotations

from . import lowlevel
from .core import (
    AsciiTableHDU,
    BinTableHDU,
    Column,
    CompImageHDU,
    Finding,
    HDUList,
    ImageHDU,
    PrimaryHDU,
    from_bytes,
    getdata,
    getheader,
    getval,
    open,
    verify,
    writeto,
)
from .header import Header
from .lowlevel import (
    FitsError,
    FitsHeaderError,
    FitsIOError,
    FitsTableError,
    FitsTypeError,
    FitsWcsError,
    KeywordNotFound,
)

__version__ = lowlevel.version()

__all__ = [
    "open",
    "from_bytes",
    "getdata",
    "getheader",
    "getval",
    "writeto",
    "verify",
    "HDUList",
    "PrimaryHDU",
    "ImageHDU",
    "CompImageHDU",
    "BinTableHDU",
    "AsciiTableHDU",
    "Column",
    "Header",
    "Finding",
    "FitsError",
    "FitsIOError",
    "FitsHeaderError",
    "FitsTableError",
    "FitsTypeError",
    "FitsWcsError",
    "KeywordNotFound",
    "lowlevel",
    "__version__",
]
