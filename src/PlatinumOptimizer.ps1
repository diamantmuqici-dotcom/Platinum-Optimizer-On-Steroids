#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Scan,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:EntryScriptPath = $PSCommandPath
$modulePath = Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Core.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

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
    $pages = @('Home','Optimize','Profiles','Tweaks','Games','Hardware','Network','Input','Storage','Debloat','Services','Startup','Diagnostics','Restore','Settings')
    foreach ($name in $pages) {
        $control = $script:poWindow.FindName($name + 'Panel')
        if ($control) { $control.Visibility = if ($name -eq $Page) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }
        $nav = $script:poWindow.FindName('Nav' + $name)
        if ($nav) { $nav.Background = if ($name -eq $Page) { [Windows.Media.Brushes]::DarkSlateGray } else { [Windows.Media.Brushes]::Transparent } }
    }
    $titles = @{
        Home = @('Home', 'System status, hardware summary, and honest readiness facts.')
        Optimize = @('Optimize', 'Preview, validate, back up, apply, verify, and restore.')
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

function Invoke-POAutoGamingOptimize {
    [CmdletBinding()]
    param()

    if (-not (Test-POIsAdministrator)) { Start-POElevated; return }

    $started = Get-Date
    $results = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]

    try {
        Set-POFooter 'Gaming optimization: preparing system...' 'normal'
        (Get-POControl 'ReadinessTitle').Text = 'Gaming optimization in progress...'
        (Get-POControl 'ReadinessDetail').Text = 'Applying supported Windows gaming settings. No game files are modified.'

        # Use the existing Gaming plan engine, but remove the manual profile-selection step.
        try {
            $snapshot = Get-POSystemSnapshot
            $plans = @(Get-POPowerPlans)
            $active = Get-POActivePowerPlanGuid
            $plan = New-POProfilePlan -ProfileId 'gaming' -SystemSnapshot $snapshot -PowerPlans $plans -ActivePlanGuid $active
            if ($plan.Change) {
                $result = Invoke-POProfilePlan -Plan $plan -Confirm:$false -ConfirmAdvanced:$true
                if ($result.Status -like '*APPLIED*') { [void]$results.Add("Power policy: $($plan.TargetPowerPlanName)") }
                else { [void]$errors.Add("Power policy: $($result.Message)") }
            } else { [void]$results.Add('Power policy: already optimal or no compatible performance plan available') }
        } catch { [void]$errors.Add("Power policy: $($_.Exception.Message)") }

        # Restore the supported Windows TCP/RSS baseline instead of obsolete registry hacks.
        if (Get-Command netsh.exe -ErrorAction SilentlyContinue) {
            try {
                & netsh.exe int tcp set global rss=enabled | Out-Null
                & netsh.exe int tcp set global autotuninglevel=normal | Out-Null
                & netsh.exe int tcp set global ecncapability=disabled | Out-Null
                & netsh.exe int tcp set global timestamps=disabled | Out-Null
                [void]$results.Add('TCP baseline: RSS enabled, autotuning normal, ECN disabled, timestamps disabled')
            } catch { [void]$errors.Add("TCP baseline: $($_.Exception.Message)") }
        }

        try { & ipconfig.exe /flushdns | Out-Null; [void]$results.Add('DNS cache: flushed') }
        catch { [void]$errors.Add("DNS cache: $($_.Exception.Message)") }

        # Prevent an active physical Ethernet NIC from being power-managed away when supported.
        try {
            $ethernetAdapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and [string]$_.InterfaceDescription -notmatch '(?i)wi-?fi|wireless|802\.11|bluetooth' })
            if ($ethernetAdapters.Count -gt 0 -and (Get-Command Set-NetAdapterPowerManagement -ErrorAction SilentlyContinue)) {
                foreach ($adapter in $ethernetAdapters) {
                    try {
                        Set-NetAdapterPowerManagement -Name $adapter.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
                        [void]$results.Add("Ethernet power management: kept active for $($adapter.Name)")
                    } catch { [void]$errors.Add("Ethernet $($adapter.Name): $($_.Exception.Message)") }
                }
            } elseif ($ethernetAdapters.Count -eq 0) {
                [void]$results.Add('Ethernet: no active physical Ethernet adapter detected')
            } else { [void]$results.Add('Ethernet: driver does not expose the Windows power-management control') }
        } catch { [void]$errors.Add("Ethernet detection: $($_.Exception.Message)") }

        $elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        $summary = "Gaming optimization complete in $elapsed s.$nl$nl" + ($results -join $nl)
        if ($errors.Count -gt 0) { $summary += "$nl$nlWarnings (non-fatal):$nl" + ($errors -join $nl) }
        (Get-POControl 'ReadinessTitle').Text = 'Gaming optimization complete'
        (Get-POControl 'ReadinessDetail').Text = 'The automatic gaming baseline is applied. Actual FPS and game-server ping still depend on hardware, drivers, the game, server and route.'
        (Get-POControl 'ScoreText').Text = 'Gaming score: NOT SCORED - run a real in-game benchmark to measure FPS/frame time.'
        Set-POFooter 'Gaming baseline applied · no game files modified' 'good'
        Show-POMessage -Text $summary -Title 'Platinum Optimizer - Gaming mode' -Icon Information
    } catch {
        Set-POFooter "Gaming optimization failed: $($_.Exception.Message)" 'error'
        Show-POMessage -Text $_.Exception.Message -Title 'Gaming optimization failed' -Icon Error
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
$navButtons = @('Home','Optimize','Profiles','Tweaks','Games','Hardware','Network','Input','Storage','Debloat','Services','Startup','Diagnostics','Restore','Settings')
foreach ($page in $navButtons) {
    $nav = $script:poWindow.FindName('Nav' + $page)
    if ($nav) { $nav.Add_Click({ param($sender, $eventArgs) Set-POPage -Page ([string]$sender.Tag) }) }
}

(Get-POControl 'RescanButton').Add_Click({ Refresh-POHome })
(Get-POControl 'OptimizeNowButton').Add_Click({ Invoke-POAutoGamingOptimize })
(Get-POControl 'BaselineButton').Add_Click({ Set-POPage 'Diagnostics'; Capture-POBenchmark -Label 'before' })
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
