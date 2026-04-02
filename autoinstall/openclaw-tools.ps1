#Requires -Version 5.1
<#
.SYNOPSIS
    OpenClaw Tools — Proxmox ISO Verwaltung (funktioniert in allen Terminals)

.PARAMETER Action
    build | copy | build-copy | help

.PARAMETER Drive
    Laufwerksbuchstabe fuer build-copy (z.B. D)

.EXAMPLE
    .\openclaw-tools.ps1 build
    .\openclaw-tools.ps1 copy
    .\openclaw-tools.ps1 build-copy D
    .\openclaw-tools.ps1
#>

param(
    [string]$Action = "",
    [string]$Drive = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ========================================================" -ForegroundColor Cyan
    Write-Host "         OpenClaw Tools -- Proxmox ISO Verwaltung          " -ForegroundColor Cyan
    Write-Host "  ========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    [1]  ISO bauen            (via WSL2)"
    Write-Host "    [2]  ISO auf Ventoy       (auf USB-Stick kopieren)"
    Write-Host "    [3]  ISO bauen + Ventoy   (Build + direkt auf Stick)"
    Write-Host "    [4]  Beenden"
    Write-Host ""
    Write-Host "  --------------------------------------------------------" -ForegroundColor Gray
    Write-Host "    Terminal:  .\openclaw-tools.ps1 build | copy | build-copy D" -ForegroundColor Gray
    Write-Host "  ========================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Run-Build {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ScriptDir\build-iso.ps1"
}

function Run-Copy {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ScriptDir\copy-iso-to-ventoy.ps1"
}

function Run-BuildCopy {
    param([string]$DriveLetter)
    if (-not $DriveLetter) {
        $DriveLetter = Read-Host "  Ventoy-Laufwerksbuchstabe (z.B. D)"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ScriptDir\build-iso.ps1" -CopyToVentoy $DriveLetter
}

function Show-Help {
    Write-Host ""
    Write-Host "  OpenClaw Tools -- Proxmox ISO Verwaltung"
    Write-Host ""
    Write-Host "  Verwendung:"
    Write-Host "    .\openclaw-tools.ps1              Interaktives Menue"
    Write-Host "    .\openclaw-tools.ps1 build        ISO bauen via WSL2"
    Write-Host "    .\openclaw-tools.ps1 copy         ISO auf Ventoy-Stick kopieren"
    Write-Host "    .\openclaw-tools.ps1 build-copy D ISO bauen + direkt auf Stick D"
    Write-Host "    .\openclaw-tools.ps1 help         Diese Hilfe"
    Write-Host ""
}

# -- Direkter Aufruf mit Argument ------------------------------------------------
switch ($Action.ToLower()) {
    "build"      { Run-Build; exit $LASTEXITCODE }
    "copy"       { Run-Copy; exit $LASTEXITCODE }
    "build-copy" { Run-BuildCopy -DriveLetter $Drive; exit $LASTEXITCODE }
    "help"       { Show-Help; exit 0 }
    default      {}  # kein Argument -> Menue
}

# -- Interaktives Menue ----------------------------------------------------------
while ($true) {
    Show-Menu
    $choice = Read-Host "  Auswahl [1-4]"

    switch ($choice) {
        "1" { Run-Build; Write-Host ""; Read-Host "  Enter zum Fortfahren" }
        "2" { Run-Copy; Write-Host ""; Read-Host "  Enter zum Fortfahren" }
        "3" { Run-BuildCopy; Write-Host ""; Read-Host "  Enter zum Fortfahren" }
        "4" { exit 0 }
        default { Write-Host "  Ungueltige Auswahl." -ForegroundColor Red; Start-Sleep 2 }
    }
}
