# MSIX loose-layout builder (1024 round 1-B validated): staging payload + fresh 3 files + AppxManifest (dual virtualization-disabled props).
# Store packaging (makeappx/signing) still TODO - see CHANGELOG round 1. This script builds build/msix-try for Add-AppxPackage -Register validation.
﻿$ErrorActionPreference = 'Stop'
$diagRoot = Split-Path $PSScriptRoot -Parent
$try = Join-Path $diagRoot 'build\msix-try'
if (Test-Path $try) { Remove-Item $try -Recurse -Force }
New-Item -ItemType Directory -Path $try -Force | Out-Null

# 1. Icons from ui/brand.png (B1 final artwork)
Add-Type -AssemblyName System.Drawing
$srcImg = [System.Drawing.Image]::FromFile((Join-Path $diagRoot 'ui\brand.png'))
foreach ($sz in @(150, 44)) {
    $bmp = New-Object System.Drawing.Bitmap $sz, $sz
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($srcImg, 0, 0, $sz, $sz)
    $bmp.Save((Join-Path $try ("logo$sz.png")), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}
$srcImg.Dispose()
Write-Output 'ICONS-OK'

# 2. App payload: fresh staging content
$staging = Join-Path $diagRoot 'build\setup-staging'
if (-not (Test-Path $staging)) { throw 'setup-staging missing - run build.ps1 -Setup first' }
Copy-Item -Recurse -Force (Join-Path $staging '*') $try
Write-Output 'STAGING-COPIED'

# 3. Overlay the three freshly-modified files (staging holds pre-change versions)
foreach ($f in @('engine\run.ps1', 'repair\repair.ps1', 'server.ps1')) {
    Copy-Item -Force (Join-Path $diagRoot $f) (Join-Path $try $f)
}
Write-Output 'OVERLAY-3-FILES'

# 4. Manifest (Chinese literals inside - this script must keep its BOM for PS 5.1)
$man = @'
<?xml version="1.0" encoding="utf-8"?>
<Package
  xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  xmlns:desktop6="http://schemas.microsoft.com/appx/manifest/desktop/windows10/6"
  IgnorableNamespaces="uap rescap desktop6">
  <Identity Name="Diag.HealthCheck" Version="1.2.0.0" Publisher="CN=DiagProbe" ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>电脑体检台</DisplayName>
    <PublisherDisplayName>DiagProbe</PublisherDisplayName>
    <Description>Windows 健康体检工具：网络/蓝屏/硬件/性能/驱动五树检查与安全修复</Description>
    <Logo>logo150.png</Logo>
    <desktop6:RegistryWriteVirtualization>disabled</desktop6:RegistryWriteVirtualization>
    <desktop6:FileSystemWriteVirtualization>disabled</desktop6:FileSystemWriteVirtualization>
  </Properties>
  <Resources>
    <Resource Language="zh-CN" />
  </Resources>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
    <rescap:Capability Name="unvirtualizedResources" />
  </Capabilities>
  <Applications>
    <Application Id="DiagHost" Executable="host.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="电脑体检台" Description="Windows 健康体检工具"
        Square150x150Logo="logo150.png" Square44x44Logo="logo44.png" BackgroundColor="#060C18" />
    </Application>
  </Applications>
</Package>
'@
[System.IO.File]::WriteAllText((Join-Path $try 'AppxManifest.xml'), $man, (New-Object System.Text.UTF8Encoding($true)))
Write-Output 'MANIFEST-OK'
# Readback assertion: raw text must carry both disabled props (namespace-prefixed elements
# are not dot-path addressable via [xml] in PS5.1) + full XML parse check
$raw = Get-Content (Join-Path $try 'AppxManifest.xml') -Raw -Encoding UTF8
if ($raw -notmatch 'desktop6:RegistryWriteVirtualization>disabled') { throw 'readback: registry prop missing' }
if ($raw -notmatch 'desktop6:FileSystemWriteVirtualization>disabled') { throw 'readback: fs prop missing' }
$xdoc = New-Object System.Xml.XmlDocument
$xdoc.LoadXml($raw)
Write-Output 'MANIFEST-READBACK-OK'
