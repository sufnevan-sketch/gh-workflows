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

    It 'rejects a trailing newline in job keys, input names, secret names and stub entries' {
        { Read-StubConfig '{"with":{"ci.yml/ci\n":{"a":"x"}}}' } | Should -Throw "*'with' key*"
        { Read-StubConfig '{"with":{"ci.yml/ci":{"a\n":"x"}}}' } | Should -Throw "*input name*"
        { Read-StubConfig '{"secrets":{"ci.yml/ci":["ABC\n"]}}' } | Should -Throw "*single line*"
        { Read-StubConfig '{"stubs":["ci.yml\n"]}' } | Should -Throw "*single line*"
    }

    It 'rejects multi-line values in secrets and stubs' {
        { Read-StubConfig '{"secrets":{"ci.yml/ci":["A\nB"]}}' } | Should -Throw '*single line*'
        { Read-StubConfig '{"stubs":["ci.yml\nx"]}' } | Should -Throw '*single line*'
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
        @{ Value = 'npm ci && npm test'; Expected = 'npm ci && npm test' }
        @{ Value = 'npm run verify:ci'; Expected = 'npm run verify:ci' }
        @{ Value = '-x'; Expected = "'-x'" }
        @{ Value = 'a:'; Expected = "'a:'" }
        @{ Value = '@x'; Expected = "'@x'" }
        @{ Value = 'a: b'; Expected = "'a: b'" }
        @{ Value = "it's # x"; Expected = "'it''s # x'" }
        @{ Value = ''; Expected = "''" }
        @{ Value = 'trailing '; Expected = "'trailing '" }
        @{ Value = ' leading'; Expected = "' leading'" }
        @{ Value = '3.10'; Expected = "'3.10'" }
        @{ Value = '22'; Expected = "'22'" }
        @{ Value = '+5'; Expected = "'+5'" }
        @{ Value = '.5'; Expected = "'.5'" }
        @{ Value = '1e3'; Expected = "'1e3'" }
        @{ Value = '1.0e-3'; Expected = "'1.0e-3'" }
        @{ Value = '0x1F'; Expected = "'0x1F'" }
        @{ Value = '0o17'; Expected = "'0o17'" }
        @{ Value = '0b101'; Expected = "'0b101'" }
        @{ Value = '.inf'; Expected = "'.inf'" }
        @{ Value = '.NaN'; Expected = "'.NaN'" }
        @{ Value = 'true'; Expected = "'true'" }
        @{ Value = 'No'; Expected = "'No'" }
        @{ Value = 'OFF'; Expected = "'OFF'" }
        @{ Value = 'y'; Expected = "'y'" }
        @{ Value = 'null'; Expected = "'null'" }
        @{ Value = 'NULL'; Expected = "'NULL'" }
        @{ Value = '~'; Expected = "'~'" }
        @{ Value = '2026-10-21'; Expected = "'2026-10-21'" }
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
