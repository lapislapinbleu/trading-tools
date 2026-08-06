# 昼の準備シート ローカル実行スクリプト（Windowsタスクスケジューラから起動）
#
# 目的: GitHub Actionsのcronは正午前後に遅延・スキップされることがあるため、
#       PCから確実な時刻に daily_prep.py を実行し、生成したJSONをpushする。
#       Actions側のcronはPCが落ちていた日のバックアップとして残す。
#
# 登録: register_daily_prep_task.ps1 が平日11:35/15:35のタスクを作成する。
# ログ: logs/daily_prep_YYYYMMDD.log（14日より古いものは自動削除）
#
# 終了コード: 0=成功(またはデータ無し=休場)、1=失敗

$ErrorActionPreference = "Stop"
$repo = "C:\Users\ananco\Documents\invest\trading-tools"
$logDir = Join-Path $repo "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$log = Join-Path $logDir ("daily_prep_{0}.log" -f (Get-Date -Format "yyyyMMdd"))

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $log -Value $line -Encoding utf8
    Write-Host $line
}

try {
    Write-Log "=== start ==="
    Set-Location $repo

    Get-ChildItem $logDir -Filter "daily_prep_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    & git pull --rebase --quiet origin main
    if ($LASTEXITCODE -ne 0) { Write-Log "warn: git pull failed (continue)" }

    $env:PYTHONIOENCODING = "utf-8"
    # 11:30バー(11:30-11:35をカバー)はyfinanceの反映に数分かかることがあるため、
    # complete=false のときは90秒待って最大2回まで再取得する（2026-08-06の実測を受けた対策）
    $attempt = 0
    while ($true) {
        $attempt++
        $out = & python -X utf8 daily_prep.py --output daily_prep.json 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "ERROR: daily_prep.py exit=$LASTEXITCODE (attempt $attempt)"
            $out | ForEach-Object { Write-Log "  $_" }
            exit 1
        }
        $out | ForEach-Object { Write-Log "  $_" }
        $isComplete = ($out -join "`n") -match "complete=True"
        if ($isComplete -or $attempt -ge 3) { break }
        Write-Log "complete=false のため90秒後に再取得します (attempt $attempt)"
        Start-Sleep -Seconds 90
    }

    $check = & python -X utf8 _check_prep_output.py 2>&1
    $checkCode = $LASTEXITCODE
    $check | ForEach-Object { Write-Log "  $_" }
    if ($checkCode -eq 2) {
        Write-Log "skip: 当日データではない（休場日など）。pushしない"
        exit 0
    }
    if ($checkCode -ne 0) {
        Write-Log "ERROR: 生成物チェック失敗 exit=$checkCode"
        exit 1
    }

    & git add daily_prep.json
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Log "no changes to commit"
        exit 0
    }

    & git commit -q -m ("daily prep sheet update (local) {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"))
    $pushed = $false
    for ($i = 1; $i -le 3; $i++) {
        & git pull --rebase --quiet origin main
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
