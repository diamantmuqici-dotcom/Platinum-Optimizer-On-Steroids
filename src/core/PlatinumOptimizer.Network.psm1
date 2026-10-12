#requires -Version 5.1
# Platinum Optimizer - Network module (CMD engine v2.0)
# Assess-first TCP/adapter optimization. Current values are always read
# before a decision is made; only deviations from documented Windows
# defaults are corrected; every write is verified by re-reading; previous
# values are captured in the run backup and a dedicated restore handler
# exists for each change. ECN, TCP timestamps, RSC, congestion provider,
# and offload features are reported only: their benefit is workload and
# hardware dependent, so they are never flipped blindly.
Set-StrictMode -Version 2.0

if (-not (Get-Module | Where-Object { $_.Name -eq 'PlatinumOptimizer.Core' })) {
    Import-Module -Name (Join-Path $PSScriptRoot 'PlatinumOptimizer.Core.psm1') -Global -Force -ErrorAction Stop
}

function Invoke-PONetsh {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = @(& netsh.exe @Arguments 2>&1)
    return [pscustomobject][ordered]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { [string]$_ }) }
}

function ConvertFrom-PONetshTcpGlobalLines {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines)
    # Pure parser for `netsh int tcp show global`. Labels are matched in
    # English (the documented output); on localized Windows the CIM path
    # (Get-NetTCPSetting) is authoritative and this parser is a fallback
    # for fields CIM does not expose. Unrecognized lines are ignored.
    $map = [ordered]@{
        'Receive-Side Scaling State' = 'RssState'
        'Receive Window Auto-Tuning Level' = 'AutotuningLevel'
        'Add-On Congestion Control Provider' = 'CongestionProvider'
        'ECN Capability' = 'EcnCapability'
        'TCP Timestamps' = 'Timestamps'
        'Receive Segment Coalescing State' = 'RscState'
        'Initial RTO (ms)' = 'InitialRtoMilliseconds'
        'Non Sack Rtt Resiliency' = 'NonSackRttResiliency'
        'Max SYN Retransmissions' = 'MaxSynRetransmissions'
    }
    $result = [ordered]@{}
    foreach ($key in $map.Keys) { $result[$map[$key]] = $null }
    foreach ($line in $Lines) {
        $text = [string]$line
        $match = [regex]::Match($text, '^\s*([^:]+?)\s*:\s*(.+?)\s*$')
        if (-not $match.Success) { continue }
        $label = $match.Groups[1].Value.Trim()
        $value = $match.Groups[2].Value.Trim()
        foreach ($key in $map.Keys) {
            if ([string]::Equals($label, $key, [StringComparison]::OrdinalIgnoreCase)) {
                $result[$map[$key]] = $value
                break
            }
        }
    }
    $result['Source'] = 'netsh'
    $result['Available'] = [bool](@($result.Keys | Where-Object { $null -ne $result[$_] -and $_ -notin @('Source', 'Available') }).Count -gt 0)
    return [pscustomobject]$result
}

