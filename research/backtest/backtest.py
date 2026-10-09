"""Backtest del índice H10X frente a BTC, HBAR y HBAR+SAUCE (50/50).

Entrada: backtest-prices.json (scripts/tools/backtest-data.js). Salida: results.json con series diarias, rendimientos
mensuales y anuales, métricas y metodología.

Reglas (las mismas para todas las carteras con varios activos):
  - Capital inicial 1.000 $ el día 1 del mes de inicio: 35 meses completos + el mes en curso (3 años).
  - Índice: pesos objetivo de config/index.json. Rebalanceo mensual (día 1) a los pesos objetivo, repartiendo el peso
    de los tokens que aún no existían entre los que sí (proporcionalmente). Un token entra en el primer rebalanceo
    después de tener precio.
  - HBAR+SAUCE: 50/50 con el mismo rebalanceo mensual.
  - Coste de rebalanceo: COST_BPS sobre lo negociado (comisión del pool + deslizamiento).
  - BTC y HBAR: comprar y mantener.
  - No se incluyen las comisiones de entrada/salida de la bóveda (0,5 % + 0,5 %) ni las de exchanges.
"""
import json
import sys
from datetime import datetime, timezone

import numpy as np
import pandas as pd

SRC = sys.argv[1] if len(sys.argv) > 1 else "backtest-prices.json"
OUT = sys.argv[2] if len(sys.argv) > 2 else "results.json"
import os
COST_BPS = int(os.environ.get("COST_BPS", "30"))
REB_MONTHS = int(os.environ.get("REB_MONTHS", "1"))  # cada cuántos meses se rebalancea
START_CAPITAL = float(os.environ.get("START_CAPITAL", "1000"))
WEEKLY = os.environ.get("WEEKLY", "0") == "1"  # añade el índice con rebalanceo semanal (cada domingo)

WEIGHTS = {"HBAR": 20, "BTC": 15, "SAUCE": 10, "ETH": 10, "BONZO": 10, "DOVU": 10, "GIB": 10, "PACK": 5, "DAVINCI": 5, "GRELF": 5}

text = open(SRC).read()
first_exact = {}
if text.lstrip().startswith("{"):
    # JSON diario de backtest-data.js
    raw = json.loads(text)
    SAMPLING = "daily"
    series = {}
    for k, rows in raw["series"].items():
        series[k] = pd.Series({pd.Timestamp(t, unit="s"): float(p) for t, p in rows}).sort_index()
    prices = pd.DataFrame(series).sort_index()
    prices = prices.reindex(pd.date_range(prices.index.min(), prices.index.max(), freq="D"))
else:
    # CSV reducido: cierres de los domingos y del primer y último día de cada mes
    SAMPLING = "weekly"
    raw = {"sources": {}, "generatedAt": None}
    lines = [l for l in text.splitlines() if l.strip()]
    for l in lines:
        if l.startswith("# fuentes:"):
            raw["sources"] = dict(x.split("=", 1) for x in l.split(":", 1)[1].split())
        if l.startswith("# primer precio:"):
            first_exact = {k: v for k, v in (x.split("=", 1) for x in l.split(":", 1)[1].split()) if v != "-"}
    import io
    prices = pd.read_csv(io.StringIO("\n".join(l for l in lines if not l.startswith("#"))), parse_dates=["date"]).set_index("date").sort_index()
    prices = prices.apply(pd.to_numeric, errors="coerce")
first_valid = {k: prices[k].first_valid_index() for k in prices.columns}
prices = prices.ffill()  # días sin operaciones: último cierre

end = prices.index.max()
start = (end.to_period("M") - 35).to_timestamp()  # día 1 del mes, 3 años: 35 meses completos + el mes en curso
if start < prices.index.min():
    start = prices.index.min().to_period("M").to_timestamp() + pd.offsets.MonthBegin(1)
prices = prices.loc[start:end]
for need in ["BTC", "HBAR", "SAUCE"]:
    if pd.isna(prices[need].iloc[0]):
        raise SystemExit(f"{need} sin precio al inicio ({start.date()})")


