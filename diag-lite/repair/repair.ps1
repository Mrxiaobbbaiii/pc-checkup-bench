#Requires -Version 5.1
<#
diag repair executor v0.9 —— 修复事务五段式执行器（design 第四节）
五段=加载 → 预检 → 回滚包（黄级：撤销脚本先行落盘 reports\rollback\）→ 执行（超时受控；需提权时
      一次 RunAs 跑完 还原点→备份→主步骤→失败自动回滚）→ 复跑对应检查项验证 → 留痕 reports/repair-log.json。
绿级=直接执行；黄级=必须显式 -AllowYellow（执行前自动生成撤销脚本；-WithRestorePoint=先建系统还原点，
      还原点建不出来=中止不执行——「先留后路」约定）；红级永远拒绝加载执行（永不代跑=出厂闸铁律）。
用法：repair.ps1 -ActionId net_flush_dns [-ActionsDir <dir>] [-Root <dir>] [-OutFile <file>] [-NeverElevate]
      [-AllowYellow] [-WithRestorePoint]
  -ActionsDir   动作库目录（默认 <本脚本目录>\actions；单测可指向临时目录塞 fixture）
  -Root         诊断根目录（默认本脚本目录的上级；验证段读其中 checks\，留痕写其中 reports\）
  -OutFile      结果 JSON 落盘路径（server 数据通路；缺省只打 stdout——与检查项同款单 JSON 接口）
  -NeverElevate 禁止提权（单测专用：需要提权时按预检失败收场，绝不弹 UAC 卡死自动化）
提权说明：Win10/11 上 ipconfig/arp 这类命令非提权一律报「请求的操作需要提升」（1021 本机实测）。
      提权=把全部步骤打包成一个临时 ps1 一次性 RunAs：UAC 关提示的机器静默跑（本机即如此），
      默认 UAC 的机器弹一次系统确认框（ui 侧预告过）；用户点否=优雅失败，什么都不改。
      提权子进程超时杀不动（非提权父进程对提权子进程无权 taskkill）——如实记超时，内部每步自带超时会自灭。
工艺坑（1021 实测定案）：①PS 变量名大小写不敏感——局部 $steps 会清空同名参数 $Steps（本轮烧 3 轮抓到），
      累加器一律异名；②Start-Process -PassThu 的 ExitCode 对秒退进程常返回 null（cast 成 0=假成功），
      子进程统一走 .NET Process+同步 WaitForExit 后读 ExitCode，null 一律按 -1 失败论处。
判定零改动：engine/checks/trees 一字不碰；验证段只是以只读方式子进程调用 checks\<项>.ps1。
退出码：0=五段走完且成功；1=预检/执行/验证未通过；3=动作库或参数错误。
#>
param(
    [Parameter(Mandatory = $true)][string]$ActionId,
    [string]$ActionsDir = '',
    [string]$Root = '',
    [string]$OutFile = '',
    [switch]$NeverElevate,
    [switch]$AllowYellow,
    [switch]$WithRestorePoint,
    # 1024 修复体验轮：用户知情跳过系统还原点（还原点服务被关的机器；撤销脚本+备份仍生成=第二道保险兜底）
    [switch]$SkipRestorePoint
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if ($ActionsDir -eq '') { $ActionsDir = Join-Path $scriptDir 'actions' }
if ($Root -eq '') { $Root = Split-Path $scriptDir -Parent }
$checksDir = Join-Path $Root 'checks'
# 数据根（MSIX 适配）：商店版安装目录只读，修复记录/回滚包外移到 %LOCALAPPDATA%\电脑体检台；
# DIAG_DATA_ROOT（server 注入/测试覆盖）优先；Inno/lite 布局不变（数据根=应用根）。判定与动作语义零碰。
$dataRoot = $Root
if ($env:DIAG_DATA_ROOT) { $dataRoot = $env:DIAG_DATA_ROOT }
elseif ($Root -like '*\WindowsApps\*') { $dataRoot = Join-Path $env:LOCALAPPDATA '电脑体检台' }
$reportsDir = Join-Path $dataRoot 'reports'
$diagPs = (Get-Process -Id $PID).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-repair-$PID-$stamp")
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$script:stepSeq = 0

function Test-IsElevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-PsSingleQuoted([string]$s) {
    return "'" + ($s -replace "'", "''") + "'"
}

# 读子进程输出文件：先按严格 UTF-8 试解，失败回退系统默认码页（中文 Windows 原生命令重定向输出是 GBK）
function Read-TextSmart([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $bytes = @()
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return '' }
    if ($bytes.Count -eq 0) { return '' }
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($bytes)
    } catch {
        return [System.Text.Encoding]::Default.GetString($bytes)
    }
}

# 取输出头几行（留痕/结果里只放摘录，防大输出撑爆 JSON）
function Get-HeadLines([string]$Text, [int]$N = 3) {
    if (-not $Text) { return '' }
    return (@(($Text -split "`r?`n") | Where-Object { $_.Trim() -ne '' }) | Select-Object -First $N) -join ' | '
}

# 参数串拼接（.NET Process.Arguments 单串）：含空格的参数加引号（施工约定：动作 args 现库全为简单词）
function Join-StepArgs([string[]]$ArgList) {
    return (@($ArgList) | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '') + '"' } else { $_ } }) -join ' '
}