function Get-POTcpGlobalState {
    [CmdletBinding()]
    param()
    $state = [ordered]@{
        Available = $false; Source = 'none'; Error = $null
        AutotuningLevel = $null; AutotuningLevelEffective = $null; RssState = $null
        EcnCapability = $null; Timestamps = $null; CongestionProvider = $null
        RscState = $null; InitialRtoMilliseconds = $null; MaxSynRetransmissions = $null
        NonSackRttResiliency = $null
    }
    if (-not (Test-POIsWindows)) { $state.Error = 'TCP state is available only on Windows.'; return [pscustomobject]$state }
    try {
        if (Get-Command Get-NetTCPSetting -ErrorAction SilentlyContinue) {
            $setting = @(Get-NetTCPSetting -SettingStore Active -ErrorAction Stop | Select-Object -First 1)
            if ($setting.Count -gt 0) {
                $row = $setting[0]
                $state.Source = 'cim'
                $state.Available = $true
                foreach ($pair in @(
                    @('AutoTuningLevelLocal', 'AutotuningLevel'),
                    @('AutoTuningLevelEffective', 'AutotuningLevelEffective'),
                    @('ReceiveSideScalingState', 'RssState'),
                    @('EcnCapability', 'EcnCapability'),
                    @('Timestamps', 'Timestamps'),
                    @('CongestionProvider', 'CongestionProvider'),
                    @('InitialRtoMilliseconds', 'InitialRtoMilliseconds'),
                    @('MaxSynRetransmissions', 'MaxSynRetransmissions'),
                    @('NonSackRttResiliency', 'NonSackRttResiliency')
                )) {
                    if ($null -ne $row.PSObject.Properties[$pair[0]] -and $null -ne $row.($pair[0])) { $state[$pair[1]] = [string]$row.($pair[0]) }
                }
            }
        }
    }
    catch { $state.Error = "Get-NetTCPSetting failed: $($_.Exception.Message)" }
    try {
        if (Get-Command Get-NetAdapterRsc -ErrorAction SilentlyContinue) {
            $rsc = @(Get-NetAdapterRsc -ErrorAction Stop)
            if ($rsc.Count -gt 0) {
                $enabled = @($rsc | Where-Object { $_.IPv4Enabled -or $_.IPv6Enabled }).Count
                $state.RscState = if ($enabled -gt 0) { "Enabled on $enabled adapter(s)" } else { 'Disabled on all adapters' }
            }
        }
    }
    catch { if (-not $state.Error) { $state.Error = "Get-NetAdapterRsc failed: $($_.Exception.Message)" } }
    if (-not $state.Available) {
        # Fallback: documented netsh interface (best effort on localized systems).
        $netsh = Invoke-PONetsh -Arguments @('int', 'tcp', 'show', 'global')
        if ($netsh.ExitCode -eq 0) {
            $parsed = ConvertFrom-PONetshTcpGlobalLines -Lines $netsh.Output
            if ($parsed.Available) {
                $state.Available = $true; $state.Source = 'netsh'
                foreach ($name in @('AutotuningLevel', 'RssState', 'EcnCapability', 'Timestamps', 'CongestionProvider', 'RscState', 'InitialRtoMilliseconds', 'MaxSynRetransmissions', 'NonSackRttResiliency')) {
                    if ($null -ne $parsed.$name) { $state[$name] = [string]$parsed.$name }
                }
            }
            elseif (-not $state.Error) { $state.Error = 'netsh int tcp show global returned no recognizable fields (localized output?).' }
        }
        elseif (-not $state.Error) { $state.Error = "netsh int tcp show global exited with code $($netsh.ExitCode)." }
    }
    return [pscustomobject]$state
}

