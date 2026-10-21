BeforeAll {
    Import-Module "$PSScriptRoot/../lib/StubRender.psm1" -Force
    Import-Module "$PSScriptRoot/../lib/StubSync.psm1" -Force

    $script:A = '.github/workflows/a.yml'
    $script:B = '.github/workflows/b.yml'
    $script:Old = '.github/workflows/old.yml'

    function script:New-Rendered([hashtable]$Files) {
        $o = [ordered]@{}
        foreach ($k in ($Files.Keys | Sort-Object)) { $o[$k] = $Files[$k] }
        $o
    }
    function script:New-LockObj([hashtable]$Files, [string]$Sha = 'old-render') {
        $h = @{}
        foreach ($k in $Files.Keys) { $h[$k] = Get-TextSha256 $Files[$k] }
        [pscustomobject]@{ sha = $Sha; files = $h }
    }
    function script:Invoke-Sync {
        param($Rendered, $RepoFiles, $Lock, $Merge = 'auto', $Branch = $null, $Pr = $null, [string]$RenderSha = 'new-render')
        Get-SyncAction -Rendered $Rendered -RenderSha $RenderSha -RepoFiles $RepoFiles -Lock $Lock -Merge $Merge -Branch $Branch -Pr $Pr
    }
    # Repo state: lock matches repo; render differs from repo (a template change).
    $script:OldFiles = @{ $script:A = "a1`n"; $script:B = "b1`n" }
    $script:NewRendered = New-Rendered @{ $script:A = "a2`n"; $script:B = "b1`n" }
    $script:GoodLock = New-LockObj $script:OldFiles
}

