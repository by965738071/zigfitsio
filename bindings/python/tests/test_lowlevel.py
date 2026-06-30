"""Low-level ctypes binding tests (no numpy required)."""

import ctypes as c

import pytest

import zigfitsio.lowlevel as ll


def test_version():
    assert ll.version().count(".") == 2


def test_create_memory_image_roundtrip():
    h = c.c_void_p()
    ll.check(ll.lib.zf_create_memory(None, c.byref(h)))
    try:
        axes = (c.c_long * 2)(4, 3)
        ll.check(ll.lib.zf_create_img(h, -32, 2, axes))
        pix = (c.c_float * 12)(*[float(i) for i in range(12)])
        ll.check(ll.lib.zf_write_img(h, ll.ZF_FLOAT32, 1, 12, None, None, pix))
        out = (c.c_float * 12)()
        ll.check(ll.lib.zf_read_img(h, ll.ZF_FLOAT32, 1, 12, None, None, out))
        assert list(out) == list(pix)
    finally:
        ll.lib.zf_close(h)


def test_keyword_not_found_is_typed():
    h = c.c_void_p()
    ll.check(ll.lib.zf_create_memory(None, c.byref(h)))
    try:
        ll.check(ll.lib.zf_create_img(h, 8, 0, None))
        v = c.c_double()
        with pytest.raises(ll.KeywordNotFound) as ei:
            ll.check(ll.lib.zf_read_key_dbl(h, b"NOPE", 4, c.byref(v)))
        assert ei.value.status == 202
        # KeywordNotFound is also a KeyError for dict-like ergonomics.
        assert isinstance(ei.value, KeyError)
    finally:
        ll.lib.zf_close(h)
