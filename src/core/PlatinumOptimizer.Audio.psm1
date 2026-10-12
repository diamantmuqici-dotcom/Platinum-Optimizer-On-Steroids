#requires -Version 5.1
# Platinum Optimizer - Audio & Headphones module
# Read-first audio inventory plus presets whose only automatic change is a
# fully readable, verifiable and restorable Windows value (communications
# ducking). Everything else is surfaced as verified detection and manual
# steps in supported Windows UI. No paid codecs, drivers, or third-party
# audio software are installed. Audio latency is never claimed to improve.
Set-StrictMode -Version 2.0

if (-not (Get-Module | Where-Object { $_.Name -eq 'PlatinumOptimizer.Core' })) {
    Import-Module -Name (Join-Path $PSScriptRoot 'PlatinumOptimizer.Core.psm1') -Global -Force -ErrorAction Stop
}

function Get-POAudioPresetCatalog {
    [CmdletBinding()]
    param()
    return (Get-POJsonFile -Name 'audio-presets.json')
}

function Get-POAudioPresets {
    [CmdletBinding()]
    param()
    return @((Get-POAudioPresetCatalog).presets)
}

function Get-POAudioStateRoot {
    $root = Join-Path (Get-POStateRoot) 'audio'
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    return $root
}

function Get-POAudioStatePath {
    return (Join-Path (Get-POAudioStateRoot) 'audio-state.json')
}

function Get-POAudioModuleState {
    [CmdletBinding()]
    param()
    $path = Get-POAudioStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $null }
}

function Set-POAudioModuleState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$State)
    Write-POJsonAtomic -Path (Get-POAudioStatePath) -Object $State
}

function ConvertTo-POAudioConnectionType {
    [CmdletBinding()]
    param([AllowNull()][string]$DeviceId, [AllowNull()][string]$ServiceOrClass)
    # Pure inference from Windows-reported identifiers only. The result is
    # labeled as inferred; device models and capabilities are never faked.
    $text = ('{0} {1}' -f $DeviceId, $ServiceOrClass)
    if ($text -match '(?i)BTHENUM|BthA2dp|BthHfAud|Bluetooth') { return 'Bluetooth (inferred from PnP id)' }
    if ($text -match '(?i)USB\\VID|USBAUDIO|UsbAudio') { return 'USB (inferred from PnP id)' }
    if ($text -match '(?i)HDAUDIO\\.*VEN_10DE|HDAUDIO\\.*VEN_1002') { return 'Display audio over HDMI/DisplayPort (inferred: GPU high-definition audio)' }
    if ($text -match '(?i)HDAUDIO') { return 'Analog/onboard HDAudio (3.5 mm likely, inferred from PnP id)' }
    return 'Unknown (not reliably exposed)'
}

