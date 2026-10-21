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
4. Credential: one classic PAT (scopes `repo` + `workflow`), chosen over a GitHub App. A private App installs only on the account that owns it, so one App across three owners would have to be public; a PAT spans all owners with one secret.
5. A change to a repo's config file since its last sync makes that repo's next sync PR wait for Evan's merge. Only template changes merge themselves. Reason: the config is mergeable by the repo's gate, and every field in it ends up in a workflow file, so an agent PR could otherwise route workflow changes past the gate through the config.

## Design

### 1. Per-repo config and lock, in each repo

Two files under `.github/` (not under `.github/workflows/`, so normal PRs can change them and the gate can merge those PRs):

- `.github/gh-workflows.json`: the repo's choices. Fields: `ref` (the gh-workflows ref the stubs pin, default `main`), `setup`, `verify`, `working-directory`, `auto-fix` (bool: installs `auto-fix.yml` + `ledger-fix.yml`, sets the fix window), `stubs` (the stub set, for repos that deviate from the default set, e.g. review-only), `merge` (`auto` | `manual`), plus the knobs the README and stubs already document as per-repo edits: per-stub `with:` overrides (e.g. `skip-branch-prefixes`, `delete-branch`, `artifact-path`, `required-checks`, `codex-check`, codex `mode`), extra named secrets per stub (e.g. `OPENAI_API_KEY` for `mode: action`), and `ledger-expiry` (bool: adds the expiry trigger and job).
- `.github/gh-workflows.lock`: written only by tooling. The gh-workflows SHA the stubs were last rendered from, a sha256 of the config file at that render, and a sha256 per owned stub file.

Anything a repo needs beyond these fields (e.g. a renamed stub job id) is drift by definition: its sync PRs wait for Evan until the knob is added to the schema or the edit is dropped. There is no "keep my hand edit" path; the way to keep an edit is to make it a config field.

### 2. One renderer, used by install and sync

`install.ps1`'s substitution logic (`@main` → `@<ref>`, `__SETUP__`, `__VERIFY__`, `working-directory`, fix-window 0 without auto-fix) moves into one render function: input = stubs at a gh-workflows SHA + a config, output = the exact set of owned files and their bytes (LF, UTF-8 no BOM, as `Write-Lf` does today). `install.ps1` becomes: write config, render, write files, write lock. pwsh is preinstalled on GitHub's `ubuntu-latest` runners, so the sync job calls the same script.

The renderer rejects a config it cannot render safely, instead of splicing raw text as `install.ps1` does today (`.Replace('__VERIFY__', $Verify)`): every string value must be a single line and is written as a quoted YAML scalar; `ref` must be `main` or a tag; `stubs` may only name stubs that exist at that ref; unknown fields are an error. A rejected config makes that repo's sync fail (reported, see Reporting), never a partial render.

### 3. The sync job

Runs from a **private** host repo (see Privacy), on `workflow_dispatch` and a schedule. Each run:

1. Lists the repos to sync: every repo under the owners in a private owner allowlist (a variable in the host repo) that the PAT can see and that has `.github/gh-workflows.json` on its default branch. Repos without one are skipped. No per-repo list file exists anywhere.
2. Per repo: resolve the repo's `ref` to a gh-workflows SHA and render from the stubs **at that SHA** with the repo's config. The lock's SHA is therefore per repo. (Rendering `main`'s stubs against a pinned tag could pass inputs the tagged callee does not declare, which is a hard config error.)
3. If the rendered files equal the repo's owned files byte for byte, do nothing, and do not touch the lock. The lock's SHA moves only when the rendered output changes, so a gh-workflows commit that changes no stub opens no PR anywhere.
4. Otherwise decide whether this PR may merge itself. It may not if any of these hold:
   - **Drift**: an owned stub file on the default branch does not match its lock hash (hand edit), or a file the lock lists is missing.
   - **Config changed**: the config file's hash differs from the one in the lock (Evan's decision 5).
   - The repo is `merge: manual`.
5. Open or update one PR, branch `chore/gh-workflows-sync` (one standing branch per repo, so a repo never collects a stack of sync PRs), with the rendered files, deletions of owned files no longer rendered, and the new lock. If the branch carries a commit the sync did not make, the sync does not force-push over it: it leaves the PR as is and reports it. The PR body says what changed (stub names, gh-workflows commit range) and, when it will not merge itself, which reason from step 4 applies.
6. Merge, only when step 4 allowed it: wait for the repo's `ci / branch-name` and `ci / verify` on the PR's head SHA to complete green, matching `headSha` to the pushed SHA, then squash-merge with the PAT. Otherwise, or on CI red or missing, leave the PR open.
7. Writes a run summary. The host repo is private, so per-repo detail is fine there (see Reporting).

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

