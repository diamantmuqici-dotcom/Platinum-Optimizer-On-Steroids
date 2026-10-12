#requires -Version 5.1
# Platinum Optimizer - Windows Gaming settings module (CMD engine v2.0)
# Game Mode / Game DVR registry optimization with capture-before,
# verify-after, and restore through the existing Core registry ledger
# (the same four allowlisted HKCU keys the Core backup snapshots).
# Also provides read-only assessments: graphics scheduling (HAGS),
# pending reboot indicators, startup entries, and background processes.
# Nothing here disables security, services, or essential components.
Set-StrictMode -Version 2.0

if (-not (Get-Module | Where-Object { $_.Name -eq 'PlatinumOptimizer.Core' })) {
    Import-Module -Name (Join-Path $PSScriptRoot 'PlatinumOptimizer.Core.psm1') -Global -Force -ErrorAction Stop
}

function Get-POGamingSettingTargets {
    # Pure table. Every entry must stay inside the Core registry snapshot
    # allowlist (Get-PORegistrySnapshotKeys / Restore-PORegistryChanges).
    return @(
        [pscustomobject][ordered]@{
            Id = 'game-mode-auto'; Hive = 'CurrentUser'; SubKey = 'Software\Microsoft\GameBar'; ValueName = 'AutoGameModeEnabled'
            DesiredValue = 1; DesiredText = 'Game Mode enabled'
            Purpose = 'Windows Game Mode prioritizes CPU/GPU resources for the foreground game. Microsoft documents it as the supported gaming scheduling feature.'
            RequiresSignOut = $false
        },
        [pscustomobject][ordered]@{
            Id = 'game-mode-allow'; Hive = 'CurrentUser'; SubKey = 'Software\Microsoft\GameBar'; ValueName = 'AllowAutoGameMode'
            DesiredValue = 1; DesiredText = 'Game Mode allowed'
            Purpose = 'Allows Windows to activate Game Mode automatically.'
            RequiresSignOut = $false
        },
        [pscustomobject][ordered]@{
            Id = 'game-dvr-enabled'; Hive = 'CurrentUser'; SubKey = 'System\GameConfigStore'; ValueName = 'GameDVR_Enabled'
            DesiredValue = 0; DesiredText = 'Background Game DVR recording off'
            Purpose = 'Disables the Game DVR flag used for background recording. Background capture consumes GPU encoder time during games; users who record clips can re-enable it in Settings > Gaming > Captures.'
            RequiresSignOut = $true
        },
        [pscustomobject][ordered]@{
            Id = 'app-capture-enabled'; Hive = 'CurrentUser'; SubKey = 'Software\Microsoft\Windows\CurrentVersion\GameDVR'; ValueName = 'AppCaptureEnabled'
            DesiredValue = 0; DesiredText = 'App capture off'
            Purpose = 'Turns off the Xbox capture pipeline that records in the background. This is the same switch Settings > Gaming > Captures exposes.'
            RequiresSignOut = $true
        }
    )
}

function Get-POGamingSettingsState {
    [CmdletBinding()]
    param()
    $rows = @()
    foreach ($target in @(Get-POGamingSettingTargets)) {
        $state = Get-PORegValueState -Hive $target.Hive -SubKey $target.SubKey -ValueName $target.ValueName
        $current = $null
        if ($state.Exists -and $state.Readable) { $current = [int]$state.Data }
        $rows += [pscustomobject][ordered]@{
            Id = [string]$target.Id
            Name = "$($target.SubKey)\$($target.ValueName)"
            DesiredText = [string]$target.DesiredText
            Readable = [bool]$state.Readable
            Exists = [bool]$state.Exists
            CurrentValue = $current
            MatchesDesired = ($state.Readable -and $state.Exists -and $current -eq [int]$target.DesiredValue)
            ReadError = $state.ReadError
        }
    }
    return $rows
}

