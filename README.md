# GO WILD — max-leverage paper-trading experiment

**PAPER MONEY ONLY.** This repo deliberately runs a reckless strategy to test a claim, not to make money.

## The question

Can an aggressive leveraged strategy produce the "double your $10k in a week" returns
that circulate online? This bot runs one honestly and keeps score.

## The strategy

| | |
|---|---|
| Signal | QQQ close vs its 20-day SMA, evaluated once daily near the close |
| Vehicle | bullish → **TQQQ** (3x long) · bearish → **SQQQ** (3x inverse) — both bought, no short selling |
| Size | **all-in at 2x margin** on top of a 3x ETF ≈ **6x Nasdaq exposure** |
| Re-lever | daily, back to full target exposure |
| Stop | broker-side −20% disaster stop, re-armed and *verified* after every size change |

## The prediction, recorded before going live

`leverage_backtest.py` (2015-01 → 2026-08, free yfinance data, 2,915 sessions):

```
$10,000  ->  $8.59        CAGR -45.9%   Sharpe 0.17   MaxDD 100.0%

"Can it double?" - rolling windows, doubled vs halved:
   1 week :  0.03%  vs   0.38%
   1 month:  0.56%  vs   3.93%
   3 months:  4.77%  vs  16.14%
   1 year :   1.21%  vs  38.23%
```

Every leverage/stop combination tested loses money. Tighter stops only slow the bleed:

| leverage | stop | final | CAGR | maxDD |
|---|---|---|---|---|
| 1.0x | 10% | $6,259 | −4.0% | 72.1% |
| 1.5x | 20% | $325 | −25.8% | 98.0% |
| 2.0x | 20% | **$9** | −45.9% | 100.0% |

**Expected outcome: this account trends toward near-zero.** A blow-up is the finding,
and it gets reported plainly.

### The one genuinely interesting result

The **SQQQ side is what destroys the account.** The identical strategy that sits in
**cash** when bearish instead of flipping short returns **$338,210** over the same window.
But that still *underperforms simply buying and holding TQQQ* ($390,723) while carrying an
83.7% drawdown — so it is leveraged beta during the best Nasdaq run in history, not an edge.
Toggle `$ALLOW_SHORT_SIDE = $false` in `wild_trader.ps1` to run that variant instead.

## Isolation

This experiment is fully separate from the two real systems and must stay that way.

- Credentials use **`WILD_APCA_*`** names so they can never collide with the main bot's `APCA_API_*`.
- `wild_trader.ps1` **hard-aborts** if the account number is `PA3T3IPIRNWJ` (main dip-buyer)
  or `PA39L2W87E2A` (politician copybot), and if the base URL is not the paper endpoint.
- Own repo, own secrets, own cron jobs. Nothing here touches `intc-vwap-trader`.

## Files

| file | purpose |
|---|---|
| `wild_trader.ps1` | the strategy — signal, flip, re-lever, arm + verify stop |
| `wild_record.ps1` | appends the daily scorecard to `wild_pnl.csv` (read-only) |
| `leverage_backtest.py` | the pre-registered backtest above |
| `.github/workflows/wild-trader.yml` | one decision run, 3:45pm ET weekdays |

## Setup

1. New Alpaca **paper** account → API keys. Confirm its number is neither protected account.
2. `cp .env.example .env` and fill it in. `.env` is gitignored — never commit it.
3. Repo secrets: `WILD_APCA_API_KEY_ID`, `WILD_APCA_API_SECRET_KEY`, `WILD_APCA_API_BASE_URL`.
4. cron-job.org job → `POST .../actions/workflows/wild-trader.yml/dispatches`, body `{"ref":"master"}`,
   timezone America/New_York. GitHub's own cron has been observed 30–90 min late, repeatedly
   after the close, so the external trigger is the reliable one.
