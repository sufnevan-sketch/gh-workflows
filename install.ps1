<#
.SYNOPSIS  Install the PR review -> fix -> auto-merge stubs into a repo's .github/.
.DESCRIPTION
  Copies stubs/ (thin callers of sufnevan-sketch/gh-workflows reusable workflows),
  the PR template, and a starter .github/review-context.md. Reports whether the repo
  has an AGENTS.md, which is the only file Codex cloud review reads, but never writes
  one: that file is the repo's own, not a CI artifact. Fills the ci stub's
  setup/verify inputs. Never commits, never touches repo settings or secrets.
.EXAMPLE   pwsh install.ps1 -Repo ../02-work/cam/projects/crm -Setup none -Verify "pwsh ./verify.ps1"
.EXAMPLE   pwsh install.ps1 -Repo C:\code\website -Setup node-pnpm -Verify "pnpm verify" -Force
.EXAMPLE   pwsh install.ps1 -Repo . -Setup python -Verify "pytest -q" -WithAutoFix -Ref v1
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Repo,
  [ValidateSet('none', 'node-pnpm', 'node-npm', 'python')] [string] $Setup = 'none',
  [string] $Verify = 'pwsh ./verify.ps1',
  [string] $WorkingDirectory = '',   # subfolder the setup + verify steps run in (wrapper repos, e.g. web)
  [string] $Ref = 'main',      # gh-workflows ref the stubs pin: main (rolling) or a tag
  [switch] $WithAutoFix,       # also install auto-fix.yml + ledger-fix.yml (need AUTOFIX_PAT secret); without it the fix window is 0
  [switch] $Force              # overwrite stubs / PR template that already exist (review-context.md is never overwritten)
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$Repo = (Resolve-Path -LiteralPath $Repo).Path
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { throw "$Repo is not a git repo root (no .git). Run from the repo that owns the workflows, not a wrapper." }

# codex-review.yml (wait: false) and codex-route.yml are a pair: without the route, the Codex verdict never arrives.
$stubs = @('ci.yml', 'claude-review.yml', 'codex-review.yml', 'codex-route.yml', 'auto-merge.yml', 'claude.yml')
if ($WithAutoFix) { $stubs += 'auto-fix.yml', 'ledger-fix.yml' }

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
  # The fix window is auto-fix.yml's time for its non-blocking pass; with no
  # auto-fix stub nothing acts in it, so it would only delay merges.
  $hasAutoFix = $WithAutoFix -or (Test-Path -LiteralPath (Join-Path $dst 'workflows/auto-fix.yml'))
  if ($s -eq 'auto-merge.yml' -and -not $hasAutoFix) { $txt = $txt -replace 'fix-window-minutes: \d+', 'fix-window-minutes: 0' }
  if ($s -eq 'ci.yml') {
    $txt = $txt.Replace('__SETUP__', $Setup).Replace('__VERIFY__', $Verify)
    if ($WorkingDirectory) { $txt = $txt -replace '(?m)^\s*# working-directory: web.*$', "      working-directory: $WorkingDirectory" }
  }
  Write-Lf $to $txt
  $copied += "workflows/$s"
}

# Opt-in upgrade: an auto-merge stub installed earlier without auto-fix has a 0 window,
# and the loop above skips existing files. Turn the window on so the pass has time.
$am = Join-Path $dst 'workflows/auto-merge.yml'
if ($WithAutoFix -and (Test-Path -LiteralPath $am) -and ($skipped -contains 'workflows/auto-merge.yml')) {
  $amTxt = [IO.File]::ReadAllText($am)
  if ($amTxt -match 'fix-window-minutes: 0\b') {
    $new = $amTxt -replace 'fix-window-minutes: 0\b', 'fix-window-minutes: 15'
    if ($new.Length -lt 100 -or $new -notmatch 'uses: sufnevan-sketch/gh-workflows') { throw "refusing to rewrite ${am}: unexpected content" }
    Write-Lf $am $new
    Write-Host "Updated : workflows/auto-merge.yml fix-window-minutes 0 -> 15 (auto-fix needs the window)"
  }
}