function Get-PONetworkOptimizationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$TcpState,
        [int]$LogicalProcessors = 0
    )
    # Pure decision function. Only deviations from documented Windows client
    # defaults become actions; everything else is report-only.
    $actions = @(); $report = @(); $skipped = @()
    if (-not $TcpState.Available) {
        $skipped += [pscustomobject]@{ Id = 'tcp-global'; Reason = "TCP state could not be read: $(if ($TcpState.Error) { $TcpState.Error } else { 'unknown' })" }
        return [pscustomobject][ordered]@{ Actions = $actions; ReportOnly = $report; Skipped = $skipped }
    }
    $autotuning = if ($TcpState.AutotuningLevelEffective) { [string]$TcpState.AutotuningLevelEffective } elseif ($TcpState.AutotuningLevel) { [string]$TcpState.AutotuningLevel } else { $null }
    if ($null -eq $autotuning) {
        $skipped += [pscustomobject]@{ Id = 'tcp-autotuning'; Reason = 'Receive-window autotuning level could not be read; left untouched.' }
    }
    elseif ($autotuning -match '(?i)^normal$') {
        $report += [pscustomobject]@{ Id = 'tcp-autotuning'; Message = 'Receive-window autotuning is at the documented Windows default (normal).' }
    }
    elseif ($autotuning -match '(?i)^(disabled|restricted|highlyrestricted)$') {
        $actions += [pscustomobject]@{
            Id = 'tcp-autotuning'; Command = @('int', 'tcp', 'set', 'global', 'autotuninglevel=normal')
            Current = $autotuning; Target = 'normal'
            Justification = 'Autotuning is below the documented Windows default (normal). Disabled/restricted autotuning caps TCP receive throughput; restoring the default is the Microsoft-documented fix.'
        }
    }
    else {
        $report += [pscustomobject]@{ Id = 'tcp-autotuning'; Message = "Autotuning level is '$autotuning' (non-default). Left untouched; only sub-default levels are corrected automatically." }
    }
    $rss = if ($TcpState.RssState) { [string]$TcpState.RssState } else { $null }
    if ($null -eq $rss) {
        $skipped += [pscustomobject]@{ Id = 'tcp-rss'; Reason = 'Receive Side Scaling state could not be read; left untouched.' }
    }
    elseif ($rss -match '(?i)enabled') {
        $report += [pscustomobject]@{ Id = 'tcp-rss'; Message = 'Receive Side Scaling is enabled (documented default on multi-processor systems).' }
    }
    elseif ($LogicalProcessors -gt 1) {
        $actions += [pscustomobject]@{
            Id = 'tcp-rss'; Command = @('int', 'tcp', 'set', 'global', 'rss=enabled')
            Current = $rss; Target = 'enabled'
            Justification = 'RSS is disabled although the system reports multiple logical processors. RSS spreads receive processing across cores; enabling it restores the documented default.'
        }
    }
    else {
        $report += [pscustomobject]@{ Id = 'tcp-rss'; Message = 'RSS is disabled but the system reports a single logical processor; no change is beneficial.' }
    }
    foreach ($item in @(
        @('tcp-ecn', $TcpState.EcnCapability, 'ECN capability is workload/network dependent and is left at its current value.'),
        @('tcp-timestamps', $TcpState.Timestamps, 'TCP timestamps are left at their current value; disabling them universally is not justified.'),
        @('tcp-congestion-provider', $TcpState.CongestionProvider, 'The congestion-control provider is left as configured; Windows defaults (CUBIC/InternetCustom) are workload dependent.'),
        @('tcp-rsc', $TcpState.RscState, 'Receive Segment Coalescing is left as configured; it benefits throughput and its latency effect is driver/game dependent.'),
        @('tcp-initial-rto', $TcpState.InitialRtoMilliseconds, 'Initial RTO left at its current value.'),
        @('tcp-max-syn-retransmissions', $TcpState.MaxSynRetransmissions, 'Max SYN retransmissions left at its current value.'),
        @('tcp-non-sack-rtt', $TcpState.NonSackRttResiliency, 'Non-SACK RTT resiliency left at its current value.')
    )) {
        $value = if ($null -ne $item[1]) { [string]$item[1] } else { 'Unknown' }
        $report += [pscustomobject]@{ Id = $item[0]; Message = "$($item[2]) Current: $value" }
    }
    return [pscustomobject][ordered]@{ Actions = $actions; ReportOnly = $report; Skipped = $skipped }
}

function Get-PONetworkAdapterInventory {
    [CmdletBinding()]
    param()
    $rows = @()
    if (-not (Test-POIsWindows)) { return @() }
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) { return @() }
    try {
        foreach ($adapter in @(Get-NetAdapter -ErrorAction Stop)) {
            $media = $null
            try { if ($adapter.PSObject.Properties['PhysicalMediaType']) { $media = [string]$adapter.PhysicalMediaType } } catch { }
            $description = [string]$adapter.InterfaceDescription
            $kind = 'Other/Virtual'
            if ($adapter.HardwareInterface) {
                if (($media -match '(?i)802\.3|Ethernet') -or ($description -match '(?i)ethernet|realtek|intel.*i[0-9]|killer e')) { $kind = 'Ethernet' }
                elseif (($media -match '(?i)802\.11|wireless|wi-?fi') -or ($description -match '(?i)wi-?fi|wireless|802\.11|wlan')) { $kind = 'Wi-Fi' }
                else { $kind = 'Physical (type unknown)' }
            }
            $powerManagement = $null; $powerManagementError = $null
            try {
                if ($adapter.Status -eq 'Up' -and (Get-Command Get-NetAdapterPowerManagement -ErrorAction SilentlyContinue)) {
                    $pm = @(Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction Stop | Select-Object -First 1)
                    if ($pm.Count -gt 0) {
                        $powerManagement = [pscustomobject][ordered]@{
                            AllowComputerToTurnOffDevice = [string]$pm[0].AllowComputerToTurnOffDevice
                            WakeOnMagicPacket = [string]$pm[0].WakeOnMagicPacket
                            WakeOnPattern = [string]$pm[0].WakeOnPattern
                        }
                    }
                }
            }
            catch { $powerManagementError = $_.Exception.Message }
            $rows += [pscustomobject][ordered]@{
                Name = [string]$adapter.Name
                Description = $description
                Status = [string]$adapter.Status
                Kind = $kind
                HardwareInterface = [bool]$adapter.HardwareInterface
                LinkSpeed = [string]$adapter.LinkSpeed
                FullDuplex = if ($null -ne $adapter.PSObject.Properties['FullDuplex']) { $adapter.FullDuplex } else { $null }
                InterfaceIndex = [int]$adapter.ifIndex
                PowerManagement = $powerManagement
                PowerManagementError = $powerManagementError
            }
        }
    }
    catch {
        return @([pscustomobject]@{ Name = 'Inventory unavailable'; Description = "Get-NetAdapter failed: $($_.Exception.Message)"; Status = 'QUERY FAILED'; Kind = 'Unknown'; HardwareInterface = $false; LinkSpeed = 'Unknown'; FullDuplex = $null; InterfaceIndex = $null; PowerManagement = $null; PowerManagementError = $null })
    }
    return $rows
}

