<#
.SYNOPSIS
    Interaktive TUI fuer das emulierte iPad-9-Geraet.

.DESCRIPTION
    Steuert das Android-AVD "iPad9_2021" (1620x2160 @ 320 dpi = 810x1080 dp,
    exakt die logischen Punkte des iPad 9) und baut Flutter-Apps darauf.

    Alles laeuft lokal, ohne Cloud und ohne Zugangsdaten.

    Wichtige Einschraenkung: Das Geraet hat die richtigen Masse, laeuft aber
    unter Android. Die Layout-Flaeche stimmt punkgenau, iOS selbst nicht.
    Fuer UIKit-Verhalten und den echten iOS-Simulator braucht es macOS.

.EXAMPLE
    .\iPad-Tui.ps1
    .\iPad-Tui.ps1 -Device iPad9_2021
    .\iPad-Tui.ps1 -AppName ios_starter -ProjectPath ..\..\projects\flutter-probe

.NOTES
    Windows PowerShell 5.1 kompatibel.
#>

[CmdletBinding()]
param(
    [string]$Device = 'iPad9_2021',
    [string]$AppName = 'flutter_probe',
    [string]$ProjectPath,

    # Eine Aktion direkt ausfuehren, ohne Menue. Damit ist die TUI auch aus
    # Skripten und Tests benutzbar.
    [ValidateSet('start', 'stop', 'status', 'wake', 'install', 'reload', 'shot',
                 'open', 'portrait', 'landscape', 'metrics', 'definition',
                 'help', 'log', 'menu')]
    [string]$Action,

    # Menueeingaben vorab, z.B. -Commands '3','7','q'. Notwendig, weil jede
    # adb-Ausfuehrung stdin erbt und eine Pipe leert: mit 'echo 3 | ...' kaeme
    # beim Menue nichts mehr an. Ueber diesen Parameter bleibt der Ablauf
    # reproduzierbar.
    [string[]]$Commands,

    [switch]$NoClear
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- Pfade
$script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:Sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { 'C:\Users\gerdi\AppData\Local\Android\Sdk' }
$script:Adb = Join-Path $script:Sdk 'platform-tools\adb.exe'
$script:Emulator = Join-Path $script:Sdk 'emulator\emulator.exe'
$script:Flutter = Join-Path $script:Root 'sdk\flutter\bin\flutter.bat'
$script:ShotDir = Join-Path $script:Root 'audits\ipad'
$script:Device = $Device
$script:AppName = $AppName
$script:Serial = $null
$script:Log = New-Object System.Collections.ArrayList

if (-not $ProjectPath) {
    $ProjectPath = Join-Path $script:Root 'projects\flutter-probe'
}
$script:ProjectPath = [IO.Path]::GetFullPath($ProjectPath)

if (-not (Test-Path -LiteralPath $script:ShotDir)) {
    New-Item -ItemType Directory -Path $script:ShotDir -Force | Out-Null
}

$script:Jdk = 'C:\Program Files\Microsoft\jdk-21.0.11.10-hotspot'
if (Test-Path -LiteralPath $script:Jdk) { $env:JAVA_HOME = $script:Jdk }

# ---------------------------------------------------------------- Ausgabe
function Write-Line { param([string]$Text = '', [string]$Color = 'Gray')
    if ($script:UseColor) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}
function Write-Ok    { param([string]$t) Write-Line "  [ok]    $t" 'Green' }
function Write-Err   { param([string]$t) Write-Line "  [fehler] $t" 'Red' }
function Write-Warn2 { param([string]$t) Write-Line "  [warnung] $t" 'Yellow' }
function Write-Info  { param([string]$t) Write-Line "  [info]  $t" 'DarkGray' }

function Add-Log {
    param([string]$Text)
    $null = $script:Log.Add("$(Get-Date -Format 'HH:mm:ss')  $Text")
}

function Write-Head {
    param([string]$Title)
    Write-Host ''
    Write-Host ('  ' + $Title) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray
}

function Clear-Screen {
    if ($NoClear) { return }
    # Clear-Host scheitert, wenn die Ausgabe umgeleitet ist.
    try { Clear-Host } catch { }
}

<#
    Eingabe lesen.

    Read-Host scheitert, wenn stdin eine Pipe ist. [Console]::In.ReadLine()
    wuerde dort funktionieren, aber jede adb-Ausfuehrung erbt stdin und leert
    die Pipe - nach dem ersten Menueaufbau waere sie leer. Deshalb der
    Warteschlangenmodus ueber -Commands; er ist auch der getestete Weg.
#>
function Read-Choice {
    param([string]$Prompt = '  Auswahl')

    if ($script:Queue) {
        Write-Host $Prompt -NoNewline
        if ($script:QueueIndex -ge $script:Queue.Count) {
            Write-Host ' (Eingaben erschoepft)' -ForegroundColor DarkGray
            return $null
        }
        $value = $script:Queue[$script:QueueIndex]
        $script:QueueIndex++
        Write-Host $value -ForegroundColor DarkGray
        return $value
    }

    if ([Console]::IsInputRedirected) {
        Write-Host $Prompt -NoNewline
        $line = [Console]::In.ReadLine()
        Write-Host $line
        return $line
    }
    return (Read-Host $Prompt)
}

function Wait-Enter {
    # Im Warteschlangenmodus entfaellt die Bestaetigung: sonst muesste hinter
    # jeder Menuezahl eine Leerzeile stehen.
    if ($script:Queue) { return }
    if ([Console]::IsInputRedirected) {
        $null = [Console]::In.ReadLine()
        return
    }
    $null = Read-Host '  Enter'
}

# ---------------------------------------------------------------- Gerät
function Get-AdbValue {
    param([string]$Arguments)
    $out = & $script:Adb -s $script:Serial shell $Arguments 2>$null | Out-String
    return ($out -replace "`r", '').Trim()
}

function Find-Device {
    if (-not (Test-Path -LiteralPath $script:Adb)) {
        throw "adb nicht gefunden: $script:Adb"
    }

    $devices = (& $script:Adb devices 2>$null | Out-String) -replace "`r", ''
    $online = @()
    foreach ($line in ($devices -split "`n")) {
        if ($line -match '^(\S+)\s+device\s*$') { $online += $Matches[1] }
    }

    if ($online.Count -eq 0) { return $false }

    # Bevorzugt das iPad-Geraet. Sonst irgendein Emulator.
    $script:Serial = $null
    foreach ($d in $online) {
        $model = (& $script:Adb -s $d shell getprop ro.product.model 2>$null | Out-String).Trim()
        $w = (& $script:Adb -s $d shell wm size 2>$null | Out-String).Trim()
        if ($w -match '1620x2160') {
            $script:Serial = $d
            $script:DeviceModel = $model
            return $true
        }
    }

    $script:Serial = $online[0]
    $script:DeviceModel = (& $script:Adb -s $online[0] shell getprop ro.product.model 2>$null | Out-String).Trim()
    return $true
}

function Get-DeviceState {
    $state = [ordered]@{
        Running   = $false
        Serial    = ''
        Model     = ''
        Android   = ''
        Api       = ''
        Size      = ''
        Density   = ''
        Logical   = ''
        IpadMatch = $false
        Uptime    = ''
    }

    if (-not (Find-Device)) { return [pscustomobject]$state }

    $state.Running = $true
    $state.Serial = $script:Serial
    $state.Model = Get-AdbValue 'getprop ro.product.model'
    $state.Android = Get-AdbValue 'getprop ro.build.version.release'
    $state.Api = Get-AdbValue 'getprop ro.build.version.sdk'

    $sizeRaw = Get-AdbValue 'wm size'
    if ($sizeRaw -match '(\d+x\d+)') { $state.Size = $Matches[1] }
    $densRaw = Get-AdbValue 'wm density'
    if ($densRaw -match '(\d+)') { $state.Density = $Matches[1] }

    # $Matches wird bei jedem -match neu gesetzt. Die Werte muessen sofort in
    # eigene Variablen, sonst ueberschreibt die Dichte-Pruefung die Breite.
    if ($state.Size -match '^(\d+)x(\d+)$') {
        $w = [int]$Matches[1]
        $h = [int]$Matches[2]
        if ($state.Density -match '^\d+$') {
            $d = [int]$state.Density
            if ($d -gt 0) {
                $state.Logical = "$([math]::Round($w * 160 / $d))x$([math]::Round($h * 160 / $d)) dp"
            }
        }
    }

    # iPad 9 hat 1620x2160 bei 320 dpi = 810x1080 dp
    $state.IpadMatch = ($state.Size -eq '1620x2160') -and ($state.Density -eq '320')

    $up = Get-AdbValue 'cat /proc/uptime'
    if ($up -match '^([\d.]+)') {
        $state.Uptime = "$([math]::Round([double]$Matches[1])) s"
    }

    return [pscustomobject]$state
}

# ---------------------------------------------------------------- Aktionen
function Start-Device {
    Write-Head 'Geraet starten'

    $state = Get-DeviceState
    if ($state.Running) {
        Write-Ok "Laeuft bereits: $($state.Serial)"
        return
    }

    if (-not (Test-Path -LiteralPath $script:Emulator)) {
        Write-Err "Emulator nicht gefunden: $script:Emulator"
        return
    }

    Write-Info "Starte AVD '$script:Device' mit Fenster..."
    $args = @('-avd', $script:Device, '-gpu', 'host', '-no-boot-anim', '-no-snapshot-load')
    Start-Process -FilePath $script:Emulator -ArgumentList $args | Out-Null
    Add-Log "Geraet gestartet: $script:Device"

    Write-Info 'Warte auf Boot (maximal 5 Minuten)...'
    & $script:Adb start-server 2>$null | Out-Null

    for ($i = 1; $i -le 60; $i++) {
        Start-Sleep -Seconds 5
        $boot = (& $script:Adb -s 'emulator-5554' shell getprop sys.boot_completed 2>$null | Out-String).Trim()
        if ($boot -eq '1') {
            Write-Ok "Boot nach etwa $($i * 5) Sekunden"
            return
        }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Warn2 'Boot nicht abgeschlossen. Emulator-Fenster pruefen.'
}

function Stop-Device {
    Write-Head 'Geraet beenden'
    if (-not (Find-Device)) { Write-Info 'Kein Geraet aktiv.'; return }

    $serial = $script:Serial
    & $script:Adb -s $serial emu kill 2>$null | Out-Null
    Add-Log "Geraet beendet: $serial"

    # 'emu kill' ist eine Bitte, kein Befehl. Der Emulator braucht zum
    # Herunterfahren mehrere Sekunden - eine feste Wartezeit von 3 s war zu
    # kurz und meldete faelschlich 'antwortet noch'.
    for ($i = 1; $i -le 20; $i++) {
        Start-Sleep -Seconds 2
        $devices = (& $script:Adb devices 2>$null | Out-String) -replace "`r", ''
        if ($devices -notmatch [regex]::Escape($serial)) {
            Write-Ok "Beendet nach etwa $($i * 2) Sekunden"
            return
        }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Warn2 'Geraet antwortet noch. Notfalls Prozess beenden:'
    Write-Info 'Get-Process emulator* | Stop-Process -Force'
}

function Show-Status {
    Write-Head 'Status'
    $s = Get-DeviceState
    if (-not $s.Running) {
        Write-Warn2 'Kein Geraet verbunden.'
        Write-Info "Starten mit Option [1]"
        return
    }
    Write-Line ("  {0,-14} {1}" -f 'Seriennummer', $s.Serial)
    Write-Line ("  {0,-14} {1}" -f 'Modell', $s.Model)
    Write-Line ("  {0,-14} {1}" -f 'Android', "$($s.Android) (API $($s.Api))")
    Write-Line ("  {0,-14} {1}" -f 'Aufloesung', $s.Size)
    Write-Line ("  {0,-14} {1}" -f 'Dichte', "$($s.Density) dpi")
    Write-Line ("  {0,-14} {1}" -f 'Layout', $s.Logical)
    Write-Line ("  {0,-14} {1}" -f 'Laufzeit', $s.Uptime)
    Write-Host ''
    if ($s.IpadMatch) {
        Write-Ok 'Entspricht dem iPad 9 (1620x2160 @ 2x = 810x1080 pt)'
    } else {
        Write-Warn2 'Entspricht NICHT dem iPad 9. Erwartet 1620x2160 bei 320 dpi.'
    }
}

function Set-Orientation {
    param([ValidateSet('portrait', 'landscape')][string]$Mode)
    if (-not (Find-Device)) { Write-Warn2 'Kein Geraet.'; return }
    $v = if ($Mode -eq 'portrait') { 0 } else { 1 }
    & $script:Adb -s $script:Serial shell settings put system user_rotation $v 2>$null | Out-Null
    & $script:Adb -s $script:Serial shell settings put system accelerometer_rotation 0 2>$null | Out-Null
    Write-Ok "Ausrichtung: $Mode"
    Add-Log "Ausrichtung $Mode"
}

function Save-Screenshot {
    param([string]$Suffix = '')
    if (-not (Find-Device)) { Write-Warn2 'Kein Geraet.'; return }

    if (-not $Suffix) { $Suffix = Get-Date -Format 'HHmmss' }
    $file = Join-Path $script:ShotDir "ipad9-$Suffix.png"

    # Bildschirm zuerst wecken, sonst wird ein schwarzes Bild aufgenommen.
    & $script:Adb -s $script:Serial shell input keyevent KEYCODE_WAKEUP 2>$null | Out-Null
    & $script:Adb -s $script:Serial shell wm dismiss-keyguard 2>$null | Out-Null
    Start-Sleep -Milliseconds 1200

    # Nicht exec-out verwenden: PowerShell 5.1 wandelt Binaerausgabe in
    # Strings um und zerstoert dabei das PNG. Auf dem Geraet ablegen und
    # herunterladen ist zeichenunabhaengig.
    $remote = '/sdcard/ipad9-shot.png'
    & $script:Adb -s $script:Serial shell screencap -p $remote 2>$null | Out-Null
    & $script:Adb -s $script:Serial pull $remote $file 2>$null | Out-Null
    & $script:Adb -s $script:Serial shell rm -f $remote 2>$null | Out-Null

    if (-not (Test-Path -LiteralPath $file)) {
        Write-Err 'Screenshot fehlgeschlagen.'
        return
    }

    $info = Get-ImageInfo $file
    $kb = [math]::Round((Get-Item -LiteralPath $file).Length / 1KB, 1)

    # Ein abgeschaltetes Display liefert ein komplett schwarzes Bild. Die
    # Dateigroesse verraet das nicht, die mittlere Helligkeit schon.
    if ($info.Brightness -ge 0 -and $info.Brightness -lt 2) {
        Write-Warn2 "Bild ist schwarz (Helligkeit $($info.Brightness), $kb KB)."
        Write-Info 'Das Display war aus. Erst -Action wake, dann erneut aufnehmen.'
    } elseif ($info.Width -ne 1620 -or $info.Height -ne 2160) {
        Write-Warn2 "Unerwartete Groesse: $($info.Width)x$($info.Height) px"
        Write-Info "Erwartet wird 1620x2160. Datei: $file"
    } else {
        Write-Ok "Screenshot: $file"
        Write-Info "$($info.Width)x$($info.Height) px - entspricht dem iPad 9, Helligkeit $($info.Brightness), $kb KB"
    }
    Add-Log "Screenshot $Suffix"
    return $file
}

<#
    Liest Groesse und Helligkeit eines PNG. Die Dateigroesse taugt nicht als
    Schwarz-Test: ein weisser Flutter-Bildschirm komprimiert auf 53 KB und ein
    schwarzer auf 52 KB. Es muss auf die Pixel geschaut werden.
#>
function Get-ImageInfo {
    param([string]$Path)
    $result = [pscustomobject]@{ Width = 0; Height = 0; Brightness = -1 }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $img = [System.Drawing.Image]::FromFile($Path)
        try {
            $result.Width = $img.Width
            $result.Height = $img.Height

            # Ein Raster von 24x24 Punkten abtasten und die mittlere Helligkeit
            # bilden. Das ist genau genug fuer "Display aus" und billig.
            $bmp = New-Object System.Drawing.Bitmap $img
            try {
                $sum = 0.0
                $n = 0
                $stepX = [Math]::Max(1, [int]($bmp.Width / 24))
                $stepY = [Math]::Max(1, [int]($bmp.Height / 24))
                for ($y = 0; $y -lt $bmp.Height; $y += $stepY) {
                    for ($x = 0; $x -lt $bmp.Width; $x += $stepX) {
                        $c = $bmp.GetPixel($x, $y)
                        $sum += (0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B)
                        $n++
                    }
                }
                if ($n -gt 0) { $result.Brightness = [math]::Round($sum / $n, 2) }
            } finally {
                $bmp.Dispose()
            }
        } finally {
            $img.Dispose()
        }
    } catch {
        # Fallback ohne System.Drawing: Groesse aus dem PNG-Kopf.
        try {
            $b = [IO.File]::ReadAllBytes($Path)
            if ($b.Length -gt 24 -and $b[1] -eq 0x50) {
                # Die Bytes muessen vor dem Verschieben zu [int] werden: -shl
                # behaelt den Typ des linken Operanden, ein Byte laeuft bei
                # 24 Bit stillschweigend ueber.
                $result.Width = ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19]
                $result.Height = ([int]$b[20] -shl 24) -bor ([int]$b[21] -shl 16) -bor ([int]$b[22] -shl 8) -bor [int]$b[23]
            }
        } catch { }
    }
    return $result
}

function Open-Screenshot {
    $latest = Get-ChildItem -LiteralPath $script:ShotDir -Filter '*.png' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $latest) { Write-Warn2 'Kein Screenshot vorhanden.'; return }
    Start-Process $latest.FullName
    Write-Ok "Geoeffnet: $($latest.Name)"
}

