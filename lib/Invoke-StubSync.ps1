<#
.SYNOPSIS  The stub sync run (two passes). Started by sync.ps1 from the runner worktree.
.DESCRIPTION
  Pass 1, per repo with a .github/gh-workflows.json: render the stubs at the repo's ref,
  decide (Get-SyncAction), then close a superseded sync PR, push the standing sync branch
  and open/update its PR, or record a hold. Pass 2: one shared CI wait for every PR that
  may merge itself; merge each whose `ci / branch-name` and `ci / verify` are green on the
  queued SHA. Prints one line per repo and a SUMMARY line.
  Exit 0: nothing held or failed. 1: something held or failed. 2: gh auth failure, or every
  repo failed with the same message.
  -Sleep and -Now are test seams; the defaults are the real clock.
#>
param(
    [string[]]$Owners = @(),
    [switch]$WhatIf,
    [int]$WaitSeconds = 420,
    [string]$GhwRoot = (Split-Path $PSScriptRoot -Parent),
    [scriptblock]$Sleep = { param($s) Start-Sleep -Seconds $s },
    [scriptblock]$Now = { Get-Date }
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# No -Force: an already-loaded module (and any test mock over it) stays in place.
Import-Module (Join-Path $PSScriptRoot 'StubConfig.psm1')
Import-Module (Join-Path $PSScriptRoot 'StubRender.psm1')
Import-Module (Join-Path $PSScriptRoot 'StubSync.psm1')
Import-Module (Join-Path $PSScriptRoot 'GhApi.psm1')

$LockPath = '.github/gh-workflows.lock'
$CompareBase = 'https://github.com/sufnevan-sketch/gh-workflows/compare'
$PollSeconds = 20

# sync.ps1 passes the owners as one comma-joined argument (pwsh -File cannot pass an array).
$Owners = [string[]]@($Owners | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Owners.Count -eq 0) { Write-Output 'no -Owners given'; exit 2 }

function Test-AuthError($Exception) {
    for ($e = $Exception; $null -ne $e; $e = $e.InnerException) {
        if ($e -is [GhAuthException]) { return $true }
    }
    $false
}

function Get-OneLine([string]$Text) { (($Text -replace '\s*[\r\n]+\s*', ' ').Trim()) }

function Get-Short([string]$Sha) { if ($Sha.Length -gt 7) { $Sha.Substring(0, 7) } else { $Sha } }

function Get-StubName([string]$Path) { $Path -replace '^\.github/workflows/', '' }

function Get-Hashes($Files) {
    $h = [ordered]@{}
    foreach ($k in $Files.Keys) { $h[$k] = Get-TextSha256 ([string]$Files[$k]) }
    $h
}

# The branch is the sync's own when it differs from the default branch only in owned files
# and the lock, and those equal the render named by its own lock (rendered with the default
# branch's config). Ownership is judged by content because every writer is the same login.
function Get-BranchView($State, $Repo, $Config, $Rendered, $Lock, $Pr) {
    $bs = Get-SyncBranchState -Repo $Repo -DefaultBranch $State.DefaultBranch
    if ($null -eq $bs) { return $null }
    # A branch still at the head of the newest sync PR, which was merged, is stale: its
    # content landed (the branch survives a merge the sync could not clean up). Treat it as
    # absent so the next push force-updates it instead of holding it as someone else's.
    if ($null -ne $Pr -and $Pr.Merged -and [string]$Pr.HeadSha -ceq [string]$bs.HeadSha) { return $null }
    $renderSha = $null
    $branchLock = $null
    if ($bs.LockText) {
        try { $branchLock = Read-StubLock $bs.LockText; $renderSha = $branchLock.sha } catch { $renderSha = $null }
    }
    # Only a full commit id is rendered; anything else (e.g. 'HEAD', a branch name) is not ours.
    if ($renderSha -and $renderSha -cnotmatch '^[0-9a-f]{40}\z') { $renderSha = $null }
    $view = [pscustomobject]@{ HeadSha = $bs.HeadSha; IsOwn = $false; RenderSha = $renderSha }
    if (-not $renderSha) { return $view }

    $owned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($k in $Rendered.Keys) { [void]$owned.Add($k) }
    if ($null -ne $Lock) { foreach ($k in $Lock.files.Keys) { [void]$owned.Add($k) } }
    foreach ($k in $branchLock.files.Keys) { [void]$owned.Add($k) }

    foreach ($p in @($bs.ChangedPaths)) {
        if (-not $p) { continue }
        if ($p -cne $LockPath -and -not $owned.Contains($p)) { return $view }
    }

    try {
        $branchRender = Invoke-StubRender -Stubs (Get-StubsAtSha -RepoRoot $GhwRoot -Sha $renderSha) -Config $Config
    } catch {
        return $view   # the branch's lock names a render this checkout cannot reproduce
    }
    if (-not [string]::Equals([string]$bs.LockText, (New-StubLock -Sha $renderSha -Files (Get-Hashes $branchRender)), [StringComparison]::Ordinal)) {
        return $view
    }

    $changed = [System.Collections.Generic.HashSet[string]]::new([string[]]@($bs.ChangedPaths | Where-Object { $_ }), [StringComparer]::Ordinal)
    $paths = [string[]]@($owned)
    $branchFiles = Get-RepoFiles -Repo $Repo -Ref $bs.HeadSha -Paths $paths
    foreach ($p in $paths) {
        if ($branchRender.Contains($p)) {
            if (-not $branchFiles.ContainsKey($p) -or
                -not [string]::Equals([string]$branchFiles[$p], [string]$branchRender[$p], [StringComparison]::Ordinal)) { return $view }
        } elseif ($changed.Contains($p) -and $branchFiles.ContainsKey($p)) {
            return $view   # an owned file the render does not produce was changed, not deleted
        }
    }
    $view.IsOwn = $true
    $view
}

function Get-PrBody($Rendered, $RepoFiles, $Lock, [string]$RenderSha, $Action) {
    $changed = @(foreach ($k in $Rendered.Keys) {
            if (-not $RepoFiles.ContainsKey($k) -or -not [string]::Equals([string]$RepoFiles[$k], [string]$Rendered[$k], [StringComparison]::Ordinal)) { Get-StubName $k }
        })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Renders the gh-workflows stubs at ``$RenderSha`` with this repo's ``.github/gh-workflows.json``.")
    $lines.Add('')
    $lines.Add('Changed stubs: ' + $(if ($changed.Count) { $changed -join ', ' } else { 'none' }))
    if ($Action.Deletes.Count) { $lines.Add('Deleted stubs: ' + ((@($Action.Deletes) | ForEach-Object { Get-StubName $_ }) -join ', ')) }
    $lines.Add("gh-workflows changes: $CompareBase/$($Lock.sha)...$RenderSha")
    if (-not $Action.AutoMerge) {
        $lines.Add('')
        $lines.Add('Waits for a human merge because:')
        foreach ($r in $Action.Reasons) { $lines.Add("- $r") }
    }
    $lines -join "`n"
}

$results = [System.Collections.Generic.List[object]]::new()
$queue = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Repo, [string]$Outcome, [string]$Reason) {
    $results.Add([pscustomobject]@{ Repo = $Repo; Outcome = $Outcome; Reason = (Get-OneLine $Reason) })
}

