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
- A hosted sync (a GitHub Actions job in some repo). Considered and dropped on 2026-10-21, see decision 4.

## Anti-goals (failure even if it technically works)

- Private repo names, owners, or per-repo settings appear anywhere public: this repo's files, issues, or Actions logs (gh-workflows is a public repo).
- The gate's refusal of workflow-file changes is weakened for agent-authored PRs, directly or through a file that controls what the sync renders.
- A repo's hand edit to a stub is lost.
- A sync PR merges while that repo's `ci / *` checks are red.

## Decided by Evan (2026-10-21)

1. A stub change may merge into a repo without him looking, as long as the files are exactly what the template produces for that repo.
2. Build the self-merging sync now; set the stub shrink aside.
3. Repos where he merges by hand on purpose (today: one review-only repo with no gate) are included: the sync opens their PR and leaves it for him. This is a per-repo setting, not special-cased code.
4. **The sync runs on Evan's PC, started by a Claude scheduled task**, using his existing `gh` login (scopes include `repo` and `workflow`, checked 2026-10-21). No host repo, no PAT, no stored secret. Chosen over a new private host repo with a classic PAT, over hosting in `evan-workspace`, and over each repo syncing itself (a PAT in every repo, 7× the Actions minutes). Accepted cost: it runs only while the PC and the Claude app are on.
5. A change to a repo's config waits for Evan's merge; only template changes merge themselves. Reason: every config field ends up in a workflow file, so an agent PR could otherwise route workflow changes past the gate through the config. How this is enforced: Design §1.

## Design

### 1. Per-repo config and lock, in each repo, protected by the gate

Two files under `.github/`:

- `.github/gh-workflows.json`: the repo's choices. Fields: `ref` (the gh-workflows ref the stubs pin, default `main`), `setup`, `verify`, `working-directory`, `auto-fix` (bool: installs `auto-fix.yml` + `ledger-fix.yml`, sets the fix window), `stubs` (the stub set, for repos that deviate from the default set, e.g. review-only), `merge` (`auto` | `manual`), plus the knobs the README and stubs already document as per-repo edits: per-stub `with:` overrides (e.g. `skip-branch-prefixes`, `delete-branch`, `artifact-path`, `required-checks`, `codex-check`, codex `mode`), extra named secrets per stub (e.g. `OPENAI_API_KEY` for `mode: action`), and `ledger-expiry` (bool: adds the expiry trigger and job).
- `.github/gh-workflows.lock`: written only by tooling. The gh-workflows SHA the stubs were last rendered from, and a sha256 per owned stub file.

**The gate treats both files like workflow files**: the reusable `auto-merge.yml` refuses any PR that touches `.github/gh-workflows.json` or `.github/gh-workflows.lock`, the same way it refuses `.github/workflows/**` today (one change at `@main`, which reaches every repo with no stub PR). So the only ways these files change on a repo's default branch are Evan's hand merge or the sync's own merge. That is how decision 5 holds: a config change is a PR Evan merges; the sync PR that renders it afterwards merges itself, because the config it renders is one Evan already merged. It also means no PR can rewrite the lock to hide a hand-edited stub.

Anything a repo needs beyond these fields (e.g. a renamed stub job id) is drift by definition: its sync PRs wait for Evan until the knob is added to the schema or the edit is dropped. There is no "keep my hand edit" path; the way to keep an edit is to make it a config field.

### 2. One renderer, used by install and sync

`install.ps1`'s substitution logic (`@main` → `@<ref>`, `__SETUP__`, `__VERIFY__`, `working-directory`, fix-window 0 without auto-fix) moves into one render function: input = stubs at a gh-workflows SHA + a config, output = the exact set of owned files and their bytes (LF, UTF-8 no BOM, as `Write-Lf` does today). `install.ps1` becomes: write config, render, write files, write lock. The new `sync.ps1` calls the same function.

The renderer rejects a config it cannot render safely, instead of splicing raw text as `install.ps1` does today (`.Replace('__VERIFY__', $Verify)`): every string value must be a single line and is written as a quoted YAML scalar; `ref` must be `main` or a tag; `stubs` may only name stubs that exist at that ref; unknown fields are an error. A rejected config makes that repo's sync fail (reported, see Reporting), never a partial render.

### 3. The sync (`sync.ps1`, run locally)

`sync.ps1` lives in gh-workflows next to `install.ps1`. It is generic: no owner or repo name appears in it. It runs in pwsh with the machine's `gh` login, from the main gh-workflows checkout after `git fetch` (it renders from `origin`, never from local `main`, which can carry another session's unpushed commits). Inputs: `-Owners` (the owner allowlist) and `-WhatIf` (report only, write nothing). Each run:

