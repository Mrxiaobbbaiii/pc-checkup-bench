#Requires -Version 5.1
<#
diag GUI v0.7 —— WPF 壳（design 第十四节；路线=1020 用户拍板"WPF 重写壳层"）
用法：powershell -NoProfile -ExecutionPolicy Bypass -STA -File gui\run_gui.ps1（bat 启动器代跑；非 STA 自动重启自身）
定位：GUI=壳、engine=脑（进程隔离），功能面=v0.6 F1-F8 零变化；呈现层 WPF(XAML) 重写+文案大白话化（P1-P9 对策）。
数据通路=B 案沿用（engine -ProgressFile 事件流 + -JsonReport，engine v0.6 零改动）。
只读铁律：GUI 唯一写动作=剪贴板复制（用户主动点）；报告/JSON 由 engine 写在 reports/ 域；修复命令只显示+复制、禁执行。
线程模型：DispatcherTimer 500ms UI 线程轮询事件流；子进程 stdout 排水=DiagDrain C# 空回调（v0.6 已验机制）。
#>
param()

# ---------- STA 自检（WPF 硬要求；bat 已带 -STA，此为直跑兜底） ----------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File $PSCommandPath
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Drawing

# ---------- DPI 感知（进程级声明非系统设置，防 125%/150% 缩放糊字） ----------
Add-Type -Namespace DiagGui -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[DiagGui.Native]::SetProcessDPIAware() | Out-Null

# ---------- 子进程 stdout 排水器（C# 空回调：scriptblock delegate 在无 runspace 回调线程会炸进程，C# 闭包不会；v0.6 已验） ----------
Add-Type -TypeDefinition @'
using System.Diagnostics;
public static class DiagDrain {
    public static void Wire(Process p) {
        p.OutputDataReceived += (s, e) => { };
        p.ErrorDataReceived += (s, e) => { };
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
    }
}
'@

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$engineScript = Join-Path $root 'engine\run.ps1'
$reportsDir = Join-Path $root 'reports'
$guiVersion = 'v1.0'
$diagPs = (Get-Process -Id $PID).Path

# ---------- 树知识（GUI 启动时只读 trees/*.yaml 数 checks，不自算判定） ----------
$menuOrder = @('network', 'bluescreen', 'hardware', 'performance', 'drivers')
$menuNames = @{ network = '网络体检'; bluescreen = '蓝屏体检'; hardware = '硬件体检'; performance = '性能体检'; drivers = '驱动体检' }
$menuDesc  = @{ network = '上不了网 / 网页打不开'; bluescreen = '蓝屏过 / 莫名重启'; hardware = '磁盘 / 电池 / 温度'; performance = '开机慢 / 用着卡'; drivers = '驱动来路 / 设备黄三角' }
$boxNames  = @{ network = 'chkNetwork'; bluescreen = 'chkBluescreen'; hardware = 'chkHardware'; performance = 'chkPerformance'; drivers = 'chkDrivers' }
$treeDefs = @{}
foreach ($t in $menuOrder) {
    $tf = Join-Path $root "trees\$t.yaml"
    if (-not (Test-Path $tf)) { continue }
    $td = Get-Content -LiteralPath $tf -Raw -Encoding UTF8 | ConvertFrom-Json
    $total = 0
    foreach ($l in $td.layers) { $total += @($l.checks).Count }
    $treeDefs[$t] = @{ Def = $td; Total = $total; ToolTip = (@($td.layers | ForEach-Object { $_.title }) -join ' → ') }
}

# ---------- 共用（状态人话，P3-P6 大白话口径） ----------
$brushPass = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x34, 0xC7, 0x7B))
$brushFail = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF2, 0x6D, 0x6D))
$brushSkip = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x98, 0xA2, 0xB5))
$brushText = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF8, 0xFA, 0xFC))
$brushDim = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xC7, 0xD6, 0xE4))
function Get-StatusColor([string]$s) {
    switch ($s) { 'PASS' { $brushPass } 'FAIL' { $brushFail } default { $brushSkip } }
}
function Get-StatusWord([string]$s) {
    switch ($s) { 'PASS' { '✓ 正常' } 'FAIL' { '✗ 有问题' } default { '– 没查成' } }
}
function Get-ExitHuman([int]$code) {
    switch ($code) {
        0 { '全部正常' } 2 { '发现问题，点左边看哪里坏了' } 3 { '程序出错' }
        default { "异常退出（代码 $code）" }
    }
}

