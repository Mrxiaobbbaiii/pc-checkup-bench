#Requires -Version 5.1
<#
diag web server v0.8 —— Edge 壳本地服务（design 第四节；判定零改动，engine B 案数据通路沿用）
用法（bat 启动器代跑）：powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File server.ps1
      开发/测试附加参数：-MockDir <dir>（透传 engine 模拟模式，自动化测试专用，默认关=真跑）
                          -NoBrowser（不拉 Edge，配合 -PortFile 供自动化测试读端口）
                          -PortFile <file>（把实际绑定端口写进该文件，自动化测试用）
架构：HttpListener 绑 loopback 随机端口（免防火墙弹窗；127.0.0.1 前缀被拒自动降级 localhost 前缀）
      + 静态 ui/ + REST API（/api/meta /api/start /api/events /api/cancel /api/report /api/heartbeat
      /api/open-reports /api/shutdown + /reports/<文件> 报告下发）。
生命周期：server 起 Edge --app 独立窗 → 页面每秒心跳（任意请求也算心跳）→ 窗关=心跳断
      → 2.5 秒内杀引擎（taskkill /T /F）→ server 自杀。引擎子进程=-ProgressFile/-JsonReport B 案（v0.6 已验）。
只读铁律：server 唯一"动"的动作=杀自己派生的引擎进程树+开资源管理器（用户点按钮）+删自己的临时进度文件。
#>
param(
    [string]$MockDir = '',
    [switch]$NoBrowser,
    [string]$PortFile = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$engineScript = Join-Path $root 'engine\run.ps1'
$uiDir = Join-Path $root 'ui'
$reportsDir = Join-Path $root 'reports'
$webVersion = 'v0.8'
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

# ---------- 端口：loopback 随机（TcpListener 探空端口→释放→HttpListener 绑） ----------
$probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()
$listener = New-Object System.Net.HttpListener
$boundHost = ''
foreach ($hostName in @('127.0.0.1', 'localhost')) {
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://${hostName}:$port/")
        $listener.Start()
        $boundHost = $hostName
        break
    } catch {
        Write-CrashLog ("bind failed http://${hostName}:$port/ : " + $_.Exception.Message)
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
$script:lastBeat = Get-Date
$script:gotBeat = $false
$script:startAt = Get-Date
$script:beatGraceMs = 25000   # 浏览器首次加载宽限（Edge 冷启动慢）
$script:beatTimeoutMs = 2500  # 心跳断判定线（窗关→3 秒内杀引擎的预算）

function Test-HeartbeatDead {
    if ($script:gotBeat) { return (((Get-Date) - $script:lastBeat).TotalMilliseconds -gt $script:beatTimeoutMs) }
    return (((Get-Date) - $script:startAt).TotalMilliseconds -gt $script:beatGraceMs)
}

function Stop-EngineTree {
    if ($script:proc) {
        try { & taskkill.exe /PID $script:proc.Id /T /F 2>&1 | Out-Null } catch { }
        try { $script:proc.WaitForExit(3000) | Out-Null } catch { }
        $script:proc = $null
    }
    if ($script:progressFile -ne '' -and (Test-Path -LiteralPath $script:progressFile)) {
        Remove-Item -LiteralPath $script:progressFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 引擎事件流增量读（B 案；与 GUI Read-NewEvents 同构）
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
$staticMap = @{ '/' = @('index.html', 'text/html; charset=utf-8'); '/index.html' = @('index.html', 'text/html; charset=utf-8'); '/app.js' = @('app.js', 'text/javascript; charset=utf-8'); '/style.css' = @('style.css', 'text/css; charset=utf-8') }

function Invoke-Route($ctx) {
    $req = $ctx.Request; $res = $ctx.Response
    $script:lastBeat = Get-Date
    $script:gotBeat = $true
    $path = $req.Url.AbsolutePath
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
        if ($path -eq '/api/start') {
            $body = Read-Body $req
            $j = @{}
            try { $j = $body | ConvertFrom-Json } catch { }
            $treeArg = [string]$j.tree
            $full = ($j.full -eq $true)
            $valid = ($treeArg -eq 'all') -or (@($menuOrder) -contains $treeArg)
            if (-not $valid) { Send-Json $res @{ ok = $false; error = '没认出这个体检项目' } 400; return }
            if ($script:state -eq 'running') { Send-Json $res @{ ok = $false; error = '正在检查中，请等这轮结束' } 409; return }
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

# ---------- 主循环（BeginGetContext + 250ms 看门狗：窗关→3 秒内杀引擎→自杀） ----------
try {
    while (-not $script:stopRequested) {
        $ar = $listener.BeginGetContext($null, $null)
        while (-not $ar.AsyncWaitHandle.WaitOne(250)) {
            if (Test-HeartbeatDead) { $script:stopRequested = $true; break }
            if ($script:stopRequested) { break }
        }
        if ($script:stopRequested) {
            try { $ar.AsyncWaitHandle.Close() } catch { }
            break
        }
        $ctx = $listener.EndGetContext($ar)
        Invoke-Route $ctx
        try { $ctx.Response.OutputStream.Close() } catch { }
        # 心跳已死则不再接新请求，直接收口
        if (Test-HeartbeatDead) { $script:stopRequested = $true; break }
    }
} catch {
    Write-CrashLog ('main loop: ' + $_.Exception.Message)
} finally {
    Stop-EngineTree
    try { if ($listener.IsListening) { $listener.Stop() } } catch { }
    try { $listener.Close() } catch { }
}
exit 0
