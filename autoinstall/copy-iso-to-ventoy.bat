@echo off
title J.A.R.V.I.S-OS ISO auf Ventoy kopieren
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0jarvis-tools.ps1" copy
pause