# ---------- XAML（深色主题取样 v0.2.1 HTML CSS；自动布局根治 P1/P2 截断） ----------
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="电脑体检台" Height="660" Width="920" MinWidth="840" MinHeight="580"
        WindowStartupLocation="CenterScreen"
        Background="#0F3D66" Foreground="#F8FAFC"
        FontFamily="Microsoft YaHei UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg" Color="#0F3D66"/>
    <!-- v0.7.1：面板 80% 不透明度，叠在背景图上（无图回退时≈原实色观感） -->
    <SolidColorBrush x:Key="Panel" Color="#CC0B2E4D"/>
    <SolidColorBrush x:Key="PanelHi" Color="#CC123A5F"/>
    <SolidColorBrush x:Key="Line" Color="#1F5280"/>
    <SolidColorBrush x:Key="Text" Color="#F8FAFC"/>
    <SolidColorBrush x:Key="Dim" Color="#C7D6E4"/>
    <SolidColorBrush x:Key="Pass" Color="#34C77B"/>
    <SolidColorBrush x:Key="Fail" Color="#F26D6D"/>
    <SolidColorBrush x:Key="Skip" Color="#98A2B5"/>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Margin" Value="0,5,28,0"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="btnBase" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource Panel}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    BorderThickness="{TemplateBinding BorderThickness}" BorderBrush="{TemplateBinding BorderBrush}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource PanelHi}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#0A2440"/>
                <Setter Property="Foreground" Value="#8FA3B8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="btnPrimary" TargetType="Button" BasedOn="{StaticResource btnBase}">
      <Setter Property="Background" Value="#1F7A4D"/>
      <Setter Property="BorderBrush" Value="#2FA368"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Foreground" Value="#34C77B"/>
      <Setter Property="Background" Value="#0B2E4D"/>
      <Setter Property="BorderBrush" Value="#1F5280"/>
      <Setter Property="Height" Value="16"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border Background="{TemplateBinding Background}" CornerRadius="8" BorderThickness="1" BorderBrush="{TemplateBinding BorderBrush}"/>
              <Border x:Name="PART_Track"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="8" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TreeView">
      <Setter Property="Background" Value="{StaticResource Panel}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="{StaticResource Panel}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style x:Key="logBox" TargetType="TextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="FontFamily" Value="Consolas, Microsoft YaHei UI"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
    </Style>
  </Window.Resources>
  <DockPanel Margin="10">
    <!-- 顶部：选择区（WrapPanel 自动换行=P1 截断根治） -->
    <Border DockPanel.Dock="Top" Background="{StaticResource Panel}" CornerRadius="10" Padding="14,10" Margin="0,0,0,8">
      <StackPanel x:Name="topPanel">
        <TextBlock Text="选择要查的项目" Foreground="{StaticResource Dim}" Margin="0,0,0,4"/>
        <WrapPanel>
          <CheckBox x:Name="chkAll" Content="全面体检（推荐，查得最全）" FontWeight="Bold" IsChecked="True"/>
          <CheckBox x:Name="chkNetwork" Content="网络体检（上不了网 / 网页打不开）" IsChecked="True"/>
          <CheckBox x:Name="chkBluescreen" Content="蓝屏体检（蓝屏过 / 莫名重启）" IsChecked="True"/>
          <CheckBox x:Name="chkHardware" Content="硬件体检（磁盘 / 电池 / 温度）" IsChecked="True"/>
          <CheckBox x:Name="chkPerformance" Content="性能体检（开机慢 / 用着卡）" IsChecked="True"/>
          <CheckBox x:Name="chkDrivers" Content="驱动体检（驱动来路 / 设备黄三角）" IsChecked="True"/>
          <CheckBox x:Name="chkFast" Content="快速模式（查到问题就停，更快）" Foreground="{StaticResource Dim}"/>
        </WrapPanel>
      </StackPanel>
    </Border>
    <!-- 底部：状态栏 -->
    <Border DockPanel.Dock="Bottom" Background="{StaticResource Panel}" CornerRadius="8" Padding="12,6" Margin="0,8,0,0">
      <DockPanel>
        <TextBlock x:Name="statusRight" Text="diag v1.0" Foreground="{StaticResource Skip}" FontSize="12" Margin="12,0,0,0"/>
        <TextBlock x:Name="statusLeft" Text="就绪" Foreground="{StaticResource Dim}" FontSize="12.5"/>
      </DockPanel>
    </Border>
    <!-- 底部：按钮区 -->
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
      <Button x:Name="btnRun" Content="开始体检" Style="{StaticResource btnPrimary}" MinWidth="132"/>
      <Button x:Name="btnBrowser" Content="浏览器看完整报告" Style="{StaticResource btnBase}" Margin="10,0,0,0"/>
      <Button x:Name="btnFolder" Content="打开报告文件夹" Style="{StaticResource btnBase}" Margin="10,0,0,0"/>
    </StackPanel>
    <!-- 中部：跑批面板 / 结果面板（同区切换） -->
    <Grid>
      <Grid x:Name="progressPanel">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="currentLabel" Grid.Row="0" Text="选好后点「开始体检」" Foreground="{StaticResource Dim}"
                   TextTrimming="CharacterEllipsis" Margin="2,0,2,8"/>
        <ProgressBar x:Name="progressBar" Grid.Row="1" Minimum="0" Maximum="100" Value="0"/>
        <Border Grid.Row="2" Background="{StaticResource Panel}" CornerRadius="10" Margin="0,10,0,0" Padding="6">
          <ListBox x:Name="logBox" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
        </Border>
      </Grid>
      <Grid x:Name="resultPanel" Visibility="Collapsed">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="5*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="8*"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="{StaticResource Panel}" CornerRadius="10" Padding="6">
          <TreeView x:Name="treeView"/>
        </Border>
        <GridSplitter Grid.Column="1" Width="6" Background="Transparent" HorizontalAlignment="Center" VerticalAlignment="Stretch"/>
        <Grid Grid.Column="2" Margin="10,0,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="2*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="selTitle" Grid.Row="0" Text="查完的结果会显示在这里" FontSize="15" FontWeight="Bold"
                     Foreground="{StaticResource Text}" TextWrapping="Wrap" Margin="2,0,2,8"/>
          <TextBlock Grid.Row="1" Text="检查依据（原始记录）" Foreground="{StaticResource Dim}" FontSize="12" Margin="2,0,2,4"/>
          <Border Grid.Row="2" Background="{StaticResource Panel}" CornerRadius="10" Padding="10" Margin="2,0,2,8">
            <TextBox x:Name="evBox" Style="{StaticResource logBox}" Text=""/>
          </Border>
          <TextBlock Grid.Row="3" Text="怎么修（工具只给步骤，不会替你改电脑）" Foreground="{StaticResource Dim}" FontSize="12" Margin="2,0,2,4"/>
          <Border Grid.Row="4" Background="{StaticResource Panel}" CornerRadius="10" Padding="10" Margin="2,0,2,8">
            <TextBox x:Name="sugBox" Style="{StaticResource logBox}" Text=""/>
          </Border>
          <Button x:Name="btnCopy" Grid.Row="5" Content="复制修复方法" Style="{StaticResource btnBase}" HorizontalAlignment="Left"
                  Margin="2,0,0,0" IsEnabled="False"/>
        </Grid>
      </Grid>
    </Grid>
  </DockPanel>
