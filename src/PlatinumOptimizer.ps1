#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Scan,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:EntryScriptPath = $PSCommandPath
$modulePath = Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Core.psm1'
Import-Module -Name $modulePath -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Power.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Audio.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Display.psm1') -Global -Force -ErrorAction Stop

if ($SelfTest) {
    & (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\Run-Tests.ps1')
    exit $LASTEXITCODE
}

if ($Scan) {
    $snapshot = Get-POSystemSnapshot
    $snapshot | ConvertTo-Json -Depth 10
    exit 0
}

if (-not (Test-POIsWindows)) {
    Write-Error 'Platinum Optimizer requires Windows 10/11 and Windows PowerShell 5.1.'
    exit 2
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$xamlPath = Join-Path $PSScriptRoot 'ui\MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$xmlReader = New-Object System.Xml.XmlNodeReader $xaml
$script:poWindow = [Windows.Markup.XamlReader]::Load($xmlReader)
$script:poSnapshot = $null
$script:poCurrentPlan = $null
$script:poBeforeBenchmark = $null
$script:poAfterBenchmark = $null
$script:poAdapters = @()
$script:poServices = @()
$script:poBackups = @()
$script:poTempPreview = $null
$script:poMonitorTimer = $null
$script:poDisplayInventory = $null
$script:poAudioInventory = $null

function Get-POControl {
    param([Parameter(Mandatory = $true)][string]$Name)
    $control = $script:poWindow.FindName($Name)
    if (-not $control) { throw "UI control '$Name' is missing from MainWindow.xaml." }
    return $control
}

function Set-POFooter {
    param([string]$Text, [ValidateSet('normal','good','warning','error')][string]$Tone = 'normal')
    $footer = Get-POControl 'FooterStatusText'
    $footer.Text = $Text
    switch ($Tone) {
        'good' { $footer.Foreground = [Windows.Media.Brushes]::LightGreen }
        'warning' { $footer.Foreground = [Windows.Media.Brushes]::Gold }
        'error' { $footer.Foreground = [Windows.Media.Brushes]::Salmon }
        default { $footer.Foreground = [Windows.Media.Brushes]::LightSlateGray }
    }
}

function Show-POMessage {
    param([string]$Text, [string]$Title = 'Platinum Optimizer', [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Information)
    [void][System.Windows.MessageBox]::Show($script:poWindow, $Text, $Title, [System.Windows.MessageBoxButton]::OK, $Icon)
}

function Confirm-POAction {
    param([string]$Text, [string]$Title = 'Confirm change', [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Warning)
    return ([System.Windows.MessageBox]::Show($script:poWindow, $Text, $Title, [System.Windows.MessageBoxButton]::YesNo, $Icon) -eq [System.Windows.MessageBoxResult]::Yes)
}

function Format-POValue {
    param([AllowNull()][object]$Value, [string]$Unit = '')
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 'Unknown' }
    if ($Unit) { return "{0} {1}" -f $Value, $Unit }
    return [string]$Value
}

function Format-POHardwareReport {
    param([Parameter(Mandatory = $true)][psobject]$Snapshot)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('OPERATING SYSTEM')
    $lines.Add("  $($Snapshot.OS.Name)  |  Version $($Snapshot.OS.Version)  |  Build $($Snapshot.OS.Build)  |  $($Snapshot.OS.Architecture)")
    $lines.Add("  Family gate: $(if ($Snapshot.OS.Supported) { 'Windows 10/11' } else { 'Unsupported / unknown' })  |  Servicing lifecycle: $($Snapshot.OS.ServicingStatus)")
    if (@($Snapshot.CollectionWarnings).Count -gt 0) {
        $lines.Add('')
        $lines.Add('COLLECTION WARNINGS - some inventory queries failed; affected fields are unknown')
        foreach ($warning in @($Snapshot.CollectionWarnings)) { $lines.Add("  $($warning.ClassName): $($warning.Error)") }
    }
    $lines.Add('')
    $lines.Add('DEVICE / POWER')
    $lines.Add("  $($Snapshot.Device.Manufacturer) $($Snapshot.Device.Model)")
    $lines.Add("  Form factor: $($Snapshot.Device.FormFactor)  |  Power source: $($Snapshot.Device.PowerSource)")
    $lines.Add('')
    $lines.Add('CPU')
    $lines.Add("  $($Snapshot.CPU.Vendor)  |  $($Snapshot.CPU.Model)")
    $lines.Add("  Architecture: $($Snapshot.CPU.Architecture)  |  Cores: $(Format-POValue $Snapshot.CPU.PhysicalCores)  |  Logical processors: $(Format-POValue $Snapshot.CPU.LogicalProcessors)")
    $lines.Add("  Maximum / current clock reported by WMI: $(Format-POValue $Snapshot.CPU.MaximumClockReportedMHz 'MHz') / $(Format-POValue $Snapshot.CPU.CurrentClockReportedMHz 'MHz')")
    $lines.Add("  L2 / L3 cache: $(Format-POValue $Snapshot.CPU.L2CacheKB 'KB') / $(Format-POValue $Snapshot.CPU.L3CacheKB 'KB')  |  Virtualization firmware: $(Format-POValue $Snapshot.CPU.VirtualizationFirmwareEnabled)")
    $lines.Add("  NUMA nodes reported: $(Format-POValue $Snapshot.CPU.NumaNodes)  |  Generation: $($Snapshot.CPU.Generation)")
    $lines.Add("  Hybrid P/E topology: $($Snapshot.CPU.PerformanceEfficiencyCoreTopology)")
    $lines.Add('')
    $lines.Add('GRAPHICS ADAPTERS')
    if (@($Snapshot.GPUs).Count -eq 0) { $lines.Add('  No GPU controller reported by WMI.') }
    foreach ($gpu in @($Snapshot.GPUs)) {
        $lines.Add("  $($gpu.Vendor)  |  $($gpu.Name)")
        $lines.Add("  Driver: $(Format-POValue $gpu.DriverVersion)  |  Reported adapter memory: $(Format-POValue $gpu.ReportedVRAMGB 'GB')")
        $lines.Add("  Adapter-reported mode: $(Format-POValue $gpu.ResolutionReportedByAdapter) @ $(Format-POValue $gpu.RefreshRateReportedByAdapterHz 'Hz')")
        $lines.Add('  Shared GPU memory: Unknown (not reliably exposed by this query).')
    }
    $lines.Add('')
    $lines.Add('MEMORY')
    $lines.Add("  Total: $(Format-POValue $Snapshot.Memory.TotalGB 'GB')  |  Available: $(Format-POValue $Snapshot.Memory.AvailableGB 'GB')")
    $lines.Add("  Channels: $($Snapshot.Memory.Channels)  |  Compression: $($Snapshot.Memory.Compression)")
    foreach ($module in @($Snapshot.Memory.Modules)) {
        $lines.Add("  DIMM: $(Format-POValue $module.CapacityGB 'GB') @ $(Format-POValue $module.SpeedMHz 'MHz')  |  Type code $(Format-POValue $module.MemoryTypeCode)  |  $($module.DeviceLocator)")
    }
    $lines.Add('')
    $lines.Add('STORAGE')
    if ($Snapshot.SystemVolume) { $lines.Add("  System volume $($Snapshot.SystemVolume.Drive): $(Format-POValue $Snapshot.SystemVolume.SizeGB 'GB') total, $(Format-POValue $Snapshot.SystemVolume.FreeGB 'GB') free ($($Snapshot.SystemVolume.FreePercent)%). $($Snapshot.SystemVolume.Warning)") }
    foreach ($disk in @($Snapshot.Storage)) { $lines.Add("  $($disk.Model)  |  $(Format-POValue $disk.SizeGB 'GB')  |  $($disk.Interface) / $($disk.MediaType)  |  health $($disk.StatusReportedByWMI)") }
    $lines.Add('  Temperature/SMART detail: Unknown unless the Windows storage provider explicitly reports it.')
    $lines.Add('')
    $lines.Add('MOTHERBOARD / BIOS')
    $lines.Add("  $($Snapshot.Motherboard.Manufacturer) $($Snapshot.Motherboard.Model)  |  BIOS $($Snapshot.BIOS.Version) dated $($Snapshot.BIOS.ReleaseDate)")
    $lines.Add('  Firmware update: information only; no automatic download or flash.')
    $lines.Add('')
    $lines.Add('SIGNED DRIVER INVENTORY (WINDOWS-PROVIDED METADATA)')
    $lines.Add('  Driver inventory: available from the Hardware page; skipped during the initial home scan to keep startup responsive.')
    $lines.Add('')
    $lines.Add('MONITORS')
    foreach ($monitor in @($Snapshot.Monitors)) { $lines.Add("  $($monitor.Manufacturer) $($monitor.Model)  |  active=$($monitor.Active)  |  resolution/refresh/HDR/color depth=$($monitor.Resolution) / $($monitor.RefreshRateHz) / $($monitor.HDR) / $($monitor.ColorDepth)") }
    return ($lines -join [Environment]::NewLine)
}

function Update-POStatusBadge {
    $dot = Get-POControl 'StatusDot'
    $status = Get-POControl 'StatusText'
    if ($script:poSnapshot -and $script:poSnapshot.OS.Supported) {
        $dot.Fill = [Windows.Media.Brushes]::MediumSeaGreen
        $status.Text = 'READY | SAFE MODE'
        $status.Foreground = [Windows.Media.Brushes]::LightGreen
    }
    else {
        $dot.Fill = [Windows.Media.Brushes]::Gold
        $status.Text = 'NEEDS REVIEW'
        $status.Foreground = [Windows.Media.Brushes]::Gold
    }
    $admin = Test-POIsAdministrator
    (Get-POControl 'AdminStatusText').Text = if ($admin) { 'Administrator | changes available' } else { 'Limited mode | read-only' }
}

function Refresh-POHome {
    try {
        $script:poSnapshot = Get-POSystemSnapshot
        $script:poSecurity = Get-POStatusSnapshot
        Update-POStatusBadge
        $snap = $script:poSnapshot
        (Get-POControl 'HomeCpu').Text = [string]$snap.CPU.Model
        (Get-POControl 'HomeCpuDetail').Text = "$(Format-POValue $snap.CPU.PhysicalCores) cores | $(Format-POValue $snap.CPU.LogicalProcessors) threads | $($snap.CPU.Vendor)"
        $gpuNames = @($snap.GPUs | ForEach-Object { $_.Name })
        if ($gpuNames.Count -eq 0) { $gpuNames = @('Not reported') }
        (Get-POControl 'HomeGpu').Text = $gpuNames[0]
        (Get-POControl 'HomeGpuDetail').Text = if ($snap.GPUs.Count -gt 1) { "$($snap.GPUs.Count) adapters reported" } elseif ($snap.GPUs.Count -eq 1) { "$(Format-POValue $snap.GPUs[0].DriverVersion 'driver') | $(Format-POValue $snap.GPUs[0].ReportedVRAMGB 'GB reported')" } else { 'No adapter reported' }
        (Get-POControl 'HomeRam').Text = "$(Format-POValue $snap.Memory.TotalGB 'GB') installed"
        (Get-POControl 'HomeRamDetail').Text = "$(Format-POValue $snap.Memory.AvailableGB 'GB') currently available | compression not reported"
        (Get-POControl 'HomeWindows').Text = $snap.OS.Family
        (Get-POControl 'HomeWindowsDetail').Text = "Build $(Format-POValue $snap.OS.Build) | $($snap.OS.Architecture) | $($snap.Device.FormFactor)"
        (Get-POControl 'ReadinessTitle').Text = if ($snap.OS.Supported) { 'System detected | profile review required' } else { 'Unknown / unsupported Windows build' }
        (Get-POControl 'ReadinessDetail').Text = 'No change has been applied. Review a profile, compare the exact proposed action, and decide whether to proceed. No FPS or performance score is fabricated.'
        (Get-POControl 'HomeSecurityText').Text = "Defender: $($script:poSecurity.Defender)  |  Firewall: $($script:poSecurity.Firewall)`nMemory Integrity: $($script:poSecurity.MemoryIntegrity)  |  Secure Boot: $($script:poSecurity.SecureBoot)  |  TPM: $($script:poSecurity.TPM)  |  UAC: $($script:poSecurity.UAC)"
        (Get-POControl 'HardwareOutput').Text = Format-POHardwareReport -Snapshot $snap
        $storageText = 'System volume metadata unavailable.'
        if ($snap.SystemVolume) { $storageText = "$($snap.SystemVolume.Drive)  |  $($snap.SystemVolume.SizeGB) GB total  |  $($snap.SystemVolume.FreeGB) GB free  |  $($snap.SystemVolume.FreePercent)% free" }
        if ($snap.SystemVolume.Warning) { $storageText += "`n`nWARNING: $($snap.SystemVolume.Warning). Low free space may affect system behavior." }
        $storageText += "`n`nPhysical devices:`n" + (@($snap.Storage | ForEach-Object { "- $($_.Model) | $($_.MediaType) | $($_.SizeGB) GB | health reported: $($_.StatusReportedByWMI)" }) -join "`n")
        $storageText += "`n`nTemperature: not exposed by the generic query. SSD TRIM and drive optimization remain under Windows' built-in schedule."
        (Get-POControl 'StorageOutput').Text = $storageText
        $pointer = @()
        foreach ($name in @('MouseSpeed', 'MouseThreshold1', 'MouseThreshold2')) {
            $state = Get-PORegValueState -Hive CurrentUser -SubKey 'Control Panel\Mouse' -ValueName $name
            $pointer += "$name = $(if (-not $state.Readable) { 'Unknown (registry read failed)' } elseif ($state.Exists) { $state.Data } else { 'Not set' })"
        }
        (Get-POControl 'InputSettingsText').Text = ($pointer -join '   |   ') + "`nMouse polling rate: not reliably available via generic Windows APIs. No pointer setting is changed."
        (Get-POControl 'LastScanText').Text = "Updated $((Get-Date).ToString('HH:mm:ss'))"
        (Get-POControl 'SettingsInfoText').Text = "Windows 10/11 inventory: $($snap.OS.Family), build $($snap.OS.Build).`nPrivilege: $(if (Test-POIsAdministrator) { 'Administrator' } else { 'Limited mode (read-only until explicitly elevated)' }).`nLocal data: $(Get-POStateRoot)`nLocal JSONL log: $(Join-Path (Get-POStateRoot) 'logs\optimizer.jsonl')`nNo telemetry or remote services are used."
        Set-POFooter 'System inventory refreshed | no changes applied' 'good'
    }
    catch {
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'System detection failed' -Icon Error
    }
}

function Set-POPage {
    param([Parameter(Mandatory = $true)][string]$Page)
    $pages = @('Home','Optimize','Power','Audio','Display','Profiles','Tweaks','Games','Hardware','Network','Input','Storage','Debloat','Services','Startup','Diagnostics','Restore','Settings')
    foreach ($name in $pages) {
        $control = $script:poWindow.FindName($name + 'Panel')
        if ($control) { $control.Visibility = if ($name -eq $Page) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
        $nav = $script:poWindow.FindName('Nav' + $name)
        if ($nav) { $nav.Background = if ($name -eq $Page) { [Windows.Media.Brushes]::DarkSlateGray } else { [Windows.Media.Brushes]::Transparent } }
    }
    $titles = @{
        Home = @('Home', 'System status, hardware summary, and honest readiness facts.')
        Optimize = @('Optimize', 'Hardware-aware gaming workflow: detect, baseline, back up, apply permitted changes, verify, restore.')
        Power = @('Power plan', 'Platinum On Steroids | presets | core parking readout | previous-plan restore.')
        Audio = @('Audio & Headphones', 'Verified detection plus presets whose only automatic change is restorable. Optional and independent.')
        Display = @('Display & Colors', 'Per-display gamma and refresh with captured-original restore. No GPU registry writes.')
        Profiles = @('Profiles', 'Safe | Balanced | Gaming | Competitive | Maximum Performance | Laptop Battery | Custom')
        Tweaks = @('Tweak catalog', 'Every automated action is classified; unverified legacy tweaks are retired.')
        Games = @('Game library', 'Local discovery and advisory profiles; no game injection.')
        Hardware = @('Hardware', 'Windows-reported inventory; missing fields remain unknown.')
        Network = @('Network', 'Read-only diagnostics and an explicit, reversible DNS option.')
        Input = @('Input latency', 'Review supported pointer settings; no made-up DPC or polling numbers.')
        Storage = @('Storage', 'Drive inventory and narrowly scoped optional user-temp cleanup.')
        Debloat = @('App inventory', 'Installed packages are listed but never mass-removed.')
        Services = @('Services', 'Dependency-aware inventory; no blanket service disabling.')
        Startup = @('Startup', 'Read-only entries with Windows Settings as the change surface.')
        Diagnostics = @('Diagnostics', 'Comparable system samples, ping tests, and honest before/after deltas.')
        Restore = @('Restore center', 'Validate a local backup and roll back only recorded optimizer changes.')
        Settings = @('Settings & logs', 'Local storage, permissions, and product behavior.')
    }
    $titleInfo = $titles[$Page]
    (Get-POControl 'PageTitle').Text = $titleInfo[0]
    (Get-POControl 'PageSubtitle').Text = $titleInfo[1]
    try {
        switch ($Page) {
            'Network' { Refresh-POAdapters; Update-POAdapterDetails }
            'Games' { Refresh-POGames }
            'Services' { Refresh-POServiceRows }
            'Startup' { Refresh-POStartupRows }
            'Debloat' { Refresh-POAppxRows }
            'Restore' { Refresh-POBackups }
            'Power' { Refresh-POPowerPage }
            'Audio' { Refresh-POAudioPage }
            'Display' { Refresh-PODisplayPage }
        }
    }
    catch { Set-POFooter "Read-only $Page inventory failed: $($_.Exception.Message)" 'error' }
}

function Set-POProfileChoices {
    $combo = Get-POControl 'ProfileCombo'
    $items = @(Get-POProfiles | ForEach-Object { [pscustomobject]@{ Id = [string]$_.id; Name = [string]$_.name } })
    $combo.ItemsSource = $items
    $combo.DisplayMemberPath = 'Name'
    $combo.SelectedValuePath = 'Id'
    $combo.SelectedValue = 'safe'
    $dns = @(
        [pscustomobject]@{ Id = 'Automatic'; Name = 'Automatic (DHCP)' },
        [pscustomobject]@{ Id = 'Cloudflare'; Name = 'Cloudflare (IPv4)' },
        [pscustomobject]@{ Id = 'Google'; Name = 'Google (IPv4)' },
        [pscustomobject]@{ Id = 'Quad9'; Name = 'Quad9 (IPv4)' },
        [pscustomobject]@{ Id = 'Custom'; Name = 'Custom (IPv4)' }
    )
    $dnsCombo = Get-POControl 'DnsProviderCombo'
    $dnsCombo.ItemsSource = $dns
    $dnsCombo.DisplayMemberPath = 'Name'
    $dnsCombo.SelectedValuePath = 'Id'
    $dnsCombo.SelectedValue = 'Automatic'
    $platinumCombo = Get-POControl 'PlatinumPresetCombo'
    $platinumItems = @(Get-POPlatinumPresetCatalog | ForEach-Object { [pscustomobject]@{ Id = [string]$_.id; Name = [string]$_.name } })
    $platinumCombo.ItemsSource = $platinumItems
    $platinumCombo.DisplayMemberPath = 'Name'
    $platinumCombo.SelectedValuePath = 'Id'
    if ($platinumItems.Count -gt 0) { $platinumCombo.SelectedValue = 'gaming' }
    $audioCombo = Get-POControl 'AudioPresetCombo'
    $audioItems = @(Get-POAudioPresets | ForEach-Object { [pscustomobject]@{ Id = [string]$_.id; Name = [string]$_.name } })
    $audioCombo.ItemsSource = $audioItems
    $audioCombo.DisplayMemberPath = 'Name'
    $audioCombo.SelectedValuePath = 'Id'
    if ($audioItems.Count -gt 0) { $audioCombo.SelectedValue = 'competitive-fps' }
    $displayProfileCombo = Get-POControl 'DisplayProfileCombo'
    $displayItems = @(Get-PODisplayProfiles | ForEach-Object { [pscustomobject]@{ Id = [string]$_.id; Name = [string]$_.name } })
    $displayProfileCombo.ItemsSource = $displayItems
    $displayProfileCombo.DisplayMemberPath = 'Name'
    $displayProfileCombo.SelectedValuePath = 'Id'
    if ($displayItems.Count -gt 0) { $displayProfileCombo.SelectedValue = 'platinum-competitive' }
    (Get-POControl 'SimulationModeCheck').IsChecked = $true
}

function Show-POProfilePlan {
    if (-not $script:poSnapshot) { $script:poSnapshot = Get-POSystemSnapshot }
    $profileId = [string](Get-POControl 'ProfileCombo').SelectedValue
    if (-not $profileId) { $profileId = 'safe' }
    $plans = @(Get-POPowerPlans)
    $active = Get-POActivePowerPlanGuid
    $script:poCurrentPlan = New-POProfilePlan -ProfileId $profileId -SystemSnapshot $script:poSnapshot -PowerPlans $plans -ActivePlanGuid $active
    $plan = $script:poCurrentPlan
    (Get-POControl 'PreviewHeadline').Text = "$($plan.ProfileName)  |  $($plan.TargetPowerPlanName)"
    (Get-POControl 'PreviewSummary').Text = $plan.Description
    if ($plan.Change) {
        $fromName = @($plans | Where-Object { $_.Guid -eq $plan.Change.FromGuid } | Select-Object -First 1)
        $fromDisplay = if ($fromName.Count -gt 0) { $fromName[0].Name } else { 'Current plan (name unavailable)' }
        (Get-POControl 'PreviewChange').Text = "$($plan.Change.Risk) RISK  |  $fromDisplay  ->  $($plan.TargetPowerPlanName)`nOnly selects an existing Windows scheme. No AC/DC values, processor limits, clocks, service state, registry, or BCD are changed.`nAdministrator: yes  |  Reboot: no  |  Rollback: previous active plan GUID from timestamped backup."
        (Get-POControl 'ApplyProfileButton').IsEnabled = $true
    }
    elseif ($profileId -in @('safe','custom')) {
        (Get-POControl 'PreviewChange').Text = 'No automated system changes. Review the recommended Windows Settings shortcuts below.'
        (Get-POControl 'ApplyProfileButton').IsEnabled = $false
    }
    else {
        (Get-POControl 'PreviewChange').Text = 'No change ready. The requested plan is already active, not installed, or blocked by a compatibility/power-source check.'
        (Get-POControl 'ApplyProfileButton').IsEnabled = $false
    }
    $messages = @($plan.Warnings) + @($plan.Skipped)
    (Get-POControl 'PreviewWarnings').Text = if ($messages.Count) { $messages -join "`n- " } else { 'None. No unsupported, security-affecting, vendor-private, or reboot-required change is proposed.' }
    (Get-POControl 'PreviewRecommendations').ItemsSource = @($plan.Recommendations | ForEach-Object { "- $($_.Name) - $($_.Description)" })
    (Get-POControl 'ApplyProfileButton').Content = if ((Get-POControl 'SimulationModeCheck').IsChecked) { 'Run simulation' } else { 'Apply reviewed profile' }
    (Get-POControl 'ApplyStatusText').Text = if ((Get-POControl 'SimulationModeCheck').IsChecked) { 'Simulation mode: no backup or Windows setting will be changed.' } else { 'Apply creates a timestamped local backup first; an apply or verification failure triggers rollback.' }
    Set-POFooter 'Profile compatibility check complete | nothing applied' 'good'
}

function Refresh-POPowerPage {
    $info = Get-POPlatinumPlanInfo
    $lines = New-Object System.Collections.Generic.List[string]
    if ($info.Exists) {
        $lines.Add("Plan: $($info.PlanName)")
        $lines.Add("GUID: $($info.PlanGuid)")
        $lines.Add("Active: $(if ($info.IsActive) { 'YES' } else { 'no' })  |  Active plan GUID: $(if ($info.ActivePlanGuid) { $info.ActivePlanGuid } else { 'Unknown' })")
        $lines.Add("Applied preset: $(if ($info.AppliedPresetId) { $info.AppliedPresetId } else { 'none applied by this app yet' })  |  Created: $(if ($info.CreatedAtUtc) { $info.CreatedAtUtc } else { 'unknown' })")
        $lines.Add("Recorded previous plan: $(if ($info.OriginalActivePlanGuid) { $info.OriginalActivePlanGuid } else { 'not recorded' })")
        if ($info.QueryError) { $lines.Add("WARNING: $($info.QueryError)") }
        if (@($info.SettingsReport).Count -gt 0) {
            $lines.Add('')
            $lines.Add('Documented processor/platform settings in this plan:')
            foreach ($row in @($info.SettingsReport)) {
                if ($row.Supported) { $lines.Add("  $($row.Name): AC $(if ($null -ne $row.AcValue) { $row.AcValue } else { '?' }) / DC $(if ($null -ne $row.DcValue) { $row.DcValue } else { '?' }) [$($row.Unit)]") }
                else { $lines.Add("  $($row.Name): Not supported on this system (skipped, never forced)") }
            }
        }
    }
    else {
        $lines.Add("The '$($info.PlanName)' plan does not exist yet.")
        $lines.Add("Active plan GUID: $(if ($info.ActivePlanGuid) { $info.ActivePlanGuid } else { 'Unknown' })")
        $lines.Add('Use Create / validate plan to build it from the documented High Performance scheme. Existing plans are preserved.')
    }
    (Get-POControl 'PlatinumPlanStatusText').Text = ($lines -join "`n")
    try {
        $parking = Get-POCpuParkingStatus
        $cpuLines = New-Object System.Collections.Generic.List[string]
        $cpuLines.Add("Active plan: $(if ($parking.ActivePlanName) { $parking.ActivePlanName } else { 'Unknown' }) ($($parking.ActivePlanGuid))")
        foreach ($setting in @($parking.ProcessorSettings)) {
            if ($setting.Supported) { $cpuLines.Add("  $($setting.Name): AC $(if ($null -ne $setting.AcValue) { $setting.AcValue } else { '?' }) / DC $(if ($null -ne $setting.DcValue) { $setting.DcValue } else { '?' })") }
            else { $cpuLines.Add("  $($setting.Name): Not exposed by Windows on this platform") }
        }
        $cpuLines.Add("Core-parking settings exposed by this system: $(if ($parking.CoreParkingVisible) { 'yes' } else { 'no (Windows manages parking internally)' })")
        $cpuLines.Add($parking.QuickCpu.Note)
        (Get-POControl 'CpuParkingText').Text = ($cpuLines -join "`n")
        (Get-POControl 'QuickCpuText').Text = "Quick CPU: $(if ($parking.QuickCpu.Installed) { "detected at $($parking.QuickCpu.Path)" } else { 'not detected (optional; never downloaded by this app)' }).`nMaximum Gaming Performance = the Competitive preset on a desktop on AC power; it pins clocks and unparks all cores and therefore needs the separate thermal confirmation."
    }
    catch {
        (Get-POControl 'CpuParkingText').Text = "CPU power status unavailable: $($_.Exception.Message)"
    }
    Set-POFooter 'Power plan state refreshed | nothing changed' 'good'
}

function Invoke-POCreatePlatinumPlanFromUi {
    try {
        $info = Get-POPlatinumPlanInfo
        if ($info.Exists) {
            Refresh-POPowerPage
            Show-POMessage -Text "The '$($info.PlanName)' plan already exists ($($info.PlanGuid)). It was inspected, not duplicated. Existing plans remain untouched." -Title 'Plan already present'
            return
        }
        $confirm = "Create the '$(Get-POPlatinumPlanName)' power plan?`n`nSource: the documented High Performance scheme (powercfg /duplicatescheme).`nName: exactly '$(Get-POPlatinumPlanName)'.`nExisting plans: preserved, never deleted.`nAdministrator is required and no plan is activated without a separate confirmation."
        if (-not (Confirm-POAction -Text $confirm -Title 'Create Platinum On Steroids plan')) { return }
        $result = New-POPlatinumPlan -Confirm:$false
        (Get-POControl 'PowerApplyStatusText').Text = "$($result.Status): $($result.Message)"
        Set-POFooter "$($result.Status): $($result.Message)" $(if ($result.Status -eq 'CREATED' -or $result.Status -eq 'EXISTS_VALIDATED') { 'good' } else { 'warning' })
        Refresh-POPowerPage
    }
    catch {
        (Get-POControl 'PowerApplyStatusText').Text = $_.Exception.Message
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Plan was not created' -Icon Error
    }
}

function Invoke-POApplyPlatinumPresetFromUi {
    $presetId = [string](Get-POControl 'PlatinumPresetCombo').SelectedValue
    if (-not $presetId) { Show-POMessage 'Select a Platinum preset first.'; return }
    $catalog = Get-POPowerSettingCatalog
    $preset = @($catalog.presets | Where-Object { $_.id -eq $presetId } | Select-Object -First 1)
    if ($preset.Count -eq 0) { Show-POMessage 'Unknown preset.'; return }
    $preset = $preset[0]
    $info = Get-POPlatinumPlanInfo
    $confirm = "Apply '$($preset.name)' to the $(Get-POPlatinumPlanName) plan?`n`n$($preset.description)`n`nThe plan is created if missing (existing plans preserved), every supported setting is written with powercfg and read back, unsupported settings are skipped and listed, and a timestamped backup with the current active plan is created first. The previous plan is NOT switched unless you confirm activation.`nAdministrator: required. Reboot: not required."
    if (-not (Confirm-POAction -Text $confirm -Title 'Review exact power change')) { return }
    if ($preset.requiresThermalConfirmation) {
        $thermal = "THERMAL / POWER WARNING ($($preset.name))`n`nThis preset pins the minimum processor state to 100% on AC and keeps every core unparked. Expect higher idle power draw, heat, and fan noise. It is not applied on battery. Do not continue if the machine is already hot.`n`nExplicitly continue?"
        if (-not (Confirm-POAction -Text $thermal -Title 'Advanced power warning')) { return }
    }
    try {
        $result = Invoke-POPlatinumPlanWorkflow -PresetId $presetId -Confirm:$false
        $statusText = "$($result.Status): $($result.Message)"
        if (@($result.Applied).Count -gt 0) { $statusText += "`n`nApplied and verified:`n" + (@($result.Applied) -join "`n") }
        if (@($result.Skipped).Count -gt 0) { $statusText += "`n`nSkipped (not supported or rejected):`n" + (@($result.Skipped) -join "`n") }
        if ($result.Backup) { $statusText += "`nBackup: $($result.Backup.Id)" }
        (Get-POControl 'PowerApplyStatusText').Text = $statusText
        $tone = if ($result.Status -like 'FAILED*') { 'error' } elseif ($result.Status -like 'APPLIED*') { 'good' } else { 'normal' }
        Set-POFooter $result.Message $tone
        Write-POLog -Category 'Power' -Status $result.Status -Message $result.Message
        if ($result.Status -like 'APPLIED*') {
            Refresh-POPowerPage
            Refresh-POBackups
            if (-not $result.Activated -and (Confirm-POAction -Text "The preset is applied and verified, and your previous plan is still active.`n`nActivate '$(Get-POPlatinumPlanName)' now? Windows will be asked to report it as active and the result is verified." -Title 'Activate now?')) {
                Invoke-POActivatePlatinumFromUi
            }
        }
    }
    catch {
        (Get-POControl 'PowerApplyStatusText').Text = $_.Exception.Message
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Preset was not applied' -Icon Error
    }
}

function Invoke-POActivatePlatinumFromUi {
    try {
        $result = Set-POPlatinumPlanActive -Confirm:$false
        (Get-POControl 'PowerApplyStatusText').Text = "$($result.Status): $($result.Message)"
        Set-POFooter "$($result.Status): $($result.Message)" $(if ($result.Status -like '*VERIFIED*' -or $result.Status -eq 'ALREADY_ACTIVE') { 'good' } elseif ($result.Status -eq 'SIMULATED') { 'normal' } else { 'error' })
        Refresh-POPowerPage
    }
    catch {
        (Get-POControl 'PowerApplyStatusText').Text = $_.Exception.Message
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Plan was not activated' -Icon Error
    }
}

function Invoke-PORestorePowerPlanFromUi {
    try {
        $state = Get-POPlatinumState
        if ($null -eq $state -or -not $state.OriginalActivePlanGuid) {
            Show-POMessage 'No previous active plan was recorded by Platinum Optimizer, so there is nothing to restore. Use Restore Center for backups.'
            return
        }
        if (-not (Confirm-POAction -Text "Restore the power plan that was active before Platinum On Steroids ($($state.OriginalActivePlanGuid))?`n`nThe Platinum plan itself is kept (not deleted). All other plans are untouched." -Title 'Restore previous power plan')) { return }
        $result = Restore-POPreviousPowerPlan -Confirm:$false
        (Get-POControl 'PowerApplyStatusText').Text = "$($result.Status): $($result.Message)"
        Set-POFooter "$($result.Status): $($result.Message)" $(if ($result.Status -like '*VERIFIED*' -or $result.Status -eq 'ALREADY_RESTORED') { 'good' } else { 'warning' })
        Refresh-POPowerPage
    }
    catch {
        (Get-POControl 'PowerApplyStatusText').Text = $_.Exception.Message
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Power plan was not restored' -Icon Error
    }
}

function Format-POAudioInventoryText {
    param([Parameter(Mandatory = $true)][psobject]$Inventory)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Inventory.Message)
    $lines.Add("Audio service: $($Inventory.ServiceState)")
    $lines.Add("Default playback/recording: $($Inventory.DefaultPlayback)")
    $lines.Add("Spatial audio: $($Inventory.SpatialAudioState)")
    $lines.Add("Enhancements: $($Inventory.EnhancementsState)")
    $lines.Add("Exclusive mode: $($Inventory.ExclusiveMode)")
    $lines.Add('')
    $lines.Add('AUDIO CONTROLLERS (Win32_SoundDevice)')
    foreach ($device in @($Inventory.SoundDevices)) {
        $lines.Add("  $($device.Name) | $($device.Manufacturer) | status $($device.Status)")
        $lines.Add("    Connection: $($device.ConnectionType)")
    }
    if (@($Inventory.Endpoints).Count -gt 0) {
        $lines.Add('')
        $lines.Add('AUDIO ENDPOINTS (PnP AudioEndpoint class)')
        foreach ($endpoint in @($Inventory.Endpoints)) {
            $lines.Add("  $($endpoint.FriendlyName) | $($endpoint.Status) | $($endpoint.ConnectionType)")
        }
    }
    elseif ($Inventory.EndpointError) { $lines.Add(''); $lines.Add("Endpoints: $($Inventory.EndpointError)") }
    return ($lines -join "`n")
}

function Refresh-POAudioPage {
    try {
        $script:poAudioInventory = Get-POAudioInventory
        (Get-POControl 'AudioInventoryText').Text = Format-POAudioInventoryText -Inventory $script:poAudioInventory
        Set-POFooter 'Audio inventory refreshed | nothing changed' 'good'
    }
    catch {
        (Get-POControl 'AudioInventoryText').Text = "Audio inventory failed: $($_.Exception.Message)"
        Set-POFooter $_.Exception.Message 'error'
    }
}

function Update-POAudioPresetExplanation {
    $presetId = [string](Get-POControl 'AudioPresetCombo').SelectedValue
    if (-not $presetId) { (Get-POControl 'AudioPresetExplanation').Text = 'Select a preset to read exactly what it changes and why.'; return }
    $preset = @(Get-POAudioPresets | Where-Object { $_.id -eq $presetId } | Select-Object -First 1)
    if ($preset.Count -eq 0) { return }
    $preset = $preset[0]
    $text = $preset.description
    if (@($preset.whatChanges).Count -gt 0) { $text += "`n`nChanges automatically: " + (@($preset.whatChanges) -join ' ') }
    else { $text += "`n`nChanges automatically: nothing (restore uses the captured values only)." }
    $text += "`nWhy: $($preset.why)"
    (Get-POControl 'AudioPresetExplanation').Text = $text
}

function Invoke-POApplyAudioPresetFromUi {
    $presetId = [string](Get-POControl 'AudioPresetCombo').SelectedValue
    if (-not $presetId) { Show-POMessage 'Select an audio preset first.'; return }
    $preset = @(Get-POAudioPresets | Where-Object { $_.id -eq $presetId } | Select-Object -First 1)
    if ($preset.Count -eq 0) { Show-POMessage 'Unknown audio preset.'; return }
    $preset = $preset[0]
    $confirm = "Apply audio preset '$($preset.name)'?`n`n$($preset.description)`n`nAutomatic changes: $(if (@($preset.whatChanges).Count -gt 0) { @($preset.whatChanges) -join ' ' } else { 'none' })`nThe captured original is backed up first and restorable at any time. The microphone and default devices are never touched. Audio stays independent of the gaming optimization."
    if (-not (Confirm-POAction -Text $confirm -Title 'Confirm audio change')) { return }
    try {
        $result = Invoke-POAudioPreset -PresetId $presetId -Confirm:$false
        $statusText = "$($result.Status): $($result.Message)"
        if (@($result.ManualSteps).Count -gt 0) { $statusText += "`n`nManual (optional, supported Windows UI):`n" + (@($result.ManualSteps) | ForEach-Object { "- $_" } | ForEach-Object { $_ }) -join "`n" }
        (Get-POControl 'AudioApplyStatusText').Text = $statusText
        (Get-POControl 'AudioManualStepsText').Text = if (@($result.ManualSteps).Count -gt 0) { 'Manual steps shown above are optional and use supported Windows UI only.' } else { '' }
        Set-POFooter "$($result.Status): $($result.Message)" $(if ($result.Status -like '*VERIFIED*') { 'good' } elseif ($result.Status -eq 'FAILED') { 'error' } else { 'normal' })
        Refresh-POBackups
    }
    catch {
        (Get-POControl 'AudioApplyStatusText').Text = $_.Exception.Message
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Audio preset was not applied' -Icon Error
    }
}

function Invoke-PORestoreAudioFromUi {
    try {
        $result = Restore-POAudioSettings -Confirm:$false
        (Get-POControl 'AudioApplyStatusText').Text = "$($result.Status): $($result.Message)"
        (Get-POControl 'AudioManualStepsText').Text = ''
        Set-POFooter "$($result.Status): $($result.Message)" $(if ($result.Status -like '*VERIFIED*' -or $result.Status -eq 'NO_CHANGES') { 'good' } else { 'normal' })
    }
    catch {
        (Get-POControl 'AudioApplyStatusText').Text = $_.Exception.Message
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Audio was not restored' -Icon Error
    }
}

function Format-PODisplayInventoryText {
    param([Parameter(Mandatory = $true)][psobject]$Inventory)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Inventory.Message)
    foreach ($display in @($Inventory.Displays)) {
        $lines.Add('')
        $lines.Add("$($display.DeviceName) $(if ($display.IsPrimary) { '(primary)' } else { '' })")
        $lines.Add("  GPU: $($display.AdapterDescription) [$($display.GpuVendor)]")
        $lines.Add("  Monitor: $($display.MonitorDescription) | PnP: $($display.MonitorPnpId)")
        $lines.Add("  Mode: $($display.Resolution) @ $($display.RefreshRateHz) Hz, $($display.BitsPerPel) bpp | highest available at this resolution: $(if ($null -ne $display.HighestAvailableRefreshAtCurrentResolution) { "$($display.HighestAvailableRefreshAtCurrentResolution) Hz" } else { 'Unknown' }) ($($display.EnumeratedModes) modes enumerated)")
        $lines.Add("  HDR: $($display.HDR)")
        $lines.Add("  ICC: $($display.IccProfile)")
    }
    $lines.Add('')
    $lines.Add("DDC/CI: $($Inventory.DdcCi)")
    foreach ($control in @($Inventory.GpuColorControls)) { $lines.Add($control) }
    return ($lines -join "`n")
}

function Refresh-PODisplayPage {
    try {
        $script:poDisplayInventory = Get-PODisplayInventory
        (Get-POControl 'DisplayInventoryText').Text = Format-PODisplayInventoryText -Inventory $script:poDisplayInventory
        $combo = Get-POControl 'DisplayCombo'
        $items = @($script:poDisplayInventory.Displays | ForEach-Object { [pscustomobject]@{ Id = [string]$_.DeviceName; Name = "$(if ($_.IsPrimary) { '[Primary] ' } else { '' })$($_.DeviceName) - $($_.Resolution) @ $($_.RefreshRateHz) Hz" } })
        $combo.ItemsSource = $items
        $combo.DisplayMemberPath = 'Name'
        $combo.SelectedValuePath = 'Id'
        $primary = @($script:poDisplayInventory.Displays | Where-Object { $_.IsPrimary } | Select-Object -First 1)
        if ($primary.Count -gt 0) { $combo.SelectedValue = [string]$primary[0].DeviceName }
        elseif ($items.Count -gt 0) { $combo.SelectedIndex = 0 }
        Set-POFooter 'Display inventory refreshed | nothing changed' 'good'
    }
    catch {
        (Get-POControl 'DisplayInventoryText').Text = "Display inventory failed: $($_.Exception.Message)"
        Set-POFooter $_.Exception.Message 'error'
    }
}

function Update-PODisplayProfileExplanation {
    $profileId = [string](Get-POControl 'DisplayProfileCombo').SelectedValue
    if (-not $profileId) { (Get-POControl 'DisplayProfileExplanation').Text = 'Select a display and a profile to read its purpose, scope, and trade-offs.'; return }
    $profile = @(Get-PODisplayProfiles | Where-Object { $_.id -eq $profileId } | Select-Object -First 1)
    if ($profile.Count -eq 0) { return }
    $profile = $profile[0]
    $text = "$($profile.purpose)`nScope: $($profile.scope)"
    if ($null -ne $profile.PSObject.Properties['gamma'] -and $null -ne $profile.gamma -and [string]$profile.gamma -ne 'restore-captured') { $text += "`nGamma target: $($profile.gamma) (clamped, absolute, identical on R/G/B)" }
    if (@($profile.tradeoffs).Count -gt 0) { $text += "`nTrade-offs: " + (@($profile.tradeoffs) -join ' ') }
    $text += "`nVendor saturation: $($profile.vibranceGuidance)"
    (Get-POControl 'DisplayProfileExplanation').Text = $text
}

function Invoke-POApplyDisplayProfileFromUi {
    $profileId = [string](Get-POControl 'DisplayProfileCombo').SelectedValue
    $deviceName = [string](Get-POControl 'DisplayCombo').SelectedValue
    if (-not $profileId) { Show-POMessage 'Select a display profile first.'; return }
    if (-not $deviceName) { Show-POMessage 'Select the target display first.'; return }
    $profile = @(Get-PODisplayProfiles | Where-Object { $_.id -eq $profileId } | Select-Object -First 1)
    if ($profile.Count -eq 0) { Show-POMessage 'Unknown display profile.'; return }
    $profile = $profile[0]
    $confirm = "Apply '$($profile.name)' to $deviceName ONLY?`n`n$($profile.purpose)`n`nScope: $($profile.scope)`nTrade-offs: $(if (@($profile.tradeoffs).Count -gt 0) { @($profile.tradeoffs) -join ' ' } else { 'none listed' })`n`nThe original mode and gamma ramp of this display are captured before the first change and restorable at any time. Gamma is clamped and identical on all channels. No GPU registry value is written. Other displays are untouched."
    if (-not (Confirm-POAction -Text $confirm -Title 'Confirm display change')) { return }
    try {
        $result = Invoke-PODisplayProfile -ProfileId $profileId -DeviceName $deviceName -Confirm:$false
        $statusText = "$($result.Status): $($result.Message)"
        if ($result.Guidance) { $statusText += "`nVendor saturation (manual): $($result.Guidance)" }
        if ($result.SettingsUri) { $statusText += "`nOpen: $($result.SettingsUri)" }
        (Get-POControl 'DisplayApplyStatusText').Text = $statusText
        $tone = if ($result.Status -eq 'APPLIED_VERIFIED' -or $result.Status -eq 'RESTORED_VERIFIED') { 'good' } elseif ($result.Status -eq 'FAILED') { 'error' } else { 'normal' }
        Set-POFooter "$($result.Status): $($result.Message)" $tone
        Refresh-PODisplayPage
        if ($result.Backup) { Refresh-POBackups }
    }
    catch {
        (Get-POControl 'DisplayApplyStatusText').Text = $_.Exception.Message
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Display profile was not applied' -Icon Error
    }
}

function Invoke-PORestoreDisplayFromUi {
    $deviceName = [string](Get-POControl 'DisplayCombo').SelectedValue
    if (-not $deviceName) { Show-POMessage 'Select the display to restore first.'; return }
    if (-not (Confirm-POAction -Text "Restore the captured original mode and gamma ramp for $deviceName?`nVendor saturation changed manually in a GPU control panel must be reverted there." -Title 'Restore display configuration')) { return }
    try {
        $result = Restore-PODisplayConfiguration -DeviceName $deviceName -Confirm:$false
        (Get-POControl 'DisplayApplyStatusText').Text = "$($result.Status): $($result.Message)"
        Set-POFooter "$($result.Status): $($result.Message)" $(if ($result.Status -like '*VERIFIED*' -or $result.Status -eq 'NO_CHANGES') { 'good' } else { 'normal' })
    }
    catch {
        (Get-POControl 'DisplayApplyStatusText').Text = $_.Exception.Message
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Display was not restored' -Icon Error
    }
}

function Invoke-POAutoGamingOptimize {
    [CmdletBinding()]
    param()
    # Combined Platinum On Steroids workflow. Low-risk, reversible,
    # evidence-supported changes can be applied automatically; audio
    # presets, color profiles, and DNS changes are NOT part of this path
    # and stay behind their own explicit confirmations.

    if (-not (Test-POIsAdministrator)) { Start-POElevated; return }

    $started = Get-Date
    $results = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]

    try {
        Set-POFooter 'Platinum On Steroids: detecting system and hardware...' 'normal'
        (Get-POControl 'ReadinessTitle').Text = 'Platinum On Steroids optimization in progress...'
        (Get-POControl 'ReadinessDetail').Text = 'Detecting hardware, displays, audio, power, network, and input state before changing anything.'

        # 1-2. System + hardware detection, displays and audio devices.
        $snapshot = Get-POSystemSnapshot
        [void]$results.Add("Detection: $($snapshot.OS.Name) | CPU $(Format-POValue $snapshot.CPU.Model) | $(@($snapshot.GPUs).Count) GPU(s) | $(Format-POValue $snapshot.Memory.TotalGB 'GB') RAM")
        try {
            $displayInventory = Get-PODisplayInventory
            [void]$results.Add("Displays: $(@($displayInventory.Displays).Count) active display(s) detected where Windows exposes them")
        } catch { [void]$skipped.Add("Display detection: $($_.Exception.Message)") }
        try {
            $audioInventory = Get-POAudioInventory
            [void]$results.Add("Audio: $(@($audioInventory.SoundDevices).Count) sound device(s), $(@($audioInventory.Endpoints).Count) endpoint(s) detected")
        } catch { [void]$skipped.Add("Audio detection: $($_.Exception.Message)") }

        # 3. Current power plan / CPU configuration inspection.
        $activeBefore = Get-POActivePowerPlanGuid
        $platinumInfo = Get-POPlatinumPlanInfo
        [void]$results.Add("Power: active plan $(if ($activeBefore) { $activeBefore } else { 'Unknown' }); Platinum plan $(if ($platinumInfo.Exists) { "present ($($platinumInfo.PlanGuid))" } else { 'not created yet' })")

        # 4. Network inspection.
        try {
            $upAdapters = @(Get-PONetworkAdapters | Where-Object { $_.Status -eq 'Up' })
            [void]$results.Add("Network: $($upAdapters.Count) connected adapter(s); DNS change stays manual and explicit")
        } catch { [void]$skipped.Add("Network inspection: $($_.Exception.Message)") }

        # 5. Input device information inspection.
        try {
            $mouseSpeed = Get-PORegValueState -Hive CurrentUser -SubKey 'Control Panel\Mouse' -ValueName 'MouseSpeed'
            [void]$results.Add("Input: pointer MouseSpeed=$(if ($mouseSpeed.Readable -and $mouseSpeed.Exists) { $mouseSpeed.Data } else { 'Unknown' }); no pointer setting is changed")
        } catch { [void]$skipped.Add("Input inspection: $($_.Exception.Message)") }

        # 6. GPU capability inspection.
        foreach ($gpu in @($snapshot.GPUs)) {
            [void]$results.Add("GPU capability: $($gpu.Vendor) | $(Format-POValue $gpu.Name) | mode $(Format-POValue $gpu.ResolutionReportedByAdapter) @ $(Format-POValue $gpu.RefreshRateReportedByAdapterHz 'Hz')")
        }

        # 7-8. Recommendation + baseline sample.
        $presetId = 'gaming'
        if ($snapshot.Device.IsLaptop -eq $true) { $presetId = 'laptop' }
        try { $sample = Get-POResourceSample; [void]$results.Add("Baseline: CPU $(Format-POValue $sample.CpuPercent '%'), $(Format-POValue $sample.AvailableMemoryGB 'GB') RAM available at capture") }
        catch { [void]$skipped.Add('Baseline sample unavailable.') }

        # 9-11. Backup + apply permitted low-risk changes (the Platinum plan).
        $applyPlan = $true
        if (-not $snapshot.OS.Supported) { $applyPlan = $false; [void]$skipped.Add('Power plan: Windows family not identified as 10/11; plan change blocked.') }
        if ($snapshot.Device.IsLaptop -eq $true -and $snapshot.Device.PowerSource -eq 'Battery') { $applyPlan = $false; [void]$skipped.Add('Power plan: portable device is on battery; high-performance plan blocked. Re-run on AC or use the Laptop preset manually.') }
        if ($snapshot.Device.IsLaptop -eq $true -and $snapshot.Device.PowerSource -ne 'AC') { $applyPlan = $false; [void]$skipped.Add('Power plan: AC power could not be positively confirmed on this portable device; plan change blocked.') }
        if ($applyPlan) {
            try {
                $planResult = Invoke-POPlatinumPlanWorkflow -PresetId $presetId -Confirm:$false
                if ($planResult.Status -like 'APPLIED*') {
                    [void]$results.Add("Power policy: Platinum On Steroids preset '$presetId' applied and verified ($($planResult.PlanGuid)); $($planResult.Applied.Count) settings verified, $($planResult.Skipped.Count) skipped")
                    if (@($planResult.Skipped).Count -gt 0) { [void]$skipped.Add("Power settings skipped as not supported: $($planResult.Skipped.Count)") }
                    if (-not $planResult.Activated) {
                        if (Confirm-POAction -Text "Platinum On Steroids is configured and verified; your previous plan is still active.`nBackup: $($planResult.Backup.Id)`n`nActivate 'Platinum On Steroids' now?`n(Verify: Windows is asked to report it active and the result is checked.)" -Title 'Activate Platinum On Steroids?') {
                            try {
                                $activateResult = Set-POPlatinumPlanActive -Confirm:$false
                                [void]$results.Add("Power policy activation: $($activateResult.Message)")
                            } catch { [void]$skipped.Add("Power policy activation failed: $($_.Exception.Message) Previous plan left active.") }
                        } else { [void]$skipped.Add('Power policy: user declined activation; the previous plan remains active.') }
                    }
                }
                else { [void]$skipped.Add("Power policy: $($planResult.Message)") }
            } catch { [void]$skipped.Add("Power policy: $($_.Exception.Message)") }
        }

        # TCP baseline (supported netsh interface).
        if (Get-Command netsh.exe -ErrorAction SilentlyContinue) {
            try {
                & netsh.exe int tcp set global rss=enabled | Out-Null
                & netsh.exe int tcp set global autotuninglevel=normal | Out-Null
                & netsh.exe int tcp set global ecncapability=disabled | Out-Null
                & netsh.exe int tcp set global timestamps=disabled | Out-Null
                [void]$results.Add('TCP baseline: RSS enabled, autotuning normal, ECN disabled, timestamps disabled')
            } catch { [void]$skipped.Add("TCP baseline: $($_.Exception.Message)") }
        }

        try { & ipconfig.exe /flushdns | Out-Null; [void]$results.Add('DNS cache: flushed') }
        catch { [void]$skipped.Add("DNS cache: $($_.Exception.Message)") }

        # Keep an active physical Ethernet NIC from being power-managed away when supported.
        try {
            $ethernetAdapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and [string]$_.InterfaceDescription -notmatch '(?i)wi-?fi|wireless|802\.11|bluetooth' })
            if ($ethernetAdapters.Count -gt 0 -and (Get-Command Set-NetAdapterPowerManagement -ErrorAction SilentlyContinue)) {
                foreach ($adapter in $ethernetAdapters) {
                    try {
                        Set-NetAdapterPowerManagement -Name $adapter.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
                        [void]$results.Add("Ethernet power management: kept active for $($adapter.Name)")
                    } catch { [void]$skipped.Add("Ethernet $($adapter.Name): $($_.Exception.Message)") }
                }
            } elseif ($ethernetAdapters.Count -eq 0) {
                [void]$results.Add('Ethernet: no active physical Ethernet adapter detected')
            } else { [void]$results.Add('Ethernet: driver does not expose the Windows power-management control') }
        } catch { [void]$skipped.Add("Ethernet detection: $($_.Exception.Message)") }

        # 12-13. Results, skipped operations, restore offer.
        $elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        $summary = "Platinum On Steroids workflow complete in $elapsed s.`n`nAPPLIED / VERIFIED`n" + ($results -join "`n")
        if ($skipped.Count -gt 0) { $summary += "`n`nSKIPPED (explained, never reported as success)`n" + ($skipped -join "`n") }
        $summary += "`n`nNot applied automatically (need their own consent): audio presets, display color profiles, DNS resolver changes.`nRestore: Restore Center rolls back recorded changes; the Power page has a one-click previous-plan restore."
        (Get-POControl 'ReadinessTitle').Text = 'Platinum On Steroids optimization complete'
        (Get-POControl 'ReadinessDetail').Text = 'Permitted low-risk changes were applied and verified. Actual FPS and ping still depend on hardware, drivers, the game, server, and route.'
        (Get-POControl 'ScoreText').Text = 'Gaming score: NOT SCORED - run a real in-game benchmark to measure FPS/frame time.'
        Set-POFooter 'Platinum On Steroids workflow finished · audio and color changes stay optional' 'good'
        Show-POMessage -Text $summary -Title 'Platinum Optimizer - Platinum On Steroids' -Icon Information
        Refresh-POBackups
    } catch {
        Set-POFooter "Platinum On Steroids optimization failed: $($_.Exception.Message)" 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Optimization stopped' -Icon Error
    }
}
function Invoke-POApplyProfile {
    if (-not $script:poCurrentPlan) { Show-POMessage 'Analyze and preview a profile before applying.'; return }
    if (-not $script:poCurrentPlan.Change) { Show-POMessage 'There is no compatible system change to apply for this profile.'; return }
    $simulation = [bool](Get-POControl 'SimulationModeCheck').IsChecked
    if (-not $simulation) {
        $planWarnings = @($script:poCurrentPlan.Warnings)
        $riskDetails = if ($planWarnings.Count -gt 0) { $planWarnings -join ' ' } else { 'No profile-specific heat or power warning was identified for this plan; its behavior still depends on Windows, firmware, and workload.' }
        $warning = "Profile: $($script:poCurrentPlan.ProfileName)`nChange: activate the existing $($script:poCurrentPlan.TargetPowerPlanName) Windows power plan.`nRisk classification: $($script:poCurrentPlan.Change.Risk). $riskDetails`nNo FPS improvement is guaranteed.`nBackup: a timestamped local snapshot will be created first.`nRollback: restore the previous active plan from Restore Center.`n`nProceed?"
        if (-not (Confirm-POAction -Text $warning -Title 'Review exact change')) { return }
        if ($script:poCurrentPlan.RequiresHighRiskConfirmation) {
            if (-not (Confirm-POAction -Text 'MAXIMUM PERFORMANCE WARNING`n`nThis may increase heat, fan noise, and energy use. Do not continue if the device is hot. This does not disable thermal protection, but no thermal sensor is assumed available.`n`nExplicitly apply this profile?' -Title 'Advanced power warning')) { return }
        }
    }
    try {
        if ($simulation) {
            $result = Invoke-POProfilePlan -Plan $script:poCurrentPlan -WhatIf
        }
        else {
            $result = Invoke-POProfilePlan -Plan $script:poCurrentPlan -Confirm:$false -ConfirmAdvanced:$true
        }
        $message = "$($result.Status): $($result.Message)"
        if ($result.Backup) { $message += "`nBackup: $($result.Backup.Id)" }
        if ($result.Rollback) { $message += "`nRollback: $($result.Rollback)" }
        (Get-POControl 'ApplyStatusText').Text = $message
        Set-POFooter $message $(if ($result.Status -like '*FAILED*') { 'error' } elseif ($result.Status -like '*APPLIED*') { 'good' } else { 'normal' })
        Write-POLog -Category 'Profile' -Status $result.Status -Message $message
        if ($result.Status -eq 'APPLIED_VERIFIED') {
            Refresh-POHome
            Refresh-POBackups
        }
    }
    catch {
        (Get-POControl 'ApplyStatusText').Text = $_.Exception.Message
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Action was not applied' -Icon Error
    }
}

