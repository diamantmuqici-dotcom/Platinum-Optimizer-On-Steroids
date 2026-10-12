#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src\core\PlatinumOptimizer.Core.psm1'
Import-Module -Name $modulePath -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $repoRoot 'src\core\PlatinumOptimizer.Power.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $repoRoot 'src\core\PlatinumOptimizer.Audio.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $repoRoot 'src\core\PlatinumOptimizer.Display.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $repoRoot 'src\core\PlatinumOptimizer.Network.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $repoRoot 'src\core\PlatinumOptimizer.Gaming.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $repoRoot 'src\core\PlatinumOptimizer.Engine.psm1') -Global -Force -ErrorAction Stop
$script:CoreModule = @(Get-Module | Where-Object { $_.Path -eq $modulePath } | Select-Object -First 1)[0]

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:FailureMessages = New-Object System.Collections.Generic.List[string]

function Assert-POTest {
    param([bool]$Condition, [string]$Name, [string]$Failure = 'Assertion failed')
    if ($Condition) {
        $script:Passed++
        Write-Host "PASS  $Name" -ForegroundColor Green
    }
    else {
        $script:Failed++
        $script:FailureMessages.Add("$Name : $Failure")
        Write-Host "FAIL  $Name — $Failure" -ForegroundColor Red
    }
}

function Skip-POTest {
    param([string]$Name, [string]$Reason)
    $script:Skipped++
    Write-Host "SKIP  $Name — $Reason" -ForegroundColor Yellow
}

function Invoke-POPrivateRegistrySetter {
    param([Parameter(Mandatory = $true)][psobject]$State)
    if (-not $script:CoreModule) { throw 'Core module scope was not found for the registry integration test.' }
    $privateScript = $script:CoreModule.NewBoundScriptBlock({ param($RegistryState) Set-PORegValueState -State $RegistryState })
    & $privateScript $State
}

function New-TestSystemSnapshot {
    param([string]$Family = 'Windows 11', [bool]$Supported = $true, [bool]$IsLaptop = $false, [string]$PowerSource = 'AC')
    return [pscustomobject][ordered]@{
        CapturedAtUtc = '2026-10-04T00:00:00.0000000Z'
        OS = [pscustomobject]@{ Family = $Family; Supported = $Supported; Build = '26100'; Version = '10.0.26100'; Name = $Family; Edition = 'Test'; Architecture = 'x64' }
        Device = [pscustomobject]@{ IsLaptop = $IsLaptop; FormFactor = if ($IsLaptop) { 'Laptop / portable' } else { 'Desktop' }; PowerSource = $PowerSource }
        CPU = [pscustomobject]@{ Vendor = 'Unknown'; Model = 'Synthetic test CPU' }
        GPUs = @()
        Memory = [pscustomobject]@{ TotalGB = 16; AvailableGB = 8; Modules = @() }
        Storage = @()
        SystemVolume = $null
        Motherboard = [pscustomobject]@{ Manufacturer = 'Test'; Model = 'Test' }
        BIOS = [pscustomobject]@{ Version = 'Test'; ReleaseDate = 'Unknown' }
        Monitors = @()
    }
}

Write-Host 'Platinum Optimizer test harness' -ForegroundColor Cyan
Write-Host "Repository: $repoRoot"