</Window>
'@
$win = [System.Windows.Markup.XamlReader]::Parse($xamlText)

# ---------- v0.7.1 背景图（assets\bg.jpg 存在才注入；发群版 zip 不带图=自动回退纯色） ----------
$bgPath = Join-Path $root 'assets\bg.jpg'
if (Test-Path -LiteralPath $bgPath) {
    try {
        $bgi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bgi.BeginInit(); $bgi.CacheOption = 'OnLoad'; $bgi.UriSource = [Uri]$bgPath; $bgi.EndInit(); $bgi.Freeze()
        $bgb = New-Object System.Windows.Media.ImageBrush $bgi
        $bgb.Stretch = 'UniformToFill'
        $win.Background = $bgb
    } catch { }
}

# FindName 绑定
$chkAll = $win.FindName('chkAll'); $chkFast = $win.FindName('chkFast')
$singleBoxes = @{}
foreach ($t in $menuOrder) { $singleBoxes[$t] = $win.FindName($boxNames[$t]) }
$topPanel = $win.FindName('topPanel')
$btnRun = $win.FindName('btnRun'); $btnBrowser = $win.FindName('btnBrowser'); $btnFolder = $win.FindName('btnFolder'); $btnCopy = $win.FindName('btnCopy')
$statusLeft = $win.FindName('statusLeft'); $statusRight = $win.FindName('statusRight')
$progressPanel = $win.FindName('progressPanel'); $resultPanel = $win.FindName('resultPanel')
$currentLabel = $win.FindName('currentLabel'); $progressBar = $win.FindName('progressBar'); $logBox = $win.FindName('logBox')
$treeView = $win.FindName('treeView'); $selTitle = $win.FindName('selTitle'); $evBox = $win.FindName('evBox'); $sugBox = $win.FindName('sugBox')

