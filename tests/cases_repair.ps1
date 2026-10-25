#Requires -Version 5.1
<#
diag 修复域用例（v0.9 第十三切片；四断言=命令序列/回滚序列/超时负例/权限负例；绿黄双级）
结构：
  - rep_schema            ：动作库静态契约（绿+黄级/id 唯一/匹配与验证检查项真实存在/超时范围/命令白名单/
                            黄级回滚包契约 backup_steps+undo_script 均含 {BK}/撤销 import 数≥备份 export 数）
  - rep_cmdseq            ：fixture 双步依序写标记文件 → 命令序列断言
  - rep_rollback          ：fixture 第二步 exit 7 → 回滚序列按序跑 → 回滚断言
  - rep_timeout           ：fixture ping 30 发+动作超时 2 秒 → 超时负例断言
  - rep_perm              ：fixture net session（非提权=拒绝访问/提权=成功，按上下文断言）→ 权限负例断言
  - rep_adminblock        ：fixture requires_admin+NeverElevate → 预检挡下零副作用 → 权限负例第二面
  - rep_flush_dns / rep_arp_flush / rep_registerdns ：三个真实绿级动作全链实测
                            （可静默提权的机器=全五段跑通；不可静默提权的机器=NeverElevate 预检挡下，双语境确定性）
  v0.9 黄级（回滚包+还原点；真黄级动作绝不真跑，单测只走预检挡下，真跑留给真机演练）：
  - rep_y_cmdseq          ：黄级提权内层=备份步→主步依序写标记+撤销脚本落盘且 {BK} 已替换 → 命令序列断言
  - rep_y_rollback        ：黄级主步失败 → 提权内层自动回滚按序跑 → 回滚序列断言
  - rep_y_timeout         ：黄级主步 ping 30 发超时 2 秒掐停+自动回滚 → 超时负例断言
  - rep_y_perm            ：黄级直跑路径 net session（非提权=失败+自动回滚/提权=成功）→ 权限负例断言
  - rep_y_rpfail          ：黄级+还原点请求（非提权=还原点建不成中止零副作用/提权=建点后照跑）→ 还原点负例断言
  - rep_y_winsock / rep_y_tcpip / rep_y_tcp ：三个真实黄级动作 NeverElevate 挡下（预检挡下零副作用+回滚包不生成）
v0.9.8 扩库 5 动作（库 8→13，全部 common=true=常用修复）：
  - rep_r_time_sync / rep_y_prn_queue / rep_y_upd_cache / rep_y_pwr_reset
                            ：4 条真动作 forceNever 挡下（预检挡下零副作用，真跑留给真机演练）
  - rep_g_icon_refresh      ：ui_icon_refresh 真跑断言——requires_admin=false，NeverElevate 拦不住
                            （repair.ps1 只拦需提权动作），动作零破坏性（只刷图标显示缓存）
  - rep_schema 升级         ：数线 13+白名单 +5 exe（w32tm/ie4uinit/net/powercfg/cmd）+cmd.exe 步 /c 前缀
                            +「match_checks 为空须 common=true」+备份段至少一步把产物写进 {BK}（停服务等
                            解锁步天然无 {BK}，原每步须含 {BK} 断言对扩库动作不可达，放宽为汇总断言）
黄级 fixture 走 requires_admin=true 的提权内层路径（requireSilent：不可静默提权的机器自动转 NeverElevate，双语境确定性）。
真实动作跑在临时仓副本（checks/ 拷贝、reports/ 独立），主仓 reports/ 零污染。
#>

function Test-CurElevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 可静默提权 = 管理员组用户 + UAC 对管理员不弹窗（ConsentPromptBehaviorAdmin=0）；
# 不满足则真实动作用例走 -NeverElevate（预检挡下），绝不弹 UAC 卡死自动化
function Test-SilentElevatable {
    try {
        $c = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop).ConsentPromptBehaviorAdmin
    } catch { return $false }
    if ($null -eq $c -or [int]$c -ne 0) { return $false }
    $g = ''
    try { $g = & "$env:SystemRoot\System32\whoami.exe" /groups 2>&1 | Out-String } catch { return $false }
    return ($g -match 'S-1-5-32-544')
}

# 读临时仓修复台账末行（首行带 BOM 用 utf-8 容错读）
function Get-LastRepairLog([string]$TmpRoot) {
    $f = Join-Path $TmpRoot 'reports\repair-log.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $lines = @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) { return $null }
    try { return ($lines[-1] | ConvertFrom-Json) } catch { return $null }
}

$fixtureCmdseq = @'
{
  "id": "zz_test_cmdseq",
  "name": "zz command order test",
  "level": "green",
  "desc": "t", "affect": "t", "undo": "t",
  "requires_admin": false, "prechecks": [],
  "steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo one>\"%TEMP%\\diag-rep-cmdseq.txt\""], "desc": "write one" },
    { "exe": "cmd.exe", "args": ["/c", "echo two>>\"%TEMP%\\diag-rep-cmdseq.txt\""], "desc": "append two" }
  ],
  "rollback": [],
  "rollback_note": "none",
  "timeout_sec": 10,
  "match_checks": [], "verify_checks": []
}
'@

$fixtureRollback = @'
{
  "id": "zz_test_rollback",
  "name": "zz rollback order test",
  "level": "green",
  "desc": "t", "affect": "t", "undo": "t",
  "requires_admin": false, "prechecks": [],
  "steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo ran>\"%TEMP%\\diag-rep-rb.txt\""], "desc": "ok step" },
    { "exe": "cmd.exe", "args": ["/c", "exit", "7"], "desc": "fail step" }
  ],
  "rollback": [
    { "exe": "cmd.exe", "args": ["/c", "echo rb1>>\"%TEMP%\\diag-rep-rb.txt\""], "desc": "rollback 1" },
    { "exe": "cmd.exe", "args": ["/c", "echo rb2>>\"%TEMP%\\diag-rep-rb.txt\""], "desc": "rollback 2" }
  ],
  "rollback_note": "test rollback",
  "timeout_sec": 10,
  "match_checks": [], "verify_checks": []
}
'@

$fixtureTimeout = @'
{
  "id": "zz_test_timeout",
  "name": "zz timeout test",
  "level": "green",
  "desc": "t", "affect": "t", "undo": "t",
  "requires_admin": false, "prechecks": [],
  "steps": [
    { "exe": "ping.exe", "args": ["-n", "30", "127.0.0.1"], "desc": "long ping" }
  ],
  "rollback": [],
  "rollback_note": "none",
  "timeout_sec": 2,
  "match_checks": [], "verify_checks": []
}
'@

$fixturePerm = @'
{
  "id": "zz_test_perm",
  "name": "zz permission test",
  "level": "green",
  "desc": "t", "affect": "t", "undo": "t",
  "requires_admin": false, "prechecks": [],
  "steps": [
    { "exe": "net.exe", "args": ["session"], "desc": "net session" }
  ],
  "rollback": [],
  "rollback_note": "none",
  "timeout_sec": 15,
  "match_checks": [], "verify_checks": []
}
'@

