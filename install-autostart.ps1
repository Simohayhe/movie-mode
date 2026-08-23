<#
.SYNOPSIS
    動画リモコンをログオン時に自動起動する常駐タスクとして登録する。

.DESCRIPTION
    ゲームPCのブラウザからセッション切り替え（映画モードへの移行）を行うには、
    リモコンが「ユーザーセッション内」かつ「昇格状態」で動いている必要がある。

      - ユーザーセッション内でないと、キー送信が対象デスクトップに届かない
      - 昇格していないと、tscon 実行用のSYSTEMタスクを作れない

    タスクスケジューラに「ログオン時 / 最上位の特権で実行」で登録することで
    両方を満たす。UACプロンプトは登録時の1回だけで、以後は出ない。

.PARAMETER Uninstall
    登録を解除して常駐を停止する。

.NOTES
    登録後はゲームPCのブラウザから
      http://<サーバーIP>:8900/?t=<トークン>
    を開けば、映画モードへの切り替えと再生操作ができる。
#>
[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName  = 'MovieRemote'

# ---------------------------------------------------------------- 管理者昇格
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'タスク登録には管理者権限が必要です。UACを承認してください...' -ForegroundColor Yellow
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $MyInvocation.MyCommand.Path))
    if ($Uninstall) { $a += '-Uninstall' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $a } catch {
        Write-Host 'UACが拒否されました。' -ForegroundColor Red
        Read-Host 'Enterで終了' | Out-Null
    }
    exit
}

# ---------------------------------------------------------------- 解除
if ($Uninstall) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "タスク '$TaskName' を削除しました。" -ForegroundColor Green
    } catch {
        Write-Host "タスクが見つかりません（既に未登録）。" -ForegroundColor Yellow
    }
    Get-Process pythonw -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -like '*python*' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '常駐を停止しました。' -ForegroundColor Green
    Read-Host 'Enterで終了' | Out-Null
    exit
}

# ---------------------------------------------------------------- 前提確認
$pyw = "$env:LOCALAPPDATA\Programs\Python\Python312\pythonw.exe"
if (-not (Test-Path $pyw)) {
    $g = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($g) { $pyw = $g.Source } else {
        Write-Host 'pythonw.exe が見つかりません。Pythonを確認してください。' -ForegroundColor Red
        Read-Host 'Enterで終了' | Out-Null
        exit 1
    }
}

$remote = Join-Path $ScriptDir 'movie-remote.py'
if (-not (Test-Path $remote)) {
    Write-Host "movie-remote.py が見つかりません: $remote" -ForegroundColor Red
    Read-Host 'Enterで終了' | Out-Null
    exit 1
}

Write-Host "pythonw : $pyw"
Write-Host "remote  : $remote"
Write-Host ''

# ---------------------------------------------------------------- 登録
$action = New-ScheduledTaskAction -Execute $pyw `
                                  -Argument ('"{0}"' -f $remote) `
                                  -WorkingDirectory $ScriptDir

$trigger = New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)

$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
                                        -LogonType Interactive `
                                        -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                         -DontStopIfGoingOnBatteries `
                                         -StartWhenAvailable `
                                         -ExecutionTimeLimit ([TimeSpan]::Zero) `
                                         -RestartCount 3 `
                                         -RestartInterval ([TimeSpan]::FromMinutes(1))

try {
    Register-ScheduledTask -TaskName $TaskName `
                           -Action $action -Trigger $trigger `
                           -Principal $principal -Settings $settings `
                           -Description '動画リモコン（映画モード切り替え用・昇格常駐）' `
                           -Force -ErrorAction Stop | Out-Null
    Write-Host "タスク '$TaskName' を登録しました（ログオン時 / 最上位の特権）。" -ForegroundColor Green
} catch {
    Write-Host ("登録に失敗: " + $_.Exception.Message) -ForegroundColor Red
    Read-Host 'Enterで終了' | Out-Null
    exit 1
}

# 既存のリモコンを止めてからタスク経由で起動し直す（昇格状態にするため）
$listening = Get-NetTCPConnection -LocalPort 8900 -State Listen -ErrorAction SilentlyContinue
if ($listening) {
    Write-Host '既存のリモコンを停止します（非昇格で動作している可能性があるため）...' -ForegroundColor Yellow
    foreach ($c in $listening) {
        Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3

if (Get-NetTCPConnection -LocalPort 8900 -State Listen -ErrorAction SilentlyContinue) {
    Write-Host 'リモコンが起動しました。' -ForegroundColor Green
} else {
    Write-Host 'リモコンの起動を確認できませんでした。' -ForegroundColor Yellow
    Write-Host 'タスクスケジューラで MovieRemote の状態を確認してください。' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 案内
$ip = (Get-NetIPAddress -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '10.*' } |
       Select-Object -First 1).IPAddress
$tokenFile = Join-Path $ScriptDir 'remote-token.txt'
$url = 'http://{0}:8900/' -f $ip
if (Test-Path $tokenFile) {
    $t = (Get-Content $tokenFile -Raw).Trim()
    if ($t) { $url += ('?t={0}' -f $t) }
}

Write-Host ''
Write-Host '  ===============================================================' -ForegroundColor Cyan
Write-Host '   ゲームPC / スマホのブラウザで開く' -ForegroundColor Cyan
Write-Host ''
Write-Host ("     {0}" -f $url) -ForegroundColor White
Write-Host ''
Write-Host '   「映画モードにする」ボタンでセッション切り替えができます' -ForegroundColor DarkGray
Write-Host '  ===============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '解除するには: install-autostart.ps1 -Uninstall' -ForegroundColor DarkGray
Read-Host 'Enterで終了' | Out-Null
