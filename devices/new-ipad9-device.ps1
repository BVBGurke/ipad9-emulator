<#
.SYNOPSIS
    Erstellt ein emuliertes iPad-9-Geraet als Android-AVD.

.DESCRIPTION
    Legt ein Android Virtual Device mit exakt den Abmessungen des iPad 9
    (2021) an:

        1620 x 2160 Pixel bei 320 dpi  =  810 x 1080 dp

    Das sind genau die logischen Punkte des echten iPad 9 (1620x2160 @2x).
    Ein Layout, das hier passt, passt auch auf dem echten Geraet.

    Was das NICHT ist: ein iOS-Simulator. Es laeuft Android darunter. Die
    Abmessungen, die Dichte und damit das Layout stimmen, das Betriebssystem
    nicht. Fuer UIKit-Verhalten, echte iOS-Widgets und den App Store braucht
    es weiterhin einen Mac.

.PARAMETER Name
    Name des AVD. Standard: iPad9_2021

.PARAMETER ApiLevel
    Android-API-Level fuer das Systemabbild. Standard: 35

.PARAMETER Force
    Vorhandenes AVD ueberschreiben.

.EXAMPLE
    .\new-ipad9-device.ps1
    .\new-ipad9-device.ps1 -Name iPad9_Test -ApiLevel 36 -Force

.NOTES
    Braucht das Android SDK. Java muss erreichbar sein (JAVA_HOME).
#>

[CmdletBinding()]
param(
    [string]$Name = 'iPad9_2021',
    [int]$ApiLevel = 35,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- Gerätedaten aus der Definition lesen (eine Quelle, keine Duplikate)
$defPath = Join-Path $PSScriptRoot 'ipad9-2021.json'
if (-not (Test-Path -LiteralPath $defPath)) {
    throw "Geraetedefinition fehlt: $defPath"
}
$def = Get-Content -LiteralPath $defPath -Raw | ConvertFrom-Json

$pxW = [int]$def.specs.nativePixels[0]
$pxH = [int]$def.specs.nativePixels[1]
$dpi = [int]$def.emulation.dpi
$ramMB = [int]$def.emulation.ramMB

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { 'C:\Users\gerdi\AppData\Local\Android\Sdk' }
$sdkmanager = Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
$avdmanager = Join-Path $sdk 'cmdline-tools\latest\bin\avdmanager.bat'
$emulator = Join-Path $sdk 'emulator\emulator.exe'
$adb = Join-Path $sdk 'platform-tools\adb.exe'

foreach ($tool in @($sdkmanager, $avdmanager)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Nicht gefunden: $tool - Android SDK unvollstaendig."
    }
}

# Java ist fuer sdkmanager/avdmanager zwingend. Der haeufigste Fehler ist ein
# JAVA_HOME, das auf einen nicht mehr vorhandenen Pfad zeigt.
if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
    $java = Join-Path $env:JAVA_HOME 'bin\java.exe'
} else {
    $java = $null
    foreach ($cand in @(
            'C:\Program Files\Microsoft\jdk-21.0.11.10-hotspot',
            'C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot',
            'C:\Program Files\Java\jdk-21')) {
        if (Test-Path -LiteralPath (Join-Path $cand 'bin\java.exe')) {
            $env:JAVA_HOME = $cand
            $java = Join-Path $cand 'bin\java.exe'
            break
        }
    }
    if (-not $java) {
        throw 'Kein Java gefunden. JAVA_HOME setzen (JDK 17 oder neuer).'
    }
}

Write-Host ''
Write-Host '  Emuliertes iPad 9 erstellen' -ForegroundColor Cyan
Write-Host ('-' * 62)
Write-Host "  Name         : $Name" -ForegroundColor Gray
Write-Host "  Aufloesung   : ${pxW}x${pxH} px" -ForegroundColor Gray
Write-Host "  Dichte       : $dpi dpi" -ForegroundColor Gray
Write-Host "  Layout-Flaeche: $($pxW * 160 / $dpi) x $($pxH * 160 / $dpi) dp" -ForegroundColor Gray
Write-Host "  RAM          : $ramMB MB" -ForegroundColor Gray
Write-Host "  Java         : $java" -ForegroundColor DarkGray
Write-Host ''

# --- Systemabbild sicherstellen
$image = "system-images;android-$ApiLevel;google_apis;x86_64"
Write-Host "  Pruefe Systemabbild: $image" -ForegroundColor Gray

$installed = (& $sdkmanager --list_installed 2>&1 | Out-String) -replace "`0", ''
if ($installed -notmatch [regex]::Escape($image)) {
    Write-Host '  Abbild fehlt, wird geladen (kann einige Minuten dauern)...' -ForegroundColor Yellow
    $env:JAVA_HOME = $env:JAVA_HOME
    & $sdkmanager $image 2>&1 | Select-Object -Last 3 | ForEach-Object {
        Write-Host "    $_" -ForegroundColor DarkGray
    }
} else {
    Write-Host '  Abbild vorhanden.' -ForegroundColor Green
}

