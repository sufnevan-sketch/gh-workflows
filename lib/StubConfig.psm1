# StubConfig.psm1 - the .github/gh-workflows.json config model for stub sync.
# Read-StubConfig validates what it can without knowing gh-workflows state;
# Test-StubConfig validates the rest (ref, stub names) once the caller has
# resolved ref and listed the stubs at that SHA.

Set-StrictMode -Version Latest

$script:Fields = @('ref', 'setup', 'verify', 'working-directory', 'auto-fix', 'stubs', 'merge', 'with', 'secrets', 'ledger-expiry')
$script:SetupValues = @('none', 'node-pnpm', 'node-npm', 'python')
$script:MergeValues = @('auto', 'manual')
# \z, not $: .NET's $ also matches before a final newline.
$script:JobKeyPattern = '^([a-z][a-z0-9-]*\.yml)/([A-Za-z0-9_-]+)\z'
$script:StubNamePattern = '^[a-z][a-z0-9-]*\.yml\z'
$script:InputNamePattern = '^[a-z][a-z0-9-]*\z'
$script:SecretNamePattern = '^[A-Z][A-Z0-9_]*\z'

function Fail([string]$Message) {
    throw [System.ArgumentException]::new($Message)
}

function Assert-SingleLine([string]$Name, $Value) {
    if ($Value -isnot [string]) { Fail "'$Name' must be a string" }
    if ($Value -match '\p{Cc}') { Fail "'$Name' must be a single line with no control characters" }
}

function Assert-Bool([string]$Name, $Value) {
    if ($Value -isnot [bool]) { Fail "'$Name' must be true or false" }
}

function Read-StubConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

    $Text = $Text.TrimStart([char]0xFEFF)
    try {
        $raw = $Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Fail "config is not valid JSON: $($_.Exception.Message)"
    }
    if ($raw -isnot [System.Collections.IDictionary]) { Fail 'config must be a JSON object' }

    foreach ($k in $raw.Keys) {
        if ($script:Fields -cnotcontains $k) { Fail "unknown field '$k'" }
    }

    $cfg = [ordered]@{
        'ref'               = 'main'
        'setup'             = 'none'
        'verify'            = 'pwsh ./verify.ps1'
        'working-directory' = ''
        'auto-fix'          = $false
        'stubs'             = $null
        'merge'             = 'auto'
        'with'              = [ordered]@{}
        'secrets'           = [ordered]@{}
        'ledger-expiry'     = $false
    }

    foreach ($name in 'ref', 'setup', 'verify', 'working-directory', 'merge') {
        if ($raw.ContainsKey($name)) {
            Assert-SingleLine $name $raw[$name]
            $cfg[$name] = $raw[$name]
        }
    }
    if ($cfg['ref'] -eq '') { Fail "'ref' must not be empty" }
    if ($script:SetupValues -cnotcontains $cfg['setup']) { Fail "'setup' must be one of $($script:SetupValues -join '|')" }
    if ($script:MergeValues -cnotcontains $cfg['merge']) { Fail "'merge' must be one of $($script:MergeValues -join '|')" }

    foreach ($name in 'auto-fix', 'ledger-expiry') {
        if ($raw.ContainsKey($name)) {
            Assert-Bool $name $raw[$name]
            $cfg[$name] = $raw[$name]
        }
    }

    if ($raw.ContainsKey('stubs') -and $null -ne $raw['stubs']) {
        if ($raw['stubs'] -isnot [System.Collections.IList]) { Fail "'stubs' must be an array of stub file names" }
        $list = @()
        foreach ($s in $raw['stubs']) {
            Assert-SingleLine 'stubs' $s
            if ($s -cnotmatch $script:StubNamePattern) { Fail "'stubs' entry '$s' is not a stub file name like ci.yml" }
            $list += $s
        }
        $cfg['stubs'] = $list
    }

    if ($raw.ContainsKey('with')) {
        if ($raw['with'] -isnot [System.Collections.IDictionary]) { Fail "'with' must be an object" }
        foreach ($key in $raw['with'].Keys) {
            if ($key -cnotmatch $script:JobKeyPattern) { Fail "'with' key '$key' must look like <stub>.yml/<jobId>" }
            $inputs = $raw['with'][$key]
            if ($inputs -isnot [System.Collections.IDictionary]) { Fail "'with' key '$key' must map input names to values" }
            $map = [ordered]@{}
            foreach ($in in $inputs.Keys) {
                if ($in -cnotmatch $script:InputNamePattern) { Fail "'with' input name '$in' under '$key' must match $($script:InputNamePattern)" }
                $v = $inputs[$in]
                if ($v -is [string]) { Assert-SingleLine "with.$key.$in" $v }
                elseif ($v -isnot [bool] -and $v -isnot [int] -and $v -isnot [long]) { Fail "'with' value '$in' under '$key' must be a scalar (string, boolean or integer)" }
                $map[$in] = $v
            }
            $cfg['with'][$key] = $map
        }
    }

    if ($raw.ContainsKey('secrets')) {
        if ($raw['secrets'] -isnot [System.Collections.IDictionary]) { Fail "'secrets' must be an object" }
        foreach ($key in $raw['secrets'].Keys) {
            if ($key -cnotmatch $script:JobKeyPattern) { Fail "'secrets' key '$key' must look like <stub>.yml/<jobId>" }
            $names = $raw['secrets'][$key]
            if ($names -isnot [System.Collections.IList]) { Fail "'secrets' key '$key' must be an array of secret names" }
            $list = @()
            foreach ($n in $names) {
                Assert-SingleLine "secrets.$key" $n
                if ($n -cnotmatch $script:SecretNamePattern) { Fail "'secrets' name '$n' under '$key' must match $($script:SecretNamePattern)" }
                $list += $n
            }
            $cfg['secrets'][$key] = $list
        }
    }

    [pscustomobject]$cfg
}