# ToolTip（各树查什么的一句话）
foreach ($t in $menuOrder) {
    if ($singleBoxes[$t]) { $singleBoxes[$t].ToolTip = "查：$($treeDefs[$t].ToolTip)" }
}
$chkAll.ToolTip = '网络、蓝屏、硬件、性能、驱动全部查一遍，出一份合并报告'
$chkFast.ToolTip = '默认不勾=全部查完（证据最全）。勾上=查到问题就提前结束，更快但查得少'

# ---------- 状态机（F7 同 v0.6：idle → running → done/cancelled/error） ----------
$script:state = 'idle'
$script:proc = $null
$script:progressFile = ''
$script:progLinesRead = 0
$script:cancelRequested = $false
$script:htmlReport = ''
$script:jsonReport = ''
$script:expectSeq = @()
$script:seqPos = 0
$script:fastMode = $false
$script:runStamp = Get-Date
$script:doneExit = $null

function Set-Status([string]$text, $color = $brushDim) {
    $statusLeft.Text = $text
    $statusLeft.Foreground = $color
}
function Set-Current([string]$text) { $currentLabel.Text = $text }
function Add-Log([string]$line, $color = $brushText) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $line
    $tb.Foreground = $color
    $tb.TextTrimming = 'CharacterEllipsis'
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas, Microsoft YaHei UI')
    $tb.FontSize = 12.5
    [void]$logBox.Items.Add($tb)
    $logBox.ScrollIntoView($tb)
}

function Get-SelectionForm {
    $picked = @($menuOrder | Where-Object { $singleBoxes[$_].IsChecked })
    if ($picked.Count -eq 5) { return 'all' }
    if ($picked.Count -eq 1) { return $picked[0] }
    if ($picked.Count -eq 0) { return 'none' }
    return 'invalid-2-4'
}

function Update-UiState {
    $running = ($script:state -eq 'running')
    $finished = ($script:state -in @('done', 'cancelled', 'error'))
    $topPanel.IsEnabled = -not $running
    if ($running) { $btnRun.Content = '取消' }
    elseif ($finished) { $btnRun.Content = '再跑一次' }
    else {
        $btnRun.Content = '开始体检'
        $sel = Get-SelectionForm
        if ($sel -eq 'invalid-2-4') { $btnRun.IsEnabled = $false; Set-Status '只支持查一项或全部——勾 2 到 4 项不行' $brushSkip }
        elseif ($sel -eq 'none') { $btnRun.IsEnabled = $false; Set-Status '先勾选要查的项目' $brushSkip }
        else { $btnRun.IsEnabled = $true; Set-Status '就绪' }
        return
    }
    $btnRun.IsEnabled = $true
    $btnBrowser.IsEnabled = ($finished -and $script:htmlReport -ne '' -and (Test-Path $script:htmlReport))
    $btnFolder.IsEnabled = $true
    $progressPanel.Visibility = $(if ($finished) { 'Collapsed' } else { 'Visible' })
    $resultPanel.Visibility = $(if ($finished) { 'Visible' } else { 'Collapsed' })
}

# 勾选联动（勾全面=五项联动勾选并禁用单改；F2 规格）
$chkAll.Add_Checked({
    foreach ($t in $menuOrder) { $singleBoxes[$t].IsChecked = $true; $singleBoxes[$t].IsEnabled = $false }
    Update-UiState
})
$chkAll.Add_Unchecked({
    foreach ($t in $menuOrder) { $singleBoxes[$t].IsEnabled = $true }
    Update-UiState
})
foreach ($t in $menuOrder) {
    $singleBoxes[$t].Add_Checked({ Update-UiState })
    $singleBoxes[$t].Add_Unchecked({ Update-UiState })
}