$prt = Join-Path $dst 'pull_request_template.md'
if ((Test-Path -LiteralPath $prt) -and -not $Force) { $skipped += 'pull_request_template.md' }
else { Write-Lf $prt ([IO.File]::ReadAllText((Join-Path $src 'stubs/pull_request_template.md'))); $copied += 'pull_request_template.md' }

$ctx = Join-Path $dst 'review-context.md'
if (Test-Path -LiteralPath $ctx) { $skipped += 'review-context.md (kept)' }
else { Write-Lf $ctx ([IO.File]::ReadAllText((Join-Path $src 'stubs/review-context.md'))); $copied += 'review-context.md' }

# Codex cloud mode reads AGENTS.md and never review-context.md, so without one the
# codex check returns a verdict formed with no repo contracts. AGENTS.md is the repo's
# own file, not a CI artifact: report the gap, never write it.
$agentsMissing = -not (Test-Path -LiteralPath (Join-Path $Repo 'AGENTS.md'))

# Repo with no origin: the old `try { git ... } catch { '<owner>/<repo>' }` left
# $name $null, so every instruction below printed an empty repo and the Codex line
# died on .Split() of $null. How that call fails is version-dependent: with
# $PSNativeCommandUseErrorActionPreference $false (pwsh 7.6.6 here) it exits 2 and
# prints nothing; with it $true under $ErrorActionPreference 'Stop' it throws. Catch
# both and test the output, so the fallback does not depend on which is in effect.
$origin = $null
try { $origin = git -C $Repo remote get-url origin 2>$null } catch { $origin = $null }
$name = if ($origin) { $origin -replace '^.*github\.com[:/]', '' -replace '\.git$', '' } else { '<owner>/<repo>' }

Write-Host "Copied  : $($copied -join ', ')"
if ($skipped) { Write-Host "Skipped : $($skipped -join ', ')" }
Write-Host "ci stub : setup=$Setup  verify=`"$Verify`"  ref=@$Ref$(if ($WorkingDirectory) { "  working-directory=$WorkingDirectory" })"
Write-Host ""
Write-Host "Edit before committing:"
Write-Host "  .github/review-context.md   -> one paragraph of project context + the contracts Claude must hold the diff against"
Write-Host ""
$names = if ($WithAutoFix) { 'CLAUDE_CODE_OAUTH_TOKEN,CODEX_TRIGGER_PAT,AUTOFIX_PAT' } else { 'CLAUDE_CODE_OAUTH_TOKEN,CODEX_TRIGGER_PAT' }
Write-Host "Secrets (values in the gitignored env file, pushed by name, never printed):"
Write-Host "  pwsh $PSScriptRoot\set-secrets.ps1 -Repo $name -Names $names"
Write-Host "    CLAUDE_CODE_OAUTH_TOKEN <- claude setup-token (interactive, your terminal)"
Write-Host "    CODEX_TRIGGER_PAT       <- GitHub PAT of your Codex-connected user (comments '@codex review'; bots are ignored)"
if ($WithAutoFix) { Write-Host "    AUTOFIX_PAT             <- fine-grained PAT: Contents + Pull requests + Issues + Workflows RW on this repo (Workflows: a ledger fix may touch .github/workflows/)" }
Write-Host "  gh secret list --repo $name                              # names + dates only"
Write-Host ""
Write-Host "Codex second review (cloud mode, ChatGPT plan, no API key): chatgpt.com -> Codex -> Settings -> Code review:"
Write-Host "  connector installed for '$($name.Split('/')[0])', repo listed, personal Auto review OFF. Codex reads AGENTS.md."
if ($agentsMissing) {
  Write-Warning "No AGENTS.md in this repo. It is the ONLY file Codex reads in cloud mode, so codex / codex-review will pass or fail having seen none of this repo's rules. Write one yourself (the rules a diff can break, kept short) or accept a content-free verdict. This installer will not write it: AGENTS.md is the repo's file, not a CI artifact."
}
Write-Host ""
Write-Host "Repo settings (see README):"
Write-Host "  gh repo edit $name --enable-squash-merge --delete-branch-on-merge"
Write-Host "  (do NOT --enable-auto-merge: without branch protection it merges before checks)"
Write-Host ""
Write-Host "Smoke test: commit .github/ on a docs/ branch, open the PR (merged by hand: it touches workflows), then a fix/ branch PR to see Codex + the gate."
