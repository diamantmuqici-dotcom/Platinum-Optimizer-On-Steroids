#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src\core\PlatinumOptimizer.Core.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
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

Write-Host ''
Write-Host ("Passed: {0}  Failed: {1}  Skipped: {2}" -f $script:Passed, $script:Failed, $script:Skipped) -ForegroundColor Cyan
if ($script:FailureMessages.Count -gt 0) {
    foreach ($failure in $script:FailureMessages) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
exit 0
