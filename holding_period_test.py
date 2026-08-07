"""
GO WILD: does the return come from OVERNIGHT gaps or from INTRADAY moves?

Splits every day's move into its two halves and runs the same 20SMA TQQQ/SQQQ signal
three ways, so "hold overnight vs day-trade it" is answered with data, not opinion:

  CONTINUOUS  hold through everything  (close[t] -> close[t+1])   trades only on signal flips
  DAYTRADE    flat overnight           (open[t+1] -> close[t+1])  round-trip EVERY day
  OVERNIGHT   flat during the day      (close[t] -> open[t+1])    round-trip EVERY day

Costs matter enormously here: CONTINUOUS pays a spread only when the signal flips, while the
other two pay one every single session. The project's measured round-trip cost is ~0.10%.

Also breaks out WEEKEND gaps (Fri close -> Mon open) from ordinary overnights, since that is
the specific risk being carried this Friday.
"""
import numpy as np
import pandas as pd
import yfinance as yf

START = "2015-01-01"
LEVERAGE = 2.0
ROUND_TRIP_COST = 0.0010     # 0.10%, the figure measured in the main project
START_EQUITY = 10_000.0


def load():
    df = yf.download(["QQQ", "TQQQ", "SQQQ"], start=START, auto_adjust=True,
                     progress=False, group_by="column")
    return df["Close"].dropna(), df["Open"].dropna()


def simulate(close, opn, mode, leverage=LEVERAGE, cost=ROUND_TRIP_COST):
    qqq = close["QQQ"]
    sma = qqq.rolling(20).mean()
    equity = START_EQUITY
    curve, dates = [], []
    peak, max_dd = START_EQUITY, 0.0
    prev_sym = None
    trades = 0

    for i in range(20, len(close) - 1):
        sym = "TQQQ" if qqq.iloc[i] > sma.iloc[i] else "SQQQ"

        if mode == "continuous":
            r = close[sym].iloc[i + 1] / close[sym].iloc[i] - 1
            # pay only when the vehicle actually changes
            c = cost if (prev_sym is not None and sym != prev_sym) else 0.0
        elif mode == "daytrade":
            r = close[sym].iloc[i + 1] / opn[sym].iloc[i + 1] - 1
            c = cost                      # in and out every session
        elif mode == "overnight":
            r = opn[sym].iloc[i + 1] / close[sym].iloc[i] - 1
            c = cost
        else:
            raise ValueError(mode)

        equity += equity * leverage * r
        equity -= equity * c * leverage    # cost scales with the levered notional
        equity = max(equity, 0.0)
        if c > 0:
            trades += 1
        prev_sym = sym

        peak = max(peak, equity)
        if peak > 0:
            max_dd = max(max_dd, (peak - equity) / peak)
        curve.append(equity)
        dates.append(close.index[i + 1])

    s = pd.Series(curve, index=pd.DatetimeIndex(dates))
    years = (s.index[-1] - s.index[0]).days / 365.25
    cagr = ((s.iloc[-1] / START_EQUITY) ** (1 / years) - 1) * 100 if s.iloc[-1] > 0 else -100.0
    return {"final": s.iloc[-1], "cagr": cagr, "dd": max_dd * 100, "trades": trades, "curve": s}


def edge_table(close, opn):
    """Raw per-session edge of each half, before leverage and before costs."""
    qqq = close["QQQ"]
    sma = qqq.rolling(20).mean()
    rows = []
    for i in range(20, len(close) - 1):
        sym = "TQQQ" if qqq.iloc[i] > sma.iloc[i] else "SQQQ"
        on = opn[sym].iloc[i + 1] / close[sym].iloc[i] - 1
        idy = close[sym].iloc[i + 1] / opn[sym].iloc[i + 1] - 1
        d0, d1 = close.index[i], close.index[i + 1]
        rows.append({"sym": sym, "overnight": on, "intraday": idy,
                     "weekend": (d1 - d0).days >= 3})
    return pd.DataFrame(rows)


def main():
    print("Downloading QQQ / TQQQ / SQQQ...")
    close, opn = load()
    print(f"{close.index[0].date()} -> {close.index[-1].date()}  ({len(close)} sessions)\n")

    print("=" * 76)
    print("  WHERE DOES THE MOVE COME FROM?  (raw per-session, no leverage, no costs)")
    print("=" * 76)
    df = edge_table(close, opn)
    print(f"  {'segment':<22} {'avg/session':>12} {'win rate':>10} {'std':>8}  n")
    for label, col in [("OVERNIGHT (gap)", "overnight"), ("INTRADAY (open->close)", "intraday")]:
        v = df[col]
        print(f"  {label:<22} {v.mean()*100:>11.4f}% {(v>0).mean()*100:>9.1f}% {v.std()*100:>7.2f}%  {len(v)}")

    print(f"\n  round-trip cost for comparison: {ROUND_TRIP_COST*100:.4f}% per trade")

    print("\n  --- weekend gaps (Fri->Mon) vs ordinary overnight ---")
    for label, sub in [("weekend", df[df.weekend]), ("weeknight", df[~df.weekend])]:
        v = sub["overnight"]
        print(f"  {label:<12} avg {v.mean()*100:>8.4f}%  win {(v>0).mean()*100:>5.1f}%  "
              f"std {v.std()*100:>5.2f}%  worst {v.min()*100:>7.2f}%  n={len(v)}")

    print("\n" + "=" * 76)
    print(f"  SAME SIGNAL, THREE HOLDING PERIODS  ({LEVERAGE}x leverage, {ROUND_TRIP_COST*100:.2f}% round trip)")
    print("=" * 76)
    print(f"  {'mode':<12} {'final $':>13} {'CAGR%':>9} {'maxDD%':>8} {'trades':>8}")
    res = {}
    for mode in ["continuous", "daytrade", "overnight"]:
        r = simulate(close, opn, mode)
        res[mode] = r
        print(f"  {mode:<12} {r['final']:>13,.2f} {r['cagr']:>9.1f} {r['dd']:>8.1f} {r['trades']:>8}")

    print("\n  --- same three with ZERO costs (isolates the signal from the friction) ---")
    print(f"  {'mode':<12} {'final $':>13} {'CAGR%':>9}")
    for mode in ["continuous", "daytrade", "overnight"]:
        r = simulate(close, opn, mode, cost=0.0)
        print(f"  {mode:<12} {r['final']:>13,.2f} {r['cagr']:>9.1f}")

    print("\n  --- unlevered (1.0x), real costs: is anything salvageable? ---")
    print(f"  {'mode':<12} {'final $':>13} {'CAGR%':>9} {'maxDD%':>8}")
    for mode in ["continuous", "daytrade", "overnight"]:
        r = simulate(close, opn, mode, leverage=1.0)
        print(f"  {mode:<12} {r['final']:>13,.2f} {r['cagr']:>9.1f} {r['dd']:>8.1f}")


if __name__ == "__main__":
    main()
