"""
昼の自動準備シート生成スクリプト。

仕様: jq/fullmarket/specs/daily_prep_sheet_spec.md
監視27銘柄（watchlist27.csv）の当日5分足をyfinanceで取得し、前引け値・前場安値・
前場高値・実測ATR14・MACD(12,26,9)ヒスト関連値・サイジング(SL/TP/株数等)を計算して
data/daily_prep.json に出力する。

MACD/ATRの計算規約は jq/fullmarket/phoenix_common.py の add_indicators と同一
(このスクリプトはActions実行のためphoenix_commonをimportできず、自己完結で再実装):
  - EMA12: alpha=2/13, EMA26: alpha=2/27 (adjust=False, 日をまたいで連続計算)
  - シグナル: MACDのEMA9 (alpha=2/10, adjust=False)
  - ATR14: TRの単純移動平均(SMA14)。ema_daily_reset=False相当のため日をまたいで
    連続計算する(1日分だけでは13行のウォームアップが足りないため、60日窓で取得)

GitHub Actions (.github/workflows/daily_prep.yml) から平日11:35/11:50/12:05 JSTに
3回呼ばれる想定(各回同処理・上書き)。ローカル検証用に --asof / --output を用意。

使い方:
  python -X utf8 daily_prep.py                          # 本番(今日のJST日付・data/daily_prep.json)
  python -X utf8 daily_prep.py --asof 2026-07-31         # 過去日付で検証(yfinance60日窓内)
  python -X utf8 daily_prep.py --asof 2026-07-31 --output /tmp/x.json
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd
import yfinance as yf

JST = ZoneInfo("Asia/Tokyo")

WATCHLIST_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "watchlist27.csv")
DEFAULT_OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "daily_prep.json")

MORNING_START_MIN = 9 * 60          # 09:00
MORNING_END_MIN = 11 * 60 + 30      # 11:30
MOMENTUM_TIMES = (11 * 60 + 20, 11 * 60 + 25, 11 * 60 + 30)  # 11:20,11:25,11:30
PM_START_MIN = 12 * 60 + 35         # 12:35（後場ハイの判定基準。トレール引上げ判定UI用）

ATR_PERIOD = 14
SL_PCT = 0.003
TP_MULT = 1.06
TRAIL_MULT = 1.015
RISK_CAP_JPY = 77_000
NOTIONAL_CAP_JPY = 1_027_000

FETCH_PERIOD = "60d"   # MACD/ATRのウォームアップ用(yfinance 5分足の取得上限)
FETCH_INTERVAL = "5m"


def load_watchlist(path: str = WATCHLIST_PATH) -> list[dict]:
    rows = []
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append({
                "code4": r["code4"].strip(),
                "name": r["name"].strip(),
                "cls": r["cls"].strip(),  # 'green' | 'yellow'
                "sector": r["sector"].strip(),
                "financial": r["financial"].strip().lower() == "true",
                "no_market_order": r["no_market_order"].strip().lower() == "true",
            })
    return rows


def fetch_bars(tickers: list[str]) -> dict[str, pd.DataFrame]:
    """yf.downloadで全銘柄の5分足をまとめて取得しticker->DataFrameに正規化する。
    列: datetime(JST naive), open, high, low, close, volume
    """
    raw = yf.download(
        tickers=tickers,
        period=FETCH_PERIOD,
        interval=FETCH_INTERVAL,
        group_by="ticker",
        auto_adjust=True,
        progress=False,
        threads=True,
    )

    out: dict[str, pd.DataFrame] = {}
    if raw is None or raw.empty:
        return out

    if isinstance(raw.columns, pd.MultiIndex):
        top_level = set(raw.columns.get_level_values(0))
        for t in tickers:
            if t not in top_level:
                continue
            sub = raw[t].copy()
            sub = sub.dropna(how="all")
            if sub.empty:
                continue
            out[t] = _normalize_one(sub)
    else:
        if len(tickers) == 1:
            sub = raw.dropna(how="all")
            if not sub.empty:
                out[tickers[0]] = _normalize_one(sub)
    return out


def _normalize_one(sub: pd.DataFrame) -> pd.DataFrame:
    sub = sub.reset_index()
    dt_col = "Datetime" if "Datetime" in sub.columns else sub.columns[0]
    sub = sub.rename(columns={dt_col: "datetime"})
    if sub["datetime"].dt.tz is not None:
        sub["datetime"] = sub["datetime"].dt.tz_convert("Asia/Tokyo").dt.tz_localize(None)
    sub = sub.rename(columns={
        "Open": "open", "High": "high", "Low": "low", "Close": "close", "Volume": "volume",
    })
    cols = ["datetime", "open", "high", "low", "close", "volume"]
    sub = sub[cols].dropna(subset=["open", "high", "low", "close"])
    sub = sub.sort_values("datetime").reset_index(drop=True)
    return sub


def add_indicators(df: pd.DataFrame) -> pd.DataFrame:
    """phoenix_common.add_indicators と同一規約(ema_daily_reset=False, atr_method='sma')
    をpandasで再実装。日をまたいで連続計算(ウォームアップのため60日窓で取得)。
    """
    df = df.sort_values("datetime").reset_index(drop=True)
    df["date"] = df["datetime"].dt.date
    df["time_min"] = df["datetime"].dt.hour * 60 + df["datetime"].dt.minute

    df["ema12"] = df["close"].ewm(alpha=2.0 / 13.0, adjust=False).mean()
    df["ema26"] = df["close"].ewm(alpha=2.0 / 27.0, adjust=False).mean()
    df["macd"] = df["ema12"] - df["ema26"]
    df["signal"] = df["macd"].ewm(alpha=2.0 / 10.0, adjust=False).mean()
    df["hist"] = df["macd"] - df["signal"]

    prev_close = df["close"].shift(1)
    tr = pd.concat([
        (df["high"] - df["low"]).abs(),
        (df["high"] - prev_close).abs(),
        (df["low"] - prev_close).abs(),
    ], axis=1).max(axis=1)
    df["tr"] = tr
    df["atr14"] = df["tr"].rolling(window=ATR_PERIOD, min_periods=ATR_PERIOD).mean()
    return df


def sign_str(x: float | None) -> str | None:
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return None
    if x > 0:
        return "+"
    if x < 0:
        return "-"
    return "0"


def compute_sizing(zenba_close: float, zenba_low: float, atr14: float) -> dict:
    floor_buf = SL_PCT * zenba_close
    atr_val = 0.0 if (atr14 is None or (isinstance(atr14, float) and math.isnan(atr14))) else atr14
    buf = max(floor_buf, atr_val)
    sl = zenba_low - buf
    risk_per_share = zenba_close - sl
    if risk_per_share <= 0:
        return {"shares": 0, "sl": sl, "tp": None, "trail_trigger": None,
                "risk_jpy": 0, "notional_jpy": 0, "tradable": False}

    shares_by_risk = math.floor(RISK_CAP_JPY / risk_per_share / 100) * 100
    shares_by_notional = math.floor(NOTIONAL_CAP_JPY / zenba_close / 100) * 100
    shares = min(shares_by_risk, shares_by_notional)
    if shares <= 0:
        return {"shares": 0, "sl": sl, "tp": zenba_close * TP_MULT,
                "trail_trigger": zenba_close * TRAIL_MULT,
                "risk_jpy": 0, "notional_jpy": 0, "tradable": False}

    tp = zenba_close * TP_MULT
    trail_trigger = zenba_close * TRAIL_MULT
    risk_jpy = risk_per_share * shares
    notional_jpy = shares * zenba_close
    return {
        "shares": shares, "sl": sl, "tp": tp, "trail_trigger": trail_trigger,
        "risk_jpy": risk_jpy, "notional_jpy": notional_jpy, "tradable": True,
    }


def process_code(entry: dict, df: pd.DataFrame, target_date) -> dict | None:
    """1銘柄分の当日値を計算。当日データが1本も無ければNoneを返す。"""
    day_df = df[df["date"] == target_date]
    morning = day_df[(day_df["time_min"] >= MORNING_START_MIN) & (day_df["time_min"] <= MORNING_END_MIN)]
    if morning.empty:
        return None

    morning = morning.sort_values("time_min")
    last_bar = morning.iloc[-1]
    has_1130_bar = bool((morning["time_min"] == MORNING_END_MIN).any())

    zenba_close = float(last_bar["close"])
    zenba_low = float(morning["low"].min())
    zenba_high = float(morning["high"].max())
    atr14 = last_bar["atr14"]
    atr14 = None if pd.isna(atr14) else float(atr14)
    hist_1130 = last_bar["hist"]
    hist_1130 = None if pd.isna(hist_1130) else float(hist_1130)
    gc_state = "正" if (hist_1130 is not None and hist_1130 > 0) else "負"

    mom = morning.set_index("time_min")["hist"]
    h1 = mom.get(MOMENTUM_TIMES[0])
    h2 = mom.get(MOMENTUM_TIMES[1])
    h3 = mom.get(MOMENTUM_TIMES[2])
    d1 = (h2 - h1) if (h1 is not None and h2 is not None and not pd.isna(h1) and not pd.isna(h2)) else None
    d2 = (h3 - h2) if (h2 is not None and h3 is not None and not pd.isna(h2) and not pd.isna(h3)) else None

    value_approx = float((morning["volume"] * (morning["open"] + morning["high"] + morning["low"] + morning["close"]) / 4.0).sum())

    sizing = compute_sizing(zenba_close, zenba_low, atr14)

    # トレール引上げ判定UI用（trail_check_ui_spec.md）: 当日ザラ場全体の高値と後場(12:35以降)の高値。
    # 前場のみの時点(11:35/11:50/12:05実行)では day_high=前場高値・pm_high=None になる。
    day_high = float(day_df["high"].max())
    pm_df = day_df[day_df["time_min"] >= PM_START_MIN]
    pm_high = float(pm_df["high"].max()) if not pm_df.empty else None

    return {
        "code4": entry["code4"],
        "name": entry["name"],
        "区分": "緑" if entry["cls"] == "green" else "黄",
        "sector": entry["sector"],
        "financial": entry["financial"],
        "no_market_order": entry["no_market_order"],
        "前引け値": zenba_close,
        "前場安値": zenba_low,
        "前場高値": zenba_high,
        "atr14": atr14,
        "hist_1130": hist_1130,
        "gc_state": gc_state,
        "d1_sign": sign_str(d1),
        "d2_sign": sign_str(d2),
        "momentum_hint": hist_1130,
        "shares": sizing["shares"],
        "sl": sizing["sl"],
        "tp": sizing["tp"],
        "trail_trigger": sizing["trail_trigger"],
        "risk_jpy": sizing["risk_jpy"],
        "notional_jpy": sizing["notional_jpy"],
        "tradable": sizing["tradable"],
        "has_1130_bar": has_1130_bar,
        "value_approx_jpy": value_approx,
        "day_high": day_high,
        "pm_high": pm_high,
    }


def round_stock_numbers(s: dict) -> dict:
    """出力直前の丸め処理(円は整数、値は小数2桁程度)。"""
    out = dict(s)
    for k in ("前引け値", "前場安値", "前場高値", "sl", "tp", "trail_trigger", "day_high", "pm_high"):
        if out.get(k) is not None:
            out[k] = round(out[k], 1)
    for k in ("atr14",):
        if out.get(k) is not None:
            out[k] = round(out[k], 2)
    for k in ("hist_1130", "momentum_hint"):
        if out.get(k) is not None:
            out[k] = round(out[k], 4)
    for k in ("risk_jpy", "notional_jpy", "value_approx_jpy"):
        if out.get(k) is not None:
            out[k] = round(out[k])
    return out


def build_output(target_date, stocks: list[dict], all_ok: bool, missing: list[dict] | None = None) -> dict:
    # 優先順位: 緑→黄、同区分内は前場売買代金近似の大きい順
    def sort_key(s):
        cls_rank = 0 if s["区分"] == "緑" else 1
        return (cls_rank, -s["value_approx_jpy"])

    ordered = sorted(stocks, key=sort_key)
    for i, s in enumerate(ordered, start=1):
        s["優先順位"] = i

    # 出力列順を固定し、内部専用フィールド(has_1130_bar/value_approx_jpy/tradable)は
    # デバッグ用として残しつつ丸め処理する
    ordered = [round_stock_numbers(s) for s in ordered]

    now_jst = datetime.now(JST)
    return {
        "generated_at": now_jst.isoformat(),
        "date": target_date.isoformat(),
        "complete": all_ok,
        # 欠落の内訳をUIに渡す（"11:30バー未達"と"銘柄まるごと取得不可"を区別して表示するため）
        "missing": missing or [],
        "stocks": ordered,
    }


def main():
    parser = argparse.ArgumentParser(description="昼の自動準備シート生成")
    parser.add_argument("--asof", type=str, default=None,
                         help="検証用: 対象日付をYYYY-MM-DDで指定(省略時はJSTの今日)")
    parser.add_argument("--output", type=str, default=DEFAULT_OUTPUT,
                         help="出力JSONパス(省略時はdata/daily_prep.json)")
    parser.add_argument("--watchlist", type=str, default=WATCHLIST_PATH)
    args = parser.parse_args()

    if args.asof:
        target_date = datetime.strptime(args.asof, "%Y-%m-%d").date()
    else:
        target_date = datetime.now(JST).date()

    watchlist = load_watchlist(args.watchlist)
    tickers = [f"{r['code4']}.T" for r in watchlist]

    print(f"対象日: {target_date}")
    print(f"取得銘柄数: {len(tickers)}")
    bars_by_ticker = fetch_bars(tickers)
    print(f"取得成功銘柄数: {len(bars_by_ticker)}/{len(tickers)}")

    missing_tickers = [t for t in tickers if t not in bars_by_ticker]
    if missing_tickers:
        print(f"[WARN] 取得失敗: {missing_tickers}")

    stocks = []
    missing: list[dict] = []   # 銘柄まるごと取得できなかったもの（UIに理由込みで渡す）
    codes_with_1130 = 0
    codes_with_any_today = 0
    for entry in watchlist:
        ticker = f"{entry['code4']}.T"
        df = bars_by_ticker.get(ticker)
        if df is None or df.empty:
            print(f"[WARN] {entry['code4']} {entry['name']}: データ取得なし")
            missing.append({"code4": entry["code4"], "name": entry["name"], "reason": "データ取得なし"})
            continue
        df = add_indicators(df)
        row = process_code(entry, df, target_date)
        if row is None:
            print(f"[WARN] {entry['code4']} {entry['name']}: 対象日({target_date})の前場データなし")
            missing.append({"code4": entry["code4"], "name": entry["name"], "reason": "当日の前場データ未配信"})
            continue
        codes_with_any_today += 1
        if row["has_1130_bar"]:
            codes_with_1130 += 1
        stocks.append(row)

    if codes_with_any_today == 0:
        # 休場日(全銘柄で当日データが空)。既存のJSONを空配列で上書きすると
        # 前営業日の準備シートを失うため、ファイルがあるときは手を触れずに終了コード3を返す
        # (呼び出し側 run_daily_prep.ps1 は 3 を「休場日 -> pushしない」として扱う)。
        print("対象日のデータが全銘柄で空。休場日と判断します。")
        if os.path.exists(args.output):
            print(f"既存の {args.output} は上書きしません(前営業日の内容を保持)")
            sys.exit(3)
        output = build_output(target_date, [], False, missing)
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(output, f, ensure_ascii=False, indent=2)
        print(f"出力完了: {args.output} (0銘柄・休場日)")
        sys.exit(3)
    else:
        all_ok = (codes_with_1130 == len(watchlist))
        output = build_output(target_date, stocks, all_ok, missing)
        print(f"11:30バー完備銘柄数: {codes_with_1130}/{len(watchlist)} (complete={all_ok})")
        if missing:
            print(f"[WARN] 欠落銘柄: {[m['code4'] + ' ' + m['name'] for m in missing]}")

    out_dir = os.path.dirname(args.output)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"出力完了: {args.output} ({len(output['stocks'])}銘柄)")


if __name__ == "__main__":
    main()
