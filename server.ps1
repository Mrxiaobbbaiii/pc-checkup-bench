#Requires -Version 5.1
<#
diag web server v1.5.0 —— Edge 壳本地服务（判定零改动，engine 数据通路沿用；
      v1.1.0 起加载 ext	rees 与 ext
epairctions：只新增不覆盖，同名冲突忽略+crash log 告警）
用法（bat 启动器代跑）：powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File server.ps1
      开发/测试附加参数：-MockDir <dir>（透传 engine 模拟模式，自动化测试专用，默认关=真跑）
                          -NoBrowser（不拉 Edge，配合 -PortFile 供自动化测试读端口）
                          -PortFile <file>（把实际绑定端口写进该文件，自动化测试用）
架构：HttpListener 绑 loopback 随机端口（免防火墙弹窗；127.0.0.1 前缀被拒自动降级 localhost 前缀）
      + 静态 ui/ + REST API（/api/meta /api/start /api/events /api/cancel /api/report /api/heartbeat
      /api/bye /api/open-reports /api/shutdown + 修复接口 /api/repair/list /api/repair/run
      /api/repair/status + /reports/<文件> 报告下发）。
v0.9 修复中心：绿级/黄级动作子进程代跑（repair/repair.ps1 五段执行器；需提权时执行器内部一次性 RunAs）；
      黄级额外带 -AllowYellow（逐项确认由 ui 前置把关）与可选 -WithRestorePoint（系统还原点先行，
      建不出来执行器自动中止）；红级只回向导数据永不执行；跑批中禁修复、修复中禁跑批（双向 409）；
      关窗自杀连带杀修复子进程。
生命周期：server 起 Edge --app 独立窗 → 关窗时页面 sendBeacon('/api/bye')（pagehide 必达）
      → server 2 秒内确认无回连→杀引擎→自杀（窗关→3 秒内杀引擎达标）。
      心跳=兜底信号（页面后台化时 Chromium 会把定时器节流到 ~1 次/分钟，禁用短超时）：
      非跑批态 60 秒无任何请求=页面已弃→自杀；跑批中不判心跳死（引擎跑完自然收敛）。
只读铁律：server 唯一"动"的动作=杀自己派生的引擎/修复进程树+开资源管理器（用户点按钮）+删自己的临时进度文件
      +派生绿级修复子进程（动作库自描述，仅绿级，五段式带预检/验证/留痕）。
