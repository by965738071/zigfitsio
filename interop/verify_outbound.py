#!/usr/bin/env python3
"""verify_outbound.py — Astropy conformance cross-check of the golden corpus (CI sidecar).

Opens every `*.fits` (and `*.fz`) under the given root and runs `hdul.verify('exception')`, so a
structurally non-conformant golden fails loudly. Also re-checks any stored DATASUM/CHECKSUM with
Astropy's own implementation. This is a CROSS-CHECK only — it authors no bytes — so Astropy
(version-variable) is fine here. Conformance-by-construction is also asserted by `fitsverify` in
`make verify` and by the Zig consumer.

Exit non-zero on the first failure.
"""
import os
import sys

from astropy.io import fits


def main(root):
    failures = 0
    checked = 0
    for dirpath, _dirs, files in os.walk(root):
        # The conformance/malformed goldens are deliberate violations — Astropy is expected to
        # reject them; that detection is the Zig consumer's job, not this structural sweep.
        if "malformed" in dirpath.split(os.sep):
            continue
        for fn in sorted(files):
            if not (fn.endswith(".fits") or fn.endswith(".fz")):
                continue
            path = os.path.join(dirpath, fn)
            checked += 1
            try:
                with fits.open(path, checksum=True) as hdul:
                    hdul.verify("exception")
                    # Touch the data of each HDU so lazy decode/codec paths execute.
                    for hdu in hdul:
                        _ = None if hdu.data is None else hdu.data.shape
                print("ok:   %s" % path)
            except Exception as exc:  # noqa: BLE001 - report and continue
                failures += 1
                print("FAIL: %s: %s" % (path, exc), file=sys.stderr)
    print("verify_outbound: %d file(s) checked, %d failure(s)" % (checked, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "../test/golden"))