<#
    Liest die applicationId aus dem Projekt, statt sie zu raten. Ohne das
    startet monkey ein Paket, das es nicht gibt, und die App bleibt einfach
    im Hintergrund - ohne Fehlermeldung.
#>
function Get-AppId {
    param([string]$Path)

    $gradle = Get-ChildItem -LiteralPath (Join-Path $Path 'android\app') -Filter 'build.gradle*' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($gradle) {
        $text = Get-Content -LiteralPath $gradle.FullName -Raw
        if ($text -match 'applicationId\s*=?\s*["'']([^"'']+)["'']') {
            return $Matches[1]
        }
    }

    # Fallback: im Manifest nachsehen
    $manifest = Join-Path $Path 'android\app\src\main\AndroidManifest.xml'
    if (Test-Path -LiteralPath $manifest) {
        $text = Get-Content -LiteralPath $manifest -Raw
        if ($text -match 'package\s*=\s*["'']([^"'']+)["'']') { return $Matches[1] }
    }
    return $null
}

<#
    Startet die App und prueft, ob sie wirklich im Vordergrund ist. monkey
    waehlt die Activity nur ueber einen Intent-Filter aus und schlaegt still
    fehl; am start mit der aufgeloesten Activity ist eindeutig.
#>
function Start-App {
    param([string]$AppId)

    $resolved = (& $script:Adb -s $script:Serial shell cmd package resolve-activity --brief $AppId 2>$null | Out-String) -replace "`r", ''
    $activity = $null
    foreach ($line in ($resolved -split "`n")) {
        if ($line -match '^\s*(\S+/\S+)\s*$') { $activity = $Matches[1]; break }
    }

    if ($activity) {
        Write-Info "Activity: $activity"
        & $script:Adb -s $script:Serial shell am start -n $activity 2>&1 | Out-Null
    } else {
        Write-Warn2 "Keine Activity fuer '$AppId' gefunden. Versuche Launcher-Intent."
        & $script:Adb -s $script:Serial shell monkey -p $AppId -c android.intent.category.LAUNCHER 1 2>$null | Out-Null
    }

    Start-Sleep -Seconds 14

    # Display wach halten. Ohne das schlaeft der Bildschirm waehrend des
    # Wartens ein und der Screenshot wird schwarz.
    & $script:Adb -s $script:Serial shell svc power stayon true 2>$null | Out-Null
    & $script:Adb -s $script:Serial shell input keyevent KEYCODE_WAKEUP 2>$null | Out-Null
    & $script:Adb -s $script:Serial shell wm dismiss-keyguard 2>$null | Out-Null
    Start-Sleep -Seconds 1

    # Pruefen, ob die App tatsaechlich vorne ist
    $focus = (& $script:Adb -s $script:Serial shell dumpsys window 2>$null | Out-String) -replace "`r", ''
    $m = [regex]::Match($focus, 'mCurrentFocus=Window\{[^}]*\s([\w.]+)/([\w.$]+)')
    if ($m.Success) {
        $top = "$($m.Groups[1].Value)/$($m.Groups[2].Value)"
        if ($top -like "$AppId*" -or $m.Groups[1].Value -eq $AppId) {
            Write-Ok "App ist im Vordergrund: $top"
            return $true
        }
        Write-Warn2 "Im Vordergrund ist: $top"
        Write-Info "Die App laeuft, aber ein anderes Fenster liegt oben."
        return $false
    }
    Write-Info 'Vordergrundfenster nicht ermittelbar.'
    return $false
}