#>
param(
    [string]$MockDir = '',
    [switch]$NoBrowser,
    [string]$PortFile = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
# 数据根（MSIX 适配）：商店版安装目录（...\WindowsApps\...）只读——探测后写入环境变量
# DIAG_DATA_ROOT，engine/repair 子进程自动继承同一路径；Inno/lite 布局不变（数据根=应用根）。
$dataRoot = $root
if ($env:DIAG_DATA_ROOT) { $dataRoot = $env:DIAG_DATA_ROOT }
elseif ($root -like '*\WindowsApps\*') {
    $dataRoot = Join-Path $env:LOCALAPPDATA '电脑体检台'
    $env:DIAG_DATA_ROOT = $dataRoot
}
$engineScript = Join-Path $root 'engine\run.ps1'
$uiDir = Join-Path $root 'ui'
$reportsDir = Join-Path $dataRoot 'reports'
$webVersion = 'v1.5.0'
$diagPs = (Get-Process -Id $PID).Path

# ---------- 子进程 stdout 排水器（C# 空回调：scriptblock delegate 无 runspace 回调线程会炸进程；v0.6 已验机制照搬）
# stderr 同时落盘 temp 日志（隐藏窗无控制台，引擎报错可诊断；纯 .NET 回调无 runspace 依赖）
Add-Type -TypeDefinition @'
using System.Diagnostics;
using System.IO;
public static class DiagDrain {
    public static void Wire(Process p, string errLog) {
        p.OutputDataReceived += (s, e) => { };
        p.ErrorDataReceived += (s, e) => {
            if (e.Data != null) { try { File.AppendAllText(errLog, e.Data + "\r\n"); } catch { } }
        };
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
    }
}
'@

# ---------- 崩溃留痕（隐藏窗无控制台，出错可诊断） ----------
function Write-CrashLog([string]$msg) {
    try {
        Add-Content -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) 'diag-web-server-crash.log') `
            -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch { }
}

# ---------- 树知识（启动时只读 trees/*.yaml；菜单文案与 engine/GUI 同源） ----------
$menuOrder = @('network', 'bluescreen', 'hardware', 'performance', 'drivers')
$menuNames = @{ network = '网络体检'; bluescreen = '蓝屏体检'; hardware = '硬件体检'; performance = '性能体检'; drivers = '驱动体检' }
$menuDesc  = @{ network = '上不了网 / 网页打不开'; bluescreen = '蓝屏过 / 莫名重启'; hardware = '磁盘 / 电池 / 温度'; performance = '开机慢 / 用着卡'; drivers = '驱动来路 / 设备黄三角' }
$treeDefs = @()
foreach ($t in $menuOrder) {
    $tf = Join-Path $root "trees\$t.yaml"
    if (-not (Test-Path -LiteralPath $tf)) { continue }
    $td = Get-Content -LiteralPath $tf -Raw -Encoding UTF8 | ConvertFrom-Json
    $layers = @()
    $total = 0
    foreach ($l in $td.layers) {
        $checks = @($l.checks)
        $layers += [ordered]@{ name = [string]$l.name; title = [string]$l.title; checks = @($checks) }
        $total += $checks.Count
    }
    $treeDefs += [ordered]@{
        id = $t; name = $menuNames[$t]; desc = $menuDesc[$t]
        tip = '查：' + (@($td.layers | ForEach-Object { $_.title }) -join ' → ')
        layers = $layers; total = $total
    }
}

# ---------- v1.1.0 ext 扩展树（ext\trees\*.yaml，内容格式同内置；只新增不覆盖：同名冲突忽略+crash log 告警） ----------
# 先扫数据根（MSIX 用户扩展放 %LOCALAPPDATA%），再扫应用根（包内示例）；数据根先注册=同名时用户版赢
$extTreesDirs = @((Join-Path $dataRoot 'ext\trees'), (Join-Path $root 'ext\trees')) | Select-Object -Unique
foreach ($extTreesDir in $extTreesDirs) {
if (Test-Path -LiteralPath $extTreesDir) {
    foreach ($ef in (Get-ChildItem -LiteralPath $extTreesDir -File -Filter '*.yaml' | Sort-Object Name)) {
        $extId = [System.IO.Path]::GetFileNameWithoutExtension($ef.Name)
        if ($menuOrder -contains $extId) { Write-CrashLog ('ext tree ignored (conflicts with built-in): ' + $ef.Name); continue }
        if (@($treeDefs | Where-Object { $_.id -eq $extId }).Count -gt 0) { Write-CrashLog ('ext tree ignored (duplicate ext): ' + $ef.Name); continue }
        try {
            $etd = Get-Content -LiteralPath $ef.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $extName = if ($etd.PSObject.Properties['display_name'] -and $etd.display_name) { [string]$etd.display_name } else { $extId }
            $extDesc = if ($etd.PSObject.Properties['desc'] -and $etd.desc) { [string]$etd.desc } else { '扩展体检（ext）' }
            $extLayers = @(); $extTotal = 0
            foreach ($l in $etd.layers) {
                $extChecks = @($l.checks)
                $extLayers += [ordered]@{ name = [string]$l.name; title = [string]$l.title; checks = @($extChecks) }
                $extTotal += $extChecks.Count
            }
            $treeDefs += [ordered]@{
                id = $extId; name = $extName; desc = $extDesc
                tip = '查：' + (@($etd.layers | ForEach-Object { $_.title }) -join ' → ')
                layers = $extLayers; total = $extTotal; ext = $true
            }
        } catch { Write-CrashLog ('ext tree json bad: ' + $ef.Name + ' : ' + $_.Exception.Message) }
    }
}
}

# ---------- 修复动作知识（启动时只读 repair/actions/*.json；绿+黄级可代跑，红级留向导位） ----------
$repairDefs = @()
$repairScript = Join-Path $root 'repair\repair.ps1'
$repairActionsDir = Join-Path $root 'repair\actions'
if (Test-Path -LiteralPath $repairActionsDir) {
    foreach ($af in (Get-ChildItem -LiteralPath $repairActionsDir -File -Filter '*.json' | Sort-Object Name)) {
        try {
            $a = Get-Content -LiteralPath $af.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$a.id -and [string]$a.level -and @($a.steps).Count) { $repairDefs += $a }
            else { Write-CrashLog ('repair action skipped (no id/level/steps): ' + $af.Name) }
        } catch { Write-CrashLog ('repair action json bad: ' + $af.Name + ' : ' + $_.Exception.Message) }
    }
}

# ---------- v1.1.0 ext 扩展修复动作（ext\repair\actions\*.json；只新增不覆盖：id 与内置冲突忽略+crash log 告警；红级照样零执行） ----------
# 同 ext 树——数据根先扫（用户扩展），应用根后扫（包内示例）
$extActionsDirs = @((Join-Path $dataRoot 'ext\repair\actions'), (Join-Path $root 'ext\repair\actions')) | Select-Object -Unique
foreach ($extActionsDir in $extActionsDirs) {
if (Test-Path -LiteralPath $extActionsDir) {
    foreach ($af in (Get-ChildItem -LiteralPath $extActionsDir -File -Filter '*.json' | Sort-Object Name)) {
        try {
            $a = Get-Content -LiteralPath $af.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not ([string]$a.id -and [string]$a.level -and @($a.steps).Count)) { Write-CrashLog ('ext repair action skipped (no id/level/steps): ' + $af.Name); continue }
            if (@($repairDefs | Where-Object { [string]$_.id -eq [string]$a.id }).Count -gt 0) { Write-CrashLog ('ext repair action ignored (id conflicts with built-in): ' + [string]$a.id); continue }
            $repairDefs += $a
        } catch { Write-CrashLog ('ext repair action json bad: ' + $af.Name + ' : ' + $_.Exception.Message) }
    }
}
}

# ---------- 端口：固定端口优先（1024 打磨轮修复：随机端口→WebView2 localStorage 按 origin 含端口隔离， ----------
# 「知道了/上次体检/主题/已读版本」等记忆跨启动全丢。固定 17320 起，被占递增至 17339，全占回退 OS 随机
# （罕见场景，记忆退化可接受）。
$listener = New-Object System.Net.HttpListener
$boundHost = ''
$port = 0
foreach ($p in @(17320..17339)) {
    foreach ($hostName in @('127.0.0.1', 'localhost')) {
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://${hostName}:$p/")
            $listener.Start()
            $boundHost = $hostName; $port = $p
            break
        } catch { }
    }
    if ($boundHost -ne '') { break }
}
if ($boundHost -eq '') {
    # 固定段全占回退：OS 随机（TcpListener 探空端口→释放→HttpListener 绑）
    $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $rp = $probe.LocalEndpoint.Port
    $probe.Stop()
    foreach ($hostName in @('127.0.0.1', 'localhost')) {
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://${hostName}:$rp/")
            $listener.Start()
            $boundHost = $hostName; $port = $rp
            break
        } catch {
            Write-CrashLog ("bind failed http://${hostName}:$rp/ : " + $_.Exception.Message)
        }
    }
}
if ($boundHost -eq '') { Write-CrashLog 'no bindable loopback prefix'; exit 3 }
$baseUrl = "http://${boundHost}:$port/"
if ($PortFile -ne '') { try { Set-Content -LiteralPath $PortFile -Value $port -Encoding ASCII } catch { } }

# ---------- 拉起 Edge --app 独立窗（找不到 Edge 降级默认浏览器） ----------
if (-not $NoBrowser) {
    $edgeExe = ''
    foreach ($c in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe")) {
        if ($c -and (Test-Path -LiteralPath $c)) { $edgeExe = $c; break }
    }
    try {
        if ($edgeExe -ne '') {
            Start-Process -FilePath $edgeExe -ArgumentList "--app=$baseUrl", '--window-size=1000,740' | Out-Null
        } else {
            Start-Process -FilePath $baseUrl | Out-Null
        }
    } catch { Write-CrashLog ('browser launch failed: ' + $_.Exception.Message) }
}

# ---------- 跑批状态机（与 v0.7.1 GUI 同构：idle → running → done/cancelled/error） ----------
$script:state = 'idle'
$script:proc = $null
$script:progressFile = ''
$script:progLinesRead = 0
$script:events = @()          # 全量事件缓冲（含 seq；页面刷新可 since=0 重放）
$script:cancelRequested = $false
$script:htmlReport = ''
$script:jsonReport = ''
$script:doneExit = $null
$script:runStamp = Get-Date
$script:stopRequested = $false
$script:runTree = 'all'
$script:runFull = $true
$script:engineErrLog = Join-Path ([System.IO.Path]::GetTempPath()) 'diag-web-engine-stderr.log'
$script:byeAt = $null
$script:lastBeat = Get-Date
$script:gotBeat = $false
$script:startAt = Get-Date
$script:beatGraceMs = 25000   # 浏览器首次加载宽限（Edge 冷启动慢）
$script:byeGraceMs = 2000     # beacon 宽限：F5 重载会在 2 秒内回连，真关窗不会
$script:beatTimeoutMs = 60000 # 心跳兜底线（页面后台节流容忍 1 次/分钟；仅非跑批态生效）
$script:repairProc = $null    # v0.8.1 修复子进程（repair/repair.ps1；跑批/修复互斥）
$script:repairOutFile = ''
$script:repairResult = $null
$script:repairId = ''
$script:repairState = 'idle'  # idle | running | done
$script:repairErrLog = Join-Path ([System.IO.Path]::GetTempPath()) 'diag-web-repair-stderr.log'

function Test-ShouldStop {
    if ($null -ne $script:byeAt) {
        if (((Get-Date) - $script:byeAt).TotalMilliseconds -gt $script:byeGraceMs) { return 'bye' }
        return $null
    }
    if ($script:state -eq 'running') { return $null }
    if ($script:gotBeat) {
        if (((Get-Date) - $script:lastBeat).TotalMilliseconds -gt $script:beatTimeoutMs) { return 'beat' }
    } elseif (((Get-Date) - $script:startAt).TotalMilliseconds -gt $script:beatGraceMs) { return 'grace' }
    return $null
}

function Stop-EngineTree {
    if ($script:proc) {
        try { & taskkill.exe /PID $script:proc.Id /T /F 2>&1 | Out-Null } catch { }
        try { $script:proc.WaitForExit(3000) | Out-Null } catch { }
        $script:proc = $null
    }
    # v0.8.1：修复子进程同待遇（外层非提权可杀；其提权内层杀不动=秒级自灭的绿级命令，无害）
    if ($script:repairProc) {
        try { & taskkill.exe /PID $script:repairProc.Id /T /F 2>&1 | Out-Null } catch { }
        try { $script:repairProc.WaitForExit(2000) | Out-Null } catch { }
        $script:repairProc = $null
        $script:repairState = 'idle'
    }
    if ($script:progressFile -ne '' -and (Test-Path -LiteralPath $script:progressFile)) {
        Remove-Item -LiteralPath $script:progressFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 引擎事件流增量读（与 GUI Read-NewEvents 同构）
# 读取用 FileShare.ReadWrite 显式共享写（Get-Content 默认共享模式会在 mock 高频追加下与 engine Add-Content 抢锁，
# engine Stop 偏好下锁冲突=终止错误中途退出——实测 mock 全流程死于第 15 项的根因）；末行解析失败=撕裂行，留待下轮重读 ----------
function Read-NewEvents {
    if ($script:progressFile -eq '' -or -not (Test-Path -LiteralPath $script:progressFile)) { return }
    $content = ''
    try {
        $fs = New-Object System.IO.FileStream ($script:progressFile), ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), ([System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader ($fs, [System.Text.Encoding]::UTF8)
        $content = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
    } catch { return }
    if ([string]::IsNullOrWhiteSpace($content)) { return }
    $all = @($content -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($all.Count -le $script:progLinesRead) { return }
    for ($i = $script:progLinesRead; $i -lt $all.Count; $i++) {
        $line = $all[$i]
        $ev = $null
        try { $ev = $line | ConvertFrom-Json } catch { $ev = $null }
        if ($null -eq $ev) {
            if ($i -eq $all.Count - 1) { break }   # 撕裂的末行：不算已读，下轮重读
            continue                                 # 中间坏行：跳过
        }
        $script:events += [ordered]@{ seq = $script:events.Count + 1; ev = $ev }
        if ($ev.event -eq 'done') {
            if ($ev.htmlReport) { $script:htmlReport = [string]$ev.htmlReport }
            if ($ev.jsonReport) { $script:jsonReport = [string]$ev.jsonReport }
        }
        $script:progLinesRead = $i + 1
    }
}

# ---------- 引擎退出收敛（与 GUI On-EngineExited 同构） ----------
function ConvertTo-EventsPayload([int]$since) {
    Read-NewEvents
    if ($script:state -eq 'running' -and $script:proc -and $script:proc.HasExited) {
        $code = try { $script:proc.ExitCode } catch { -1 }
        if ($script:cancelRequested) { $script:state = 'cancelled' }
        elseif ($code -eq 0 -or $code -eq 2) { $script:state = 'done'; $script:doneExit = $code }
        else { $script:state = 'error'; $script:doneExit = $code }
        Read-NewEvents
        if ($script:progressFile -ne '' -and (Test-Path -LiteralPath $script:progressFile)) {
            Remove-Item -LiteralPath $script:progressFile -Force -ErrorAction SilentlyContinue
        }
        $script:proc = $null
    }
    $newEvents = @()
    foreach ($e in $script:events) { if ([int]$e.seq -gt $since) { $newEvents += $e.ev } }
    $htmlUrl = ''
    $jsonUrl = ''
    if ($script:htmlReport -ne '') { $htmlUrl = '/reports/' + [System.IO.Path]::GetFileName($script:htmlReport) }
    if ($script:jsonReport -ne '') { $jsonUrl = '/reports/' + [System.IO.Path]::GetFileName($script:jsonReport) }
    $elapsed = 0
    if ($script:state -in @('running', 'done', 'cancelled', 'error')) { $elapsed = [int][Math]::Round(((Get-Date) - $script:runStamp).TotalSeconds) }
    $enginePid = 0
    if ($script:proc) { $enginePid = $script:proc.Id }
    return [ordered]@{
        state = $script:state; lastSeq = $script:events.Count; events = $newEvents
        exit = $script:doneExit; htmlUrl = $htmlUrl; jsonUrl = $jsonUrl; elapsedSec = $elapsed
        runTree = $script:runTree; runFull = $script:runFull; enginePid = $enginePid
    }
}

function Start-Engine([string]$treeArg, [bool]$full) {
    if (-not (Test-Path -LiteralPath $engineScript)) { return @{ ok = $false; error = "找不到程序文件：$engineScript" } }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:progressFile = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-web-progress-$PID-$stamp.jsonl")
    Remove-Item -LiteralPath $script:progressFile -Force -ErrorAction SilentlyContinue
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engineScript, '-TreeName', $treeArg, '-NoMenu', '-ProgressFile', $script:progressFile, '-JsonReport')
    if ($full) { $argList += '-Full' }
    if ($MockDir -ne '') { $argList += @('-MockDir', $MockDir) }
    $quoted = @($argList | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '') + '"' } else { $_ } })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $diagPs
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($psi.PSObject.Properties['StandardOutputEncoding']) { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 }
    if ($psi.PSObject.Properties['StandardErrorEncoding']) { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 }
    try { $script:proc = [System.Diagnostics.Process]::Start($psi) } catch { return @{ ok = $false; error = '启动失败：' + $_.Exception.Message } }
    [DiagDrain]::Wire($script:proc, $script:engineErrLog)
    $script:state = 'running'
    $script:progLinesRead = 0
    $script:events = @()
    $script:cancelRequested = $false
    $script:htmlReport = ''
    $script:jsonReport = ''
    $script:doneExit = $null
    $script:runStamp = Get-Date
    $script:runTree = $treeArg
    $script:runFull = $full
    return @{ ok = $true }
}

# ---------- HTTP 应答工具 ----------
function Send-Json($res, $obj, [int]$code = 200) {
    $json = ConvertTo-Json $obj -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $res.StatusCode = $code
    $res.ContentType = 'application/json; charset=utf-8'
    $res.Headers['Cache-Control'] = 'no-store'
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}
function Send-Static($res, [string]$file, [string]$mime) {
    $path = Join-Path $uiDir $file
    if (-not (Test-Path -LiteralPath $path)) {
        $res.StatusCode = 404; $bytes = [System.Text.Encoding]::UTF8.GetBytes('not found')
        $res.OutputStream.Write($bytes, 0, $bytes.Length); return
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $res.StatusCode = 200
    $res.ContentType = $mime
    $res.Headers['Cache-Control'] = 'no-cache'
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}
function Read-Body($req) {
    if ($req.ContentLength64 -le 0) { return '' }
    $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
    return $sr.ReadToEnd()
}

# ---------- 路由（任意请求=心跳；单线程事件循环无并发竞态） ----------
$staticMap = @{ '/' = @('index.html', 'text/html; charset=utf-8'); '/index.html' = @('index.html', 'text/html; charset=utf-8'); '/app.js' = @('app.js', 'text/javascript; charset=utf-8'); '/style.css' = @('style.css', 'text/css; charset=utf-8'); '/custom.css' = @('custom.css', 'text/css; charset=utf-8'); '/i18n/zh-CN.js' = @('i18n/zh-CN.js', 'text/javascript; charset=utf-8'); '/i18n/en-US.js' = @('i18n/en-US.js', 'text/javascript; charset=utf-8'); '/bg.jpg' = @('bg.jpg', 'image/jpeg'); '/brand.png' = @('brand.png', 'image/png'); '/bg-light.jpg' = @('bg-light.jpg', 'image/jpeg'); '/favicon.png' = @('favicon.png', 'image/png') }

function Invoke-Route($ctx) {
    $req = $ctx.Request; $res = $ctx.Response
    $path = $req.Url.AbsolutePath
    if ($path -ne '/api/bye') {
        # 只有「新页面加载」信号（静态资源/meta）才撤销 bye 判定——F5 重载会先拉静态文件；
        # 心跳/事件轮询不清 bye（pagehide beacon 与在途心跳赛跑时，后者后到会把 bye 冲掉退化为 60 秒兜底，Edge 复测实锤）
        if ($staticMap.ContainsKey($path) -or $path -eq '/api/meta') { $script:byeAt = $null }
        $script:lastBeat = Get-Date
        $script:gotBeat = $true
    }
    try {
        if ($staticMap.ContainsKey($path)) {
            Send-Static $res $staticMap[$path][0] $staticMap[$path][1]
            return
        }
        if ($path -eq '/api/meta') {
            Send-Json $res ([ordered]@{ version = $webVersion; trees = $treeDefs })
            return
        }
        if ($path -eq '/api/heartbeat') {
            Send-Json $res @{ ok = $true }
            return
        }
        if ($path -eq '/api/reports/list') {
            # 历史对比：报告列表（文件名+时间，降序）；详情走既有 /reports/<file> 下发
            $list = @(Get-ChildItem -LiteralPath $reportsDir -Filter 'diag-*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                ForEach-Object { [ordered]@{ file = $_.Name; mtime = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } })
            Send-Json $res @{ reports = $list }
            return
        }
        if ($path -eq '/api/bye') {
            # 关窗 beacon（pagehide 必达；2 秒宽限内无回连=真关窗→杀引擎自杀）
            $script:byeAt = Get-Date
            Send-Json $res @{ ok = $true }
            return
        }
        if ($path -eq '/api/start') {
            $body = Read-Body $req
            $j = @{}
            try { $j = $body | ConvertFrom-Json } catch { }
            $treeArg = [string]$j.tree
            $full = ($j.full -eq $true)
            $valid = ($treeArg -eq 'all') -or (@($menuOrder) -contains $treeArg)
            if (-not $valid) { Send-Json $res @{ ok = $false; error = '没认出这个体检项目' } 400; return }
            if ($script:state -eq 'running') { Send-Json $res @{ ok = $false; error = '正在检查中，请等这轮结束' } 409; return }
            if ($script:repairState -eq 'running') { Send-Json $res @{ ok = $false; error = '正在修复中，请等它结束再体检' } 409; return }
            $r = Start-Engine $treeArg $full
            if (-not $r.ok) { Send-Json $res @{ ok = $false; error = $r.error } 500; return }
            Send-Json $res @{ ok = $true }
            return
        }
        if ($path -eq '/api/events') {
            $since = 0
            $q = $req.QueryString['since']
            if ($q) { $since = [int]$q }
            Send-Json $res (ConvertTo-EventsPayload $since)
            return
        }
        if ($path -eq '/api/cancel') {
            if ($script:state -eq 'running' -and $script:proc) {
                $script:cancelRequested = $true
                try { & taskkill.exe /PID $script:proc.Id /T /F 2>&1 | Out-Null } catch { }
                Send-Json $res @{ ok = $true }
            } else {
                Send-Json $res @{ ok = $false; error = '现在没有在查' }
            }
            return
        }
        if ($path -eq '/api/report') {
            if ($script:jsonReport -eq '' -or -not (Test-Path -LiteralPath $script:jsonReport)) {
                Send-Json $res @{ error = '还没有报告（查完才有）' }
                return
            }
            try {
                $report = Get-Content -LiteralPath $script:jsonReport -Raw -Encoding UTF8 | ConvertFrom-Json
                $htmlUrl = '/reports/' + [System.IO.Path]::GetFileName($script:htmlReport)
                Send-Json $res ([ordered]@{ report = $report; htmlUrl = $htmlUrl; exit = $script:doneExit })
            } catch {
                Send-Json $res @{ error = '报告读取失败' }
            }
            return
        }
        if ($path -like '/reports/*') {
            $name = [System.IO.Path]::GetFileName($req.Url.AbsolutePath)
            if ($name -notmatch '^diag-[A-Za-z0-9_.\-]+\.(html|json)$') { $res.StatusCode = 404; return }
            $rp = Join-Path $reportsDir $name
            if (-not (Test-Path -LiteralPath $rp)) { $res.StatusCode = 404; return }
            $mime = 'text/html; charset=utf-8'
            if ($name -like '*.json') { $mime = 'application/json; charset=utf-8' }
            $bytes = [System.IO.File]::ReadAllBytes($rp)
            $res.StatusCode = 200
            $res.ContentType = $mime
            $res.Headers['Cache-Control'] = 'no-store'
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            return
        }
        if ($path -eq '/api/repair/list') {
            # 动作库清单（含等级/三行文案/步骤人话/匹配检查项；ui 修复中心数据源）
            Send-Json $res ([ordered]@{ ok = $true; actions = $repairDefs })
            return
        }
        if ($path -eq '/api/repair/history') {
            # 修复小史：数据根 repair-log.json 尾 20 条精简投影（时间/动作/等级/结果；host 与步骤明细不下发）
            $hist = @()
            $logPath = Join-Path $reportsDir 'repair-log.json'
            if (Test-Path -LiteralPath $logPath) {
                foreach ($ln in @(Get-Content -LiteralPath $logPath -Tail 20 -Encoding UTF8)) {
                    if (-not $ln.Trim()) { continue }
                    try {
                        $h = $ln | ConvertFrom-Json
                        $rpState = ''
                        if ($h.PSObject.Properties['pkg'] -and $h.pkg -and $h.pkg.PSObject.Properties['restore_point']) { $rpState = $(if ($h.pkg.restore_point.ok) { 'ok' } elseif ($h.pkg.restore_point.requested) { 'failed' } else { '' }) }
                        $hist += [ordered]@{ time = [string]$h.time; id = [string]$h.id; name = [string]$h.name; level = [string]$h.level; ok = ($h.ok -eq $true); fail_stage = [string]$h.fail_stage; rp = $rpState }
                    } catch { }
                }
            }
            Send-Json $res ([ordered]@{ ok = $true; history = $hist })
            return
        }
        if ($path -eq '/api/repair/run') {
            $body = Read-Body $req
            $j = @{}
            try { $j = $body | ConvertFrom-Json } catch { }
            $rid = [string]$j.id
            $wantRp = ($j.restore_point -eq $true)
            $skipRp = ($j.skip_restore_point -eq $true)
            $def = @($repairDefs | Where-Object { [string]$_.id -eq $rid })[0]
            if (-not $def) { Send-Json $res @{ ok = $false; error = '没认出这个修复动作' } 400; return }
            if ([string]$def.level -eq 'red') {
                # 红级只出向导数据、永不代跑（design 铁律；红级动作入库=纯指南卡（C 片起））
                Send-Json $res ([ordered]@{
                    ok = $false; error = '这一级不会自动执行——下面是可以自己照着做的步骤'
                    guide = [ordered]@{ name = [string]$def.name; level = [string]$def.level; desc = [string]$def.desc; affect = [string]$def.affect; undo = [string]$def.undo; steps = @($def.steps); rollback_note = [string]$def.rollback_note }
                })
                return
            }
            if ($script:state -eq 'running') { Send-Json $res @{ ok = $false; error = '正在检查中，请等这轮结束再修复' } 409; return }
            if ($script:repairState -eq 'running') { Send-Json $res @{ ok = $false; error = '正在修复中，请等它结束' } 409; return }
            if (-not (Test-Path -LiteralPath $repairScript)) { Send-Json $res @{ ok = $false; error = '修复程序文件缺失' } 500; return }
            $rstamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $script:repairOutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-web-repair-$PID-$rstamp.json")
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $repairScript, '-ActionId', $rid, '-OutFile', $script:repairOutFile)
            if ([string]$def.level -eq 'yellow') {
                # 黄级：ui 逐项确认已在前置把关，这里显式放行 + 可选系统还原点
                $argList += '-AllowYellow'
                if ($wantRp) { $argList += '-WithRestorePoint' }
                if ($skipRp) { $argList += '-SkipRestorePoint' }  # 1024 修复体验轮：用户知情跳过（撤销脚本仍生成）
            }
            $quoted = @($argList | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '') + '"' } else { $_ } })
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $diagPs
            $psi.Arguments = $quoted -join ' '
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            if ($psi.PSObject.Properties['StandardOutputEncoding']) { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 }
            if ($psi.PSObject.Properties['StandardErrorEncoding']) { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 }
            try { $script:repairProc = [System.Diagnostics.Process]::Start($psi) } catch { Send-Json $res @{ ok = $false; error = '修复程序启动失败：' + $_.Exception.Message } 500; return }
            [DiagDrain]::Wire($script:repairProc, $script:repairErrLog)
            $script:repairState = 'running'
            $script:repairId = $rid
            $script:repairResult = $null
            Send-Json $res @{ ok = $true }
            return
        }
        if ($path -eq '/api/repair/status') {
            # 收敛：子进程退了→读结果文件→缓存到下次 run（页面刷新可重取）
            if ($script:repairProc -and $script:repairProc.HasExited) {
                $resJson = $null
                try { $resJson = Get-Content -LiteralPath $script:repairOutFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
                if ($null -eq $resJson) { $resJson = [ordered]@{ ok = $false; id = $script:repairId; fail_stage = 'lost'; human = '修复程序没有交回结果（异常退出）'; stages = @{} } }
                $script:repairResult = $resJson
                $script:repairProc = $null
                $script:repairState = 'done'
            }
            Send-Json $res ([ordered]@{ state = $script:repairState; id = $script:repairId; result = $script:repairResult })
            return
        }
        if ($path -eq '/api/open-reports') {
            if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
            Start-Process explorer.exe -ArgumentList "`"$reportsDir`""
            Send-Json $res @{ ok = $true }
            return
        }
        if ($path -eq '/api/shutdown') {
            if ($script:state -eq 'running') {
                $script:cancelRequested = $true
                Stop-EngineTree
                $script:state = 'cancelled'
            } else {
                Stop-EngineTree
            }
            Send-Json $res @{ ok = $true }
            $script:stopRequested = $true
            return
        }
        $res.StatusCode = 404
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('not found')
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
        Write-CrashLog ("route error $path : " + $_.Exception.Message)
        try { Send-Json $res @{ error = 'server error' } 500 } catch { }
    }
}

# ---------- 主循环（BeginGetContext + 250ms 看门狗：关窗 beacon→2 秒宽限→杀引擎自杀；心跳 60 秒兜底） ----------
try {
    while (-not $script:stopRequested) {
        $ar = $listener.BeginGetContext($null, $null)
        while (-not $ar.AsyncWaitHandle.WaitOne(250)) {
            if ((Test-ShouldStop)) { $script:stopRequested = $true; break }
        }
        if ($script:stopRequested) {
            try { $ar.AsyncWaitHandle.Close() } catch { }
            break
        }
        $ctx = $listener.EndGetContext($ar)
        Invoke-Route $ctx
        try { $ctx.Response.OutputStream.Close() } catch { }
        if ((Test-ShouldStop)) { $script:stopRequested = $true; break }
    }
} catch {
    Write-CrashLog ('main loop: ' + $_.Exception.Message)
} finally {
    Stop-EngineTree
    try { if ($listener.IsListening) { $listener.Stop() } } catch { }
    try { $listener.Close() } catch { }
}
exit 0
