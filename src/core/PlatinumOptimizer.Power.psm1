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
    $output = @(& powercfg.exe @Arguments 2>&1)
    return [pscustomobject][ordered]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { [string]$_ }) }
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
    $match = @($plans | Where-Object { [string]$_.Name -eq $name } | Select-Object -First 1)
    if ($match.Count -eq 0) { return $null }
    return $match[0]
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
    param()
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
    if (-not $PSCmdlet.ShouldProcess($name, 'Create the Platinum On Steroids power plan from the High Performance base scheme')) {
        return [pscustomobject][ordered]@{ Status = 'SIMULATED'; PlanGuid = $null; Created = $false; Message = "Dry run: would duplicate the High Performance scheme, rename it to '$name', and verify it. No plan was created." }
    }
    if (-not (Test-POIsAdministrator)) { throw 'Creating a power plan requires an elevated Administrator session.' }
    $baseGuid = [string]$catalog.builtinSchemes.([string]$catalog.duplicateBaseScheme)
    $plansBefore = @(Get-POPowerPlans | ForEach-Object { [string]$_.Guid })
    $duplicate = Invoke-POPowercfg -Arguments @('/duplicatescheme', $baseGuid)
    if ($duplicate.ExitCode -ne 0) {
        throw "powercfg /duplicatescheme failed with exit code $($duplicate.ExitCode): $(($duplicate.Output -join ' ').Trim())"
    }
    $guidMatch = [regex]::Match(($duplicate.Output -join "`n"), '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
    if (-not $guidMatch.Success) { throw 'powercfg /duplicatescheme succeeded but did not report the new plan GUID; the plan was not adopted.' }
    $newGuid = $guidMatch.Groups[1].Value.ToLowerInvariant()
    $verifyList = @(ConvertFrom-POPowerPlanListLines -Lines (Invoke-POPowercfg -Arguments @('/list')).Output)
    if (@($verifyList | Where-Object { $_.Guid -eq $newGuid }).Count -eq 0) { throw "The duplicated plan GUID $newGuid was not found in the power scheme list; the plan was not adopted." }
    $setName = Invoke-POPowercfg -Arguments @('/setname', $newGuid, $name, [string]$catalog.planDescription)
    if ($setName.ExitCode -ne 0) {
        [void](Invoke-POPowercfg -Arguments @('/delete', $newGuid))
        throw "powercfg /setname failed with exit code $($setName.ExitCode); the unnamed duplicate was removed."
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
        Notes = 'Created from the documented High Performance scheme with powercfg /duplicatescheme. Existing user plans were preserved.'
    }
    Set-POPlatinumState -State $state
    Write-POLog -Category 'Power' -TweakId 'platinum-power-plan' -Status 'CREATED' -Message "Created power plan '$name' ($newGuid) from base scheme $baseGuid."
    return [pscustomobject][ordered]@{ Status = 'CREATED'; PlanGuid = $newGuid; Created = $true; Message = "Created '$name' ($newGuid) from the High Performance base scheme. Existing plans were preserved." }
}