# Data schema and policy checks.
try {
    $tweakDocument = Get-Content -LiteralPath (Join-Path $repoRoot 'src\data\tweaks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $profileDocument = Get-Content -LiteralPath (Join-Path $repoRoot 'src\data\profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $gameDocument = Get-Content -LiteralPath (Join-Path $repoRoot 'src\data\games.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $serviceDocument = Get-Content -LiteralPath (Join-Path $repoRoot 'src\data\services.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-POTest ($tweakDocument.schemaVersion -eq 1) 'Tweak catalog JSON parses'
    Assert-POTest (@($tweakDocument.tweaks).Count -ge 5) 'Tweak catalog has entries'
    $requiredTweakFields = @('id','name','category','description','purpose','risk','supportedVersions','hardwareRequirements','prerequisites','defaultValue','recommendedValue','expectedBenefit','requiresReboot','requiresAdmin','vendorDependency','rollbackMethod','evidence','operation','enabledByDefault')
    $missingTweakFields = @()
    foreach ($tweak in $tweakDocument.tweaks) { foreach ($field in $requiredTweakFields) { if ($null -eq $tweak.PSObject.Properties[$field]) { $missingTweakFields += "$($tweak.id).$field" } } }
    Assert-POTest ($missingTweakFields.Count -eq 0) 'Every tweak has audit metadata' ($missingTweakFields -join ', ')
    $validRisks = @('SAFE','LOW','MODERATE','HIGH','EXPERIMENTAL')
    $invalidRisks = @($tweakDocument.tweaks | Where-Object { $_.risk -notin $validRisks })
    Assert-POTest ($invalidRisks.Count -eq 0) 'Tweak risk labels use the defined vocabulary'
    Assert-POTest ($profileDocument.recommendedFirstRun -eq 'safe') 'First-run default is Safe'
    $profileIds = @($profileDocument.profiles | ForEach-Object { $_.id })
    foreach ($required in @('safe','balanced','gaming','competitive','max-performance','laptop-battery','custom')) {
        Assert-POTest ($profileIds -contains $required) "Profile exists: $required"
    }
    Assert-POTest (@($gameDocument.games).Count -ge 16) 'Game catalog includes requested titles'
    Assert-POTest (@($serviceDocument.classifications.SAFE_TO_DISABLE).Count -eq 0) 'Service catalog has no blanket safe-disable list'
    Assert-POTest (@($serviceDocument.classifications.SECURITY_CRITICAL).Count -gt 0) 'Security-critical services are identified'
}
catch {
    Assert-POTest $false 'Catalog loading' $_.Exception.Message
}

# Pure compatibility and planning tests use synthetic Windows inventories.
try {
    $plans = @(
        [pscustomobject]@{ Guid = '381b4222-f694-41f0-9685-ff5bb260df2e'; Name = 'Balanced'; IsActive = $true },
        [pscustomobject]@{ Guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; Name = 'High Performance'; IsActive = $false }
    )
    $desktop = New-TestSystemSnapshot -Family 'Windows 11' -Supported $true -IsLaptop $false -PowerSource 'AC'
    $balanced = New-POProfilePlan -ProfileId 'balanced' -SystemSnapshot $desktop -PowerPlans $plans -ActivePlanGuid '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    Assert-POTest ($balanced.Change -and $balanced.Change.ToGuid -eq '381b4222-f694-41f0-9685-ff5bb260df2e') 'Balanced profile selects existing built-in plan'
    Assert-POTest (-not $balanced.RequiresReboot) 'Power-plan change does not request reboot'
    Assert-POTest ($balanced.Change.Risk -eq 'LOW') 'Balanced plan displays its catalog risk ceiling'

    $safe = New-POProfilePlan -ProfileId 'safe' -SystemSnapshot $desktop -PowerPlans $plans -ActivePlanGuid '381b4222-f694-41f0-9685-ff5bb260df2e'
    Assert-POTest ($null -eq $safe.Change) 'Safe profile has no automatic system change'
    Assert-POTest ($safe.Recommendations.Count -gt 0) 'Safe profile offers manual Settings recommendations'

    $gaming = New-POProfilePlan -ProfileId 'gaming' -SystemSnapshot $desktop -PowerPlans $plans -ActivePlanGuid '381b4222-f694-41f0-9685-ff5bb260df2e'
    Assert-POTest ($gaming.Change -and $gaming.Change.ToGuid -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') 'Gaming profile offers only the existing High Performance plan'

    $battery = New-TestSystemSnapshot -Family 'Windows 11' -Supported $true -IsLaptop $true -PowerSource 'Battery'
    $blocked = New-POProfilePlan -ProfileId 'competitive' -SystemSnapshot $battery -PowerPlans $plans -ActivePlanGuid '381b4222-f694-41f0-9685-ff5bb260df2e'
    Assert-POTest ($null -eq $blocked.Change) 'Competitive performance plan is blocked on battery'
    Assert-POTest (@($blocked.Skipped | Where-Object { $_ -match 'battery' }).Count -gt 0) 'Battery block explains the skip'

    $unknownPower = New-TestSystemSnapshot -Family 'Windows 10' -Supported $true -IsLaptop $true -PowerSource 'Unknown'
    $unknownBlocked = New-POProfilePlan -ProfileId 'gaming' -SystemSnapshot $unknownPower -PowerPlans $plans -ActivePlanGuid '381b4222-f694-41f0-9685-ff5bb260df2e'
    Assert-POTest ($null -eq $unknownBlocked.Change) 'Performance plan is blocked when portable power source is unknown'
    $unknownFormFactor = New-TestSystemSnapshot -Family 'Windows 11' -Supported $true -IsLaptop $false -PowerSource 'Unknown'
    $unknownFormFactor.Device.IsLaptop = $null
    $unknownFormFactor.Device.FormFactor = 'Unknown'
    $unknownFormFactorPlan = New-POProfilePlan -ProfileId 'gaming' -SystemSnapshot $unknownFormFactor -PowerPlans $plans -ActivePlanGuid '381b4222-f694-41f0-9685-ff5bb260df2e'
    Assert-POTest ($null -eq $unknownFormFactorPlan.Change -and @($unknownFormFactorPlan.Skipped | Where-Object { $_ -match 'form factor' }).Count -gt 0) 'Performance plan is blocked when portable status is unknown'

    $unsupported = New-TestSystemSnapshot -Family 'Unknown' -Supported $false -IsLaptop $false -PowerSource 'AC'
    $unsupportedPlan = New-POProfilePlan -ProfileId 'gaming' -SystemSnapshot $unsupported -PowerPlans $plans -ActivePlanGuid '381b4222-f694-41f0-9685-ff5bb260df2e'
    Assert-POTest ($null -eq $unsupportedPlan.Change) 'Unsupported Windows build receives no plan change'

    $max = New-POProfilePlan -ProfileId 'max-performance' -SystemSnapshot $desktop -PowerPlans $plans -ActivePlanGuid '381b4222-f694-41f0-9685-ff5bb260df2e'
    Assert-POTest ($max.RequiresHighRiskConfirmation) 'Maximum Performance requires a separate confirmation'
    Assert-POTest ($max.Change.Risk -eq 'MODERATE') 'Maximum Performance preview reports its moderate risk classification'
    Assert-POTest ($max.Change.ToGuid -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') 'Maximum Performance falls back to installed High Performance plan'

    $planTweak = Get-POTweakCatalog | Where-Object { $_.id -eq 'power-plan' } | Select-Object -First 1
    $limitedCompatibility = Get-POTweakCompatibility -Tweak $planTweak -SystemSnapshot $desktop -Administrator:$false
    Assert-POTest (-not $limitedCompatibility.Compatible -and $limitedCompatibility.Status -eq 'SKIPPED') 'Compatibility blocks admin-only power changes in limited mode'
    $adminCompatibility = Get-POTweakCompatibility -Tweak $planTweak -SystemSnapshot $desktop -Administrator:$true
    Assert-POTest ($adminCompatibility.Compatible) 'Compatible supported Windows plan can pass the preflight'
}
catch {
    Assert-POTest $false 'Profile planning tests' $_.Exception.Message
}

# Pure validators/comparators must not depend on live hardware.
try {
    $dnsValid = Test-POIPv4DnsAddresses -Addresses @('1.1.1.1','1.0.0.1')
    Assert-POTest ($dnsValid.Valid -and $dnsValid.Addresses.Count -eq 2) 'DNS validator accepts IPv4 resolver addresses'
    $dnsInvalid = Test-POIPv4DnsAddresses -Addresses @('example.com')
    Assert-POTest (-not $dnsInvalid.Valid) 'DNS validator rejects names/non-IP values'
    $dnsV6 = Test-POIPv4DnsAddresses -Addresses @('2606:4700:4700::1111')
    Assert-POTest (-not $dnsV6.Valid) 'IPv4-only DNS form rejects IPv6 input clearly'
    $dnsTooMany = Test-POIPv4DnsAddresses -Addresses @('1.1.1.1','1.0.0.1','8.8.8.8','8.8.4.4','9.9.9.9')
    Assert-POTest (-not $dnsTooMany.Valid) 'DNS validator limits custom entries'
    $dnsShorthand = Test-POIPv4DnsAddresses -Addresses @('1.1')
    Assert-POTest (-not $dnsShorthand.Valid) 'DNS validator rejects ambiguous shorthand IPv4'
    $dnsBadOctet = Test-POIPv4DnsAddresses -Addresses @('300.1.1.1')
    Assert-POTest (-not $dnsBadOctet.Valid) 'DNS validator rejects out-of-range octets'
    $dnsUnicast = Test-POIPv4DnsAddresses -Addresses @('224.0.0.1')
    Assert-POTest (-not $dnsUnicast.Valid) 'DNS validator rejects multicast resolver addresses'

    $eligibleDnsState = [pscustomobject]@{
        Status = 'Up'; HardwareInterface = $true; InterfaceGuid = '12345678-1234-1234-1234-123456789abc'; DhcpEnabled = $true; IPv4DnsReadable = $true
        IPv4DnsReadError = $null; DnsConfigState = 'AUTOMATIC/DHCP'; DnsConfigDetail = 'No override or policy reported.'
    }
    $eligibleDns = Test-POAdapterDnsEligibility -AdapterState $eligibleDnsState
    Assert-POTest ($eligibleDns.Eligible) 'DNS preflight accepts a connected physical DHCP adapter with readable automatic DNS'
    $unknownDnsState = $eligibleDnsState.PSObject.Copy()
    $unknownDnsState.IPv4DnsReadable = $false
    $unknownDnsState.IPv4DnsReadError = 'query denied'
    $unknownDns = Test-POAdapterDnsEligibility -AdapterState $unknownDnsState
    Assert-POTest (-not $unknownDns.Eligible -and @($unknownDns.Reasons | Where-Object { $_ -match 'query denied' }).Count -gt 0) 'DNS preflight blocks when current IPv4 servers cannot be read'
    $managedDnsState = $eligibleDnsState.PSObject.Copy()
    $managedDnsState.DnsConfigState = 'POLICY-MANAGED'
    $managedDns = Test-POAdapterDnsEligibility -AdapterState $managedDnsState
    Assert-POTest (-not $managedDns.Eligible -and @($managedDns.Reasons | Where-Object { $_ -match 'policy' }).Count -gt 0) 'DNS preflight blocks policy-managed resolver state'

    $before = [pscustomobject]@{ CapturedAtUtc = 'before'; Metrics = [pscustomobject]@{ CpuUsagePercent = 4.5; RamAvailableGB = 5.0; MemoryCommitGB = $null; DiskPercentTime = 0; DiskBytesPerSecond = 0; DpcTimePercent = $null; InterruptTimePercent = $null } }
    $after = [pscustomobject]@{ CapturedAtUtc = 'after'; Metrics = [pscustomobject]@{ CpuUsagePercent = 3.5; RamAvailableGB = 4.0; MemoryCommitGB = 2.5; DiskPercentTime = 0; DiskBytesPerSecond = 0; DpcTimePercent = $null; InterruptTimePercent = $null } }
    $comparison = Compare-POBenchmarkSnapshots -Before $before -After $after
    $cpuDelta = @($comparison.Metrics | Where-Object { $_.Metric -eq 'CpuUsagePercent' })[0]
    $commitDelta = @($comparison.Metrics | Where-Object { $_.Metric -eq 'MemoryCommitGB' })[0]
    $diskDelta = @($comparison.Metrics | Where-Object { $_.Metric -eq 'DiskPercentTime' })[0]
    Assert-POTest ($cpuDelta.Delta -eq -1) 'Benchmark comparison computes observed deltas'
    Assert-POTest ($commitDelta.After -eq 'Unavailable') 'Missing metrics are not presented as measured values'
    Assert-POTest ($diskDelta.Delta -eq 0) 'Real zero counter samples are preserved'
    Assert-POTest ($comparison.GamingPerformanceScore -match 'NOT SCORED') 'No fabricated gaming score is emitted'
}
catch {
    Assert-POTest $false 'Pure validator/comparison tests' $_.Exception.Message
}

# Backup integrity and dry-run behavior.
try {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('PlatinumOptimizerTests_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $invalid = Test-POBackup -Path $tempRoot
    Assert-POTest (-not $invalid.Valid -and $invalid.Status -eq 'INVALID') 'Backup validator rejects a missing manifest'
    $validRoot = Join-Path $tempRoot 'valid-backup'
    $systemFolder = Join-Path $validRoot 'system'
    New-Item -ItemType Directory -Path $systemFolder -Force | Out-Null
    $sampleFile = Join-Path $systemFolder 'sample.json'
    Set-Content -LiteralPath $sampleFile -Value '{"sample":true}' -Encoding UTF8
    $sampleItem = Get-Item -LiteralPath $sampleFile
    $sampleHash = (Get-FileHash -LiteralPath $sampleFile -Algorithm SHA256).Hash
    $relativeSamplePath = [System.IO.Path]::Combine('system', 'sample.json')
    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1; id = 'valid-backup'; status = 'VALID'; modifiedSections = @(); changes = @(); restoreHistory = @()
        files = @([pscustomobject]@{ Path = $relativeSamplePath; Length = [long]$sampleItem.Length; SHA256 = $sampleHash })
    }
    Set-Content -LiteralPath (Join-Path $validRoot 'manifest.json') -Value ($manifest | ConvertTo-Json -Depth 6) -Encoding UTF8
    $validBackup = Test-POBackup -Path $validRoot
    Assert-POTest ($validBackup.Valid -and $validBackup.Status -eq 'VALID') 'Backup validator accepts matching manifest/checksum/length'
    $unlistedFile = Join-Path $validRoot 'unlisted.dat'
    Set-Content -LiteralPath $unlistedFile -Value 'unlisted' -Encoding UTF8
    $unlistedBackup = Test-POBackup -Path $validRoot
    Assert-POTest (-not $unlistedBackup.Valid -and @($unlistedBackup.Issues | Where-Object { $_ -match 'Unlisted file in backup' }).Count -gt 0) 'Backup validator rejects files omitted from the checksum inventory'
    Remove-Item -LiteralPath $unlistedFile -Force

    $missingFieldManifest = $manifest.PSObject.Copy()
    $missingFieldManifest.PSObject.Properties.Remove('restoreHistory')
    Set-Content -LiteralPath (Join-Path $validRoot 'manifest.json') -Value ($missingFieldManifest | ConvertTo-Json -Depth 6) -Encoding UTF8
    $missingFieldBackup = Test-POBackup -Path $validRoot
    Assert-POTest (-not $missingFieldBackup.Valid -and @($missingFieldBackup.Issues | Where-Object { $_ -match 'restoreHistory' }).Count -gt 0) 'Backup validator rejects a manifest missing a required ledger field'

    $idMismatchManifest = $manifest.PSObject.Copy()
    $idMismatchManifest.id = 'different-directory'
    Set-Content -LiteralPath (Join-Path $validRoot 'manifest.json') -Value ($idMismatchManifest | ConvertTo-Json -Depth 6) -Encoding UTF8
    $idMismatchBackup = Test-POBackup -Path $validRoot
    Assert-POTest (-not $idMismatchBackup.Valid -and @($idMismatchBackup.Issues | Where-Object { $_ -match 'does not match its directory' }).Count -gt 0) 'Backup validator rejects an ID/directory mismatch'

    $duplicateManifest = $manifest.PSObject.Copy()
    $duplicateManifest.files = @($manifest.files[0], $manifest.files[0])
    Set-Content -LiteralPath (Join-Path $validRoot 'manifest.json') -Value ($duplicateManifest | ConvertTo-Json -Depth 6) -Encoding UTF8
    $duplicateBackup = Test-POBackup -Path $validRoot
    Assert-POTest (-not $duplicateBackup.Valid -and @($duplicateBackup.Issues | Where-Object { $_ -match 'duplicate file path' }).Count -gt 0) 'Backup validator rejects duplicate file ledger entries'

    Set-Content -LiteralPath (Join-Path $validRoot 'manifest.json') -Value ($manifest | ConvertTo-Json -Depth 6) -Encoding UTF8
    Set-Content -LiteralPath $sampleFile -Value '{"sample":false}' -Encoding UTF8
    $corruptBackup = Test-POBackup -Path $validRoot
    Assert-POTest (-not $corruptBackup.Valid -and @($corruptBackup.Issues | Where-Object { $_ -match 'Checksum mismatch|Length mismatch' }).Count -gt 0) 'Backup validator rejects a changed snapshot file'
    $traversal = $manifest.PSObject.Copy()
    $traversal.files = @([pscustomobject]@{ Path = [System.IO.Path]::Combine('..', 'outside.json'); Length = 1; SHA256 = ('0' * 64) })
    Set-Content -LiteralPath (Join-Path $validRoot 'manifest.json') -Value ($traversal | ConvertTo-Json -Depth 6) -Encoding UTF8
    $traversalBackup = Test-POBackup -Path $validRoot
    Assert-POTest (-not $traversalBackup.Valid -and @($traversalBackup.Issues | Where-Object { $_ -match 'Invalid relative path' }).Count -gt 0) 'Backup validator rejects manifest path traversal'
    Remove-Item -LiteralPath $tempRoot -Recurse -Force

    if (Test-POIsWindows) {
        $beforeBackups = @(Get-POBackups).Count
        $windowPlans = @(Get-POPowerPlans)
        $activePlan = Get-POActivePowerPlanGuid
        $dryPlan = New-POProfilePlan -ProfileId 'gaming' -SystemSnapshot (Get-POSystemSnapshot) -PowerPlans $windowPlans -ActivePlanGuid $activePlan
        if ($dryPlan.Change) {
            $dryResult = Invoke-POProfilePlan -Plan $dryPlan -WhatIf
            $afterBackups = @(Get-POBackups).Count
            Assert-POTest ($dryResult.Status -eq 'SIMULATED') 'Profile -WhatIf returns simulation status'
            Assert-POTest ($beforeBackups -eq $afterBackups) 'Profile -WhatIf creates no backup or system change'
        }
        else { Skip-POTest 'Profile -WhatIf integration' 'No compatible plan change is available on this machine.' }
        $maxDryPlan = New-POProfilePlan -ProfileId 'max-performance' -SystemSnapshot (Get-POSystemSnapshot) -PowerPlans $windowPlans -ActivePlanGuid $activePlan
        if ($maxDryPlan.Change) {
            $maxDryResult = Invoke-POProfilePlan -Plan $maxDryPlan -WhatIf
            Assert-POTest ($maxDryResult.Status -eq 'SIMULATED') 'High-risk profile dry run does not require apply-only confirmation'
        }
        else { Skip-POTest 'Maximum Performance -WhatIf integration' 'No compatible performance plan is available on this machine.' }

        $eligibleAdapters = @(Get-PONetworkAdapters | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface -and $_.DhcpEnabled -and $_.IPv4DnsReadable -and $_.DnsConfigState -eq 'AUTOMATIC/DHCP' })
        if ($eligibleAdapters.Count -gt 0) {
            $testAdapter = $eligibleAdapters[0]
            $dnsBefore = Get-POCurrentAdapterDns -InterfaceIndex ([int]$testAdapter.InterfaceIndex)
            $dnsBeforeJson = ConvertTo-Json -InputObject @($dnsBefore.IPv4DnsServers) -Compress
            $expectedDnsServers = @($dnsBefore.IPv4DnsServers)
            $backupCountBeforeDnsWhatIf = @(Get-POBackups).Count
            $dnsDryRun = Set-PODnsProvider -InterfaceIndex ([int]$testAdapter.InterfaceIndex) -Provider 'Cloudflare' -ExpectedInterfaceGuid ([string]$dnsBefore.InterfaceGuid) -ExpectedIPv4DnsServers $expectedDnsServers -WhatIf
            $dnsAfter = Get-POCurrentAdapterDns -InterfaceIndex ([int]$testAdapter.InterfaceIndex)
            $dnsAfterJson = ConvertTo-Json -InputObject @($dnsAfter.IPv4DnsServers) -Compress
            $backupCountAfterDnsWhatIf = @(Get-POBackups).Count
            Assert-POTest ($dnsDryRun.Status -eq 'SIMULATED') 'DNS -WhatIf returns simulation status'
            Assert-POTest ($dnsBeforeJson -eq $dnsAfterJson -and $backupCountBeforeDnsWhatIf -eq $backupCountAfterDnsWhatIf) 'DNS -WhatIf changes no resolver or backup state'
        }
        else { Skip-POTest 'DNS -WhatIf integration' 'No connected physical adapter with confirmed DHCP and readable automatic DNS is available.' }

        # Exact registry type/value snapshot round-trip in an isolated HKCU test key.
        $testSubKey = 'Software\PlatinumOptimizerTests\' + [guid]::NewGuid().ToString('N')
        $absent = [pscustomobject]@{ Hive = 'CurrentUser'; SubKey = $testSubKey; ValueName = 'TestValue'; Exists = $false; Kind = $null; Data = $null }
        try {
            Invoke-POPrivateRegistrySetter -State ([pscustomobject]@{ Hive = 'CurrentUser'; SubKey = $testSubKey; ValueName = 'TestValue'; Exists = $true; Kind = 'DWord'; Data = 1234; Readable = $true })
            $captured = Get-PORegValueState -Hive CurrentUser -SubKey $testSubKey -ValueName 'TestValue'
            Assert-POTest ($captured.Readable -and $captured.Exists -and $captured.Kind -eq 'DWord' -and [int]$captured.Data -eq 1234) 'Registry snapshot reads an exact DWORD type/value'
            Invoke-POPrivateRegistrySetter -State ([pscustomobject]@{ Hive = 'CurrentUser'; SubKey = $testSubKey; ValueName = 'TestValue'; Exists = $false; Kind = $null; Data = $null; Readable = $true })
            $restoredAbsent = Get-PORegValueState -Hive CurrentUser -SubKey $testSubKey -ValueName 'TestValue'
            Assert-POTest (-not $restoredAbsent.Exists) 'Registry restore deletes a value that was absent before'
            $multi = [pscustomobject]@{ Hive = 'CurrentUser'; SubKey = $testSubKey; ValueName = 'Multi'; Exists = $true; Kind = 'MultiString'; Data = @('one','two'); Readable = $true }
            Invoke-POPrivateRegistrySetter -State $multi
            $multiCaptured = Get-PORegValueState -Hive CurrentUser -SubKey $testSubKey -ValueName 'Multi'
            Assert-POTest ($multiCaptured.Kind -eq 'MultiString' -and @($multiCaptured.Data).Count -eq 2) 'Registry snapshot preserves multi-string type/data'
        }
        finally {
            try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testSubKey, $false) } catch { }
        }
    }
    else {
        Skip-POTest 'Windows power-plan and registry integration' 'Windows PowerShell/CIM/registry are unavailable on this host.'
    }
}
catch {
    Assert-POTest $false 'Backup/dry-run/registry tests' $_.Exception.Message
}

# Platinum On Steroids extension tests: power presets, audio presets,
# display profiles, pure parsers, and the single-file release structure.
# These are pure logic/structure tests and run on any host.
try {
    $powerCatalog = Get-Content -LiteralPath (Join-Path $repoRoot 'src\data\power-settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-POTest ($powerCatalog.planName -eq 'Platinum On Steroids') 'Power catalog defines the exact Platinum On Steroids plan name'
    $guidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    $allGuids = @($powerCatalog.builtinSchemes.PSObject.Properties | ForEach-Object { [string]$_.Value })
    $allGuids += @($powerCatalog.subgroups.PSObject.Properties | ForEach-Object { [string]$_.Value })
    foreach ($setting in @($powerCatalog.settings)) {
        $allGuids += [string]$setting.guid
        if ($setting.PSObject.Properties['dcGuid'] -and $setting.dcGuid) { $allGuids += [string]$setting.dcGuid }
    }
    $badGuids = @($allGuids | Where-Object { $_ -notmatch $guidPattern })
    Assert-POTest ($badGuids.Count -eq 0) 'Power catalog uses only well-formed documented GUID strings' ($badGuids -join ', ')
    $presetIds = @($powerCatalog.presets | ForEach-Object { [string]$_.id })
    foreach ($requiredPreset in @('gaming', 'competitive', 'balanced', 'laptop')) {
        Assert-POTest ($presetIds -contains $requiredPreset) "Power preset exists: $requiredPreset"
    }
    $settingIds = @($powerCatalog.settings | ForEach-Object { [string]$_.id })
    $presetValidationIssues = @()
    foreach ($preset in @($powerCatalog.presets)) {
        $check = Test-POPowerPresetDefinition -Preset $preset -Catalog $powerCatalog
        if (-not $check.Valid) { $presetValidationIssues += $check.Issues }
        foreach ($sideName in @('ac', 'dc')) {
            $side = $preset.PSObject.Properties[$sideName]
            if ($null -eq $side -or $null -eq $side.Value) { continue }
            foreach ($property in $side.Value.PSObject.Properties) {
                if ($property.Name -notin $settingIds) { $presetValidationIssues += "$($preset.id).$sideName.$($property.Name) is not in the settings catalog" }
            }
        }
    }
    Assert-POTest ($presetValidationIssues.Count -eq 0) 'All power presets reference only documented settings inside documented ranges' ($presetValidationIssues -join '; ')
    $competitivePreset = @($powerCatalog.presets | Where-Object { $_.id -eq 'competitive' } | Select-Object -First 1)[0]
    Assert-POTest ([bool]$competitivePreset.requiresThermalConfirmation) 'Competitive preset requires a separate thermal/power confirmation'

    $listSample = @(
        'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced) *',
        'Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)',
        'Power Scheme GUID: E9A42B02-D5DF-448D-AA00-03F14749EB61  (Ultimate Performance)'
    )
    $parsedList = @(ConvertFrom-POPowerPlanListLines -Lines $listSample)
    Assert-POTest ($parsedList.Count -eq 3) 'powercfg /list parser finds every plan line'
    $activeParsed = @($parsedList | Where-Object { $_.IsActive })
    Assert-POTest ($activeParsed.Count -eq 1 -and $activeParsed[0].Guid -eq '381b4222-f694-41f0-9685-ff5bb260df2e') 'powercfg /list parser marks only the starred plan active'

    $querySample = @(
        'Power Scheme GUID: 11111111-2222-3333-4444-555555555555  (Platinum On Steroids)',
        '',
        'Subgroup GUID: 54533251-82be-4824-96c1-47b60b740d00  (Processor performance)',
        'GUID Alias: SUB_PROCESSOR',
        'Power Setting GUID: 893dee8e-2bef-41e0-89c6-b55d0929964c  (Minimum processor state)',
        'GUID Alias: PROCFLOOR',
        'Current AC Power Setting Index: 0x00000064',
        'Current DC Power Setting Index: 0x00000005',
        'Power Setting GUID: ea062031-0e34-4ff1-9b6d-eb1059334028',
        'Current AC Power Setting Index: 0x00000064'
    )
    $parsedQuery = @(ConvertFrom-POPowerQueryLines -Lines $querySample)
    Assert-POTest ($parsedQuery.Count -eq 2) 'powercfg /qh parser extracts setting records'
    $minState = @($parsedQuery | Where-Object { $_.SettingGuid -eq '893dee8e-2bef-41e0-89c6-b55d0929964c' } | Select-Object -First 1)[0]
    Assert-POTest ($minState.AcIndex -eq 100 -and $minState.DcIndex -eq 5) 'powercfg /qh parser decodes hex AC/DC indices'
    Assert-POTest ($minState.SubgroupGuid -eq '54533251-82be-4824-96c1-47b60b740d00') 'powercfg /qh parser tracks the owning subgroup'
}
catch {
    Assert-POTest $false 'Power module tests' $_.Exception.Message
}

try {
    $audioCatalog = Get-Content -LiteralPath (Join-Path $repoRoot 'src\data\audio-presets.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $audioPresetIds = @($audioCatalog.presets | ForEach-Object { [string]$_.id })
    foreach ($requiredAudio in @('competitive-fps', 'positional-audio', 'stereo-headphones', 'surround-spatial', 'music-general', 'microphone-voice-chat', 'restore-original')) {
        Assert-POTest ($audioPresetIds -contains $requiredAudio) "Audio preset exists: $requiredAudio"
    }
    $supportedIds = @($audioCatalog.supportedChanges | ForEach-Object { [string]$_.id })
    Assert-POTest ($supportedIds -contains 'communications-ducking') 'Audio catalog documents its supported automatic change'
    $duckingDefinition = @($audioCatalog.supportedChanges | Where-Object { $_.id -eq 'communications-ducking' } | Select-Object -First 1)[0]
    $duckingValues = @($duckingDefinition.documentedValues.PSObject.Properties | ForEach-Object { [int]$_.Name })
    $audioPresetIssues = @()
    foreach ($preset in @($audioCatalog.presets)) {
        $changes = $preset.PSObject.Properties['changes']
        if ($null -eq $changes -or $null -eq $changes.Value) { continue }
        foreach ($change in $changes.Value.PSObject.Properties) {
            if ($change.Name -notin $supportedIds) { $audioPresetIssues += "$($preset.id) references unsupported automatic change $($change.Name)"; continue }
            if ($change.Name -eq 'communications-ducking' -and [int]$change.Value -notin $duckingValues) { $audioPresetIssues += "$($preset.id) requests undocumented ducking value $($change.Value)" }
        }
        if (@($preset.whatChanges).Count -eq 0) { $audioPresetIssues += "$($preset.id) does not explain what it changes" }
    }
    Assert-POTest ($audioPresetIssues.Count -eq 0) 'Audio presets only touch documented values and explain themselves' ($audioPresetIssues -join '; ')
    Assert-POTest (ConvertTo-POAudioConnectionType -DeviceId 'USB\VID_046D&PID_0A5C' -ServiceOrClass $null -match 'USB') 'Audio connection inference recognises USB devices'
    Assert-POTest (ConvertTo-POAudioConnectionType -DeviceId 'BTHENUM\Dev_abc' -ServiceOrClass $null -match 'Bluetooth') 'Audio connection inference recognises Bluetooth devices'
    Assert-POTest (ConvertTo-POAudioConnectionType -DeviceId 'HDAUDIO\FUNC_01&VEN_10EC' -ServiceOrClass $null -match '3.5 mm|Analog') 'Audio connection inference maps HDAudio to analog'
    Assert-POTest (ConvertTo-POAudioConnectionType -DeviceId 'PCI\VEN_8086' -ServiceOrClass $null -match 'Unknown') 'Audio connection inference never fabricates an unknown type'
}
catch {
    Assert-POTest $false 'Audio module tests' $_.Exception.Message
}

try {
    $displayCatalog = Get-Content -LiteralPath (Join-Path $repoRoot 'src\data\display-profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $displayProfileIds = @($displayCatalog.profiles | ForEach-Object { [string]$_.id })
    foreach ($requiredDisplay in @('platinum-competitive', 'cs2-visibility', 'fortnite-visibility', 'rust-visibility', 'natural', 'movie-media', 'hdr-gaming', 'color-accurate', 'restore-display')) {
        Assert-POTest ($displayProfileIds -contains $requiredDisplay) "Display profile exists: $requiredDisplay"
    }
    $gammaMin = [double]$displayCatalog.safety.gammaMin
    $gammaMax = [double]$displayCatalog.safety.gammaMax
    Assert-POTest ($gammaMin -ge 0.85 -and $gammaMax -le 1.15) 'Display gamma safety bounds stay conservative'
    $displayIssues = @()
    foreach ($profile in @($displayCatalog.profiles)) {
        $gammaProperty = $profile.PSObject.Properties['gamma']
        if ($null -eq $gammaProperty -or $null -eq $gammaProperty.Value) { continue }
        $gammaText = [string]$gammaProperty.Value
        if ($gammaText -eq 'restore-captured') { continue }
        $gammaValue = [double]$gammaText
        if ($gammaValue -lt $gammaMin -or $gammaValue -gt $gammaMax) { $displayIssues += "$($profile.id) gamma $gammaValue is outside safety bounds" }
    }
    Assert-POTest ($displayIssues.Count -eq 0) 'Every display profile gamma stays inside the safety bounds' ($displayIssues -join '; ')
    Assert-POTest ([bool]$displayCatalog.safety.neverWriteGpuRegistry) 'Display catalog declares that GPU registry values are never written'

    $identity = Compute-POGammaRamp -Gamma 1.0
    Assert-POTest ([int]$identity.Red[0] -eq 0 -and [int]$identity.Red[255] -eq 65535) 'Gamma ramp at 1.0 starts at 0 and ends at 65535'
    $identityMid = [int]$identity.Red[128]
    Assert-POTest ([math]::Abs($identityMid - 32896) -le 256) 'Gamma ramp at 1.0 is (close to) the identity curve'
    $channelsIdentical = $true
    for ($i = 0; $i -lt 256; $i++) {
        if ([int]$identity.Red[$i] -ne [int]$identity.Green[$i] -or [int]$identity.Red[$i] -ne [int]$identity.Blue[$i]) { $channelsIdentical = $false; break }
    }
    Assert-POTest $channelsIdentical 'Gamma ramp is identical on all three channels (no tint / no green-shift path)'
    $clamped = Compute-POGammaRamp -Gamma 5.0
    Assert-POTest ([double]$clamped.Gamma -le $gammaMax) 'Gamma input is clamped to the documented safety maximum'
    $first = Compute-POGammaRamp -Gamma 1.08
    $second = Compute-POGammaRamp -Gamma 1.08
    Assert-POTest ((ConvertTo-Json $first.Red -Compress) -eq (ConvertTo-Json $second.Red -Compress)) 'Gamma ramps are absolute: recomputing a profile never accumulates'
    $monotonic = $true
    for ($i = 1; $i -lt 256; $i++) { if ([int]$first.Red[$i] -lt [int]$first.Red[$i - 1]) { $monotonic = $false; break } }
    Assert-POTest $monotonic 'Gamma ramp stays monotonic (no banding/inversion path)'

    $modes = @(
        [pscustomobject]@{ Width = 1920; Height = 1080; Bpp = 32; Frequency = 60 },
        [pscustomobject]@{ Width = 1920; Height = 1080; Bpp = 32; Frequency = 144 },
        [pscustomobject]@{ Width = 1920; Height = 1080; Bpp = 32; Frequency = 165 },
        [pscustomobject]@{ Width = 2560; Height = 1440; Bpp = 32; Frequency = 240 }
    )
    $best = Select-POHighestRefresh -Modes $modes -Width 1920 -Height 1080 -CurrentFrequency 60
    Assert-POTest ($null -ne $best -and [int]$best.Frequency -eq 165) 'Refresh selector picks the highest Hz at the current resolution'
    $noUpgrade = Select-POHighestRefresh -Modes $modes -Width 1920 -Height 1080 -CurrentFrequency 165
    Assert-POTest ($null -eq $noUpgrade) 'Refresh selector proposes no change when already at the highest Hz'
}
catch {
    Assert-POTest $false 'Display module tests' $_.Exception.Message
}

try {
    # Change ledger accepts the new audio/display sections.
    $ledgerRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('PlatinumOptimizerLedger_' + [guid]::NewGuid().ToString('N'))
    $ledgerBackup = Join-Path $ledgerRoot 'ledger-backup'
    New-Item -ItemType Directory -Path $ledgerBackup -Force | Out-Null
    $ledgerManifest = [pscustomobject][ordered]@{
        schemaVersion = 1; id = 'ledger-backup'; status = 'VALID'; modifiedSections = @(); changes = @(); restoreHistory = @(); files = @()
    }
    Set-Content -LiteralPath (Join-Path $ledgerBackup 'manifest.json') -Value ($ledgerManifest | ConvertTo-Json -Depth 6) -Encoding UTF8
    Add-POBackupChange -BackupPath $ledgerBackup -Section audio -Change ([pscustomobject][ordered]@{ section = 'audio'; id = 'audio-preset'; status = 'APPLYING' })
    Add-POBackupChange -BackupPath $ledgerBackup -Section display -Change ([pscustomobject][ordered]@{ section = 'display'; id = 'display-profile'; status = 'APPLYING' })
    Update-POBackupChangeStatus -BackupPath $ledgerBackup -Section audio -Status 'APPLIED_VERIFIED' -Message 'test'
    $ledgerAfter = Get-Content -LiteralPath (Join-Path $ledgerBackup 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-POTest (@($ledgerAfter.modifiedSections) -contains 'audio' -and @($ledgerAfter.modifiedSections) -contains 'display') 'Backup ledger accepts audio and display sections'
    $audioChangeAfter = @($ledgerAfter.changes | Where-Object { $_.section -eq 'audio' } | Select-Object -First 1)
    Assert-POTest ($audioChangeAfter.Count -gt 0 -and $audioChangeAfter[0].status -eq 'APPLIED_VERIFIED') 'Audio change status is updated in the ledger'
    Remove-Item -LiteralPath $ledgerRoot -Recurse -Force
}
catch {
    Assert-POTest $false 'Ledger extension tests' $_.Exception.Message
}

try {
    # Single-file release structure (CMD engine v2.0): the BAT is pure batch
    # up to the payload marker; cmd exits before the payload, and PowerShell
    # extracts the byte-exact embedded sources at runtime.
    $batPath = Join-Path $repoRoot 'PlatinumOptimizer.bat'
    Assert-POTest (Test-Path -LiteralPath $batPath -PathType Leaf) 'Single-file release PlatinumOptimizer.bat exists'
    $batText = [System.IO.File]::ReadAllText($batPath, [System.Text.Encoding]::UTF8)
    $markerCount = ([regex]::Matches($batText, [regex]::Escape('#>PO_PAYLOAD'))).Count
    Assert-POTest ($markerCount -eq 1) 'Release file contains exactly one payload marker'
    $batchSection = $batText.Split('#>PO_PAYLOAD')[0]
    Assert-POTest ($batchSection.Split("`n")[0].Trim() -eq '@echo off') 'Release batch section starts with @echo off (cmd never parses the payload)'
    $nonAscii = @([char[]]$batchSection.ToCharArray() | Where-Object { [int]$_ -gt 127 })
    Assert-POTest ($nonAscii.Count -eq 0) 'Release batch section is pure ASCII (any cmd code page can parse it)'
    Assert-POTest ($batchSection -match '(?i)powershell\.exe .*-ExecutionPolicy Bypass') 'Release launcher uses Bypass Windows PowerShell'
    Assert-POTest ($batchSection -notmatch '(?i)-STA') 'Release launcher no longer requires STA (no WPF UI)'
    Assert-POTest ($batchSection -match '(?i)where powershell\.exe') 'Release launcher fails clearly when PowerShell is missing'
    Assert-POTest ($batchSection -match '(?i)net session') 'Release launcher detects administrator privileges'
    Assert-POTest ($batchSection -match '(?i)-Verb RunAs') 'Release launcher self-elevates through the normal Windows UAC mechanism'
    Assert-POTest ($batchSection -match '(?i)pause >nul') 'Release console stays open until the user presses a key'
    Assert-POTest ($batchSection -match '(?i)exit /b 3' -and $batchSection -match '(?i)exit /b 4') 'Release launcher returns distinct exit codes for missing PowerShell and declined elevation'
    foreach ($relative in @('src\PlatinumOptimizer.ps1', 'src\core\PlatinumOptimizer.Core.psm1', 'src\core\PlatinumOptimizer.Power.psm1', 'src\core\PlatinumOptimizer.Audio.psm1', 'src\core\PlatinumOptimizer.Display.psm1', 'src\core\PlatinumOptimizer.Network.psm1', 'src\core\PlatinumOptimizer.Gaming.psm1', 'src\core\PlatinumOptimizer.Engine.psm1', 'tests\Run-Tests.ps1')) {
        $sourcePath = Join-Path $repoRoot $relative
        $expectedB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($sourcePath))
        Assert-POTest ($batText.Contains("Expand-POEmbeddedFile -RelativePath '$relative' -EncodedContent '$expectedB64'")) "Release embeds $relative byte-exact"
    }
    Assert-POTest ($batText.Contains('src\data\power-settings.json')) 'Release embeds the Platinum power preset catalog'
    Assert-POTest ($batText.Contains('src\data\audio-presets.json')) 'Release embeds the audio preset catalog'
    Assert-POTest ($batText.Contains('src\data\display-profiles.json')) 'Release embeds the display profile catalog'
    Assert-POTest (-not $batText.Contains('MainWindow.xaml')) 'Release contains no graphical UI file'
}
catch {
    Assert-POTest $false 'Single-file release tests' $_.Exception.Message
}

try {
    # UI removal: the graphical interface and every WPF execution path are gone.
    Assert-POTest (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'src\ui') -PathType Container)) 'The src\ui graphical interface directory no longer exists'
    $xamlFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter '*.xaml' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.git\\' })
    Assert-POTest ($xamlFiles.Count -eq 0) 'No XAML file remains in the repository'
    $entryText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'src\PlatinumOptimizer.ps1'), [System.Text.Encoding]::UTF8)
    foreach ($wpfMarker in @('PresentationFramework', 'XamlReader', 'ShowDialog', 'MainWindow.xaml', 'System.Windows.Forms')) {
        Assert-POTest (-not $entryText.Contains($wpfMarker)) "Engine entry point contains no WPF/WinForms reference ($wpfMarker)"
    }
    $cmdText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'Platinum+Optimizer.V9.3.FREE.cmd'), [System.Text.Encoding]::UTF8)
    Assert-POTest ($cmdText -match '(?i)net session' -and $cmdText -match '(?i)-Verb RunAs') 'Repository launcher detects elevation and self-elevates via UAC'
    Assert-POTest ($cmdText -notmatch '(?i)MainWindow|xaml') 'Repository launcher never starts the old graphical UI'
    Assert-POTest ($cmdText -match '(?i)src\\PlatinumOptimizer\.ps1') 'Repository launcher runs the console engine from the repository layout'
}
catch {
    Assert-POTest $false 'UI removal tests' $_.Exception.Message
}

