@echo off
setlocal
rem 映画モード: コンソールセッションへ即移動する（配信は張ったまま維持）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0movie-mode.ps1" -Yes %*
