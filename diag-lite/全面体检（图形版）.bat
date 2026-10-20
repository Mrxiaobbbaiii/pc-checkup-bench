@echo off
rem diag-lite v0.6 GUI launcher (ASCII-only on purpose)
rem Starts the diag checkup window (WinForms GUI).
rem The cmd host flashes for under a second, then only the
rem window remains. Read-only probing. Nothing will be changed.
cd /d "%~dp0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "gui\run_gui.ps1"
