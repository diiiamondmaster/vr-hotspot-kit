@echo off
title Hotspot DeepClean - ghost adapters + stale ICS
rem ============================================================
rem  One-click launcher for Hotspot-DeepClean.ps1
rem  Keep this .bat and the .ps1 in the SAME folder.
rem  IMPORTANT: fully exit your 3rd-party hotspot app first!
rem ============================================================

if not exist "%~dp0Hotspot-DeepClean.ps1" (
    echo ERROR: Hotspot-DeepClean.ps1 was not found next to this file.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Hotspot-DeepClean.ps1"
exit /b
