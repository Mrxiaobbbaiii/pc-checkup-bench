@echo off
rem diag-lite v1.2.0 all-in-one launcher (ASCII-only on purpose)
rem A Chinese menu is rendered by engine\run.ps1 itself:
rem   press Enter = run all five trees (one merged report),
rem   or type 1-5 to run a single tree.
cd /d "%~dp0"
echo ==============================================================
echo   diag Full Checkup v1.2.0
echo   network / bluescreen / hardware / performance / drivers
echo   Read-only probing. Nothing on your PC will be changed.
echo   A menu will appear next: press Enter to check ALL five
echo   trees (several minutes, one merged report), or type 1-5
echo   to check just one tree.
echo ==============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "engine\run.ps1" -TreeName all -Full -OpenReport
echo.
echo ==============================================================
echo   Finished. The report should open in your web browser
echo   automatically (styled HTML, evidence collapsible).
echo   (also saved in the reports folder, newest .html file)
echo   If nothing opened, open the newest .html in reports
echo ==============================================================
pause
