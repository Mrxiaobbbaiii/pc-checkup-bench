; 电脑体检台 Inno Setup 安装脚本 v1.2.0（片1 形态片）
; per-user 安装 %LOCALAPPDATA%\电脑体检台，无管理员弹窗（PrivilegesRequired=lowest）
; WebView2 缺失时静默跑官方 bootstrapper；卸载 keep 分支把用户数据搬到 电脑体检台-报告备份-*。
; 本文件必须保存为 UTF-8 with BOM（ISCC 6 才能正确读中文）；build.ps1 侧有 BOM 断言。
; 编译：ISCC installer\diag-setup.iss → build\电脑体检台-setup-v1.2.0.exe

#define MyAppName "电脑体检台"
#define MyAppVersion "1.2.0"
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
OutputBaseFilename=电脑体检台-setup-v1.2.0
SetupIconFile=..\host\app.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\build\setup-staging\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion createallsubdirs
Source: "..\installer\bootstrapper\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "立即运行{#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
const
  Wv2KeyLM = 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  Wv2KeyCU = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function WebView2Installed(): Boolean;
var
  v: String;
begin
  v := '';
  if not RegQueryStringValue(HKLM, Wv2KeyLM, 'pv', v) then
    RegQueryStringValue(HKCU, Wv2KeyCU, 'pv', v);
  Result := (v <> '') and (v <> '0.0.0.0');
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

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  stamp, backup, appdir, args: String;
  rc: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    // keep 分支：卸载前把用户数据（报告/自加检查/修复痕迹）搬到备份目录，程序文件留给 Inno 删
    appdir := ExpandConstant('{app}');
    stamp := GetDateTimeString('yyyymmddhhnn', '', '');
    backup := ExpandConstant('{localappdata}') + '\电脑体检台-报告备份-' + stamp;
    args := '-NoProfile -ExecutionPolicy Bypass -Command "' +
      'New-Item -ItemType Directory -Force -LiteralPath ''' + backup + ''' | Out-Null; ' +
      'foreach($n in @(''reports'',''ext'')){ if(Test-Path -LiteralPath (Join-Path ''' + appdir + ''' $n)){ Move-Item -LiteralPath (Join-Path ''' + appdir + ''' $n) -Destination (Join-Path ''' + backup + ''' $n) -Force } }; ' +
      'foreach($n in @(''repair\repair-log.json'',''repair\rollback'')){ $p = Join-Path ''' + appdir + ''' $n; if(Test-Path -LiteralPath $p){ New-Item -ItemType Directory -Force -LiteralPath (Split-Path $p -Parent) | Out-Null; Move-Item -LiteralPath $p -Destination (Join-Path ''' + backup + ''' $n) -Force } }' +
      '"';
    Exec('powershell.exe', args, '', SW_HIDE, ewWaitUntilTerminated, rc);
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    // Inno 删完自带文件后清残壳（webview2-data 等），目录已空则删目录
    appdir := ExpandConstant('{app}');
    if DirExists(appdir) then
      Exec('powershell.exe',
        '-NoProfile -Command "Remove-Item -LiteralPath ''' + appdir + ''' -Recurse -Force -ErrorAction SilentlyContinue"',
        '', SW_HIDE, ewWaitUntilTerminated, rc);
  end;
end;
