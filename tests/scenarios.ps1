#Requires -Version 5.1
# 全树场景数据（engine 断点链验证）：mocks=各检查项 MockRaw；expectExit/keywords=报告断言
# 场景 2 = 2026-10-19 原始故障重演（DNS 死地址，光路闪断后网卡换了网段、DNS 留着旧网关地址）

$routeSingle = @'
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.108     35
'@

$mockAdapterPass = @'
Admin State    State          Type             Interface Name
-------------------------------------------------------------------------
Enabled        Connected      Dedicated        WLAN
'@

$mockIpPass = @'
Configuration for interface "WLAN"
    DHCP enabled:                         Yes
    IP Address:                           192.168.1.108
    Subnet Prefix:                        192.168.1.0/24 (mask 255.255.255.0)
    Default Gateway:                      192.168.1.1
'@

$mockGwPingOk = "###GW 192.168.1.1`n`nPinging 192.168.1.1 with 32 bytes of data:`nReply from 192.168.1.1: bytes=32 time=2ms TTL=64"
$mockGwPingDead = "###GW 192.168.1.1`n`nPinging 192.168.1.1 with 32 bytes of data:`nRequest timed out."
$mockPublicOk = "###SRC 192.168.1.108`n`nPinging 223.5.5.5 with 32 bytes of data:`nReply from 223.5.5.5: bytes=32 time=30ms TTL=50"

$mockDnsInSubnet = @'
Configuration for interface "WLAN"
    DNS servers configured through DHCP:  192.168.1.1
    Register with which suffix:           Primary only
===PART===
Configuration for interface "WLAN"
    DHCP enabled:                         Yes
    IP Address:                           192.168.1.108
    Subnet Prefix:                        192.168.1.0/24 (mask 255.255.255.0)
'@

$mockDnsDead = @'
Configuration for interface "WLAN"
    Statically Configured DNS Servers:    192.168.137.1
    Register with which suffix:           Primary only
===PART===
Configuration for interface "WLAN"
    DHCP enabled:                         Yes
    IP Address:                           192.168.1.108
    Subnet Prefix:                        192.168.1.0/24 (mask 255.255.255.0)
'@

$mockNsOk = "Server:  UnKnown`nAddress:  192.168.1.1`n`nNon-authoritative answer:`nName:    qq.com`nAddresses:  113.108.81.189"
$mockNsTimeout = "DNS request timed out.`n    timeout was 2 seconds."
$mockNsOkPublic = "Server:  public1.alidns.com`nAddress:  223.5.5.5`n`nNon-authoritative answer:`nName:    qq.com`nAddresses:  113.108.81.189"

$global:DiagScenarios = @(
    @{ name = 'full_pass_all_green'; expectExit = 0
       keywords = @('四层全通', '网络栈全通', '应用层')
       mocks    = @{
           net_adapter_list     = $mockAdapterPass
           net_ip_dhcp          = $mockIpPass
           net_gateway_conflict = $routeSingle
           net_gateway_ping     = $routeSingle + "`n===PART===`n" + $mockGwPingOk
           net_public_ping      = $routeSingle + "`n===PART===`n" + $mockPublicOk
           net_dns_deadaddr     = $mockDnsInSubnet
           net_dns_default      = $mockNsOk
           net_dns_gateway_proxy = $routeSingle + "`n===PART===`n" + "###GW 192.168.1.1`n" + $mockNsOk
           net_dns_public       = $mockNsOkPublic
       } }
    @{ name = 'dns_deadaddr_breakpoint'; expectExit = 2
       keywords = @('断点在：DNS 层', '死地址嫌疑', 'netsh interface ip set dns', '【回滚】')
       mocks    = @{
           net_adapter_list     = $mockAdapterPass
           net_ip_dhcp          = $mockIpPass
           net_gateway_conflict = $routeSingle
           net_gateway_ping     = $routeSingle + "`n===PART===`n" + $mockGwPingOk
           net_public_ping      = $routeSingle + "`n===PART===`n" + $mockPublicOk
           net_dns_deadaddr     = $mockDnsDead
           net_dns_default      = $mockNsTimeout
           net_dns_gateway_proxy = $routeSingle + "`n===PART===`n" + "###GW 192.168.1.1`n" + $mockNsTimeout
           net_dns_public       = $mockNsOkPublic
       } }
    @{ name = 'gateway_dead_breakpoint'; expectExit = 2
       keywords = @('断点在：网关', '未查(前层有问题)', 'DNS 层')
       mocks    = @{
           net_adapter_list     = $mockAdapterPass
           net_ip_dhcp          = $mockIpPass
           net_gateway_conflict = $routeSingle
           net_gateway_ping     = $routeSingle + "`n===PART===`n" + $mockGwPingDead
       } }
)