# --- Vorhandenes AVD entfernen, falls gewuenscht
$existing = (& $avdmanager list avd 2>&1 | Out-String) -replace "`0", ''
if ($existing -match "Name:\s+$([regex]::Escape($Name))\b") {
    if ($Force) {
        Write-Host "  Entferne vorhandenes AVD '$Name'..." -ForegroundColor Yellow
        & $emulator -avd $Name -no-window 2>$null | Out-Null
        Start-Sleep -Seconds 1
        'no' | & $avdmanager delete avd -n $Name 2>&1 | ForEach-Object {
            Write-Host "    $_" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  AVD '$Name' existiert bereits. Mit -Force ueberschreiben." -ForegroundColor Yellow
        exit 0
    }
}

# --- AVD anlegen. Das Geraeteprofil liefert nur Rahmen/Groesse; die
#     entscheidenden Werte (Aufloesung, Dichte) setzen wir danach direkt in
#     der config.ini, weil avdmanager keine freie Aufloesung annimmt.
Write-Host "  Lege AVD an..." -ForegroundColor Gray
'no' | & $avdmanager create avd -n $Name -k $image -d pixel_tablet --force 2>&1 | ForEach-Object {
    $line = $_.ToString().Trim()
    if ($line -and $line -notmatch 'Loading local repository|Fetch remote repository|Computing updates') {
        Write-Host "    $line" -ForegroundColor DarkGray
    }
}

$avdDir = Join-Path $env:USERPROFILE ".android\avd\$Name.avd"
$configPath = Join-Path $avdDir 'config.ini'

if (-not (Test-Path -LiteralPath $configPath)) {
    throw "AVD wurde nicht angelegt. Erwartet: $configPath"
}

# --- config.ini auf die iPad-9-Werte setzen
Write-Host ''
Write-Host '  Setze Geraetewerte auf iPad 9:' -ForegroundColor Cyan

$settings = [ordered]@{
    'hw.lcd.width'         = $pxW
    'hw.lcd.height'        = $pxH
    'hw.lcd.density'       = $dpi
    'hw.ramSize'           = $ramMB
    'hw.gpu.enabled'       = 'yes'
    'hw.gpu.mode'          = 'host'
    'hw.keyboard'          = 'yes'
    'hw.mainKeys'          = 'no'
    'hw.dPad'              = 'no'
    'hw.audioInput'        = 'yes'
    'hw.audioOutput'       = 'yes'
    'hw.camera.back'       = 'none'
    'hw.camera.front'      = 'none'
    'hw.sdCard'            = 'yes'
    'hw.device.name'       = 'iPad 9 (2021)'
    'hw.device.manufacturer' = 'Apple'
    'hw.lcd.vsync'         = 60
    'disk.dataPartition.size' = '6442450944'
    'skin.name'            = "${pxW}x${pxH}"
    'skin.path'            = '_no_skin'
}

$lines = Get-Content -LiteralPath $configPath
$seen = @{}
$out = New-Object System.Collections.ArrayList

foreach ($line in $lines) {
    if ($line -match '^\s*([a-zA-Z0-9._]+)\s*=') {
        $key = $Matches[1]
        if ($settings.Contains($key)) {
            $null = $out.Add("$key = $($settings[$key])")
            $seen[$key] = $true
            continue
        }
    }
    $null = $out.Add($line)
}

foreach ($key in $settings.Keys) {
    if (-not $seen.ContainsKey($key)) {
        $null = $out.Add("$key = $($settings[$key])")
    }
}

# AVD-Namen eintragen, sonst startet der Emulator nicht.
$iniPath = Join-Path $env:USERPROFILE ".android\avd\$Name.ini"
if (Test-Path -LiteralPath $iniPath) {
    $iniContent = Get-Content -LiteralPath $iniPath -Raw
    if ($iniContent -notmatch 'avd\.id') {
        # avdmanager setzt das normalerweise selbst.
    }
}

Set-Content -LiteralPath $configPath -Value $out -Encoding UTF8

Write-Host "  config.ini geschrieben: $configPath" -ForegroundColor Green
Write-Host ''
Write-Host '  Gesetzte Werte:' -ForegroundColor Cyan
foreach ($k in @('hw.lcd.width', 'hw.lcd.height', 'hw.lcd.density', 'hw.ramSize', 'hw.gpu.mode', 'hw.device.name')) {
    Write-Host ("    {0,-22} = {1}" -f $k, $settings[$k]) -ForegroundColor Gray
}

Write-Host ''
Write-Host '  Fertig. Starten mit:' -ForegroundColor Green
Write-Host "    .\tools\start-ipad.ps1" -ForegroundColor White
Write-Host "    oder: `"$emulator`" -avd $Name -gpu host" -ForegroundColor DarkGray
Write-Host ''
