# gh-workflows

Reusable GitHub Actions for one operator's repos: Claude reviews every PR as a red/green check, Codex gives a second review on code branches, the local Claude Code session fixes findings until green, and a gate workflow squash-merges. Public so that private repos under any owner can call it; it holds no secrets and no client data.

Each repo keeps only thin stubs under `.github/workflows/` that call the workflows here. Change a workflow here, every repo runs the new version on its next PR. No copies, no drift.

## Layout

| Path | What |
|---|---|
| `.github/workflows/ci.yml` | reusable: `branch-name` (enforces `<type>/<short-description>`) + `verify` (optional toolchain, then the repo's one verify command) |
| `.github/workflows/claude-review.yml` | reusable: Claude reviews, posts inline findings, submits `AUTO-REVIEW: PASS` or `CHANGES REQUESTED`; a gate step turns that into the job's exit code |
| `.github/workflows/codex-review.yml` | reusable: Codex second review on `feat/ fix/ refactor/ perf/ build/` branches or PRs labeled `codex-review` / `risk:high`. Default `mode: cloud` = Codex cloud code review from the ChatGPT plan (the job comments `@codex review`, waits for the bot's review, red on any P0/P1 finding). `mode: action` = `openai/codex-action@v1` with an API key. Either way: `CODEX-REVIEW: PASS` or `CHANGES REQUESTED`, red/green |
| `.github/workflows/auto-merge.yml` | reusable: squash-merges when every check on the head SHA is green, required checks present, Codex present where the branch rule applies |
| `.github/workflows/claude.yml` | reusable: `@claude` mention handler |
| `.github/workflows/auto-fix.yml` | reusable, opt-in: Claude fixes CHANGES REQUESTED in CI, max 3 rounds, needs `AUTOFIX_PAT` |
| `.github/workflows/self-check.yml` | this repo's CI: actionlint on workflows and stubs, stub references resolve, script bodies parse |
| `.github/workflows/self-review.yml` | this repo dogfoods `claude-review` + `codex-review` on its own PRs |
| `stubs/*.yml` | what a calling repo gets: triggers + `uses:` + inputs, nothing else |
| `stubs/review-context.md` | starter for the one per-repo file the reviewers read |
| `stubs/pull_request_template.md` | PR body written for a reader who does not read code |
| `install.ps1` | copies the stubs into a repo, fills the ci inputs |
| `set-secrets.ps1` | pushes named secrets from a gitignored env file to the repo with `gh secret set --body`; values never printed |

## Install into a repo

```powershell
pwsh install.ps1 -Repo <repo-root> -Setup none|node-pnpm|node-npm|python -Verify "<one command>"
```

Then in the repo:

1. Fill `.github/review-context.md`: one paragraph of what the repo is, its stack, and the contracts a reviewer must hold the diff against. Both reviewers read it from the **base** branch, so a PR cannot rewrite its own reviewer's instructions.
2. Secrets, before the PR. Values live once in a gitignored env file (default `EVAN_WORKSPACE/.env`, line `CLAUDE_CODE_OAUTH_TOKEN=`); the helper pushes them by name with `gh secret set --body` and never prints them:

```powershell
pwsh set-secrets.ps1 -Repo <owner>/<repo>            # -Names CLAUDE_CODE_OAUTH_TOKEN,AUTOFIX_PAT with auto-fix; add OPENAI_API_KEY only for codex mode: action
gh secret list --repo <owner>/<repo>
```

   `CLAUDE_CODE_OAUTH_TOKEN` comes from `claude setup-token` (interactive, run it yourself). Do not run `gh secret set` interactively from a non-TTY tool: it stores an empty value silently.
3. The **Claude Code GitHub App** must cover the repo, or `claude / claude-review` fails after ~30s with `Claude Code is not installed on this repository`. The OAuth token authenticates you; the App is what grants the action a token for THIS repo, and the two are independent. An install scoped to "selected repositories" silently excludes every new repo. Check it before the PR:

   ```bash
   gh api orgs/<org>/installations --jq '.installations[] | select(.app_slug=="claude") | .repository_selection'
   ```

   `all` is fine. `selected` means someone must add the repo at `github.com/organizations/<org>/settings/installations` → Claude → Repository access (a user account uses `github.com/settings/installations`). Verified 2026-09-17: three `camedu-io` repos had both secrets set and still failed this way until the install was widened to all.
4. Codex (cloud mode, the default, no API key): in chatgpt.com → Codex → Settings → Code review, the GitHub connector must be installed for the repo's owner and the repo must appear in the list; keep personal **Auto review OFF** so Codex reviews only the PRs this workflow asks about (`@codex review`), never business PRs. The ask must come from a human account connected to Codex: Codex ignores mentions by `github-actions[bot]` (verified 2026-09-17), so the secret `CODEX_TRIGGER_PAT` is required: a GitHub PAT of the connected user with permission to comment on the repo (fine-grained: Pull requests read/write + Issues read/write on the chosen repos, or classic `repo`). One PAT can cover every installed repo; push it with `set-secrets.ps1 -Names CLAUDE_CODE_OAUTH_TOKEN,CODEX_TRIGGER_PAT`. Codex reads the repo's `AGENTS.md`, so repo contracts for Codex go there (2 KB cap). `OPENAI_API_KEY` is needed only with `mode: action`.
5. Commit `.github/` on a `docs/` branch and open the PR. The gate never auto-merges a PR that touches `.github/workflows/**`, so merge this one by hand; it is the smoke test for `ci / verify` and `claude / claude-review`. A second PR on a `fix/` branch exercises Codex and the gate.

### Why the stubs name every secret instead of `secrets: inherit`

GitHub passes inherited secrets only to a reusable workflow **in the same organization or enterprise** as the caller. This repo lives under a user account, so a caller in any org inherits nothing and the job dies in 2 seconds with `Secret CLAUDE_CODE_OAUTH_TOKEN is required, but not provided while calling` — the repo's secrets are set and present; they are simply never handed over. Verified 2026-09-17 on `camedu-io/district-intel` PR #1, where `gh secret list` showed both secrets and a rerun failed identically.

So each stub passes what its callee declares, by name:

| Stub | Passes |
|---|---|
| `claude-review.yml`, `claude.yml` | `CLAUDE_CODE_OAUTH_TOKEN` |
| `codex-review.yml` | `CODEX_TRIGGER_PAT` (add `OPENAI_API_KEY` only with `mode: action`) |
| `auto-fix.yml` | `CLAUDE_CODE_OAUTH_TOKEN`, `AUTOFIX_PAT` |
| `auto-merge.yml` | nothing — the callee declares no secrets, so it has no `secrets:` block at all |

Naming a secret the repo has not set is safe: it resolves empty, and a callee that declares it `required: false` runs anyway. Naming one the callee does not declare is a hard config error, which is why `auto-merge.yml` must stay bare. `self-review.yml` keeps `inherit` because it calls workflows in this same repo.

Per-repo variance is exactly: the ci stub's `setup` / `verify` (and `working-directory` for wrapper repos), and `review-context.md`. Everything else is here.

## Check names

A reusable job shows up as `<stub job id> / <job name>`. The stubs fix the ids, so the gate's defaults match:

| Check | From |
|---|---|
| `ci / branch-name`, `ci / verify` | `stubs/ci.yml` |
| `claude / claude-review` | `stubs/claude-review.yml` |
| `codex / codex-review` | `stubs/codex-review.yml` |
| `gate / auto-merge` | `stubs/auto-merge.yml` (excluded from its own evaluation) |

Rename a stub job id and you must pass matching `required-checks` / `codex-check` inputs to the gate.

## Repo settings the gate needs, and the ones it cannot use

On a private repo on GitHub's free plan there is no branch protection and no rulesets (`gh api repos/<r>/branches/main/protection` returns 403 "Upgrade to GitHub Pro or make this repository public"). Consequences:

| Setting | Do |
|---|---|
| Required status checks | unavailable; `auto-merge.yml` is the required check, `required-checks` is the list |
| Allow auto-merge (`gh repo edit --enable-auto-merge`) | **leave off.** Without required checks, `gh pr merge --auto` merges the instant it is called, before CI runs. Never use `--auto` on these repos. |
| Squash merge | on (`merge-method` input) |
| Delete branch on merge | optional; the gate deletes the head branch itself (`delete-branch` input) |
| Actions → Workflow permissions | default read is fine; every workflow declares its own `permissions:` |
| Actions → Allowed actions (org policy) | must permit `sufnevan-sketch/gh-workflows`, `anthropics/claude-code-action`, `openai/codex-action`, and `rhysd/actionlint` (self-check only). An org that restricts to verified creators blocks the first call; the smoke-test PR shows it. |

If a repo moves to Pro or public: add branch protection on `main` with required checks `ci / verify`, `claude / claude-review` (and `codex / codex-review` if desired); then `--enable-auto-merge` plus `gh pr merge --auto --squash` becomes safe and the gate is redundant, not wrong.

## How the loop runs

```
push to PR branch
  ├─ CI (ci / branch-name, ci / verify)          ─┐
  ├─ Claude Code Review (claude / claude-review)  ┼─ each completion fires ─► auto-merge (gate / auto-merge)
  └─ Codex Review (codex / codex-review)         ─┘                          all checks on head SHA green
        only on feat/ fix/ refactor/ perf/ build/                            + required checks present
        or label codex-review / risk:high                                    + codex present when that rule applies
        each reviewer posts ONE review, first line                           + no human CHANGES_REQUESTED
        AUTO-REVIEW: | CODEX-REVIEW: PASS | CHANGES REQUESTED                + not draft / BLOCKED / wo/* / fork
        verdict → job green or red                                           + no .github/workflows/** in diff
   any red review ──► local Claude Code session fixes ──► push ──► loop
                      (or auto-fix, opt-in, ≤3 rounds)                       ──► squash merge, comment, branch deleted
```

Who reviews what is decided by the branch name (`<type>/<short-description>`):

| Branch type | Claude | Codex | Why |
|---|---|---|---|
| `feat/` `fix/` `refactor/` `perf/` `build/` | yes | yes | code work; two model families catch different bugs |
| `docs/` `chore/` `spike/`, area names, `wo/` | yes | only with label `codex-review` or `risk:high` | business, housekeeping, exploration; `wo/` has its own harness evaluator |
| anything else | `ci / branch-name` fails; rename the branch | | |

Why `workflow_run` and not `check_suite` for the gate: GitHub does not fire `check_suite` / `check_run` events for suites created by Actions (documented recursion guard). An earlier gate with that trigger fired 0 times in 15 runs; every merge came from a PAT-posted review. Here verdicts are posted with the default `GITHUB_TOKEN` and the chain is `workflow_run`, so the merge path needs no PAT. Only `auto-fix` needs one, because a push made with `GITHUB_TOKEN` does not re-trigger CI or the reviews.

### The local fix loop (Claude Code session, after opening a PR)

```bash
gh pr checks <n> --watch --fail-fast
gh api repos/<owner>/<repo>/pulls/<n>/reviews --jq '.[] | select(.body | test("^(AUTO|CODEX)-REVIEW")) | .body'
gh api repos/<owner>/<repo>/pulls/<n>/comments --jq '.[] | "\(.path):\(.line // .original_line) \(.body)"'
```

Fix every CRITICAL/HIGH, run the verify command, commit, push. `synchronize` re-runs the checks; when all are green the gate merges within about a minute of the last completion. Reply on a comment instead of changing code when a finding is a false positive. If the gate does not merge, read the `gate / auto-merge` run log: every skip reason is logged as `#<n>: <reason>, skip`. `gh workflow run auto-merge` re-evaluates every open PR.

### Holds

- `BLOCKED` at the start of the PR title or body: the gate skips it; merge by hand. Reserved for changes that cannot be undone after merge (the PR template's "How to undo" line says so).
- Draft PRs: not reviewed, not merged, until marked ready.
- Any PR that changes `.github/workflows/**`: human merge.
- Head branch under `skip-branch-prefixes` (`wo/`): the solo-harness `ship.ps1` waits on the same checks and merges these itself; the gate stays out to avoid a double-merge race.
- A human `CHANGES_REQUESTED` review blocks until that reviewer approves or dismisses.
- Kill switch: delete the repo's `auto-merge.yml` stub.

## Changing a workflow here

Branch (`fix/...` or `feat/...`), PR, let `self-check` and `self-review` run, merge by hand (every PR here touches workflows). Stubs pin `@main`, so the change is live for every repo on its next PR. If a change must roll out gradually, tag a release (`v1`) and install stubs with `-Ref v1`.

## Verdict log

- [2026-09-17] camedu-io/crm PR #5 (docs/ + label `codex-review`, smoke test 2) | every check green, Codex reviewed via the label path in 2m44s, and the gate still refused: `not green on b83a391 (failed: [codex / codex-review=cancelled])`. The PR was created with the label, so `opened` and `labeled` fired one second apart and the concurrency group cancelled the first codex run, leaving a dead check run on the SHA next to the green one | Lesson: the gate counted every check run on the head SHA, superseded ones included, so one cancelled run blocked the merge permanently. It now keeps only the newest run per check name, the way GitHub's own checks UI does.
- [2026-09-17] camedu-io/ai-os PR #2 (docs/, install) + PR #3 (fix/, smoke test 2) | install green first try with `setup: node-npm` + `working-directory: scripts/hours-sync` (51 tests, npm cache); PR #3 fixed a path assertion that only passed on Linux, and `gate / auto-merge` squash-merged it unattended | Lesson: `-WorkingDirectory` is the right shape for a repo whose only code sits in one subfolder; no verify.ps1 needed.
- [2026-09-17] camedu-io/district-intel PR #2 (fix/, smoke test 2) | `ci / *` green, Codex PASS, `claude / claude-review` PASS in 2m, `gate / auto-merge` squash-merged 11s after the last check completed, with no human action. First fully automatic merge on a camedu-io repo | Lesson: `claude / claude-review` needs the Claude Code GitHub App to cover the repo, separately from the OAuth token secret. An org install scoped to "selected repositories" fails every new repo with `Claude Code is not installed on this repository` after ~30s; now step 3 of the install.
- [2026-09-17] camedu-io/district-intel PR #2 (fix/, the trivial-edit smoke test) | `ci / *` green; `codex / codex-review` asked with the PAT and Codex reviewed the commit in 84s with no findings, then the wait step sat until its timeout | Lesson: a clean Codex cloud review posts NO review object, only an issue comment carrying `Reviewed commit: <sha10>`. Polling `pulls/N/reviews` alone only ever succeeds on a PR Codex had something to say about. The wait (and the idempotency check) now accept either shape.
- [2026-09-17] camedu-io/district-intel PR #1 (docs/, install itself) | `ci / branch-name` + `ci / verify` green on first run (196 pytest in 34s, via `pwsh scripts/verify.ps1` wrapping the dummy `SUPABASE_*` env the stub cannot inject); `codex / codex-review` correctly skipped for `docs/`; `claude / claude-review` failed in 2s on a set-and-present secret, twice, including after `gh run rerun` | Lesson: `secrets: inherit` is same-org-or-enterprise only. Every caller outside `sufnevan-sketch` inherits nothing. Stubs now pass each secret by name; `auto-merge.yml` stays bare because its callee declares none. First install under a different owner, which is what surfaced it.
- [2026-09-17] sufnevan-sketch/evan-workspace PR #3, round 2 with CODEX_TRIGGER_PAT set | Claude PASS 2m08s; Codex cloud review triggered by the PAT-authored `@codex review`, reviewed in 2m43s, one P2 (non-blocking), `CODEX-REVIEW: PASS`; `gate / auto-merge` squash-merged and deleted the branch with no human action. First fully automatic merge through the loop. | Lesson: the whole install is: stubs + review-context + verify command + two secrets (Claude token, Codex-connected user's PAT) + repo listed in Codex settings.
- [2026-09-17] sufnevan-sketch/evan-workspace PR #3 (fix/ branch) | `ci / *` green; `claude / claude-review` PASS in 3m56s with one real inline MEDIUM (BOM bytes uncounted), fixed in the next push; `gate / auto-merge` ran and correctly waited on Codex; `codex / codex-review` (cloud) got the bot reply "To use Codex here, create a Codex account and connect to github" | Lessons: (1) Codex ignores `@codex review` from `github-actions[bot]`; `CODEX_TRIGGER_PAT` is required, now fail-fast. (2) claude-code-action skips any PR that changes a workflow file; install PRs are hand-merge, now reported as a warning instead of "no verdict".

One line per install: `[YYYY-MM-DD] <repo> | <what happened on the smoke-test PRs> | <lesson, if any>`.

- [2026-09-17] sufnevan-sketch/evan-workspace PR #2 (chore/ branch, install itself) | `ci / branch-name` + `ci / verify` green on first run (verify.ps1 output visible in CI), `codex / codex-review` correctly skipped for chore/, `claude / claude-review` failed in 2s: "Secret CLAUDE_CODE_OAUTH_TOKEN is required, but not provided" because no secret was set yet | Lesson: set both secrets BEFORE opening PR 1, or expect one `gh run rerun` after setting them. Reusable-workflow calls from a private repo to this public repo resolve with no extra settings.
