<#
.SYNOPSIS
    movie-mode のセットアップ。リモコンの常駐登録・ファイアウォール開放・ショートカット作成。

.DESCRIPTION
    ゲームPCなど別端末のブラウザからセッション切り替えを行うには、
    リモコンが「ユーザーセッション内」かつ「昇格状態」で常駐している必要がある。

      - ユーザーセッション内でないと、キー送信が対象デスクトップに届かない
      - 昇格していないと、tscon 実行用のSYSTEMタスクを作れない
      - 移行処理の一部として起動する作りのままだと、
        映画モードに入る前はリモコンが動いておらず、そこから開始できない

    タスクスケジューラに「ログオン時 / 最上位の特権」で登録することで解決する。
    UACプロンプトは登録時の1回だけ。

.PARAMETER Uninstall
    登録を解除する（タスク・ファイアウォール規則・ショートカット）。

.PARAMETER SkipTask
    リモコンの常駐登録を行わない。

.PARAMETER SkipFirewall
    ファイアウォール規則を作らない。

.PARAMETER SkipShortcuts
    ショートカットを作らない。
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$SkipTask,
    [switch]$SkipFirewall,
    [switch]$SkipShortcuts
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName  = 'MovieRemote'
$FwName    = 'MovieRemote (TCP 8900)'
$LinkName  = '映画モード.lnk'
$Port      = 8900

function Ok   { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  [警告] $m" -ForegroundColor Yellow }
function Fail { param($m) Write-Host "  [失敗] $m" -ForegroundColor Red }
function Step { param($m) Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 管理者昇格
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'セットアップには管理者権限が必要です。UACを承認してください...' -ForegroundColor Yellow
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $MyInvocation.MyCommand.Path))
    foreach ($sw in 'Uninstall','SkipTask','SkipFirewall','SkipShortcuts') {
        if ($PSBoundParameters[$sw]) { $a += "-$sw" }
    }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $a } catch {
        Fail 'UACが拒否されました。'
    }
    exit
}

$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop'))  $LinkName
$startLnk   = Join-Path ([Environment]::GetFolderPath('Programs')) $LinkName

# ---------------------------------------------------------------- 解除
if ($Uninstall) {
    Step 'アンインストール'

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Ok "常駐タスク '$TaskName' を削除しました"
    } catch { Warn "常駐タスクは登録されていません" }

    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue }
    if ($conns) { Ok 'リモコンを停止しました' }

    try {
        Get-NetFirewallRule -DisplayName $FwName -ErrorAction Stop | Remove-NetFirewallRule -ErrorAction Stop
        Ok 'ファイアウォール規則を削除しました'
    } catch { Warn 'ファイアウォール規則はありません' }

    foreach ($l in @($desktopLnk, $startLnk)) {
        if (Test-Path -LiteralPath $l) {
            Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue
            Ok "ショートカットを削除: $l"
        }
    }

    Write-Host ''
    Write-Host 'アンインストールが完了しました。' -ForegroundColor Green
    Write-Host 'プログラム本体のファイルは残っています（フォルダごと削除して構いません）。' -ForegroundColor DarkGray
    exit
}

# ---------------------------------------------------------------- 前提確認
Step '前提確認'

$remote = Join-Path $ScriptDir 'movie-remote.py'
$exe    = Join-Path $ScriptDir 'MovieMode.exe'

if (Test-Path $exe) { Ok "MovieMode.exe を確認" }
else { Warn "MovieMode.exe がありません。build.cmd でビルドしてください" }

$pyw = "$env:LOCALAPPDATA\Programs\Python\Python312\pythonw.exe"
if (-not (Test-Path $pyw)) {
    $g = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($g) { $pyw = $g.Source } else { $pyw = $null }
}
if ($pyw) { Ok "pythonw.exe: $pyw" }
else { Warn 'pythonw.exe が見つかりません。リモコンは使えません（本体は動きます）' }

if (-not (Test-Path $remote)) { Warn 'movie-remote.py がありません' }

