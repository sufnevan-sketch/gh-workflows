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

function Get-JobIds([string]$Text) {
    $ids = [System.Collections.Generic.List[string]]::new()
    $inJobs = $false
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^jobs:\s*$') { $inJobs = $true; continue }
        if (-not $inJobs) { continue }
        if ($line -match '^\S') { $inJobs = $false; continue }
        if ($line -match '^  ([A-Za-z0-9_-]+):\s*$') { $ids.Add($Matches[1]) }
    }
    , $ids.ToArray()
}

function Test-ExpiryJob([string]$Text) { [bool]($Text -match '(?m)^  expiry:\s*$') }

# The template-relative knobs of a set of stub files: with inputs, extra secrets and ledger-expiry.
# $Baseline (leaf name -> text) is the era template rendered with no overrides; a value equal to
# the baseline's own is the template's, not a per-repo choice, and is not recorded. Entries whose
# job is not in the template are skipped (the renderer could not place them). With no baseline
# (null) everything active is recorded except the fix-window and known-secret defaults.
function Get-StubKnobs($Files, $Baseline, [bool]$AutoFix) {
    $with = [ordered]@{}
    $secrets = [ordered]@{}
    $expiry = $false
    $known = @('CLAUDE_CODE_OAUTH_TOKEN', 'CODEX_TRIGGER_PAT', 'AUTOFIX_PAT')

    foreach ($name in $Files.Keys) {
        $text = $Files[$name]
        $base = if ($null -ne $Baseline -and $Baseline.Contains($name)) { $Baseline[$name] } else { $null }
        $jobs = if ($null -ne $base) { Get-JobIds $base } else { Get-JobIds $text }
        $baseEntries = if ($null -ne $base) { @(Get-JobEntries $base) } else { @() }

        $job = $null; $inputs = @(); $typed = $true
        if ($name -ceq 'ci.yml') { $job = 'ci'; $inputs = @('artifact-path'); $typed = $false }
        elseif ($name -ceq 'auto-merge.yml') { $job = 'gate'; $inputs = @('skip-branch-prefixes', 'delete-branch', 'fix-window-minutes') }

        $entries = @(Get-JobEntries $text)
        foreach ($e in $entries) {
            if ($e.Section -cne 'with' -or $e.Job -cne $job -or $jobs -cnotcontains $e.Job -or $e.Line -match '^\s*#') { continue }
            if ($e.Line -notmatch '^([a-z][a-z0-9-]*):\s*(.*)$') { continue }
            $inName = $Matches[1]; $inText = $Matches[2]
            if ($inputs -cnotcontains $inName) { continue }
            $v = ConvertFrom-YamlScalar $inText $typed
            if ($v -is [string] -and $v -match '\p{Cc}') { continue }
            if ($inName -ceq 'fix-window-minutes' -and $v -is [int] -and -not $AutoFix -and $v -eq 0) { continue }
            if ($null -ne $base) {
                $same = $false
                foreach ($b in $baseEntries) {
                    if ($b.Section -ceq 'with' -and $b.Job -ceq $e.Job -and $b.Line -notmatch '^\s*#' -and $b.Line -match ('^' + [regex]::Escape($inName) + ':\s*(.*)$')) {
                        $bt = $Matches[1]
                        if ((ConvertFrom-YamlScalar $bt $typed) -ceq $v) { $same = $true }
                    }
                }
                if ($same) { continue }
            } elseif ($inName -ceq 'fix-window-minutes' -and $v -is [int] -and $v -eq $(if ($AutoFix) { 15 } else { 0 })) { continue }
            $key = "$name/$($e.Job)"
            if (-not $with.Contains($key)) { $with[$key] = [ordered]@{} }
            $with[$key][$inName] = $v
        }

        foreach ($e in $entries) {
            if ($e.Section -cne 'secrets' -or $jobs -cnotcontains $e.Job) { continue }
            if ($e.Line -cnotmatch '^([A-Z][A-Z0-9_]*): \$\{\{ secrets\.\1 \}\}\s*$') { continue }
            $secret = $Matches[1]
            if ($null -ne $base) {
                $own = $false
                foreach ($b in $baseEntries) { if ($b.Section -ceq 'secrets' -and $b.Job -ceq $e.Job -and $b.Line.Trim() -ceq $e.Line.Trim()) { $own = $true } }
                if ($own) { continue }
            } elseif ($known -ccontains $secret) { continue }
            $key = "$name/$($e.Job)"
            if (-not $secrets.Contains($key)) { $secrets[$key] = @() }
            $secrets[$key] += $secret
        }

        if ($name -ceq 'auto-merge.yml' -and (Test-ExpiryJob $text)) {
            $expiry = -not ($null -ne $base -and (Test-ExpiryJob $base))
        }
    }
    [pscustomobject]@{ With = $with; Secrets = $secrets; LedgerExpiry = $expiry }
}

