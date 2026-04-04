#Requires -Version 5.1
<#
.SYNOPSIS
    Sichert mkcert CA + Site-Zertifikate ins USB-Backup (keys/mkcert/).
.DESCRIPTION
    Kopiert rootCA + admin.openclaw.local Zertifikate aus den Quellverzeichnissen
    ins lokale USB-Mirror-Verzeichnis. Von dort werden sie per FreeFileSync
    auf den USB-Stick (Secure Zone) synchronisiert.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$BackupKeysDir = Join-Path $ProjectRoot "USB-F35-Pro\backup\openclaw-backups\keys\mkcert"
$MkcertCA = Join-Path $env:LOCALAPPDATA "mkcert"

# Zielverzeichnis erstellen
if (-not (Test-Path $BackupKeysDir)) {
    New-Item -ItemType Directory -Path $BackupKeysDir -Force | Out-Null
}

$copied = 0

# mkcert CA (Root-Zertifikat + Private Key)
foreach ($file in @("rootCA.pem", "rootCA-key.pem")) {
    $src = Join-Path $MkcertCA $file
    if (Test-Path $src) {
        Copy-Item $src -Destination $BackupKeysDir -Force
        Write-Host "[OK] $file" -ForegroundColor Green
        $copied++
    } else {
        Write-Host "[--] $file nicht gefunden (mkcert nicht installiert?)" -ForegroundColor Yellow
    }
}

# Site-Zertifikate (admin.openclaw.local)
foreach ($file in @("admin.openclaw.local.pem", "admin.openclaw.local-key.pem")) {
    $src = Join-Path $ProjectRoot $file
    if (Test-Path $src) {
        Copy-Item $src -Destination $BackupKeysDir -Force
        Write-Host "[OK] $file" -ForegroundColor Green
        $copied++
    } else {
        Write-Host "[--] $file nicht gefunden" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "$copied Dateien gesichert nach:" -ForegroundColor Cyan
Write-Host "  $BackupKeysDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "Naechster Schritt: USB-Stick (Secure Zone) per FreeFileSync synchronisieren." -ForegroundColor DarkGray
