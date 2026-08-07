# Appends one row per day to wild_pnl.csv so the experiment has an honest scorecard.
# Read-only against Alpaca - places no orders.
$ErrorActionPreference = "Stop"
$PROTECTED = @("PA3T3IPIRNWJ", "PA39L2W87E2A")

$base = $env:WILD_APCA_API_BASE_URL
$kid  = $env:WILD_APCA_API_KEY_ID
$sec  = $env:WILD_APCA_API_SECRET_KEY
if (-not $kid) {
  $envPath = Join-Path $PSScriptRoot ".env"
  $m = @{}
  foreach ($l in (Get-Content $envPath | Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' })) {
    $p = $l -split '=', 2; if ($p.Count -eq 2) { $m[$p[0].Trim()] = $p[1].Trim() }
  }
  $kid = $m["WILD_APCA_API_KEY_ID"]; $sec = $m["WILD_APCA_API_SECRET_KEY"]; $base = $m["WILD_APCA_API_BASE_URL"]
}
if (-not $base) { $base = "https://paper-api.alpaca.markets" }
# Trim first - a secret stored with a trailing newline breaks the URL and the auth headers.
$base = $base.Trim(); $kid = $kid.Trim(); $sec = $sec.Trim()
$base = ($base.TrimEnd('/')) -replace '/v2$', ''
$h = @{ "APCA-API-KEY-ID" = $kid; "APCA-API-SECRET-KEY" = $sec }

$a = Invoke-RestMethod -Uri "$base/v2/account" -Headers $h
if ($PROTECTED -contains "$($a.account_number)") { throw "ABORT: recorder pointed at PROTECTED account $($a.account_number)" }

$eq = [double]$a.equity; $last = [double]$a.last_equity
$day = [math]::Round($eq - $last, 2)
$cum = [math]::Round($eq - 10000, 2)
# An empty Alpaca list ([]) comes back as $null, and @($null) has Count 1 - so filter on a real
# field, never on .Count alone. Without the Where-Object this writes ":" on a flat day.
$pos = @(Invoke-RestMethod -Uri "$base/v2/positions" -Headers $h | Where-Object { $_ -and $_.symbol })
$held = ($pos | ForEach-Object { "$($_.symbol):$($_.qty)" }) -join ";"
if (-not $held) { $held = "flat" }

$f = Join-Path $PSScriptRoot "wild_pnl.csv"
if (-not (Test-Path $f)) { "date,equity,cash,day_pl,cum_pl,pct_of_start,positions" | Out-File $f -Encoding utf8 }
$row = "{0},{1},{2},{3},{4},{5},{6}" -f (Get-Date -Format "yyyy-MM-dd"), [math]::Round($eq,2),
        [math]::Round([double]$a.cash,2), $day, $cum, [math]::Round($eq/10000*100,1), $held
Add-Content -Path $f -Value $row
Write-Host "recorded: $row"