# The era-template baseline: the stubs rendered with no overrides and every optional stub in.
function Get-BaselineTexts($Stubs, $Config) {
    try {
        $b = $Config.PSObject.Copy()
        $b.stubs = $null; $b.'auto-fix' = $true; $b.with = [ordered]@{}; $b.secrets = [ordered]@{}; $b.'ledger-expiry' = $false
        $r = Invoke-StubRender -Stubs $Stubs -Config $b
        $out = @{}
        foreach ($k in $r.Keys) { $out[($k -split '/')[-1]] = $r[$k] }
        $out
    } catch { $null }
}

function Set-Knobs($Config, $Knobs) {
    $c = $Config.PSObject.Copy()
    $c.with = $Knobs.With; $c.secrets = $Knobs.Secrets; $c.'ledger-expiry' = $Knobs.LedgerExpiry
    $c
}

# The `stubs` field for a present set: null when it equals the default set, else the explicit list.
function Get-StubsFieldFor($Config, [string[]]$PresentNames, [string[]]$StubNames) {
    $present = [string[]]@($PresentNames | Where-Object { $StubNames -ccontains $_ })
    [Array]::Sort($present, [StringComparer]::Ordinal)
    $default = Get-DefaultStubSet -StubNames $StubNames -AutoFix $Config.'auto-fix'
    if (($present -join '|') -ceq ($default -join '|')) { return $null }
    , $present
}

