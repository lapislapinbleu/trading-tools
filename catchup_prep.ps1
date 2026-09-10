# ログオン時キャッチアップ（2026-09-10新設）
#
# 背景: 定時タスク（Phoenix DailyPrep Noon/Noon2 等）は LogonType=Interactive のため
#       「ユーザーがログオンしているときのみ」実行される。2026-09-10はPCが02:32から
#       起動していたのに誰もログオンしておらず（初回ログオン12:27）、11:42/11:52の
#       両方が起動せずシートが前日のままになった。
#       GitHub Actionsのcronは当時ほぼ毎日5時間遅延しており（昼の4本が16時台に着火）
#       保険として機能していなかった。
#
# 動作: ログオン直後に走り、「その時刻に必要なシートが古ければ」だけ生成し直す。
#       条件を満たさなければ何もしない（無駄なコミットを作らない）。
#
# 判定:
#   昼の準備シート … 11:35〜15:00 の間で daily_prep.json の date が本日でなければ実行
#   A型のバンド    … 08:35〜09:25 の間で atype_prep.json の prev_close_date が
#                    前営業日でなければ実行（前営業日の算出は簡易・土日のみ考慮）
#
# 終了コード: 常に0（キャッチアップ不要も正常）。生成の成否は各ランナーのログを見る。

$ErrorActionPreference = "Stop"
$repo = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$logDir = Join-Path $repo "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$log = Join-Path $logDir ("catchup_{0}.log" -f (Get-Date -Format "yyyyMMdd"))

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $log -Value $line -Encoding utf8
    Write-Host $line
}

function Get-JsonField($path, $field) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json).$field }
    catch { return $null }
}

$now = Get-Date
$today = $now.ToString("yyyy-MM-dd")
$minutes = $now.Hour * 60 + $now.Minute

Write-Log ("=== catchup start === {0} (平日={1})" -f $now.ToString("HH:mm"), ($now.DayOfWeek -notin 'Saturday','Sunday'))

if ($now.DayOfWeek -in 'Saturday', 'Sunday') {
    Write-Log "土日のため何もしない"
    exit 0
}

$ran = $false

# ---- 昼の準備シート ----
if ($minutes -ge (11 * 60 + 35) -and $minutes -le (15 * 60)) {
    $d = Get-JsonField (Join-Path $repo "daily_prep.json") "date"
    if ($d -ne $today) {
        Write-Log ("昼の準備シートが古い（date={0} / 本日={1}）→ run_daily_prep.ps1 を実行" -f $d, $today)
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo "run_daily_prep.ps1")
        Write-Log ("run_daily_prep.ps1 終了コード={0}" -f $LASTEXITCODE)
        $ran = $true
    } else {
        Write-Log ("昼の準備シートは本日分（date={0}）。何もしない" -f $d)
    }
}

# ---- A型の朝のバンド ----
if ($minutes -ge (8 * 60 + 35) -and $minutes -le (9 * 60 + 25)) {
    $prev = $now.AddDays(-1)
    while ($prev.DayOfWeek -in 'Saturday', 'Sunday') { $prev = $prev.AddDays(-1) }
    $expected = $prev.ToString("yyyy-MM-dd")
    $a = Get-JsonField (Join-Path $repo "atype_prep.json") "prev_close_date"
    if ($a -ne $expected) {
        Write-Log ("A型バンドが古い（prev_close_date={0} / 期待={1}）→ run_atype_prep.ps1 を実行" -f $a, $expected)
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo "run_atype_prep.ps1")
        Write-Log ("run_atype_prep.ps1 終了コード={0}" -f $LASTEXITCODE)
        $ran = $true
    } else {
        Write-Log ("A型バンドは前営業日分（{0}）。何もしない" -f $a)
    }
}

if (-not $ran) { Write-Log "キャッチアップ対象の時間帯外、または既に最新" }
Write-Log "=== catchup done ==="
exit 0
