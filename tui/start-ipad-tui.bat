@echo off
REM Startet die iPad-TUI. Doppelklick genuegt.
REM Die Ausfuehrungsrichtlinie wird nur fuer diesen Aufruf gelockert.

setlocal
set "PS1=%~dp0iPad-Tui.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*

if errorlevel 1 (
    echo.
    echo Die TUI wurde mit Fehlercode %errorlevel% beendet.
    pause
)
endlocal
