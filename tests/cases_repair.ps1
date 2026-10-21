#Requires -Version 5.1
<#
diag 修复域用例（v0.8.1 第十二切片；四断言=命令序列/回滚序列/超时负例/权限负例）
结构：
  - rep_schema            ：动作库静态契约（全部绿级/id 唯一/匹配与验证检查项真实存在/超时范围/命令白名单）
  - rep_cmdseq            ：fixture 双步依序写标记文件 → 命令序列断言
  - rep_rollback          ：fixture 第二步 exit 7 → 回滚序列按序跑 → 回滚断言
  - rep_timeout           ：fixture ping 30 发+动作超时 2 秒 → 超时负例断言
  - rep_perm              ：fixture net session（非提权=拒绝访问/提权=成功，按上下文断言）→ 权限负例断言
  - rep_adminblock        ：fixture requires_admin+NeverElevate → 预检挡下零副作用 → 权限负例第二面
  - rep_flush_dns / rep_arp_flush / rep_registerdns ：三个真实绿级动作全链实测
                            （可静默提权的机器=全五段跑通；不可静默提权的机器=NeverElevate 预检挡下，双语境确定性）
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
            if ($jsons.Count -lt 3) { $bad += "actions count $($jsons.Count) < 3 (green 3-5 ruled)" }
            $seenIds = @{}
            $exeAllow = @('ipconfig.exe', 'arp.exe', 'nbtstat.exe', 'netsh.exe')
            foreach ($jf in $jsons) {
                $a = $null
                try { $a = Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $bad += "unparsable: $($jf.Name)"; continue }
                if ([string]$a.id -ne $jf.BaseName) { $bad += "id/file mismatch: $($jf.Name)" }
                if ([string]$a.level -ne 'green') { $bad += "non-green action shipped: $($jf.Name)" }
                if ($seenIds[[string]$a.id]) { $bad += "duplicate id: $($a.id)" }
                $seenIds[[string]$a.id] = $true
                foreach ($mc in @($a.match_checks)) { if ($checksNames -notcontains [string]$mc) { $bad += "match_check not a real check: $mc" } }
                foreach ($vc in @($a.verify_checks)) { if ($checksNames -notcontains [string]$vc) { $bad += "verify_check not a real check: $vc" } }
                if (@($a.steps).Count -lt 1) { $bad += "no steps: $($jf.Name)" }
                foreach ($st in @($a.steps)) {
                    if ($exeAllow -notcontains [string]$st.exe) { $bad += "exe not in allowlist: $($st.exe)" }
                    if (-not @($st.args).Count) { $bad += "step without args: $($jf.Name)" }
                }
                $ts = [int]$a.timeout_sec
                if ($ts -lt 5 -or $ts -gt 120) { $bad += "timeout_sec out of 5..120: $($jf.Name)" }
                if ($null -eq $a.rollback) { $bad += "rollback field missing: $($jf.Name)" }
                foreach ($pc in @($a.prechecks)) { if (@('no_static_arp') -notcontains [string]$pc) { $bad += "unknown precheck '$pc': $($jf.Name)" } }
                foreach ($k in @('name', 'desc', 'affect', 'undo', 'rollback_note')) { if (-not [string]$a.$k) { $bad += "field '$k' empty: $($jf.Name)" } }
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
            if ($steps.Count -ne 2) { $bad += "expect 2 steps got $($steps.Count)" }
            elseif ([int]$steps[1].exit -ne 7) { $bad += "expect fail step exit=7 got $($steps[1].exit)" }
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
)
