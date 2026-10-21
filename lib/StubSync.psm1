Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'StubRender.psm1')

function New-SyncResult([string]$Action, [string[]]$Reasons = @(), [string[]]$Deletes = @(), [bool]$AutoMerge = $false, [bool]$BranchCurrent = $false) {
    [pscustomobject]@{
        Action        = $Action
        Reasons       = [string[]]@($Reasons)
        Deletes       = [string[]]@($Deletes)
        AutoMerge     = $AutoMerge
        BranchCurrent = $BranchCurrent
    }
}

function Test-RenderedEqualsRepo($Rendered, $RepoFiles) {
    if ($Rendered.Count -ne $RepoFiles.Count) { return $false }
    foreach ($k in $Rendered.Keys) {
        if (-not $RepoFiles.ContainsKey($k)) { return $false }
        if (-not [string]::Equals([string]$Rendered[$k], [string]$RepoFiles[$k], [StringComparison]::Ordinal)) { return $false }
    }
    $true
}

# Pure decision for one repo. No IO. See spec section 3, steps 3-6.
function Get-SyncAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rendered,
        [Parameter(Mandatory)][string]$RenderSha,
        [Parameter(Mandatory)]$RepoFiles,
        [AllowNull()]$Lock,
        [Parameter(Mandatory)][string]$Merge,
        [AllowNull()]$Branch,
        [AllowNull()]$Pr
    )

    if ($null -eq $Lock) { return New-SyncResult 'hold' @('not adopted') }

    if (Test-RenderedEqualsRepo $Rendered $RepoFiles) { return New-SyncResult 'current' }

    if ($null -ne $Pr -and $Pr.State -eq 'closed' -and -not $Pr.Merged -and $Pr.LockSha -eq $RenderSha) {
        return New-SyncResult 'hold' @('closed by hand')
    }

    if ($null -ne $Branch -and -not $Branch.IsOwn) {
        return New-SyncResult 'hold' @('sync branch changed by someone else')
    }

    $lockKeys = [string[]]@($Lock.files.Keys)
    [Array]::Sort($lockKeys, [StringComparer]::Ordinal)

    $deletes = [System.Collections.Generic.List[string]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $lockKeys) {
        $present = $RepoFiles.ContainsKey($k)
        $unchanged = $present -and ((Get-TextSha256 ([string]$RepoFiles[$k])) -eq $Lock.files[$k])
        if ($unchanged) {
            if (-not $Rendered.Contains($k)) { $deletes.Add($k) }
        } elseif ($present) {
            $reasons.Add("drift: $k differs from lock")
        } else {
            $reasons.Add("drift: $k missing")
        }
    }
    $drift = $reasons.Count -gt 0
    $autoMerge = (-not $drift) -and $Merge -eq 'auto'
    if ($Merge -ne 'auto') { $reasons.Add('merge: manual') }

    $branchAtRender = $null -ne $Branch -and $Branch.IsOwn -and $Branch.RenderSha -eq $RenderSha
    if ($branchAtRender) {
        if ($null -ne $Pr -and $Pr.State -eq 'open') {
            $action = if ($autoMerge) { 'wait' } else { 'hold' }
            return New-SyncResult $action $reasons $deletes $autoMerge $true
        }
        return New-SyncResult 'push' $reasons $deletes $autoMerge $true
    }

    New-SyncResult 'push' $reasons $deletes $autoMerge $false
}

Export-ModuleMember -Function Get-SyncAction
