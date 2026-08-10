# A型の朝の準備シートのタスクスケジューラ登録スクリプト（1回だけ実行すればよい）
#
# 作成タスク（平日のみ・ログオン中のユーザーで実行）:
#   Phoenix ATypePrep Morning   08:40  A型バンド生成（主系）
#   Phoenix ATypePrep Morning2  08:55  再生成（yfinance未応答時の保険）
#
# 実行方法（PowerShellで）:
#   powershell -ExecutionPolicy Bypass -File C:\trading-tools\register_atype_prep_task.ps1
# 削除したい場合:
#   Unregister-ScheduledTask -TaskName "Phoenix ATypePrep Morning" -Confirm:$false

$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script = Join-Path $here "run_atype_prep.ps1"
if (-not (Test-Path $script)) { throw "run_atype_prep.ps1 が見つかりません: $script" }

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"" `
    -WorkingDirectory $here

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

# 実行時刻の根拠: 判定は9:00〜9:29。寄り付き前に確実に公開しておく必要があるため8:40を主系とし、
# yfinanceが応答しなかった場合の保険として8:55にもう一度走らせる。
$defs = @(
    @{ Name = "Phoenix ATypePrep Morning";  Time = "08:40"; Desc = "A型の前日終値+3.5〜5.0%バンド生成（主系）" },
    @{ Name = "Phoenix ATypePrep Morning2"; Time = "08:55"; Desc = "A型バンド再生成（取得失敗時の保険）" }
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
Get-ScheduledTask | Where-Object { $_.TaskName -like "Phoenix *Prep*" } |
    Select-Object TaskName, State | Format-Table -AutoSize
