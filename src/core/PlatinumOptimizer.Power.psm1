#requires -Version 5.1
# Platinum Optimizer - Power Plan module
# Creates, validates, configures, activates and restores the dedicated
# "Platinum On Steroids" Windows power plan using only powercfg and
# Microsoft-documented power-setting GUIDs. Every write is verified by
# reading the plan back; unsupported settings are skipped, never forced.
Set-StrictMode -Version 2.0

if (-not (Get-Module | Where-Object { $_.Name -eq 'PlatinumOptimizer.Core' })) {
    Import-Module -Name (Join-Path $PSScriptRoot 'PlatinumOptimizer.Core.psm1') -Global -Force -ErrorAction Stop
}

$script:POPlatinumPlanName = $null
$script:POPowerCatalogCache = $null

function Get-POPowerSettingCatalog {
    [CmdletBinding()]
    param()
    if ($null -eq $script:POPowerCatalogCache) {
        $script:POPowerCatalogCache = Get-POJsonFile -Name 'power-settings.json'
    }
    return $script:POPowerCatalogCache
}

function Get-POPlatinumPlanName {
    if ($null -eq $script:POPlatinumPlanName) {
        $script:POPlatinumPlanName = [string]((Get-POPowerSettingCatalog).planName)
    }
    return $script:POPlatinumPlanName
}

function Get-POPowerStateRoot {
    $root = Join-Path (Get-POStateRoot) 'power'
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    return $root
}

function Get-POPlatinumStatePath {
    return (Join-Path (Get-POPowerStateRoot) 'platinum-plan.json')
}

function Get-POPlatinumState {
    [CmdletBinding()]
    param()
    $path = Get-POPlatinumStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $null }
}

function Set-POPlatinumState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$State)
    Write-POJsonAtomic -Path (Get-POPlatinumStatePath) -Object $State
}

function Invoke-POPowercfg {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $result = Invoke-POExternalCommand -FilePath 'powercfg.exe' -Arguments $Arguments -TimeoutSeconds 30
    $combined = @($result.Output) + @($result.ErrorOutput)
    return [pscustomobject][ordered]@{
        ExitCode = [int]$result.ExitCode
        TimedOut = [bool]$result.TimedOut
        DurationMilliseconds = [long]$result.DurationMilliseconds
        Output = @($combined | ForEach-Object { [string]$_ })
        ErrorOutput = @($result.ErrorOutput)
    }
}

function ConvertFrom-POPowerPlanListLines {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines)
    $plans = @()
    foreach ($line in $Lines) {
        $match = [regex]::Match([string]$line, '(?i)(?<guid>\{?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}?)\s*\((?<name>[^)]+)\)\s*(?<active>\*)?')
        if ($match.Success) {
            $plans += [pscustomobject][ordered]@{
                Guid = $match.Groups['guid'].Value.Trim('{}').ToLowerInvariant()
                Name = $match.Groups['name'].Value.Trim()
                IsActive = ($match.Groups['active'].Success)
            }
        }
    }
    return $plans
}

function ConvertFrom-POPowerQueryLines {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines)
    # Parses `powercfg /qh [SCHEME]` (quiet, hierarchical) output into
    # setting records. Only GUIDs and hex indices are read; localized text
    # is ignored so the parser works on every Windows display language.
    $settings = @()
    $currentSubgroup = $null
    $currentSetting = $null
    foreach ($line in $Lines) {
        $text = [string]$line
        $subgroupMatch = [regex]::Match($text, '(?i)Subgroup GUID:\s*\{?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\}?')
        if ($subgroupMatch.Success) { $currentSubgroup = $subgroupMatch.Groups[1].Value.ToLowerInvariant(); continue }
        $settingMatch = [regex]::Match($text, '(?i)Power Setting GUID:\s*\{?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\}?')
        if ($settingMatch.Success) {
            $currentSetting = [pscustomobject][ordered]@{
                SubgroupGuid = $currentSubgroup
                SettingGuid = $settingMatch.Groups[1].Value.ToLowerInvariant()
                AcIndex = $null
                DcIndex = $null
            }
            $settings += $currentSetting
            continue
        }
        if ($null -ne $currentSetting) {
            $acMatch = [regex]::Match($text, '(?i)Current AC Power Setting Index:\s*0x([0-9a-f]+)')
            if ($acMatch.Success) { $currentSetting.AcIndex = [Convert]::ToInt32($acMatch.Groups[1].Value, 16); continue }
            $dcMatch = [regex]::Match($text, '(?i)Current DC Power Setting Index:\s*0x([0-9a-f]+)')
            if ($dcMatch.Success) { $currentSetting.DcIndex = [Convert]::ToInt32($dcMatch.Groups[1].Value, 16) }
        }
    }
    return $settings
}

function ConvertFrom-POPowerSettingsSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PlanGuid,
          [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines)
    $parsedGuid = [guid]::Empty
    if (-not [guid]::TryParse($PlanGuid, [ref]$parsedGuid)) { throw 'Cannot snapshot a power plan with an invalid GUID.' }
    $catalog = Get-POPowerSettingCatalog
    $parsed = @(ConvertFrom-POPowerQueryLines -Lines $Lines)
    $records = @()
    foreach ($setting in @($catalog.settings)) {
        $subgroupGuid = [string]$catalog.subgroups.([string]$setting.subgroup).ToLowerInvariant()
        $acGuid = [string]$setting.guid
        $dcGuid = if ($setting.PSObject.Properties['dcGuid'] -and $setting.dcGuid) { [string]$setting.dcGuid } else { $acGuid }
        $acRecord = @($parsed | Where-Object { $_.SubgroupGuid -eq $subgroupGuid -and $_.SettingGuid -eq $acGuid.ToLowerInvariant() -and $null -ne $_.AcIndex } | Select-Object -First 1)
        $dcRecord = @($parsed | Where-Object { $_.SubgroupGuid -eq $subgroupGuid -and $_.SettingGuid -eq $dcGuid.ToLowerInvariant() -and $null -ne $_.DcIndex } | Select-Object -First 1)
        $records += [pscustomobject][ordered]@{
            Id = [string]$setting.id
            SubgroupGuid = $subgroupGuid
            AcGuid = $acGuid.ToLowerInvariant()
            DcGuid = $dcGuid.ToLowerInvariant()
            AcCaptured = ($acRecord.Count -gt 0)
            AcValue = if ($acRecord.Count -gt 0) { [int]$acRecord[0].AcIndex } else { $null }
            DcCaptured = ($dcRecord.Count -gt 0)
            DcValue = if ($dcRecord.Count -gt 0) { [int]$dcRecord[0].DcIndex } else { $null }
        }
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        PlanGuid = $parsedGuid.ToString().ToLowerInvariant()
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        ParsedSettingCount = $parsed.Count
        Settings = $records
    }
}

function Get-POPlatinumPowerSettingsSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PlanGuid)
    $parsedGuid = [guid]::Empty
    if (-not [guid]::TryParse($PlanGuid, [ref]$parsedGuid)) { throw 'Cannot query a power plan with an invalid GUID.' }
    $query = Invoke-POPowercfg -Arguments @('/qh', $parsedGuid.ToString())
    if ($query.TimedOut) { throw 'powercfg /qh timed out after 30 seconds; existing plan settings were not changed.' }
    if ($query.ExitCode -ne 0) { throw "powercfg /qh failed with exit code $($query.ExitCode): $(($query.Output -join ' ').Trim())" }
    return (ConvertFrom-POPowerSettingsSnapshot -PlanGuid $parsedGuid.ToString() -Lines $query.Output)
}

function Test-POPowerCatalogValue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Definition,
          [Parameter(Mandatory = $true)][int]$Value)
    switch ([string]$Definition.unit) {
        'percent' { return ($Value -ge [int]$Definition.min -and $Value -le [int]$Definition.max) }
        'seconds' { return ($Value -ge 0 -and $Value -le 86400) }
        'enum' {
            $allowed = @($Definition.values.PSObject.Properties | ForEach-Object { [int]$_.Name })
            return ($Value -in $allowed)
        }
        default { return $false }
    }
}

function Restore-POPlatinumPowerSettingsSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PlanGuid,
          [Parameter(Mandatory = $true)][psobject]$Snapshot,
          [AllowNull()][string[]]$SettingKeys = $null)
    $parsedGuid = [guid]::Empty
    if (-not [guid]::TryParse($PlanGuid, [ref]$parsedGuid)) { throw 'Cannot restore power settings with an invalid plan GUID.' }
    if ($null -eq $Snapshot.PSObject.Properties['SchemaVersion'] -or [int]$Snapshot.SchemaVersion -ne 1) { throw 'The power-settings backup schema is not supported.' }
    if ($null -eq $Snapshot.PSObject.Properties['PlanGuid']) { throw 'The power-settings backup has no plan GUID.' }
    $snapshotGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$Snapshot.PlanGuid, [ref]$snapshotGuid) -or $snapshotGuid.ToString() -ne $parsedGuid.ToString()) { throw 'The power-settings backup does not match the Platinum plan GUID.' }
    if ($null -eq $Snapshot.PSObject.Properties['Settings']) { throw 'The power-settings backup has no setting list.' }

    $catalog = Get-POPowerSettingCatalog
    $settingsById = @{}
    foreach ($definition in @($catalog.settings)) { $settingsById[[string]$definition.id] = $definition }
    $filterRequested = $PSBoundParameters.ContainsKey('SettingKeys')
    $settingKeySet = @{}
    if ($filterRequested) {
        foreach ($settingKey in @($SettingKeys)) {
            $keyMatch = [regex]::Match([string]$settingKey, '^(?<id>[a-z0-9-]+)\|(?<side>AC|DC)$', 'IgnoreCase')
            if (-not $keyMatch.Success -or -not $settingsById.ContainsKey($keyMatch.Groups['id'].Value)) { throw "The selected restore setting key '$settingKey' is invalid or unsupported." }
            $settingKeySet[($keyMatch.Groups['id'].Value + '|' + $keyMatch.Groups['side'].Value.ToUpperInvariant())] = $true
        }
    }
    $prepared = @()
    $seenIds = @{}
    foreach ($record in @($Snapshot.Settings)) {
        if ($null -eq $record) { throw 'The power-settings backup contains a null record.' }
        foreach ($field in @('Id', 'AcCaptured', 'AcValue', 'DcCaptured', 'DcValue')) {
            if ($null -eq $record.PSObject.Properties[$field]) { throw "A power-settings backup record is missing '$field'." }
        }
        $id = [string]$record.Id
        if (-not $settingsById.ContainsKey($id)) { throw "Snapshot references unrecognized power setting '$id'." }
        if ($seenIds.ContainsKey($id)) { throw "Snapshot contains a duplicate power setting '$id'." }
        $seenIds[$id] = $true
        $definition = $settingsById[$id]
        $acValue = $null
        $dcValue = $null
        if ([bool]$record.AcCaptured) {
            $parsedValue = 0
            if (-not [int]::TryParse([string]$record.AcValue, [ref]$parsedValue) -or -not (Test-POPowerCatalogValue -Definition $definition -Value $parsedValue)) { throw "$($definition.name): captured AC index is invalid or outside the documented range." }
            $acValue = $parsedValue
        }
        if ([bool]$record.DcCaptured) {
            $parsedValue = 0
            if (-not [int]::TryParse([string]$record.DcValue, [ref]$parsedValue) -or -not (Test-POPowerCatalogValue -Definition $definition -Value $parsedValue)) { throw "$($definition.name): captured DC index is invalid or outside the documented range." }
            $dcValue = $parsedValue
        }
        $prepared += [pscustomobject][ordered]@{ Id = $id; Definition = $definition; AcCaptured = [bool]$record.AcCaptured; AcValue = $acValue; DcCaptured = [bool]$record.DcCaptured; DcValue = $dcValue }
    }
    if ($filterRequested) {
        foreach ($selectedKey in @($settingKeySet.Keys)) {
            $parts = [string]$selectedKey -split '\|', 2
            $selectedRecord = @($prepared | Where-Object { $_.Id -eq $parts[0] } | Select-Object -First 1)
            if ($selectedRecord.Count -eq 0) { throw "The selected restore setting '$selectedKey' is not present in the backup." }
            $selectedCaptured = if ($parts[1] -eq 'AC') { [bool]$selectedRecord[0].AcCaptured } else { [bool]$selectedRecord[0].DcCaptured }
            if (-not $selectedCaptured) { throw "The selected restore setting '$selectedKey' has no captured baseline value." }
        }
    }

    $applied = @(); $failed = @(); $skipped = @()
    foreach ($record in $prepared) {
        $definition = $record.Definition
        $subgroupGuid = [string]$catalog.subgroups.([string]$definition.subgroup)
        $acGuid = [string]$definition.guid
        $dcGuid = if ($definition.PSObject.Properties['dcGuid'] -and $definition.dcGuid) { [string]$definition.dcGuid } else { $acGuid }
        $restoreAc = (-not $filterRequested -or $settingKeySet.ContainsKey(([string]$record.Id + '|AC')))
        $restoreDc = (-not $filterRequested -or $settingKeySet.ContainsKey(([string]$record.Id + '|DC')))
        if ($restoreAc -and $record.AcCaptured) {
            $setAc = Invoke-POPowercfg -Arguments @('/setacvalueindex', $parsedGuid.ToString(), $subgroupGuid, $acGuid, [string]$record.AcValue)
            if ($setAc.ExitCode -eq 0 -and -not $setAc.TimedOut) { $applied += [pscustomobject]@{ Id = $record.Id; Side = 'AC'; Value = $record.AcValue } }
            else { $failed += "$($definition.name): restoring AC value failed (exit code $($setAc.ExitCode), timeout=$($setAc.TimedOut))." }
        }
        elseif ($restoreAc) { $skipped += "$($definition.name): AC value was not exposed in the verified backup." }
        if ($restoreDc -and $record.DcCaptured) {
            $setDc = Invoke-POPowercfg -Arguments @('/setdcvalueindex', $parsedGuid.ToString(), $subgroupGuid, $dcGuid, [string]$record.DcValue)
            if ($setDc.ExitCode -eq 0 -and -not $setDc.TimedOut) { $applied += [pscustomobject]@{ Id = $record.Id; Side = 'DC'; Value = $record.DcValue } }
            else { $failed += "$($definition.name): restoring DC value failed (exit code $($setDc.ExitCode), timeout=$($setDc.TimedOut))." }
        }
        elseif ($restoreDc) { $skipped += "$($definition.name): DC value was not exposed in the verified backup." }
    }
    if ($failed.Count -eq 0 -and $applied.Count -gt 0) {
        try {
            $actual = Get-POPlatinumPowerSettingsSnapshot -PlanGuid $parsedGuid.ToString()
            foreach ($record in $prepared) {
                $restoreAc = (-not $filterRequested -or $settingKeySet.ContainsKey(([string]$record.Id + '|AC')))
                $restoreDc = (-not $filterRequested -or $settingKeySet.ContainsKey(([string]$record.Id + '|DC')))
                if (-not $restoreAc -and -not $restoreDc) { continue }
                $actualRecord = @($actual.Settings | Where-Object { $_.Id -eq $record.Id } | Select-Object -First 1)
                if ($actualRecord.Count -eq 0) { $failed += "$($record.Id): setting was missing during restore verification."; continue }
                if ($restoreAc -and $record.AcCaptured -and (-not [bool]$actualRecord[0].AcCaptured -or [int]$actualRecord[0].AcValue -ne [int]$record.AcValue)) { $failed += "$($record.Id): restored AC value could not be verified." }
                if ($restoreDc -and $record.DcCaptured -and (-not [bool]$actualRecord[0].DcCaptured -or [int]$actualRecord[0].DcValue -ne [int]$record.DcValue)) { $failed += "$($record.Id): restored DC value could not be verified." }
            }
        }
        catch { $failed += "Power-setting restore verification failed: $($_.Exception.Message)" }
    }
    return [pscustomobject][ordered]@{ Applied = $applied; Failed = $failed; Skipped = $skipped; Verified = ($failed.Count -eq 0) }
}

function Get-POPlatinumPresetCatalog {
    [CmdletBinding()]
    param()
    return @((Get-POPowerSettingCatalog).presets)
}

function Get-POPresetSettingValue {
    [CmdletBinding()]
    param([AllowNull()][psobject]$Side, [Parameter(Mandatory = $true)][string]$SettingId)
    if ($null -eq $Side) { return $null }
    $property = $Side.PSObject.Properties[$SettingId]
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    return [int]$property.Value
}

