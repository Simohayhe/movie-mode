@echo off
setlocal
cd /d "%~dp0"
set CSC=%WINDIR%\Microsoft.NET\Framework644.0.30319\csc.exe
if not exist "%CSC%" (
  echo csc.exe not found: %CSC%
  pause
  exit /b 1
)
"%CSC%" /nologo /target:winexe /out:MovieMode.exe /win32icon:movie-mode.ico /win32manifest:movie-mode.manifest /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll MovieModeGui.cs
if errorlevel 1 (
  echo build failed
  pause
  exit /b 1
)
echo built: MovieMode.exe
pause
