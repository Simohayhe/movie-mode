#!/usr/bin/env python3
"""
movie-remote - サーバー機の動画再生をLAN内の別端末から操作するリモコン

映画モード（コンソールセッション）に移ると、サーバー機を直接操作する手段が無くなる。
このスクリプトを移行前に起動しておくと、セッションと一緒にコンソール側へ移動し、
スマホやゲームPCのブラウザから再生・停止・音量などを送れるようになる。

標準ライブラリのみ。追加パッケージ不要。

    python movie-remote.py             起動（既定ポート 8900）
    python movie-remote.py --port 9000
    python movie-remote.py --token     トークン認証を有効にする
    python movie-remote.py --any-source  同一サブネット以外からの接続も受け付ける

既定ではトークンなしで動く。URLを控えたりコピーしたりせずに
`http://<このPCのIP>:8900/` を開くだけで使えるようにするため。

その代わり、既定では**同一サブネットからの接続のみ**を受け付ける。
うっかりポート開放してしまった場合に外から操作されるのを防ぐための保険で、
LAN内での使用感は変わらない。
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
import time
import urllib.parse
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE = os.path.join(BASE_DIR, "remote-token.txt")
SITES_FILE = os.path.join(BASE_DIR, "sites.json")

DEFAULT_SITES = [
    {"name": "Netflix",   "url": "https://www.netflix.com/"},
    {"name": "U-NEXT",    "url": "https://video.unext.jp/"},
    {"name": "Prime",     "url": "https://www.amazon.co.jp/gp/video/storefront"},
    {"name": "Disney+",   "url": "https://www.disneyplus.com/"},
    {"name": "ABEMA",     "url": "https://abema.tv/"},
    {"name": "YouTube",   "url": "https://www.youtube.com/"},
]

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
shell32 = ctypes.WinDLL("shell32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

KEYEVENTF_KEYUP = 0x0002
CREATE_NO_WINDOW = 0x08000000
TASK_NAME = "MovieMode-ToConsole"

# 仮想キーコード
VK = {
    "playpause": 0xB3,
    "next":      0xB0,
    "prev":      0xB1,
    "stop":      0xB2,
    "volup":     0xAF,
    "voldown":   0xAE,
    "mute":      0xAD,
    "space":     0x20,
    "left":      0x25,
    "right":     0x27,
    "up":        0x26,
    "down":      0x28,
    "f":         0x46,
    "esc":       0x1B,
}

# ブラウザにフォーカスを当ててから送るキー。
# メディアキーはグローバルに届くが、矢印キー等は前面ウィンドウにしか届かないため。
NEEDS_FOCUS = {"space", "left", "right", "up", "down", "f", "esc"}

# 押した回数で送る（seek は連打で調整する）
REPEATS = {"seekfwd": ("right", 1), "seekback": ("left", 1)}


def tap(vk: int, times: int = 1) -> None:
    for _ in range(times):
        user32.keybd_event(vk, 0, 0, 0)
        user32.keybd_event(vk, 0, KEYEVENTF_KEYUP, 0)


def focus_browser() -> str | None:
    """Chromium系ウィンドウ（Brave/Chrome/Edge）を前面に出す。"""
    found: list[tuple[int, str]] = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd):
            return True
        buf = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, buf, 256)
        if buf.value != "Chrome_WidgetWin_1":
            return True
        n = user32.GetWindowTextLengthW(hwnd)
        if n <= 0:
            return True
        title = ctypes.create_unicode_buffer(n + 1)
        user32.GetWindowTextW(hwnd, title, n + 1)
        found.append((hwnd, title.value))
        return True

    user32.EnumWindows(cb, 0)
    if not found:
        return None

    hwnd, title = found[0]
    try:
        user32.ShowWindow(hwnd, 9)          # SW_RESTORE
        user32.SetForegroundWindow(hwnd)
    except Exception:
        pass
    return title


def do_action(action: str) -> dict:
    if action in REPEATS:
        key, times = REPEATS[action]
        target = focus_browser()
        if target is None:
            return {"ok": False, "message": "ブラウザのウィンドウが見つかりません"}
        tap(VK[key], times)
        return {"ok": True, "message": f"{action} -> {target[:40]}"}

    if action not in VK:
        return {"ok": False, "message": f"不明な操作: {action}"}

    target = None
    if action in NEEDS_FOCUS:
        target = focus_browser()
        if target is None:
            return {"ok": False, "message": "ブラウザのウィンドウが見つかりません"}

    tap(VK[action])
    return {"ok": True, "message": action + (f" -> {target[:40]}" if target else "")}


# ------------------------------------------------------- 画面取り込み / 入力
SRCCOPY = 0x00CC0020
HALFTONE = 4

MOUSEEVENTF = {
    "leftdown": 0x0002, "leftup": 0x0004,
    "rightdown": 0x0008, "rightup": 0x0010,
    "wheel": 0x0800,
}

ULONG_PTR = ctypes.c_ulonglong if ctypes.sizeof(ctypes.c_void_p) == 8 else ctypes.c_ulong


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG),
        ("biPlanes", wt.WORD), ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
        ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", wt.LONG),
        ("biYPelsPerMeter", wt.LONG), ("biClrUsed", wt.DWORD), ("biClrImportant", wt.DWORD),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD),
                ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wt.DWORD), ("u", _INPUTUNION)]


def png_encode(rgb: bytes, w: int, h: int) -> bytes:
    """PNGを自前で組み立てる。標準ライブラリにJPEGエンコーダが無いため。"""
    stride = w * 3
    raw = b"".join(b"\x00" + rgb[y * stride:(y + 1) * stride] for y in range(h))
    comp = zlib.compress(raw, 6)

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8bit truecolor
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", comp) + chunk(b"IEND", b""))


def capture_png(max_w: int = 960):
    """デスクトップを縮小して取り込み、PNGバイト列と実解像度を返す。"""
    sw = user32.GetSystemMetrics(0)
    sh = user32.GetSystemMetrics(1)
    if sw <= 0 or sh <= 0:
        return None, (0, 0)
    scale = min(1.0, max_w / float(sw))
    w = max(1, int(sw * scale))
    h = max(1, int(sh * scale))

    hdc = user32.GetDC(0)
    memdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    old = gdi32.SelectObject(memdc, bmp)
    try:
        gdi32.SetStretchBltMode(memdc, HALFTONE)
        gdi32.StretchBlt(memdc, 0, 0, w, h, hdc, 0, 0, sw, sh, SRCCOPY)

        bi = BITMAPINFOHEADER()
        bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        bi.biWidth = w
        bi.biHeight = -h          # 上下反転を避けるため負値（トップダウン）
        bi.biPlanes = 1
        bi.biBitCount = 32
        bi.biCompression = 0

        buf = ctypes.create_string_buffer(w * h * 4)
        gdi32.GetDIBits(memdc, bmp, 0, h, buf, ctypes.byref(bi), 0)
        src = buf.raw

        # BGRA -> RGB。ステップ付きスライス代入はC側で回るので十分速い
        rgb = bytearray(w * h * 3)
        rgb[0::3] = src[2::4]
        rgb[1::3] = src[1::4]
        rgb[2::3] = src[0::4]
    finally:
        gdi32.SelectObject(memdc, old)
        gdi32.DeleteObject(bmp)
        gdi32.DeleteDC(memdc)
        user32.ReleaseDC(0, hdc)

    return png_encode(bytes(rgb), w, h), (sw, sh)


def do_mouse(action: str, x=None, y=None, amount: int = 0) -> dict:
    """xとyは実スクリーン座標。"""
    try:
        if x is not None and y is not None:
            user32.SetCursorPos(int(x), int(y))
        if action == "move":
            return {"ok": True, "message": "move"}
        if action == "left":
            user32.mouse_event(MOUSEEVENTF["leftdown"], 0, 0, 0, 0)
            user32.mouse_event(MOUSEEVENTF["leftup"], 0, 0, 0, 0)
        elif action == "double":
            for _ in range(2):
                user32.mouse_event(MOUSEEVENTF["leftdown"], 0, 0, 0, 0)
                user32.mouse_event(MOUSEEVENTF["leftup"], 0, 0, 0, 0)
                time.sleep(0.05)
        elif action == "right":
            user32.mouse_event(MOUSEEVENTF["rightdown"], 0, 0, 0, 0)
            user32.mouse_event(MOUSEEVENTF["rightup"], 0, 0, 0, 0)
        elif action == "scroll":
            user32.mouse_event(MOUSEEVENTF["wheel"], 0, 0, int(amount), 0)
        else:
            return {"ok": False, "message": "不明な操作: " + action}
        return {"ok": True, "message": action}
    except Exception as e:
        return {"ok": False, "message": str(e)}


def type_text(text: str) -> dict:
    """Unicodeで直接送るので日本語もそのまま入力できる。"""
    if not text:
        return {"ok": False, "message": "文字が空です"}
    try:
        for ch in text[:500]:
            for flags in (0x0004, 0x0004 | 0x0002):   # UNICODE, UNICODE|KEYUP
                inp = INPUT(type=1, u=_INPUTUNION(ki=KEYBDINPUT(0, ord(ch), flags, 0, 0)))
                user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
            time.sleep(0.004)
        return {"ok": True, "message": "入力しました: " + text[:30]}
    except Exception as e:
        return {"ok": False, "message": str(e)}


# ------------------------------------------------------------ サイトを開く
def load_sites() -> list:
    """sites.json が無ければ既定値で作る。ユーザーが編集できるようにするため。"""
    if not os.path.exists(SITES_FILE):
        try:
            with open(SITES_FILE, "w", encoding="utf-8") as f:
                json.dump(DEFAULT_SITES, f, ensure_ascii=False, indent=2)
        except Exception:
            return DEFAULT_SITES
    try:
        with open(SITES_FILE, encoding="utf-8") as f:
            data = json.load(f)
        return [s for s in data if s.get("name") and s.get("url")]
    except Exception:
        return DEFAULT_SITES


def open_site(url: str) -> dict:
    """
    URLを既定のブラウザで開く。

    リモコンは昇格状態で常駐しているため、そのまま起動すると
    ブラウザまで昇格して動いてしまう(プロファイルやDRMの扱いが変わる)。
    explorer.exe を経由すると通常の整合性レベルで開かれる。
    """
    if not (url.startswith("http://") or url.startswith("https://")):
        return {"ok": False, "message": "http/https のURLのみ開けます"}
    try:
        subprocess.Popen(["explorer.exe", url], creationflags=CREATE_NO_WINDOW)
        time.sleep(1.5)
        focus_browser()
        return {"ok": True, "message": "開きました: " + url}
    except Exception as e:
        return {"ok": False, "message": str(e)}


# ------------------------------------------------------------ セッション操作
class DISPLAY_DEVICE(ctypes.Structure):
    _fields_ = [
        ("cb", wt.DWORD),
        ("DeviceName", ctypes.c_wchar * 32),
        ("DeviceString", ctypes.c_wchar * 128),
        ("StateFlags", wt.DWORD),
        ("DeviceID", ctypes.c_wchar * 128),
        ("DeviceKey", ctypes.c_wchar * 128),
    ]


def is_admin() -> bool:
    try:
        return bool(shell32.IsUserAnAdmin())
    except Exception:
        return False


def adapter_name() -> str:
    dd = DISPLAY_DEVICE()
    dd.cb = ctypes.sizeof(DISPLAY_DEVICE)
    if user32.EnumDisplayDevicesW(None, 0, ctypes.byref(dd), 0):
        return dd.DeviceString
    return "(不明)"


def session_info() -> dict:
    sid = wt.DWORD()
    kernel32.ProcessIdToSessionId(kernel32.GetCurrentProcessId(), ctypes.byref(sid))
    console = int(kernel32.WTSGetActiveConsoleSessionId())
    w = user32.GetSystemMetrics(0)
    h = user32.GetSystemMetrics(1)
    ad = adapter_name()
    return {
        "session_id": int(sid.value),
        "console_id": console,
        "on_console": int(sid.value) == console,
        "resolution": f"{w}x{h}",
        "adapter": ad,
        "is_admin": is_admin(),
        "ideal": (int(sid.value) == console) and w == 1920 and h == 1080,
    }


def _run(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True,
                          creationflags=CREATE_NO_WINDOW)


def switch_to_console() -> dict:
    """
    セッションをコンソールへ移す。tscon はSYSTEM権限が要るため、
    schtasksでSYSTEMタスクを作って実行する。この関数自体も昇格状態で動く必要がある。
    """
    info = session_info()
    if info["on_console"]:
        return {"ok": True, "message": "既にコンソールセッションです", "info": info}
    if not info["is_admin"]:
        return {"ok": False,
                "message": "管理者権限で動いていません。install-autostart.ps1 で常駐登録してください",
                "info": info}

    sid = info["session_id"]
    r = _run(["schtasks", "/create", "/tn", TASK_NAME,
              "/tr", f"tscon {sid} /dest:console",
              "/sc", "once", "/st", "00:00", "/ru", "SYSTEM", "/f"])
    if r.returncode != 0:
        return {"ok": False, "message": f"タスク作成に失敗: {r.stderr.strip()[:200]}", "info": info}

    _run(["schtasks", "/run", "/tn", TASK_NAME])

    for _ in range(60):
        time.sleep(0.5)
        if int(kernel32.WTSGetActiveConsoleSessionId()) == sid:
            _run(["schtasks", "/delete", "/tn", TASK_NAME, "/f"])
            time.sleep(2)
            return {"ok": True, "message": "コンソールセッションへ移動しました",
                    "info": session_info()}

    _run(["schtasks", "/delete", "/tn", TASK_NAME, "/f"])
    return {"ok": False, "message": "30秒待っても移動を確認できませんでした", "info": info}


# --------------------------------------------------------------------- Web UI
PAGE = r"""<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Movie Remote</title>
<style>
:root{--bg:#0f1115;--panel:#1b1f27;--line:#2b3038;--fg:#e8eaee;--dim:#8b93a1;--accent:#5b9dff}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,"Segoe UI",sans-serif;
padding:18px;max-width:520px;margin:0 auto}
h1{font-size:15px;color:var(--dim);font-weight:500;margin:0 0 14px;letter-spacing:.04em}
.grid{display:grid;gap:10px}
.g3{grid-template-columns:repeat(3,1fr)}
.g2{grid-template-columns:repeat(2,1fr)}
button{background:var(--panel);color:var(--fg);border:1px solid var(--line);border-radius:12px;
padding:20px 8px;font:inherit;font-size:15px;cursor:pointer;transition:.08s;user-select:none}
button:active{background:#2a3040;border-color:var(--accent);transform:scale(.97)}
button.big{padding:30px 8px;font-size:19px;font-weight:600}
.sec{margin:18px 0 8px;font-size:12px;color:var(--dim);letter-spacing:.08em;text-transform:uppercase}
#msg{margin-top:16px;min-height:22px;font-size:13px;color:var(--dim);word-break:break-all}
.status{background:var(--panel);border:1px solid var(--line);border-radius:10px;
padding:12px 14px;margin-bottom:12px;font-size:13px;line-height:1.8}
.status.ok{border-color:#3f7a55}
.status.warn{border-color:#7a6a3f}
.dim{color:var(--dim)}
button.go{background:#1f2f45;border-color:#3d5a80}
#shot{width:100%;height:auto;display:block;border:1px solid var(--line);
border-radius:10px;background:#000;cursor:crosshair;touch-action:manipulation}
#screenWrap{margin-top:10px}
.hint{font-size:12px;color:var(--dim);margin:8px 2px}
</style></head><body>
<h1>MOVIE REMOTE</h1>

<div id="status" class="status">状態を取得中...</div>
<div class="grid g2">
  <button class="big go" onclick="toConsole()">🎬 映画モードにする</button>
  <button onclick="loadStatus()">↻ 状態を更新</button>
</div>

<div class="grid g2">
  <button class="big" onclick="k('playpause')">⏯ 再生 / 一時停止</button>
  <button class="big" onclick="k('space')">␣ スペース</button>
</div>

<div class="sec">配信サービスを開く</div>
<div class="grid g3" id="sites"></div>

<div class="sec">画面を見て操作する</div>
<div class="grid g3">
  <button id="btnScreen" onclick="toggleScreen()">📺 画面を表示</button>
  <button onclick="wheel(360)">▲ スクロール</button>
  <button onclick="wheel(-360)">▼ スクロール</button>
</div>
<div id="screenWrap" style="display:none">
  <img id="shot" alt="画面">
  <div class="hint">画面をタップするとその位置をクリックします。ピンチで拡大できます。</div>
  <div class="grid g3">
    <button id="btnMode" onclick="cycleMode()">クリック: 左</button>
    <button onclick="shoot()">↻ 今すぐ更新</button>
    <button id="btnRate" onclick="cycleRate()">更新: 1.5秒</button>
  </div>
  <div class="grid g2" style="margin-top:10px">
    <input id="typeText" placeholder="検索したい語を入力">
    <button onclick="sendText()">⌨ 送信</button>
  </div>
</div>

<div class="sec">シーク</div>
<div class="grid g2">
  <button onclick="k('seekback')">⏪ 戻る</button>
  <button onclick="k('seekfwd')">⏩ 進む</button>
</div>

<div class="sec">音量</div>
<div class="grid g3">
  <button onclick="k('voldown')">🔉 −</button>
  <button onclick="k('mute')">🔇 ミュート</button>
  <button onclick="k('volup')">🔊 ＋</button>
</div>

<div class="sec">表示</div>
<div class="grid g2">
  <button onclick="k('f')">⛶ 全画面</button>
  <button onclick="k('esc')">⎋ 解除</button>
</div>

<div class="sec">トラック</div>
<div class="grid g2">
  <button onclick="k('prev')">⏮ 前</button>
  <button onclick="k('next')">⏭ 次</button>
</div>

<div id="msg"></div>
<script>
const T = new URLSearchParams(location.search).get('t') || '';
function msg(t){ document.getElementById('msg').textContent = t; }
async function k(a){
  try{
    const r = await fetch('/k/'+a+'?t='+encodeURIComponent(T), {method:'POST'});
    const j = await r.json();
    msg((j.ok ? '✓ ' : '✕ ') + j.message);
  }catch(e){ msg('✕ ' + e.message); }
}
async function loadStatus(){
  const el = document.getElementById('status');
  try{
    const r = await fetch('/status?t='+encodeURIComponent(T));
    const s = await r.json();
    if(s.error){ el.className='status warn'; el.textContent = s.error; return; }
    el.className = 'status ' + (s.ideal ? 'ok' : 'warn');
    let h = (s.on_console ? '✓ コンソールセッション' : '△ RDPセッション（画質が落ちた状態）')
          + '<br><span class="dim">' + s.resolution + ' · ' + s.adapter + '</span>';
    if(!s.is_admin) h += '<br><span class="dim">※ 非管理者で動作中 — セッション切り替えは使えません</span>';
    el.innerHTML = h;
  }catch(e){ el.className='status warn'; el.textContent = '状態を取得できません: ' + e.message; }
}
async function toConsole(){
  if(!confirm('コンソールセッションへ移動します。\n\nRDP接続は切断されますが、Discordの配信は継続します。\n実行しますか?')) return;
  msg('移動中... 最大30秒かかります');
  try{
    const r = await fetch('/session/console?t='+encodeURIComponent(T), {method:'POST'});
    const j = await r.json();
    msg((j.ok ? '✓ ' : '✕ ') + j.message);
  }catch(e){ msg('✕ ' + e.message); }
  loadStatus();
}
async function loadSites(){
  try{
    const r = await fetch('/sites?t='+encodeURIComponent(T));
    const list = await r.json();
    document.getElementById('sites').innerHTML = list.map(s =>
      `<button onclick="openSite('${s.url.replace(/'/g,"\\'")}','${s.name.replace(/'/g,"\\'")}')">${s.name}</button>`
    ).join('');
  }catch(e){ /* 一覧が出せなくても他の操作には影響させない */ }
}
async function openSite(url, name){
  msg(name + ' を開いています...');
  try{
    const r = await fetch('/open?t='+encodeURIComponent(T), {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({url: url})
    });
    const j = await r.json();
    msg((j.ok ? '✓ ' : '✕ ') + j.message);
  }catch(e){ msg('✕ ' + e.message); }
}
// ---- 画面表示とマウス操作 ----
let shotTimer = null, mode = 'left', rate = 1500;
const MODES = {left:'左', right:'右', double:'ダブル'};
const RATES = [1500, 3000, 6000, 800];

function shoot(){
  const img = document.getElementById('shot');
  img.src = '/screen.png?w=960&t=' + encodeURIComponent(T) + '&_=' + Date.now();
}
function toggleScreen(){
  const wrap = document.getElementById('screenWrap');
  const btn = document.getElementById('btnScreen');
  if(shotTimer){
    clearInterval(shotTimer); shotTimer = null;
    wrap.style.display = 'none'; btn.textContent = '📺 画面を表示';
  }else{
    wrap.style.display = 'block'; btn.textContent = '⏹ 画面を停止';
    shoot(); shotTimer = setInterval(shoot, rate);
  }
}
function cycleMode(){
  mode = mode === 'left' ? 'right' : (mode === 'right' ? 'double' : 'left');
  document.getElementById('btnMode').textContent = 'クリック: ' + MODES[mode];
}
function cycleRate(){
  rate = RATES[(RATES.indexOf(rate) + 1) % RATES.length];
  document.getElementById('btnRate').textContent = '更新: ' + (rate/1000) + '秒';
  if(shotTimer){ clearInterval(shotTimer); shotTimer = setInterval(shoot, rate); }
}
async function mouse(body){
  try{
    const r = await fetch('/mouse?t='+encodeURIComponent(T), {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify(body)
    });
    const j = await r.json();
    if(!j.ok) msg('✕ ' + j.message);
    setTimeout(shoot, 350);   // 操作結果をすぐ見たい
  }catch(e){ msg('✕ ' + e.message); }
}
function wheel(amount){ mouse({action:'scroll', amount:amount}); }
document.getElementById('shot').addEventListener('click', function(ev){
  const r = ev.target.getBoundingClientRect();
  const nx = (ev.clientX - r.left) / r.width;
  const ny = (ev.clientY - r.top) / r.height;
  if(nx < 0 || nx > 1 || ny < 0 || ny > 1) return;
  mouse({action: mode, nx: nx, ny: ny});
});
async function sendText(){
  const el = document.getElementById('typeText');
  if(!el.value) return;
  try{
    const r = await fetch('/type?t='+encodeURIComponent(T), {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({text: el.value})
    });
    const j = await r.json();
    msg((j.ok ? '✓ ' : '✕ ') + j.message);
    el.value = '';
    setTimeout(shoot, 400);
  }catch(e){ msg('✕ ' + e.message); }
}

loadStatus();
loadSites();
setInterval(loadStatus, 15000);
</script></body></html>
"""


class Handler(BaseHTTPRequestHandler):
    token = ""
    host_ip = "127.0.0.1"
    any_source = False

    def log_message(self, *a):
        pass

    def _source_ok(self) -> bool:
        if self.any_source:
            return True
        return same_subnet(self.client_address[0], self.host_ip)

    def _send(self, obj, code=200, ctype="application/json; charset=utf-8"):
        raw = obj if isinstance(obj, bytes) else json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _authed(self, q) -> bool:
        if not self._source_ok():
            return False
        if not self.token:
            return True
        return q.get("t", [""])[0] == self.token

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/":
            if not self._source_ok():
                return self._send({"error": "このネットワークからは利用できません"}, 403)
            self._send(PAGE.encode(), 200, "text/html; charset=utf-8")
        elif u.path == "/status":
            if not self._authed(q):
                return self._send({"error": "このネットワークからは利用できません"}, 403)
            try:
                self._send(session_info())
            except Exception as e:
                self._send({"error": str(e)}, 500)
        elif u.path == "/sites":
            if not self._authed(q):
                return self._send([], 403)
            self._send(load_sites())
        elif u.path == "/screen.png":
            if not self._authed(q):
                return self._send({"error": "利用できません"}, 403)
            try:
                width = int(q.get("w", ["960"])[0])
            except ValueError:
                width = 960
            width = max(320, min(1920, width))
            try:
                png, _ = capture_png(width)
                if png is None:
                    return self._send({"error": "取り込めません"}, 500)
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(png)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(png)
            except Exception as e:
                self._send({"error": str(e)}, 500)
        else:
            self._send({"ok": False, "message": "not found"}, 404)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if not self._authed(q):
            return self._send({"ok": False, "message": "トークンが違います"}, 403)
        try:
            if u.path == "/session/console":
                self._send(switch_to_console())
            elif u.path == "/open":
                n = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(n) or b"{}")
                self._send(open_site(body.get("url", "")))
            elif u.path == "/mouse":
                n = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(n) or b"{}")
                sw = user32.GetSystemMetrics(0)
                sh = user32.GetSystemMetrics(1)
                x = y = None
                # クライアントは 0..1 の正規化座標を送る。画面解像度を知らなくて済む。
                if "nx" in body and "ny" in body:
                    x = int(float(body["nx"]) * sw)
                    y = int(float(body["ny"]) * sh)
                self._send(do_mouse(body.get("action", "left"), x, y,
                                    int(body.get("amount", 0))))
            elif u.path == "/type":
                n = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(n) or b"{}")
                self._send(type_text(body.get("text", "")))
            elif u.path.startswith("/k/"):
                self._send(do_action(u.path[3:]))
            else:
                self._send({"ok": False, "message": "not found"}, 404)
        except Exception as e:
            self._send({"ok": False, "message": str(e)}, 500)


def same_subnet(client_ip: str, host_ip: str) -> bool:
    """クライアントが同一 /24 か、ループバックかを判定する。"""
    if client_ip in ("127.0.0.1", "::1"):
        return True
    try:
        return client_ip.rsplit(".", 1)[0] == host_ip.rsplit(".", 1)[0]
    except Exception:
        return False


def lan_ip() -> str:
    try:
        # UDPのconnectは実際にはパケットを出さない。
        # 外向きに使われるインターフェースのアドレスを得るための定石。
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def get_token(enabled: bool) -> str:
    if not enabled:
        return ""
    if os.path.exists(TOKEN_FILE):
        t = open(TOKEN_FILE, encoding="utf-8").read().strip()
        if t:
            return t
    t = secrets.token_urlsafe(9)
    with open(TOKEN_FILE, "w", encoding="utf-8") as f:
        f.write(t)
    return t


def main():
    ap = argparse.ArgumentParser(description="動画再生リモコン")
    ap.add_argument("--port", type=int, default=8900)
    ap.add_argument("--token", action="store_true",
                    help="トークン認証を有効にする（既定は無効）")
    ap.add_argument("--any-source", action="store_true",
                    help="同一サブネット以外からの接続も受け付ける（非推奨）")
    # 旧オプション。既定が「トークンなし」になったため何もしない。
    ap.add_argument("--no-token", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()

    host = lan_ip()
    Handler.token = get_token(args.token)
    Handler.host_ip = host
    Handler.any_source = args.any_source

    url = f"http://{host}:{args.port}/"
    if Handler.token:
        url += f"?t={Handler.token}"

    print("=" * 60)
    print(" Movie Remote 起動中")
    print("=" * 60)
    print("  スマホ / ゲームPC のブラウザで開く:")
    print(f"    {url}")
    print()
    if Handler.token:
        print(f"  トークン認証: 有効  （{TOKEN_FILE}）")
    else:
        print("  トークン認証: 無効")
    if args.any_source:
        print("  接続元制限: なし  ← 到達できる相手なら誰でも操作できます")
    else:
        print(f"  接続元制限: {host.rsplit('.', 1)[0]}.0/24 のみ")
    print("  Ctrl+C で終了")
    print("=" * 60)

    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n終了します")


if __name__ == "__main__":
    main()
