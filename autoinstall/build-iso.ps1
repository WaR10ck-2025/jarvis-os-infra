#Requires -Version 5.1
<#
.SYNOPSIS
    Baut das J.A.R.V.I.S-OS Proxmox ISO via WSL2 und verifiziert das Ergebnis.

.PARAMETER PveIso
    Pfad zur Proxmox VE Basis-ISO. Standard: automatische Suche im Downloads-Ordner.

.PARAMETER Interactive
    Interaktiven Modus verwenden (Proxmox-Wizard statt Autoinstall).

.PARAMETER CopyToVentoy
    Nach dem Build direkt auf Ventoy-Stick kopieren (Laufwerksbuchstabe, z.B. D).

.EXAMPLE
    .\build-iso.ps1
    .\build-iso.ps1 -PveIso "C:\Downloads\proxmox-ve_9.1-1.iso"
    .\build-iso.ps1 -CopyToVentoy D
#>

param(
    [string]$PveIso = "",
    [switch]$Interactive,
    [string]$CopyToVentoy = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Farben -------------------------------------------------------------------
function Write-Ok   { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Err  { param($msg) Write-Host "  [!!] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "  [ ] $msg"  -ForegroundColor Cyan }
function Write-Head { param($msg) Write-Host "`n$msg" -ForegroundColor Yellow }

$ProjectDir = "C:\Daten\Projekte\jarvis-os-infra\autoinstall"
$WslProjectDir = "/mnt/c/Daten/Projekte/jarvis-os-infra/autoinstall"
$OutputIso = Join-Path $ProjectDir "proxmox-jarvis.iso"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "       J.A.R.V.I.S-OS -- Proxmox ISO Builder                  " -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

if ($Interactive) {
    Write-Host "  Modus: INTERAKTIV" -ForegroundColor Yellow
} else {
    Write-Host "  Modus: AUTOMATISCH (answer.toml)" -ForegroundColor Green
}

# -- WSL2 pruefen -------------------------------------------------------------
Write-Head ">> WSL2 pruefen..."
$wslStatus = wsl -l -v 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "WSL2 nicht verfuegbar. Bitte WSL2 installieren."
    exit 1
}
Write-Ok "WSL2 verfuegbar"

# -- Proxmox VE ISO suchen ---------------------------------------------------
Write-Head ">> Proxmox VE Basis-ISO suchen..."

if (-not $PveIso) {
    # Automatisch suchen: Downloads, Projektordner
    $searchPaths = @(
        "$env:USERPROFILE\Downloads",
        $ProjectDir,
        (Split-Path $ProjectDir)
    )

    foreach ($searchPath in $searchPaths) {
        $found = Get-ChildItem -Path $searchPath -Filter "proxmox-ve_*.iso" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($found) {
            $PveIso = $found.FullName
            break
        }
    }
}

if (-not $PveIso -or -not (Test-Path $PveIso)) {
    Write-Err "Keine Proxmox VE ISO gefunden."
    Write-Host "  Gesucht in: Downloads, Projektordner" -ForegroundColor Gray
    Write-Host ""
    $PveIso = Read-Host "  ISO-Pfad manuell eingeben"
    if (-not $PveIso -or -not (Test-Path $PveIso)) {
        Write-Err "ISO nicht gefunden -- abgebrochen."
        exit 1
    }
}

$pveSize = [math]::Round((Get-Item $PveIso).Length / 1MB, 0)
Write-Ok "Basis-ISO: $PveIso -- $pveSize MB"

# -- Alte ISO loeschen --------------------------------------------------------
if (Test-Path $OutputIso) {
    Write-Head ">> Alte ISO entfernen..."
    Remove-Item $OutputIso -Force
    Write-Ok "Alte proxmox-jarvis.iso entfernt"
}

# -- WSL2 Pfad umrechnen -----------------------------------------------------
# Windows-Pfad -> WSL-Pfad (C:\foo\bar -> /mnt/c/foo/bar)
$PveIsoWsl = $PveIso -replace '\\', '/'
$driveLetter = $PveIsoWsl.Substring(0,1).ToLower()
$PveIsoWsl = "/mnt/$driveLetter" + $PveIsoWsl.Substring(2)

# -- Build starten ------------------------------------------------------------
Write-Head ">> ISO bauen via WSL2..."
Write-Info "Das kann 1-5 Minuten dauern..."
Write-Host ""

$buildArgs = "--pve-iso `"$PveIsoWsl`""
if ($Interactive) {
    $buildArgs += " --interactive"
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$buildCmd = "cd `"$WslProjectDir`" && bash build-iso.sh $buildArgs"
wsl -u root -- bash -c $buildCmd

if ($LASTEXITCODE -ne 0) {
    Write-Err "ISO-Build fehlgeschlagen! Exit code: $LASTEXITCODE"
    exit 1
}

$sw.Stop()
$elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 0)

# -- Ergebnis pruefen --------------------------------------------------------
Write-Head ">> Ergebnis pruefen..."

if (-not (Test-Path $OutputIso)) {
    Write-Err "ISO wurde nicht erstellt -- Build fehlgeschlagen."
    exit 1
}

$isoSize = [math]::Round((Get-Item $OutputIso).Length / 1MB, 0)
Write-Ok "ISO erstellt: $OutputIso -- $isoSize MB -- ${elapsed}s"

# -- SHA256 berechnen ---------------------------------------------------------
Write-Head ">> SHA256 berechnen..."
$hash = (Get-FileHash $OutputIso -Algorithm SHA256).Hash
Write-Ok "SHA256: $hash"

# -- Optional: auf Ventoy kopieren -------------------------------------------
if ($CopyToVentoy) {
    Write-Head ">> Auf Ventoy-Stick kopieren -- Laufwerk $CopyToVentoy..."

    $ventoyTarget = "${CopyToVentoy}:\proxmox-jarvis.iso"

    if (-not (Test-Path "${CopyToVentoy}:\")) {
        Write-Err "Laufwerk $CopyToVentoy nicht gefunden."
        exit 1
    }

    # Systemlaufwerk-Schutz
    if ($CopyToVentoy -eq $env:SystemDrive.TrimEnd(":")) {
        Write-Err "Laufwerk $CopyToVentoy ist das System-Laufwerk -- abgebrochen!"
        exit 1
    }

    Write-Info "Kopiere $isoSize MB..."
    $copySw = [System.Diagnostics.Stopwatch]::StartNew()

    # Kopieren mit FileStream + Fortschritt
    if (Test-Path $ventoyTarget) {
        Remove-Item $ventoyTarget -Force
    }

    $bufSize = 4MB
    $srcStream = [System.IO.File]::OpenRead($OutputIso)
    $dstStream = [System.IO.File]::OpenWrite($ventoyTarget)
    $buf = New-Object byte[] $bufSize
    $totalRead = 0
    $fileSize = $srcStream.Length

    try {
        while (($read = $srcStream.Read($buf, 0, $buf.Length)) -gt 0) {
            $dstStream.Write($buf, 0, $read)
            $totalRead += $read
            $pct = [math]::Round($totalRead / $fileSize * 100, 0)
            $mb  = [math]::Round($totalRead / 1MB, 0)
            $speed = if ($copySw.Elapsed.TotalSeconds -gt 0) {
                [math]::Round($totalRead / 1MB / $copySw.Elapsed.TotalSeconds, 1)
            } else { 0 }
            Write-Progress -Activity "ISO auf Ventoy kopieren" `
                -Status "$mb MB / $isoSize MB  -- $speed MB/s" `
                -PercentComplete $pct
        }
    } finally {
        $dstStream.Flush()
        $dstStream.Close()
        $srcStream.Close()
    }
    Write-Progress -Activity "ISO auf Ventoy kopieren" -Completed

    # SHA256 verifizieren
    Write-Info "SHA256 verifizieren..."
    $hashDst = (Get-FileHash $ventoyTarget -Algorithm SHA256).Hash

    if ($hash -eq $hashDst) {
        Write-Ok "SHA256 identisch -- bit-genau uebertragen"
    } else {
        Write-Err "SHA256 UNTERSCHIEDLICH -- Uebertragungsfehler!"
        Remove-Item $ventoyTarget -Force
        exit 1
    }
}

# -- Fertig -------------------------------------------------------------------
Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "                      Fertig!                           " -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  ISO:      $OutputIso" -ForegroundColor Green
Write-Host "  Groesse:  $isoSize MB" -ForegroundColor Green
Write-Host "  SHA256:   $hash" -ForegroundColor Green
Write-Host "  Dauer:    ${elapsed}s" -ForegroundColor Green

if ($CopyToVentoy) {
    Write-Host "  Ventoy:   ${CopyToVentoy}:\proxmox-jarvis.iso" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Stick kann jetzt abgezogen werden." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Naechste Schritte:" -ForegroundColor Yellow
Write-Host "    1. USB booten -> Ventoy-Menu -> proxmox-jarvis.iso" -ForegroundColor Gray
if ($Interactive) {
    Write-Host "    2. Proxmox Wizard -> Disk, Hostname, Passwort konfigurieren" -ForegroundColor Gray
} else {
    Write-Host "    2. Proxmox installiert automatisch (kein Input noetig)" -ForegroundColor Gray
}
Write-Host "    3. Neustart -> first-boot.sh startet LXC-Deployment" -ForegroundColor Gray
Write-Host ""