# ---------- 跑批启动（engine 子进程：-TreeName <名|all> [-Full] -NoMenu -ProgressFile -JsonReport） ----------
function Start-Run {
    if (-not (Test-Path $engineScript)) {
        [void][System.Windows.MessageBox]::Show($win, "找不到程序文件：$engineScript", '电脑体检台', 'OK', 'Error')
        return
    }
    $formSel = Get-SelectionForm
    if ($formSel -in @('none', 'invalid-2-4')) { return }
    $treeArg = $formSel
    $script:fastMode = $chkFast.IsChecked
    $script:expectSeq = @()
    foreach ($t in $menuOrder) {
        if ($treeArg -ne 'all' -and $t -ne $treeArg) { continue }
        foreach ($l in $treeDefs[$t].Def.layers) {
            foreach ($c in $l.checks) { $script:expectSeq += @{ tree = $t; layer = $l.name; layerTitle = [string]$l.title; check = $c } }
        }
    }
    $script:seqPos = 0
    $script:progLinesRead = 0
    $script:cancelRequested = $false
    $script:htmlReport = ''
    $script:jsonReport = ''
    $script:doneExit = $null
    $script:runStamp = Get-Date
    $logBox.Items.Clear()
    $progressBar.Maximum = $script:expectSeq.Count
    $progressBar.Value = 0
    $treeView.Items.Clear()
    $script:progressFile = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-gui-progress-$PID-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.jsonl')
    Remove-Item -LiteralPath $script:progressFile -Force -ErrorAction SilentlyContinue

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engineScript, '-TreeName', $treeArg, '-NoMenu', '-ProgressFile', $script:progressFile, '-JsonReport')
    if (-not $script:fastMode) { $argList += '-Full' }
    $quoted = @($argList | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '') + '"' } else { $_ } })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $diagPs
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($psi.PSObject.Properties['StandardOutputEncoding']) { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 }
    if ($psi.PSObject.Properties['StandardErrorEncoding']) { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 }
    try {
        $script:proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Set-Status ('启动失败：' + $_.Exception.Message) $brushFail
        return
    }
    [DiagDrain]::Wire($script:proc)

    $script:state = 'running'
    $label = if ($treeArg -eq 'all') { '全面体检' } else { "$($menuNames[$treeArg])" }
    Add-Log ('—— 开始' + $label + ' ——') $brushDim
    if ($script:expectSeq.Count -gt 0) { Set-Current ('正在查：' + $script:expectSeq[0].check) }
    Set-Status ("正在检查（共 $($script:expectSeq.Count) 项）…") $brushDim
    Update-UiState
}

# ---------- 事件流处理（B 案；文案=大白话口径） ----------
function Handle-Event($ev) {
    switch ($ev.event) {
        'check' {
            $sec = if ($ev.ms) { ('{0:n1}' -f ($ev.ms / 1000.0)) + ' 秒' } else { '' }
            $word = switch ($ev.status) { 'PASS' { '✓ 正常' } 'FAIL' { '✗ 有问题' } default { '– 没查成' } }
            $color = Get-StatusColor $ev.status
            Add-Log ("$word  $($ev.check) · $sec") $color
            $script:seqPos++
            $progressBar.Value = [Math]::Min($script:seqPos, $progressBar.Maximum)
            if ($script:seqPos -lt $script:expectSeq.Count) {
                $nx = $script:expectSeq[$script:seqPos]
                $layerIdx = 1 + [array]::IndexOf(@($treeDefs[$nx.tree].Def.layers | ForEach-Object { $_.name }), $nx.layer)
                $layerTotal = @($treeDefs[$nx.tree].Def.layers).Count
                Set-Current ("正在查：$($nx.layerTitle)（第 $layerIdx 步，共 $layerTotal 步）")
            }
        }
        'break' {
            Add-Log ("✗ 问题出在这一步：$($ev.layerTitle)") $brushFail
            if ($script:fastMode -and $script:seqPos -lt $script:expectSeq.Count) {
                foreach ($nx in $script:expectSeq[$script:seqPos..($script:expectSeq.Count - 1)]) {
                    if ($nx.tree -ne $ev.tree) { continue }
                    if ($nx.layer -eq $ev.layer) { continue }
                    Add-Log ("– 没查成  $($nx.check)（快速模式提前结束）") $brushSkip
                    $script:seqPos++
                }
                $progressBar.Value = [Math]::Min($script:seqPos, $progressBar.Maximum)
            }
        }
        'tree_done' {
            $tn = if ($menuNames[$ev.tree]) { $menuNames[$ev.tree] } else { $ev.tree }
            $word = if ($ev.status -eq 'FAIL') { '发现问题' } else { '全部正常' }
            Add-Log ("—— $tn 完成：$word ——") $brushDim
        }
        'done' {
            $script:doneExit = $ev.exit
            if ($ev.htmlReport) { $script:htmlReport = $ev.htmlReport }
            if ($ev.jsonReport) { $script:jsonReport = $ev.jsonReport }
        }
    }
}