function Test-StubConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StubNames,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tags
    )

    if ($Config.ref -cne 'main' -and $Tags -cnotcontains $Config.ref) {
        Fail "'ref' must be 'main' or an existing tag, got '$($Config.ref)'"
    }
    if ($null -ne $Config.stubs) {
        foreach ($s in $Config.stubs) {
            if ($StubNames -cnotcontains $s) { Fail "unknown stub '$s' in 'stubs'" }
        }
    }
    foreach ($field in 'with', 'secrets') {
        foreach ($key in $Config.$field.Keys) {
            $stub = $key.Split('/')[0]
            if ($StubNames -cnotcontains $stub) { Fail "unknown stub '$stub' in '$field' key '$key'" }
        }
    }
}

# True when a YAML parser would read the plain scalar as something other than a string.
function Test-YamlNonString([string]$s) {
    $s -match '^(true|false|yes|no|on|off|y|n|null|~)\z' -or
    $s -match '^[-+]?(\d[\d_]*(\.\d*)?|\.\d+)([eE][-+]?\d+)?\z' -or
    $s -match '^0(x[0-9a-f_]+|o[0-7_]+|b[01_]+)\z' -or
    $s -match '^[-+]?\.(inf|nan)\z' -or
    $s -match '^\d{4}-\d{1,2}-\d{1,2}([Tt ].*)?\z'
}

function ConvertTo-YamlScalar {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()]$Value)

    if ($Value -is [bool]) {
        if ($Value) { return 'true' } else { return 'false' }
    }
    if ($Value -is [int] -or $Value -is [long]) { return ([long]$Value).ToString([cultureinfo]::InvariantCulture) }
    $s = [string]$Value
    if ($s -cmatch '^[A-Za-z0-9./_][A-Za-z0-9 ./_=+-]*\z' -and -not $s.EndsWith(' ') -and -not (Test-YamlNonString $s)) { return $s }
    "'" + $s.Replace("'", "''") + "'"
}

function ConvertTo-StubConfigJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $out = [ordered]@{}
    foreach ($f in $script:Fields) {
        $v = $Config.$f
        if ($f -eq 'stubs') {
            if ($null -eq $v) { continue }
            $out[$f] = @($v)
        } elseif ($f -eq 'with') {
            $m = [ordered]@{}
            foreach ($k in ($v.Keys | Sort-Object)) {
                $inner = [ordered]@{}
                foreach ($i in ($v[$k].Keys | Sort-Object)) { $inner[$i] = $v[$k][$i] }
                $m[$k] = $inner
            }
            $out[$f] = $m
        } elseif ($f -eq 'secrets') {
            $m = [ordered]@{}
            foreach ($k in ($v.Keys | Sort-Object)) { $m[$k] = @($v[$k]) }
            $out[$f] = $m
        } else {
            $out[$f] = $v
        }
    }
    $json = $out | ConvertTo-Json -Depth 10
    ($json -replace "`r`n", "`n").TrimEnd() + "`n"
}

Export-ModuleMember -Function Read-StubConfig, Test-StubConfig, ConvertTo-YamlScalar, ConvertTo-StubConfigJson