gh-workflows is public and its Actions logs are public. Therefore the sync job, the PAT, the owner allowlist, and all per-repo output live in a private host repo. gh-workflows holds only public, generic parts: the renderer, the config/lock schema, the docs.

### 7. Reporting

Something has to tell Evan when a sync PR is left open or failed, without him checking each repo. In the private host repo: the run summary (private there) lists each repo with outcome, and one standing issue (e.g. "stub sync: needs attention") is updated when any repo is left open (drift, config changed, manual merge, foreign commit, red CI) or failed (rejected config, PAT error), and closed when none are. A run where every repo fails the same way (typically an expired PAT) says so in one line at the top of that issue.

### 8. Credentials

One classic PAT, created by Evan, scopes `repo` and `workflow`, with an expiry date. Stored as a secret in the private host repo only, pushed with `set-secrets.ps1` from the gitignored env file; during setup the env file gets the empty `NAME=` line before Evan is asked for anything, and the value never passes through chat. A fine-grained PAT cannot be used: it targets one resource owner, and the repos span three.

Consequences to accept: sync commits and merges show as Evan; pushes made with a PAT do trigger the repo's workflows (unlike `GITHUB_TOKEN`), which is what lets `ci / *` run on the sync PR; when the PAT expires, every repo's sync fails at once, which Reporting must make obvious.

Trust: whoever can push to gh-workflows `main` already controls every installed repo (stubs call `@main` with write permissions). The sync adds no new path in; the PAT is the one new secret, held in a private repo. It is broader than an App token (it can write to every repo Evan can), which is the trade Evan chose for a single secret.

## Constraints

- Free-plan private repos: no branch protection, so nothing server-side stops a merge; the sync's own green-check rule is the guard. Never `gh pr merge --auto`.
- Merge only on checks for the head being merged (`headSha` match).
- Every write outside gh-workflows goes through the one sync PAT.
- Bash 3.2 / Git Bash constraints do not apply (everything is pwsh on the runner, pwsh locally).
- The open `fix/gate-no-idle-wait` branch changes stubs; the stub set the renderer starts from is whatever is on `main` when this is built.

## My calls (Evan can override)

- **Lock with file hashes** instead of re-rendering the previous version for the drift check: simpler, and also catches a hand edit made before adoption.
- **Template version = gh-workflows commit SHA**, not a hand-bumped semver: nothing to remember to bump. Per-change notes come from the commit range in the PR body.
- **Render at each repo's own `ref`**, so the lock SHA is per repo.
- **Lock moves only when rendered output changes**: no lock-only PRs, which would otherwise open in every repo on every gh-workflows commit and race the repo's own gate.
- **One standing sync branch per repo**, force-updated only while every commit on it is the sync's own.
- **Config schema covers the per-repo edits the README and stubs document today**; anything else is drift.
- **Renderer validates instead of splicing raw text**; `ref` limited to `main` or a tag.
- **Owner allowlist** in the host repo plus "has a config file" as the registry, since a PAT has no installation set.
- **Private host repo**: a new private repo dedicated to the sync, so the PAT sits apart from umbrella-repo work. `evan-workspace` would also work.
- **Trigger**: schedule (every 6 hours) plus `workflow_dispatch`, rather than a cross-repo dispatch from gh-workflows, which would need a token in the public repo. Cost estimate: 4 short runs a day.

## Left to the builder

- Config/lock exact schema and file format (JSON vs YAML).
- How the sync waits for CI (poll inside the run with a cap, or leave the PR and merge on the next scheduled run once green). Either is fine if it obeys the headSha rule.
- How adoption handles each kind of difference in step 5.4.
- Selftest additions to `self-check.yml` (renderer is deterministic; rendering every stub with representative configs passes actionlint).

## Verification

- **Renderer**: for each installed repo, adopt in dry-run and confirm the render of its inferred config equals its current files, or that every difference is explained. Run locally, output kept out of this public repo.
- **Sync, dry-run mode**: a `-WhatIf` input that lists, per repo, what it would push, delete and merge, and writes nothing. Run it against the real installation set before the first real run.
- **End to end**: on a throwaway private repo with the stubs installed and `ref` pinned to a test tag, move the tag to a commit with a changed stub, run the sync, and confirm: PR opened, CI green, merged. Then confirm each hold: a hand-edited stub (drift), an edited config (config changed), `merge: manual`, a foreign commit on the sync branch; each leaves the PR open with the right reason. Then remove a stub from the template and confirm it is deleted. Then a gh-workflows commit that changes no stub: confirm no PR. Then a config with a newline in `verify`: confirm the renderer rejects it.
- **Privacy**: after a real run, read the public gh-workflows Actions logs for that period and confirm none of them was produced by the sync, and grep this repo for private owner names.
