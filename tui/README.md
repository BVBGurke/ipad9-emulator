# iPad 9 als emuliertes Geraet

Ein Android-Geraet mit exakt den Abmessungen des iPad 9 (2021), gesteuert
ueber eine PowerShell-TUI.

## Warum das sinnvoll ist

Das iPad 9 hat 1620 x 2160 Pixel bei @2x. Das sind **810 x 1080 logische
Punkte**. Ein Android-Geraet mit derselben Pixelzahl und 320 dpi hat genau
dieselbe logische Flaeche, weil 1 dp bei 320 dpi exakt 2 px entspricht:

```
1620 px / 2 =  810 dp
2160 px / 2 = 1080 dp
```

| | iPad 9 | dieses AVD |
|---|---|---|
| Pixel | 1620 x 2160 | 1620 x 2160 |
| Skalierung | @2x | 320 dpi (= 2 px/dp) |
| Logische Punkte | 810 x 1080 | 810 x 1080 |
| Seitenverhaeltnis | 4:3 | 4:3 |

Ein Layout, das hier passt, passt auch auf dem echten iPad 9. Umbruch,
Rastergroessen und Seitenverhaeltnis stimmen punkgenau.

## Was es nicht ist

Darunter laeuft **Android, nicht iOS**. Es fehlen UIKit, SwiftUI, die
iOS-Widgets, SF Symbols und die iOS-Typografie. Der echte iOS-Simulator
braucht macOS und laeuft auf diesem Rechner nicht — auch nicht in WSL.
Gemessen in `docs/ios-simulator-messung.md`.

## Einrichten

```powershell
.\tools\devices\new-ipad9-device.ps1
```

Legt das AVD `iPad9_2021` an: Systemabbild laden, Geraet erstellen,
`config.ini` auf 1620x2160 @ 320 dpi setzen. Einmalig.

## Bedienen

```powershell
.\tools\tui\start-ipad-tui.bat
```

Doppelklick auf die `.bat` geht auch. Dann:

```
 GERAET
   1  Geraet starten (mit Fenster)
   2  Geraet beenden
   3  Status anzeigen
   4  Display wecken / entsperren

 APP
   5  App bauen, installieren, starten
   6  Flutter mit Hot Reload starten

 ANSICHT
   7  Screenshot aufnehmen
   8  Letzten Screenshot oeffnen
   9  Hochformat (Portrait)
  10  Querformat (Landscape)
  11  iPad-9-Masse neu setzen
```

## Ohne Menue (fuer Skripte)

```powershell
.\tools\tui\iPad-Tui.ps1 -Action status
.\tools\tui\iPad-Tui.ps1 -Action start
.\tools\tui\iPad-Tui.ps1 -Action install
.\tools\tui\iPad-Tui.ps1 -Action shot
.\tools\tui\iPad-Tui.ps1 -Action landscape
```

Ein Menueablauf laesst sich vorab festlegen:

```powershell
.\tools\tui\iPad-Tui.ps1 -Commands 3,7,q
```

## Anderes Projekt verwenden

```powershell
.\tools\tui\iPad-Tui.ps1 -ProjectPath ..\..\projects\meine-app
```

Der Paketname wird aus `android/app/build.gradle` gelesen. Wird er geraten,
startet die App nicht und bleibt stumm im Hintergrund.

## Testen ohne Geraet

```powershell
.\tools\conversations\check-syntax.ps1 -Path .\tools\tui\iPad-Tui.ps1
```

## Grenzen im Betrieb

- **Erster Start dauert.** Kaltstart des AVD etwa 35 Sekunden, danach
  Snapshots. Der erste `flutter build apk` braucht mehrere Minuten.
- **Display schlaeft ein.** Vor jedem Screenshot wecken (`-Action wake`);
  die TUI setzt bei Bedarf `svc power stayon true`.
- **Schwarze Screenshots sind erkennbar.** Die TUI misst die mittlere
  Helligkeit. Unter 2 von 255 gilt das Bild als abgeschaltet — die
  Dateigroesse taugt dafuer nicht, ein weisser Bildschirm komprimiert
  genauso stark wie ein schwarzer.
- **Ausrichtung folgt der App.** Ein Tablet-Layout bleibt quer, auch wenn
  Hochformat gesetzt ist.
