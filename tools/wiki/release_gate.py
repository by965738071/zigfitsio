#!/usr/bin/env python3
"""Gate Wiki publication on both release workflows for one exact tag/SHA."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


EXPECTED_WORKFLOWS = (
    ".github/workflows/python-wheels.yml",
    ".github/workflows/typescript.yml",
)
PYTHON_WORKFLOW = ".github/workflows/python-wheels.yml"
_TAG = re.compile(r"^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$")


class GateError(RuntimeError):
    """The release is definitively unsafe to publish."""


class GitHub:
    def __init__(self, repository: str, token: str) -> None:
        self.repository = repository
        self.token = token
        self.base = f"https://api.github.com/repos/{repository}"

    def get(self, path: str, params: dict[str, str | int] | None = None) -> Any:
        url = f"{self.base}{path}"
        if params:
            url += "?" + urlencode(params)
        request = Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "zigfitsio-wiki-release-gate",
            },
        )
        try:
            with urlopen(request, timeout=30) as response:
                return json.load(response)
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            raise GateError(f"GitHub API {exc.code} for {path}: {detail}") from exc
        except (URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise GateError(f"GitHub API request failed for {path}: {exc}") from exc


def select_workflow_runs(
    runs: list[dict[str, Any]], tag: str, sha: str
) -> dict[str, dict[str, Any]]:
    """Return the newest exact-tag run for each expected workflow path."""

    selected: dict[str, dict[str, Any]] = {}
    for run in runs:
        path = run.get("path")
        if (
            path not in EXPECTED_WORKFLOWS
            or run.get("event") != "push"
            or run.get("head_branch") != tag
            or run.get("head_sha") != sha
        ):
            continue
        previous = selected.get(path)
        # A rerun keeps the same run id while its attempt changes. Prefer the newest
        # workflow run, then its latest attempt, so an old rerun cannot outrank a newer run.
        rank = (int(run.get("id") or 0), int(run.get("run_attempt") or 0))
        old_rank = (
            int(previous.get("id") or 0),
            int(previous.get("run_attempt") or 0),
        ) if previous else (-1, -1)
        if rank > old_rank:
            selected[path] = run
    return selected


def evaluate_runs(
    runs: list[dict[str, Any]], tag: str, sha: str
) -> tuple[str, dict[str, dict[str, Any]]]:
    selected = select_workflow_runs(runs, tag, sha)
    if len(selected) != len(EXPECTED_WORKFLOWS):
        return "waiting", selected
    if any(run.get("status") != "completed" for run in selected.values()):
        return "waiting", selected
    failures = {
        path: run.get("conclusion")
        for path, run in selected.items()
        if run.get("conclusion") != "success"
    }
    if failures:
        formatted = ", ".join(f"{path}={value}" for path, value in sorted(failures.items()))
        raise GateError(f"release workflow did not succeed: {formatted}")
    return "ready", selected


def _event_release(event: dict[str, Any]) -> tuple[str, str, str]:
    run = event.get("workflow_run") or {}
    repository = (event.get("repository") or {}).get("full_name")
    if not run and isinstance(event.get("inputs"), dict):
        tag = event["inputs"].get("tag")
        if not isinstance(repository, str) or "/" not in repository:
            raise GateError("workflow_dispatch payload has no repository full_name")
        if not isinstance(tag, str) or not _TAG.fullmatch(tag):
            raise GateError("workflow_dispatch input 'tag' must be vX.Y.Z SemVer")
        return repository, tag, ""
    tag = run.get("head_branch")
    sha = run.get("head_sha")
    if run.get("event") != "push" or not isinstance(tag, str) or not _TAG.fullmatch(tag):
        return str(repository or ""), "", ""
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise GateError("workflow_run payload has an invalid head SHA")
    if not isinstance(repository, str) or "/" not in repository:
        raise GateError("workflow_run payload has no repository full_name")
    return repository, tag, sha


def gate(
    event: dict[str, Any], token: str, *, poll_attempts: int = 1, poll_seconds: float = 0
) -> dict[str, Any]:
    repository, tag, sha = _event_release(event)
    if not tag:
        return {"ready": False, "waiting": False, "reason": "not-a-release-tag"}
    client = GitHub(repository, token)
    if not sha:
        commit = client.get(f"/commits/{quote(tag, safe='')}")
        sha = commit.get("sha", "")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise GateError(f"tag {tag} did not resolve to a commit SHA")

    selected: dict[str, dict[str, Any]] = {}
    state = "waiting"
    for attempt in range(max(1, poll_attempts)):
        payload = client.get(
            "/actions/runs",
            {"head_sha": sha, "event": "push", "per_page": 100},
        )
        state, selected = evaluate_runs(payload.get("workflow_runs", []), tag, sha)
        if state == "ready" or attempt + 1 == poll_attempts:
            break
        time.sleep(poll_seconds)
    if state != "ready":
        return {
            "ready": False,
            "waiting": True,
            "reason": "peer-workflow-not-complete",
            "repository": repository,
            "tag": tag,
            "sha": sha,
            "observedWorkflows": sorted(selected),
        }

    commit = client.get(f"/commits/{quote(tag, safe='')}")
    if commit.get("sha") != sha:
        raise GateError(f"tag {tag} resolves to {commit.get('sha')}, expected {sha}")
    release = client.get(f"/releases/tags/{quote(tag, safe='')}")
    if release.get("draft") or release.get("tag_name") != tag:
        raise GateError(f"GitHub Release for {tag} is missing, draft, or mismatched")

    return {
        "ready": True,
        "waiting": False,
        "reason": "both-release-workflows-succeeded",
        "repository": repository,
        "tag": tag,
        "version": tag[1:],
        "sha": sha,
        "releaseUrl": release.get("html_url", ""),
        "workflowRunIds": {
            path: selected[path]["id"] for path in EXPECTED_WORKFLOWS
        },
    }


def _write_outputs(path: str | None, state: dict[str, Any]) -> None:
    if not path:
        return
    with Path(path).open("a", encoding="utf-8") as handle:
        for key in ("ready", "waiting", "reason", "repository", "tag", "version", "sha"):
            if key in state:
                value = state[key]
                if isinstance(value, bool):
                    value = str(value).lower()
                handle.write(f"{key}={value}\n")
        run_ids = state.get("workflowRunIds")
        if isinstance(run_ids, dict) and PYTHON_WORKFLOW in run_ids:
            handle.write(f"python_run_id={int(run_ids[PYTHON_WORKFLOW])}\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", type=Path, default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN"))
    parser.add_argument("--poll-attempts", type=int, default=6)
    parser.add_argument("--poll-seconds", type=float, default=5)
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    parser.add_argument("--expected-tag")
    parser.add_argument("--expected-sha")
    parser.add_argument("--require-ready", action="store_true")
    args = parser.parse_args(argv)
    if not args.event or not args.token:
        parser.error("--event and --token (or their GitHub environment variables) are required")
    try:
        event = json.loads(args.event.read_text(encoding="utf-8"))
        state = gate(
            event,
            args.token,
            poll_attempts=args.poll_attempts,
            poll_seconds=args.poll_seconds,
        )
        if args.expected_tag and state.get("tag") != args.expected_tag:
            raise GateError(
                f"release tag changed during publication: "
                f"expected {args.expected_tag}, got {state.get('tag')!r}"
            )
        if args.expected_sha and state.get("sha") != args.expected_sha:
            raise GateError(
                f"release SHA changed during publication: "
                f"expected {args.expected_sha}, got {state.get('sha')!r}"
            )
        if args.require_ready and state.get("ready") is not True:
            raise GateError(f"release is no longer ready: {state.get('reason', 'unknown')}")
    except (OSError, json.JSONDecodeError, GateError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    _write_outputs(args.github_output, state)
    print(json.dumps(state, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