Describe 'Get-SyncAction' {
    It 'no lock (never adopted) is reported as hold not adopted' {
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $null
        $r.Action | Should -Be 'hold'
        $r.Reasons | Should -Contain 'not adopted'
    }

    It 'identical rendered and repo files are current' {
        $r = Invoke-Sync -Rendered (New-Rendered $OldFiles) -RepoFiles $OldFiles -Lock $GoodLock
        $r.Action | Should -Be 'current'
        $r.Reasons.Count | Should -Be 0
        $r.AutoMerge | Should -BeFalse
    }

    It 'different text with same keys is not current' {
        (Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock).Action | Should -Not -Be 'current'
    }

    It 'comparison is exact: trailing newline difference is not current' {
        $repo = @{ $A = "a2`n"; $B = "b1" }
        (Invoke-Sync -Rendered $NewRendered -RepoFiles $repo -Lock $GoodLock).Action | Should -Not -Be 'current'
    }

    It 'extra owned file in repo (key set differs) is not current' {
        $repo = @{ $A = "a2`n"; $B = "b1`n"; $Old = "x`n" }
        (Invoke-Sync -Rendered $NewRendered -RepoFiles $repo -Lock $GoodLock).Action | Should -Not -Be 'current'
    }

    It 'closed unmerged PR for same render is not reopened' {
        $pr = [pscustomobject]@{ Number = 5; State = 'closed'; Merged = $false; HeadSha = 'h'; LockSha = 'new-render' }
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Pr $pr
        $r.Action | Should -Be 'hold'
        $r.Reasons | Should -Contain 'closed by hand'
    }

    It 'closed unmerged PR for an older render pushes again' {
        $pr = [pscustomobject]@{ Number = 5; State = 'closed'; Merged = $false; HeadSha = 'h'; LockSha = 'older-render' }
        (Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Pr $pr).Action | Should -Be 'push'
    }

    It 'sync branch changed by someone else holds' {
        $br = [pscustomobject]@{ HeadSha = 'bh'; IsOwn = $false; RenderSha = $null }
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Branch $br
        $r.Action | Should -Be 'hold'
        $r.Reasons | Should -Contain 'sync branch changed by someone else'
    }

    It 'closed-by-hand wins over a foreign branch' {
        $br = [pscustomobject]@{ HeadSha = 'bh'; IsOwn = $false; RenderSha = $null }
        $pr = [pscustomobject]@{ Number = 5; State = 'closed'; Merged = $false; HeadSha = 'h'; LockSha = 'new-render' }
        (Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Branch $br -Pr $pr).Reasons | Should -Contain 'closed by hand'
    }

    It 'clean repo with merge auto is pushed with AutoMerge true' {
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock
        $r.Action | Should -Be 'push'
        $r.AutoMerge | Should -BeTrue
        $r.BranchCurrent | Should -BeFalse
        $r.Reasons.Count | Should -Be 0
        $r.Deletes.Count | Should -Be 0
    }

    It 'merge manual is pushed with AutoMerge false and a reason' {
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Merge manual
        $r.Action | Should -Be 'push'
        $r.AutoMerge | Should -BeFalse
        $r.Reasons | Should -Contain 'merge: manual'
    }

    It 'lock key missing from repo is drift' {
        $repo = @{ $A = "a1`n" }
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $repo -Lock $GoodLock
        $r.AutoMerge | Should -BeFalse
        ($r.Reasons -join ';') | Should -Match 'b\.yml'
    }

    It 'hand-edited lock key is drift and named' {
        $repo = @{ $A = "a1 edited`n"; $B = "b1`n" }
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $repo -Lock $GoodLock
        $r.AutoMerge | Should -BeFalse
        ($r.Reasons -join ';') | Should -Match 'a\.yml'
        ($r.Reasons -join ';') | Should -Not -Match 'b\.yml'
    }

    It 'deleted stub with unchanged file is deleted' {
        $files = @{ $A = "a1`n"; $Old = "old`n" }
        $lock = New-LockObj $files
        $rendered = New-Rendered @{ $A = "a2`n" }
        $r = Invoke-Sync -Rendered $rendered -RepoFiles $files -Lock $lock
        $r.Action | Should -Be 'push'
        $r.Deletes | Should -Be @($Old)
        $r.AutoMerge | Should -BeTrue
    }

    It 'deleted stub with edited file is drift, not deleted' {
        $files = @{ $A = "a1`n"; $Old = "old`n" }
        $lock = New-LockObj $files
        $repo = @{ $A = "a1`n"; $Old = "old edited`n" }
        $rendered = New-Rendered @{ $A = "a2`n" }
        $r = Invoke-Sync -Rendered $rendered -RepoFiles $repo -Lock $lock
        $r.Deletes.Count | Should -Be 0
        $r.AutoMerge | Should -BeFalse
        ($r.Reasons -join ';') | Should -Match 'old\.yml'
    }

    It 'own branch at this render with open PR and AutoMerge waits' {
        $br = [pscustomobject]@{ HeadSha = 'bh'; IsOwn = $true; RenderSha = 'new-render' }
        $pr = [pscustomobject]@{ Number = 5; State = 'open'; Merged = $false; HeadSha = 'bh'; LockSha = 'new-render' }
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Branch $br -Pr $pr
        $r.Action | Should -Be 'wait'
        $r.AutoMerge | Should -BeTrue
    }

    It 'own branch at this render with open PR and no AutoMerge holds with the reasons' {
        $br = [pscustomobject]@{ HeadSha = 'bh'; IsOwn = $true; RenderSha = 'new-render' }
        $pr = [pscustomobject]@{ Number = 5; State = 'open'; Merged = $false; HeadSha = 'bh'; LockSha = 'new-render' }
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Merge manual -Branch $br -Pr $pr
        $r.Action | Should -Be 'hold'
        $r.Reasons | Should -Contain 'merge: manual'
    }

    It 'own branch at an older render pushes' {
        $br = [pscustomobject]@{ HeadSha = 'bh'; IsOwn = $true; RenderSha = 'older-render' }
        $pr = [pscustomobject]@{ Number = 5; State = 'open'; Merged = $false; HeadSha = 'bh'; LockSha = 'older-render' }
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Branch $br -Pr $pr
        $r.Action | Should -Be 'push'
        $r.BranchCurrent | Should -BeFalse
    }

    It 'own branch at this render with no PR pushes with BranchCurrent true' {
        $br = [pscustomobject]@{ HeadSha = 'bh'; IsOwn = $true; RenderSha = 'new-render' }
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Branch $br
        $r.Action | Should -Be 'push'
        $r.BranchCurrent | Should -BeTrue
    }

    It 'own branch at this render with PR closed for an older render pushes with BranchCurrent true' {
        $br = [pscustomobject]@{ HeadSha = 'bh'; IsOwn = $true; RenderSha = 'new-render' }
        $pr = [pscustomobject]@{ Number = 5; State = 'closed'; Merged = $false; HeadSha = 'h'; LockSha = 'older-render' }
        $r = Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Branch $br -Pr $pr
        $r.Action | Should -Be 'push'
        $r.BranchCurrent | Should -BeTrue
    }

    It 'merged PR is ignored' {
        $pr = [pscustomobject]@{ Number = 5; State = 'closed'; Merged = $true; HeadSha = 'h'; LockSha = 'new-render' }
        (Invoke-Sync -Rendered $NewRendered -RepoFiles $OldFiles -Lock $GoodLock -Pr $pr).Action | Should -Be 'push'
    }

    It 'always returns all fields with non-null arrays' {
        $r = Invoke-Sync -Rendered (New-Rendered $OldFiles) -RepoFiles $OldFiles -Lock $GoodLock
        $r.PSObject.Properties.Name | Should -Contain 'Action'
        $r.PSObject.Properties.Name | Should -Contain 'Reasons'
        $r.PSObject.Properties.Name | Should -Contain 'Deletes'
        $r.PSObject.Properties.Name | Should -Contain 'AutoMerge'
        $r.PSObject.Properties.Name | Should -Contain 'BranchCurrent'
        , $r.Reasons | Should -BeOfType [string[]]
        , $r.Deletes | Should -BeOfType [string[]]
    }
}
