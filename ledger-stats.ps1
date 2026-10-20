<#
.SYNOPSIS  Fix rates for non-blocking review findings, from review-outcomes comments and review-ledger issues.
.DESCRIPTION
  Per finding, not per issue: one ledger issue holds mixed items, so its close reason cannot
  give a fix rate. Sources:
    - `<!-- review-outcomes:v1 {...} -->` comments on merged PRs (posted by review-ledger.yml):
      each non-blocking finding's severity, reviewer and pre-merge outcome
      (addressed by a push / dropped / deferred).
    - `review-ledger` issues: a ticked box is a deferred item fixed later; an unticked box in a
      closed issue was skipped or expired.
  Thresholds printed at the end are judgment calls from the research report
  (docs/review-ledger-research in EVAN_WORKSPACE), not published norms.
  Read-only: only `gh` reads. Runs on Windows PowerShell 5.1 and pwsh 7.
.EXAMPLE   pwsh ledger-stats.ps1 -Repos camedu-io/crm
.EXAMPLE   powershell -File ledger-stats.ps1 -Repos camedu-io/crm,sufnevan-sketch/gh-workflows -Days 60
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string[]] $Repos,
  [int] $Days = 90
)
$ErrorActionPreference = 'Stop'
# `-File script.ps1 -Repos a,b` passes one string "a,b"; split it here.
$Repos = @($Repos | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# A failed gh call must stop the report, not print zeros.
function Invoke-Gh {
  $out = & gh @args
  if ($LASTEXITCODE -ne 0) { throw "gh $($args -join ' ') failed (exit $LASTEXITCODE)" }
  $out
}
$since = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyy-MM-dd')
$tiers = @('P2', 'P3', 'MEDIUM', 'LOW', 'note')

function Get-Sev([string] $text) {
  $m = [regex]::Match($text, '\b(CRITICAL|HIGH|MEDIUM|LOW|P[0-3])\b')
  if ($m.Success) { return $m.Groups[1].Value } else { return 'note' }
}
function New-Row { [ordered]@{ addressed = 0; dropped = 0; deferred = 0; ledgerFixed = 0; ledgerOpen = 0; ledgerClosedUnfixed = 0 } }

$byTier = @{}
foreach ($t in $tiers) { $byTier[$t] = New-Row }
$mergedCount = 0; $prsWithFindings = 0; $ledgerCount = 0; $openAges = @()
$autoFix = [ordered]@{ merged = 0; closedUnmerged = 0; open = 0 }

foreach ($r in $Repos) {
  # --- Pre-merge outcomes, one comment per merged PR ---
  $prs = Invoke-Gh pr list --repo $r --state merged --search "merged:>=$since" --limit 500 --json "number,headRefName" | ConvertFrom-Json
  $mergedCount += @($prs).Count
  foreach ($p in $prs) {
    $comments = Invoke-Gh api "repos/$r/issues/$($p.number)/comments?per_page=100" | ConvertFrom-Json
    $mark = @($comments | Where-Object { $_.body -match '<!-- review-outcomes:v1 (\{.*?\}) -->' }) | Select-Object -First 1
    if (-not $mark) { continue }
    $null = $mark.body -match '<!-- review-outcomes:v1 (\{.*?\}) -->'
    $rec = $Matches[1] | ConvertFrom-Json
    if (@($rec.items).Count -gt 0) { $prsWithFindings++ }
    foreach ($i in $rec.items) {
      $t = if ($tiers -contains $i.sev) { $i.sev } else { 'note' }
      $byTier[$t][$i.outcome]++
    }
  }
  # --- Auto-fix PRs (ledger-fix opens fix/ledger-<n>) ---
  $fixPrs = Invoke-Gh pr list --repo $r --state all --search "head:fix/ledger- created:>=$since" --limit 200 --json state | ConvertFrom-Json
  foreach ($f in $fixPrs) {
    if ($f.state -eq 'MERGED') { $autoFix.merged++ } elseif ($f.state -eq 'CLOSED') { $autoFix.closedUnmerged++ } else { $autoFix.open++ }
  }
  # --- Ledger items: ticked = fixed after merge ---
  $issues = Invoke-Gh issue list --repo $r --label review-ledger --state all --limit 500 --search "created:>=$since" --json "number,state,body,createdAt" | ConvertFrom-Json
  $ledgerCount += @($issues).Count
  foreach ($iss in $issues) {
    if ($iss.state -eq 'OPEN') { $openAges += ((Get-Date).ToUniversalTime() - [datetime]$iss.createdAt).TotalDays }
    foreach ($line in ($iss.body -split "`n")) {
      $m = [regex]::Match($line, '^- \[( |x|X)\] (.*)$')
      if (-not $m.Success) { continue }
      $sev = Get-Sev $m.Groups[2].Value
      $t = if ($tiers -contains $sev) { $sev } else { 'note' }
      if ($m.Groups[1].Value -ne ' ') { $byTier[$t].ledgerFixed++ }
      elseif ($iss.state -eq 'OPEN') { $byTier[$t].ledgerOpen++ }
      else { $byTier[$t].ledgerClosedUnfixed++ }
    }
  }
}

"Window: last $Days days (since $since UTC), repos: $($Repos -join ', ')"
"Merged PRs: $mergedCount   with non-blocking findings: $prsWithFindings   ledger issues: $ledgerCount"
""
$rows = foreach ($t in $tiers) {
  $x = $byTier[$t]
  $total = $x.addressed + $x.dropped + $x.deferred
  if ($total -eq 0 -and ($x.ledgerFixed + $x.ledgerOpen + $x.ledgerClosedUnfixed) -eq 0) { continue }
  $fixed = $x.addressed + $x.ledgerFixed
  [pscustomobject]@{
    Tier = $t; Findings = $total; Addressed = $x.addressed; Dropped = $x.dropped; Deferred = $x.deferred
    LedgerFixed = $x.ledgerFixed; LedgerOpen = $x.ledgerOpen; LedgerExpiredOrSkipped = $x.ledgerClosedUnfixed
    FixedShare = if ($total -gt 0) { '{0:P0}' -f ($fixed / $total) } else { 'n/a' }
  }
}
$rows | Format-Table -AutoSize | Out-String -Width 200
$open = @($openAges)
if ($open.Count) { "Open ledgers: $($open.Count)   oldest: {0:N0} days" -f ($open | Measure-Object -Maximum).Maximum } else { "Open ledgers: 0" }
"Auto-fix PRs: $($autoFix.merged) merged, $($autoFix.closedUnmerged) closed unmerged, $($autoFix.open) open"
""
"Thresholds (judgment, see the research report):"
$low = 0; $lowFixed = 0
foreach ($t in @('LOW', 'P3')) { $x = $byTier[$t]; $low += $x.addressed + $x.dropped + $x.deferred; $lowFixed += $x.addressed + $x.ledgerFixed }
if ($low -eq 0) { "  - LOW/P3 fixed share: no recorded LOW/P3 findings yet (outcomes start with the fix-window stub)" }
elseif ($mergedCount -lt 20) { "  - LOW/P3 fixed share: wait for 20 merged PRs (have $mergedCount)" }
elseif ($low -gt 0 -and ($lowFixed / $low) -lt 0.25) { "  - LOW/P3 fixed share {0:P0} < 25%: stop requesting LOW/P3 (reviewer prompt + AGENTS.md)" -f ($lowFixed / $low) }
else { "  - LOW/P3 fixed share OK" }
if ($mergedCount -gt 0) {
  $ratio = $ledgerCount / $mergedCount
  if ($ratio -ge 0.3) { "  - Ledger issues per merged PR {0:N2} >= 0.3: tune reviewers or use the fix window more" -f $ratio } else { "  - Ledger issues per merged PR {0:N2} OK (< 0.3)" -f $ratio }
}
$af = $autoFix.merged + $autoFix.closedUnmerged
if ($af -ge 10) {
  if ($autoFix.merged / $af -ge 0.8) { "  - Auto-fix merged $($autoFix.merged)/${af}: candidate for default-on (check reverts by hand)" } else { "  - Auto-fix merged $($autoFix.merged)/${af} < 80%: keep opt-in" }
} else { "  - Auto-fix: $af finished PRs, decide at 10" }
"  - Same finding class dropped 3 times: add a 'Do not report' line (review-context.md, AGENTS.md); judged by hand"
