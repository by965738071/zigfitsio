#!/usr/bin/env python3
"""check_funpack.py — prove the OUTBOUND codec interop with the reference tool.

For every `compress_<codec>.fits` a zigfitsio `emit-fixtures` run wrote into the given directory,
run CFITSIO `funpack` and assert the decompressed 16x16 image is the identity ramp `pixel[i] = i`.
A wrong value means CFITSIO cannot read zigfitsio's tile — the exact failure that the PLIO
`1PB`->`1PI` / line-list-header fixes addressed. Authors no committed bytes; safe to run in CI.

Usage: check_funpack.py <emitted-dir>
"""
import os
import struct
import subprocess
import sys
import tempfile


def main(d):
    fails = 0
    for codec in ("plio", "rice", "gzip", "hcompress"):
        src = os.path.join(d, "compress_%s.fits" % codec)
        if not os.path.exists(src):
            print("skip: %s absent" % src)
            continue
        out = os.path.join(tempfile.mkdtemp(), "u_%s.fits" % codec)
        subprocess.run(["funpack", "-O", out, src], check=True)
        raw = open(out, "rb").read()
        off = ((raw.rfind(b"END     ") // 2880) + 1) * 2880  # data after the last END card
        vals = struct.unpack(">256h", raw[off:off + 512])    # 16x16 big-endian int16
        ok = vals == tuple(range(256))
        print(("ok:   " if ok else "FAIL: ") + "funpack %s ramp" % codec)
        if not ok:
            fails += 1
            print("  got %s" % str(vals[:8]), file=sys.stderr)
    print("check_funpack: %d failure(s)" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
