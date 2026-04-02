@echo off
title OpenClaw ISO Builder
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0openclaw-tools.ps1" build
pause
