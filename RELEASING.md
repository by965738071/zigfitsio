# Releasing zigfitsio

Releases are tag-driven. Pushing a tag `vX.Y.Z` runs `.github/workflows/python-wheels.yml`,
which gates on version consistency and the core Zig suite, builds wheels + sdist, publishes
them to PyPI via [trusted publishing](https://docs.pypi.org/trusted-publishers/) (OIDC — no
API tokens anywhere), and then creates a GitHub Release with the tag's CHANGELOG section as
notes and all artifacts attached. The same tag also runs
`.github/workflows/typescript.yml`, which cross-compiles the 7 `@zigfitsio/*` platform
packages and publishes them + the main `zigfitsio` npm package via npm trusted publishing.

```
version-check ──┐
zig-test ───────┤  (tag/dispatch only)
wheels (×5) ────┼──► publish-pypi ──► github-release        [tag pushes]
sdist ──────────┤ └─► publish-testpypi                      [manual dispatch]
smoke ──────────┘

version-check ──┐
test (×8) ──────┼──► publish-npm                            [tag pushes]
interop ────────┤ └─► publish-rehearsal (--dry-run)         [manual dispatch]
build-natives ──┘
```

`version-check` fails within seconds of a bad tag (version mismatch or missing CHANGELOG
section) and nothing publishes. `github-release` runs only after the PyPI upload succeeds,
so a release announcement never points at an uninstallable package.

## One-time setup

Done once per index/repo; nothing here stores a secret.

1. **PyPI** — at <https://pypi.org/manage/account/publishing/> add a *pending publisher*
   (GitHub):
   - PyPI Project Name: `zigfitsio`
   - Owner: `anhydrous99`
   - Repository name: `zigfitsio`
   - Workflow name: `python-wheels.yml`
   - Environment name: `pypi`

   ⚠️ A pending publisher does **not** reserve the name — `zigfitsio` stays claimable by
   anyone until the first successful publish. Do this and the first release promptly.

2. **TestPyPI** — separate account at <https://test.pypi.org>; same pending-publisher form
   with identical values except Environment name: `testpypi`.

3. **GitHub** — repo Settings → Environments:
   - Create `pypi`; under *Deployment branches and tags* select "Selected branches and tags"
     and add a **tag** rule `v*`. Optionally add yourself as a required reviewer — each
     release then pauses for one approval click (sensible for the first release).
   - Create `testpypi`; optionally restrict it to branch `main`.
   - Create `npm` with the same tag rule `v*` (the `publish-npm` job in `typescript.yml`
     uses it).

4. **npm** — trusted publishing is configured **per existing package** (npm has no
   PyPI-style pending publishers), so the first release of all 8 packages must be
   bootstrapped by hand:
   - Create the npm org **`zigfitsio`** (owns the `@zigfitsio/*` platform-package scope)
     and confirm the unscoped name `zigfitsio` is still free — like PyPI, it stays
     claimable until the first publish, so do this promptly.
   - Bootstrap once from a logged-in machine (or a short-lived granular automation token,
     deleted afterwards):

     ```sh
     cd bindings/typescript
     npm ci && node scripts/build-native.mjs        # all 7 platform packages
     for d in npm/*/; do npm publish "$d" --access public; done
     node scripts/prepare-publish.mjs               # inject optionalDependencies
     npm publish --access public
     git checkout package.json                      # discard the injected block
     ```

   - Then, for **each of the 8 packages** on npmjs.com: Settings → Trusted Publisher →
     GitHub Actions with owner `anhydrous99`, repository `zigfitsio`, workflow
     `typescript.yml`, environment `npm`. Subsequent tag releases publish via OIDC with
     provenance, no tokens.

## Cutting a release

1. Bump the version in all five spots (CI's `version-check` jobs enforce they agree):
   - `build.zig.zon` — `.version`
   - `src/version.zig` — `version_string` **and** the `expectEqualStrings` test literal
   - `pyproject.toml` — `[project] version`
   - `bindings/typescript/package.json` — `version` (the generated `npm/*` platform
     packages and the injected optionalDependencies pins inherit it automatically)
2. Move the `## [Unreleased]` content in `CHANGELOG.md` into a new
   `## [X.Y.Z] - YYYY-MM-DD` section (leave `_Nothing yet._` under Unreleased). This section
   becomes the GitHub Release notes verbatim. Don't add link-reference lines
   (`[X.Y.Z]: https://…`) at the bottom — the notes extractor treats `## [` headings as the
   only section boundaries.
3. Commit (`release: vX.Y.Z`), push, and **wait for the main-branch CI run to go green**.
4. Tag and push:

   ```sh
   git tag -a vX.Y.Z -m "zigfitsio X.Y.Z"
   git push origin vX.Y.Z
   ```

5. Watch the run (`gh run watch`), then verify: <https://pypi.org/project/zigfitsio/>,
   <https://www.npmjs.com/package/zigfitsio>, the GitHub Release, and clean installs:

   ```sh
   pip install zigfitsio==X.Y.Z
   python -c "import zigfitsio; print(zigfitsio.__version__)"   # must print X.Y.Z

   npm install zigfitsio@X.Y.Z
   node -e "import('zigfitsio').then(zf => console.log(zf.VERSION))"   # must print X.Y.Z
   ```

## TestPyPI rehearsal

Before a risky release (especially the first), rehearse the OIDC handshake and artifact
plumbing against TestPyPI:

```sh
gh workflow run python-wheels.yml --ref main -f publish_testpypi=true
gh run watch
```

Verify at <https://test.pypi.org/project/zigfitsio/>. TestPyPI files are immutable too;
re-running the rehearsal for an already-uploaded version no-ops via `skip-existing` (which
still proves the OIDC handshake). Optional install check:

```sh
pip install -i https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple zigfitsio==X.Y.Z
```

## Failure recovery

- **`version-check` fails on the tag** — delete the tag, fix, re-tag:

  ```sh
  git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z
  # fix versions/CHANGELOG, commit, push, wait for green, re-tag
  ```

- **A build/publish job fails after wheels were built** — fix the external cause, then use
  **"Re-run failed jobs"** on the same run (artifacts are reused; uploads use `overwrite: true`
  so a full re-run also works).
- **PyPI partially accepted files** — PyPI files are immutable: never delete/re-upload.
  Roll forward with a patch release instead.
- Don't delete + re-push the same tag while its run is in flight (tag runs are deliberately
  never auto-cancelled); wait for the run to stop first.

## Renames break trusted publishing

PyPI's and npm's trusted publishers match owner / repository / workflow filename /
environment **exactly**. Renaming the repo, a workflow file (`python-wheels.yml`,
`typescript.yml`), or the `pypi`/`npm` environments breaks publishing until the publisher
config on the respective registry is updated (npm: per package, all 8).
