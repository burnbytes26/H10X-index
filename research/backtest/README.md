# Backtest of the H10X index (3 years)

Simulation of the H10X basket against Bitcoin, HBAR and a 50/50 HBAR + SAUCE portfolio, using real market prices.
The full report is published at [h10xindex.xyz/backtest](https://h10xindex.xyz/backtest/).

## Files

| File | Contents |
|---|---|
| `prices-weekly.csv` | USD closes (Sundays plus the first and last day of each month), 20 Aug 2023 to 27 Sep 2026. BTC, ETH and HBAR from Binance; Hedera tokens from SaucerSwap |
| `backtest.py` | The calculation: index with monthly and weekly rebalancing, BTC and HBAR buy-and-hold, HBAR + SAUCE 50/50, metrics |
| `results.json` | Output with a $10,000 starting capital |

## Run it

```bash
pip install pandas numpy
START_CAPITAL=10000 WEEKLY=1 python3 backtest.py prices-weekly.csv results.json
```

This reproduces the portfolio series and metrics in `results.json`.

## Rules

- Starting capital invested on 1 October 2023; data up to 27 September 2026.
- Index: current target weights. Rebalanced to target on the first day of each month (or every Sunday for the weekly
  variant). A token enters at the first rebalance after it has a price; until then its weight is shared among the others.
- A 0.3% cost on the traded amount at every rebalance (pool fee plus slippage). Vault issue/redeem fees (0.5% + 0.5%)
  are not included.
- Volatility and ratios from weekly returns (52 per year), risk-free rate 0%.

## Result ($10,000)

| Portfolio | Final value | Max. drawdown |
|---|---|---|
| H10X basket, monthly rebalancing | $47,530 | −66% |
| Bitcoin | $30,177 | −53% |
| HBAR | $18,907 | −81% |
| HBAR + SAUCE 50/50 | $15,929 | −86% |

Hypothetical results based on historical prices. Past performance does not predict future returns.
