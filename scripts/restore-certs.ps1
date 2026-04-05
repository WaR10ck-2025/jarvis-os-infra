#Requires -Version 5.1
<#
.SYNOPSIS
    Stellt mkcert CA + Site-Zertifikate aus dem USB-Backup wieder her.
.DESCRIPTION
    Kopiert rootCA aus dem Backup ins mkcert-Verzeichnis, installiert die CA
    im Windows Trust Store, und kopiert die Site-Zertifikate ins Projektverzeichnis.
    Danach muessen die Site-Zertifikate noch in den NPM (LXC 110) hochgeladen werden.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$BackupKeysDir = Join-Path $ProjectRoot "USB-F35-Pro\backup\jarvis-os-backups\keys\mkcert"
$MkcertCA = Join-Path $env:LOCALAPPDATA "mkcert"

if (-not (Test-Path $BackupKeysDir)) {
    Write-Host "FEHLER: Backup-Verzeichnis nicht gefunden:" -ForegroundColor Red
    Write-Host "  $BackupKeysDir" -ForegroundColor Red
    Write-Host "USB-Stick (Secure Zone) einstecken und FreeFileSync synchronisieren." -ForegroundColor Yellow
    exit 1
}

Write-Host "=== mkcert CA wiederherstellen ===" -ForegroundColor Cyan

# mkcert-Verzeichnis erstellen
if (-not (Test-Path $MkcertCA)) {
    New-Item -ItemType Directory -Path $MkcertCA -Force | Out-Null
}

# CA-Dateien kopieren
foreach ($file in @("rootCA.pem", "rootCA-key.pem")) {
    $src = Join-Path $BackupKeysDir $file
    if (Test-Path $src) {
        Copy-Item $src -Destination $MkcertCA -Force
        Write-Host "[OK] $file -> $MkcertCA" -ForegroundColor Green
    } else {
        Write-Host "[!!] $file fehlt im Backup" -ForegroundColor Red
    }
}

# CA im Windows Trust Store installieren
Write-Host ""
Write-Host "Installiere CA im Windows Trust Store..." -ForegroundColor Cyan
$mkcertExe = Get-Command mkcert -ErrorAction SilentlyContinue
if ($mkcertExe) {
    & mkcert -install 2>&1 | Out-Null
    Write-Host "[OK] mkcert CA installiert" -ForegroundColor Green
} else {
    Write-Host "[!!] mkcert nicht installiert — CA manuell importieren:" -ForegroundColor Yellow
    Write-Host "     certutil -addstore Root `"$MkcertCA\rootCA.pem`"" -ForegroundColor Yellow
}

# Site-Zertifikate ins Projektverzeichnis kopieren
Write-Host ""
Write-Host "=== Site-Zertifikate wiederherstellen ===" -ForegroundColor Cyan
foreach ($file in @("admin.jarvis.local.pem", "admin.jarvis.local-key.pem")) {
    $src = Join-Path $BackupKeysDir $file
    if (Test-Path $src) {
        Copy-Item $src -Destination $ProjectRoot -Force
        Write-Host "[OK] $file -> Projektverzeichnis" -ForegroundColor Green
    } else {
        Write-Host "[--] $file nicht im Backup (kann mit mkcert neu generiert werden)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Naechste Schritte:" -ForegroundColor Cyan
Write-Host "  1. Chrome komplett neu starten (alle Fenster schliessen)" -ForegroundColor White
Write-Host "  2. Site-Zertifikate in NPM (LXC 110) hochladen:" -ForegroundColor White
Write-Host "     scp admin.jarvis.local*.pem root@192.168.10.147:/tmp/" -ForegroundColor DarkGray
Write-Host "     ssh root@... 'pct exec 110 -- docker cp /tmp/*.pem nginx-proxy-manager:/data/custom_ssl/npm-1/'" -ForegroundColor DarkGray
Write-Host "     ssh root@... 'pct exec 110 -- docker exec nginx-proxy-manager nginx -s reload'" -ForegroundColor DarkGray
