@echo off
rem diag-lite v0.8 web launcher (ASCII-only on purpose)
rem Starts the local web server and opens the Edge app window.
rem The cmd host flashes for under a second, then only the
rem app window remains. Read-only probing. Nothing will be changed.
cd /d "%~dp0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "server.ps1"
