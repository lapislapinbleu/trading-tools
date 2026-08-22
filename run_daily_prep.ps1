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
# 置き場所が変わっても動くようスクリプト自身の位置から解決する（2026-08 D:へ移動）
$repo = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$logDir = Join-Path $repo "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$log = Join-Path $logDir ("daily_prep_{0}.log" -f (Get-Date -Format "yyyyMMdd"))

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

    Get-ChildItem $logDir -Filter "daily_prep_*.log" -ErrorAction SilentlyContinue |
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
    # 11:30バー(11:30-11:35をカバー)はyfinanceの反映に数分かかることがあるため、
    # complete=false のときは90秒待って最大2回まで再取得する（2026-08-06の実測を受けた対策）
    $attempt = 0
    while ($true) {
        $attempt++
        $run = Invoke-Native { python -X utf8 daily_prep.py --output daily_prep.json }
        $out = $run.output
        $prepCode = $run.code
        if ($prepCode -eq 3) {
            # 休場日(全銘柄で当日データなし)。既存JSONは保持され、pushもしない
            $out | ForEach-Object { Write-Log "  $_" }
            Write-Log "skip: 休場日と判断。既存の準備シートを保持しpushしない"
            exit 0
        }
        if ($prepCode -ne 0) {
            Write-Log "ERROR: daily_prep.py exit=$prepCode (attempt $attempt)"
            $out | ForEach-Object { Write-Log "  $_" }
            exit 1
        }
        $out | ForEach-Object { Write-Log "  $_" }
        $isComplete = ($out -join "`n") -match "complete=True"
        if ($isComplete -or $attempt -ge 3) { break }
        Write-Log "complete=false のため90秒後に再取得します (attempt $attempt)"
        Start-Sleep -Seconds 90
    }

    $checkRun = Invoke-Native { python -X utf8 _check_prep_output.py }
    $check = $checkRun.output
    $checkCode = $checkRun.code
    $check | ForEach-Object { Write-Log "  $_" }
    if ($checkCode -eq 2) {
        Write-Log "skip: 当日データではない（休場日など）。pushしない"
        exit 0
    }
    if ($checkCode -ne 0) {
        Write-Log "ERROR: 生成物チェック失敗 exit=$checkCode"
        exit 1
    }

    $msg = "daily prep sheet update (local) {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm")
    $pub = Publish-Generated -File "daily_prep.json" -Generated $GENERATED -Message $msg -Log { param($m) Write-Log $m }
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
