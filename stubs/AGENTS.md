<!-- Codex reads THIS file (and only this file) when it reviews a PR in the default
     cloud mode; Claude reads .github/review-context.md. Keep both, carrying the same
     contracts, or one reviewer works blind. Codex caps what it reads at ~2 KB, so this
     is the short form: the rules a diff can break, not an explanation of the project.
     Replace everything below. -->

# AGENTS.md — <repo>

<One or two sentences: what this repo is and what runs in production.> Stack: <languages, frameworks, runtime>. Verify: `<the one command CI runs>`.

## Never
- <The rule whose violation would be worst, first. Name the consequence, not just the rule.>
- <A past incident, in one line: what broke and what it cost. Reviewers weight these heavily.>
- Commit secrets. <Where they actually live.>
- <Edit a migration that already ran / whatever is append-only here.>

## Always
- Keep verification offline: no live services, no secrets. Green must mean the gates ran, never that they were skipped.
- <A change of kind X ships with tests of kind Y in the same diff.>
- <The thing that must be updated in the same commit as its pair.>