$fixtureAdminBlock = @'
{
  "id": "zz_test_adminblock",
  "name": "zz admin block test",
  "level": "green",
  "desc": "t", "affect": "t", "undo": "t",
  "requires_admin": true, "prechecks": [],
  "steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo ran>\"%TEMP%\\diag-rep-ab.txt\""], "desc": "should never run" }
  ],
  "rollback": [],
  "rollback_note": "none",
  "timeout_sec": 10,
  "match_checks": [], "verify_checks": []
}
'@

# ---- v0.9 黄级 fixture（requireSilent：提权内层路径；不可静默提权的机器自动转 NeverElevate 挡下） ----
$fixtureYCmdseq = @'
{
  "id": "zz_test_y_cmdseq",
  "name": "zz yellow cmd order test",
  "level": "yellow",
  "desc": "t", "affect": "t", "undo": "t",
  "requires_admin": true, "restore_point": true, "prechecks": [],
  "backup_steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo bak>\"{BK}\\marker-y.txt\""], "desc": "backup marker" }
  ],
  "undo_script": [
    "echo undo placeholder {BK}"
  ],
  "steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo main>>\"%TEMP%\\diag-rep-y.txt\""], "desc": "main marker" }
  ],
  "rollback": [],
  "rollback_note": "none",
  "timeout_sec": 10,
  "match_checks": [], "verify_checks": []
}
'@

$fixtureYRollback = @'
{
  "id": "zz_test_y_rollback",
  "name": "zz yellow rollback test",
  "level": "yellow",
  "desc": "t", "affect": "t", "undo": "t",
  "requires_admin": true, "prechecks": [],
  "backup_steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo bak>\"%TEMP%\\diag-rep-yb.txt\""], "desc": "backup marker" }
  ],
  "undo_script": [ "echo undo {BK}" ],
  "steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo main>>\"%TEMP%\\diag-rep-yb.txt\""], "desc": "ok main" },
    { "exe": "cmd.exe", "args": ["/c", "exit", "7"], "desc": "fail main" }
  ],
  "rollback": [
    { "exe": "cmd.exe", "args": ["/c", "echo rb1>>\"%TEMP%\\diag-rep-yb.txt\""], "desc": "auto rollback 1" },
    { "exe": "cmd.exe", "args": ["/c", "echo rb2>>\"%TEMP%\\diag-rep-yb.txt\""], "desc": "auto rollback 2" }
  ],
  "rollback_note": "test",
  "timeout_sec": 10,
  "match_checks": [], "verify_checks": []
}
'@

$fixtureYTimeout = @'
{
  "id": "zz_test_y_timeout",
  "name": "zz yellow timeout test",
  "level": "yellow",
  "desc": "t", "affect": "t", "undo": "t",
  "requires_admin": true, "prechecks": [],
  "backup_steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo bak>\"%TEMP%\\diag-rep-yt.txt\""], "desc": "backup marker" }
  ],
  "undo_script": [ "echo undo {BK}" ],
  "steps": [
    { "exe": "ping.exe", "args": ["-n", "30", "127.0.0.1"], "desc": "long ping" }
  ],
  "rollback": [
    { "exe": "cmd.exe", "args": ["/c", "echo rb>>\"%TEMP%\\diag-rep-yt.txt\""], "desc": "auto rollback" }
  ],
  "rollback_note": "test",
  "timeout_sec": 2,
  "match_checks": [], "verify_checks": []
}
'@

$fixtureYPerm = @'
{
  "id": "zz_test_y_perm",
  "name": "zz yellow permission test",
  "level": "yellow",
  "desc": "t", "affect": "t", "undo": "t",
  "requires_admin": false, "prechecks": [],
  "backup_steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo bak>\"%TEMP%\\diag-rep-yp.txt\""], "desc": "backup marker" }
  ],
  "undo_script": [ "echo undo {BK}" ],
  "steps": [
    { "exe": "net.exe", "args": ["session"], "desc": "net session" }
  ],
  "rollback": [
    { "exe": "cmd.exe", "args": ["/c", "echo rb>>\"%TEMP%\\diag-rep-yp.txt\""], "desc": "auto rollback" }
  ],
  "rollback_note": "test",
  "timeout_sec": 15,
  "match_checks": [], "verify_checks": []
}
'@

$fixtureYRpFail = @'
{
  "id": "zz_test_y_rpfail",
  "name": "zz yellow restore point fail test",
  "level": "yellow",
  "desc": "t", "affect": "t", "undo": "t",
  "requires_admin": false, "prechecks": [],
  "backup_steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo bak>\"%TEMP%\\diag-rep-yrp.txt\""], "desc": "backup marker" }
  ],
  "undo_script": [ "echo undo {BK}" ],
  "steps": [
    { "exe": "cmd.exe", "args": ["/c", "echo main>\"%TEMP%\\diag-rep-yrp.txt\""], "desc": "main marker" }
  ],
  "rollback": [],
  "rollback_note": "none",
  "timeout_sec": 10,
  "match_checks": [], "verify_checks": []
}
'@

