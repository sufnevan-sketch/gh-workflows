BeforeAll {
    Import-Module "$PSScriptRoot/../lib/GhApi.psm1" -Force
    function script:B64([string]$t) { [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($t)) }
    function script:Content([string]$t) {
        # GitHub wraps base64 at 60 columns with newlines
        $b = B64 $t
        $wrapped = ($b -split '(.{60})' | Where-Object { $_ }) -join "`n"
        [pscustomobject]@{ content = $wrapped + "`n"; encoding = 'base64' }
    }
    function script:NotFound { [GhApiException]::new('gh: Not Found (HTTP 404)', 404) }
}

Describe 'Get-SyncRepoState' {
    It 'uses default_branch, not main' {
        Mock Invoke-GhApi -ModuleName GhApi {
            switch -Regex ($Path) {
                '^repos/octo-org/demo$' { [pscustomobject]@{ default_branch = 'master' } }
                'git/ref/heads/master$' { [pscustomobject]@{ object = [pscustomobject]@{ sha = 'abc123' } } }
                'gh-workflows\.json\?ref=master$' { Content '{"a":1}' }
                'gh-workflows\.lock\?ref=master$' { throw (NotFound) }
                default { throw "unexpected $Path" }
            }
        }
        $s = Get-SyncRepoState -Repo 'octo-org/demo'
        $s.DefaultBranch | Should -Be 'master'
        $s.DefaultSha | Should -Be 'abc123'
        $s.ConfigText | Should -Be '{"a":1}'
        $s.LockText | Should -BeNullOrEmpty
        Should -Invoke Invoke-GhApi -ModuleName GhApi -ParameterFilter { $Path -like '*contents/.github/gh-workflows.json?ref=master' }
        Should -Not -Invoke Invoke-GhApi -ModuleName GhApi -ParameterFilter { $Path -like '*ref=main' }
    }
}

Describe 'Get-RepoFiles' {
    It 'decodes base64 with embedded newlines and preserves CR, omits missing' {
        $script:text = ("line one`r`nline two with more text to force wrapping past sixty columns`r`n" * 3)
        Mock Invoke-GhApi -ModuleName GhApi {
            if ($Path -like '*present.txt*') { Content $script:text } else { throw (NotFound) }
        }
        $r = Get-RepoFiles -Repo 'octo-org/demo' -Ref 'v1' -Paths 'present.txt', 'gone.txt'
        $r.Keys.Count | Should -Be 1
        $r['present.txt'] | Should -BeExactly $script:text
        $r['present.txt'] | Should -Match "`r`n"
    }
    It 'rethrows non-404 errors' {
        Mock Invoke-GhApi -ModuleName GhApi { throw [GhApiException]::new('boom (HTTP 500)', 500) }
        { Get-RepoFiles -Repo 'octo-org/demo' -Ref 'v1' -Paths 'x' } | Should -Throw
    }
}

Describe 'Get-SyncRepoList' {
    It 'keeps non-archived repos with a config and skips 404' {
        Mock Invoke-GhApi -ModuleName GhApi {
            switch -Regex ($Path) {
                '^users/octo-org$' { [pscustomobject]@{ type = 'Organization' } }
                '^orgs/octo-org/repos' {
                    @(
                        [pscustomobject]@{ full_name = 'octo-org/demo'; default_branch = 'master'; archived = $false },
                        [pscustomobject]@{ full_name = 'octo-org/old'; default_branch = 'main'; archived = $true },
                        [pscustomobject]@{ full_name = 'octo-org/plain'; default_branch = 'main'; archived = $false })
                }
                'repos/octo-org/demo/contents' { Content '{}' }
                'repos/octo-org/plain/contents' { throw (NotFound) }
                default { throw "unexpected $Path" }
            }
        }
        $l = @(Get-SyncRepoList -Owners 'octo-org')
        $l.Count | Should -Be 1
        $l[0].FullName | Should -Be 'octo-org/demo'
        $l[0].DefaultBranch | Should -Be 'master'
        Should -Invoke Invoke-GhApi -ModuleName GhApi -ParameterFilter { $Path -like 'repos/octo-org/demo/contents/*?ref=master' }
    }
    It 'uses users/<o>/repos for a user owner' {
        Mock Invoke-GhApi -ModuleName GhApi {
            if ($Path -eq 'users/octo-user') { [pscustomobject]@{ type = 'User' } } else { @() }
        }
        $null = Get-SyncRepoList -Owners 'octo-user'
        Should -Invoke Invoke-GhApi -ModuleName GhApi -ParameterFilter { $Path -like 'users/octo-user/repos*' }
    }
    It 'throws on a non-404 error' {
        Mock Invoke-GhApi -ModuleName GhApi {
            switch -Regex ($Path) {
                '^users/' { [pscustomobject]@{ type = 'User' } }
                '/repos' { @([pscustomobject]@{ full_name = 'octo-user/demo'; default_branch = 'main'; archived = $false }) }
                default { throw [GhApiException]::new('boom (HTTP 500)', 500) }
            }
        }
        { Get-SyncRepoList -Owners 'octo-user' } | Should -Throw
    }
}

