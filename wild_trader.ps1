# ============================================================================
#  GO WILD - MAX LEVERAGE ALL-IN  (PAPER ONLY - deliberately reckless experiment)
#
#  Hypothesis under test: can an aggressive leveraged strategy produce the
#  "double your money fast" returns claimed online? Backtest 2015-2026 says NO
#  ($10,000 -> $8.59, CAGR -45.9%; doubled in 0.03% of 1-week windows vs halved
#  in 0.38%). This bot runs it live on PAPER to score that prediction honestly.
#
#  RULES:
#    SIGNAL (daily, near close): QQQ close > 20-day SMA -> bullish, else bearish
#    VEHICLE: bullish -> TQQQ (3x long)   bearish -> SQQQ (3x inverse)
#             (both are BOUGHT - no short selling required)
#    SIZE:    ALL-IN at $LEVERAGE x equity of margin -> ~6x Nasdaq exposure
#    RELEVER: every day, back to full target exposure (this is what the online
#             posts do, and it is also what makes leverage decay bite)
#    STOP:    broker-side -20% disaster stop, re-armed after every size change
#
#  ISOLATION: uses WILD_APCA_* credentials ONLY and hard-aborts if it ever finds
#  itself pointed at the main dip-buyer or the copybot account.
# ============================================================================
$ErrorActionPreference = "Stop"

# ---- accounts this bot must NEVER trade -------------------------------------
$PROTECTED = @("PA3T3IPIRNWJ", "PA39L2W87E2A")   # main dip-buyer, politician copybot

# ---- strategy knobs ---------------------------------------------------------
$LEVERAGE          = 2.0     # margin multiplier on top of the 3x ETF (~6x underlying)
$DISASTER_STOP     = 0.20    # -20% broker-side stop on the position
$SMA_LEN           = 20      # trend filter length on QQQ
$RELEVER_TOLERANCE = 0.05    # only resize when >5% away from target (avoid pointless churn)
# Backtested alternative: $false = sit in CASH when bearish instead of buying SQQQ.
# That variant returned $338,210 vs $8.59 - the SQQQ side is what kills the account.
# Left as $true because the reckless version is the one being tested.
$ALLOW_SHORT_SIDE  = $true

$BULL = "TQQQ"; $BEAR = "SQQQ"; $SIGNAL = "QQQ"

# DRY RUN: validate creds/signal/sizing and place NO orders. Set WILD_DRY_RUN=1.
# Used to test the cloud plumbing outside market hours - a market order sent while the
# market is closed just queues to the open, and the script cannot arm a stop against an
# unfilled order, which is how a position once sat unprotected over a 4-day closure.
$DRY = ($env:WILD_DRY_RUN -eq "1" -or $env:WILD_DRY_RUN -eq "true")

function Stamp($m) { Write-Host "[$([DateTime]::UtcNow.ToString('HH:mm:ss'))] $m" }

