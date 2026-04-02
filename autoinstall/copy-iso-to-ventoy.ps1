#Requires -Version 5.1
<#
.SYNOPSIS
    Kopiert das OpenClaw ISO auf einen Ventoy-USB-Stick und verifiziert via SHA256.

.PARAMETER Drive
    Laufwerksbuchstabe des Ventoy-Sticks (z.B. D). Wenn nicht angegeben: interaktive Auswahl.

.PARAMETER IsoPath
    Pfad zur ISO-Datei. Standard: proxmox-openclaw.iso im selben Verzeichnis.

.EXAMPLE
    .\copy-iso-to-ventoy.ps1
    .\copy-iso-to-ventoy.ps1 -Drive D
    .\copy-iso-to-ventoy.ps1 -Drive E -IsoPath "C:\Downloads\mein.iso"
#>

param(
    [string]$Drive = "",
    [string]$IsoPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Farben -------------------------------------------------------------------
function Write-Ok   { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Err  { param($msg) Write-Host "  [!!] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "  [ ] $msg"  -ForegroundColor Cyan }
function Write-Head { param($msg) Write-Host "`n$msg" -ForegroundColor Yellow }

# -- ISO-Pfad bestimmen -------------------------------------------------------
if (-not $IsoPath) {
    $IsoPath = Join-Path $PSScriptRoot "proxmox-openclaw.iso"
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "       OpenClaw -- ISO auf Ventoy-Stick kopieren        " -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

# -- ISO pruefen --------------------------------------------------------------
Write-Head ">> ISO pruefen..."
if (-not (Test-Path $IsoPath)) {
    Write-Err "ISO nicht gefunden: $IsoPath"
    exit 1
}
$IsoSize = (Get-Item $IsoPath).Length
$IsoSizeMB = [math]::Round($IsoSize / 1MB, 0)
Write-Ok "ISO gefunden: $IsoPath -- $IsoSizeMB MB"

# -- USB-Laufwerke inkrementell anzeigen --------------------------------------
Write-Head ">> Suche USB-Laufwerke... (beliebige Taste = Suche abbrechen)"
Write-Host ""
Write-Host "  Buchst  Label               Groesse     Frei" -ForegroundColor Gray
Write-Host "  ------  ------------------  ----------  ----------" -ForegroundColor Gray

$UsbDrives = @()
$letters = 68..90 | ForEach-Object { [char]$_ }  # D-Z

foreach ($letter in $letters) {
    # Abbruch bei Tastendruck (nur wenn interaktive Konsole)
    try {
        if ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
            Write-Host ""
            Write-Host "  Suche abgebrochen." -ForegroundColor Yellow
            break
        }
    } catch {
        # Keine Konsole verfuegbar (z.B. piped/redirected) -- weiter scannen
    }

    $devId = "${letter}:"
    $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$devId' AND DriveType=2" -ErrorAction SilentlyContinue
    if ($disk) {
        $label  = if ($disk.VolumeName) { $disk.VolumeName } else { "(kein Label)" }
        $sizeStr = if ($disk.Size)      { "$([math]::Round($disk.Size/1GB,1)) GB" } else { "?" }
        $freeStr = if ($disk.FreeSpace) { "$([math]::Round($disk.FreeSpace/1GB,1)) GB" } else { "?" }
        Write-Host ("  {0,-6}  {1,-18}  {2,-10}  {3}" -f $letter, $label, $sizeStr, $freeStr)
        $UsbDrives += $disk
    }
}

Write-Host ""

if ($UsbDrives.Count -eq 0) {
    Write-Err "Keine USB-Laufwerke gefunden. Stick einstecken und nochmal versuchen."
    exit 1
}

# -- Laufwerk auswaehlen ------------------------------------------------------
if (-not $Drive) {
    $Drive = Read-Host "  Laufwerksbuchstabe eingeben (z.B. D)"
}
$Drive = $Drive.TrimEnd(":").ToUpper()
$TargetRoot = "${Drive}:\"

if (-not (Test-Path $TargetRoot)) {
    Write-Err "Laufwerk $Drive nicht gefunden."
    exit 1
}

# Sicherheitscheck: nicht die System-Disk
$SystemDrive = $env:SystemDrive.TrimEnd(":")
if ($Drive -eq $SystemDrive) {
    Write-Err "Laufwerk $Drive ist das System-Laufwerk -- abgebrochen!"
    exit 1
}

# Genug Platz?
$FreeDisk = (Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='${Drive}:'").FreeSpace
if ($FreeDisk -lt $IsoSize) {
    $FreeMB = [math]::Round($FreeDisk/1MB, 0)
    Write-Err "Nicht genug Platz: $FreeMB MB frei, $IsoSizeMB MB benoetigt."
    exit 1
}

$TargetPath = Join-Path $TargetRoot (Split-Path $IsoPath -Leaf)

# -- Bestaetigung -------------------------------------------------------------
Write-Head ">> Zusammenfassung:"
Write-Host "  Quelle:  $IsoPath -- $IsoSizeMB MB"
Write-Host "  Ziel:    $TargetPath"
Write-Host ""
$confirm = Read-Host "  Fortfahren? [J/n]"
if ($confirm -and $confirm -notmatch "^[jJyY]") {
    Write-Host "  Abgebrochen." -ForegroundColor Yellow
    exit 0
}

# -- Kopieren mit Fortschritt -------------------------------------------------
Write-Head ">> Kopiere ISO..."

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Vorhandene Datei ueberschreiben
if (Test-Path $TargetPath) {
    Remove-Item $TargetPath -Force
}

# Kopieren mit Write-Progress
$bufSize = 4MB
$srcStream = [System.IO.File]::OpenRead($IsoPath)
$dstStream = [System.IO.File]::OpenWrite($TargetPath)
$buf = New-Object byte[] $bufSize
$totalRead = 0

try {
    while (($read = $srcStream.Read($buf, 0, $buf.Length)) -gt 0) {
        $dstStream.Write($buf, 0, $read)
        $totalRead += $read
        $pct = [math]::Round($totalRead / $IsoSize * 100, 0)
        $mb  = [math]::Round($totalRead / 1MB, 0)
        $speed = if ($sw.Elapsed.TotalSeconds -gt 0) {
            [math]::Round($totalRead / 1MB / $sw.Elapsed.TotalSeconds, 1)
        } else { 0 }
        Write-Progress -Activity "ISO kopieren" `
            -Status "$mb MB / $IsoSizeMB MB  -- $speed MB/s" `
            -PercentComplete $pct
    }
} finally {
    $dstStream.Flush()
    $dstStream.Close()
    $srcStream.Close()
}

Write-Progress -Activity "ISO kopieren" -Completed
$elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$avgSpeed = [math]::Round($IsoSizeMB / $sw.Elapsed.TotalSeconds, 1)
Write-Ok "Kopiert in ${elapsed}s -- $avgSpeed MB/s"

# -- SHA256 verifizieren ------------------------------------------------------
Write-Head ">> SHA256 verifizieren..."

Write-Info "Berechne Quelle..."
$hashSrc = (Get-FileHash $IsoPath -Algorithm SHA256).Hash

Write-Info "Berechne Ziel..."
$hashDst = (Get-FileHash $TargetPath -Algorithm SHA256).Hash

Write-Host "  Quelle:  $hashSrc"
Write-Host "  Ziel:    $hashDst"

if ($hashSrc -eq $hashDst) {
    Write-Ok "SHA256 identisch -- ISO bit-genau uebertragen"
} else {
    Write-Err "SHA256 UNTERSCHIEDLICH -- Uebertragungsfehler!"
    Remove-Item $TargetPath -Force
    exit 1
}

# -- Fertig -------------------------------------------------------------------
Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "                      Fertig!                           " -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  ISO:    $TargetPath" -ForegroundColor Green
Write-Host "  SHA256: $hashDst" -ForegroundColor Green
Write-Host ""
Write-Host "  Stick kann jetzt abgezogen werden." -ForegroundColor Yellow
Write-Host "  Booten -> Ventoy-Menu -> proxmox-openclaw.iso waehlen" -ForegroundColor Yellow
Write-Host ""
