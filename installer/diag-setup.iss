; 电脑体检台 Inno Setup 安装脚本 v1.4.0（片1 形态片）
; per-user 安装 %LOCALAPPDATA%\电脑体检台，无管理员弹窗（PrivilegesRequired=lowest）
; WebView2 缺失时静默跑官方 bootstrapper；卸载 keep 分支把用户数据搬到 电脑体检台-报告备份-*。
; 本文件必须保存为 UTF-8 with BOM（ISCC 6 才能正确读中文）；build.ps1 侧有 BOM 断言。
; 编译：ISCC installer\diag-setup.iss → build\PC-CheckupBench-setup-v1.4.0.exe

#define MyAppName "电脑体检台"
#define MyAppVersion "1.4.0"
#define MyAppExeName "host.exe"

[Setup]
AppId={{8B9D3F6A-2C4E-4A7B-9F1D-6E8A5C2D7B31}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
UninstallDisplayName={#MyAppName}
DefaultDirName={localappdata}\{#MyAppName}
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
OutputDir=..\build
OutputBaseFilename=PC-CheckupBench-setup-v1.4.0
SetupIconFile=..\host\app.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\build\setup-staging\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion createallsubdirs
Source: "..\installer\uninstall-backup.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\installer\bootstrapper\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "立即运行{#MyAppName}"; Flags: nowait postinstall skipifsilent

; keep 分支：卸载删文件前先把用户数据（报告/自加检查/修复痕迹）搬到 电脑体检台-报告备份-<时间戳>。
; 用独立 ps1（ASCII 源码+码点拼中文）而不是 [Code] Pascal——后者在卸载器脚本引擎里炸
; Runtime error Type Mismatch（1023 实锤），且 PowerShell move 对中文路径最稳（bat/cmd 有静默解析坑）。
[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall-backup.ps1"" -AppDir ""{app}"""; RunOnceId: "BackupUserData"; Flags: runhidden

; 运行时生成的 WebView2 缓存等残壳 + keep 分支搬走数据后留下的目录壳（终验实锤 checks/repair 空壳残留），
; keep 用户数据在 [UninstallRun] 已先搬走，此处只清 Inno 自装文件与空目录
[UninstallDelete]
Type: filesandordirs; Name: "{app}\webview2-data"
Type: filesandordirs; Name: "{app}\checks"
Type: filesandordirs; Name: "{app}\repair"
Type: filesandordirs; Name: "{app}\trees"
Type: filesandordirs; Name: "{app}\ui"
Type: filesandordirs; Name: "{app}\engine"
Type: filesandordirs; Name: "{app}\ext"
Type: dirifempty; Name: "{app}"

[Code]
// 多键兜底：Inno 7 的注册表视图行为与 EdgeUpdate 键实际落位组合不可靠
// （1023 实锤：单键探测在已装 runtime 的机器上误判为未装，触发 bootstrapper 中止安装），
// 四键全扫（HKLM/HKCU × 直连/WOW6432Node），任一非空非 0.0.0.0 即视为已装。
function WebView2Installed(): Boolean;
var
  v: String;
  i: Integer;
  roots: array of Integer;
  keys: array of String;
begin
  SetArrayLength(roots, 4);
  roots[0] := HKLM; roots[1] := HKLM; roots[2] := HKCU; roots[3] := HKCU;
  SetArrayLength(keys, 4);
  keys[0] := 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  keys[1] := 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  keys[2] := 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  keys[3] := 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  Result := False;
  for i := 0 to 3 do
  begin
    v := '';
    if RegQueryStringValue(roots[i], keys[i], 'pv', v) then
      if (v <> '') and (v <> '0.0.0.0') then
      begin
        Result := True;
        Exit;
      end;
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if not WebView2Installed() then
    MsgBox('本机还没有网页内核（Edge WebView2），安装过程会自动联网装上（约 2 分钟）。' + #13#10 +
           '如果没联网，装完体检台第一次打开时会提示怎么补装。', mbInformation, MB_OK);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  rc: Integer;
begin
  Result := '';
  if WebView2Installed() then Exit;
  ExtractTemporaryFile('MicrosoftEdgeWebview2Setup.exe');
  Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install', '',
       SW_SHOW, ewWaitUntilTerminated, rc);
  if (rc <> 0) and (rc <> 3010) then
    Result := '网页内核（WebView2）安装失败（代码 ' + IntToStr(rc) + '）。' + #13#10 +
              '请检查网络后重试，或先手动装好 WebView2 再运行本安装器。';
end;
