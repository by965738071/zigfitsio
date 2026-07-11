#!/usr/bin/env python3
"""Install a generated API bundle into a cloned GitHub Wiki safely.

This script deliberately knows nothing about Git authentication.  The workflow
clones the Wiki with a short-lived token, this script updates only files owned by
the generated manifest, and ordinary ``git`` commands commit/push the result.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
from typing import Any


MANIFEST_NAME = ".generated-api-manifest.json"
BUNDLE_METADATA_FILES = frozenset(
    {
        MANIFEST_NAME,
        "zig-api-symbols.json",
        "python-symbols.json",
        "typescript-api-manifest.json",
        "typescript-api-coverage.json",
    }
)
MARKER_PREFIX = "<!-- zigfitsio-api-reference:"
BOOTSTRAP_MARKER = "<!-- zigfitsio-api-wiki-bootstrap -->"
_SAFE_FILE = re.compile(r"^[A-Za-z0-9_.-]+\.md$")
_SEMVER = re.compile(
    r"^v?(?P<major>0|[1-9]\d*)\."
    r"(?P<minor>0|[1-9]\d*)\."
    r"(?P<patch>0|[1-9]\d*)"
    r"(?:-(?P<pre>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


class BundleError(RuntimeError):
    """The bundle or destination Wiki violates a publication invariant."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _prerelease_key(value: str | None) -> tuple[tuple[int, int | str], ...]:
    # A release sorts after every prerelease of the same numeric version.
    if value is None:
        return ((2, ""),)
    result: list[tuple[int, int | str]] = []
    for item in value.split("."):
        if item.isdigit():
            result.append((0, int(item)))
        else:
            result.append((1, item))
    return tuple(result)


def semver_key(value: str) -> tuple[int, int, int, tuple[tuple[int, int | str], ...]]:
    match = _SEMVER.fullmatch(value)
    if not match:
        raise BundleError(f"not a supported SemVer release: {value!r}")
    return (
        int(match.group("major")),
        int(match.group("minor")),
        int(match.group("patch")),
        _prerelease_key(match.group("pre")),
    )


