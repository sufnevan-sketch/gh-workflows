BeforeAll {
    Import-Module "$PSScriptRoot/../lib/StubConfig.psm1" -Force
    Import-Module "$PSScriptRoot/../lib/StubRender.psm1" -Force
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:Install = Join-Path $script:RepoRoot 'install.ps1'

    function script:New-Target {
        $t = Join-Path $TestDrive ('t-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $t | Out-Null
        git -C $t init -q
        $t
    }
    # Runs install.ps1 in a child pwsh so its host output stays out of the test log.
    function script:Invoke-Install([string]$Target, [string[]]$More = @()) {
        $env:GHW_STUB_SHA = 'HEAD'
        $out = & pwsh -NoProfile -File $script:Install -Repo $Target @More 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "install.ps1 failed ($LASTEXITCODE): $out" }
        $out
    }
    function script:Get-Sha([string]$Path) {
        Get-TextSha256 ([Text.UTF8Encoding]::new($false).GetString([IO.File]::ReadAllBytes($Path)))
    }
    # The lock records the render SHA: the last commit touching stubs/, not HEAD.
    $script:Head = (git -C $script:RepoRoot log -1 --format=%H HEAD -- stubs/).Trim()
}

AfterAll { Remove-Item Env:GHW_STUB_SHA -ErrorAction SilentlyContinue }

Describe 'install.ps1' {
    It 'fresh install writes config, lock and stubs' {
        $t = New-Target
        Invoke-Install $t @('-Setup', 'python', '-Verify', 'pytest -q') | Out-Null
        $cfg = Get-Content (Join-Path $t '.github/gh-workflows.json') -Raw | ConvertFrom-Json
        $cfg.setup | Should -Be 'python'
        $cfg.verify | Should -Be 'pytest -q'
        $lock = Read-StubLock (Get-Content (Join-Path $t '.github/gh-workflows.lock') -Raw)
        $lock.sha | Should -Be $script:Head
        $written = Get-ChildItem (Join-Path $t '.github/workflows') -Filter *.yml | ForEach-Object { ".github/workflows/$($_.Name)" } | Sort-Object
        ($lock.files.Keys | Sort-Object) -join ',' | Should -Be ($written -join ',')
        foreach ($k in $lock.files.Keys) { $lock.files[$k] | Should -Be (Get-Sha (Join-Path $t $k)) -Because $k }
    }

    It 'existing stubs are skipped without -Force and the lock records the render, not the disk' {
        $t = New-Target
        New-Item -ItemType Directory -Force (Join-Path $t '.github/workflows') | Out-Null
        $ci = Join-Path $t '.github/workflows/ci.yml'
        [IO.File]::WriteAllText($ci, "name: custom`n")
        Invoke-Install $t | Out-Null
        [IO.File]::ReadAllText($ci) | Should -Be "name: custom`n"
        $lock = Read-StubLock (Get-Content (Join-Path $t '.github/gh-workflows.lock') -Raw)
        $fresh = New-Target
        Invoke-Install $fresh | Out-Null
        $lock.files['.github/workflows/ci.yml'] | Should -Be (Get-Sha (Join-Path $fresh '.github/workflows/ci.yml'))
        $lock.files['.github/workflows/ci.yml'] | Should -Not -Be (Get-TextSha256 "name: custom`n")
        Invoke-Install $t @('-Force') | Out-Null
        [IO.File]::ReadAllText($ci) | Should -Not -Be "name: custom`n"
    }

    It '-Merge manual is recorded in the config' {
        $t = New-Target
        Invoke-Install $t @('-Merge', 'manual') | Out-Null
        (Get-Content (Join-Path $t '.github/gh-workflows.json') -Raw | ConvertFrom-Json).merge | Should -Be 'manual'
    }

    It 'records auto-fix and upgrades an old auto-merge window to 15' {
        $t = New-Target
        Invoke-Install $t | Out-Null
        $am = Join-Path $t '.github/workflows/auto-merge.yml'
        [IO.File]::ReadAllText($am) | Should -Match 'fix-window-minutes: 0\b'
        Invoke-Install $t @('-WithAutoFix') | Out-Null
        [IO.File]::ReadAllText($am) | Should -Match 'fix-window-minutes: 15\b'
        (Get-Content (Join-Path $t '.github/gh-workflows.json') -Raw | ConvertFrom-Json).'auto-fix' | Should -BeTrue
        $lock = Read-StubLock (Get-Content (Join-Path $t '.github/gh-workflows.lock') -Raw)
        $lock.files['.github/workflows/auto-merge.yml'] | Should -Be (Get-Sha $am)
        $lock.files.ContainsKey('.github/workflows/auto-fix.yml') | Should -BeTrue
    }

    It 'rejects a -Ref that is not main or an existing tag' {
        $t = New-Target
        { Invoke-Install $t @('-Ref', 'v999') } | Should -Throw
    }

    It 'keeps an existing config and applies only explicitly passed parameters' {
        $t = New-Target
        New-Item -ItemType Directory -Force (Join-Path $t '.github') | Out-Null
        $in = '{"setup":"python","merge":"manual","with":{"ci.yml/ci":{"timeout-minutes":30}}}'
        [IO.File]::WriteAllText((Join-Path $t '.github/gh-workflows.json'), $in)
        $out = Invoke-Install $t @('-WithAutoFix')
        # The summary line shows the merged config, not the parameter defaults.
        $out | Should -Match 'ci stub : setup=python  verify="pwsh ./verify.ps1"  ref=@main'
        $cfg = Get-Content (Join-Path $t '.github/gh-workflows.json') -Raw | ConvertFrom-Json
        $cfg.merge | Should -Be 'manual'
        $cfg.setup | Should -Be 'python'
        $cfg.'auto-fix' | Should -BeTrue
        $cfg.with.'ci.yml/ci'.'timeout-minutes' | Should -Be 30
    }

    It 'rewrites a pristine auto-merge.yml on -WithAutoFix but warns and keeps an edited one' {
        $t = New-Target
        Invoke-Install $t | Out-Null
        $am = Join-Path $t '.github/workflows/auto-merge.yml'
        $edited = [IO.File]::ReadAllText($am) + "# local edit`n"
        [IO.File]::WriteAllText($am, $edited)
        $out = Invoke-Install $t @('-WithAutoFix')
        [IO.File]::ReadAllText($am) | Should -Be $edited
        $out | Should -Match 'auto-merge.yml differs'
        $lock = Read-StubLock (Get-Content (Join-Path $t '.github/gh-workflows.lock') -Raw)
        $lock.files['.github/workflows/auto-merge.yml'] | Should -Not -Be (Get-Sha $am)
    }
}

