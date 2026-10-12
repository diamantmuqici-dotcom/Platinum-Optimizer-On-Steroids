#requires -Version 5.1
# Automatic, foreground-only command-line workflow. This module deliberately
# keeps network, security, services, startup, display and capture settings
# read-only; the automatic writer is the verified Platinum power-plan path.
Set-StrictMode -Version 2.0

$script:POAutomaticModuleVersion = '2.0.1'

function Get-POAutomaticPropertyValue {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-POAutomaticAdapterKind {
    [CmdletBinding()]
    param([AllowNull()][string]$Name, [AllowNull()][string]$Description, [AllowNull()][string]$PhysicalMediaType)
    $text = '{0} {1} {2}' -f $Name, $Description, $PhysicalMediaType
    if ($text -match '(?i)wi-?fi|wireless|802\.11|wlan') { return 'Wi-Fi (inferred from Windows adapter metadata)' }
    if ($text -match '(?i)ethernet|802\.3|gigabit|10gbe|2\.5gbe') { return 'Ethernet (inferred from Windows adapter metadata)' }
    if ($text -match '(?i)bluetooth') { return 'Bluetooth (inferred from Windows adapter metadata)' }
    if ($text -match '(?i)vpn|virtual|hyper-v|vmware|virtualbox|tunnel|loopback') { return 'Virtual / VPN (inferred from Windows adapter metadata)' }
    return 'Unknown (adapter type not reliably identified)'
}

function New-POAutomaticRunContext {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Auto', 'Scan', 'Benchmark', 'Restore')][string]$Mode,
          [Parameter(Mandatory = $true)][string]$ApplicationVersion)
    $root = Get-POStateRoot
    $logRoot = Join-Path $root 'logs'
    $reportRoot = Join-Path $root 'reports'
    foreach ($directory in @($logRoot, $reportRoot)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
        }
    }
    $started = [DateTime]::UtcNow
    $runId = 'run_{0}_{1}' -f $started.ToString('yyyyMMddTHHmmssfffZ'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $logPath = Join-Path $logRoot ($runId + '.log')
    $reportPath = Join-Path $reportRoot ($runId + '.json')
    [System.IO.File]::WriteAllText($logPath, "Platinum Optimizer On Steroids $ApplicationVersion`r`nRun: $runId`r`nStarted UTC: $($started.ToString('o'))`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $context = [pscustomobject][ordered]@{
        RunId = $runId
        Mode = $Mode
        StartedUtc = $started
        LogPath = $logPath
        ReportPath = $reportPath
        Events = (New-Object System.Collections.ArrayList)
        Applied = (New-Object System.Collections.ArrayList)
        Restored = (New-Object System.Collections.ArrayList)
        AlreadyOptimized = (New-Object System.Collections.ArrayList)
        Skipped = (New-Object System.Collections.ArrayList)
        Failed = (New-Object System.Collections.ArrayList)
        Unverified = (New-Object System.Collections.ArrayList)
        Report = [pscustomobject][ordered]@{
            schemaVersion = 1
            application = 'Platinum Optimizer On Steroids'
            applicationVersion = $ApplicationVersion
            runId = $runId
            mode = $Mode
            status = 'RUNNING'
            startedAtUtc = $started.ToString('o')
            endedAtUtc = $null
            durationSeconds = $null
            administrator = $false
            windowsPowerShellVersion = [string]$PSVersionTable.PSVersion
            system = $null
            assessment = $null
            metrics = $null
            restorePoint = $null
            backup = $null
            recoverySource = $null
            changes = $null
            summary = $null
            summaryText = $null
            recommendations = @()
            logWriteError = $null
            rebootRecommended = $false
            logPath = $logPath
            reportPath = $reportPath
            events = @()
        }
    }
    return $context
}