function Write-Report([string]$Top, [switch]$NoLines) {
    if ($Top) { Write-Output $Top }
    if (-not $NoLines) {
        foreach ($r in $results) { Write-Output ("{0}  {1}  {2}" -f $r.Repo, $r.Outcome, $r.Reason).TrimEnd() }
    }
    $count = { param($o) @($results | Where-Object { $_.Outcome -ceq $o }).Count }
    $pending = @($results | Where-Object { $_.Outcome -ceq 'pending' -or $_.Outcome -like 'would-*' }).Count
    Write-Output ("SUMMARY merged={0} current={1} pending={2} held={3} failed={4}" -f (& $count 'merged'), (& $count 'current'), $pending, (& $count 'held'), (& $count 'failed'))
}

function Exit-Auth($Exception) {
    # The top line says why; the repos already decided still get their lines.
    Write-Report ("gh auth failed, run aborted: " + (Get-OneLine $Exception.Message))
    exit 2
}

# Deletes the sync branch after its PR merged or was closed as superseded. Returns a note
# for the repo line when the delete failed; an auth failure still aborts the run.
function Remove-BranchNote([string]$Repo) {
    try { Remove-SyncBranch -Repo $Repo; '' } catch {
        if (Test-AuthError $_.Exception) { Exit-Auth $_.Exception }
        "; branch not deleted: $(Get-OneLine $_.Exception.Message)"
    }
}