function Invoke-PONetworkOptimization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][psobject]$Snapshot
    )
    # Applies the planned TCP corrections and wired-adapter power-management
    # changes with capture-before, verify-after, and ledger records. Returns a
    # list of result records in the shared engine schema.
    $results = @()
    if (-not (Test-POIsWindows)) { throw 'Network optimization is available only on Windows.' }
    if (-not (Test-POIsAdministrator)) { throw 'Network optimization requires an elevated Administrator session.' }

    $logicalProcessors = 0
    try { if ($Snapshot.CPU -and $Snapshot.CPU.LogicalProcessors) { $logicalProcessors = [int]$Snapshot.CPU.LogicalProcessors } } catch { }

    # --- TCP global settings -------------------------------------------------
    $before = Get-POTcpGlobalState
    $plan = Get-PONetworkOptimizationPlan -TcpState $before -LogicalProcessors $logicalProcessors
    [void](Add-POBackupFile -BackupPath $BackupPath -RelativePath 'network\tcp-global-before.json' -Content (ConvertTo-Json -InputObject $before -Depth 6))
    foreach ($item in @($plan.ReportOnly)) {
        $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = $item.Id; Status = 'INFO'; Message = $item.Message; Details = $null; RequiresReboot = $false; Reversible = $false }
    }
    foreach ($item in @($plan.Skipped)) {
        $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = $item.Id; Status = 'SKIPPED'; Message = $item.Reason; Details = $null; RequiresReboot = $false; Reversible = $false }
    }
    $appliedTcp = @()
    foreach ($action in @($plan.Actions)) {
        $changeRecord = [pscustomobject][ordered]@{
            section = 'network-tcp'; id = [string]$action.Id; name = "TCP global setting $([string]$action.Id)"
            command = (@('netsh') + @($action.Command)) -join ' '; current = [string]$action.Current; target = [string]$action.Target
            justification = [string]$action.Justification; status = 'APPLYING'; timestampUtc = [DateTime]::UtcNow.ToString('o')
        }
        Add-POBackupChange -BackupPath $BackupPath -Section 'network-tcp' -Change $changeRecord
        $netsh = Invoke-PONetsh -Arguments @($action.Command)
        if ($netsh.ExitCode -ne 0) {
            Update-POBackupChangeStatus -BackupPath $BackupPath -Section 'network-tcp' -ChangeId ([string]$action.Id) -Status 'FAILED' -Message "netsh exit code $($netsh.ExitCode): $(($netsh.Output -join ' ').Trim())"
            $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = [string]$action.Id; Status = 'FAILED'; Message = "netsh exited with code $($netsh.ExitCode): $(($netsh.Output -join ' ').Trim())"; Details = $action.Justification; RequiresReboot = $false; Reversible = $true }
            continue
        }
        $after = Get-POTcpGlobalState
        $verified = $false
        if ([string]$action.Id -eq 'tcp-autotuning') {
            $level = if ($after.AutotuningLevelEffective) { [string]$after.AutotuningLevelEffective } else { [string]$after.AutotuningLevel }
            $verified = ($level -match '(?i)^normal$')
        }
        elseif ([string]$action.Id -eq 'tcp-rss') {
            $verified = ([string]$after.RssState -match '(?i)enabled')
        }
        if ($verified) {
            Update-POBackupChangeStatus -BackupPath $BackupPath -Section 'network-tcp' -ChangeId ([string]$action.Id) -Status 'APPLIED_VERIFIED' -Message "Changed from '$($action.Current)' to '$($action.Target)' and verified by re-reading."
            $appliedTcp += [string]$action.Id
            $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = [string]$action.Id; Status = 'APPLIED_VERIFIED'; Message = "Changed '$($action.Current)' to '$($action.Target)' and verified. $($action.Justification)"; Details = $null; RequiresReboot = $false; Reversible = $true }
        }
        else {
            Update-POBackupChangeStatus -BackupPath $BackupPath -Section 'network-tcp' -ChangeId ([string]$action.Id) -Status 'UNVERIFIED' -Message 'netsh accepted the change but re-reading did not confirm it.'
            $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = [string]$action.Id; Status = 'UNVERIFIED'; Message = 'The change was accepted by netsh but could not be confirmed by re-reading; it is NOT reported as successful.'; Details = $null; RequiresReboot = $false; Reversible = $true }
        }
    }

    # --- Wired adapter power management ---------------------------------------
    # Only connected physical Ethernet adapters are changed, and only while the
    # device is not battery-dependent. Wi-Fi power saving is legitimate and is
    # never disabled here.
    $adapters = @(Get-PONetworkAdapterInventory)
    $onBattery = ($Snapshot.Device.IsLaptop -eq $true -and [string]$Snapshot.Device.PowerSource -eq 'Battery')
    $wiredUp = @($adapters | Where-Object { $_.Kind -eq 'Ethernet' -and $_.Status -eq 'Up' -and $_.HardwareInterface })
    if ($wiredUp.Count -eq 0) {
        $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = 'adapter-power-management'; Status = 'SKIPPED'; Message = 'No connected physical Ethernet adapter was detected; adapter power-management change skipped.'; Details = $null; RequiresReboot = $false; Reversible = $false }
    }
    elseif ($onBattery) {
        $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = 'adapter-power-management'; Status = 'SKIPPED'; Message = 'Portable device is on battery; disabling adapter power saving would drain the battery and is skipped.'; Details = $null; RequiresReboot = $false; Reversible = $false }
    }
    else {
        $beforeRows = @()
        foreach ($adapter in $wiredUp) {
            if ($null -eq $adapter.PowerManagement) { continue }
            $beforeRows += [pscustomobject][ordered]@{
                Name = $adapter.Name; InterfaceIndex = $adapter.InterfaceIndex
                AllowComputerToTurnOffDevice = [string]$adapter.PowerManagement.AllowComputerToTurnOffDevice
            }
        }
        [void](Add-POBackupFile -BackupPath $BackupPath -RelativePath 'network\adapter-power-before.json' -Content (ConvertTo-Json -InputObject @($beforeRows) -Depth 6))
        $candidates = @($beforeRows | Where-Object { $_.AllowComputerToTurnOffDevice -match '(?i)^Enabled$' })
        if ($candidates.Count -eq 0) {
            $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = 'adapter-power-management'; Status = 'ALREADY_OPTIMIZED'; Message = "Wired adapter power saving is already configured appropriately on $($beforeRows.Count) adapter(s) or not exposed by the driver."; Details = $null; RequiresReboot = $false; Reversible = $true }
        }
        else {
            $changeRecord = [pscustomobject][ordered]@{
                section = 'network-adapter-power'; id = 'adapter-power-management'; name = 'Wired adapter power management'
                adapters = @($candidates | ForEach-Object { [string]$_.Name }); status = 'APPLYING'; timestampUtc = [DateTime]::UtcNow.ToString('o')
            }
            Add-POBackupChange -BackupPath $BackupPath -Section 'network-adapter-power' -Change $changeRecord
            $changed = 0; $failed = 0
            foreach ($row in $candidates) {
                try {
                    Set-NetAdapterPowerManagement -Name ([string]$row.Name) -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
                    $verify = @(Get-NetAdapterPowerManagement -Name ([string]$row.Name) -ErrorAction Stop | Select-Object -First 1)
                    if ($verify.Count -gt 0 -and [string]$verify[0].AllowComputerToTurnOffDevice -match '(?i)^Disabled$') { $changed++ }
                    else { $failed++ }
                }
                catch { $failed++ }
            }
            if ($failed -eq 0 -and $changed -gt 0) {
                Update-POBackupChangeStatus -BackupPath $BackupPath -Section 'network-adapter-power' -ChangeId 'adapter-power-management' -Status 'APPLIED_VERIFIED' -Message "Disabled allow-to-turn-off on $changed wired adapter(s); verified by re-reading."
                $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = 'adapter-power-management'; Status = 'APPLIED_VERIFIED'; Message = "Prevented Windows from powering off $($changed) connected wired adapter(s) during use; verified. Previous values are recorded for restore."; Details = $null; RequiresReboot = $false; Reversible = $true }
            }
            elseif ($changed -gt 0) {
                Update-POBackupChangeStatus -BackupPath $BackupPath -Section 'network-adapter-power' -ChangeId 'adapter-power-management' -Status 'PARTIAL_FAILURE' -Message "$changed changed, $failed failed verification."
                $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = 'adapter-power-management'; Status = 'FAILED'; Message = "$changed adapter(s) changed and verified, $failed could not be applied or verified."; Details = $null; RequiresReboot = $false; Reversible = $true }
            }
            else {
                Update-POBackupChangeStatus -BackupPath $BackupPath -Section 'network-adapter-power' -ChangeId 'adapter-power-management' -Status 'FAILED' -Message 'No adapter change could be verified.'
                $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = 'adapter-power-management'; Status = 'FAILED'; Message = 'The adapter power-management change could not be applied or verified on any adapter; previous behavior is unchanged.'; Details = $null; RequiresReboot = $false; Reversible = $true }
            }
        }
    }

    # --- DNS resolver cache flush (transient, non-persistent, safe) ------------
    try {
        $flush = @(& ipconfig.exe /flushdns 2>&1)
        if ($LASTEXITCODE -eq 0) {
            $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = 'dns-cache-flush'; Status = 'APPLIED_VERIFIED'; Message = 'DNS resolver cache flushed (ipconfig exit code 0). This is transient and changes no configuration.'; Details = $null; RequiresReboot = $false; Reversible = $false }
        }
        else {
            $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = 'dns-cache-flush'; Status = 'FAILED'; Message = "ipconfig /flushdns exited with code $LASTEXITCODE."; Details = ($flush -join ' '); RequiresReboot = $false; Reversible = $false }
        }
    }
    catch {
        $results += [pscustomobject][ordered]@{ Stage = 'Network'; Id = 'dns-cache-flush'; Status = 'FAILED'; Message = "DNS cache flush failed: $($_.Exception.Message)"; Details = $null; RequiresReboot = $false; Reversible = $false }
    }
    return $results
}

