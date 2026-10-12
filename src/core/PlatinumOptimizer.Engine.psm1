#requires -Version 5.1
# Platinum Optimizer - Automatic CMD Engine (v2.0)
# The console is the entire user interface. This module runs the complete
# optimization pipeline without interactive menus: preflight, detection,
# restore point, backup, power, CPU, gaming, GPU/display, network, storage,
# verification, report. Every status line reflects an actual operation and
# its verified outcome. Nothing is printed as successful before it succeeds.
Set-StrictMode -Version 2.0

if (-not (Get-Module | Where-Object { $_.Name -eq 'PlatinumOptimizer.Core' })) {
    Import-Module -Name (Join-Path $PSScriptRoot 'PlatinumOptimizer.Core.psm1') -Global -Force -ErrorAction Stop
}

$script:POEngineVersion = '2.0.0'
$script:PORunLogPath = $null

function Get-POEngineVersion { return $script:POEngineVersion }

function Get-POConsolePrefix {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('INFO', 'PASS', 'WARN', 'SKIP', 'FAIL', 'STEP')][string]$Level)
    switch ($Level) {
        'STEP' { return '======' }
        default { return "[$Level]" }
    }
}

function Write-POConsole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('INFO', 'PASS', 'WARN', 'SKIP', 'FAIL', 'STEP')][string]$Level,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )
    $color = switch ($Level) {
        'INFO' { 'Gray' }
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'SKIP' { 'Cyan' }
        'FAIL' { 'Red' }
        'STEP' { 'White' }
    }
    foreach ($line in @($Message -split "`r?`n")) {
        $text = if ($Level -eq 'STEP') { "---- $line ----" } else { "$(Get-POConsolePrefix -Level $Level) $line" }
        Write-Host $text -ForegroundColor $color
        if ($script:PORunLogPath) {
            try {
                $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
                Add-Content -LiteralPath $script:PORunLogPath -Value "$stamp $text" -Encoding UTF8
            }
            catch { }
        }
    }
}

function Get-PORunLogRoot {
    # Timestamped logs live under ProgramData when elevated (machine-wide,
    # survive console close), with a per-user fallback. Previous logs are
    # never overwritten: every run gets its own directory.
    if ((Test-POIsWindows) -and (Test-POIsAdministrator) -and -not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        return (Join-Path $env:ProgramData 'PlatinumOptimizer\logs')
    }
    return (Join-Path (Get-POStateRoot) 'logs')
}

function Start-PORunLog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('optimize', 'restore', 'benchmark', 'scan')][string]$Mode)
    $dir = $null
    try {
        $root = Get-PORunLogRoot
        $dir = Join-Path $root ('Run_{0}_{1}' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'), $Mode)
        $suffix = 1
        while (Test-Path -LiteralPath $dir) { $dir = Join-Path $root ('Run_{0}_{1}_{2}' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'), $Mode, $suffix); $suffix++ }
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        $script:PORunLogPath = Join-Path $dir 'run.log'
        Set-Content -LiteralPath $script:PORunLogPath -Value ("Platinum Optimizer On Steroids v{0} - run log ({1})" -f (Get-POEngineVersion), $Mode) -Encoding UTF8
    }
    catch {
        # Logging must never crash the run; fall back to the JSONL log only.
        $script:PORunLogPath = $null
        try { Write-POLog -Level 'WARNING' -Category 'Engine' -Status 'RUN_LOG_UNAVAILABLE' -Message "Run log directory could not be created: $($_.Exception.Message)" } catch { }
    }
    return [pscustomobject][ordered]@{ LogDir = $dir; RunLogPath = $script:PORunLogPath }
}

function New-POResultRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('APPLIED_VERIFIED', 'ALREADY_OPTIMIZED', 'SKIPPED', 'FAILED', 'UNVERIFIED', 'WARN', 'INFO')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()][string]$Details = $null,
        [bool]$RequiresReboot = $false,
        [bool]$Reversible = $false
    )
    return [pscustomobject][ordered]@{
        Stage = $Stage; Id = $Id; Status = $Status; Message = $Message; Details = $Details
        RequiresReboot = $RequiresReboot; Reversible = $Reversible; TimestampUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Write-POResultToConsole {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Result)
    $level = switch ([string]$Result.Status) {
        'APPLIED_VERIFIED' { 'PASS' }
        'ALREADY_OPTIMIZED' { 'PASS' }
        'SKIPPED' { 'SKIP' }
        'FAILED' { 'FAIL' }
        'UNVERIFIED' { 'WARN' }
        'WARN' { 'WARN' }
        default { 'INFO' }
    }
    $suffix = switch ([string]$Result.Status) {
        'ALREADY_OPTIMIZED' { ' (already optimized)' }
        'UNVERIFIED' { ' (could NOT be verified - not counted as success)' }
        default { '' }
    }
    Write-POConsole -Level $level -Message "$($Result.Stage): $($Result.Message)$suffix"
}

function Get-POReportSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][psobject[]]$Results)
    # Pure counter. Distinguishes attempted/applied/already-optimized/skipped/
    # failed/unverified exactly as recorded - no re-interpretation.
    $applied = @($Results | Where-Object { $_.Status -eq 'APPLIED_VERIFIED' })
    $already = @($Results | Where-Object { $_.Status -eq 'ALREADY_OPTIMIZED' })
    $skipped = @($Results | Where-Object { $_.Status -eq 'SKIPPED' })
    $failed = @($Results | Where-Object { $_.Status -eq 'FAILED' })
    $unverified = @($Results | Where-Object { $_.Status -eq 'UNVERIFIED' })
    $warnings = @($Results | Where-Object { $_.Status -eq 'WARN' })
    $reboot = @($Results | Where-Object { $_.RequiresReboot -and $_.Status -in @('APPLIED_VERIFIED', 'UNVERIFIED') })
    return [pscustomobject][ordered]@{
        Applied = $applied.Count
        AlreadyOptimized = $already.Count
        Skipped = $skipped.Count
        Failed = $failed.Count
        Unverified = $unverified.Count
        Warnings = $warnings.Count
        RebootRecommended = ($reboot.Count -gt 0)
        FailedIds = @($failed | ForEach-Object { "$($_.Stage)/$($_.Id)" })
        UnverifiedIds = @($unverified | ForEach-Object { "$($_.Stage)/$($_.Id)" })
    }
}