function Test-POPowerPresetDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Preset, [Parameter(Mandatory = $true)][psobject]$Catalog)
    # Pure validator: every preset value must reference a documented setting
    # from the catalog and stay inside its documented range.
    $issues = @()
    $settingsById = @{}
    foreach ($setting in @($Catalog.settings)) { $settingsById[[string]$setting.id] = $setting }
    foreach ($sideName in @('ac', 'dc')) {
        $side = $Preset.PSObject.Properties[$sideName]
        if ($null -eq $side -or $null -eq $side.Value) { continue }
        foreach ($property in $side.Value.PSObject.Properties) {
            $settingId = [string]$property.Name
            if (-not $settingsById.ContainsKey($settingId)) { $issues += "$($Preset.id).$sideName.$settingId is not a documented setting"; continue }
            $definition = $settingsById[$settingId]
            $value = [int]$property.Value
            if ([string]$definition.unit -eq 'percent' -or $null -ne $definition.PSObject.Properties['min']) {
                $min = [int]$definition.min
                $max = [int]$definition.max
                if ($value -lt $min -or $value -gt $max) { $issues += "$($Preset.id).$sideName.$settingId value $value is outside $min..$max" }
            }
            elseif ([string]$definition.unit -eq 'seconds') {
                if ($value -lt 0 -or $value -gt 86400) { $issues += "$($Preset.id).$sideName.$settingId timeout $value is outside 0..86400 seconds" }
            }
            elseif ([string]$definition.unit -eq 'enum') {
                $allowed = @($definition.values.PSObject.Properties | ForEach-Object { [int]$_.Name })
                if ($value -notin $allowed) { $issues += "$($Preset.id).$sideName.$settingId value $value is not a documented enum value" }
            }
            if ($settingId -eq 'sleep-after' -and $value -eq 0) { $issues += "$($Preset.id).$sideName.sleep-after must not silently disable sleep" }
        }
    }
    return [pscustomobject][ordered]@{ Valid = ($issues.Count -eq 0); Issues = $issues }
}

