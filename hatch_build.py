"""Hatchling build hook: compile the ``zigfitsio_capi`` shared library with Zig and bundle it
into the wheel as package data.

Zig is obtained from the ``ziglang`` build dependency (``python -m ziglang``); a system ``zig``
on ``PATH`` is used as a fallback. Set ``ZIG_TARGET`` to cross-compile (e.g. for cibuildwheel
emitting wheels for another platform).
"""

from __future__ import annotations

import importlib.util
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

# os token -> (library name prefix, suffix, zig-out install subdir). Zig installs a Windows DLL
# under zig-out/bin (only the import .lib lands in lib/); .so/.dylib live under zig-out/lib.
_LIB_BY_OS = {
    "linux": ("lib", ".so", "lib"),
    "macos": ("lib", ".dylib", "lib"),
    "windows": ("", ".dll", "bin"),
}

# (os, arch) -> wheel platform tag, used when ZIG_TARGET cross-compiles for a non-host platform.
_WHEEL_PLAT = {
    ("linux", "x86_64"): "manylinux2014_x86_64",
    ("linux", "aarch64"): "manylinux2014_aarch64",
    ("macos", "x86_64"): "macosx_10_9_x86_64",
    ("macos", "arm64"): "macosx_11_0_arm64",
    ("macos", "aarch64"): "macosx_11_0_arm64",
    ("windows", "x86_64"): "win_amd64",
    ("windows", "amd64"): "win_amd64",
    ("windows", "aarch64"): "win_arm64",
}


def _host_os() -> str:
    if sys.platform.startswith("win"):
        return "windows"
    return "macos" if sys.platform == "darwin" else "linux"


def _resolve_target(target: str | None) -> tuple[str, str]:
    """(os_token, arch) parsed from ZIG_TARGET '<arch>-<os>[-<abi>]' if set, else the host."""
    if not target:
        return _host_os(), platform.machine().lower()
    parts = target.split("-")
    arch = parts[0]
    os_tok = parts[1] if len(parts) > 1 else "linux"
    if os_tok.startswith("win"):
        os_tok = "windows"
    elif os_tok in ("macos", "darwin", "ios"):
        os_tok = "macos"
    else:
        os_tok = "linux"
    return os_tok, arch


def _libname(os_tok: str) -> str:
    prefix, suffix, _ = _LIB_BY_OS[os_tok]
    return f"{prefix}zigfitsio_capi{suffix}"


class ZigSharedLibraryHook(BuildHookInterface):
    PLUGIN_NAME = "zig"

    def initialize(self, version, build_data):  # noqa: D401
        if self.target_name != "wheel":
            return

        repo = Path(self.root).resolve()
        target = os.environ.get("ZIG_TARGET")
        os_tok, arch = _resolve_target(target)
        libname = _libname(os_tok)
        subdir = _LIB_BY_OS[os_tok][2]
        self._build(repo)

        src = repo / "zig-out" / subdir / libname
        if not src.exists():
            raise RuntimeError(f"`zig build capi` did not produce {src}")

        pkg_dir = repo / "bindings" / "python" / "src" / "zigfitsio"
        dest = pkg_dir / libname
        shutil.copy2(src, dest)

        build_data["pure_python"] = False
        build_data.setdefault("force_include", {})[str(dest)] = f"zigfitsio/{libname}"
        if target:  # cross-compile: derive the wheel tag from the target, not the host interpreter
            plat = _WHEEL_PLAT.get((os_tok, arch))
            if plat is None:
                raise RuntimeError(f"no wheel platform tag mapping for ZIG_TARGET={target!r}")
            build_data["tag"] = f"py3-none-{plat}"
        else:
            build_data["infer_tag"] = True

    def _build(self, repo: Path) -> None:
        args = ["build", "capi", "-Doptimize=ReleaseFast"]
        target = os.environ.get("ZIG_TARGET")
        if not target and _host_os() == "macos":
            # A native macOS build stamps the dylib's minimum OS version with the *host*
            # version (e.g. 15.x on the CI runner). delocate then rejects it against the
            # macosx_11_0_* wheel tag ("dependencies do not satisfy target MacOS version").
            # Pin it to the wheel's floor so the dylib fits — same arch, so still not a
            # cross-compile (the tag stays interpreter-inferred).
            zig_arch = "aarch64" if platform.machine().lower() in ("arm64", "aarch64") else "x86_64"
            minver = os.environ.get("MACOSX_DEPLOYMENT_TARGET", "11.0")
            target = f"{zig_arch}-macos.{minver}"
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
