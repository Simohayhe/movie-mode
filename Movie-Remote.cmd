@echo off
setlocal
cd /d "%~dp0"
rem 動画リモコンを単体で起動する（映画モード実行時は自動起動されるので通常は不要）
"%LOCALAPPDATA%\Programs\Python\Python312\python.exe" movie-remote.py %*
pause
