from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from publish_bundle import (
    BUNDLE_METADATA_FILES,
    BundleError,
    MANIFEST_NAME,
    install_bundle,
    semver_key,
)


def write_bundle(root: Path, version: str, sha: str, pages: dict[str, str]) -> None:
    files = []
    for name, body in pages.items():
        data = (
            f"<!-- zigfitsio-api-reference: tag=v{version} sha={sha}; do not edit -->\n\n"
            + body
        ).encode()
        (root / name).write_bytes(data)
        files.append({"path": name, "sha256": hashlib.sha256(data).hexdigest()})
    manifest = {
        "schemaVersion": 1,
        "version": version,
        "tag": f"v{version}",
        "sha": sha,
        "repository": "owner/repo",
        "files": sorted(files, key=lambda item: item["path"]),
    }
    (root / MANIFEST_NAME).write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
    for name in BUNDLE_METADATA_FILES - {MANIFEST_NAME}:
        (root / name).write_text("{}\n", encoding="utf-8")


class PublishBundleTests(unittest.TestCase):
    def test_semver_release_sorts_after_prerelease(self) -> None:
        self.assertLess(semver_key("1.2.3-rc.1"), semver_key("1.2.3"))
        self.assertLess(semver_key("1.2.3-1"), semver_key("1.2.3-alpha"))

    def test_install_preserves_manual_pages_and_removes_stale_managed_page(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            wiki, first, second = base / "wiki", base / "first", base / "second"
            wiki.mkdir(); first.mkdir(); second.mkdir()
            (wiki / "Manual.md").write_text("keep me", encoding="utf-8")
            write_bundle(first, "1.0.0", "a" * 40, {"Home.md": "one", "Old.md": "old"})
            self.assertTrue(install_bundle(first, wiki)["changed"])
            write_bundle(second, "1.1.0", "b" * 40, {"Home.md": "two", "New.md": "new"})
            self.assertTrue(install_bundle(second, wiki)["changed"])
            self.assertEqual((wiki / "Manual.md").read_text(), "keep me")
            self.assertFalse((wiki / "Old.md").exists())
            self.assertTrue((wiki / "New.md").read_text().endswith("new"))

    def test_idempotent_reinstall_is_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td); wiki = base / "wiki"; bundle = base / "bundle"
            wiki.mkdir(); bundle.mkdir()
            write_bundle(bundle, "1.0.0", "a" * 40, {"Home.md": "same"})
            install_bundle(bundle, wiki)
            self.assertFalse(install_bundle(bundle, wiki)["changed"])

    def test_older_release_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td); wiki = base / "wiki"; newer = base / "newer"; older = base / "older"
            wiki.mkdir(); newer.mkdir(); older.mkdir()
            write_bundle(newer, "2.0.0", "b" * 40, {"Home.md": "new"})
            write_bundle(older, "1.9.9", "a" * 40, {"Home.md": "old"})
            install_bundle(newer, wiki)
            state = install_bundle(older, wiki)
            self.assertTrue(state["skipped"])
            self.assertTrue((wiki / "Home.md").read_text().endswith("new"))

    def test_same_version_different_sha_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td); wiki = base / "wiki"; one = base / "one"; two = base / "two"
            wiki.mkdir(); one.mkdir(); two.mkdir()
            write_bundle(one, "1.0.0", "a" * 40, {"Home.md": "one"})
            write_bundle(two, "1.0.0", "b" * 40, {"Home.md": "two"})
            install_bundle(one, wiki)
            with self.assertRaises(BundleError):
                install_bundle(two, wiki)

    def test_expected_release_metadata_is_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td); wiki = base / "wiki"; bundle = base / "bundle"
            wiki.mkdir(); bundle.mkdir()
            write_bundle(bundle, "1.0.0", "a" * 40, {"Home.md": "one"})
            with self.assertRaises(BundleError):
                install_bundle(bundle, wiki, expected_sha="b" * 40)

    def test_refuses_unexpected_artifact_content(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td); wiki = base / "wiki"; bundle = base / "bundle"
            wiki.mkdir(); bundle.mkdir()
            write_bundle(bundle, "1.0.0", "a" * 40, {"Home.md": "one"})
            (bundle / "unexpected.sh").write_text("echo untrusted", encoding="utf-8")
            with self.assertRaisesRegex(BundleError, "unexpected=.*unexpected[.]sh"):
                install_bundle(bundle, wiki)

    def test_refuses_destination_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td); wiki = base / "wiki"; bundle = base / "bundle"
            wiki.mkdir(); bundle.mkdir()
            outside = base / "outside"; outside.write_text("safe")
            (wiki / "Home.md").symlink_to(outside)
            write_bundle(bundle, "1.0.0", "a" * 40, {"Home.md": "one"})
            with self.assertRaises(BundleError):
                install_bundle(bundle, wiki)
            self.assertEqual(outside.read_text(), "safe")

    def test_refuses_hand_written_home_without_bootstrap_marker(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td); wiki = base / "wiki"; bundle = base / "bundle"
            wiki.mkdir(); bundle.mkdir()
            (wiki / "Home.md").write_text("important manual home")
            write_bundle(bundle, "1.0.0", "a" * 40, {"Home.md": "generated"})
            with self.assertRaises(BundleError):
                install_bundle(bundle, wiki)
            self.assertEqual((wiki / "Home.md").read_text(), "important manual home")

    def test_accepts_explicit_first_run_home_bootstrap(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td); wiki = base / "wiki"; bundle = base / "bundle"
            wiki.mkdir(); bundle.mkdir()
            (wiki / "Home.md").write_text(
                "<!-- zigfitsio-api-wiki-bootstrap -->\n\nPlaceholder."
            )
            write_bundle(bundle, "1.0.0", "a" * 40, {"Home.md": "generated"})
            self.assertTrue(install_bundle(bundle, wiki)["changed"])

    def test_tampered_old_version_cannot_skip_publication(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td); wiki = base / "wiki"; first = base / "first"; second = base / "second"
            wiki.mkdir(); first.mkdir(); second.mkdir()
            write_bundle(first, "1.0.0", "a" * 40, {"Home.md": "one"})
            install_bundle(first, wiki)
            manifest_path = wiki / MANIFEST_NAME
            manifest = json.loads(manifest_path.read_text())
            manifest["version"] = "99.0.0"
            manifest["tag"] = "v99.0.0"
            manifest_path.write_text(json.dumps(manifest))
            write_bundle(second, "1.1.0", "b" * 40, {"Home.md": "two"})
            with self.assertRaises(BundleError):
                install_bundle(second, wiki)


if __name__ == "__main__":
    unittest.main()
