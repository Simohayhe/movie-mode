<#
.SYNOPSIS
    映画モード: RDPセッションをコンソールセッションへ移動し、
    Discordの画面共有をGPU(NVENC)経路に載せる。

.DESCRIPTION
    RDPセッションのデスクトップは "Microsoft Remote Display Adapter" が描画するため、
    DiscordがNVENCを掴めずCPUソフトエンコードに落ちる(実測: NVENC Active Sessions = 0)。
    さらに解像度がRDPクライアント窓のサイズに引きずられ、非整数スケールで劣化する。

    本スクリプトはセッションを物理コンソールへ移し、GPUが描画する
    1920x1080 のデスクトップ上でDiscordがキャプチャできる状態を作る。

.PARAMETER RestartDiscord
    移動後にDiscordを再起動する。既定では再起動しない。
    配信を張ったまま移動するとキャプチャがそのまま生き残るため、
    再起動すると逆に配信が切れて張り直しが必要になる。
    移動後に映像が固まる・黒くなる場合だけ付ける。

.PARAMETER Yes
    確認プロンプトを出さずに即実行する。ランチャー用。

.NOTES
    移動後にRDPで接続し直すと、セッションはRDP側に引き戻される(Windowsの仕様)。
    画面を見るには物理モニタか、セッションを奪わないミラー型ツール
    (Parsec / RustDesk / AnyDesk / Sunshine) を使うこと。
#>
[CmdletBinding()]
param(
    [switch]$RestartDiscord,
    [switch]$Yes,
    [switch]$NoRemote,
    [switch]$DryRun
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile   = Join-Path $ScriptDir 'movie-mode.log'
$TaskName  = 'MovieMode-ToConsole'

function Write-Log {
    param([string]$Message, [ConsoleColor]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

# ランチャー起動時（-Yes）はウィンドウを自動で閉じる。
# 移動後はコンソールセッション側に窓が残るため、Enter待ちだと閉じられなくなる。
function Wait-Exit {
    param([int]$Seconds = 3)
    if ($Yes) {
        Write-Host ("`n{0}秒後に自動で閉じます..." -f $Seconds) -ForegroundColor DarkGray
        Start-Sleep -Seconds $Seconds
    } else {
        Read-Host 'Enterで終了' | Out-Null
    }
}

# ---------------------------------------------------------------- 管理者昇格
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host 'tscon にはSYSTEM権限が要るため昇格します。UACを承認してください...' -ForegroundColor Yellow
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $MyInvocation.MyCommand.Path))
    if ($RestartDiscord) { $a += '-RestartDiscord' }
    if ($Yes)            { $a += '-Yes' }
    if ($NoRemote)       { $a += '-NoRemote' }
    if ($DryRun)         { $a += '-DryRun' }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    } catch {
        Write-Host 'UACが拒否されました。中止します。' -ForegroundColor Red
        Wait-Exit -Seconds 15
    }
    exit
}

# ---------------------------------------------------------------- ヘルパー
if (-not ('Native.Wts' -as [type])) {
    Add-Type -Name Wts -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint WTSGetActiveConsoleSessionId();
'@
}
function Get-ConsoleSessionId { [int][Native.Wts]::WTSGetActiveConsoleSessionId() }

Add-Type -AssemblyName System.Windows.Forms
function Get-PrimaryResolution {
    $b = ([System.Windows.Forms.Screen]::AllScreens)[0].Bounds
    return ('{0}x{1}' -f $b.Width, $b.Height)
}

function Get-ActiveAdapter {
    try {
        $vc = Get-CimInstance Win32_VideoController -ErrorAction Stop |
              Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
        if ($vc) { return $vc.Name }
    } catch { }
    return '(判定不能)'
}

