<#
.SYNOPSIS  Sync the gh-workflows stubs into every repo under -Owners that has .github/gh-workflows.json.
.DESCRIPTION
  Fetches origin, checks out origin/main detached in the runner worktree
  .worktrees/sync-runner (created on first use, refused if it has local changes), and runs
  lib/Invoke-StubSync.ps1 from there, so the code and the stubs both come from origin/main,
  never from this checkout's branch or working tree. Exits with the runner's code
  (0 all current/merged/pending, 1 something held or failed, 2 auth failure or every repo
  failed the same way, or the runner worktree is dirty).
.EXAMPLE   pwsh -NoProfile -File sync.ps1 -Owners octo-org,octo-user -WhatIf
#>
param(
    [string[]]$Owners = @(),
    [switch]$WhatIf,
    [int]$WaitSeconds = 420
)
$ErrorActionPreference = 'Stop'

$runner = Join-Path $PSScriptRoot '.worktrees/sync-runner'
function Invoke-Git([string[]]$GitArgs) {
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) { Write-Output "git $($GitArgs -join ' ') failed"; exit 2 }
}

Invoke-Git @('-C', $PSScriptRoot, 'fetch', '-q', '--tags', 'origin')
if (-not (Test-Path -LiteralPath (Join-Path $runner '.git'))) {
    Invoke-Git @('-C', $PSScriptRoot, 'worktree', 'add', '-q', '--detach', $runner, 'origin/main')
}
if (& git -C $runner status --porcelain) {
    Write-Output "runner worktree $runner has local changes; clean it by hand, then rerun"
    exit 2
}
Invoke-Git @('-C', $runner, 'checkout', '-q', '--detach', 'origin/main')

$runArgs = @('-NoProfile', '-File', (Join-Path $runner 'lib/Invoke-StubSync.ps1'),
    '-Owners', ($Owners -join ','), '-WaitSeconds', $WaitSeconds, '-GhwRoot', $runner)
if ($WhatIf) { $runArgs += '-WhatIf' }
& pwsh @runArgs
exit $LASTEXITCODE