# .NET 子进程跑一步：同步 WaitForExit 后读 ExitCode（可靠）；输出经管道流读回（本域命令输出都很小，管道不会塞死；
# 挂死由超时兜底）。超时=Kill+timed_out（如启动失败=evid 里的启动错误）
function Invoke-StepDirect {
    param([string]$Exe, [string[]]$ArgList, [int]$TimeoutMs)
    $script:stepSeq++
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = Join-StepArgs @($ArgList)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($psi.PSObject.Properties['StandardOutputEncoding']) { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 }
    if ($psi.PSObject.Properties['StandardErrorEncoding']) { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 }
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ exit = -1; ms = [int]$sw.ElapsedMilliseconds; timed_out = $false; out = ''; err_head = ('启动失败：' + $_.Exception.Message) }
    }
    $timed = -not $p.WaitForExit($TimeoutMs)
    if ($timed) {
        try { $p.Kill() } catch { }
        $sw.Stop()
        return @{ exit = -1; ms = [int]$sw.ElapsedMilliseconds; timed_out = $true; out = ''; err_head = '' }
    }
    $null = $p.WaitForExit()   # 同步等待确保 ExitCode 就位（带时限版返回时可能还没填）
    $out = ''
    $err = ''
    try { $out = $p.StandardOutput.ReadToEnd() } catch { }
    try { $err = $p.StandardError.ReadToEnd() } catch { }
    $code = -1
    try { if ($null -ne $p.ExitCode) { $code = [int]$p.ExitCode } } catch { }
    $sw.Stop()
    $mix = $out
    if ($err) { $mix = ($out.TrimEnd() + "`n" + $err).Trim() }
    return @{ exit = $code; ms = [int]$sw.ElapsedMilliseconds; timed_out = $false; out = $mix; err_head = (Get-HeadLines $err 2) }
}