function Write-POAutomaticEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Context,
          [Parameter(Mandatory = $true)][ValidateSet('INFO', 'PASS', 'WARN', 'SKIP', 'FAIL')][string]$Level,
          [Parameter(Mandatory = $true)][string]$Message,
          [AllowNull()][object]$Details)
    $colors = @{
        INFO = 'Gray'
        PASS = 'Green'
        WARN = 'Yellow'
        SKIP = 'DarkYellow'
        FAIL = 'Red'
    }
    $timestamp = [DateTime]::UtcNow.ToString('o')
    $prefix = '[' + $Level + ']'
    Write-Host ("{0} {1}" -f $prefix, $Message) -ForegroundColor $colors[$Level]
    $event = [pscustomobject][ordered]@{
        timestampUtc = $timestamp
        level = $Level
        message = $Message
        details = $Details
    }
    [void]$Context.Events.Add($event)
    $logLine = "{0} {1} {2}" -f $timestamp, $prefix, $Message
    try {
        [System.IO.File]::AppendAllText($Context.LogPath, $logLine + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        if (-not $Context.Report.logWriteError) { $Context.Report.logWriteError = $_.Exception.Message }
        Write-Host "[WARN] The run log could not be updated: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Add-POAutomaticChange {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Context,
          [Parameter(Mandatory = $true)][string]$Id,
          [Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][string]$Status,
          [switch]$Attempted,
          [switch]$Verified,
          [AllowNull()][object]$PreviousValue,
          [AllowNull()][object]$TargetValue,
          [string]$Reason = '',
          [bool]$RequiresReboot = $false)
    $entry = [pscustomobject][ordered]@{
        id = $Id
        name = $Name
        status = $Status
        attempted = [bool]$Attempted
        verified = [bool]$Verified
        previousValue = $PreviousValue
        targetValue = $TargetValue
        reason = $Reason
        requiresReboot = $RequiresReboot
        timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    if ($Status -eq 'RESTORED_VERIFIED') {
        [void]$Context.Restored.Add($entry)
    }
    elseif ($Status -in @('APPLIED_VERIFIED', 'APPLIED_VERIFIED_ACTIVATED')) {
        [void]$Context.Applied.Add($entry)
    }
    elseif ($Status -in @('ALREADY_OPTIMIZED', 'ALREADY_RESTORED', 'REUSED_VERIFIED')) {
        [void]$Context.AlreadyOptimized.Add($entry)
    }
    elseif ($Status -in @('UNVERIFIED', 'PARTIAL_FAILURE', 'APPLIED_UNVERIFIED')) {
        [void]$Context.Unverified.Add($entry)
    }
    elseif ($Status -in @('FAILED', 'ROLLBACK_FAILED')) {
        [void]$Context.Failed.Add($entry)
    }
    else {
        [void]$Context.Skipped.Add($entry)
    }
    return $entry
}

function Get-POAutomaticNetworkAssessment {
    [CmdletBinding()]
    param()
    $adapters = @()
    $queryStatus = 'Unavailable'
    $queryError = $null
    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        try {
            foreach ($adapter in @(Get-NetAdapter -ErrorAction Stop)) {
                $ifIndex = Get-POAutomaticPropertyValue -InputObject $adapter -Name 'ifIndex'
                $name = [string](Get-POAutomaticPropertyValue -InputObject $adapter -Name 'Name')
                $description = [string](Get-POAutomaticPropertyValue -InputObject $adapter -Name 'InterfaceDescription')
                $physicalMedia = [string](Get-POAutomaticPropertyValue -InputObject $adapter -Name 'NdisPhysicalMedium')
                $hardware = Get-POAutomaticPropertyValue -InputObject $adapter -Name 'HardwareInterface'
                $status = [string](Get-POAutomaticPropertyValue -InputObject $adapter -Name 'Status')
                $linkSpeed = [string](Get-POAutomaticPropertyValue -InputObject $adapter -Name 'LinkSpeed')
                $dnsStatus = 'Not queried'
                if ($null -ne $ifIndex -and (Get-Command Get-POCurrentAdapterDns -ErrorAction SilentlyContinue)) {
                    try {
                        $dns = Get-POCurrentAdapterDns -InterfaceIndex ([int]$ifIndex)
                        $dnsStatus = if ($dns.IPv4DnsReadable -and $dns.IPv6DnsReadable) { 'IPv4 and IPv6 DNS state readable' } elseif ($dns.IPv4DnsReadable) { 'IPv4 DNS readable; IPv6 state unavailable' } else { 'DNS state unknown' }
                    }
                    catch { $dnsStatus = 'DNS state query failed' }
                }
                $adapters += [pscustomobject][ordered]@{
                    InterfaceIndex = if ($null -ne $ifIndex) { [int]$ifIndex } else { $null }
                    Name = if ($name) { $name } else { 'Unknown adapter name' }
                    Description = if ($description) { $description } else { 'Unknown adapter description' }
                    Kind = Get-POAutomaticAdapterKind -Name $name -Description $description -PhysicalMediaType $physicalMedia
                    Status = if ($status) { $status } else { 'Unknown' }
                    LinkSpeed = if ($linkSpeed) { $linkSpeed } else { 'Unknown' }
                    HardwareInterface = if ($null -ne $hardware) { [bool]$hardware } else { $null }
                    DnsState = $dnsStatus
                }
            }
            $queryStatus = 'Get-NetAdapter completed'
        }
        catch { $queryStatus = 'Get-NetAdapter query failed'; $queryError = $_.Exception.Message }
    }
    else {
        $queryError = 'The NetAdapter PowerShell module is unavailable; adapter inventory was not guessed.'
    }
    $tcp = [pscustomobject][ordered]@{ Available = $false; ExitCode = $null; TimedOut = $false; Output = @(); Error = $null }
    if (Get-Command Invoke-POExternalCommand -ErrorAction SilentlyContinue) {
        try {
            $tcpResult = Invoke-POExternalCommand -FilePath 'netsh.exe' -Arguments @('interface', 'tcp', 'show', 'global') -TimeoutSeconds 15
            $tcp = [pscustomobject][ordered]@{
                Available = ($tcpResult.ExitCode -eq 0 -and -not $tcpResult.TimedOut)
                ExitCode = $tcpResult.ExitCode
                TimedOut = [bool]$tcpResult.TimedOut
                Output = @($tcpResult.Output)
                Error = if ($tcpResult.ExitCode -ne 0) { ($tcpResult.ErrorOutput -join ' ').Trim() } else { $null }
            }
        }
        catch { $tcp.Error = $_.Exception.Message }
    }
    return [pscustomobject][ordered]@{
        QueryStatus = $queryStatus
        QueryError = $queryError
        Adapters = $adapters
        TcpGlobalReadOnly = $tcp
        ChangesApplied = $false
        Note = 'Network policy remains unchanged. Ping also depends on the ISP, routing, distance, congestion, and the game server.'
    }
}

function Get-POAutomaticGamingSettingsAssessment {
    [CmdletBinding()]
    param()
    $definitions = @(
        [pscustomobject]@{ Id = 'AutoGameModeEnabled'; Hive = 'CurrentUser'; SubKey = 'Software\Microsoft\GameBar'; ValueName = 'AutoGameModeEnabled' },
        [pscustomobject]@{ Id = 'AllowAutoGameMode'; Hive = 'CurrentUser'; SubKey = 'Software\Microsoft\GameBar'; ValueName = 'AllowAutoGameMode' },
        [pscustomobject]@{ Id = 'GameDVR_Enabled'; Hive = 'CurrentUser'; SubKey = 'System\GameConfigStore'; ValueName = 'GameDVR_Enabled' },
        [pscustomobject]@{ Id = 'AppCaptureEnabled'; Hive = 'CurrentUser'; SubKey = 'Software\Microsoft\Windows\CurrentVersion\GameDVR'; ValueName = 'AppCaptureEnabled' }
    )
    $settings = @()
    foreach ($definition in $definitions) {
        try {
            $state = Get-PORegValueState -Hive $definition.Hive -SubKey $definition.SubKey -ValueName $definition.ValueName
            $settings += [pscustomobject][ordered]@{
                Id = $definition.Id
                Readable = [bool]$state.Readable
                Exists = [bool]$state.Exists
                Kind = $state.Kind
                CurrentValue = $state.Data
                Note = if (-not $state.Readable) { [string]$state.ReadError } else { 'Observed only; no registry value was changed.' }
            }
        }
        catch {
            $settings += [pscustomobject][ordered]@{ Id = $definition.Id; Readable = $false; Exists = $false; Kind = $null; CurrentValue = $null; Note = $_.Exception.Message }
        }
    }
    return $settings
}

function Get-POAutomaticRebootAssessment {
    [CmdletBinding()]
    param()
    $reasons = @()
    $unknown = @()
    $keyPaths = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($path in $keyPaths) {
        try { if (Test-Path -LiteralPath $path -PathType Container -ErrorAction Stop) { $reasons += $path } }
        catch { $unknown += "Could not read $path" }
    }
    $renamePath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager'
    try {
        $rename = Get-ItemProperty -LiteralPath $renamePath -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($null -ne $rename -and @($rename.PendingFileRenameOperations).Count -gt 0) { $reasons += 'PendingFileRenameOperations' }
    }
    catch { $unknown += 'Pending file rename state could not be read' }
    return [pscustomobject][ordered]@{
        Pending = ($reasons.Count -gt 0)
        State = if ($reasons.Count -gt 0) { 'Pending reboot indicators found' } elseif ($unknown.Count -gt 0) { 'Unknown (one or more indicators could not be read)' } else { 'No pending reboot indicator found' }
        Reasons = $reasons
        UnknownChecks = $unknown
    }
}