try {
    # CMD engine v2.0: pure pipeline logic that must never depend on live hardware.
    Assert-POTest ((Get-POEngineVersion) -match '^\d+\.\d+\.\d+$') 'Engine reports a semantic version'
    Assert-POTest ((Get-POConsolePrefix -Level 'INFO') -eq '[INFO]' -and (Get-POConsolePrefix -Level 'FAIL') -eq '[FAIL]') 'Console status prefixes use the documented [LEVEL] form'

    $desktop = New-TestSystemSnapshot -Family 'Windows 11' -Supported $true -IsLaptop $false -PowerSource 'AC'
    $desktopPreset = Select-POAutoPowerPreset -Snapshot $desktop
    Assert-POTest ($desktopPreset.Action -eq 'apply' -and $desktopPreset.PresetId -eq 'gaming') 'Automatic preset selects Gaming for a supported desktop'
    $laptopAc = New-TestSystemSnapshot -Family 'Windows 11' -Supported $true -IsLaptop $true -PowerSource 'AC'
    $laptopPreset = Select-POAutoPowerPreset -Snapshot $laptopAc
    Assert-POTest ($laptopPreset.Action -eq 'apply' -and $laptopPreset.PresetId -eq 'laptop') 'Automatic preset selects the capped Laptop preset on AC'
    $laptopBattery = New-TestSystemSnapshot -Family 'Windows 11' -Supported $true -IsLaptop $true -PowerSource 'Battery'
    $batteryPreset = Select-POAutoPowerPreset -Snapshot $laptopBattery
    Assert-POTest ($batteryPreset.Action -eq 'skip' -and $batteryPreset.Reason -match '(?i)battery') 'Automatic run never applies a performance plan on battery'
    $unknownDevice = New-TestSystemSnapshot -Family 'Windows 10' -Supported $true -IsLaptop $false -PowerSource 'Unknown'
    $unknownDevice.Device.IsLaptop = $null
    $unknownPreset = Select-POAutoPowerPreset -Snapshot $unknownDevice
    Assert-POTest ($unknownPreset.Action -eq 'skip') 'Automatic run skips the plan change when the form factor is unknown'
    $unsupportedOs = New-TestSystemSnapshot -Family 'Unsupported' -Supported $false -IsLaptop $false -PowerSource 'AC'
    Assert-POTest ((Select-POAutoPowerPreset -Snapshot $unsupportedOs).Action -eq 'skip') 'Unsupported Windows receives no automatic plan change'

    $mixedResults = @(
        (New-POResultRecord -Stage 'Power' -Id 'a' -Status 'APPLIED_VERIFIED' -Message 'applied'),
        (New-POResultRecord -Stage 'Gaming' -Id 'b' -Status 'ALREADY_OPTIMIZED' -Message 'already'),
        (New-POResultRecord -Stage 'Network' -Id 'c' -Status 'SKIPPED' -Message 'skipped'),
        (New-POResultRecord -Stage 'Network' -Id 'd' -Status 'FAILED' -Message 'failed'),
        (New-POResultRecord -Stage 'Gaming' -Id 'e' -Status 'UNVERIFIED' -Message 'unverified'),
        (New-POResultRecord -Stage 'Gaming' -Id 'f' -Status 'APPLIED_VERIFIED' -Message 'needs reboot' -RequiresReboot $true),
        (New-POResultRecord -Stage 'Storage' -Id 'g' -Status 'INFO' -Message 'info')
    )
    $summary = Get-POReportSummary -Results $mixedResults
    Assert-POTest ($summary.Applied -eq 2 -and $summary.AlreadyOptimized -eq 1 -and $summary.Skipped -eq 1 -and $summary.Failed -eq 1 -and $summary.Unverified -eq 1) 'Report summary counts each status exactly as recorded'
    Assert-POTest ($summary.RebootRecommended) 'Report flags a reboot only when an applied change requires one'
    Assert-POTest (@($summary.FailedIds) -contains 'Network/d') 'Report names failed operations explicitly'
    $cleanSummary = Get-POReportSummary -Results @((New-POResultRecord -Stage 'Power' -Id 'x' -Status 'INFO' -Message 'read-only'))
    Assert-POTest (-not $cleanSummary.RebootRecommended -and $cleanSummary.Failed -eq 0) 'A read-only run never claims failures or reboots'

    $backupChoices = @(
        [pscustomobject]@{ Id = 'Backup_A'; Path = 'C:\pd\Backup_A'; Status = 'VALID'; ChangeCount = 2; CreatedAt = '2026-10-01 10:00:00 +02:00'; Changes = 'x'; Issues = @() },
        [pscustomobject]@{ Id = 'Backup_B'; Path = 'C:\pd\Backup_B'; Status = 'VALID'; ChangeCount = 1; CreatedAt = '2026-10-05 10:00:00 +02:00'; Changes = 'y'; Issues = @() },
        [pscustomobject]@{ Id = 'Backup_C'; Path = 'C:\pd\Backup_C'; Status = 'INVALID'; ChangeCount = 3; CreatedAt = '2026-10-09 10:00:00 +02:00'; Changes = 'z'; Issues = @('checksum mismatch') }
    )
    $latest = Select-PORestoreBackup -Backups $backupChoices -BackupId $null
    Assert-POTest ($latest.Selected -and $latest.Selected.Id -eq 'Backup_B') 'Restore mode selects the newest VALID backup with recorded changes'
    $explicit = Select-PORestoreBackup -Backups $backupChoices -BackupId 'Backup_A'
    Assert-POTest ($explicit.Selected -and $explicit.Selected.Id -eq 'Backup_A') 'Restore mode honors an explicit backup id'
    $invalidChoice = Select-PORestoreBackup -Backups $backupChoices -BackupId 'Backup_C'
    Assert-POTest ($null -eq $invalidChoice.Selected -and $invalidChoice.Reason -match '(?i)validation') 'Restore mode refuses an INVALID backup'
    $missingChoice = Select-PORestoreBackup -Backups $backupChoices -BackupId 'Backup_ZZZ'
    Assert-POTest ($null -eq $missingChoice.Selected) 'Restore mode reports a missing backup id clearly'
    $emptyChoice = Select-PORestoreBackup -Backups @() -BackupId $null
    Assert-POTest ($null -eq $emptyChoice.Selected -and $emptyChoice.Reason -match '(?i)no platinum optimizer backup') 'Restore mode explains an empty backup inventory'

    $searchRoots = @(Get-POBackupSearchRoots)
    Assert-POTest ($searchRoots.Count -ge 1) 'Backup search roots always include at least the local root'
    Assert-POTest (@($searchRoots | Where-Object { $_ -match '(?i)Backups$' }).Count -eq $searchRoots.Count) 'Every backup search root is a Backups directory'
}
catch {
    Assert-POTest $false 'CMD engine pipeline tests' $_.Exception.Message
}

