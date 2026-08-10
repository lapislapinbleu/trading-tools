"""A型（寄り天ショート）の朝の準備シート生成スクリプト。

rulebook §3.2 のエントリー条件のうち、事前に確定できるのは「前日終値」だけである。
  1本目: 始値 > 前日終値
  2本目: 陽線かつ高値が前日終値比 +3.5〜5.0%   ← このバンドを円建てで先に出しておく
  3本目: 2本目始値を下回ったら成行ショート
9:00〜9:29の判定中に%計算をする余裕はないため、発注可能3銘柄について
「前日終値」「+3.5%の価格」「+5.0%の価格」を atype_prep.json に書き出し、index.htmlのA型タブで表示する。

前日終値は日足の終値（無調整）を使う。auto_adjust=Trueだと配当調整済み終値になり
SBI/TradingViewの表示値と食い違うため、必ず auto_adjust=False で取得すること。

実行タイミング: 平日 08:40 / 08:55（run_atype_prep.ps1 → タスクスケジューラ）。
大引け後に走らせた場合は当日終値が翌営業日用のバンドになる（15:40以降のみ当日足を採用）。

使い方:
  python -X utf8 atype_prep.py                       # 本番（atype_prep.json）
  python -X utf8 atype_prep.py --output /tmp/x.json  # 検証用

終了コード: 0=成功 / 1=失敗（3銘柄すべて取得できず）
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, time as dtime
from zoneinfo import ZoneInfo

import pandas as pd
import yfinance as yf

JST = ZoneInfo("Asia/Tokyo")
DEFAULT_OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "atype_prep.json")

# rulebook §3.1 発注可能3銘柄（同時シグナル時のタイブレークもこのコード昇順）
ATYPE_STOCKS = [
    {"code4": "5803", "name": "フジクラ"},
    {"code4": "6723", "name": "ルネサス"},
    {"code4": "6981", "name": "村田製作所"},
]

BAND_LOW_PCT = 0.035   # 2本目高値の下限（前日終値比 +3.5%）
BAND_HIGH_PCT = 0.050  # 上限（+5.0%）

# 大引け(15:30)後にyfinanceの日足が当日分に更新されるまでの余裕
CLOSE_SETTLED = dtime(15, 40)


def tick_size(price: float) -> float:
    """東証の細かい呼値（TOPIX500構成銘柄）。index.htmlのtickSize()と同一定義。"""
    if price <= 1000:
        return 0.1
    if price <= 3000:
        return 0.5
    if price <= 10000:
        return 1.0
    if price <= 30000:
        return 5.0
    return 10.0


def round_up_tick(price: float) -> float:
    """バンド下限用。+3.5%を満たす最初の呼値（切上げ）。"""
    tick = tick_size(price)
    steps = -(-price / tick // 1)  # ceil
    return round(steps * tick, 2)


def round_down_tick(price: float) -> float:
    """バンド上限用。+5.0%を超えない最後の呼値（切下げ）。"""
    tick = tick_size(price)
    steps = price / tick // 1  # floor
    return round(steps * tick, 2)


def fetch_daily(tickers: list[str]) -> dict[str, pd.DataFrame]:
    raw = yf.download(
        tickers=tickers,
        period="1mo",
        interval="1d",
        group_by="ticker",
        auto_adjust=False,   # 配当調整済み終値では実際の前日終値と合わないため必須
        progress=False,
        threads=True,
    )
    out: dict[str, pd.DataFrame] = {}
    if raw is None or raw.empty:
        return out
    if isinstance(raw.columns, pd.MultiIndex):
        top = set(raw.columns.get_level_values(0))
        for t in tickers:
            if t in top:
                sub = raw[t].dropna(how="all")
                if not sub.empty:
                    out[t] = sub
    elif len(tickers) == 1:
        sub = raw.dropna(how="all")
        if not sub.empty:
            out[tickers[0]] = sub
    return out


def last_settled_close(df: pd.DataFrame, now_jst: datetime) -> tuple[str, float] | None:
    """確定済みの最新日足（日付, 終値）を返す。

    当日の足は大引け直後だと未確定・部分値のことがあるため、15:40より前は採用しない。
    """
    today = now_jst.date()
    for idx in reversed(df.index):
        d = idx.date() if hasattr(idx, "date") else idx
        if d > today:
            continue
        if d == today and now_jst.time() < CLOSE_SETTLED:
            continue
        close = df.loc[idx, "Close"]
        if pd.isna(close):
            continue
        return d.isoformat(), float(close)
    return None


def build_stock(entry: dict, date_str: str, prev_close: float) -> dict:
    low_raw = prev_close * (1 + BAND_LOW_PCT)
    high_raw = prev_close * (1 + BAND_HIGH_PCT)
    return {
        "code4": entry["code4"],
        "name": entry["name"],
        "prev_close": round(prev_close, 2),
        "prev_close_date": date_str,
        # 生値（%の定義そのもの）と、呼値に丸めた実際に約定しうる境界の両方を持たせる
        "band_low_raw": round(low_raw, 2),
        "band_high_raw": round(high_raw, 2),
        "band_low": round_up_tick(low_raw),
        "band_high": round_down_tick(high_raw),
        "tick": tick_size(prev_close),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="A型の朝の準備シート生成")
    parser.add_argument("--output", type=str, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    now_jst = datetime.now(JST)
    tickers = [s["code4"] + ".T" for s in ATYPE_STOCKS]
    frames = fetch_daily(tickers)

    stocks, missing = [], []
    for entry in ATYPE_STOCKS:
        df = frames.get(entry["code4"] + ".T")
        if df is None or df.empty:
            missing.append({"code4": entry["code4"], "name": entry["name"], "reason": "データ取得なし"})
            continue
        got = last_settled_close(df, now_jst)
        if got is None:
            missing.append({"code4": entry["code4"], "name": entry["name"], "reason": "確定日足なし"})
            continue
        date_str, prev_close = got
        stocks.append(build_stock(entry, date_str, prev_close))

    if not stocks:
        print("[ERROR] 3銘柄すべて取得できませんでした")
        return 1

    # 3銘柄の基準日は通常一致する。ずれた場合は最新日を代表値にし、行ごとの日付で検証できるようにする
    base_date = max(s["prev_close_date"] for s in stocks)
    output = {
        "generated_at": now_jst.isoformat(),
        "prev_close_date": base_date,
        "band_pct": [BAND_LOW_PCT, BAND_HIGH_PCT],
        "missing": missing,
        "stocks": stocks,
    }

    out_dir = os.path.dirname(args.output)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)

    print(f"基準日(前日終値): {base_date}")
    for s in stocks:
        print(f"  {s['code4']} {s['name']}: 終値{s['prev_close']} → "
              f"+3.5%={s['band_low']} 〜 +5.0%={s['band_high']}")
    if missing:
        print(f"[WARN] 欠落: {[m['code4'] + ' ' + m['name'] for m in missing]}")
    print(f"出力完了: {args.output} ({len(stocks)}銘柄)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
