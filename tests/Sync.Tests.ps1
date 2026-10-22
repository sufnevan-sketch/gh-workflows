# Tests for lib/Invoke-StubSync.ps1 (the sync runner). The GhApi functions are mocked
# without -ModuleName: the runner is invoked with `&` from the test scope and resolves
# them there, and its own Import-Module (no -Force) leaves the loaded modules and the
# mocks in place. Stubs render from this checkout's HEAD (GHW_STUB_SHA test hook).
# Test state lives in $global:ST_* (removed in AfterAll): mock bodies and the -Sleep/-Now
# blocks run while the runner is the current script scope, so $script: would be its scope.

BeforeAll {
    $global:ST_Root = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module "$global:ST_Root/lib/StubConfig.psm1" -Force
    Import-Module "$global:ST_Root/lib/StubRender.psm1" -Force
    Import-Module "$global:ST_Root/lib/StubSync.psm1" -Force
    Import-Module "$global:ST_Root/lib/GhApi.psm1" -Force
    # The resolved ref is a docs-only commit on top of HEAD (same tree, a dangling object, no
    # ref moves): the render SHA is still the last commit touching stubs/, never the ref head.
    $global:ST_DocsHead = (git -C $global:ST_Root -c user.name=t -c user.email=t@example.com commit-tree 'HEAD^{tree}' -p HEAD -m 'docs: only').Trim()
    $env:GHW_STUB_SHA = $global:ST_DocsHead
    $global:ST_Runner = Join-Path $global:ST_Root 'lib/Invoke-StubSync.ps1'
    $global:ST_Head = (git -C $global:ST_Root log -1 --format=%H HEAD -- stubs/).Trim()
    $global:ST_LockPath = '.github/gh-workflows.lock'
    $global:ST_ConfigText = '{"ref":"main","merge":"auto"}'
    $global:ST_DefaultSha = 'd' * 40
    $global:ST_OldSha = '0' * 40

    $cfg = Read-StubConfig $global:ST_ConfigText
    $global:ST_Rendered = Invoke-StubRender -Stubs (Get-StubsAtSha -RepoRoot $global:ST_Root -Sha $global:ST_Head) -Config $cfg
    $global:ST_StaleKey = @($global:ST_Rendered.Keys)[0]

    function script:Get-Hashes($Files) {
        $h = [ordered]@{}
        foreach ($k in $Files.Keys) { $h[$k] = Get-TextSha256 $Files[$k] }
        $h
    }
    # "Behind": one owned stub is an older render; the lock matches it, so no drift.
    $global:ST_Behind = @{}
    foreach ($k in $global:ST_Rendered.Keys) { $global:ST_Behind[$k] = $global:ST_Rendered[$k] }
    $global:ST_Behind[$global:ST_StaleKey] = $global:ST_Rendered[$global:ST_StaleKey] + "# older render`n"
    $global:ST_BehindLock = New-StubLock -Sha $global:ST_OldSha -Files (Get-Hashes $global:ST_Behind)
    $global:ST_RenderLock = New-StubLock -Sha $global:ST_Head -Files (Get-Hashes $global:ST_Rendered)

    function script:New-State([string]$LockText = $global:ST_BehindLock, [string]$ConfigText = $global:ST_ConfigText) {
        [pscustomobject]@{ DefaultBranch = 'main'; DefaultSha = $global:ST_DefaultSha; ConfigText = $ConfigText; LockText = $LockText }
    }
    function script:Select-Files($Source, [string[]]$Paths) {
        $o = @{}
        foreach ($p in $Paths) { if ($Source.Contains($p)) { $o[$p] = $Source[$p] } }
        $o
    }
    function script:Invoke-Sync([switch]$WhatIf, [int]$WaitSeconds = 420, [scriptblock]$Now = { $global:ST_T0.AddSeconds($global:ST_Slept) }) {
        $global:ST_Slept = 0
        $global:ST_T0 = [datetime]'2026-10-21T12:00:00'
        $a = @{
            Owners      = @('octo-org')
            GhwRoot     = $global:ST_Root
            WaitSeconds = $WaitSeconds
            Sleep       = { param($s) $global:ST_Slept += $s }
            Now         = $Now
        }
        if ($WhatIf) { $a['WhatIf'] = $true }
        $global:ST_Out = @(& $global:ST_Runner @a)
        $global:ST_Code = $LASTEXITCODE
    }
    function script:Line([string]$Repo) { @($global:ST_Out | Where-Object { $_ -match ('^' + [regex]::Escape($Repo) + '\s') }) }
    function script:NotFound { [GhApiException]::new('gh: Not Found (HTTP 404)', 404) }
}

