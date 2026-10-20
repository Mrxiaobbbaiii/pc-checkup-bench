@echo off
rem diag-lite v0.2.1 network check launcher (ASCII-only on purpose)
cd /d "%~dp0"
echo ==============================================================
echo   diag Network Check v0.2.1
echo   Read-only probing. Nothing on your PC will be changed.
echo   Takes 1-3 minutes. Please wait...
echo ==============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "engine\run.ps1" -OpenReport
echo.
echo ==============================================================
echo   Finished. The report should open in your web browser
echo   automatically (styled HTML, evidence collapsible).
echo   (also saved in the reports folder, newest .html file)
echo   If nothing opened, open the newest .html in reports
echo ==============================================================
pause
