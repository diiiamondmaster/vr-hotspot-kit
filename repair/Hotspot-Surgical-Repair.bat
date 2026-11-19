@echo off
title Surgical hotspot repair from ISO (no upgrade, no bloat)
rem ============================================================
rem  One-click launcher for Hotspot-Surgical-Repair.ps1
rem  Keep this .bat and the .ps1 in the SAME folder.
rem  Requires the official Windows 11 ISO mounted (double-click it).
rem ============================================================

if not exist "%~dp0Hotspot-Surgical-Repair.ps1" (
    echo ERROR: Hotspot-Surgical-Repair.ps1 was not found next to this file.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Hotspot-Surgical-Repair.ps1"
exit /b
