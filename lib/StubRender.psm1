# StubRender.psm1 - renders gh-workflows stubs for a config, and reads/writes the
# lock file. Shared by install.ps1 and the sync. All edits are text-level (never a
# YAML round-trip) so the stubs' comments survive.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'StubConfig.psm1')

$script:OptInStubs = @('auto-fix.yml', 'ledger-fix.yml')
$script:ExpiryCron = '    - cron: "17 9 * * *"'

function Fail([string]$Message) {
    throw [System.ArgumentException]::new($Message)
}

function Get-TextSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

# Runs git and returns stdout decoded as UTF-8 from the raw bytes (the console
# code page would mangle non-ASCII).
function Invoke-GitText([string]$RepoRoot, [string[]]$GitArgs) {
    $psi = [Diagnostics.ProcessStartInfo]::new('git')
    $psi.ArgumentList.Add('-C'); $psi.ArgumentList.Add($RepoRoot)
    foreach ($a in $GitArgs) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    $ms = [IO.MemoryStream]::new()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { Fail "git $($GitArgs -join ' ') failed: $($errTask.Result.Trim())" }
    $text = [Text.UTF8Encoding]::new($false).GetString($ms.ToArray())
    $text -replace "`r`n", "`n"
}

# Full commit SHA the stubs for a config ref come from: origin/main for 'main', the tag's
# commit otherwise. GHW_STUB_SHA (test hook) overrides both.
function Resolve-StubSha {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Ref
    )

    $rev = if ($env:GHW_STUB_SHA) { $env:GHW_STUB_SHA }
           elseif ($Ref -ceq 'main') { 'origin/main' }
           else { "refs/tags/$Ref" }
    (Invoke-GitText $RepoRoot @('rev-parse', '--verify', "$rev^{commit}")).Trim()
}

function Get-StubsAtSha {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Sha
    )

    $listing = Invoke-GitText $RepoRoot @('ls-tree', '--name-only', $Sha, 'stubs/')
    $stubs = @{}
    foreach ($path in ($listing -split "`n")) {
        if ($path -cnotmatch '^stubs/([^/]+\.yml)$') { continue }
        $name = $Matches[1]
        $stubs[$name] = Invoke-GitText $RepoRoot @('show', "${Sha}:stubs/$name")
    }
    $stubs
}

function Get-DefaultStubSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StubNames,
        [Parameter(Mandatory)][bool]$AutoFix
    )

    $names = [string[]]@($StubNames | Where-Object { $AutoFix -or $script:OptInStubs -cnotcontains $_ })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    , $names
}

# Line range of a job's block: [start, end) where start is the `  <jobId>:` line.
function Find-JobBlock([System.Collections.Generic.List[string]]$Lines, [string]$StubName, [string]$JobId) {
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^  ' + [regex]::Escape($JobId) + ':\s*$') { $start = $i; break }
    }
    if ($start -lt 0) { Fail "job '$JobId' not found in $StubName" }
    $end = $Lines.Count
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\S' -or $Lines[$i] -match '^  \S') { $end = $i; break }
    }
    [pscustomobject]@{ Start = $start; End = $end }
}

function Find-InBlock([System.Collections.Generic.List[string]]$Lines, $Block, [string]$Pattern) {
    for ($i = $Block.Start + 1; $i -lt $Block.End; $i++) {
        if ($Lines[$i] -match $Pattern) { return $i }
    }
    -1
}

function Set-JobWithInput([System.Collections.Generic.List[string]]$Lines, [string]$StubName, [string]$JobId, [string]$Name, $Value) {
    $block = Find-JobBlock $Lines $StubName $JobId
    $line = '      ' + $Name + ': ' + (ConvertTo-YamlScalar $Value)
    $k = [regex]::Escape($Name)
    $withAt = Find-InBlock $Lines $block '^    with:\s*$'
    if ($withAt -ge 0) {
        # The with: region: indented input lines and comments directly beneath it,
        # ending at the first blank line or other key (e.g. secrets:).
        $regionEnd = $withAt + 1
        while ($regionEnd -lt $block.End -and ($Lines[$regionEnd] -match '^      \S' -or $Lines[$regionEnd] -match '^\s*#')) { $regionEnd++ }
        for ($i = $withAt + 1; $i -lt $regionEnd; $i++) {
            if ($Lines[$i] -match ('^\s*#\s*' + $k + ':|^\s+' + $k + ':')) { $Lines[$i] = $line; return }
        }
        $Lines.Insert($withAt + 1, $line)
        return
    }
    $usesAt = Find-InBlock $Lines $block '^    uses:'
    if ($usesAt -lt 0) { Fail "job '$JobId' in $StubName has no uses: line" }
    $Lines.Insert($usesAt + 1, $line)
    $Lines.Insert($usesAt + 1, '    with:')
}

function Add-JobSecret([System.Collections.Generic.List[string]]$Lines, [string]$StubName, [string]$JobId, [string]$Secret) {
    $block = Find-JobBlock $Lines $StubName $JobId
    $line = '      ' + $Secret + ': ${{ secrets.' + $Secret + ' }}'
    $secAt = Find-InBlock $Lines $block '^    secrets:\s*$'
    if ($secAt -ge 0) {
        $last = $secAt
        for ($i = $secAt + 1; $i -lt $block.End; $i++) {
            if ($Lines[$i] -match '^      \S') { $last = $i }
            elseif ($Lines[$i] -match '^\s*$') { continue }
            else { break }
        }
        for ($i = $secAt + 1; $i -le $last; $i++) {
            if ($Lines[$i] -match ('^      ' + [regex]::Escape($Secret) + ':')) { return }
        }
        $Lines.Insert($last + 1, $line)
        return
    }
    $last = $block.Start
    for ($i = $block.Start + 1; $i -lt $block.End; $i++) { if ($Lines[$i] -notmatch '^\s*$') { $last = $i } }
    $Lines.Insert($last + 1, $line)
    $Lines.Insert($last + 1, '    secrets:')
}

