@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Storage-Settings.ps1"
echo.
echo Press any key to close this window.
pause >nul
