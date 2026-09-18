<#
.SYNOPSIS  Install the PR review -> fix -> auto-merge stubs into a repo's .github/.
.DESCRIPTION
  Copies stubs/ (thin callers of sufnevan-sketch/gh-workflows reusable workflows),
  the PR template, and starters for .github/review-context.md (Claude) and AGENTS.md
  (Codex cloud review, which reads nothing else). Fills the ci stub's
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
  [string] $WorkingDirectory = '',   # subfolder the setup + verify steps run in (wrapper repos, e.g. web)
  [string] $Ref = 'main',      # gh-workflows ref the stubs pin: main (rolling) or a tag
  [switch] $WithAutoFix,       # also install auto-fix.yml (needs AUTOFIX_PAT secret)
  [switch] $Force              # overwrite stubs / PR template that already exist (review-context.md and AGENTS.md are never overwritten)
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
  if ($s -eq 'ci.yml') {
    $txt = $txt.Replace('__SETUP__', $Setup).Replace('__VERIFY__', $Verify)
    if ($WorkingDirectory) { $txt = $txt -replace '(?m)^\s*# working-directory: web.*$', "      working-directory: $WorkingDirectory" }
  }
  Write-Lf $to $txt
  $copied += "workflows/$s"
}

$prt = Join-Path $dst 'pull_request_template.md'
if ((Test-Path -LiteralPath $prt) -and -not $Force) { $skipped += 'pull_request_template.md' }
else { Write-Lf $prt ([IO.File]::ReadAllText((Join-Path $src 'stubs/pull_request_template.md'))); $copied += 'pull_request_template.md' }

$ctx = Join-Path $dst 'review-context.md'
if (Test-Path -LiteralPath $ctx) { $skipped += 'review-context.md (kept)' }
else { Write-Lf $ctx ([IO.File]::ReadAllText((Join-Path $src 'stubs/review-context.md'))); $copied += 'review-context.md' }

# Codex cloud mode reads AGENTS.md and never review-context.md, so a repo without one
# gets a CODEX-REVIEW verdict formed with no contracts at all. Repo root, not .github/.
$agents = Join-Path $Repo 'AGENTS.md'
if (Test-Path -LiteralPath $agents) { $skipped += 'AGENTS.md (kept)' }
else { Write-Lf $agents ([IO.File]::ReadAllText((Join-Path $src 'stubs/AGENTS.md'))); $copied += 'AGENTS.md' }

$name = try { (git -C $Repo remote get-url origin) -replace '^.*github\.com[:/]', '' -replace '\.git$', '' } catch { '<owner>/<repo>' }

Write-Host "Copied  : $($copied -join ', ')"
if ($skipped) { Write-Host "Skipped : $($skipped -join ', ')" }
Write-Host "ci stub : setup=$Setup  verify=`"$Verify`"  ref=@$Ref$(if ($WorkingDirectory) { "  working-directory=$WorkingDirectory" })"
Write-Host ""
Write-Host "Edit before committing:"
Write-Host "  .github/review-context.md   -> one paragraph of project context + the contracts Claude must hold the diff against"
Write-Host "  AGENTS.md                   -> the same contracts in short form, under 2 KB; this is the only file Codex cloud review reads"
Write-Host ""
$names = if ($WithAutoFix) { 'CLAUDE_CODE_OAUTH_TOKEN,CODEX_TRIGGER_PAT,AUTOFIX_PAT' } else { 'CLAUDE_CODE_OAUTH_TOKEN,CODEX_TRIGGER_PAT' }
Write-Host "Secrets (values in the gitignored env file, pushed by name, never printed):"
Write-Host "  pwsh $PSScriptRoot\set-secrets.ps1 -Repo $name -Names $names"
Write-Host "    CLAUDE_CODE_OAUTH_TOKEN <- claude setup-token (interactive, your terminal)"
Write-Host "    CODEX_TRIGGER_PAT       <- GitHub PAT of your Codex-connected user (comments '@codex review'; bots are ignored)"
if ($WithAutoFix) { Write-Host "    AUTOFIX_PAT             <- fine-grained PAT: Contents + Pull requests RW on this repo" }
Write-Host "  gh secret list --repo $name                              # names + dates only"
Write-Host ""
Write-Host "Codex second review (cloud mode, ChatGPT plan, no API key): chatgpt.com -> Codex -> Settings -> Code review:"
Write-Host "  connector installed for '$($name.Split('/')[0])', repo listed, personal Auto review OFF. Codex reads AGENTS.md."
Write-Host ""
Write-Host "Repo settings (see README):"
Write-Host "  gh repo edit $name --enable-squash-merge --delete-branch-on-merge"
Write-Host "  (do NOT --enable-auto-merge: without branch protection it merges before checks)"
Write-Host ""
Write-Host "Smoke test: commit .github/ on a docs/ branch, open the PR (merged by hand: it touches workflows), then a fix/ branch PR to see Codex + the gate."