function Invoke-POGamingOptimization {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupPath)
    # Writes only values that deviate from the desired state, verifies each
    # write by re-reading, and records every change in the backup ledger so
    # Restore-PORegistryChanges (Core allowlist) can reverse it exactly.
    $results = @()
    if (-not (Test-POIsWindows)) { throw 'Gaming settings optimization is available only on Windows.' }
    foreach ($target in @(Get-POGamingSettingTargets)) {
        $before = Get-PORegValueState -Hive $target.Hive -SubKey $target.SubKey -ValueName $target.ValueName
        if (-not $before.Readable) {
            $results += [pscustomobject][ordered]@{ Stage = 'Gaming'; Id = [string]$target.Id; Status = 'SKIPPED'; Message = "$($target.DesiredText): current value could not be read ($($before.ReadError)); left untouched."; Details = $null; RequiresReboot = $false; Reversible = $false }
            continue
        }
        if ($before.Exists -and [int]$before.Data -eq [int]$target.DesiredValue) {
            $results += [pscustomobject][ordered]@{ Stage = 'Gaming'; Id = [string]$target.Id; Status = 'ALREADY_OPTIMIZED'; Message = "$($target.DesiredText) - already configured ($($target.ValueName)=$([int]$before.Data))."; Details = $null; RequiresReboot = $false; Reversible = $false }
            continue
        }
        $beforeText = if ($before.Exists) { "$($target.ValueName)=$([int]$before.Data)" } else { "$($target.ValueName) not present" }
        $changeRecord = [pscustomobject][ordered]@{
            section = 'registry'; id = [string]$target.Id; name = $target.DesiredText
            hive = [string]$target.Hive; subKey = [string]$target.SubKey; valueName = [string]$target.ValueName
            before = $beforeText; after = "$($target.ValueName)=$([int]$target.DesiredValue)"
            purpose = [string]$target.Purpose; status = 'APPLYING'; timestampUtc = [DateTime]::UtcNow.ToString('o')
        }
        Add-POBackupChange -BackupPath $BackupPath -Section registry -Change $changeRecord
        try {
            $desiredState = [pscustomobject][ordered]@{
                Hive = [string]$target.Hive; SubKey = [string]$target.SubKey; ValueName = [string]$target.ValueName
                Exists = $true; Kind = 'DWord'; Data = [int]$target.DesiredValue; Readable = $true
            }
            Set-PORegValueState -State $desiredState
            $verify = Get-PORegValueState -Hive $target.Hive -SubKey $target.SubKey -ValueName $target.ValueName
            if ($verify.Readable -and $verify.Exists -and [int]$verify.Data -eq [int]$target.DesiredValue) {
                Update-POBackupChangeStatus -BackupPath $BackupPath -Section registry -ChangeId ([string]$target.Id) -Status 'APPLIED_VERIFIED' -Message "Written and verified: $beforeText -> $($target.ValueName)=$([int]$target.DesiredValue)."
                $results += [pscustomobject][ordered]@{ Stage = 'Gaming'; Id = [string]$target.Id; Status = 'APPLIED_VERIFIED'; Message = "$($target.DesiredText): $beforeText -> $($target.ValueName)=$([int]$target.DesiredValue), verified by re-reading."; Details = $target.Purpose; RequiresReboot = [bool]$target.RequiresSignOut; Reversible = $true }
            }
            else {
                # Roll the single value back to its captured state so no
                # half-applied setting survives a verification failure.
                try { Set-PORegValueState -State $before } catch { }
                Update-POBackupChangeStatus -BackupPath $BackupPath -Section registry -ChangeId ([string]$target.Id) -Status 'FAILED' -Message 'Verification failed after write; the original value was restored.'
                $results += [pscustomobject][ordered]@{ Stage = 'Gaming'; Id = [string]$target.Id; Status = 'FAILED'; Message = "$($target.DesiredText): verification failed after writing; the original value was restored. Not reported as applied."; Details = $null; RequiresReboot = $false; Reversible = $true }
            }
        }
        catch {
            try { Set-PORegValueState -State $before } catch { }
            Update-POBackupChangeStatus -BackupPath $BackupPath -Section registry -ChangeId ([string]$target.Id) -Status 'FAILED' -Message $_.Exception.Message
            $results += [pscustomobject][ordered]@{ Stage = 'Gaming'; Id = [string]$target.Id; Status = 'FAILED'; Message = "$($target.DesiredText): $($_.Exception.Message)"; Details = $null; RequiresReboot = $false; Reversible = $true }
        }
    }
    return $results
}