# ---- credentials: cloud uses WILD_ secrets, locally fall back to wild\.env ---
$base = $env:WILD_APCA_API_BASE_URL
$kid  = $env:WILD_APCA_API_KEY_ID
$sec  = $env:WILD_APCA_API_SECRET_KEY
if (-not $kid) {
  # NOTE: reads THIS folder's .env only. Never the main alpaco\.env.
  $envPath = Join-Path $PSScriptRoot ".env"
  if (-not (Test-Path $envPath)) { throw "No WILD_APCA_* env vars and no $envPath" }
  $m = @{}
  foreach ($l in (Get-Content $envPath | Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' })) {
    $p = $l -split '=', 2
    if ($p.Count -eq 2) { $m[$p[0].Trim()] = $p[1].Trim() }
  }
  $kid = $m["WILD_APCA_API_KEY_ID"]; $sec = $m["WILD_APCA_API_SECRET_KEY"]; $base = $m["WILD_APCA_API_BASE_URL"]
}
if (-not $base) { $base = "https://paper-api.alpaca.markets" }
$base = $base.TrimEnd('/')
# A trailing /v2 caused a 404 outage on the main bot 2026-08-07 - strip it defensively.
if ($base -match '/v2$') { $base = $base -replace '/v2$', ''; Stamp "stripped trailing /v2 from base URL" }
if (-not $kid -or -not $sec) { throw "WILD Alpaca credentials missing" }
$h = @{ "APCA-API-KEY-ID" = $kid; "APCA-API-SECRET-KEY" = $sec }

# ---- HARD ISOLATION GATE ----------------------------------------------------
$acct = Invoke-RestMethod -Uri "$base/v2/account" -Headers $h
$acctNo = "$($acct.account_number)"
if ($PROTECTED -contains $acctNo) {
  throw "ABORT: wild bot is pointed at PROTECTED account $acctNo. Refusing to trade. Check WILD_APCA_* secrets."
}
if ($base -notmatch 'paper-api') {
  throw "ABORT: base URL '$base' is not the Alpaca PAPER endpoint. This experiment is paper-only."
}
Stamp "isolation OK - trading account $acctNo (paper), not the protected accounts"
if ($DRY) { Stamp "*** DRY RUN - no orders will be placed ***" }

# Market-hours guard: a market order sent while closed queues to the next open and cannot be
# protected by a stop until it fills. Refuse rather than leave a naked position (mistake #17).
$clk = Invoke-RestMethod -Uri "$base/v2/clock" -Headers $h
if (-not $clk.is_open -and -not $DRY) {
  Stamp "market is CLOSED (next open $($clk.next_open)) - refusing to queue an unprotectable order. Exiting."
  exit 0
}

$equity = [double]$acct.equity
$cash   = [double]$acct.cash
Stamp "GO WILD run. equity $([math]::Round($equity,2))  cash $([math]::Round($cash,2))"

if ($equity -lt 50) { Stamp "equity below `$50 - account is effectively wiped out. Nothing to trade. THIS IS THE RESULT."; exit 0 }

# ---- market data helpers ----------------------------------------------------
function DailyCloses($s) {
  $st = (Get-Date).ToUniversalTime().AddDays(-200).ToString("yyyy-MM-dd")
  $all = @(); $pt = $null
  do {
    $u = "https://data.alpaca.markets/v2/stocks/$s/bars?timeframe=1Day&start=${st}T00:00:00Z&limit=10000&feed=iex&adjustment=all"
    if ($pt) { $u += "&page_token=$pt" }
    $r = Invoke-RestMethod -Uri $u -Headers $h
    $all += $r.bars; $pt = $r.next_page_token
  } while ($pt)
  , @($all)
}
function LastPx($s) {
  $r = Invoke-RestMethod -Uri "https://data.alpaca.markets/v2/stocks/$s/trades/latest?feed=iex" -Headers $h
  [double]$r.trade.p
}
function Pos($s) { try { Invoke-RestMethod -Uri "$base/v2/positions/$s" -Headers $h } catch { $null } }
function CancelOpen($s) {
  # Filter on a real field: an empty Alpaca list ([]) becomes $null and @($null) has Count 1,
  # which would otherwise send a DELETE to /v2/orders/ with an empty id.
  foreach ($o in @(Invoke-RestMethod -Uri "$base/v2/orders?status=open&symbols=$s" -Headers $h | Where-Object { $_ -and $_.id })) {
    try { Invoke-RestMethod -Uri "$base/v2/orders/$($o.id)" -Method Delete -Headers $h | Out-Null } catch {}
  }
}

# ---- 1) SIGNAL --------------------------------------------------------------
$qb = DailyCloses $SIGNAL
$qc = @($qb | ForEach-Object { [double]$_.c })
if ($qc.Count -lt ($SMA_LEN + 1)) { throw "not enough QQQ history ($($qc.Count) bars)" }
$sum = 0.0; for ($j = $qc.Count - $SMA_LEN; $j -lt $qc.Count; $j++) { $sum += $qc[$j] }
$sma = $sum / $SMA_LEN
$qpx = $qc[-1]
$bullish = $qpx -gt $sma
$target = if ($bullish) { $BULL } elseif ($ALLOW_SHORT_SIDE) { $BEAR } else { $null }
Stamp "signal: QQQ $([math]::Round($qpx,2)) vs ${SMA_LEN}SMA $([math]::Round($sma,2)) -> $(if($bullish){'BULLISH'}else{'BEARISH'}) -> target $(if($target){$target}else{'CASH'})"

# ---- 2) EXIT anything that is not the target vehicle ------------------------
foreach ($s in @($BULL, $BEAR)) {
  if ($s -eq $target) { continue }
  $p = Pos $s
  if (-not $p) { continue }
  if ($DRY) { Stamp "DRY: would close $s qty $($p.qty) (signal favours $(if($target){$target}else{'cash'}))"; continue }
  CancelOpen $s; Start-Sleep -Seconds 1
  try {
    Invoke-RestMethod -Uri "$base/v2/positions/$s" -Method Delete -Headers $h | Out-Null
    Stamp "FLIP: closed $s (uPL $([math]::Round([double]$p.unrealized_pl,2))) - signal now favours $(if($target){$target}else{'cash'})"
    Start-Sleep -Seconds 3
  } catch { Stamp "$s close err $($_.ErrorDetails.Message)" }
}
if (-not $target) { Stamp "bearish with short side disabled - staying in cash"; exit 0 }

# ---- 3) RE-LEVER to full target exposure ------------------------------------
# Re-read the account: the flip above changes cash/equity.
$acct = Invoke-RestMethod -Uri "$base/v2/account" -Headers $h
$equity = [double]$acct.equity
# regt_buying_power is the OVERNIGHT (Reg-T) limit. Using day-trading BP would let the
# position get force-liquidated at the close, which would confound the experiment.
$regt = [double]$acct.regt_buying_power
$px = LastPx $target
$targetNotional = [math]::Min($equity * $LEVERAGE, $regt * 0.97)

$p = Pos $target
$curQty = if ($p) { [int]$p.qty } else { 0 }
$curNotional = $curQty * $px
$targetQty = [int][math]::Floor($targetNotional / $px)
$delta = $targetQty - $curQty

Stamp "exposure: have $curQty $target (`$$([math]::Round($curNotional,0))) target $targetQty (`$$([math]::Round($targetNotional,0))) at $([math]::Round($px,2)) = $([math]::Round($targetNotional/$equity,2))x equity"

$drift = if ($targetQty -gt 0) { [math]::Abs($delta) / [double]$targetQty } else { 0 }
if ($delta -ne 0 -and $drift -gt $RELEVER_TOLERANCE) {
  $side = if ($delta -gt 0) { "buy" } else { "sell" }
  $qty = [math]::Abs($delta)
  if ($DRY) {
    Stamp "DRY: would $($side.ToUpper()) $qty $target @ ~$([math]::Round($px,2)) -> $targetQty shares = `$$([math]::Round($targetNotional,0)) ($([math]::Round($targetNotional/$equity,2))x equity)"
    Stamp "DRY: would then arm a stop @ $([math]::Round($px*(1-$DISASTER_STOP),2)) (-$([math]::Round($DISASTER_STOP*100,0))%) and verify it rests"
    Stamp "DRY RUN complete - plumbing OK, no orders placed"
    exit 0
  }
  # Cancel the resting stop first - it reserves shares and will reject/partial the resize.
  CancelOpen $target; Start-Sleep -Seconds 1
  $body = @{ symbol = $target; qty = "$qty"; side = $side; type = "market"; time_in_force = "day" } | ConvertTo-Json
  try {
    Invoke-RestMethod -Uri "$base/v2/orders" -Method Post -Headers $h -Body $body -ContentType "application/json" | Out-Null
    Stamp "$(($side).ToUpper()) $qty $target - re-levering to $LEVERAGE`x equity (~$([math]::Round($LEVERAGE*3,0))x Nasdaq)"
    for ($try = 1; $try -le 20; $try++) { Start-Sleep -Seconds 2; $chk = Pos $target; if ($chk -and [int]$chk.qty -eq $targetQty) { break } }
  } catch { Stamp "$target $side err $($_.ErrorDetails.Message)" }
} else {
  Stamp "already within $([math]::Round($RELEVER_TOLERANCE*100,0))% of target exposure - no resize"
  if ($DRY) { Stamp "DRY RUN complete - plumbing OK, no orders placed"; exit 0 }
}

# ---- 4) ARM the disaster stop, then VERIFY it actually rests ----------------
# A silent stop failure once left a main-bot position unprotected over a 4-day weekend.
$p = Pos $target
if (-not $p) { Stamp "WARNING: no $target position after resize - nothing to protect"; exit 0 }
$qty = [int]$p.qty
$entry = [double]$p.avg_entry_price
$stopPx = [math]::Round($entry * (1 - $DISASTER_STOP), 2)

$hasStop = @(Invoke-RestMethod -Uri "$base/v2/orders?status=open&symbols=$target" -Headers $h |
             Where-Object { $_.side -eq "sell" -and $_.type -eq "stop" -and [int]$_.qty -eq $qty }).Count -ge 1
if (-not $hasStop) {
  CancelOpen $target; Start-Sleep -Seconds 1
  $armed = $false
  for ($try = 1; $try -le 5 -and -not $armed; $try++) {
    $sb = @{ symbol = $target; qty = "$qty"; side = "sell"; type = "stop"; stop_price = "$stopPx"; time_in_force = "gtc" } | ConvertTo-Json
    try {
      Invoke-RestMethod -Uri "$base/v2/orders" -Method Post -Headers $h -Body $sb -ContentType "application/json" | Out-Null
      $armed = $true
    } catch { Stamp "stop attempt $try err $($_.ErrorDetails.Message)"; Start-Sleep -Seconds 3 }
  }
  # Verify by re-querying - do not trust the POST alone.
  Start-Sleep -Seconds 2
  $verify = @(Invoke-RestMethod -Uri "$base/v2/orders?status=open&symbols=$target" -Headers $h |
              Where-Object { $_.side -eq "sell" -and $_.type -eq "stop" })
  if ($verify.Count -ge 1) { Stamp "$target disaster-stop VERIFIED resting @ $stopPx (-$([math]::Round($DISASTER_STOP*100,0))%)" }
  else { Stamp "$target WARNING: disaster stop NOT armed after retries - POSITION UNPROTECTED, needs manual stop!" }
} else {
  Stamp "$target disaster-stop already resting for $qty shares"
}

$acct = Invoke-RestMethod -Uri "$base/v2/account" -Headers $h
Stamp "done. equity $([math]::Round([double]$acct.equity,2))  cash $([math]::Round([double]$acct.cash,2))  (negative cash = on margin, which is the point)"
