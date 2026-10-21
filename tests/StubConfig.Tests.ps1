BeforeAll {
    Import-Module "$PSScriptRoot/../lib/StubConfig.psm1" -Force
}

Describe 'Read-StubConfig' {
    It 'defaults fill an empty object' {
        $c = Read-StubConfig '{}'
        $c.ref | Should -Be 'main'
        $c.setup | Should -Be 'none'
        $c.verify | Should -Be 'pwsh ./verify.ps1'
        $c.merge | Should -Be 'auto'
        $c.'auto-fix' | Should -Be $false
        $c.'working-directory' | Should -Be ''
        $c.'ledger-expiry' | Should -Be $false
        $c.stubs | Should -BeNullOrEmpty
        $c.with.Keys.Count | Should -Be 0
        $c.secrets.Keys.Count | Should -Be 0
    }

    It 'accepts BOM and CRLF' {
        $text = "`u{FEFF}{`r`n  `"setup`": `"python`"`r`n}"
        (Read-StubConfig $text).setup | Should -Be 'python'
    }

    It 'rejects an unknown field' {
        { Read-StubConfig '{"verfy":"x"}' } | Should -Throw "*unknown field 'verfy'*"
    }

    It 'rejects a multi-line value' {
        { Read-StubConfig '{"verify":"a\nb"}' } | Should -Throw "*'verify' must be a single line*"
    }

    It 'rejects wrong types' {
        { Read-StubConfig '{"auto-fix":"yes"}' } | Should -Throw "*'auto-fix'*"
        { Read-StubConfig '{"verify":5}' } | Should -Throw "*'verify'*"
        { Read-StubConfig '{"stubs":"ci.yml"}' } | Should -Throw "*'stubs'*"
    }

    It 'rejects invalid JSON' {
        { Read-StubConfig '{nope' } | Should -Throw '*not valid JSON*'
    }

    It 'merge must be auto or manual' {
        (Read-StubConfig '{"merge":"manual"}').merge | Should -Be 'manual'
        { Read-StubConfig '{"merge":"later"}' } | Should -Throw "*'merge'*"
    }

    It 'setup must be one of none|node-pnpm|node-npm|python' {
        foreach ($s in 'none', 'node-pnpm', 'node-npm', 'python') {
            (Read-StubConfig ('{"setup":"' + $s + '"}')).setup | Should -Be $s
        }
        { Read-StubConfig '{"setup":"ruby"}' } | Should -Throw "*'setup'*"
    }

    It 'with keys are validated' {
        $ok = Read-StubConfig '{"with":{"ci.yml/ci":{"node-version":"22","strict":true,"retries":3}}}'
        $ok.with['ci.yml/ci']['node-version'] | Should -Be '22'
        { Read-StubConfig '{"with":{"ci.yml/ci":{"Bad Name":"x"}}}' } | Should -Throw '*Bad Name*'
        { Read-StubConfig '{"with":{"ci/ci":{"a":"x"}}}' } | Should -Throw '*ci/ci*'
        { Read-StubConfig '{"with":{"ci.yml/ci":{"a":"x\ny"}}}' } | Should -Throw '*single line*'
        { Read-StubConfig '{"with":{"ci.yml/ci":{"a":["x"]}}}' } | Should -Throw '*scalar*'
    }

    It 'secrets are validated' {
        $ok = Read-StubConfig '{"secrets":{"ci.yml/ci":["NPM_TOKEN"]}}'
        $ok.secrets['ci.yml/ci'] | Should -Be @('NPM_TOKEN')
        { Read-StubConfig '{"secrets":{"ci.yml/ci":["lower"]}}' } | Should -Throw '*lower*'
        { Read-StubConfig '{"secrets":{"ci.yml/ci":"NPM_TOKEN"}}' } | Should -Throw '*array*'
    }
}

Describe 'Test-StubConfig' {
    BeforeAll {
        $script:names = @('ci.yml', 'claude.yml')
        $script:tags = @('v1')
    }

    It 'ref must be main or a tag' {
        { Test-StubConfig -Config (Read-StubConfig '{"ref":"feature/x"}') -StubNames $names -Tags $tags } | Should -Throw "*'ref'*"
        { Test-StubConfig -Config (Read-StubConfig '{"ref":"v1"}') -StubNames $names -Tags $tags } | Should -Not -Throw
        { Test-StubConfig -Config (Read-StubConfig '{}') -StubNames $names -Tags @() } | Should -Not -Throw
    }

    It 'stubs may only name known stubs' {
        { Test-StubConfig -Config (Read-StubConfig '{"stubs":["ci.yml","nope.yml"]}') -StubNames @('ci.yml') -Tags $tags } | Should -Throw "*unknown stub 'nope.yml'*"
        { Test-StubConfig -Config (Read-StubConfig '{"stubs":["ci.yml"]}') -StubNames @('ci.yml') -Tags $tags } | Should -Not -Throw
    }

    It 'with and secrets keys must name known stubs' {
        { Test-StubConfig -Config (Read-StubConfig '{"with":{"nope.yml/ci":{"a":"x"}}}') -StubNames $names -Tags $tags } | Should -Throw "*unknown stub 'nope.yml'*"
        { Test-StubConfig -Config (Read-StubConfig '{"secrets":{"nope.yml/ci":["A"]}}') -StubNames $names -Tags $tags } | Should -Throw "*unknown stub 'nope.yml'*"
        { Test-StubConfig -Config (Read-StubConfig '{"with":{"ci.yml/ci":{"a":"x"}}}') -StubNames $names -Tags $tags } | Should -Not -Throw
    }
}

Describe 'ConvertTo-YamlScalar' {
    It 'emits <Expected> for <Value>' -ForEach @(
        @{ Value = 'pwsh ./verify.ps1'; Expected = 'pwsh ./verify.ps1' }
        @{ Value = 'pnpm verify'; Expected = 'pnpm verify' }
        @{ Value = 'a: b'; Expected = "'a: b'" }
        @{ Value = "it's # x"; Expected = "'it''s # x'" }
        @{ Value = ''; Expected = "''" }
        @{ Value = 'trailing '; Expected = "'trailing '" }
        @{ Value = $true; Expected = 'true' }
        @{ Value = $false; Expected = 'false' }
        @{ Value = 15; Expected = '15' }
    ) {
        ConvertTo-YamlScalar -Value $Value | Should -Be $Expected
    }
}

Describe 'ConvertTo-StubConfigJson' {
    It 'round-trips with stable order, LF and a trailing newline' {
        $c = Read-StubConfig '{"setup":"python","with":{"ci.yml/ci":{"b":"2","a":"1"}}}'
        $json = ConvertTo-StubConfigJson -Config $c
        $json | Should -Not -Match "`r"
        $json | Should -Match "`n$"
        $json.IndexOf('"ref"') | Should -BeLessThan $json.IndexOf('"setup"')
        $json.IndexOf('"setup"') | Should -BeLessThan $json.IndexOf('"with"')
        $json | Should -Match '(?s)"a": "1".*"b": "2"'
        (ConvertTo-StubConfigJson -Config (Read-StubConfig $json)) | Should -Be $json
    }
}
