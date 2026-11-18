@echo off
title Hotspot vs VPN test (Tailscale etc.)
rem ============================================================
rem  One-click launcher for VPN-Hotspot-Test.ps1
rem  Keep this .bat and the .ps1 in the SAME folder.
rem ============================================================

if not exist "%~dp0VPN-Hotspot-Test.ps1" (
    echo ERROR: VPN-Hotspot-Test.ps1 was not found next to this file.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0VPN-Hotspot-Test.ps1"
exit /b