function Select-POAutoPowerPreset {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Snapshot)
    # Pure, hardware-aware preset decision for the Platinum On Steroids plan.
    if (-not $Snapshot.OS -or -not $Snapshot.OS.Supported) {
        return [pscustomobject]@{ Action = 'skip'; PresetId = $null; Reason = 'Windows family is not identified as Windows 10/11; the power-plan change is blocked.' }
    }
    if ($null -eq $Snapshot.Device.IsLaptop) {
        return [pscustomobject]@{ Action = 'skip'; PresetId = $null; Reason = 'Desktop/laptop form factor could not be confirmed; the power-plan change is blocked until detection succeeds.' }
    }
    if ($Snapshot.Device.IsLaptop) {
        if ([string]$Snapshot.Device.PowerSource -eq 'Battery') {
            return [pscustomobject]@{ Action = 'skip'; PresetId = $null; Reason = 'Portable device is on battery; a performance plan would drain it. Re-run while plugged in.' }
        }
        if ([string]$Snapshot.Device.PowerSource -ne 'AC') {
            return [pscustomobject]@{ Action = 'skip'; PresetId = $null; Reason = "AC power could not be positively confirmed (source: '$($Snapshot.Device.PowerSource)'); the power-plan change is blocked." }
        }
        return [pscustomobject]@{ Action = 'apply'; PresetId = 'laptop'; Reason = 'Portable device on AC power: the Laptop preset applies a capped, thermally aware configuration.' }
    }
    return [pscustomobject]@{ Action = 'apply'; PresetId = 'gaming'; Reason = 'Non-portable desktop: the Gaming preset applies the documented processor/power configuration.' }
}

function Invoke-POSystemRestorePointAttempt {
    [CmdletBinding()]
    param()
    # System Restore point: supplemental protection, never a substitute for
    # the explicit backup. Availability is checked first; the attempt is
    # time-bounded; every outcome is reported truthfully.
    if (-not (Test-POIsAdministrator)) {
        return (New-POResultRecord -Stage 'Recovery' -Id 'system-restore-point' -Status 'SKIPPED' -Message 'System Restore point skipped: session is not elevated.' -Reversible $false)
    }
    $config = $null
    try { $config = @(Get-CimInstance -Namespace 'root\default' -ClassName SystemRestoreConfig -ErrorAction Stop | Select-Object -First 1) } catch { }
    if ($config.Count -gt 0 -and $null -ne $config[0].PSObject.Properties['DisableSR'] -and [int]$config[0].DisableSR -eq 1) {
        return (New-POResultRecord -Stage 'Recovery' -Id 'system-restore-point' -Status 'SKIPPED' -Message 'System Restore is disabled on this system (reported by SystemRestoreConfig). The explicit configuration backup is the primary recovery path.' -Reversible $false)
    }
    if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) {
        return (New-POResultRecord -Stage 'Recovery' -Id 'system-restore-point' -Status 'SKIPPED' -Message 'Checkpoint-Computer is unavailable on this system; the explicit configuration backup is the primary recovery path.' -Reversible $false)
    }
    $description = 'Platinum Optimizer On Steroids - automatic optimization'
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($desc)
            Checkpoint-Computer -Description $desc -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
            'CREATED'
        } -ArgumentList $description
        $finished = Wait-Job -Job $job -Timeout 240
        if ($null -eq $finished) {
            return (New-POResultRecord -Stage 'Recovery' -Id 'system-restore-point' -Status 'WARN' -Message 'System Restore point creation did not finish within 240 s; it may still complete in the background. The explicit configuration backup was created independently.' -Reversible $false)
        }
        $jobResult = @(Receive-Job -Job $job -ErrorAction Stop)
        if (@($jobResult | Where-Object { [string]$_ -eq 'CREATED' }).Count -gt 0) {
            return (New-POResultRecord -Stage 'Recovery' -Id 'system-restore-point' -Status 'INFO' -Message 'System Restore point created (supplemental recovery; the configuration backup is the primary restore path).' -Reversible $true)
        }
        return (New-POResultRecord -Stage 'Recovery' -Id 'system-restore-point' -Status 'WARN' -Message 'System Restore point creation did not confirm success. The explicit configuration backup is the primary recovery path.' -Reversible $false)
    }
    catch {
        $reason = $_.Exception.Message
        if ($reason -match '(?i)interval|cannot create|already been created') {
            return (New-POResultRecord -Stage 'Recovery' -Id 'system-restore-point' -Status 'SKIPPED' -Message "Windows declined a new restore point (typically the creation interval limit): $reason" -Reversible $false)
        }
        return (New-POResultRecord -Stage 'Recovery' -Id 'system-restore-point' -Status 'WARN' -Message "System Restore point could not be created: $reason The explicit configuration backup is the primary recovery path." -Reversible $false)
    }
    finally {
        if ($job) { try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { }; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
}

function Show-POFinalReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Summary,
        [AllowNull()][string]$BackupPath,
        [AllowNull()][string]$LogDir,
        [string[]]$NextSteps = @(),
        [string[]]$Notes = @()
    )
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor White
    Write-Host '                  OPTIMIZATION REPORT' -ForegroundColor White
    Write-Host '============================================================' -ForegroundColor White
    Write-Host ''
    Write-Host ("Changes applied and verified : {0}" -f $Summary.Applied) -ForegroundColor Green
    Write-Host ("Already optimized            : {0}" -f $Summary.AlreadyOptimized) -ForegroundColor Green
    Write-Host ("Skipped (with reason)        : {0}" -f $Summary.Skipped) -ForegroundColor Cyan
    Write-Host ("Failed                       : {0}" -f $Summary.Failed) -ForegroundColor $(if ($Summary.Failed -gt 0) { 'Red' } else { 'Green' })
    Write-Host ("Unverified (not success)     : {0}" -f $Summary.Unverified) -ForegroundColor $(if ($Summary.Unverified -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host ("Reboot recommended           : {0}" -f $(if ($Summary.RebootRecommended) { 'Yes - to fully apply capture-related settings' } else { 'No' }))
    Write-Host ''
    Write-Host ("Backup : {0}" -f $(if ($BackupPath) { $BackupPath } else { 'None created (no change stage ran)' }))
    Write-Host ("Log    : {0}" -f $(if ($LogDir) { $LogDir } else { 'JSONL log only (run log unavailable)' }))
    if (@($NextSteps).Count -gt 0) {
        Write-Host ''
        Write-Host 'Recommended next steps:' -ForegroundColor White
        foreach ($step in $NextSteps) { Write-Host ("  - {0}" -f $step) }
    }
    if (@($Notes).Count -gt 0) {
        Write-Host ''
        Write-Host 'Honest notes:' -ForegroundColor White
        foreach ($note in $Notes) { Write-Host ("  - {0}" -f $note) }
    }
}

function Save-PORunReport {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][psobject]$Summary,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][psobject[]]$Results,
        [AllowNull()][string]$BackupPath,
        [AllowNull()][psobject]$MachineInfo,
        [string[]]$NextSteps = @()
    )
    $report = [pscustomobject][ordered]@{
        applicationVersion = Get-POEngineVersion
        mode = $Mode
        startedUtc = [string]$script:PORunStartedUtc
        finishedUtc = [DateTime]::UtcNow.ToString('o')
        administrator = (Test-POIsAdministrator)
        machine = $MachineInfo
        backupPath = $BackupPath
        runLogDir = $LogDir
        summary = $Summary
        results = $Results
        nextSteps = $NextSteps
    }
    if ($LogDir -and (Test-Path -LiteralPath $LogDir -PathType Container)) {
        try {
            Write-POJsonAtomic -Path (Join-Path $LogDir 'report.json') -Object $report
            return (Join-Path $LogDir 'report.json')
        }
        catch { Write-POLog -Level 'WARNING' -Category 'Engine' -Status 'REPORT_WRITE_FAILED' -Message $_.Exception.Message }
    }
    return $null
}

