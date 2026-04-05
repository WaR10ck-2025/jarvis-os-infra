@echo off
title J.A.R.V.I.S-OS ISO Builder
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0jarvis-tools.ps1" build
pause
