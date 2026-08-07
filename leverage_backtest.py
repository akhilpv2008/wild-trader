"""
GO WILD - backtest for the MAX LEVERAGE ALL-IN strategy, before a dollar is risked.

The strategy under test:
  - Trend filter on QQQ: close > 20-day SMA  -> hold TQQQ (3x long)
                         close <= 20-day SMA -> hold SQQQ (3x short)
  - ALL-IN, every day, using full margin buying power (2x) -> ~6x Nasdaq exposure
  - Re-lever daily back to full buying power (this is what the online "double it" posts do,
    and it is also what makes leverage decay bite)
  - Broker-side disaster stop on the position

Data: yfinance (free, no API key) so this NEVER touches the main bot's Alpaca credentials.

Purpose: record an honest prediction BEFORE going live, so the live result can be scored
against it. Per the project's testing discipline, an untested strategy is not deployed -
not even a deliberately reckless one.
"""
import sys
import numpy as np
import pandas as pd
import yfinance as yf

START = "2015-01-01"
LEVERAGE = 2.0          # margin multiplier on top of the 3x ETF -> ~6x underlying
STOP_PCT = 0.20         # disaster stop on the ETF position (-20%)
START_EQUITY = 10_000.0


def load():
    """Daily OHLC for the signal (QQQ) and the two 3x vehicles."""
    df = yf.download(["QQQ", "TQQQ", "SQQQ"], start=START, auto_adjust=True,
                     progress=False, group_by="column")
    close = df["Close"].dropna()
    low = df["Low"].dropna()
    high = df["High"].dropna()
    idx = close.index.intersection(low.index).intersection(high.index)
    return close.loc[idx], low.loc[idx], high.loc[idx]


def run(close, low, high, leverage=LEVERAGE, stop_pct=STOP_PCT, allow_short_side=True):
    """
    Simulate daily all-in, fully re-levered.

    Equity math per day:
      exposure   = equity * leverage          (dollars in the ETF)
      etf_return = today's close/close move of the held ETF, or the stop if it triggers intraday
      pnl        = exposure * etf_return
    A stop hit is modelled off the day's LOW (long ETF), which is the honest worst case.
    Equity is floored at zero - a wipeout is a wipeout.
    """
    qqq = close["QQQ"]
    sma20 = qqq.rolling(20).mean()

    equity = START_EQUITY
    curve, dates = [], []
    peak, max_dd = START_EQUITY, 0.0
    wipeout_date = None
    stops_hit = 0
    days_traded = 0

    for i in range(20, len(close) - 1):
        # Decide at today's close, hold tomorrow.
        bullish = qqq.iloc[i] > sma20.iloc[i]
        sym = "TQQQ" if bullish else ("SQQQ" if allow_short_side else None)
        d = close.index[i + 1]

        if sym is None or equity <= 0:
            curve.append(max(equity, 0.0))
            dates.append(d)
            continue

        entry = close[sym].iloc[i]
        nxt_close = close[sym].iloc[i + 1]
        nxt_low = low[sym].iloc[i + 1]

        stop_px = entry * (1 - stop_pct)
        if nxt_low <= stop_px:
            ret = (stop_px / entry) - 1.0      # stopped out intraday
            stops_hit += 1
        else:
            ret = (nxt_close / entry) - 1.0

        equity = equity + (equity * leverage) * ret
        days_traded += 1

        if equity <= 0:
            equity = 0.0
            if wipeout_date is None:
                wipeout_date = d

        peak = max(peak, equity)
        if peak > 0:
            max_dd = max(max_dd, (peak - equity) / peak)

        curve.append(equity)
        dates.append(d)

    s = pd.Series(curve, index=pd.DatetimeIndex(dates))
    rets = s.pct_change().replace([np.inf, -np.inf], np.nan).dropna()
    sharpe = (rets.mean() / rets.std() * np.sqrt(252)) if len(rets) > 1 and rets.std() > 0 else 0.0
    years = max((s.index[-1] - s.index[0]).days / 365.25, 0.01)
    cagr = ((s.iloc[-1] / START_EQUITY) ** (1 / years) - 1) * 100 if s.iloc[-1] > 0 else -100.0

    return {
        "curve": s, "final": s.iloc[-1], "max_dd": max_dd * 100, "sharpe": sharpe,
        "cagr": cagr, "wipeout": wipeout_date, "stops": stops_hit, "days": days_traded,
    }


