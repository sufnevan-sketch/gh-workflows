# Stub sync: template updates reach every repo without hand-opened PRs

Status: design, awaiting Evan's approval. Date: 2026-10-21.

## Intent

Each repo that uses gh-workflows carries thin stubs in `.github/workflows/` that call the reusable workflows here at `@main`. Changes to the reusable workflows already reach every repo on its next run. Changes to the **stubs** do not: today each one means opening and hand-merging a PR in every installed repo, because nothing can merge a workflow-file change on its own (`GITHUB_TOKEN` cannot push workflow files, the gate refuses any diff under `.github/workflows/`, and `claude-review` skips such PRs by design).

Evan's goal, in his words: "I just don't want to have to open a bunch of PRs in every repo every time the gh templates get updated."

Stub changes are frequent enough to hurt: 7 of the 28 commits on `main` (as of 2026-10-21) changed a `stubs/*.yml` file, four of them on 2026-10-20 alone.

## Goals

- A stub change merged to gh-workflows `main` reaches every installed repo with no PR opened by hand and, for repos set to auto, no PR merged by hand.
- A repo's own values (setup, verify, working directory, which optional stubs it has) survive every sync.
- A stub someone edited by hand inside a repo is never silently overwritten.
- Stubs removed from the template are removed from repos; stubs added are added (if the repo's config selects them).

## Non-goals

- Shrinking the stubs so they change less often (moving triggers, routing and values into the reusable workflows). Considered and set aside on 2026-10-21: of the 7 historical stub commits, at most two (a `fix-window-minutes` value, the expiry removal) would have been absorbed; the rest added triggers, permissions, secrets or a whole stub, which a frozen shell cannot anticipate. Once sync PRs merge themselves, stub churn stops costing Evan time anyway.
- Syncing `review-context.md`, `pull_request_template.md` or `AGENTS.md`. Those are the repo's own files after install, as today.
- Touching any workflow file the sync does not own (repos have their own, e.g. a content or scheduled-scraper workflow).
- Repo settings or secrets. The sync never calls `gh secret set` and never changes repo settings.

## Anti-goals (failure even if it technically works)

- Private repo names, owners, or per-repo settings appear anywhere public: this repo's files, issues, or **Actions logs** (gh-workflows is a public repo; its run logs are world-readable).
- The gate's refusal of workflow-file changes is weakened for agent-authored PRs.
- A repo's hand edit to a stub is lost.
- A sync PR merges while that repo's `ci / *` checks are red.

## Decided by Evan (2026-10-21)

1. A stub change may merge into a repo without him looking, as long as the files are exactly what the template produces for that repo.
2. Build the self-merging sync now; set the stub shrink aside.
3. Repos where he merges by hand on purpose (today: one review-only repo with no gate) are included: the sync opens their PR and leaves it for him. This is a per-repo setting, not special-cased code.

## Design

### 1. Per-repo config and lock, in each repo

Two files under `.github/` (not under `.github/workflows/`, so normal PRs can change them and the gate can merge those PRs):

- `.github/gh-workflows.json`: the repo's choices. Fields: `ref` (the gh-workflows ref the stubs pin, default `main`), `setup`, `verify`, `working-directory`, `auto-fix` (bool: installs `auto-fix.yml` + `ledger-fix.yml`, sets the fix window), `stubs` (the stub set, for repos that deviate from the default set, e.g. review-only), `merge` (`auto` | `manual`).
- `.github/gh-workflows.lock`: written only by tooling. The gh-workflows commit SHA the stubs were last rendered from, and a sha256 per owned stub file.

The config holds every per-repo variance the README lists today ("Per-repo variance is exactly: the ci stub's setup / verify (and working-directory...)") plus the opt-in stub set and merge mode.

### 2. One renderer, used by install and sync

`install.ps1`'s substitution logic (`@main` → `@<ref>`, `__SETUP__`, `__VERIFY__`, `working-directory`, fix-window 0 without auto-fix) moves into one render function: input = stubs at a gh-workflows SHA + a config, output = the exact set of owned files and their bytes (LF, UTF-8 no BOM, as `Write-Lf` does today). `install.ps1` becomes: write config, render, write files, write lock. pwsh is preinstalled on GitHub's `ubuntu-latest` runners, so the sync job calls the same script.

### 3. The sync job

Runs from a **private** host repo (see Privacy), on `workflow_dispatch` and a schedule. Each run:

1. Reads gh-workflows `main` SHA.
2. Lists the repos the sync GitHub App is installed on (this is the registry; no list file exists anywhere). Repos without `.github/gh-workflows.json` are skipped and counted as "not adopted".
3. Per repo: render from the repo's config at the current gh-workflows SHA. If the rendered files equal the repo's files, and the lock already names this SHA, do nothing.
4. Otherwise run the **drift check**: hash every owned stub file currently on the repo's default branch and compare to the lock. Any mismatch (hand edit, or a file missing that the lock lists) = drift.
5. Open or update one PR, branch `chore/gh-workflows-sync` (one standing branch per repo, force-updated, so a repo never collects a stack of sync PRs), with the rendered files, deletions of owned files no longer rendered, and the new lock. The PR body says what changed (stub names, gh-workflows commit range) and, if drift was found, which files and that this PR will not auto-merge.
6. Merge policy:
   - `merge: auto`, no drift: wait for the repo's `ci / branch-name` and `ci / verify` on the PR's head SHA to complete green, matching `headSha` to the pushed SHA, then squash-merge with the App token.
   - `merge: manual`, or drift found, or CI red/missing: leave the PR open. Do nothing else.
7. Writes a run summary that contains no repo names (counts only: synced, left open, not adopted, failed). Per-repo detail goes only to places inside the private host repo (see Reporting).

The sync merges centrally rather than through each repo's gate, so: the gate's workflow-file refusal stays exactly as it is for agent PRs; the first sync works without any gate change landing in every repo first; and a manual repo is simply "open, don't merge".

Because `claude-review` skips workflow-file PRs and `codex-review` skips `chore/` branches, the only signal a sync PR gets is `ci / *`. That is acceptable because the content is a deterministic render of a template that itself passed review in gh-workflows.

### 4. Owned files

The sync owns exactly: the stub files the renderer can produce (`stubs/*.yml` at the rendered SHA, plus any listed in the lock from an earlier SHA). It deletes an owned file only if the lock lists it, the file still matches its lock hash, and the new render no longer produces it. Anything else under `.github/workflows/` is never read for writing, never deleted.

### 5. Adoption of the already-installed repos (one time)

Today's installed repos have stubs but no config or lock. An adopt mode (new `install.ps1 -Adopt`, run locally by a session, one repo at a time):

1. Infers the config from the repo's current files (`ci.yml` inputs, which optional stubs exist, pinned ref).
2. Renders at gh-workflows `main` with that config.
3. If the render equals the current files byte for byte: writes config + lock only. That PR touches nothing under `.github/workflows/`, so the repo's gate merges it like any docs change.
4. If not: reports the differences so the session can fold the intended ones into the config and render again. Whatever still differs is written into the lock with the **rendered** hashes, so the first sync sees those files as drift and leaves its PR open for Evan to look at once. Adoption itself never changes a stub, and a pre-adoption hand edit is never overwritten without that one look.

### 6. Privacy

gh-workflows is public and its Actions logs are public. Therefore the sync job, the App private key, and all per-repo output live in a private host repo. gh-workflows holds only public, generic parts: the renderer, the config/lock schema, the docs. The App's installation set is the only registry.

### 7. Reporting

Something has to tell Evan when a sync PR is left open or failed, without him checking each repo. In the private host repo: the run summary (private there) lists each repo with outcome, and one standing issue (e.g. "stub sync: needs attention") is updated when any repo is left open for drift, manual merge, or red CI, and closed when none are.

### 8. Credentials

One GitHub App, created by Evan, installed with "only select repositories" on the owners that hold installed repos (Evan is admin on all of them, checked 2026-10-21). Repository permissions: Contents read/write, Pull requests read/write, Workflows read/write, Checks read, Actions read, Metadata read. App ID and private key stored as secrets in the private host repo only. During setup the gitignored env file gets the empty `NAME=` lines before Evan is asked for anything; values never pass through chat.

Trust: whoever can push to gh-workflows `main` already controls every installed repo (stubs call `@main` with write permissions). The sync adds no new path in; the App key is the one new secret, held in a private repo.

## Constraints

- Free-plan private repos: no branch protection, so nothing server-side stops a merge; the sync's own green-check rule is the guard. Never `gh pr merge --auto`.
- Merge only on checks for the head being merged (`headSha` match).
- Every write outside gh-workflows goes through the App token; no personal PAT.
- Bash 3.2 / Git Bash constraints do not apply (everything is pwsh on the runner, pwsh locally).
- The open `fix/gate-no-idle-wait` branch changes stubs; the stub set the renderer starts from is whatever is on `main` when this is built.

## My calls (Evan can override)

- **Lock with file hashes** instead of re-rendering the previous version for the drift check: simpler, and also catches a hand edit made before adoption.
- **Template version = gh-workflows commit SHA**, not a hand-bumped semver: nothing to remember to bump. Per-change notes come from the commit range in the PR body.
- **One standing sync branch per repo**, force-updated.
- **Private host repo**: a new private repo dedicated to the sync, so the App key sits apart from umbrella-repo work. `evan-workspace` would also work.
- **Trigger**: schedule (every 6 hours) plus `workflow_dispatch`, rather than a cross-repo dispatch from gh-workflows, which would need a token in the public repo. Cost estimate: 4 short runs a day.

## Left to the builder

- Config/lock exact schema and file format (JSON vs YAML).
- How the sync waits for CI (poll inside the run with a cap, or leave the PR and merge on the next scheduled run once green). Either is fine if it obeys the headSha rule.
- How adoption handles each kind of difference in step 5.4.
- Selftest additions to `self-check.yml` (renderer is deterministic; rendering every stub with representative configs passes actionlint).

## Verification

- **Renderer**: for each installed repo, adopt in dry-run and confirm the render of its inferred config equals its current files, or that every difference is explained. Run locally, output kept out of this public repo.
- **Sync, dry-run mode**: a `-WhatIf` input that lists, per repo, what it would push, delete and merge, and writes nothing. Run it against the real installation set before the first real run.
- **End to end**: on a throwaway private repo with the stubs installed, change a stub on a gh-workflows test branch (`ref` pinned to it), run the sync, and confirm: PR opened, CI green, merged; then hand-edit a stub and confirm the next sync leaves the PR open and flags drift; then delete a stub from the template and confirm it is removed; then set `merge: manual` and confirm no merge.
- **Privacy**: after a real run, read the public gh-workflows Actions logs for that period and confirm none of them was produced by the sync, and grep this repo for private owner names.