AfterAll {
    Remove-Item Env:GHW_STUB_SHA -ErrorAction SilentlyContinue
    Get-Variable -Scope Global -Name 'ST_*' | Remove-Variable -Scope Global
}

Describe 'Invoke-StubSync' {
    BeforeEach {
        $global:ST_Repos = @(
            [pscustomobject]@{ FullName = 'octo-org/demo'; DefaultBranch = 'main' },
            [pscustomobject]@{ FullName = 'octo-org/other'; DefaultBranch = 'main' }
        )
        Mock Get-SyncRepoList { $global:ST_Repos }
        Mock Get-SyncRepoState { New-State }
        Mock Get-RepoFiles { if ($Ref -eq $global:ST_DefaultSha) { Select-Files $global:ST_Behind $Paths } else { @{} } }
        Mock Get-SyncBranchState { $null }
        Mock Get-SyncPr { $null }
        Mock Publish-SyncCommit { "pushed-$($Repo -replace '/', '-')" }
        Mock Set-SyncPr { 7 }
        Mock Close-SyncPr { }
        Mock Merge-SyncPr { }
        Mock Remove-SyncBranch { }
        Mock Get-CiState { [pscustomobject]@{ BranchName = 'success'; Verify = 'success' } }
    }

    It 'one failing repo does not stop the others' {
        Mock Get-SyncRepoState -ParameterFilter { $Repo -eq 'octo-org/demo' } { throw (NotFound) }
        Invoke-Sync
        $global:ST_Code | Should -Be 1
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+failed\s+.*404'
        Line 'octo-org/other' | Should -Match '^octo-org/other\s+merged\b'
        Should -Invoke Publish-SyncCommit -Times 1 -Exactly -ParameterFilter { $Repo -eq 'octo-org/other' }
        Should -Invoke Merge-SyncPr -Times 1 -Exactly -ParameterFilter { $Repo -eq 'octo-org/other' -and $Number -eq 7 }
        $global:ST_Out[-1] | Should -BeExactly 'SUMMARY merged=1 current=0 pending=0 held=0 failed=1'
    }

    It 'auth failure exits 2 after the first call' {
        Mock Get-SyncRepoState { throw [GhAuthException]::new('gh auth login required (HTTP 401)', 401) }
        Invoke-Sync
        $global:ST_Code | Should -Be 2
        Should -Invoke Get-SyncRepoState -Times 1 -Exactly
        Should -Invoke Publish-SyncCommit -Times 0 -Exactly
        ($global:ST_Out -join "`n") | Should -Match 'gh auth login required'
    }

    It 'a repo whose config probe failed while listing prints failed and the others continue' {
        $global:ST_Repos = @(
            [pscustomobject]@{ FullName = 'octo-org/demo'; DefaultBranch = 'main'; Error = 'gh api GET repos/octo-org/demo/contents/.github/gh-workflows.json?ref=main failed: gh: Server Error (HTTP 502)' },
            [pscustomobject]@{ FullName = 'octo-org/other'; DefaultBranch = 'main'; Error = $null }
        )
        Invoke-Sync
        $global:ST_Code | Should -Be 1
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+failed\s+.*HTTP 502'
        Line 'octo-org/other' | Should -Match '^octo-org/other\s+merged\b'
        Should -Invoke Get-SyncRepoState -Times 0 -Exactly -ParameterFilter { $Repo -eq 'octo-org/demo' }
        $global:ST_Out[-1] | Should -BeExactly 'SUMMARY merged=1 current=0 pending=0 held=0 failed=1'
    }

    It 'auth failure while listing repos exits 2' {
        Mock Get-SyncRepoList { throw [GhAuthException]::new('not logged in', 401) }
        Invoke-Sync
        $global:ST_Code | Should -Be 2
        Should -Invoke Get-SyncRepoState -Times 0 -Exactly
    }

    It 'auth failure in pass 2 exits 2' {
        Mock Get-CiState { throw [GhAuthException]::new('token revoked', 401) }
        Invoke-Sync
        $global:ST_Code | Should -Be 2
        Should -Invoke Merge-SyncPr -Times 0 -Exactly
    }

    It 'WhatIf writes nothing' {
        Mock Get-SyncPr { [pscustomobject]@{ Number = 3; State = 'open'; Merged = $false; HeadSha = 'e' * 40; LockSha = $global:ST_OldSha } }
        Invoke-Sync -WhatIf
        Should -Invoke Publish-SyncCommit -Times 0 -Exactly
        Should -Invoke Set-SyncPr -Times 0 -Exactly
        Should -Invoke Close-SyncPr -Times 0 -Exactly
        Should -Invoke Merge-SyncPr -Times 0 -Exactly
        Should -Invoke Get-CiState -Times 0 -Exactly
        $global:ST_Slept | Should -Be 0
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+would-push\b'
        Line 'octo-org/other' | Should -Match '^octo-org/other\s+would-push\b'
    }

    It 'WhatIf reports a not-adopted repo as held' {
        Mock Get-SyncRepoState { New-State -LockText $null }
        Invoke-Sync -WhatIf
        $global:ST_Code | Should -Be 1
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+not adopted'
        Should -Invoke Publish-SyncCommit -Times 0 -Exactly
    }

    It 'waits once across repos' {
        $global:ST_CiCalls = @{}
        Mock Get-CiState {
            $global:ST_CiCalls[$Repo] = 1 + [int]$global:ST_CiCalls[$Repo]
            if ($global:ST_CiCalls[$Repo] -le 1) { [pscustomobject]@{ BranchName = 'success'; Verify = 'pending' } }
            else { [pscustomobject]@{ BranchName = 'success'; Verify = 'success' } }
        }
        Invoke-Sync
        $global:ST_Code | Should -Be 0
        $global:ST_CiCalls['octo-org/demo'] | Should -Be 2
        $global:ST_CiCalls['octo-org/other'] | Should -Be 2
        $global:ST_Slept | Should -Be 20
        Should -Invoke Merge-SyncPr -Times 2 -Exactly
        $global:ST_Out[-1] | Should -BeExactly 'SUMMARY merged=2 current=0 pending=0 held=0 failed=0'
    }

    It 'stops waiting at WaitSeconds and leaves PRs pending' {
        Mock Get-CiState { [pscustomobject]@{ BranchName = 'missing'; Verify = 'pending' } }
        Invoke-Sync -WaitSeconds 50
        $global:ST_Code | Should -Be 0
        $global:ST_Slept | Should -BeLessOrEqual 50
        $global:ST_Slept | Should -BeGreaterThan 0
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+pending\s+next run merges'
        Should -Invoke Merge-SyncPr -Times 0 -Exactly
        $global:ST_Out[-1] | Should -BeExactly 'SUMMARY merged=0 current=0 pending=2 held=0 failed=0'
    }

    It 'merge uses the pushed sha' {
        $global:ST_Repos = @($global:ST_Repos[0])
        Mock Publish-SyncCommit { 'a1b2c3' + ('f' * 34) }
        Invoke-Sync
        Should -Invoke Get-CiState -ParameterFilter { $Sha -eq ('a1b2c3' + ('f' * 34)) }
        Should -Invoke Merge-SyncPr -Times 1 -Exactly -ParameterFilter { $Sha -eq ('a1b2c3' + ('f' * 34)) -and $Number -eq 7 }
        Should -Invoke Publish-SyncCommit -Times 1 -Exactly -ParameterFilter {
            $Files.Contains($global:ST_LockPath) -and $Files[$global:ST_LockPath] -ceq $global:ST_RenderLock -and
            $Files[$global:ST_StaleKey] -ceq $global:ST_Rendered[$global:ST_StaleKey] -and $DefaultSha -eq $global:ST_DefaultSha -and
            $Message -ceq "chore: sync gh-workflows stubs to $($global:ST_Head.Substring(0, 7))"
        }
        Should -Invoke Set-SyncPr -Times 1 -Exactly -ParameterFilter {
            $Base -eq 'main' -and $Title -ceq "chore: sync gh-workflows stubs to $($global:ST_Head.Substring(0, 7))" -and
            $Body -match [regex]::Escape("https://github.com/sufnevan-sketch/gh-workflows/compare/$($global:ST_OldSha)...$($global:ST_Head)") -and
            $Body -match [regex]::Escape(($global:ST_StaleKey -replace '^\.github/workflows/', '')) -and
            $Body -notmatch 'Waits for a human merge'
        }
    }

    It 'all repos failing the same way prints one top line and exits 2' {
        # Real messages carry the per-repo path: "gh api GET repos/<repo> failed: ...".
        Mock Get-SyncRepoState { throw [GhApiException]::new("gh api GET repos/$Repo failed: gh: Server Error (HTTP 502)", 502) }
        Invoke-Sync
        $global:ST_Code | Should -Be 2
        $global:ST_Out.Count | Should -Be 2
        $global:ST_Out[0] | Should -BeExactly 'every repo failed: gh: Server Error (HTTP 502)'
        $global:ST_Out[1] | Should -BeExactly 'SUMMARY merged=0 current=0 pending=0 held=0 failed=2'
    }

    It 'the render SHA is the last stubs/ commit, not the docs-only ref head' {
        $global:ST_Head | Should -Not -Be $global:ST_DocsHead
        $global:ST_Repos = @($global:ST_Repos[0])
        Invoke-Sync
        Should -Invoke Publish-SyncCommit -Times 1 -Exactly -ParameterFilter { $Files[$global:ST_LockPath] -ceq $global:ST_RenderLock }
    }

    It 'a PR closed by hand stays held across a docs-only gh-workflows commit' {
        $global:ST_Repos = @($global:ST_Repos[0])
        Mock Get-SyncPr { [pscustomobject]@{ Number = 8; State = 'closed'; Merged = $false; HeadSha = 'e' * 40; LockSha = $global:ST_Head } }
        Invoke-Sync
        $global:ST_Code | Should -Be 1
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+closed by hand'
        Should -Invoke Publish-SyncCommit -Times 0 -Exactly
        Should -Invoke Set-SyncPr -Times 0 -Exactly
    }

    It 'zero repos prints a zero summary and exits 0' {
        $global:ST_Repos = @()
        Invoke-Sync
        $global:ST_Code | Should -Be 0
        $global:ST_Out | Should -Be @('SUMMARY merged=0 current=0 pending=0 held=0 failed=0')
    }

    It 'current with an open sync PR closes it as superseded' {
        Mock Get-RepoFiles { if ($Ref -eq $global:ST_DefaultSha) { Select-Files $global:ST_Rendered $Paths } else { @{} } }
        Mock Get-SyncRepoState { New-State -LockText $global:ST_RenderLock }
        Mock Get-SyncPr { [pscustomobject]@{ Number = 4; State = 'open'; Merged = $false; HeadSha = 'e' * 40; LockSha = $global:ST_OldSha } }
        Invoke-Sync
        $global:ST_Code | Should -Be 0
        Should -Invoke Close-SyncPr -Times 2 -Exactly -ParameterFilter { $Number -eq 4 -and $Comment -ceq "Superseded: stubs already match gh-workflows $($global:ST_Head.Substring(0, 7))." }
        Should -Invoke Publish-SyncCommit -Times 0 -Exactly
        Should -Invoke Remove-SyncBranch -Times 2 -Exactly
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+current\b'
    }

    Context 'sync branch exists' {
        BeforeEach {
            $global:ST_Repos = @($global:ST_Repos[0])
            $global:ST_BranchHead = 'b' * 40
            $global:ST_BranchFiles = @{}
            foreach ($k in $global:ST_Rendered.Keys) { $global:ST_BranchFiles[$k] = $global:ST_Rendered[$k] }
            $global:ST_BranchFiles[$global:ST_LockPath] = $global:ST_RenderLock
            Mock Get-SyncBranchState {
                [pscustomobject]@{ HeadSha = $global:ST_BranchHead; ChangedPaths = [string[]]@($global:ST_StaleKey, $global:ST_LockPath); LockText = $global:ST_RenderLock }
            }
            Mock Get-RepoFiles {
                if ($Ref -eq $global:ST_DefaultSha) { Select-Files $global:ST_Behind $Paths }
                elseif ($Ref -eq $global:ST_BranchHead) { Select-Files $global:ST_BranchFiles $Paths }
                else { @{} }
            }
        }

        It 'wait: branch already current with an open PR merges at the branch head (no force-push after a docs-only gh-workflows commit)' {
            Mock Get-SyncPr { [pscustomobject]@{ Number = 5; State = 'open'; Merged = $false; HeadSha = $global:ST_BranchHead; LockSha = $global:ST_Head } }
            Invoke-Sync
            Should -Invoke Publish-SyncCommit -Times 0 -Exactly
            Should -Invoke Set-SyncPr -Times 0 -Exactly
            Should -Invoke Merge-SyncPr -Times 1 -Exactly -ParameterFilter { $Number -eq 5 -and $Sha -eq $global:ST_BranchHead }
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+merged\b'
        }

        It 'push with the branch current and no PR opens the PR without pushing' {
            Invoke-Sync
            Should -Invoke Publish-SyncCommit -Times 0 -Exactly
            Should -Invoke Set-SyncPr -Times 1 -Exactly
            Should -Invoke Merge-SyncPr -Times 1 -Exactly -ParameterFilter { $Sha -eq $global:ST_BranchHead }
        }

        It 'a config change merged while the sync PR is open does not make the branch foreign' {
            # The branch was rendered with its own (older) config; the default branch now has C2.
            $c2 = '{"ref":"main","merge":"auto","setup":"python"}'
            $global:ST_C2Render = Invoke-StubRender -Stubs (Get-StubsAtSha -RepoRoot $global:ST_Root -Sha $global:ST_Head) -Config (Read-StubConfig $c2)
            $global:ST_BranchFiles['.github/gh-workflows.json'] = $global:ST_ConfigText
            Mock Get-SyncRepoState { New-State -ConfigText '{"ref":"main","merge":"auto","setup":"python"}' }
            Mock Get-SyncPr { [pscustomobject]@{ Number = 5; State = 'open'; Merged = $false; HeadSha = $global:ST_BranchHead; LockSha = $global:ST_Head } }
            Invoke-Sync
            $global:ST_Code | Should -Be 0
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+merged\b'
            # Not merged at the stale branch head: re-pushed with the C2 render first.
            Should -Invoke Publish-SyncCommit -Times 1 -Exactly -ParameterFilter {
                $Files['.github/workflows/ci.yml'] -ceq $global:ST_C2Render['.github/workflows/ci.yml'] -and
                $Files['.github/workflows/ci.yml'] -cne $global:ST_Rendered['.github/workflows/ci.yml']
            }
            Should -Invoke Merge-SyncPr -Times 0 -Exactly -ParameterFilter { $Sha -eq $global:ST_BranchHead }
        }

        It 'a branch whose own config does not parse is not own' {
            $global:ST_BranchFiles['.github/gh-workflows.json'] = '{"bogus":1}'
            Invoke-Sync
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+sync branch changed by someone else'
        }

        It 'a non-owned path on the branch holds' {
            Mock Get-SyncBranchState {
                [pscustomobject]@{ HeadSha = $global:ST_BranchHead; ChangedPaths = [string[]]@($global:ST_StaleKey, $global:ST_LockPath, 'README.md'); LockText = $global:ST_RenderLock }
            }
            Invoke-Sync
            $global:ST_Code | Should -Be 1
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+sync branch changed by someone else'
            Should -Invoke Publish-SyncCommit -Times 0 -Exactly
            Should -Invoke Set-SyncPr -Times 0 -Exactly
        }

        It 'an owned file edited on the branch holds' {
            $global:ST_BranchFiles[$global:ST_StaleKey] = $global:ST_Rendered[$global:ST_StaleKey] + "# hand edit`n"
            Invoke-Sync
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+sync branch changed by someone else'
        }

        It 'a branch whose lock SHA cannot be rendered holds' {
            $global:ST_BranchFiles = @{}
            foreach ($k in $global:ST_Behind.Keys) { $global:ST_BranchFiles[$k] = $global:ST_Behind[$k] }
            $global:ST_BranchFiles[$global:ST_LockPath] = $global:ST_BehindLock
            Mock Get-SyncBranchState {
                [pscustomobject]@{ HeadSha = $global:ST_BranchHead; ChangedPaths = [string[]]@($global:ST_LockPath); LockText = $global:ST_BehindLock }
            }
            # The old lock SHA is not a commit here, so the branch cannot be re-rendered: not own.
            Invoke-Sync
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+sync branch changed by someone else'
        }

        It 'a branch lock SHA that is not a 40-hex commit id is not own' {
            # 'HEAD' would resolve and render identically; it must be refused before rendering.
            $global:ST_HeadLock = New-StubLock -Sha 'HEAD' -Files (Get-Hashes $global:ST_Rendered)
            $global:ST_BranchFiles[$global:ST_LockPath] = $global:ST_HeadLock
            Mock Get-SyncBranchState {
                [pscustomobject]@{ HeadSha = $global:ST_BranchHead; ChangedPaths = [string[]]@($global:ST_StaleKey, $global:ST_LockPath); LockText = $global:ST_HeadLock }
            }
            Invoke-Sync
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+sync branch changed by someone else'
        }

        It 'a stale branch whose PR was merged is not held as foreign' {
            Mock Get-SyncBranchState {
                [pscustomobject]@{ HeadSha = $global:ST_BranchHead; ChangedPaths = [string[]]@($global:ST_StaleKey, $global:ST_LockPath, 'README.md'); LockText = $global:ST_RenderLock }
            }
            Mock Get-SyncPr { [pscustomobject]@{ Number = 6; State = 'closed'; Merged = $true; HeadSha = $global:ST_BranchHead; LockSha = $global:ST_OldSha } }
            Invoke-Sync
            $global:ST_Code | Should -Be 0
            Should -Invoke Publish-SyncCommit -Times 1 -Exactly
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+merged\b'
        }

        It 'a branch that moved past its merged PR is still judged by content' {
            Mock Get-SyncBranchState {
                [pscustomobject]@{ HeadSha = $global:ST_BranchHead; ChangedPaths = [string[]]@($global:ST_StaleKey, $global:ST_LockPath, 'README.md'); LockText = $global:ST_RenderLock }
            }
            Mock Get-SyncPr { [pscustomobject]@{ Number = 6; State = 'closed'; Merged = $true; HeadSha = 'c' * 40; LockSha = $global:ST_OldSha } }
            Invoke-Sync
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+sync branch changed by someone else'
            Should -Invoke Publish-SyncCommit -Times 0 -Exactly
        }

        It 'a superseded close keeps a branch someone else changed' {
            Mock Get-RepoFiles {
                if ($Ref -eq $global:ST_DefaultSha) { Select-Files $global:ST_Rendered $Paths }
                elseif ($Ref -eq $global:ST_BranchHead) { Select-Files $global:ST_BranchFiles $Paths }
                else { @{} }
            }
            Mock Get-SyncRepoState { New-State -LockText $global:ST_RenderLock }
            Mock Get-SyncBranchState {
                [pscustomobject]@{ HeadSha = $global:ST_BranchHead; ChangedPaths = [string[]]@($global:ST_LockPath, 'README.md'); LockText = $global:ST_RenderLock }
            }
            Mock Get-SyncPr { [pscustomobject]@{ Number = 4; State = 'open'; Merged = $false; HeadSha = $global:ST_BranchHead; LockSha = $global:ST_OldSha } }
            Invoke-Sync
            Should -Invoke Close-SyncPr -Times 1 -Exactly
            Should -Invoke Remove-SyncBranch -Times 0 -Exactly
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+current\s+closed superseded PR #4; branch kept: changed by someone else'
        }

        It 'a superseded close deletes the sync branch when it is the sync''s own' {
            Mock Get-RepoFiles {
                if ($Ref -eq $global:ST_DefaultSha) { Select-Files $global:ST_Rendered $Paths }
                elseif ($Ref -eq $global:ST_BranchHead) { Select-Files $global:ST_BranchFiles $Paths }
                else { @{} }
            }
            Mock Get-SyncRepoState { New-State -LockText $global:ST_RenderLock }
            Mock Get-SyncPr { [pscustomobject]@{ Number = 4; State = 'open'; Merged = $false; HeadSha = $global:ST_BranchHead; LockSha = $global:ST_Head } }
            Invoke-Sync
            Should -Invoke Remove-SyncBranch -Times 1 -Exactly
        }

        It 'WhatIf on the wait path writes nothing' {
            Mock Get-SyncPr { [pscustomobject]@{ Number = 5; State = 'open'; Merged = $false; HeadSha = $global:ST_BranchHead; LockSha = $global:ST_Head } }
            Invoke-Sync -WhatIf
            Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+would-merge\b'
            foreach ($w in 'Publish-SyncCommit', 'Set-SyncPr', 'Close-SyncPr', 'Merge-SyncPr', 'Remove-SyncBranch', 'Get-CiState') {
                Should -Invoke $w -Times 0 -Exactly
            }
        }
    }

    It 'merge deletes the sync branch' {
        Invoke-Sync
        Should -Invoke Remove-SyncBranch -Times 1 -Exactly -ParameterFilter { $Repo -eq 'octo-org/demo' }
        Should -Invoke Remove-SyncBranch -Times 1 -Exactly -ParameterFilter { $Repo -eq 'octo-org/other' }
    }

    It 'a failed branch delete after a merge still reports merged' {
        Mock Remove-SyncBranch { throw [GhApiException]::new('gh: Server Error (HTTP 502)', 502) }
        Invoke-Sync
        $global:ST_Code | Should -Be 0
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+merged\s+.*branch not deleted.*502'
    }

    It 'an auth error deleting the branch after a merge keeps the merged line' {
        $global:ST_Repos = @($global:ST_Repos[0])
        Mock Remove-SyncBranch { throw [GhAuthException]::new('token revoked (HTTP 401)', 401) }
        Invoke-Sync
        $global:ST_Code | Should -Be 2
        $global:ST_Out[0] | Should -Match 'token revoked'
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+merged\s+PR #7'
    }

    It 'WhatIf on current with an open PR writes nothing' {
        Mock Get-RepoFiles { if ($Ref -eq $global:ST_DefaultSha) { Select-Files $global:ST_Rendered $Paths } else { @{} } }
        Mock Get-SyncRepoState { New-State -LockText $global:ST_RenderLock }
        Mock Get-SyncPr { [pscustomobject]@{ Number = 4; State = 'open'; Merged = $false; HeadSha = 'e' * 40; LockSha = $global:ST_OldSha } }
        Invoke-Sync -WhatIf
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+current\s+would close superseded PR #4'
        foreach ($w in 'Publish-SyncCommit', 'Set-SyncPr', 'Close-SyncPr', 'Merge-SyncPr', 'Remove-SyncBranch') {
            Should -Invoke $w -Times 0 -Exactly
        }
    }

    It 'an auth abort prints the repos already decided' {
        Mock Get-SyncRepoState -ParameterFilter { $Repo -eq 'octo-org/demo' } { New-State -LockText $null }
        Mock Get-SyncRepoState -ParameterFilter { $Repo -eq 'octo-org/other' } { throw [GhAuthException]::new('token revoked (HTTP 401)', 401) }
        Invoke-Sync
        $global:ST_Code | Should -Be 2
        $global:ST_Out[0] | Should -Match 'token revoked'
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+not adopted'
    }

    It 'the CI wait cap counts from the start of the run' {
        $global:ST_NowCalls = 0
        Mock Get-CiState { [pscustomobject]@{ BranchName = 'pending'; Verify = 'pending' } }
        # First clock read is the run start; every later read is 500 s on (pass 1 was slow).
        Invoke-Sync -WaitSeconds 420 -Now { $global:ST_NowCalls++; if ($global:ST_NowCalls -eq 1) { $global:ST_T0 } else { $global:ST_T0.AddSeconds(500) } }
        $global:ST_Slept | Should -Be 0
        Should -Invoke Get-CiState -Times 2 -Exactly
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+pending\b'
    }

    It 'CI red holds the PR' {
        Mock Get-CiState { [pscustomobject]@{ BranchName = 'success'; Verify = 'failure' } }
        Invoke-Sync
        $global:ST_Code | Should -Be 1
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+CI red'
        Should -Invoke Merge-SyncPr -Times 0 -Exactly
    }

    It 'merge: manual pushes, opens the PR with reasons, and holds' {
        Mock Get-SyncRepoState { New-State -ConfigText '{"ref":"main","merge":"manual"}' }
        Invoke-Sync
        $global:ST_Code | Should -Be 1
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+held\s+merge: manual'
        Should -Invoke Set-SyncPr -Times 2 -Exactly -ParameterFilter { $Body -match 'Waits for a human merge because:' -and $Body -match '- merge: manual' }
        Should -Invoke Get-CiState -Times 0 -Exactly
    }

    It 'a non-auth merge error fails only that repo' {
        Mock Merge-SyncPr -ParameterFilter { $Repo -eq 'octo-org/demo' } { throw [GhApiException]::new('Head branch was modified (HTTP 409)', 409) }
        Invoke-Sync
        $global:ST_Code | Should -Be 1
        Line 'octo-org/demo' | Should -Match '^octo-org/demo\s+failed\s+.*409'
        Line 'octo-org/other' | Should -Match '^octo-org/other\s+merged\b'
    }
}