# ---------- v0.2 蓝屏树场景（tree='bluescreen'；聚合取证型用 full=$true 跑满三层） ----------
$bs139x3 = @'
2026-09-04 03:12 | 0x00000139 | C:\WINDOWS\Minidump\090426-12301-01.dmp
2026-10-10 21:45 | 0x00000139 | C:\WINDOWS\Minidump\101026-9876-01.dmp
2026-10-13 20:31 | 0x00000139 | C:\WINDOWS\Minidump\101326-10437-01.dmp
'@

$bsPowerlossPaired = @'
2026-09-04 03:12
2026-10-10 21:45
2026-10-13 20:31
===PART===
2026-09-04 03:12
2026-10-10 21:45
2026-10-13 20:31
'@

$bsDriversHit = @'
nnndisfilter | Running | C:\Windows\system32\drivers\nnndisfilter.sys
HTTP | Stopped | C:\Windows\system32\drivers\HTTP.sys
rassstp | Stopped | C:\Windows\system32\drivers\rassstp.sys
'@

$bsDriversClean = @'
nvlddmkm | Running | C:\Windows\system32\drivers\nvlddmkm.sys
HTTP | Stopped | C:\Windows\system32\drivers\HTTP.sys
rassstp | Stopped | C:\Windows\system32\drivers\rassstp.sys
'@

$global:DiagScenarios += @(
    @{ name = 'bs_full_clean'; tree = 'bluescreen'; expectExit = 0
       keywords = @('三层全通', '无蓝屏', '隐患结论')
       mocks    = @{
           bs_event_history         = ''
           bs_powerloss_distinction = ''
           bs_code_frequency        = ''
           bs_whea_hardware         = ''
           bs_minidump_inventory    = "NONE`n===PART===`n0"
           bs_suspect_drivers       = $bsDriversClean
       } }
    @{ name = 'bs_local_case'; tree = 'bluescreen'; full = $true; expectExit = 2
       keywords = @('隐患结论', '给梨', '0x139', '蓝屏史')
       mocks    = @{
           bs_event_history         = $bs139x3
           bs_powerloss_distinction = $bsPowerlossPaired
           bs_code_frequency        = $bs139x3
           bs_whea_hardware         = '10-04 | 已更正的硬件错误。'
           bs_minidump_inventory    = "101326-10437-01.dmp | 3096 | 2026-10-13 20:35`n===PART===`n3"
           bs_suspect_drivers       = $bsDriversHit
       } }
)

# ---------- v0.3 硬件树场景（1020） ----------
$global:DiagScenarios += @(
    @{ name = 'hw_full_clean'; tree = 'hardware'; expectExit = 0
       keywords = @('三层全通', '硬件体检报告')
       mocks    = @{
           hw_disk_health     = "Samsung SSD 970 | SSD | Healthy | OK"
           hw_smart_predict   = "Samsung SSD 970 | 2 | 0 | 40.0 | false"
           hw_battery_wear    = "Designed | 48000`nFullCharged | 43200"
           hw_thermal         = "TZ_0 | 45.0"
           hw_memdiag_history = "03-02 | 1102"
           bs_whea_hardware   = ''
       } }
    @{ name = 'hw_local_case'; tree = 'hardware'; full = $true; expectExit = 2
       keywords = @('隐患结论', 'WHEA', 'Warning', '硬件体检报告')
       mocks    = @{
           hw_disk_health     = "WDC WD10 | HDD | Warning | Predictive Failure"
           hw_smart_predict   = "WDC WD10 | 25 | 0 | 41.5 | false"
           hw_battery_wear    = "Designed | 48000`nFullCharged | 21600"
           hw_thermal         = "TZ_0 | 85.0"
           hw_memdiag_history = "03-02 | 1101"
           bs_whea_hardware   = '10-04 | 已更正的硬件错误。'
       } }
)

# ---------- v0.4 性能树场景（1020；聚合取证型用 full=$true 跑满三层） ----------
$pfStartup12 = (@(1..12) | ForEach-Object { 'App{0} | HKCU Run | C:\x\a{0}.exe' -f $_ }) -join "`n"
$pfStartup25 = (@(1..25) | ForEach-Object { 'App{0} | HKCU Run | C:\x\a{0}.exe' -f $_ }) -join "`n"