try {
    # Network module: parse-first, act-only-on-deviation, verify, restore.
    $netshSample = @(
        'Querying active global state...',
        '---------------------------------------------',
        'Receive-Side Scaling State          : enabled',
        'Receive Window Auto-Tuning Level    : normal',
        'Add-On Congestion Control Provider  : default',
        'ECN Capability                      : disabled',
        'TCP Timestamps                      : disabled',
        'Receive Segment Coalescing State    : enabled',
        'Initial RTO (ms)                    : 1000',
        'Non Sack Rtt Resiliency             : disabled',
        'Max SYN Retransmissions             : 2'
    )
    $parsedTcp = ConvertFrom-PONetshTcpGlobalLines -Lines $netshSample
    Assert-POTest ($parsedTcp.Available) 'netsh TCP parser recognises documented global-state output'
    Assert-POTest ($parsedTcp.AutotuningLevel -eq 'normal' -and $parsedTcp.RssState -eq 'enabled') 'netsh TCP parser extracts autotuning and RSS values'
    Assert-POTest ($parsedTcp.EcnCapability -eq 'disabled' -and $parsedTcp.Timestamps -eq 'disabled' -and $parsedTcp.CongestionProvider -eq 'default') 'netsh TCP parser extracts ECN, timestamps, and congestion provider'
    Assert-POTest ($parsedTcp.InitialRtoMilliseconds -eq '1000') 'netsh TCP parser extracts numeric fields as text'
    $garbageParsed = ConvertFrom-PONetshTcpGlobalLines -Lines @('some localized text', 'another line')
    Assert-POTest (-not $garbageParsed.Available) 'netsh TCP parser reports unrecognizable (localized) output as unavailable instead of guessing'

    $defaultState = [pscustomobject]@{
        Available = $true; Source = 'cim'; Error = $null
        AutotuningLevel = 'Normal'; AutotuningLevelEffective = 'Normal'; RssState = 'Enabled'
        EcnCapability = 'Disabled'; Timestamps = 'Disabled'; CongestionProvider = 'CUBIC'
        RscState = 'Enabled on 1 adapter(s)'; InitialRtoMilliseconds = '1000'; MaxSynRetransmissions = '2'; NonSackRttResiliency = 'Disabled'
    }
    $defaultPlan = Get-PONetworkOptimizationPlan -TcpState $defaultState -LogicalProcessors 8
    Assert-POTest (@($defaultPlan.Actions).Count -eq 0) 'A system at documented Windows defaults receives no TCP change'
    Assert-POTest (@($defaultPlan.ReportOnly | Where-Object { $_.Id -eq 'tcp-ecn' }).Count -eq 1) 'ECN stays report-only on a default system'

    $degradedState = $defaultState.PSObject.Copy()
    $degradedState.AutotuningLevel = 'Disabled'; $degradedState.AutotuningLevelEffective = 'Disabled'; $degradedState.RssState = 'Disabled'
    $degradedPlan = Get-PONetworkOptimizationPlan -TcpState $degradedState -LogicalProcessors 8
    $degradedActions = @($degradedPlan.Actions)
    Assert-POTest ($degradedActions.Count -eq 2) 'Disabled autotuning and disabled RSS on a multi-core system each produce exactly one corrective action'
    $autotuningAction = @($degradedActions | Where-Object { $_.Id -eq 'tcp-autotuning' })[0]
    Assert-POTest ($autotuningAction.Target -eq 'normal' -and (@($autotuningAction.Command) -join ' ') -match 'autotuninglevel=normal') 'The autotuning correction targets the documented Windows default (normal)'
    $ecnActions = @($degradedPlan.Actions | Where-Object { $_.Id -like '*ecn*' -or $_.Id -like '*timestamp*' -or $_.Id -like '*rsc*' -or $_.Id -like '*congestion*' })
    Assert-POTest ($ecnActions.Count -eq 0) 'ECN, timestamps, RSC, and the congestion provider are never changed automatically'

    $singleCorePlan = Get-PONetworkOptimizationPlan -TcpState $degradedState -LogicalProcessors 1
    Assert-POTest (@($singleCorePlan.Actions | Where-Object { $_.Id -eq 'tcp-rss' }).Count -eq 0) 'RSS is not forced on a single-logical-processor system'

    $unavailableState = [pscustomobject]@{
        Available = $false; Source = 'none'; Error = 'query failed'
        AutotuningLevel = $null; AutotuningLevelEffective = $null; RssState = $null
        EcnCapability = $null; Timestamps = $null; CongestionProvider = $null
        RscState = $null; InitialRtoMilliseconds = $null; MaxSynRetransmissions = $null; NonSackRttResiliency = $null
    }
    $unavailablePlan = Get-PONetworkOptimizationPlan -TcpState $unavailableState -LogicalProcessors 8
    Assert-POTest (@($unavailablePlan.Actions).Count -eq 0 -and @($unavailablePlan.Skipped).Count -eq 1) 'Unreadable TCP state leads to a documented skip, never a blind change'
    Assert-POTest (@(Get-PONetworkReportNotes | Where-Object { $_ -match '(?i)ISP' }).Count -gt 0) 'The report explains that ping also depends on ISP, routing, and servers'
}
catch {
    Assert-POTest $false 'Network module tests' $_.Exception.Message
}