$runStart = & $Now

# ---- Pass 1 -------------------------------------------------------------------------
try {
    $repos = @(Get-SyncRepoList -Owners $Owners)
} catch {
    if (Test-AuthError $_.Exception) { Exit-Auth $_.Exception }
    Write-Report ("listing repos failed: " + (Get-OneLine $_.Exception.Message)) -NoLines
    exit 2
}

$tags = [string[]]@((& git -C $GhwRoot tag -l) | Where-Object { $_ })

foreach ($r in $repos) {
    $repo = [string]$r.FullName
    try {
        $state = Get-SyncRepoState -Repo $repo
        $config = Read-StubConfig ([string]$state.ConfigText)
        $sha = Resolve-StubSha -RepoRoot $GhwRoot -Ref $config.ref
        $stubs = Get-StubsAtSha -RepoRoot $GhwRoot -Sha $sha
        Test-StubConfig -Config $config -StubNames ([string[]]@($stubs.Keys)) -Tags $tags
        $rendered = Invoke-StubRender -Stubs $stubs -Config $config
        $lock = if ($state.LockText) { Read-StubLock ([string]$state.LockText) } else { $null }

        # RepoFiles is exactly the owned stub paths (rendered + default-branch lock), never the lock itself.
        $paths = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $rendered.Keys) { $paths.Add($k) }
        if ($null -ne $lock) { foreach ($k in $lock.files.Keys) { if (-not $paths.Contains($k)) { $paths.Add($k) } } }
        $repoFiles = Get-RepoFiles -Repo $repo -Ref $state.DefaultSha -Paths $paths.ToArray()

        $pr = Get-SyncPr -Repo $repo
        $branch = Get-BranchView $state $repo $config $rendered $lock $pr
        $action = Get-SyncAction -Rendered $rendered -RenderSha $sha -RepoFiles $repoFiles -Lock $lock -Merge $config.merge -Branch $branch -Pr $pr
        $reasons = @($action.Reasons) -join '; '
        $openPr = $null -ne $pr -and $pr.State -eq 'open'

        switch ($action.Action) {
            'current' {
                if ($openPr) {
                    if ($WhatIf) { Add-Result $repo 'current' "would close superseded PR #$($pr.Number)" }
                    else {
                        Close-SyncPr -Repo $repo -Number $pr.Number -Comment "Superseded: stubs already match gh-workflows $(Get-Short $sha)."
                        # `current` is decided before branch ownership: delete only a branch that is the sync's own.
                        Add-Result $repo 'current' "closed superseded PR #$($pr.Number)"
                        $note = if ($null -eq $branch -or $branch.IsOwn) { Remove-BranchNote $repo } else { '; branch kept: changed by someone else' }
                        $results[$results.Count - 1].Reason += $note
                    }
                } else { Add-Result $repo 'current' '' }
            }
            'hold' { Add-Result $repo 'held' $reasons }
            'wait' {
                if ($WhatIf) { Add-Result $repo 'would-merge' "PR #$($pr.Number) when CI is green" }
                else { $queue.Add([pscustomobject]@{ Repo = $repo; Number = [int]$pr.Number; Sha = [string]$branch.HeadSha }) }
            }
            'push' {
                $title = "chore: sync gh-workflows stubs to $(Get-Short $sha)"
                if ($WhatIf) {
                    $what = if ($action.BranchCurrent) { 'open PR (branch already current)' } else { 'push and open PR' }
                    if ($action.Deletes.Count) { $what += '; delete ' + ((@($action.Deletes) | ForEach-Object { Get-StubName $_ }) -join ', ') }
                    if ($action.AutoMerge) { Add-Result $repo 'would-push' "$what; merge when CI is green" }
                    else { Add-Result $repo 'held' "would $what; $reasons" }
                    continue
                }
                if ($action.BranchCurrent) {
                    $pushed = [string]$branch.HeadSha
                } else {
                    $files = [ordered]@{}
                    foreach ($k in $rendered.Keys) { $files[$k] = $rendered[$k] }
                    $files[$LockPath] = New-StubLock -Sha $sha -Files (Get-Hashes $rendered)
                    $pushed = Publish-SyncCommit -Repo $repo -DefaultSha $state.DefaultSha -Files $files -Deletes ([string[]]@($action.Deletes)) -Message $title
                }
                $body = Get-PrBody $rendered $repoFiles $lock $sha $action
                $number = Set-SyncPr -Repo $repo -Base $state.DefaultBranch -Title $title -Body $body
                if ($action.AutoMerge) { $queue.Add([pscustomobject]@{ Repo = $repo; Number = [int]$number; Sha = [string]$pushed }) }
                else { Add-Result $repo 'held' "$reasons (PR #$number)" }
            }
            default { throw "unknown sync action '$($action.Action)'" }
        }
    } catch {
        if (Test-AuthError $_.Exception) { Exit-Auth $_.Exception }
        Add-Result $repo 'failed' $_.Exception.Message
    }
}