Describe 'Resolve-StubSha' {
    It 'resolves a tag to its commit and main to origin/main' {
        $r = Join-Path $TestDrive 'shaRepo'
        New-Item -ItemType Directory $r | Out-Null
        git -C $r init -q
        git -C $r -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m one
        git -C $r tag v1
        git -C $r -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m two
        $v1 = (git -C $r rev-parse v1).Trim()
        $head = (git -C $r rev-parse HEAD).Trim()
        $v1 | Should -Not -Be $head
        $saved = $env:GHW_STUB_SHA; Remove-Item Env:GHW_STUB_SHA -ErrorAction SilentlyContinue
        try {
            Resolve-StubSha -RepoRoot $r -Ref 'v1' | Should -Be $v1
            { Resolve-StubSha -RepoRoot $r -Ref 'v9' } | Should -Throw
            git -C $r update-ref refs/remotes/origin/main $head
            Resolve-StubSha -RepoRoot $r -Ref 'main' | Should -Be $head
        } finally { if ($saved) { $env:GHW_STUB_SHA = $saved } }
    }
}

Describe 'Get-StubRenderSha' {
    It 'a docs-only commit after a stubs commit keeps the same render SHA' {
        $r = Join-Path $TestDrive 'renderRepo'
        New-Item -ItemType Directory -Force (Join-Path $r 'stubs') | Out-Null
        git -C $r init -q
        [IO.File]::WriteAllText((Join-Path $r 'stubs/a.yml'), "name: a`n")
        git -C $r add stubs/a.yml
        git -C $r -c user.name=t -c user.email=t@example.com commit -q -m stubs
        $stubsSha = (git -C $r rev-parse HEAD).Trim()
        [IO.File]::WriteAllText((Join-Path $r 'README.md'), "docs`n")
        git -C $r add README.md
        git -C $r -c user.name=t -c user.email=t@example.com commit -q -m docs
        $docsSha = (git -C $r rev-parse HEAD).Trim()
        $docsSha | Should -Not -Be $stubsSha
        Get-StubRenderSha -RepoRoot $r -Sha $docsSha | Should -Be $stubsSha
        Get-StubRenderSha -RepoRoot $r -Sha $stubsSha | Should -Be $stubsSha
    }

    It 'fails when no commit touches stubs/' {
        $r = Join-Path $TestDrive 'noStubs'
        New-Item -ItemType Directory $r | Out-Null
        git -C $r init -q
        git -C $r -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m one
        { Get-StubRenderSha -RepoRoot $r -Sha 'HEAD' } | Should -Throw '*touches stubs/*'
    }
}
