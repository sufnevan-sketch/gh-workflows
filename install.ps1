<#
.SYNOPSIS  Install the PR review -> fix -> auto-merge stubs into a repo's .github/.
.DESCRIPTION
  Copies stubs/ (thin callers of sufnevan-sketch/gh-workflows reusable workflows),
  the PR template, and a starter .github/review-context.md. Fills the ci stub's
  setup/verify inputs. Never commits, never touches repo settings or secrets.
.EXAMPLE   pwsh install.ps1 -Repo ../02-work/cam/projects/crm -Setup none -Verify "pwsh scripts/verify.ps1"
.EXAMPLE   pwsh install.ps1 -Repo C:\code\website -Setup node-pnpm -Verify "pnpm verify" -Force
.EXAMPLE   pwsh install.ps1 -Repo . -Setup python -Verify "pytest -q" -WithAutoFix -Ref v1
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Repo,
  [ValidateSet('none', 'node-pnpm', 'node-npm', 'python')] [string] $Setup = 'none',
  [string] $Verify = 'pwsh scripts/verify.ps1',
  [string] $Ref = 'main',      # gh-workflows ref the stubs pin: main (rolling) or a tag
  [switch] $WithAutoFix,       # also install auto-fix.yml (needs AUTOFIX_PAT secret)
  [switch] $Force              # overwrite stubs / PR template that already exist (review-context.md is never overwritten)
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$Repo = (Resolve-Path -LiteralPath $Repo).Path
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { throw "$Repo is not a git repo root (no .git). Run from the repo that owns the workflows, not a wrapper." }

$stubs = @('ci.yml', 'claude-review.yml', 'codex-review.yml', 'auto-merge.yml', 'claude.yml')
if ($WithAutoFix) { $stubs += 'auto-fix.yml' }

$dst = Join-Path $Repo '.github'
New-Item -ItemType Directory -Force -Path (Join-Path $dst 'workflows') | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$copied = @(); $skipped = @()

function Write-Lf([string] $Path, [string] $Text) { [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8) }

foreach ($s in $stubs) {
  $to = Join-Path $dst "workflows/$s"
  if ((Test-Path -LiteralPath $to) -and -not $Force) { $skipped += "workflows/$s"; continue }
  $txt = [IO.File]::ReadAllText((Join-Path $src "stubs/$s"))
  $txt = $txt -replace '@main\b', "@$Ref"
  if ($s -eq 'ci.yml') { $txt = $txt.Replace('__SETUP__', $Setup).Replace('__VERIFY__', $Verify) }
  Write-Lf $to $txt
  $copied += "workflows/$s"
}

$prt = Join-Path $dst 'pull_request_template.md'
if ((Test-Path -LiteralPath $prt) -and -not $Force) { $skipped += 'pull_request_template.md' }
else { Write-Lf $prt ([IO.File]::ReadAllText((Join-Path $src 'stubs/pull_request_template.md'))); $copied += 'pull_request_template.md' }

$ctx = Join-Path $dst 'review-context.md'
if (Test-Path -LiteralPath $ctx) { $skipped += 'review-context.md (kept)' }
else { Write-Lf $ctx ([IO.File]::ReadAllText((Join-Path $src 'stubs/review-context.md'))); $copied += 'review-context.md' }

$name = try { (git -C $Repo remote get-url origin) -replace '^.*github\.com[:/]', '' -replace '\.git$', '' } catch { '<owner>/<repo>' }

Write-Host "Copied  : $($copied -join ', ')"
if ($skipped) { Write-Host "Skipped : $($skipped -join ', ')" }
Write-Host "ci stub : setup=$Setup  verify=`"$Verify`"  ref=@$Ref"
Write-Host ""
Write-Host "Edit before committing:"
Write-Host "  .github/review-context.md   -> one paragraph of project context + the contracts reviewers must hold the diff against"
Write-Host ""
Write-Host "Then, from YOUR terminal (never through a Claude Bash tool; non-TTY stdin sets an empty secret):"
Write-Host "  gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $name      # value: claude setup-token"
Write-Host "  gh secret set OPENAI_API_KEY --repo $name               # Codex second review on feat/ fix/ refactor/ perf/ build/ branches"
if ($WithAutoFix) { Write-Host "  gh secret set AUTOFIX_PAT --repo $name                  # fine-grained PAT: Contents + Pull requests RW on this repo" }
Write-Host "  gh secret list --repo $name                              # names + dates only"
Write-Host ""
Write-Host "Repo settings (see README):"
Write-Host "  gh repo edit $name --enable-squash-merge --delete-branch-on-merge"
Write-Host "  (do NOT --enable-auto-merge: without branch protection it merges before checks)"
Write-Host ""
Write-Host "Smoke test: commit .github/ on a docs/ branch, open the PR (merged by hand: it touches workflows), then a fix/ branch PR to see Codex + the gate."