$global:DiagScenarios += @(
    @{ name = 'pf_full_clean'; tree = 'performance'; expectExit = 0
       keywords = @('三层全通', '性能体检报告', '未发现明显性能瓶颈')
       mocks    = @{
           pf_boot_duration          = "10-20 | Information | 21000`n10-19 | Information | 19000"
           pf_boot_degradation_events = ''
           pf_startup_items          = $pfStartup12
           pf_service_timeouts       = ''
           pf_disk_space             = "C: | 237 | 118 | sys`nD: | 931 | 512 | -"
           pf_memory_pressure        = '15.9 | 31.9 | 19.1'
           pf_disk_saturation        = "0 C: | 1 | 0.001`n===SAMPLE===`n0 C: | 2 | 0.001"
       } }
    @{ name = 'pf_local_case'; tree = 'performance'; full = $true; expectExit = 2
       keywords = @('性能瓶颈结论', '性能体检报告', '95', '30000 毫秒')
       mocks    = @{
           pf_boot_duration          = "10-20 | Warning | 95300`n10-19 | Warning | 88210`n10-18 | Information | 41200"
           pf_boot_degradation_events = "101 | WeChat.exe | 3200`n101 | 360Safe.exe | 2800`n103 | XxxGuard | 4100"
           pf_startup_items          = $pfStartup25
           pf_service_timeouts       = "7011 | XxxGuard`n7011 | XxxGuard`n7011 | XxxGuard`n7000 | XxxSvc`n7000 | XxxSvc"
           pf_disk_space             = "C: | 237 | 11.2 | sys`nD: | 931 | 512 | -"
           pf_memory_pressure        = '15.9 | 31.9 | 1.6'
           pf_disk_saturation        = "0 C: | 5 | 0.038`n===SAMPLE===`n0 C: | 6 | 0.041"
       } }
)

# ---------- v0.5 驱动树场景（1020；聚合取证型用 full=$true 跑满三层） ----------
$dvSigClean = @'
nvlddmkm | NVIDIA | Valid | C:\Windows\System32\drivers\nvlddmkm.sys
rt630x64 | Realtek | Valid | C:\Windows\System32\drivers\rt630x64.sys
'@

$dvSigBad = @'
nnndisfilter | 给梨科技 | NotSigned | C:\Windows\System32\drivers\nnndisfilter.sys
nvlddmkm | NVIDIA | Valid | C:\Windows\System32\drivers\nvlddmkm.sys
rt630x64 | Realtek | Valid | C:\Windows\System32\drivers\rt630x64.sys
'@

$dvAgeClean = @'
nvlddmkm | NVIDIA | 2024-03-14 | C:\Windows\System32\drivers\nvlddmkm.sys
rt630x64 | Realtek | 2019-08-02 | C:\Windows\System32\drivers\rt630x64.sys
'@

$dvAgeOld6 = @'
old1 | 老厂商甲 | 2012-03-14 | C:\Windows\System32\drivers\old1.sys
old2 | 老厂商乙 | 2013-08-02 | C:\Windows\System32\drivers\old2.sys
old3 | 老厂商甲 | 2013-11-20 | C:\Windows\System32\drivers\old3.sys
old4 | 老厂商丙 | 2014-01-20 | C:\Windows\System32\drivers\old4.sys
old5 | 老厂商乙 | 2014-05-15 | C:\Windows\System32\drivers\old5.sys
old6 | 老厂商丁 | 2014-09-01 | C:\Windows\System32\drivers\old6.sys
newdrv | NVIDIA | 2024-03-14 | C:\Windows\System32\drivers\newdrv.sys
'@

$dvInv8 = (@(1..8) | ForEach-Object { 'ok{0} | Co{1} | C:\Windows\System32\drivers\ok{0}.sys' -f $_, ($_ % 3 + 1) }) -join "`n"
$dvInv35 = (@(1..35) | ForEach-Object { 'tp{0} | {1} | C:\Windows\System32\drivers\tp{0}.sys' -f $_, @('NVIDIA', '360', '给梨科技', 'VMware', 'Realtek')[($_ - 1) % 5] }) -join "`n"

$dvFiltersClean = @'
ms_tcpip | TCP/IPv4 | True
ms_msclient | 网络客户端 | True
'@