function Find-POPlatinumPlanEntry {
    [CmdletBinding()]
    param()
    $name = Get-POPlatinumPlanName
    $plans = @(Get-POPowerPlans)
    $matches = @($plans | Where-Object { [string]$_.Name -eq $name })
    if ($matches.Count -gt 1) { throw "Multiple power schemes are named '$name'; no scheme was selected or changed. Resolve the duplicate names in Windows Power Options and retry." }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-POPlatinumPlanInfo {
    [CmdletBinding()]
    param()
    $catalog = Get-POPowerSettingCatalog
    $name = Get-POPlatinumPlanName
    $state = Get-POPlatinumState
    $entry = $null
    $queryError = $null
    if (Test-POIsWindows) { $entry = Find-POPlatinumPlanEntry }
    $planGuid = $null
    $isActive = $false
    if ($entry) { $planGuid = [string]$entry.Guid; $isActive = [bool]$entry.IsActive }
    elseif ($state -and $state.PSObject.Properties['PlanGuid'] -and $state.PlanGuid) { $planGuid = [string]$state.PlanGuid }
    $settingsReport = @()
    if ($planGuid -and (Test-POIsWindows)) {
        $query = Invoke-POPowercfg -Arguments @('/qh', $planGuid)
        if ($query.ExitCode -ne 0) { $queryError = "powercfg /qh returned exit code $($query.ExitCode); settings could not be verified." }
        else {
            $parsed = @(ConvertFrom-POPowerQueryLines -Lines $query.Output)
            foreach ($setting in @($catalog.settings)) {
                $subgroupGuid = [string]$catalog.subgroups.([string]$setting.subgroup)
                $guidCandidates = @([string]$setting.guid)
                if ($setting.PSObject.Properties['dcGuid'] -and $setting.dcGuid) { $guidCandidates += [string]$setting.dcGuid }
                $acValue = $null; $dcValue = $null; $supported = $false
                foreach ($candidate in $guidCandidates) {
                    foreach ($record in @($parsed | Where-Object { $_.SubgroupGuid -eq $subgroupGuid -and $_.SettingGuid -eq $candidate.ToLowerInvariant() })) {
                        $supported = $true
                        if ($null -ne $record.AcIndex) { $acValue = [int]$record.AcIndex }
                        if ($null -ne $record.DcIndex) { $dcValue = [int]$record.DcIndex }
                    }
                }
                $settingsReport += [pscustomobject][ordered]@{
                    Id = [string]$setting.id
                    Name = [string]$setting.name
                    Unit = [string]$setting.unit
                    Supported = $supported
                    AcValue = $acValue
                    DcValue = $dcValue
                }
            }
        }
    }
    return [pscustomobject][ordered]@{
        PlanName = $name
        Exists = [bool]$entry
        PlanGuid = $planGuid
        IsActive = $isActive
        ActivePlanGuid = if (Test-POIsWindows) { Get-POActivePowerPlanGuid } else { $null }
        AppliedPresetId = if ($state -and $state.PSObject.Properties['AppliedPresetId']) { [string]$state.AppliedPresetId } else { $null }
        CreatedAtUtc = if ($state -and $state.PSObject.Properties['CreatedAtUtc']) { [string]$state.CreatedAtUtc } else { $null }
        OriginalActivePlanGuid = if ($state -and $state.PSObject.Properties['OriginalActivePlanGuid']) { [string]$state.OriginalActivePlanGuid } else { $null }
        SettingsReport = $settingsReport
        QueryError = $queryError
        State = $state
    }
}

function New-POPlatinumPlan {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([AllowNull()][string]$BasePlanGuid)
    if (-not (Test-POIsWindows)) { throw 'The Platinum power plan is available only on Windows.' }
    if (-not (Get-Command powercfg.exe -ErrorAction SilentlyContinue)) { throw 'powercfg.exe is not available on this system.' }
    $catalog = Get-POPowerSettingCatalog
    $name = Get-POPlatinumPlanName
    $existing = Find-POPlatinumPlanEntry
    if ($existing) {
        $query = Invoke-POPowercfg -Arguments @('/qh', [string]$existing.Guid)
        if ($query.ExitCode -eq 0) {
            return [pscustomobject][ordered]@{ Status = 'EXISTS_VALIDATED'; PlanGuid = [string]$existing.Guid; Created = $false; Message = "The '$name' plan already exists and its settings could be queried. No duplicate was created." }
        }
        return [pscustomobject][ordered]@{ Status = 'EXISTS_INVALID'; PlanGuid = [string]$existing.Guid; Created = $false; Message = "The '$name' plan exists but powercfg could not query it (exit code $($query.ExitCode)). Review it manually; no duplicate was created." }
    }
    if (-not $PSCmdlet.ShouldProcess($name, 'Create the Platinum On Steroids power plan from the active Windows scheme')) {
        return [pscustomobject][ordered]@{ Status = 'SIMULATED'; PlanGuid = $null; Created = $false; Message = "Dry run: would duplicate the current active scheme (Balanced fallback), rename it to '$name', and verify it. No plan was created." }
    }
    if (-not (Test-POIsAdministrator)) { throw 'Creating a power plan requires an elevated Administrator session.' }
    $plansBefore = @(Get-POPowerPlans | ForEach-Object { [string]$_.Guid.ToLowerInvariant() })
    if ([string]::IsNullOrWhiteSpace($BasePlanGuid)) { $BasePlanGuid = Get-POActivePowerPlanGuid }
    if ([string]::IsNullOrWhiteSpace($BasePlanGuid)) { $BasePlanGuid = [string]$catalog.builtinSchemes.([string]$catalog.duplicateBaseScheme) }
    $parsedBaseGuid = [guid]::Empty
    if (-not [guid]::TryParse($BasePlanGuid, [ref]$parsedBaseGuid)) { throw 'The selected source power plan GUID is invalid.' }
    $baseGuid = $parsedBaseGuid.ToString().ToLowerInvariant()
    if ($baseGuid -notin $plansBefore) { throw "The source power plan $baseGuid is not installed; no custom plan was created." }
    $duplicate = Invoke-POPowercfg -Arguments @('/duplicatescheme', $baseGuid)
    if ($duplicate.ExitCode -ne 0) {
        throw "powercfg /duplicatescheme failed with exit code $($duplicate.ExitCode): $(($duplicate.Output -join ' ').Trim())"
    }
    $guidMatch = [regex]::Match(($duplicate.Output -join "`n"), '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
    if (-not $guidMatch.Success) { throw 'powercfg /duplicatescheme succeeded but did not report the new plan GUID; the plan was not adopted.' }
    $newGuid = $guidMatch.Groups[1].Value.ToLowerInvariant()
    $verifyList = @(ConvertFrom-POPowerPlanListLines -Lines (Invoke-POPowercfg -Arguments @('/list')).Output)
    if (@($verifyList | Where-Object { $_.Guid -eq $newGuid }).Count -eq 0) { throw "The duplicated plan GUID $newGuid was not found in the power scheme list; the plan was not adopted." }
    # powercfg's documented plan-rename verb is /changename (not /setname).
    # Rename the duplicate before adopting it; on failure, remove only this
    # newly-created duplicate and keep every pre-existing plan untouched.
    $renameResult = Invoke-POPowercfg -Arguments @('/changename', $newGuid, $name, [string]$catalog.planDescription)
    if ($renameResult.ExitCode -ne 0) {
        [void](Invoke-POPowercfg -Arguments @('/delete', $newGuid))
        $renameDetails = (@($renameResult.Output) -join ' ').Trim()
        $renameDetailText = if ($renameDetails) { ": $renameDetails" } else { '' }
        throw "powercfg /changename failed with exit code $($renameResult.ExitCode)$renameDetailText; the unnamed duplicate was removed."
    }
    $verifyNamed = @(ConvertFrom-POPowerPlanListLines -Lines (Invoke-POPowercfg -Arguments @('/list')).Output)
    if (@($verifyNamed | Where-Object { $_.Guid -eq $newGuid -and $_.Name -eq $name }).Count -eq 0) {
        [void](Invoke-POPowercfg -Arguments @('/delete', $newGuid))
        throw "The duplicated plan could not be renamed to '$name'; the unnamed duplicate was removed."
    }
    $plansAfter = @(Get-POPowerPlans | ForEach-Object { [string]$_.Guid })
    $lostPlans = @($plansBefore | Where-Object { $_ -notin $plansAfter })
    if ($lostPlans.Count -gt 0) {
        Write-POLog -Level 'WARNING' -Category 'Power' -Status 'PLAN_LIST_CHANGED' -Message "Plans present before creation are missing afterwards: $($lostPlans -join ', '). Investigate; Platinum Optimizer never deletes existing plans."
    }
    $exportPath = Join-Path (Get-POPowerStateRoot) 'platinum-plan.pow'
    $export = Invoke-POPowercfg -Arguments @('/export', $exportPath, $newGuid)
    if ($export.ExitCode -ne 0) { $exportPath = $null }
    $state = [pscustomobject][ordered]@{
        PlanName = $name
        PlanGuid = $newGuid
        BaseSchemeGuid = $baseGuid
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        OriginalActivePlanGuid = $null
        AppliedPresetId = $null
        AppliedAtUtc = $null
        PlanExportPath = $exportPath
        RestoredAtUtc = $null
        Notes = 'Created from the current active Windows scheme (Balanced fallback) with powercfg /duplicatescheme. Existing user plans were preserved.'
    }
    Set-POPlatinumState -State $state
    Write-POLog -Category 'Power' -TweakId 'platinum-power-plan' -Status 'CREATED' -Message "Created power plan '$name' ($newGuid) from base scheme $baseGuid."
    return [pscustomobject][ordered]@{ Status = 'CREATED'; PlanGuid = $newGuid; Created = $true; Message = "Created '$name' ($newGuid) from the selected active Windows scheme. Existing plans were preserved." }
}

function Invoke-POPlatinumPresetValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PlanGuid,
        [Parameter(Mandatory = $true)][psobject]$Preset
    )
    $catalog = Get-POPowerSettingCatalog
    $baseline = Get-POPlatinumPowerSettingsSnapshot -PlanGuid $PlanGuid
    $changes = @()
    $abortVerification = $false
    foreach ($setting in @($catalog.settings)) {
        $settingId = [string]$setting.id
        $acValue = Get-POPresetSettingValue -Side $Preset.ac -SettingId $settingId
        $dcValue = Get-POPresetSettingValue -Side $Preset.dc -SettingId $settingId
        if ($null -eq $acValue -and $null -eq $dcValue) { continue }
        $baselineEntry = @($baseline.Settings | Where-Object { $_.Id -eq $settingId } | Select-Object -First 1)
        if ($baselineEntry.Count -eq 0) {
            $changes += [pscustomobject][ordered]@{ Id = $settingId; Name = [string]$setting.name; Status = 'UNVERIFIED'; Attempted = $false; Verified = $false; PreviousValue = $null; TargetValue = $null; Reason = 'The pre-change setting snapshot did not contain this catalog setting.'; RequiresReboot = $false }
            continue
        }
        $baselineEntry = $baselineEntry[0]
        $sides = @(
            [pscustomobject]@{ Name = 'AC'; Target = $acValue; Captured = [bool]$baselineEntry.AcCaptured; Current = $baselineEntry.AcValue; Command = '/setacvalueindex'; Guid = [string]$setting.guid; ValueProperty = 'AcValue'; CapturedProperty = 'AcCaptured' },
            [pscustomobject]@{ Name = 'DC'; Target = $dcValue; Captured = [bool]$baselineEntry.DcCaptured; Current = $baselineEntry.DcValue; Command = '/setdcvalueindex'; Guid = [string]$baselineEntry.DcGuid; ValueProperty = 'DcValue'; CapturedProperty = 'DcCaptured' }
        )
        foreach ($side in $sides) {
            if ($null -eq $side.Target) { continue }
            if (-not $side.Captured) {
                $changes += [pscustomobject][ordered]@{ Id = "$settingId-$($side.Name.ToLowerInvariant())"; Name = "$($setting.name) ($($side.Name))"; Status = 'SKIPPED'; Attempted = $false; Verified = $false; PreviousValue = $null; TargetValue = [int]$side.Target; Reason = 'Windows did not expose this setting for the selected power scheme; it was not written.'; RequiresReboot = $false }
                continue
            }
            if ([int]$side.Current -eq [int]$side.Target) {
                $changes += [pscustomobject][ordered]@{ Id = "$settingId-$($side.Name.ToLowerInvariant())"; Name = "$($setting.name) ($($side.Name))"; Status = 'ALREADY_OPTIMIZED'; Attempted = $false; Verified = $true; PreviousValue = [int]$side.Current; TargetValue = [int]$side.Target; Reason = 'Windows already reports the requested value.'; RequiresReboot = $false }
                continue
            }
            $subgroupGuid = [string]$catalog.subgroups.([string]$setting.subgroup)
            try { $set = Invoke-POPowercfg -Arguments @([string]$side.Command, $PlanGuid, $subgroupGuid, [string]$side.Guid, [string][int]$side.Target) }
            catch {
                $changes += [pscustomobject][ordered]@{ Id = "$settingId-$($side.Name.ToLowerInvariant())"; Name = "$($setting.name) ($($side.Name))"; Status = 'UNVERIFIED'; Attempted = $true; Verified = $false; PreviousValue = [int]$side.Current; TargetValue = [int]$side.Target; Reason = "The powercfg command could not be confirmed: $($_.Exception.Message)"; RequiresReboot = $false }
                $abortVerification = $true
                break
            }
            if ($set.TimedOut -or $set.ExitCode -ne 0) {
                $changes += [pscustomobject][ordered]@{ Id = "$settingId-$($side.Name.ToLowerInvariant())"; Name = "$($setting.name) ($($side.Name))"; Status = 'FAILED'; Attempted = $true; Verified = $false; PreviousValue = [int]$side.Current; TargetValue = [int]$side.Target; Reason = "powercfg rejected or timed out applying this setting (exit code $($set.ExitCode), timeout=$($set.TimedOut)): $(($set.Output -join ' ').Trim())"; RequiresReboot = $false }
                continue
            }
            try {
                $after = Get-POPlatinumPowerSettingsSnapshot -PlanGuid $PlanGuid
                $afterEntry = @($after.Settings | Where-Object { $_.Id -eq $settingId } | Select-Object -First 1)
                $verified = $false
                $actualValue = $null
                if ($afterEntry.Count -gt 0) {
                    $actualProperty = $afterEntry[0].PSObject.Properties[[string]$side.ValueProperty]
                    $capturedProperty = $afterEntry[0].PSObject.Properties[[string]$side.CapturedProperty]
                    if ($actualProperty -and $capturedProperty -and [bool]$capturedProperty.Value) {
                        $actualValue = [int]$actualProperty.Value
                        $verified = ($actualValue -eq [int]$side.Target)
                    }
                }
                if ($verified) {
                    $changes += [pscustomobject][ordered]@{ Id = "$settingId-$($side.Name.ToLowerInvariant())"; Name = "$($setting.name) ($($side.Name))"; Status = 'APPLIED_VERIFIED'; Attempted = $true; Verified = $true; PreviousValue = [int]$side.Current; TargetValue = [int]$side.Target; Reason = 'Written and read back from powercfg.'; RequiresReboot = $false }
                }
                else {
                    $changes += [pscustomobject][ordered]@{ Id = "$settingId-$($side.Name.ToLowerInvariant())"; Name = "$($setting.name) ($($side.Name))"; Status = 'UNVERIFIED'; Attempted = $true; Verified = $false; PreviousValue = [int]$side.Current; TargetValue = [int]$side.Target; Reason = "The powercfg write returned success, but read-back reported '$actualValue'."; RequiresReboot = $false }
                    $abortVerification = $true
                    break
                }
            }
            catch {
                $changes += [pscustomobject][ordered]@{ Id = "$settingId-$($side.Name.ToLowerInvariant())"; Name = "$($setting.name) ($($side.Name))"; Status = 'UNVERIFIED'; Attempted = $true; Verified = $false; PreviousValue = [int]$side.Current; TargetValue = [int]$side.Target; Reason = "Post-write verification failed: $($_.Exception.Message)"; RequiresReboot = $false }
                $abortVerification = $true
                break
            }
        }
        if ($abortVerification) { break }
    }
    $applied = @($changes | Where-Object { $_.Status -eq 'APPLIED_VERIFIED' })
    $already = @($changes | Where-Object { $_.Status -eq 'ALREADY_OPTIMIZED' })
    $skipped = @($changes | Where-Object { $_.Status -eq 'SKIPPED' })
    $failed = @($changes | Where-Object { $_.Status -eq 'FAILED' })
    $unverified = @($changes | Where-Object { $_.Status -eq 'UNVERIFIED' })
    return [pscustomobject][ordered]@{
        Changes = $changes
        Applied = $applied
        AlreadyOptimized = $already
        Skipped = $skipped
        Failed = $failed
        Unverified = $unverified
        AttemptedCount = @($changes | Where-Object { $_.Attempted }).Count
    }
}