function Get-POAudioInventory {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) {
        return [pscustomobject][ordered]@{
            Available = $false; Message = 'Audio inventory is available only on Windows.'; SoundDevices = @(); Endpoints = @(); EndpointError = 'Not a Windows host.'
            ServiceState = 'Unknown'; DefaultPlayback = 'Unknown'; DefaultRecording = 'Unknown'
            SpatialAudioState = 'Unknown'; EnhancementsState = 'Unknown'; ExclusiveMode = 'Unknown'; SampleRate = 'Unknown'
        }
    }
    $devices = @()
    try {
        foreach ($device in @(Get-CimInstance -ClassName Win32_SoundDevice -ErrorAction Stop)) {
            $devices += [pscustomobject][ordered]@{
                Name = [string]$device.Name
                Manufacturer = [string]$device.Manufacturer
                Status = [string]$device.Status
                PnpDeviceId = [string]$device.PNPDeviceID
                ConnectionType = ConvertTo-POAudioConnectionType -DeviceId ([string]$device.PNPDeviceID) -ServiceOrClass $null
            }
        }
    }
    catch { $devices = @([pscustomobject][ordered]@{ Name = 'Inventory unavailable'; Manufacturer = 'Unknown'; Status = 'QUERY FAILED'; PnpDeviceId = ''; ConnectionType = "Win32_SoundDevice query failed: $($_.Exception.Message)" }) }
    $endpoints = @()
    $endpointError = $null
    try {
        if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
            foreach ($pnp in @(Get-PnpDevice -Class 'AudioEndpoint' -ErrorAction Stop)) {
                $endpoints += [pscustomobject][ordered]@{
                    FriendlyName = [string]$pnp.FriendlyName
                    Status = [string]$pnp.Status
                    InstanceId = [string]$pnp.InstanceId
                    ConnectionType = ConvertTo-POAudioConnectionType -DeviceId ([string]$pnp.InstanceId) -ServiceOrClass ([string]$pnp.Class)
                }
            }
        }
        else { $endpointError = 'Get-PnpDevice is unavailable; endpoint details were not guessed.' }
    }
    catch { $endpointError = "Audio endpoint query failed: $($_.Exception.Message)" }
    $serviceState = 'Unknown'
    try {
        $audioService = Get-CimInstance -ClassName Win32_Service -Filter "Name='Audiosrv'" -ErrorAction Stop
        if ($audioService) { $serviceState = "$([string]$audioService.State) (start mode $([string]$audioService.StartMode))" }
    }
    catch { $serviceState = "Unknown (service query failed: $($_.Exception.Message))" }
    $defaultPlayback = 'Not readable through a documented PowerShell interface. Use Sound settings (ms-settings:sound) or mmsys.cpl to confirm the default device.'
    $defaultRecording = $defaultPlayback
    return [pscustomobject][ordered]@{
        Available = ($devices.Count -gt 0)
        Message = if ($devices.Count -gt 0) { 'Inventory read from Windows WMI/PnP. Fields Windows does not expose remain Unknown.' } else { 'No audio controller was reported by Windows.' }
        SoundDevices = $devices
        Endpoints = $endpoints
        EndpointError = $endpointError
        ServiceState = $serviceState
        DefaultPlayback = $defaultPlayback
        DefaultRecording = $defaultRecording
        SpatialAudioState = 'Not reliably readable from generic WMI. Check Settings > System > Sound > device properties.'
        EnhancementsState = 'Endpoint enhancement state is not exposed through a documented PowerShell interface; see mmsys.cpl device properties.'
        ExclusiveMode = 'Per-endpoint exclusive-mode flags are not read or written by this app; manage them in mmsys.cpl > device > Advanced.'
        SampleRate = 'Reported only by the device UI (mmsys.cpl > device > Advanced); not guessed here.'
    }
}

function Get-POAudioDuckingState {
    [CmdletBinding()]
    param()
    $catalog = Get-POAudioPresetCatalog
    $definition = @($catalog.supportedChanges | Where-Object { $_.id -eq 'communications-ducking' } | Select-Object -First 1)
    if ($definition.Count -eq 0) { throw 'The audio preset catalog is missing the communications-ducking definition.' }
    return [pscustomobject][ordered]@{
        Definition = $definition[0]
        Current = Get-PORegValueState -Hive ([string]$definition[0].hive) -SubKey ([string]$definition[0].subKey) -ValueName ([string]$definition[0].valueName)
    }
}

