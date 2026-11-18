@echo off
title Mobile Hotspot Repair Kit (tiny11 fix)
rem ============================================================
rem  One-click launcher for Restore-MobileHotspot.ps1
rem  Keep this .bat and the .ps1 in the SAME folder.
rem  Double-click this file - it will ask for admin rights.
rem ============================================================

if not exist "%~dp0Restore-MobileHotspot.ps1" (
    echo ERROR: Restore-MobileHotspot.ps1 was not found next to this file.
    echo Keep both files in the same folder and run this again.
    pause
    exit /b 1
)

rem -- relaunch elevated if needed --
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

rem -- run the repair script --
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-MobileHotspot.ps1"
exit /b