# ---------- 事件流增量读（DispatcherTimer 在 UI 线程 tick） ----------
function Read-NewEvents {
    if ($script:progressFile -eq '' -or -not (Test-Path $script:progressFile)) { return }
    $all = @(Get-Content -LiteralPath $script:progressFile -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' })
    if ($all.Count -le $script:progLinesRead) { return }
    foreach ($line in $all[$script:progLinesRead..($all.Count - 1)]) {
        try { $ev = $line | ConvertFrom-Json } catch { continue }
        Handle-Event $ev
    }
    $script:progLinesRead = $all.Count
}

# ---------- 进程退出收敛 ----------
function On-EngineExited {
    Read-NewEvents
    $code = try { $script:proc.ExitCode } catch { -1 }
    $elapsed = (Get-Date) - $script:runStamp
    $secHuman = [string][int][Math]::Round($elapsed.TotalSeconds)
    if ($script:cancelRequested) {
        $script:state = 'cancelled'
        Add-Log '—— 已取消，本次没有报告 ——' $brushSkip
        Set-Current '已取消，本次没有报告'
        Set-Status ('已取消 · 用时 ' + $secHuman + ' 秒') $brushSkip
    } elseif ($code -eq 0 -or $code -eq 2) {
        $script:state = 'done'
        $word = if ($code -eq 0) { '全部正常' } else { '发现问题' }
        Add-Log ('—— 检查完成（' + $secHuman + ' 秒）· ' + $word + ' ——') $(if ($code -eq 0) { $brushPass } else { $brushFail })
        $progressBar.Value = $progressBar.Maximum
        Set-Current '查完了。左边看每项结果，也可以点「浏览器看完整报告」'
        Set-Status ("检查完成（$secHuman 秒）· " + (Get-ExitHuman $code)) $(if ($code -eq 0) { $brushPass } else { $brushFail })
        Build-ResultTree
    } else {
        $script:state = 'error'
        Add-Log ('—— 程序出错了（代码 ' + $code + '）——') $brushFail
        Set-Current '程序出错'
        Set-Status ("程序出错了（代码 $code）。请把 reports 文件夹里最新的文件发给维护者") $brushFail
    }
    if (Test-Path $script:progressFile) { Remove-Item -LiteralPath $script:progressFile -Force -ErrorAction SilentlyContinue }
    $script:proc = $null
    Update-UiState
}

# ---------- 结果树（B 案 JSON；P8 时间戳去秒+文案中文化） ----------
function New-TreeNode([string]$text, $color, $tag) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text; $tb.Foreground = $color; $tb.TextTrimming = 'CharacterEllipsis'
    $item = New-Object System.Windows.Controls.TreeViewItem
    $item.Header = $tb; $item.Tag = $tag
    return $item
}
function Build-ResultTree {
    if ($script:jsonReport -eq '' -or -not (Test-Path $script:jsonReport)) {
        $n = New-TreeNode '报告数据缺失——点「浏览器看完整报告」查看' $brushSkip $null
        [void]$treeView.Items.Add($n)
        return
    }
    $j = $null
    try { $j = Get-Content -LiteralPath $script:jsonReport -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not $j) {
        $n = New-TreeNode '报告读取失败——点「浏览器看完整报告」查看' $brushFail $null
        [void]$treeView.Items.Add($n)
        return
    }
    $time = ([string]$j.time) -replace ':\d\d$', ''
    $isAll = @($j.trees).Count -gt 1
    $rootText = if ($isAll) { "全面体检报告  $time" } else { "$($j.trees[0].report_name)  $time" }
    $exitCode = $(if ($null -ne $script:doneExit) { $script:doneExit } else { -1 })
    $rootColor = $(if ($exitCode -eq 0) { $brushPass } else { $brushFail })
    $rootNode = New-TreeNode $rootText $rootColor @{ type = 'root'; title = $rootText; exitCode = $exitCode; time = $time }
    $layerNum = @('①', '②', '③', '④', '⑤', '⑥')
    foreach ($t in $j.trees) {
        $treeNode = New-TreeNode ([string]$t.report_name) $(if ($t.break_layer) { $brushFail } else { $brushPass }) @{ type = 'tree'; data = $t }
        $breakTitle = ''
        if ($t.break_layer) { $bl = @($t.layers | Where-Object { $_.name -eq $t.break_layer }); if ($bl) { $breakTitle = [string]$bl[0].title } }
        $treeNode.Tag = @{ type = 'tree'; data = $t; breakTitle = $breakTitle }
        $li = 0
        foreach ($l in $t.layers) {
            $li++
            $num = if ($li -le 6) { $layerNum[$li - 1] } else { "第$li" }
            if ($l.state -eq 'BREAK') { $mark = ' —— 有问题'; $lc = $brushFail }
            elseif ($l.state -like 'SKIPPED*') { $mark = '（快速模式未查）'; $lc = $brushSkip }
            else { $mark = ' ✓'; $lc = $brushPass }
            $ln = New-TreeNode "$num $($l.title)$mark" $lc @{ type = 'layer'; data = $l }
            foreach ($c in @($l.checks)) {
                $cn = New-TreeNode ((Get-StatusWord $c.status) + '  ' + $c.name) (Get-StatusColor $c.status) @{ type = 'check'; data = $c }
                [void]$ln.Items.Add($cn)
            }
            [void]$treeNode.Items.Add($ln)
        }
        [void]$rootNode.Items.Add($treeNode)
    }
    $treeView.Items.Clear()
    [void]$treeView.Items.Add($rootNode)
    $rootNode.IsExpanded = $true
    $rootNode.IsSelected = $true
}