# 生成提权内层脚本（v0.9）：全部步骤一次打包（一次 UAC）；执行序=还原点（可选，失败即中止）→
# 备份步骤（黄级，任一失败即中止、不碰主步骤）→ 主步骤 → 有失败且配了回滚=按序自动回滚；
# 内层每步=.NET Process+自带超时（提权上下文里自己可杀自己）；每步 stdout/stderr 落文件，
# 末尾写 summary（restore_point/aborted/steps[idx/phase/exit/timed_out/ms]，UTF8）
function New-ElevatedInner {
    param($MainSteps, $BackupSteps, $RollbackSteps, [int]$PerStepTimeoutMs, [bool]$WantRestorePoint, [string]$ElevActionId)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('$results = @()')
    [void]$sb.AppendLine('$aborted = ""')
    [void]$sb.AppendLine('$mainFailed = $false')
    [void]$sb.AppendLine('$rpOk = $true')
    [void]$sb.AppendLine('$rpNote = ""')
    if ($WantRestorePoint) {
        # 还原点：前后序号对比 + 当日已有兜底（Checkpoint-Computer 会被 24h 频率限制静默跳过）
        [void]$sb.AppendLine('$rpSeq = {')
        [void]$sb.AppendLine('    param($tag)')
        [void]$sb.AppendLine('    try {')
        [void]$sb.AppendLine('        $all = @(Get-CimInstance -Namespace "root\default" -ClassName "SystemRestore" -ErrorAction Stop)')
        [void]$sb.AppendLine('        if ($all.Count -eq 0) { return -1 }')
        [void]$sb.AppendLine('        $mx = ($all | Measure-Object -Property SequenceNumber -Maximum).Maximum')
        [void]$sb.AppendLine('        if ($null -eq $mx) { return -1 }')
        [void]$sb.AppendLine('        return [int]$mx')
        [void]$sb.AppendLine('    } catch { return -1 }')
        [void]$sb.AppendLine('}')
        [void]$sb.AppendLine('$rpBefore = & $rpSeq 0')
        [void]$sb.AppendLine('try {')
        [void]$sb.AppendLine('    Checkpoint-Computer -Description ' + (ConvertTo-PsSingleQuoted ('diag repair ' + $ElevActionId)) + ' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop')
        [void]$sb.AppendLine('    $rpAfter = & $rpSeq 1')
        [void]$sb.AppendLine('    if ($rpAfter -gt $rpBefore) { $rpOk = $true; $rpNote = "created" }')
        [void]$sb.AppendLine('    else {')
        [void]$sb.AppendLine('        $rpOk = $false')
        [void]$sb.AppendLine('        try {')
        [void]$sb.AppendLine('            $dayStart = (Get-Date).Date')
        [void]$sb.AppendLine('            $all2 = @(Get-CimInstance -Namespace "root\default" -ClassName "SystemRestore" -ErrorAction Stop)')
        [void]$sb.AppendLine('            foreach ($s in $all2) { try { $t = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$s.CreationTime); if ($t -ge $dayStart) { $rpOk = $true; $rpNote = "today-already"; break } } catch { } }')
        [void]$sb.AppendLine('        } catch { }')
        [void]$sb.AppendLine('        if (-not $rpOk) { $rpNote = "系统还原点没建成（system protection 可能没开）" }')
        [void]$sb.AppendLine('    }')
        [void]$sb.AppendLine('} catch { $rpOk = $false; $rpNote = "系统还原点没建成: " + $_.Exception.Message }')
        [void]$sb.AppendLine('if (-not $rpOk) { $aborted = "restore_point" }')
    }
    $phaseDefs = @()
    foreach ($b in @($BackupSteps)) { $phaseDefs += @{ phase = 'backup'; st = $b } }
    foreach ($m in @($MainSteps)) { $phaseDefs += @{ phase = 'main'; st = $m } }
    $idx = 0
    foreach ($pd in $phaseDefs) {
        $idx++
        $st = $pd.st
        $exeQ = ConvertTo-PsSingleQuoted ([string]$st.exe)
        $argsQ = ConvertTo-PsSingleQuoted (Join-StepArgs @(@($st.args) | ForEach-Object { [string]$_ }))
        $outF = ConvertTo-PsSingleQuoted (Join-Path $workDir ("step-$idx-out.txt"))
        $errF = ConvertTo-PsSingleQuoted (Join-Path $workDir ("step-$idx-err.txt"))
        $stepGuard = 'if (-not $aborted'
        if ($pd.phase -eq 'main') { $stepGuard += ' -and (-not $mainFailed)' }
        [void]$sb.AppendLine(($stepGuard + ') {'))
        [void]$sb.AppendLine('    $__psi = New-Object System.Diagnostics.ProcessStartInfo')
        [void]$sb.AppendLine('    $__psi.FileName = ' + $exeQ)
        [void]$sb.AppendLine('    $__psi.Arguments = ' + $argsQ)
        [void]$sb.AppendLine('    $__psi.UseShellExecute = $false')
        [void]$sb.AppendLine('    $__psi.CreateNoWindow = $true')
        [void]$sb.AppendLine('    $__psi.RedirectStandardOutput = $true')
        [void]$sb.AppendLine('    $__psi.RedirectStandardError = $true')
        [void]$sb.AppendLine('    $__sw = [System.Diagnostics.Stopwatch]::StartNew()')
        [void]$sb.AppendLine('    try { $__p = [System.Diagnostics.Process]::Start($__psi) } catch { $__p = $null; $__exit = -1; $__timed = $false }')
        [void]$sb.AppendLine('    if ($__p) {')
        [void]$sb.AppendLine(("        `$__timed = -not `$__p.WaitForExit($PerStepTimeoutMs)"))
        [void]$sb.AppendLine('        if ($__timed) { try { $__p.Kill() } catch { } } else { $null = $__p.WaitForExit() }')
        [void]$sb.AppendLine('        $__exit = -1')
        [void]$sb.AppendLine('        if (-not $__timed) { try { if ($null -ne $__p.ExitCode) { $__exit = [int]$__p.ExitCode } } catch { } }')
        [void]$sb.AppendLine('    }')
        [void]$sb.AppendLine('    $__out = ""; $__err = ""')
        [void]$sb.AppendLine('    if (-not $__timed) { try { $__out = $__p.StandardOutput.ReadToEnd() } catch { }; try { $__err = $__p.StandardError.ReadToEnd() } catch { } }')
        [void]$sb.AppendLine('    $__sw.Stop()')
        [void]$sb.AppendLine('    [System.IO.File]::WriteAllText(' + $outF + ', $__out)')
        [void]$sb.AppendLine('    [System.IO.File]::WriteAllText(' + $errF + ', $__err)')
        [void]$sb.AppendLine('    $results += [pscustomobject]@{ idx = ' + $idx + '; phase = ' + (ConvertTo-PsSingleQuoted $pd.phase) + '; exit = $__exit; timed_out = $__timed; ms = [int]$__sw.ElapsedMilliseconds }')
        [void]$sb.AppendLine(('    if ($__exit -ne 0 -or $__timed) { ' + $(if ($pd.phase -eq 'backup') { '$aborted = "backup_failed"' } else { '$mainFailed = $true' }) + ' }'))
        [void]$sb.AppendLine('}')
    }
    # 主步骤失败后自动回滚（回滚步骤结果照记，不影响 ok 判定——失败已经成立）
    if (@($RollbackSteps).Count) {
        foreach ($rb in @($RollbackSteps)) {
            $idx++
            $exeQ = ConvertTo-PsSingleQuoted ([string]$rb.exe)
            $argsQ = ConvertTo-PsSingleQuoted (Join-StepArgs @(@($rb.args) | ForEach-Object { [string]$_ }))
            $outF = ConvertTo-PsSingleQuoted (Join-Path $workDir ("step-$idx-out.txt"))
            $errF = ConvertTo-PsSingleQuoted (Join-Path $workDir ("step-$idx-err.txt"))
            [void]$sb.AppendLine(('if ($mainFailed) {'))
            [void]$sb.AppendLine('    $__psi = New-Object System.Diagnostics.ProcessStartInfo')
            [void]$sb.AppendLine('    $__psi.FileName = ' + $exeQ)
            [void]$sb.AppendLine('    $__psi.Arguments = ' + $argsQ)
            [void]$sb.AppendLine('    $__psi.UseShellExecute = $false')
            [void]$sb.AppendLine('    $__psi.CreateNoWindow = $true')
            [void]$sb.AppendLine('    $__psi.RedirectStandardOutput = $true')
            [void]$sb.AppendLine('    $__psi.RedirectStandardError = $true')
            [void]$sb.AppendLine('    $__sw = [System.Diagnostics.Stopwatch]::StartNew()')
            [void]$sb.AppendLine('    try { $__p = [System.Diagnostics.Process]::Start($__psi) } catch { $__p = $null; $__exit = -1; $__timed = $false }')
            [void]$sb.AppendLine('    if ($__p) {')
            [void]$sb.AppendLine(("        `$__timed = -not `$__p.WaitForExit($PerStepTimeoutMs)"))
            [void]$sb.AppendLine('        if ($__timed) { try { $__p.Kill() } catch { } } else { $null = $__p.WaitForExit() }')
            [void]$sb.AppendLine('        $__exit = -1')
            [void]$sb.AppendLine('        if (-not $__timed) { try { if ($null -ne $__p.ExitCode) { $__exit = [int]$__p.ExitCode } } catch { } }')
            [void]$sb.AppendLine('    }')
            [void]$sb.AppendLine('    $__out = ""; $__err = ""')
            [void]$sb.AppendLine('    if (-not $__timed) { try { $__out = $__p.StandardOutput.ReadToEnd() } catch { }; try { $__err = $__p.StandardError.ReadToEnd() } catch { } }')
            [void]$sb.AppendLine('    $__sw.Stop()')
            [void]$sb.AppendLine('    [System.IO.File]::WriteAllText(' + $outF + ', $__out)')
            [void]$sb.AppendLine('    [System.IO.File]::WriteAllText(' + $errF + ', $__err)')
            [void]$sb.AppendLine('    $results += [pscustomobject]@{ idx = ' + $idx + '; phase = "rollback"; exit = $__exit; timed_out = $__timed; ms = [int]$__sw.ElapsedMilliseconds }')
            [void]$sb.AppendLine('}')
        }
    }
    $sumF = ConvertTo-PsSingleQuoted (Join-Path $workDir 'elev-summary.json')
    [void]$sb.AppendLine('$summary = @{ restore_point = @{ requested = ' + $(if ($WantRestorePoint) { '$true' } else { '$false' }) + '; ok = $rpOk; note = $rpNote }; aborted = $aborted; steps = $results }')
    [void]$sb.AppendLine('ConvertTo-Json -InputObject $summary -Compress -Depth 6 | Set-Content -LiteralPath ' + $sumF + ' -Encoding UTF8')
    $innerPath = Join-Path $workDir 'elev-inner.ps1'
    [System.IO.File]::WriteAllText($innerPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return $innerPath
}

# 1024 修复体验轮：还原点中止的人话解释（用户实锤「restore point failed: <系统原文>」看不懂、不知道下一步）
function Get-RpAbortHuman([string]$Note) {
    $why = if ($Note -match '禁用了该服务|disabled|没有启用') { '这台电脑的系统还原功能被关着——常见原因：优化软件为省空间把它关掉了。' }
    elseif ($Note -match 'frequency|24') { 'Windows 对手动建还原点有每天次数限制，今天的次数用完了。' }
    else { $Note }
    return '系统还原点没建成，安全起见什么都没改。' + $why + '想继续有两条路：开启系统还原后再修（Win 搜索「创建还原点」→ 选 C 盘 → 配置 → 启用），或跳过还原点直接修（撤销脚本已备好，出问题双击它就能还原）。'
}

# 提权执行全部步骤（RunAs 一次）；UAC 被点否=优雅失败；总时限=各步超时和+120 秒确认宽限（+90 秒还原点宽限）
function Invoke-StepsElevated {
    param($MainSteps, $BackupSteps, $RollbackSteps, [int]$PerStepTimeoutMs, [bool]$WantRestorePoint, [string]$ElevActionId)
    $perStep = [int]$PerStepTimeoutMs
    $total = $perStep * (@($MainSteps).Count + @($BackupSteps).Count + @($RollbackSteps).Count) + 120000
    if ($WantRestorePoint) { $total += 90000 }
    $inner = New-ElevatedInner -MainSteps $MainSteps -BackupSteps $BackupSteps -RollbackSteps $RollbackSteps -PerStepTimeoutMs $perStep -WantRestorePoint $WantRestorePoint -ElevActionId $ElevActionId
    $emptyRp = @{ requested = $WantRestorePoint; ok = $true; note = '' }
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $inner) -Verb RunAs -PassThru -WindowStyle Hidden
    } catch {
        return @{ ok = $false; declined = $true; rp_failed = $false; backup_failed = $false; steps = @(); rp = $emptyRp; note = '管理员确认框被取消了（点了「否」或没有权限）——什么都没有改动' }
    }
    $timed = -not $p.WaitForExit($total)
    $summary = $null
    $sumPath = Join-Path $workDir 'elev-summary.json'
    if (Test-Path -LiteralPath $sumPath) {
        try { $summary = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $sumPath -Raw -Encoding UTF8) } catch { $summary = $null }
    }
    if ($null -eq $summary) {
        if ($timed) { return @{ ok = $false; declined = $false; rp_failed = $false; backup_failed = $false; steps = @(); rp = $emptyRp; note = "提权执行超时（${total}ms 内没有交回结果）" } }
        return @{ ok = $false; declined = $false; rp_failed = $false; backup_failed = $false; steps = @(); rp = $emptyRp; note = '提权执行没有交回结果（异常退出）' }
    }
    # 还原点结果（老版 summary 没有这个键=没请求过，视为 ok）
    $rp = @{ requested = $WantRestorePoint; ok = $true; note = '' }
    if ($summary.PSObject.Properties['restore_point'] -and $summary.restore_point) {
        $rp.ok = [bool]$summary.restore_point.ok
        $rp.note = [string]$summary.restore_point.note
    }
    if ([string]$summary.aborted -eq 'restore_point') {
        return @{ ok = $false; declined = $false; rp_failed = $true; backup_failed = $false; steps = @(); rp = $rp; note = [string]$rp.note }
    }
    $rawSteps = @()
    if ($summary.PSObject.Properties['steps']) { $rawSteps = @($summary.steps) }
    if ($rawSteps.Count -gt 0 -and $rawSteps[0] -is [object[]]) { $rawSteps = @($rawSteps[0]) }   # 5.1 顶层数组多包一层双保险解包
    if ([string]$summary.aborted -eq 'backup_failed') {
        return @{ ok = $false; declined = $false; rp_failed = $false; backup_failed = $true; steps = $rawSteps; rp = $rp; note = '备份没有全部成功，为了能撤销，什么都没有改' }
    }
    if ($rawSteps.Count -eq 0) {
        return @{ ok = $false; declined = $false; rp_failed = $false; backup_failed = $false; steps = @(); rp = $rp; note = '提权结果组装异常（零步骤）' }
    }
    # 步骤定义按 内层同序（备份→主→回滚）对齐 idx，组装带 phase 的完整结果
    $defs = @()
    foreach ($b in @($BackupSteps)) { $defs += @{ phase = 'backup'; exe = [string]$b.exe; args = @(@($b.args) | ForEach-Object { [string]$_ }); desc = '[备份] ' + [string]$b.desc } }
    foreach ($m in @($MainSteps)) { $defs += @{ phase = 'main'; exe = [string]$m.exe; args = @(@($m.args) | ForEach-Object { [string]$_ }); desc = [string]$m.desc } }
    foreach ($rb in @($RollbackSteps)) { $defs += @{ phase = 'rollback'; exe = [string]$rb.exe; args = @(@($rb.args) | ForEach-Object { [string]$_ }); desc = '[自动回滚] ' + [string]$rb.desc } }
    $built = @()
    for ($i = 0; $i -lt $defs.Count; $i++) {
        $s = $null
        foreach ($cand in $rawSteps) { if ([int]$cand.idx -eq ($i + 1)) { $s = $cand; break } }
        $code = -1; $msv = 0; $tmo = $false
        if ($s) {
            if ($null -ne $s.exit) { $code = [int]$s.exit }
            if ($s.PSObject.Properties['ms']) { $msv = [int]$s.ms }
            $tmo = [bool]$s.timed_out
        }
        $outF = Join-Path $workDir ("step-" + ($i + 1) + "-out.txt")
        $errF = Join-Path $workDir ("step-" + ($i + 1) + "-err.txt")
        $out = (Read-TextSmart $outF).TrimEnd()
        $err = Read-TextSmart $errF
        if ($err) { $out = ($out + "`n" + $err).Trim() }
        $built += @{
            phase = [string]$defs[$i].phase
            exe = [string]$defs[$i].exe; args = [string[]]$defs[$i].args; desc = [string]$defs[$i].desc
            exit = $code; ms = $msv; timed_out = $tmo; out = $out; err_head = (Get-HeadLines $err 2)
        }
    }
    return @{ ok = $true; declined = $false; rp_failed = $false; backup_failed = $false; steps = $built; rp = $rp; note = '' }
}