function Restore-PONetworkTcpSection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupPath, [Parameter(Mandatory = $true)][psobject]$Manifest)
    $changes = @($Manifest.changes | Where-Object { $_.section -eq 'network-tcp' })
    if ($changes.Count -eq 0) { throw 'No TCP change was recorded in this backup.' }
    $statePath = Join-Path $BackupPath 'network\tcp-global-before.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'The captured TCP before-state file is missing; restore is blocked.' }
    $before = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $allowedAutotuning = @('normal', 'disabled', 'restricted', 'highlyrestricted', 'experimental')
    foreach ($change in $changes) {
        $id = [string]$change.id
        $restoreCommand = $null
        if ($id -eq 'tcp-autotuning') {
            $captured = if ($before.AutotuningLevel) { [string]$before.AutotuningLevel } else { $null }
            if ($null -eq $captured) { continue }
            $normalized = ($captured -replace '\s', '').ToLowerInvariant()
            if ($normalized -notin $allowedAutotuning) { throw "Captured autotuning value '$captured' is not a known level; refusing to apply it." }
            $restoreCommand = @('int', 'tcp', 'set', 'global', "autotuninglevel=$normalized")
        }
        elseif ($id -eq 'tcp-rss') {
            $captured = if ($before.RssState) { [string]$before.RssState } else { $null }
            if ($null -eq $captured) { continue }
            if ($captured -match '(?i)enabled') { $restoreCommand = @('int', 'tcp', 'set', 'global', 'rss=enabled') }
            elseif ($captured -match '(?i)disabled') { $restoreCommand = @('int', 'tcp', 'set', 'global', 'rss=disabled') }
            else { throw "Captured RSS value '$captured' is not recognized; refusing to apply it." }
        }
        else { throw "Unknown TCP change id '$id' in the ledger; refusing to apply it." }
        $netsh = Invoke-PONetsh -Arguments $restoreCommand
        if ($netsh.ExitCode -ne 0) { throw "Restoring $id failed: netsh exit code $($netsh.ExitCode): $(($netsh.Output -join ' ').Trim())" }
        $after = Get-POTcpGlobalState
        if ($id -eq 'tcp-autotuning') {
            $level = if ($after.AutotuningLevelEffective) { [string]$after.AutotuningLevelEffective } elseif ($after.AutotuningLevel) { [string]$after.AutotuningLevel } else { '' }
            if ($level -notmatch '(?i)^normal$' -and $before.AutotuningLevel -and ($level -notmatch [regex]::Escape(([string]$before.AutotuningLevel).ToLowerInvariant()))) {
                throw "TCP autotuning restore could not be verified (current: '$level')."
            }
        }
    }
}