function Install-App {
    Write-Head 'App installieren und starten'

    if (-not (Find-Device)) { Write-Warn2 'Kein Geraet.'; return }

    if (-not (Test-Path -LiteralPath $script:Flutter)) {
        Write-Err "Flutter nicht gefunden: $script:Flutter"
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectPath 'pubspec.yaml'))) {
        Write-Err "Kein Flutter-Projekt: $script:ProjectPath"
        return
    }

    $appId = Get-AppId -Path $script:ProjectPath
    if ($appId) {
        Write-Info "Paketname: $appId"
    } else {
        Write-Warn2 "Paketname nicht ermittelbar, verwende '$script:AppName'"
        $appId = $script:AppName
    }

    Write-Info "Projekt: $script:ProjectPath"
    Write-Info 'Baue APK (kann beim ersten Mal mehrere Minuten dauern)...'

    Push-Location $script:ProjectPath
    try {
        $build = & $script:Flutter build apk --debug 2>&1 | Out-String
        $ok = $build -match 'app-debug\.apk'
        if (-not $ok) {
            Write-Err 'Build fehlgeschlagen. Letzte Zeilen:'
            foreach ($l in (($build -split "`n") | Select-Object -Last 12)) {
                Write-Line "    $($l.Trim())" 'DarkGray'
            }
            return
        }
        Write-Ok 'Build erfolgreich'
    } finally {
        Pop-Location
    }

    $apk = Join-Path $script:ProjectPath 'build\app\outputs\flutter-apk\app-debug.apk'
    if (-not (Test-Path -LiteralPath $apk)) { Write-Err "APK fehlt: $apk"; return }

    Write-Info 'Installiere...'
    $res = & $script:Adb -s $script:Serial install -r $apk 2>&1 | Out-String
    if ($res -match 'Success') {
        Write-Ok 'Installiert'
    } else {
        Write-Err "Installation fehlgeschlagen: $(($res -split "`n" | Select-Object -Last 2) -join ' ')"
        return
    }

    # Vor dem Start wach halten, sonst schlaeft das Display mitten im Test ein.
    & $script:Adb -s $script:Serial shell svc power stayon true 2>$null | Out-Null

    Write-Info "Starte $appId..."
    Start-App -AppId $appId | Out-Null

    Write-Head 'App auf dem iPad 9'
    Save-Screenshot -Suffix "$(Get-Date -Format 'HHmmss')-app" | Out-Null
    Add-Log "App installiert: $appId"
}

function Run-HotReload {
    Write-Head 'Flutter im Debug-Modus (Hot Reload)'
    if (-not (Find-Device)) { Write-Warn2 'Kein Geraet.'; return }
    if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectPath 'pubspec.yaml'))) {
        Write-Err "Kein Flutter-Projekt: $script:ProjectPath"; return
    }
    Write-Info 'Startet Flutter im Vordergrund.'
    Write-Info 'Im Flutter-Terminal: r = Hot Reload, R = Neustart, q = beenden'
    Write-Host ''
    Push-Location $script:ProjectPath
    try {
        & $script:Flutter run -d $script:Serial
    } finally {
        Pop-Location
    }
}

function Wake-Device {
    if (-not (Find-Device)) { Write-Warn2 'Kein Geraet.'; return }
    & $script:Adb -s $script:Serial shell svc power stayon true 2>$null | Out-Null
    & $script:Adb -s $script:Serial shell input keyevent KEYCODE_WAKEUP 2>$null | Out-Null
    & $script:Adb -s $script:Serial shell input keyevent 82 2>$null | Out-Null
    & $script:Adb -s $script:Serial shell wm dismiss-keyguard 2>$null | Out-Null
    Write-Ok 'Display geweckt, entsperrt und bleibt an'
}

function Set-IpadMetrics {
    Write-Head 'iPad-9-Masse setzen'
    if (-not (Find-Device)) { Write-Warn2 'Kein Geraet.'; return }

    & $script:Adb -s $script:Serial shell wm size 1620x2160 2>$null | Out-Null
    & $script:Adb -s $script:Serial shell wm density 320 2>$null | Out-Null
    Write-Ok 'Aufloesung 1620x2160, Dichte 320 dpi'
    Write-Info '1620/2 = 810 sp, 2160/2 = 1080 pt - identisch mit dem iPad 9'
    Start-Sleep -Seconds 2
    Show-Action 'Status'
}

function Show-Action {
    param([string]$Name)
    switch ($Name) {
        'Status'       { Show-Status }
        'Start'        { Start-Device }
        'Stop'         { Stop-Device }
        'Shot'         { Save-Screenshot | Out-Null }
        'Open'         { Open-Screenshot }
        'Install'      { Install-App }
        'Reload'       { Run-HotReload }
        'Wake'         { Wake-Device }
        'Metrics'      { Set-IpadMetrics }
        'Portrait'     { Set-Orientation 'portrait' }
        'Landscape'    { Set-Orientation 'landscape' }
    }
}

function Show-Menu {
    Clear-Screen
    Write-Host ''
    Write-Host '  iPad 9 - Emuliertes Geraet' -ForegroundColor Cyan
    Write-Host "  $script:Device  |  1620x2160 px @ 320 dpi = 810x1080 dp" -ForegroundColor DarkGray
    Write-Host ('  ' + ('=' * 66)) -ForegroundColor DarkGray

    $s = Get-DeviceState
    if ($s.Running) {
        $mark = if ($s.IpadMatch) { 'iPad 9 bestaetigt' } else { 'andere Aufloesung' }
        Write-Host "  Geraet: $($s.Serial)  $($s.Model)  Android $($s.Android)" -ForegroundColor Green
        Write-Host "  $($s.Size) @ $($s.Density) dpi  =  $($s.Logical)   [$mark]" -ForegroundColor DarkGray
    } else {
        Write-Host '  Geraet: nicht verbunden' -ForegroundColor Yellow
    }
    Write-Host ('  ' + ('=' * 66)) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  GERAET' -ForegroundColor White
    Write-Host '    1  Geraet starten (mit Fenster)' -ForegroundColor Gray
    Write-Host '    2  Geraet beenden' -ForegroundColor Gray
    Write-Host '    3  Status anzeigen' -ForegroundColor Gray
    Write-Host '    4  Display wecken / entsperren' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  APP' -ForegroundColor White
    Write-Host '    5  App bauen, installieren, starten' -ForegroundColor Gray
    Write-Host '    6  Flutter mit Hot Reload starten' -ForegroundColor Gray
    Write-Host "       Projekt: $script:ProjectPath" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  ANSICHT' -ForegroundColor White
    Write-Host '    7  Screenshot aufnehmen' -ForegroundColor Gray
    Write-Host '    8  Letzten Screenshot oeffnen' -ForegroundColor Gray
    Write-Host '    9  Hochformat (Portrait)' -ForegroundColor Gray
    Write-Host '   10  Querformat (Landscape)' -ForegroundColor Gray
    Write-Host '   11  iPad-9-Masse neu setzen' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  INFO' -ForegroundColor White
    Write-Host '   12  Geraetedefinition anzeigen' -ForegroundColor Gray
    Write-Host '   13  Protokoll anzeigen' -ForegroundColor Gray
    Write-Host '    h  Hilfe / Grenzen' -ForegroundColor Gray
    Write-Host '    q  Beenden' -ForegroundColor Gray
    Write-Host ''
}

function Show-DeviceDefinition {
    Write-Head 'Geraetedefinition'
    $def = Join-Path $script:Root 'tools\devices\ipad9-2021.json'
    if (Test-Path -LiteralPath $def) {
        $json = Get-Content -LiteralPath $def -Raw | ConvertFrom-Json
        Write-Line ("  {0,-16} {1}" -f 'Name', $json.name)
        Write-Line ("  {0,-16} {1}" -f 'Produkt', $json.specs.productName)
        Write-Line ("  {0,-16} {1}" -f 'Jahr', $json.specs.releaseYear)
        Write-Line ("  {0,-16} {1}" -f 'Bildschirm', "$($json.specs.screenInches) Zoll")
        Write-Line ("  {0,-16} {1}" -f 'Pixel', "$($json.specs.nativePixels -join ' x ')")
        Write-Line ("  {0,-16} {1}" -f 'Skalierung', "@$($json.specs.scale)x")
        Write-Line ("  {0,-16} {1}" -f 'Logische Punkte', "$($json.specs.logicalPoints -join ' x ')")
        Write-Line ("  {0,-16} {1}" -f 'PPI', $json.specs.ppi)
        Write-Line ("  {0,-16} {1}" -f 'Chip', $json.specs.cpu)
        Write-Host ''
        Write-Line ("  {0,-16} {1}" -f 'AVD', $json.emulation.avdName)
        Write-Line ("  {0,-16} {1}" -f 'Dichte', "$($json.emulation.dpi) dpi")
        Write-Line ("  {0,-16} {1}" -f 'RAM', "$($json.emulation.ramMB) MB")
        Write-Host ''
        Write-Info $json.emulation.why320dpi
    } else {
        Write-Warn2 "Nicht gefunden: $def"
    }
}

function Show-Help {
    Write-Head 'Grenzen dieses Geraets'
    Write-Line @'
  Was dieses Geraet leistet:

    Das AVD hat exakt die Abmessungen des iPad 9:
      1620 x 2160 Pixel bei 320 dpi
      = 810 x 1080 dp logische Flaeche
      = dieselben Werte wie das echte iPad 9 (1620x2160 @2x)

    Ein Layout, das hier passt, passt auch auf dem echten iPad 9.
    Das Seitenverhaeltnis ist 4:3 wie beim iPad.

  Was es nicht leistet:

    Darunter laeuft Android, nicht iOS. Deshalb fehlen:
      - UIKit und SwiftUI
      - iOS-Widgets, SF Symbols, iOS-Navigation
      - echte iOS-Schriftgroessen und Animationen
      - der App Store und die Signierung

    Fuer den echten iOS-Simulator braucht es macOS. Hier auf Windows ist
    das nicht moeglich - auch nicht in WSL. Gemessen und belegt in
    docs/ios-simulator-messung.md.

  Wofuer es taugt:

    - Layout pruefen: bricht der Text um, passt die Sidebar, stimmen die
      Rastergroessen bei 810x1080 dp
    - Flutter-Apps iterativ entwickeln, mit Hot Reload
    - Screenshots als Referenz fuer das iPad-Format erzeugen
    - Fehler finden, bevor der macOS-Runner startet (spart CI-Minuten)

  Der echte Simulator:

    Laeuft auf dem macOS-Runner (Codemagic oder GitHub Actions) mit
    iPhone 17 Pro und iPad Pro 11-inch (M5).
    Siehe docs/simulator-via-github-actions.md
'@ 'Gray'
}

function Show-Log {
    Write-Head 'Protokoll'
    if ($script:Log.Count -eq 0) { Write-Info 'Noch keine Eintraege.'; return }
    foreach ($entry in $script:Log) { Write-Line "  $entry" 'Gray' }
}

# ---------------------------------------------------------------- Hauptablauf
$script:UseColor = $true

# Ergebnispruefung: sind alle noetigen Dateien vorhanden?
if (-not (Test-Path -LiteralPath $script:Adb)) {
    Write-Err "adb fehlt: $script:Adb"
    Write-Info 'Android SDK neu installieren oder ANDROID_HOME setzen.'
    exit 2
}

# Direktmodus: eine Aktion ausfuehren und beenden. Fuer Skripte und Tests.
if ($Action -and $Action -ne 'menu') {
    $map = @{
        'start' = 'Start'; 'stop' = 'Stop'; 'status' = 'Status'; 'wake' = 'Wake'
        'install' = 'Install'; 'reload' = 'Reload'; 'shot' = 'Shot'
        'open' = 'Open'; 'portrait' = 'Portrait'; 'landscape' = 'Landscape'
        'metrics' = 'Metrics'
    }
    switch ($Action) {
        'definition' { Show-DeviceDefinition }
        'help'       { Show-Help }
        'log'        { Show-Log }
        default      { Show-Action $map[$Action] }
    }
    exit 0
}

# Menueeingaben aus -Commands als Warteschlange.
# Aus bash/Git Bash kommt '3,12,q' als einzelne Zeichenkette an, aus
# PowerShell als echtes Array. Beide Formen werden zerlegt.
$script:Queue = $null
$script:QueueIndex = 0
if ($Commands -and $Commands.Count -gt 0) {
    $flat = @()
    foreach ($c in $Commands) {
        foreach ($part in "$c" -split ',') {
            $t = $part.Trim()
            if ($t) { $flat += $t }
        }
    }
    if ($flat.Count -gt 0) {
        $script:Queue = $flat
        Write-Host ''
        Write-Host "  Ablauf: $($flat -join ' -> ')" -ForegroundColor DarkGray
    }
}

Write-Host ''
if (-not $script:Queue -and [Console]::IsInputRedirected) {
    Write-Host '  Hinweis: Die Eingabe ist umgeleitet. Das Menue braucht ein' -ForegroundColor DarkGray
    Write-Host '  echtes Terminal, oder -Commands bzw. -Action verwenden.' -ForegroundColor DarkGray
}

$running = $true
while ($running) {
    Show-Menu
    $choice = Read-Choice

    # Bei geschlossenem stdin liefert die Eingabe $null. Ohne diese Pruefung
    # wirft $choice.Trim() und die Schleife laeuft endlos weiter.
    if ($null -eq $choice) { $running = $false; continue }

    switch ($choice.Trim().ToLower()) {
        '1'  { Show-Action 'Start';     Wait-Enter }
        '2'  { Show-Action 'Stop';      Wait-Enter }
        '3'  { Show-Action 'Status';    Wait-Enter }
        '4'  { Show-Action 'Wake';      Wait-Enter }
        '5'  { Show-Action 'Install';   Wait-Enter }
        '6'  { Show-Action 'Reload' }
        '7'  { Show-Action 'Shot';      Wait-Enter }
        '8'  { Show-Action 'Open';      Wait-Enter }
        '9'  { Show-Action 'Portrait';  Wait-Enter }
        '10' { Show-Action 'Landscape'; Wait-Enter }
        '11' { Show-Action 'Metrics';   Wait-Enter }
        '12' { Show-DeviceDefinition;   Wait-Enter }
        '13' { Show-Log;                Wait-Enter }
        'h'  { Show-Help;               Wait-Enter }
        'q'  { $running = $false }
        ''   { }
        default { Write-Warn2 "Unbekannte Auswahl: $choice"; Start-Sleep -Seconds 1 }
    }
}

Write-Host ''
Write-Host '  Beendet.' -ForegroundColor Cyan
if (Find-Device) {
    Write-Info "Das Geraet laeuft weiter: $script:Serial"
    Write-Info 'Beenden mit Option 2 oder: adb -s emulator-5554 emu kill'
}
Write-Host ''
