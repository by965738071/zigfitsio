# Releasing zigfitsio

Releases are tag-driven. Pushing a tag `vX.Y.Z` runs `.github/workflows/python-wheels.yml`,
which gates on version consistency and the core Zig suite, builds wheels + sdist, publishes
them to PyPI via [trusted publishing](https://docs.pypi.org/trusted-publishers/) (OIDC — no
API tokens anywhere), and then creates a GitHub Release with the tag's CHANGELOG section as
notes and the wheels + sdist attached. The same tag also runs
`.github/workflows/typescript.yml`, which builds the single `zigfitsio.wasm` module and
publishes the one `zigfitsio` npm package via npm trusted publishing. Both publisher
workflows generate and validate the Zig, Python, and TypeScript API references before an
external upload. The Python workflow retains that exact validated bundle as an artifact. After
both workflows succeed for the same tag and commit, `.github/workflows/publish-wiki.yml`
downloads the artifact from the gate-selected Python run, publishes its Markdown to the GitHub
Wiki, and attaches an immutable API-reference archive to the GitHub Release.

```
version-check ──┐
api-docs ───────┤
zig-test ───────┤  (tag/dispatch only)
wheels (×5) ────┼──► publish-pypi ──► github-release        [tag pushes]
sdist ──────────┤ └─► publish-testpypi                      [manual dispatch]
smoke ──────────┘

version-check ──┐
api-docs ───────┤  (tag/dispatch only)
test (×6) ──────┼──► publish-npm                            [tag pushes]
interop ────────┘ └─► publish-rehearsal (--dry-run)         [manual dispatch]

python api-docs artifact ─┐
github-release ─────────┤
publish-npm ─────────────┴──► trusted publish-wiki.yml ──► GitHub Wiki + API archive
```

`version-check` fails within seconds of a bad tag (version mismatch or missing CHANGELOG
section), while `api-docs` rejects incomplete, non-deterministic, or cross-language ABI-drifted
references. `github-release` runs only after the PyPI upload succeeds. The Wiki publisher
checks both upstream workflow files, the tag ref, source SHA, and non-draft GitHub Release
before the publishing job receives write permission. That privileged job checks out and executes
only the trusted default branch; tagged code runs in the unprivileged Python workflow, and its
artifact is accepted only as data after its release metadata, exact allowed filenames,
managed-page hashes, and page ownership are validated again.

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
   - Open the repository's **Wiki** tab and create a placeholder `Home` page once whose body
     includes `<!-- zigfitsio-api-wiki-bootstrap -->` (a visible line such as “API reference
     automation bootstrap” may follow it). GitHub does not create the cloneable
     `<repository>.wiki.git` repository until its first page exists. The marker explicitly
     authorizes the first automated release to replace this placeholder; an established manual
     Home page is otherwise protected from overwrite.
   - After the first release containing the Wiki tooling, run the Wiki rehearsal below and
     confirm the repository-scoped `GITHUB_TOKEN` can push. No Wiki PAT is configured or
     expected; repository policy must permit Actions with `contents: write`.

4. **npm** — trusted publishing is configured **per existing package** (npm has no
   PyPI-style pending publishers), so the first release of `zigfitsio` must be bootstrapped
   by hand. The name is unscoped and first-come-first-served like PyPI, so confirm it is not
   already taken and do this promptly.
   - Bootstrap once from a logged-in machine (or a short-lived granular automation token,
     deleted afterwards) — `prepack` builds `dist/` + `zigfitsio.wasm`, so the zig toolchain
     must be on PATH:

     ```sh
     cd bindings/typescript
     npm ci
     npm publish --access public
     ```

   - Then, on npmjs.com for the `zigfitsio` package: Settings → Trusted Publisher →
     GitHub Actions with owner `anhydrous99`, repository `zigfitsio`, workflow
     `typescript.yml`, environment `npm`. Subsequent tag releases publish via OIDC with
     provenance, no tokens.

## Cutting a release