try {
    # Gaming module: allowlisted, reversible registry targets only.
    $targets = @(Get-POGamingSettingTargets)
    Assert-POTest ($targets.Count -eq 4) 'Exactly four gaming registry targets are defined'
    $allowlist = @(
        'Software\Microsoft\GameBar|AutoGameModeEnabled',
        'Software\Microsoft\GameBar|AllowAutoGameMode',
        'System\GameConfigStore|GameDVR_Enabled',
        'Software\Microsoft\Windows\CurrentVersion\GameDVR|AppCaptureEnabled'
    )
    $outsideAllowlist = @()
    foreach ($target in $targets) {
        if ($target.Hive -ne 'CurrentUser') { $outsideAllowlist += "$($target.Id): hive is not CurrentUser" }
        if ("$($target.SubKey)|$($target.ValueName)" -notin $allowlist) { $outsideAllowlist += "$($target.Id): key is not on the Core restore allowlist" }
    }
    Assert-POTest ($outsideAllowlist.Count -eq 0) 'Every gaming target stays inside the HKCU restore allowlist' ($outsideAllowlist -join '; ')
    $gameMode = @($targets | Where-Object { $_.ValueName -eq 'AutoGameModeEnabled' })[0]
    Assert-POTest ([int]$gameMode.DesiredValue -eq 1) 'Game Mode is enabled, not disabled'
    $dvr = @($targets | Where-Object { $_.ValueName -eq 'GameDVR_Enabled' })[0]
    Assert-POTest ([int]$dvr.DesiredValue -eq 0 -and [bool]$dvr.RequiresSignOut) 'Background Game DVR is disabled and flagged as needing sign-out/reboot to fully apply'
    $coreText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'src\core\PlatinumOptimizer.Core.psm1'), [System.Text.Encoding]::UTF8)
    foreach ($entry in $allowlist) {
        $parts = $entry.Split('|')
        Assert-POTest ($coreText.Contains($parts[0]) -and $coreText.Contains($parts[1])) "Core backup/restore allowlist covers $($parts[1])"
    }
    Assert-POTest (-not ($coreText -match "(?i)Set-Service|Stop-Service|sc config|sc stop")) 'Core never changes or stops Windows services'
    $gamingText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'src\core\PlatinumOptimizer.Gaming.psm1'), [System.Text.Encoding]::UTF8)
    Assert-POTest ($gamingText -notmatch '(?i)Stop-Process|taskkill') 'The gaming module never terminates processes'
}
catch {
    Assert-POTest $false 'Gaming module tests' $_.Exception.Message
}

