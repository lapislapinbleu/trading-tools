# 準備シート自動運用のgit共通処理（run_daily_prep.ps1 / run_atype_prep.ps1 から dot-source する）
#
# 設計方針（2026-08-22 障害を受けて全面変更）:
#   旧方式は push が弾かれるたびに `git pull --rebase` していた。生成物JSONは
#   ローカル(タスクスケジューラ)とGitHub Actionsの両方が同じ行を書き換えるため
#   rebaseは必ずコンフリクトし、リポジトリが「rebase途中」で固定される。
#   一度そうなると以降の全実行が pull/push 失敗で死ぬ（2026-08-20〜21の障害）。
#
#   新方式は rebase/merge を一切使わない:
#     ① 生成物の差分だけならローカル履歴を捨てて origin/main に合わせる
#     ② 生成し直したJSONを載せ替えて単一コミットにする
#   マージ解決が発生しないので「途中で止まる」状態が原理的に作れない。
#   生成物以外に差分があるときは何もせず警告を出す（手作業の編集を壊さないため）。

# git が「Deletion of directory '.git/objects/xx' failed. Should I try again? (y/n)」等の
# 対話プロンプトを出すと、タスクスケジューラ実行では応答できず無限に待つ（2026-08-20 15:42の停止）。
# GIT_ASK_YESNO に「常にno」を返すバッチを渡して、この種のプロンプトを封じる。
function Set-GitSafeEnv {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $env:GIT_ASK_YESNO = Join-Path $Repo "git_ask_no.cmd"
    $env:GIT_TERMINAL_PROMPT = "0"
    $env:GIT_PAGER = "cat"
    # 自動gcはロック競合でプロンプトを出す元凶なので止める（棚卸しは手動 git gc）
    $current = (& git config --get gc.auto)
    if ($current -ne "0") { & git config gc.auto 0 }
}

# 前回実行が異常終了して .git に残骸が残っていれば取り除く。
# これが無いと1日の失敗が翌日以降すべてに波及する。
function Repair-GitState {
    $gitDir = (& git rev-parse --git-dir 2>$null)
    if (-not $gitDir) { return $null }
    foreach ($d in @("rebase-merge", "rebase-apply")) {
        if (Test-Path (Join-Path $gitDir $d)) {
            & git rebase --abort 2>&1 | Out-Null
            return "rebase途中の状態を検出し abort しました"
        }
    }
    if (Test-Path (Join-Path $gitDir "MERGE_HEAD")) {
        & git merge --abort 2>&1 | Out-Null
        return "merge途中の状態を検出し abort しました"
    }
    $lock = Join-Path $gitDir "index.lock"
    if (Test-Path $lock) {
        # 実行中のgitが持っている可能性があるので、10分以上放置されたものだけ消す
        $age = (Get-Date) - (Get-Item $lock).LastWriteTime
        if ($age.TotalMinutes -ge 10) {
            Remove-Item $lock -Force -ErrorAction SilentlyContinue
            return "放置された index.lock を削除しました"
        }
    }
    return $null
}

# 作業ツリーの差分 + origin/main に無いローカルコミットが触ったファイル
function Get-DivergentPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(& git status --porcelain)) {
        if (-not $line) { continue }
        $p = $line.Substring(3).Trim()
        if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }   # リネームは新しい方だけ見る
        $paths.Add($p.Trim('"'))
    }
    foreach ($p in @(& git diff --name-only origin/main...HEAD 2>$null)) {
        if ($p) { $paths.Add($p.Trim()) }
    }
    return @($paths | Sort-Object -Unique)
}

# ローカルを origin/main に合わせ直す。差分が $Generated だけのときしか実行しない。
# 戻り値: @{ ok = $true/$false; reason = "..." }
function Sync-ToRemote {
    param([Parameter(Mandatory = $true)][string[]]$Generated)

    $diverged = Get-DivergentPaths
    $unexpected = @($diverged | Where-Object { $Generated -notcontains $_ })
    if ($unexpected.Count -gt 0) {
        return @{ ok = $false; reason = ("生成物以外に差分があるため自動同期しません: " + ($unexpected -join ", ")) }
    }
    if ($diverged.Count -eq 0) {
        # ローカル固有の変更なし。origin/mainまで早送りするだけ
        & git merge --ff-only --quiet origin/main 2>&1 | Out-Null
        return @{ ok = $true; reason = "fast-forward" }
    }

    & git reset --soft -q origin/main
    foreach ($f in $Generated) {
        & git checkout --quiet origin/main -- $f 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # origin/main にまだ無いファイル（初回など）。indexから外して未追跡に戻す
            & git restore --staged -- $f 2>&1 | Out-Null
        }
    }
    $left = @(& git status --porcelain)
    if ($left.Count -gt 0) {
        return @{ ok = $false; reason = ("同期後も差分が残りました: " + ($left -join " / ")) }
    }
    return @{ ok = $true; reason = "reset-to-remote" }
}

# 生成物をコミットしてpushする。pushが弾かれたらrebaseせずに
# 「origin/mainへ合わせ直す → 生成物を載せ替える → 再コミット」を繰り返す。
# 戻り値: @{ ok = $true/$false; reason = "..." }
function Publish-Generated {
    param(
        [Parameter(Mandatory = $true)][string]$File,        # コミット対象（生成したJSON）
        [Parameter(Mandatory = $true)][string[]]$Generated, # 同期時にリモート優先でよいファイル一覧
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$MaxAttempts = 4,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )

    # 生成したJSONの控え。push競合でorigin/mainの内容に戻したあと載せ替えるのに使う
    $backup = Join-Path $env:TEMP ("prep_pending_{0}_{1}.json" -f ($File -replace '\W', '_'), $PID)
    Copy-Item $File $backup -Force

    try {
        & git add -- $File
        & git diff --cached --quiet
        if ($LASTEXITCODE -eq 0) { return @{ ok = $true; reason = "no-changes" } }
        & git commit -q -m $Message

        for ($i = 1; $i -le $MaxAttempts; $i++) {
            & git push --quiet origin main
            if ($LASTEXITCODE -eq 0) { return @{ ok = $true; reason = ("pushed (attempt {0})" -f $i) } }

            & $Log ("push拒否 (attempt {0}) — リモートを取り込み直します" -f $i)
            & git fetch --quiet origin main
            if ($LASTEXITCODE -ne 0) {
                Start-Sleep -Seconds 5
                continue
            }
            $r = Sync-ToRemote -Generated $Generated
            if (-not $r.ok) { return @{ ok = $false; reason = $r.reason } }

            Copy-Item $backup $File -Force
            & git add -- $File
            & git diff --cached --quiet
            if ($LASTEXITCODE -eq 0) {
                return @{ ok = $true; reason = "リモートが同一内容のためcommit不要" }
            }
            & git commit -q -m $Message
            Start-Sleep -Seconds 3
        }
        return @{ ok = $false; reason = ("push失敗（{0}回試行）" -f $MaxAttempts) }
    }
    finally {
        Remove-Item $backup -Force -ErrorAction SilentlyContinue
    }
}

# ネイティブコマンドのstderrをPowerShellの終了エラーに化けさせずに捕まえる。
# $ErrorActionPreference='Stop' のまま `python ... 2>&1` すると、yfinanceが出す
# ただの警告(例: "$8795.T: possibly delisted")でスクリプト全体が落ちる（2026-08-20の障害）。
function Invoke-Native {
    param([Parameter(Mandatory = $true)][scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command 2>&1
        return @{ output = @($output); code = $LASTEXITCODE }
    }
    finally { $ErrorActionPreference = $prev }
}