function ConvertTo-POPowerSettingWriteLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Changes)
    $writes = @()
    foreach ($change in @($Changes)) {
        if ($null -eq $change) { continue }
        $attemptedProperty = $change.PSObject.Properties['Attempted']
        if ($null -eq $attemptedProperty -or -not [bool]$attemptedProperty.Value) { continue }
        foreach ($field in @('Id', 'PreviousValue', 'TargetValue', 'Status', 'Verified')) {
            if ($null -eq $change.PSObject.Properties[$field]) { throw "An attempted power-setting result is missing '$field'; the write cannot be safely recorded." }
        }
        $writes += [pscustomobject][ordered]@{
            Id = [string]$change.Id
            Attempted = $true
            Status = [string]$change.Status
            Verified = [bool]$change.Verified
            PreviousValue = $change.PreviousValue
            TargetValue = $change.TargetValue
        }
    }
    return $writes
}

function Invoke-POPlatinumPlanWorkflow {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$PresetId,
        [switch]$Activate,
        [AllowNull()][scriptblock]$OnBackupCreated = $null,
        [AllowNull()][scriptblock]$OnVerifiedBackup = $null
    )
    if (-not (Test-POIsWindows)) { throw 'The Platinum power plan workflow is available only on Windows.' }
    if (-not (Get-Command powercfg.exe -ErrorAction SilentlyContinue)) { throw 'powercfg.exe is not available on this system.' }
    $catalog = Get-POPowerSettingCatalog
    $preset = @($catalog.presets | Where-Object { $_.id -eq $PresetId } | Select-Object -First 1)
    if ($preset.Count -eq 0) { throw "Unknown Platinum power preset '$PresetId'. Use one of: $(($catalog.presets | ForEach-Object { $_.id }) -join ', ')." }
    $preset = $preset[0]
    $validation = Test-POPowerPresetDefinition -Preset $preset -Catalog $catalog
    if (-not $validation.Valid) { throw ('The preset definition failed validation: ' + ($validation.Issues -join '; ')) }
    $activeBefore = Get-POActivePowerPlanGuid
    if ([string]::IsNullOrWhiteSpace($activeBefore)) { throw 'The currently active power plan could not be read; a verified restore target is unavailable, so no change is made.' }
    $existing = Find-POPlatinumPlanEntry
    $existingBefore = [bool]$existing
    $planAction = if ($existing) { "reuse and update the existing '$(Get-POPlatinumPlanName)' plan" } else { "create the '$(Get-POPlatinumPlanName)' plan from the currently active Windows scheme" }
    $activationText = if ($Activate) { ' Then activate and verify it.' } else { ' Leave the active plan unchanged.' }
    if (-not $PSCmdlet.ShouldProcess((Get-POPlatinumPlanName), "Apply the $($preset.name) preset: $planAction.$activationText")) {
        return [pscustomobject][ordered]@{
            Status = 'SIMULATED'; Message = "Dry run: would $planAction with the $($preset.name) preset.$activationText No plan, setting, or backup was changed."
            PlanGuid = if ($existing) { [string]$existing.Guid } else { $null }; Backup = $null; Changes = @(); PlanCreated = $false; Activated = $false
        }
    }
    if (-not (Test-POIsAdministrator)) { throw 'Creating and configuring a power plan requires an elevated Administrator session.' }

    # Capture the existing Platinum plan values before creating any backup or
    # changing the scheme. The backup itself is written and checksum-verified
    # before New-POPlatinumPlan or any set/activate command can run.
    $settingsBefore = $null
    if ($existingBefore) { $settingsBefore = Get-POPlatinumPowerSettingsSnapshot -PlanGuid ([string]$existing.Guid) }
    $backupState = [pscustomobject][ordered]@{
        SchemaVersion = 1
        OriginalActivePlanGuid = [string]$activeBefore
        PlatinumPlanGuid = if ($existingBefore) { [string]$existing.Guid } else { $null }
        PlatinumPlanExistedBefore = $existingBefore
        PresetId = $PresetId
        PlanName = Get-POPlatinumPlanName
        PowerSettingsSnapshotFile = if ($existingBefore) { 'power\platinum-settings-before.json' } else { $null }
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $backup = New-POBackup -PlatinumState $backupState `
        -PlatinumPlanGuid $(if ($existingBefore) { [string]$existing.Guid } else { $null }) `
        -PowerSettingsSnapshot $settingsBefore
    $backupValidation = Test-POBackup -Path $backup.Path
    if (-not $backupValidation.Valid) { throw ('Configuration backup failed checksum/path verification: ' + (@($backupValidation.Issues) -join '; ')) }
    if ($null -ne $OnBackupCreated) {
        try { & $OnBackupCreated $backup }
        catch { throw "The verified backup was created at $($backup.Path), but its reporting callback failed before system changes. $($_.Exception.Message)" }
    }
    $activeExportPath = Join-Path $backup.Path 'power\active-plan.pow'
    if (-not (Test-Path -LiteralPath $activeExportPath -PathType Leaf) -or (Get-Item -LiteralPath $activeExportPath -Force).Length -le 0) {
        throw 'The active power scheme could not be exported and verified. System changes were blocked.'
    }
    if ($existingBefore) {
        $platinumExportPath = Join-Path $backup.Path 'power\platinum-plan-before.pow'
        if (-not (Test-Path -LiteralPath $platinumExportPath -PathType Leaf) -or (Get-Item -LiteralPath $platinumExportPath -Force).Length -le 0) {
            throw 'The existing Platinum plan could not be exported and verified. Its settings were not changed.'
        }
        $snapshotPath = Join-Path $backup.Path 'power\platinum-settings-before.json'
        if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { throw 'The existing Platinum settings snapshot is missing; its settings were not changed.' }
    }

    if ($null -ne $OnVerifiedBackup) {
        try { & $OnVerifiedBackup $backup }
        catch { throw "A pre-change backup callback failed; the verified configuration backup remains at $($backup.Path), and the Platinum plan was not changed. $($_.Exception.Message)" }
    }

    $createResult = New-POPlatinumPlan -BasePlanGuid $activeBefore -Confirm:$false
    if ($createResult.Status -eq 'EXISTS_INVALID') { throw $createResult.Message }
    if ($createResult.Status -notin @('CREATED', 'EXISTS_VALIDATED')) { throw "The custom power plan was not created or validated: $($createResult.Message)" }
    $planGuid = [string]$createResult.PlanGuid
    $createdByThisRun = [bool]$createResult.Created

    $changeRecord = [pscustomobject][ordered]@{
        section = 'power'
        id = 'platinum-power-plan'
        name = "Platinum On Steroids power plan ($($preset.name))"
        fromGuid = [string]$activeBefore
        toGuid = $planGuid
        platinumPlanGuid = $planGuid
        preset = $PresetId
        activate = [bool]$Activate
        createdByThisRun = $createdByThisRun
        platinumPlanExistedBefore = $existingBefore
        expectedSettings = [pscustomobject][ordered]@{ ac = $preset.ac; dc = $preset.dc }
        status = 'APPLYING'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    try { Add-POBackupChange -BackupPath $backup.Path -Section power -Change $changeRecord }
    catch {
        if ($createdByThisRun -and (Get-POActivePowerPlanGuid) -eq $activeBefore) {
            $createdEntry = @(Get-POPowerPlans | Where-Object { $_.Guid -eq $planGuid -and $_.Name -eq (Get-POPlatinumPlanName) } | Select-Object -First 1)
            if ($createdEntry.Count -gt 0) { [void](Invoke-POPowercfg -Arguments @('/delete', $planGuid)) }
        }
        throw "The verified backup could not record the power transaction; no power setting was changed. $($_.Exception.Message)"
    }

    $values = $null
    $state = Get-POPlatinumState
    if ($null -eq $state -or -not $state.PlanGuid -or [string]$state.PlanGuid -ne $planGuid) {
        $state = [pscustomobject][ordered]@{
            PlanName = Get-POPlatinumPlanName
            PlanGuid = $planGuid
            BaseSchemeGuid = [string]$activeBefore
            CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
            OriginalActivePlanGuid = $null
            AppliedPresetId = $null
            AppliedAtUtc = $null
            PlanExportPath = $null
            RestoredAtUtc = $null
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$state.OriginalActivePlanGuid)) { $state.OriginalActivePlanGuid = $activeBefore }
    $activationChanged = $false
    try {
        $values = Invoke-POPlatinumPresetValues -PlanGuid $planGuid -Preset $preset
        if ($values.Failed.Count -gt 0 -or $values.Unverified.Count -gt 0) {
            $details = @($values.Failed | ForEach-Object { $_.Reason }) + @($values.Unverified | ForEach-Object { $_.Reason })
            throw ('One or more power settings failed or could not be verified: ' + ($details -join '; '))
        }
        $currentActive = Get-POActivePowerPlanGuid
        if ($Activate) {
            if ($currentActive -eq $planGuid) {
                $activationChanged = $false
            }
            elseif ($currentActive -ne $activeBefore) {
                throw "The active plan changed during optimization to '$currentActive'; that newer user choice was left untouched."
            }
            else {
                [void](Set-POActivePowerPlan -Guid ([guid]$planGuid))
                $activationChanged = $true
            }
        }
        $activeAfter = Get-POActivePowerPlanGuid
        $activated = ([bool]$Activate -and $activeAfter -eq $planGuid)
        if ($Activate -and -not $activated) { throw "Active-plan verification failed. Windows reports '$activeAfter', not '$planGuid'." }
        $state.AppliedPresetId = $PresetId
        $state.AppliedAtUtc = [DateTime]::UtcNow.ToString('o')
        Set-POPlatinumState -State $state
        $items = @()
        if ($createdByThisRun) {
            $items += [pscustomobject][ordered]@{ Id = 'platinum-plan-created'; Name = "Create $(Get-POPlatinumPlanName) plan"; Status = 'APPLIED_VERIFIED'; Attempted = $true; Verified = $true; PreviousValue = 'Plan did not exist'; TargetValue = $planGuid; Reason = 'Created from the active Windows scheme and confirmed in powercfg /list.'; RequiresReboot = $false }
        }
        else {
            $items += [pscustomobject][ordered]@{ Id = 'platinum-plan-reused'; Name = "Reuse $(Get-POPlatinumPlanName) plan"; Status = 'REUSED_VERIFIED'; Attempted = $false; Verified = $true; PreviousValue = $planGuid; TargetValue = $planGuid; Reason = 'Existing named scheme was queried and reused; no duplicate plan was created.'; RequiresReboot = $false }
        }
        $items += @($values.Changes)
        if ($Activate) {
            if ($activationChanged) {
                $items += [pscustomobject][ordered]@{ Id = 'platinum-plan-activation'; Name = 'Activate Platinum On Steroids power plan'; Status = 'APPLIED_VERIFIED_ACTIVATED'; Attempted = $true; Verified = $true; PreviousValue = $activeBefore; TargetValue = $planGuid; Reason = 'powercfg setactive succeeded and Windows reported the requested active GUID.'; RequiresReboot = $false }
            }
            else {
                $items += [pscustomobject][ordered]@{ Id = 'platinum-plan-activation'; Name = 'Activate Platinum On Steroids power plan'; Status = 'ALREADY_OPTIMIZED'; Attempted = $false; Verified = $true; PreviousValue = $planGuid; TargetValue = $planGuid; Reason = 'The Platinum plan was already active and Windows verified its GUID.'; RequiresReboot = $false }
            }
        }
        $summary = "Preset $($preset.name): $($values.Applied.Count) settings changed and verified, $($values.AlreadyOptimized.Count) already at target, $($values.Skipped.Count) unsupported, $($values.Failed.Count) failed, $($values.Unverified.Count) unverified."
        $ledgerWarning = $null
        try {
            $settingWriteLedger = ConvertTo-POPowerSettingWriteLedger -Changes @($values.Changes)
            Update-POBackupChangeStatus -BackupPath $backup.Path -Section power -Status 'APPLIED_VERIFIED' -Message $summary -PowerSettingWrites @($settingWriteLedger)
        }
        catch { $ledgerWarning = $_.Exception.Message }
        Write-POLog -Category 'Power' -TweakId 'platinum-power-plan' -Status $(if ($activated) { 'APPLIED_VERIFIED_ACTIVATED' } else { 'APPLIED_VERIFIED' }) -Message $summary -Command "powercfg preset=$PresetId" -ExitCode 0
        $finalMessage = $summary
        if ($activated) { $finalMessage += " '$(Get-POPlatinumPlanName)' is the active plan." }
        if ($ledgerWarning) { $finalMessage += " WARNING: backup ledger status update failed: $ledgerWarning" }
        return [pscustomobject][ordered]@{
            Status = if ($activated) { 'APPLIED_VERIFIED_ACTIVATED' } else { 'APPLIED_VERIFIED' }
            Message = $finalMessage
            PlanName = Get-POPlatinumPlanName
            PlanGuid = $planGuid
            PlanCreated = $createdByThisRun
            Activated = $activated
            ActivationChanged = $activationChanged
            Changes = $items
            Applied = $values.Applied
            AlreadyOptimized = $values.AlreadyOptimized
            Skipped = $values.Skipped
            Failed = $values.Failed
            Unverified = $values.Unverified
            Backup = $backup
            RequiresReboot = $false
            LedgerWarning = $ledgerWarning
        }
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackNotes = @()
        $rollbackOk = $true
        $currentActive = Get-POActivePowerPlanGuid
        if ($currentActive -eq $planGuid -and $planGuid -ne $activeBefore) {
            try { [void](Set-POActivePowerPlan -Guid ([guid]$activeBefore)); $currentActive = $activeBefore; $rollbackNotes += 'Restored the prior active plan and verified it.' }
            catch { $rollbackOk = $false; $rollbackNotes += "Active-plan rollback failed: $($_.Exception.Message)" }
        }
        if ($existingBefore -and $settingsBefore) {
            try {
                $rollbackKeys = @()
                if ($values -and $values.Changes) {
                    $currentSettings = Get-POPlatinumPowerSettingsSnapshot -PlanGuid $planGuid
                    foreach ($attemptedSetting in @($values.Changes | Where-Object { $_.Attempted })) {
                        $idMatch = [regex]::Match([string]$attemptedSetting.Id, '^(?<id>.+)-(?<side>ac|dc)$', 'IgnoreCase')
                        if (-not $idMatch.Success) { $rollbackOk = $false; $rollbackNotes += "Cannot identify the side for attempted setting '$($attemptedSetting.Id)'; it was not overwritten during rollback."; continue }
                        $settingId = $idMatch.Groups['id'].Value
                        $sideName = $idMatch.Groups['side'].Value.ToUpperInvariant()
                        $valueName = if ($sideName -eq 'AC') { 'AcValue' } else { 'DcValue' }
                        $capturedName = if ($sideName -eq 'AC') { 'AcCaptured' } else { 'DcCaptured' }
                        $currentRecord = @($currentSettings.Settings | Where-Object { $_.Id -eq $settingId } | Select-Object -First 1)
                        $beforeRecord = @($settingsBefore.Settings | Where-Object { $_.Id -eq $settingId } | Select-Object -First 1)
                        if ($currentRecord.Count -eq 0 -or $beforeRecord.Count -eq 0 -or -not [bool]$currentRecord[0].$capturedName -or -not [bool]$beforeRecord[0].$capturedName) {
                            $rollbackOk = $false
                            $rollbackNotes += "The attempted setting '$settingId' ($sideName) could not be read for safe rollback."
                            continue
                        }
                        $currentValue = 0; $beforeValue = 0; $previousValue = 0; $targetValue = 0
                        if (-not [int]::TryParse([string]$currentRecord[0].$valueName, [ref]$currentValue) -or
                            -not [int]::TryParse([string]$beforeRecord[0].$valueName, [ref]$beforeValue) -or
                            -not [int]::TryParse([string]$attemptedSetting.PreviousValue, [ref]$previousValue) -or
                            -not [int]::TryParse([string]$attemptedSetting.TargetValue, [ref]$targetValue) -or
                            $previousValue -ne $beforeValue) {
                            $rollbackOk = $false
                            $rollbackNotes += "The attempted setting '$settingId' ($sideName) has invalid or inconsistent rollback values."
                            continue
                        }
                        if ($currentValue -eq $beforeValue) { continue }
                        if ($currentValue -ne $targetValue) {
                            $rollbackOk = $false
                            $rollbackNotes += "The attempted setting '$settingId' ($sideName) now has a newer value ($currentValue); it was left untouched."
                            continue
                        }
                        $rollbackKeys += ($settingId + '|' + $sideName)
                    }
                }
                if ($rollbackKeys.Count -gt 0) {
                    $restoreSettings = Restore-POPlatinumPowerSettingsSnapshot -PlanGuid $planGuid -Snapshot $settingsBefore -SettingKeys @($rollbackKeys | Select-Object -Unique)
                    if ($restoreSettings.Verified) { $rollbackNotes += 'Restored and verified only the existing Platinum settings attempted by this failed transaction.' }
                    else { $rollbackOk = $false; $rollbackNotes += ('Existing plan settings rollback failed: ' + (@($restoreSettings.Failed) -join '; ')) }
                }
                elseif ($rollbackOk) { $rollbackNotes += 'No existing Platinum settings required rollback.' }
            }
            catch { $rollbackOk = $false; $rollbackNotes += "Existing plan settings rollback failed: $($_.Exception.Message)" }
        }
        elseif ($createdByThisRun) {
            $currentActive = Get-POActivePowerPlanGuid
            if ($currentActive -eq $activeBefore) {
                $createdEntry = @(Get-POPowerPlans | Where-Object { $_.Guid -eq $planGuid -and $_.Name -eq (Get-POPlatinumPlanName) } | Select-Object -First 1)
                if ($createdEntry.Count -gt 0) {
                    $removeResult = Invoke-POPowercfg -Arguments @('/delete', $planGuid)
                    if ($removeResult.ExitCode -eq 0 -and -not $removeResult.TimedOut -and @(Get-POPowerPlans | Where-Object { $_.Guid -eq $planGuid }).Count -eq 0) { $rollbackNotes += 'Removed only the new Platinum scheme created by this failed run.' }
                    else { $rollbackOk = $false; $rollbackNotes += 'Could not verify removal of the newly created Platinum scheme; it was left installed.' }
                }
            }
            else { $rollbackOk = $false; $rollbackNotes += "The active plan changed to '$currentActive'; the newly created plan was left untouched." }
        }
        try {
            if ($null -ne $values) {
                $settingWriteLedger = ConvertTo-POPowerSettingWriteLedger -Changes @($values.Changes)
                Update-POBackupChangeStatus -BackupPath $backup.Path -Section power -Status 'FAILED' -Message $failure -PowerSettingWrites @($settingWriteLedger)
            }
            else { Update-POBackupChangeStatus -BackupPath $backup.Path -Section power -Status 'FAILED' -Message $failure }
        }
        catch { $rollbackNotes += "Backup ledger status update failed: $($_.Exception.Message)" }
        Write-POLog -Level 'ERROR' -Category 'Power' -TweakId 'platinum-power-plan' -Status 'FAILED' -Message $failure
        if (-not $rollbackOk) { Write-POLog -Level 'CRITICAL' -Category 'Power' -TweakId 'platinum-power-plan' -Status 'ROLLBACK_FAILED' -Message ($rollbackNotes -join ' ') }
        $allChanges = @()
        if ($values -and $values.Changes) {
            foreach ($item in @($values.Changes)) {
                if ($item.Status -eq 'APPLIED_VERIFIED') {
                    $item.Status = if ($rollbackOk) { 'FAILED' } else { 'UNVERIFIED' }
                    $item.Verified = $false
                    $item.Reason = if ($rollbackOk) { 'The transaction failed; the pre-run state was restored and verified.' } else { 'The transaction failed and full rollback could not be verified.' }
                }
                $allChanges += $item
            }
        }
        $allChanges += [pscustomobject][ordered]@{ Id = 'platinum-plan-workflow'; Name = 'Platinum power-plan workflow'; Status = if ($rollbackOk) { 'FAILED' } else { 'UNVERIFIED' }; Attempted = $true; Verified = $false; PreviousValue = $activeBefore; TargetValue = $planGuid; Reason = $failure + ' ' + ($rollbackNotes -join ' '); RequiresReboot = $false }
        return [pscustomobject][ordered]@{
            Status = 'FAILED'
            Message = $failure + ' ' + ($rollbackNotes -join ' ')
            PlanName = Get-POPlatinumPlanName
            PlanGuid = $planGuid
            PlanCreated = $createdByThisRun
            Activated = $false
            ActivationChanged = $activationChanged
            Changes = $allChanges
            Applied = @()
            AlreadyOptimized = if ($values) { $values.AlreadyOptimized } else { @() }
            Skipped = if ($values) { $values.Skipped } else { @() }
            Failed = if ($values) { $values.Failed } else { @() }
            Unverified = if ($values) { $values.Unverified } else { @() }
            RollbackVerified = $rollbackOk
            Rollback = $rollbackNotes
            Backup = $backup
            RequiresReboot = $false
        }
    }
}

function Set-POPlatinumPlanActive {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    if (-not (Test-POIsWindows)) { throw 'Power plan activation is available only on Windows.' }
    $entry = Find-POPlatinumPlanEntry
    if (-not $entry) { throw "The '$(Get-POPlatinumPlanName)' plan does not exist yet; create it first." }
    $currentActive = Get-POActivePowerPlanGuid
    if ([string]::IsNullOrWhiteSpace($currentActive)) { throw 'The current active power plan could not be read; activation was blocked.' }
    if ($currentActive -eq [string]$entry.Guid) {
        return [pscustomobject][ordered]@{ Status = 'ALREADY_ACTIVE'; Message = "'$(Get-POPlatinumPlanName)' is already the active plan."; PlanGuid = [string]$entry.Guid }
    }
    if (-not $PSCmdlet.ShouldProcess((Get-POPlatinumPlanName), 'Activate the Platinum On Steroids power plan')) {
        return [pscustomobject][ordered]@{ Status = 'SIMULATED'; Message = "Dry run: would activate '$(Get-POPlatinumPlanName)'. No change was made."; PlanGuid = [string]$entry.Guid }
    }
    if (-not (Test-POIsAdministrator)) { throw 'Activating a power plan requires an elevated Administrator session.' }
    $state = Get-POPlatinumState
    if ($null -eq $state -or -not $state.PlanGuid) {
        $state = [pscustomobject][ordered]@{
            PlanName = Get-POPlatinumPlanName; PlanGuid = [string]$entry.Guid; BaseSchemeGuid = $null; CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
            OriginalActivePlanGuid = $null; AppliedPresetId = $null; AppliedAtUtc = $null; PlanExportPath = $null; RestoredAtUtc = $null
        }
    }
    if (-not $state.OriginalActivePlanGuid) {
        if ($state.PSObject.Properties['OriginalActivePlanGuid']) { $state.OriginalActivePlanGuid = $currentActive }
        else { $state | Add-Member -MemberType NoteProperty -Name 'OriginalActivePlanGuid' -Value $currentActive }
    }
    [void](Set-POActivePowerPlan -Guid ([guid]$entry.Guid))
    Set-POPlatinumState -State $state
    Write-POLog -Category 'Power' -TweakId 'platinum-power-plan' -Status 'ACTIVATED_VERIFIED' -Message "Activated '$(Get-POPlatinumPlanName)' ($($entry.Guid)); previous plan $currentActive recorded for restore."
    return [pscustomobject][ordered]@{ Status = 'ACTIVATED_VERIFIED'; Message = "Windows now reports '$(Get-POPlatinumPlanName)' as active. Previous plan ($currentActive) is recorded for one-click restore."; PlanGuid = [string]$entry.Guid; PreviousPlanGuid = $currentActive }
}

function Restore-POPreviousPowerPlan {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    if (-not (Test-POIsWindows)) { throw 'Power plan restore is available only on Windows.' }
    $state = Get-POPlatinumState
    if ($null -eq $state -or -not $state.OriginalActivePlanGuid) { throw 'No previous active plan was recorded by Platinum Optimizer; nothing to restore.' }
    $originalGuid = [string]$state.OriginalActivePlanGuid
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($originalGuid, [ref]$parsed)) { throw 'The recorded previous plan GUID is invalid.' }
    $currentActive = Get-POActivePowerPlanGuid
    if ([string]::IsNullOrWhiteSpace($currentActive)) { throw 'The current active power plan could not be read; restore was blocked.' }
    if ($currentActive -eq $parsed.ToString()) {
        return [pscustomobject][ordered]@{ Status = 'ALREADY_RESTORED'; Message = 'The recorded previous plan is already active.'; PlanGuid = $parsed.ToString() }
    }
    if (-not $PSCmdlet.ShouldProcess($parsed.ToString(), 'Restore the power plan that was active before Platinum On Steroids')) {
        return [pscustomobject][ordered]@{ Status = 'SIMULATED'; Message = "Dry run: would re-activate the previous plan $($parsed.ToString()). No change was made."; PlanGuid = $parsed.ToString() }
    }
    if (-not (Test-POIsAdministrator)) { throw 'Restoring a power plan requires an elevated Administrator session.' }
    $available = @(Get-POPowerPlans | Where-Object { $_.Guid -eq $parsed.ToString() })
    if ($available.Count -eq 0) {
        $export = $null
        if ($state.PSObject.Properties['PlanExportPath'] -and $state.PlanExportPath -and (Test-Path -LiteralPath ([string]$state.PlanExportPath) -PathType Leaf)) { $export = [string]$state.PlanExportPath }
        $localPow = Join-Path (Get-POPowerStateRoot) 'previous-plan.pow'
        if (-not $export -and (Test-Path -LiteralPath $localPow -PathType Leaf)) { $export = $localPow }
        if (-not $export) { throw "The previous plan $originalGuid no longer exists and no .pow export is available to re-import it." }
        $import = Invoke-POPowercfg -Arguments @('/import', $export, $parsed.ToString())
        if ($import.ExitCode -ne 0) { throw "Re-importing the previous plan failed with exit code $($import.ExitCode)." }
    }
    [void](Set-POActivePowerPlan -Guid $parsed)
    if ($state.PSObject.Properties['RestoredAtUtc']) { $state.RestoredAtUtc = [DateTime]::UtcNow.ToString('o') }
    else { $state | Add-Member -MemberType NoteProperty -Name 'RestoredAtUtc' -Value ([DateTime]::UtcNow.ToString('o')) }
    Set-POPlatinumState -State $state
    Write-POLog -Category 'Power' -TweakId 'platinum-power-plan' -Status 'RESTORED_VERIFIED' -Message "Restored previous active plan $originalGuid. The Platinum plan was kept, not deleted."
    return [pscustomobject][ordered]@{ Status = 'RESTORED_VERIFIED'; Message = "The previous plan ($originalGuid) is active again and Windows verified it. The Platinum On Steroids plan remains installed and can be re-activated."; PlanGuid = $parsed.ToString() }
}