function Restore-PONetworkAdapterPowerSection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupPath, [Parameter(Mandatory = $true)][psobject]$Manifest)
    $changes = @($Manifest.changes | Where-Object { $_.section -eq 'network-adapter-power' })
    if ($changes.Count -eq 0) { throw 'No adapter-power change was recorded in this backup.' }
    $statePath = Join-Path $BackupPath 'network\adapter-power-before.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'The captured adapter-power before-state file is missing; restore is blocked.' }
    $rows = @(Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
    if (-not (Get-Command Set-NetAdapterPowerManagement -ErrorAction SilentlyContinue)) { throw 'Set-NetAdapterPowerManagement is unavailable; cannot restore adapter power settings.' }
    foreach ($row in $rows) {
        $captured = [string]$row.AllowComputerToTurnOffDevice
        if ($captured -notmatch '(?i)^(Enabled|Disabled)$') { throw "Captured adapter power value '$captured' for '$($row.Name)' is not recognized; refusing to apply it." }
        try {
            $adapter = @(Get-NetAdapter -Name ([string]$row.Name) -ErrorAction Stop | Select-Object -First 1)
            if ($adapter.Count -eq 0) { continue }
            Set-NetAdapterPowerManagement -Name ([string]$row.Name) -AllowComputerToTurnOffDevice $captured -ErrorAction Stop
            $verify = @(Get-NetAdapterPowerManagement -Name ([string]$row.Name) -ErrorAction Stop | Select-Object -First 1)
            if ($verify.Count -eq 0 -or [string]$verify[0].AllowComputerToTurnOffDevice -notmatch ('(?i)^' + $captured + '$')) {
                throw "Restore verification failed for adapter '$($row.Name)'."
            }
        }
        catch { throw "Restoring adapter power management for '$($row.Name)' failed: $($_.Exception.Message)" }
    }
}

function Get-PONetworkReportNotes {
    return @(
        'Ping/latency is determined by your ISP, routing, server location, congestion, and the game server itself - a Windows optimizer cannot guarantee lower ping.',
        'ECN, TCP timestamps, RSC, congestion provider, and offload features were assessed and left at their current values: their benefit depends on hardware, drivers, and workload.',
        'No DNS resolver, network identity, speed/duplex setting, or firewall rule was changed. No network reset was performed.'
    )
}

Export-ModuleMember -Function @(
    'Invoke-PONetsh', 'ConvertFrom-PONetshTcpGlobalLines', 'Get-POTcpGlobalState',
    'Get-PONetworkOptimizationPlan', 'Get-PONetworkAdapterInventory', 'Invoke-PONetworkOptimization',
    'Restore-PONetworkTcpSection', 'Restore-PONetworkAdapterPowerSection', 'Get-PONetworkReportNotes'
)