function Get-POAutomaticAssessment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$SystemSnapshot)
    $powerPlans = @()
    $activeGuid = $null
    $powerStatus = $null
    $powerError = $null
    try {
        $activeGuid = Get-POActivePowerPlanGuid
        $powerPlans = @(Get-POPowerPlans)
        $powerStatus = Get-POCpuParkingStatus
    }
    catch { $powerError = $_.Exception.Message }
    $activePlan = @($powerPlans | Where-Object { $_.Guid -eq $activeGuid } | Select-Object -First 1)
    $platinum = $null
    try { $platinum = Get-POPlatinumPlanInfo }
    catch { $powerError = if ($powerError) { $powerError + '; ' + $_.Exception.Message } else { $_.Exception.Message } }

    $network = Get-POAutomaticNetworkAssessment
    $display = $null
    try { $display = Get-PODisplayInventory }
    catch { $display = [pscustomobject][ordered]@{ Available = $false; Displays = @(); Message = $_.Exception.Message; GpuColorControls = @('Color-control detection unavailable.') } }
    $audio = $null
    try { $audio = Get-POAudioInventory }
    catch { $audio = [pscustomobject][ordered]@{ Available = $false; SoundDevices = @(); Endpoints = @(); Message = $_.Exception.Message } }
    $security = $null
    try { $security = Get-POStatusSnapshot }
    catch { $security = [pscustomobject][ordered]@{ QueryStatus = 'Unavailable'; Note = $_.Exception.Message } }
    $gamingSettings = @(Get-POAutomaticGamingSettingsAssessment)
    $startup = @()
    $startupError = $null
    try { $startup = @(Get-POStartupAudit) }
    catch { $startupError = $_.Exception.Message }
    $serviceCount = $null
    $serviceError = $null
    try {
        $serviceRows = @(Get-POServiceAudit)
        if ($serviceRows.Count -gt 0 -and [string]$serviceRows[0].Classification -ne 'QUERY FAILED') { $serviceCount = $serviceRows.Count }
        elseif ($serviceRows.Count -gt 0) { $serviceError = [string]$serviceRows[0].DependentServiceQuery }
    }
    catch { $serviceError = $_.Exception.Message }
    $resource = $null
    try { $resource = Get-POResourceSample }
    catch { $resource = [pscustomobject][ordered]@{ CpuPercent = $null; AvailableMemoryGB = $null; DiskActivePercent = $null; SampledAtUtc = [DateTime]::UtcNow.ToString('o'); Error = $_.Exception.Message } }
    $mouseSpeed = $null
    try { $mouseSpeed = Get-PORegValueState -Hive CurrentUser -SubKey 'Control Panel\Mouse' -ValueName 'MouseSpeed' }
    catch { }
    $reboot = Get-POAutomaticRebootAssessment
    $storage = [pscustomobject][ordered]@{
        SystemVolume = $SystemSnapshot.SystemVolume
        Disks = @($SystemSnapshot.Storage)
        Note = 'No temporary files, shader caches, personal files, page-file settings, or storage services were changed.'
    }
    $startupCount = $null
    if ($null -eq $startupError -and $startup.Count -gt 0 -and [string]$startup[0].Enabled -ne 'QUERY FAILED') {
        $startupCount = @($startup | Where-Object { $_.Name -ne 'No startup entries reported' }).Count
    }
    return [pscustomobject][ordered]@{
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        Administrator = Test-POIsAdministrator
        Windows = $SystemSnapshot.OS
        Device = $SystemSnapshot.Device
        CPU = $SystemSnapshot.CPU
        GPUs = @($SystemSnapshot.GPUs)
        Memory = $SystemSnapshot.Memory
        Storage = $storage
        Power = [pscustomobject][ordered]@{
            ActivePlanGuid = $activeGuid
            ActivePlanName = if ($activePlan.Count -gt 0) { [string]$activePlan[0].Name } else { 'Unknown' }
            AvailablePlans = $powerPlans
            PlatinumPlan = $platinum
            ProcessorPowerAndCoreParking = $powerStatus
            QueryError = $powerError
        }
        Network = $network
        Displays = $display
        Audio = $audio
        GamingSettings = $gamingSettings
        Startup = [pscustomobject][ordered]@{ EntryCount = $startupCount; QueryError = $startupError; ReadOnly = $true }
        Services = [pscustomobject][ordered]@{ ServiceCount = $serviceCount; QueryError = $serviceError; ReadOnly = $true }
        Security = $security
        ResourceSample = $resource
        Mouse = [pscustomobject][ordered]@{ MouseSpeed = if ($mouseSpeed -and $mouseSpeed.Readable -and $mouseSpeed.Exists) { $mouseSpeed.Data } else { $null }; ReadOnly = $true }
        PendingReboot = $reboot
        CollectionWarnings = @($SystemSnapshot.CollectionWarnings)
        AppliedBeforeOptimization = $false
    }
}

function Invoke-POAutomaticRestorePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RunId)
    if (-not (Test-POIsAdministrator)) {
        return [pscustomobject][ordered]@{ Status = 'SKIPPED'; Verified = $false; Message = 'A restore point requires Administrator privileges.' }
    }
    if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) {
        return [pscustomobject][ordered]@{ Status = 'UNAVAILABLE'; Verified = $false; Message = 'Checkpoint-Computer is unavailable. The application backup remains the primary recovery mechanism.' }
    }
    $description = 'Platinum Optimizer ' + $RunId
    try {
        Checkpoint-Computer -Description $description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        if (Get-Command Get-ComputerRestorePoint -ErrorAction SilentlyContinue) {
            $points = @(Get-ComputerRestorePoint -ErrorAction Stop | Where-Object { [string]$_.Description -eq $description })
            if ($points.Count -gt 0) {
                return [pscustomobject][ordered]@{ Status = 'CREATED_VERIFIED'; Verified = $true; Description = $description; Message = 'Windows lists the newly created restore point.' }
            }
            return [pscustomobject][ordered]@{ Status = 'CREATED_UNVERIFIED'; Verified = $false; Description = $description; Message = 'Checkpoint-Computer returned successfully, but Windows did not return the new point for verification.' }
        }
        return [pscustomobject][ordered]@{ Status = 'CREATED_UNVERIFIED'; Verified = $false; Description = $description; Message = 'Checkpoint-Computer returned successfully; Get-ComputerRestorePoint is unavailable for verification.' }
    }
    catch {
        return [pscustomobject][ordered]@{ Status = 'UNAVAILABLE'; Verified = $false; Description = $description; Message = "Windows did not create a restore point: $($_.Exception.Message) The verified application backup remains available." }
    }
}

function Get-POAutomaticPowerPresetId {
    [CmdletBinding()]
    param([AllowNull()][psobject]$SystemSnapshot)
    if ($SystemSnapshot -and $SystemSnapshot.Device -and $SystemSnapshot.Device.IsLaptop -eq $true) { return 'laptop' }
    return 'gaming'
}

