@echo off
rem diag-lite v1.1.0 installer (no admin needed)
rem Chinese prompts are GBK-encoded on purpose; keep CRLF when editing.
setlocal
set "TARGET=%LOCALAPPDATA%\电脑体检台"
echo ==============================================
echo   电脑体检台 v1.1.0 一键安装
echo ==============================================
echo.
echo  安装位置：%TARGET%
echo  说明：免管理员权限；已有旧版会覆盖升级；你自己在 ext 目录加的检查和历史报告都会保留。
echo  如果体检窗口正开着，请先关掉再装。
echo.
choice /c YN /m "确认安装到上面这个位置吗？(Y=安装 N=取消)"
if errorlevel 2 goto cancelled
robocopy "%~dp0." "%TARGET%" /E /IS /IT /NFL /NDL /NJH /NJS /NP
if errorlevel 8 goto fail
echo.
echo  [安装完成] 程序在：%TARGET%
echo  下一步：打开这个文件夹，双击「全面体检.bat」开始体检。
start "" explorer.exe "%TARGET%"
goto end
:cancelled
echo  已取消，没有做任何改动。
goto end
:fail
echo  [安装失败] 文件复制出错（错误码 %errorlevel%）。常见原因：杀毒软件拦截或文件被占用。
echo  处理：关掉体检相关窗口和杀软弹窗后，重新双击本脚本。
goto end
:end
endlocal