Describe 'Get-SyncBranchState' {
    It 'returns null when the branch is absent' {
        Mock Invoke-GhApi -ModuleName GhApi { throw (NotFound) }
        Get-SyncBranchState -Repo 'octo-org/demo' -DefaultBranch main | Should -BeNullOrEmpty
    }
    It 'returns head sha, changed paths and lock text' {
        Mock Invoke-GhApi -ModuleName GhApi {
            switch -Regex ($Path) {
                'git/ref/heads/chore/gh-workflows-sync$' { [pscustomobject]@{ object = [pscustomobject]@{ sha = 'head1' } } }
                'compare/main\.\.\.chore/gh-workflows-sync$' { [pscustomobject]@{ files = @([pscustomobject]@{ filename = '.github/workflows/a.yml' }, [pscustomobject]@{ filename = '.github/gh-workflows.lock' }) } }
                'gh-workflows\.lock\?ref=head1$' { Content '{"sha":"s"}' }
                default { throw "unexpected $Path" }
            }
        }
        $b = Get-SyncBranchState -Repo 'octo-org/demo' -DefaultBranch main
        $b.HeadSha | Should -Be 'head1'
        $b.ChangedPaths | Should -Be @('.github/workflows/a.yml', '.github/gh-workflows.lock')
        $b.LockText | Should -Be '{"sha":"s"}'
    }
}

Describe 'Get-SyncPr' {
    It 'returns the newest PR with Merged and LockSha' {
        Mock Invoke-GhApi -ModuleName GhApi {
            switch -Regex ($Path) {
                '^repos/octo-org/demo/pulls\?head=octo-org:chore/gh-workflows-sync&state=all' {
                    @(
                        [pscustomobject]@{ number = 9; state = 'closed'; merged_at = '2026-10-01T00:00:00Z'; head = [pscustomobject]@{ sha = 'h9' } },
                        [pscustomobject]@{ number = 4; state = 'closed'; merged_at = $null; head = [pscustomobject]@{ sha = 'h4' } })
                }
                'gh-workflows\.lock\?ref=h9$' { Content '{"sha":"render9","files":{}}' }
                default { throw "unexpected $Path" }
            }
        }
        $p = Get-SyncPr -Repo 'octo-org/demo'
        $p.Number | Should -Be 9
        $p.State | Should -Be 'closed'
        $p.Merged | Should -BeTrue
        $p.HeadSha | Should -Be 'h9'
        $p.LockSha | Should -Be 'render9'
    }
    It 'gives LockSha null for an unparseable lock, without throwing' {
        Mock Invoke-GhApi -ModuleName GhApi {
            if ($Path -like '*pulls?head*') { @([pscustomobject]@{ number = 1; state = 'open'; merged_at = $null; head = [pscustomobject]@{ sha = 'h1' } }) }
            else { Content 'not json' }
        }
        $p = Get-SyncPr -Repo 'octo-org/demo'
        $p.LockSha | Should -BeNullOrEmpty
        $p.Merged | Should -BeFalse
    }
    It 'gives LockSha null when the lock is missing at the head' {
        Mock Invoke-GhApi -ModuleName GhApi {
            if ($Path -like '*pulls?head*') { @([pscustomobject]@{ number = 1; state = 'open'; merged_at = $null; head = [pscustomobject]@{ sha = 'h1' } }) }
            else { throw (NotFound) }
        }
        (Get-SyncPr -Repo 'octo-org/demo').LockSha | Should -BeNullOrEmpty
    }
    It 'returns null when there is no PR' {
        Mock Invoke-GhApi -ModuleName GhApi { @() }
        Get-SyncPr -Repo 'octo-org/demo' | Should -BeNullOrEmpty
    }
}

