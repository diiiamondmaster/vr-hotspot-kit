@echo off
title 5 GHz hotspot setup + conflict test
rem ============================================================
rem  One-click launcher for Hotspot-5GHz-Setup.ps1
rem  Keep this .bat and the .ps1 in the SAME folder.
rem  IMPORTANT: stop MyPublicWiFi's hotspot completely first!
rem ============================================================

if not exist "%~dp0Hotspot-5GHz-Setup.ps1" (
    echo ERROR: Hotspot-5GHz-Setup.ps1 was not found next to this file.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Hotspot-5GHz-Setup.ps1"
exit /b
