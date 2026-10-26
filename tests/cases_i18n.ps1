#Requires -Version 5.1
<#
tests/cases_i18n.ps1 -- en-US suggestions template static checks (1026 Plan B, M1 skeleton + M2 full run)
Per case: run the REAL check script with a FAIL mock, take the LIVE detail object, then
  (1) en-US.js suggestions.<tplKey> template exists as a single-line quoted value;
  (2) placeholder set of the template == declared set. Declaration = the variables the
      app.js adapter (sugVars/enSuggestion) produces for that key: direct detail fields
      keep the field name (warnCount); derived vars (deadList/avgSec) name the dynamic
      value the zh suggestion interpolates, and their source fields are pinned below;
  (3) every detailSources entry exists in the LIVE detail object (run output, not docs);
  (4) template carries the fix-action keywords (command / manual path / rollback label).
Mock source: either an inline mock (M1 samples) or mockFrom = 'note fragment' that picks
  the matching FAIL case from cases.ps1 (added in run_tests.ps1 section 7, M2).
Suite-wide guards (in run_tests.ps1 section 7):
  (5) zh-CN.js must NOT gain a suggestions table (zh = engine original, no double layer);
  (6) every key inside the en-US.js suggestions block maps to a real checks/<id>.ps1
      after stripping a registered variant suffix.
File carries a UTF-8 BOM (required: Chinese mockFrom fragments;
  PS 5.1 reads BOM-less files as GBK, craft rule 1013).