function Save-POAutomaticReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Context,
          [Parameter(Mandatory = $true)][string]$OverallStatus,
          [Parameter(Mandatory = $true)][string]$Summary,
          [bool]$RebootRecommended = $false)
    $ended = [DateTime]::UtcNow
    $Context.Report.endedAtUtc = $ended.ToString('o')
    $Context.Report.durationSeconds = [math]::Round(($ended - $Context.StartedUtc).TotalSeconds, 2)
    $finalStatus = $OverallStatus
    if ($Context.Report.logWriteError -and $finalStatus -eq 'COMPLETED') {
        $finalStatus = 'COMPLETED_WITH_WARNINGS'
        $Summary += ' The run log could not be fully written; see logWriteError in this JSON report.'
    }
    $Context.Report.status = $finalStatus
    $Context.Report.summary = $Summary
    $Context.Report.summaryText = $Summary
    $Context.Report.rebootRecommended = $RebootRecommended
    $completed = @($Context.Applied) + @($Context.Restored)
    $attemptedItems = $completed + @($Context.AlreadyOptimized) + @($Context.Skipped) + @($Context.Failed) + @($Context.Unverified)
    $Context.Report.changes = [pscustomobject][ordered]@{
        attempted = @($attemptedItems | Where-Object { $_.attempted }).Count
        appliedAndVerified = @($Context.Applied)
        restoredAndVerified = @($Context.Restored)
        completedAndVerified = $completed
        alreadyOptimized = @($Context.AlreadyOptimized)
        skipped = @($Context.Skipped)
        failed = @($Context.Failed)
        couldNotBeVerified = @($Context.Unverified)
        appliedCount = $Context.Applied.Count
        restoredCount = $Context.Restored.Count
        completedCount = $completed.Count
        alreadyOptimizedCount = $Context.AlreadyOptimized.Count
        skippedCount = $Context.Skipped.Count
        failedCount = $Context.Failed.Count
        unverifiedCount = $Context.Unverified.Count
    }
    $Context.Report.events = @($Context.Events)
    Write-POJsonAtomic -Path $Context.ReportPath -Object $Context.Report
    if (-not (Test-Path -LiteralPath $Context.ReportPath -PathType Leaf)) { throw "JSON report was not written: $($Context.ReportPath)" }
}

function Write-POAutomaticSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Context)
    $changesReport = Get-POAutomaticPropertyValue -InputObject $Context.Report -Name 'changes'
    $attempted = Get-POAutomaticPropertyValue -InputObject $changesReport -Name 'attempted'
    if ($null -eq $attempted) {
        $attemptedItems = @($Context.Applied) + @($Context.Restored) + @($Context.AlreadyOptimized) + @($Context.Skipped) + @($Context.Failed) + @($Context.Unverified)
        $attempted = @($attemptedItems | Where-Object { $_.attempted }).Count
    }
    $heading = switch ([string]$Context.Mode) {
        'Restore' { 'RECOVERY REPORT' }
        'Scan' { 'SYSTEM ASSESSMENT REPORT' }
        'Benchmark' { 'DIAGNOSTIC REPORT' }
        default { 'OPTIMIZATION REPORT' }
    }
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ('                  ' + $heading) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    if ($Context.Mode -eq 'Restore') {
        Write-Host ("Restore attempts:        {0}" -f $attempted)
        Write-Host ("Restored and verified:   {0}" -f $Context.Restored.Count)
    }
    else {
        Write-Host ("Changes attempted:       {0}" -f $attempted)
        Write-Host ("Applied and verified:    {0}" -f $Context.Applied.Count)
    }
    $alreadyLabel = if ($Context.Mode -eq 'Restore') { 'Already restored' } else { 'Already optimized' }
    Write-Host ('{0,-25} {1}' -f ($alreadyLabel + ':'), $Context.AlreadyOptimized.Count)
    Write-Host ("Skipped:                 {0}" -f $Context.Skipped.Count)
    Write-Host ("Failed:                  {0}" -f $Context.Failed.Count)
    Write-Host ("Could not be verified:   {0}" -f $Context.Unverified.Count)
    $backup = Get-POAutomaticPropertyValue -InputObject $Context.Report -Name 'backup'
    $backupPath = Get-POAutomaticPropertyValue -InputObject $backup -Name 'path'
    if ($backupPath) { Write-Host ("Backup: {0}" -f $backupPath) }
    else { Write-Host 'Backup: No verified backup is available for this run.' -ForegroundColor Yellow }
    Write-Host ("Log:    {0}" -f $Context.LogPath)
    Write-Host ("JSON:   {0}" -f $Context.ReportPath)
    if (Get-POAutomaticPropertyValue -InputObject $Context.Report -Name 'rebootRecommended') { Write-Host 'A reboot is recommended before judging the resulting system state.' -ForegroundColor Yellow }
    if (Get-POAutomaticPropertyValue -InputObject $Context.Report -Name 'logWriteError') { Write-Host 'WARNING: The per-run log could not be fully written; inspect the JSON report.' -ForegroundColor Yellow }
    Write-Host 'No FPS, frame-time, ping, or latency increase is claimed.' -ForegroundColor DarkGray
    Write-Host '============================================================' -ForegroundColor DarkCyan
}