1. Bump the version in all five spots (CI's `version-check` jobs enforce they agree):
   - `build.zig.zon` — `.version`
   - `src/version.zig` — `version_string` **and** the `expectEqualStrings` test literal
   - `pyproject.toml` — `[project] version`
   - `bindings/typescript/package.json` — `version`
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

5. Watch both publisher runs (`gh run watch`). Their successful completion automatically starts
   **Publish release API Wiki**. Then verify: <https://pypi.org/project/zigfitsio/>,
   <https://www.npmjs.com/package/zigfitsio>, the GitHub Release, the repository Wiki, the
   `zigfitsio-api-vX.Y.Z.tar.gz` release asset, and clean installs:

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

## API Wiki preview and rehearsal

Every successful Python `api-docs` job generates twice, rejects any byte-level difference, then
uploads `api-wiki-preview-<commit>` for 90 days. It contains the exact flat Wiki bundle:
generated Markdown, `.generated-api-manifest.json`, and the four language/coverage validation
JSON files. For a release, the trusted publisher downloads that artifact by both the
gate-verified Python run ID and commit-specific artifact name. Generate the same bundle locally
after `npm ci`; `--out` must not exist or must be empty:

```sh
cd bindings/typescript && npm ci && cd ../..
python3 tools/wiki/generate.py \
  --out /tmp/zigfitsio-wiki \
  --tag vX.Y.Z \
  --sha "$(git rev-parse HEAD)" \
  --repository anhydrous99/zigfitsio
```

To rehearse or recover publication for a successful release whose tagged commit contains this
Wiki tooling, dispatch the publisher while the gate-selected Python tag run's artifact is still
retained. It re-verifies both exact tag/SHA release runs, downloads only that run's artifact, and
is idempotent:

```sh
gh workflow run publish-wiki.yml -f tag=vX.Y.Z
gh run watch
```

The live Wiki never downgrades when an older release is rerun. `force_downgrade=true` exists for
an explicit manual rollback only. The publisher updates files listed in
`.generated-api-manifest.json`; unrelated hand-written Wiki pages are preserved.

The release archive packages that already-validated downloaded directory with sorted paths,
epoch timestamps, numeric owner/group zero, and a timestamp-free gzip header. If the named asset
already exists, the publisher downloads and byte-compares it: identical bytes are an idempotent
success, while different bytes fail and are never overwritten.

## Failure recovery

- **`version-check` fails on the tag** — delete the tag, fix, re-tag:

  ```sh
  git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z
  # fix versions/CHANGELOG, commit, push, wait for green, re-tag
  ```

- **A build/publish job fails after wheels were built** — within GitHub's 30-day workflow-rerun
  window, fix the external cause, then use **"Re-run failed jobs"** on the same run (artifacts are
  reused; uploads use `overwrite: true` so a full re-run also works if no immutable registry file
  was already accepted).
- **PyPI partially accepted files** — PyPI files are immutable: never delete/re-upload.
  Roll forward with a patch release instead.
- **`api-docs` fails** — nothing in that workflow publishes. Fix missing docs, export drift, or
  broken links on `main`, cut a new tag if necessary, and rerun normally.
- **Wiki publication fails after the registries succeeded** — initialize the Wiki if the clone
  failed, correct the repository policy or transient cause, then dispatch `publish-wiki.yml` for
  the existing tag while the exact Python `api-wiki-preview-<commit>` artifact is retained. A
  no-diff rerun succeeds without creating another Wiki commit. If that artifact has expired, do
  not rebuild tag code inside the privileged publisher. The immutable API archive from an earlier
  successful publication is the durable copy for audited manual restoration; otherwise cut a new
  release. Automated restoration from another run would require a separately reviewed recovery
  path that does not yet exist.
- Don't delete + re-push the same tag while its run is in flight (tag runs are deliberately
  never auto-cancelled); wait for the run to stop first.

## Renames break trusted publishing

PyPI's and npm's trusted publishers match owner / repository / workflow filename /
environment **exactly**. Renaming the repo, a workflow file (`python-wheels.yml`,
`typescript.yml`), or the `pypi`/`npm` environments breaks publishing until the publisher
config on the respective registry is updated.