function Remove-POPlatinumPlan {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    if (-not (Test-POIsWindows)) { throw 'Power plan management is available only on Windows.' }
    $entry = Find-POPlatinumPlanEntry
    if (-not $entry) { return [pscustomobject][ordered]@{ Status = 'NOT_FOUND'; Message = "The '$(Get-POPlatinumPlanName)' plan does not exist; nothing to remove." } }
    if ([bool]$entry.IsActive) { throw 'The Platinum plan is currently active. Restore or activate another plan first; an active plan cannot be deleted.' }
    if (-not $PSCmdlet.ShouldProcess([string]$entry.Name, 'Delete ONLY the Platinum On Steroids plan created by this application')) {
        return [pscustomobject][ordered]@{ Status = 'SIMULATED'; Message = 'Dry run: would delete only the Platinum On Steroids plan. No plan was deleted.' }
    }
    if (-not (Test-POIsAdministrator)) { throw 'Deleting a power plan requires an elevated Administrator session.' }
    $delete = Invoke-POPowercfg -Arguments @('/delete', [string]$entry.Guid)
    if ($delete.ExitCode -ne 0) { throw "powercfg /delete failed with exit code $($delete.ExitCode)." }
    $statePath = Get-POPlatinumStatePath
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { Remove-Item -LiteralPath $statePath -Force }
    $powPath = Join-Path (Get-POPowerStateRoot) 'platinum-plan.pow'
    if (Test-Path -LiteralPath $powPath -PathType Leaf) { Remove-Item -LiteralPath $powPath -Force }
    Write-POLog -Category 'Power' -TweakId 'platinum-power-plan' -Status 'REMOVED' -Message "Removed the Platinum On Steroids plan ($($entry.Guid)). No other plan was touched."
    return [pscustomobject][ordered]@{ Status = 'REMOVED'; Message = "The '$(Get-POPlatinumPlanName)' plan was removed. All other plans are untouched." }
}