def _load_manifest(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BundleError(f"cannot read manifest {path}: {exc}") from exc
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise BundleError(f"unsupported generated manifest schema in {path}")
    for key in ("version", "tag", "sha", "files"):
        if key not in value:
            raise BundleError(f"manifest {path} has no {key!r}")
    if not isinstance(value["files"], list) or not value["files"]:
        raise BundleError("manifest files must be a non-empty list")
    if len(value["files"]) > 1000:
        raise BundleError("manifest declares more than 1000 managed pages")
    if not isinstance(value["sha"], str) or not re.fullmatch(r"[0-9a-f]{40}", value["sha"]):
        raise BundleError("manifest sha must be a lowercase 40-character commit SHA")
    if value["tag"] != f"v{value['version']}":
        raise BundleError("manifest tag must equal 'v' plus manifest version")
    semver_key(value["version"])
    return value


def _entries(manifest: dict[str, Any], bundle: Path | None = None) -> dict[str, str]:
    result: dict[str, str] = {}
    for entry in manifest["files"]:
        if not isinstance(entry, dict):
            raise BundleError("every manifest file entry must be an object")
        name = entry.get("path")
        digest = entry.get("sha256")
        if not isinstance(name, str) or not _SAFE_FILE.fullmatch(name):
            raise BundleError(f"unsafe or non-Markdown managed filename: {name!r}")
        if name in result:
            raise BundleError(f"duplicate managed filename: {name}")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BundleError(f"invalid sha256 for {name}")
        if bundle is not None:
            source = bundle / name
            if not source.is_file() or source.is_symlink():
                raise BundleError(f"managed page is missing or not a regular file: {source}")
            actual = _sha256(source)
            if actual != digest:
                raise BundleError(f"sha256 mismatch for {name}: expected {digest}, got {actual}")
        result[name] = digest
    return result


def _bundle_file_names(bundle: Path) -> set[str]:
    if bundle.is_symlink() or not bundle.is_dir():
        raise BundleError(f"bundle must be a normal directory: {bundle}")
    names: set[str] = set()
    for entry in bundle.iterdir():
        if entry.is_symlink() or not entry.is_file():
            raise BundleError(f"bundle contains a non-regular file: {entry}")
        names.add(entry.name)
    return names


def install_bundle(
    bundle: Path,
    wiki: Path,
    *,
    allow_downgrade: bool = False,
    expected_tag: str | None = None,
    expected_sha: str | None = None,
    expected_version: str | None = None,
    expected_repository: str | None = None,
) -> dict[str, Any]:
    """Install ``bundle`` into ``wiki`` and return publication state.

    Files not listed by the previous generated manifest are never touched.
    """

    bundle_files = _bundle_file_names(bundle)
    bundle = bundle.resolve()
    wiki = wiki.resolve()
    if bundle == wiki:
        raise BundleError("bundle and Wiki checkout must be different directories")
    new_manifest_path = bundle / MANIFEST_NAME
    new_manifest = _load_manifest(new_manifest_path)
    new_files = _entries(new_manifest, bundle)
    expected_bundle_files = set(new_files) | BUNDLE_METADATA_FILES
    if bundle_files != expected_bundle_files:
        missing = sorted(expected_bundle_files - bundle_files)
        unexpected = sorted(bundle_files - expected_bundle_files)
        raise BundleError(
            f"bundle layout mismatch: missing={missing}, unexpected={unexpected}"
        )
    expected = {
        "tag": expected_tag,
        "sha": expected_sha,
        "version": expected_version,
        "repository": expected_repository,
    }
    for key, value in expected.items():
        if value is not None and new_manifest.get(key) != value:
            raise BundleError(
                f"bundle {key} does not match the trusted release gate: "
                f"expected {value!r}, got {new_manifest.get(key)!r}"
            )
    for name in new_files:
        source = bundle / name
        if source.stat().st_size > 2 * 1024 * 1024:
            raise BundleError(f"managed Wiki page exceeds 2 MiB: {source}")
        try:
            prefix = source.read_text(encoding="utf-8")[:300]
        except UnicodeDecodeError as exc:
            raise BundleError(f"managed Wiki page is not UTF-8: {source}") from exc
        if (
            not prefix.startswith(MARKER_PREFIX)
            or new_manifest["tag"] not in prefix
            or new_manifest["sha"] not in prefix
        ):
            raise BundleError(f"managed Wiki page lacks matching release provenance: {source}")

    if not wiki.is_dir():
        raise BundleError(f"Wiki checkout does not exist: {wiki}")

    old_manifest_path = wiki / MANIFEST_NAME
    if old_manifest_path.is_symlink() or (
        old_manifest_path.exists() and not old_manifest_path.is_file()
    ):
        raise BundleError(f"refusing unsafe Wiki manifest path: {old_manifest_path}")
    old_manifest: dict[str, Any] | None = None
    old_files: dict[str, str] = {}
    if old_manifest_path.exists():
        old_manifest = _load_manifest(old_manifest_path)
        old_files = _entries(old_manifest)
        if old_manifest.get("repository") != new_manifest.get("repository"):
            raise BundleError("existing Wiki manifest belongs to a different repository")

    # Validate every destination before changing anything. In particular, never follow a
    # Wiki-controlled symlink and never overwrite a hand-written page newly claimed by a
    # later generator version. Home.md is the documented first-run bootstrap exception.
    for name in sorted(set(old_files) | set(new_files)):
        target = wiki / name
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise BundleError(f"refusing unsafe managed Wiki path: {target}")
        if target.exists() and name not in old_files:
            first_run_home = (
                old_manifest is None
                and name == "Home.md"
                and BOOTSTRAP_MARKER in target.read_text(encoding="utf-8")
            )
            if not first_run_home:
                raise BundleError(f"refusing to overwrite hand-written Wiki page: {target}")

    # An edited ownership manifest must not be able to delete an unrelated manual page.
    for name, digest in old_files.items():
        target = wiki / name
        if not target.exists():
            raise BundleError(f"managed Wiki page is missing: {target}")
        if _sha256(target) != digest:
            raise BundleError(f"managed Wiki page was edited outside automation: {target}")
        prefix = target.read_text(encoding="utf-8")[:300]
        if (
            not prefix.startswith(MARKER_PREFIX)
            or old_manifest["tag"] not in prefix
            or old_manifest["sha"] not in prefix
        ):
            raise BundleError(f"managed Wiki page lacks the ownership marker: {target}")

    # Trust the existing version only after proving its manifest still matches every page.
    # This prevents a Wiki edit to the manifest alone from pinning an arbitrarily high version.
    if old_manifest is not None:
        old_key = semver_key(old_manifest["version"])
        new_key = semver_key(new_manifest["version"])
        if new_key < old_key and not allow_downgrade:
            return {
                "changed": False,
                "skipped": True,
                "reason": "newer-version-already-published",
                "currentVersion": old_manifest["version"],
                "requestedVersion": new_manifest["version"],
            }
        if (
            new_manifest["version"] == old_manifest["version"]
            and new_manifest["sha"] != old_manifest["sha"]
        ):
            raise BundleError(
                "refusing same-version publication from a different commit: "
                f"{old_manifest['sha']} != {new_manifest['sha']}"
            )

    before: dict[str, str | None] = {
        name: _sha256(wiki / name) if (wiki / name).is_file() else None
        for name in set(old_files) | set(new_files)
    }

    for name in sorted(set(old_files) - set(new_files)):
        target = wiki / name
        if target.exists():
            if target.is_symlink() or not target.is_file():
                raise BundleError(f"refusing to remove non-regular managed path: {target}")
            target.unlink()

    for name in sorted(new_files):
        shutil.copyfile(bundle / name, wiki / name)

    shutil.copyfile(new_manifest_path, old_manifest_path)

    after: dict[str, str | None] = {
        name: _sha256(wiki / name) if (wiki / name).is_file() else None
        for name in set(old_files) | set(new_files)
    }
    manifest_changed = (
        old_manifest_path.read_bytes() != new_manifest_path.read_bytes()
        if old_manifest_path.resolve() != new_manifest_path.resolve()
        else False
    )
    # copyfile above makes the byte comparison equal, so compare the loaded values instead.
    manifest_changed = old_manifest != new_manifest
    return {
        "changed": before != after or manifest_changed,
        "skipped": False,
        "reason": "installed",
        "version": new_manifest["version"],
        "tag": new_manifest["tag"],
        "sha": new_manifest["sha"],
        "managedPages": len(new_files),
    }


def _write_github_output(path: str | None, state: dict[str, Any]) -> None:
    if not path:
        return
    with Path(path).open("a", encoding="utf-8") as handle:
        for key in ("changed", "skipped", "reason", "version", "tag", "sha"):
            if key in state:
                value = state[key]
                if isinstance(value, bool):
                    value = str(value).lower()
                handle.write(f"{key}={value}\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--wiki", type=Path, required=True)
    parser.add_argument("--allow-downgrade", action="store_true")
    parser.add_argument("--expected-tag", required=True)
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-repository", required=True)
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    args = parser.parse_args(argv)
    try:
        state = install_bundle(
            args.bundle,
            args.wiki,
            allow_downgrade=args.allow_downgrade,
            expected_tag=args.expected_tag,
            expected_sha=args.expected_sha,
            expected_version=args.expected_version,
            expected_repository=args.expected_repository,
        )
    except BundleError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    _write_github_output(args.github_output, state)
    print(json.dumps(state, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