# ---------- 选中渲染（P2 根治：TextWrapping=Wrap） ----------
$script:currentSuggestion = ''
$treeView.Add_SelectedItemChanged({
    $node = $treeView.SelectedItem
    if (-not $node) { return }
    $tag = $node.Tag
    $script:currentSuggestion = ''
    $btnCopy.IsEnabled = $false
    $btnCopy.Content = '复制修复方法'
    $evBox.Text = ''; $sugBox.Text = ''
    if (-not $tag) { $selTitle.Text = '查完的结果会显示在这里'; return }
    switch ($tag.type) {
        'check' {
            $selTitle.Text = "$($tag.data.name)  $(Get-StatusWord $tag.data.status)"
            $selTitle.Foreground = Get-StatusColor $tag.data.status
            $evBox.Text = [string]$tag.data.evidence
            if ($tag.data.suggestion) {
                $sugBox.Text = [string]$tag.data.suggestion
                if ($tag.data.status -eq 'FAIL') { $script:currentSuggestion = [string]$tag.data.suggestion; $btnCopy.IsEnabled = $true }
            } else {
                $sugBox.Text = if ($tag.data.status -eq 'FAIL') { '（这项有问题但没给修复方法——异常，请反馈）' } else { '（这项正常，不需要修）' }
            }
        }
        'layer' {
            $selTitle.Text = "$($tag.data.title)"
            if ($tag.data.state -eq 'BREAK') { $selTitle.Foreground = $brushFail } elseif ($tag.data.state -like 'SKIPPED*') { $selTitle.Foreground = $brushSkip } else { $selTitle.Foreground = $brushPass }
            $stateHuman = switch ($tag.data.state) {
                'BREAK' { '这一步查出了问题' } 'PASS' { '这一步全部正常' } 'PASSED-EARLIER' { '这一步全部正常' }
                'SKIPPED-AFTER-BREAK' { '快速模式下这一步没有查' } default { $tag.data.state }
            }
            $evBox.Text = "$stateHuman`r`n`r`n这一步说明：$($tag.data.verdict_fail)"
            $sugBox.Text = '（点开这一步下面的具体项目，看怎么修）'
        }
        'tree' {
            $selTitle.Text = "$($tag.data.report_name)"
            $concl = if ($tag.data.break_layer) { "问题出在这一步：$($tag.breakTitle)" } else { '全部正常' }
            $selTitle.Foreground = if ($tag.data.break_layer) { $brushFail } else { $brushPass }
            $evBox.Text = "$concl`r`n`r`n这项检查正常时会看到：$($tag.data.verdict_all_pass)"
            $sugBox.Text = '（点开左边的步骤看每项详情）'
        }
        'root' {
            $selTitle.Text = $tag.title
            $selTitle.Foreground = if ($tag.exitCode -eq 0) { $brushPass } else { $brushFail }
            $evBox.Text = "总结论：$(Get-ExitHuman $tag.exitCode)`r`n报告时间：$($tag.time)`r`n`r`n想看带样式的完整报告：点下方「浏览器看完整报告」"
            $sugBox.Text = '（点开左边的树和步骤，查看每项详情）'
        }
    }
})