function Refresh-POAdapters {
    $script:poAdapters = @(Get-PONetworkAdapters)
    $combo = Get-POControl 'AdapterCombo'
    $queryFailure = @($script:poAdapters | Where-Object { $_.Status -eq 'QUERY FAILED' } | Select-Object -First 1)
    $combo.ItemsSource = $null
    if ($queryFailure.Count -gt 0) {
        $script:poAdapters = @()
        $combo.ItemsSource = @()
        (Get-POControl 'AdapterDetailsText').Text = "Network adapter inventory failed: $($queryFailure[0].IPv4DnsReadError)"
        (Get-POControl 'DnsStatusText').Text = 'DNS changes are disabled because adapter inventory could not be verified.'
        (Get-POControl 'ApplyDnsButton').IsEnabled = $false
        return
    }
    $combo.ItemsSource = $script:poAdapters
    $combo.DisplayMemberPath = 'Name'
    $combo.SelectedValuePath = 'InterfaceIndex'
    if ($script:poAdapters.Count -gt 0) { $combo.SelectedIndex = 0; (Get-POControl 'ApplyDnsButton').IsEnabled = $true }
    else { (Get-POControl 'AdapterDetailsText').Text = 'No connected adapters were reported. This is not proof that no network interfaces are installed.'; (Get-POControl 'ApplyDnsButton').IsEnabled = $false }
}