def rebalanced(weights, cost_bps=None, reb_months=None):
    """NAV de una cartera rebalanceada a `weights` (repartiendo los que aún no existen).

    reb_months: 1, 3, 12… = cada N meses (el día 1); "W" = cada semana (cada domingo)."""
    cost_bps = COST_BPS if cost_bps is None else cost_bps
    reb_months = REB_MONTHS if reb_months is None else reb_months
    keys = list(weights)
    units = pd.Series(0.0, index=keys)
    nav = []
    value = START_CAPITAL
    traded_total = 0.0
    log = []
    month = None
    first = True
    for d, row in prices[keys].iterrows():
        px = row
        if units.sum() > 0:
            value = float((units * px.fillna(0)).sum())
        if reb_months == "W":
            due = first or d.dayofweek == 6
        else:
            due = d.to_period("M") != month and (month is None or (d.to_period("M") - start.to_period("M")).n % reb_months == 0)
        if due:
            first = False
            month = d.to_period("M")
            avail = [k for k in keys if not pd.isna(px[k]) and first_valid.get(k) is not None and first_valid[k] <= d]
            wsum = sum(weights[k] for k in avail)
            target_val = pd.Series({k: (value * weights[k] / wsum if k in avail else 0.0) for k in keys})
            current_val = units * px.fillna(0)
            traded = float((target_val - current_val).abs().sum() / 2) if units.sum() > 0 else 0.0
            cost = traded * cost_bps / 10_000
            value -= cost
            traded_total += traded
            target_val = target_val * (value / target_val.sum())
            units = pd.Series({k: (target_val[k] / px[k] if k in avail else 0.0) for k in keys})
            log.append({"date": d.strftime("%Y-%m-%d"), "components": avail, "traded": round(traded, 2), "cost": round(cost, 2)})
        nav.append(value if units.sum() == 0 else float((units * px.fillna(0)).sum()))
    return pd.Series(nav, index=prices.index), log, traded_total


def hold(key):
    return prices[key] / prices[key].iloc[0] * START_CAPITAL


idx, idx_log, idx_traded = rebalanced(WEIGHTS)
hs, hs_log, hs_traded = rebalanced({"HBAR": 50, "SAUCE": 50})
cols = {"H10X": idx}
if WEEKLY:
    idx_w, idx_w_log, idx_w_traded = rebalanced(WEIGHTS, reb_months="W")
    hs_w, hs_w_log, hs_w_traded = rebalanced({"HBAR": 50, "SAUCE": 50}, reb_months="W")
    cols["H10X_W"] = idx_w
navs = pd.DataFrame({**cols, "BTC": hold("BTC"), "HBAR": hold("HBAR"), "HBAR_SAUCE": hs})


def period_returns(s):
    """Rendimientos para volatilidad y ratios: diarios, o semanales (domingo a domingo) con el CSV reducido."""
    if SAMPLING == "daily":
        return s.pct_change().dropna(), 365
    w = s[s.index.dayofweek == 6]
    return w.pct_change().dropna(), 52


def stats(s):
    daily, per_year = period_returns(s)
    yrs = (s.index[-1] - s.index[0]).days / 365.25
    total = s.iloc[-1] / s.iloc[0] - 1
    cagr = (s.iloc[-1] / s.iloc[0]) ** (1 / yrs) - 1
    vol = daily.std() * np.sqrt(per_year)
    dd = s / s.cummax() - 1
    mdd = dd.min()
    trough = dd.idxmin()
    peak = s.loc[:trough].idxmax()
    sharpe = daily.mean() * per_year / vol if vol > 0 else None
    downside = daily[daily < 0].std() * np.sqrt(per_year)
    sortino = daily.mean() * per_year / downside if downside > 0 else None
    me = s.resample("ME").last()
    monthly = me.pct_change()
    monthly.iloc[0] = me.iloc[0] / s.iloc[0] - 1
    return {
        "final": s.iloc[-1],
        "totalReturn": total,
        "cagr": cagr,
        "volatility": vol,
        "maxDrawdown": mdd,
        "maxDrawdownPeak": peak.strftime("%Y-%m-%d"),
        "maxDrawdownTrough": trough.strftime("%Y-%m-%d"),
        "sharpe": sharpe,
        "sortino": sortino,
        "calmar": cagr / abs(mdd) if mdd < 0 else None,
        "bestMonth": monthly.max(),
        "bestMonthAt": monthly.idxmax().strftime("%Y-%m"),
        "worstMonth": monthly.min(),
        "worstMonthAt": monthly.idxmin().strftime("%Y-%m"),
        "positiveMonths": float((monthly > 0).mean()),
    }


def monthly_returns(s):
    me = s.resample("ME").last()
    r = me.pct_change()
    r.iloc[0] = me.iloc[0] / s.iloc[0] - 1
    return {d.strftime("%Y-%m"): float(v) for d, v in r.items()}


def yearly_returns(s):
    """Tramos de 12 meses encadenados por cierres desde el inicio (el último, parcial hasta hoy)."""
    out = []
    prev = s.index[0]
    while prev < s.index[-1]:
        b = min(prev + pd.DateOffset(months=12), s.index[-1])
        out.append({"from": prev.strftime("%Y-%m-%d"), "to": b.strftime("%Y-%m-%d"), "ret": float(s.loc[b] / s.loc[prev] - 1)})
        prev = b
    return out