function Invoke-POPlatinumPresetValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PlanGuid,
        [Parameter(Mandatory = $true)][psobject]$Preset
    )
    $catalog = Get-POPowerSettingCatalog
    $applied = @(); $skipped = @(); $failed = @()
    foreach ($setting in @($catalog.settings)) {
        $settingId = [string]$setting.id
        $acValue = Get-POPresetSettingValue -Side $Preset.ac -SettingId $settingId
        $dcValue = Get-POPresetSettingValue -Side $Preset.dc -SettingId $settingId
        if ($null -eq $acValue -and $null -eq $dcValue) { continue }
        $subgroupGuid = [string]$catalog.subgroups.([string]$setting.subgroup)
        $optional = ($setting.PSObject.Properties['optional'] -and [bool]$setting.optional)
        $settingOk = $true
        if ($null -ne $acValue) {
            $setAc = Invoke-POPowercfg -Arguments @('/setacvalueindex', $PlanGuid, $subgroupGuid, [string]$setting.guid, [string]$acValue)
            if ($setAc.ExitCode -ne 0) { $settingOk = $false; $skipped += "$($setting.name): AC value $acValue was rejected by powercfg (exit code $($setAc.ExitCode)); setting left unchanged." }
        }
        if ($null -ne $dcValue -and $settingOk) {
            $dcGuid = if ($setting.PSObject.Properties['dcGuid'] -and $setting.dcGuid) { [string]$setting.dcGuid } else { [string]$setting.guid }
            $setDc = Invoke-POPowercfg -Arguments @('/setdcvalueindex', $PlanGuid, $subgroupGuid, $dcGuid, [string]$dcValue)
            if ($setDc.ExitCode -ne 0) { $settingOk = $false; $skipped += "$($setting.name): DC value $dcValue was rejected by powercfg (exit code $($setDc.ExitCode)); setting left unchanged." }
        }
        if (-not $settingOk) {
            if (-not $optional) { $failed += "$($setting.name): a documented mandatory setting could not be applied." }
            continue
        }
        # Verify by re-reading the plan.
        $query = Invoke-POPowercfg -Arguments @('/qh', $PlanGuid)
        if ($query.ExitCode -ne 0) { $failed += "$($setting.name): verification query failed with exit code $($query.ExitCode)."; continue }
        $parsed = @(ConvertFrom-POPowerQueryLines -Lines $query.Output)
        $verified = $true
        $acGuid = [string]$setting.guid
        $dcGuid = if ($setting.PSObject.Properties['dcGuid'] -and $setting.dcGuid) { [string]$setting.dcGuid } else { [string]$setting.guid }
        if ($null -ne $acValue) {
            $acRecord = @($parsed | Where-Object { $_.SubgroupGuid -eq $subgroupGuid -and $_.SettingGuid -eq $acGuid.ToLowerInvariant() -and $null -ne $_.AcIndex } | Select-Object -First 1)
            if ($acRecord.Count -eq 0 -or [int]$acRecord[0].AcIndex -ne $acValue) { $verified = $false }
        }
        if ($null -ne $dcValue -and $verified) {
            $dcRecord = @($parsed | Where-Object { $_.SubgroupGuid -eq $subgroupGuid -and $_.SettingGuid -eq $dcGuid.ToLowerInvariant() -and $null -ne $_.DcIndex } | Select-Object -First 1)
            if ($dcRecord.Count -eq 0 -or [int]$dcRecord[0].DcIndex -ne $dcValue) { $verified = $false }
        }
        if (-not $verified) {
            if ($optional) { $skipped += "$($setting.name): powercfg accepted the value but verification could not confirm it; treat as not applied." }
            else { $failed += "$($setting.name): verification mismatch after apply." }
            continue
        }
        $applied += "$($setting.name): AC $(if ($null -ne $acValue) { $acValue } else { 'unchanged' }) / DC $(if ($null -ne $dcValue) { $dcValue } else { 'unchanged' })"
    }
    return [pscustomobject][ordered]@{ Applied = $applied; Skipped = $skipped; Failed = $failed }
}