function Invoke-StubRender {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Stubs,
        [Parameter(Mandatory)]$Config
    )

    if ($null -ne $Config.stubs) {
        $names = [string[]]@($Config.stubs)
        foreach ($n in $names) { if (-not $Stubs.ContainsKey($n)) { Fail "stub '$n' does not exist" } }
        $names = [string[]]@($names | Select-Object -Unique)
        [Array]::Sort($names, [StringComparer]::Ordinal)
    } else {
        $names = Get-DefaultStubSet -StubNames ([string[]]@($Stubs.Keys)) -AutoFix $Config.'auto-fix'
    }

    foreach ($field in 'with', 'secrets') {
        foreach ($key in $Config.$field.Keys) {
            $stub = $key.Split('/')[0]
            if ($names -cnotcontains $stub) { Fail "'$field' key '$key': stub '$stub' is not in the rendered set" }
        }
    }

    if ($Config.'ledger-expiry' -and $names -cnotcontains 'auto-merge.yml') {
        Fail "'ledger-expiry' needs auto-merge.yml, which is not in the rendered set"
    }

    $ref = $Config.ref
    $hasAutoFix = $Config.'auto-fix' -or ($names -ccontains 'auto-fix.yml')
    $out = [System.Collections.Specialized.OrderedDictionary]::new()

    foreach ($name in $names) {
        $txt = $Stubs[$name] -replace "`r`n", "`n"
        $txt = [regex]::Replace($txt, '@main\b', [Text.RegularExpressions.MatchEvaluator] { param($m) "@$ref" })

        if ($name -ceq 'auto-merge.yml' -and -not $hasAutoFix) {
            $txt = $txt -replace 'fix-window-minutes: \d+', 'fix-window-minutes: 0'
        }
        if ($name -ceq 'ci.yml') {
            $txt = $txt.Replace('__SETUP__', (ConvertTo-YamlScalar $Config.setup)).Replace('__VERIFY__', (ConvertTo-YamlScalar $Config.verify))
            if ($Config.'working-directory') {
                $wdScalar = ConvertTo-YamlScalar $Config.'working-directory'
                $txt = [regex]::Replace($txt, '(?m)^\s*# working-directory: web.*$', [Text.RegularExpressions.MatchEvaluator] { param($m) "      working-directory: $wdScalar" })
            }
        }

        $lines = [System.Collections.Generic.List[string]]::new([string[]]($txt -split "`n"))

        foreach ($key in $Config.with.Keys) {
            $parts = $key.Split('/')
            if ($parts[0] -cne $name) { continue }
            $inputs = $Config.with[$key]
            if ($inputs.Count -eq 0) { continue }
            $inKeys = [string[]]@($inputs.Keys)
            [Array]::Sort($inKeys, [StringComparer]::Ordinal)
            [Array]::Reverse($inKeys)
            foreach ($in in $inKeys) {
                Set-JobWithInput $lines $name $parts[1] $in $inputs[$in]
            }
        }
        foreach ($key in $Config.secrets.Keys) {
            $parts = $key.Split('/')
            if ($parts[0] -cne $name) { continue }
            foreach ($s in $Config.secrets[$key]) { Add-JobSecret $lines $name $parts[1] $s }
        }

        $txt = $lines -join "`n"

        if ($name -ceq 'auto-merge.yml' -and $Config.'ledger-expiry') {
            $onAt = [array]::IndexOf(@($lines), 'on:')
            if ($onAt -lt 0) { Fail 'auto-merge.yml has no on: line' }
            $lines.Insert($onAt + 1, $script:ExpiryCron)
            $lines.Insert($onAt + 1, '  schedule:')
            $txt = ($lines -join "`n").TrimEnd("`n") + "`n`n" +
                "  expiry:`n" +
                "    if: github.event_name == 'schedule'`n" +
                "    uses: sufnevan-sketch/gh-workflows/.github/workflows/ledger-expiry.yml@$ref`n"
        }

        $out.Add(".github/workflows/$name", $txt)
    }
    $out
}

function New-StubLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Sha,
        [Parameter(Mandatory)]$Files
    )

    $keys = [string[]]@($Files.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $sorted = [ordered]@{}
    foreach ($k in $keys) { $sorted[$k] = $Files[$k] }
    $json = ([ordered]@{ sha = $Sha; files = $sorted } | ConvertTo-Json -Depth 5)
    ($json -replace "`r`n", "`n").TrimEnd() + "`n"
}

function Read-StubLock {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

    $Text = $Text.TrimStart([char]0xFEFF)
    try {
        $raw = $Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Fail "lock is not valid JSON: $($_.Exception.Message)"
    }
    if ($raw -isnot [System.Collections.IDictionary]) { Fail 'lock must be a JSON object' }
    if ($raw['sha'] -isnot [string] -or -not $raw['sha']) { Fail "lock 'sha' must be a non-empty string" }
    if ($raw['files'] -isnot [System.Collections.IDictionary]) { Fail "lock 'files' must be an object" }
    $files = @{}
    foreach ($k in $raw['files'].Keys) {
        if ($raw['files'][$k] -isnot [string]) { Fail "lock hash for '$k' must be a string" }
        $files[$k] = $raw['files'][$k]
    }
    [pscustomobject]@{ sha = $raw['sha']; files = $files }
}

Export-ModuleMember -Function Resolve-StubSha, Get-StubsAtSha, Get-DefaultStubSet, Invoke-StubRender, Get-TextSha256, New-StubLock, Read-StubLock
