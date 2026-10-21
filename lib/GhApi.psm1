# GitHub IO for the stub sync. Every GitHub call goes through Invoke-GhApi (the one
# mock seam); Invoke-GhProcess is the only place that launches `gh`.

Import-Module "$PSScriptRoot/StubRender.psm1"

# Exception types are plain .NET types (Add-Type), so they are visible session-wide:
# callers can `catch [GhApiException]` / `catch [GhAuthException]` with no `using module`.
if (-not ('GhApiException' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public class GhApiException : Exception {
    public int Status { get; private set; }
    public GhApiException(string message, int status) : base(message) { Status = status; }
}
public class GhAuthException : GhApiException {
    public GhAuthException(string message, int status) : base(message, status) { }
}
'@
}

$script:SyncBranch = 'chore/gh-workflows-sync'
$script:ConfigPath = '.github/gh-workflows.json'
$script:LockPath = '.github/gh-workflows.lock'

function Invoke-GhProcess {
    # Seam for the stderr->exception test. Returns @{ ExitCode; Stdout; Stderr }.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$StdIn)

    $psi = [System.Diagnostics.ProcessStartInfo]::new('gh')
    $quoted = foreach ($a in $Arguments) { '"' + ($a -replace '"', '\"') + '"' }
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if ($PSBoundParameters.ContainsKey('StdIn')) {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($StdIn)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    }
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $outTask.Result; Stderr = $errTask.Result }
}

function Invoke-GhApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body,
        [switch]$Paginate
    )
    $ghArgs = @('api', '-X', $Method.ToUpperInvariant(), $Path, '-H', 'Accept: application/vnd.github+json')
    # --slurp (gh >= 2.48) wraps every page in one outer array, even for object pages.
    if ($Paginate) { $ghArgs += @('--paginate', '--slurp') }
    $proc = @{}
    if ($PSBoundParameters.ContainsKey('Body')) {
        $ghArgs += @('--input', '-')
        $proc['StdIn'] = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
    }
    $r = Invoke-GhProcess -Arguments $ghArgs @proc
    if ($r.ExitCode -ne 0) {
        $status = 0
        if ($r.Stderr -match 'HTTP (\d{3})') { $status = [int]$Matches[1] }
        $msg = "gh api $Method $Path failed: $($r.Stderr.Trim())"
        if ($status -eq 401 -or $r.Stderr -match 'gh auth login|not logged in|authentication required') {
            throw [GhAuthException]::new($msg, $status)
        }
        throw [GhApiException]::new($msg, $status)
    }
    if ([string]::IsNullOrWhiteSpace($r.Stdout)) { return $null }
    $data = $r.Stdout | ConvertFrom-Json -Depth 20
    if ($Paginate) {
        # Pages that are arrays merge into one flat array; object pages stay as a page list.
        $pages = @($data)
        if (@($pages | Where-Object { $_ -isnot [System.Array] }).Count -eq 0) {
            $flat = [System.Collections.Generic.List[object]]::new()
            foreach ($p in $pages) { foreach ($i in $p) { $flat.Add($i) } }
            return $flat.ToArray()
        }
        return $pages
    }
    $data
}

function Get-StatusOf($Exception) { if ($Exception -is [GhApiException]) { $Exception.Status } else { 0 } }

function ConvertFrom-GhContent($Item) {
    $b64 = ([string]$Item.content) -replace '\s', ''
    $bytes = [Convert]::FromBase64String($b64)
    [Text.UTF8Encoding]::new($false).GetString($bytes)   # no EOL normalisation, CR preserved; invalid bytes become U+FFFD (reads as drift, intended)
}

function Get-RepoFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string[]]$Paths)
    $out = @{}
    $q = [uri]::EscapeDataString($Ref)
    foreach ($p in $Paths) {
        try {
            $item = Invoke-GhApi -Method GET -Path "repos/$Repo/contents/${p}?ref=$q"
        } catch {
            if ((Get-StatusOf $_.Exception) -eq 404) { continue }
            throw
        }
        if ($null -ne $item -and $item.PSObject.Properties['content']) { $out[$p] = ConvertFrom-GhContent $item }
    }
    $out
}

