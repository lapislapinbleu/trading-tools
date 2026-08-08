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
n_stocks = len(d.get("stocks", []))
print(f"date={d.get('date')} today={today} complete={d.get('complete')} stocks={n_stocks}")
if d.get("date") != today:
    sys.exit(2)
# 当日日付でも銘柄0件なら休場日。空のシートをpushして前営業日の内容を消さない
if n_stocks == 0:
    print("銘柄0件のためpushしない(休場日)")
    sys.exit(2)
sys.exit(0)
