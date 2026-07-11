#!/usr/bin/env python3
"""Generate and validate the complete release-versioned GitHub Wiki bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Iterable
from urllib.parse import unquote


REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_NAME = ".generated-api-manifest.json"
MARKER_PREFIX = "<!-- zigfitsio-api-reference:"
_SHA = re.compile(r"^[0-9a-f]{40}$")
_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_SAFE_PAGE = re.compile(r"^[A-Za-z0-9_.-]+\.md$")
_MD_LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+['\"][^'\"]*['\"])?\)")
_WIKI_LINK = re.compile(r"\[\[([^\]]+)\]\]")


class WikiGenerationError(RuntimeError):
    """A generator or bundle invariant failed."""


def _run(command: list[str], *, cwd: Path = REPO_ROOT) -> None:
    print("+ " + " ".join(command), flush=True)
    try:
        subprocess.run(command, cwd=cwd, check=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise WikiGenerationError(f"command failed: {' '.join(command)}") from exc


def _read_versions() -> dict[str, str]:
    zon = (REPO_ROOT / "build.zig.zon").read_text(encoding="utf-8")
    zig = (REPO_ROOT / "src/version.zig").read_text(encoding="utf-8")
    pyproject = (REPO_ROOT / "pyproject.toml").read_text(encoding="utf-8")
    package = json.loads((REPO_ROOT / "bindings/typescript/package.json").read_text(encoding="utf-8"))
    lock = json.loads((REPO_ROOT / "bindings/typescript/package-lock.json").read_text(encoding="utf-8"))

    def match(pattern: str, text: str, label: str) -> str:
        found = re.search(pattern, text, re.MULTILINE)
        if not found:
            raise WikiGenerationError(f"could not parse version from {label}")
        return found.group(1)

    versions = {
        "build.zig.zon": match(r'\.version\s*=\s*"([^"]+)"', zon, "build.zig.zon"),
        "src/version.zig": match(r'version_string\s*=\s*"([^"]+)"', zig, "src/version.zig"),
        "pyproject.toml": match(r'^version\s*=\s*"([^"]+)"', pyproject, "pyproject.toml"),
        "package.json": str(package.get("version", "")),
        "package-lock.json": str(lock.get("version", "")),
        "package-lock root": str((lock.get("packages", {}).get("", {}) or {}).get("version", "")),
    }
    unique = set(versions.values())
    if len(unique) != 1 or "" in unique:
        raise WikiGenerationError(
            "release versions disagree: "
            + ", ".join(f"{name}={value!r}" for name, value in versions.items())
        )
    return versions


def _prepare_output(output: Path) -> Path:
    output = output.resolve()
    if output in {Path("/").resolve(), REPO_ROOT.resolve()} or output in REPO_ROOT.resolve().parents:
        raise WikiGenerationError(f"refusing unsafe output directory: {output}")
    if output.is_relative_to(REPO_ROOT.resolve()) and not output.is_relative_to(
        (REPO_ROOT / "zig-out").resolve()
    ):
        raise WikiGenerationError(
            "output inside the source tree is allowed only below zig-out; use a temporary "
            f"directory instead of {output}"
        )
    if output.exists():
        if output.is_symlink() or not output.is_dir():
            raise WikiGenerationError(f"output must be a normal directory: {output}")
        if any(output.iterdir()):
            raise WikiGenerationError(
                f"refusing to delete or overwrite non-empty output directory: {output}"
            )
    else:
        output.mkdir(parents=True)
    return output


def _stamp_pages(output: Path, tag: str, sha: str, repository: str) -> None:
    marker = f"{MARKER_PREFIX} tag={tag} sha={sha}; do not edit -->\n\n"
    for page in sorted(output.glob("*.md")):
        text = page.read_text(encoding="utf-8")
        if not text.startswith(MARKER_PREFIX):
            page.write_text(marker + text, encoding="utf-8")


def _common_pages(output: Path, version: str, tag: str, sha: str, repository: str) -> None:
    source = f"https://github.com/{repository}/tree/{sha}"
    release = f"https://github.com/{repository}/releases/tag/{tag}"
    generated = (
        f"> Generated from [`{tag}`]({release}) at commit "
        f"[`{sha}`]({source}). Do not edit this page manually.\n"
    )
    pages = {
        "Home.md": (
            f"# zigfitsio {version}\n\n{generated}\n"
            "The Wiki contains the public API shipped in this release. Choose a language:\n\n"
            "- [[Zig API|Zig-API]]\n"
            "- [[Python API|Python-API]]\n"
            "- [[TypeScript API|TypeScript-API]]\n\n"
            "See [[API reference policy|API-Reference]] for the exact public boundaries.\n"
        ),
        "API-Reference.md": (
            f"# API reference policy\n\n{generated}\n"
            "The reference is generated from consumer-visible entry points, rather than every "
            "source file:\n\n"
            "- **Zig:** declarations reachable from `src/root.zig`.\n"
            "- **Python:** `zigfitsio.__all__`, its public class members, and the explicit "
            "`zigfitsio.lowlevel` contract.\n"
            "- **TypeScript:** the `zigfitsio` and `zigfitsio/lowlevel` package entry points.\n\n"
            "The Python and TypeScript low-level pages also enumerate every runtime `zf_*` ABI "
            "prototype and are checked against `bindings/c/zigfitsio.h`.\n"
        ),
        "_Sidebar.md": (
            "### API reference\n\n"
            "- [[Home]]\n"
            "- [[Reference policy|API-Reference]]\n"
            "- [[Zig|Zig-API]]\n"
            "- [[Python|Python-API]]\n"
            "  - [[Low-level Python API|Python-API-Low-Level]]\n"
            "- [[TypeScript|TypeScript-API]]\n"
            "  - [[Low-level TypeScript API|TypeScript-API-Low-Level]]\n"
            "  - [[Dynamic ABI prototypes|TypeScript-API-Low-Level-Prototypes]]\n"
        ),
        "_Footer.md": f"zigfitsio {version} · `{tag}` · `{sha}` · generated API reference\n",
    }
    for name, body in pages.items():
        (output / name).write_text(body, encoding="utf-8")


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise WikiGenerationError(f"invalid generator manifest {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise WikiGenerationError(f"generator manifest is not an object: {path}")
    return value


def _walk_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _walk_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _walk_strings(item)


def _zf_symbols(value: Any) -> set[str]:
    result: set[str] = set()
    for item in _walk_strings(value):
        for found in re.findall(r"(?:^|\.)(zf_[A-Za-z0-9_]+)$", item):
            result.add(found)
    return result


_C_SCALARS = {
        "void": "void",
        "int": "int",
        "uint32_t": "u32",
        "int64_t": "i64",
        "long long": "i64",
        "uint64_t": "u64",
        "float": "f32",
        "double": "f64",
        "long": "long",
        "size_t": "usize",
}


def _c_type_parts(value: str) -> tuple[str, int]:
    value = re.sub(r"\bconst\b", "", value)
    value = " ".join(value.replace("\t", " ").split())
    depth = value.count("*")
    base = " ".join(value.replace("*", " ").split())
    return base, depth


def _c_scalar(value: str) -> str:
    try:
        return _C_SCALARS[value]
    except KeyError as exc:
        raise WikiGenerationError(f"unsupported C ABI type in zigfitsio.h: {value!r}") from exc


def _raw_header_zf_prototypes() -> list[dict[str, Any]]:
    header = (REPO_ROOT / "bindings/c/zigfitsio.h").read_text(encoding="utf-8")
    header = re.sub(r"/\*.*?\*/", "", header, flags=re.DOTALL)
    declarations = re.compile(
        r"^[ \t]*(?P<returns>[A-Za-z_][A-Za-z0-9_ \t]*?(?:[ \t]*\*)?)"
        r"[ \t]*(?P<name>zf_[A-Za-z0-9_]+)[ \t]*\((?P<args>.*?)\)[ \t]*;",
        re.MULTILINE | re.DOTALL,
    )
    result: list[dict[str, Any]] = []
    for match in declarations.finditer(header):
        raw_args = match.group("args").strip()
        args: list[str] = []
        if raw_args and raw_args != "void":
            for raw_arg in raw_args.split(","):
                raw_arg = " ".join(raw_arg.split())
                if "*" in raw_arg:
                    arg_type = raw_arg.rsplit("*", 1)[0] + "*"
                else:
                    arg_type = raw_arg.rsplit(" ", 1)[0]
                args.append(arg_type)
        result.append(
            {
                "name": match.group("name"),
                "returns": match.group("returns"),
                "args": args,
            }
        )
    names = [item["name"] for item in result]
    if not result or len(names) != len(set(names)):
        raise WikiGenerationError("could not parse a unique ordered C ABI from zigfitsio.h")
    return result


def _header_python_abi() -> list[dict[str, Any]]:
    """Map C declarations to the exact ctypes shapes used by lowlevel._PROTOS."""

    pointer_scalars = {
        "size_t": "size_ptr",
        "uint64_t": "u64_ptr",
        "long": "long_ptr",
        "long long": "i64_ptr",
        "int64_t": "i64_ptr",
        "int": "int_ptr",
        "double": "f64_ptr",
        "float": "f32_ptr",
    }

    def normalize(
        value: str, *, returns: bool = False, function: str = "", index: int = -1
    ) -> str:
        base, depth = _c_type_parts(value)
        if depth == 0:
            return _c_scalar(base)
        if returns and base == "char" and depth == 1:
            return "cstring_ret"
        if function == "zf_free" and index == 0:
            return "void_ptr"
        if base == "char":
            return "char_ptr" if depth == 1 else "char_ptr_ptr" if depth == 2 else ""
        if base == "uint8_t":
            return "char_ptr" if depth == 1 else "void_ptr_ptr" if depth == 2 else ""
        if base == "ZfColInfo" and depth == 1:
            return "col_info_ptr"
        if base in {"void", "ZfFits", "ZfTable", "ZfFindings", "ZfOpenOpts", "ZfScaling"}:
            return "void_ptr" if depth == 1 else "void_ptr_ptr" if depth == 2 else ""
        if depth == 1 and base in pointer_scalars:
            return pointer_scalars[base]
        raise WikiGenerationError(f"unsupported C pointer shape for Python: {value!r}")

    result: list[dict[str, Any]] = []
    for prototype in _raw_header_zf_prototypes():
        name = prototype["name"]
        result.append(
            {
                "name": name,
                "returns": normalize(prototype["returns"], returns=True, function=name),
                "args": [
                    normalize(value, function=name, index=index)
                    for index, value in enumerate(prototype["args"])
                ],
            }
        )
    return result


def _header_typescript_abi() -> list[dict[str, Any]]:
    """Map C declarations to the semantic neutral-FFI categories used by TypeScript."""

    result: list[dict[str, Any]] = []
    handles = {"ZfFits", "ZfTable", "ZfFindings"}
    for prototype in _raw_header_zf_prototypes():
        name = prototype["name"]

        def normalize(value: str, *, returns: bool = False, index: int = -1) -> str:
            base, depth = _c_type_parts(value)
            if depth == 0:
                return _c_scalar(base)
            if returns and base == "char" and depth == 1:
                return "cstring_ret"
            if name == "zf_free" and index == 0:
                return "handle"
            if base in handles and depth == 1:
                return "handle"
            if base == "char" and depth == 1:
                return "cstr"
            if base == "char" and depth == 2:
                return "cstr_arr"
            return "buf"

        result.append(
            {
                "name": name,
                "returns": normalize(prototype["returns"], returns=True),
                "args": [normalize(value, index=index) for index, value in enumerate(prototype["args"])],
            }
        )
    return result


def _header_zf_prototypes() -> list[dict[str, Any]]:
    """Return the ordered, semantically typed C ABI used by the TypeScript bridge."""

    return _header_typescript_abi()


def _header_zf_symbols() -> set[str]:
    return {item["name"] for item in _header_zf_prototypes()}


def _normalize_python_abi(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    scalar_types = {
        "INT": "int", "U32": "u32", "I64": "i64", "LL": "i64", "U64": "u64",
        "FLT": "f32", "DBL": "f64", "LONG": "long", "SZ": "usize",
    }
    pointer_types = {
        "CHARP": "char_ptr",
        "VOID": "void_ptr",
        "PVOID": "void_ptr_ptr",
        "PSZ": "size_ptr",
        "PU64": "u64_ptr",
        "PLONG": "long_ptr",
        "PINT": "int_ptr",
        "PLL": "i64_ptr",
        "PDBL": "f64_ptr",
        "PCHARP": "char_ptr_ptr",
        "ctypes.POINTER(ZfColInfo)": "col_info_ptr",
        "_c.POINTER(ZfColInfo)": "col_info_ptr",
    }

    def normalize(value: Any, *, returns: bool = False) -> str:
        if value is None or value == "None":
            return "void"
        if returns and value == "CHARP":
            return "cstring_ret"
        if isinstance(value, str) and value in pointer_types:
            return pointer_types[value]
        if isinstance(value, str) and value in scalar_types:
            return scalar_types[value]
        raise WikiGenerationError(f"unsupported Python ctypes ABI type: {value!r}")

    raw = manifest.get("abi_prototypes")
    if not isinstance(raw, list):
        raise WikiGenerationError("Python manifest has no structured ABI prototypes")
    result: list[dict[str, Any]] = []
    for prototype in raw:
        if not isinstance(prototype, dict) or not isinstance(prototype.get("args"), list):
            raise WikiGenerationError("Python manifest contains an invalid ABI prototype")
        result.append(
            {
                "name": prototype.get("name"),
                "returns": normalize(prototype.get("returns"), returns=True),
                "args": [normalize(value) for value in prototype["args"]],
            }
        )
    return result


def _normalize_typescript_abi(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    def normalize(value: Any) -> str:
        if value in {
            "void", "int", "u32", "i64", "u64", "f32", "f64", "long", "usize",
            "handle", "buf", "cstr", "cstr_arr", "cstring_ret",
        }:
            return str(value)
        raise WikiGenerationError(f"unsupported TypeScript neutral ABI type: {value!r}")

    symbols = manifest.get("symbols")
    raw = symbols.get("dynamicPrototypes") if isinstance(symbols, dict) else None
    if not isinstance(raw, list):
        raise WikiGenerationError("TypeScript manifest has no structured ABI prototypes")
    result: list[dict[str, Any]] = []
    for prototype in raw:
        native = prototype.get("nativeIR") if isinstance(prototype, dict) else None
        if not isinstance(native, dict) or not isinstance(native.get("args"), list):
            raise WikiGenerationError("TypeScript manifest contains an invalid ABI prototype")
        result.append(
            {
                "name": prototype.get("name"),
                "returns": normalize(native.get("returns")),
                "args": [normalize(value) for value in native["args"]],
            }
        )
    return result


def _assert_abi_equal(
    expected: list[dict[str, Any]], actual: list[dict[str, Any]], language: str
) -> None:
    if expected == actual:
        return
    limit = max(len(expected), len(actual))
    for index in range(limit):
        left = expected[index] if index < len(expected) else None
        right = actual[index] if index < len(actual) else None
        if left != right:
            raise WikiGenerationError(
                f"{language}/C ABI documentation drift at prototype {index}: "
                f"expected={left!r}, documented={right!r}"
            )
    raise WikiGenerationError(f"{language}/C ABI documentation drift")


def _symbol_count(value: Any) -> int:
    if isinstance(value, list):
        return sum(1 for item in value if isinstance(item, dict))
    if isinstance(value, dict):
        return sum(_symbol_count(item) for item in value.values())
    return 0


def _validate_metadata(output: Path, tag: str, sha: str) -> dict[str, Any]:
    paths = {
        "zig": output / "zig-api-symbols.json",
        "python": output / "python-symbols.json",
        "typescript": output / "typescript-api-manifest.json",
    }
    manifests = {name: _load_json(path) for name, path in paths.items()}
    for name, manifest in manifests.items():
        serialized = json.dumps(manifest, sort_keys=True)
        if tag not in serialized or sha not in serialized:
            raise WikiGenerationError(f"{name} manifest lacks release tag/SHA provenance")
        symbols = manifest.get("symbols")
        if _symbol_count(symbols) == 0:
            raise WikiGenerationError(f"{name} manifest contains no public symbols")
        missing = manifest.get("coverage", {}).get("missing", []) if isinstance(manifest.get("coverage"), dict) else []
        if missing:
            raise WikiGenerationError(f"{name} generator reports missing symbols: {missing}")

    _assert_abi_equal(
        _header_python_abi(), _normalize_python_abi(manifests["python"]), "Python"
    )
    _assert_abi_equal(
        _header_typescript_abi(),
        _normalize_typescript_abi(manifests["typescript"]),
        "TypeScript",
    )
    ts_coverage = _load_json(output / "typescript-api-coverage.json")
    if ts_coverage.get("valid") is not True:
        raise WikiGenerationError("TypeScript documentation coverage is not valid")
    for section in ("typedocSymbols", "dynamicPrototypes"):
        details = ts_coverage.get(section, {})
        if details.get("missing") or details.get("duplicates"):
            raise WikiGenerationError(f"TypeScript {section} coverage failed: {details}")
    return manifests


def _link_target(raw: str) -> str | None:
    target = unquote(raw.split("#", 1)[0].split("?", 1)[0])
    if not target or target.startswith(("#", "http://", "https://", "mailto:", "tel:")):
        return None
    if target.startswith("./"):
        target = target[2:]
    return target


def _markdown_anchors(text: str) -> set[str]:
    anchors = {
        match.lower()
        for match in re.findall(r'<a\s+(?:id|name)=["\']([^"\']+)["\']', text, re.IGNORECASE)
    }
    counts: dict[str, int] = {}
    for heading in re.findall(r"^#{1,6}\s+(.+?)\s*#*$", text, re.MULTILINE):
        heading = re.sub(r"\\(.)", r"\1", heading)
        heading = re.sub(r"<[^>]+>", "", heading)
        heading = re.sub(r"[`*~]", "", heading).strip().lower()
        base = re.sub(r"[^\w\- ]", "", heading)
        base = re.sub(r" +", "-", base)
        count = counts.get(base, 0)
        counts[base] = count + 1
        anchors.add(base if count == 0 else f"{base}-{count}")
    return anchors


def _validate_pages(output: Path, tag: str, sha: str) -> list[Path]:
    required = {
        "Home.md", "API-Reference.md", "Zig-API.md", "Python-API.md",
        "Python-API-Low-Level.md", "TypeScript-API.md", "TypeScript-API-Low-Level.md",
        "TypeScript-API-Low-Level-Prototypes.md", "_Sidebar.md", "_Footer.md",
    }
    pages = sorted(output.glob("*.md"))
    names = {page.name for page in pages}
    anchors = {
        page.name: _markdown_anchors(page.read_text(encoding="utf-8")) for page in pages
    }
    missing = required - names
    if missing:
        raise WikiGenerationError(f"required Wiki pages are missing: {sorted(missing)}")
    for page in pages:
        if not _SAFE_PAGE.fullmatch(page.name):
            raise WikiGenerationError(f"unsafe Wiki page filename: {page.name}")
        if page.stat().st_size > 2 * 1024 * 1024:
            raise WikiGenerationError(f"Wiki page exceeds 2 MiB: {page.name}")
        text = page.read_text(encoding="utf-8")
        if not text.startswith(MARKER_PREFIX) or tag not in text[:300] or sha not in text[:300]:
            raise WikiGenerationError(f"Wiki page lacks generated provenance marker: {page.name}")
        if not re.search(r"^#", text, re.MULTILINE) and page.name not in {"_Sidebar.md", "_Footer.md"}:
            raise WikiGenerationError(f"Wiki page has no heading: {page.name}")
        for raw in _MD_LINK.findall(text):
            target = _link_target(raw)
            if target is None:
                if raw.startswith("#"):
                    candidate = page.name
                else:
                    continue
            else:
                candidate = Path(target).name
                if not candidate.endswith(".md"):
                    candidate += ".md"
            if candidate not in names:
                raise WikiGenerationError(f"unresolved link in {page.name}: {raw}")
            if "#" in raw:
                fragment = unquote(raw.split("#", 1)[1]).lower()
                if fragment and fragment not in anchors[candidate]:
                    raise WikiGenerationError(
                        f"unresolved link fragment in {page.name}: {raw}"
                    )
        for raw in _WIKI_LINK.findall(text):
            target = raw.rsplit("|", 1)[-1].strip()
            if target.startswith(("http://", "https://")):
                continue
            target, _, fragment = target.partition("#")
            candidate = target if target.endswith(".md") else target + ".md"
            if candidate not in names:
                raise WikiGenerationError(f"unresolved Wiki link in {page.name}: {raw}")
            if fragment and unquote(fragment).lower() not in anchors[candidate]:
                raise WikiGenerationError(
                    f"unresolved Wiki link fragment in {page.name}: {raw}"
                )
    return pages


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generate(output: Path, tag: str, sha: str, repository: str) -> dict[str, Any]:
    if not _SHA.fullmatch(sha):
        raise WikiGenerationError("--sha must be a lowercase 40-character commit SHA")
    if not _REPOSITORY.fullmatch(repository):
        raise WikiGenerationError("--repository must be an owner/name GitHub slug")
    versions = _read_versions()
    version = next(iter(versions.values()))
    if tag != f"v{version}":
        raise WikiGenerationError(f"tag {tag!r} does not match project version {version!r}")
    output = _prepare_output(output)
    repository_url = f"https://github.com/{repository}"

    _run(["zig", "build", "docs"])
    _run([
        "zig", "build", "wiki-zig", "--", str(output), "--tag", tag,
        "--sha", sha, "--repo-url", repository_url, "--strict-docs",
    ])
    _run([
        sys.executable, "tools/wiki/render_python.py", "--out", str(output),
        "--tag", tag, "--sha", sha, "--repository", repository_url,
    ])
    _run([
        "node", "bindings/typescript/scripts/generate-wiki-docs.mjs",
        "--out", str(output), "--tag", tag, "--sha", sha,
        "--repository", repository,
    ])

    _common_pages(output, version, tag, sha, repository)
    _stamp_pages(output, tag, sha, repository)
    manifests = _validate_metadata(output, tag, sha)
    pages = _validate_pages(output, tag, sha)

    package_lock = json.loads(
        (REPO_ROOT / "bindings/typescript/package-lock.json").read_text(encoding="utf-8")
    )
    packages = package_lock.get("packages", {})
    typedoc = (packages.get("node_modules/typedoc", {}) or {}).get("version", "unknown")
    manifest: dict[str, Any] = {
        "schemaVersion": 1,
        "version": version,
        "tag": tag,
        "sha": sha,
        "repository": repository,
        "files": [{"path": page.name, "sha256": _sha256(page)} for page in pages],
        "languageSymbolCounts": {
            name: _symbol_count(value.get("symbols")) for name, value in sorted(manifests.items())
        },
        "abiFunctionCount": len(_header_zf_symbols()),
        "tools": {
            "zig": "0.16.0",
            "pythonRendererSchema": 1,
            "typedoc": str(typedoc),
        },
    }
    (output / MANIFEST_NAME).write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--repository", default="anhydrous99/zigfitsio")
    args = parser.parse_args(argv)
    try:
        manifest = generate(args.out, args.tag, args.sha, args.repository)
    except (OSError, json.JSONDecodeError, WikiGenerationError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "version": manifest["version"],
                "pages": len(manifest["files"]),
                "languageSymbolCounts": manifest["languageSymbolCounts"],
                "abiFunctionCount": manifest["abiFunctionCount"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