function Get-SyncRepoList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Owners)
    $login = (Invoke-GhApi -Method GET -Path 'user').login
    $found = foreach ($owner in $Owners) {
        # users/<o>/repos lists PUBLIC repos only, even for the logged-in user; user/repos sees private ones.
        if ($login -and $owner -ieq $login) {
            $path = 'user/repos?affiliation=owner&per_page=100'
        } else {
            $u = Invoke-GhApi -Method GET -Path "users/$owner"
            $path = if ($u.type -eq 'Organization') { "orgs/$owner/repos?per_page=100" } else { "users/$owner/repos?per_page=100" }
        }
        $repos = @(Invoke-GhApi -Method GET -Path $path -Paginate)
        foreach ($r in $repos) {
            if ($r.archived) { continue }
            $files = Get-RepoFiles -Repo $r.full_name -Ref $r.default_branch -Paths @($script:ConfigPath)
            if ($files.ContainsKey($script:ConfigPath)) {
                [pscustomobject]@{ FullName = $r.full_name; DefaultBranch = $r.default_branch }
            }
        }
    }
    @($found)
}

function Get-SyncRepoState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repo)
    $meta = Invoke-GhApi -Method GET -Path "repos/$Repo"
    $branch = $meta.default_branch
    $ref = Invoke-GhApi -Method GET -Path "repos/$Repo/git/ref/heads/$branch"
    $sha = $ref.object.sha
    $files = Get-RepoFiles -Repo $Repo -Ref $branch -Paths @($script:ConfigPath, $script:LockPath)
    [pscustomobject]@{
        DefaultBranch = $branch
        DefaultSha    = $sha
        ConfigText    = $files[$script:ConfigPath]
        LockText      = $files[$script:LockPath]
    }
}

function Get-SyncBranchState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$DefaultBranch)
    try {
        $ref = Invoke-GhApi -Method GET -Path "repos/$Repo/git/ref/heads/$script:SyncBranch"
    } catch {
        if ((Get-StatusOf $_.Exception) -eq 404) { return $null }
        throw
    }
    $head = $ref.object.sha
    $cmp = Invoke-GhApi -Method GET -Path "repos/$Repo/compare/$([uri]::EscapeDataString($DefaultBranch))...$script:SyncBranch"
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @($cmp.files)) {
        if (-not $f) { continue }
        $changed.Add([string]$f.filename)
        if ($f.PSObject.Properties['previous_filename'] -and $f.previous_filename) { $changed.Add([string]$f.previous_filename) }
    }
    $files = Get-RepoFiles -Repo $Repo -Ref $head -Paths @($script:LockPath)
    [pscustomobject]@{
        HeadSha      = $head
        ChangedPaths = [string[]]$changed.ToArray()
        LockText     = $files[$script:LockPath]
    }
}

function Get-SyncPrRaw {
    param([string]$Repo)
    $owner = ($Repo -split '/')[0]
    $prs = @(Invoke-GhApi -Method GET -Path "repos/$Repo/pulls?head=${owner}:$script:SyncBranch&state=all&sort=created&direction=desc")
    $prs | Where-Object { $_ } | Select-Object -First 1
}

function Get-SyncPr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repo)
    $pr = Get-SyncPrRaw -Repo $Repo
    if (-not $pr) { return $null }
    $headSha = $pr.head.sha
    $lockSha = $null
    $files = Get-RepoFiles -Repo $Repo -Ref $headSha -Paths @($script:LockPath)
    if ($files.ContainsKey($script:LockPath)) {
        try { $lockSha = (Read-StubLock $files[$script:LockPath]).sha } catch { $lockSha = $null }
    }
    [pscustomobject]@{
        Number  = [int]$pr.number
        State   = [string]$pr.state
        Merged  = ($null -ne $pr.merged_at)
        HeadSha = $headSha
        LockSha = $lockSha
    }
}