function Update-POAdapterDetails {
    $selected = (Get-POControl 'AdapterCombo').SelectedItem
    if (-not $selected) { (Get-POControl 'AdapterDetailsText').Text = 'No adapter selected.'; return }
    $ipv4DnsText = if ($selected.IPv4DnsReadable) { @($selected.IPv4DnsServers) -join ', ' } else { "Unknown; query failed: $($selected.IPv4DnsReadError)" }
    $ipv6DnsText = if ($selected.IPv6DnsReadable) { @($selected.IPv6DnsServers) -join ', ' } else { "Unknown; query failed: $($selected.IPv6DnsReadError)" }
    $text = "Index $($selected.InterfaceIndex) | $($selected.Description)`nStatus $($selected.Status) | physical $($selected.HardwareInterface) | link $($selected.LinkSpeed) | DHCP $($selected.DhcpEnabled)`nIPv4: $(@($selected.IPv4Addresses) -join ', ')`nGateway: $(Format-POValue $selected.Gateway)`nDNS mode IPv4: $($selected.DnsConfigState) | $($selected.DnsConfigDetail)`nDNS IPv4: $ipv4DnsText`nDNS IPv6 (not changed): $ipv6DnsText"
    (Get-POControl 'AdapterDetailsText').Text = $text
}