#>
$global:DiagI18nCases = @(
    # ---------- M1 samples (1026 skeleton, inline mocks) ----------
    @{ name = 'i18n_sug_deadaddr'; check = 'net_dns_deadaddr'
       mock = "Configuration for interface `"WLAN`"`n    Statically Configured DNS Servers:    192.168.137.1`n    Register with which suffix:           Primary only`n===PART===`nConfiguration for interface `"WLAN`"`n    DHCP enabled:                         Yes`n    IP Address:                           192.168.1.108`n    Subnet Prefix:                        192.168.1.0/24 (mask 255.255.255.0)"
       tplKey = 'net_dns_deadaddr'
       placeholders = @('deadList'); detailSources = @('findings')
       keywords = @('netsh interface ip set dns', '223.5.5.5', '[Rollback]') },
    @{ name = 'i18n_sug_uac'; check = 'sec_uac_level'
       mock = "EnableLUA=1`nConsentPromptBehaviorAdmin=0`nPromptOnSecureDesktop=0"
       tplKey = 'sec_uac_level'
       placeholders = @(); detailSources = @('enableLUA', 'consentPromptBehaviorAdmin', 'promptOnSecureDesktop', 'level')
       keywords = @('useraccountcontrolsettings', '[Manual path]', '[Rollback]') },
    @{ name = 'i18n_sug_boot_marks'; check = 'pf_boot_duration'
       mock = "10-20 | Warning | 95300`n10-19 | Warning | 88210`n10-18 | Information | 41200"
       tplKey = 'pf_boot_duration_marks'
       placeholders = @('warnCount'); detailSources = @('warnCount', 'avgMs')
       keywords = @('Ctrl+Shift+Esc', '[Rollback]') },
    @{ name = 'i18n_sug_boot_avg'; check = 'pf_boot_duration'
       mock = "10-20 | Information | 78000`n10-19 | Information | 72000"
       tplKey = 'pf_boot_duration_avg'
       placeholders = @('avgSec'); detailSources = @('avgMs')
       keywords = @('60-second', 'Task Manager') },

    # ---------- M2 full run: network tree (mockFrom = cases.ps1 note fragment) ----------
    @{ name = 'i18n_sug_adapter'; check = 'net_adapter_list'
       mockFrom = '全部断开'
       tplKey = 'net_adapter_list'
       placeholders = @(); detailSources = @('connected', 'disconnected')
       keywords = @('netsh interface set interface', '[Rollback]') },
    @{ name = 'i18n_sug_dhcp'; check = 'net_ip_dhcp'
       mockFrom = 'APIPA'
       tplKey = 'net_ip_dhcp'
       placeholders = @(); detailSources = @('good', 'bad')
       keywords = @('ipconfig /release', 'ipconfig /renew') },
    @{ name = 'i18n_sug_gwconf_conflict'; check = 'net_gateway_conflict'
       mockFrom = '双默认网关同跃点'
       tplKey = 'net_gateway_conflict_conflict'
       placeholders = @('gwCount', 'gwList'); detailSources = @('routes', 'why')
       keywords = @('route delete 0.0.0.0 mask 0.0.0.0', 'metric=100') },
    @{ name = 'i18n_sug_gwconf_noroute'; check = 'net_gateway_conflict'
       mockFrom = '无默认路由'
       tplKey = 'net_gateway_conflict_noroute'
       placeholders = @(); detailSources = @('routes', 'why')
       keywords = @('ipconfig /renew', '[Rollback]') },
    @{ name = 'i18n_sug_gwconf_xnet'; check = 'net_gateway_conflict'
       mockFrom = '网关跨网段'
       tplKey = 'net_gateway_conflict_xnet'
       placeholders = @('gw', 'subnet'); detailSources = @('routes', 'why')
       keywords = @('netsh interface ip set address', 'dhcp') },
    @{ name = 'i18n_sug_gwping'; check = 'net_gateway_ping'
       mockFrom = '网关 ping 超时'
       tplKey = 'net_gateway_ping'
       placeholders = @(); detailSources = @('gateways')
       keywords = @('nslookup qq.com', '[Try the risk-free step first]') },
    @{ name = 'i18n_sug_dnsdef_timeout'; check = 'net_dns_default'
       mockFrom = '默认DNS超时'
       tplKey = 'net_dns_default_timeout'
       placeholders = @(); detailSources = @('mode', 'server')
       keywords = @('netsh interface ip set dns', '223.5.5.5') },
    @{ name = 'i18n_sug_dnsdef_nxdomain'; check = 'net_dns_default'
       mockFrom = 'NXDOMAIN'
       tplKey = 'net_dns_default_nxdomain'
       placeholders = @(); detailSources = @('mode', 'server')
       keywords = @('ipconfig /flushdns', 'Alibaba Public DNS') },
    @{ name = 'i18n_sug_dnsdef_refused'; check = 'net_dns_default'
       mockFrom = '拒绝应答'
       tplKey = 'net_dns_default_refused'
       placeholders = @(); detailSources = @('mode', 'server')
       keywords = @('netsh interface ip set dns', '[Rollback]') },
    @{ name = 'i18n_sug_dnsgwproxy'; check = 'net_dns_gateway_proxy'
       mockFrom = '网关不响应DNS'
       tplKey = 'net_dns_gateway_proxy'
       placeholders = @(); detailSources = @('probes')
       keywords = @('netsh interface ip set dns', '223.5.5.5') },
    @{ name = 'i18n_sug_dnspublic'; check = 'net_dns_public'
       mockFrom = '公共DNS超时'
       tplKey = 'net_dns_public'
       placeholders = @(); detailSources = @('mode', 'server')
       keywords = @('119.29.29.29', 'nslookup qq.com') },
    @{ name = 'i18n_sug_pubping'; check = 'net_public_ping'
       mockFrom = '公网ping全不通'
       tplKey = 'net_public_ping'
       placeholders = @(); detailSources = @('sources')
       keywords = @('10000', 'LOS') },
    @{ name = 'i18n_sug_proxyvpn_proxy'; check = 'net_proxy_vpn'
       mockFrom = '系统代理开启'
       tplKey = 'net_proxy_vpn_proxy'
       placeholders = @(); detailSources = @('proxyEnabled', 'hostsCount')
       keywords = @('netsh winhttp reset proxy', 'hosts') },
    @{ name = 'i18n_sug_proxyvpn_hosts'; check = 'net_proxy_vpn'
       mockFrom = 'hosts 有自定义条目'
       tplKey = 'net_proxy_vpn_hosts'
       placeholders = @('hostsCount'); detailSources = @('proxyEnabled', 'hostsCount')
       keywords = @('netsh winhttp reset proxy', '{hostsCount}') },
    @{ name = 'i18n_sug_proxysys_winhttp'; check = 'net_proxy_system'
       mockFrom = 'WinHTTP 被设代理'
       tplKey = 'net_proxy_system_winhttp'
       placeholders = @(); detailSources = @('winhttpMode', 'wininetOn')
       keywords = @('netsh winhttp reset proxy', 'netsh winhttp set proxy') },
    @{ name = 'i18n_sug_proxysys_wininet'; check = 'net_proxy_system'
       mockFrom = 'WinINET 用户代理开启'
       tplKey = 'net_proxy_system_wininet'
       placeholders = @(); detailSources = @('winhttpMode', 'wininetOn')
       keywords = @('Use a proxy server', 'Use a setup script') },
    @{ name = 'i18n_sug_tcpport'; check = 'net_tcp_port'
       mockFrom = '解析成功但 443 连不上'
       tplKey = 'net_tcp_port'
       placeholders = @(); detailSources = @('resolved', 'port', 'tcpOk')
       keywords = @('443', 'hotspot') },
    @{ name = 'i18n_sug_dfping_frag'; check = 'net_df_ping'
       mockFrom = '中途回需要分片'
       tplKey = 'net_df_ping_frag'
       placeholders = @(); detailSources = @('probe', 'size', 'result')
       keywords = @('1492', 'PMTUD') },
    @{ name = 'i18n_sug_dfping_blackhole'; check = 'net_df_ping'
       mockFrom = '大包超时'
       tplKey = 'net_df_ping_blackhole'
       placeholders = @(); detailSources = @('probe', 'size', 'result')
       keywords = @('1492', '1480') },
    @{ name = 'i18n_sug_wlan'; check = 'net_wlan_signal'
       mockFrom = '信号 25%'
       tplKey = 'net_wlan_signal'
       placeholders = @(); detailSources = @('state', 'signal')
       keywords = @('5 GHz', '2.4 GHz') },
    @{ name = 'i18n_sug_tcpstall'; check = 'net_tcp_stall'
       mockFrom = '双样本停滞 8/7'
       tplKey = 'net_tcp_stall'
       placeholders = @(); detailSources = @('sample1', 'sample2')
       keywords = @('proxy', 'filter') },

    # ---------- M2: bluescreen tree ----------
    @{ name = 'i18n_sug_bshist'; check = 'bs_event_history'
       mockFrom = '3次0x139蓝屏史'
       tplKey = 'bs_event_history'
       placeholders = @('count'); detailSources = @('records', 'count')
       keywords = @('WER 1001', '[Rollback]') },
    @{ name = 'i18n_sug_bscode_known'; check = 'bs_code_frequency'
       mockFrom = '0x139×3慢性病'
       tplKey = 'bs_code_frequency_known'
       placeholders = @('code', 'count', 'fullName', 'url'); detailSources = @('distribution', 'note')
       keywords = @('{url}', 'mdsched.exe') },
    @{ name = 'i18n_sug_bscode_unknown'; check = 'bs_code_frequency'
       mockFrom = '陌生码0xABC'
       tplKey = 'bs_code_frequency_unknown'
       placeholders = @('code', 'count'); detailSources = @('distribution', 'note')
       keywords = @('learn.microsoft.com', 'mdsched.exe') },
    @{ name = 'i18n_sug_powerloss'; check = 'bs_powerloss_distinction'
       mockFrom = '41×3全孤立'
       tplKey = 'bs_powerloss_distinction'
       placeholders = @('total41'); detailSources = @('total41', 'total1001', 'isolated41')
       keywords = @('powercfg /batteryreport', 'Kernel-Power 41') },
    @{ name = 'i18n_sug_whea'; check = 'bs_whea_hardware'
       mockFrom = '1条WHEA'
       tplKey = 'bs_whea_hardware'
       placeholders = @('count'); detailSources = @('items', 'count')
       keywords = @('mdsched.exe', 'WHEA') },
    @{ name = 'i18n_sug_suspect_drv'; check = 'bs_suspect_drivers'
       mockFrom = 'nnndisfilter Running'
       tplKey = 'bs_suspect_drivers'
       placeholders = @('labels'); detailSources = @('hits', 'scanned')
       keywords = @('Settings → Apps', '[Rollback]') },

    # ---------- M2: hardware tree ----------
    @{ name = 'i18n_sug_diskhealth'; check = 'hw_disk_health'
       mockFrom = '一块盘Warning'
       tplKey = 'hw_disk_health'
       placeholders = @('badCount', 'badList'); detailSources = @('disks', 'badCount')
       keywords = @('chkdsk <drive>: /scan', 'CrystalDiskInfo') },
    @{ name = 'i18n_sug_smartpredict'; check = 'hw_smart_predict'
       mockFrom = 'SSD磨损25%'
       tplKey = 'hw_smart_predict'
       placeholders = @('alerts'); detailSources = @('rows', 'findings')
       keywords = @('{alerts}', 'CrystalDiskInfo') },
    @{ name = 'i18n_sug_battery'; check = 'hw_battery_wear'
       mockFrom = '损耗55%'
       tplKey = 'hw_battery_wear'
       placeholders = @('wearPct'); detailSources = @('designedMWh', 'wearPct')
       keywords = @('powercfg /batteryreport', '{wearPct}') },
    @{ name = 'i18n_sug_thermal'; check = 'hw_thermal'
       mockFrom = '热区85℃过热'
       tplKey = 'hw_thermal'
       placeholders = @('hotList'); detailSources = @('zones', 'maxC')
       keywords = @('{hotList}', 'HWiNFO') },
    @{ name = 'i18n_sug_memdiag'; check = 'hw_memdiag_history'
       mockFrom = '诊断报硬件问题1101'
       tplKey = 'hw_memdiag_history'
       placeholders = @('badCount'); detailSources = @('events', 'badCount')
       keywords = @('mdsched.exe', '{badCount}') },
    @{ name = 'i18n_sug_diskerrors'; check = 'hw_disk_errors'
       mockFrom = 'NTFS 55'
       tplKey = 'hw_disk_errors'
       placeholders = @('id55', 'id98', 'id153'); detailSources = @('total', 'id55', 'id98', 'id153')
       keywords = @('chkdsk C: /scan', 'chkdsk C: /f', '{id153}') },

    # ---------- M2: performance tree ----------
    @{ name = 'i18n_sug_bootdegrade'; check = 'pf_boot_degradation_events'
       mockFrom = '3条点名(101/103)'
       tplKey = 'pf_boot_degradation_events'
       placeholders = @('count'); detailSources = @('count', 'top')
       keywords = @('Startup apps', '{count}') },
    @{ name = 'i18n_sug_startup_over'; check = 'pf_startup_items'
       mockFrom = '25项超负担线'
       tplKey = 'pf_startup_items_overload'
       placeholders = @('total'); detailSources = @('total', 'hits', 'locations')
       keywords = @('Ctrl+Shift+Esc', '{total}') },
    @{ name = 'i18n_sug_startup_hit'; check = 'pf_startup_items'
       mockFrom = '注入名单命中'
       tplKey = 'pf_startup_items_hit'
       placeholders = @('hitList'); detailSources = @('total', 'hits', 'locations')
       keywords = @('{hitList}', 'Uninstall') },
    @{ name = 'i18n_sug_svctimeout'; check = 'pf_service_timeouts'
       mockFrom = '5条(7011×3+7000×2)'
       tplKey = 'pf_service_timeouts'
       placeholders = @('total'); detailSources = @('total', 'groups')
       keywords = @('{total}', 'Settings → Apps') },
    @{ name = 'i18n_sug_diskspace'; check = 'pf_disk_space'
       mockFrom = '系统盘4.7%'
       tplKey = 'pf_disk_space'
       placeholders = @('freeGB', 'pct'); detailSources = @('disks')
       keywords = @('Storage Sense', '{freeGB}') },
    @{ name = 'i18n_sug_mem_lowmem'; check = 'pf_memory_pressure'
       mockFrom = '物理2GB'
       tplKey = 'pf_memory_pressure_lowmem'
       placeholders = @('physicalGB'); detailSources = @('physicalGB', 'commitPct')
       keywords = @('{physicalGB}', '4GB') },
    @{ name = 'i18n_sug_mem_commit'; check = 'pf_memory_pressure'
       mockFrom = '16GB+commit95%'
       tplKey = 'pf_memory_pressure_commit'
       placeholders = @('commitPct'); detailSources = @('physicalGB', 'commitPct')
       keywords = @('{commitPct}', 'Committed') },
    @{ name = 'i18n_sug_disksat'; check = 'pf_disk_saturation'
       mockFrom = '双采样队列5/6'
       tplKey = 'pf_disk_saturation'
       placeholders = @('queueStr', 'avgStr'); detailSources = @('instance', 'queue', 'avgMs')
       keywords = @('{queueStr}', '{avgStr}') },
    @{ name = 'i18n_sug_appcrash'; check = 'pf_app_crashes'
       mockFrom = '同一应用崩 2 次'
       tplKey = 'pf_app_crashes'
       placeholders = @('total', 'apps'); detailSources = @('total', 'groups')
       keywords = @('{total}', '{apps}') },
    @{ name = 'i18n_sug_uptime'; check = 'pf_uptime'
       mockFrom = '连续开机 45.2 天'
       tplKey = 'pf_uptime'
       placeholders = @(); detailSources = @('days')
       keywords = @('Restart', '[Rollback]') },

    # ---------- M2: drivers tree ----------
    @{ name = 'i18n_sug_driversig'; check = 'dv_driver_signature'
       mockFrom = 'NotSigned 1 个'
       tplKey = 'dv_driver_signature'
       placeholders = @('badCount'); detailSources = @('running', 'bad', 'valid')
       keywords = @('{badCount}', 'Settings → Apps') },
    @{ name = 'i18n_sug_driverage'; check = 'dv_driver_age'
       mockFrom = '7 个 2013 年文件'
       tplKey = 'dv_driver_age'
       placeholders = @('old'); detailSources = @('old', 'total')
       keywords = @('{old}', 'Roll Back Driver') },
    @{ name = 'i18n_sug_drv3rd'; check = 'dv_thirdparty_inventory'
       mockFrom = '35 个非微软'
       tplKey = 'dv_thirdparty_inventory'
       placeholders = @('thirdParty'); detailSources = @('thirdParty', 'microsoft')
       keywords = @('{thirdParty}', 'Settings → Apps') },
    @{ name = 'i18n_sug_netfilter'; check = 'dv_network_filters'
       mockFrom = '4 层第三方'
       tplKey = 'dv_network_filters'
       placeholders = @('filters'); detailSources = @('filters', 'items')
       keywords = @('{filters}', 'ComponentID') },
    @{ name = 'i18n_sug_deverr_known'; check = 'dv_device_errors'
       mockFrom = 'Code28+Code43'
       tplKey = 'dv_device_errors_known'
       placeholders = @('errCount'); detailSources = @('total', 'errors', 'soft')
       keywords = @('{errCount}', 'Code 28') },
    @{ name = 'i18n_sug_deverr_other'; check = 'dv_device_errors'
       mockFrom = '未收录码 37'
       tplKey = 'dv_device_errors_other'
       placeholders = @('errCount'); detailSources = @('total', 'errors', 'soft')
       keywords = @('{errCount}', 'Device Manager') },
    @{ name = 'i18n_sug_drvloadfail'; check = 'dv_driver_load_failures'
       mockFrom = '同路径×3'
       tplKey = 'dv_driver_load_failures'
       placeholders = @('count', 'repeatPaths'); detailSources = @('count', 'top')
       keywords = @('{repeatPaths}', 'Show hidden devices') },

    # ---------- M2: security tree ----------
    @{ name = 'i18n_sug_defstatus'; check = 'sec_defender_status'
       mockFrom = '实时保护被关'
       tplKey = 'sec_defender_status'
       placeholders = @(); detailSources = @('mode', 'realtime', 'sigAgeDays')
       keywords = @('Real-time protection', '[Manual path]') },
    @{ name = 'i18n_sug_defexcl'; check = 'sec_defender_exclusions'
       mockFrom = '有排除路径'
       tplKey = 'sec_defender_exclusions'
       placeholders = @('exclCount'); detailSources = @('readable', 'paths', 'processes')
       keywords = @('{exclCount}', '[Manual path]') },
    @{ name = 'i18n_sug_defthreat'; check = 'sec_defender_threats'
       mockFrom = '1116两条'
       tplKey = 'sec_defender_threats'
       placeholders = @(); detailSources = @('detected', 'remediated', 'failed')
       keywords = @('Protection history', '[Manual path]') },
    @{ name = 'i18n_sug_defsvc'; check = 'sec_defender_service'
       mockFrom = 'WinDefend停止'
       tplKey = 'sec_defender_service'
       placeholders = @(); detailSources = @('services')
       keywords = @('services.msc', 'WinDefend') },
    @{ name = 'i18n_sug_firewall'; check = 'sec_firewall_profiles'
       mockFrom = 'Public被关'
       tplKey = 'sec_firewall_profiles'
       placeholders = @('offCount'); detailSources = @('profiles')
       keywords = @('{offCount}', 'wf.msc') },
    @{ name = 'i18n_sug_bitlocker'; check = 'sec_bitlocker'
       mockFrom = '系统卷FullyDecrypted'
       tplKey = 'sec_bitlocker'
       placeholders = @(); detailSources = @('readable', 'volumes')
       keywords = @('[Manual path]', 'recovery key') },
    @{ name = 'i18n_sug_susptask'; check = 'sec_suspicious_tasks'
       mockFrom = '1可疑'
       tplKey = 'sec_suspicious_tasks'
       placeholders = @('susCount'); detailSources = @('totalTasks', 'suspicious')
       keywords = @('{susCount}', '[Manual path]') }
)

# variant suffix registry: template keys = check_id + suffix when one check has multiple
# FAIL wordings (branch pick lives in app.js sugTplKey). Extend both together.
# M1: _marks/_avg (pf_boot_duration). M2 adds the rest (1026 full run).
$global:DiagI18nVariantSuffixes = @('_marks', '_avg',
    '_conflict', '_noroute', '_xnet',                                   # net_gateway_conflict
    '_timeout', '_nxdomain', '_refused',                                # net_dns_default
    '_known', '_unknown', '_other',                                               # bs_code_frequency, dv_device_errors
    '_overload', '_hit',                                                # pf_startup_items
    '_lowmem', '_commit',                                               # pf_memory_pressure
    '_proxy', '_hosts',                                                 # net_proxy_vpn
    '_winhttp', '_wininet',                                             # net_proxy_system
    '_frag', '_blackhole')                                              # net_df_ping
