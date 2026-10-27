#Requires -Version 5.1
<#
diag engine v1.8.3 —— 推进器（PowerShell 5.1+ / 7 双兼容，大众普及版；用户可见自称=「电脑体检台」，版本走 $engVersion 常量）
用法：powershell -NoProfile -ExecutionPolicy Bypass -File engine\run.ps1 [-TreeName <树名|all>] [-Full] [-MockDir <dir>] [-OpenReport] [-NoMenu] [-ProgressFile <file>] [-JsonReport]
树可选字段：verdict_title=报告结论标题（缺省"断点结论"）；report_name=报告大标题树名（缺省保持网络树文案，非网络树证据链副标转聚合取证）
  -Full      断点后继续跑完剩余层取证（默认断点即停，后续层 SKIP）
  -MockDir   模拟模式：目录内 <检查项名>.txt 作为该检查项的 MockRaw（模拟测试/演示用）
  -OpenReport 跑完自动用默认浏览器打开 HTML 报告（普及版双击场景用；v0.2.1 起替代记事本）
  -NoMenu    -TreeName all 时跳过中文菜单直接连跑全部内置树（自动化用；-MockDir 非空时同样自动跳过）
  -ProgressFile GUI 数据通路（默认关）：每完成一检查项向该文件追加一行 JSON 事件
             （event=check/tree_done/break/done；树/层/项名/状态/耗时；done 带退出码与报告路径）。stdout 零新增。
  -JsonReport GUI 数据通路（默认关）：HTML 落盘同时多落一份 diag-<树>-<时间戳>.json
             （树→层→项 status/evidence/suggestion/detail 全量，与 HTML 同源结构；进 reports/ 50 份裁剪）。
v0.5：-TreeName all=多树模式（依次跑 network/bluescreen/hardware/performance/drivers 五树出合并报告；
      菜单条件=all 且 MockDir 空且未带 -NoMenu，回车=连跑五树、1-5=单跑该树）；reports/ 保留最新 50 份自动裁剪。
v0.6：新增 -ProgressFile/-JsonReport 两默认关参数（图形界面片；判定/推进/既有输出逐字不动，GUI 壳消费）。
v1.1.0：ext 扩展口子——ext	rees\*.yaml（单树补缺）与 ext\checks\*.ps1（检查补缺）自动加载；内置优先，同名冲突忽略+stderr 告警；all 模式仍=内置五树，扩展树在菜单/网页版单独选跑。
铁律：探测只读（检查项全部只读命令）；证据必附（报告含原始输出摘录）；修复只给命令文本+回滚。
安全树：内置第六棵树 security（安全体检，8 项只读检查：Defender 开关/服务/检出史/排除项+UAC/防火墙/BitLocker/计划任务）；
      all 模式=内置六树连跑，总入口菜单扩为 1-6；单树执行路径零改动。
退出码：0=全通；2=有断点（all 模式=任一树有 FAIL）；3=引擎自身错误。
#>
param(
    [string]$TreeName = 'network',
    [switch]$Full,
    [string]$MockDir = '',
    [switch]$OpenReport,
    [switch]$NoSaveReport,
    [switch]$NoMenu,
    [string]$ProgressFile = '',
    [switch]$JsonReport
)
$engVersion = '1.8.3'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# 子进程解释器=当前解释器自身（5.1→powershell.exe / 7→pwsh.exe，双版本通吃）
$diagPs = (Get-Process -Id $PID).Path

# 数据根（MSIX 适配）：商店版安装目录（...\WindowsApps\...）只读，报告等写产物必须外移到
# %LOCALAPPDATA%\电脑体检台；Inno/lite/开发仓布局不变（数据根=应用根，行为零变化）。
# 优先级：DIAG_DATA_ROOT 环境变量（server 注入/测试覆盖）> WindowsApps 探测 > $root。判定语义零碰，仅写盘位置。
$dataRoot = $root
if ($env:DIAG_DATA_ROOT) { $dataRoot = $env:DIAG_DATA_ROOT }
elseif ($root -like '*\WindowsApps\*') { $dataRoot = Join-Path $env:LOCALAPPDATA '电脑体检台' }
$reportsDir = Join-Path $dataRoot 'reports'
# reports 目录自愈（发行包缺目录防御，幂等；不碰判定与输出）
if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }

# ---------- 总入口中文菜单（-TreeName all 且 MockDir 空且未带 -NoMenu 才显示，不卡自动化） ----------
$menuNames = @{ network = '网络体检'; bluescreen = '蓝屏体检'; hardware = '硬件体检'; performance = '性能体检'; drivers = '驱动体检'; security = '安全体检' }
if ($TreeName -eq 'all' -and $MockDir -eq '' -and -not $NoMenu) {
    $menuMap = @{ '1' = 'network'; '2' = 'bluescreen'; '3' = 'hardware'; '4' = 'performance'; '5' = 'drivers'; '6' = 'security' }
    $picked = ''
    for ($i = 1; $i -le 3; $i++) {
        Write-Host ''
        Write-Host "================== 电脑体检台 全面体检 v$engVersion =================="
        Write-Host '  回车 = 六类全查，出一份合并体检报告（推荐，约几分钟）'
        Write-Host '    1 = 网络体检（上不了网 / 网页打不开）'
        Write-Host '    2 = 蓝屏体检（蓝屏过 / 莫名重启）'
        Write-Host '    3 = 硬件体检（磁盘 / 电池 / 温度年检）'
        Write-Host '    4 = 性能体检（开机慢 / 用着卡）'
        Write-Host '    5 = 驱动体检（驱动来路 / 设备黄三角）'
        Write-Host '    6 = 安全体检（病毒防护 / 系统加固）'
        $ans = Read-Host '请输入数字（1-6）或直接回车跑全部'
        if ([string]::IsNullOrWhiteSpace($ans)) { $picked = 'all'; break }
        $k = $ans.Trim()
        if ($menuMap.ContainsKey($k)) { $picked = $menuMap[$k]; break }
        Write-Host "没认出「$k」——请输入 1-6，或直接回车。"
    }
    if ($picked -eq '') { $picked = 'all'; Write-Host '（连续 3 次未识别，按默认六类全查）' }
    if ($picked -ne 'all') {
        $TreeName = $picked
        Write-Host "→ 本轮单跑：$($menuNames[$picked])（出这一类的报告）"
    } else {
        Write-Host '→ 本轮六类全查（合并报告）'
    }
}

