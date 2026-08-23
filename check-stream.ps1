<#
.SYNOPSIS
    配信状態の実測。NVENCが乗っているか、解像度は正しいかを判定する。

.DESCRIPTION
    Discordで画面共有を開始した状態で実行すること。
    NVENC Active Sessions が 1 以上なら成功（GPUエンコード）。
    0 のままでDiscordのCPUが張り付いていればソフトエンコード＝失敗。

.NOTES
    管理者権限は不要。
#>
[CmdletBinding()]
param(
    [int]$SampleSeconds = 6
)

function Write-Section { param([string]$T) Write-Host ''; Write-Host ('===== {0} =====' -f $T) -ForegroundColor Cyan }

# 映画モード中（コンソールセッション）に実行した結果を後から読めるよう記録する。
# RDPで繋ぎ直すとセッションがRDP側へ戻ってしまい、その場では確認できないため。
$LogFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'check-stream.log'
try { Start-Transcript -Path $LogFile -Append -Force | Out-Null } catch { }
Write-Host ('計測日時: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray

if (-not ('Native.Wts2' -as [type])) {
    Add-Type -Name Wts2 -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint WTSGetActiveConsoleSessionId();
'@
}
Add-Type -AssemblyName System.Windows.Forms

function Get-NvidiaSmi {
    $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $paths = @(
        "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
        "$env:SystemRoot\System32\nvidia-smi.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $null
}

# ---------------------------------------------------------------- セッション
Write-Section 'セッション'
$sid       = (Get-Process -Id $PID).SessionId
$consoleId = [int][Native.Wts2]::WTSGetActiveConsoleSessionId()
$bounds    = ([System.Windows.Forms.Screen]::AllScreens)[0].Bounds
$res       = '{0}x{1}' -f $bounds.Width, $bounds.Height

$adapter = '(判定不能)'
try {
    $vc = Get-CimInstance Win32_VideoController -ErrorAction Stop |
          Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
    if ($vc) { $adapter = $vc.Name }
} catch { }

$onConsole = ($sid -eq $consoleId)
Write-Host ('  セッションID : {0}  (コンソール: {1})' -f $sid, $consoleId)
Write-Host ('  種別         : ' ) -NoNewline
if ($onConsole) { Write-Host 'コンソール (OK)' -ForegroundColor Green }
else            { Write-Host 'RDPセッション (キャプチャがソフトアダプタ経由)' -ForegroundColor Yellow }

Write-Host ('  解像度       : ') -NoNewline
if ($res -eq '1920x1080') { Write-Host $res -ForegroundColor Green }
else                      { Write-Host ('{0}  <- 1920x1080 が理想' -f $res) -ForegroundColor Yellow }

Write-Host ('  描画アダプタ : ') -NoNewline
if ($adapter -match 'Remote Display') { Write-Host $adapter -ForegroundColor Red }
else                                  { Write-Host $adapter -ForegroundColor Green }

# ---------------------------------------------------------------- NVENC
Write-Section 'NVENC (GPUエンコーダ)'
$smi = Get-NvidiaSmi
$encSessions = -1
$discordOnGpu = $false
if (-not $smi) {
    Write-Host '  nvidia-smi が見つかりません。' -ForegroundColor Yellow
} else {
    $stats = & $smi -q -d ENCODER_STATS 2>$null
    $m = $stats | Select-String 'Active Sessions\s*:\s*(\d+)' | Select-Object -First 1
    if ($m) { $encSessions = [int]$m.Matches[0].Groups[1].Value }

    $fpsM = $stats | Select-String 'Average FPS\s*:\s*(\d+)' | Select-Object -First 1
    $encFps = 0
    if ($fpsM) { $encFps = [int]$fpsM.Matches[0].Groups[1].Value }

    $util = & $smi --query-gpu=utilization.gpu,utilization.encoder --format=csv,noheader 2>$null

    Write-Host ('  Active Sessions : ') -NoNewline
    if ($encSessions -gt 0) { Write-Host $encSessions -ForegroundColor Green }
    else                    { Write-Host '0  <- ハードウェアエンコード未使用' -ForegroundColor Red }
    Write-Host ('  Average FPS     : {0}   (GeForceでは常に0。判定材料にならない)' -f $encFps) -ForegroundColor DarkGray
    Write-Host ('  GPU / Encoder   : {0}' -f $util)

    # nvidia-smi はNVENCセッションの持ち主PIDを出さないため、
    # DiscordがGPUコンテキストを持っているかで裏を取る
    $gpuApps = & $smi --query-compute-apps=pid --format=csv,noheader 2>$null
    $gpuPids = @()
    foreach ($line in $gpuApps) {
        $t = ($line -split ',')[0].Trim()
        if ($t -match '^\d+$') { $gpuPids += [int]$t }
    }
    $dPids = @((Get-Process Discord -ErrorAction SilentlyContinue).Id)
    foreach ($dp in $dPids) { if ($gpuPids -contains $dp) { $discordOnGpu = $true; break } }

    Write-Host '  Discord on GPU  : ' -NoNewline
    if ($discordOnGpu) { Write-Host 'yes' -ForegroundColor Green }
    else               { Write-Host 'no  <- NVENCセッションは別プロセスの可能性' -ForegroundColor Yellow }
}

# ---------------------------------------------------------------- Discord
Write-Section ('Discord CPU ({0}秒サンプリング)' -f $SampleSeconds)
$p1 = Get-Process Discord -ErrorAction SilentlyContinue | Select-Object Id, CPU
if (-not $p1) {
    Write-Host '  Discordが起動していません。' -ForegroundColor Yellow
    $topPct = 0
} else {
    Start-Sleep -Seconds $SampleSeconds
    $p2 = Get-Process Discord -ErrorAction SilentlyContinue | Select-Object Id, CPU
    $topPct = 0
    foreach ($a in $p1) {
        $b = $p2 | Where-Object Id -eq $a.Id
        if (-not $b) { continue }
        $pct = [math]::Round((($b.CPU - $a.CPU) / $SampleSeconds) * 100, 0)
        if ($pct -gt $topPct) { $topPct = $pct }
        if ($pct -ge 5) { Write-Host ('  PID {0,-6} {1,4}% of one core' -f $a.Id, $pct) }
    }
    Write-Host ('  最大: {0}% of one core' -f $topPct)
}

# ---------------------------------------------------------------- 判定
Write-Section '判定'
if ($encSessions -gt 0 -and $discordOnGpu) {
    Write-Host '  NVENCが動作中で、DiscordもGPUコンテキストを持っています。' -ForegroundColor Green
    if (-not $onConsole) {
        Write-Host '  ただしRDPセッションのままです。キャプチャ元が Remote Display Adapter なので、' -ForegroundColor Yellow
        Write-Host '  フレームレートと解像度に上限が残ります（エンコードだけGPUに乗った状態）。' -ForegroundColor Yellow
    }
    if ($res -ne '1920x1080') {
        Write-Host ('  解像度が {0} です。1920x1080にすると非整数スケールが1段消えます。' -f $res) -ForegroundColor Yellow
    }
    if ($onConsole -and $res -eq '1920x1080') {
        Write-Host '  理想状態です。これ以上はDiscordとDRMの上限。' -ForegroundColor Green
    }
} elseif ($encSessions -gt 0) {
    Write-Host '  注意: NVENCは動いていますが、DiscordはGPUを掴んでいません。' -ForegroundColor Yellow
    Write-Host '        別プロセスのエンコードを拾っている可能性があります。' -ForegroundColor Yellow
} elseif ($encSessions -eq 0 -and $topPct -ge 20) {
    Write-Host '  NG: ソフトウェアエンコード中です。' -ForegroundColor Red
    if (-not $onConsole) {
        Write-Host '     原因: RDPセッションのため。movie-mode.ps1 でコンソールへ移動してください。' -ForegroundColor Red
    } else {
        Write-Host '     コンソール上なのにNVENCが乗っていません。' -ForegroundColor Red
        Write-Host '     Discord設定 > 音声・ビデオ > H.264ハードウェアアクセラレーション を確認。' -ForegroundColor Red
        Write-Host '     Discordを再起動すると拾い直すことがあります。' -ForegroundColor Red
    }
} elseif ($encSessions -eq 0) {
    Write-Host '  配信が動いていないようです（Discordのエンコード負荷が検出されません）。' -ForegroundColor Yellow
    Write-Host '  画面共有を開始した状態で実行してください。' -ForegroundColor Yellow
} else {
    Write-Host '  NVENCの状態を取得できませんでした。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host ('記録先: {0}' -f $LogFile) -ForegroundColor DarkGray
try { Stop-Transcript | Out-Null } catch { }
Read-Host 'Enterで終了'
