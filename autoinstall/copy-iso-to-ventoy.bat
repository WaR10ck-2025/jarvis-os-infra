@echo off
title OpenClaw ISO auf Ventoy kopieren
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0openclaw-tools.ps1" copy
pause
