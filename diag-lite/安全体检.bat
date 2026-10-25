@echo off
rem diag-lite v1.5.0 security check launcher (ASCII-only on purpose)
cd /d "%~dp0"
echo ==============================================================
echo   diag Security Check v1.5.0
echo   Read-only probing. Nothing on your PC will be changed.
echo   Takes 1-3 minutes. Please wait...
echo ==============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "engineun.ps1" -TreeName security -Full -OpenReport
echo.
echo ==============================================================
echo   Finished. The report should open in your web browser
echo   automatically (styled HTML, evidence collapsible).
echo   (also saved in the reports folder, newest .html file)
echo   If nothing opened, open the newest .html in reports
echo ==============================================================
pause
