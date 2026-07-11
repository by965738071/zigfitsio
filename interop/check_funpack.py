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


def _funpack_pixels(src, fmt, count):
    """funpack `src` and return the primary-HDU pixels (big-endian `fmt` x `count`)."""
    out = os.path.join(tempfile.mkdtemp(), "u.fits")
    subprocess.run(["funpack", "-O", out, src], check=True)
    raw = open(out, "rb").read()
    # Data start after the last END card. A real END card sits at an 80-byte-aligned offset;
    # requiring that keeps a chance byte pattern inside binary data from being mistaken for it.
    idx = raw.rfind(b"END     ")
    while idx >= 0 and idx % 80 != 0:
        idx = raw.rfind(b"END     ", 0, idx)
    if idx < 0:
        raise AssertionError("no aligned END card found in %s" % out)
    off = ((idx // 2880) + 1) * 2880
    width = struct.calcsize(fmt)
    return struct.unpack(">%d%s" % (count, fmt), raw[off:off + count * width])


def main(d):
    fails = 0
    for codec in ("plio", "rice", "gzip", "hcompress"):
        src = os.path.join(d, "compress_%s.fits" % codec)
        if not os.path.exists(src):
            print("skip: %s absent" % src)
            continue
        vals = _funpack_pixels(src, "h", 256)  # 16x16 int16
        ok = vals == tuple(range(256))
        print(("ok:   " if ok else "FAIL: ") + "funpack %s ramp" % codec)
        if not ok:
            fails += 1
            print("  got %s" % str(vals[:8]), file=sys.stderr)

    # Lossy HCOMPRESS trio (absolute scale 16 / +smooth / noise-adaptive over 32x32 i32):
    # funpack's decode must equal zigfitsio's own decode of the same file (the .pix sidecar) —
    # exact agreement between the two independent decoders on zigfitsio-authored lossy bytes.
    # The curved fixtures additionally stay within the quantization bound of the original.
    curved = tuple(r * r + 2 * c * c + r * c for r in range(32) for c in range(32))
    smooth_pixels = {}
    for name in ("lossy", "smooth", "noise"):
        src = os.path.join(d, "compress_hcompress_%s.fits" % name)
        pix = os.path.join(d, "compress_hcompress_%s.pix" % name)
        if not (os.path.exists(src) and os.path.exists(pix)):
            print("skip: %s absent" % src)
            continue
        vals = _funpack_pixels(src, "i", 1024)  # 32x32 int32
        want = struct.unpack("<1024i", open(pix, "rb").read())
        ok = vals == want
        print(("ok:   " if ok else "FAIL: ") + "funpack hcompress_%s == zigfitsio decode" % name)
        if not ok:
            fails += 1
        if name in ("lossy", "smooth"):
            smooth_pixels[name] = vals
            err = max(abs(a - b) for a, b in zip(vals, curved))
            ok = 0 < err <= 64 * 16
            print(("ok:   " if ok else "FAIL: ") + "hcompress_%s lossy error bounded (max %d)" % (name, err))
            if not ok:
                fails += 1
    if len(smooth_pixels) == 2:
        ok = smooth_pixels["lossy"] != smooth_pixels["smooth"]
        print(("ok:   " if ok else "FAIL: ") + "hcompress smooth output differs from plain (non-vacuous)")
        if not ok:
            fails += 1

    # Quantized-float trio (dithered HCOMPRESS/RICE, NO_DITHER HCOMPRESS over a 32x32 f32
    # field): funpack's dequantized decode must equal zigfitsio's own decode (the .pix sidecar)
    # to the exact f32 BIT pattern — compared as u32 so the assert is bitwise, not tolerant.
    for name in ("hcompress_fdith", "rice_fdith", "hcompress_fq0"):
        src = os.path.join(d, "compress_%s.fits" % name)
        pix = os.path.join(d, "compress_%s.pix" % name)
        if not (os.path.exists(src) and os.path.exists(pix)):
            print("skip: %s absent" % src)
            continue
        vals = _funpack_pixels(src, "I", 1024)  # raw f32 bit patterns, big-endian in the file
        want = struct.unpack("<1024I", open(pix, "rb").read())
        ok = vals == want
        print(("ok:   " if ok else "FAIL: ") + "funpack %s == zigfitsio decode (f32 bit-exact)" % name)
        if not ok:
            fails += 1
            bad = [i for i, (a, b) in enumerate(zip(vals, want)) if a != b][:5]
            print("  first mismatches at %s" % bad, file=sys.stderr)

    print("check_funpack: %d failure(s)" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