1. Lists the repos to sync: every repo under the given owners that `gh` can see and that has `.github/gh-workflows.json` on its default branch. Repos without one are skipped. No per-repo list file exists anywhere.
2. Per repo: resolve the repo's `ref` to a gh-workflows SHA and render from the stubs **at that SHA** with the repo's config. The lock's SHA is therefore per repo. (Rendering `main`'s stubs against a pinned tag could pass inputs the tagged callee does not declare, which is a hard config error.)
3. If the rendered files equal the repo's owned files byte for byte, close any open sync PR as superseded and stop. The lock's SHA moves only when the rendered output changes, so a gh-workflows commit that changes no stub opens no PR anywhere.
4. Otherwise decide whether this PR may merge itself. It may not if any of these hold:
   - **Drift**: an owned stub file on the default branch does not match its lock hash (hand edit), or a file the lock lists is missing.
   - The repo is `merge: manual`.
5. Bring the standing branch `chore/gh-workflows-sync` (one per repo, so a repo never collects a stack of sync PRs) and its PR up to date with the rendered files, deletions of owned files no longer rendered, and the new lock. All writes go through the GitHub API (no local clone of each repo). **Ownership of the branch is judged by content, not author** (the sync's commits, Evan's own pushes and every agent session using his `gh` login all show as Evan): the branch is the sync's own if its tree differs from the default branch only in owned files and the lock, and those equal the render named by the branch's own lock. If so, force-update it. If not, someone else changed it: leave the PR as is and report it. The PR body says what changed (stub names, gh-workflows commit range) and, when it will not merge itself, why.
6. Merge, only when step 4 allowed it, as a second pass after steps 1–5 have run for **every** repo: wait once, for all pending PRs together, under one overall cap that keeps the whole run inside a single 10-minute tool call (the Claude tool limit; a run killed mid-way reports nothing). Waiting is local and costs no Actions minutes. For each PR whose `ci / branch-name` and `ci / verify` completed green on a head SHA that matches the pushed SHA, squash-merge. Red: leave open and report. Still running when the cap ends: leave it; the next run merges it. A PR opened by an earlier run and already green is merged in this pass without waiting.
7. Prints a summary: per repo, one outcome (current, merged, left open with reason, failed with reason). This stays local: the scheduled task's run output.

The sync merges directly rather than through each repo's gate, so the gate's refusal stays absolute for every other PR, and a manual repo is simply "open, don't merge".

Because `claude-review` skips workflow-file PRs and `codex-review` skips `chore/` branches, the only signal a sync PR gets is `ci / *`. That is acceptable because the content is a deterministic render of a template that itself passed review in gh-workflows, with a config Evan merged by hand.

### 4. Owned files

The sync owns exactly: the stub files the renderer can produce (`stubs/*.yml` at the rendered SHA, plus any listed in the lock from an earlier SHA). It deletes an owned file only if the lock lists it, the file still matches its lock hash, and the new render no longer produces it. Anything else under `.github/workflows/` is never read for writing, never deleted.

### 5. Adoption of the already-installed repos (one time)

Today's installed repos have stubs but no config or lock. An adopt mode (new `install.ps1 -Adopt`, run locally by a session, one repo at a time, which opens the adoption PR):

1. Infers the config from the repo's current files (`ci.yml` inputs, which optional stubs exist, pinned ref).
2. Renders at gh-workflows `main` with that config.
3. If the render equals the current files byte for byte: the PR adds config + lock only.
4. If not: reports the differences so the session can fold the intended ones into the config and render again. Whatever still differs is written into the lock with the **rendered** hashes, so the first sync sees those files as drift and leaves its PR open for Evan to look at once. Adoption itself never changes a stub, and a pre-adoption hand edit is never overwritten without that one look.

Because the gate refuses config and lock changes, each adoption PR is a one-time hand merge by Evan (about one per installed repo).

### 6. The scheduled task

A Claude scheduled task (the same mechanism as `daily-github-stars`) runs once a day: `git fetch` in the gh-workflows checkout, then `pwsh sync.ps1 -Owners <the owners>`. The owner list lives in the task's own prompt, on this PC, so it never enters the public repo. The task reads the summary and tells Evan only when something needs him (a PR left open, a failure); a day where every repo is current or merged ends quietly. Run notices never go to Todoist.

After merging a stub change, Evan (or the session that merged it) can also run the task on demand instead of waiting for the next day.

The task must be able to push and merge with nobody watching, which no existing task proves: `daily-github-stars` does GitHub writes through `gh` unattended (star Lists, 3 successful runs by 2026-10-21) but deliberately never pushes. So the task's prompt runs exactly one fixed command, `pwsh <gh-workflows path>/sync.ps1 -Owners ...`, and that one command is allowlisted narrowly in Claude Code permissions. That allowlist entry is a settings change Evan approves at build time. The task does nothing else that could hit a permission prompt.

