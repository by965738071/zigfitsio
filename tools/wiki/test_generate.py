from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from generate import (
    REPO_ROOT,
    WikiGenerationError,
    _assert_abi_equal,
    _common_pages,
    _header_python_abi,
    _header_typescript_abi,
    _header_zf_prototypes,
    _prepare_output,
    _read_versions,
    _stamp_pages,
    _validate_pages,
)


TAG = "v0.1.5"
SHA = "a" * 40
REPOSITORY = "owner/repo"


class GenerateWikiTests(unittest.TestCase):
    def test_all_project_versions_agree(self) -> None:
        versions = _read_versions()
        self.assertEqual(set(versions.values()), {"0.1.5"})

    def test_c_header_has_ordered_neutral_abi(self) -> None:
        prototypes = _header_zf_prototypes()
        self.assertEqual(len(prototypes), 89)
        self.assertEqual(
            prototypes[0],
            {"name": "zf_version", "returns": "cstring_ret", "args": []},
        )
        self.assertEqual(prototypes[-1]["name"], "zf_write_compressed3")

    def test_abi_models_preserve_pointer_categories(self) -> None:
        python = {item["name"]: item for item in _header_python_abi()}
        typescript = {item["name"]: item for item in _header_typescript_abi()}
        self.assertEqual(python["zf_hdu_count"]["args"], ["void_ptr", "long_ptr"])
        self.assertEqual(
            python["zf_create_tbl"]["args"][-4:],
            ["char_ptr_ptr", "char_ptr_ptr", "char_ptr_ptr", "char_ptr"],
        )
        self.assertEqual(typescript["zf_open_file"]["args"][0], "buf")
        self.assertEqual(typescript["zf_open_file"]["args"][3], "buf")
        self.assertEqual(typescript["zf_create_tbl"]["args"][-4], "cstr_arr")
        self.assertEqual(typescript["zf_create_tbl"]["args"][-1], "cstr")

        wrong = [dict(item) for item in _header_python_abi()]
        wrong[17] = {**wrong[17], "args": ["void_ptr", "i64_ptr"]}
        with self.assertRaises(WikiGenerationError):
            _assert_abi_equal(_header_python_abi(), wrong, "Python")

    def test_common_bundle_has_resolvable_navigation(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            output = Path(td)
            for name in (
                "Zig-API.md",
                "Python-API.md",
                "Python-API-Low-Level.md",
                "TypeScript-API.md",
                "TypeScript-API-Low-Level.md",
                "TypeScript-API-Low-Level-Prototypes.md",
            ):
                (output / name).write_text(f"# {name}\n", encoding="utf-8")
            _common_pages(output, "0.1.5", TAG, SHA, REPOSITORY)
            _stamp_pages(output, TAG, SHA, REPOSITORY)
            pages = _validate_pages(output, TAG, SHA)
            self.assertEqual(len(pages), 10)

    def test_unresolved_local_link_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            output = Path(td)
            for name in (
                "Zig-API.md",
                "Python-API.md",
                "Python-API-Low-Level.md",
                "TypeScript-API.md",
                "TypeScript-API-Low-Level.md",
                "TypeScript-API-Low-Level-Prototypes.md",
            ):
                (output / name).write_text(f"# {name}\n", encoding="utf-8")
            _common_pages(output, "0.1.5", TAG, SHA, REPOSITORY)
            with (output / "Home.md").open("a", encoding="utf-8") as handle:
                handle.write("\n[missing](Does-Not-Exist.md)\n")
            _stamp_pages(output, TAG, SHA, REPOSITORY)
            with self.assertRaises(WikiGenerationError):
                _validate_pages(output, TAG, SHA)

    def test_unresolved_local_fragment_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            output = Path(td)
            for name in (
                "Zig-API.md",
                "Python-API.md",
                "Python-API-Low-Level.md",
                "TypeScript-API.md",
                "TypeScript-API-Low-Level.md",
                "TypeScript-API-Low-Level-Prototypes.md",
            ):
                (output / name).write_text(f"# {name}\n", encoding="utf-8")
            _common_pages(output, "0.1.5", TAG, SHA, REPOSITORY)
            with (output / "Home.md").open("a", encoding="utf-8") as handle:
                handle.write("\n[broken](Python-API.md#not-a-real-heading)\n")
            _stamp_pages(output, TAG, SHA, REPOSITORY)
            with self.assertRaises(WikiGenerationError):
                _validate_pages(output, TAG, SHA)

    def test_refuses_to_clean_source_directory(self) -> None:
        with self.assertRaises(WikiGenerationError):
            _prepare_output(REPO_ROOT / "src" / "definitely-not-an-output-directory")

    def test_refuses_to_clean_unrelated_nonempty_directory(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            output = Path(td)
            marker = output / "keep.txt"
            marker.write_text("do not delete", encoding="utf-8")
            with self.assertRaises(WikiGenerationError):
                _prepare_output(output)
            self.assertEqual(marker.read_text(encoding="utf-8"), "do not delete")


if __name__ == "__main__":
    unittest.main()