function Get-POQuickCpuStatus {
    [CmdletBinding()]
    param()
    # Detection only. Quick CPU is a third-party tool; it is never bundled,
    # downloaded, or launched by Platinum Optimizer.
    $found = $null
    $candidates = @()
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $candidates += Join-Path $root 'CoderBag'
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $exe = @(Get-ChildItem -LiteralPath $candidate -Recurse -Filter 'QuickCPU*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($exe.Count -gt 0) { $found = [string]$exe[0].FullName; break }
        }
    }
    if (-not $found) {
        $startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu'
        if (Test-Path -LiteralPath $startMenu -PathType Container) {
            $shortcuts = @(Get-ChildItem -LiteralPath $startMenu -Recurse -Filter '*Quick CPU*' -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($shortcuts.Count -gt 0) { $found = [string]$shortcuts[0].FullName }
        }
    }
    return [pscustomobject][ordered]@{
        Installed = [bool]$found
        Path = $found
        Note = 'Quick CPU is an optional third-party utility. Platinum Optimizer does not download or launch it. If installed, it can manage the same documented processor power settings (core parking, frequency floors) that the Platinum plan configures via powercfg.'
    }
}

function Get-POCpuParkingStatus {
    [CmdletBinding()]
    param()
    if (-not (Test-POIsWindows)) { throw 'CPU power status is available only on Windows.' }
    $activeGuid = Get-POActivePowerPlanGuid
    $report = [pscustomobject][ordered]@{
        ActivePlanGuid = $activeGuid
        ActivePlanName = $null
        ProcessorSettings = @()
        CoreParkingVisible = $false
        QuickCpu = Get-POQuickCpuStatus
        Note = 'Values are read from the active power plan with powercfg. Settings Windows does not expose on this platform are shown as Not supported.'
    }
    if ([string]::IsNullOrWhiteSpace($activeGuid)) { return $report }
    $plans = @(Get-POPowerPlans)
    $activePlan = @($plans | Where-Object { $_.Guid -eq $activeGuid } | Select-Object -First 1)
    if ($activePlan.Count -gt 0) { $report.ActivePlanName = [string]$activePlan[0].Name }
    $catalog = Get-POPowerSettingCatalog
    $query = Invoke-POPowercfg -Arguments @('/qh', $activeGuid)
    if ($query.ExitCode -ne 0) { $report.Note = "powercfg could not query the active plan (exit code $($query.ExitCode))."; return $report }
    $parsed = @(ConvertFrom-POPowerQueryLines -Lines $query.Output)
    $settings = @()
    foreach ($setting in @($catalog.settings)) {
        if ([string]$setting.subgroup -ne 'processor') { continue }
        $subgroupGuid = [string]$catalog.subgroups.processor
        $guidCandidates = @([string]$setting.guid)
        if ($setting.PSObject.Properties['dcGuid'] -and $setting.dcGuid) { $guidCandidates += [string]$setting.dcGuid }
        $acValue = $null; $dcValue = $null; $supported = $false
        foreach ($candidate in $guidCandidates) {
            foreach ($record in @($parsed | Where-Object { $_.SubgroupGuid -eq $subgroupGuid -and $_.SettingGuid -eq $candidate.ToLowerInvariant() })) {
                $supported = $true
                if ($null -ne $record.AcIndex) { $acValue = [int]$record.AcIndex }
                if ($null -ne $record.DcIndex) { $dcValue = [int]$record.DcIndex }
            }
        }
        if ($supported -and [string]$setting.id -match '^core-parking') { $report.CoreParkingVisible = $true }
        $settings += [pscustomobject][ordered]@{
            Id = [string]$setting.id
            Name = [string]$setting.name
            Supported = $supported
            AcValue = $acValue
            DcValue = $dcValue
        }
    }
    $report.ProcessorSettings = $settings
    return $report
}

Export-ModuleMember -Function @(
    'Get-POPowerSettingCatalog', 'Get-POPlatinumPlanName', 'Get-POPlatinumState', 'Get-POPlatinumStatePath',
    'ConvertFrom-POPowerPlanListLines', 'ConvertFrom-POPowerQueryLines', 'ConvertFrom-POPowerSettingsSnapshot',
    'Get-POPlatinumPowerSettingsSnapshot', 'Restore-POPlatinumPowerSettingsSnapshot', 'Test-POPowerPresetDefinition',
    'Get-POPlatinumPresetCatalog', 'Get-POPlatinumPlanInfo', 'New-POPlatinumPlan',
    'Invoke-POPlatinumPlanWorkflow', 'Set-POPlatinumPlanActive', 'Restore-POPreviousPowerPlan', 'Remove-POPlatinumPlan',
    'Get-POQuickCpuStatus', 'Get-POCpuParkingStatus'
)
