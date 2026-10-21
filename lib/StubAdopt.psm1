# StubAdopt.psm1 - adoption of a repo whose stubs were installed by an older
# install.ps1 (no config, no lock). Infers the config from the stub files, finds
# the gh-workflows commit the stubs were rendered from, and leaves the stubs alone.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'StubConfig.psm1')
Import-Module (Join-Path $PSScriptRoot 'StubRender.psm1')

# Secrets the stubs pass by their own name or under another name; never "extra".
$script:KnownSecrets = @('CLAUDE_CODE_OAUTH_TOKEN', 'CODEX_TRIGGER_PAT', 'AUTOFIX_PAT')

function Fail([string]$Message) {
    throw [System.ArgumentException]::new($Message)
}

# One YAML scalar as written in a stub: one level of quotes removed ('' unescaped inside
# single quotes), or an unquoted value with any trailing ` # comment` cut. Typed = true
# turns unquoted true/false/integers into bool/int (quoted values stay strings).
function ConvertFrom-YamlScalar([string]$Text, [bool]$Typed) {
    $t = $Text.Trim()
    if ($t.StartsWith("'")) {
        $m = [regex]::Match($t, "^'((?:[^']|'')*)'")
        if ($m.Success) { return $m.Groups[1].Value.Replace("''", "'") }
    } elseif ($t.StartsWith('"')) {
        $m = [regex]::Match($t, '^"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { return [regex]::Replace($m.Groups[1].Value, '\\(.)', '$1') }
    }
    $t = ($t -replace '\s+#.*$', '').Trim()
    if ($Typed) {
        if ($t -ceq 'true') { return $true }
        if ($t -ceq 'false') { return $false }
        if ($t -match '^-?\d{1,9}\z') { return [int]$t }
    }
    $t
}

# Walks a stub's jobs: yields @{ Job; Section ('with'|'secrets'); Line } for each
# indent-6 line (comments included) under a job's with:/secrets: block.
function Get-JobEntries([string]$Text) {
    $job = $null; $section = $null; $inJobs = $false
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^jobs:\s*$') { $inJobs = $true; continue }
        if (-not $inJobs) { continue }
        if ($line -match '^\S') { $inJobs = $false; continue }
        if ($line -match '^  ([A-Za-z0-9_-]+):\s*$') { $job = $Matches[1]; $section = $null; continue }
        if ($line -match '^    (with|secrets):\s*$') { $section = $Matches[1]; continue }
        if ($line -match '^    \S') { $section = $null; continue }
        if ($job -and $section -and $line -match '^      \S') {
            [pscustomobject]@{ Job = $job; Section = $section; Line = $line.Substring(6) }
        }
    }
}

function Get-InferredStubConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkflowsDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StubNames,
        # Optional stub templates (name -> text): secrets they already carry are not "extra".
        [hashtable]$Templates = @{}
    )

    $files = [ordered]@{}
    foreach ($f in (Get-ChildItem -LiteralPath $WorkflowsDir -Filter *.yml -File | Sort-Object { $_.Name } -CaseSensitive)) {
        if ($StubNames -ccontains $f.Name) {
            $files[$f.Name] = [Text.UTF8Encoding]::new($false).GetString([IO.File]::ReadAllBytes($f.FullName))
        }
    }

    $ref = 'main'
    foreach ($name in $files.Keys) {
        $m = [regex]::Match($files[$name], 'sufnevan-sketch/gh-workflows/[^@\s]+@([^\s''"#]+)')
        if ($m.Success) { $ref = $m.Groups[1].Value; break }
    }

    $cfg = [ordered]@{ ref = $ref; setup = 'none'; verify = 'pwsh ./verify.ps1' }
    $with = [ordered]@{}
    $secrets = [ordered]@{}
    $autoFix = $files.Contains('auto-fix.yml')
    $cfg['merge'] = if ($files.Contains('auto-merge.yml')) { 'auto' } else { 'manual' }
    $cfg['auto-fix'] = $autoFix

    if ($files.Contains('ci.yml')) {
        foreach ($e in (Get-JobEntries $files['ci.yml'])) {
            if ($e.Job -cne 'ci' -or $e.Section -cne 'with' -or $e.Line -match '^\s*#') { continue }
            if ($e.Line -notmatch '^([a-z][a-z0-9-]*):\s*(.*)$') { continue }
            $inName = $Matches[1]; $inText = $Matches[2]
            $v = ConvertFrom-YamlScalar $inText $false
            switch ($inName) {
                'setup' { $cfg['setup'] = $v }
                'verify' { $cfg['verify'] = $v }
                'working-directory' { $cfg['working-directory'] = $v }
                'artifact-path' {
                    if (-not $with.Contains('ci.yml/ci')) { $with['ci.yml/ci'] = [ordered]@{} }
                    $with['ci.yml/ci']['artifact-path'] = $v
                }
            }
        }
    }

    if ($files.Contains('auto-merge.yml')) {
        $am = $files['auto-merge.yml']
        $cfg['ledger-expiry'] = [bool]($am -match '(?m)^  expiry:\s*$')
        foreach ($e in (Get-JobEntries $am)) {
            if ($e.Job -cne 'gate' -or $e.Section -cne 'with' -or $e.Line -match '^\s*#') { continue }
            if ($e.Line -notmatch '^(skip-branch-prefixes|delete-branch|fix-window-minutes):\s*(.*)$') { continue }
            $name = $Matches[1]; $inText = $Matches[2]
            $v = ConvertFrom-YamlScalar $inText $true
            # The default window follows auto-fix (15 with it, 0 without); record only a deviation.
            if ($name -ceq 'fix-window-minutes' -and $v -is [int] -and $v -eq $(if ($autoFix) { 15 } else { 0 })) { continue }
            if (-not $with.Contains('auto-merge.yml/gate')) { $with['auto-merge.yml/gate'] = [ordered]@{} }
            $with['auto-merge.yml/gate'][$name] = $v
        }
    }

    foreach ($name in $files.Keys) {
        $own = [System.Collections.Generic.HashSet[string]]::new()
        if ($Templates.ContainsKey($name)) {
            foreach ($e in (Get-JobEntries $Templates[$name])) { if ($e.Section -ceq 'secrets') { [void]$own.Add("$($e.Job)/$($e.Line.Trim())") } }
        }
        foreach ($e in (Get-JobEntries $files[$name])) {
            if ($e.Section -cne 'secrets') { continue }
            if ($e.Line -cnotmatch '^([A-Z][A-Z0-9_]*): \$\{\{ secrets\.\1 \}\}\s*$') { continue }
            $secret = $Matches[1]
            if ($own.Contains("$($e.Job)/$($e.Line.Trim())")) { continue }
            if ($Templates.Count -eq 0 -and $script:KnownSecrets -ccontains $secret) { continue }
            $key = "$name/$($e.Job)"
            if (-not $secrets.Contains($key)) { $secrets[$key] = @() }
            $secrets[$key] += $secret
        }
    }

    if ($with.Count) { $cfg['with'] = $with }
    if ($secrets.Count) { $cfg['secrets'] = $secrets }

    $config = Read-StubConfig ($cfg | ConvertTo-Json -Depth 10)
    $config.stubs = Get-StubsFieldFor -Config $config -PresentNames ([string[]]@($files.Keys)) -StubNames $StubNames
    $config
}

