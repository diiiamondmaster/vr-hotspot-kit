@echo off
title VR Hotspot Studio
rem ============================================================
rem  One-click launcher for VR-Hotspot-Studio.ps1
rem  Keep this .bat and the .ps1 in the SAME folder.
rem  STOP MyPublicWiFi (or any other hotspot app) before starting.
rem ============================================================

if not exist "%~dp0VR-Hotspot-Studio.ps1" (
    echo ERROR: VR-Hotspot-Studio.ps1 was not found next to this file.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0VR-Hotspot-Studio.ps1"
exit /b