$script:PORunStartedUtc = [DateTime]::UtcNow.ToString('o')

function Invoke-POAutomaticOptimization {
    [CmdletBinding()]
    param()
    $script:PORunStartedUtc = [DateTime]::UtcNow.ToString('o')
    $runLog = Start-PORunLog -Mode 'optimize'
    $results = New-Object System.Collections.Generic.List[psobject]
    $runBackupPath = $null
    $machineInfo = $null

    Write-Host '============================================================' -ForegroundColor White
    Write-Host '        PLATINUM OPTIMIZER ON STEROIDS  v' -NoNewline -ForegroundColor White
    Write-Host (Get-POEngineVersion) -ForegroundColor Gray
    Write-Host '                AUTOMATIC MODE' -ForegroundColor White
    Write-Host '============================================================' -ForegroundColor White
    Write-Host ''

    # ---- 1. Preflight --------------------------------------------------------
    Write-POConsole -Level 'STEP' -Message 'PREFLIGHT'
    if (-not (Test-POIsWindows)) {
        Write-POConsole -Level 'FAIL' -Message 'Platinum Optimizer requires Windows 10/11 with Windows PowerShell 5.1.'
        return [pscustomobject]@{ ExitCode = 2; Results = @(); Summary = (Get-POReportSummary -Results @()); BackupPath = $null; LogDir = $runLog.LogDir; NextSteps = @() }
    }
    $isAdmin = Test-POIsAdministrator
    if ($isAdmin) { Write-POConsole -Level 'PASS' -Message 'Administrator privileges confirmed.' }
    else {
        Write-POConsole -Level 'FAIL' -Message 'This session is NOT elevated. Right-click PlatinumOptimizer.bat and choose "Run as administrator", or accept the UAC prompt.'
        return [pscustomobject]@{ ExitCode = 4; Results = @(); Summary = (Get-POReportSummary -Results @()); BackupPath = $null; LogDir = $runLog.LogDir; NextSteps = @('Relaunch as administrator.') }
    }
    if (Get-Command powercfg.exe -ErrorAction SilentlyContinue) { Write-POConsole -Level 'PASS' -Message 'powercfg.exe is available.' }
    else {
        $rec = New-POResultRecord -Stage 'Preflight' -Id 'powercfg' -Status 'FAILED' -Message 'powercfg.exe is missing; power-plan stages cannot run.'
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }

    # ---- 2. Detection --------------------------------------------------------
    Write-POConsole -Level 'STEP' -Message 'SYSTEM DETECTION'
    $snapshot = $null
    try { $snapshot = Get-POSystemSnapshot }
    catch { Write-POConsole -Level 'WARN' -Message "Full system snapshot failed: $($_.Exception.Message)" }
    if ($null -eq $snapshot) {
        Write-POConsole -Level 'FAIL' -Message 'System detection failed completely; stopping before any change (unsafe to proceed without hardware awareness).'
        $summary = Get-POReportSummary -Results $results.ToArray()
        [void](Save-PORunReport -LogDir $runLog.LogDir -Mode 'optimize' -Summary $summary -Results $results.ToArray() -BackupPath $null -MachineInfo $null)
        return [pscustomobject]@{ ExitCode = 1; Results = $results.ToArray(); Summary = $summary; BackupPath = $null; LogDir = $runLog.LogDir; NextSteps = @() }
    }
    $machineInfo = [pscustomobject][ordered]@{
        OS = "$($snapshot.OS.Name) | Build $($snapshot.OS.Build) | $($snapshot.OS.Architecture)"
        Device = "$($snapshot.Device.Manufacturer) $($snapshot.Device.Model) | $($snapshot.Device.FormFactor) | Power: $($snapshot.Device.PowerSource)"
        CPU = if ($snapshot.CPU) { "$($snapshot.CPU.Model) | cores $($snapshot.CPU.PhysicalCores) | logical $($snapshot.CPU.LogicalProcessors)" } else { 'Unknown' }
        MemoryGB = if ($snapshot.Memory) { $snapshot.Memory.TotalGB } else { $null }
        GPUs = @($snapshot.GPUs | ForEach-Object { "$($_.Name) [$($_.Vendor)] driver $($_.DriverVersion)" })
    }
    Write-POConsole -Level 'INFO' -Message "Windows: $($snapshot.OS.Name) | Build $($snapshot.OS.Build) | $($snapshot.OS.Architecture) | Supported: $($snapshot.OS.Supported)"
    Write-POConsole -Level 'INFO' -Message "Device: $($snapshot.Device.Manufacturer) $($snapshot.Device.Model) | $($snapshot.Device.FormFactor) | Power source: $($snapshot.Device.PowerSource)"
    if ($snapshot.CPU) { Write-POConsole -Level 'INFO' -Message "CPU: $($snapshot.CPU.Model) | physical cores: $(if ($snapshot.CPU.PhysicalCores) { $snapshot.CPU.PhysicalCores } else { 'Unknown' }) | logical: $(if ($snapshot.CPU.LogicalProcessors) { $snapshot.CPU.LogicalProcessors } else { 'Unknown' })" }
    else { Write-POConsole -Level 'WARN' -Message 'CPU information could not be read; processor stages will be conservative.' }
    foreach ($gpu in @($snapshot.GPUs)) { Write-POConsole -Level 'INFO' -Message "GPU: $($gpu.Name) [$($gpu.Vendor)] | driver $($gpu.DriverVersion) | reported mode $($gpu.ResolutionReportedByAdapter) @ $(if ($gpu.RefreshRateReportedByAdapterHz) { "$($gpu.RefreshRateReportedByAdapterHz) Hz" } else { 'Unknown' })" }
    if (@($snapshot.GPUs).Count -eq 0) { Write-POConsole -Level 'WARN' -Message 'No GPU controller was reported by Windows.' }
    if ($snapshot.Memory) { Write-POConsole -Level 'INFO' -Message "Memory: $($snapshot.Memory.TotalGB) GB total | $($snapshot.Memory.AvailableGB) GB available" }
    if ($snapshot.SystemVolume) { Write-POConsole -Level 'INFO' -Message "System volume: $($snapshot.SystemVolume.Drive) $($snapshot.SystemVolume.FreeGB) GB free of $($snapshot.SystemVolume.SizeGB) GB ($($snapshot.SystemVolume.FreePercent)%)" }
    foreach ($warning in @($snapshot.CollectionWarnings)) { Write-POConsole -Level 'WARN' -Message "Detection gap: $($warning.ClassName): $($warning.Error)" }

    Write-POConsole -Level 'INFO' -Message 'Detecting network configuration...'
    $adapters = @()
    try { $adapters = @(Get-PONetworkAdapterInventory) }
    catch { Write-POConsole -Level 'WARN' -Message "Network adapter inventory failed: $($_.Exception.Message)" }
    foreach ($adapter in @($adapters | Where-Object { $_.Status -eq 'Up' })) {
        Write-POConsole -Level 'INFO' -Message "Network: $($adapter.Name) [$($adapter.Kind)] link $(if ($adapter.LinkSpeed) { $adapter.LinkSpeed } else { 'Unknown' }) duplex $(if ($null -ne $adapter.FullDuplex) { $adapter.FullDuplex } else { 'Unknown' })"
    }

    Write-POConsole -Level 'INFO' -Message 'Checking the active power plan...'
    $activeGuid = Get-POActivePowerPlanGuid
    $platinumInfo = $null
    try { $platinumInfo = Get-POPlatinumPlanInfo } catch { Write-POConsole -Level 'WARN' -Message "Platinum plan info query failed: $($_.Exception.Message)" }
    $activeName = ''
    if ($activeGuid) {
        try {
            $activeEntry = @(Get-POPowerPlans | Where-Object { [string]$_.Guid -eq [string]$activeGuid } | Select-Object -First 1)
            if ($activeEntry.Count -gt 0) { $activeName = " ($($activeEntry[0].Name))" }
        }
        catch { }
        Write-POConsole -Level 'INFO' -Message "Active power plan GUID: $activeGuid$activeName"
    }
    else { Write-POConsole -Level 'WARN' -Message 'The active power plan GUID could not be read.' }
    if ($platinumInfo) { Write-POConsole -Level 'INFO' -Message "'Platinum On Steroids' plan: $(if ($platinumInfo.Exists) { "present ($($platinumInfo.PlanGuid))" } else { 'not created yet' })" }

    Write-POConsole -Level 'INFO' -Message 'Detecting gaming-related configuration...'
    $gamingState = @()
    try { $gamingState = @(Get-POGamingSettingsState) } catch { Write-POConsole -Level 'WARN' -Message "Gaming settings read failed: $($_.Exception.Message)" }
    foreach ($row in $gamingState) {
        $current = if ($row.Exists) { [string]$row.CurrentValue } else { 'not set' }
        Write-POConsole -Level 'INFO' -Message "$($row.DesiredText): current $current$(if ($row.MatchesDesired) { ' (already configured)' } else { '' })"
    }
    $hags = $null
    try { $hags = Get-POGraphicsSchedulingStatus; Write-POConsole -Level 'INFO' -Message "Hardware-accelerated GPU scheduling: $($hags.StatusText) (read-only)" } catch { }
    $pendingReboot = $null
    try {
        $pendingReboot = Get-POPendingRebootStatus
        if ($pendingReboot.PendingReboot) { Write-POConsole -Level 'WARN' -Message "Pending reboot indicator(s): $($pendingReboot.Reasons -join '; ')" }
        else { Write-POConsole -Level 'INFO' -Message 'No pending reboot indicator detected.' }
    } catch { }
    $parking = $null
    try {
        $parking = Get-POCpuParkingStatus
        $visibleParking = @($parking.ProcessorSettings | Where-Object { $_.Supported -and [string]$_.Id -match '^core-parking' })
        if ($visibleParking.Count -gt 0) {
            foreach ($setting in $visibleParking) { Write-POConsole -Level 'INFO' -Message "Core parking setting '$($setting.Name)': AC $(if ($null -ne $setting.AcValue) { $setting.AcValue } else { 'n/a' }) / DC $(if ($null -ne $setting.DcValue) { $setting.DcValue } else { 'n/a' }) (active plan)" }
        }
        else { Write-POConsole -Level 'INFO' -Message 'Core-parking controls are not exposed by the active power scheme on this system (Windows-managed).' }
        if ($parking.QuickCpu -and $parking.QuickCpu.Installed) { Write-POConsole -Level 'INFO' -Message "Quick CPU detected at $($parking.QuickCpu.Path). It is not launched or modified; it manages the same documented processor settings." }
    } catch { Write-POConsole -Level 'WARN' -Message "CPU parking readout failed: $($_.Exception.Message)" }

    # ---- 3. Restore point (supplemental) --------------------------------------
    Write-POConsole -Level 'STEP' -Message 'RECOVERY PREPARATION'
    Write-POConsole -Level 'INFO' -Message 'Attempting a System Restore point (supplemental; the explicit backup is primary)...'
    $rpRecord = Invoke-POSystemRestorePointAttempt
    $results.Add($rpRecord); Write-POResultToConsole -Result $rpRecord

    # ---- 4/5. Power plan (creates the run backup when it applies) --------------
    Write-POConsole -Level 'STEP' -Message 'POWER MANAGEMENT'
    Write-POConsole -Level 'INFO' -Message 'Creating configuration backup and applying the Platinum On Steroids power plan...'
    $presetDecision = Select-POAutoPowerPreset -Snapshot $snapshot
    $planResult = $null
    if ($presetDecision.Action -eq 'skip') {
        $rec = New-POResultRecord -Stage 'Power' -Id 'platinum-power-plan' -Status 'SKIPPED' -Message $presetDecision.Reason
        $results.Add($rec); Write-POResultToConsole -Result $rec
        try {
            Write-POConsole -Level 'INFO' -Message 'Creating the configuration backup (power stage skipped)...'
            $backup = New-POBackup
            $runBackupPath = [string]$backup.Path
            Write-POConsole -Level 'PASS' -Message "Configuration backup created and checksum-verified: $runBackupPath"
            foreach ($warning in @($backup.Warnings)) { Write-POConsole -Level 'WARN' -Message "Backup warning: $warning" }
        }
        catch {
            $rec = New-POResultRecord -Stage 'Backup' -Id 'configuration-backup' -Status 'FAILED' -Message "Configuration backup failed: $($_.Exception.Message) No system changes will be applied without a verified backup."
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
    }
    else {
        try {
            # The workflow creates and checksum-verifies the backup BEFORE any
            # plan change, reuses an existing Platinum plan (idempotent), applies
            # only documented settings, verifies each write, and activates the
            # plan only after verification.
            $planResult = Invoke-POPlatinumPlanWorkflow -PresetId $presetDecision.PresetId -Activate -Confirm:$false
            if ($planResult.Backup) { $runBackupPath = [string]$planResult.Backup.Path }
            if ($planResult.Status -like 'APPLIED*') {
                $rec = New-POResultRecord -Stage 'Power' -Id 'platinum-power-plan' -Status 'APPLIED_VERIFIED' -Message "Platinum On Steroids preset '$($presetDecision.PresetId)' applied and verified (plan $($planResult.PlanGuid)); $(@($planResult.Applied).Count) setting(s) verified, $(@($planResult.Skipped).Count) unsupported setting(s) skipped; plan activation verified by re-reading the active scheme GUID." -Details ((@($planResult.Skipped)) -join '; ') -Reversible $true
                $results.Add($rec); Write-POResultToConsole -Result $rec
                foreach ($skip in @($planResult.Skipped)) { Write-POConsole -Level 'SKIP' -Message "Power setting not supported on this platform: $skip" }
                if ($runBackupPath) { Write-POConsole -Level 'PASS' -Message "Configuration backup created and checksum-verified: $runBackupPath" }
            }
            else {
                $rec = New-POResultRecord -Stage 'Power' -Id 'platinum-power-plan' -Status 'FAILED' -Message $planResult.Message -Reversible $true
                $results.Add($rec); Write-POResultToConsole -Result $rec
            }
        }
        catch {
            $rec = New-POResultRecord -Stage 'Power' -Id 'platinum-power-plan' -Status 'FAILED' -Message "Power-plan workflow failed: $($_.Exception.Message)" -Reversible $true
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
        if (-not $runBackupPath) {
            # The workflow failed before/without producing a backup; create the
            # run backup now so the remaining stages still have recovery data.
            try {
                $backup = New-POBackup
                $runBackupPath = [string]$backup.Path
                Write-POConsole -Level 'PASS' -Message "Configuration backup created and checksum-verified: $runBackupPath"
            }
            catch {
                $rec = New-POResultRecord -Stage 'Backup' -Id 'configuration-backup' -Status 'FAILED' -Message "Configuration backup failed: $($_.Exception.Message) Remaining change stages will be skipped."
                $results.Add($rec); Write-POResultToConsole -Result $rec
            }
        }
    }

    # ---- 7. Windows gaming settings --------------------------------------------
    Write-POConsole -Level 'STEP' -Message 'WINDOWS GAMING SETTINGS'
    if ($runBackupPath) {
        try {
            foreach ($rec in @(Invoke-POGamingOptimization -BackupPath $runBackupPath)) { $results.Add($rec); Write-POResultToConsole -Result $rec }
        }
        catch {
            $rec = New-POResultRecord -Stage 'Gaming' -Id 'gaming-settings' -Status 'FAILED' -Message "Gaming settings stage failed: $($_.Exception.Message)"
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
    }
    else {
        $rec = New-POResultRecord -Stage 'Gaming' -Id 'gaming-settings' -Status 'SKIPPED' -Message 'No verified backup exists; gaming registry changes are skipped (backup-first policy).'
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }

    # ---- 8. GPU / display assessment (read-only) --------------------------------
    Write-POConsole -Level 'STEP' -Message 'GPU AND DISPLAY ASSESSMENT'
    $refreshAdvice = $null
    try {
        $displayInventory = Get-PODisplayInventory
        foreach ($display in @($displayInventory.Displays)) {
            $currentHz = if ($null -ne $display.RefreshRateHz) { [int]$display.RefreshRateHz } else { $null }
            $maxHz = if ($null -ne $display.HighestAvailableRefreshAtCurrentResolution) { [int]$display.HighestAvailableRefreshAtCurrentResolution } else { $null }
            Write-POConsole -Level 'INFO' -Message "Display '$($display.DeviceName)': $($display.Resolution) @ $(if ($currentHz) { "$currentHz Hz" } else { 'Unknown Hz' }) | highest available at this resolution: $(if ($maxHz) { "$maxHz Hz" } else { 'Unknown' })"
            if ($currentHz -and $maxHz -and $maxHz -gt $currentHz) {
                $refreshAdvice = "Display '$($display.DeviceName)' runs at $currentHz Hz but enumerates $maxHz Hz at the same resolution. Change it in Settings > System > Display > Advanced display if your monitor/cable support it (never changed automatically: an unsupported refresh rate can blank the screen)."
            }
        }
    }
    catch { Write-POConsole -Level 'WARN' -Message "Display inventory failed: $($_.Exception.Message)" }
    try {
        $colorControls = @(Get-POGpuColorControlStatus)
        foreach ($control in $colorControls) { Write-POConsole -Level 'INFO' -Message "GPU color control: $control" }
        Write-POConsole -Level 'INFO' -Message 'No color/saturation value is changed automatically: vendor saturation controls have no documented write API here, and third-party color software (e.g. PlexusX) is never touched.'
    }
    catch { Write-POConsole -Level 'INFO' -Message 'GPU color-control detection unavailable; no color change is attempted.' }
    if ($hags) {
        $rec = New-POResultRecord -Stage 'GPU' -Id 'hardware-gpu-scheduling' -Status 'INFO' -Message "HAGS: $($hags.StatusText). Read-only: enabling it requires a reboot and depends on GPU/driver support." -Details $hags.Note
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }

    # ---- 9-11. Network ---------------------------------------------------------
    Write-POConsole -Level 'STEP' -Message 'NETWORK ASSESSMENT AND OPTIMIZATION'
    if ($runBackupPath) {
        try {
            foreach ($rec in @(Invoke-PONetworkOptimization -BackupPath $runBackupPath -Snapshot $snapshot)) { $results.Add($rec); Write-POResultToConsole -Result $rec }
        }
        catch {
            $rec = New-POResultRecord -Stage 'Network' -Id 'network-optimization' -Status 'FAILED' -Message "Network stage failed: $($_.Exception.Message)"
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
    }
    else {
        $rec = New-POResultRecord -Stage 'Network' -Id 'network-optimization' -Status 'SKIPPED' -Message 'No verified backup exists; network changes are skipped (backup-first policy). The assessment above remains valid.'
        $results.Add($rec); Write-POResultToConsole -Result $rec
        try {
            $tcpState = Get-POTcpGlobalState
            $plan = Get-PONetworkOptimizationPlan -TcpState $tcpState -LogicalProcessors 0
            foreach ($item in @($plan.ReportOnly)) { $rec = New-POResultRecord -Stage 'Network' -Id $item.Id -Status 'INFO' -Message $item.Message; $results.Add($rec); Write-POResultToConsole -Result $rec }
        }
        catch { }
    }

    # ---- Storage / startup / background assessment (read-only) -------------------
    Write-POConsole -Level 'STEP' -Message 'STORAGE AND BACKGROUND ACTIVITY ASSESSMENT'
    if ($snapshot.SystemVolume -and $null -ne $snapshot.SystemVolume.FreePercent -and [double]$snapshot.SystemVolume.FreePercent -lt 10) {
        $rec = New-POResultRecord -Stage 'Storage' -Id 'free-space' -Status 'WARN' -Message "System drive has only $($snapshot.SystemVolume.FreePercent)% free space; low free space degrades storage performance. Free space via Settings > System > Storage."
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }
    try {
        $tempPreview = Get-POUserTempPreview -MinimumAgeDays 7
        $rec = New-POResultRecord -Stage 'Storage' -Id 'temp-files' -Status 'INFO' -Message "User TEMP: $($tempPreview.FileCount) file(s) older than 7 days ($([math]::Round($tempPreview.TotalBytes / 1MB, 1)) MB). Not deleted automatically - deletion is irreversible; review in Settings > System > Storage > Temporary files."
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }
    catch { Write-POConsole -Level 'WARN' -Message "TEMP preview failed: $($_.Exception.Message)" }
    try {
        $startup = @(Get-POStartupAudit)
        $rec = New-POResultRecord -Stage 'Startup' -Id 'startup-apps' -Status 'INFO' -Message "$($startup.Count) startup entry/entries registered. Nothing was disabled automatically; review per-app in Settings > Apps > Startup (impact is not guessed)."
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }
    catch { Write-POConsole -Level 'WARN' -Message "Startup audit failed: $($_.Exception.Message)" }
    try {
        $background = Get-POBackgroundProcessSummary
        if ($background.ProcessCount) {
            $top = @($background.TopProcesses | Select-Object -First 5 | ForEach-Object { "$($_.Name) ($($_.WorkingSetMB) MB)" }) -join ', '
            $rec = New-POResultRecord -Stage 'Background' -Id 'background-processes' -Status 'INFO' -Message "$($background.ProcessCount) processes running. Largest by working set: $top. No process is terminated by the optimizer."
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
    }
    catch { }
    $rec = New-POResultRecord -Stage 'Services' -Id 'services-policy' -Status 'INFO' -Message 'Windows services (including SysMain, Windows Search, audio, networking, and all security services) were NOT modified. Defender, Firewall, and Windows Update remain untouched.'
    $results.Add($rec); Write-POResultToConsole -Result $rec

    # ---- 13. Final verification pass --------------------------------------------
    Write-POConsole -Level 'STEP' -Message 'FINAL VERIFICATION'
    $appliedPower = @($results | Where-Object { $_.Id -eq 'platinum-power-plan' -and $_.Status -eq 'APPLIED_VERIFIED' })
    if ($appliedPower.Count -gt 0 -and $planResult -and $planResult.PlanGuid) {
        $activeNow = Get-POActivePowerPlanGuid
        if ($activeNow -eq ([string]$planResult.PlanGuid).ToLowerInvariant()) {
            $rec = New-POResultRecord -Stage 'Verify' -Id 'active-plan' -Status 'INFO' -Message "Verified: Windows reports 'Platinum On Steroids' ($activeNow) as the active power plan."
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
        else {
            $rec = New-POResultRecord -Stage 'Verify' -Id 'active-plan' -Status 'UNVERIFIED' -Message "The active plan reads as '$activeNow' instead of the Platinum plan; the activation could not be confirmed."
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
    }
    try {
        $gamingNow = @(Get-POGamingSettingsState)
        $appliedGaming = @($results | Where-Object { $_.Stage -eq 'Gaming' -and $_.Status -eq 'APPLIED_VERIFIED' })
        if ($appliedGaming.Count -gt 0) {
            $mismatch = @($gamingNow | Where-Object { -not $_.MatchesDesired -and $_.Readable })
            if ($mismatch.Count -eq 0) {
                $rec = New-POResultRecord -Stage 'Verify' -Id 'gaming-settings' -Status 'INFO' -Message "Verified: all $($gamingNow.Count) gaming registry targets read back at their desired values."
                $results.Add($rec); Write-POResultToConsole -Result $rec
            }
            else {
                $rec = New-POResultRecord -Stage 'Verify' -Id 'gaming-settings' -Status 'UNVERIFIED' -Message "$(@($mismatch).Count) gaming setting(s) did not read back at the desired value."
                $results.Add($rec); Write-POResultToConsole -Result $rec
            }
        }
    }
    catch { }
    try {
        $appliedTcp = @($results | Where-Object { $_.Stage -eq 'Network' -and $_.Status -eq 'APPLIED_VERIFIED' -and $_.Id -like 'tcp-*' })
        if ($appliedTcp.Count -gt 0) {
            $tcpNow = Get-POTcpGlobalState
            $rec = New-POResultRecord -Stage 'Verify' -Id 'tcp-state' -Status 'INFO' -Message "Verified TCP state after changes: autotuning $(if ($tcpNow.AutotuningLevelEffective) { $tcpNow.AutotuningLevelEffective } elseif ($tcpNow.AutotuningLevel) { $tcpNow.AutotuningLevel } else { 'Unknown' }), RSS $($tcpNow.RssState)."
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
    }
    catch { }

    # ---- 14. Report ---------------------------------------------------------------
    $summary = Get-POReportSummary -Results $results.ToArray()
    $nextSteps = @()
    if ($refreshAdvice) { $nextSteps += $refreshAdvice }
    if ($hags -and ($null -eq $hags.HwSchMode -or $hags.HwSchMode -eq 1)) { $nextSteps += 'Consider Hardware-accelerated GPU scheduling in Settings > System > Display > Graphics if your GPU/driver supports it (requires reboot; effect is game-dependent).' }
    if ($pendingReboot -and $pendingReboot.PendingReboot) { $nextSteps += 'A reboot is already pending on this system; reboot before judging performance.' }
    if ($summary.RebootRecommended) { $nextSteps += 'Restart Windows (or sign out/in) so capture-related settings fully apply.' }
    $nextSteps += 'Measure honestly: run "PlatinumOptimizer.bat --benchmark" before/after a comparable gaming session; FPS/frame-time must come from a real in-game benchmark.'
    $nextSteps += 'Restore any recorded change with "PlatinumOptimizer.bat --restore" (restores the latest verified backup).'
    $notes = @(Get-PONetworkReportNotes)
    $notes += 'No FPS, latency, or ping improvement is guaranteed by any Windows optimizer; results depend on hardware, drivers, the game, and the server.'

    [void](Save-PORunReport -LogDir $runLog.LogDir -Mode 'optimize' -Summary $summary -Results $results.ToArray() -BackupPath $runBackupPath -MachineInfo $machineInfo -NextSteps $nextSteps)
    Show-POFinalReport -Summary $summary -BackupPath $runBackupPath -LogDir $runLog.LogDir -NextSteps $nextSteps -Notes $notes
    Write-POLog -Category 'Engine' -Status 'RUN_COMPLETE' -Message ("Automatic run finished: applied {0}, already {1}, skipped {2}, failed {3}, unverified {4}." -f $summary.Applied, $summary.AlreadyOptimized, $summary.Skipped, $summary.Failed, $summary.Unverified)

    $exitCode = if (($summary.Failed -gt 0) -or ($summary.Unverified -gt 0)) { 1 } else { 0 }
    return [pscustomobject]@{ ExitCode = $exitCode; Results = $results.ToArray(); Summary = $summary; BackupPath = $runBackupPath; LogDir = $runLog.LogDir; NextSteps = $nextSteps }
}

function Select-PORestoreBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][psobject[]]$Backups,
        [AllowNull()][string]$BackupId
    )
    # Pure selection: explicit id wins; otherwise the newest VALID backup that
    # actually recorded optimizer changes. Never selects an INVALID backup.
    if (@($Backups).Count -eq 0) { return [pscustomobject]@{ Selected = $null; Reason = 'No Platinum Optimizer backup was found in any backup location.' } }
    if (-not [string]::IsNullOrWhiteSpace($BackupId)) {
        $match = @($Backups | Where-Object { [string]$_.Id -eq $BackupId } | Select-Object -First 1)
        if ($match.Count -eq 0) { return [pscustomobject]@{ Selected = $null; Reason = "No backup with id '$BackupId' was found." } }
        if ([string]$match[0].Status -ne 'VALID') { return [pscustomobject]@{ Selected = $null; Reason = "Backup '$BackupId' failed validation: $(@($match[0].Issues) -join '; ')" } }
        return [pscustomobject]@{ Selected = $match[0]; Reason = $null }
    }
    $valid = @($Backups | Where-Object { [string]$_.Status -eq 'VALID' -and [int]$_.ChangeCount -gt 0 } | Sort-Object -Property CreatedAt -Descending)
    if ($valid.Count -eq 0) {
        $anyValid = @($Backups | Where-Object { [string]$_.Status -eq 'VALID' })
        if ($anyValid.Count -eq 0) { return [pscustomobject]@{ Selected = $null; Reason = 'Every found backup failed checksum/manifest validation; nothing will be restored from an untrusted backup.' } }
        return [pscustomobject]@{ Selected = $null; Reason = 'Valid backups exist but none recorded optimizer changes; there is nothing to restore.' }
    }
    return [pscustomobject]@{ Selected = $valid[0]; Reason = $null }
}

function Invoke-PORestoreMode {
    [CmdletBinding()]
    param([AllowNull()][string]$BackupId)
    $script:PORunStartedUtc = [DateTime]::UtcNow.ToString('o')
    $runLog = Start-PORunLog -Mode 'restore'
    Write-Host '============================================================' -ForegroundColor White
    Write-Host '      PLATINUM OPTIMIZER ON STEROIDS - RESTORE MODE' -ForegroundColor White
    Write-Host '============================================================' -ForegroundColor White
    Write-Host ''
    if (-not (Test-POIsWindows)) {
        Write-POConsole -Level 'FAIL' -Message 'Restore is available only on Windows.'
        return [pscustomobject]@{ ExitCode = 2 }
    }
    $backups = @(Get-POBackups)
    foreach ($backup in $backups) {
        Write-POConsole -Level 'INFO' -Message "Found backup $($backup.Id) [$($backup.Status)] changes: $(if ($backup.ChangeCount -gt 0) { $backup.Changes } else { 'none recorded' }) at $($backup.Path)"
    }
    $selection = Select-PORestoreBackup -Backups $backups -BackupId $BackupId
    if ($null -eq $selection.Selected) {
        Write-POConsole -Level 'WARN' -Message $selection.Reason
        return [pscustomobject]@{ ExitCode = 1 }
    }
    $chosen = $selection.Selected
    Write-POConsole -Level 'INFO' -Message "Restoring recorded changes from $($chosen.Id) (only sections this application changed; the manifest is validated first)..."
    try {
        $result = Restore-POBackup -BackupPath $chosen.Path -Confirm:$false
        if ($result.Status -eq 'RESTORED') {
            Write-POConsole -Level 'PASS' -Message "Restored and verified section(s): $(@($result.Restored) -join ', ')."
            Write-POLog -Category 'Engine' -Status 'RESTORE_COMPLETE' -Message "Restored backup $($chosen.Id): $(@($result.Restored) -join ', ')."
            return [pscustomobject]@{ ExitCode = 0 }
        }
        if ($result.Status -eq 'NO_CHANGES') {
            Write-POConsole -Level 'INFO' -Message $result.Message
            return [pscustomobject]@{ ExitCode = 0 }
        }
        Write-POConsole -Level 'FAIL' -Message "Restore stopped: $($result.Message)"
        foreach ($failure in @($result.Failures)) { Write-POConsole -Level 'FAIL' -Message $failure }
        Write-POConsole -Level 'INFO' -Message 'Restored sections so far are verified; remaining sections were left untouched for safety.'
        return [pscustomobject]@{ ExitCode = 1 }
    }
    catch {
        Write-POConsole -Level 'FAIL' -Message "Restore failed: $($_.Exception.Message)"
        return [pscustomobject]@{ ExitCode = 1 }
    }
}

function Invoke-POBenchmarkMode {
    [CmdletBinding()]
    param([AllowNull()][string]$Target, [ValidateRange(1, 30)][int]$SampleSeconds = 8)
    $script:PORunStartedUtc = [DateTime]::UtcNow.ToString('o')
    $runLog = Start-PORunLog -Mode 'benchmark'
    Write-Host '============================================================' -ForegroundColor White
    Write-Host '     PLATINUM OPTIMIZER ON STEROIDS - BENCHMARK MODE' -ForegroundColor White
    Write-Host '============================================================' -ForegroundColor White
    Write-Host ''
    Write-POConsole -Level 'INFO' -Message "Sampling system counters for $SampleSeconds second(s). No system setting is changed in this mode."
    if (-not (Test-POIsWindows)) {
        Write-POConsole -Level 'FAIL' -Message 'Benchmark mode is available only on Windows.'
        return [pscustomobject]@{ ExitCode = 2 }
    }
    try {
        $usePing = -not [string]::IsNullOrWhiteSpace($Target)
        $benchParams = @{ SampleSeconds = $SampleSeconds }
        if ($usePing) { $benchParams['IncludeNetworkPing'] = $true; $benchParams['NetworkHost'] = [string]$Target }
        $snapshot = Get-POBenchmarkSnapshot @benchParams
        $path = Save-POBenchmarkSnapshot -Label 'standalone' -Snapshot $snapshot
        $m = $snapshot.Metrics
        Write-POConsole -Level 'INFO' -Message ("CPU usage: {0}% | RAM available: {1} GB | commit: {2} GB" -f $(if ($null -ne $m.CpuUsagePercent) { $m.CpuUsagePercent } else { 'unavailable' }), $(if ($null -ne $m.RamAvailableGB) { $m.RamAvailableGB } else { 'unavailable' }), $(if ($null -ne $m.MemoryCommitGB) { $m.MemoryCommitGB } else { 'unavailable' }))
        Write-POConsole -Level 'INFO' -Message ("Disk active: {0}% | DPC time: {1}% | interrupt time: {2}%" -f $(if ($null -ne $m.DiskPercentTime) { $m.DiskPercentTime } else { 'unavailable' }), $(if ($null -ne $m.DpcTimePercent) { $m.DpcTimePercent } else { 'unavailable' }), $(if ($null -ne $m.InterruptTimePercent) { $m.InterruptTimePercent } else { 'unavailable' }))
        Write-POConsole -Level 'INFO' -Message ("GPU usage: not measured by the generic CIM path | FPS/frame time: not measured (no game injection)")
        if ($usePing -and $m.NetworkPing) {
            Write-POConsole -Level 'INFO' -Message ("ICMP to {0}: avg {1} ms, loss {2}%. ICMP is not a game-server route measurement." -f $m.NetworkPing.Target, $(if ($null -ne $m.NetworkPing.AverageMs) { $m.NetworkPing.AverageMs } else { 'n/a' }), $(if ($null -ne $m.NetworkPing.PacketLossPercent) { $m.NetworkPing.PacketLossPercent } else { 'n/a' }))
        }
        Write-POConsole -Level 'PASS' -Message "Snapshot saved: $path"
        Write-POConsole -Level 'INFO' -Message 'These are short system observations, not a controlled gameplay benchmark. Compare snapshots captured under comparable conditions; a difference is not automatically a causal optimization benefit.'
        Write-POLog -Category 'Engine' -Status 'BENCHMARK_SAVED' -Message "Benchmark snapshot saved to $path."
        return [pscustomobject]@{ ExitCode = 0 }
    }
    catch {
        Write-POConsole -Level 'FAIL' -Message "Benchmark sampling failed: $($_.Exception.Message)"
        return [pscustomobject]@{ ExitCode = 1 }
    }
}

Export-ModuleMember -Function @(
    'Get-POEngineVersion', 'Get-POConsolePrefix', 'Write-POConsole', 'Get-PORunLogRoot', 'Start-PORunLog',
    'New-POResultRecord', 'Write-POResultToConsole', 'Get-POReportSummary', 'Select-POAutoPowerPreset',
    'Invoke-POSystemRestorePointAttempt', 'Show-POFinalReport', 'Save-PORunReport',
    'Invoke-POAutomaticOptimization', 'Select-PORestoreBackup', 'Invoke-PORestoreMode', 'Invoke-POBenchmarkMode'
)