Describe 'Publish-SyncCommit' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
    }
    It 'sends deletes as sha null and force-updates an existing ref' {
        Mock Invoke-GhApi -ModuleName GhApi {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            switch -Regex ("$Method $Path") {
                'POST .*git/trees' { [pscustomobject]@{ sha = 'tree1' } }
                'POST .*git/commits' { [pscustomobject]@{ sha = 'commit1' } }
                default { [pscustomobject]@{} }
            }
        }
        $files = [ordered]@{ '.github/workflows/a.yml' = "a`n"; '.github/gh-workflows.lock' = "{}`n" }
        $sha = Publish-SyncCommit -Repo 'octo-org/demo' -DefaultSha 'def1' -Files $files -Deletes @('.github/workflows/old.yml') -Message 'msg'
        $sha | Should -Be 'commit1'
        $tree = $script:calls | Where-Object { $_.Path -like '*git/trees' }
        $tree.Body.base_tree | Should -Be 'def1'
        $tree.Body.tree.Count | Should -Be 3
        $del = $tree.Body.tree | Where-Object { $_.path -eq '.github/workflows/old.yml' }
        $del.ContainsKey('sha') | Should -BeTrue
        $del.sha | Should -BeNullOrEmpty
        ($tree.Body | ConvertTo-Json -Depth 10 -Compress) | Should -Match '"sha":null'
        ($tree.Body.tree | Where-Object { $_.path -eq '.github/workflows/a.yml' }).content | Should -Be "a`n"
        $commit = $script:calls | Where-Object { $_.Path -like '*git/commits' }
        $commit.Body.parents | Should -Be @('def1')
        $commit.Body.tree | Should -Be 'tree1'
        $patch = $script:calls | Where-Object { $_.Method -eq 'PATCH' }
        $patch.Path | Should -Be 'repos/octo-org/demo/git/refs/heads/chore/gh-workflows-sync'
        $patch.Body.force | Should -BeTrue
        $patch.Body.sha | Should -Be 'commit1'
        $script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -like '*git/refs' } | Should -BeNullOrEmpty
    }
    It 'creates the ref when it does not exist' {
        Mock Invoke-GhApi -ModuleName GhApi {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            switch -Regex ("$Method $Path") {
                'POST .*git/trees' { [pscustomobject]@{ sha = 'tree1' } }
                'POST .*git/commits' { [pscustomobject]@{ sha = 'commit1' } }
                'GET .*git/ref/heads' { throw (NotFound) }
                default { [pscustomobject]@{} }
            }
        }
        $null = Publish-SyncCommit -Repo 'octo-org/demo' -DefaultSha 'def1' -Files ([ordered]@{ 'x' = 'y' }) -Message 'm'
        $post = $script:calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -like '*git/refs' }
        $post.Body.ref | Should -Be 'refs/heads/chore/gh-workflows-sync'
        $post.Body.sha | Should -Be 'commit1'
    }
}

