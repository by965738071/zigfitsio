"""Hatchling build hook: compile the ``zigfitsio_capi`` shared library with Zig and bundle it
into the wheel as package data.

Zig is obtained from the ``ziglang`` build dependency (``python -m ziglang``); a system ``zig``
on ``PATH`` is used as a fallback. Set ``ZIG_TARGET`` to cross-compile (e.g. for cibuildwheel
emitting wheels for another platform).
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

_LIBNAMES = {
    "linux": "libzigfitsio_capi.so",
    "darwin": "libzigfitsio_capi.dylib",
    "win32": "zigfitsio_capi.dll",
}


def _libname() -> str:
    for key, name in _LIBNAMES.items():
        if sys.platform.startswith(key):
            return name
    return "libzigfitsio_capi.so"


class ZigSharedLibraryHook(BuildHookInterface):
    PLUGIN_NAME = "zig"

    def initialize(self, version, build_data):  # noqa: D401
        if self.target_name != "wheel":
            return

        repo = Path(self.root).resolve()
        libname = _libname()
        self._build(repo)

        src = repo / "zig-out" / "lib" / libname
        if not src.exists():
            raise RuntimeError(f"`zig build capi` did not produce {src}")

        pkg_dir = repo / "bindings" / "python" / "src" / "zigfitsio"
        dest = pkg_dir / libname
        shutil.copy2(src, dest)

        build_data["pure_python"] = False
        build_data["infer_tag"] = True
        build_data.setdefault("force_include", {})[str(dest)] = f"zigfitsio/{libname}"

    def _build(self, repo: Path) -> None:
        args = ["build", "capi", "-Doptimize=ReleaseFast"]
        target = os.environ.get("ZIG_TARGET")
        if target:
            args.append(f"-Dtarget={target}")

        # Prefer the `ziglang` build dependency (a pinned, bundled Zig); fall back to a system
        # `zig` on PATH. A genuine compile failure propagates rather than silently trying the next.
        runners = []
        if importlib.util.find_spec("ziglang") is not None:
            runners.append([sys.executable, "-m", "ziglang"])
        runners.append(["zig"])

        for runner in runners:
            try:
                subprocess.run([*runner, *args], cwd=repo, check=True)
                return
            except FileNotFoundError:
                continue
        raise RuntimeError(
            "no Zig toolchain found: add `ziglang` to the build environment or install `zig`"
        )