function Invoke-POAutomaticOptimization {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ApplicationVersion)
    $context = New-POAutomaticRunContext -Mode Auto -ApplicationVersion $ApplicationVersion
    $exitCode = 0
    $overallStatus = 'COMPLETED'
    $summary = 'Automatic optimization completed.'
    try {
        Write-POAutomaticEvent -Context $context -Level INFO -Message 'Checking Administrator privileges...' -Details $null
        $context.Report.administrator = Test-POIsAdministrator
        if (-not $context.Report.administrator) {
            Add-POAutomaticChange -Context $context -Id 'preflight-administrator' -Name 'Administrator preflight' -Status 'FAILED' -Reason 'Elevation was not granted. No system changes were made.' | Out-Null
            Write-POAutomaticEvent -Context $context -Level FAIL -Message 'Administrator privileges are required. Run PlatinumOptimizer.bat and accept the Windows UAC prompt.' -Details $null
            $exitCode = 5
            $overallStatus = 'ABORTED_PRECONDITION'
            $summary = 'Administrator privileges were not available; no system changes were made.'
        }
        else {
            Write-POAutomaticEvent -Context $context -Level PASS -Message 'Administrator privileges verified.' -Details $null
            Write-POAutomaticEvent -Context $context -Level INFO -Message 'Detecting Windows, processor, graphics, memory, storage, display, audio, network, power, and gaming configuration...' -Details $null
            if (-not (Test-POIsWindows)) { throw 'This optimizer requires Windows 10/11.' }
            $system = Get-POSystemSnapshot
            $context.Report.system = $system
            $context.Report.assessment = Get-POAutomaticAssessment -SystemSnapshot $system
            Write-POAutomaticEvent -Context $context -Level PASS -Message 'System assessment completed; unavailable hardware fields remain unknown rather than guessed.' -Details ([pscustomobject]@{ windows = $system.OS; cpu = $system.CPU; gpuCount = @($system.GPUs).Count; memoryGB = $system.Memory.TotalGB; systemVolume = $system.SystemVolume })
            if (-not $system.OS.Supported) {
                Add-POAutomaticChange -Context $context -Id 'preflight-windows-version' -Name 'Supported Windows version' -Status 'FAILED' -Reason 'Windows 10/11 could not be positively identified; no system changes were made.' | Out-Null
                Write-POAutomaticEvent -Context $context -Level FAIL -Message 'Windows 10/11 could not be positively identified. No optimization was applied.' -Details $system.OS
                $exitCode = 2
                $overallStatus = 'ABORTED_UNSUPPORTED_WINDOWS'
                $summary = 'Unsupported or unknown Windows family; no system changes were made.'
            }
            else {
                $reboot = $context.Report.assessment.PendingReboot
                if ($reboot.Pending) {
                    Write-POAutomaticEvent -Context $context -Level WARN -Message 'Windows reports a pending reboot. The optimizer will not restart the computer; configuration changes continue only if their preflight succeeds.' -Details $reboot
                }
                elseif ($reboot.UnknownChecks.Count -gt 0) {
                    Write-POAutomaticEvent -Context $context -Level WARN -Message 'Pending reboot state is partly unknown; no reboot will be requested.' -Details $reboot
                }
                else { Write-POAutomaticEvent -Context $context -Level PASS -Message 'No pending reboot indicator was found.' -Details $null }

                $presetId = Get-POAutomaticPowerPresetId -SystemSnapshot $system
                Write-POAutomaticEvent -Context $context -Level INFO -Message "Creating and verifying a timestamped configuration backup before any system changes; automatic preset: $presetId." -Details $null
                $backupReportCallback = {
                    param($verifiedBackup)
                    $context.Report.backup = [pscustomobject][ordered]@{
                        id = $verifiedBackup.Id
                        path = $verifiedBackup.Path
                        status = $verifiedBackup.Status
                        warnings = @($verifiedBackup.Warnings)
                    }
                    Write-POAutomaticEvent -Context $context -Level PASS -Message "Verified backup created at $($verifiedBackup.Path)." -Details $context.Report.backup
                }
                $backupReportCallback = $backupReportCallback.GetNewClosure()
                $restorePointCallback = {
                    param($verifiedBackup)
                    $restorePoint = Invoke-POAutomaticRestorePoint -RunId $context.RunId
                    $context.Report.restorePoint = $restorePoint
                    if ($restorePoint.Status -eq 'CREATED_VERIFIED') {
                        Write-POAutomaticEvent -Context $context -Level PASS -Message 'Windows System Restore point created and verified after the application backup.' -Details $restorePoint
                    }
                    else {
                        Write-POAutomaticEvent -Context $context -Level WARN -Message $restorePoint.Message -Details $restorePoint
                    }
                }
                $restorePointCallback = $restorePointCallback.GetNewClosure()
                $planResult = Invoke-POPlatinumPlanWorkflow -PresetId $presetId -Activate -OnBackupCreated $backupReportCallback -OnVerifiedBackup $restorePointCallback -Confirm:$false
                if ($planResult.Backup -and -not $context.Report.backup) {
                    $context.Report.backup = [pscustomobject][ordered]@{
                        id = $planResult.Backup.Id
                        path = $planResult.Backup.Path
                        status = $planResult.Backup.Status
                        warnings = @($planResult.Backup.Warnings)
                    }
                    Write-POAutomaticEvent -Context $context -Level PASS -Message "Verified backup created at $($planResult.Backup.Path)." -Details $context.Report.backup
                }
                if ($planResult.Changes) {
                    foreach ($change in @($planResult.Changes)) {
                        Add-POAutomaticChange -Context $context `
                            -Id ([string]$change.Id) `
                            -Name ([string]$change.Name) `
                            -Status ([string]$change.Status) `
                            -Attempted:([bool]$change.Attempted) `
                            -Verified:([bool]$change.Verified) `
                            -PreviousValue $change.PreviousValue `
                            -TargetValue $change.TargetValue `
                            -Reason ([string]$change.Reason) `
                            -RequiresReboot:([bool]$change.RequiresReboot) | Out-Null
                    }
                }
                if ($planResult.Status -like 'APPLIED_VERIFIED*') {
                    $actionText = if ($planResult.PlanCreated) { "Created '$($planResult.PlanName)'" } else { "Reused '$($planResult.PlanName)'" }
                    Write-POAutomaticEvent -Context $context -Level PASS -Message "$actionText ($($planResult.PlanGuid)); active-plan verification: $($planResult.Activated)." -Details $planResult
                    Write-POAutomaticEvent -Context $context -Level INFO -Message 'Processor limits and active-cooling policy were read back. Core parking, boost policy, PCIe/USB behavior, capture, network, storage, services, and startup entries were not force-tuned.' -Details $null
                    $summary = 'Automatic assessment and supported power-plan workflow completed. Changes remain reversible through --restore.'
                    if ($planResult.PSObject.Properties['LedgerWarning'] -and $planResult.LedgerWarning) {
                        $ledgerWarning = [string]$planResult.LedgerWarning
                        Write-POAutomaticEvent -Context $context -Level WARN -Message "The power-plan operation verified, but the backup ledger status could not be updated: $ledgerWarning" -Details $null
                        if ($context.Report.backup) { $context.Report.backup.warnings = @($context.Report.backup.warnings) + @("Backup ledger status update failed: $ledgerWarning") }
                        $overallStatus = 'COMPLETED_WITH_WARNINGS'
                        $summary = 'Automatic assessment and power-plan configuration completed and verified, but the backup ledger status update failed. Review the report and backup before recovery.'
                    }
                }
                else {
                    if (@($planResult.Changes).Count -eq 0) {
                        Add-POAutomaticChange -Context $context -Id 'platinum-power-plan' -Name 'Platinum On Steroids power plan' -Status 'FAILED' -Attempted -Reason ([string]$planResult.Message) | Out-Null
                    }
                    Write-POAutomaticEvent -Context $context -Level FAIL -Message "Power-plan workflow did not complete successfully: $($planResult.Message)" -Details $planResult
                    $exitCode = 10
                    $overallStatus = 'COMPLETED_WITH_FAILURES'
                    $summary = 'The power-plan workflow failed safely. Review the verified backup and report before retrying.'
                }

                $skipReasons = @(
                    [pscustomobject]@{ Id = 'game-mode'; Name = 'Windows Game Mode'; Reason = 'Current state was assessed. No setting was changed because the existing supported Windows control surface is user-managed and registry policy writes are not treated as a reliable API.' },
                    [pscustomobject]@{ Id = 'game-capture'; Name = 'Game Bar and background capture'; Reason = 'Left unchanged to preserve the user’s recording, streaming, and capture preferences.' },
                    [pscustomobject]@{ Id = 'cpu-core-parking'; Name = 'CPU core parking and boost policy'; Reason = 'Read-only powercfg assessment only. Windows/OEM scheduling is preserved because disabling parking or forcing boost is workload-, processor-, firmware-, and thermal-dependent.' },
                    [pscustomobject]@{ Id = 'network-tuning'; Name = 'TCP, DNS, NIC offloads, and adapter power'; Reason = 'Read-only adapter and TCP assessment only. No DNS, ECN, autotuning, RSS/RSC, offload, duplex, or adapter power setting was changed without a hardware- and route-specific justification.' },
                    [pscustomobject]@{ Id = 'display-color'; Name = 'Display refresh and color'; Reason = 'Display modes and vendor control surfaces were assessed; no resolution, refresh, ICC profile, gamma, saturation, or driver setting was changed automatically.' },
                    [pscustomobject]@{ Id = 'startup-services'; Name = 'Startup applications and Windows services'; Reason = 'Inventories are read-only. No process was terminated and no service or startup item was disabled.' },
                    [pscustomobject]@{ Id = 'storage-memory'; Name = 'Storage cleanup and memory policy'; Reason = 'Storage and memory were assessed. No personal files, caches, page-file settings, or memory-management settings were changed.' }
                )
                foreach ($reason in $skipReasons) {
                    Add-POAutomaticChange -Context $context -Id $reason.Id -Name $reason.Name -Status 'SKIPPED' -Reason $reason.Reason | Out-Null
                }
                if ($context.Skipped.Count -gt 0) {
                    Write-POAutomaticEvent -Context $context -Level INFO -Message 'Hardware-dependent or preference-sensitive categories were safely left unchanged; see the final report for each reason.' -Details @($context.Skipped)
                }
                if ($context.Failed.Count -gt 0 -or $context.Unverified.Count -gt 0) {
                    if ($exitCode -eq 0) { $exitCode = 10 }
                    $overallStatus = 'COMPLETED_WITH_FAILURES'
                }
            }
        }
    }
    catch {
        Add-POAutomaticChange -Context $context -Id 'automatic-workflow' -Name 'Automatic optimization workflow' -Status 'FAILED' -Attempted -Reason $_.Exception.Message | Out-Null
        Write-POAutomaticEvent -Context $context -Level FAIL -Message "The optimizer stopped safely: $($_.Exception.Message)" -Details $_.Exception.ToString()
        $exitCode = 10
        $overallStatus = 'ABORTED_WITH_FAILURE'
        $summary = 'The optimizer encountered a critical error. No further system changes were attempted.'
    }
    finally {
        try {
            Save-POAutomaticReport -Context $context -OverallStatus $overallStatus -Summary $summary -RebootRecommended ([bool]($context.Report.assessment -and $context.Report.assessment.PendingReboot.Pending))
        }
        catch {
            Write-Host "[FAIL] The JSON report could not be saved: $($_.Exception.Message)" -ForegroundColor Red
            $exitCode = 12
        }
        Write-POAutomaticSummary -Context $context
    }
    return [pscustomobject][ordered]@{ ExitCode = $exitCode; Context = $context }
}

function Invoke-POAutomaticRestore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ApplicationVersion,
          [AllowNull()][string]$BackupPath)
    $context = New-POAutomaticRunContext -Mode Restore -ApplicationVersion $ApplicationVersion
    $exitCode = 0
    $status = 'COMPLETED'
    $summary = 'Recorded optimizer changes were restored.'
    $restoreInvoked = $false
    try {
        $context.Report.administrator = Test-POIsAdministrator
        if (-not $context.Report.administrator) { throw 'Administrator privileges are required for system recovery.' }
        $targetPath = $BackupPath
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            $candidates = @(Get-POBackups | Where-Object { $_.Status -eq 'VALID' })
            foreach ($candidate in $candidates) {
                $manifestPath = Join-Path $candidate.Path 'manifest.json'
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                $restoreAssessment = Test-POBackupNeedsRestore -Manifest $manifest
                if ($restoreAssessment.NeedsRestore) { $targetPath = [string]$candidate.Path; break }
            }
        }
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            Add-POAutomaticChange -Context $context -Id 'restore' -Name 'Optimizer recovery' -Status 'SKIPPED' -Reason 'No valid backup with un-restored recorded changes was found.' | Out-Null
            Write-POAutomaticEvent -Context $context -Level SKIP -Message 'No valid backup with un-restored recorded changes was found.' -Details $null
            $summary = 'There was no un-restored recorded optimizer change to restore.'
        }
        else {
            $validation = Test-POBackup -Path $targetPath
            if (-not $validation.Valid) { throw ('The selected backup is invalid: ' + (@($validation.Issues) -join '; ')) }
            $restoreAssessment = Test-POBackupNeedsRestore -Manifest $validation.Manifest
            $context.Report.recoverySource = [pscustomobject][ordered]@{
                id = [string]$validation.Manifest.id
                path = [string]$targetPath
                sections = @($restoreAssessment.PendingSections)
                alreadyRestoredSections = @($restoreAssessment.RestoredSections)
                changeCount = @($validation.Manifest.changes).Count
            }
            if (-not $restoreAssessment.NeedsRestore) {
                Add-POAutomaticChange -Context $context -Id 'restore' -Name 'Optimizer recovery' -Status 'ALREADY_RESTORED' -Reason 'The selected backup has no pending sections; completed sections were not replayed.' | Out-Null
                Write-POAutomaticEvent -Context $context -Level SKIP -Message 'The selected backup has no pending sections; no pre-restore backup or restore operation was needed.' -Details $context.Report.recoverySource
                $summary = 'All recorded optimizer changes in the selected backup were already restored.'
            }
            else {
                Write-POAutomaticEvent -Context $context -Level INFO -Message "Validated recovery backup $($validation.Manifest.id). Capturing and verifying a fresh pre-restore safety snapshot for pending sections..." -Details $context.Report.recoverySource
                $activeGuid = Get-POActivePowerPlanGuid
                $parsedActiveGuid = [guid]::Empty
                if (-not [guid]::TryParse([string]$activeGuid, [ref]$parsedActiveGuid)) { throw 'The current active power plan could not be captured; restore was blocked.' }
                $platinumInfo = Get-POPlatinumPlanInfo
                $platinumSnapshot = $null
                if ($platinumInfo -and $platinumInfo.Exists) {
                    $parsedPlatinumGuid = [guid]::Empty
                    if (-not [guid]::TryParse([string]$platinumInfo.PlanGuid, [ref]$parsedPlatinumGuid)) { throw 'The current Platinum plan identity could not be verified; restore was blocked.' }
                    $platinumSnapshot = Get-POPlatinumPowerSettingsSnapshot -PlanGuid $parsedPlatinumGuid.ToString()
                }
                $targetSections = @($restoreAssessment.PendingSections | ForEach-Object { [string]$_ } | Select-Object -Unique)
                $audioState = $null
                if ($targetSections -contains 'audio') {
                    $audioCurrent = Get-POAudioDuckingState
                    if (-not $audioCurrent.Current.Readable) { throw 'The current audio communications setting could not be captured; recovery was blocked.' }
                    $audioState = [pscustomobject][ordered]@{ DuckingBefore = $audioCurrent.Current; CapturedAtUtc = [DateTime]::UtcNow.ToString('o') }
                }
                $displayState = $null
                if ($targetSections -contains 'display') {
                    $displayChanges = @($validation.Manifest.changes | Where-Object { $_.section -eq 'display' })
                    $displayNames = @($displayChanges | ForEach-Object { if ($null -ne $_.PSObject.Properties['deviceName']) { [string]$_.deviceName } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
                    if ($displayNames.Count -eq 0) { throw 'The display backup does not identify a target device for a pre-restore state capture.' }
                    $displayState = Get-PODisplayLiveStateSnapshot -DeviceNames $displayNames
                }
                $preRestoreBackup = New-POBackup -PlatinumState ([pscustomobject][ordered]@{ OriginalActivePlanGuid = $parsedActiveGuid.ToString().ToLowerInvariant(); PlatinumPlanGuid = if ($platinumInfo -and $platinumInfo.Exists) { $platinumInfo.PlanGuid } else { $null }; PlatinumPlanExistedBefore = [bool]($platinumInfo -and $platinumInfo.Exists); CapturedAtUtc = [DateTime]::UtcNow.ToString('o') }) -PlatinumPlanGuid $(if ($platinumInfo -and $platinumInfo.Exists) { [string]$platinumInfo.PlanGuid } else { '' }) -PowerSettingsSnapshot $platinumSnapshot -AudioState $audioState -DisplayState $displayState
                $preRestoreValidation = Test-POBackup -Path $preRestoreBackup.Path
                if (-not $preRestoreValidation.Valid) { throw ('The pre-restore backup failed validation: ' + (@($preRestoreValidation.Issues) -join '; ')) }
                $context.Report.backup = [pscustomobject][ordered]@{ id = $preRestoreBackup.Id; path = $preRestoreBackup.Path; status = $preRestoreBackup.Status; warnings = @($preRestoreBackup.Warnings); purpose = 'Pre-restore safety snapshot' }
                if ($targetSections -contains 'network') {
                    $dnsSnapshotPath = Join-Path $preRestoreBackup.Path 'network\dns-before.json'
                    $dnsSnapshot = @(Get-Content -LiteralPath $dnsSnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
                    foreach ($networkChange in @($validation.Manifest.changes | Where-Object { $_.section -eq 'network' })) {
                        $interfaceIndex = 0
                        $interfaceGuid = [guid]::Empty
                        if (-not [int]::TryParse([string]$networkChange.interfaceIndex, [ref]$interfaceIndex) -or -not [guid]::TryParse([string]$networkChange.interfaceGuid, [ref]$interfaceGuid)) { throw 'The network recovery ledger does not identify a valid adapter; recovery was blocked.' }
                        $capturedDns = @($dnsSnapshot | Where-Object { [int]$_.InterfaceIndex -eq $interfaceIndex } | Select-Object -First 1)
                        if ($capturedDns.Count -eq 0 -or [string]$capturedDns[0].InterfaceGuid -ne $interfaceGuid.ToString() -or -not $capturedDns[0].IPv4DnsReadable) { throw "The fresh pre-restore DNS snapshot is incomplete for adapter index $interfaceIndex; recovery was blocked." }
                    }
                }
                if ($targetSections -contains 'registry') {
                    $registrySnapshotPath = Join-Path $preRestoreBackup.Path 'registry\game-settings-before.json'
                    $registrySnapshot = @(Get-Content -LiteralPath $registrySnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
                    foreach ($registryChange in @($validation.Manifest.changes | Where-Object { $_.section -eq 'registry' })) {
                        $capturedRegistry = @($registrySnapshot | Where-Object { $_.Hive -eq $registryChange.hive -and $_.SubKey -eq $registryChange.subKey -and $_.ValueName -eq $registryChange.valueName } | Select-Object -First 1)
                        if ($capturedRegistry.Count -eq 0 -or -not $capturedRegistry[0].Readable) { throw "The fresh registry safety snapshot is incomplete for $($registryChange.subKey)\$($registryChange.valueName); recovery was blocked." }
                    }
                }
                foreach ($requiredSection in @('audio', 'display')) {
                    if ($targetSections -contains $requiredSection) {
                        $sectionSnapshot = Join-Path $preRestoreBackup.Path ("{0}\{0}-before.json" -f $requiredSection)
                        if (-not (Test-Path -LiteralPath $sectionSnapshot -PathType Leaf) -or (Get-Item -LiteralPath $sectionSnapshot -Force).Length -le 0) { throw "The fresh $requiredSection safety snapshot is missing or empty; recovery was blocked." }
                    }
                }
                $activeExportPath = Join-Path $preRestoreBackup.Path 'power\active-plan.pow'
                if (-not (Test-Path -LiteralPath $activeExportPath -PathType Leaf) -or (Get-Item -LiteralPath $activeExportPath -Force).Length -le 0) { throw 'The current active power scheme could not be exported and verified; restore was blocked.' }
                if ($platinumInfo -and $platinumInfo.Exists) {
                    $platinumExportPath = Join-Path $preRestoreBackup.Path 'power\platinum-plan-before.pow'
                    $settingsSnapshotPath = Join-Path $preRestoreBackup.Path 'power\platinum-settings-before.json'
                    if (-not (Test-Path -LiteralPath $platinumExportPath -PathType Leaf) -or (Get-Item -LiteralPath $platinumExportPath -Force).Length -le 0 -or -not (Test-Path -LiteralPath $settingsSnapshotPath -PathType Leaf) -or (Get-Item -LiteralPath $settingsSnapshotPath -Force).Length -le 0) {
                        throw 'The current Platinum plan and settings could not be completely exported; restore was blocked.'
                    }
                }
                if ((Get-POActivePowerPlanGuid) -ne $parsedActiveGuid.ToString().ToLowerInvariant()) { throw 'The active power plan changed during the pre-restore snapshot; no restore was attempted.' }
                Write-POAutomaticEvent -Context $context -Level PASS -Message "Pre-restore safety backup verified at $($preRestoreBackup.Path)." -Details $context.Report.backup
                $restoreInvoked = $true
                $result = Restore-POBackup -BackupPath $targetPath -Confirm:$false
                foreach ($section in @($result.Restored)) {
                    Add-POAutomaticChange -Context $context -Id ("restore-{0}" -f $section) -Name ("Restore {0} settings" -f $section) -Status 'RESTORED_VERIFIED' -Attempted -Verified -TargetValue $targetPath -Reason ([string]$result.Message) | Out-Null
                }
                foreach ($failure in @($result.Failures)) {
                    Add-POAutomaticChange -Context $context -Id 'restore-section-failure' -Name 'Restore recorded settings' -Status 'FAILED' -Attempted -Reason ([string]$failure) | Out-Null
                    $failedSection = ([string]$failure -split ':', 2)[0].Trim()
                    if (@($result.UnverifiedSections) -contains $failedSection) {
                        Add-POAutomaticChange -Context $context -Id 'restore-section-state' -Name ("Restore {0} final state" -f $failedSection) -Status 'UNVERIFIED' -Reason 'The restore handler failed during this section, so a partial system change cannot be ruled out. Inspect the current setting before retrying.' | Out-Null
                    }
                }
                if ($result.Status -eq 'NO_CHANGES') {
                    Add-POAutomaticChange -Context $context -Id 'restore' -Name 'Restore recorded settings' -Status 'ALREADY_RESTORED' -Reason ([string]$result.Message) | Out-Null
                    Write-POAutomaticEvent -Context $context -Level SKIP -Message ([string]$result.Message) -Details $result
                }
                elseif ($result.Status -eq 'RESTORED') {
                    Write-POAutomaticEvent -Context $context -Level PASS -Message "Recovery completed from $targetPath." -Details $result
                }
                else {
                    Write-POAutomaticEvent -Context $context -Level FAIL -Message "Recovery did not fully complete: $($result.Message)" -Details $result
                    $exitCode = 10
                    $status = 'COMPLETED_WITH_FAILURES'
                    $summary = 'Recovery was partial or failed; review the restore report and pre-restore safety backup.'
                }
            }
        }
    }
    catch {
        Add-POAutomaticChange -Context $context -Id 'restore' -Name 'Optimizer recovery' -Status 'FAILED' -Attempted -Reason $_.Exception.Message | Out-Null
        if ($restoreInvoked) {
            Add-POAutomaticChange -Context $context -Id 'restore-state' -Name 'Restore final machine state' -Status 'UNVERIFIED' -Reason 'The restore handler stopped unexpectedly; a partial system change cannot be ruled out. Inspect the current settings and pre-restore snapshot before retrying.' | Out-Null
        }
        Write-POAutomaticEvent -Context $context -Level FAIL -Message "Recovery did not complete cleanly: $($_.Exception.Message)" -Details $_.Exception.ToString()
        $exitCode = 10
        $status = 'ABORTED_WITH_FAILURE'
        $summary = if ($restoreInvoked) { 'Recovery stopped unexpectedly. Review the pre-restore safety backup and current system state before retrying.' } else { 'Recovery failed validation or could not begin; no restore handler was run.' }
    }
    finally {
        try { Save-POAutomaticReport -Context $context -OverallStatus $status -Summary $summary }
        catch { Write-Host "[FAIL] The JSON report could not be saved: $($_.Exception.Message)" -ForegroundColor Red; $exitCode = 12 }
        Write-POAutomaticSummary -Context $context
    }
    return [pscustomobject][ordered]@{ ExitCode = $exitCode; Context = $context }
}

function Invoke-POAutomaticReadOnlyMode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Scan', 'Benchmark')][string]$Mode,
          [Parameter(Mandatory = $true)][string]$ApplicationVersion)
    $context = New-POAutomaticRunContext -Mode $Mode -ApplicationVersion $ApplicationVersion
    $exitCode = 0
    $status = 'COMPLETED'
    $summary = if ($Mode -eq 'Scan') { 'Read-only system assessment completed.' } else { 'Diagnostic sample completed; no gaming benchmark was executed.' }
    try {
        $context.Report.administrator = Test-POIsAdministrator
        Write-POAutomaticEvent -Context $context -Level INFO -Message $(if ($Mode -eq 'Scan') { 'Running read-only hardware and Windows assessment...' } else { 'Collecting short read-only system counters; no settings will be changed...' }) -Details $null
        $system = Get-POSystemSnapshot
        $context.Report.system = $system
        $assessment = Get-POAutomaticAssessment -SystemSnapshot $system
        $context.Report.assessment = $assessment
        if ($Mode -eq 'Benchmark') {
            $benchmark = Get-POBenchmarkSnapshot -SampleSeconds 3
            $context.Report.metrics = $benchmark
            Write-POAutomaticEvent -Context $context -Level PASS -Message 'Three-second Windows system sample collected. This is not an in-game FPS or frame-time benchmark.' -Details $benchmark
            Add-POAutomaticChange -Context $context -Id 'benchmark' -Name 'Read-only diagnostic sample' -Status 'ALREADY_OPTIMIZED' -Reason 'No configuration changes were requested or made.' | Out-Null
        }
        else {
            Write-POAutomaticEvent -Context $context -Level PASS -Message 'Read-only system assessment completed.' -Details ([pscustomobject]@{ windows = $system.OS; cpu = $system.CPU; gpuCount = @($system.GPUs).Count; memoryGB = $system.Memory.TotalGB })
            Add-POAutomaticChange -Context $context -Id 'scan' -Name 'Read-only system assessment' -Status 'ALREADY_OPTIMIZED' -Reason 'Scan mode does not apply system changes.' | Out-Null
            Write-Host ($assessment | ConvertTo-Json -Depth 12)
        }
    }
    catch {
        Add-POAutomaticChange -Context $context -Id $Mode.ToLowerInvariant() -Name ("{0} mode" -f $Mode) -Status 'FAILED' -Attempted -Reason $_.Exception.Message | Out-Null
        Write-POAutomaticEvent -Context $context -Level FAIL -Message "Read-only $Mode mode failed: $($_.Exception.Message)" -Details $_.Exception.ToString()
        $exitCode = 10
        $status = 'ABORTED_WITH_FAILURE'
        $summary = "Read-only $Mode mode failed."
    }
    finally {
        try { Save-POAutomaticReport -Context $context -OverallStatus $status -Summary $summary }
        catch { Write-Host "[FAIL] The JSON report could not be saved: $($_.Exception.Message)" -ForegroundColor Red; $exitCode = 12 }
        Write-POAutomaticSummary -Context $context
    }
    return [pscustomobject][ordered]@{ ExitCode = $exitCode; Context = $context }
}

function Invoke-POAutomaticMode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Auto', 'Scan', 'Benchmark', 'Restore')][string]$Mode,
          [AllowNull()][string]$BackupPath,
          [Parameter(Mandatory = $true)][string]$ApplicationVersion)
    switch ($Mode) {
        'Auto' {
            # The detailed staged engine lives in PlatinumOptimizer.Engine and
            # covers every category. If it is loaded it owns the automatic run;
            # the power-only path below is retained only as a fallback for a
            # session where the Engine module could not be imported.
            if (Get-Command Invoke-POFullOptimization -ErrorAction SilentlyContinue) {
                return (Invoke-POFullOptimization)
            }
            return (Invoke-POAutomaticOptimization -ApplicationVersion $ApplicationVersion)
        }
        'Restore' { return (Invoke-POAutomaticRestore -ApplicationVersion $ApplicationVersion -BackupPath $BackupPath) }
        { $_ -in @('Scan', 'Benchmark') } { return (Invoke-POAutomaticReadOnlyMode -Mode $Mode -ApplicationVersion $ApplicationVersion) }
        default { throw "Unsupported automatic mode: $Mode" }
    }
}

Export-ModuleMember -Function @(
    'Get-POAutomaticPropertyValue', 'Get-POAutomaticAdapterKind', 'New-POAutomaticRunContext',
    'Write-POAutomaticEvent', 'Add-POAutomaticChange', 'Get-POAutomaticNetworkAssessment',
    'Get-POAutomaticGamingSettingsAssessment', 'Get-POAutomaticRebootAssessment',
    'Get-POAutomaticAssessment', 'Invoke-POAutomaticRestorePoint', 'Get-POAutomaticPowerPresetId',
    'Save-POAutomaticReport', 'Write-POAutomaticSummary', 'Invoke-POAutomaticOptimization',
    'Invoke-POAutomaticRestore', 'Invoke-POAutomaticReadOnlyMode', 'Invoke-POAutomaticMode'
)
