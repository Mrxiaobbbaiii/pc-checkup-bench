#Requires -Version 5.1
<#
tests/cases_i18n.ps1 -- en-US suggestions template static checks (1026 Plan B / M1)
Per case: run the REAL check script with a FAIL mock, take the LIVE detail object, then
  (1) en-US.js suggestions.<tplKey> template exists as a single-line quoted value;
  (2) placeholder set of the template == declared set. Declaration = the variables the
      app.js adapter (sugVars/enSuggestion) produces for that key: direct detail fields
      keep the field name (warnCount); derived vars (deadList/avgSec) name the dynamic
      value the zh suggestion interpolates, and their source fields are pinned below;
  (3) every detailSources entry exists in the LIVE detail object (run output, not docs);
  (4) template carries the fix-action keywords (command / manual path / rollback label).
Suite-wide guards (in run_tests.ps1 section 7):
  (5) zh-CN.js must NOT gain a suggestions table (zh = engine original, no double layer);
  (6) every key inside the en-US.js suggestions block maps to a real checks/<id>.ps1
      after stripping a registered variant suffix.
ASCII-only file (PS 5.1 no-BOM hazard, craft rule 1013).
#>
$global:DiagI18nCases = @(
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
       keywords = @('60-second', 'Task Manager') }
)

# variant suffix registry: template keys = check_id + suffix when one check has multiple
# FAIL wordings (branch pick lives in app.js sugTplKey). Extend both together (M2+).
$global:DiagI18nVariantSuffixes = @('_marks', '_avg')