function Get-InferredStubConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkflowsDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StubNames,
        # Optional stub templates (name -> text) of the era to compare against.
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

    $autoFix = $files.Contains('auto-fix.yml')
    $cfg = [ordered]@{ ref = $ref; setup = 'none'; verify = 'pwsh ./verify.ps1'; merge = $(if ($files.Contains('auto-merge.yml')) { 'auto' } else { 'manual' }); 'auto-fix' = $autoFix }
    if ($files.Contains('ci.yml')) {
        foreach ($e in (Get-JobEntries $files['ci.yml'])) {
            if ($e.Job -cne 'ci' -or $e.Section -cne 'with' -or $e.Line -match '^\s*#') { continue }
            if ($e.Line -notmatch '^([a-z][a-z0-9-]*):\s*(.*)$') { continue }
            $inName = $Matches[1]; $inText = $Matches[2]
            $v = ConvertFrom-YamlScalar $inText $false
            # Only values the renderer can use: an out-of-enum setup or a multi-line value keeps the default.
            if ($v -match '\p{Cc}') { continue }
            switch ($inName) {
                'setup' { if (@('none', 'node-pnpm', 'node-npm', 'python') -ccontains $v) { $cfg['setup'] = $v } }
                'verify' { $cfg['verify'] = $v }
                'working-directory' { $cfg['working-directory'] = $v }
            }
        }
    }
    $config = Read-StubConfig ($cfg | ConvertTo-Json -Depth 10)
    $config.stubs = Get-StubsFieldFor -Config $config -PresentNames ([string[]]@($files.Keys)) -StubNames $StubNames

    $baseline = if ($Templates.Count) { Get-BaselineTexts $Templates $config } else { $null }
    Set-Knobs $config (Get-StubKnobs $files $baseline $autoFix)
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
        # Supplies the non-template fields (ref, setup, verify, working-directory, auto-fix, merge);
        # stubs / with / secrets / ledger-expiry are re-inferred per candidate against its templates.
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CurrentFiles,
        [string]$HeadRef = 'origin/main'
    )

    # Every candidate is a render SHA (a commit touching stubs/); head is the newest of them,
    # so a docs-only commit on top of the last stubs commit is never written to a lock.
    $headSha = Get-StubRenderSha -RepoRoot $RepoRoot -Sha (Resolve-Commit $RepoRoot $HeadRef)
    $log = & git -C $RepoRoot log --format=%H $headSha -- stubs/
    if ($LASTEXITCODE -ne 0) { Fail "git log failed in $RepoRoot" }
    $candidates = @($headSha) + @($log | Where-Object { $_ -and $_ -cne $headSha })

    $present = [string[]]@($CurrentFiles.Keys | ForEach-Object { ($_ -split '/')[-1] })
    [Array]::Sort($present, [StringComparer]::Ordinal)
    $leafFiles = [ordered]@{}
    foreach ($k in $CurrentFiles.Keys) { $leafFiles[($k -split '/')[-1]] = $CurrentFiles[$k] }
    $currentKeys = [string[]]@($CurrentFiles.Keys)
    [Array]::Sort($currentKeys, [StringComparer]::Ordinal)
    $autoFix = [bool]$Config.'auto-fix'

    $cache = @{}
    $getCached = {
        param([string]$Sha)
        if (-not $cache.ContainsKey($Sha)) { $cache[$Sha] = try { Get-StubsAtSha -RepoRoot $RepoRoot -Sha $Sha } catch { $null } }
        $cache[$Sha]
    }

    # Era: the newest SHA whose default stub set (for this auto-fix) is the repo's present set.
    # With an era the install used defaults, so `stubs` stays null and a stub added since then
    # surfaces as a difference; with none, the present set is pinned explicitly.
    $era = $null
    foreach ($sha in $candidates) {
        $st = & $getCached $sha
        if ($null -eq $st) { continue }
        $def = Get-DefaultStubSet -StubNames ([string[]]@($st.Keys)) -AutoFix $autoFix
        if (($def -join '|') -ceq ($present -join '|')) { $era = $sha; break }
    }
    $stubsField = if ($era) { $null } else { , $present }

    # Config for a candidate's templates: knobs inferred against that era's own template values.
    $newCandidateConfig = {
        param($Stubs, [bool]$WithKnobs)
        $c = $Config.PSObject.Copy()
        $c.stubs = $stubsField
        $c.with = [ordered]@{}; $c.secrets = [ordered]@{}; $c.'ledger-expiry' = $false
        if ($WithKnobs) { $c = Set-Knobs $c (Get-StubKnobs $leafFiles (Get-BaselineTexts $Stubs $c) $autoFix) }
        $c
    }

    $headStubs = & $getCached $headSha
    if ($null -eq $headStubs) { Fail "cannot read the stubs at ${HeadRef}" }

    $best = $null; $bestCount = [int]::MaxValue
    foreach ($sha in $candidates) {
        $stubs = & $getCached $sha
        if ($null -eq $stubs) { continue }
        # Cheap pre-check: the rendered key set is the default set (or the explicit list), so skip candidates that cannot match.
        $names = [string[]]@($stubs.Keys)
        $wanted = if ($null -eq $stubsField) { Get-DefaultStubSet -StubNames $names -AutoFix $autoFix } else { $present }
        if (($wanted -join '|') -cne ($present -join '|')) { continue }
        try {
            $cfg = & $newCandidateConfig $stubs $true
            $rendered = Invoke-StubRender -Stubs $stubs -Config $cfg
        } catch { continue }
        $renderedKeys = [string[]]@($rendered.Keys)
        [Array]::Sort($renderedKeys, [StringComparer]::Ordinal)
        # Closest era so far: fewest differing paths, then fewest inferred overrides (newest wins ties).
        $n = 0
        foreach ($k in $renderedKeys) { if (-not $CurrentFiles.Contains($k) -or $rendered[$k] -cne $CurrentFiles[$k]) { $n++ } }
        foreach ($k in $currentKeys) { if (-not $rendered.Contains($k)) { $n++ } }
        # Fewest inferred overrides breaks a tie: the true era needs none of the template values recorded.
        $knobs = [int]$cfg.'ledger-expiry'
        foreach ($v in $cfg.with.Values) { $knobs += $v.Count }
        foreach ($v in $cfg.secrets.Values) { $knobs += @($v).Count }
        $score = $n * 1000 + $knobs
        if ($score -lt $bestCount) { $best = $cfg; $bestCount = $score }
        if ($n -eq 0) {
            return [pscustomobject]@{ Sha = $sha; Matched = $true; Differences = [string[]]@(); Config = $cfg; Rendered = $rendered }
        }
    }

    # No match: the era-relative config (so what the era template supplied is not a repo choice),
    # rendered at head, so head-template changes show up as differences. Fall back to head-relative
    # knobs, then none, if the era's knobs cannot be placed in head's stubs.
    $tries = @(
        { if ($null -eq $best) { throw 'no era' }; $best },
        { & $newCandidateConfig $headStubs $true },
        { & $newCandidateConfig $headStubs $false }
    )
    $cfg = $null; $rendered = $null; $lastErr = ''
    foreach ($t in $tries) {
        try { $cfg = & $t; $rendered = Invoke-StubRender -Stubs $headStubs -Config $cfg; break }
        catch { $lastErr = $_.Exception.Message; $rendered = $null }
    }
    if ($null -eq $rendered) { Fail "the inferred config does not render at ${HeadRef}: $lastErr" }

    $diff = [System.Collections.Generic.List[string]]::new()
    $all = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($k in $rendered.Keys) { [void]$all.Add($k) }
    foreach ($k in $CurrentFiles.Keys) { [void]$all.Add($k) }
    foreach ($k in $all) {
        if (-not $rendered.Contains($k) -or -not $CurrentFiles.Contains($k) -or $rendered[$k] -cne $CurrentFiles[$k]) { $diff.Add($k) }
    }
    [pscustomobject]@{ Sha = $headSha; Matched = $false; Differences = [string[]]$diff.ToArray(); Config = $cfg; Rendered = $rendered }
}

Export-ModuleMember -Function Get-InferredStubConfig, Find-StubRenderMatch
