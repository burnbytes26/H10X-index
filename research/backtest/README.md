# Backtest of the H10X index (3 years)

Simulation of the current H10X basket against Bitcoin, HBAR and SAUCE, using real market prices.
The full report is published at [h10xindex.xyz/backtest](https://h10xindex.xyz/backtest/).

## Files

| File | Contents |
|---|---|
| `prices-weekly.csv` | USD closes (Sundays plus the first and last day of each month), 20 Aug 2023 to 27 Sep 2026. BTC, ETH and HBAR from Binance; Hedera tokens from SaucerSwap (xSAUCE and HBARX from SaucerSwap's on-chain history) |
| `backtest.py` | The calculation: the index with the current target weights and monthly rebalancing, BTC, HBAR and SAUCE buy-and-hold, metrics and a cost and frequency sensitivity analysis |
| `results.json` | Output with a $10,000 starting capital |

## Run it

```bash
pip install pandas numpy
START_CAPITAL=10000 python3 backtest.py prices-weekly.csv results.json
```

This reproduces the portfolio series and metrics in `results.json`. To try another basket, pass its weights:
`WEIGHTS_JSON='{"HBAR": 50, "BTC": 50}'`. `WEEKLY=1` adds the index with weekly rebalancing.

## Rules

- Starting capital invested on 1 October 2023; data up to 27 September 2026.
- Index: the basket's current target weights (below). The vault holds HTS-WBTC and HTS-WETH; the backtest values them
  at the BTC and ETH market price. Rebalanced to target on the first day of each month. A token enters at the first
  rebalance after it has a price; until then its weight is shared among the others.
- A 0.3% cost on the traded amount at every rebalance (pool fee plus slippage). Vault issue/redeem fees (0.5% + 0.5%)
  are not included.
- Volatility and ratios from weekly returns (52 per year), risk-free rate 0%.

| HBAR | BTC | xSAUCE | ETH | DOVU | PACK | HBARX | GIB |
|---|---|---|---|---|---|---|---|
| 20% | 20% | 15% | 10% | 10% | 10% | 10% | 5% |

## Result ($10,000)

| Portfolio | Final value | CAGR | Volatility | Max. drawdown |
|---|---|---|---|---|
| H10X basket, monthly rebalancing | $43,253 | 63.2% | 79.2% | −64.5% |
| Bitcoin | $30,177 | 44.7% | 45.4% | −52.5% |
| HBAR | $18,907 | 23.7% | 102.1% | −80.6% |
| SAUCE | $8,375 | −5.8% | 119.3% | −94.6% |

The index peaked at $90,679 on 21 September 2025; its maximum drawdown ran from there to 30 June 2026.

Sensitivity of the index's final value: $42,400 with a 1% cost per rebalance, $41,211 with 2%, $41,238 with quarterly
rebalancing and $27,661 with yearly rebalancing.

Hypothetical results based on historical prices, with today's basket applied to the past. Past performance does not
predict future returns.
