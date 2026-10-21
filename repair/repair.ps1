#Requires -Version 5.1
<#
diag repair executor v0.8.1 —— 修复事务五段式执行器（design 第四节）
只执行绿级动作。五段=加载 → 预检 → 执行（超时受控；需提权时 Start-Process -Verb RunAs 一次提权跑全部步骤）
      → 复跑对应检查项验证 → 留痕 reports/repair-log.json。
黄级/红级动作一律拒绝加载执行（红级永不代跑=出厂闸铁律）。
用法：repair.ps1 -ActionId net_flush_dns [-ActionsDir <dir>] [-Root <dir>] [-OutFile <file>] [-NeverElevate]
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
    [switch]$NeverElevate
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if ($ActionsDir -eq '') { $ActionsDir = Join-Path $scriptDir 'actions' }
if ($Root -eq '') { $Root = Split-Path $scriptDir -Parent }
$checksDir = Join-Path $Root 'checks'
$reportsDir = Join-Path $Root 'reports'
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

# 生成提权内层脚本：全部步骤一次打包（一次 UAC）；内层每步=.NET Process+自带超时（提权上下文里自己可杀自己）；
# 每步 stdout/stderr 落文件（外层统一 Read-TextSmart 解码），末尾写 summary（idx/exit/timed_out/ms）
function New-ElevatedInner {
    param($StepList, [int]$PerStepTimeoutMs)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('$results = @()')
    $i = 0
    foreach ($st in $StepList) {
        $i++
        $exeQ = ConvertTo-PsSingleQuoted ([string]$st.exe)
        $argsQ = ConvertTo-PsSingleQuoted (Join-StepArgs @(@($st.args) | ForEach-Object { [string]$_ }))
        $outF = ConvertTo-PsSingleQuoted (Join-Path $workDir ("step-$i-out.txt"))
        $errF = ConvertTo-PsSingleQuoted (Join-Path $workDir ("step-$i-err.txt"))
        [void]$sb.AppendLine("`$__psi = New-Object System.Diagnostics.ProcessStartInfo")
        [void]$sb.AppendLine("`$__psi.FileName = $exeQ")
        [void]$sb.AppendLine("`$__psi.Arguments = $argsQ")
        [void]$sb.AppendLine('$__psi.UseShellExecute = $false')
        [void]$sb.AppendLine('$__psi.CreateNoWindow = $true')
        [void]$sb.AppendLine('$__psi.RedirectStandardOutput = $true')
        [void]$sb.AppendLine('$__psi.RedirectStandardError = $true')
        [void]$sb.AppendLine('$__sw = [System.Diagnostics.Stopwatch]::StartNew()')
        [void]$sb.AppendLine('$__p = [System.Diagnostics.Process]::Start($__psi)')
        [void]$sb.AppendLine("`$__timed = -not `$__p.WaitForExit($PerStepTimeoutMs)")
        [void]$sb.AppendLine('if ($__timed) { try { $__p.Kill() } catch { } } else { $null = $__p.WaitForExit() }')
        [void]$sb.AppendLine('$__out = ""; $__err = ""')
        [void]$sb.AppendLine('if (-not $__timed) { try { $__out = $__p.StandardOutput.ReadToEnd() } catch { }; try { $__err = $__p.StandardError.ReadToEnd() } catch { } }')
        [void]$sb.AppendLine('$__exit = -1')
        [void]$sb.AppendLine('if (-not $__timed) { try { if ($null -ne $__p.ExitCode) { $__exit = [int]$__p.ExitCode } } catch { } }')
        [void]$sb.AppendLine('$__sw.Stop()')
        [void]$sb.AppendLine('[System.IO.File]::WriteAllText(' + $outF + ', $__out)')
        [void]$sb.AppendLine('[System.IO.File]::WriteAllText(' + $errF + ', $__err)')
        [void]$sb.AppendLine('$results += [pscustomobject]@{ idx = ' + $i + '; exit = $__exit; timed_out = $__timed; ms = [int]$__sw.ElapsedMilliseconds }')
    }
    $sumF = ConvertTo-PsSingleQuoted (Join-Path $workDir 'elev-summary.json')
    [void]$sb.AppendLine('ConvertTo-Json -InputObject @($results) -Compress | Set-Content -LiteralPath ' + $sumF + ' -Encoding ASCII')
    $innerPath = Join-Path $workDir 'elev-inner.ps1'
    [System.IO.File]::WriteAllText($innerPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return $innerPath
}

# 提权执行全部步骤（RunAs 一次）；UAC 被点否=优雅失败；总时限=各步超时和+120 秒确认宽限
function Invoke-StepsElevated {
    param($StepList, [int]$PerStepTimeoutMs)
    $perStep = [int]$PerStepTimeoutMs
    $total = $perStep * @($StepList).Count + 120000
    $inner = New-ElevatedInner -StepList $StepList -PerStepTimeoutMs $perStep
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $inner) -Verb RunAs -PassThru -WindowStyle Hidden
    } catch {
        return @{ ok = $false; declined = $true; steps = @(); note = '管理员确认框被取消了（点了「否」或没有权限）——什么都没有改动' }
    }
    $timed = -not $p.WaitForExit($total)
    $summary = @()
    $sumPath = Join-Path $workDir 'elev-summary.json'
    if (Test-Path -LiteralPath $sumPath) {
        # 5.1 的 ConvertFrom-Json 对顶层数组会多包一层 Object[]（-InputObject 与管道喂皆然，
        # 管道版更狠：Where [0] 拿到内层数组，.exit 靠成员枚举侥幸对、属性探测全落空）——一次性解包双保险
        try {
            $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $sumPath -Raw -Encoding ASCII)
            $summary = @($parsed)
            if ($summary.Count -gt 0 -and $summary[0] -is [object[]]) { $summary = @($summary[0]) }
        } catch { $summary = @() }
    }
    if ($summary.Count -eq 0) {
        if ($timed) { return @{ ok = $false; declined = $false; steps = @(); note = "提权执行超时（${total}ms 内没有交回结果）" } }
        return @{ ok = $false; declined = $false; steps = @(); note = '提权执行没有交回结果（异常退出）' }
    }
    $built = @()
    $i = 0
    foreach ($st in $StepList) {
        $i++
        $s = $null
        foreach ($cand in $summary) { if ([int]$cand.idx -eq $i) { $s = $cand; break } }
        $code = -1
        if ($s -and $null -ne $s.exit) { $code = [int]$s.exit }
        $outF = Join-Path $workDir ("step-$i-out.txt")
        $errF = Join-Path $workDir ("step-$i-err.txt")
        $out = (Read-TextSmart $outF).TrimEnd()
        $err = Read-TextSmart $errF
        if ($err) { $out = ($out + "`n" + $err).Trim() }
        $built += @{
            exit = $code
            ms = [int]$(if ($s -and $s.PSObject.Properties['ms']) { $s.ms } else { 0 })
            timed_out = [bool]$(if ($s) { $s.timed_out } else { $false })
            out = $out; err_head = (Get-HeadLines $err 2)
        }
    }
    if (@($built).Count -eq 0) { return @{ ok = $false; declined = $false; steps = @(); note = '提权结果组装异常（零步骤）' } }
    return @{ ok = $true; declined = $false; steps = $built; note = '' }
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
    if ([string]$action.level -ne 'green') { $loadErr = 'only green level actions are executable here (yellow/red never auto-run)' }
    elseif (-not @($action.steps).Count) { $loadErr = 'action has no steps' }
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