# 系统还原点（黄级可选；提权上下文里才可靠）：Checkpoint-Computer 被频率限制静默跳过时
# 靠「前后序号对比 + 当日已有还原点」判定；系统保护没开启=如实报失败，调用方按约中止不执行
function Get-RpMaxSeq {
    try {
        $all = @(Get-CimInstance -Namespace 'root\default' -ClassName 'SystemRestore' -ErrorAction Stop)
        if ($all.Count -eq 0) { return -1 }
        $m = ($all | Measure-Object -Property SequenceNumber -Maximum).Maximum
        if ($null -eq $m) { return -1 }
        return [int]$m
    } catch { return -1 }
}
function Test-RpTodayExists {
    try {
        $all = @(Get-CimInstance -Namespace 'root\default' -ClassName 'SystemRestore' -ErrorAction Stop)
        $dayStart = (Get-Date).Date
        foreach ($s in $all) {
            try {
                $t = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$s.CreationTime)
                if ($t -ge $dayStart) { return $true }
            } catch { }
        }
        return $false
    } catch { return $false }
}
function Invoke-RestorePointLocal {
    param([string]$RpActionId)
    try {
        $before = Get-RpMaxSeq
        Checkpoint-Computer -Description ("diag repair " + $RpActionId) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        $after = Get-RpMaxSeq
        if ($after -gt $before) { return @{ ok = $true; note = 'created' } }
        if (Test-RpTodayExists) { return @{ ok = $true; note = '今天已建过还原点（系统 24 小时内只建一个），以最近的还原点为准' } }
        return @{ ok = $false; note = '系统还原点没有建成（常见原因：系统保护没开启，可在控制面板搜「创建还原点」打开）。按「先留后路」的约定，这次先不执行，什么都没有改' }
    } catch {
        return @{ ok = $false; note = '创建系统还原点失败：' + $_.Exception.Message + '。按「先留后路」的约定，这次先不执行，什么都没有改' }
    }
}

