@echo off
title Publish vr-hotspot-kit to GitHub
rem ============================================================
rem  One-click publisher. Needs a GitHub Personal Access Token
rem  (repo scope): https://github.com/settings/tokens/new?scopes=repo&description=vr-hotspot-kit
rem  Full instructions: docs\PUBLISHING.md
rem ============================================================

if not exist "%~dp0Publish-to-GitHub.ps1" (
    echo ERROR: Publish-to-GitHub.ps1 was not found next to this file.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Publish-to-GitHub.ps1"
exit /b %errorlevel%