function Get-POGraphicsSchedulingStatus {
    [CmdletBinding()]
    param()
    # Hardware-accelerated GPU scheduling (HAGS) assessment. Read-only:
    # enabling HAGS requires a reboot, depends on GPU/driver support, and can
    # regress some workloads, so it stays a user decision in Windows Settings.
    $state = Get-PORegValueState -Hive LocalMachine -SubKey 'SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ValueName 'HwSchMode'
    $value = $null; $text = 'Unknown'
    if ($state.Readable -and $state.Exists) {
        $value = [int]$state.Data
        $text = switch ($value) {
            1 { 'Off (HwSchMode=1)' }
            2 { 'On (HwSchMode=2)' }
            default { "Non-standard value ($value)" }
        }
    }
    elseif ($state.Readable) { $text = 'Not set - Windows/driver decides' }
    else { $text = "Could not be read: $($state.ReadError)" }
    return [pscustomobject][ordered]@{
        HwSchMode = $value
        StatusText = $text
        Changed = $false
        Note = 'Read-only assessment. HAGS depends on GPU and driver support and requires a reboot; change it only in Settings > System > Display > Graphics if a game benefits.'
    }
}

function Get-POPendingRebootStatus {
    [CmdletBinding()]
    param()
    # Read-only pending-reboot indicators from documented registry locations.
    $reasons = @()
    $checks = @(
        @{ Hive = 'LocalMachine'; SubKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'; ValueName = 'RebootPending'; Label = 'Component-based servicing reboot pending' },
        @{ Hive = 'LocalMachine'; SubKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'; ValueName = 'RebootRequired'; Label = 'Windows Update reboot required' }
    )
    foreach ($check in $checks) {
        try {
            $state = Get-PORegValueState -Hive $check.Hive -SubKey $check.SubKey -ValueName $check.ValueName
            if ($state.Readable -and $state.Exists) { $reasons += [string]$check.Label }
        }
        catch { }
    }
    try {
        $pfro = Get-PORegValueState -Hive LocalMachine -SubKey 'SYSTEM\CurrentControlSet\Control\Session Manager' -ValueName 'PendingFileRenameOperations'
        if ($pfro.Readable -and $pfro.Exists) { $reasons += 'Pending file rename operations are queued' }
    }
    catch { }
    return [pscustomobject][ordered]@{
        PendingReboot = ($reasons.Count -gt 0)
        Reasons = $reasons
        Note = 'Read-only detection. Pending Windows updates can mask optimization effects; rebooting before judging performance is recommended.'
    }
}

function Get-POBackgroundProcessSummary {
    [CmdletBinding()]
    param([int]$Top = 8)
    # Read-only. Processes are identified and reported; none is terminated.
    $rows = @()
    $total = 0
    try {
        $processes = @(Get-Process -ErrorAction Stop)
        $total = $processes.Count
        $rows = @($processes |
            Sort-Object -Property WorkingSet64 -Descending |
            Select-Object -First $Top |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Name = [string]$_.ProcessName
                    WorkingSetMB = [math]::Round(([double]$_.WorkingSet64 / 1MB), 1)
                    Note = 'Reported for visibility only; no process is terminated by the optimizer'
                }
            })
    }
    catch {
        return [pscustomobject][ordered]@{ ProcessCount = $null; TopProcesses = @(); Error = $_.Exception.Message }
    }
    return [pscustomobject][ordered]@{ ProcessCount = $total; TopProcesses = $rows; Error = $null }
}

Export-ModuleMember -Function @(
    'Get-POGamingSettingTargets', 'Get-POGamingSettingsState', 'Invoke-POGamingOptimization',
    'Get-POGraphicsSchedulingStatus', 'Get-POPendingRebootStatus', 'Get-POBackgroundProcessSummary'
)