function Invoke-POPingFromUi {
    $target = [string](Get-POControl 'PingHostBox').Text
    (Get-POControl 'PingResultText').Text = 'Running ICMP test...'
    $yieldToUi = [System.Action] {}
    [void]$script:poWindow.Dispatcher.Invoke($yieldToUi, [System.Windows.Threading.DispatcherPriority]::Background)
    try {
        $result = Invoke-PONetworkPingTest -HostName $target -Count 4
        $output = "Target: $($result.Target)`nReceived: $($result.Received)/$($result.Sent) | Packet loss: $($result.PacketLossPercent)%`nAverage: $(Format-POValue $result.AverageMs 'ms') | min $(Format-POValue $result.MinMs 'ms') | max $(Format-POValue $result.MaxMs 'ms')`n$($result.Note)"
        if ($result.Error) { $output += "`nError: $($result.Error)" }
        (Get-POControl 'PingResultText').Text = $output
        Set-POFooter 'ICMP test complete | network path and server selection affect results' 'good'
    }
    catch { (Get-POControl 'PingResultText').Text = $_.Exception.Message; Set-POFooter $_.Exception.Message 'error' }
}

function Invoke-POApplyDnsFromUi {
    $selected = (Get-POControl 'AdapterCombo').SelectedItem
    if (-not $selected) { Show-POMessage 'Select a connected adapter first.'; return }
    $provider = [string](Get-POControl 'DnsProviderCombo').SelectedValue
    if (-not $provider) { Show-POMessage 'Select a DNS provider.'; return }
    $custom = @()
    if ($provider -eq 'Custom') { $custom = @(([string](Get-POControl 'CustomDnsText').Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $dnsText = if ($provider -eq 'Custom') { $custom -join ', ' } else { $provider }
    if ($provider -eq 'Custom') {
        $validation = Test-POIPv4DnsAddresses -Addresses $custom
        if (-not $validation.Valid) { Show-POMessage -Text $validation.Message -Title 'Invalid custom DNS' -Icon Warning; return }
        $custom = @($validation.Addresses)
        $dnsText = $custom -join ', '
    }
    $currentDns = Get-POCurrentAdapterDns -InterfaceIndex ([int]$selected.InterfaceIndex)
    $eligibility = Test-POAdapterDnsEligibility -AdapterState $currentDns
    if (-not $eligibility.Eligible) { Show-POMessage -Text ($eligibility.Reasons -join "`n") -Title 'DNS change blocked' -Icon Warning; return }
    if ($provider -eq 'Automatic') { (Get-POControl 'DnsStatusText').Text = 'No change needed | this adapter already uses verified automatic/DHCP DNS.'; return }
    $currentDnsText = @($currentDns.IPv4DnsServers) -join ', '
    $beforeText = "Current IPv4 DNS: $currentDnsText | mode $($currentDns.DnsConfigState) | DHCP $($currentDns.DhcpEnabled)"
    $confirm = "Adapter: $($currentDns.InterfaceAlias) ($($currentDns.InterfaceDescription))`n$beforeText`nProvider: $dnsText`nOnly IPv4 DNS on this connected physical adapter will change, and only after DHCP plus automatic DNS mode are verified. IPv6, DHCP address assignment, other adapters, VPNs, and static/managed/unknown DNS configurations remain untouched.`nA timestamped backup is created first; failure triggers a verified reset to DHCP-provided DNS.`nThis may change name-resolution behavior, not game-server routing or in-game ping.`n`nContinue?"
    if (-not (Confirm-POAction -Text $confirm -Title 'Confirm DNS change')) { return }
    $expectedDnsServers = @($currentDns.IPv4DnsServers)
    try {
        $result = Set-PODnsProvider -InterfaceIndex ([int]$selected.InterfaceIndex) -Provider $provider -CustomServers $custom -ExpectedInterfaceGuid $currentDns.InterfaceGuid -ExpectedIPv4DnsServers $expectedDnsServers -Confirm:$false
        (Get-POControl 'DnsStatusText').Text = "$($result.Status): $($result.Message)"
        Set-POFooter "$($result.Status): $($result.Message)" $(if ($result.Status -like '*FAILED*') { 'error' } else { 'good' })
        if ($result.Backup) { Refresh-POBackups }
        Refresh-POAdapters
    }
    catch {
        (Get-POControl 'DnsStatusText').Text = $_.Exception.Message
        Set-POFooter $_.Exception.Message 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'DNS change blocked' -Icon Warning
    }
}

function Refresh-POBackups {
    $grid = Get-POControl 'BackupsGrid'
    try {
        $script:poBackups = @(Get-POBackups)
        $grid.ItemsSource = $null
        $grid.ItemsSource = $script:poBackups
        (Get-POControl 'BackupDetailText').Text = if ($script:poBackups.Count -gt 0) { 'Select a backup. VALID means its manifest and recorded files pass checksum validation.' } else { 'No backups have been created yet.' }
        Set-POFooter 'Backup inventory verified' 'good'
    }
    catch {
        $script:poBackups = @()
        $grid.ItemsSource = $null
        (Get-POControl 'BackupDetailText').Text = "Backup inventory unavailable: $($_.Exception.Message)"
        foreach ($buttonName in @('RestoreBackupButton','ExportBackupButton','DeleteBackupButton')) { (Get-POControl $buttonName).IsEnabled = $false }
        Set-POFooter $_.Exception.Message 'error'
    }
}

function Update-POSelectedBackup {
    $item = (Get-POControl 'BackupsGrid').SelectedItem
    $canSelect = [bool]$item
    (Get-POControl 'RestoreBackupButton').IsEnabled = $canSelect -and $item.Status -eq 'VALID' -and $item.ChangeCount -gt 0
    (Get-POControl 'ExportBackupButton').IsEnabled = $canSelect -and $item.Status -eq 'VALID'
    (Get-POControl 'DeleteBackupButton').IsEnabled = $canSelect
    if ($canSelect) {
        $validation = Test-POBackup -Path $item.Path
        $manifest = $validation.Manifest
        $changes = @()
        if ($manifest) {
            foreach ($change in @($manifest.changes)) {
                $resultDetail = if ($change.resultMessage) { "`n  $($change.resultMessage)" } else { '' }
                $changes += "- $($change.name) - $($change.section) - status $($change.status) - $($change.timestampUtc)$resultDetail"
            }
        }
        $details = "Backup: $($item.Id)`nStatus: $($item.Status)`nCreated: $($item.CreatedAt)`nRecorded changes: $($item.ChangeCount)`n" + ($changes -join "`n")
        if (@($item.Issues).Count) { $details += "`nValidation issues: $(@($item.Issues) -join '; ')" }
        if ($manifest -and @($manifest.warnings).Count) { $details += "`nWarnings: $(@($manifest.warnings) -join '; ')" }
        (Get-POControl 'BackupDetailText').Text = $details
    }
}

function Refresh-POProfileCatalogUi {
    $rows = @()
    foreach ($profile in (Get-POProfiles)) {
        $rows += "* $($profile.name)`n$($profile.description)`nRisk ceiling: $($profile.riskCeiling) | reboot: no profile change requires a reboot`nManual review: $(@($profile.manualRecommendations) -join ', ')`n$(@($profile.notes) -join ' ')"
    }
    (Get-POControl 'ProfilesList').ItemsSource = $rows
}

function Refresh-POTweaksUi {
    $query = [string](Get-POControl 'TweakSearchBox').Text
    $rows = @()
    foreach ($tweak in (Get-POTweakCatalog)) {
        $haystack = "$($tweak.name) $($tweak.category) $($tweak.description) $($tweak.purpose)"
        if (-not [string]::IsNullOrWhiteSpace($query) -and $haystack -notmatch [regex]::Escape($query)) { continue }
        $rows += "[$($tweak.risk)] $($tweak.name)  |  $($tweak.category)`nWHAT: $($tweak.description)`nWHY: $($tweak.purpose)`nEXPECTED: $($tweak.expectedBenefit)`nSUPPORTED: $(@($tweak.supportedVersions) -join ', ')  |  ADMIN: $($tweak.requiresAdmin)  |  REBOOT: $($tweak.requiresReboot)`nROLLBACK: $($tweak.rollbackMethod)`nSTATUS: $(if ($tweak.operation -eq 'OpenWindowsSettings') { 'User-controlled Windows Settings' } elseif ($tweak.operation -eq 'PreviewUserTempCleanup') { 'Manual and irreversible; never automatic' } else { 'Preview required' })"
    }
    (Get-POControl 'TweakCatalogList').ItemsSource = $rows
}

function Refresh-POGames {
    $grid = Get-POControl 'GamesGrid'
    $grid.ItemsSource = $null
    $grid.ItemsSource = @(Get-POInstalledGames)
    $guidance = @()
    foreach ($game in (Get-POGameCatalog)) {
        $guidance += "- $($game.name): $(@($game.focus) -join ' ' )"
    }
    (Get-POControl 'GameGuidanceList').ItemsSource = $guidance
}

function Update-POServiceRowsView {
    $query = [string](Get-POControl 'ServiceSearchBox').Text
    $items = if ($query) { @($script:poServices | Where-Object { ("$($_.Name) $($_.DisplayName) $($_.Classification)") -match [regex]::Escape($query) }) } else { $script:poServices }
    (Get-POControl 'ServicesGrid').ItemsSource = $null
    (Get-POControl 'ServicesGrid').ItemsSource = $items
}

function Refresh-POServiceRows {
    $script:poServices = @(Get-POServiceAudit)
    Update-POServiceRowsView
}

function Refresh-POStartupRows {
    (Get-POControl 'StartupGrid').ItemsSource = $null
    (Get-POControl 'StartupGrid').ItemsSource = @(Get-POStartupAudit)
}

function Refresh-POAppxRows {
    (Get-POControl 'AppxGrid').ItemsSource = $null
    (Get-POControl 'AppxGrid').ItemsSource = @(Get-POAppxInventory)
}

function Refresh-POTasks {
    (Get-POControl 'TasksGrid').ItemsSource = $null
    $rows = @(Get-POScheduledTaskAudit -MaximumTasks 1000)
    (Get-POControl 'TasksGrid').ItemsSource = $rows
    $unavailable = @($rows | Where-Object { $_.TaskName -eq 'Inventory unavailable' })
    if ($unavailable.Count -gt 0) { (Get-POControl 'DiagnosticsOutput').Text = [string]$unavailable[0].Action }
    else { (Get-POControl 'DiagnosticsOutput').Text = "Read-only scheduled task inventory: $($rows.Count) tasks. Impact is not measured. No task is disabled or removed." }
}

function Capture-POBenchmark {
    param([ValidateSet('before','after')][string]$Label)
    (Get-POControl 'DiagnosticsOutput').Text = "Sampling for five seconds ($Label)..."
    $yieldToUi = [System.Action] {}
    [void]$script:poWindow.Dispatcher.Invoke($yieldToUi, [System.Windows.Threading.DispatcherPriority]::Background)
    try {
        $snapshot = Get-POBenchmarkSnapshot -SampleSeconds 5
        $file = Save-POBenchmarkSnapshot -Label $Label -Snapshot $snapshot
        if ($Label -eq 'before') { $script:poBeforeBenchmark = $snapshot } else { $script:poAfterBenchmark = $snapshot }
        $rendered = $snapshot | ConvertTo-Json -Depth 9
        (Get-POControl 'DiagnosticsOutput').Text = "Saved $Label sample to:`n$file`n`n$rendered"
        if ($script:poBeforeBenchmark -and $script:poAfterBenchmark) {
            $comparison = Compare-POBenchmarkSnapshots -Before $script:poBeforeBenchmark -After $script:poAfterBenchmark
            $grid = Get-POControl 'BenchmarkGrid'
            $grid.ItemsSource = $null
            $grid.ItemsSource = @($comparison.Metrics)
            (Get-POControl 'BenchmarkScoreText').Text = $comparison.GamingPerformanceScore
        }
        Set-POFooter "$Label system sample captured | not a controlled in-game benchmark" 'good'
    }
    catch { (Get-POControl 'DiagnosticsOutput').Text = $_.Exception.Message; Set-POFooter $_.Exception.Message 'error' }
}

function Refresh-POBcdDiagnostics {
    $audit = Get-POBcdAudit
    $lines = @("BCD status: $($audit.Message)")
    foreach ($setting in @($audit.Settings)) {
        $lines += "$($setting.Setting)  |  current: $($setting.Current)  |  default: $($setting.Default)  |  recommendation: $($setting.Recommendation)"
    }
    $lines += 'The optimizer does not write BCD values.'
    (Get-POControl 'DiagnosticsOutput').Text = $lines -join "`n"
}

function Update-POCustomDnsEnabled {
    $enabled = ((Get-POControl 'DnsProviderCombo').SelectedValue -eq 'Custom')
    (Get-POControl 'CustomDnsText').IsEnabled = $enabled
}

function Start-POElevated {
    if (Test-POIsAdministrator) { Show-POMessage 'This session is already elevated.'; return }
    $powershell = Join-Path $PSHOME 'powershell.exe'
    $argumentLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $script:EntryScriptPath
    try {
        Start-Process -FilePath $powershell -ArgumentList $argumentLine -Verb RunAs -ErrorAction Stop | Out-Null
        $script:poWindow.Close()
    }
    catch { Show-POMessage -Text "Elevation was cancelled or unavailable. The current read-only session remains open.`n$($_.Exception.Message)" -Title 'Administrator restart not completed' -Icon Warning }
}

# Populate static UI data and wire events.
Set-POProfileChoices
Refresh-POProfileCatalogUi
Refresh-POTweaksUi
$navButtons = @('Home','Optimize','Power','Audio','Display','Profiles','Tweaks','Games','Hardware','Network','Input','Storage','Debloat','Services','Startup','Diagnostics','Restore','Settings')
foreach ($page in $navButtons) {
    $nav = $script:poWindow.FindName('Nav' + $page)
    if ($nav) { $nav.Add_Click({ param($sender, $eventArgs) Set-POPage -Page ([string]$sender.Tag) }) }
}

(Get-POControl 'RescanButton').Add_Click({ Refresh-POHome })
(Get-POControl 'OptimizeNowButton').Add_Click({ Invoke-POAutoGamingOptimize })
(Get-POControl 'BaselineButton').Add_Click({ Set-POPage 'Diagnostics'; Capture-POBenchmark -Label 'before' })

# Power plan (Platinum On Steroids) wiring.
(Get-POControl 'RefreshPowerButton').Add_Click({ try { Refresh-POPowerPage } catch { Set-POFooter $_.Exception.Message 'error' } })
(Get-POControl 'CreatePlatinumPlanButton').Add_Click({ Invoke-POCreatePlatinumPlanFromUi })
(Get-POControl 'ApplyPlatinumPresetButton').Add_Click({ Invoke-POApplyPlatinumPresetFromUi })
(Get-POControl 'ActivatePlatinumButton').Add_Click({ Invoke-POActivatePlatinumFromUi })
(Get-POControl 'RestorePowerPlanButton').Add_Click({ Invoke-PORestorePowerPlanFromUi })
(Get-POControl 'OpenPowerSettingsButton').Add_Click({ try { Start-Process control.exe -ArgumentList 'powercfg.cpl' -ErrorAction Stop } catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open power settings' -Icon Error } })

# Audio wiring.
(Get-POControl 'RefreshAudioButton').Add_Click({ Refresh-POAudioPage })
(Get-POControl 'AudioPresetCombo').Add_SelectionChanged({ Update-POAudioPresetExplanation })
(Get-POControl 'ApplyAudioPresetButton').Add_Click({ Invoke-POApplyAudioPresetFromUi })
(Get-POControl 'RestoreAudioButton').Add_Click({ Invoke-PORestoreAudioFromUi })
(Get-POControl 'OpenSoundSettingsButton').Add_Click({ try { Open-POWindowsSettings -Uri 'ms-settings:sound' } catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open Settings' -Icon Error } })
(Get-POControl 'OpenMmsysButton').Add_Click({ try { Start-Process rundll32.exe -ArgumentList 'shell32.dll,Control_RunDLL mmsys.cpl,,0' -ErrorAction Stop } catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open Sound Control Panel' -Icon Error } })

# Display wiring.
(Get-POControl 'RefreshDisplaysButton').Add_Click({ Refresh-PODisplayPage })
(Get-POControl 'DisplayProfileCombo').Add_SelectionChanged({ Update-PODisplayProfileExplanation })
(Get-POControl 'ApplyDisplayProfileButton').Add_Click({ Invoke-POApplyDisplayProfileFromUi })
(Get-POControl 'RestoreDisplayButton').Add_Click({ Invoke-PORestoreDisplayFromUi })
(Get-POControl 'OpenDisplaySettingsButton').Add_Click({ try { Open-POWindowsSettings -Uri 'ms-settings:display' } catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open Settings' -Icon Error } })
(Get-POControl 'OpenColorManagementButton').Add_Click({ try { Start-Process colorcpl.exe -ErrorAction Stop } catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open Color Management' -Icon Error } })
(Get-POControl 'PreviewProfileButton').Add_Click({ Show-POProfilePlan })
(Get-POControl 'ApplyProfileButton').Add_Click({ Invoke-POApplyProfile })
(Get-POControl 'CancelProfileButton').Add_Click({
    $script:poCurrentPlan = $null
    (Get-POControl 'PreviewHeadline').Text = 'Select a profile to start a compatibility check.'
    (Get-POControl 'PreviewChange').Text = 'None'
    (Get-POControl 'PreviewWarnings').Text = 'None'
    (Get-POControl 'PreviewRecommendations').ItemsSource = @()
    (Get-POControl 'ApplyProfileButton').IsEnabled = $false
    Set-POFooter 'Preview cleared | no changes applied' 'normal'
})
(Get-POControl 'SimulationModeCheck').Add_Click({
    $button = Get-POControl 'ApplyProfileButton'
    $button.Content = if ((Get-POControl 'SimulationModeCheck').IsChecked) { 'Run simulation' } else { 'Apply reviewed profile' }
    (Get-POControl 'ApplyStatusText').Text = if ((Get-POControl 'SimulationModeCheck').IsChecked) { 'Simulation mode: no backup or Windows setting will be changed.' } else { 'Apply creates a timestamped local backup first.' }
})
(Get-POControl 'ProfileCombo').Add_SelectionChanged({ if ($script:poCurrentPlan) { Show-POProfilePlan } })
(Get-POControl 'TweakSearchBox').Add_TextChanged({ Refresh-POTweaksUi })
(Get-POControl 'RefreshGamesButton').Add_Click({ Refresh-POGames })
(Get-POControl 'AddCustomGameButton').Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Game executable or shortcut (*.exe;*.lnk)|*.exe;*.lnk|Executables (*.exe)|*.exe|Shortcuts (*.lnk)|*.lnk'
    $dialog.Title = 'Add a game to the local library'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try { [void](Add-POCustomGame -ExecutablePath $dialog.FileName); Refresh-POGames; Set-POFooter 'Custom game saved locally; no game files changed' 'good' }
        catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not add game' -Icon Error }
    }
})
(Get-POControl 'RefreshAdaptersButton').Add_Click({ Refresh-POAdapters })
(Get-POControl 'AdapterCombo').Add_SelectionChanged({ Update-POAdapterDetails })
(Get-POControl 'DnsProviderCombo').Add_SelectionChanged({ Update-POCustomDnsEnabled })
(Get-POControl 'ApplyDnsButton').Add_Click({ Invoke-POApplyDnsFromUi })
(Get-POControl 'PingButton').Add_Click({ Invoke-POPingFromUi })
(Get-POControl 'RunNetworkTestButton').Add_Click({ Set-POPage 'Network'; Invoke-POPingFromUi })
(Get-POControl 'AuditTasksButton').Add_Click({ Refresh-POTasks })
(Get-POControl 'RefreshServicesButton').Add_Click({ Refresh-POServiceRows })
(Get-POControl 'AuditBcdButton').Add_Click({ Refresh-POBcdDiagnostics })
(Get-POControl 'OpenMouseSettingsButton').Add_Click({ try { Open-POWindowsSettings -Uri 'ms-settings:mouse' } catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open Settings' -Icon Error } })
(Get-POControl 'OpenStartupSettingsButton').Add_Click({ try { Open-POWindowsSettings -Uri 'ms-settings:startupapps' } catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open Settings' -Icon Error } })
(Get-POControl 'OpenGameModeSettingsButton').Add_Click({ try { Open-POWindowsSettings -Uri 'ms-settings:gaming-gamemode' } catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open Settings' -Icon Error } })
(Get-POControl 'OpenCaptureSettingsButton').Add_Click({ try { Open-POWindowsSettings -Uri 'ms-settings:gaming-captures' } catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open Settings' -Icon Error } })
(Get-POControl 'OpenGraphicsSettingsButton').Add_Click({ try { Open-POWindowsSettings -Uri 'ms-settings:display-advancedgraphics' } catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open Settings' -Icon Error } })
(Get-POControl 'RefreshStartupButton').Add_Click({ Refresh-POStartupRows })
(Get-POControl 'RefreshAppxButton').Add_Click({ Refresh-POAppxRows })
(Get-POControl 'ServiceSearchBox').Add_TextChanged({ Update-POServiceRowsView })
(Get-POControl 'CaptureBeforeButton').Add_Click({ Capture-POBenchmark -Label 'before' })
(Get-POControl 'CaptureAfterButton').Add_Click({ Capture-POBenchmark -Label 'after' })
(Get-POControl 'PreviewTempButton').Add_Click({
    try {
        $script:poTempPreview = Get-POUserTempPreview -MinimumAgeDays 7
        $previewErrors = @($script:poTempPreview.Errors)
        $previewStatus = "Preview: $($script:poTempPreview.FileCount) files | $([math]::Round($script:poTempPreview.TotalBytes / 1MB, 1)) MB | older than 7 days"
        if ($script:poTempPreview.SkippedReparsePoints -gt 0) { $previewStatus += " | skipped $($script:poTempPreview.SkippedReparsePoints) reparse points" }
        if ($previewErrors.Count -gt 0) { $previewStatus += " | INCOMPLETE ($($previewErrors.Count) inspection errors): $(@($previewErrors | Select-Object -First 3) -join '; ')" }
        (Get-POControl 'TempStatusText').Text = $previewStatus
        (Get-POControl 'CleanTempButton').IsEnabled = ($script:poTempPreview.FileCount -gt 0 -and $previewErrors.Count -eq 0)
        if ($previewErrors.Count -gt 0) { Set-POFooter 'Temporary-file preview incomplete | cleanup disabled until a complete preview succeeds' 'warning' }
        else { Set-POFooter 'Temporary-file preview ready | irreversible deletion is never automatic' 'warning' }
    }
    catch { Show-POMessage -Text $_.Exception.Message -Title 'Cleanup preview refused' -Icon Warning }
})
(Get-POControl 'CleanTempButton').Add_Click({
    if (-not $script:poTempPreview) { return }
    $confirm = "This permanently deletes $($script:poTempPreview.FileCount) files ($( [math]::Round($script:poTempPreview.TotalBytes / 1MB, 1) ) MB) older than seven days from:`n$($script:poTempPreview.Root)`n`nDeletion is not reversible. Continue?"
    if (Confirm-POAction -Text $confirm -Title 'Confirm temporary file deletion') {
        try {
            $result = Clear-POUserTemp -Preview $script:poTempPreview -Confirm:$false
            $cleanupErrors = @($result.Errors)
            $cleanupStatus = "$($result.Status) | deleted $($result.Deleted); errors $($cleanupErrors.Count)"
            if ($cleanupErrors.Count -gt 0) { $cleanupStatus += "`n" + (@($cleanupErrors | Select-Object -First 5) -join "`n") }
            (Get-POControl 'TempStatusText').Text = $cleanupStatus
            (Get-POControl 'CleanTempButton').IsEnabled = $false
            Set-POFooter "Temporary cleanup: $($result.Status) | deleted $($result.Deleted); errors $($cleanupErrors.Count)" $(if ($cleanupErrors.Count -gt 0) { 'warning' } else { 'good' })
        }
        catch { Show-POMessage -Text $_.Exception.Message -Title 'Cleanup failed' -Icon Error }
    }
})
(Get-POControl 'RefreshBackupsButton').Add_Click({ Refresh-POBackups })
(Get-POControl 'BackupsGrid').Add_SelectionChanged({ Update-POSelectedBackup })
(Get-POControl 'RestoreBackupButton').Add_Click({
    $item = (Get-POControl 'BackupsGrid').SelectedItem
    if (-not $item) { return }
    if (-not (Confirm-POAction -Text "Restore recorded optimizer changes from $($item.Id)?`nOnly sections changed by Platinum Optimizer will be touched." -Title 'Restore backup')) { return }
    try {
        $result = Restore-POBackup -BackupPath $item.Path -Confirm:$false
        $message = "$($result.Status): $($result.Message)"
        if ($result.Failures) { $message += "`n$(@($result.Failures) -join "`n")" }
        (Get-POControl 'BackupDetailText').Text = $message
        Set-POFooter $message $(if ($result.Status -eq 'RESTORED') { 'good' } else { 'error' })
        Refresh-POHome
        Refresh-POBackups
    }
    catch { Show-POMessage -Text $_.Exception.Message -Title 'Restore did not complete' -Icon Error; Set-POFooter $_.Exception.Message 'error' }
})
(Get-POControl 'DeleteBackupButton').Add_Click({
    $item = (Get-POControl 'BackupsGrid').SelectedItem
    if ($item -and (Confirm-POAction -Text "Permanently delete backup $($item.Id)? This does not change the current Windows settings." -Title 'Delete backup')) {
        try { [void](Remove-POBackup -BackupPath $item.Path -Confirm:$false); Refresh-POBackups; Set-POFooter 'Backup deleted' 'good' }
        catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not delete backup' -Icon Error }
    }
})
(Get-POControl 'ExportBackupButton').Add_Click({
    $item = (Get-POControl 'BackupsGrid').SelectedItem
    if (-not $item) { return }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'ZIP archive (*.zip)|*.zip'
    $dialog.FileName = ($item.Id + '.zip')
    $dialog.Title = 'Export local backup (unencrypted)'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $result = Export-POBackup -BackupPath $item.Path -DestinationPath $dialog.FileName -Confirm:$false
            Show-POMessage -Text "Exported unencrypted archive:`n$($result.Path)`n`nIt contains local system and adapter metadata. Store it privately."
        }
        catch { Show-POMessage -Text $_.Exception.Message -Title 'Backup export failed' -Icon Error }
    }
})
(Get-POControl 'OpenDataFolderButton').Add_Click({
    try {
        $path = Get-POStateRoot
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $path)
    }
    catch { Show-POMessage -Text $_.Exception.Message -Title 'Could not open local folder' -Icon Error }
})
(Get-POControl 'RunAsAdminButton').Add_Click({ Start-POElevated })
(Get-POControl 'MonitorToggle').Add_Checked({
    if (-not $script:poMonitorTimer) {
        $script:poMonitorTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:poMonitorTimer.Interval = [TimeSpan]::FromSeconds(2.5)
        $script:poMonitorTimer.Add_Tick({
            try {
                $sample = Get-POResourceSample
                $cpu = Format-POValue $sample.CpuPercent '%'
                $ram = Format-POValue $sample.AvailableMemoryGB 'GB available'
                $disk = Format-POValue $sample.DiskActivePercent '% disk active'
                (Get-POControl 'LiveSampleText').Text = "CPU  $cpu`nRAM  $ram`nDISK  $disk`nGPU  Not measured | PING  Run a test on demand`nSampled $($sample.SampledAtUtc)"
            }
            catch { (Get-POControl 'LiveSampleText').Text = "Monitoring unavailable: $($_.Exception.Message)" }
        })
    }
    $script:poMonitorTimer.Start()
})
(Get-POControl 'MonitorToggle').Add_Unchecked({ if ($script:poMonitorTimer) { $script:poMonitorTimer.Stop() }; (Get-POControl 'LiveSampleText').Text = 'Monitoring is off. No background sampling is running.' })
$script:poWindow.Add_Closing({ if ($script:poMonitorTimer) { $script:poMonitorTimer.Stop() } })

# Show the window before the first hardware scan; page-specific inventories load only when requested.
Update-POCustomDnsEnabled
Set-POPage 'Home'
Set-POFooter 'Window ready | loading the first read-only system snapshot...' 'normal'
$script:poStartupTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:poStartupTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:poStartupTimer.Add_Tick({
    $script:poStartupTimer.Stop()
    try { Refresh-POHome }
    catch { Set-POFooter "Initial system inventory failed: $($_.Exception.Message)" 'error' }
})
$script:poStartupTimer.Start()
[void]$script:poWindow.ShowDialog()
