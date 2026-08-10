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

    & git pull --rebase --autostash --quiet origin main
    if ($LASTEXITCODE -ne 0) { Write-Log "warn: git pull failed (continue)" }

    $env:PYTHONIOENCODING = "utf-8"
    # yfinance側が一時的に応答しないことがあるため最大3回まで再取得する
    $attempt = 0
    while ($true) {
        $attempt++
        $out = & python -X utf8 atype_prep.py --output atype_prep.json 2>&1
        $code = $LASTEXITCODE
        $out | ForEach-Object { Write-Log "  $_" }
        if ($code -eq 0) { break }
        if ($attempt -ge 3) {
            Write-Log "ERROR: atype_prep.py exit=$code (attempt $attempt)"
            exit 1
        }
        Write-Log "取得失敗のため60秒後に再試行します (attempt $attempt)"
        Start-Sleep -Seconds 60
    }

    & git add atype_prep.json
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Log "no changes to commit"
        exit 0
    }

    & git commit -q -m ("atype prep sheet update {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"))
    $pushed = $false
    for ($i = 1; $i -le 3; $i++) {
        & git pull --rebase --autostash --quiet origin main
        & git push --quiet origin main
        if ($LASTEXITCODE -eq 0) {
            Write-Log "pushed (attempt $i)"
            $pushed = $true
            break
        }
        Write-Log "push retry $i"
        Start-Sleep -Seconds 5
    }
    if (-not $pushed) {
        Write-Log "ERROR: push failed"
        exit 1
    }

    Write-Log "=== done ==="
    exit 0
}
catch {
    Write-Log ("EXCEPTION: " + $_.Exception.Message)
    exit 1
}
