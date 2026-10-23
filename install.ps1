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
  [ValidateSet('auto', 'manual')] [string] $Merge = 'auto',   # recorded in .github/gh-workflows.json
  [switch] $WithAutoFix,       # also install auto-fix.yml + ledger-fix.yml (need AUTOFIX_PAT secret); without it the fix window is 0
  [switch] $Adopt,             # infer .github/gh-workflows.json + .lock from an existing install; writes no stub
  [switch] $Force              # overwrite stubs / PR template that already exist (review-context.md is never overwritten)
)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
Import-Module (Join-Path $src 'lib/StubConfig.psm1') -Force
Import-Module (Join-Path $src 'lib/StubRender.psm1') -Force
$Repo = (Resolve-Path -LiteralPath $Repo).Path
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { throw "$Repo is not a git repo root (no .git). Run from the repo that owns the workflows, not a wrapper." }

$dst = Join-Path $Repo '.github'
$utf8 = [Text.UTF8Encoding]::new($false)
$copied = @(); $skipped = @()

function Write-Lf([string] $Path, [string] $Text) { [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8) }
function Invoke-Git([string[]] $GitArgs) {
  $o = & git -C $src @GitArgs
  if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in $src" }
  $o
}

if ($Adopt) {
  # Adoption: an install made by an older install.ps1 has stubs but no config or lock. Infer the
  # config, find the gh-workflows commit the stubs were rendered from, write config + lock only.
  # Never writes a stub, the PR template or review-context.md. GHW_STUB_SHA (test hook) is the head.
  Import-Module (Join-Path $src 'lib/StubAdopt.psm1') -Force
  $adoptCfg = Join-Path $Repo '.github/gh-workflows.json'
  if ((Test-Path -LiteralPath $adoptCfg) -and -not $Force) { throw "$adoptCfg already exists (already adopted). Use -Force to re-infer it." }
  $wfDir = Join-Path $Repo '.github/workflows'
  if (-not (Test-Path -LiteralPath $wfDir)) { throw "$wfDir does not exist: nothing to adopt." }
  $headRef = if ($env:GHW_STUB_SHA) { $env:GHW_STUB_SHA } else { 'origin/main' }
  if (-not $env:GHW_STUB_SHA) { Invoke-Git @('fetch', '-q', '--tags', 'origin') | Out-Null }
  $headSha = (Invoke-Git @('rev-parse', '--verify', "$headRef^{commit}")).Trim()
  $headStubs = Get-StubsAtSha -RepoRoot $src -Sha $headSha
  $current = [ordered]@{}
  foreach ($f in (Get-ChildItem -LiteralPath $wfDir -Filter *.yml -File | Sort-Object { $_.Name } -CaseSensitive)) {
    if (-not $headStubs.ContainsKey($f.Name)) { continue }
    $rel = ".github/workflows/$($f.Name)"
    # Sync compares against the committed blob GitHub serves, not the working copy. A file git
    # calls unchanged from HEAD (core.autocrlf=true puts CRLF on disk) is hashed as its blob;
    # an untracked or edited file as its disk bytes, so a real edit still reads as a difference.
    & git -C $Repo diff --quiet HEAD -- $rel 2>$null
    $clean = $LASTEXITCODE -eq 0
    if ($clean) { & git -C $Repo cat-file -e "HEAD:$rel" 2>$null; $clean = $LASTEXITCODE -eq 0 }
    $current[$rel] = if ($clean) {
      # Raw blob bytes (PowerShell pipes would re-encode them and drop a committed CR).
      $psi = [Diagnostics.ProcessStartInfo]::new('git')
      foreach ($a in @('-C', $Repo, 'cat-file', 'blob', "HEAD:$rel")) { $psi.ArgumentList.Add($a) }
      $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
      $p = [Diagnostics.Process]::Start($psi)
      $ms = [IO.MemoryStream]::new(); $p.StandardOutput.BaseStream.CopyTo($ms); $p.WaitForExit()
      if ($p.ExitCode -ne 0) { throw "git cat-file blob HEAD:$rel failed in $Repo" }
      $utf8.GetString($ms.ToArray())
    } else { $utf8.GetString([IO.File]::ReadAllBytes($f.FullName)) }
  }
  if ($current.Count -eq 0) { throw "No gh-workflows stubs found in $wfDir." }
  $inferred = Get-InferredStubConfig -WorkflowsDir $wfDir -StubNames ([string[]]@($headStubs.Keys)) -Templates $headStubs
  $match = Find-StubRenderMatch -RepoRoot $src -Config $inferred -CurrentFiles $current -HeadRef $headSha
  $adoptTags = [string[]]@((Invoke-Git @('tag', '-l')) | Where-Object { $_ })
  Test-StubConfig -Config $match.Config -StubNames ([string[]]@($headStubs.Keys)) -Tags $adoptTags

  # Matched: the lock holds the current hashes. Not matched: the RENDERED hash for every differing
  # path (so sync sees the file as modified), the current hash elsewhere.
  $adoptLock = [ordered]@{}
  foreach ($k in $current.Keys) {
    $adoptLock[$k] = if (-not $match.Matched -and $match.Differences -ccontains $k -and $match.Rendered.Contains($k)) { Get-TextSha256 $match.Rendered[$k] } else { Get-TextSha256 $current[$k] }
  }
  foreach ($k in $match.Differences) { if (-not $adoptLock.Contains($k) -and $match.Rendered.Contains($k)) { $adoptLock[$k] = Get-TextSha256 $match.Rendered[$k] } }

  Write-Lf $adoptCfg (ConvertTo-StubConfigJson $match.Config)
  Write-Lf (Join-Path $Repo '.github/gh-workflows.lock') (New-StubLock -Sha $match.Sha -Files $adoptLock)
  Write-Host "Adopted : .github/gh-workflows.json, .github/gh-workflows.lock (no stub written)"
  if ($match.Matched) { Write-Host "Match   : stubs are byte-identical to a render at $($match.Sha)" }
  else {
    Write-Host "Match   : none; lock sha = $($match.Sha) (head). Differences from a render at head:"
    foreach ($d in $match.Differences) { Write-Host "  $d" }
    Write-Host "  (the lock holds the rendered hash for these, so sync will update them)"
  }
  Write-Host ""
  Write-Host "Next    : on a chore/ branch commit .github/gh-workflows.json and .github/gh-workflows.lock, open the PR,"
  Write-Host "          and merge it by hand (the gate refuses PRs that touch these files)."
  return
}