# ---------- 按钮/窗体事件 ----------
$btnRun.Add_Click({
    if ($script:state -eq 'running') {
        $script:cancelRequested = $true
        if ($script:proc) {
            try { & taskkill.exe /PID $script:proc.Id /T /F 2>&1 | Out-Null } catch { }
        }
        return
    }
    if ($script:state -in @('done', 'cancelled', 'error')) {
        $script:state = 'idle'
        $logBox.Items.Clear()
        $progressBar.Value = 0
        $treeView.Items.Clear()
        $evBox.Text = ''; $sugBox.Text = ''
        $selTitle.Text = '查完的结果会显示在这里'
        Set-Current '选好后点「开始体检」'
        Update-UiState
        return
    }
    Start-Run
})
$btnBrowser.Add_Click({
    if ($script:htmlReport -ne '' -and (Test-Path $script:htmlReport)) { Invoke-Item -LiteralPath $script:htmlReport }
})
$btnFolder.Add_Click({
    if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList "`"$reportsDir`""
})
$btnCopyTimer = New-Object System.Windows.Threading.DispatcherTimer
$btnCopyTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$btnCopyTimer.Add_Tick({ $btnCopyTimer.Stop(); $btnCopy.Content = '复制修复方法' })
$btnCopy.Add_Click({
    if ($script:currentSuggestion) {
        [System.Windows.Clipboard]::SetText($script:currentSuggestion)
        $btnCopy.Content = '已复制 ✓'
        $btnCopyTimer.Start()
    }
})

# 跑批中点 X=确认弹窗；空闲/完成态直接关（F1）
# v0.7.1 修复：Closing 分发过程内同步 MessageBox 死锁不弹窗、BeginInvoke 回调不出队（1021 UIA 复测实锤）——
# 改用一次性 DispatcherTimer 把弹窗脱出 WM_CLOSE 分发上下文（本程序 btnCopyTimer 同模式）；确认后置标志真关窗
$script:closeConfirmed = $false
$askCloseTimer = New-Object System.Windows.Threading.DispatcherTimer
$askCloseTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$askCloseTimer.Add_Tick({
    $askCloseTimer.Stop()
    $r = [System.Windows.MessageBox]::Show($win, '体检没跑完，确定退出？', 'diag 电脑体检台', 'YesNo', 'Question')
    if ($r -eq [System.Windows.MessageBoxResult]::Yes) {
        $script:cancelRequested = $true
        if ($script:proc) { try { & taskkill.exe /PID $script:proc.Id /T /F 2>&1 | Out-Null } catch { } }
        if (Test-Path $script:progressFile) { Remove-Item -LiteralPath $script:progressFile -Force -ErrorAction SilentlyContinue }
        $script:closeConfirmed = $true
        $win.Close()
    }
})
$win.Add_Closing({
    param($s, $e)
    if ($script:state -eq 'running' -and -not $script:closeConfirmed) {
        $e.Cancel = $true
        $askCloseTimer.Start()
    }
})

# ---------- Dispatcher 未捕获异常兜底（间歇崩进程→留痕+不崩：crash.log 可诊断） ----------
$dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
$dispatcher.Add_UnhandledException({
    param($s, $e)
    try {
        $logLine = "[{0}] {1}`r`n{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $e.Exception.Message, $e.Exception.StackTrace
        Add-Content -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) 'diag-gui-crash.log') -Value $logLine -Encoding UTF8
    } catch { }
    $e.Handled = $true
})

# ---------- DispatcherTimer（500ms：事件流+退出收敛+状态栏秒刷） ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:tickCount = 0
$timer.Add_Tick({
    $script:tickCount++
    if ($script:tickCount % 2 -eq 0 -and $script:state -eq 'running' -and $script:proc) {
        $elapsed = (Get-Date) - $script:runStamp
        $mm = $elapsed.Minutes + 60 * $elapsed.Hours; $ss = $elapsed.Seconds
        $statusRight.Text = "diag $guiVersion · 用时 {0:d2}:{1:d2}" -f $mm, $ss
    }
    if ($script:state -eq 'running') {
        Read-NewEvents
        if ($script:proc -and $script:proc.HasExited) { On-EngineExited }
    }
})
$timer.Start()

# ---------- 启动 ----------
Update-UiState
[void]$win.ShowDialog()
$timer.Stop()