Describe 'Set-SyncPr' {
    BeforeEach { $script:calls = [System.Collections.Generic.List[object]]::new() }
    It 'creates a new PR when none exists' {
        Mock Invoke-GhApi -ModuleName GhApi {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Method -eq 'GET') { @() } else { [pscustomobject]@{ number = 12 } }
        }
        Set-SyncPr -Repo 'octo-org/demo' -Base master -Title 't' -Body 'b' | Should -Be 12
        $post = $script:calls | Where-Object { $_.Method -eq 'POST' }
        $post.Path | Should -Be 'repos/octo-org/demo/pulls'
        $post.Body.head | Should -Be 'chore/gh-workflows-sync'
        $post.Body.base | Should -Be 'master'
    }
    It 'updates title and body of an open PR' {
        Mock Invoke-GhApi -ModuleName GhApi {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Method -eq 'GET') { @([pscustomobject]@{ number = 5; state = 'open'; merged_at = $null }) } else { [pscustomobject]@{} }
        }
        Set-SyncPr -Repo 'octo-org/demo' -Base main -Title 't' -Body 'b' | Should -Be 5
        $patch = $script:calls | Where-Object { $_.Method -eq 'PATCH' }
        $patch.Path | Should -Be 'repos/octo-org/demo/pulls/5'
        $patch.Body.ContainsKey('state') | Should -BeFalse
        $patch.Body.title | Should -Be 't'
    }
    It 'reopens a closed unmerged PR' {
        Mock Invoke-GhApi -ModuleName GhApi {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Method -eq 'GET') { @([pscustomobject]@{ number = 5; state = 'closed'; merged_at = $null }) } else { [pscustomobject]@{} }
        }
        Set-SyncPr -Repo 'octo-org/demo' -Base main -Title 't' -Body 'b' | Should -Be 5
        ($script:calls | Where-Object { $_.Method -eq 'PATCH' }).Body.state | Should -Be 'open'
    }
    It 'creates a new PR when the newest one was merged' {
        Mock Invoke-GhApi -ModuleName GhApi {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Method -eq 'GET') { @([pscustomobject]@{ number = 5; state = 'closed'; merged_at = '2026-10-01T00:00:00Z' }) } else { [pscustomobject]@{ number = 6 } }
        }
        Set-SyncPr -Repo 'octo-org/demo' -Base main -Title 't' -Body 'b' | Should -Be 6
    }
}

Describe 'Close-SyncPr' {
    It 'comments then closes' {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-GhApi -ModuleName GhApi {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body }); [pscustomobject]@{}
        }
        Close-SyncPr -Repo 'octo-org/demo' -Number 5 -Comment 'bye'
        $script:calls[0].Path | Should -Be 'repos/octo-org/demo/issues/5/comments'
        $script:calls[0].Body.body | Should -Be 'bye'
        $script:calls[1].Method | Should -Be 'PATCH'
        $script:calls[1].Body.state | Should -Be 'closed'
    }
}

Describe 'Get-CiState' {
    It 'keeps the newest run per name and maps in_progress to pending' {
        Mock Invoke-GhApi -ModuleName GhApi {
            [pscustomobject]@{ check_runs = @(
                    [pscustomobject]@{ id = 1; name = 'ci / branch-name'; status = 'completed'; conclusion = 'failure'; started_at = '2026-10-21T10:00:00Z' },
                    [pscustomobject]@{ id = 2; name = 'ci / branch-name'; status = 'completed'; conclusion = 'success'; started_at = '2026-10-21T10:05:00Z' },
                    [pscustomobject]@{ id = 3; name = 'ci / verify'; status = 'completed'; conclusion = 'success'; started_at = '2026-10-21T10:00:00Z' },
                    [pscustomobject]@{ id = 4; name = 'ci / verify'; status = 'in_progress'; conclusion = $null; started_at = '2026-10-21T10:06:00Z' },
                    [pscustomobject]@{ id = 5; name = 'other'; status = 'completed'; conclusion = 'failure'; started_at = '2026-10-21T10:07:00Z' }) }
        }
        $s = Get-CiState -Repo 'octo-org/demo' -Sha 'abc'
        $s.BranchName | Should -Be 'success'
        $s.Verify | Should -Be 'pending'
    }
    It 'reports absent as missing and cancelled as failure' {
        Mock Invoke-GhApi -ModuleName GhApi {
            [pscustomobject]@{ check_runs = @([pscustomobject]@{ id = 1; name = 'ci / verify'; status = 'completed'; conclusion = 'cancelled'; started_at = 'x' }) }
        }
        $s = Get-CiState -Repo 'octo-org/demo' -Sha 'abc'
        $s.BranchName | Should -Be 'missing'
        $s.Verify | Should -Be 'failure'
    }
    It 'treats skipped as missing' {
        Mock Invoke-GhApi -ModuleName GhApi {
            [pscustomobject]@{ check_runs = @([pscustomobject]@{ id = 1; name = 'ci / verify'; status = 'completed'; conclusion = 'skipped'; started_at = 'x' }) }
        }
        (Get-CiState -Repo 'octo-org/demo' -Sha 'abc').Verify | Should -Be 'missing'
    }
    It 'merges paginated pages' {
        Mock Invoke-GhApi -ModuleName GhApi {
            @(
                [pscustomobject]@{ check_runs = @([pscustomobject]@{ id = 1; name = 'ci / branch-name'; status = 'completed'; conclusion = 'success'; started_at = 'a' }) },
                [pscustomobject]@{ check_runs = @([pscustomobject]@{ id = 2; name = 'ci / verify'; status = 'queued'; conclusion = $null; started_at = 'b' }) })
        }
        $s = Get-CiState -Repo 'octo-org/demo' -Sha 'abc'
        $s.BranchName | Should -Be 'success'
        $s.Verify | Should -Be 'pending'
    }
}