# Chromiumは hardware_acceleration_mode を「明示的にOFFにしたとき」だけ書き込む。
# キーが無い状態は「既定のまま(ON)」とも「まだフラッシュされていない」とも取れるため、
# ON / OFF / 不明 の3状態で返す。断定して警告すると誤警報になる。
function Test-BrowserHwAccel {
    $targets = @(
        @{ Name = 'Chrome'; Proc = 'chrome'; Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Preferences" }
        @{ Name = 'Edge';   Proc = 'msedge'; Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Preferences" }
        @{ Name = 'Brave';  Proc = 'brave';  Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Preferences" }
    )
    $out = @()
    foreach ($t in $targets) {
        if (-not (Test-Path $t.Path)) { continue }
        $running = [bool](Get-Process -Name $t.Proc -ErrorAction SilentlyContinue)
        $state = 'unknown'
        try {
            $j = Get-Content $t.Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $hwmode = $j.hardware_acceleration_mode
            if ($hwmode -and ($hwmode.PSObject.Properties.Name -contains 'enabled')) {
                $state = if ([bool]$hwmode.enabled) { 'on' } else { 'off' }
            }
        } catch { }
        $out += [pscustomobject]@{ Browser = $t.Name; State = $state; Running = $running }
    }
    return $out
}

function Get-MirrorRemoteTools {
    $cand = [ordered]@{
        'Parsec'   = @("$env:ProgramFiles\Parsec\parsecd.exe", "$env:LOCALAPPDATA\Parsec\parsecd.exe")
        'RustDesk' = @("$env:ProgramFiles\RustDesk\rustdesk.exe")
        'AnyDesk'  = @("${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe", "$env:ProgramData\AnyDesk\AnyDesk.exe")
        'Sunshine' = @("$env:ProgramFiles\Sunshine\sunshine.exe", "$env:LOCALAPPDATA\Programs\Sunshine\sunshine.exe")
    }
    $found = @()
    foreach ($k in $cand.Keys) {
        foreach ($p in $cand[$k]) { if (Test-Path $p) { $found += $k; break } }
    }
    return $found
}

function Get-PythonPath {
    $c = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
    if (Test-Path $c) { return $c }
    $g = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    return $null
}

# 移動前にリモコンを起動しておく。プロセスはセッションごとコンソール側へ移動するため、
# 移動後もキー送信がコンソールのデスクトップに届く。
function Start-MovieRemote {
    param([string]$Ip)
    $script = Join-Path $ScriptDir 'movie-remote.py'
    if (-not (Test-Path $script)) {
        Write-Log 'movie-remote.py が見つかりません。リモコンは起動しません。' Yellow
        return
    }
    $py = Get-PythonPath
    if (-not $py) {
        Write-Log 'Pythonが見つかりません。リモコンは起動しません。' Yellow
        return
    }

    # 他の端末から届くようにポートを開けておく。
    # python.exe への既存の許可規則に依存するとネットワークカテゴリ変更で届かなくなる。
    $fwName = 'MovieRemote (TCP 8900)'
    if (-not (Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue)) {
        try {
            New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Action Allow `
                                -Protocol TCP -LocalPort 8900 -Profile Any `
                                -Description '動画リモコン(movie-mode)の受信を許可' `
                                -ErrorAction Stop | Out-Null
            Write-Log 'ファイアウォール: TCP 8900 を許可しました' Green
        } catch {
            Write-Log ('ファイアウォール規則を作れませんでした: ' + $_.Exception.Message) Yellow
        }
    }

    $listening = Get-NetTCPConnection -LocalPort 8900 -State Listen -ErrorAction SilentlyContinue
    if ($listening) {
        Write-Log 'リモコンは既に起動しています (port 8900)' Green
    } else {
        Start-Process $py -ArgumentList ('"{0}"' -f $script) `
                          -WorkingDirectory $ScriptDir -WindowStyle Minimized | Out-Null
        Start-Sleep -Seconds 2
        if (Get-NetTCPConnection -LocalPort 8900 -State Listen -ErrorAction SilentlyContinue) {
            Write-Log 'リモコンを起動しました (port 8900)' Green
        } else {
            Write-Log 'リモコンの起動を確認できませんでした。' Yellow
            return
        }
    }

    $tokenFile = Join-Path $ScriptDir 'remote-token.txt'
    $url = 'http://{0}:8900/' -f $Ip
    if (Test-Path $tokenFile) {
        $t = (Get-Content $tokenFile -Raw).Trim()
        if ($t) { $url += ('?t={0}' -f $t) }
    }
    Write-Host ''
    Write-Host '  ---------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '   リモコン（スマホ/ゲームPCのブラウザで開く）' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('     {0}' -f $url) -ForegroundColor White
    Write-Host '  ---------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
    try { Add-Content -Path (Join-Path $ScriptDir 'remote-url.txt') -Value $url -Encoding UTF8 } catch { }
}

function Get-LanIPv4 {
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.IPAddress -notlike '169.254.*' -and
            $_.IPAddress -ne '127.0.0.1' -and
            $_.InterfaceAlias -notmatch 'Default Switch'
        }
        $best = $ips | Where-Object { $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '10.*' } | Select-Object -First 1
        if ($best) { return $best.IPAddress }
        if ($ips)  { return ($ips | Select-Object -First 1).IPAddress }
    } catch { }
    return '<サーバーIP>'
}

# 移動後にゲームPCから操作できるよう、RDPシャドウを開けておく。
# これをやらないと、移動後は物理キーボード頼みになる。
function Enable-ShadowAccess {
    $ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $ok = $true
    try {
        if (-not (Test-Path $ts)) { New-Item -Path $ts -Force | Out-Null }
        Set-ItemProperty -Path $ts -Name 'Shadow' -Value 2 -Type DWord -ErrorAction Stop
        if ((Get-ItemProperty $ts -Name Shadow).Shadow -eq 2) {
            Write-Log 'シャドウ接続を許可 (Shadow=2 / 同意プロンプトなしフルコントロール)' Green
        } else {
            Write-Log 'シャドウポリシーを設定できませんでした。' Yellow
            $ok = $false
        }
    } catch {
        Write-Log ('シャドウポリシーの設定に失敗: {0}' -f $_.Exception.Message) Yellow
        $ok = $false
    }
    try {
        $r = Get-NetFirewallRule -Name 'RemoteDesktop-Shadow-In-TCP' -ErrorAction Stop
        if ($r.Enabled -ne 'True') {
            Enable-NetFirewallRule -Name 'RemoteDesktop-Shadow-In-TCP' -ErrorAction Stop
            Write-Log 'ファイアウォール: シャドウ受信を有効化' Green
        } else {
            Write-Log 'ファイアウォール: シャドウ受信は有効' Green
        }
    } catch {
        Write-Log 'シャドウ用ファイアウォール規則を確認できませんでした。' Yellow
        $ok = $false
    }
    return $ok
}

# ---------------------------------------------------------------- 事前診断
$sid       = (Get-Process -Id $PID).SessionId
$consoleId = Get-ConsoleSessionId

Write-Log ''
Write-Log '========== 映画モード ==========' Cyan
Write-Log ('現在のセッションID    : {0}' -f $sid)
Write-Log ('コンソールセッションID: {0}' -f $consoleId)
Write-Log ('解像度                : {0}' -f (Get-PrimaryResolution))
Write-Log ('描画アダプタ          : {0}' -f (Get-ActiveAdapter))
Write-Log ''

# DRM黒画面の落とし穴を先に潰す
$hwList = Test-BrowserHwAccel
if ($hwList.Count -eq 0) {
    Write-Log 'ブラウザ設定を読めませんでした。手動で確認してください。' Yellow
}
foreach ($b in $hwList) {
    $mark = if ($b.Running) { '[起動中]' } else { '[未起動]' }
    switch ($b.State) {
        'off' {
            Write-Log ('{0} {1} ハードウェアアクセラレーション OFF (OK)' -f $mark, $b.Browser) Green
        }
        'on' {
            if ($b.Running) {
                Write-Log ('{0} {1} ハードウェアアクセラレーションが ON です。' -f $mark, $b.Browser) Yellow
                Write-Log '        コンソール移動後はGPUが効くため、DRM保護で画面共有が' Yellow
                Write-Log '        黒画面になる可能性があります。設定でOFFにしてください。' Yellow
            } else {
                Write-Log ('{0} {1} ハードウェアアクセラレーション ON（未起動なので影響なし）' -f $mark, $b.Browser) DarkGray
            }
        }
        default {
            if ($b.Running) {
                Write-Log ('{0} {1} ハードウェアアクセラレーションの状態を判定できません。' -f $mark, $b.Browser) DarkGray
                Write-Log '        設定ファイルにキーが無く、既定のままか未保存かを区別できません。' DarkGray
                Write-Log '        確実に確認するならブラウザで設定画面を開いてください。' DarkGray
            }
        }
    }
}
if (($hwList | Where-Object { $_.Running }).Count -eq 0) {
    Write-Log 'ブラウザが起動していません。配信するブラウザを開いてから実行してください。' Yellow
}
Write-Log ''

# 移動後の操作手段を用意する。物理キーボードを不要にするための要。
Write-Log '--- 移動後の操作手段 ---' Cyan
$shadowOk = Enable-ShadowAccess

# mstsc /shadow は IPアドレスを受け付けない（"このコンピューター名は無効です" になる）。
# 必ずコンピューター名を使うこと。
$ip          = Get-LanIPv4
$hostName    = $env:COMPUTERNAME
$connectCmd  = 'mstsc /v:{0} /shadow:{1} /control /noConsentPrompt' -f $hostName, $sid
$connectFile = Join-Path $ScriptDir 'connect-shadow.cmd'
try {
    $body  = "@echo off`r`n"
    $body += "title Shadow $hostName session $sid`r`n"
    $body += "rem mstsc /shadow は IP を受け付けないため、コンピューター名で接続する`r`n"
    $body += "rem 名前解決できない場合は、ゲームPCの hosts に次の行を追加:`r`n"
    $body += "rem   $ip   $hostName`r`n"
    $body += "$connectCmd`r`n"
    $body += "if errorlevel 1 pause`r`n"
    [System.IO.File]::WriteAllText($connectFile, $body, [System.Text.Encoding]::ASCII)
    Write-Log ('接続用バッチを生成: {0}' -f $connectFile) Green
} catch {
    Write-Log ('接続用バッチを作れませんでした: {0}' -f $_.Exception.Message) Yellow
}

if ($hostName -match '_') {
    Write-Log ('注意: ホスト名 "{0}" にアンダースコアが含まれます。' -f $hostName) Yellow
    Write-Log '      DNS的に不正な文字のため名前解決に失敗することがあります。' Yellow
    Write-Log ('      その場合はゲームPCの hosts に "{0}  {1}" を追加してください。' -f $ip, ($hostName -replace '_','')) Yellow
}

$tools = Get-MirrorRemoteTools
if ($tools.Count -gt 0) {
    Write-Log ('ミラー型リモートツールも検出: {0}' -f ($tools -join ', ')) Green
}

Write-Host ''
Write-Host '  ===============================================================' -ForegroundColor Cyan
Write-Host '   移動後、ゲームPCからこのコマンドで操作できます（要メモ）' -ForegroundColor Cyan
Write-Host ''
Write-Host ('     {0}' -f $connectCmd) -ForegroundColor White
Write-Host ''
Write-Host ('   ※ IP({0})では繋がりません。mstsc /shadow はコンピューター名のみ受け付けます' -f $ip) -ForegroundColor DarkGray
Write-Host '   connect-shadow.cmd をゲームPCにコピーしておくと二度手間がない' -ForegroundColor DarkGray
Write-Host '  ===============================================================' -ForegroundColor Cyan
Write-Host ''

if (-not $shadowOk) {
    Write-Log '警告: シャドウの準備が完全ではありません。' Yellow
    Write-Log '      移動後に操作できなくなる可能性があります。中止を推奨。' Yellow
    Write-Log '      (最悪の場合もRDPで繋ぎ直せば元の状態に戻せます)' Yellow
}
Write-Log ''

if ($DryRun) {
    Write-Log ''
    Write-Log '========== ドライラン ==========' Cyan
    Write-Log 'ここまでが事前チェックです。セッションの移動は行いません。' Green
    Write-Log ''
    Write-Log '本番前に確認すべき点:'
    Write-Log '  - ブラウザのハードウェアアクセラレーションがOFFか（上の警告を参照）'
    Write-Log '  - Discordの画面共有を開始してから実行すること'
    Write-Log '  - 配信中はRDPで繋ぎ直さないこと（元の画質に戻ります）'
    Write-Log ''
    Write-Log ('ログ: {0}' -f $LogFile) DarkGray
    Wait-Exit -Seconds 20
    exit
}

# 移動前に起動しておくのが要点。移動後に起動しようとしても操作手段が無い。
if (-not $NoRemote) {
    Write-Log '--- リモコン ---' Cyan
    Start-MovieRemote -Ip $ip
}

# ---------------------------------------------------------------- 移動
if ($sid -eq $consoleId) {
    Write-Log '既にコンソールセッションです。移動は不要。' Green
} else {
    Write-Host ''
    Write-Host '  コンソールセッションへ移動します。RDP接続は切断されます。' -ForegroundColor Yellow
    Write-Host '  (元に戻すには、普通にRDPで接続し直すだけです)' -ForegroundColor DarkGray
    Write-Host ''
    if ($Yes) {
        # ランチャー経由。押し間違い対策に数秒だけ中断の猶予を置く。
        Write-Host '  5秒後に実行します。中止する場合は Ctrl+C' -ForegroundColor Yellow
        foreach ($i in 5..1) {
            Write-Host ("`r  {0}..." -f $i) -NoNewline -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
        Write-Host "`r         "
    } else {
        $ans = Read-Host '  続行しますか? (y/N)'
        if ($ans -ne 'y') {
            Write-Log 'ユーザーが中止しました。' Yellow
            Wait-Exit -Seconds 15
            exit
        }
    }

    Write-Log 'tscon をSYSTEM権限で実行中...'
    & schtasks /create /tn $TaskName /tr "tscon $sid /dest:console" /sc once /st 00:00 /ru SYSTEM /f | Out-Null
    & schtasks /run    /tn $TaskName | Out-Null

    $deadline = (Get-Date).AddSeconds(30)
    $moved = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ((Get-ConsoleSessionId) -eq $sid) { $moved = $true; break }
    }
    & schtasks /delete /tn $TaskName /f | Out-Null

    if ($moved) {
        Write-Log 'コンソールセッションへ移動しました。' Green
    } else {
        Write-Log '30秒待ちましたが移動を確認できませんでした。' Red
        Write-Log 'tscon が権限で弾かれた可能性があります。物理モニタからの手動ログインで代替してください。' Red
        Wait-Exit -Seconds 15
        exit
    }
}

# ---------------------------------------------------------------- 移動後
Start-Sleep -Seconds 3
Write-Log ''
Write-Log '---------- 移動後の状態 ----------' Cyan
Write-Log ('解像度       : {0}' -f (Get-PrimaryResolution))
Write-Log ('描画アダプタ : {0}' -f (Get-ActiveAdapter))
Write-Log ''

if ($RestartDiscord) {
    $d = Get-Process Discord -ErrorAction SilentlyContinue
    if ($d) {
        Write-Log 'Discordを再起動します（キャプチャをNVIDIAアダプタに再バインドするため）...'
        Write-Log '※ 配信は切れます。移動後に張り直してください。' Yellow
        $d | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $upd = "$env:LOCALAPPDATA\Discord\Update.exe"
        if (Test-Path $upd) {
            Start-Process $upd -ArgumentList '--processStart', 'Discord.exe'
            Write-Log 'Discordを起動しました。' Green
        } else {
            Write-Log ('Update.exe が見つかりません: {0}' -f $upd) Yellow
            Write-Log '手動でDiscordを起動してください。' Yellow
        }
    } else {
        Write-Log 'Discordは起動していません。手動で起動してください。' Yellow
    }
} else {
    Write-Log 'Discordはそのまま維持しました（配信を張ったまま移行）。' Green
    Write-Log '映像が固まる/黒くなる場合のみ -RestartDiscord を付けて実行してください。' DarkGray
}

Write-Log ''
Write-Log '========== 状態 ==========' Cyan
Write-Log '  配信を張ったまま移行しました。友達側の映像はそのまま続いているはずです。'
Write-Log '  解像度とフレームレートの取りこぼしが解消された状態になります。'
Write-Log ''
Write-Log '  戻すとき : ゲームPCから普通にRDPで接続し直すだけ'
Write-Log '  再開する : このランチャーをもう一度実行'
Write-Log ''
Write-Log '  ※ RDPで繋ぎ直すとセッションがRDP側へ戻り、元の画質に戻ります。' Yellow
Write-Log '     映画を配信している間はRDPで入らないこと。' Yellow
Write-Log ''
Write-Log ('ログ: {0}' -f $LogFile) DarkGray
Wait-Exit -Seconds 3
