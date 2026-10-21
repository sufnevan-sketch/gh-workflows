BeforeAll {
    Import-Module "$PSScriptRoot/../lib/StubConfig.psm1" -Force
    Import-Module "$PSScriptRoot/../lib/StubRender.psm1" -Force
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path

    function script:Get-WorkingStubs {
        $h = @{}
        foreach ($f in Get-ChildItem (Join-Path $script:RepoRoot 'stubs') -Filter *.yml) {
            $h[$f.Name] = ([IO.File]::ReadAllText($f.FullName)) -replace "`r`n", "`n"
        }
        $h
    }
    function script:New-Cfg([hashtable]$Over = @{}) {
        $j = if ($Over.Count) { $Over | ConvertTo-Json -Depth 10 } else { '{}' }
        Read-StubConfig $j
    }
    $script:Stubs = Get-WorkingStubs
}

Describe 'Get-TextSha256 and lock' {
    It 'hashes UTF-8 text as lowercase hex' {
        Get-TextSha256 'a' | Should -Be 'ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb'
    }

    It 'lock round-trips' {
        $files = [ordered]@{ '.github/workflows/b.yml' = (Get-TextSha256 'b'); '.github/workflows/a.yml' = (Get-TextSha256 'a') }
        $text = New-StubLock -Sha 'abc123' -Files $files
        $text | Should -Match "`n\z"
        $text | Should -Not -Match "`r"
        $text.IndexOf('a.yml') | Should -BeLessThan $text.IndexOf('b.yml')
        $lock = Read-StubLock $text
        $lock.sha | Should -Be 'abc123'
        $lock.files['.github/workflows/a.yml'] | Should -Be (Get-TextSha256 'a')
        $lock.files['.github/workflows/b.yml'] | Should -Be (Get-TextSha256 'b')
        $lock.files.Count | Should -Be 2
    }

    It 'Read-StubLock tolerates BOM and CRLF' {
        $text = New-StubLock -Sha 'abc' -Files ([ordered]@{ '.github/workflows/a.yml' = 'x' })
        $lock = Read-StubLock ([char]0xFEFF + ($text -replace "`n", "`r`n"))
        $lock.sha | Should -Be 'abc'
        $lock.files['.github/workflows/a.yml'] | Should -Be 'x'
    }
}

Describe 'Get-StubsAtSha' {
    It 'reads the yml stubs at HEAD from git objects' {
        $got = Get-StubsAtSha -RepoRoot $script:RepoRoot -Sha 'HEAD'
        $got.Keys | Should -Contain 'ci.yml'
        $got.Keys | Should -Not -Contain 'review-context.md'
        $got.Keys | Should -Not -Contain 'pull_request_template.md'
        $head = git -C $script:RepoRoot show 'HEAD:stubs/ci.yml'
        $got['ci.yml'] | Should -Be ((($head -join "`n")) + "`n")
    }

    It 'throws for an unknown sha' {
        { Get-StubsAtSha -RepoRoot $script:RepoRoot -Sha '0000000000000000000000000000000000000001' } | Should -Throw
    }
}

Describe 'Get-DefaultStubSet' {
    It 'excludes the opt-in stubs without auto-fix, sorted' {
        $names = @('ledger-fix.yml', 'ci.yml', 'auto-fix.yml', 'claude.yml')
        (Get-DefaultStubSet -StubNames $names -AutoFix $false) -join ',' | Should -Be 'ci.yml,claude.yml'
        (Get-DefaultStubSet -StubNames $names -AutoFix $true) -join ',' | Should -Be 'auto-fix.yml,ci.yml,claude.yml,ledger-fix.yml'
    }
}

