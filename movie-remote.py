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
import subprocess
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE = os.path.join(BASE_DIR, "remote-token.txt")

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
shell32 = ctypes.WinDLL("shell32", use_last_error=True)

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
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
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
loadStatus();
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
                return self._send({"error": "トークンが違います"}, 403)
            try:
                self._send(session_info())
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
