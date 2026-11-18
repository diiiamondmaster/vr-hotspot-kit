@echo off
title Hotspot Doctor - deep diagnosis (tiny11)
rem ============================================================
rem  One-click launcher for Hotspot-Doctor.ps1
rem  Keep this .bat and the .ps1 in the SAME folder.
rem ============================================================

if not exist "%~dp0Hotspot-Doctor.ps1" (
    echo ERROR: Hotspot-Doctor.ps1 was not found next to this file.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Hotspot-Doctor.ps1"
exit /b
