@echo off
title VR Hotspot Studio DEBUG
rem ============================================================
rem  One-click launcher for VR-Hotspot-Studio.ps1
rem  Keep this .bat and the .ps1 in the SAME folder.
rem  STOP MyPublicWiFi (or any other hotspot app) before starting.
rem  DEBUG BUILD: records everything to debug-logs\ next to this
rem  file. Submit that log file with any problem report.
rem ============================================================

if not exist "%~dp0VR-Hotspot-Studio.ps1" (
    echo ERROR: VR-Hotspot-Studio.ps1 was not found next to this file.
    pause
    exit /b 1
)

rem ---- admin check (v2.4.0) -------------------------------------------
rem  fltmc needs elevation and is instant. If it refuses, ask PowerShell
rem  for the authoritative answer (its exit code is 0 only when the
rem  process is already elevated) - this covers images where fltmc is
rem  missing. The old "net session" check depended on the Server
rem  service, which stripped Windows images often lack, and then loops
rem  on the elevation request forever.
fltmc >nul 2>&1
if %errorlevel% equ 0 goto :elevated
powershell -NoProfile -NonInteractive -Command "exit [int](-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))" >nul 2>&1
if %errorlevel% equ 0 goto :elevated

echo Requesting administrator access...
rem  pass the path through the environment so ANY character in the
rem  install folder (spaces, apostrophes, parentheses) survives
set "VRHS_LAUNCHER=%~f0"
powershell -NoProfile -NonInteractive -Command "Start-Process -FilePath $env:VRHS_LAUNCHER -Verb RunAs"
if %errorlevel% neq 0 (
    echo.
    echo Could not elevate. If you declined the Administrator prompt,
    echo run the file again; otherwise the red text above says why.
    pause
)
exit /b

:elevated
rem  -NonInteractive (v2.4.0): a bug can never freeze the app on a
rem  "Supply values for the following parameters" console prompt -
rem  a prompting command fails fast with a visible error instead.
powershell -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "%~dp0VR-Hotspot-Studio.ps1"
if %errorlevel% neq 0 (
    echo.
    echo VR Hotspot Studio exited with an error.
    echo If no window or message box explained the problem, look at the
    echo red text above and at studio-crash.log in this folder.
    pause
)
echo.
echo Debug log for this session: look in the debug-logs folder next
echo to this file, and submit that file with any problem report.
exit /b
