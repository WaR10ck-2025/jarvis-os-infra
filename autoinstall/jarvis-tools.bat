@echo off
title J.A.R.V.I.S-OS Tools
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0jarvis-tools.ps1" %*
