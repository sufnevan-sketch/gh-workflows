<!-- Lead paragraph, no heading, 1-3 sentences, plain English: what changes and what is true once this is merged.
     Written for Evan, who does not read code. No file names, no function names, no jargon. -->

## What this means for you

<!-- One or two lines. What Evan (or a client, a district, a visitor) sees or gets that they did not before. "Nothing visible, internal only" is a valid answer. -->

-

## Changes

<!-- Meaningful changes grouped by area, whole PR, not per commit. Plain words first; a path in parentheses only when it helps the reviewer. -->

-

## Verification

<!-- Only checks that actually ran. Command or method, then the result in plain words. For a relevant check that did not run, say why. No secrets, credentials, client data, or personal data in this table. -->

| Check | Result |
| --- | --- |
| | |

## Risk

<!-- Pick the tier by EFFECTS, not by reading the code. HIGH if ANY of these is true:
     money moves or pricing changes · login/auth/permissions · data deleted or migrated · messages, emails, or posts go out to real people · secrets or tokens · anything a client or district sees that cannot be quietly undone.
     Otherwise LOW. -->

- **Tier:** LOW | HIGH
- **If HIGH, why:**
- **How to undo:** <!-- revert the PR / restore from X / flip flag Y / "cannot be undone: needs Evan before merge" -->
- **Reviewer, look hardest at:** <!-- the one place a bug would hurt most -->

<!-- Review path. Claude reviews every PR (claude-review check). Codex reviews as well (codex-review check) when the branch type says code work: feat/ fix/ refactor/ perf/ build/. Both must pass; the auto-merge gate merges when every check is green.
     HIGH on a non-code branch (docs/ chore/ area-name/): add the label `risk:high` so Codex reviews too.
     If "How to undo" says it cannot be undone, put BLOCKED at the very start of the title so nothing merges until Evan says so.
     Never `gh pr merge --auto` on these repos: no branch protection, so it merges before checks run. -->

## References

<!-- Issue, work order, decision line, source document, preview link. Delete the section if empty. -->

-