function Publish-SyncCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$DefaultSha,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Files,
        [string[]]$Deletes = @(),
        [Parameter(Mandatory)][string]$Message
    )
    $tree = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $Files.Keys) {
        $tree.Add(@{ path = [string]$k; mode = '100644'; type = 'blob'; content = [string]$Files[$k] })
    }
    foreach ($d in $Deletes) {
        $tree.Add(@{ path = $d; mode = '100644'; type = 'blob'; sha = $null })
    }
    $t = Invoke-GhApi -Method POST -Path "repos/$Repo/git/trees" -Body @{ base_tree = $DefaultSha; tree = $tree.ToArray() }
    $c = Invoke-GhApi -Method POST -Path "repos/$Repo/git/commits" -Body @{ message = $Message; tree = $t.sha; parents = @($DefaultSha) }
    $exists = $true
    try {
        $null = Invoke-GhApi -Method GET -Path "repos/$Repo/git/ref/heads/$script:SyncBranch"
    } catch {
        if ((Get-StatusOf $_.Exception) -eq 404) { $exists = $false } else { throw }
    }
    if ($exists) {
        $null = Invoke-GhApi -Method PATCH -Path "repos/$Repo/git/refs/heads/$script:SyncBranch" -Body @{ sha = $c.sha; force = $true }
    } else {
        $null = Invoke-GhApi -Method POST -Path "repos/$Repo/git/refs" -Body @{ ref = "refs/heads/$script:SyncBranch"; sha = $c.sha }
    }
    [string]$c.sha
}

function Set-SyncPr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body
    )
    $pr = Get-SyncPrRaw -Repo $Repo
    if ($pr -and $pr.state -eq 'open') {
        $null = Invoke-GhApi -Method PATCH -Path "repos/$Repo/pulls/$($pr.number)" -Body @{ title = $Title; body = $Body }
        return [int]$pr.number
    }
    # Never reopen: the force-pushed branch is not a descendant of a closed PR's head (422); open a new PR.
    $new = Invoke-GhApi -Method POST -Path "repos/$Repo/pulls" -Body @{ title = $Title; body = $Body; head = $script:SyncBranch; base = $Base }
    [int]$new.number
}

function Close-SyncPr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$Comment)
    $null = Invoke-GhApi -Method POST -Path "repos/$Repo/issues/$Number/comments" -Body @{ body = $Comment }
    $null = Invoke-GhApi -Method PATCH -Path "repos/$Repo/pulls/$Number" -Body @{ state = 'closed' }
}

function Get-CiState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Sha)
    $resp = Invoke-GhApi -Method GET -Path "repos/$Repo/commits/$Sha/check-runs?per_page=100" -Paginate
    $runs = foreach ($page in @($resp)) { foreach ($r in @($page.check_runs)) { if ($r) { $r } } }
    $state = {
        param($name)
        $mine = @($runs | Where-Object { $_.name -eq $name })
        if ($mine.Count -eq 0) { return 'missing' }
        $latest = $mine | Sort-Object @{ Expression = { [long]$_.id }; Descending = $true } | Select-Object -First 1   # ids are monotonic; queued re-runs have null started_at
        if ($latest.status -ne 'completed') { return 'pending' }
        switch ($latest.conclusion) {
            'success' { 'success' }
            { $_ -in 'skipped', 'neutral' } { 'missing' }
            default { 'failure' }
        }
    }
    [pscustomobject]@{
        BranchName = & $state 'ci / branch-name'
        Verify     = & $state 'ci / verify'
    }
}

function Merge-SyncPr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$Sha)
    $null = Invoke-GhApi -Method PUT -Path "repos/$Repo/pulls/$Number/merge" -Body @{ merge_method = 'squash'; sha = $Sha }
}

Export-ModuleMember -Function Invoke-GhApi, Get-SyncRepoList, Get-SyncRepoState, Get-RepoFiles, Get-SyncBranchState, Get-SyncPr, Publish-SyncCommit, Set-SyncPr, Close-SyncPr, Get-CiState, Merge-SyncPr
