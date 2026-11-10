# 昼の準備シートのタスクスケジューラ登録スクリプト（1回だけ実行すればよい）
#
# 作成タスク（いずれも平日のみ・ログオン中のユーザーで実行・電源条件なし）:
#   Phoenix DailyPrep Noon    11:35  昼の準備シート（サイジング用）
#   Phoenix DailyPrep Close   15:35  大引け後（トレール引上げ判定用）
# いずれも「起動時刻を過ぎていたらできるだけ早く実行」を有効化（PC起動が遅れた日の保険）。
#
# 実行方法（PowerShellで）:
#   powershell -ExecutionPolicy Bypass -File C:\trading-tools\register_daily_prep_task.ps1
# 削除したい場合:
#   Unregister-ScheduledTask -TaskName "Phoenix DailyPrep Noon" -Confirm:$false
#   Unregister-ScheduledTask -TaskName "Phoenix DailyPrep Close" -Confirm:$false

$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script = Join-Path $here "run_daily_prep.ps1"
if (-not (Test-Path $script)) { throw "run_daily_prep.ps1 が見つかりません: $script" }

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"" `
    -WorkingDirectory $here

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

# 実行時刻の根拠: 11:30バー（11:30〜11:35をカバー）はyfinance側の反映に数分かかるため、
# 11:35ちょうどに実行すると has_1130_bar=false になる（2026-08-06に実測）。11:42/11:52の2本立てとし、
# 大引け(15:30)後も同様に15:42へ後ろ倒しする。
# 2026-11-04追加・2026-11-10修正: 後場の発注前チェック枠。
# **11-04に書いた12:42/12:50は実測に合っていなかった。** また、このスクリプト自体を実行して
# いなかったため、12:42/12:50 のタスクは一度も登録されておらず entry_block は毎日 null だった。
#
# 2026-11-10 の直接観測（3銘柄・45秒間隔・probe_bar_lag_20261110.py）: yfinance の5分足は
# **バー確定から 10.1〜10.7分**遅れて届く。3銘柄すべて同一時刻に到着＝配信側のバッチである。
#   12:30足（確定12:35）→ 12:45:20 着   ← 判定の本体。atr_confirm がここで揃う
#   12:35足（確定12:40）→ 12:50:36 着
#   12:40足（確定12:45）→ 12:55:07 着
#   12:45足（確定12:50）→ 13:00:23 着   ← 発注締切13:00に間に合わない
#   12:50足（確定12:55）→ 13:05:40 着
#   12:55足（確定13:00）→ 13:10:11 着
# よって**発注可能時間（12:30〜13:00）に間に合うのは12:30/12:35/12:40足の3本だけ**であり、
# index.html の PmHistTracker が追う3本とちょうど一致する。各足の到着直後に1本ずつ置く。
# **12:42では12:30足に間に合わない**（到着12:45:20）ので12:46へ後ろ倒しする。
$defs = @(
    @{ Name = "Phoenix DailyPrep Noon";   Time = "11:42"; Desc = "フェニックス昼の準備シート生成（サイジング用・主系）" },
    @{ Name = "Phoenix DailyPrep Noon2";  Time = "11:52"; Desc = "フェニックス昼の準備シート再生成（11:30バー取りこぼしの保険）" },
    @{ Name = "Phoenix DailyPrep Order";  Time = "12:46"; Desc = "発注前チェック主系（12:30足が12:45:20に着く。atr_confirmで正しいSLを出し entry_block を判定）" },
    @{ Name = "Phoenix DailyPrep Order2"; Time = "12:52"; Desc = "発注前チェック（12:35足が12:50:36に着く。12:30足取りこぼしの保険も兼ねる）" },
    @{ Name = "Phoenix DailyPrep Order3"; Time = "12:57"; Desc = "発注前チェック（12:40足が12:55:07に着く。発注締切13:00前の最終更新）" },
    @{ Name = "Phoenix DailyPrep Close";  Time = "15:42"; Desc = "フェニックス大引け後の準備シート更新（トレール引上げ判定用）" }
)

foreach ($d in $defs) {
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At $d.Time
    if (Get-ScheduledTask -TaskName $d.Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $d.Name -Confirm:$false
        Write-Host "既存タスクを削除: $($d.Name)"
    }
    Register-ScheduledTask -TaskName $d.Name -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description $d.Desc | Out-Null
    Write-Host "登録完了: $($d.Name) ($($d.Time) 平日)"
}

Write-Host ""
Write-Host "--- 登録済みタスク ---"
Get-ScheduledTask | Where-Object { $_.TaskName -like "Phoenix DailyPrep*" } |
    Select-Object TaskName, State | Format-Table -AutoSize
