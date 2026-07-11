from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from release_gate import (
    GateError,
    PYTHON_WORKFLOW,
    _event_release,
    _write_outputs,
    evaluate_runs,
    select_workflow_runs,
)


TAG = "v1.2.3"
SHA = "a" * 40


def run(path: str, *, status: str = "completed", conclusion: str | None = "success", ident: int = 1):
    return {
        "path": path,
        "event": "push",
        "head_branch": TAG,
        "head_sha": SHA,
        "status": status,
        "conclusion": conclusion,
        "run_attempt": 1,
        "id": ident,
    }


class ReleaseGateTests(unittest.TestCase):
    def test_manual_dispatch_extracts_tag_without_sha(self) -> None:
        event = {
            "inputs": {"tag": TAG},
            "repository": {"full_name": "owner/repo"},
        }
        self.assertEqual(_event_release(event), ("owner/repo", TAG, ""))

    def test_waits_for_peer(self) -> None:
        state, selected = evaluate_runs([run(".github/workflows/python-wheels.yml")], TAG, SHA)
        self.assertEqual(state, "waiting")
        self.assertEqual(len(selected), 1)

    def test_waits_for_in_progress_peer(self) -> None:
        runs = [
            run(".github/workflows/python-wheels.yml"),
            run(".github/workflows/typescript.yml", status="in_progress", conclusion=None),
        ]
        self.assertEqual(evaluate_runs(runs, TAG, SHA)[0], "waiting")

    def test_both_success_are_ready(self) -> None:
        runs = [
            run(".github/workflows/python-wheels.yml"),
            run(".github/workflows/typescript.yml"),
        ]
        self.assertEqual(evaluate_runs(runs, TAG, SHA)[0], "ready")

    def test_completed_failure_is_rejected(self) -> None:
        runs = [
            run(".github/workflows/python-wheels.yml"),
            run(".github/workflows/typescript.yml", conclusion="failure"),
        ]
        with self.assertRaises(GateError):
            evaluate_runs(runs, TAG, SHA)

    def test_ignores_other_tag_and_chooses_newest_run(self) -> None:
        old = run(".github/workflows/python-wheels.yml", conclusion="failure", ident=1)
        old["run_attempt"] = 1
        newest = run(".github/workflows/python-wheels.yml", ident=2)
        newest["run_attempt"] = 2
        other = run(".github/workflows/typescript.yml", ident=3)
        wrong_tag = run(".github/workflows/typescript.yml", ident=4)
        wrong_tag["head_branch"] = "v9.9.9"
        selected = select_workflow_runs([old, newest, other, wrong_tag], TAG, SHA)
        self.assertEqual(selected[".github/workflows/python-wheels.yml"]["id"], 2)

    def test_old_rerun_does_not_outrank_newer_run(self) -> None:
        old = run(".github/workflows/python-wheels.yml", conclusion="failure", ident=10)
        old["run_attempt"] = 9
        newest = run(".github/workflows/python-wheels.yml", ident=11)
        selected = select_workflow_runs([old, newest], TAG, SHA)
        self.assertEqual(selected[".github/workflows/python-wheels.yml"]["id"], 11)

    def test_writes_verified_python_run_id_for_artifact_download(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            output = Path(td) / "outputs"
            _write_outputs(
                str(output),
                {
                    "ready": True,
                    "tag": TAG,
                    "sha": SHA,
                    "workflowRunIds": {PYTHON_WORKFLOW: 123456},
                },
            )
            self.assertIn("python_run_id=123456\n", output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