function Invoke-POPlatinumPlanWorkflow {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$PresetId,
        [switch]$Activate
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
    $planAction = if ($existing) { "update the existing '$(Get-POPlatinumPlanName)' plan" } else { "create the '$(Get-POPlatinumPlanName)' plan from the High Performance scheme" }
    $activationText = if ($Activate) { ' Then activate it.' } else { ' Do not activate it.' }
    if (-not $PSCmdlet.ShouldProcess((Get-POPlatinumPlanName), "Apply the $($preset.name) preset: $planAction.$activationText")) {
        return [pscustomobject][ordered]@{ Status = 'SIMULATED'; Message = "Dry run: would $planAction with the $($preset.name) preset.$activationText No plan, setting, or backup was changed."; PlanGuid = if ($existing) { [string]$existing.Guid } else { $null }; Backup = $null }
    }
    if (-not (Test-POIsAdministrator)) { throw 'Creating and configuring a power plan requires an elevated Administrator session.' }

    $createResult = New-POPlatinumPlan -Confirm:$false
    if ($createResult.Status -eq 'EXISTS_INVALID') { throw $createResult.Message }
    $planGuid = [string]$createResult.PlanGuid

    $state = Get-POPlatinumState
    if ($null -eq $state -or -not $state.PlanGuid -or [string]$state.PlanGuid -ne $planGuid) {
        $state = [pscustomobject][ordered]@{
            PlanName = Get-POPlatinumPlanName; PlanGuid = $planGuid; BaseSchemeGuid = [string]$catalog.builtinSchemes.([string]$catalog.duplicateBaseScheme)
            CreatedAtUtc = [DateTime]::UtcNow.ToString('o'); OriginalActivePlanGuid = $null; AppliedPresetId = $null; AppliedAtUtc = $null; PlanExportPath = $null; RestoredAtUtc = $null
        }
    }
    if (-not $state.OriginalActivePlanGuid) {
        if ($state.PSObject.Properties['OriginalActivePlanGuid']) { $state.OriginalActivePlanGuid = $activeBefore }
        else { $state | Add-Member -MemberType NoteProperty -Name 'OriginalActivePlanGuid' -Value $activeBefore }
    }
    $backupState = [pscustomobject][ordered]@{
        OriginalActivePlanGuid = [string]$activeBefore
        PlatinumPlanGuid = $planGuid
        PresetId = $PresetId
        PlanName = Get-POPlatinumPlanName
        PlansPreserved = @(Get-POPowerPlans | ForEach-Object { [pscustomobject]@{ Guid = $_.Guid; Name = $_.Name } })
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $backup = New-POBackup -PlatinumState $backupState
    $changeRecord = [pscustomobject][ordered]@{
        section = 'power'; id = 'platinum-power-plan'; name = "Platinum On Steroids power plan ($($preset.name))"
        fromGuid = [string]$activeBefore; toGuid = $planGuid; preset = $PresetId; activate = [bool]$Activate
        status = 'APPLYING'; timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    Add-POBackupChange -BackupPath $backup.Path -Section power -Change $changeRecord
    try {
        $values = Invoke-POPlatinumPresetValues -PlanGuid $planGuid -Preset $preset
        if ($values.Failed.Count -gt 0) { throw ('Preset application failed: ' + ($values.Failed -join '; ')) }
        $activated = $false
        if ($Activate) {
            if ((Get-POActivePowerPlanGuid) -ne $activeBefore) { throw 'The active plan changed during the workflow; the newer selection was left untouched.' }
            [void](Set-POActivePowerPlan -Guid ([guid]$planGuid))
            $activated = $true
        }
        if ($state.PSObject.Properties['AppliedPresetId']) { $state.AppliedPresetId = $PresetId } else { $state | Add-Member -MemberType NoteProperty -Name 'AppliedPresetId' -Value $PresetId }
        if ($state.PSObject.Properties['AppliedAtUtc']) { $state.AppliedAtUtc = [DateTime]::UtcNow.ToString('o') } else { $state | Add-Member -MemberType NoteProperty -Name 'AppliedAtUtc' -Value ([DateTime]::UtcNow.ToString('o')) }
        Set-POPlatinumState -State $state
        $summary = "Preset $($preset.name): $($values.Applied.Count) settings applied and verified, $($values.Skipped.Count) skipped."
        Update-POBackupChangeStatus -BackupPath $backup.Path -Section power -Status 'APPLIED_VERIFIED' -Message $summary
        Write-POLog -Category 'Power' -TweakId 'platinum-power-plan' -Status $(if ($activated) { 'APPLIED_VERIFIED_ACTIVATED' } else { 'APPLIED_VERIFIED' }) -Message $summary -Command "powercfg preset=$PresetId" -ExitCode 0
        return [pscustomobject][ordered]@{
            Status = if ($activated) { 'APPLIED_VERIFIED_ACTIVATED' } else { 'APPLIED_VERIFIED' }
            Message = $summary + $(if ($activated) { " '$(Get-POPlatinumPlanName)' is now the active plan." } else { ' The previous plan remains active; use Activate when ready.' })
            PlanGuid = $planGuid
            Activated = $activated
            Applied = $values.Applied
            Skipped = $values.Skipped
            Backup = $backup
            RequiresReboot = $false
        }
    }
    catch {
        $failure = $_.Exception.Message
        Write-POLog -Level 'ERROR' -Category 'Power' -TweakId 'platinum-power-plan' -Status 'FAILED' -Message $failure
        try { Update-POBackupChangeStatus -BackupPath $backup.Path -Section power -Status 'FAILED' -Message $failure }
        catch { Write-POLog -Level 'CRITICAL' -Category 'Backup' -Status 'TRANSACTION_STATUS_WRITE_FAILED' -Message $_.Exception.Message }
        $stillActive = Get-POActivePowerPlanGuid
        $rollbackNote = if ($stillActive -eq $activeBefore) { 'The previous plan is still active; nothing was switched.' } else { "WARNING: the active plan is now '$stillActive'; review manually." }
        return [pscustomobject][ordered]@{ Status = 'FAILED'; Message = "$failure $rollbackNote"; PlanGuid = $planGuid; Activated = $false; Applied = @(); Skipped = @(); Rollback = $rollbackNote; Backup = $backup }
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
    'ConvertFrom-POPowerPlanListLines', 'ConvertFrom-POPowerQueryLines', 'Test-POPowerPresetDefinition',
    'Get-POPlatinumPresetCatalog', 'Get-POPlatinumPlanInfo', 'New-POPlatinumPlan',
    'Invoke-POPlatinumPlanWorkflow', 'Set-POPlatinumPlanActive', 'Restore-POPreviousPowerPlan', 'Remove-POPlatinumPlan',
    'Get-POQuickCpuStatus', 'Get-POCpuParkingStatus'
)