# 预检：ARP 表有手动加的静态记录则挡下（保「完全可逆」承诺——静态记录删了不会自动长回来）
function Test-PrecheckNoStaticArp {
    $raw = ''
    try { $raw = (& arp.exe -a 2>&1 | Out-String) } catch { return @{ ok = $false; note = 'ARP 表读不出来，为稳妥起见不自动清' } }
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '静态|static' -and $line -match '\d{1,3}(\.\d{1,3}){3}') {
            return @{ ok = $false; note = 'ARP 表里有手动加的静态记录——为可撤销起见不自动清；请先记下静态项，再自己在管理员窗口执行 arp -d *' }
        }
    }
    return @{ ok = $true; note = '' }
}

# 验证段：复跑对应检查项（与 engine Invoke-Check 同款子进程+60 秒超时；只读）
function Invoke-VerifyCheck {
    param([string]$Name)
    $script = Join-Path $checksDir ($Name + '.ps1')
    if (-not (Test-Path -LiteralPath $script)) { return @{ name = $Name; status = 'SKIP'; evidence = 'verify check script missing' } }
    # stdout 单独收（不加 2>&1）：检查项契约=单 JSON 打 stdout；nslookup 这类命令的 stderr 提示
    # （如 Non-authoritative answer）经子进程错误流回传会把合并流污染成不可解析——engine 同款调用
    # 在真机 stderr 非空时同样中招（1021 实测，挂账下棒 engine 侧修复；本棒只修自己，判定层零改动）
    $job = Start-Job -ScriptBlock {
        param($ps, $s)
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        & $ps -NoProfile -ExecutionPolicy Bypass -File $s | Out-String
    } -ArgumentList $diagPs, $script
    if (-not (Wait-Job $job -Timeout 60)) {
        Stop-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return @{ name = $Name; status = 'SKIP'; evidence = 'verify check timed out (60s)' }
    }
    $outText = (Receive-Job $job -ErrorAction SilentlyContinue) | Out-String
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $j = $null
    try { $j = $outText | ConvertFrom-Json } catch { $j = $null }
    if ($null -eq $j -and $outText -match '(?s)\{\s*"name".*\}\s*$') {
        try { $j = $Matches[0] | ConvertFrom-Json } catch { $j = $null }
    }
    if ($null -eq $j) { return @{ name = $Name; status = 'SKIP'; evidence = 'verify check unparsable' } }
    return @{ name = [string]$j.name; status = [string]$j.status; evidence = (Get-HeadLines ([string]$j.evidence) 2) }
}

