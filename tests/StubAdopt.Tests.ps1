BeforeAll {
    Import-Module "$PSScriptRoot/../lib/StubConfig.psm1" -Force
    Import-Module "$PSScriptRoot/../lib/StubRender.psm1" -Force
    Import-Module "$PSScriptRoot/../lib/StubAdopt.psm1" -Force
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:Install = Join-Path $script:RepoRoot 'install.ps1'
    $script:Utf8 = [Text.UTF8Encoding]::new($false)
    $script:HeadStubs = Get-StubsAtSha -RepoRoot $script:RepoRoot -Sha 'HEAD'
    $script:HeadNames = [string[]]@($script:HeadStubs.Keys)

    function script:New-Cfg([hashtable]$Over = @{}) { Read-StubConfig ($Over | ConvertTo-Json -Depth 10) }

    # Writes the stubs a config renders to at $Sha into a new repo dir; returns the repo dir.
    function script:New-Fixture([string]$Sha, $Cfg) {
        $t = Join-Path $TestDrive ('t-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force (Join-Path $t '.github/workflows') | Out-Null
        git -C $t init -q
        $rendered = Invoke-StubRender -Stubs (Get-StubsAtSha -RepoRoot $script:RepoRoot -Sha $Sha) -Config $Cfg
        foreach ($k in $rendered.Keys) { [IO.File]::WriteAllText((Join-Path $t $k), $rendered[$k], $script:Utf8) }
        $t
    }
    function script:Get-Current([string]$Repo) {
        $h = [ordered]@{}
        foreach ($f in (Get-ChildItem (Join-Path $Repo '.github/workflows') -Filter *.yml | Sort-Object Name)) {
            $h[".github/workflows/$($f.Name)"] = $script:Utf8.GetString([IO.File]::ReadAllBytes($f.FullName))
        }
        $h
    }
    function script:Invoke-Adopt([string]$Repo) {
        $inferred = Get-InferredStubConfig -WorkflowsDir (Join-Path $Repo '.github/workflows') -StubNames $script:HeadNames -Templates $script:HeadStubs
        $match = Find-StubRenderMatch -RepoRoot $script:RepoRoot -Config $inferred -CurrentFiles (Get-Current $Repo) -HeadRef 'HEAD'
        [pscustomobject]@{ Inferred = $inferred; Match = $match }
    }
    function script:Invoke-InstallAdopt([string]$Repo, [string[]]$More = @()) {
        $env:GHW_STUB_SHA = 'HEAD'
        $out = & pwsh -NoProfile -File $script:Install -Repo $Repo -Adopt @More 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    }
    function script:Get-TextHash([string]$Path) { Get-TextSha256 ($script:Utf8.GetString([IO.File]::ReadAllBytes($Path))) }

    # Newest commit touching stubs/ whose default render differs from HEAD's, so a match must be found by walking history.
    $headRender = Invoke-StubRender -Stubs $script:HeadStubs -Config (New-Cfg)
    $script:OlderSha = $null
    foreach ($sha in (git -C $script:RepoRoot log --format=%H HEAD -- stubs/)) {
        $r = Invoke-StubRender -Stubs (Get-StubsAtSha -RepoRoot $script:RepoRoot -Sha $sha) -Config (New-Cfg)
        $differs = ($r.Keys.Count -ne $headRender.Keys.Count)
        foreach ($k in $r.Keys) { if (-not $headRender.Contains($k) -or $r[$k] -cne $headRender[$k]) { $differs = $true } }
        if ($differs) { $script:OlderSha = $sha; break }
    }
}

AfterAll { Remove-Item Env:GHW_STUB_SHA -ErrorAction SilentlyContinue }

Describe 'adoption' {
    It 'found an older stub commit to build the fixture from' {
        $script:OlderSha | Should -Not -BeNullOrEmpty
    }

    It 'infers config from an install made by an older SHA' {
        $repo = New-Fixture $script:OlderSha (New-Cfg)
        $r = Invoke-Adopt $repo
        $r.Match.Matched | Should -BeTrue
        $r.Match.Sha | Should -Be $script:OlderSha
        $r.Match.Differences.Count | Should -Be 0
        $r.Inferred.ref | Should -Be 'main'
        $r.Inferred.merge | Should -Be 'auto'
    }

    It 'a matched adoption through install.ps1 writes a lock of the current hashes at the matched sha' {
        $repo = New-Fixture 'HEAD' (New-Cfg)
        $res = Invoke-InstallAdopt $repo
        $res.Code | Should -Be 0 -Because $res.Out
        $lock = Read-StubLock ([IO.File]::ReadAllText((Join-Path $repo '.github/gh-workflows.lock')))
        $lock.sha | Should -Be (git -C $script:RepoRoot rev-parse HEAD).Trim()
        $lock.files.Count | Should -BeGreaterThan 0
        foreach ($k in $lock.files.Keys) { $lock.files[$k] | Should -Be (Get-TextHash (Join-Path $repo $k)) -Because $k }
    }

    It 'infers pnpm, verify, working-directory and auto-fix' {
        $cfg = New-Cfg @{ setup = 'node-pnpm'; verify = 'pnpm verify'; 'working-directory' = 'web'; 'auto-fix' = $true }
        $repo = New-Fixture 'HEAD' $cfg
        $r = Invoke-Adopt $repo
        $r.Inferred.setup | Should -Be 'node-pnpm'
        $r.Inferred.verify | Should -Be 'pnpm verify'
        $r.Inferred.'working-directory' | Should -Be 'web'
        $r.Inferred.'auto-fix' | Should -BeTrue
        $r.Inferred.stubs | Should -BeNullOrEmpty
        $r.Match.Matched | Should -BeTrue
    }

    It 'round-trips a quoted verify value and records active gate inputs' {
        $cfg = New-Cfg @{ verify = "it's: ok"; with = @{ 'auto-merge.yml/gate' = @{ 'skip-branch-prefixes' = 'wo/'; 'delete-branch' = $true; 'fix-window-minutes' = 20 } } }
        $repo = New-Fixture 'HEAD' $cfg
        $r = Invoke-Adopt $repo
        $r.Inferred.verify | Should -Be "it's: ok"
        $w = $r.Inferred.with['auto-merge.yml/gate']
        $w['skip-branch-prefixes'] | Should -Be 'wo/'
        $w['delete-branch'] | Should -BeTrue
        $w['fix-window-minutes'] | Should -Be 20
        $r.Match.Matched | Should -BeTrue
    }

    It 'a fix window equal to the auto-fix rule is not recorded' {
        $repo = New-Fixture 'HEAD' (New-Cfg @{ 'auto-fix' = $true })
        (Invoke-Adopt $repo).Inferred.with.Count | Should -Be 0
    }

    It 'infers ledger-expiry and an extra secret' {
        $cfg = New-Cfg @{ 'ledger-expiry' = $true; secrets = @{ 'claude-review.yml/claude' = @('EXTRA_TOKEN') } }
        $repo = New-Fixture 'HEAD' $cfg
        $r = Invoke-Adopt $repo
        $r.Inferred.'ledger-expiry' | Should -BeTrue
        $r.Inferred.secrets.Keys.Count | Should -Be 1
        @($r.Inferred.secrets.Values[0]) | Should -Be @('EXTRA_TOKEN')
        $r.Match.Matched | Should -BeTrue
    }

    It 'hand-edited stub is a difference' {
        $repo = New-Fixture 'HEAD' (New-Cfg)
        $ci = Join-Path $repo '.github/workflows/ci.yml'
        [IO.File]::AppendAllText($ci, "# local note`n", $script:Utf8)
        $r = Invoke-Adopt $repo
        $r.Match.Matched | Should -BeFalse
        $r.Match.Differences | Should -Contain '.github/workflows/ci.yml'
        $r.Match.Differences.Count | Should -Be 1
        $r.Match.Sha | Should -Be (git -C $script:RepoRoot rev-parse HEAD).Trim()

        $res = Invoke-InstallAdopt $repo
        $res.Code | Should -Be 0 -Because $res.Out
        $res.Out | Should -Match 'ci\.yml'
        $lock = Read-StubLock ([IO.File]::ReadAllText((Join-Path $repo '.github/gh-workflows.lock')))
        $fresh = New-Fixture 'HEAD' (New-Cfg)
        $lock.files['.github/workflows/ci.yml'] | Should -Be (Get-TextHash (Join-Path $fresh '.github/workflows/ci.yml'))
        $lock.files['.github/workflows/ci.yml'] | Should -Not -Be (Get-TextHash $ci)
        $lock.files['.github/workflows/auto-merge.yml'] | Should -Be (Get-TextHash (Join-Path $repo '.github/workflows/auto-merge.yml'))
    }

    It 'CRLF stub is a difference, not an error' {
        $repo = New-Fixture 'HEAD' (New-Cfg)
        $ci = Join-Path $repo '.github/workflows/ci.yml'
        [IO.File]::WriteAllText($ci, ([IO.File]::ReadAllText($ci) -replace "`n", "`r`n"), $script:Utf8)
        $r = Invoke-Adopt $repo
        $r.Match.Matched | Should -BeFalse
        $r.Match.Differences | Should -Contain '.github/workflows/ci.yml'
        $r.Inferred.setup | Should -Be 'none'
        (Invoke-InstallAdopt $repo).Code | Should -Be 0
    }

    It 'review-only set becomes an explicit stubs list with merge manual' {
        $cfg = New-Cfg @{ stubs = @('ci.yml', 'claude-review.yml', 'codex-review.yml'); merge = 'manual' }
        $repo = New-Fixture 'HEAD' $cfg
        $r = Invoke-Adopt $repo
        $r.Inferred.merge | Should -Be 'manual'
        @($r.Inferred.stubs) | Should -Be @('ci.yml', 'claude-review.yml', 'codex-review.yml')
        $r.Match.Matched | Should -BeTrue
    }

    It 'other workflow files in the repo are ignored' {
        $repo = New-Fixture 'HEAD' (New-Cfg)
        [IO.File]::WriteAllText((Join-Path $repo '.github/workflows/deploy.yml'), "name: deploy`n", $script:Utf8)
        $r = Invoke-Adopt ($repo)
        $r.Inferred.stubs | Should -BeNullOrEmpty
    }

    It 'adopt never writes a stub file' {
        $repo = New-Fixture 'HEAD' (New-Cfg)
        $ci = Join-Path $repo '.github/workflows/ci.yml'
        [IO.File]::AppendAllText($ci, "# edited`n", $script:Utf8)
        (Get-Item $ci).LastWriteTimeUtc = [datetime]'2020-01-01'
        $before = Get-ChildItem (Join-Path $repo '.github/workflows') | ForEach-Object { "$($_.Name)|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash $_.FullName).Hash)" }
        $res = Invoke-InstallAdopt $repo
        $res.Code | Should -Be 0 -Because $res.Out
        $after = Get-ChildItem (Join-Path $repo '.github/workflows') | ForEach-Object { "$($_.Name)|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash $_.FullName).Hash)" }
        $after | Should -Be $before
        Test-Path (Join-Path $repo '.github/gh-workflows.json') | Should -BeTrue
        Test-Path (Join-Path $repo '.github/gh-workflows.lock') | Should -BeTrue
        Test-Path (Join-Path $repo '.github/pull_request_template.md') | Should -BeFalse
        Test-Path (Join-Path $repo '.github/review-context.md') | Should -BeFalse
        Read-StubConfig ([IO.File]::ReadAllText((Join-Path $repo '.github/gh-workflows.json'))) | Should -Not -BeNullOrEmpty
    }

    It 'refuses an already adopted repo without -Force' {
        $repo = New-Fixture 'HEAD' (New-Cfg)
        (Invoke-InstallAdopt $repo).Code | Should -Be 0
        $res = Invoke-InstallAdopt $repo
        $res.Code | Should -Not -Be 0
        $res.Out | Should -Match 'already'
        (Invoke-InstallAdopt $repo @('-Force')).Code | Should -Be 0
    }
}
