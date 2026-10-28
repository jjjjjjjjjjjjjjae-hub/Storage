@echo off
setlocal
set "POWERSHELL_TELEMETRY_OPTOUT=1"
set "POWERSHELL_UPDATECHECK=Off"
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Storage.ps1"
echo.
echo TUZE has stopped. Press any key to close this window.
pause >nul