# ---- Pass 2: one shared CI wait -------------------------------------------------------
if ($queue.Count -gt 0) {
    $deadline = $runStart.AddSeconds($WaitSeconds)   # the cap covers the whole run, pass 1 included
    $pendingQ = [System.Collections.Generic.List[object]]::new($queue)
    while ($true) {
        foreach ($q in @($pendingQ)) {
            try {
                $ci = Get-CiState -Repo $q.Repo -Sha $q.Sha
                if ($ci.BranchName -eq 'success' -and $ci.Verify -eq 'success') {
                    # The SHA makes GitHub refuse the merge if the PR head moved since the push.
                    Merge-SyncPr -Repo $q.Repo -Number $q.Number -Sha $q.Sha
                    # Record the merge first, so an auth abort during the delete still prints it.
                    Add-Result $q.Repo 'merged' "PR #$($q.Number)"
                    $results[$results.Count - 1].Reason += (Remove-BranchNote $q.Repo)
                    [void]$pendingQ.Remove($q)
                } elseif ($ci.BranchName -eq 'failure' -or $ci.Verify -eq 'failure') {
                    Add-Result $q.Repo 'held' "CI red on PR #$($q.Number) (branch-name $($ci.BranchName), verify $($ci.Verify))"
                    [void]$pendingQ.Remove($q)
                }
            } catch {
                if (Test-AuthError $_.Exception) { Exit-Auth $_.Exception }
                Add-Result $q.Repo 'failed' $_.Exception.Message
                [void]$pendingQ.Remove($q)
            }
        }
        if ($pendingQ.Count -eq 0) { break }
        $left = ($deadline - (& $Now)).TotalSeconds
        if ($left -le 0) { break }
        & $Sleep ([int][Math]::Ceiling([Math]::Min($PollSeconds, $left)))
    }
    foreach ($q in $pendingQ) { Add-Result $q.Repo 'pending' "next run merges PR #$($q.Number)" }
}

# Keep the report in repo order.
$order = @{}
for ($i = 0; $i -lt $repos.Count; $i++) { $order[[string]$repos[$i].FullName] = $i }
$sorted = @($results | Sort-Object { $order[$_.Repo] })
$results.Clear(); foreach ($x in $sorted) { $results.Add($x) }

$failed = @($results | Where-Object { $_.Outcome -ceq 'failed' })
if ($results.Count -gt 0 -and $failed.Count -eq $results.Count -and @($failed.Reason | Select-Object -Unique).Count -eq 1) {
    Write-Report ("every repo failed: " + $failed[0].Reason) -NoLines
    exit 2
}
Write-Report ''
$bad = @($results | Where-Object { $_.Outcome -ceq 'held' -or $_.Outcome -ceq 'failed' }).Count
if ($bad -gt 0) { exit 1 }
exit 0
