@echo off
title Tethering settings store reset (last software step)
rem ============================================================
rem  One-click launcher for Hotspot-Store-Reset.ps1
rem  Keep this .bat and the .ps1 in the SAME folder.
rem  Creates .reg backups before touching anything.
rem ============================================================

if not exist "%~dp0Hotspot-Store-Reset.ps1" (
    echo ERROR: Hotspot-Store-Reset.ps1 was not found next to this file.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Hotspot-Store-Reset.ps1"
exit /b