# ---------- 进度事件流（默认关：-ProgressFile 空则零副作用、零 stdout 新增） ----------
function Write-ProgressEvent {
    param([hashtable]$Fields)
    if ($ProgressFile -eq '') { return }
    $order = @('event', 'tree', 'layer', 'layerTitle', 'check', 'status', 'ms', 'exit', 'htmlReport', 'jsonReport')
    $o = [ordered]@{}
    foreach ($k in $order) {
        if ($Fields -and $Fields.ContainsKey($k) -and $null -ne $Fields[$k] -and ([string]$Fields[$k] -ne '')) { $o[$k] = $Fields[$k] }
    }
    # 1021 竞态收口：PS5.1 Add-Content 不容忍并发读句柄（GUI/网页壳轮询读进度文件时偶发撞车），
    # Stop 偏好下单次撞车=引擎中途退出。重试 5 次；全部失败=丢这一条事件（丢事件只影响进度显示，好过整树暴毙）。
    # 判定与 stdout 零改动（135 基线前后双跑证明）。
    $written = $false
    for ($i = 0; $i -lt 5 -and -not $written; $i++) {
        try {
            Add-Content -LiteralPath $ProgressFile -Value ([string]($o | ConvertTo-Json -Compress)) -Encoding UTF8
            $written = $true
        } catch { Start-Sleep -Milliseconds 40 }
    }
}

# ---------- 单检查项执行（子进程+总超时；经 Start-Job 数组传参，规避命令行空格/转义） ----------
function Invoke-Check {
    param([string]$CheckName, [int]$TimeoutSec = 60, [string]$MockFile = '')
    $script = Join-Path $root "checks/$CheckName.ps1"
    if (-not (Test-Path $script)) { $script = Join-Path $root "ext/checks/$CheckName.ps1" }   # v1.1.0 ext 口子：内置优先，ext 只补缺，永不覆盖内置
    if (-not (Test-Path $script)) { $script = Join-Path $dataRoot "ext/checks/$CheckName.ps1" }  # MSIX 用户 ext 检查脚本在数据根（与 server ext 树双目录扫描对齐；默认场景与上行同路径无害）
    if (-not (Test-Path $script)) {
        return [PSCustomObject]@{ name = $CheckName; status = 'SKIP'; evidence = "check script missing: $script"; suggestion = ''; detail = @{ reason = 'missing-script' } }
    }
    $job = Start-Job -ScriptBlock {
        param($ps, $s, $mf)
        # 父端按 UTF-8 解码子进程 stdout（中文 Windows 控制台默认 GBK，会打散 JSON 字符串）
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        # mock 走文件传路径（-MockFile）：5.1 命令行传参会吃掉内容里的双引号
        $extra = @()
        if ($mf) { $extra = @('-MockFile', $mf) }
        & $ps -NoProfile -ExecutionPolicy Bypass -File $s @extra 2>&1 | Out-String
    } -ArgumentList $diagPs, $script, $MockFile
    if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
        Stop-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ name = $CheckName; status = 'SKIP'; evidence = "check timed out after ${TimeoutSec}s"; suggestion = ''; detail = @{ reason = 'timeout' } }
    }
    $outText = (Receive-Job $job) | Out-String
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($outText.Trim() -eq '') {
        return [PSCustomObject]@{ name = $CheckName; status = 'SKIP'; evidence = "check produced no output"; suggestion = ''; detail = @{ reason = 'no-output' } }
    }
    try {
        return ($outText | ConvertFrom-Json)
    } catch {
        return [PSCustomObject]@{ name = $CheckName; status = 'SKIP'; evidence = "unparsable output: " + (($outText.Trim() -split "`r?`n") | Select-Object -First 3); suggestion = ''; detail = @{ reason = 'bad-json' } }
    }
}

# ---------- 报告头按树渲染（网络树无新字段=文案逐字不变，仅版本号随引擎走） ----------
function Get-TreeMeta {
    param($TreeData)
    $verdictTitle = if ($TreeData.PSObject.Properties['verdict_title'] -and $TreeData.verdict_title) { [string]$TreeData.verdict_title } else { '断点结论' }
    $hasReportName = $TreeData.PSObject.Properties['report_name'] -and $TreeData.report_name
    $reportName = if ($hasReportName) { [string]$TreeData.report_name } else { '网络体检报告' }
    $evidenceNote = if ($TreeData.PSObject.Properties['evidence_note'] -and $TreeData.evidence_note) { [string]$TreeData.evidence_note }
        elseif ($hasReportName) { '（按组，聚合取证）' } else { '（按组，从物理到应用）' }
    $layerCn = @('零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十')
    $layerTotal = @($TreeData.layers).Count
    $layerCnStr = if ($layerTotal -ge 1 -and $layerTotal -le 10) { $layerCn[$layerTotal] } else { [string]$layerTotal }
    return [PSCustomObject]@{ VerdictTitle = $verdictTitle; ReportName = $reportName; EvidenceNote = $evidenceNote; LayerCnStr = $layerCnStr }
}