# ---------- ③ 执行 ----------
$execSteps = @()
$execOk = $false
$execNote = ''
if ($preOk) {
    if ($needElev -and -not $NeverElevate) {
        $r = Invoke-StepsElevated -StepList $action.steps -PerStepTimeoutMs $timeoutMs
        if (-not $r.ok) {
            $execNote = [string]$r.note
            if ($r.declined) { $elevDeclinedNote = [string]$r.note }
        } else {
            $i = 0
            foreach ($st in $action.steps) {
                $i++
                $sr = @($r.steps)[$i - 1]
                $stepExit = -1; $stepMs = 0; $stepTimed = $false; $stepOut = ''
                if ($sr) {
                    if ($null -ne $sr.exit) { $stepExit = [int]$sr.exit }
                    $stepMs = [int]$sr.ms; $stepTimed = [bool]$sr.timed_out; $stepOut = [string]$sr.out
                }
                $execSteps += @{
                    exe = [string]$st.exe; args = @(@($st.args) | ForEach-Object { [string]$_ }); desc = [string]$st.desc
                    exit = $stepExit; ms = $stepMs; timed_out = $stepTimed; out_head = (Get-HeadLines $stepOut 3)
                }
            }
            $execOk = -not (@($execSteps) | Where-Object { $_.exit -ne 0 -or $_.timed_out }).Count
            if (-not $execOk) { $execNote = '有步骤没跑成（详见各步结果）' }
        }
    } else {
        $i = 0
        foreach ($st in $action.steps) {
            $i++
            $sr = Invoke-StepDirect -Exe ([string]$st.exe) -ArgList @(@($st.args) | ForEach-Object { [string]$_ }) -TimeoutMs $timeoutMs
            $execSteps += @{
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
                $null = Invoke-StepDirect -Exe ([string]$rb.exe) -ArgList @(@($rb.args) | ForEach-Object { [string]$_ }) -TimeoutMs $timeoutMs
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
elseif (-not $execOk) { $verifyNote = '执行未成功，跳过验证' }
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
        steps = @(foreach ($es in $execSteps) { [ordered]@{ exe = $es.exe; args = $es.args; exit = $es.exit; ms = $es.ms; timed_out = $es.timed_out; out_head = $es.out_head } })
        verify = @(foreach ($v in $verifyChecks) { [ordered]@{ name = $v.name; status = $v.status } })
    }
    Add-Content -LiteralPath (Join-Path $reportsDir 'repair-log.json') -Value (Get-ResultJson $logLine) -Encoding UTF8
    $logOk = $true
} catch { $logErr = $_.Exception.Message }

# ---------- 汇总（ok = 预检过 + 全部步骤 exit=0 且未超时；验证结果如实另报，不并入 ok） ----------
$ok = $okOverall
$human = ''
if ($ok) {
    $vSum = ''
    if ($verifyChecks.Count) {
        $p = @($verifyChecks | Where-Object { $_.status -eq 'PASS' }).Count
        $vSum = "；复检 $($p)/$($verifyChecks.Count) 项正常"
    }
    $human = "「$actName」执行完成$vSum" + $(if ($verifyNote) { "（$verifyNote）" } else { '' })
} elseif ($failStage -eq 'precheck') {
    $human = "「$actName」没有执行：" + (@($preNotes) -join '；')
} elseif ($elevDeclinedNote) {
    $human = "「$actName」没有执行：$elevDeclinedNote"
} else {
    $human = "「$actName」没有成功：$execNote"
}

$result = [ordered]@{
    ok = $ok; id = $ActionId; name = $actName; level = $actLevel; fail_stage = $failStage
    human = $human
    stages = [ordered]@{
        precheck = [ordered]@{ ok = $preOk; notes = @($preNotes); admin = $isElev; elevated_run = $(if ($needElev -and -not $NeverElevate) { $true } else { $false }) }
        exec     = [ordered]@{ ok = $execOk; note = $execNote; steps = @(foreach ($es in $execSteps) { [ordered]@{ exe = $es.exe; args = $es.args; desc = $es.desc; exit = $es.exit; ms = $es.ms; timed_out = $es.timed_out; out_head = $es.out_head } }) }
        verify   = [ordered]@{ note = $verifyNote; checks = @(foreach ($v in $verifyChecks) { [ordered]@{ name = $v.name; status = $v.status; evidence_head = $v.evidence } }) }
        log      = [ordered]@{ ok = $logOk; file = (Join-Path $reportsDir 'repair-log.json'); err = $logErr }
    }
}
$json = Get-ResultJson $result
Write-Output $json
if ($OutFile -ne '') { Set-Content -LiteralPath $OutFile -Value $json -Encoding UTF8 }
Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
exit $(if ($ok) { 0 } else { 1 })
