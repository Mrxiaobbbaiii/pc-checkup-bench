# repair/recon/report_recon.ps1 (v1.8 disposition layer - recon script)
# READ-ONLY scout: resolves report-named services/drivers to owning software.
# Output: single-line JSON on stdout (ASCII labels; data may carry UTF-8 from file metadata).
# Called only via repair.ps1 recon whitelist (powershell -NoProfile -File <this file> -Kind <kind>).
# Iron rule: zero writes - no Set/Remove/New/Stop/Start, registry reads only, file reads only.
param([string]$Kind = 'service')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# data root: env override first (server injects), else repo layout (recon -> repair -> root)
$reconDir = $PSScriptRoot
$root = Split-Path -Parent (Split-Path -Parent $reconDir)
$dataRoot = $root
if ($env:DIAG_DATA_ROOT) { $dataRoot = $env:DIAG_DATA_ROOT }
$reportsDir = Join-Path $dataRoot 'reports'

# latest full-run report (diag-all-*.json); none = empty rows with ok=true (honest empty)
$latest = $null
if (Test-Path -LiteralPath $reportsDir) {
    $latest = Get-ChildItem -LiteralPath $reportsDir -File -Filter 'diag-all-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
$source = ''
$rep = $null
if ($latest) {
    $source = $latest.Name
    try { $rep = Get-Content -LiteralPath $latest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $rep = $null }
}

# safe filter token: letters/digits/_/./-/$/space only (names come from our own report, belt for injection)
function Get-SafeToken([string]$s) {
    if (-not $s) { return '' }
    $t = ($s -replace '[^A-Za-z0-9_\.\-\$ ]', '').Trim()
    return $t
}

# binary lookup: strip quotes and args from PathName, test existence, read version info
function Get-BinInfo([string]$pathName) {
    $exe = ''
    if ($pathName) {
        $p = $pathName.Trim()
        if ($p.StartsWith('"')) { $seg = ($p -split '"'); if ($seg.Count -ge 2) { $exe = $seg[1] } }
        else {
            $exe = $p
            foreach ($cut in @(' -', ' /')) { $ix = $exe.IndexOf($cut); if ($ix -ge 0) { $exe = $exe.Substring(0, $ix) } }
        }
        $exe = $exe -replace '^[\\\?]+\\', ''
    }
    $info = @{ bin = $exe; exists = $false; company = ''; product = ''; desc = '' }
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        $info.exists = $true
        try {
            $vi = (Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo
            $info.company = [string]$vi.CompanyName
            $info.product = [string]$vi.ProductName
            $info.desc = [string]$vi.FileDescription
        } catch { }
    }
    return $info
}

# uninstall registry sweep (read-only): token -> matching app entry (DisplayName/Publisher)
function Get-UninstallMatches([string]$token) {
    $hits = @()
    if (-not $token -or $token.Length -lt 3) { return $hits }
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($pp in $paths) {
        foreach ($it in @(Get-ItemProperty -Path $pp -ErrorAction SilentlyContinue)) {
            if (-not $it.DisplayName) { continue }
            $blob = ('' + $it.DisplayName + ' ' + $it.Publisher)
            if ($blob -like ('*' + $token + '*')) {
                $hits += @{ token = $token; app = [string]$it.DisplayName; publisher = [string]$it.Publisher }
                break
            }
        }
    }
    return $hits
}

$rows = @()
$apps = @()

if ($Kind -eq 'service') {
    # named services from latest report pf_service_timeouts detail (groups[].service), fallback: top third-party auto services
    $named = @()
    if ($rep) {
        foreach ($t in @($rep.trees)) {
            if ($t.tree -ne 'performance') { continue }
            foreach ($ly in @($t.layers)) {
                foreach ($c in @($ly.checks)) {
                    if ($c.name -ne 'pf_service_timeouts' -or $c.status -ne 'FAIL') { continue }
                    foreach ($g in @($c.detail.groups)) {
                        $tok = Get-SafeToken ([string]$g.service)
                        if ($tok -and $named -notcontains $tok) { $named += $tok }
                    }
                }
            }
        }
    }
    if ($named.Count -eq 0) {
        # no report / no fails: list third-party auto services (path not under Windows dirs) top 15
        foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
                Where-Object { $_.StartMode -in @('Auto', 'Auto Delayed') -and $_.PathName -and $_.PathName -notmatch '(?i)\\(windows|microsoft)\\' } |
                Select-Object -First 15)) {
            $named += [string]$s.Name
        }
    }
    foreach ($nm in $named) {
        $s = $null
        try { $s = Get-CimInstance Win32_Service -Filter ('Name=' + "'" + ($nm -replace "'", '') + "'") -ErrorAction Stop | Select-Object -First 1 } catch { }
        if (-not $s) {
            $rows += @{ name = $nm; display = ''; state = 'not-registered'; start = ''; bin = ''; exists = $false; company = ''; product = ''; desc = '' }
            continue
        }
        $bi = Get-BinInfo ([string]$s.PathName)
        $rows += @{
            name = [string]$s.Name; display = [string]$s.DisplayName; state = [string]$s.State
            start = [string]$s.StartMode; bin = $bi.bin; exists = $bi.exists
            company = $bi.company; product = $bi.product; desc = $bi.desc
        }
        if (-not $bi.exists) { continue }
        $tok = ''
        if ($bi.company) { $tok = ($bi.company -split '[ ,]')[0] } elseif ($bi.product) { $tok = ($bi.product -split '[ ,]')[0] }
        if ($tok) {
            # Microsoft 系=系统正常件，不产生卸载指引（对号表只给第三方/全家桶）
            if (($bi.company -notmatch '(?i)^microsoft') -and ($bi.product -notmatch '(?i)microsoft')) { $apps += @(Get-UninstallMatches $tok) }
        }
    }
}
elseif ($Kind -eq 'driver') {
    # named filters/drivers from latest report dv_network_filters + dv_thirdparty_inventory
    $ids = @()
    if ($rep) {
        foreach ($t in @($rep.trees)) {
            if ($t.tree -ne 'drivers') { continue }
            foreach ($ly in @($t.layers)) {
                foreach ($c in @($ly.checks)) {
                    if ($c.status -ne 'FAIL') { continue }
                    if ($c.name -eq 'dv_network_filters') {
                        foreach ($it in @($c.detail.items)) {
                            $raw = [string]$it.id
                            # 剥命名空间前缀（INSECURE_/nt_），保驱动真名（NPCAP_WIFI→npcap_wifi 全名匹配）
                            $short = $raw
                            if ($raw -match '^(?i)(?:INSECURE_|nt_)(.+)$') { $short = $Matches[1] }
                            if ($short -and $ids -notcontains $short) { $ids += $short }
                        }
                    }
                }
            }
        }
    }
    foreach ($nm in $ids) {
        $d = $null
        try { $d = Get-CimInstance Win32_SystemDriver -Filter ('Name=' + "'" + ($nm -replace "'", '') + "'") -ErrorAction Stop | Select-Object -First 1 } catch { }
        if (-not $d) {
            $rows += @{ name = $nm; display = ''; state = 'not-registered'; start = ''; bin = ''; exists = $false; company = ''; product = ''; desc = '' }
            continue
        }
        $bi = Get-BinInfo ([string]$d.PathName)
        $rows += @{
            name = [string]$d.Name; display = [string]$d.DisplayName; state = [string]$d.State
            start = [string]$d.StartMode; bin = $bi.bin; exists = $bi.exists
            company = $bi.company; product = $bi.product; desc = $bi.desc
        }
        if (-not $bi.exists) { continue }
        $tok = ''
        if ($bi.company) { $tok = ($bi.company -split '[ ,]')[0] } elseif ($bi.product) { $tok = ($bi.product -split '[ ,]')[0] }
        if ($tok) {
            # Microsoft 系=系统正常件，不产生卸载指引（对号表只给第三方/全家桶）
            if (($bi.company -notmatch '(?i)^microsoft') -and ($bi.product -notmatch '(?i)microsoft')) { $apps += @(Get-UninstallMatches $tok) }
        }
    }
}
else {
    $rows += @{ name = ''; display = ''; state = 'bad-kind'; start = ''; bin = ''; exists = $false; company = ''; product = ''; desc = '' }
}

$out = [ordered]@{ ok = $true; kind = $Kind; source = $source; rows = $rows; apps = $apps }
ConvertTo-Json -InputObject $out -Depth 5 -Compress
