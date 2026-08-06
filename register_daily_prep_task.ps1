# 昼の準備シートのタスクスケジューラ登録スクリプト（1回だけ実行すればよい）
#
# 作成タスク（いずれも平日のみ・ログオン中のユーザーで実行・電源条件なし）:
#   Phoenix DailyPrep Noon    11:35  昼の準備シート（サイジング用）
#   Phoenix DailyPrep Close   15:35  大引け後（トレール引上げ判定用）
# いずれも「起動時刻を過ぎていたらできるだけ早く実行」を有効化（PC起動が遅れた日の保険）。
#
# 実行方法（PowerShellで）:
#   powershell -ExecutionPolicy Bypass -File C:\Users\ananco\Documents\invest\trading-tools\register_daily_prep_task.ps1
# 削除したい場合:
#   Unregister-ScheduledTask -TaskName "Phoenix DailyPrep Noon" -Confirm:$false
#   Unregister-ScheduledTask -TaskName "Phoenix DailyPrep Close" -Confirm:$false

$ErrorActionPreference = "Stop"
$script = "C:\Users\ananco\Documents\invest\trading-tools\run_daily_prep.ps1"
if (-not (Test-Path $script)) { throw "run_daily_prep.ps1 が見つかりません: $script" }

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"" `
    -WorkingDirectory "C:\Users\ananco\Documents\invest\trading-tools"

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
$defs = @(
    @{ Name = "Phoenix DailyPrep Noon";   Time = "11:42"; Desc = "フェニックス昼の準備シート生成（サイジング用・主系）" },
    @{ Name = "Phoenix DailyPrep Noon2";  Time = "11:52"; Desc = "フェニックス昼の準備シート再生成（11:30バー取りこぼしの保険）" },
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