function Get-ResultJson {
    param($Obj)
    return (ConvertTo-Json -InputObject $Obj -Depth 10 -Compress)
}

# ---------- ① 加载 ----------
$failStage = ''
$loadErr = ''
$action = $null
if ($ActionId -notmatch '^[a-z0-9_]+$') { $loadErr = 'bad action id' }
elseif (-not (Test-Path -LiteralPath (Join-Path $ActionsDir ($ActionId + '.json')))) { $loadErr = "action not found: $ActionId" }
else {
    try { $action = Get-Content -LiteralPath (Join-Path $ActionsDir ($ActionId + '.json')) -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $loadErr = 'action json unparsable: ' + $_.Exception.Message }
}
if (-not $loadErr) {
    $lvl = [string]$action.level
    if ($lvl -eq 'red') { $loadErr = 'red level actions are never auto-executed (step guide only)' }
    elseif ($lvl -eq 'yellow' -and -not $AllowYellow) { $loadErr = 'yellow level requires explicit -AllowYellow (item-by-item confirm flow)' }
    elseif (@('green', 'yellow') -notcontains $lvl) { $loadErr = "unknown level: $lvl" }
    elseif (-not @($action.steps).Count) { $loadErr = 'action has no steps' }
    elseif ($lvl -eq 'yellow' -and (-not @($action.backup_steps).Count -or -not @($action.undo_script).Count)) { $loadErr = 'yellow action missing rollback package definition (backup_steps/undo_script)' }
}
if ($loadErr) {
    $r = [ordered]@{ ok = $false; id = $ActionId; level = ''; name = ''; fail_stage = 'load'; error = $loadErr; stages = @{} }
    $json = Get-ResultJson $r
    Write-Output $json
    if ($OutFile -ne '') { Set-Content -LiteralPath $OutFile -Value $json -Encoding UTF8 }
    Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    exit 3
}

$actName = [string]$action.name
$actLevel = [string]$action.level
$timeoutMs = [int]$action.timeout_sec * 1000
if ($timeoutMs -le 0) { $timeoutMs = 30000 }

# ---------- ② 预检 ----------
$isElev = Test-IsElevated
$preOk = $true
$preNotes = @()
foreach ($pc in @($action.prechecks)) {
    if ([string]$pc -eq 'no_static_arp') {
        $r = Test-PrecheckNoStaticArp
        if (-not $r.ok) { $preOk = $false; $preNotes += $r.note }
    } else {
        $preOk = $false
        $preNotes += ('未知预检条件：' + $pc)
    }
}
$needElev = ([bool]$action.requires_admin -and -not $isElev)
$elevDeclinedNote = ''
if (-not $preOk) { $failStage = 'precheck' }
elseif ($needElev -and $NeverElevate) {
    # 单测语境：不弹 UAC，按预检失败收场（自助文案）
    $cmdText = (@($action.steps) | ForEach-Object { [string]$_.exe + ' ' + (@($_.args) -join ' ') }) -join ' ; '
    $preOk = $false
    $failStage = 'precheck'
    $preNotes += ('这一步要管理员权限（测试模式不弹窗不执行）。想自己跑：开管理员命令行执行 ' + $cmdText)
}

