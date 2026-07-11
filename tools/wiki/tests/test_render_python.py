"""Static Python Wiki renderer tests (no native library or package import required)."""

from __future__ import annotations

import ast
import importlib.util
import json
from pathlib import Path
import shutil
import sys

import pytest


REPO_ROOT = Path(__file__).resolve().parents[3]
SOURCE_ROOT = REPO_ROOT / "bindings/python/src/zigfitsio"
TAG = "v9.8.7"
SHA = "0123456789abcdef0123456789abcdef01234567"

_SPEC = importlib.util.spec_from_file_location(
    "render_python", REPO_ROOT / "tools/wiki/render_python.py"
)
assert _SPEC is not None and _SPEC.loader is not None
render_python = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = render_python
_SPEC.loader.exec_module(render_python)


def _generate(output: Path, source: Path = SOURCE_ROOT):
    return render_python.generate(
        source,
        output,
        TAG,
        SHA,
        repo_root=REPO_ROOT,
    )


def test_generates_complete_static_contract(tmp_path):
    manifest = _generate(tmp_path)

    assert manifest["managed_files"] == [
        "Python-API-Low-Level.md",
        "Python-API.md",
        "python-symbols.json",
    ]
    assert manifest["counts"]["public_exports"] == 25
    assert manifest["counts"]["lowlevel_exports"] == 62
    assert manifest["counts"]["lowlevel_functions"] == 89
    assert manifest["coverage"]["missing"] == []
    assert len(manifest["abi_prototypes"]) == 89
    assert manifest["abi_prototypes"][0] == {
        "name": "zf_version",
        "returns": "CHARP",
        "args": [],
    }
    assert manifest["abi_prototypes"][-1]["name"] == "zf_write_compressed3"

    symbols = {item["id"] for item in manifest["symbols"]}
    assert "zigfitsio.open" in symbols
    assert "zigfitsio.ImageHDU.header" in symbols  # visible API owned by private _HDU
    assert "zigfitsio.BinTableHDU.from_columns" in symbols
    assert "zigfitsio.AsciiTableHDU.from_columns" in symbols
    assert "zigfitsio.Column.name" in symbols
    assert "zigfitsio.Header.__getitem__" in symbols
    assert "zigfitsio.Header.__iter__" in symbols
    assert "zigfitsio.HDUList.__enter__" in symbols
    assert "zigfitsio.HDUList.__exit__" in symbols
    assert "zigfitsio.lowlevel.ZfOpenOpts.max_open_alloc" in symbols
    assert "zigfitsio.lowlevel.lib.zf_write_compressed3" in symbols

    highlevel = (tmp_path / "Python-API.md").read_text(encoding="utf-8")
    lowlevel = (tmp_path / "Python-API-Low-Level.md").read_text(encoding="utf-8")
    assert f"Release: **{TAG}**" in highlevel
    assert f"`{SHA}`" in highlevel
    assert "BinTableHDU.from_columns" in highlevel
    assert "lib.zf_version() -> CHARP" in lowlevel
    assert "lib.zf_write_compressed3" in lowlevel
    assert str(REPO_ROOT) not in highlevel
    assert str(REPO_ROOT) not in lowlevel

    on_disk = json.loads((tmp_path / "python-symbols.json").read_text(encoding="utf-8"))
    assert on_disk == manifest


def test_generation_is_byte_for_byte_deterministic(tmp_path):
    first = tmp_path / "first"
    second = tmp_path / "second"
    manifest = _generate(first)
    _generate(second)

    for filename in manifest["managed_files"]:
        assert (first / filename).read_bytes() == (second / filename).read_bytes()


def test_missing_all_export_fails_coverage_before_writing(tmp_path):
    source = tmp_path / "zigfitsio"
    shutil.copytree(SOURCE_ROOT, source)
    init = source / "__init__.py"
    text = init.read_text(encoding="utf-8")
    marker = '    "__version__",\n]'
    assert marker in text
    init.write_text(text.replace(marker, '    "__version__",\n    "not_a_real_export",\n]'))

    output = tmp_path / "output"
    with pytest.raises(render_python.ApiContractError, match="not_a_real_export"):
        _generate(output, source)
    assert not output.exists()


def test_lowlevel_all_is_literal_and_hides_loader_internals():
    tree = ast.parse((SOURCE_ROOT / "lowlevel.py").read_text(encoding="utf-8"))
    all_node = next(
        node
        for node in tree.body
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "__all__" for target in node.targets)
    )
    exports = ast.literal_eval(all_node.value)

    assert len(exports) == len(set(exports)) == 62
    assert "lib" in exports
    assert "ZfOpenOpts" in exports
    assert "version" in exports
    assert "load_library" not in exports
    assert "_PROTOS" not in exports
