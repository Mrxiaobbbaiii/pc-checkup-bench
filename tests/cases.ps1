#Requires -Version 5.1
# 模拟故障测试用例数据（铁律 3：每个检查项配模拟故障，无负例验证不许进主分支）
# 结构：check / note / mock / expectStatus / expectEvidenceKeyword（可选，证据须含）
# 真实格式样张取自 2026-10-19 真机取证。

$global:DiagCases = @(
    # ---------- 1. net_adapter_list ----------
    @{ check = 'net_adapter_list'; note = '多网卡其中2张已连接'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'Connected'
       mock = @'
Admin State    State          Type             Interface Name
-------------------------------------------------------------------------
Enabled        Disconnected   Dedicated        以太网 2
Enabled        Connected      Dedicated        以太网
Enabled        Connected      Dedicated        WLAN
'@ },
    @{ check = 'net_adapter_list'; note = '全部断开(拔线/关WiFi)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'Disconnected'
       mock = @'
Admin State    State          Type             Interface Name
-------------------------------------------------------------------------
Enabled        Disconnected   Dedicated        以太网
'@ },

    # ---------- 2. net_ip_dhcp ----------
    @{ check = 'net_ip_dhcp'; note = '正常 DHCP 地址'
       expectStatus = 'PASS'; expectEvidenceKeyword = '192.168.1.108'
       mock = @'
Configuration for interface "WLAN"
    DHCP enabled:                         Yes
    IP Address:                           192.168.1.108
    Subnet Prefix:                        192.168.1.0/24 (mask 255.255.255.0)
    Default Gateway:                      192.168.1.1
'@ },
    @{ check = 'net_ip_dhcp'; note = 'APIPA 自分配 169.254(DHCP 无人应答)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '169.254'
       mock = @'
Configuration for interface "WLAN"
    DHCP enabled:                         Yes
    IP Address:                           169.254.100.5
    Subnet Prefix:                        169.254.0.0/16 (mask 255.255.0.0)
'@ },
    @{ check = 'net_ip_dhcp'; note = '双网卡一坏一好(有可用链路不算断点)'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'APIPA'
       mock = @'
Configuration for interface "以太网"
    DHCP enabled:                         Yes
    IP Address:                           169.254.99.9
    Subnet Prefix:                        169.254.0.0/16 (mask 255.255.0.0)
===ADAPTER===
Configuration for interface "WLAN"
    DHCP enabled:                         Yes
    IP Address:                           192.168.1.108
    Subnet Prefix:                        192.168.1.0/24 (mask 255.255.255.0)
    Default Gateway:                      192.168.1.1
'@ },

    # ---------- 3. net_gateway_conflict ----------
    @{ check = 'net_gateway_conflict'; note = '单默认网关'
       expectStatus = 'PASS'; expectEvidenceKeyword = '192.168.1.1'
       mock = @'
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.108     35
'@ },
    @{ check = 'net_gateway_conflict'; note = '双默认网关同跃点(冲突)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '10.32.76.135'
       mock = @'
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.0.1    192.168.0.110     35
          0.0.0.0          0.0.0.0     10.32.76.135      10.32.76.93     35
'@ },
    @{ check = 'net_gateway_conflict'; note = '双默认网关跃点不同(低者优先)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '192.168.1.1'
       mock = @'
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.108     25
          0.0.0.0          0.0.0.0     10.32.76.135      10.32.76.93     35
'@ },
    @{ check = 'net_gateway_conflict'; note = '无默认路由'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'route print'
       mock = @'
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
        127.0.0.0    255.0.0.0         On-link         127.0.0.1    331
'@ },
    @{ check = 'net_gateway_conflict'; note = '网关跨网段(官方故障模式:网关必须与网卡同网段)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '192.168.137.1'
       mock = @'
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0    192.168.137.1    192.168.1.108     35
      192.168.1.0    255.255.255.0         On-link     192.168.1.108    291
'@ },

    # ---------- 4. net_gateway_ping ----------
    @{ check = 'net_gateway_ping'; note = '网关可达'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'TTL=64'
       mock = @'
Active Routes:
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.108     35
===PART===
###GW 192.168.1.1

Pinging 192.168.1.1 with 32 bytes of data:
Reply from 192.168.1.1: bytes=32 time=2ms TTL=64
'@ },
    @{ check = 'net_gateway_ping'; note = '网关 ping 超时'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'timed out'
       mock = @'
Active Routes:
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.108     35
===PART===
###GW 192.168.1.1

Pinging 192.168.1.1 with 32 bytes of data:
Request timed out.
'@ },

    # ---------- 5. net_dns_deadaddr ----------
    @{ check = 'net_dns_deadaddr'; note = '私有DNS在网段内+公共DNS'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'ok-in-subnet'
       mock = @'
Configuration for interface "WLAN"
    DNS servers configured through DHCP:  10.32.76.135
    Register with which suffix:           Primary only

Configuration for interface "以太网"
    Statically Configured DNS Servers:    223.5.5.5
                                          119.29.29.29
    Register with which suffix:           Primary only
===PART===
Configuration for interface "WLAN"
    DHCP enabled:                         Yes
    IP Address:                           10.32.76.93
    Subnet Prefix:                        10.32.76.0/24 (mask 255.255.255.0)
===PART===
Configuration for interface "以太网"
    DHCP enabled:                         No
    IP Address:                           192.168.0.110
    Subnet Prefix:                        192.168.0.0/24 (mask 255.255.255.0)
'@ },
    @{ check = 'net_dns_deadaddr'; note = '死地址:DNS指向不存在的旧网段(2026-10-19原始故障)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'DEAD-SUSPECT'
       mock = @'
Configuration for interface "以太网"
    Statically Configured DNS Servers:    192.168.137.1
    Register with which suffix:           Primary only
===PART===
Configuration for interface "以太网"
    DHCP enabled:                         No
    IP Address:                           192.168.1.108
    Subnet Prefix:                        192.168.1.0/24 (mask 255.255.255.0)
'@ },

    # ---------- 6. net_dns_default ----------
    @{ check = 'net_dns_default'; note = '默认DNS解析成功'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'Addresses'
       mock = @'
Server:  public1.alidns.com
Address:  223.5.5.5

Non-authoritative answer:
Name:    qq.com
Addresses:  113.108.81.189
'@ },
    @{ check = 'net_dns_default'; note = '默认DNS超时(死地址典型表现)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'timed out'
       mock = @'
DNS request timed out.
    timeout was 2 seconds.
Default servers are not available
DNS request timed out.
    timeout was 2 seconds.
'@ },
    @{ check = 'net_dns_default'; note = 'NXDOMAIN(qq.com不可能不存在=劫持/污染)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'Non-existent'
       mock = @'
Server:  UnKnown
Address:  192.168.137.1

*** UnKnown can't find qq.com: Non-existent domain
'@ },
    @{ check = 'net_dns_default'; note = '拒绝应答(网络策略禁自定义DNS)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'refused'
       mock = @'
Server:  UnKnown
Address:  192.168.0.1

*** UnKnown can't find qq.com: Query refused
'@ },

    # ---------- 7. net_dns_gateway_proxy ----------
    @{ check = 'net_dns_gateway_proxy'; note = '路由器DNS代理正常'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'ok'
       mock = @'
Active Routes:
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.108     35
===PART===
###GW 192.168.1.1
Server:  UnKnown
Address:  192.168.1.1

Name:    qq.com
Addresses:  113.108.81.189
'@ },
    @{ check = 'net_dns_gateway_proxy'; note = '网关不响应DNS(代理挂)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'timeout'
       mock = @'
Active Routes:
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.108     35
===PART===
###GW 192.168.1.1
DNS request timed out.
    timeout was 2 seconds.
'@ },

    # ---------- 8. net_dns_public ----------
    @{ check = 'net_dns_public'; note = '公共DNS 223.5.5.5 可用'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'Addresses'
       mock = @'
Server:  public1.alidns.com
Address:  223.5.5.5

Non-authoritative answer:
Name:    qq.com
Addresses:  123.150.76.218
'@ },
    @{ check = 'net_dns_public'; note = '公共DNS超时(UDP53被拦/断网)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'timed out'
       mock = @'
DNS request timed out.
    timeout was 2 seconds.
'@ },

    # ---------- 9. net_public_ping ----------
    @{ check = 'net_public_ping'; note = '源地址可出公网'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'TTL=50'
       mock = @'
Active Routes:
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.108     35
===PART===
###SRC 192.168.1.108

Pinging 223.5.5.5 with 32 bytes of data:
Reply from 223.5.5.5: bytes=32 time=30ms TTL=50
'@ },
    @{ check = 'net_public_ping'; note = '公网ping全不通(WAN侧断)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'timed out'
       mock = @'
Active Routes:
          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.108     35
===PART===
###SRC 192.168.1.108

Pinging 223.5.5.5 with 32 bytes of data:
Request timed out.
'@ },

    # ---------- 10. bs_event_history（v0.2 蓝屏史） ----------
    @{ check = 'bs_event_history'; note = '3次0x139蓝屏史(1013案实况)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '0x00000139'
       mock = @'
2026-09-04 03:12 | 0x00000139 | C:\WINDOWS\Minidump\090426-12301-01.dmp
2026-10-10 21:45 | 0x00000139 | C:\WINDOWS\Minidump\101026-9876-01.dmp
2026-10-13 20:31 | 0x00000139 | C:\WINDOWS\Minidump\101326-10437-01.dmp
'@ },
    @{ check = 'bs_event_history'; note = '无记录(mock空文本)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '无蓝屏史'
       mock = '' },

    # ---------- 11. bs_code_frequency（同码复发） ----------
    @{ check = 'bs_code_frequency'; note = '0x139×3慢性病(码书命中含人话)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '0x139'; expectSuggestionKeyword = '关键数据结构'
       mock = @'
2026-09-04 03:12 | 0x00000139 | C:\WINDOWS\Minidump\090426-12301-01.dmp
2026-10-10 21:45 | 0x00000139 | C:\WINDOWS\Minidump\101026-9876-01.dmp
2026-10-13 20:31 | 0x00000139 | C:\WINDOWS\Minidump\101326-10437-01.dmp
'@ },
    @{ check = 'bs_code_frequency'; note = '陌生码0xABC×2(未收录如实标注)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '0xABC'; expectSuggestionKeyword = '未收录'
       mock = @'
2026-10-01 10:00 | 0x00000ABC | C:\WINDOWS\Minidump\100126-1-01.dmp
2026-10-02 10:00 | 0x00000ABC | C:\WINDOWS\Minidump\100226-2-01.dmp
'@ },
    @{ check = 'bs_code_frequency'; note = '各单次(非慢性病)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '全部单次'
       mock = @'
2026-10-01 10:00 | 0x00000139 | C:\WINDOWS\Minidump\100126-1-01.dmp
2026-10-02 10:00 | 0x0000007E | C:\WINDOWS\Minidump\100226-2-01.dmp
'@ },
    @{ check = 'bs_code_frequency'; note = '码书JSON损坏→SKIP不得崩'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '不可用'
       mock = @'
2026-10-01 10:00 | 0x00000139 | C:\WINDOWS\Minidump\100126-1-01.dmp
'@
       mockCodesJson = '{ broken json!!' },

    # ---------- 12. bs_powerloss_distinction（掉电/死机辨别） ----------
    @{ check = 'bs_powerloss_distinction'; note = '41×3全孤立(频繁掉电嫌疑)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '孤立'
       mock = @'
2026-09-01 08:00
2026-09-15 12:30
2026-10-05 23:10
===PART===
2026-10-13 20:31
'@ },
    @{ check = 'bs_powerloss_distinction'; note = '41与1001分钟级配对(同一蓝屏)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '配对'
       mock = @'
2026-10-13 20:31
2026-10-10 21:45
===PART===
2026-10-13 20:31
2026-10-10 21:46
'@ },
    @{ check = 'bs_powerloss_distinction'; note = '无任何事件'
       expectStatus = 'PASS'; expectEvidenceKeyword = '无 41'
       mock = '' },

    # ---------- 13. bs_whea_hardware（硬件层报错） ----------
    @{ check = 'bs_whea_hardware'; note = '1条WHEA(硬件层嫌疑)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '10-04'
       mock = @'
10-04 | 已更正的硬件错误。
'@ },
    @{ check = 'bs_whea_hardware'; note = '空(无硬件报错)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '无 WHEA'
       mock = '' },

    # ---------- 14. bs_minidump_inventory（dump 盘点） ----------
    @{ check = 'bs_minidump_inventory'; note = '1个dump(素材在)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '.dmp'
       mock = @'
101326-10437-01.dmp | 3096 | 2026-10-13 20:35
===PART===
3
'@ },
    @{ check = 'bs_minidump_inventory'; note = 'NONE+有蓝屏史(WARN已被清理)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '已被清理'
       mock = @'
NONE
===PART===
3
'@ },
    @{ check = 'bs_minidump_inventory'; note = 'NONE+无蓝屏史(SKIP)'
       expectStatus = 'SKIP'
       mock = @'
NONE
===PART===
0
'@ },

    # ---------- 15. bs_suspect_drivers（嫌疑驱动） ----------
    @{ check = 'bs_suspect_drivers'; note = 'nnndisfilter Running(某加速器命中)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '某加速器'; expectSuggestionKeyword = '卸载'
       mock = @'
nnndisfilter | Running | C:\Windows\system32\drivers\nnndisfilter.sys
HTTP | Stopped | C:\Windows\system32\drivers\HTTP.sys
'@ },
    @{ check = 'bs_suspect_drivers'; note = '无关驱动(无命中)'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'nvlddmkm'
       mock = @'
nvlddmkm | Running | C:\Windows\system32\drivers\nvlddmkm.sys
HTTP | Stopped | C:\Windows\system32\drivers\HTTP.sys
'@ },
    @{ check = 'bs_suspect_drivers'; note = '名单JSON损坏→SKIP不得崩'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '不可用'
       mock = @'
nnndisfilter | Running | C:\Windows\system32\drivers\nnndisfilter.sys
'@
       mockSuspectsJson = '{ broken json!!' }

    # ---------- 16. hw_disk_health（v0.3 硬件树） ----------
    @{ check = 'hw_disk_health'; note = '一块盘Warning'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'Warning'; expectSuggestionKeyword = '备份'
       mock = @'
Samsung SSD 970 | SSD | Healthy | OK
WDC WD10 | HDD | Warning | Predictive Failure
'@ },
    @{ check = 'hw_disk_health'; note = '全Healthy'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'Healthy'
       mock = @'
Samsung SSD 970 | SSD | Healthy | OK
'@ },
    @{ check = 'hw_disk_health'; note = '无盘信息'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
'@ },

    # ---------- 17. hw_smart_predict ----------
    @{ check = 'hw_smart_predict'; note = 'SSD磨损25%(超10%警戒)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '磨损'; expectSuggestionKeyword = '备份'
       mock = @'
Samsung SSD 970 | 25 | 0 | 41.5 | false
'@ },
    @{ check = 'hw_smart_predict'; note = 'SMART PredictFailure=true'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'PredictFailure'
       mock = @'
WDC WD10 | null | null | null | true
'@ },
    @{ check = 'hw_smart_predict'; note = '健康计数器'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'wear=2'
       mock = @'
Samsung SSD 970 | 2 | 0 | 40.0 | false
'@ },
    @{ check = 'hw_smart_predict'; note = '计数器全null(家用盘)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '家用盘'
       mock = @'
WDC WD10 | null | null | null | null
'@ },
    @{ check = 'hw_smart_predict'; note = '非管理员ACCESS-DENIED'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '管理员'
       mock = @'
ACCESS-DENIED
'@ },

    # ---------- 18. hw_battery_wear ----------
    @{ check = 'hw_battery_wear'; note = '损耗55%(重度)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '损耗'; expectSuggestionKeyword = 'batteryreport'
       mock = @'
Designed | 48000
FullCharged | 21600
'@ },
    @{ check = 'hw_battery_wear'; note = '损耗10%(正常)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '损耗 10'
       mock = @'
Designed | 48000
FullCharged | 43200
'@ },
    @{ check = 'hw_battery_wear'; note = '无电池(台式)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '无电池'
       mock = @'
'@ },

    # ---------- 19. hw_thermal ----------
    @{ check = 'hw_thermal'; note = '热区85℃过热'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '过热'; expectSuggestionKeyword = '清灰'
       mock = @'
TZ_0 | 85.0
'@ },
    @{ check = 'hw_thermal'; note = '热区45℃正常'
       expectStatus = 'PASS'; expectEvidenceKeyword = '45'
       mock = @'
TZ_0 | 45.0
'@ },
    @{ check = 'hw_thermal'; note = '无热区暴露(台式)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '无热区'
       mock = @'
'@ },
    @{ check = 'hw_thermal'; note = 'ACPI假值-5℃(不可信)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '不可信'
       mock = @'
TZ_0 | -5.0
'@ },

    # ---------- 20. hw_memdiag_history（1027 口径修正：消息优先，ID 仅展示） ----------
    @{ check = 'hw_memdiag_history'; note = '诊断报硬件问题1101'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'hardware problems'; expectSuggestionKeyword = 'mdsched'
       mock = @'
03-02 | 1101 | hardware problems
'@ },
    @{ check = 'hw_memdiag_history'; note = '诊断无问题1102'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'no errors'
       mock = @'
03-02 | 1102 | no errors
'@ },
    @{ check = 'hw_memdiag_history'; note = '1101结论文本no errors(消息优先正例)'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'no errors'
       mock = @'
03-02 | 1101 | no errors
'@ },
    @{ check = 'hw_memdiag_history'; note = '1101乱码文本(不可判读负例)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '无法判读'
       mock = @'
03-02 | 1101 | 乱码文本
'@ },
    @{ check = 'hw_memdiag_history'; note = '从未跑过诊断(常态)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '没查过'
       mock = @'
'@ },

    # ---------- 21. pf_boot_duration（v0.4 性能树） ----------
    @{ check = 'pf_boot_duration'; note = '近5次2×Warning(微软慢启动标记)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'Warning'; expectSuggestionKeyword = '慢启动'
       mock = @'
10-20 | Warning | 95300
10-19 | Warning | 88210
10-18 | Information | 41200
10-17 | Information | 38900
10-16 | Information | 44500
'@ },
    @{ check = 'pf_boot_duration'; note = '无Warning但均值75s(超60s警戒线)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '75000ms'; expectSuggestionKeyword = '警戒线'
       mock = @'
10-20 | Information | 78000
10-19 | Information | 72000
'@ },
    @{ check = 'pf_boot_duration'; note = '均值40s(30-60s偏慢附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '偏慢'
       mock = @'
10-20 | Information | 41000
10-19 | Information | 39000
'@ },
    @{ check = 'pf_boot_duration'; note = '均值20s(健康)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '19000ms'
       mock = @'
10-20 | Information | 21000
10-19 | Information | 19000
'@ },
    @{ check = 'pf_boot_duration'; note = '无100事件(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
'@ },

    # ---------- 22. pf_boot_degradation_events ----------
    @{ check = 'pf_boot_degradation_events'; note = '3条点名(101/103)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '拖慢启动'; expectSuggestionKeyword = '点名'
       mock = @'
101 | WeChat.exe | 3200
101 | 360Safe.exe | 2800
103 | XxxGuard | 4100
'@ },
    @{ check = 'pf_boot_degradation_events'; note = '1条点名(少量PASS附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '1 条'
       mock = @'
101 | WeChat.exe | 3200
'@ },
    @{ check = 'pf_boot_degradation_events'; note = '0条点名'
       expectStatus = 'PASS'; expectEvidenceKeyword = '0 条'
       mock = @'
'@ },
    @{ check = 'pf_boot_degradation_events'; note = '日志不可读(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 23. pf_startup_items ----------
    @{ check = 'pf_startup_items'; note = '25项超负担线(空名单不误报损坏)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '超过 20 项负担线'; expectSuggestionKeyword = '识别'
       mock = @'
App01 | HKCU Run | C:\x\a1.exe
App02 | HKCU Run | C:\x\a2.exe
App03 | HKCU Run | C:\x\a3.exe
App04 | HKCU Run | C:\x\a4.exe
App05 | HKCU Run | C:\x\a5.exe
App06 | HKCU Run | C:\x\a6.exe
App07 | HKCU Run | C:\x\a7.exe
App08 | HKCU Run | C:\x\a8.exe
App09 | HKCU Run | C:\x\a9.exe
App10 | HKCU Run | C:\x\a10.exe
App11 | HKCU Run | C:\x\a11.exe
App12 | HKCU Run | C:\x\a12.exe
App13 | HKCU Run | C:\x\a13.exe
App14 | HKCU Run | C:\x\a14.exe
App15 | HKCU Run | C:\x\a15.exe
App16 | HKCU Run | C:\x\a16.exe
App17 | HKCU Run | C:\x\a17.exe
App18 | HKCU Run | C:\x\a18.exe
App19 | HKCU Run | C:\x\a19.exe
App20 | HKCU Run | C:\x\a20.exe
App21 | HKCU Run | C:\x\a21.exe
App22 | HKCU Run | C:\x\a22.exe
App23 | HKCU Run | C:\x\a23.exe
App24 | HKCU Run | C:\x\a24.exe
App25 | HKCU Run | C:\x\a25.exe
'@ },
    @{ check = 'pf_startup_items'; note = '注入名单命中→FAIL'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '命中名单'; expectSuggestionKeyword = '卸载'
       mock = @'
App1 | HKCU Run | C:\x\a1.exe
App2 | HKCU Run | C:\x\a2.exe
App3 | HKCU Run | C:\x\a3.exe
App4 | HKCU Run | C:\x\a4.exe
App5 | HKCU Run | C:\x\a5.exe
App6 | HKCU Run | C:\x\a6.exe
App7 | HKCU Run | C:\x\a7.exe
FastBooster | HKLM Run | C:\Program Files\fastbooster\fb.exe
'@
       mockSuspectsJson = '{"suspects":[{"pattern":"fastbooster","label":"某加速器自启(测试)","advice":"卸载本体。回滚：重装即可"}]}' },
    @{ check = 'pf_startup_items'; note = '8项健康'
       expectStatus = 'PASS'; expectEvidenceKeyword = '8 项'
       mock = @'
App1 | HKCU Run | C:\x\a1.exe
App2 | HKCU Run | C:\x\a2.exe
App3 | HKCU Run | C:\x\a3.exe
App4 | HKCU Run | C:\x\a4.exe
App5 | HKCU Run | C:\x\a5.exe
App6 | HKCU Run | C:\x\a6.exe
App7 | HKCU Run | C:\x\a7.exe
OneDrive | Startup | C:\x\OneDrive.exe
'@ },
    @{ check = 'pf_startup_items'; note = '无自启数据(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
'@ },
    @{ check = 'pf_startup_items'; note = '名单JSON损坏→SKIP不得崩'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '不可用'
       mock = @'
App1 | HKCU Run | C:\x\a1.exe
'@
       mockSuspectsJson = '{ broken json!!' },

    # ---------- 24. pf_service_timeouts ----------
    @{ check = 'pf_service_timeouts'; note = '5条(7011×3+7000×2)服务迟钝'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '30000 毫秒'; expectSuggestionKeyword = '卸载'
       mock = @'
7011 | XxxGuard
7011 | XxxGuard
7011 | XxxGuard
7000 | XxxSvc
7000 | XxxSvc
'@ },
    @{ check = 'pf_service_timeouts'; note = '1条(少量PASS附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '1 条'
       mock = @'
7000 | XxxSvc
'@ },
    @{ check = 'pf_service_timeouts'; note = '0条'
       expectStatus = 'PASS'; expectEvidenceKeyword = '0 条'
       mock = @'
'@ },
    @{ check = 'pf_service_timeouts'; note = 'System日志不可读(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 25. pf_disk_space ----------
    @{ check = 'pf_disk_space'; note = '系统盘4.7%(触10%线)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '系统盘'; expectSuggestionKeyword = '清理建议'
       mock = @'
C: | 237 | 11.2 | sys
D: | 931 | 512 | -
'@ },
    @{ check = 'pf_disk_space'; note = '系统盘比例10.6%但剩18GB(触20GB线)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '系统盘'; expectSuggestionKeyword = '20GB'
       mock = @'
C: | 170 | 18 | sys
'@ },
    @{ check = 'pf_disk_space'; note = '系统盘12.2%(偏紧PASS附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '偏紧'
       mock = @'
C: | 237 | 29 | sys
'@ },
    @{ check = 'pf_disk_space'; note = '全盘充足'
       expectStatus = 'PASS'; expectEvidenceKeyword = '118'
       mock = @'
C: | 237 | 118 | sys
D: | 931 | 512 | -
'@ },
    @{ check = 'pf_disk_space'; note = '非系统盘紧张(PASS附WARN)'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'WARN'
       mock = @'
C: | 237 | 118 | sys
E: | 100 | 8 | -
'@ },
    @{ check = 'pf_disk_space'; note = '无本地盘(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
'@ },

    # ---------- 26. pf_memory_pressure ----------
    @{ check = 'pf_memory_pressure'; note = '物理2GB(低于Win11官方线)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'Win11'; expectSuggestionKeyword = '内存条'
       mock = @'
2.0 | 31.9 | 3.1
'@ },
    @{ check = 'pf_memory_pressure'; note = '16GB+commit95%(双吃紧)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '双吃紧'; expectSuggestionKeyword = 'commit'
       mock = @'
15.9 | 31.9 | 1.6
'@ },
    @{ check = 'pf_memory_pressure'; note = '6GB(规格贴最低线PASS附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '贴最低线'
       mock = @'
5.9 | 15.9 | 9.5
'@ },
    @{ check = 'pf_memory_pressure'; note = '16GB+commit40%(健康)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '15.9'
       mock = @'
15.9 | 31.9 | 19.1
'@ },
    @{ check = 'pf_memory_pressure'; note = '查询失败(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
'@ },

    # ---------- 27. pf_disk_saturation ----------
    @{ check = 'pf_disk_saturation'; note = '双采样队列5/6(IO持续堵塞)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '队列=5'; expectSuggestionKeyword = '堵塞'
       mock = @'
0 C: | 5 | 0.038
===SAMPLE===
0 C: | 6 | 0.041
'@ },
    @{ check = 'pf_disk_saturation'; note = '双采样4/1(瞬时高峰PASS附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '瞬时高峰'
       mock = @'
0 C: | 4 | 0.02
===SAMPLE===
0 C: | 1 | 0.01
'@ },
    @{ check = 'pf_disk_saturation'; note = '双采样1/2(健康)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '队列=1'
       mock = @'
0 C: | 1 | 0.001
===SAMPLE===
0 C: | 2 | 0.001
'@ },
    @{ check = 'pf_disk_saturation'; note = '计数器不暴露(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
'@ }

    # ---------- 28. dv_driver_signature（v0.5 驱动树） ----------
    @{ check = 'dv_driver_signature'; note = 'NotSigned 1 个+Valid 3 个(来路不明)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'NotSigned'; expectSuggestionKeyword = '蓝屏高发源'
       mock = @'
nnndisfilter | 示例科技 | NotSigned | C:\Windows\System32\drivers\nnndisfilter.sys
nvlddmkm | NVIDIA | Valid | C:\Windows\System32\drivers\nvlddmkm.sys
rt630x64 | Realtek | Valid | C:\Windows\System32\drivers\rt630x64.sys
vgk | Riot Games | Valid | C:\Windows\System32\drivers\vgk.sys
'@ },
    @{ check = 'dv_driver_signature'; note = 'HashMismatch(签名被改)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'HashMismatch'; expectSuggestionKeyword = '蓝屏高发源'
       mock = @'
xxgamedrv | XX Game | HashMismatch | C:\Windows\System32\drivers\xxgamedrv.sys
'@ },
    @{ check = 'dv_driver_signature'; note = 'UnknownError(验签系统报错)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'UnknownError'; expectSuggestionKeyword = '蓝屏高发源'
       mock = @'
weird0drv | Weird Co | UnknownError | C:\Windows\System32\drivers\weird0drv.sys
'@ },
    @{ check = 'dv_driver_signature'; note = '非微软全 Valid(正规第三方常态)'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'Valid'
       mock = @'
nvlddmkm | NVIDIA | Valid | C:\Windows\System32\drivers\nvlddmkm.sys
rt630x64 | Realtek | Valid | C:\Windows\System32\drivers\rt630x64.sys
vgk | Riot Games | Valid | C:\Windows\System32\drivers\vgk.sys
'@ },
    @{ check = 'dv_driver_signature'; note = '枚举失败(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 29. dv_driver_age ----------
    @{ check = 'dv_driver_age'; note = '7 个 2013 年文件(古董队)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '古董'; expectSuggestionKeyword = '更新驱动'
       mock = @'
drv1 | 老厂商甲 | 2013-01-10 | C:\Windows\System32\drivers\drv1.sys
drv2 | 老厂商乙 | 2013-02-10 | C:\Windows\System32\drivers\drv2.sys
drv3 | 老厂商甲 | 2013-03-10 | C:\Windows\System32\drivers\drv3.sys
drv4 | 老厂商丙 | 2013-04-10 | C:\Windows\System32\drivers\drv4.sys
drv5 | 老厂商乙 | 2013-05-10 | C:\Windows\System32\drivers\drv5.sys
drv6 | 老厂商甲 | 2013-06-10 | C:\Windows\System32\drivers\drv6.sys
drv7 | 老厂商丁 | 2013-07-10 | C:\Windows\System32\drivers\drv7.sys
newdrv | NVIDIA | 2024-03-14 | C:\Windows\System32\drivers\newdrv.sys
'@ },
    @{ check = 'dv_driver_age'; note = '2 个 2014 年(PASS 附注点名)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '年代久远'
       mock = @'
old1 | Realtek | 2014-01-20 | C:\Windows\System32\drivers\old1.sys
old2 | 老厂商乙 | 2014-06-20 | C:\Windows\System32\drivers\old2.sys
newdrv | NVIDIA | 2024-03-14 | C:\Windows\System32\drivers\newdrv.sys
'@ },
    @{ check = 'dv_driver_age'; note = '全 2019 后(健康)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '最早文件日期'
       mock = @'
nvlddmkm | NVIDIA | 2024-03-14 | C:\Windows\System32\drivers\nvlddmkm.sys
rt630x64 | Realtek | 2019-08-02 | C:\Windows\System32\drivers\rt630x64.sys
'@ },
    @{ check = 'dv_driver_age'; note = '枚举失败(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 30. dv_thirdparty_inventory ----------
    @{ check = 'dv_thirdparty_inventory'; note = '35 个非微软(体量过大)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '35'; expectSuggestionKeyword = '卸载'
       mock = @'
nv1 | NVIDIA | C:\Windows\System32\drivers\nv1.sys
nv2 | NVIDIA | C:\Windows\System32\drivers\nv2.sys
nv3 | NVIDIA | C:\Windows\System32\drivers\nv3.sys
nv4 | NVIDIA | C:\Windows\System32\drivers\nv4.sys
nv5 | NVIDIA | C:\Windows\System32\drivers\nv5.sys
nv6 | NVIDIA | C:\Windows\System32\drivers\nv6.sys
nv7 | NVIDIA | C:\Windows\System32\drivers\nv7.sys
nv8 | NVIDIA | C:\Windows\System32\drivers\nv8.sys
s360a | 360 | C:\Windows\System32\drivers\s360a.sys
s360b | 360 | C:\Windows\System32\drivers\s360b.sys
s360c | 360 | C:\Windows\System32\drivers\s360c.sys
s360d | 360 | C:\Windows\System32\drivers\s360d.sys
s360e | 360 | C:\Windows\System32\drivers\s360e.sys
s360f | 360 | C:\Windows\System32\drivers\s360f.sys
gli1 | 示例科技 | C:\Windows\System32\drivers\gli1.sys
gli2 | 示例科技 | C:\Windows\System32\drivers\gli2.sys
gli3 | 示例科技 | C:\Windows\System32\drivers\gli3.sys
vm1 | VMware | C:\Windows\System32\drivers\vm1.sys
vm2 | VMware | C:\Windows\System32\drivers\vm2.sys
vm3 | VMware | C:\Windows\System32\drivers\vm3.sys
vm4 | VMware | C:\Windows\System32\drivers\vm4.sys
rtl1 | Realtek | C:\Windows\System32\drivers\rtl1.sys
rtl2 | Realtek | C:\Windows\System32\drivers\rtl2.sys
rtl3 | Realtek | C:\Windows\System32\drivers\rtl3.sys
rtl4 | Realtek | C:\Windows\System32\drivers\rtl4.sys
rtl5 | Realtek | C:\Windows\System32\drivers\rtl5.sys
itl1 | Intel | C:\Windows\System32\drivers\itl1.sys
itl2 | Intel | C:\Windows\System32\drivers\itl2.sys
itl3 | Intel | C:\Windows\System32\drivers\itl3.sys
vg1 | Vanguard | C:\Windows\System32\drivers\vg1.sys
vg2 | Vanguard | C:\Windows\System32\drivers\vg2.sys
qk1 | quark | C:\Windows\System32\drivers\qk1.sys
qk2 | quark | C:\Windows\System32\drivers\qk2.sys
nf1 | netfilter Co | C:\Windows\System32\drivers\nf1.sys
nf2 | netfilter Co | C:\Windows\System32\drivers\nf2.sys
'@ },
    @{ check = 'dv_thirdparty_inventory'; note = '20 个(偏厚 PASS 附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '偏厚'
       mock = @'
tp01 | CoA | C:\Windows\System32\drivers\tp01.sys
tp02 | CoA | C:\Windows\System32\drivers\tp02.sys
tp03 | CoA | C:\Windows\System32\drivers\tp03.sys
tp04 | CoA | C:\Windows\System32\drivers\tp04.sys
tp05 | CoB | C:\Windows\System32\drivers\tp05.sys
tp06 | CoB | C:\Windows\System32\drivers\tp06.sys
tp07 | CoB | C:\Windows\System32\drivers\tp07.sys
tp08 | CoB | C:\Windows\System32\drivers\tp08.sys
tp09 | CoC | C:\Windows\System32\drivers\tp09.sys
tp10 | CoC | C:\Windows\System32\drivers\tp10.sys
tp11 | CoC | C:\Windows\System32\drivers\tp11.sys
tp12 | CoC | C:\Windows\System32\drivers\tp12.sys
tp13 | CoD | C:\Windows\System32\drivers\tp13.sys
tp14 | CoD | C:\Windows\System32\drivers\tp14.sys
tp15 | CoD | C:\Windows\System32\drivers\tp15.sys
tp16 | CoD | C:\Windows\System32\drivers\tp16.sys
tp17 | CoE | C:\Windows\System32\drivers\tp17.sys
tp18 | CoE | C:\Windows\System32\drivers\tp18.sys
tp19 | CoE | C:\Windows\System32\drivers\tp19.sys
tp20 | CoE | C:\Windows\System32\drivers\tp20.sys
'@ },
    @{ check = 'dv_thirdparty_inventory'; note = '8 个(健康)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '8 个'
       mock = @'
ok01 | CoA | C:\Windows\System32\drivers\ok01.sys
ok02 | CoA | C:\Windows\System32\drivers\ok02.sys
ok03 | CoA | C:\Windows\System32\drivers\ok03.sys
ok04 | CoB | C:\Windows\System32\drivers\ok04.sys
ok05 | CoB | C:\Windows\System32\drivers\ok05.sys
ok06 | CoC | C:\Windows\System32\drivers\ok06.sys
ok07 | CoC | C:\Windows\System32\drivers\ok07.sys
ok08 | CoC | C:\Windows\System32\drivers\ok08.sys
'@ },
    @{ check = 'dv_thirdparty_inventory'; note = '枚举失败(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 31. dv_network_filters ----------
    @{ check = 'dv_network_filters'; note = '4 层第三方+2 行 ms_ 干扰(微软前缀豁免)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'nnndisfilter'; expectSuggestionKeyword = '过滤'
       mock = @'
nnndisfilter | 示例 NDIS 过滤 | True
360Firewall | 360 网络过滤 | True
xxproxy | XX 代理过滤 | True
vNano | 虚拟网卡 | True
ms_tcpip | TCP/IPv4 | True
ms_msclient | 网络客户端 | True
'@ },
    @{ check = 'dv_network_filters'; note = '1 层示例+名单注入(PASS 附注点名)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '某加速器'
       mock = @'
nnndisfilter | 示例 NDIS 过滤 | True
ms_tcpip | TCP/IPv4 | True
offfilter | 已停用的过滤 | False
'@
       mockSuspectsJson = '{"suspects":[{"pattern":"nnndisfilter","label":"某加速器捆绑的 NDIS 网络过滤驱动(测试)","advice":"卸载该加速器本体。回滚：重装即可"}]}' },
    @{ check = 'dv_network_filters'; note = '仅 ms_ 行(0 层)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '0 层'
       mock = @'
ms_tcpip | TCP/IPv4 | True
ms_msclient | 网络客户端 | True
ms_server | Microsoft 网络文件和打印机共享 | True
'@ },
    @{ check = 'dv_network_filters'; note = 'cmdlet 缺失(精简系统 SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
NO-CMDLET
'@ },

    # ---------- 32. dv_device_errors ----------
    @{ check = 'dv_device_errors'; note = 'Code28+Code43 两台(黄三角)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'Code 28'; expectSuggestionKeyword = '设备管理器'
       mock = @'
未知 USB 设备 | 28
USB 大容量存储设备 | 43
Intel(R) Wi-Fi 6 AX201 | 0
'@ },
    @{ check = 'dv_device_errors'; note = '仅 22+45 软码(非故障)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '非故障'
       mock = @'
已禁用摄像头 | 22
残留蓝牙设备 | 45
正常声卡 | 0
'@ },
    @{ check = 'dv_device_errors'; note = '全 0(设备全正常)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '全部正常'
       mock = @'
Intel(R) Wi-Fi 6 AX201 | 0
标准 NVM Express 控制器 | 0
'@ },
    @{ check = 'dv_device_errors'; note = '未收录码 37(显码号+指引属性页)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '详见设备管理器属性页'; expectSuggestionKeyword = '设备管理器'
       mock = @'
某未知设备 | 37
'@ },
    @{ check = 'dv_device_errors'; note = '枚举失败(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 33. dv_driver_load_failures ----------
    @{ check = 'dv_driver_load_failures'; note = '同路径×3+异路径×1(反复加载失败)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '反复'; expectSuggestionKeyword = '残留'
       mock = @'
USB\VID_1234&PID_5678\0001
USB\VID_1234&PID_5678\0001
USB\VID_1234&PID_5678\0001
ROOT\XXSYS\0000
'@ },
    @{ check = 'dv_driver_load_failures'; note = '1 条(瞬时插拔 PASS 附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '1 条'
       mock = @'
USB\VID_9999&PID_8888\0001
'@ },
    @{ check = 'dv_driver_load_failures'; note = '0 条'
       expectStatus = 'PASS'; expectEvidenceKeyword = '0 条'
       mock = @'
'@ },
    @{ check = 'dv_driver_load_failures'; note = 'System 日志不可读(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 34. pf_app_crashes（v1.1.0 应用崩溃） ----------
    @{ check = 'pf_app_crashes'; note = '0 次(应用都稳定)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '0 次'
       mock = '' },
    @{ check = 'pf_app_crashes'; note = '同一应用崩 2 次(点名)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'chrome.exe'; expectSuggestionKeyword = '更新'
       mock = @'
1000 | chrome.exe | 2026-10-20 10:00
1002 | chrome.exe | 2026-10-21 11:00
'@ },
    @{ check = 'pf_app_crashes'; note = '3 个应用各 1 次(系统性)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '共 3 次'; expectSuggestionKeyword = '内存'
       mock = @'
1000 | a.exe | 2026-10-20 10:00
1000 | b.exe | 2026-10-20 11:00
1002 | c.exe | 2026-10-20 12:00
'@ },
    @{ check = 'pf_app_crashes'; note = 'Application 日志不可读(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 35. hw_disk_errors（v1.1.0 文件系统错误） ----------
    @{ check = 'hw_disk_errors'; note = '0 条(文件系统正常)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '0 条'
       mock = '' },
    @{ check = 'hw_disk_errors'; note = 'NTFS 55(结构损坏信号)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '55'; expectSuggestionKeyword = 'chkdsk'
       mock = @'
55 | C: | 2026-10-20 10:00
'@ },
    @{ check = 'hw_disk_errors'; note = '153×2(偶发延迟 PASS 附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '153 少量'
       mock = @'
153 | C: | 2026-10-20 10:00
153 | C: | 2026-10-21 10:00
'@ },
    @{ check = 'hw_disk_errors'; note = '153×3(长期写延迟)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '153'; expectSuggestionKeyword = 'chkdsk'
       mock = @'
153 | C: | 2026-10-20 10:00
153 | C: | 2026-10-21 10:00
153 | C: | 2026-10-22 10:00
'@ },
    @{ check = 'hw_disk_errors'; note = 'System 日志不可读(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 36. net_proxy_vpn（v1.1.0 应用层） ----------
    @{ check = 'net_proxy_vpn'; note = '代理关+hosts 净(干净)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '未启用'
       mock = @'
PROXY | 0 | |
HOSTS | 0
ADAPTER | WLAN | Intel(R) Wi-Fi 6 AX201 | Up | False
'@ },
    @{ check = 'net_proxy_vpn'; note = '系统代理开启(点名)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '系统代理'; expectSuggestionKeyword = 'netsh winhttp reset proxy'
       mock = @'
PROXY | 1 | 127.0.0.1:7890 |
HOSTS | 0
'@ },
    @{ check = 'net_proxy_vpn'; note = 'hosts 有自定义条目'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'hosts'; expectSuggestionKeyword = 'hosts'
       mock = @'
PROXY | 0 | |
HOSTS | 2
ADAPTER | WLAN | Intel(R) Wi-Fi 6 AX201 | Up | False
'@ },
    @{ check = 'net_proxy_vpn'; note = '只有 VPN 连上(只提示不算故障)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '虚拟网卡'
       mock = @'
PROXY | 0 | |
HOSTS | 0
ADAPTER | OpenVPN TAP | TAP-Windows Adapter V9 | Up | True
'@ },
    @{ check = 'net_proxy_vpn'; note = '读取失败(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 37. net_proxy_system（v1.2.0 片4 优先项①：系统级代理 WinHTTP+WinINET 双通道） ----------
    @{ check = 'net_proxy_system'; note = 'WinHTTP 直连+WinINET 关(干净)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '直接访问'
       mock = @'
WINHTTP | DIRECT
WININET | 0 | |
'@ },
    @{ check = 'net_proxy_system'; note = 'WinHTTP 被设代理(服务级残留，软件退了还在)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'WinHTTP'; expectSuggestionKeyword = 'winhttp reset proxy'
       mock = @'
WINHTTP | PROXY | 127.0.0.1:7890
WININET | 0 | |
'@ },
    @{ check = 'net_proxy_system'; note = 'WinINET 用户代理开启(带 PAC 脚本)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'PAC'; expectSuggestionKeyword = '代理'
       mock = @'
WINHTTP | DIRECT
WININET | 1 | 127.0.0.1:7890 | http://pac.example.com/pac
'@ },
    @{ check = 'net_proxy_system'; note = '读取失败(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 38. net_tcp_port（v1.2.0 片4：端口级连通，ICMP 不通时的权威替代） ----------
    @{ check = 'net_tcp_port'; note = '443 端口通(TCP 级连通)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '113.108.81.189'
       mock = @'
RESOLVED | 113.108.81.189
TCP | 443 | True
'@ },
    @{ check = 'net_tcp_port'; note = '解析成功但 443 连不上(端口级实锤)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '443'; expectSuggestionKeyword = '端口'
       mock = @'
RESOLVED | 113.108.81.189
TCP | 443 | False
'@ },
    @{ check = 'net_tcp_port'; note = '域名解不出(问题更可能在 DNS 层→不冤枉 WAN)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = 'DNS'
       mock = @'
RESOLVED | NONE
TCP | 443 | False
'@ },
    @{ check = 'net_tcp_port'; note = '查询失败(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 39. net_df_ping（v1.2.0 片4：DF 大包探测，PMTUD 黑洞） ----------
    @{ check = 'net_df_ping'; note = '1472 大包通(路径 MTU>=1500)'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'TTL=50'
       mock = @'
PING | REPLY | TTL=50
'@ },
    @{ check = 'net_df_ping'; note = '中途回需要分片(MTU 不匹配实锤)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = 'MTU'; expectSuggestionKeyword = '1492'
       mock = @'
PING | NEED-FRAG
'@ },
    @{ check = 'net_df_ping'; note = '大包超时(PMTUD 黑洞嫌疑)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '黑洞'; expectSuggestionKeyword = 'MTU'
       mock = @'
PING | TIMEOUT
'@ },
    @{ check = 'net_df_ping'; note = '无数据(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
'@ },

    # ---------- 40. net_wlan_signal（v1.2.0 片4：Wi-Fi 信号质量） ----------
    @{ check = 'net_wlan_signal'; note = '信号 75%(良好)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '75'
       mock = @'
STATE | connected
SIGNAL | 75
'@ },
    @{ check = 'net_wlan_signal'; note = '信号 45%(偏弱 PASS 附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '偏弱'
       mock = @'
STATE | connected
SIGNAL | 45
'@ },
    @{ check = 'net_wlan_signal'; note = '信号 25%(弱信号)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '弱信号'; expectSuggestionKeyword = '路由器'
       mock = @'
STATE | connected
SIGNAL | 25
'@ },
    @{ check = 'net_wlan_signal'; note = '无 WLAN 网卡或未连 WiFi(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = 'WLAN'
       mock = @'
STATE | none
'@ },

    # ---------- 41. net_tcp_stall（v1.2.0 片4：TCP 连接停滞，双采样防瞬时误报） ----------
    @{ check = 'net_tcp_stall'; note = '双样本停滞 8/7(连接持续发不出去)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '停滞'; expectSuggestionKeyword = '代理'
       mock = @'
SAMPLE | SYN_SENT | 5 | SYN_RCVD | 3
===SAMPLE===
SAMPLE | SYN_SENT | 7 | SYN_RCVD | 0
'@ },
    @{ check = 'net_tcp_stall'; note = '单样本 7→0(瞬时高峰 PASS 附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '瞬时'
       mock = @'
SAMPLE | SYN_SENT | 7 | SYN_RCVD | 0
===SAMPLE===
SAMPLE | SYN_SENT | 0 | SYN_RCVD | 0
'@ },
    @{ check = 'net_tcp_stall'; note = '双样本全 0(无停滞)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '0'
       mock = @'
SAMPLE | SYN_SENT | 0 | SYN_RCVD | 0
===SAMPLE===
SAMPLE | SYN_SENT | 0 | SYN_RCVD | 0
'@ },
    @{ check = 'net_tcp_stall'; note = 'netstat 不可用(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
QUERY-ERROR
'@ },

    # ---------- 42. pf_uptime（v1.2.0 片4：连续开机时长） ----------
    @{ check = 'pf_uptime'; note = '连续开机 45.2 天(超 30 天警戒线)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '45.2'; expectSuggestionKeyword = '重启'
       mock = @'
45.2
'@ },
    @{ check = 'pf_uptime'; note = '连续开机 12 天(正常)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '12'
       mock = @'
12
'@ },
    @{ check = 'pf_uptime'; note = '开机半天内(健康)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '0.5'
       mock = @'
0.5
'@ },
    @{ check = 'pf_uptime'; note = '查不到开机时间(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '查不到'
       mock = @'
'@ }
    # ---------- sec_defender_status（规格第三节 #1） ----------
    @{ check = 'sec_defender_status'; note = '全开+病毒库当天更新(实测样例)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '实时保护: True'
       expectExtraEvidenceKeywords = @('0 天')
       mock = @'
AMRunningMode=Normal
AntivirusEnabled=True
RealTimeProtectionEnabled=True
AntivirusSignatureAge=0
AntivirusSignatureLastUpdated=2026/10/25 0:31:48
'@ },
    @{ check = 'sec_defender_status'; note = '实时保护被关(负例)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '实时保护'
       expectExtraEvidenceKeywords = @('结论：')
       mock = @'
AMRunningMode=Normal
AntivirusEnabled=True
RealTimeProtectionEnabled=False
AntivirusSignatureAge=0
AntivirusSignatureLastUpdated=2026/10/25 0:31:48
'@ },
    @{ check = 'sec_defender_status'; note = '病毒库9天未更新(负例,超7天工程线,结论行含超期天数)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '7 天'
       expectExtraEvidenceKeywords = @('9')
       mock = @'
AMRunningMode=Normal
AntivirusEnabled=True
RealTimeProtectionEnabled=True
AntivirusSignatureAge=9
AntivirusSignatureLastUpdated=2026/10/16 0:31:48
'@ },
    @{ check = 'sec_defender_status'; note = '病毒库5天未更新(PASS附注建议尽快更新)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '已 5 天未更新'
       mock = @'
AMRunningMode=Normal
AntivirusEnabled=True
RealTimeProtectionEnabled=True
AntivirusSignatureAge=5
AntivirusSignatureLastUpdated=2026/10/20 0:31:48
'@ },
    @{ check = 'sec_defender_status'; note = '第三方杀软接管Passive Mode(SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '第三方杀软'
       mock = @'
AMRunningMode=Passive Mode
AntivirusEnabled=True
RealTimeProtectionEnabled=True
AntivirusSignatureAge=0
AntivirusSignatureLastUpdated=2026/10/25 0:31:48
'@ },

    # ---------- sec_defender_exclusions（规格第三节 #2） ----------
    @{ check = 'sec_defender_exclusions'; note = '占位文本(标准用户实测原文,SKIP admin-required)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = 'Must be an administrator'
       expectSuggestionKeyword = '人工路径'
       mock = @'
ExclusionPath=N/A: Must be an administrator to view exclusions
ExclusionExtension=N/A: Must be an administrator to view exclusions
ExclusionProcess=N/A: Must be an administrator to view exclusions
ExclusionIpAddress=N/A: Must be an administrator to view exclusions
'@ },
    @{ check = 'sec_defender_exclusions'; note = '四清单全空(无排除项)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '（无）'
       expectExtraEvidenceKeywords = @('无排除项')
       mock = @'
ExclusionPath=
ExclusionExtension=
ExclusionProcess=
ExclusionIpAddress=
'@ },
    @{ check = 'sec_defender_exclusions'; note = '有排除路径+排除进程(负例,查杀盲区)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '排除路径(1)'
       expectExtraEvidenceKeywords = @('D:\dev\projects', '盲区')
       mock = @'
ExclusionPath=D:\dev\projects
ExclusionExtension=
ExclusionProcess=cpu_z.exe
ExclusionIpAddress=
'@ },

    # ---------- sec_defender_threats（规格第三节 #3） ----------
    @{ check = 'sec_defender_threats'; note = '空输入(0事件,近30天无检出)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '近 30 天无任何检出'
       mock = @'
'@ },
    @{ check = 'sec_defender_threats'; note = '1116检出+1117隔离(实测样例,处置齐=PASS附清单)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '检出 1 次'
       expectExtraEvidenceKeywords = @('Contebrew', '隔离')
       mock = @'
2026/10/25 15:06:03 | 1116 | Name=Program:Win32/Contebrew.A!ml | Severity=高 | Path=file:_D:\gost\gost.exe | Action=
2026/10/25 15:06:12 | 1117 | Name=Program:Win32/Contebrew.A!ml | Severity=高 | Path=file:_D:\gost\gost.exe | Action=隔离
'@ },
    @{ check = 'sec_defender_threats'; note = '1116两条+1117一条(有检出无对应处置,负例)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '无对应处置'
       mock = @'
2026/10/25 15:06:03 | 1116 | Name=Program:Win32/Contebrew.A!ml | Severity=高 | Path=file:_D:\gost\gost.exe | Action=
2026/10/25 15:07:00 | 1116 | Name=Trojan:Win32/Wacatac.B!ml | Severity=严重 | Path=file:_C:\Users\test\payload.exe | Action=
2026/10/25 15:07:30 | 1117 | Name=Trojan:Win32/Wacatac.B!ml | Severity=严重 | Path=file:_C:\Users\test\payload.exe | Action=隔离
'@ },
    @{ check = 'sec_defender_threats'; note = '含1118处置失败(负例)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '处置失败'
       mock = @'
2026/10/25 15:06:03 | 1116 | Name=Program:Win32/Contebrew.A!ml | Severity=高 | Path=file:_D:\gost\gost.exe | Action=
2026/10/25 15:06:12 | 1118 | Name=Program:Win32/Contebrew.A!ml | Severity=高 | Path=file:_D:\gost\gost.exe | Action=
'@ },

    # ---------- sec_defender_service（规格第三节 #4） ----------
    @{ check = 'sec_defender_service'; note = '五服务全Running(实测样例)'
       expectStatus = 'PASS'; expectEvidenceKeyword = 'WinDefend): Running'
       mock = @'
WinDefend | Running | Automatic
WdNisSvc | Running | Manual
WdNisDrv | Running | Manual
SecurityHealthService | Running | Manual
wscsvc | Running | Automatic
'@ },
    @{ check = 'sec_defender_service'; note = 'WinDefend停止(核心服务停摆,负例)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '停摆'
       expectExtraEvidenceKeywords = @('WinDefend')
       expectSuggestionKeyword = '没有在跑'
       mock = @'
WinDefend | Stopped | Automatic
WdNisSvc | Running | Manual
WdNisDrv | Running | Manual
SecurityHealthService | Running | Manual
wscsvc | Running | Automatic
'@ },
    @{ check = 'sec_defender_service'; note = '仅安全中心界面服务停止(PASS附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '安全中心界面服务未运行'
       mock = @'
WinDefend | Running | Automatic
WdNisSvc | Running | Manual
WdNisDrv | Running | Manual
SecurityHealthService | Stopped | Manual
wscsvc | Running | Automatic
'@ },
    @{ check = 'sec_defender_service'; note = 'WinDefend不存在(非Defender环境,SKIP)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '非 Defender 环境'
       mock = @'
WinDefend | MISSING |
'@ },

    # ---------- sec_uac_level（规格第三节 #5） ----------
    @{ check = 'sec_uac_level'; note = '从不通知档(本机实测样例,负例:静默提权)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '从不通知'
       expectExtraEvidenceKeywords = @('静默提权')
       mock = @'
EnableLUA=1
ConsentPromptBehaviorAdmin=0
PromptOnSecureDesktop=0
'@ },
    @{ check = 'sec_uac_level'; note = '官方默认档(CPBA=5+安全桌面开)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '默认'
       mock = @'
EnableLUA=1
ConsentPromptBehaviorAdmin=5
PromptOnSecureDesktop=1
'@ },
    @{ check = 'sec_uac_level'; note = 'EnableLUA=0(UAC整体禁用,负例)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '整体禁用'
       mock = @'
EnableLUA=0
ConsentPromptBehaviorAdmin=5
PromptOnSecureDesktop=1
'@ },
    @{ check = 'sec_uac_level'; note = '第四档+提词不经安全桌面(PASS附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '提词不经安全桌面'
       mock = @'
EnableLUA=1
ConsentPromptBehaviorAdmin=4
PromptOnSecureDesktop=0
'@ },

    # ---------- sec_firewall_profiles（规格第三节 #6） ----------
    @{ check = 'sec_firewall_profiles'; note = '三配置文件全开(实测样例)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '公用网络(Public): 开'
       mock = @'
Domain | True | NotConfigured | NotConfigured
Private | True | NotConfigured | NotConfigured
Public | True | NotConfigured | NotConfigured
'@ },
    @{ check = 'sec_firewall_profiles'; note = 'Public被关(负例:公用网络不设防)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '公用网络(Public): 关'
       expectExtraEvidenceKeywords = @('不设防')
       mock = @'
Domain | True | NotConfigured | NotConfigured
Private | True | NotConfigured | NotConfigured
Public | False | NotConfigured | NotConfigured
'@ },
    @{ check = 'sec_firewall_profiles'; note = '三开+出站默认拦截(PASS附注罕见加固态)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '出站默认拦截'
       mock = @'
Domain | True | NotConfigured | Block
Private | True | NotConfigured | Block
Public | True | NotConfigured | Block
'@ },

    # ---------- sec_bitlocker（规格第三节 #7 + 1 补充边界） ----------
    @{ check = 'sec_bitlocker'; note = '拒绝访问(标准用户实测原文,SKIP admin-required)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = '管理员权限'
       expectExtraEvidenceKeywords = @('看不到≠没加密')
       expectSuggestionKeyword = '人工路径'
       mock = @'
ERROR: 拒绝访问
'@ },
    @{ check = 'sec_bitlocker'; note = '系统卷FullyDecrypted(负例:未加密裸奔)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '未加密'
       expectExtraEvidenceKeywords = @('裸奔')
       mock = @'
C: | OperatingSystem | FullyDecrypted | Off | 0
D: | Data | FullyEncrypted | On | 100
'@ },
    @{ check = 'sec_bitlocker'; note = '系统卷FullyEncrypted+保护On'
       expectStatus = 'PASS'; expectEvidenceKeyword = '保护: On'
       mock = @'
C: | OperatingSystem | FullyEncrypted | On | 100
D: | Data | FullyEncrypted | On | 100
'@ },
    @{ check = 'sec_bitlocker'; note = '系统卷FullyEncrypted但保护Off(补充边界:挂起态PASS附注)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '挂起态'
       mock = @'
C: | OperatingSystem | FullyEncrypted | Off | 100
'@ },

    # ---------- sec_suspicious_tasks（规格第三节 #8 + 1 补充英文表头） ----------
    @{ check = 'sec_suspicious_tasks'; note = '1可疑(非系统盘脚本)+1正常+1微软(负例,实测样例)'
       expectStatus = 'FAIL'; expectEvidenceKeyword = '[可疑]'
       expectExtraEvidenceKeywords = @('MySync-Update-Check')
       expectSuggestionKeyword = '人工路径'
       mock = @'
"主机名","任务名","下次运行时间","模式","登录状态","上次运行时间","上次结果","创建者","要运行的任务","起始于"
"DESKTOP-X","\MySync-Update-Check","2026/10/26 8:00","就绪","已登录","2026/10/25 8:00","0","","powershell -NoProfile -File ""D:\MySync\mysync-update.ps1""",""
"DESKTOP-X","\MSIAfterburner","2026/10/26 9:00","就绪","已登录","2026/10/25 9:00","0","","C:\Program Files (x86)\MSI Afterburner\MSIAfterburner.exe /s",""
"DESKTOP-X","\Microsoft\Windows\Chkdsk\ProactiveScan","N/A","就绪","已登录","2026/10/20 3:00","0","","C:\Windows\System32\svchost.exe",""
'@ },
    @{ check = 'sec_suspicious_tasks'; note = '仅Program Files第三方任务(全部系统只读目录)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '系统只读目录'
       mock = @'
"主机名","任务名","下次运行时间","模式","登录状态","上次运行时间","上次结果","创建者","要运行的任务","起始于"
"DESKTOP-X","\MSIAfterburner","2026/10/26 9:00","就绪","已登录","2026/10/25 9:00","0","","C:\Program Files (x86)\MSI Afterburner\MSIAfterburner.exe /s",""
"DESKTOP-X","\Microsoft\Windows\Chkdsk\ProactiveScan","N/A","就绪","已登录","2026/10/20 3:00","0","","C:\Windows\System32\svchost.exe",""
'@ },
    @{ check = 'sec_suspicious_tasks'; note = '仅\Microsoft\任务(第三方0条)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '第三方任务 0 条'
       mock = @'
"主机名","任务名","下次运行时间","模式","登录状态","上次运行时间","上次结果","创建者","要运行的任务","起始于"
"DESKTOP-X","\Microsoft\Windows\Chkdsk\ProactiveScan","N/A","就绪","已登录","2026/10/20 3:00","0","","C:\Windows\System32\svchost.exe",""
'@ },
    @{ check = 'sec_suspicious_tasks'; note = '乱表头(中英都定位不到,SKIP unknown-locale)'
       expectStatus = 'SKIP'; expectEvidenceKeyword = 'unknown-locale'
       mock = @'
"Foo","Bar"
"x","y"
'@ },
    @{ check = 'sec_suspicious_tasks'; note = '英文表头(补充边界:TaskName/Task To Run 动态定位)'
       expectStatus = 'PASS'; expectEvidenceKeyword = '系统只读目录'
       mock = @'
"HostName","TaskName","Next Run Time","Status","Logon Mode","Last Run Time","Last Result","Author","Task To Run","Start In"
"DESKTOP-X","\MSIAfterburner","2026/10/26 9:00","Ready","LoggedIn","2026/10/25 9:00","0","","C:\Program Files (x86)\MSI Afterburner\MSIAfterburner.exe /s",""
'@ }
)