def doubling_odds(curve_series, horizon_days):
    """
    Over every rolling window of `horizon_days`, how often did equity DOUBLE
    vs how often did it get CUT IN HALF? This is the actual question being tested:
    the online claim is 'double it fast', so measure both tails at the same horizon.
    """
    v = curve_series.values
    n = len(v)
    doubles = halves = total = 0
    for i in range(n - horizon_days):
        if v[i] <= 0:
            continue
        r = v[i + horizon_days] / v[i]
        total += 1
        if r >= 2.0:
            doubles += 1
        if r <= 0.5:
            halves += 1
    if total == 0:
        return 0.0, 0.0, 0
    return doubles / total * 100, halves / total * 100, total


def main():
    print("Downloading QQQ / TQQQ / SQQQ daily bars (yfinance, no API key)...")
    close, low, high = load()
    print(f"History: {close.index[0].date()} -> {close.index[-1].date()}  ({len(close)} sessions)\n")

    print("=" * 78)
    print("  MAX LEVERAGE ALL-IN  (QQQ>20SMA -> TQQQ else SQQQ, 2x margin, re-levered daily)")
    print("=" * 78)

    base = run(close, low, high)
    print(f"  Start ${START_EQUITY:,.0f} -> End ${base['final']:,.2f}")
    print(f"  CAGR {base['cagr']:.1f}%   Sharpe {base['sharpe']:.2f}   MaxDD {base['max_dd']:.1f}%")
    print(f"  Disaster stops hit: {base['stops']} over {base['days']} trading days")
    print(f"  WIPEOUT: {base['wipeout'].date() if base['wipeout'] is not None else 'no (survived)'}")

    print("\n  --- 'Can it double?' rolling-window odds (the actual claim being tested) ---")
    for label, days in [("1 week", 5), ("1 month", 21), ("3 months", 63), ("1 year", 252)]:
        up, down, n = doubling_odds(base["curve"], days)
        print(f"   {label:>9}: doubled {up:5.2f}% of windows | halved {down:5.2f}% | n={n}")

    print("\n" + "=" * 78)
    print("  SENSITIVITY - is any leverage/stop setting survivable?")
    print("=" * 78)
    print(f"  {'leverage':>9} {'stop':>6} {'final $':>14} {'CAGR%':>8} {'maxDD%':>8}  wipeout")
    for lev in [1.0, 1.5, 2.0]:
        for stop in [0.10, 0.20, 0.35]:
            r = run(close, low, high, leverage=lev, stop_pct=stop)
            w = r["wipeout"].date() if r["wipeout"] is not None else "-"
            print(f"  {lev:>9.1f} {stop*100:>5.0f}% {r['final']:>14,.0f} {r['cagr']:>8.1f} "
                  f"{r['max_dd']:>8.1f}  {w}")

    print("\n  --- long-only variant (sit in CASH instead of shorting via SQQQ) ---")
    lo = run(close, low, high, allow_short_side=False)
    w = lo["wipeout"].date() if lo["wipeout"] is not None else "no"
    print(f"  final ${lo['final']:,.0f}  CAGR {lo['cagr']:.1f}%  maxDD {lo['max_dd']:.1f}%  wipeout: {w}")

    print("\n  --- benchmarks over the same window ---")
    for sym in ["QQQ", "TQQQ"]:
        c = close[sym]
        mult = c.iloc[-1] / c.iloc[20]
        dd = ((c.cummax() - c) / c.cummax()).max() * 100
        print(f"  buy & hold {sym:<5} ${START_EQUITY*mult:>12,.0f}   maxDD {dd:.1f}%")


if __name__ == "__main__":
    sys.exit(main())
