# A型の朝の準備シート ローカル実行スクリプト（Windowsタスクスケジューラから起動）
#
# 目的: A型のエントリー判定は9:00〜9:29に行うため、寄り付き前に前日終値と
#       +3.5〜5.0%バンドを atype_prep.json として公開しておく。
#
# 登録: register_atype_prep_task.ps1 が平日08:40/08:55のタスクを作成する。
# ログ: logs/atype_prep_YYYYMMDD.log（14日より古いものは自動削除）
#
# 終了コード: 0=成功 / 1=失敗

$ErrorActionPreference = "Stop"
$repo = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$logDir = Join-Path $repo "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$log = Join-Path $logDir ("atype_prep_{0}.log" -f (Get-Date -Format "yyyyMMdd"))

# リモート(GitHub Actions)が勝手に更新してよい生成物。これ以外に差分があるときは自動同期しない
$GENERATED = @("daily_prep.json", "atype_prep.json")

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $log -Value $line -Encoding utf8
    Write-Host $line
}

try {
    Write-Log "=== start ==="
    Set-Location $repo

    Get-ChildItem $logDir -Filter "atype_prep_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    . (Join-Path $repo "_git_sync.ps1")
    Set-GitSafeEnv -Repo $repo
    $repaired = Repair-GitState
    if ($repaired) { Write-Log ("warn: " + $repaired) }

    & git fetch --quiet origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Log "warn: git fetch failed (continue)"
    } else {
        $sync = Sync-ToRemote -Generated $GENERATED
        if (-not $sync.ok) { Write-Log ("warn: " + $sync.reason) }
    }

    $env:PYTHONIOENCODING = "utf-8"
    # yfinance側が一時的に応答しないことがあるため最大3回まで再取得する
    $attempt = 0
    while ($true) {
        $attempt++
        $run = Invoke-Native { python -X utf8 atype_prep.py --output atype_prep.json }
        $out = $run.output
        $code = $run.code
        $out | ForEach-Object { Write-Log "  $_" }
        if ($code -eq 0) { break }
        if ($attempt -ge 3) {
            Write-Log "ERROR: atype_prep.py exit=$code (attempt $attempt)"
            exit 1
        }
        Write-Log "取得失敗のため60秒後に再試行します (attempt $attempt)"
        Start-Sleep -Seconds 60
    }

    $msg = "atype prep sheet update (local) {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm")
    $pub = Publish-Generated -File "atype_prep.json" -Generated $GENERATED -Message $msg -Log { param($m) Write-Log $m }
    if (-not $pub.ok) {
        Write-Log ("ERROR: " + $pub.reason)
        exit 1
    }
    Write-Log $pub.reason

    Write-Log "=== done ==="
    exit 0
}
catch {
    Write-Log ("EXCEPTION: " + $_.Exception.Message)
    exit 1
}