# ---------- 逐层执行，遇 FAIL 定位断点（-Full 则跑完全部层）——单树逻辑，多树=外层循环复用 ----------
function Invoke-TreeLayers {
    param($TreeData)
    $layerResults = @()
    $breakLayer = $null
    foreach ($layer in $TreeData.layers) {
        $checks = @()
        foreach ($c in $layer.checks) {
            $mockFile = ''
            if ($MockDir -ne '') {
                $mf = Join-Path $MockDir "$c.txt"
                if (Test-Path $mf) { $mockFile = $mf }
                else {
                    $checks += [PSCustomObject]@{ name = $c; status = 'SKIP'; evidence = "mock file missing: $mf"; suggestion = ''; detail = @{ reason = 'missing-mock' } }
                    Write-ProgressEvent @{ event = 'check'; tree = $TreeData.tree; layer = $layer.name; layerTitle = $layer.title; check = $c; status = 'SKIP'; ms = 0 }
                    continue
                }
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $checks += (Invoke-Check $c -MockFile $mockFile)
            $sw.Stop()
            Write-ProgressEvent @{ event = 'check'; tree = $TreeData.tree; layer = $layer.name; layerTitle = $layer.title; check = $c; status = ([string]$checks[-1].status); ms = [int]$sw.ElapsedMilliseconds }
        }
        $hasFail = @($checks | Where-Object { $_.status -eq 'FAIL' }).Count -ge 1
        $layerResults += [PSCustomObject]@{
            name = $layer.name; title = $layer.title; verdict_fail = $layer.verdict_fail
            checks = $checks; state = $(if ($hasFail) { 'BREAK' } else { 'PASS' })
        }
        if ($hasFail) {
            if (-not $breakLayer) {
                $breakLayer = $layer
                Write-ProgressEvent @{ event = 'break'; tree = $TreeData.tree; layer = $layer.name; layerTitle = $layer.title }
            }
            if (-not $Full) { break }
        }
    }
    if (-not $breakLayer) {
        $ran = @($layerResults | ForEach-Object { $_.name })
        foreach ($layer in $TreeData.layers) {
            if ($ran -notcontains $layer.name) {
                $layerResults += [PSCustomObject]@{
                    name = $layer.name; title = $layer.title; verdict_fail = $layer.verdict_fail
                    checks = @(); state = 'PASSED-EARLIER'
                }
            }
        }
    } elseif ($breakLayer -and -not $Full) {
        $ran = @($layerResults | ForEach-Object { $_.name })
        foreach ($layer in $TreeData.layers) {
            if ($ran -notcontains $layer.name) {
                $layerResults += [PSCustomObject]@{
                    name = $layer.name; title = $layer.title; verdict_fail = $layer.verdict_fail
                    checks = @(); state = 'SKIPPED-AFTER-BREAK'
                }
            }
        }
    }
    # 排序还原树的层序
    $layerResults = @($TreeData.layers | ForEach-Object { $l = $_; $r = $layerResults | Where-Object { $_.name -eq $l.name }; $r })
    return [PSCustomObject]@{ Layers = $layerResults; BreakLayer = $breakLayer }
}

# ---------- 文本报告（stdout；单树文本=测试基线锚，v0.5 仅升版本号） ----------
function New-TextReport {
    param($LayerResults, $BreakLayer, $TreeData, [string]$VerdictTitle, [string]$ReportName, [string]$EvidenceNote, [string]$LayerCnStr, [string]$HostName, [string]$Ts)
    $sym = @{ PASS = '[PASS]'; FAIL = '[FAIL]'; SKIP = '[SKIP]' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("======================================================================")
    [void]$sb.AppendLine("电脑体检台 · $ReportName  v$engVersion   主机: $HostName   时间: $Ts")
    [void]$sb.AppendLine("体检全程只读 | 证据必附 | 修法见报告与修复中心（绿色可代跑，红色只给步骤）")
    [void]$sb.AppendLine("======================================================================")
    [void]$sb.AppendLine("")

    if ($BreakLayer) {
        [void]$sb.AppendLine("【$VerdictTitle】")
        [void]$sb.AppendLine("问题出在：$($BreakLayer.title)")
        $failedChecks = @($LayerResults | Where-Object { $_.name -eq $BreakLayer.name } | ForEach-Object { $_.checks } | Where-Object { $_.status -eq 'FAIL' })
        foreach ($f in $failedChecks) {
            [void]$sb.AppendLine("- $($f.name): " + (($f.evidence -split "`n" | Select-Object -First 2) -join ' | '))
        }
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("一句人话：$($BreakLayer.verdict_fail)")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("【修复方法】（绿色小修可在修复中心代跑；命令也可复制自己执行，附撤销方法）")
        $n = 1
        foreach ($f in $failedChecks) { if ($f.suggestion) { [void]$sb.AppendLine("$n. [$($f.name)]"); [void]$sb.AppendLine("   " + ($f.suggestion -replace "`n", "`n   ")); [void]$sb.AppendLine(""); $n++ } }
    } else {
        [void]$sb.AppendLine("【$VerdictTitle】")
        [void]$sb.AppendLine("${LayerCnStr}组全通，没发现问题。")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("一句人话：$($TreeData.verdict_all_pass)")
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("【证据链】$EvidenceNote")
    foreach ($l in $LayerResults) {
        $mark = switch ($l.state) { 'BREAK' { '▶问题' } 'PASS' { '·通过' } 'SKIPPED-AFTER-BREAK' { '↷未查(前层有问题)' } 'PASSED-EARLIER' { '·通过' } default { '·' } }
        $layerIdx = [array]::IndexOf(@($TreeData.layers | ForEach-Object { $_.name }), $l.name) + 1
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("--- $mark  第$layerIdx 组: $($l.title) ---")
        if ($l.checks.Count -eq 0) {
            $stateCn = switch ($l.state) { 'SKIPPED-AFTER-BREAK' { '前层有问题，这一层没查' } 'PASSED-EARLIER' { '前面层已全通' } default { [string]$l.state } }
            [void]$sb.AppendLine("    （$stateCn，未执行检查）")
            continue
        }
        foreach ($c in $l.checks) {
            [void]$sb.AppendLine("  $($sym[$c.status]) $($c.name)")
            foreach ($eline in ($c.evidence -split "`n")) { [void]$sb.AppendLine("       $eline") }
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("报告生成：电脑体检台 v$engVersion（体检全程只读，未改动任何系统设置）")
    return $sb.ToString()
}

# ---------- HTML 报告渲染（v0.5 只改"怎么显示"：数据源=同一层结果，判定文案逐字沿用；抽可复用函数+多树合并） ----------
function Escape-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text -replace '&', '&amp;'
    $t = $t -replace '<', '&lt;'
    $t = $t -replace '>', '&gt;'
    $t = $t -replace '"', '&quot;'
    return $t
}

$css = @'
body { font-family: "Segoe UI", system-ui, "Microsoft YaHei", sans-serif; background: #eef2f7; color: #1f2937; margin: 0; padding: 16px; }
.wrap { max-width: 920px; margin: 0 auto; }
.banner { background: linear-gradient(135deg, #0a1426 0%, #0d2140 100%); color: #fff; border-radius: 12px; padding: 18px 22px; border-bottom: 3px solid #0e9488; }
.banner h1 { margin: 0 0 6px 0; font-size: 21px; }
.banner .meta { font-size: 12.5px; opacity: .88; margin-top: 3px; }
.card { background: #fff; border-radius: 12px; box-shadow: 0 2px 10px rgba(13, 33, 64, .08); padding: 16px 20px; margin-top: 14px; }
.verdict-fail { border-left: 5px solid #d92b2b; }
.verdict-pass { border-left: 5px solid #188a42; }
.verdict h2 { margin: 0 0 8px 0; font-size: 17px; }
.verdict .where { font-size: 15px; font-weight: 600; }
.verdict .plain { font-size: 14px; margin: 10px 0 0 0; background: #f6f9fc; border-radius: 8px; padding: 8px 12px; }
h2.sec { font-size: 16px; margin: 0 0 10px 0; }
.fix-card { border: 1px solid #f3dcdc; border-left: 4px solid #d92b2b; border-radius: 10px; padding: 10px 14px; margin-bottom: 10px; background: #fffafa; }
.fix-title { font-weight: 600; font-size: 14px; margin-bottom: 6px; }
pre.fix-body { white-space: pre-wrap; word-break: break-all; }
details.layer { background: #fff; border-radius: 12px; box-shadow: 0 2px 10px rgba(13, 33, 64, .08); margin-top: 10px; }
details.layer summary { cursor: pointer; padding: 12px 18px; font-size: 15px; font-weight: 600; list-style-position: inside; border-radius: 12px; }
details.layer summary:hover { background: #f2f6fa; }
details.layer .body { padding: 2px 18px 14px 18px; }
.check { margin-bottom: 12px; }
.check-head { font-size: 14px; font-family: Consolas, monospace; margin-bottom: 4px; }
pre.ev { background: #f6f9fc; border: 1px solid #e3eaf2; border-radius: 8px; padding: 8px 12px; font-size: 12.5px; white-space: pre-wrap; word-break: break-all; margin: 0; }
.badge { display: inline-block; border-radius: 999px; padding: 1px 9px; font-size: 12px; font-weight: 600; vertical-align: 1px; }
.b-pass { background: #e6f7ee; color: #14804a; }
.b-fail { background: #fdeeed; color: #c62828; }
.b-skip { background: #edf0f5; color: #667085; }
.m-fail { color: #d92b2b; }
.m-pass { color: #188a42; }
.m-skip { color: #667085; }
.cnt { font-weight: 400; font-size: 12.5px; color: #667085; margin-left: 6px; }
.empty-note { font-size: 13px; color: #667085; }
footer { text-align: center; font-size: 12px; color: #8a94a6; margin: 18px 0 8px 0; }
@media print { body { background: #fff; padding: 0; } .card, details.layer { box-shadow: none; } details.layer .body { display: block !important; } }
@media (max-width: 480px) { pre.ev { font-size: 13.5px; } .check-head { font-size: 13px; } body { padding: 10px; } }
'@

# 合并报告专用样式（只挂在 all 页面，单树页面 CSS 逐字节不动）
$cssMerge = @'
table.ov { width: 100%; border-collapse: collapse; font-size: 14px; }
table.ov th { text-align: left; padding: 6px 10px; border-bottom: 2px solid #dbe4ee; color: #0f3d66; font-size: 13.5px; }
table.ov td { padding: 8px 10px; border-bottom: 1px solid #eef2f6; }
.tree-sec h2.sec { border-bottom: 2px solid #e5eaf0; padding-bottom: 6px; margin: 0 0 4px 0; }
'@

# 结论卡（fail：断点组+FAIL 项摘录+一句人话；pass：N 组全通+一句人话）
function New-VerdictCardHtml {
    param($Results, $BreakLayer, $TreeData, [string]$VerdictTitle, [string]$LayerCnStr)
    $layerNames = @($TreeData.layers | ForEach-Object { $_.name })
    $failedChecks = @()
    if ($BreakLayer) {
        $failedChecks = @($Results | Where-Object { $_.name -eq $BreakLayer.name } | ForEach-Object { $_.checks } | Where-Object { $_.status -eq 'FAIL' })
    }
    $h = New-Object System.Text.StringBuilder
    if ($BreakLayer) {
        [void]$h.AppendLine('<div class="card verdict verdict-fail"><h2>【' + (Escape-Html $VerdictTitle) + '】</h2>')
        [void]$h.AppendLine('<div class="where">问题出在：' + (Escape-Html $BreakLayer.title) + '</div>')
        foreach ($f in $failedChecks) {
            [void]$h.AppendLine('<div class="check-head"><span class="badge b-fail">FAIL</span> ' + (Escape-Html $f.name) + '</div>')
            [void]$h.AppendLine('<pre class="ev">' + (Escape-Html (($f.evidence -split "`r?`n" | Select-Object -First 2) -join ' | ')) + '</pre>')
        }
        [void]$h.AppendLine('<p class="plain">一句人话：' + (Escape-Html $BreakLayer.verdict_fail) + '</p></div>')
    } else {
        [void]$h.AppendLine('<div class="card verdict verdict-pass"><h2>【' + (Escape-Html $VerdictTitle) + '】</h2>')
        [void]$h.AppendLine('<div class="where">' + (Escape-Html $LayerCnStr) + '组全通，没发现问题。</div>')
        [void]$h.AppendLine('<p class="plain">一句人话：' + (Escape-Html $TreeData.verdict_all_pass) + '</p></div>')
    }
    return $h.ToString()
}

# 修复建议卡（按检查项分段）
function New-FixCardsHtml {
    param($Results, $BreakLayer)
    $failedChecks = @($Results | Where-Object { $_.name -eq $BreakLayer.name } | ForEach-Object { $_.checks } | Where-Object { $_.status -eq 'FAIL' })
    $withSug = @($failedChecks | Where-Object { $_.suggestion })
    if ($withSug.Count -lt 1) { return '' }
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine('<div class="card"><h2 class="sec">【修复方法】（绿色小修可在修复中心代跑；命令也可复制自己执行，附撤销方法）</h2>')
    $n = 1
    foreach ($f in $withSug) {
        [void]$h.AppendLine('<div class="fix-card"><div class="fix-title">' + $n + '. [' + (Escape-Html $f.name) + ']</div>')
        [void]$h.AppendLine('<pre class="fix-body">' + (Escape-Html $f.suggestion) + '</pre></div>')
        $n++
    }
    [void]$h.AppendLine('</div>')
    return $h.ToString()
}

# 证据链（按组可折叠：断点组默认展开）
function New-EvidenceChainHtml {
    param($Results, $TreeData, [string]$EvidenceNote)
    $layerNames = @($TreeData.layers | ForEach-Object { $_.name })
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine('<div class="card"><h2 class="sec">【证据链】' + (Escape-Html $EvidenceNote) + '</h2>')
    foreach ($l in $Results) {
        $layerIdx = [array]::IndexOf($layerNames, $l.name) + 1
        $openAttr = ''
        $mark = ''; $mcls = ''
        switch ($l.state) {
            'BREAK' { $mark = '▶问题'; $mcls = 'm-fail'; $openAttr = ' open' }
            'PASS' { $mark = '·通过'; $mcls = 'm-pass' }
            'PASSED-EARLIER' { $mark = '·通过'; $mcls = 'm-pass' }
            'SKIPPED-AFTER-BREAK' { $mark = '↷未查(前层有问题)'; $mcls = 'm-skip' }
            default { $mark = '·'; $mcls = 'm-skip' }
        }
        $cPass = @($l.checks | Where-Object { $_.status -eq 'PASS' }).Count
        $cFail = @($l.checks | Where-Object { $_.status -eq 'FAIL' }).Count
        $cSkip = @($l.checks | Where-Object { $_.status -eq 'SKIP' }).Count
        $cnt = @()
        if ($cFail -gt 0) { $cnt += "$cFail FAIL" }
        if ($cPass -gt 0) { $cnt += "$cPass PASS" }
        if ($cSkip -gt 0) { $cnt += "$cSkip SKIP" }
        $cntStr = if ($cnt.Count -gt 0) { ' <span class="cnt">' + ($cnt -join ' · ') + '</span>' } else { '' }
        [void]$h.AppendLine('<details class="layer"' + $openAttr + '>')
        [void]$h.AppendLine('<summary><span class="' + $mcls + '">' + $mark + '</span> 第' + $layerIdx + '组: ' + (Escape-Html $l.title) + $cntStr + '</summary>')
        [void]$h.AppendLine('<div class="body">')
        if (@($l.checks).Count -eq 0) {
            $stateCn = switch ($l.state) { 'SKIPPED-AFTER-BREAK' { '前层有问题，这一层没查' } 'PASSED-EARLIER' { '前面层已全通' } default { [string]$l.state } }
            [void]$h.AppendLine('<div class="empty-note">（' + (Escape-Html $stateCn) + '，未执行检查）</div>')
        } else {
            foreach ($c in $l.checks) {
                $bcls = switch ($c.status) { 'PASS' { 'b-pass' } 'FAIL' { 'b-fail' } default { 'b-skip' } }
                [void]$h.AppendLine('<div class="check"><div class="check-head"><span class="badge ' + $bcls + '">' + (Escape-Html $c.status) + '</span> ' + (Escape-Html $c.name) + '</div>')
                [void]$h.AppendLine('<pre class="ev">' + (Escape-Html ([string]$c.evidence)) + '</pre></div>')
            }
        }
        [void]$h.AppendLine('</div></details>')
    }
    [void]$h.AppendLine('</div>')
    return $h.ToString()
}

function New-HtmlReport {
    param($Results, $BreakLayer, $TreeData, [string]$ReportName, [string]$VerdictTitle, [string]$EvidenceNote, [string]$HostName, [string]$TimeStamp, [string]$LayerCnStr)
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine('<!DOCTYPE html>')
    [void]$h.AppendLine('<html lang="zh-CN">')
    [void]$h.AppendLine('<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$h.AppendLine('<title>' + (Escape-Html $ReportName) + ' ' + (Escape-Html $TimeStamp) + '</title>')
    [void]$h.AppendLine('<style>' + $css + '</style></head>')
    [void]$h.AppendLine('<body><div class="wrap">')
    [void]$h.AppendLine('<div class="banner"><h1>' + (Escape-Html $ReportName) + '</h1>')
    [void]$h.AppendLine('<div class="meta">主机: ' + (Escape-Html $HostName) + ' &middot; ' + (Escape-Html $TimeStamp) + ' &middot; 电脑体检台 v' + $engVersion + '</div>')
    [void]$h.AppendLine('<div class="meta">体检全程只读 | 证据必附 | 修法见报告与修复中心（绿色可代跑，红色只给步骤）</div></div>')
    [void]$h.Append((New-VerdictCardHtml -Results $Results -BreakLayer $BreakLayer -TreeData $TreeData -VerdictTitle $VerdictTitle -LayerCnStr $LayerCnStr))
    if ($BreakLayer) {
        [void]$h.Append((New-FixCardsHtml -Results $Results -BreakLayer $BreakLayer))
    }
    [void]$h.Append((New-EvidenceChainHtml -Results $Results -TreeData $TreeData -EvidenceNote $EvidenceNote))
    [void]$h.AppendLine('<footer>报告生成：电脑体检台 v' + $engVersion + '（体检全程只读，未改动任何系统设置）</footer>')
    [void]$h.AppendLine('</div></body></html>')
    return $h.ToString()
}

# ---------- 多树合并 HTML（all/多选共用：banner 标题随路径=全面体检报告/合并体检报告；总览表+每树 verdict 卡与证据链） ----------
function New-MergedHtmlReport {
    param($Overview, [string[]]$SectionHtmls, [string]$HostName, [string]$TimeStamp, [string]$ReportTitle = '全面体检报告')
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine('<!DOCTYPE html>')
    [void]$h.AppendLine('<html lang="zh-CN">')
    [void]$h.AppendLine('<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$h.AppendLine('<title>' + $ReportTitle + ' ' + (Escape-Html $TimeStamp) + '</title>')
    [void]$h.AppendLine('<style>' + $css + "`n" + $cssMerge + '</style></head>')
    [void]$h.AppendLine('<body><div class="wrap">')
    [void]$h.AppendLine('<div class="banner"><h1>' + $ReportTitle + '</h1>')
    [void]$h.AppendLine('<div class="meta">主机: ' + (Escape-Html $HostName) + ' &middot; ' + (Escape-Html $TimeStamp) + ' &middot; 电脑体检台 v' + $engVersion + '</div>')
    [void]$h.AppendLine('<div class="meta">体检全程只读 | 证据必附 | 修法见报告与修复中心（绿色可代跑，红色只给步骤）</div></div>')
    [void]$h.AppendLine('<div class="card"><h2 class="sec">体检总览</h2>')
    [void]$h.AppendLine('<table class="ov"><tr><th>体检树</th><th>结论</th><th>FAIL 项</th></tr>')
    foreach ($o in $Overview) {
        $conclCls = if ($o.FailCnt -gt 0) { 'm-fail' } else { 'm-pass' }
        $failBadge = if ($o.FailCnt -gt 0) { '<span class="badge b-fail">' + $o.FailCnt + ' FAIL</span>' } else { '<span class="badge b-pass">0</span>' }
        [void]$h.AppendLine('<tr><td>' + (Escape-Html $o.ReportName) + '</td><td class="' + $conclCls + '">' + (Escape-Html $o.Conclusion) + '</td><td>' + $failBadge + '</td></tr>')
    }
    [void]$h.AppendLine('</table></div>')
    foreach ($sec in $SectionHtmls) { [void]$h.Append($sec) }
    [void]$h.AppendLine('<footer>报告生成：电脑体检台 v' + $engVersion + '（体检全程只读，未改动任何系统设置）</footer>')
    [void]$h.AppendLine('</div></body></html>')
    return $h.ToString()
}

# ---------- JSON 结构化报告（默认关：与 HTML 同源 layerResults，GUI 结果树数据源；禁解析 HTML 充数） ----------
function New-JsonPayload {
    param([array]$TreeEntries, [string]$HostName, [string]$Ts)
    $trees = @()
    foreach ($te in $TreeEntries) {
        $meta = Get-TreeMeta $te.TreeData
        $trees += [ordered]@{
            tree = [string]$te.TreeData.tree
            report_name = $meta.ReportName
            verdict_title = $meta.VerdictTitle
            verdict_all_pass = [string]$te.TreeData.verdict_all_pass
            break_layer = $(if ($te.BreakLayer) { [string]$te.BreakLayer.name } else { $null })
            layers = @(foreach ($l in @($te.Layers)) {
                [ordered]@{
                    name = [string]$l.name; title = [string]$l.title; state = [string]$l.state
                    verdict_fail = [string]$l.verdict_fail
                    checks = @(foreach ($c in @($l.checks)) {
                        [ordered]@{ name = [string]$c.name; status = [string]$c.status; evidence = [string]$c.evidence; suggestion = [string]$c.suggestion; detail = $c.detail }
                    })
                }
            })
        }
    }
    return [ordered]@{ engine = "电脑体检台 v$engVersion"; host = $HostName; time = $Ts; trees = $trees }
}

# ---------- reports/ 保留策略（diag-* 的 .html/.txt/.md/.json 保留最新 50 份） ----------
function Trim-Reports {
    $repDir = $reportsDir
    if (-not (Test-Path $repDir)) { return }
    # 1021 修正：按文件名内嵌时间戳排序，不能按整名字典序——跨树前缀时 diag-all-*（字母 a）
    # 恒排"最旧"，目录到 50 上限时合并报告会被先裁掉（真机实锤：写完即被删→下载 404）。
    $files = @(Get-ChildItem -LiteralPath $repDir -File -Filter 'diag-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.html', '.txt', '.md', '.json' } |
        Sort-Object -Descending -Property @{e = { if ($_.Name -match '^diag-[A-Za-z0-9_]+-(\d{8}-\d{6})\.(html|txt|md|json)$') { $Matches[1] } else { '00000000-000000' } }}, @{e = { $_.Name }})
    $old = @($files | Select-Object -Skip 50)
    if ($old.Count -gt 0) {
        foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        Write-Output "[报告清理] 已删 $($old.Count) 份最旧报告（reports/ 上限 50 份）"
    }
}

# ---------- 多树模式（-TreeName all=内置六树全集；或逗号分隔多树如 network,security；单树执行路径零改动） ----------
if ($TreeName -eq 'all' -or $TreeName -match ',') {
    if ($TreeName -eq 'all') {
        $treesOrder = @('network', 'bluescreen', 'hardware', 'performance', 'drivers', 'security')
        $mergedTitle = '全面体检报告'
    } else {
        $treesOrder = @($TreeName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
        if ($treesOrder.Count -lt 2) { Write-Error "multi-tree mode needs 2+ trees, got: $TreeName"; exit 3 }
        foreach ($t in $treesOrder) {
            $tf = Join-Path $root "trees/$t.yaml"
            if (-not (Test-Path $tf)) { Write-Error "tree not found: $tf"; exit 3 }
        }
        $mergedTitle = '合并体检报告'
    }
    $treeDatas = @{}
    foreach ($t in $treesOrder) {
        $tf = Join-Path $root "trees/$t.yaml"
        if (-not (Test-Path $tf)) { Write-Error "tree not found: $tf"; exit 3 }
        $treeDatas[$t] = Get-Content $tf -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $hostName = $env:COMPUTERNAME

    Write-Output "电脑体检台 · $mergedTitle v$engVersion"
    Write-Output ""

    $anyFailAll = $false
    $overview = @()
    $sectionsHtml = @()
    $treeEntries = @()
    foreach ($t in $treesOrder) {
        $td = $treeDatas[$t]
        $meta = Get-TreeMeta $td
        $treeSw = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Invoke-TreeLayers -TreeData $td
        $treeSw.Stop()
        $treeEntries += @{ TreeData = $td; Layers = $res.Layers; BreakLayer = $res.BreakLayer }
        $treeFail = @($res.Layers | ForEach-Object { $_.checks } | Where-Object { $_.status -eq 'FAIL' }).Count
        Write-ProgressEvent @{ event = 'tree_done'; tree = $t; ms = [int]$treeSw.ElapsedMilliseconds; status = $(if ($treeFail -gt 0) { 'FAIL' } else { 'PASS' }) }
        Write-Output (New-TextReport -LayerResults $res.Layers -BreakLayer $res.BreakLayer -TreeData $td -VerdictTitle $meta.VerdictTitle -ReportName $meta.ReportName -EvidenceNote $meta.EvidenceNote -LayerCnStr $meta.LayerCnStr -HostName $hostName -Ts $ts)
        Write-Output ""
        $failCnt = @($res.Layers | ForEach-Object { $_.checks } | Where-Object { $_.status -eq 'FAIL' }).Count
        if ($failCnt -gt 0) { $anyFailAll = $true }
        $concl = if ($res.BreakLayer) { '问题出在：' + $res.BreakLayer.title } else { "$($meta.LayerCnStr)组全通" }
        $overview += [PSCustomObject]@{ Tree = $t; ReportName = $meta.ReportName; Conclusion = $concl; FailCnt = $failCnt }
        # 每树一节：节标题+verdict 卡+修复建议+证据链（复用单树渲染件）
        $sec = New-Object System.Text.StringBuilder
        [void]$sec.Append('<div class="tree-sec">')
        [void]$sec.AppendLine('<h2 class="sec">' + (Escape-Html $meta.ReportName) + '</h2>')
        [void]$sec.Append((New-VerdictCardHtml -Results $res.Layers -BreakLayer $res.BreakLayer -TreeData $td -VerdictTitle $meta.VerdictTitle -LayerCnStr $meta.LayerCnStr))
        if ($res.BreakLayer) {
            [void]$sec.Append((New-FixCardsHtml -Results $res.Layers -BreakLayer $res.BreakLayer))
        }
        [void]$sec.Append((New-EvidenceChainHtml -Results $res.Layers -TreeData $td -EvidenceNote $meta.EvidenceNote))
        [void]$sec.Append('</div>')
        $sectionsHtml += $sec.ToString()
    }

    $htmlFile = ''
    $jsonFileOut = ''
    if (-not $NoSaveReport) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $repFile = Join-Path $reportsDir ("diag-all-$stamp.html")
        $html = New-MergedHtmlReport -Overview $overview -SectionHtmls $sectionsHtml -HostName $hostName -TimeStamp $ts -ReportTitle $mergedTitle
        Set-Content -Path $repFile -Value $html -Encoding UTF8
        Write-Output "[报告已保存] $repFile"
        $htmlFile = $repFile
        if ($OpenReport) { Start-Process $repFile }
        if ($JsonReport) {
            $jsonFile = Join-Path $reportsDir ("diag-all-$stamp.json")
            Set-Content -LiteralPath $jsonFile -Value (ConvertTo-Json (New-JsonPayload -TreeEntries $treeEntries -HostName $hostName -Ts $ts) -Depth 12) -Encoding UTF8
            $jsonFileOut = $jsonFile
        }
        Trim-Reports
    }
    $exitAll = $(if ($anyFailAll) { 2 } else { 0 })
    Write-ProgressEvent @{ event = 'done'; tree = 'all'; exit = $exitAll; htmlReport = $htmlFile; jsonReport = $jsonFileOut }
    exit $exitAll
}

# ---------- 单树模式（v0.1 起主路径，v0.5 函数化重构输出逐字一致；v1.1.0 ext 口子：内置优先，ext 树只补缺，同名冲突忽略+stderr 告警） ----------
$treeFile = Join-Path $root "trees/$TreeName.yaml"
$extTreeFile = Join-Path $root "ext/trees/$TreeName.yaml"
if (Test-Path $treeFile) {
    if (Test-Path $extTreeFile) { [Console]::Error.WriteLine("[ext] tree '$TreeName' conflicts with built-in; ext copy ignored") }
} elseif (Test-Path $extTreeFile) {
    $treeFile = $extTreeFile
    [Console]::Error.WriteLine("[ext] tree '$TreeName' loaded from ext/trees")
} else {
    Write-Error "tree not found: $treeFile"; exit 3
}
$tree = Get-Content $treeFile -Raw -Encoding UTF8 | ConvertFrom-Json

$meta = Get-TreeMeta $tree
$verdictTitle = $meta.VerdictTitle
$reportName = $meta.ReportName
$evidenceNote = $meta.EvidenceNote
$layerCnStr = $meta.LayerCnStr

$res = Invoke-TreeLayers -TreeData $tree
$layerResults = $res.Layers
$breakLayer = $res.BreakLayer
Write-ProgressEvent @{ event = 'tree_done'; tree = [string]$tree.tree; status = $(if ($breakLayer) { 'FAIL' } else { 'PASS' }) }

# ---------- 报告 ----------
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$hostName = $env:COMPUTERNAME
$report = New-TextReport -LayerResults $layerResults -BreakLayer $breakLayer -TreeData $tree -VerdictTitle $verdictTitle -ReportName $reportName -EvidenceNote $evidenceNote -LayerCnStr $layerCnStr -HostName $hostName -Ts $ts
Write-Output $report

$htmlFile = ''
$jsonFileOut = ''
if (-not $NoSaveReport) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $repFile = Join-Path $reportsDir ("diag-$TreeName-$stamp.html")
    $html = New-HtmlReport -Results $layerResults -BreakLayer $breakLayer -TreeData $tree -ReportName $reportName -VerdictTitle $verdictTitle -EvidenceNote $evidenceNote -HostName $hostName -TimeStamp $ts -LayerCnStr $layerCnStr
    Set-Content -Path $repFile -Value $html -Encoding UTF8
    Write-Output ""
    Write-Output "[报告已保存] $repFile"
    $htmlFile = $repFile
    if ($OpenReport) { Start-Process $repFile }
    if ($JsonReport) {
        $jsonFile = Join-Path $reportsDir ("diag-$TreeName-$stamp.json")
        Set-Content -LiteralPath $jsonFile -Value (ConvertTo-Json (New-JsonPayload -TreeEntries @(@{ TreeData = $tree; Layers = $layerResults; BreakLayer = $breakLayer }) -HostName $hostName -Ts $ts) -Depth 12) -Encoding UTF8
        $jsonFileOut = $jsonFile
    }
    Trim-Reports
}

$anyFail = @($layerResults | ForEach-Object { $_.checks } | Where-Object { $_.status -eq 'FAIL' }).Count -ge 1
$exitCode = $(if ($anyFail) { 2 } else { 0 })
Write-ProgressEvent @{ event = 'done'; tree = [string]$tree.tree; exit = $exitCode; htmlReport = $htmlFile; jsonReport = $jsonFileOut }
exit $exitCode