Describe 'Merge-SyncPr' {
    It 'passes the head sha and squash' {
        Mock Invoke-GhApi -ModuleName GhApi { [pscustomobject]@{ merged = $true } }
        Merge-SyncPr -Repo 'octo-org/demo' -Number 7 -Sha 'head7'
        Should -Invoke Invoke-GhApi -ModuleName GhApi -Exactly 1 -ParameterFilter {
            $Method -eq 'PUT' -and $Path -eq 'repos/octo-org/demo/pulls/7/merge' -and $Body.merge_method -eq 'squash' -and $Body.sha -eq 'head7'
        }
    }
}

Describe 'Invoke-GhApi error mapping' {
    It '401 surfaces as GhAuthException' {
        Mock Invoke-GhProcess -ModuleName GhApi { [pscustomobject]@{ ExitCode = 1; Stdout = ''; Stderr = "gh: Bad credentials (HTTP 401)`n" } }
        { Invoke-GhApi -Method GET -Path 'repos/octo-org/demo' } | Should -Throw -ExceptionType ([GhAuthException])
    }
    It 'gh auth login text surfaces as GhAuthException' {
        Mock Invoke-GhProcess -ModuleName GhApi { [pscustomobject]@{ ExitCode = 4; Stdout = ''; Stderr = "To get started with GitHub CLI, please run:  gh auth login`n" } }
        { Invoke-GhApi -Method GET -Path 'x' } | Should -Throw -ExceptionType ([GhAuthException])
    }
    It '404 is a GhApiException carrying the status' {
        Mock Invoke-GhProcess -ModuleName GhApi { [pscustomobject]@{ ExitCode = 1; Stdout = ''; Stderr = "gh: Not Found (HTTP 404)`n" } }
        $err = $null
        try { Invoke-GhApi -Method GET -Path 'x' } catch { $err = $_.Exception }
        $err | Should -BeOfType ([GhApiException])
        $err | Should -Not -BeOfType ([GhAuthException])
        $err.Status | Should -Be 404
    }
    It 'sends the body on stdin as compact JSON and parses the response' {
        Mock Invoke-GhProcess -ModuleName GhApi { [pscustomobject]@{ ExitCode = 0; Stdout = '{"sha":"s1"}'; Stderr = '' } }
        $r = Invoke-GhApi -Method POST -Path 'repos/octo-org/demo/git/trees' -Body @{ a = 1 }
        $r.sha | Should -Be 's1'
        Should -Invoke Invoke-GhProcess -ModuleName GhApi -ParameterFilter {
            $StdIn -eq '{"a":1}' -and ($Arguments -join ' ') -match '--input -' -and $Arguments[2] -eq 'POST'
        }
    }
    It 'flattens paginated array pages' {
        Mock Invoke-GhProcess -ModuleName GhApi { [pscustomobject]@{ ExitCode = 0; Stdout = '[[{"n":1},{"n":2}],[{"n":3}]]'; Stderr = '' } }
        $r = @(Invoke-GhApi -Method GET -Path 'x' -Paginate)
        $r.Count | Should -Be 3
        Should -Invoke Invoke-GhProcess -ModuleName GhApi -ParameterFilter { $Arguments -contains '--paginate' -and $Arguments -contains '--slurp' }
    }
}