# The `stubs` field for a present set: null when it equals the default set, else the explicit list.
function Get-StubsFieldFor($Config, [string[]]$PresentNames, [string[]]$StubNames) {
    $present = [string[]]@($PresentNames | Where-Object { $StubNames -ccontains $_ })
    [Array]::Sort($present, [StringComparer]::Ordinal)
    $default = Get-DefaultStubSet -StubNames $StubNames -AutoFix $Config.'auto-fix'
    if (($present -join '|') -ceq ($default -join '|')) { return $null }
    , $present
}

function Resolve-Commit([string]$RepoRoot, [string]$Rev) {
    $o = & git -C $RepoRoot rev-parse --verify "$Rev^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $o) { Fail "cannot resolve '$Rev' in $RepoRoot" }
    ([string]$o).Trim()
}

function Find-StubRenderMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CurrentFiles,
        [string]$HeadRef = 'origin/main'
    )

    $headSha = Resolve-Commit $RepoRoot $HeadRef
    $log = & git -C $RepoRoot log --format=%H $headSha -- stubs/
    if ($LASTEXITCODE -ne 0) { Fail "git log failed in $RepoRoot" }
    $candidates = @($headSha) + @($log | Where-Object { $_ -and $_ -cne $headSha })

    $present = [string[]]@($CurrentFiles.Keys | ForEach-Object { ($_ -split '/')[-1] })
    $currentKeys = [string[]]@($CurrentFiles.Keys)
    [Array]::Sort($currentKeys, [StringComparer]::Ordinal)

    $headResult = $null
    foreach ($sha in $candidates) {
        $isHead = $sha -ceq $headSha -and $null -eq $headResult
        try {
            $stubs = Get-StubsAtSha -RepoRoot $RepoRoot -Sha $sha
            $cfg = $Config.PSObject.Copy()
            $cfg.stubs = Get-StubsFieldFor -Config $cfg -PresentNames $present -StubNames ([string[]]@($stubs.Keys))
            $rendered = Invoke-StubRender -Stubs $stubs -Config $cfg
        } catch {
            if ($isHead) { Fail "the inferred config does not render at ${HeadRef}: $($_.Exception.Message)" }
            continue
        }
        if ($isHead) { $headResult = [pscustomobject]@{ Config = $cfg; Rendered = $rendered } }

        $renderedKeys = [string[]]@($rendered.Keys)
        [Array]::Sort($renderedKeys, [StringComparer]::Ordinal)
        if (($renderedKeys -join '|') -cne ($currentKeys -join '|')) { continue }
        $same = $true
        foreach ($k in $renderedKeys) { if ($rendered[$k] -cne $CurrentFiles[$k]) { $same = $false; break } }
        if ($same) {
            return [pscustomobject]@{ Sha = $sha; Matched = $true; Differences = [string[]]@(); Config = $cfg; Rendered = $rendered }
        }
    }

    $diff = [System.Collections.Generic.List[string]]::new()
    $all = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($k in $headResult.Rendered.Keys) { [void]$all.Add($k) }
    foreach ($k in $CurrentFiles.Keys) { [void]$all.Add($k) }
    foreach ($k in $all) {
        if (-not $headResult.Rendered.Contains($k) -or -not $CurrentFiles.Contains($k) -or $headResult.Rendered[$k] -cne $CurrentFiles[$k]) { $diff.Add($k) }
    }
    [pscustomobject]@{ Sha = $headSha; Matched = $false; Differences = [string[]]$diff.ToArray(); Config = $headResult.Config; Rendered = $headResult.Rendered }
}

Export-ModuleMember -Function Get-InferredStubConfig, Find-StubRenderMatch