$global:DiagRepairCases = @(

    # ---- 动作库静态契约（真仓真文件，不跑临时仓） ----
    @{
        name = 'rep_schema'
        kind = 'schema'
        assert = {
            param($res, $ctx)
            $bad = @()
            $root = $ctx.Root
            $actionsDir = Join-Path $root 'repair\actions'
            $checksNames = @(Get-ChildItem -LiteralPath (Join-Path $root 'checks') -File -Filter '*.ps1' | ForEach-Object { $_.BaseName })
            $jsons = @(Get-ChildItem -LiteralPath $actionsDir -File -Filter '*.json')
            if ($jsons.Count -lt 13) { $bad += "actions count $($jsons.Count) < 13 (green 5 + yellow 6 + red 2 ruled)" }
            $seenIds = @{}
            $exeAllow = @('ipconfig.exe', 'arp.exe', 'nbtstat.exe', 'netsh.exe', 'reg.exe', 'w32tm.exe', 'ie4uinit.exe', 'net.exe', 'powercfg.exe', 'cmd.exe', 'driverquery.exe', 'pnputil.exe')
            $exeAllowRed = @('sfc.exe', 'dism.exe', 'notepad.exe', 'ipconfig.exe', 'pnputil.exe', 'cmd.exe', 'driverquery.exe', 'powercfg.exe')
            foreach ($jf in $jsons) {
                $a = $null
                try { $a = Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $bad += "unparsable: $($jf.Name)"; continue }
                if ([string]$a.id -ne $jf.BaseName) { $bad += "id/file mismatch: $($jf.Name)" }
                $lvl = [string]$a.level
                if (@('green', 'yellow', 'red') -notcontains $lvl) { $bad += "level not green/yellow/red: $($jf.Name)" }
                if ($seenIds[[string]$a.id]) { $bad += "duplicate id: $($a.id)" }
                $seenIds[[string]$a.id] = $true
                foreach ($mc in @($a.match_checks)) { if ($checksNames -notcontains [string]$mc) { $bad += "match_check not a real check: $mc" } }
                foreach ($vc in @($a.verify_checks)) { if ($checksNames -notcontains [string]$vc) { $bad += "verify_check not a real check: $vc" } }
                # v0.9.8：match_checks 为空的动作必须标 common=true（防「永不出现」的死动作）
                if (-not @($a.match_checks).Count -and $a.common -ne $true) { $bad += "match_checks empty requires common=true: $($jf.Name)" }
                if (@($a.steps).Count -lt 1) { $bad += "no steps: $($jf.Name)" }
                $lvlAllow = $exeAllow; if ($lvl -eq 'red') { $lvlAllow = $exeAllowRed }
                foreach ($st in @($a.steps)) {
                    if ($lvlAllow -notcontains [string]$st.exe) { $bad += "exe not in allowlist: $($st.exe)" }
                    if (-not @($st.args).Count) { $bad += "step without args: $($jf.Name)" }
                    if ([string]$st.exe -eq 'cmd.exe' -and [string]@($st.args)[0] -ne '/c') { $bad += "cmd.exe step must start with /c: $($jf.Name)" }
                }
                $ts = [int]$a.timeout_sec
                if ($ts -lt 5 -or $ts -gt 120) { $bad += "timeout_sec out of 5..120: $($jf.Name)" }
                if ($null -eq $a.rollback) { $bad += "rollback field missing: $($jf.Name)" }
                foreach ($st in @($a.rollback)) {
                    if ([string]$st.exe -eq 'cmd.exe' -and [string]@($st.args)[0] -ne '/c') { $bad += "cmd.exe rollback step must start with /c: $($jf.Name)" }
                }
                foreach ($pc in @($a.prechecks)) { if (@('no_static_arp') -notcontains [string]$pc) { $bad += "unknown precheck '$pc': $($jf.Name)" } }
                foreach ($k in @('name', 'desc', 'affect', 'undo', 'rollback_note')) { if (-not [string]$a.$k) { $bad += "field '$k' empty: $($jf.Name)" } }
                if ($lvl -eq 'red') {
                    # 红级=guide-only 永不执行：不许带任何回滚包字段（无执行即无回滚），exe 走红级展示白名单
                    if ($a.PSObject.Properties['backup_steps']) { $bad += "red with backup_steps: $($jf.Name)" }
                    if ($a.PSObject.Properties['undo_script']) { $bad += "red with undo_script: $($jf.Name)" }
                }
                if ($lvl -eq 'yellow') {
                    # 回滚包契约：备份步+撤销脚本都要有，{BK} 占位符必须在场（撤销=把备份导回去）
                    if (-not @($a.backup_steps).Count) { $bad += "yellow without backup_steps: $($jf.Name)" }
                    else {
                        $nExport = 0
                        $nBkStep = 0
                        foreach ($bst in @($a.backup_steps)) {
                            if ($exeAllow -notcontains [string]$bst.exe) { $bad += "backup exe not in allowlist: $($bst.exe)" }
                            if ((@($bst.args) -join ' ') -match '\{BK\}') { $nBkStep++ }
                            if ([string]$bst.exe -eq 'cmd.exe' -and [string]@($bst.args)[0] -ne '/c') { $bad += "cmd.exe backup step must start with /c: $($jf.Name)" }
                            if ([string]$bst.exe -eq 'reg.exe') { $nExport++ }
                        }
                        # v0.9.8 放宽：停服务等「解锁步」天然不写 {BK}，只要求备份段至少一步把产物写进回滚包
                        if (-not $nBkStep) { $bad += "backup_steps none writes into {BK} package: $($jf.Name)" }
                        $nImport = 0
                        if (-not @($a.undo_script).Count) { $bad += "yellow without undo_script: $($jf.Name)" }
                        else {
                            $hasBk = $false
                            foreach ($ul in @($a.undo_script)) {
                                if ([string]$ul -match '\{BK\}') { $hasBk = $true }
                                if ([string]$ul -match 'reg\s+import') { $nImport++ }
                            }
                            if (-not $hasBk) { $bad += "undo_script missing {BK}: $($jf.Name)" }
                            if ($nExport -gt 0 -and $nImport -lt $nExport) { $bad += "undo imports($nImport) < backup exports($nExport): $($jf.Name)" }
                        }
                    }
                }
            }
            return $bad
        }
    }

    # ---- 命令序列：两步依序写标记 ----
    @{
        name = 'rep_cmdseq'
        kind = 'fixture'
        actionId = 'zz_test_cmdseq'
        fixtures = @{ 'zz_test_cmdseq.json' = $fixtureCmdseq }
        clean = @('diag-rep-cmdseq.txt')
        assert = {
            param($res, $ctx)
            $bad = @()
            if ($res.ok -ne $true) { $bad += "expect ok=true got $($res.ok) (human=$($res.human))"; return $bad }
            $steps = @($res.stages.exec.steps)
            if ($steps.Count -ne 2) { $bad += "expect 2 steps got $($steps.Count)" }
            else {
                if ([int]$steps[0].exit -ne 0 -or [int]$steps[1].exit -ne 0) { $bad += "step exits: $($steps[0].exit)/$($steps[1].exit)" }
            }
            $mk = Join-Path $env:TEMP 'diag-rep-cmdseq.txt'
            if (-not (Test-Path -LiteralPath $mk)) { $bad += 'marker file missing' }
            else {
                $lines = @(Get-Content -LiteralPath $mk | Where-Object { $_.Trim() -ne '' })
                if ($lines.Count -lt 2 -or $lines[0].Trim() -ne 'one' -or $lines[1].Trim() -ne 'two') { $bad += "marker order wrong: $($lines -join '|')" }
            }
            $log = Get-LastRepairLog $ctx.TmpRoot
            if (-not $log -or $log.id -ne 'zz_test_cmdseq' -or $log.ok -ne $true) { $bad += 'repair-log line missing/wrong' }
            return $bad
        }
    }

    # ---- 回滚序列：第二步失败后回滚按序跑 ----
    @{
        name = 'rep_rollback'
        kind = 'fixture'
        actionId = 'zz_test_rollback'
        fixtures = @{ 'zz_test_rollback.json' = $fixtureRollback }
        clean = @('diag-rep-rb.txt')
        assert = {
            param($res, $ctx)
            $bad = @()
            if ($res.ok -ne $false) { $bad += "expect ok=false got $($res.ok)"; return $bad }
            if ([string]$res.fail_stage -ne 'exec') { $bad += "expect fail_stage=exec got $($res.fail_stage)" }
            $steps = @($res.stages.exec.steps)
            if ($steps.Count -ne 4) { $bad += "expect 4 steps (2 main + 2 rollback) got $($steps.Count)" }
            else {
                if ([string]$steps[0].phase -ne 'main' -or [string]$steps[1].phase -ne 'main') { $bad += "expect main phases got $($steps[0].phase)/$($steps[1].phase)" }
                if ([string]$steps[2].phase -ne 'rollback' -or [string]$steps[3].phase -ne 'rollback') { $bad += "expect rollback phases got $($steps[2].phase)/$($steps[3].phase)" }
                if ([int]$steps[1].exit -ne 7) { $bad += "expect fail step exit=7 got $($steps[1].exit)" }
                if ($steps[2].desc -notmatch '^\[自动回滚\]') { $bad += "rollback desc prefix missing: $($steps[2].desc)" }
            }
            $mk = Join-Path $env:TEMP 'diag-rep-rb.txt'
            if (-not (Test-Path -LiteralPath $mk)) { $bad += 'marker missing' }
            else {
                $lines = @(Get-Content -LiteralPath $mk | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
                if ($lines -notcontains 'ran') { $bad += 'first step marker missing' }
                $i1 = [array]::IndexOf($lines, 'ran'); $i2 = [array]::IndexOf($lines, 'rb1'); $i3 = [array]::IndexOf($lines, 'rb2')
                if ($i1 -lt 0 -or $i2 -lt 0 -or $i3 -lt 0 -or -not ($i1 -lt $i2 -and $i2 -lt $i3)) { $bad += "rollback order wrong: $($lines -join '|')" }
            }
            $log = Get-LastRepairLog $ctx.TmpRoot
            if (-not $log -or $log.ok -ne $false) { $bad += 'repair-log should record failure' }
            return $bad
        }
    }

    # ---- 超时负例：2 秒超时掐停 30 发 ping ----
    @{
        name = 'rep_timeout'
        kind = 'fixture'
        actionId = 'zz_test_timeout'
        fixtures = @{ 'zz_test_timeout.json' = $fixtureTimeout }
        assert = {
            param($res, $ctx)
            $bad = @()
            if ($res.ok -ne $false) { $bad += "expect ok=false got $($res.ok)"; return $bad }
            $steps = @($res.stages.exec.steps)
            if ($steps.Count -ne 1) { $bad += "expect 1 step got $($steps.Count)" }
            elseif ($steps[0].timed_out -ne $true) { $bad += "expect timed_out=true" }
            if ([int]$steps[0].ms -gt 15000) { $bad += "timeout took $($steps[0].ms)ms (>15s)" }
            if ([string]$res.fail_stage -ne 'exec') { $bad += "fail_stage=$($res.fail_stage)" }
            return $bad
        }
    }

    # ---- 权限负例之一：失败命令优雅收场（非提权=拒绝访问；提权上下文=成功，双语境各自断言） ----
    @{
        name = 'rep_perm'
        kind = 'fixture'
        actionId = 'zz_test_perm'
        fixtures = @{ 'zz_test_perm.json' = $fixturePerm }
        assert = {
            param($res, $ctx)
            $bad = @()
            if (Test-CurElevated) {
                if ($res.ok -ne $true) { $bad += "elevated ctx: expect ok=true got $($res.ok) (human=$($res.human))" }
            } else {
                if ($res.ok -ne $false) { $bad += "non-elevated ctx: expect ok=false got $($res.ok)（net session 本该被拒绝）" }
                else {
                    if ([string]$res.fail_stage -ne 'exec') { $bad += "fail_stage=$($res.fail_stage)" }
                    $steps = @($res.stages.exec.steps)
                    if ($steps.Count -ne 1 -or [int]$steps[0].exit -eq 0) { $bad += "expect nonzero exit captured" }
                }
            }
            return $bad
        }
    }

    # ---- 权限负例之二：需要提权+测试模式不弹窗 → 预检挡下零副作用 ----
    @{
        name = 'rep_adminblock'
        kind = 'fixture'
        actionId = 'zz_test_adminblock'
        fixtures = @{ 'zz_test_adminblock.json' = $fixtureAdminBlock }
        clean = @('diag-rep-ab.txt')
        neverElevate = $true
        assert = {
            param($res, $ctx)
            $bad = @()
            if (Test-CurElevated) {
                # 提权上下文里 requires_admin 不构成阻断（本就提权）——ok=true 合法
                if ($res.ok -ne $true) { $bad += "elevated ctx: expect ok=true got $($res.ok)" }
                return $bad
            }
            if ($res.ok -ne $false) { $bad += "expect ok=false got $($res.ok)"; return $bad }
            if ([string]$res.fail_stage -ne 'precheck') { $bad += "expect fail_stage=precheck got $($res.fail_stage)" }
            $notes = (@($res.stages.precheck.notes) -join '；')
            if ($notes -notmatch '管理员') { $bad += "precheck note should mention admin: $notes" }
            $mk = Join-Path $env:TEMP 'diag-rep-ab.txt'
            if (Test-Path -LiteralPath $mk) { $bad += 'marker exists: step ran despite precheck block' }
            return $bad
        }
    }

    # ---- 真实动作全链实测 ×3（可静默提权=全五段；否则 NeverElevate 预检挡下） ----
    @{
        name = 'rep_flush_dns'
        kind = 'real'
        actionId = 'net_flush_dns'
        assert = {
            param($res, $ctx)
            $bad = @()
            $log = Get-LastRepairLog $ctx.TmpRoot
            if ($ctx.SilentElev) {
                if ($res.ok -ne $true) { $bad += "expect ok=true got $($res.ok) (human=$($res.human))" }
                $steps = @($res.stages.exec.steps)
                if ($steps.Count -ne 1 -or [int]$steps[0].exit -ne 0) { $bad += 'flushdns step not clean' }
                $vcs = @($res.stages.verify.checks)
                if ($vcs.Count -lt 1) { $bad += 'verify checks empty' }
                foreach ($v in $vcs) { if (@('PASS', 'FAIL', 'SKIP') -notcontains [string]$v.status) { $bad += "bad verify status: $($v.status)" } }
                if (-not $log -or $log.ok -ne $true) { $bad += 'repair-log line missing/wrong' }
            } else {
                if ($res.ok -ne $false -or [string]$res.fail_stage -ne 'precheck') { $bad += "no-silent-elev ctx: expect precheck block got $($res.ok)/$($res.fail_stage)" }
                if (-not $log -or $log.ok -ne $false) { $bad += 'repair-log should record blocked run' }
            }
            return $bad
        }
    }
    @{
        name = 'rep_arp_flush'
        kind = 'real'
        actionId = 'net_arp_flush'
        assert = {
            param($res, $ctx)
            $bad = @()
            $log = Get-LastRepairLog $ctx.TmpRoot
            if ($ctx.SilentElev) {
                $notes = (@($res.stages.precheck.notes) -join '；')
                if ($res.ok -eq $true) {
                    $steps = @($res.stages.exec.steps)
                    if ($steps.Count -ne 1 -or [int]$steps[0].exit -ne 0) { $bad += 'arp step not clean' }
                    $vcs = @($res.stages.verify.checks)
                    if ($vcs.Count -lt 1) { $bad += 'verify checks empty' }
                } elseif ([string]$res.fail_stage -eq 'precheck' -and $notes -match '静态') {
                    # 机器上真有手动静态 ARP 记录 → 预检挡下是设计行为，合法
                } else {
                    $bad += "unexpected fail: $($res.fail_stage) / $($res.human)"
                }
                if (-not $log) { $bad += 'repair-log line missing' }
            } else {
                if ($res.ok -ne $false -or [string]$res.fail_stage -ne 'precheck') { $bad += "no-silent-elev ctx: expect precheck block got $($res.ok)/$($res.fail_stage)" }
                if (-not $log -or $log.ok -ne $false) { $bad += 'repair-log should record blocked run' }
            }
            return $bad
        }
    }
    @{
        name = 'rep_registerdns'
        kind = 'real'
        actionId = 'net_dhcp_reregister'
        assert = {
            param($res, $ctx)
            $bad = @()
            $log = Get-LastRepairLog $ctx.TmpRoot
            if ($ctx.SilentElev) {
                if ($res.ok -ne $true) { $bad += "expect ok=true got $($res.ok) (human=$($res.human))" }
                $steps = @($res.stages.exec.steps)
                if ($steps.Count -ne 1 -or [int]$steps[0].exit -ne 0) { $bad += 'registerdns step not clean' }
                $vcs = @($res.stages.verify.checks)
                if ($vcs.Count -lt 1) { $bad += 'verify checks empty' }
                foreach ($v in $vcs) { if (@('PASS', 'FAIL', 'SKIP') -notcontains [string]$v.status) { $bad += "bad verify status: $($v.status)" } }
                if (-not $log -or $log.ok -ne $true) { $bad += 'repair-log line missing/wrong' }
            } else {
                if ($res.ok -ne $false -or [string]$res.fail_stage -ne 'precheck') { $bad += "no-silent-elev ctx: expect precheck block got $($res.ok)/$($res.fail_stage)" }
                if (-not $log -or $log.ok -ne $false) { $bad += 'repair-log should record blocked run' }
            }
            return $bad
        }
    }

    # ---- v0.9 黄级：命令序列（提权内层 备份→主步 依序+撤销脚本落盘且 {BK} 已替换） ----
    @{
        name = 'rep_y_cmdseq'
        kind = 'fixture'
        actionId = 'zz_test_y_cmdseq'
        fixtures = @{ 'zz_test_y_cmdseq.json' = $fixtureYCmdseq }
        clean = @('diag-rep-y.txt')
        requireSilent = $true
        extraArgs = @('-AllowYellow')
        assert = {
            param($res, $ctx)
            $bad = @()
            if (-not $ctx.SilentElev) {
                if ($res.ok -ne $false -or [string]$res.fail_stage -ne 'precheck') { $bad += "non-silent ctx: expect precheck block got $($res.ok)/$($res.fail_stage)" }
                return $bad
            }
            if ($res.ok -ne $true) { $bad += "expect ok=true got $($res.ok) (human=$($res.human))"; return $bad }
            $steps = @($res.stages.exec.steps)
            if ($steps.Count -ne 2) { $bad += "expect 2 steps (backup+main) got $($steps.Count)" }
            else {
                if ([string]$steps[0].phase -ne 'backup' -or [string]$steps[1].phase -ne 'main') { $bad += "phases: $($steps[0].phase)/$($steps[1].phase)" }
                if ([int]$steps[0].exit -ne 0 -or [int]$steps[1].exit -ne 0) { $bad += "step exits: $($steps[0].exit)/$($steps[1].exit)" }
            }
            $mk = Join-Path $env:TEMP 'diag-rep-y.txt'
            if (-not (Test-Path -LiteralPath $mk)) { $bad += 'marker file missing' }
            else {
                $lines = @(Get-Content -LiteralPath $mk | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
                if ($lines.Count -lt 1 -or $lines[0] -ne 'main') { $bad += "main marker wrong: $($lines -join '|')" }
            }
            # {BK} 替换闭环：备份标记文件必须落在真实备份目录里（备份步 args 占位符替换实测）
            $pkg = $res.stages.pkg
            $bkm = Join-Path ([string]$pkg.backup_dir) 'marker-y.txt'
            if (-not (Test-Path -LiteralPath $bkm)) { $bad += "backup marker not in backup dir: $bkm" }
            elseif ((Get-Content -LiteralPath $bkm | Where-Object { $_.Trim() -ne '' }) -notcontains 'bak') { $bad += 'backup marker content wrong' }
            # 撤销脚本：落盘+{BK} 已替换成真实备份目录+内容头正确
            if (-not $pkg -or -not $pkg.ok) { $bad += 'pkg stage missing/not ok' }
            else {
                $uf = [string]$pkg.undo_file
                if (-not (Test-Path -LiteralPath $uf)) { $bad += "undo script missing: $uf" }
                else {
                    $txt = Get-Content -LiteralPath $uf -Raw
                    if ($txt -notmatch 'rollback package: zz_test_y_cmdseq') { $bad += 'undo script header wrong' }
                    if ($txt -match '\{BK\}') { $bad += '{BK} placeholder not replaced' }
                    if (-not $txt.Contains([string]$pkg.backup_dir)) { $bad += 'undo script missing backup dir' }
                }
            }
            $log = Get-LastRepairLog $ctx.TmpRoot
            if (-not $log -or $log.id -ne 'zz_test_y_cmdseq' -or $log.ok -ne $true) { $bad += 'repair-log line missing/wrong' }
            return $bad
        }
    }

    # ---- v0.9 黄级：回滚序列（主步失败 → 提权内层自动回滚按序跑） ----
    @{
        name = 'rep_y_rollback'
        kind = 'fixture'
        actionId = 'zz_test_y_rollback'
        fixtures = @{ 'zz_test_y_rollback.json' = $fixtureYRollback }
        clean = @('diag-rep-yb.txt')
        requireSilent = $true
        extraArgs = @('-AllowYellow')
        assert = {
            param($res, $ctx)
            $bad = @()
            if (-not $ctx.SilentElev) {
                if ($res.ok -ne $false -or [string]$res.fail_stage -ne 'precheck') { $bad += "non-silent ctx: expect precheck block got $($res.ok)/$($res.fail_stage)" }
                return $bad
            }
            if ($res.ok -ne $false) { $bad += "expect ok=false got $($res.ok)"; return $bad }
            if ([string]$res.fail_stage -ne 'exec') { $bad += "expect fail_stage=exec got $($res.fail_stage)" }
            $steps = @($res.stages.exec.steps)
            if ($steps.Count -ne 5) { $bad += "expect 5 steps (1 backup+2 main+2 rollback) got $($steps.Count)" }
            else {
                $phases = ($steps | ForEach-Object { [string]$_.phase }) -join '/'
                if ($phases -ne 'backup/main/main/rollback/rollback') { $bad += "phases: $phases" }
                if ([int]$steps[2].exit -ne 7) { $bad += "expect fail main exit=7 got $($steps[2].exit)" }
            }
            $mk = Join-Path $env:TEMP 'diag-rep-yb.txt'
            if (-not (Test-Path -LiteralPath $mk)) { $bad += 'marker missing' }
            else {
                $lines = @(Get-Content -LiteralPath $mk | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
                $iB = [array]::IndexOf($lines, 'bak'); $iM = [array]::IndexOf($lines, 'main'); $i1 = [array]::IndexOf($lines, 'rb1'); $i2 = [array]::IndexOf($lines, 'rb2')
                if ($iB -lt 0 -or $iM -lt 0 -or $i1 -lt 0 -or $i2 -lt 0 -or -not ($iB -lt $iM -and $iM -lt $i1 -and $i1 -lt $i2)) { $bad += "order wrong: $($lines -join '|')" }
            }
            if (-not (Test-Path -LiteralPath ([string]$res.stages.pkg.undo_file))) { $bad += 'undo script missing' }
            $log = Get-LastRepairLog $ctx.TmpRoot
            if (-not $log -or $log.ok -ne $false) { $bad += 'repair-log should record failure' }
            return $bad
        }
    }

    # ---- v0.9 黄级：超时负例（主步 2 秒掐停+自动回滚） ----
    @{
        name = 'rep_y_timeout'
        kind = 'fixture'
        actionId = 'zz_test_y_timeout'
        fixtures = @{ 'zz_test_y_timeout.json' = $fixtureYTimeout }
        clean = @('diag-rep-yt.txt')
        requireSilent = $true
        extraArgs = @('-AllowYellow')
        assert = {
            param($res, $ctx)
            $bad = @()
            if (-not $ctx.SilentElev) {
                if ($res.ok -ne $false -or [string]$res.fail_stage -ne 'precheck') { $bad += "non-silent ctx: expect precheck block got $($res.ok)/$($res.fail_stage)" }
                return $bad
            }
            if ($res.ok -ne $false) { $bad += "expect ok=false got $($res.ok)"; return $bad }
            $steps = @($res.stages.exec.steps)
            if ($steps.Count -ne 3) { $bad += "expect 3 steps (backup+main+rollback) got $($steps.Count)" }
            else {
                $main = $steps[1]
                if ($main.timed_out -ne $true) { $bad += 'expect timed_out=true on main' }
                if ([int]$main.ms -gt 15000) { $bad += "timeout took $($main.ms)ms (>15s)" }
                if ([string]$steps[2].phase -ne 'rollback') { $bad += "expect rollback after timeout got $($steps[2].phase)" }
            }
            $mk = Join-Path $env:TEMP 'diag-rep-yt.txt'
            if (-not (Test-Path -LiteralPath $mk)) { $bad += 'rollback marker missing' }
            elseif ((Get-Content -LiteralPath $mk | Where-Object { $_.Trim() -ne '' }) -notcontains 'rb') { $bad += 'rollback marker content wrong' }
            if ([string]$res.fail_stage -ne 'exec') { $bad += "fail_stage=$($res.fail_stage)" }
            return $bad
        }
    }

    # ---- v0.9 黄级：权限负例（直跑路径；非提权=失败+自动回滚，提权=成功） ----
    @{
        name = 'rep_y_perm'
        kind = 'fixture'
        actionId = 'zz_test_y_perm'
        fixtures = @{ 'zz_test_y_perm.json' = $fixtureYPerm }
        clean = @('diag-rep-yp.txt')
        extraArgs = @('-AllowYellow')
        assert = {
            param($res, $ctx)
            $bad = @()
            $mk = Join-Path $env:TEMP 'diag-rep-yp.txt'
            if (Test-CurElevated) {
                if ($res.ok -ne $true) { $bad += "elevated ctx: expect ok=true got $($res.ok) (human=$($res.human))" }
                $lines = @()
                if (Test-Path -LiteralPath $mk) { $lines = @(Get-Content -LiteralPath $mk | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }) }
                if ($lines -contains 'rb') { $bad += 'rollback ran despite success' }
            } else {
                if ($res.ok -ne $false) { $bad += "non-elevated ctx: expect ok=false got $($res.ok)（net session 本该被拒绝）" }
                else {
                    if ([string]$res.fail_stage -ne 'exec') { $bad += "fail_stage=$($res.fail_stage)" }
                    $steps = @($res.stages.exec.steps)
                    if ($steps.Count -ne 3 -or [int]$steps[1].exit -eq 0) { $bad += "expect backup+fail+rollback got $($steps.Count)" }
                    $lines = @()
                    if (Test-Path -LiteralPath $mk) { $lines = @(Get-Content -LiteralPath $mk | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }) }
                    if (-not ($lines.Contains('bak') -and $lines.Contains('rb'))) { $bad += "markers wrong: $($lines -join '|')" }
                }
            }
            return $bad
        }
    }

    # ---- v0.9 黄级：还原点负例（还原点请求；非提权=建不成中止零副作用，提权=建点后照跑） ----
    @{
        name = 'rep_y_rpfail'
        kind = 'fixture'
        actionId = 'zz_test_y_rpfail'
        fixtures = @{ 'zz_test_y_rpfail.json' = $fixtureYRpFail }
        clean = @('diag-rep-yrp.txt')
        extraArgs = @('-AllowYellow', '-WithRestorePoint')
        assert = {
            param($res, $ctx)
            $bad = @()
            $mk = Join-Path $env:TEMP 'diag-rep-yrp.txt'
            if (Test-CurElevated) {
                # 提权上下文：还原点建成（或当日已有）→ 照常执行
                if ($res.ok -ne $true) { $bad += "elevated ctx: expect ok=true got $($res.ok) (human=$($res.human))" }
                return $bad
            }
            if ($res.ok -ne $false) { $bad += "non-elevated ctx: expect ok=false got $($res.ok)"; return $bad }
            if ([string]$res.fail_stage -ne 'rollback_pkg') { $bad += "expect fail_stage=rollback_pkg got $($res.fail_stage)" }
            $pkg = $res.stages.pkg
            if (-not $pkg -or -not $pkg.restore_point -or $pkg.restore_point.requested -ne $true) { $bad += 'restore_point.requested not recorded' }
            elseif ($pkg.restore_point.ok -ne $false) { $bad += 'restore_point should be failed in non-elevated ctx' }
            if (Test-Path -LiteralPath $mk) { $bad += 'marker exists: steps ran despite restore-point abort' }
            if (-not $pkg -or -not (Test-Path -LiteralPath ([string]$pkg.undo_file))) { $bad += 'undo script should exist (rollback package first)' }
            $log = Get-LastRepairLog $ctx.TmpRoot
            if (-not $log -or $log.ok -ne $false) { $bad += 'repair-log should record abort' }
            return $bad
        }
    }
)

# ---- v0.9 真实黄级动作 ×3：单测绝不真跑（forceNever=预检挡下零副作用）；真跑留给真机演练 ----
foreach ($yAct in @(@('rep_y_winsock', 'net_winsock_reset'), @('rep_y_tcpip', 'net_tcpip_reset'), @('rep_y_tcp', 'net_tcp_reset'))) {
    $global:DiagRepairCases += @{
        name = $yAct[0]
        kind = 'real'
        actionId = $yAct[1]
        forceNever = $true
        extraArgs = @('-AllowYellow')
        assert = {
            param($res, $ctx)
            $bad = @()
            if ($res.ok -ne $false) { $bad += "expect ok=false (never really run in tests) got $($res.ok)"; return $bad }
            if ([string]$res.fail_stage -ne 'precheck') { $bad += "expect fail_stage=precheck got $($res.fail_stage)" }
            $notes = (@($res.stages.precheck.notes) -join '；')
            if ($notes -notmatch '管理员') { $bad += "precheck note should mention admin: $notes" }
            if (@($res.stages.exec.steps).Count -ne 0) { $bad += 'steps ran despite NeverElevate' }
            if (Test-Path -LiteralPath (Join-Path $ctx.TmpRoot 'reports\rollback')) { $bad += 'rollback dir created despite precheck block' }
            $log = Get-LastRepairLog $ctx.TmpRoot
            if (-not $log -or $log.ok -ne $false) { $bad += 'repair-log should record blocked run' }
            return $bad
        }
    }
}

# ---- v0.9.8 扩库 5 动作：4 条 forceNever（预检挡下零副作用，真跑只在真机演练）----
#      sys_time_sync 真跑会动系统时钟，黄 3 条绝不真跑——同 rep_y_winsock 断言模板
foreach ($xAct in @(
        @('rep_r_time_sync', 'sys_time_sync', $false),
        @('rep_y_prn_queue', 'prn_queue_clean', $true),
        @('rep_y_upd_cache', 'upd_cache_clean', $true),
        @('rep_y_pwr_reset', 'pwr_plan_reset', $true))) {
    $global:DiagRepairCases += @{
        name = $xAct[0]
        kind = 'real'
        actionId = $xAct[1]
        forceNever = $true
        extraArgs = $(if ($xAct[2]) { @('-AllowYellow') } else { @() })
        assert = {
            param($res, $ctx)
            $bad = @()
            if ($res.ok -ne $false) { $bad += "expect ok=false (never really run in tests) got $($res.ok)"; return $bad }
            if ([string]$res.fail_stage -ne 'precheck') { $bad += "expect fail_stage=precheck got $($res.fail_stage)" }
            $notes = (@($res.stages.precheck.notes) -join '；')
            if ($notes -notmatch '管理员') { $bad += "precheck note should mention admin: $notes" }
            if (@($res.stages.exec.steps).Count -ne 0) { $bad += 'steps ran despite NeverElevate' }
            if (Test-Path -LiteralPath (Join-Path $ctx.TmpRoot 'reports\rollback')) { $bad += 'rollback dir created despite precheck block' }
            $log = Get-LastRepairLog $ctx.TmpRoot
            if (-not $log -or $log.ok -ne $false) { $bad += 'repair-log should record blocked run' }
            return $bad
        }
    }
}

# ---- v0.9.8 ui_icon_refresh：真跑断言（施工单「一律 forceNever」对本动作不可达：
#      requires_admin=false，NeverElevate 只拦需提权动作；动作本身零破坏性=只刷图标显示缓存） ----
$global:DiagRepairCases += @{
    name = 'rep_g_icon_refresh'
    kind = 'real'
    actionId = 'ui_icon_refresh'
    assert = {
        param($res, $ctx)
        $bad = @()
        if ($res.ok -ne $true) { $bad += "expect ok=true got $($res.ok) (human=$($res.human) fail=$($res.fail_stage))"; return $bad }
        $steps = @($res.stages.exec.steps)
        if ($steps.Count -ne 1 -or [int]$steps[0].exit -ne 0) { $bad += 'icon refresh step not clean' }
        $log = Get-LastRepairLog $ctx.TmpRoot
        if (-not $log -or $log.ok -ne $true) { $bad += 'repair-log line missing/wrong' }
        return $bad
    }
}

# ---- v1.2.0 片4 扩容 3 动作（1023 拍板优先级修订版）----
#      net_winhttp_reset（绿，改系统级 WinHTTP 代理=真跑会动本机代理状态）→ forceNever 挡下
foreach ($s4Act in @(@('rep_g_winhttp_reset', 'net_winhttp_reset', @()),
                     @('rep_y_rescan', 'dv_device_rescan', @('-AllowYellow')))) {
    $global:DiagRepairCases += @{
        name = $s4Act[0]
        kind = 'real'
        actionId = $s4Act[1]
        forceNever = $true
        extraArgs = $s4Act[2]
        assert = {
            param($res, $ctx)
            $bad = @()
            if ($res.ok -ne $false) { $bad += "expect ok=false (never really run in tests) got $($res.ok)"; return $bad }
            if ([string]$res.fail_stage -ne 'precheck') { $bad += "expect fail_stage=precheck got $($res.fail_stage)" }
            $notes = (@($res.stages.precheck.notes) -join '；')
            if ($notes -notmatch '管理员') { $bad += "precheck note should mention admin: $notes" }
            if (@($res.stages.exec.steps).Count -ne 0) { $bad += 'steps ran despite NeverElevate' }
            $log = Get-LastRepairLog $ctx.TmpRoot
            if (-not $log -or $log.ok -ne $false) { $bad += 'repair-log should record blocked run' }
            return $bad
        }
    }
}

# ---- net_wininet_proxy_off 黄级闸门：不带 -AllowYellow 必须在加载段拒掉（零副作用级验证，不碰本机 HKCU 代理） ----
$global:DiagRepairCases += @{
    name = 'rep_y_wininet_gate'
    kind = 'real'
    actionId = 'net_wininet_proxy_off'
    assert = {
        param($res, $ctx)
        $bad = @()
        if ($res.ok -ne $false) { $bad += "expect ok=false got $($res.ok)"; return $bad }
        if ([string]$res.fail_stage -ne 'load') { $bad += "expect fail_stage=load got $($res.fail_stage)" }
        if ($res.error -notmatch 'AllowYellow') { $bad += "load error should mention AllowYellow: $($res.error)" }
        return $bad
    }
}

# ---- v1.2.0 片4 修复中心闭环率断言（1023 拍板：每个可 FAIL 的检查项必须有下文，禁静默断链） ----
#      三种合法下文：action=绿/黄动作匹配 / card=红级处置卡匹配 / advice=显式「建议即处置」声明（reason 必填）
$global:DiagRepairCases += @{
    name = 'rep_closure'
    kind = 'schema'
    assert = {
        param($res, $ctx)
        $bad = @()
        $root = $ctx.Root
        $covFile = Join-Path $root 'repair\coverage.json'
        if (-not (Test-Path -LiteralPath $covFile)) { return @('coverage.json missing') }
        $cov = $null
        try { $cov = Get-Content -LiteralPath $covFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @('coverage.json unparsable') }
        $checkNames = @(Get-ChildItem -LiteralPath (Join-Path $root 'checks') -File -Filter '*.ps1' | ForEach-Object { $_.BaseName } | Where-Object { $_ -ne '_lib' })
        $lvlByCheck = @{}
        $actionsDir = Join-Path $root 'repair\actions'
        foreach ($jf in (Get-ChildItem -LiteralPath $actionsDir -File -Filter '*.json')) {
            $a = $null
            try { $a = Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            foreach ($mc in @($a.match_checks)) {
                if (-not $lvlByCheck[[string]$mc]) { $lvlByCheck[[string]$mc] = @() }
                $lvlByCheck[[string]$mc] += [string]$a.level
            }
        }
        $covRows = @()
        if ($cov.PSObject.Properties['checks']) { $covRows = @($cov.checks.PSObject.Properties) }
        if ($covRows.Count -eq 0) { $bad += 'coverage.checks empty' }
        $seen = @{}
        foreach ($p in $covRows) {
            $cn = [string]$p.Name
            $seen[$cn] = $true
            if ($checkNames -notcontains $cn) { $bad += "coverage row not a real check: $cn"; continue }
            $how = ''
            if ($p.Value.PSObject.Properties['how']) { $how = [string]$p.Value.how }
            if (@('action', 'card', 'advice') -notcontains $how) { $bad += "bad how '$how': $cn"; continue }
            $matched = @()
            if ($lvlByCheck.ContainsKey($cn)) { $matched = @($lvlByCheck[$cn]) }
            if ($how -eq 'action') {
                if (-not ($matched | Where-Object { $_ -in @('green', 'yellow') })) { $bad += "declared action but no green/yellow matches: $cn" }
            } elseif ($how -eq 'card') {
                if (-not ($matched | Where-Object { $_ -eq 'red' })) { $bad += "declared card but no red matches: $cn" }
            } else {
                $reason = ''
                if ($p.Value.PSObject.Properties['reason']) { $reason = [string]$p.Value.reason }
                if (-not $reason) { $bad += "advice row needs reason: $cn" }
                if ($matched) { $bad += "declared advice but actions match it ($($matched -join '/')): $cn" }
            }
        }
        foreach ($cn in $checkNames) { if (-not $seen[$cn]) { $bad += "check has no closure coverage (silent dead-end): $cn" } }
        return $bad
    }
}

# ---- v1.4.0 轮3 权威溯源断言：每个动作必有合法 sources（≥1 条微软官方域 https 链接，禁静默断链）；
#      coverage.json 的 advice 行同样必须有官方 source。URL 考证记录=知识来源.md §七（1025 批量 HTTP 200 实测） ----
$global:DiagRepairCases += @{
    name = 'rep_sources'
    kind = 'schema'
    assert = {
        param($res, $ctx)
        $bad = @()
        $root = $ctx.Root
        $actionsDir = Join-Path $root 'repair\actions'
        $msDomains = @('learn.microsoft.com', 'support.microsoft.com', 'www.microsoft.com', 'msdn.microsoft.com')
        foreach ($jf in (Get-ChildItem -LiteralPath $actionsDir -File -Filter '*.json')) {
            $a = $null
            try { $a = Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $bad += "unparsable: $($jf.Name)"; continue }
            if (-not $a.PSObject.Properties['sources']) { $bad += "sources missing: $($jf.Name)"; continue }
            $srcs = @($a.sources)
            if ($srcs.Count -lt 1) { $bad += "sources empty: $($jf.Name)"; continue }
            $hasOfficial = $false
            foreach ($s in $srcs) {
                if (-not [string]$s.title -or -not [string]$s.url) { $bad += "source needs title+url: $($jf.Name)"; continue }
                if ([string]$s.url -notmatch '^https://') { $bad += "source url not https: $($jf.Name)" }
                foreach ($d in $msDomains) { if ([string]$s.url -like ('https://' + $d + '/*')) { $hasOfficial = $true } }
            }
            if (-not $hasOfficial) { $bad += "no microsoft-official source: $($jf.Name)" }
        }
        $covFile = Join-Path $root 'repair\coverage.json'
        $cov = $null
        try { $cov = Get-Content -LiteralPath $covFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $bad + @('coverage.json unparsable') }
        foreach ($p in @($cov.checks.PSObject.Properties)) {
            $how = ''
            if ($p.Value.PSObject.Properties['how']) { $how = [string]$p.Value.how }
            if ($how -ne 'advice') { continue }
            if (-not $p.Value.PSObject.Properties['source']) { $bad += "advice row missing source: $($p.Name)"; continue }
            $as = @($p.Value.source)
            if ($as.Count -lt 1) { $bad += "advice source empty: $($p.Name)"; continue }
            $okDomain = $false
            foreach ($s in $as) {
                if (-not [string]$s.title -or -not [string]$s.url) { $bad += "advice source needs title+url: $($p.Name)"; continue }
                if ([string]$s.url -notmatch '^https://') { $bad += "advice source url not https: $($p.Name)" }
                foreach ($d in $msDomains) { if ([string]$s.url -like ('https://' + $d + '/*')) { $okDomain = $true } }
            }
            if (-not $okDomain) { $bad += "advice source not microsoft domain: $($p.Name)" }
        }
        return $bad
    }
}

# ---- v1.4.0 轮2 宝宝巴士规范断言：红卡 steps 全部带 how 五要素（在哪/点什么/输入什么/算成功/失败了先），
#      规范进测试=机器拦（后续新增红卡不带五要素直接红） ----
$global:DiagRepairCases += @{
    name = 'rep_how_steps'
    kind = 'schema'
    assert = {
        param($res, $ctx)
        $bad = @()
        $actionsDir = Join-Path $ctx.Root 'repair\actions'
        foreach ($jf in (Get-ChildItem -LiteralPath $actionsDir -File -Filter '*.json')) {
            $a = $null
            try { $a = Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if ([string]$a.level -ne 'red') { continue }
            $i = 0
            foreach ($st in @($a.steps)) {
                $i++
                if (-not $st.PSObject.Properties['how']) { $bad += "red step without how: $($jf.Name) #$i"; continue }
                foreach ($k in @('at', 'click', 'type', 'ok', 'fail')) {
                    if (-not [string]$st.how.$k) { $bad += "red step how missing '$k': $($jf.Name) #$i" }
                }
            }
        }
        return $bad
    }
}

# ---- v1.4.0 轮3 两张缺口卡用例：红卡必须在加载段拒绝执行（零副作用验证，出厂闸） ----
foreach ($redAct in @('pf_app_crashes_card', 'dv_display_residue_card')) {
    $global:DiagRepairCases += @{
        name = 'rep_red_' + $redAct
        kind = 'real'
        actionId = $redAct
        assert = {
            param($res, $ctx)
            $bad = @()
            if ($res.ok -ne $false) { $bad += "expect ok=false got $($res.ok)"; return $bad }
            if ([string]$res.fail_stage -ne 'load') { $bad += "expect fail_stage=load got $($res.fail_stage)" }
            if ($res.error -notmatch 'red level') { $bad += "load error should mention red level: $($res.error)" }
            return $bad
        }
    }
}