sens = []
for label, cb, rm in [("base", COST_BPS, 1), ("cost100", 100, 1), ("cost200", 200, 1), ("quarterly", COST_BPS, 3), ("yearly", COST_BPS, 12)]:
    nv, _, _ = rebalanced(WEIGHTS, cb, rm)
    st = stats(nv)
    sens.append({"id": label, "costBps": cb, "months": rm, "final": float(st["final"]), "cagr": float(st["cagr"]), "maxDrawdown": float(st["maxDrawdown"])})

sens_matrix = None
rebal_compare = None
if WEEKLY:
    # matriz frecuencia × coste (solo el índice)
    freqs, costs = ["W", 1, 3, 12], [COST_BPS, 100, 200]
    cells = []
    for f in freqs:
        row = []
        for cb in costs:
            nv, lg, tr = rebalanced(WEIGHTS, cb, f)
            st = stats(nv)
            row.append({"final": float(st["final"]), "cagr": float(st["cagr"]), "maxDrawdown": float(st["maxDrawdown"]), "costs": float(sum(x["cost"] for x in lg))})
        cells.append(row)
    sens_matrix = {"freqs": [str(f) for f in freqs], "costs": costs, "cells": cells}

    def summ(nv, lg, tr):
        st = stats(nv)
        return {
            "final": float(st["final"]), "totalReturn": float(st["totalReturn"]), "cagr": float(st["cagr"]),
            "volatility": float(st["volatility"]), "maxDrawdown": float(st["maxDrawdown"]), "sharpe": float(st["sharpe"]),
            "rebalances": len(lg) - 1,  # sin contar la compra inicial
            "traded": float(tr), "costs": float(sum(x["cost"] for x in lg)),
        }

    rebal_compare = {
        "H10X": {"monthly": summ(idx, idx_log, idx_traded), "weekly": summ(idx_w, idx_w_log, idx_w_traded)},
        "HBAR_SAUCE": {"monthly": summ(hs, hs_log, hs_traded), "weekly": summ(hs_w, hs_w_log, hs_w_traded)},
        # sin ningún coste: separa el efecto de los costes del efecto del calendario
        "noCost": {"monthly": float(rebalanced(WEIGHTS, 0, 1)[0].iloc[-1]), "weekly": float(rebalanced(WEIGHTS, 0, "W")[0].iloc[-1])},
    }

corr = (navs.pct_change() if SAMPLING == "daily" else navs[navs.index.dayofweek == 6].pct_change()).dropna().corr()
res = {
    "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "dataGeneratedAt": raw.get("generatedAt"),
    "start": start.strftime("%Y-%m-%d"),
    "end": end.strftime("%Y-%m-%d"),
    "partialMonth": end.strftime("%Y-%m") if end.day < end.days_in_month else None,
    "startCapital": START_CAPITAL,
    "costBps": COST_BPS,
    "weights": WEIGHTS,
    "sources": raw.get("sources", {}),
    "sampling": SAMPLING,
    "firstPrice": {k: (first_exact.get(k) or (v.strftime("%Y-%m-%d") if v is not None else None)) for k, v in first_valid.items()},
    "indexRebalances": idx_log,
    "indexTurnover": idx_traded,
    "dates": [d.strftime("%Y-%m-%d") for d in navs.index],
    "nav": {k: [round(float(x), 4) for x in navs[k]] for k in navs.columns},
    "drawdown": {k: [round(float(x), 5) for x in (navs[k] / navs[k].cummax() - 1)] for k in navs.columns},
    "monthly": {k: monthly_returns(navs[k]) for k in navs.columns},
    "yearly": {k: yearly_returns(navs[k]) for k in navs.columns},
    "stats": {k: {kk: (float(vv) if isinstance(vv, (int, float, np.floating)) and vv is not None else vv) for kk, vv in stats(navs[k]).items()} for k in navs.columns},
    "sensitivity": sens,
    "sensMatrix": sens_matrix,
    "rebalCompare": rebal_compare,
    "correlation": {a: {b: round(float(corr.loc[a, b]), 3) for b in navs.columns} for a in navs.columns},
    "componentsMonthly": {k: monthly_returns(prices[k].dropna()) for k in WEIGHTS if k in prices and prices[k].notna().any()},
}
json.dump(res, open(OUT, "w"), separators=(",", ":"))
print(f"{res['start']} → {res['end']} · {len(res['dates'])} días")
for k, s in res["stats"].items():
    print(f"{k:11s} final {s['final']:9.2f} $ · total {s['totalReturn']*100:7.1f} % · CAGR {s['cagr']*100:6.1f} % · vol {s['volatility']*100:5.1f} % · maxDD {s['maxDrawdown']*100:6.1f} % · Sharpe {s['sharpe']:.2f} · meses+ {s['positiveMonths']*100:.0f} %")
print("entradas en el índice:", {k: v for k, v in res["firstPrice"].items() if k in WEIGHTS})
