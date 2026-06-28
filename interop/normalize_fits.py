#!/usr/bin/env python3
"""normalize_fits.py — enforce the committed-golden determinism contract.

Walks every ``*.fits`` under the given root and, *in place* and *offset-preserving*, neutralises
any wall-clock content a generating tool might have injected into a header:

  * a ``DATE`` card (CFITSIO's ``fits_write_date``) is blanked to spaces;
  * an ISO timestamp ``YYYY-MM-DDTHH:MM:SS`` anywhere in a header card (e.g. the "… updated <ts>"
    comment ``fits_write_chksum`` writes) is replaced by a fixed placeholder of identical length.

Only bytes inside header blocks are touched (the data units are parsed and skipped), so pixel /
table bytes are never altered and every byte offset is preserved. On the clean pipeline in the
Makefile (the C generator writes no ``DATE``; ``fpack -C`` writes no checksum cards) this makes
**zero** changes — it exists to make a regression in that pipeline fail loudly rather than commit
nondeterministic bytes.

Pure stdlib; never imports astropy. Does not author FITS bytes, only normalises CFITSIO's.
"""
import os
import re
import sys

CARD = 80
BLOCK = 2880
TS = re.compile(rb"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")
TS_PLACEHOLDER = b"1980-01-01T00:00:00"  # same length as a real ISO timestamp


def _int_card(block, key):
    """Return the integer value of a mandatory card in a header block, or None."""
    for i in range(0, len(block), CARD):
        c = block[i:i + CARD]
        if c[:8].rstrip() == key and c[8:10] == b"= ":
            try:
                return int(c[10:30].split(b"/")[0].strip())
            except ValueError:
                return None
    return None


def _header_regions(data):
    """Yield (start, end) byte ranges of each HDU's header (header blocks only)."""
    off = 0
    n = len(data)
    while off + BLOCK <= n:
        hstart = off
        # advance block by block until the END card is seen
        ended = False
        while off + BLOCK <= n:
            blk = data[off:off + BLOCK]
            off += BLOCK
            found_end = False
            for i in range(0, BLOCK, CARD):
                if blk[i:i + 3] == b"END" and blk[i + 3:i + CARD].strip() == b"":
                    found_end = True
                    break
            if found_end:
                ended = True
                break
        hend = off
        yield hstart, hend
        if not ended:
            return
        # compute data size of this HDU and skip it
        hdr = data[hstart:hend]
        bitpix = _int_card(hdr, b"BITPIX") or 8
        naxis = _int_card(hdr, b"NAXIS") or 0
        npix = 1
        if naxis == 0:
            npix = 0
        else:
            for ax in range(1, naxis + 1):
                v = _int_card(hdr, ("NAXIS%d" % ax).encode())
                if v is None:
                    v = 0
                npix *= v
        pcount = _int_card(hdr, b"PCOUNT") or 0
        gcount = _int_card(hdr, b"GCOUNT") or 1
        if npix == 0:
            dbytes = 0
        else:
            dbytes = (abs(bitpix) // 8) * gcount * (pcount + npix)
        dblocks = (dbytes + BLOCK - 1) // BLOCK
        off += dblocks * BLOCK


def normalize_file(path):
    with open(path, "rb") as fh:
        data = bytearray(fh.read())
    changes = []
    for hstart, hend in _header_regions(data):
        for i in range(hstart, hend, CARD):
            card = bytes(data[i:i + CARD])
            key = card[:8].rstrip()
            new = card
            if key == b"DATE":
                new = b" " * CARD
                changes.append(("blanked DATE card", i))
            ts_new, n = TS.subn(TS_PLACEHOLDER, new)
            if n:
                new = ts_new
                changes.append(("neutralised %d timestamp(s)" % n, i))
                if key in (b"CHECKSUM", b"DATASUM"):
                    print(
                        "WARNING: %s: neutralised a timestamp inside a %s card — its value is now "
                        "stale (regenerate with fpack -C / deterministic checksums)"
                        % (path, key.decode()),
                        file=sys.stderr,
                    )
            if new != card:
                data[i:i + CARD] = new
    if changes:
        with open(path, "wb") as fh:
            fh.write(data)
    return changes


def main(root):
    total = 0
    for dirpath, _dirs, files in os.walk(root):
        for fn in sorted(files):
            if fn.endswith(".fits"):
                ch = normalize_file(os.path.join(dirpath, fn))
                total += len(ch)
                for what, off in ch:
                    print("normalize: %s @%d: %s" % (os.path.join(dirpath, fn), off, what))
    print("normalize: %d card(s) changed under %s" % (total, root))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "../test/golden"))
