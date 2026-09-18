<#
.SYNOPSIS  Push named secrets from a gitignored env file to a repo's Actions secrets, without printing them.
.DESCRIPTION
  Reads KEY=VALUE lines from -EnvFile (default: the workspace .env), and for each name in -Names
  runs `gh secret set <name> --repo <repo> --body <value>`. Values stay in process memory; nothing
  is echoed. A name that is missing or empty in the env file is reported, not set. Then prints
  `gh secret list` (names and dates only).
.EXAMPLE   pwsh set-secrets.ps1 -Repo sufnevan-sketch/evan-workspace
.EXAMPLE   pwsh set-secrets.ps1 -Repo camedu-io/crm -Names CLAUDE_CODE_OAUTH_TOKEN,OPENAI_API_KEY,AUTOFIX_PAT
.NOTES     Interactive `gh secret set` from a non-TTY stores an empty value; --body avoids that.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Repo,                       # owner/repo
  [string[]] $Names = @('CLAUDE_CODE_OAUTH_TOKEN', 'CODEX_TRIGGER_PAT'),   # add OPENAI_API_KEY for codex mode: action, AUTOFIX_PAT for auto-fix
  [string] $EnvFile = 'C:\Users\evanl\Desktop\EVAN_WORKSPACE\.env'
)
$ErrorActionPreference = 'Stop'
# `pwsh set-secrets.ps1 -Names a,b` from another shell arrives as the single string "a,b"; normalize.
$Names = @($Names | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not (Test-Path -LiteralPath $EnvFile)) { throw "env file not found: $EnvFile" }

$vals = @{}
foreach ($line in [IO.File]::ReadAllLines($EnvFile)) {
  $l = $line.Trim()
  if ($l -eq '' -or $l.StartsWith('#')) { continue }
  $i = $l.IndexOf('=')
  if ($i -lt 1) { continue }
  $k = $l.Substring(0, $i).Trim()
  $v = $l.Substring($i + 1).Trim().Trim('"').Trim("'")
  $vals[$k] = $v
}

$missing = @()
foreach ($n in $Names) {
  if (-not $vals.ContainsKey($n) -or [string]::IsNullOrWhiteSpace($vals[$n])) { $missing += $n; continue }
  gh secret set $n --repo $Repo --body $vals[$n] | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "gh secret set $n failed (exit $LASTEXITCODE)" }
  Write-Host "set     $n ($($vals[$n].Length) chars)"
}
if ($missing) { Write-Host "MISSING in $EnvFile (add the value on its NAME= line, then rerun): $($missing -join ', ')" }

Write-Host "--- gh secret list --repo $Repo ---"
gh secret list --repo $Repo
if ($missing) { exit 1 }