# ---------------------------------------------------------------- 常駐登録
if (-not $SkipTask) {
    Step 'リモコンの常駐登録'
    if (-not $pyw -or -not (Test-Path $remote)) {
        Warn 'Python もしくは movie-remote.py が無いためスキップします'
    } else {
        try {
            $action  = New-ScheduledTaskAction -Execute $pyw -Argument ('"{0}"' -f $remote) -WorkingDirectory $ScriptDir
            $me      = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
            $princ   = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
            $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                                    -StartWhenAvailable `
                                                    -ExecutionTimeLimit ([TimeSpan]::Zero) `
                                                    -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                                   -Principal $princ -Settings $set `
                                   -Description '動画リモコン（映画モード切り替え用・昇格常駐）' `
                                   -Force -ErrorAction Stop | Out-Null
            Ok "タスク '$TaskName' を登録（ログオン時 / 最上位の特権）"
        } catch {
            Fail ('登録に失敗: ' + $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------- ファイアウォール
if (-not $SkipFirewall) {
    Step 'ファイアウォール'
    # python.exe への既存の許可規則に依存すると、
    # ネットワークカテゴリが Public から Private に変わった時点で届かなくなる。
    if (Get-NetFirewallRule -DisplayName $FwName -ErrorAction SilentlyContinue) {
        Ok '規則は既に存在します'
    } else {
        try {
            New-NetFirewallRule -DisplayName $FwName -Direction Inbound -Action Allow `
                                -Protocol TCP -LocalPort $Port -Profile Any `
                                -Description '動画リモコン(movie-mode)の受信を許可' `
                                -ErrorAction Stop | Out-Null
            Ok "TCP $Port の受信を許可しました"
        } catch {
            Fail ('規則の作成に失敗: ' + $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------- ショートカット
if (-not $SkipShortcuts) {
    Step 'ショートカット'
    if (-not (Test-Path $exe)) {
        Warn 'MovieMode.exe が無いためスキップします'
    } else {
        try {
            $ws  = New-Object -ComObject WScript.Shell
            $ico = Join-Path $ScriptDir 'movie-mode.ico'
            foreach ($lp in @($desktopLnk, $startLnk)) {
                $l = $ws.CreateShortcut($lp)
                $l.TargetPath       = $exe
                $l.WorkingDirectory = $ScriptDir
                $l.Description      = '映画モード: コンソールセッションへ移動して配信画質を上げる'
                if (Test-Path $ico) { $l.IconLocation = "$ico,0" }
                $l.Hotkey = 'CTRL+ALT+M'
                $l.Save()
                Ok "作成: $lp"
            }
            Write-Host '  ショートカットキー: Ctrl + Alt + M' -ForegroundColor DarkGray
        } catch {
            Fail ('ショートカットの作成に失敗: ' + $_.Exception.Message)
        }
    }
}

# ---------------------------------------------------------------- 起動
if (-not $SkipTask -and $pyw -and (Test-Path $remote)) {
    Step 'リモコンの起動'
    # 非昇格で動いている既存プロセスがあると権限が足りないので、必ず入れ替える
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conns) {
        foreach ($c in $conns) { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        Ok '既存のリモコンを停止しました（非昇格の可能性があるため）'
    }
    try {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Start-Sleep -Seconds 3
        if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
            Ok 'リモコンが起動しました'
        } else {
            Warn 'リモコンの起動を確認できません。タスクスケジューラで MovieRemote を確認してください'
        }
    } catch {
        Fail ('起動に失敗: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 案内
$ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '10.*' -or $_.IPAddress -like '172.*' } |
       Select-Object -First 1).IPAddress
$url = 'http://{0}:{1}/' -f $ip, $Port

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' セットアップが完了しました' -ForegroundColor Cyan
Write-Host ''
Write-Host ' 別の端末のブラウザで開く:' -ForegroundColor Cyan
Write-Host ("   {0}" -f $url) -ForegroundColor White
Write-Host ''
Write-Host ' この画面から「映画モードにする」と再生操作ができます' -ForegroundColor DarkGray
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '解除するには Setup.exe の「アンインストール」を押してください。' -ForegroundColor DarkGray
