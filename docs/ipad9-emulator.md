# Emuliertes iPad 9: Messung und Grenzen

Stand: 2026-10-16. Alle Werte auf diesem Rechner gemessen, nicht angenommen.

## Das Geraet

AVD `iPad9_2021`, angelegt von `tools/devices/new-ipad9-device.ps1`, bedient
von `tools/tui/IPad-Tui.ps1`.

| | Soll (iPad 9) | Gemessen |
|---|---|---|
| Aufloesung | 1620 x 2160 | **1620 x 2160** |
| Dichte | @2x | **320 dpi** |
| Logische Flaeche | 810 x 1080 pt | **810 x 1080 dp** |
| Seitenverhaeltnis | 4:3 | **4:3** |
| Screenshot | 1620 x 2160 | **1620 x 2160** |

Nachweis der Werte am laufenden Geraet:

```
$ adb shell wm size
Physical size: 1620x2160

$ adb shell wm density
Physical density: 320

$ adb shell getprop ro.build.version.release
15
```

Der Screenshot wurde zusaetzlich als PNG ausgelesen und im Dateikopf geprueft:
`1620 x 2160`. Querformat liefert `2160 x 1620`.

## Warum 320 dpi richtig ist

Bei 320 dpi entspricht 1 dp genau 2 px. Damit gilt:

```
1620 px / 2 px/dp =  810 dp
2160 px / 2 px/dp = 1080 dp
```

Das sind die logischen Punkte des echten iPad 9 (1620x2160 bei @2x). Waere
die Dichte 160 dpi, ergaebe dieselbe Pixelzahl 1620x2160 dp — das Layout waere
um Faktor 2 zu gross und jede Beurteilung falsch.

## Was das Geraet leistet

Belegt mit einem laufenden Flutter-Build:

- App-Bau: `flutter build apk --debug` erfolgreich
- Installation ueber `adb install -r`, danach im Vordergrund:
  `dev.gerdi.flutter_probe/.MainActivity`
- Darstellung im Tablet-Layout auf 810x1080 dp
- Querformat 2160x1620, Hochformat 1620x2160
- Emulator-Fenster real vorhanden:
  `Android Emulator - iPad9_2021:5554`

## Was es nicht leistet

Es laeuft Android darunter. Damit fehlen UIKit, SwiftUI, iOS-Widgets,
SF Symbols, die iOS-Typografie, Signierung und der App Store. Der echte
iOS-Simulator setzt macOS und Metal voraus — auf diesem Rechner gemessen
ausgeschlossen, siehe `ios-simulator-messung.md`.

Der praktische Nutzen liegt vor dem CI-Lauf: Layoutfehler, Umbruchprobleme
und Rastergroessen finden sich hier in Sekunden statt in macOS-CI-Minuten.

## Beim Testen gefundene Fehler

Sieben Fehler, jeder erst durch Ausfuehren sichtbar:

1. **`Layout 0x0 dp`.** `$Matches` wird von jedem `-match` neu gesetzt. Die
   Dichte-Pruefung ueberschrieb Breite und Hoehe, bevor sie ausgelesen waren.
2. **Endlosschleife bei leerer Eingabe.** `Read-Host` liefert bei
   geschlossenem stdin `$null`; `$null.Trim()` wirft, die Schleife lief weiter.
3. **Zerstoerte PNG-Datei.** `exec-out screencap` durch PowerShell 5.1
   wandelt Binaerdaten in Strings um. Jetzt `screencap` auf dem Geraet und
   `adb pull`.
4. **Falsche Bildgroesse (84x112).** `-shl` behaelt den Typ des linken
   Operanden; ein `[byte]` laeuft bei 24 Bit stillschweigend ueber. Erst
   `[int]` vor dem Verschieben liefert 1620.
5. **Schwarzbild-Heuristik unbrauchbar.** Ein weisser Flutter-Bildschirm
   komprimiert auf 52,5 KB, ein schwarzer auf 52,6 KB. Die Dateigroesse sagt
   nichts. Jetzt wird die mittlere Helligkeit gemessen:
   schwarz = 0, Inhalt = 244,55 (von 255).
6. **App startete nicht.** Der Paketname war geraten
   (`com.example.flutter_probe`), tatsaechlich heisst er
   `dev.gerdi.flutter_probe`. `monkey` schlug still fehl. Jetzt wird die
   `applicationId` aus `build.gradle` gelesen und die Activity ueber
   `resolve-activity` aufgeloest.
7. **`Beendet` meldete sich zu frueh.** `adb emu kill` ist eine Bitte; das
   Herunterfahren dauert. Feste 3 Sekunden Wartezeit waren zu kurz. Jetzt
   eine Warteschleife bis zu 40 Sekunden.

Dazu eine Eigenheit von Git Bash: MSYS wandelt `/sdcard/x.png` in einen
Windows-Pfad um und `screencap` scheitert. In PowerShell tritt das nicht auf.

## Testbefehle

```powershell
# Werte am Geraet pruefen
.\tools\tui\iPad-Tui.ps1 -Action status

# Vollstaendiger Ablauf ohne Terminal
.\tools\tui\iPad-Tui.ps1 -Commands 3,7,q

# App bauen, installieren, starten, fotografieren
.\tools\tui\iPad-Tui.ps1 -Action install

# Syntaxpruefung
.\tools\conversations\check-syntax.ps1 -Path .\tools\tui\iPad-Tui.ps1
```