function Invoke-POAudioPreset {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][string]$PresetId)
    if (-not (Test-POIsWindows)) { throw 'Audio presets are available only on Windows.' }
    $catalog = Get-POAudioPresetCatalog
    $preset = @($catalog.presets | Where-Object { $_.id -eq $PresetId } | Select-Object -First 1)
    if ($preset.Count -eq 0) { throw "Unknown audio preset '$PresetId'. Use one of: $(($catalog.presets | ForEach-Object { $_.id }) -join ', ')." }
    $preset = $preset[0]
    if ($PresetId -eq 'restore-original') { return (Restore-POAudioSettings -Confirm:$false) }
    $ducking = Get-POAudioDuckingState
    if (-not $ducking.Current.Readable) { throw "The current communications behavior value could not be read ($($ducking.Current.ReadError)); no audio change was made." }
    $targetValue = $null
    $changeProperties = $preset.PSObject.Properties['changes']
    if ($changeProperties -and $changeProperties.Value) {
        $duckingProperty = $changeProperties.Value.PSObject.Properties['communications-ducking']
        if ($duckingProperty) { $targetValue = [int]$duckingProperty.Value }
    }
    $targetDescription = 'no automatic change (manual guidance only)'
    if ($null -ne $targetValue) {
        $documented = $ducking.Definition.documentedValues.PSObject.Properties[[string]$targetValue]
        if ($null -eq $documented) { throw "Preset '$PresetId' requests undocumented ducking value $targetValue; nothing was changed." }
        $targetDescription = "communications behavior -> '$($documented.Value)' (value $targetValue)"
    }
    if (-not $PSCmdlet.ShouldProcess($preset.name, "Apply audio preset: $targetDescription")) {
        return [pscustomobject][ordered]@{ Status = 'SIMULATED'; PresetId = $PresetId; Message = "Dry run: would apply '$($preset.name)' ($targetDescription). No backup or setting was changed."; ManualSteps = @($preset.manualSteps); Backup = $null }
    }
    $moduleState = Get-POAudioModuleState
    if ($null -eq $moduleState -or -not $moduleState.OriginalDucking) {
        $moduleState = [pscustomobject][ordered]@{
            OriginalDucking = $ducking.Current
            FirstCapturedAtUtc = [DateTime]::UtcNow.ToString('o')
            LastPresetId = $null
            LastBackupId = $null
            AppliedAtUtc = $null
        }
    }
    $audioBefore = [pscustomobject][ordered]@{
        PresetRequested = $PresetId
        DuckingBefore = $ducking.Current
        ModuleState = $moduleState
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $backup = New-POBackup -AudioState $audioBefore
    $changeRecord = [pscustomobject][ordered]@{
        section = 'audio'; id = 'audio-preset'; name = "Audio preset: $($preset.name)"
        preset = $PresetId; targetValue = $targetValue; status = 'APPLYING'; timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    Add-POBackupChange -BackupPath $backup.Path -Section audio -Change $changeRecord
    try {
        if ($null -ne $targetValue) {
            $applyState = [pscustomobject][ordered]@{
                Hive = [string]$ducking.Definition.hive; SubKey = [string]$ducking.Definition.subKey; ValueName = [string]$ducking.Definition.valueName
                Exists = $true; Kind = 'DWord'; Data = [int]$targetValue; Readable = $true; ReadError = $null
            }
            Set-PORegValueState -State $applyState
            $verify = Get-PORegValueState -Hive ([string]$ducking.Definition.hive) -SubKey ([string]$ducking.Definition.subKey) -ValueName ([string]$ducking.Definition.valueName)
            if (-not $verify.Readable -or -not $verify.Exists -or [int]$verify.Data -ne $targetValue) { throw 'The communications behavior value could not be verified after writing it.' }
        }
        if ($moduleState.PSObject.Properties['LastPresetId']) { $moduleState.LastPresetId = $PresetId } else { $moduleState | Add-Member -MemberType NoteProperty -Name 'LastPresetId' -Value $PresetId }
        if ($moduleState.PSObject.Properties['LastBackupId']) { $moduleState.LastBackupId = [string]$backup.Id } else { $moduleState | Add-Member -MemberType NoteProperty -Name 'LastBackupId' -Value ([string]$backup.Id) }
        if ($moduleState.PSObject.Properties['AppliedAtUtc']) { $moduleState.AppliedAtUtc = [DateTime]::UtcNow.ToString('o') } else { $moduleState | Add-Member -MemberType NoteProperty -Name 'AppliedAtUtc' -Value ([DateTime]::UtcNow.ToString('o')) }
        Set-POAudioModuleState -State $moduleState
        Update-POBackupChangeStatus -BackupPath $backup.Path -Section audio -Status 'APPLIED_VERIFIED' -Message "Applied $($preset.name): $targetDescription."
        Write-POLog -Category 'Audio' -TweakId 'audio-preset' -Status 'APPLIED_VERIFIED' -Message "Applied audio preset $($preset.name) ($targetDescription)."
        return [pscustomobject][ordered]@{
            Status = 'APPLIED_VERIFIED'
            PresetId = $PresetId
            Message = "Preset '$($preset.name)' applied: $targetDescription. Guidance below is manual and optional."
            ManualSteps = @($preset.manualSteps)
            Why = [string]$preset.why
            Backup = $backup
        }
    }
    catch {
        $failure = $_.Exception.Message
        Write-POLog -Level 'ERROR' -Category 'Audio' -TweakId 'audio-preset' -Status 'FAILED' -Message $failure
        try { Update-POBackupChangeStatus -BackupPath $backup.Path -Section audio -Status 'FAILED' -Message $failure }
        catch { Write-POLog -Level 'CRITICAL' -Category 'Backup' -Status 'TRANSACTION_STATUS_WRITE_FAILED' -Message $_.Exception.Message }
        return [pscustomobject][ordered]@{ Status = 'FAILED'; PresetId = $PresetId; Message = "Audio preset was not applied: $failure"; ManualSteps = @(); Backup = $backup }
    }
}

function Restore-POAudioSettings {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    if (-not (Test-POIsWindows)) { throw 'Audio restore is available only on Windows.' }
    $moduleState = Get-POAudioModuleState
    if ($null -eq $moduleState -or -not $moduleState.OriginalDucking) {
        return [pscustomobject][ordered]@{ Status = 'NO_CHANGES'; Message = 'Platinum Optimizer has not changed any audio setting on this machine; nothing to restore.' }
    }
    $original = $moduleState.OriginalDucking
    if (-not $original.Readable) { throw 'The captured original audio state was unreadable; restore was blocked.' }
    if (-not $PSCmdlet.ShouldProcess('Audio settings', 'Restore the audio values captured before the first preset')) {
        return [pscustomobject][ordered]@{ Status = 'SIMULATED'; Message = 'Dry run: would restore the captured communications behavior. No change was made.' }
    }
    Set-PORegValueState -State $original
    $verify = Get-PORegValueState -Hive ([string]$original.Hive) -SubKey ([string]$original.SubKey) -ValueName ([string]$original.ValueName)
    if (-not $verify.Readable -or $verify.Exists -ne [bool]$original.Exists) { throw 'Audio restore verification failed after writing the original value.' }
    if ($verify.Exists -and [int]$verify.Data -ne [int]$original.Data) { throw 'Audio restore verification failed: the restored value does not match the captured original.' }
    if ($moduleState.PSObject.Properties['LastPresetId']) { $moduleState.LastPresetId = $null }
    Set-POAudioModuleState -State $moduleState
    Write-POLog -Category 'Audio' -TweakId 'audio-restore' -Status 'RESTORED_VERIFIED' -Message 'Restored the captured original communications behavior.'
    return [pscustomobject][ordered]@{ Status = 'RESTORED_VERIFIED'; Message = 'The captured original audio setting was written back and verified. Microphone and default devices were never touched.' }
}

function Restore-POAudioSection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupPath, [Parameter(Mandatory = $true)][psobject]$Manifest)
    $change = @($Manifest.changes | Where-Object { $_.section -eq 'audio' } | Select-Object -Last 1)
    if ($change.Count -eq 0 -or $change[0].id -ne 'audio-preset') { throw 'No supported audio change was recorded in this backup.' }
    $statePath = Join-Path $BackupPath 'audio\audio-before.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'The backup does not contain the audio state file.' }
    $audioBefore = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $original = $audioBefore.DuckingBefore
    if ($null -eq $original -or -not $original.Readable) { throw 'The captured original audio state in this backup was unreadable; restore was blocked.' }
    $current = Get-PORegValueState -Hive ([string]$original.Hive) -SubKey ([string]$original.SubKey) -ValueName ([string]$original.ValueName)
    if (-not $current.Readable) { throw 'The current audio state could not be read; restore was blocked.' }
    $alreadySame = ($current.Exists -eq [bool]$original.Exists) -and (-not $current.Exists -or (([string]$current.Kind -eq [string]$original.Kind) -and ([int]$current.Data -eq [int]$original.Data)))
    if ($alreadySame) { return }
    $targetProperty = $change[0].PSObject.Properties['targetValue']
    $expectedTarget = 0
    if ($null -eq $targetProperty -or -not [int]::TryParse([string]$targetProperty.Value, [ref]$expectedTarget)) {
        throw 'The backup does not record a verifiable audio target; current audio settings were left untouched.'
    }
    if (-not $current.Exists -or [string]$current.Kind -ne 'DWord' -or [int]$current.Data -ne $expectedTarget) {
        throw 'The audio communications value changed after Platinum Optimizer ran; refusing to overwrite the newer value.'
    }
    Set-PORegValueState -State $original
    $verify = Get-PORegValueState -Hive ([string]$original.Hive) -SubKey ([string]$original.SubKey) -ValueName ([string]$original.ValueName)
    if (-not $verify.Readable -or $verify.Exists -ne [bool]$original.Exists) { throw 'Audio restore verification failed after writing the original value.' }
    if ($verify.Exists -and [int]$verify.Data -ne [int]$original.Data) { throw 'Audio restore verification failed: the restored value does not match the captured original.' }
}

Export-ModuleMember -Function @(
    'Get-POAudioPresetCatalog', 'Get-POAudioPresets', 'Get-POAudioInventory', 'Get-POAudioModuleState',
    'ConvertTo-POAudioConnectionType', 'Get-POAudioDuckingState',
    'Invoke-POAudioPreset', 'Restore-POAudioSettings', 'Restore-POAudioSection'
)