# ---------- ②.5 回滚包（黄级：撤销脚本先行落盘 reports\rollback\；还原点在执行段建——提权内层/直跑分支各自处理） ----------
$pkgOk = $true
$pkgNote = ''
$pkgUndoFile = ''
$pkgBackupDir = ''
$rpRequested = $false
$rpOk = $true
$rpNote = ''
$isYellow = ($actLevel -eq 'yellow')
if ($isYellow) {
    $rpRequested = [bool]$WithRestorePoint -and -not $SkipRestorePoint
    if (-not $preOk) {
        $pkgNote = '预检没过，未生成回滚包'
    } else {
        try {
            $pkgBackupDir = Join-Path $reportsDir ('rollback\' + $ActionId + '-' + $stamp)
            New-Item -ItemType Directory -Path $pkgBackupDir -Force | Out-Null
            $pkgUndoFile = Join-Path $pkgBackupDir ('undo-' + $ActionId + '.bat')
            $undoSb = New-Object System.Text.StringBuilder
            # bat 内容纯 ASCII（工艺红线：bat 无 BOM 无中文字面量，中文说明走 UI）
            [void]$undoSb.AppendLine('@echo off')
            [void]$undoSb.AppendLine('REM diag repair rollback package: ' + $ActionId)
            [void]$undoSb.AppendLine('REM generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            [void]$undoSb.AppendLine('REM restores the settings backed up BEFORE the repair ran.')
            [void]$undoSb.AppendLine('REM how to use: right-click this file - Run as administrator, then restart the PC.')
            foreach ($ln in @($action.undo_script)) { [void]$undoSb.AppendLine(([string]$ln -replace '\{BK\}', $pkgBackupDir)) }
            [void]$undoSb.AppendLine('pause')
            [System.IO.File]::WriteAllText($pkgUndoFile, $undoSb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
            # 写盘后回读断言（不信写成功自报）
            if (-not (Test-Path -LiteralPath $pkgUndoFile)) { throw 'undo script not found after write' }
            if ((Get-Content -LiteralPath $pkgUndoFile -First 1) -ne '@echo off') { throw 'undo script content mismatch' }
        } catch {
            $pkgOk = $false
            $pkgNote = '回滚包生成失败：' + $_.Exception.Message
            $failStage = 'rollback_pkg'
        }
    }
}

# ---------- ③ 执行 ----------
$execSteps = @()
$execOk = $false
$execNote = ''
# 备份步 args 的 {BK} 占位符在此替换成真实备份目录（pkg 段已建好目录；两执行路径共用）
$bkSteps = @()
if ($isYellow) {
    $bkSteps = @(foreach ($bst in @($action.backup_steps)) {
        [ordered]@{
            exe = [string]$bst.exe
            args = @(@($bst.args) | ForEach-Object { ([string]$_ -replace '\{BK\}', $pkgBackupDir) })
            desc = [string]$bst.desc
        }
    })
}
if ($preOk) {
    if ($failStage -eq 'rollback_pkg') {
        $execNote = '回滚包没准备好，未执行任何修改'
    } elseif ($needElev -and -not $NeverElevate) {
        # 一次提权跑完：还原点（可选）→ 备份（黄级）→ 主步骤（失败即停）→ 自动回滚
        $r = Invoke-StepsElevated -MainSteps @($action.steps) -BackupSteps $bkSteps -RollbackSteps @($action.rollback) -PerStepTimeoutMs $timeoutMs -WantRestorePoint $rpRequested -ElevActionId $ActionId
        if ($r.rp_failed) {
            $rpOk = $false; $rpNote = [string]$r.rp.note
            $execNote = Get-RpAbortHuman $rpNote
            $failStage = 'rollback_pkg'
        } elseif (-not $r.ok) {
            $execNote = [string]$r.note
            if ($r.backup_failed) { $failStage = 'rollback_pkg' }
            if ($r.declined) { $elevDeclinedNote = [string]$r.note }
            # 失败分支也如实带出已跑步骤（备份跑到哪一步、退出码——排障与记录都要）
            foreach ($st in @($r.steps)) {
                $execSteps += @{
                    phase = [string]$st.phase
                    exe = [string]$st.exe; args = @($st.args); desc = [string]$st.desc
                    exit = [int]$st.exit; ms = [int]$st.ms; timed_out = [bool]$st.timed_out; out_head = (Get-HeadLines ([string]$st.out) 3)
                }
            }
        } else {
            $rpOk = [bool]$r.rp.ok; $rpNote = [string]$r.rp.note
            if ($rpRequested -and -not $rpOk) {
                # 内层还原点失败却交回成功（理论不达）——按中止兜底
                $execNote = $rpNote
                $failStage = 'rollback_pkg'
            } else {
                foreach ($st in @($r.steps)) {
                    $execSteps += @{
                        phase = [string]$st.phase
                        exe = [string]$st.exe; args = @($st.args); desc = [string]$st.desc
                        exit = [int]$st.exit; ms = [int]$st.ms; timed_out = [bool]$st.timed_out; out_head = (Get-HeadLines ([string]$st.out) 3)
                    }
                }
                $execOk = -not (@($execSteps) | Where-Object { $_.phase -ne 'rollback' -and ($_.exit -ne 0 -or $_.timed_out) }).Count
                if (-not $execOk) { $execNote = '有步骤没跑成（详见各步结果）' }
            }
        }
    } else {
        # 直跑路径：还原点（可选）→ 备份（黄级）→ 主步骤（失败即停）→ 自动回滚
        if ($rpRequested) {
            if ($NeverElevate) {
                $rpOk = $false
                $rpNote = '创建系统还原点需要管理员权限（测试模式不弹窗不执行）——先不执行，什么都没有改'
            } else {
                $rp = Invoke-RestorePointLocal -RpActionId $ActionId
                $rpOk = [bool]$rp.ok; $rpNote = [string]$rp.note
            }
        }
        if ($rpRequested -and -not $rpOk) {
            $execNote = Get-RpAbortHuman $rpNote
            $failStage = 'rollback_pkg'
        } else {
            $bkFailed = $false
            foreach ($bst in $bkSteps) {
                $sr = Invoke-StepDirect -Exe ([string]$bst.exe) -ArgList @(@($bst.args) | ForEach-Object { [string]$_ }) -TimeoutMs $timeoutMs
                $execSteps += @{
                    phase = 'backup'
                    exe = [string]$bst.exe; args = @(@($bst.args) | ForEach-Object { [string]$_ }); desc = '[备份] ' + [string]$bst.desc
                    exit = [int]$sr.exit; ms = [int]$sr.ms; timed_out = [bool]$sr.timed_out; out_head = (Get-HeadLines $sr.out 3)
                }
                if ($sr.exit -ne 0 -or $sr.timed_out) {
                    $bkFailed = $true
                    $execNote = '备份「' + [string]$bst.desc + '」没成功——为了能撤销，先什么都不改'
                    break
                }
            }
            if (-not $bkFailed) {
                $i = 0
                foreach ($st in $action.steps) {
                    $i++
                    $sr = Invoke-StepDirect -Exe ([string]$st.exe) -ArgList @(@($st.args) | ForEach-Object { [string]$_ }) -TimeoutMs $timeoutMs
                    $execSteps += @{
                        phase = 'main'
                        exe = [string]$st.exe; args = @(@($st.args) | ForEach-Object { [string]$_ }); desc = [string]$st.desc
                        exit = [int]$sr.exit; ms = [int]$sr.ms; timed_out = [bool]$sr.timed_out; out_head = (Get-HeadLines $sr.out 3)
                    }
                    if ($sr.exit -ne 0 -or $sr.timed_out) {
                        $execNote = '步骤「' + [string]$st.desc + '」' + $(if ($sr.timed_out) { '超时被停' } else { '没有成功（退出码 ' + $sr.exit + '）' })
                        break
                    }
                }
                if (-not $execNote) { $execOk = $true }
                if (-not $execOk -and @($action.rollback).Count) {
                    # 回滚序列：执行失败后按序跑（绿级现库都为空；fixture 单测覆盖此路径）
                    foreach ($rb in @($action.rollback)) {
                        $sr = Invoke-StepDirect -Exe ([string]$rb.exe) -ArgList @(@($rb.args) | ForEach-Object { [string]$_ }) -TimeoutMs $timeoutMs
                        $execSteps += @{
                            phase = 'rollback'
                            exe = [string]$rb.exe; args = @(@($rb.args) | ForEach-Object { [string]$_ }); desc = '[自动回滚] ' + [string]$rb.desc
                            exit = [int]$sr.exit; ms = [int]$sr.ms; timed_out = [bool]$sr.timed_out; out_head = (Get-HeadLines $sr.out 3)
                        }
                    }
                }
            } else {
                $failStage = 'rollback_pkg'
            }
        }
    }
    if (-not $execOk -and -not $execNote) { $execNote = '执行没有成功' }
    if (-not $execOk -and $failStage -eq '') { $failStage = 'exec' }
} else {
    $execNote = '预检没通过，未执行任何修改'
}

# ---------- ④ 验证（复跑对应检查项；执行没成则跳过） ----------
$verifyChecks = @()
$verifyNote = ''
if (-not $preOk) { $verifyNote = '预检未通过，跳过验证' }
elseif ($failStage -eq 'rollback_pkg') { $verifyNote = '没有执行任何修改（安全中止），无需验证' }
elseif (-not $execOk) { $verifyNote = '执行没成功，跳过验证' }
elseif (-not @($action.verify_checks).Count) { $verifyNote = '该动作没有配验证检查项' }
else {
    foreach ($vc in @($action.verify_checks)) {
        $verifyChecks += (Invoke-VerifyCheck ([string]$vc))
    }
}

# ---------- ⑤ 留痕（reports/repair-log.json 追加一行；engine 的 50 份裁剪只动 diag-*，不碰本文件） ----------
$okOverall = ($preOk -and $execOk)
$logOk = $false
$logErr = ''
try {
    if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
    $logLine = [ordered]@{
        time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); host = $env:COMPUTERNAME
        id = $ActionId; name = $actName; level = $actLevel
        ok = $okOverall; fail_stage = $failStage
        elevated_run = $(if ($needElev -and -not $NeverElevate) { $true } else { $false })
        steps = @(foreach ($es in $execSteps) { [ordered]@{ phase = $es.phase; exe = $es.exe; args = $es.args; exit = $es.exit; ms = $es.ms; timed_out = $es.timed_out; out_head = $es.out_head } })
        verify = @(foreach ($v in $verifyChecks) { [ordered]@{ name = $v.name; status = $v.status } })
    }
    if ($isYellow) {
        $logLine['pkg'] = [ordered]@{ undo_file = $pkgUndoFile; backup_dir = $pkgBackupDir; restore_point = [ordered]@{ requested = $rpRequested; ok = $rpOk } }
    }
    Add-Content -LiteralPath (Join-Path $reportsDir 'repair-log.json') -Value (Get-ResultJson $logLine) -Encoding UTF8
    $logOk = $true
} catch { $logErr = $_.Exception.Message }

# ---------- 汇总（ok = 预检过 + 备份/主步骤全部 exit=0 且未超时；验证结果如实另报，不并入 ok） ----------
$ok = $okOverall
$human = ''
if ($ok) {
    $vSum = ''
    if ($verifyChecks.Count) {
        $p = @($verifyChecks | Where-Object { $_.status -eq 'PASS' }).Count
        $vSum = "；复检 $($p)/$($verifyChecks.Count) 项正常"
    }
    $human = "「$actName」执行完成$vSum"
    if ($isYellow -and $pkgUndoFile) {
        $rel = $pkgUndoFile
        if ($rel -like ($Root + '*')) { $rel = $rel.Substring($Root.Length).TrimStart('\') }
        $human += '；撤销脚本已生成：' + $rel
    }
    if ($rpRequested -and $rpNote -and $rpNote -ne 'created') { $human += '（还原点：' + $rpNote + '）' }
    $human += $(if ($verifyNote) { "（$verifyNote）" } else { '' })
} elseif ($failStage -eq 'precheck') {
    $human = "「$actName」没有执行：" + (@($preNotes) -join '；')
} elseif ($failStage -eq 'rollback_pkg') {
    $human = "「$actName」没有执行：$execNote$(if ($pkgNote -and $pkgOk) { '；回滚包已备好可重试' })"
} elseif ($elevDeclinedNote) {
    $human = "「$actName」没有执行：$elevDeclinedNote"
} else {
    $human = "「$actName」没有成功：$execNote"
}

$stagesOut = [ordered]@{
    precheck = [ordered]@{ ok = $preOk; notes = @($preNotes); admin = $isElev; elevated_run = $(if ($needElev -and -not $NeverElevate) { $true } else { $false }) }
}
if ($isYellow) {
    $stagesOut['pkg'] = [ordered]@{ ok = $pkgOk; note = $pkgNote; undo_file = $pkgUndoFile; backup_dir = $pkgBackupDir; restore_point = [ordered]@{ requested = $rpRequested; ok = $rpOk; note = $rpNote } }
}
$stagesOut['exec']   = [ordered]@{ ok = $execOk; note = $execNote; steps = @(foreach ($es in $execSteps) { [ordered]@{ phase = $es.phase; exe = $es.exe; args = $es.args; desc = $es.desc; exit = $es.exit; ms = $es.ms; timed_out = $es.timed_out; out_head = $es.out_head } }) }
$stagesOut['verify'] = [ordered]@{ note = $verifyNote; checks = @(foreach ($v in $verifyChecks) { [ordered]@{ name = $v.name; status = $v.status; evidence_head = $v.evidence } }) }
$stagesOut['log']    = [ordered]@{ ok = $logOk; file = (Join-Path $reportsDir 'repair-log.json'); err = $logErr }

$result = [ordered]@{
    ok = $ok; id = $ActionId; name = $actName; level = $actLevel; fail_stage = $failStage
    human = $human
    stages = $stagesOut
}
$json = Get-ResultJson $result
Write-Output $json
if ($OutFile -ne '') { Set-Content -LiteralPath $OutFile -Value $json -Encoding UTF8 }
Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
exit $(if ($ok) { 0 } else { 1 })
