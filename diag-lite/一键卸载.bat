@echo off
rem diag-lite v1.4.0 uninstaller (no admin needed)
rem Chinese prompts are GBK-encoded on purpose; keep CRLF when editing.
rem NOTE 1: cmd built-ins (if exist / move) mis-parse paths with a Chinese
rem         directory segment PLUS a deeper sub-directory on some machines,
rem         so all in-target operations run AFTER pushd via ASCII relative
rem         names (ext / reports). Target itself stays one Chinese level.
rem NOTE 2: this script lives INSIDE the dir it deletes - the final rd uses
rem         the (goto) 2>nul trick and must be the last action of a branch.
setlocal
set "TARGET=%LOCALAPPDATA%\电脑体检台"
set "EXTBK=%LOCALAPPDATA%\电脑体检台-ext备份"
set "REPBK=%LOCALAPPDATA%\电脑体检台-reports备份"
echo ==============================================
echo   电脑体检台 v1.4.0 一键卸载
echo ==============================================
echo.
if not exist "%TARGET%" (
  echo  没找到安装目录：%TARGET%
  echo  可能已经卸载过了。没有做任何改动。
  goto end
)
echo  安装目录：%TARGET%
echo  提醒：ext 里可能有你自己加的检查，reports 里是历史体检报告。
echo.
choice /c YN /m "卸载时保留 ext 自定义检查和历史报告吗？(Y=保留 N=一起删掉)"
if errorlevel 2 goto full
:keep
pushd "%TARGET%"
if exist ext move /y ext "%EXTBK%"
if exist reports move /y reports "%REPBK%"
popd
echo.
echo  正在卸载。你的自定义检查和历史报告已保留在：
echo    %EXTBK%
echo    %REPBK%
echo  确认不要了可以手动删掉这两个文件夹。
(goto) 2>nul & rd /s /q "%TARGET%"
goto check
:full
echo.
echo  即将删除整个安装目录（含 ext 和 reports），不可恢复。
choice /c YN /m "真的全删吗？(Y=全删 N=还是保留数据)"
if errorlevel 2 goto keep
echo  正在卸载并删除全部数据……
(goto) 2>nul & rd /s /q "%TARGET%"
:check
if exist "%TARGET%" (
  echo  [卸载失败] 目录删不掉。常见原因：体检窗口或报告文件还开着，关掉后重试。
) else (
  echo  [卸载完成]
)
:end
endlocal