Describe 'Invoke-StubRender' {
    It 'renders the default set in name order with LF text' {
        $r = Invoke-StubRender -Stubs $script:Stubs -Config (New-Cfg)
        ($r.Keys -join ',') | Should -Be '.github/workflows/auto-merge.yml,.github/workflows/ci.yml,.github/workflows/claude-review.yml,.github/workflows/claude.yml,.github/workflows/codex-review.yml,.github/workflows/codex-route.yml'
        foreach ($v in $r.Values) { $v | Should -Not -Match "`r" }
    }

    It 'fix window is 0 without auto-fix' {
        $r = Invoke-StubRender -Stubs $script:Stubs -Config (New-Cfg)
        $r['.github/workflows/auto-merge.yml'] | Should -Match 'fix-window-minutes: 0'
        $r2 = Invoke-StubRender -Stubs $script:Stubs -Config (New-Cfg @{ 'auto-fix' = $true })
        $r2['.github/workflows/auto-merge.yml'] | Should -Match 'fix-window-minutes: 15'
    }

    It 'with override replaces a commented line' {
        $cfg = New-Cfg @{ with = @{ 'auto-merge.yml/gate' = @{ 'delete-branch' = $true } } }
        $t = (Invoke-StubRender -Stubs $script:Stubs -Config $cfg)['.github/workflows/auto-merge.yml']
        $t | Should -Match '(?m)^      delete-branch: true$'
        $t | Should -Not -Match '#\s+delete-branch'
    }

    It 'with override replaces an active line' {
        $cfg = New-Cfg @{ with = @{ 'auto-merge.yml/gate' = @{ 'fix-window-minutes' = 5 } } }
        $t = (Invoke-StubRender -Stubs $script:Stubs -Config $cfg)['.github/workflows/auto-merge.yml']
        $t | Should -Match '(?m)^      fix-window-minutes: 5$'
        $t | Should -Not -Match 'fix-window-minutes: (0|15)'
    }

    It 'with override adds a with block when the job has none' {
        $cfg = New-Cfg @{ with = @{ 'claude-review.yml/claude' = @{ 'model' = 'x' } } }
        $t = (Invoke-StubRender -Stubs $script:Stubs -Config $cfg)['.github/workflows/claude-review.yml']
        $lines = $t -split "`n"
        $i = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^    uses: ' })
        $lines[$i + 1] | Should -Be '    with:'
        $lines[$i + 2] | Should -Be '      model: x'
        $lines[$i + 3] | Should -Be '    secrets:'
    }

    It 'with override appends a new input after the with line' {
        $cfg = New-Cfg @{ with = @{ 'ci.yml/ci' = @{ 'timeout' = 30 } } }
        $t = (Invoke-StubRender -Stubs $script:Stubs -Config $cfg)['.github/workflows/ci.yml']
        $lines = $t -split "`n"
        $i = [array]::IndexOf($lines, '    with:')
        $lines[$i + 1] | Should -Be '      timeout: 30'
        $lines[$i + 2] | Should -Match '^      setup: '
    }

    It 'with override quotes strings YAML would misread' {
        $cfg = New-Cfg @{ with = @{ 'claude-review.yml/claude' = @{ 'model' = 'true' } } }
        $t = (Invoke-StubRender -Stubs $script:Stubs -Config $cfg)['.github/workflows/claude-review.yml']
        $t | Should -Match "(?m)^      model: 'true'$"
    }

    It 'extra secret appended to the job secrets block' {
        $cfg = New-Cfg @{ secrets = @{ 'codex-review.yml/codex' = @('OPENAI_API_KEY') } }
        $t = (Invoke-StubRender -Stubs $script:Stubs -Config $cfg)['.github/workflows/codex-review.yml']
        $t.TrimEnd("`n") -split "`n" | Select-Object -Last 1 | Should -Be '      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}'
        $t | Should -Match '(?m)^      CODEX_TRIGGER_PAT: '
    }

    It 'extra secret creates a secrets block when the job has none' {
        $cfg = New-Cfg @{ secrets = @{ 'ci.yml/ci' = @('MY_TOKEN') } }
        $t = (Invoke-StubRender -Stubs $script:Stubs -Config $cfg)['.github/workflows/ci.yml']
        $t | Should -Match '(?m)^    secrets:\n      MY_TOKEN: \$\{\{ secrets\.MY_TOKEN \}\}\n'
    }

    It 'ledger-expiry adds trigger and job' {
        $cfg = New-Cfg @{ 'ledger-expiry' = $true; ref = 'v1' }
        $t = (Invoke-StubRender -Stubs $script:Stubs -Config $cfg)['.github/workflows/auto-merge.yml']
        $t | Should -Match '(?m)^on:\n  schedule:\n    - cron: "17 9 \* \* \*"\n  workflow_run:'
        $t | Should -Match "(?s)\n\n  expiry:\n    if: github\.event_name == 'schedule'\n    uses: sufnevan-sketch/gh-workflows/\.github/workflows/ledger-expiry\.yml@v1\n\z"
        $off = (Invoke-StubRender -Stubs $script:Stubs -Config (New-Cfg))['.github/workflows/auto-merge.yml']
        $off | Should -Not -Match '(?m)ledger-expiry\.yml|^  schedule:'
    }

    It 'explicit stubs list wins' {
        $cfg = New-Cfg @{ stubs = @('ci.yml', 'claude-review.yml') }
        $r = Invoke-StubRender -Stubs $script:Stubs -Config $cfg
        ($r.Keys -join ',') | Should -Be '.github/workflows/ci.yml,.github/workflows/claude-review.yml'
    }

    It 'override for a stub not rendered is an error' {
        $cfg = New-Cfg @{ stubs = @('ci.yml'); with = @{ 'claude-review.yml/claude' = @{ 'model' = 'x' } } }
        { Invoke-StubRender -Stubs $script:Stubs -Config $cfg } | Should -Throw '*not in the rendered set*'
        $cfg2 = New-Cfg @{ stubs = @('ci.yml'); secrets = @{ 'claude-review.yml/claude' = @('X') } }
        { Invoke-StubRender -Stubs $script:Stubs -Config $cfg2 } | Should -Throw '*not in the rendered set*'
    }

    It 'override for an unknown job id is an error' {
        $cfg = New-Cfg @{ with = @{ 'ci.yml/nope' = @{ 'model' = 'x' } } }
        { Invoke-StubRender -Stubs $script:Stubs -Config $cfg } | Should -Throw '*nope*'
    }
}

