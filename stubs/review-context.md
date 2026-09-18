<!-- Project context for the Claude PR reviewer. Read from the base branch, so a PR cannot edit its own reviewer's instructions.
     Codex does NOT read this file in the default cloud mode: it reads the repo's AGENTS.md (2 KB cap). Only codex-review's
     `mode: action` loads this one. Give a repo BOTH, with the same contracts, or Codex reviews with none of them.
     One short paragraph plus the contracts. Replace everything below. -->

This repo is <what it is, for whom>. Stack: <languages, frameworks, runtime>. Verify command: <the one command>.

Contracts the diff must honor:

- <AGENTS.md hard rules, if any>
- <schema / migration conventions, e.g. every migration has a paired .down.sql and updates types.ts>
- <design or copy contract, e.g. rendered text must match content/copy/ verbatim>
- <anything that must never change without a human: payments, auth, secrets handling>

Reviewer priorities specific to this repo (beyond correctness, acceptance criteria, tests):

- <e.g. no network calls in tests; offline only>
- <e.g. district-facing output must cite a source document>