### 7. Reporting

The scheduled task's run output is the record. It surfaces, per repo: left open (drift, manual merge, branch changed by someone else, red CI) or failed (rejected config, `gh` auth error). A run where every repo fails the same way (typically `gh` logged out or its token revoked) says so in one line instead of seven.

### 8. Credentials

None stored. The sync uses the machine's existing `gh` login. If that login loses `repo` or `workflow` scope, is logged out, or a client org starts restricting OAuth app access, the sync fails, and Reporting makes that obvious.

Consequences to accept: sync commits and merges show as Evan; pushes and merges made with his login do trigger the repo's workflows (unlike `GITHUB_TOKEN`), which is what lets `ci / *` run on the sync PR.

Trust: whoever can push to gh-workflows `main` already controls every installed repo (stubs call `@main` with write permissions). The sync adds no new path in and no new secret.

## Constraints

- Free-plan private repos: no branch protection, so nothing server-side stops a merge; the sync's own green-check rule is the guard. Never `gh pr merge --auto`.
- Merge only on checks for the head being merged (`headSha` match).
- `sync.ps1` and the renderer are pwsh, started by a Claude scheduled task, not Windows Task Scheduler (which cannot launch the Store `pwsh`).
- The sync renders from `origin` refs after a fetch, never from a local branch.
- The open `fix/gate-no-idle-wait` branch also changes the gate and stubs; the gate change in §1 and the stub set the renderer starts from are whatever is on `main` when this is built.

## My calls (Evan can override)

- **Gate refuses config and lock changes**, rather than keeping trusted state somewhere else: one line in a workflow that already refuses workflow files, no state store to keep consistent. Cost: adoption is one hand merge per repo, and every config change is a hand merge (which decision 5 wants anyway).
- **Lock with file hashes** instead of re-rendering the previous version for the drift check: simpler, and also catches a hand edit made before adoption.
- **Template version = gh-workflows commit SHA**, not a hand-bumped semver: nothing to remember to bump. Per-change notes come from the commit range in the PR body.
- **Render at each repo's own `ref`**, so the lock SHA is per repo.
- **Lock moves only when rendered output changes**: no lock-only PRs on gh-workflows commits that touch no stub.
- **One standing sync branch per repo**, force-updated only while its content is exactly the sync's render (ownership by content, since every writer has the same identity).
- **Writes through the GitHub API**, no local clones of the target repos.
- **Open every PR first, then one shared CI wait** under a cap that fits one 10-minute tool call; a later run merges anything still running.
- **Daily schedule plus on-demand runs.**
- **One fixed, narrowly allowlisted command** is all the scheduled task runs.
- **Config schema covers the per-repo edits the README and stubs document today**; anything else is drift.
- **Renderer validates instead of splicing raw text**; `ref` limited to `main` or a tag.

## Left to the builder

- Config/lock exact schema and file format (JSON vs YAML).
- How adoption handles each kind of difference in step 5.4.
- The exact wait cap within the 10-minute limit, and the time of day for the schedule.
- Selftest additions to `self-check.yml` (renderer is deterministic; rendering every stub with representative configs passes actionlint).

## Verification

- **Already checked (2026-10-21)**: the `gh` login reads `.github/workflows/` contents of private repos in all three owners, so no org restricts the `gh` CLI's OAuth app; Evan is admin in each org.
- **Renderer**: for each installed repo, adopt in dry-run and confirm the render of its inferred config equals its current files, or that every difference is explained. Output kept out of this public repo.
- **Gate**: a PR touching only `.github/gh-workflows.json` is refused by the gate with a hand-merge reason; a docs-only PR still merges.
- **Sync, dry-run**: `sync.ps1 -WhatIf` lists, per repo, what it would push, delete and merge, and writes nothing. Run it against the real owners before the first real run.
- **End to end**: on a throwaway private repo with the stubs installed and `ref` pinned to a test tag, move the tag to a commit with a changed stub, run the sync, and confirm: PR opened, CI green, merged. Then confirm each hold: a hand-edited stub (drift), `merge: manual`, a commit pushed to the sync branch by hand; each leaves the PR open with the right reason. Then remove a stub from the template and confirm it is deleted. Then a gh-workflows commit that changes no stub: confirm no PR. Then a config with a newline in `verify`: confirm the renderer rejects it.
- **Scheduled task**: a real scheduled run (not "Run now" from a watched session) opens a sync PR **and merges it** with no permission prompt; one with nothing to do ends quietly; one with a held PR notifies.
- **Privacy**: grep this repo for private owner names.