New-Item -ItemType Directory -Force -Path (Join-Path $dst 'workflows') | Out-Null

# An existing .github/gh-workflows.json is the base config; only parameters passed explicitly override it.
$cfgPath = Join-Path $dst 'gh-workflows.json'
if (Test-Path -LiteralPath $cfgPath) {
  $config = Read-StubConfig ($utf8.GetString([IO.File]::ReadAllBytes($cfgPath)))
  foreach ($p in @(@('Setup', 'setup', $Setup), @('Verify', 'verify', $Verify), @('WorkingDirectory', 'working-directory', $WorkingDirectory), @('Ref', 'ref', $Ref), @('Merge', 'merge', $Merge))) {
    if ($PSBoundParameters.ContainsKey($p[0])) { $config.($p[1]) = $p[2] }
  }
  if ($WithAutoFix) { $config.'auto-fix' = $true }
  $config = Read-StubConfig (ConvertTo-StubConfigJson $config)   # re-validate the merged result
} else {
  # The fix window is auto-fix.yml's time for its non-blocking pass; with no auto-fix stub
  # nothing acts in it, so an existing auto-fix.yml keeps the window on.
  $autoFix = $WithAutoFix.IsPresent -or (Test-Path -LiteralPath (Join-Path $dst 'workflows/auto-fix.yml'))
  $cfgIn = [ordered]@{ ref = $Ref; setup = $Setup; verify = $Verify; merge = $Merge; 'auto-fix' = $autoFix }
  if ($WorkingDirectory) { $cfgIn['working-directory'] = $WorkingDirectory }
  $config = Read-StubConfig ($cfgIn | ConvertTo-Json)
}

# Stubs come from git objects at a resolved SHA (origin/main, or the tag the config pins), never the working tree.
# GHW_STUB_SHA is a test hook: it replaces the resolved SHA so tests need no network.
if (-not $env:GHW_STUB_SHA) { Invoke-Git @('fetch', '-q', '--tags', 'origin') | Out-Null }
# The render SHA (last commit touching stubs/ at or before the ref) is what the lock records.
$sha = Get-StubRenderSha -RepoRoot $src -Sha (Resolve-StubSha -RepoRoot $src -Ref $config.ref)
$stubText = Get-StubsAtSha -RepoRoot $src -Sha $sha
$tags = [string[]]@((Invoke-Git @('tag', '-l')) | Where-Object { $_ })
Test-StubConfig -Config $config -StubNames ([string[]]@($stubText.Keys)) -Tags $tags
$rendered = Invoke-StubRender -Stubs $stubText -Config $config

$lockFiles = [ordered]@{}
foreach ($key in $rendered.Keys) {
  $rel = $key -replace '^\.github/', ''
  $to = Join-Path $Repo $key
  if ((Test-Path -LiteralPath $to) -and -not $Force) {
    $skipThis = $true
    # Opt-in upgrade: an auto-merge stub installed earlier without auto-fix has a 0 window.
    # Rewrite it only when it is still the pristine render of the same config without auto-fix.
    if ($WithAutoFix -and $key -ceq '.github/workflows/auto-merge.yml') {
      $onDisk = $utf8.GetString([IO.File]::ReadAllBytes($to))
      $prev = $config.PSObject.Copy(); $prev.'auto-fix' = $false
      $prevRender = Invoke-StubRender -Stubs $stubText -Config $prev
      if ($prevRender.Contains($key) -and $onDisk -ceq $prevRender[$key]) {
        Write-Lf $to $rendered[$key]
        Write-Host "Updated : workflows/auto-merge.yml fix-window-minutes 0 -> 15 (auto-fix needs the window)"
        $skipThis = $false
      } else {
        Write-Warning "workflows/auto-merge.yml differs from a pristine install, so it was not rewritten. Set its fix-window-minutes to 15 by hand (auto-fix needs the window), or rerun with -Force."
      }
    }
    if ($skipThis) { $skipped += $rel }
  } else {
    Write-Lf $to $rendered[$key]
    $copied += $rel
  }
  # The lock records the RENDER, not the disk, so a hand-edited stub reads as modified to sync.
  $lockFiles[$key] = Get-TextSha256 $rendered[$key]
}

Write-Lf $cfgPath (ConvertTo-StubConfigJson $config)
Write-Lf (Join-Path $dst 'gh-workflows.lock') (New-StubLock -Sha $sha -Files $lockFiles)
$copied += 'gh-workflows.json', 'gh-workflows.lock'

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
# The merged config (an existing gh-workflows.json plus explicit parameters), not the parameter defaults.
Write-Host "ci stub : setup=$($config.setup)  verify=`"$($config.verify)`"  ref=@$($config.ref)$(if ($config.'working-directory') { "  working-directory=$($config.'working-directory')" })"
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