try {
    # Add-POBackupFile keeps the checksum ledger valid, and targeted status
    # updates touch only the addressed change record.
    $fileRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('PlatinumOptimizerFileLedger_' + [guid]::NewGuid().ToString('N'))
    $fileBackup = Join-Path $fileRoot 'engine-backup'
    New-Item -ItemType Directory -Path (Join-Path $fileBackup 'network') -Force | Out-Null
    $seedManifest = [pscustomobject][ordered]@{
        schemaVersion = 1; id = 'engine-backup'; status = 'VALID'; modifiedSections = @(); changes = @(); restoreHistory = @(); files = @()
    }
    Set-Content -LiteralPath (Join-Path $fileBackup 'manifest.json') -Value ($seedManifest | ConvertTo-Json -Depth 6) -Encoding UTF8
    $emptyValidation = Test-POBackup -Path $fileBackup
    Assert-POTest (-not $emptyValidation.Valid) 'Backup validator rejects an empty file inventory before the first snapshot'
    $added = Add-POBackupFile -BackupPath $fileBackup -RelativePath 'network\tcp-global-before.json' -Content '{"AutotuningLevel":"normal"}'
    $afterAdd = Test-POBackup -Path $fileBackup
    Assert-POTest ($afterAdd.Valid) 'Add-POBackupFile registers the new file so checksum validation still passes'
    Assert-POTest ($added.SHA256 -match '^[A-F0-9]{64}$') 'Add-POBackupFile records a SHA-256 checksum'
    $traversalRejected = $false
    try { [void](Add-POBackupFile -BackupPath $fileBackup -RelativePath '..\escape.json' -Content 'x') } catch { $traversalRejected = $true }
    Assert-POTest $traversalRejected 'Add-POBackupFile rejects paths outside the backup directory'

    Add-POBackupChange -BackupPath $fileBackup -Section registry -Change ([pscustomobject][ordered]@{ section = 'registry'; id = 'game-mode-auto'; status = 'APPLYING' })
    Add-POBackupChange -BackupPath $fileBackup -Section registry -Change ([pscustomobject][ordered]@{ section = 'registry'; id = 'game-dvr-enabled'; status = 'APPLYING' })
    Update-POBackupChangeStatus -BackupPath $fileBackup -Section registry -ChangeId 'game-mode-auto' -Status 'APPLIED_VERIFIED' -Message 'first value verified'
    $fileManifest = Get-Content -LiteralPath (Join-Path $fileBackup 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $firstChange = @($fileManifest.changes | Where-Object { $_.id -eq 'game-mode-auto' })[0]
    $secondChange = @($fileManifest.changes | Where-Object { $_.id -eq 'game-dvr-enabled' })[0]
    Assert-POTest ($firstChange.status -eq 'APPLIED_VERIFIED') 'Targeted status update reaches the addressed registry change'
    Assert-POTest ($secondChange.status -eq 'APPLYING') 'Targeted status update leaves other changes untouched'
    $badIdRejected = $false
    try { Update-POBackupChangeStatus -BackupPath $fileBackup -Section registry -ChangeId 'does-not-exist' -Status 'APPLIED_VERIFIED' } catch { $badIdRejected = $true }
    Assert-POTest $badIdRejected 'A status update for an unknown change id is rejected'
    Remove-Item -LiteralPath $fileRoot -Recurse -Force
}
catch {
    Assert-POTest $false 'Backup file ledger tests' $_.Exception.Message
}

Write-Host ''
Write-Host ("Passed: {0}  Failed: {1}  Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped) -ForegroundColor Cyan
if ($script:FailureMessages.Count -gt 0) {
    foreach ($failure in $script:FailureMessages) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
exit 0
