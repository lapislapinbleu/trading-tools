"""run_daily_prep.ps1 用の生成物チェック。

daily_prep.json が「当日日付」であることを確認する。
終了コード: 0=当日データ / 2=当日でない(休場日など。pushしない) / 1=読めない
"""
import datetime
import json
import sys

try:
    with open("daily_prep.json", encoding="utf-8") as f:
        d = json.load(f)
except Exception as ex:  # noqa: BLE001
    print(f"read error: {ex}")
    sys.exit(1)

today = datetime.datetime.now().strftime("%Y-%m-%d")
print(f"date={d.get('date')} today={today} complete={d.get('complete')} stocks={len(d.get('stocks', []))}")
sys.exit(0 if d.get("date") == today else 2)
