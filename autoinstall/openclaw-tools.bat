@echo off
title OpenClaw Tools
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0openclaw-tools.ps1" %*
