#Requires -Version 5.1
<#
检查项：sec_bitlocker —— 磁盘加密（BitLocker）状态（层：system_hardening）
命令：Get-BitLockerVolume（只读；标准用户下拒绝访问→SKIP admin-required）
判定（安全树规格 v1.6 第一节 7）：拒绝访问/查询异常→SKIP(admin-required/query-error)；无 VolumeType=OperatingSystem 卷→SKIP(no-os-volume)；
  系统卷 VolumeStatus=FullyDecrypted→FAIL（系统盘未加密）；FullyEncrypted 且 ProtectionStatus=On→PASS；
  EncryptionInProgress 或 FullyEncrypted 但保护 Off→PASS 附注「挂起态」
出处：https://learn.microsoft.com/en-us/powershell/module/bitlocker/get-bitlockervolume
      + https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/
mock 契约：逐行 `MountPoint | VolumeType | VolumeStatus | ProtectionStatus | EncryptionPercentage`；拒绝访问注入 `ERROR: 拒绝访问`
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Out-Result { param($Status, $Evidence, $Suggestion, $Detail)
    [PSCustomObject]@{
        name = 'sec_bitlocker'; status = $Status; evidence = $Evidence; suggestion = $Suggestion; detail = $Detail
    } | ConvertTo-Json -Depth 5
}

$cmdTag = '[Get-BitLockerVolume]'
$vols = @()
$errLine = ''

if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        if ($ln -match '^ERROR') { $errLine = $ln.Trim(); continue }
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -lt 5) { continue }
        $vols += [PSCustomObject]@{ mount = $p[0].Trim(); type = $p[1].Trim(); status = $p[2].Trim(); prot = $p[3].Trim(); pct = $p[4].Trim() }
    }
} else {
    try {
        foreach ($v in @(Get-BitLockerVolume -ErrorAction Stop)) {
            $vols += [PSCustomObject]@{
                mount = [string]$v.MountPoint; type = [string]$v.VolumeType; status = [string]$v.VolumeStatus
                prot = [string]$v.ProtectionStatus; pct = [string]$v.EncryptionPercentage
            }
        }
    } catch {
        $exMsg = $_.Exception.Message
        if ($exMsg -match '拒绝访问|denied|尚未提升|administrator') { $errLine = $exMsg }
        else {
            Out-Result 'SKIP' "$cmdTag`n查询失败（无法判定）：$exMsg" '' ([PSCustomObject]@{ readable = $false; reason = 'query-error'; error = $exMsg })
            return
        }
    }
}

if ($errLine -ne '') {
    $suggestion = '磁盘加密状态需要管理员权限才能读取（本工具不提权，看不到≠没加密）。' + "`n" + '【人工路径】Win+I →「隐私和安全性」→「设备加密」（家庭版入口；专业版显示为「BitLocker 驱动器加密」）——开关是「开」就安心；「关」且本机常有外出携带，建议开启（先确认微软账户已登录，恢复密钥会自动备份，否则忘密码=数据全丢，务必谨慎）。' + "`n" + '【回滚】不适用（只读核对）'
    Out-Result 'SKIP' "$cmdTag`n$errLine`n结论：磁盘加密状态需要管理员权限才能读取（$errLine）——本工具不提权，看不到≠没加密，请按建议人工核对" $suggestion ([PSCustomObject]@{ readable = $false; reason = 'admin-required' })
    return
}

$typeCn = @{ OperatingSystem = '系统卷'; Data = '数据卷' }
$lines = @(foreach ($v in $vols) {
    $tcn = if ($typeCn.ContainsKey($v.type)) { $typeCn[$v.type] } else { $v.type }
    '{0} {1} | {2} | 保护: {3} | 加密进度: {4}%' -f $v.mount, $tcn, $v.status, $v.prot, $v.pct
})
$head = "$cmdTag`n" + ($lines -join "`n")
$detail = [PSCustomObject]@{ readable = $true; volumes = @($vols | ForEach-Object { [PSCustomObject]@{ mount = $_.mount; type = $_.type; status = $_.status; protection = $_.prot; pct = $_.pct } }) }

$os = @($vols | Where-Object { $_.type -eq 'OperatingSystem' })
if ($os.Count -eq 0) {
    $d = [PSCustomObject]@{ readable = $true; reason = 'no-os-volume'; volumes = $detail.volumes }
    Out-Result 'SKIP' "$head`n结论：未发现系统卷（VolumeType=OperatingSystem）——无法判定系统盘加密状态" '' $d
    return
}
$o = $os[0]

if ($o.status -eq 'FullyDecrypted') {
    $suggestion = "系统盘未加密——电脑丢失或硬盘被拔走时，数据对拿到机器的人完全可见。`n【人工路径】同上入口开启；开启前两件事：①登录微软账户（自动备份恢复密钥）②把重要数据先备份一份。开启后加密在后台跑几小时，期间可正常用电脑。`n【回滚】不适用（解密需在设置里关闭并等待，丢恢复密钥=数据全丢，谨慎）"
    Out-Result 'FAIL' "$head`n结论：系统盘未加密（$($o.mount)，FullyDecrypted）——电脑丢失或被拔盘时数据裸奔" $suggestion $detail
    return
}
if ($o.status -eq 'FullyEncrypted' -and $o.prot -eq 'On') {
    Out-Result 'PASS' $head '' $detail
    return
}
Out-Result 'PASS' "$head`n加密进行中/保护未生效（挂起态）" '' $detail