Describe 'byte-identical to install.ps1' {
    BeforeAll {
        # Pinned PRE-change installer: Task 3 rewrites install.ps1, this stays the oracle.
        $script:Inst = Join-Path $TestDrive 'inst'
        New-Item -ItemType Directory -Force $script:Inst | Out-Null
        $old = git -C $script:RepoRoot show 'ba498c5226a97569725f52fb0310d1e19add53ac:install.ps1'
        [IO.File]::WriteAllText((Join-Path $script:Inst 'install.ps1'), (($old -join "`n") + "`n"))
        Copy-Item -Recurse (Join-Path $script:RepoRoot 'stubs') (Join-Path $script:Inst 'stubs')
    }

    It 'matches for <name>' -ForEach @(
        @{ name = 'defaults'; cfg = @{}; sw = @{} }
        @{ name = 'node-pnpm with auto-fix'; cfg = @{ setup = 'node-pnpm'; verify = 'pnpm verify'; 'auto-fix' = $true }; sw = @{ Setup = 'node-pnpm'; Verify = 'pnpm verify'; WithAutoFix = $true } }
        @{ name = 'working-directory and ref'; cfg = @{ 'working-directory' = 'web'; ref = 'v1' }; sw = @{ WorkingDirectory = 'web'; Ref = 'v1' } }
    ) {
        $repo = Join-Path $TestDrive ("repo-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $repo | Out-Null
        git -C $repo init -q
        $splat = $sw
        & (Join-Path $script:Inst 'install.ps1') -Repo $repo -Force @splat 6>$null 3>$null | Out-Null

        $written = @{}
        foreach ($f in Get-ChildItem (Join-Path $repo '.github/workflows') -Filter *.yml) { $written[".github/workflows/$($f.Name)"] = [IO.File]::ReadAllBytes($f.FullName) }

        $r = Invoke-StubRender -Stubs $script:Stubs -Config (New-Cfg $cfg)
        ($r.Keys | Sort-Object) -join ',' | Should -Be (($written.Keys | Sort-Object) -join ',')
        $utf8 = [Text.UTF8Encoding]::new($false)
        foreach ($k in $r.Keys) {
            $bytes = $utf8.GetBytes($r[$k])
            [Convert]::ToBase64String($bytes) | Should -Be ([Convert]::ToBase64String($written[$k])) -Because $k
        }
    }
}
