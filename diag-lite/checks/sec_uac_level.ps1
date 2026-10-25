#Requires -Version 5.1
<#
检查项：sec_uac_level —— 用户账户控制（UAC）档位（层：system_hardening）
命令：Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop（只读）
判定（安全树规格 v1.6 第一节 5）：注册表键不可读/值不完整→SKIP(query-error)；
  EnableLUA=0→FAIL（UAC 整体禁用）；EnableLUA=1 且 ConsentPromptBehaviorAdmin=0→FAIL（「从不通知」档=管理员静默提权，官方释义仅限最受限环境）；
  其余（值 1-5）→PASS；其中 PromptOnSecureDesktop=0→PASS 附注「提词不经安全桌面」
出处：https://learn.microsoft.com/en-us/windows/security/application-security/application-control/user-account-control/settings-and-configuration
      + https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-gpsb/341747f5-6b5d-4d30-85fc-fa1cc04038d4
mock 契约：逐行 `键=值`（EnableLUA/ConsentPromptBehaviorAdmin/PromptOnSecureDesktop）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Out-Result { param($Status, $Evidence, $Suggestion, $Detail)
    [PSCustomObject]@{
        name = 'sec_uac_level'; status = $Status; evidence = $Evidence; suggestion = $Suggestion; detail = $Detail
    } | ConvertTo-Json -Depth 5
}

$cmdTag = '[注册表 HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System（只读）]'
$lua = -1; $cpba = -1; $posd = -1

if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $i = $ln.IndexOf('=')
        if ($i -le 0) { continue }
        $k = $ln.Substring(0, $i).Trim(); $v = $ln.Substring($i + 1).Trim()
        if ($v -notmatch '^\d+$') { continue }
        if ($k -eq 'EnableLUA') { $lua = [int]$v }
        elseif ($k -eq 'ConsentPromptBehaviorAdmin') { $cpba = [int]$v }
        elseif ($k -eq 'PromptOnSecureDesktop') { $posd = [int]$v }
    }
} else {
    try {
        $rk = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop -ErrorAction Stop
        $lua = [int]$rk.EnableLUA
        $cpba = [int]$rk.ConsentPromptBehaviorAdmin
        $posd = [int]$rk.PromptOnSecureDesktop
    } catch {
        Out-Result 'SKIP' "$cmdTag`n查询失败（无法判定）：$($_.Exception.Message)" '' ([PSCustomObject]@{ reason = 'query-error' })
        return
    }
}
if ($lua -lt 0 -or $cpba -lt 0 -or $posd -lt 0) {
    Out-Result 'SKIP' "$cmdTag`n查询失败（无法判定）：UAC 注册表值不完整" '' ([PSCustomObject]@{ reason = 'query-error' })
    return
}

$cpbaCn = switch ($cpba) {
    0 { '无提示直接提升（从不通知）' }
    1 { '在安全桌面上提示输入凭据' }
    2 { '在安全桌面上提示同意（始终通知）' }
    3 { '提示输入凭据（不经安全桌面）' }
    4 { '在安全桌面上提示同意' }
    5 { '提示同意（非 Windows 应用）——官方默认档' }
    default { "非常规值 $cpba" }
}
$level = 'custom'
if ($lua -eq 0) { $level = 'disabled' }
elseif ($cpba -eq 0) { $level = 'never-notify' }
elseif ($cpba -eq 5) { $level = 'default' }

$head = "$cmdTag`nUAC 总开关(EnableLUA): $lua`n管理员提词档(ConsentPromptBehaviorAdmin): $cpba = $cpbaCn`n安全桌面(PromptOnSecureDesktop): $posd"
$detail = [PSCustomObject]@{ enableLUA = $lua; consentPromptBehaviorAdmin = $cpba; promptOnSecureDesktop = $posd; level = $level }

$suggestion = "UAC 被降到最低档（从不通知）——装软件/改系统设置时不再弹确认窗，恶意程序提权也悄无声息。微软官方口径：此档仅限「最受限环境」使用。`n【人工路径】Win+R → 输入 useraccountcontrolsettings 回车 → 把滑块从最底拉到「默认」档（倒数第二格，文字=仅当应用尝试更改我的电脑时通知我）→ 点「确定」→ 弹出的确认窗点「是」。`n【回滚】同一路径把滑块拉回原档位即可（改档不改数据，随时可逆）"

if ($lua -eq 0) {
    Out-Result 'FAIL' "$head`n结论：UAC 整体禁用（EnableLUA=0）——微软官方：Windows 安全中心会通知操作系统整体安全性已降低" $suggestion $detail
    return
}
if ($cpba -eq 0) {
    Out-Result 'FAIL' "$head`n结论：UAC 处于「从不通知」档——管理员账户静默提权，任何程序请求提升都不弹窗（微软官方：此档仅限最受限环境使用）" $suggestion $detail
    return
}
$tail = if ($posd -eq 0) { "`n提词不经安全桌面（控制面板第三档），可接受但低于默认" } else { '' }
Out-Result 'PASS' ($head + $tail) '' $detail