$dvFilters4 = @'
nnndisfilter | 给梨 NDIS 过滤 | True
360Firewall | 360 网络过滤 | True
xxproxy | XX 代理过滤 | True
vNano | 虚拟网卡 | True
ms_tcpip | TCP/IPv4 | True
'@

$dvPnpClean = @'
Intel(R) Wi-Fi 6 AX201 | 0
标准 NVM Express 控制器 | 0
'@

$dvPnpBad = @'
未知 USB 设备 | 28
USB 大容量存储设备 | 43
'@

$dv219Repeat = @'
USB\VID_1234&PID_5678\0001
USB\VID_1234&PID_5678\0001
USB\VID_1234&PID_5678\0001
ROOT\XXSYS\0000
'@

$global:DiagScenarios += @(
    @{ name = 'dv_full_clean'; tree = 'drivers'; expectExit = 0
       keywords = @('驱动体检报告', '三层全通', '未发现驱动域隐患')
       mocks    = @{
           dv_driver_signature     = $dvSigClean
           dv_driver_age           = $dvAgeClean
           dv_thirdparty_inventory = $dvInv8
           dv_network_filters      = $dvFiltersClean
           dv_device_errors        = $dvPnpClean
           dv_driver_load_failures = ''
           bs_suspect_drivers      = $bsDriversClean
       } }
    @{ name = 'dv_local_case'; tree = 'drivers'; full = $true; expectExit = 2
       keywords = @('驱动隐患结论', 'NotSigned', '古董', 'nnndisfilter')
       mocks    = @{
           dv_driver_signature     = $dvSigBad
           dv_driver_age           = $dvAgeOld6
           dv_thirdparty_inventory = $dvInv35
           dv_network_filters      = $dvFilters4
           dv_device_errors        = $dvPnpBad
           dv_driver_load_failures = $dv219Repeat
           bs_suspect_drivers      = $bsDriversHit
       } }
    @{ name = 'all_trees_merge'; tree = 'all'; expectExit = 0
       keywords = @('全面体检报告', '网络体检报告', '蓝屏体检报告', '硬件体检报告', '性能体检报告', '驱动体检报告')
       mocks    = @{
           # 网络（full-clean 集）
           net_adapter_list      = $mockAdapterPass
           net_ip_dhcp           = $mockIpPass
           net_gateway_conflict  = $routeSingle
           net_gateway_ping      = $routeSingle + "`n===PART===`n" + $mockGwPingOk
           net_public_ping       = $routeSingle + "`n===PART===`n" + $mockPublicOk
           net_dns_deadaddr      = $mockDnsInSubnet
           net_dns_default       = $mockNsOk
           net_dns_gateway_proxy = $routeSingle + "`n===PART===`n" + "###GW 192.168.1.1`n" + $mockNsOk
           net_dns_public        = $mockNsOkPublic
           # 蓝屏（full-clean 集）
           bs_event_history         = ''
           bs_powerloss_distinction = ''
           bs_code_frequency        = ''
           bs_whea_hardware         = ''
           bs_minidump_inventory    = "NONE`n===PART===`n0"
           bs_suspect_drivers       = $bsDriversClean
           # 硬件（full-clean 集）
           hw_disk_health     = "Samsung SSD 970 | SSD | Healthy | OK"
           hw_smart_predict   = "Samsung SSD 970 | 2 | 0 | 40.0 | false"
           hw_battery_wear    = "Designed | 48000`nFullCharged | 43200"
           hw_thermal         = "TZ_0 | 45.0"
           hw_memdiag_history = "03-02 | 1102"
           # 性能（full-clean 集）
           pf_boot_duration          = "10-20 | Information | 21000`n10-19 | Information | 19000"
           pf_boot_degradation_events = ''
           pf_startup_items          = $pfStartup12
           pf_service_timeouts       = ''
           pf_disk_space             = "C: | 237 | 118 | sys`nD: | 931 | 512 | -"
           pf_memory_pressure        = '15.9 | 31.9 | 19.1'
           pf_disk_saturation        = "0 C: | 1 | 0.001`n===SAMPLE===`n0 C: | 2 | 0.001"
           # 驱动（full-clean 集）
           dv_driver_signature     = $dvSigClean
           dv_driver_age           = $dvAgeClean
           dv_thirdparty_inventory = $dvInv8
           dv_network_filters      = $dvFiltersClean
           dv_device_errors        = $dvPnpClean
           dv_driver_load_failures = ''
       } }
)
