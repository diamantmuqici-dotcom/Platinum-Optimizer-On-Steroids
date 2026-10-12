#requires -Version 5.1
# Platinum Optimizer On Steroids - Automatic CMD execution engine (v2.1.0)
#
# The console is the entire user interface. This module runs the complete
# optimization pipeline without interactive menus:
#
#   BOOT -> SCAN -> BACKUP -> CPU -> POWER -> GAMING -> NETWORK -> GPU ->
#   DISPLAY -> AUDIO -> MEMORY -> STORAGE -> VERIFY -> REPORT
#
# Every status line reflects an actual operation and its verified outcome.
# Nothing is printed as successful before it succeeds, and no line is printed
# for work that was not performed.
#
# Each configurable setting goes through Invoke-POConfigOperation, which
# enforces a single contract:
#   1  detect the capability
#   2  read the current value
#   3  evaluate whether a change is appropriate
#   4  explain the change and its trade-offs
#   5  confirm a backup / rollback path exists
#   6  apply only when justified
#   7  read the value back
#   8  record the actual result
#   9  roll back when the operation fails and rollback is safe
#   10 report the result to the console, the log and the JSON report
Set-StrictMode -Version 2.0

if (-not (Get-Module | Where-Object { $_.Name -eq 'PlatinumOptimizer.Core' })) {
    Import-Module -Name (Join-Path $PSScriptRoot 'PlatinumOptimizer.Core.psm1') -Global -Force -ErrorAction Stop
}

$script:POEngineVersion = '2.1.0'
$script:PORunLogPath = $null
$script:PORunStartedUtc = [DateTime]::UtcNow.ToString('o')
$script:POCurrentStage = 'BOOT'
$script:POStageIndex = 0
# BOOT, SCAN, BACKUP, CPU, POWER, GAMING, NETWORK, GPU, DISPLAY, AUDIO,
# MEMORY, VERIFY.
$script:POStageTotal = 12
$script:POStageName = ''
$script:POOperationIndex = 0
# Genuine before/after measurements collected during the run.
$script:POMeasurements = New-Object System.Collections.ArrayList
# Set by the DISPLAY stage when a monitor enumerates a higher refresh rate
# than it currently runs at. Initialised here because Set-StrictMode 2.0
# throws on reads of uninitialised variables.
$script:PODisplayRefreshAdvice = $null
# Captured before-state for the gaming registry rollback handler.
$script:POGamingBeforeState = $null

# Modules the engine expects the entry point to have imported. Used by the
# BOOT stage to prove, rather than assume, that every category is wired in.
$script:PORequiredModules = @(
    'PlatinumOptimizer.Core',
    'PlatinumOptimizer.Power',
    'PlatinumOptimizer.Audio',
    'PlatinumOptimizer.Display',
    'PlatinumOptimizer.Network',
    'PlatinumOptimizer.Gaming',
    'PlatinumOptimizer.Engine',
    'PlatinumOptimizer.Automatic'
)

function Get-POEngineVersion { return $script:POEngineVersion }

# ---------------------------------------------------------------------------
# Console infrastructure
# ---------------------------------------------------------------------------

function Get-POConsoleTimestamp {
    # Local time is what the operator sees next to the terminal clock.
    return [DateTime]::Now.ToString('HH:mm:ss')
}

function Set-POConsoleStage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:POCurrentStage = $Name.ToUpperInvariant()
}

function Get-POConsoleStage { return $script:POCurrentStage }

function Write-POStageHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Title
    )
    $script:POStageIndex++
    $script:POStageName = $Title
    Set-POConsoleStage -Name $Name
    Write-Host ''
    Write-Host ('====== [{0}] {1}  (stage {2} of {3}) ======' -f $Name.ToUpperInvariant(), $Title, $script:POStageIndex, $script:POStageTotal) -ForegroundColor White
    $banner = ('====== [{0}] {1}  (stage {2} of {3}) ======' -f $Name.ToUpperInvariant(), $Title, $script:POStageIndex, $script:POStageTotal)
    Write-PORawLog -Line $banner
}

function Write-PORawLog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)
    if (-not $script:PORunLogPath) { return }
    try {
        $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
        # AppendAllText opens, writes and closes the file immediately so the
        # log mirrors the live console instead of buffering until exit.
        [System.IO.File]::AppendAllText($script:PORunLogPath, ($stamp + ' ' + $Line + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Write-POConsole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('INFO', 'PASS', 'FAIL', 'WARN', 'SKIP', 'STEP', 'CMD')][string]$Level,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [string]$Stage = ''
    )
    $color = switch ($Level) {
        'INFO' { 'Gray' }
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'SKIP' { 'DarkYellow' }
        'FAIL' { 'Red' }
        'STEP' { 'White' }
        'CMD' { 'DarkCyan' }
    }
    $stageTag = if ([string]::IsNullOrWhiteSpace($Stage)) { $script:POCurrentStage } else { $Stage.ToUpperInvariant() }
    # Progress lines read as "[STAGE] message"; outcome lines add a status tag.
    $levelTag = if ($Level -eq 'INFO') { '' } else { "[$Level] " }
    $prefix = if ([string]::IsNullOrWhiteSpace($stageTag)) { $levelTag } else { "[$stageTag] $levelTag" }
    if ($Level -eq 'CMD') { $prefix = if ([string]::IsNullOrWhiteSpace($stageTag)) { '  > ' } else { "[$stageTag]   > " } }
    foreach ($line in @([string]$Message -split "`r?`n")) {
        $text = '{0} {1}{2}' -f (Get-POConsoleTimestamp), $prefix, $line
        # Write-Host goes straight to the console host: output appears while the
        # operation is running rather than when the pipeline flushes.
        Write-Host $text -ForegroundColor $color
        Write-PORawLog -Line $text
    }
}

function Write-POCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Command)
    Write-POConsole -Level 'CMD' -Message $Command
}

function Add-POMeasurement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Before,
        [AllowNull()][object]$After,
        [string]$Unit = '',
        [string]$Note = ''
    )
    $record = [pscustomobject][ordered]@{
        Name = $Name
        Before = $Before
        After = $After
        Unit = $Unit
        Note = $Note
        Changed = -not ([string]$Before -eq [string]$After)
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    [void]$script:POMeasurements.Add($record)
    return $record
}

# ---------------------------------------------------------------------------
# Run log
# ---------------------------------------------------------------------------

function Get-PORunLogRoot {
    # Timestamped logs live under ProgramData when elevated (machine-wide),
    # with a per-user fallback. Previous logs are never overwritten.
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
        # Logging must never crash the run.
        $script:PORunLogPath = $null
        try { Write-POLog -Level 'WARNING' -Category 'Engine' -Status 'RUN_LOG_UNAVAILABLE' -Message "Run log directory could not be created: $($_.Exception.Message)" } catch { }
    }
    return [pscustomobject][ordered]@{ LogDir = $dir; RunLogPath = $script:PORunLogPath }
}

# ---------------------------------------------------------------------------
# Result records
# ---------------------------------------------------------------------------

function New-POResultRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet(
            'APPLIED_VERIFIED', 'ALREADY_OPTIMIZED', 'SKIPPED', 'FAILED',
            'UNVERIFIED', 'ROLLED_BACK', 'DIAGNOSTIC', 'INFO')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()][object]$Details = $null,
        [AllowNull()][object]$BeforeValue = $null,
        [AllowNull()][object]$AfterValue = $null,
        [bool]$RequiresReboot = $false,
        [bool]$Reversible = $false,
        [bool]$Inspected = $true,
        [bool]$Attempted = $false,
        [string]$Reason = ''
    )
    return [pscustomobject][ordered]@{
        Stage = $Stage; Id = $Id; Status = $Status; Message = $Message; Details = $Details
        BeforeValue = $BeforeValue; AfterValue = $AfterValue
        RequiresReboot = $RequiresReboot; Reversible = $Reversible
        Inspected = $Inspected; Attempted = $Attempted; Reason = $Reason
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
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
        'ROLLED_BACK' { 'WARN' }
        'DIAGNOSTIC' { 'INFO' }
        default { 'INFO' }
    }
    $suffix = switch ([string]$Result.Status) {
        'ALREADY_OPTIMIZED' { ' (already matches the gaming policy)' }
        'UNVERIFIED' { ' - NOT verified, not counted as success' }
        'ROLLED_BACK' { ' - rolled back to the previous value' }
        'SKIPPED' { ' (skipped)' }
        default { '' }
    }
    Write-POConsole -Level $level -Message "$($Result.Message)$suffix" -Stage $Result.Stage
    if ($Result.Status -eq 'SKIPPED' -and -not [string]::IsNullOrWhiteSpace([string]$Result.Reason)) {
        Write-POConsole -Level 'SKIP' -Message "reason: $($Result.Reason)" -Stage $Result.Stage
    }
}

function Get-POReportSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][psobject[]]$Results)
    # Pure counter. Every bucket below is reported separately: a failure is
    # never folded into a success count.
    $rows = @($Results)
    $applied = @($rows | Where-Object { $_.Status -eq 'APPLIED_VERIFIED' })
    $already = @($rows | Where-Object { $_.Status -eq 'ALREADY_OPTIMIZED' })
    $skipped = @($rows | Where-Object { $_.Status -eq 'SKIPPED' })
    $failed = @($rows | Where-Object { $_.Status -eq 'FAILED' })
    $unverified = @($rows | Where-Object { $_.Status -eq 'UNVERIFIED' })
    $rolledBack = @($rows | Where-Object { $_.Status -eq 'ROLLED_BACK' })
    $diagnostic = @($rows | Where-Object { $_.Status -eq 'DIAGNOSTIC' })
    $informational = @($rows | Where-Object { $_.Status -eq 'INFO' })
    $inspected = @($rows | Where-Object { $_.Inspected })
    $attempted = @($rows | Where-Object { $_.Attempted })
    $reboot = @($rows | Where-Object { $_.RequiresReboot -and $_.Status -in @('APPLIED_VERIFIED', 'UNVERIFIED') })
    return [pscustomobject][ordered]@{
        Inspected = $inspected.Count
        Attempted = $attempted.Count
        Applied = $applied.Count
        AlreadyOptimized = $already.Count
        Skipped = $skipped.Count
        Failed = $failed.Count
        Unverified = $unverified.Count
        RolledBack = $rolledBack.Count
        DiagnosticOnly = $diagnostic.Count
        Informational = $informational.Count
        RebootRecommended = ($reboot.Count -gt 0)
        FailedIds = @($failed | ForEach-Object { "$($_.Stage)/$($_.Id)" })
        UnverifiedIds = @($unverified | ForEach-Object { "$($_.Stage)/$($_.Id)" })
        SkippedWithReasons = @($skipped | ForEach-Object { [pscustomobject]@{ Id = "$($_.Stage)/$($_.Id)"; Reason = $_.Reason } })
    }
}

# ---------------------------------------------------------------------------
# The optimization contract
# ---------------------------------------------------------------------------

function Invoke-POConfigOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Detect,
        [Parameter(Mandatory = $true)][scriptblock]$Read,
        [Parameter(Mandatory = $true)][scriptblock]$Evaluate,
        [scriptblock]$Apply = $null,
        [scriptblock]$Verify = $null,
        [scriptblock]$Rollback = $null,
        [AllowNull()][string]$BackupPath = $null,
        [switch]$RequiresBackup,
        [bool]$RequiresReboot = $false,
        [switch]$DiagnosticOnly,
        [switch]$AllowRollback
    )
    # One contract for every configurable setting. Returns a single result
    # record whose status is derived from what actually happened.
    Write-POConsole -Level 'INFO' -Message "$Name : inspecting..." -Stage $Stage
    $script:POOperationIndex++

    # Step 1 - detect the capability.
    $detection = $null
    try { $detection = & $Detect }
    catch {
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'SKIPPED' `
            -Message "$Name : capability detection failed." -Attempted $false `
            -Reason $_.Exception.Message -Inspected $false)
    }
    if ($null -eq $detection -or -not $detection.Supported) {
        $reason = if ($detection -and $detection.PSObject.Properties['Reason']) { [string]$detection.Reason } else { 'capability not exposed by this system' }
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'SKIPPED' `
            -Message "$Name : not supported here." -Attempted $false -Reason $reason -Inspected $false)
    }

    # Step 2 - read the current value.
    $current = $null
    try { $current = & $Read }
    catch {
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'SKIPPED' `
            -Message "$Name : the current value could not be read; nothing was changed." `
            -Attempted $false -Reason $_.Exception.Message -Inspected $false)
    }
    $currentText = if ($null -eq $current) { 'not present' } else { [string]$current }
    Write-POConsole -Level 'INFO' -Message "$Name : current value = $currentText" -Stage $Stage

    # Step 3 - evaluate.
    $decision = $null
    try { $decision = & $Evaluate $current }
    catch {
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'SKIPPED' `
            -Message "$Name : the change could not be evaluated; nothing was changed." `
            -Attempted $false -Reason $_.Exception.Message -BeforeValue $currentText)
    }
    $action = if ($decision -and $decision.PSObject.Properties['Action']) { [string]$decision.Action } else { 'skip' }
    $tradeoffs = if ($decision -and $decision.PSObject.Properties['Tradeoffs']) { [string]$decision.Tradeoffs } else { '' }
    $justification = if ($decision -and $decision.PSObject.Properties['Justification']) { [string]$decision.Justification } else { '' }
    $target = if ($decision -and $decision.PSObject.Properties['Target']) { $decision.Target } else { $null }

    if ($DiagnosticOnly) {
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'DIAGNOSTIC' `
            -Message "$Name : inspected only, left unchanged ($currentText)." `
            -Details $justification -BeforeValue $currentText -AfterValue $currentText -Reason $tradeoffs)
    }
    if ($action -eq 'noop') {
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'ALREADY_OPTIMIZED' `
            -Message "$Name : already at the gaming policy value ($currentText)." `
            -BeforeValue $currentText -AfterValue $currentText -Reason $justification)
    }
    if ($action -ne 'apply') {
        $reason = if ($decision -and $decision.PSObject.Properties['Reason']) { [string]$decision.Reason } else { 'no justified change' }
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'SKIPPED' `
            -Message "$Name : no change applied." -BeforeValue $currentText -Attempted $false -Reason $reason)
    }

    # Step 4 - explain the intended change and its trade-offs.
    Write-POConsole -Level 'INFO' -Message "$Name : change justified - $justification" -Stage $Stage
    if (-not [string]::IsNullOrWhiteSpace($tradeoffs)) {
        Write-POConsole -Level 'WARN' -Message "$Name : trade-off - $tradeoffs" -Stage $Stage
    }

    # Step 5 - confirm a recovery path exists before writing anything.
    if ($RequiresBackup -and [string]::IsNullOrWhiteSpace($BackupPath)) {
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'SKIPPED' `
            -Message "$Name : blocked by the backup-first policy (no verified backup for this run)." `
            -BeforeValue $currentText -Attempted $false -Reason 'A verified configuration backup is required before this write.')
    }
    if ($null -eq $Apply) {
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'SKIPPED' `
            -Message "$Name : evaluated as changeable but no apply handler is implemented; left unchanged." `
            -BeforeValue $currentText -Attempted $false -Reason 'No write path is implemented for this setting.')
    }

    # Step 6 - apply only when justified.
    try { & $Apply $target | Out-Null }
    catch {
        $failureMessage = $_.Exception.Message
        $rolled = $false
        if ($AllowRollback -and $null -ne $Rollback) {
            try { & $Rollback $current | Out-Null; $rolled = $true } catch { }
        }
        if ($rolled) {
            return (New-POResultRecord -Stage $Stage -Id $Id -Status 'ROLLED_BACK' -Attempted `
                -Message "$Name : the write failed ($failureMessage); the previous value was restored." `
                -BeforeValue $currentText -AfterValue $currentText -Reversible $true)
        }
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'FAILED' -Attempted `
            -Message "$Name : the write failed - $failureMessage" -BeforeValue $currentText -Reversible $false)
    }

    # Step 7 - read the value back.
    $observed = $null
    $verified = $false
    $detail = $null
    if ($null -ne $Verify) {
        try {
            $verification = & $Verify $target
            if ($null -ne $verification) {
                $verified = [bool]$verification.Verified
                $observed = if ($verification.PSObject.Properties['Observed']) { $verification.Observed } else { $null }
                $detail = if ($verification.PSObject.Properties['Detail']) { $verification.Detail } else { $null }
            }
        }
        catch { $verified = $false; $detail = $_.Exception.Message }
    }
    else {
        # No verify handler means the write is genuinely unverifiable.
        $verified = $false
        $detail = 'No read-back handler exists for this setting.'
    }
    $observedText = if ($null -eq $observed) { 'not readable' } else { [string]$observed }

    # Steps 8/9 - record, and roll back when verification fails.
    if ($verified) {
        Write-POConsole -Level 'PASS' -Message "$Name : $currentText -> $observedText (verified by reading back)." -Stage $Stage
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'APPLIED_VERIFIED' -Attempted `
            -Message "$Name : $currentText -> $observedText, verified by reading back. $justification" `
            -Details $detail -BeforeValue $currentText -AfterValue $observedText `
            -RequiresReboot $RequiresReboot -Reversible ($null -ne $Rollback))
    }

    $rolled = $false
    if ($AllowRollback -and $null -ne $Rollback) {
        try {
            & $Rollback $current | Out-Null
            $recheck = & $Read
            $rolled = ([string]$recheck -eq $currentText)
            if ($rolled) { Write-POConsole -Level 'WARN' -Message "$Name : change did not verify; rolled back to $currentText." -Stage $Stage }
        }
        catch { }
    }
    if ($rolled) {
        return (New-POResultRecord -Stage $Stage -Id $Id -Status 'ROLLED_BACK' -Attempted `
            -Message "$Name : applied but not verified (read back '$observedText'); reverted to $currentText." `
            -Details $detail -BeforeValue $currentText -AfterValue $currentText -Reversible $true)
    }
    Write-POConsole -Level 'WARN' -Message "$Name : applied but NOT verified (read back '$observedText')." -Stage $Stage
    return (New-POResultRecord -Stage $Stage -Id $Id -Status 'UNVERIFIED' -Attempted `
        -Message "$Name : the write was accepted but reading it back returned '$observedText'; not counted as success." `
        -Details $detail -BeforeValue $currentText -AfterValue $observedText -RequiresReboot $RequiresReboot)
}

# ---------------------------------------------------------------------------
# Stage: BOOT
# ---------------------------------------------------------------------------

function Invoke-POBootStage {
    [CmdletBinding()]
    param()
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'BOOT' -Title 'EXECUTION ENGINE INITIALIZATION'

    Write-POConsole -Level 'INFO' -Message 'Initializing execution engine...'
    Write-POConsole -Level 'INFO' -Message ("Platinum Optimizer On Steroids v{0} (engine module)" -f (Get-POEngineVersion))

    Write-POConsole -Level 'INFO' -Message 'Checking PowerShell version and execution environment...'
    $psVersion = [string]$PSVersionTable.PSVersion
    $psEdition = if ($PSVersionTable.PSObject.Properties['PSEdition']) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
    Write-POConsole -Level 'INFO' -Message "PowerShell $psVersion ($psEdition edition) on $($env:OS)."
    if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
        $rec = New-POResultRecord -Stage 'BOOT' -Id 'powershell-version' -Status 'FAILED' -Message "Windows PowerShell 5.1 or later is required; this session is $psVersion." -Inspected $false
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }
    else {
        $rec = New-POResultRecord -Stage 'BOOT' -Id 'powershell-version' -Status 'DIAGNOSTIC' -Message "PowerShell version check passed ($psVersion)." -AfterValue $psVersion
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }

    Write-POConsole -Level 'INFO' -Message 'Checking administrator token...'
    $isAdmin = Test-POIsAdministrator
    if ($isAdmin) {
        Write-POConsole -Level 'PASS' -Message 'Administrator token confirmed (elevated session).'
        $rec = New-POResultRecord -Stage 'BOOT' -Id 'administrator-token' -Status 'DIAGNOSTIC' -Message 'Administrator privileges confirmed.' -AfterValue $true
        $results.Add($rec)
    }
    else {
        $rec = New-POResultRecord -Stage 'BOOT' -Id 'administrator-token' -Status 'FAILED' -Message 'This session is not elevated; system changes are blocked.' -Inspected $false
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }

    Write-POConsole -Level 'INFO' -Message 'Verifying that every optimization module is loaded...'
    foreach ($moduleName in $script:PORequiredModules) {
        $module = @(Get-Module | Where-Object { $_.Name -eq $moduleName } | Select-Object -First 1)
        if ($module.Count -gt 0) {
            $exportCount = @($module[0].ExportedFunctions.Keys).Count
            Write-POConsole -Level 'PASS' -Message "Module loaded: $moduleName ($exportCount exported function(s))."
            $results.Add((New-POResultRecord -Stage 'BOOT' -Id "module-$moduleName" -Status 'DIAGNOSTIC' -Message "Module $moduleName is loaded with $exportCount exported function(s)." -AfterValue $true))
        }
        else {
            Write-POConsole -Level 'FAIL' -Message "Module NOT loaded: $moduleName. Its optimization category will be skipped."
            $results.Add((New-POResultRecord -Stage 'BOOT' -Id "module-$moduleName" -Status 'FAILED' -Message "Module $moduleName is not loaded; its category cannot run." -Inspected $false))
        }
    }

    Write-POConsole -Level 'INFO' -Message 'Checking required Windows command-line tools...'
    foreach ($tool in @('powercfg.exe', 'netsh.exe', 'ipconfig.exe', 'powershell.exe')) {
        $command = Get-Command $tool -ErrorAction SilentlyContinue
        if ($command) { Write-POConsole -Level 'PASS' -Message "Tool available: $tool" }
        else {
            Write-POConsole -Level 'WARN' -Message "Tool not found: $tool (dependent checks will be skipped, not simulated)."
            $results.Add((New-POResultRecord -Stage 'BOOT' -Id "tool-$($tool -replace '\.exe$','')" -Status 'SKIPPED' -Message "Tool $tool is unavailable." -Inspected $false -Reason "$tool was not found on this system."))
        }
    }

    Write-POConsole -Level 'INFO' -Message 'Checking optional Windows PowerShell modules used by the pipeline...'
    foreach ($cmdlet in @('Get-NetAdapter', 'Get-NetTCPSetting', 'Get-NetAdapterPowerManagement', 'Checkpoint-Computer', 'Get-PhysicalDisk', 'Get-CimInstance')) {
        $command = Get-Command $cmdlet -ErrorAction SilentlyContinue
        if ($command) { Write-POConsole -Level 'INFO' -Message "Cmdlet available: $cmdlet" }
        else { Write-POConsole -Level 'WARN' -Message "Cmdlet unavailable: $cmdlet (its checks are skipped, not faked)." }
    }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Stage: SCAN
# ---------------------------------------------------------------------------

function Invoke-POScanStage {
    [CmdletBinding()]
    param()
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'SCAN' -Title 'HARDWARE AND WINDOWS DETECTION'

    Write-POConsole -Level 'INFO' -Message 'Detecting Windows build...'
    $snapshot = $null
    try {
        $snapshot = Get-POSystemSnapshot
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'system-snapshot' -Status 'DIAGNOSTIC' -Message 'Windows system snapshot collected via CIM.'))
    }
    catch {
        Write-POConsole -Level 'FAIL' -Message "Windows system snapshot failed: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'system-snapshot' -Status 'FAILED' -Message "System snapshot failed: $($_.Exception.Message)" -Inspected $false))
        return [pscustomobject]@{ Results = $results.ToArray(); Snapshot = $null }
    }

    if ($snapshot.OS) {
        Write-POConsole -Level 'INFO' -Message ("Windows: {0} | build {1} | {2} | supported: {3}" -f $snapshot.OS.Name, $snapshot.OS.Build, $snapshot.OS.Architecture, $snapshot.OS.Supported)
    }
    if (-not $snapshot.OS.Supported) {
        $rec = New-POResultRecord -Stage 'SCAN' -Id 'windows-support' -Status 'FAILED' -Message 'Windows 10/11 could not be confirmed; system changes are blocked.'
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }

    Write-POConsole -Level 'INFO' -Message 'Detecting CPU model and logical processors...'
    if ($snapshot.CPU) {
        Write-POConsole -Level 'INFO' -Message ("CPU: {0} | vendor {1} | {2} physical core(s) | {3} logical processor(s)" -f $snapshot.CPU.Model, $snapshot.CPU.Vendor, $snapshot.CPU.PhysicalCores, $snapshot.CPU.LogicalProcessors)
        if ($snapshot.CPU.MaximumClockReportedMHz) { Write-POConsole -Level 'INFO' -Message ("CPU nominal clock: {0} MHz" -f $snapshot.CPU.MaximumClockReportedMHz) }
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'cpu-detection' -Status 'DIAGNOSTIC' -Message ("CPU detected: {0} ({1} logical processors)." -f $snapshot.CPU.Model, $snapshot.CPU.LogicalProcessors) -AfterValue $snapshot.CPU.Model))
    }
    else {
        Write-POConsole -Level 'WARN' -Message 'CPU could not be identified; processor stages will be conservative.'
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'cpu-detection' -Status 'SKIPPED' -Message 'CPU detection failed.' -Inspected $false -Reason 'Win32_Processor returned no usable data.'))
    }

    Write-POConsole -Level 'INFO' -Message 'Reading processor power-management capabilities...'
    try {
        $parking = Get-POCpuParkingStatus
        $supported = @($parking.ProcessorSettings | Where-Object { $_.Supported })
        Write-POConsole -Level 'INFO' -Message ("Active plan '{0}' exposes {1} of {2} catalogued processor power setting(s)." -f $parking.ActivePlanName, $supported.Count, @($parking.ProcessorSettings).Count)
        foreach ($setting in $supported) {
            Write-POConsole -Level 'INFO' -Message ("Processor setting '{0}': AC={1} DC={2}" -f $setting.Name, $(if ($null -ne $setting.AcValue) { $setting.AcValue } else { 'n/a' }), $(if ($null -ne $setting.DcValue) { $setting.DcValue } else { 'n/a' }))
        }
        foreach ($setting in @($parking.ProcessorSettings | Where-Object { -not $_.Supported })) {
            Write-POConsole -Level 'INFO' -Message ("Processor setting '{0}' is not exposed by this system." -f $setting.Name)
        }
        if (-not $parking.CoreParkingVisible) { Write-POConsole -Level 'INFO' -Message 'Core-parking controls are not exposed by the active scheme; core parking is Windows-managed here.' }
        if ($parking.QuickCpu -and $parking.QuickCpu.Installed) { Write-POConsole -Level 'INFO' -Message "Quick CPU detected at $($parking.QuickCpu.Path). It is not launched or modified." }
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'processor-capabilities' -Status 'DIAGNOSTIC' -Message ("{0} processor power setting(s) supported on this platform." -f $supported.Count) -AfterValue $supported.Count))
    }
    catch {
        Write-POConsole -Level 'WARN' -Message "Processor power capability read failed: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'processor-capabilities' -Status 'SKIPPED' -Message 'Processor power capabilities could not be read.' -Inspected $false -Reason $_.Exception.Message))
    }

    Write-POConsole -Level 'INFO' -Message 'Detecting installed GPUs and drivers...'
    foreach ($gpu in @($snapshot.GPUs)) {
        Write-POConsole -Level 'INFO' -Message ("GPU: {0} | vendor {1} | driver {2} | mode {3} @ {4} Hz" -f $gpu.Name, $gpu.Vendor, $gpu.DriverVersion, $gpu.ResolutionReportedByAdapter, $(if ($gpu.RefreshRateReportedByAdapterHz) { $gpu.RefreshRateReportedByAdapterHz } else { 'unknown' }))
        if ($gpu.ReportedVRAMGB) { Write-POConsole -Level 'INFO' -Message ("     reported VRAM: {0} GB (adapter-reported, may be inaccurate)" -f $gpu.ReportedVRAMGB) }
    }
    if (@($snapshot.GPUs).Count -eq 0) { Write-POConsole -Level 'WARN' -Message 'Windows reported no display controller.' }
    $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'gpu-detection' -Status 'DIAGNOSTIC' -Message ("{0} display controller(s) detected." -f @($snapshot.GPUs).Count) -AfterValue @($snapshot.GPUs).Count))

    Write-POConsole -Level 'INFO' -Message 'Reading installed memory and available memory...'
    if ($snapshot.Memory) {
        Write-POConsole -Level 'INFO' -Message ("Memory: {0} GB installed | {1} GB available | {2} module(s)" -f $snapshot.Memory.TotalGB, $snapshot.Memory.AvailableGB, @($snapshot.Memory.Modules).Count)
        foreach ($module in @($snapshot.Memory.Modules)) {
            Write-POConsole -Level 'INFO' -Message ("     module {0}: {1} GB @ {2} MHz" -f $module.DeviceLocator, $module.CapacityGB, $(if ($module.SpeedMHz) { $module.SpeedMHz } else { 'unknown' }))
        }
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'memory-detection' -Status 'DIAGNOSTIC' -Message ("Memory detected: {0} GB installed, {1} GB available." -f $snapshot.Memory.TotalGB, $snapshot.Memory.AvailableGB) -AfterValue $snapshot.Memory.TotalGB))
    }

    Write-POConsole -Level 'INFO' -Message 'Inspecting storage devices and volume health...'
    foreach ($disk in @($snapshot.Storage)) {
        $mediaText = if ($disk.PSObject.Properties['MediaType'] -and $disk.MediaType) { " | media $($disk.MediaType)" } else { '' }
        $healthText = if ($disk.PSObject.Properties['StatusReportedByWMI'] -and $disk.StatusReportedByWMI) { " | status $($disk.StatusReportedByWMI)" } else { '' }
        Write-POConsole -Level 'INFO' -Message ("Disk: {0} | {1} GB{2}{3}" -f $(if ($disk.PSObject.Properties['Model']) { $disk.Model } else { 'Unknown' }, $(if ($disk.PSObject.Properties['SizeGB']) { $disk.SizeGB } else { 'unknown' }), $mediaText, $healthText))
    }
    if (@($snapshot.Storage).Count -eq 0) { Write-POConsole -Level 'INFO' -Message 'No physical disk inventory was reported by Windows.' }
    if ($snapshot.SystemVolume) {
        Write-POConsole -Level 'INFO' -Message ("System volume {0}: {1} GB free of {2} GB ({3}% free)" -f $snapshot.SystemVolume.Drive, $snapshot.SystemVolume.FreeGB, $snapshot.SystemVolume.SizeGB, $snapshot.SystemVolume.FreePercent)
    }

    Write-POConsole -Level 'INFO' -Message 'Detecting monitor refresh rates...'
    try {
        $displayInventory = Get-PODisplayInventory
        foreach ($display in @($displayInventory.Displays)) {
            $currentHz = if ($null -ne $display.RefreshRateHz) { [int]$display.RefreshRateHz } else { $null }
            $maxHz = if ($null -ne $display.HighestAvailableRefreshAtCurrentResolution) { [int]$display.HighestAvailableRefreshAtCurrentResolution } else { $null }
            Write-POConsole -Level 'INFO' -Message ("Display '{0}': {1} @ {2} Hz | highest available at this resolution: {3} Hz" -f $display.DeviceName, $display.Resolution, $(if ($currentHz) { $currentHz } else { 'unknown' }), $(if ($maxHz) { $maxHz } else { 'unknown' }))
        }
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'display-scan' -Status 'DIAGNOSTIC' -Message ("{0} display(s) enumerated." -f @($displayInventory.Displays).Count) -AfterValue @($displayInventory.Displays).Count))
    }
    catch {
        Write-POConsole -Level 'WARN' -Message "Display enumeration failed: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'display-scan' -Status 'SKIPPED' -Message 'Display enumeration failed.' -Inspected $false -Reason $_.Exception.Message))
    }

    Write-POConsole -Level 'INFO' -Message 'Inspecting network adapters and link speeds...'
    $adapters = @()
    if (Get-Command Get-PONetworkAdapterInventory -ErrorAction SilentlyContinue) {
        try {
            $adapters = @(Get-PONetworkAdapterInventory)
            foreach ($adapter in $adapters) {
                Write-POConsole -Level 'INFO' -Message ("Adapter '{0}' [{1}]: status {2} | link {3} | duplex {4}" -f $adapter.Name, $adapter.Kind, $adapter.Status, $adapter.LinkSpeed, $(if ($null -ne $adapter.FullDuplex) { $adapter.FullDuplex } else { 'unknown' }))
            }
            $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'network-adapters' -Status 'DIAGNOSTIC' -Message ("{0} network adapter(s) enumerated." -f $adapters.Count) -AfterValue $adapters.Count))
        }
        catch {
            Write-POConsole -Level 'WARN' -Message "Network adapter inventory failed: $($_.Exception.Message)"
            $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'network-adapters' -Status 'SKIPPED' -Message 'Network adapter inventory failed.' -Inspected $false -Reason $_.Exception.Message))
        }
    }
    else {
        Write-POConsole -Level 'WARN' -Message 'The Network module is not loaded; adapter inventory is unavailable.'
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'network-adapters' -Status 'SKIPPED' -Message 'Network module not loaded.' -Inspected $false -Reason 'PlatinumOptimizer.Network is not imported.'))
    }

    Write-POConsole -Level 'INFO' -Message 'Reading active power scheme...'
    $activeGuid = Get-POActivePowerPlanGuid
    $platinumInfo = $null
    try { $platinumInfo = Get-POPlatinumPlanInfo } catch { Write-POConsole -Level 'WARN' -Message "Platinum plan query failed: $($_.Exception.Message)" }
    if ($activeGuid) {
        $activeName = 'unknown'
        try {
            $entry = @(Get-POPowerPlans | Where-Object { [string]$_.Guid -eq [string]$activeGuid } | Select-Object -First 1)
            if ($entry.Count -gt 0) { $activeName = [string]$entry[0].Name }
        }
        catch { }
        Write-POConsole -Level 'INFO' -Message "Active power scheme: $activeName ($activeGuid)"
    }
    else { Write-POConsole -Level 'WARN' -Message 'The active power scheme GUID could not be read.' }
    if ($platinumInfo) {
        Write-POConsole -Level 'INFO' -Message ("'Platinum On Steroids' plan: {0}" -f $(if ($platinumInfo.Exists) { "present ($($platinumInfo.PlanGuid))" } else { 'not created yet' }))
    }
    $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'active-power-scheme' -Status 'DIAGNOSTIC' -Message "Active power scheme read: $activeGuid" -AfterValue $activeGuid))

    Write-POConsole -Level 'INFO' -Message 'Detecting game-related background activity...'
    try {
        $background = Get-POBackgroundProcessSummary -Top 5
        if ($background.ProcessCount) {
            Write-POConsole -Level 'INFO' -Message "$($background.ProcessCount) process(es) running. Largest by working set:"
            foreach ($proc in @($background.TopProcesses)) { Write-POConsole -Level 'INFO' -Message ("     {0} ({1} MB) - reported only, never terminated" -f $proc.Name, $proc.WorkingSetMB) }
        }
        $results.Add((New-POResultRecord -Stage 'SCAN' -Id 'background-activity' -Status 'DIAGNOSTIC' -Message "$($background.ProcessCount) running process(es) recorded (read-only)." -AfterValue $background.ProcessCount))
    }
    catch { Write-POConsole -Level 'WARN' -Message "Background process summary failed: $($_.Exception.Message)" }

    foreach ($warning in @($snapshot.CollectionWarnings)) {
        Write-POConsole -Level 'WARN' -Message "Detection gap: $($warning.ClassName): $($warning.Error)"
    }
    return [pscustomobject]@{ Results = $results.ToArray(); Snapshot = $snapshot }
}

# ---------------------------------------------------------------------------
# Stage: BACKUP
# ---------------------------------------------------------------------------

function Invoke-POBackupStage {
    [CmdletBinding()]
    param([AllowNull()][psobject]$Snapshot = $null)
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'BACKUP' -Title 'CONFIGURATION BACKUP AND RECOVERY PREPARATION'

    Write-POConsole -Level 'INFO' -Message 'Creating timestamped configuration backup...'
    $backup = $null
    try {
        $backup = New-POBackup
        Write-POConsole -Level 'PASS' -Message "Backup created and checksum-verified: $($backup.Path)"
        foreach ($warning in @($backup.Warnings)) { Write-POConsole -Level 'WARN' -Message "Backup warning: $warning" }
        $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'configuration-backup' -Status 'APPLIED_VERIFIED' -Attempted -Message "Configuration backup created and checksum-verified at $($backup.Path)." -AfterValue $backup.Path -Reversible $false))
    }
    catch {
        $rec = New-POResultRecord -Stage 'BACKUP' -Id 'configuration-backup' -Status 'FAILED' -Attempted -Message "Configuration backup failed: $($_.Exception.Message)"
        $results.Add($rec); Write-POResultToConsole -Result $rec
        return [pscustomobject]@{ Results = $results.ToArray(); Backup = $null }
    }
    $backupPath = [string]$backup.Path

    Write-POConsole -Level 'INFO' -Message 'Recording original power configuration...'
    $activeExport = Join-Path $backupPath 'power\active-plan.pow'
    if (Test-Path -LiteralPath $activeExport -PathType Leaf) {
        $size = (Get-Item -LiteralPath $activeExport -Force).Length
        Write-POConsole -Level 'PASS' -Message "Active power scheme exported to power\active-plan.pow ($size bytes)."
        $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-power-export' -Status 'APPLIED_VERIFIED' -Attempted -Message "Original active power scheme exported ($size bytes)." -AfterValue $size))
    }
    else {
        Write-POConsole -Level 'WARN' -Message 'The active power scheme could not be exported; power changes will be blocked.'
        $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-power-export' -Status 'FAILED' -Attempted -Message 'The active power scheme export is missing from the backup.'))
    }

    Write-POConsole -Level 'INFO' -Message 'Saving applicable registry values...'
    try {
        $registryFile = Join-Path $backupPath 'registry\game-settings-before.json'
        if (Test-Path -LiteralPath $registryFile -PathType Leaf) {
            $registryState = @(Get-Content -LiteralPath $registryFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
            foreach ($state in $registryState) {
                Write-POConsole -Level 'INFO' -Message ("     {0}\{1} = {2}" -f $state.SubKey, $state.ValueName, $(if ($state.Exists) { $state.Data } else { 'not present' }))
            }
            Write-POConsole -Level 'PASS' -Message "Registry snapshot written for $($registryState.Count) allowlisted gaming value(s)."
            $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-registry' -Status 'APPLIED_VERIFIED' -Attempted -Message "Registry snapshot captured for $($registryState.Count) allowlisted gaming value(s)." -AfterValue $registryState.Count))
        }
        else {
            Write-POConsole -Level 'WARN' -Message 'The registry snapshot file is missing from the backup.'
            $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-registry' -Status 'FAILED' -Attempted -Message 'The registry snapshot file is missing.'))
        }
    }
    catch {
        Write-POConsole -Level 'WARN' -Message "Registry snapshot verification failed: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-registry' -Status 'FAILED' -Attempted -Message "Registry snapshot verification failed: $($_.Exception.Message)"))
    }

    Write-POConsole -Level 'INFO' -Message 'Recording service and scheduled-task states...'
    try {
        $services = @(Get-POServiceAudit)
        [void](Add-POBackupFile -BackupPath $backupPath -RelativePath 'services\service-state-before.json' -Content (ConvertTo-Json -InputObject $services -Depth 6))
        Write-POConsole -Level 'PASS' -Message "$($services.Count) service state row(s) recorded."
        $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-services' -Status 'APPLIED_VERIFIED' -Attempted -Message "$($services.Count) service state row(s) recorded (read-only snapshot; no service is changed)." -AfterValue $services.Count))
    }
    catch {
        Write-POConsole -Level 'WARN' -Message "Service state capture failed: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-services' -Status 'FAILED' -Attempted -Message "Service state capture failed: $($_.Exception.Message)"))
    }
    try {
        $tasks = @(Get-POScheduledTaskAudit -MaximumTasks 500)
        [void](Add-POBackupFile -BackupPath $backupPath -RelativePath 'services\scheduled-tasks-before.json' -Content (ConvertTo-Json -InputObject $tasks -Depth 6))
        Write-POConsole -Level 'PASS' -Message "$($tasks.Count) scheduled task row(s) recorded."
        $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-scheduled-tasks' -Status 'APPLIED_VERIFIED' -Attempted -Message "$($tasks.Count) scheduled task row(s) recorded (read-only snapshot; no task is changed)." -AfterValue $tasks.Count))
    }
    catch {
        Write-POConsole -Level 'WARN' -Message "Scheduled task capture failed: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-scheduled-tasks' -Status 'FAILED' -Attempted -Message "Scheduled task capture failed: $($_.Exception.Message)"))
    }

    Write-POConsole -Level 'INFO' -Message 'Recording relevant network configuration...'
    try {
        if (Get-Command Get-PONetworkAdapterInventory -ErrorAction SilentlyContinue) {
            $adapters = @(Get-PONetworkAdapterInventory)
            [void](Add-POBackupFile -BackupPath $backupPath -RelativePath 'network\adapters-before.json' -Content (ConvertTo-Json -InputObject $adapters -Depth 6))
            Write-POConsole -Level 'PASS' -Message "$($adapters.Count) adapter configuration row(s) recorded."
            $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-network' -Status 'APPLIED_VERIFIED' -Attempted -Message "$($adapters.Count) network adapter configuration row(s) recorded." -AfterValue $adapters.Count))
        }
        else {
            Write-POConsole -Level 'WARN' -Message 'The Network module is not loaded; adapter configuration was not recorded.'
            $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-network' -Status 'SKIPPED' -Message 'Network module not loaded.' -Inspected $false -Reason 'PlatinumOptimizer.Network is not imported.'))
        }
    }
    catch {
        Write-POConsole -Level 'WARN' -Message "Network configuration capture failed: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'BACKUP' -Id 'backup-network' -Status 'FAILED' -Attempted -Message "Network configuration capture failed: $($_.Exception.Message)"))
    }

    Write-POConsole -Level 'INFO' -Message 'Attempting a Windows System Restore point (supplemental, not the primary backup)...'
    $rpRecord = Invoke-POSystemRestorePointAttempt
    $results.Add($rpRecord); Write-POResultToConsole -Result $rpRecord

    return [pscustomobject]@{ Results = $results.ToArray(); Backup = $backup }
}

function Invoke-POSystemRestorePointAttempt {
    [CmdletBinding()]
    param()
    # Supplemental protection only; the explicit backup is the primary path.
    if (-not (Test-POIsAdministrator)) {
        return (New-POResultRecord -Stage 'BACKUP' -Id 'system-restore-point' -Status 'SKIPPED' -Message 'System Restore point skipped: session is not elevated.' -Inspected $false -Reason 'Elevation is required to create a restore point.')
    }
    if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) {
        return (New-POResultRecord -Stage 'BACKUP' -Id 'system-restore-point' -Status 'SKIPPED' -Message 'Checkpoint-Computer is unavailable; the configuration backup remains the recovery path.' -Inspected $false -Reason 'Checkpoint-Computer is not present on this system.')
    }
    $config = $null
    try { $config = @(Get-CimInstance -Namespace 'root\default' -ClassName SystemRestoreConfig -ErrorAction Stop | Select-Object -First 1) } catch { }
    if ($config.Count -gt 0 -and $null -ne $config[0].PSObject.Properties['DisableSR'] -and [int]$config[0].DisableSR -eq 1) {
        return (New-POResultRecord -Stage 'BACKUP' -Id 'system-restore-point' -Status 'SKIPPED' -Message 'System Restore is disabled on this system; the configuration backup is the primary recovery path.' -Inspected $false -Reason 'SystemRestoreConfig reports DisableSR=1.')
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
            Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
            return (New-POResultRecord -Stage 'BACKUP' -Id 'system-restore-point' -Status 'UNVERIFIED' -Message 'The System Restore point did not finish within 4 minutes; its state is unknown.' -Attempted -Reason 'The restore point job timed out.')
        }
        $output = @(Receive-Job -Job $job -ErrorAction Stop)
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        if (@($output | Where-Object { [string]$_ -eq 'CREATED' }).Count -gt 0) {
            return (New-POResultRecord -Stage 'BACKUP' -Id 'system-restore-point' -Status 'APPLIED_VERIFIED' -Attempted -Message 'Windows System Restore point created (supplemental protection).' -AfterValue $description)
        }
        return (New-POResultRecord -Stage 'BACKUP' -Id 'system-restore-point' -Status 'UNVERIFIED' -Message 'Checkpoint-Computer finished but did not confirm creation.' -Attempted -Reason 'The restore point job returned no confirmation.')
    }
    catch {
        if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null }
        return (New-POResultRecord -Stage 'BACKUP' -Id 'system-restore-point' -Status 'SKIPPED' -Message "Windows did not create a restore point: $($_.Exception.Message)" -Inspected $false -Reason $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Stage: CPU
# ---------------------------------------------------------------------------

function Invoke-POCpuStage {
    [CmdletBinding()]
    param([AllowNull()][psobject]$Snapshot = $null)
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'CPU' -Title 'PROCESSOR POWER MANAGEMENT'

    Write-POConsole -Level 'INFO' -Message 'Inspecting supported processor power settings...'
    $status = $null
    try { $status = Get-POCpuParkingStatus }
    catch {
        Write-POConsole -Level 'FAIL' -Message "Processor power status could not be read: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'CPU' -Id 'processor-read' -Status 'FAILED' -Message "Processor power status read failed: $($_.Exception.Message)" -Inspected $false))
        return $results.ToArray()
    }

    $byId = @{}
    foreach ($setting in @($status.ProcessorSettings)) { $byId[[string]$setting.Id] = $setting }

    # Every processor setting the catalog knows about is inspected and reported.
    # Most are diagnostic-only: forcing them is hardware-dependent and is not
    # justified as a universal change.
    $inspectionOrder = @(
        @{ Id = 'processor-min-state'; Label = 'Minimum processor state'; Diagnostic = $false },
        @{ Id = 'processor-max-state'; Label = 'Maximum processor state'; Diagnostic = $false },
        @{ Id = 'processor-boost-policy'; Label = 'Processor performance boost policy'; Diagnostic = $true },
        @{ Id = 'system-cooling-policy'; Label = 'System cooling policy'; Diagnostic = $false },
        @{ Id = 'core-parking-max-cores'; Label = 'Core parking: maximum parked cores'; Diagnostic = $true },
        @{ Id = 'core-parking-min-cores'; Label = 'Core parking: minimum unparked cores'; Diagnostic = $true },
        @{ Id = 'core-parking-utility-distribution'; Label = 'Core parking: utility distribution'; Diagnostic = $true }
    )

    foreach ($item in $inspectionOrder) {
        $setting = if ($byId.ContainsKey($item.Id)) { $byId[$item.Id] } else { $null }
        if ($null -eq $setting) {
            Write-POConsole -Level 'SKIP' -Message "$($item.Label) : not in the power-setting catalog."
            continue
        }
        if (-not $setting.Supported) {
            Write-POConsole -Level 'SKIP' -Message "$($item.Label) : not exposed by this system's firmware/driver; left under Windows control."
            $results.Add((New-POResultRecord -Stage 'CPU' -Id $item.Id -Status 'SKIPPED' -Message "$($item.Label) : not exposed on this platform." -Inspected $false -Reason 'powercfg /qh does not report this setting for the active scheme.'))
            continue
        }
        $acText = if ($null -ne $setting.AcValue) { [string]$setting.AcValue } else { 'n/a' }
        $dcText = if ($null -ne $setting.DcValue) { [string]$setting.DcValue } else { 'n/a' }
        Write-POConsole -Level 'INFO' -Message "$($item.Label) : AC=$acText DC=$dcText (active plan)"

        if ($item.Diagnostic) {
            # The user asked for these to be inspected and explained, not forced:
            # boost/parking policy has no universal benefit across CPU
            # topologies, cooling designs and firmware.
            $note = switch ($item.Id) {
                'processor-boost-policy' { 'Boost policy is reported only. Forcing an aggressive boost raises power draw and thermals; on many designs it increases sustained throttling rather than performance.' }
                'core-parking-max-cores' { 'Core parking is reported only. Disabling parking universally is not justified: on hybrid and high-core-count CPUs it can hurt scheduling and raises idle power.' }
                'core-parking-min-cores' { 'Core parking is reported only; Windows schedules unparked cores dynamically.' }
                default { 'Reported only; the benefit is hardware, firmware and workload dependent.' }
            }
            $results.Add((New-POResultRecord -Stage 'CPU' -Id $item.Id -Status 'DIAGNOSTIC' -Message "$($item.Label) : inspected ($acText), left unchanged. $note" -BeforeValue $acText -AfterValue $acText -Reason $note))
            continue
        }

        # min/max state and cooling policy are configured on the Platinum plan
        # by the POWER stage. Here we compare the CURRENT plan against the
        # gaming preset so the report can state what will change and why.
        $preset = Get-POAutomaticPowerPresetId -SystemSnapshot $Snapshot
        $catalog = Get-POPowerSettingCatalog
        $presetEntry = @($catalog.presets | Where-Object { $_.id -eq $preset } | Select-Object -First 1)
        $targetValue = $null
        if ($presetEntry.Count -gt 0 -and $presetEntry[0].ac.PSObject.Properties[$item.Id]) { $targetValue = $presetEntry[0].ac.($item.Id) }
        if ($null -eq $targetValue) {
            Write-POConsole -Level 'INFO' -Message "$($item.Label) : the selected '$preset' preset does not define this setting; it will not be written."
            $results.Add((New-POResultRecord -Stage 'CPU' -Id $item.Id -Status 'DIAGNOSTIC' -Message "$($item.Label) : inspected ($acText); the '$preset' preset does not target it." -BeforeValue $acText -AfterValue $acText))
            continue
        }
        if ([string]$setting.AcValue -eq [string]$targetValue) {
            Write-POConsole -Level 'PASS' -Message "$($item.Label) : already at the gaming policy value ($acText)."
            $results.Add((New-POResultRecord -Stage 'CPU' -Id $item.Id -Status 'ALREADY_OPTIMIZED' -Message "$($item.Label) : already $acText, matching the '$preset' preset." -BeforeValue $acText -AfterValue $acText))
        }
        else {
            Write-POConsole -Level 'INFO' -Message "$($item.Label) : current $acText, gaming policy target $targetValue - queued for the POWER stage."
            $results.Add((New-POResultRecord -Stage 'CPU' -Id $item.Id -Status 'DIAGNOSTIC' -Message "$($item.Label) : current $acText, target $targetValue (written and verified by the POWER stage)." -BeforeValue $acText -AfterValue $targetValue -Reason 'Change is applied to the Platinum plan, not the currently active plan.'))
        }
    }

    Write-POConsole -Level 'INFO' -Message 'Comparing current configuration with the gaming preset...'
    $presetDecision = Select-POAutoPowerPreset -Snapshot $Snapshot
    if ($presetDecision.Action -eq 'apply') {
        Write-POConsole -Level 'INFO' -Message "Preset selected for this machine: '$($presetDecision.PresetId)' - $($presetDecision.Reason)"
    }
    else {
        Write-POConsole -Level 'SKIP' -Message "No preset selected: $($presetDecision.Reason)"
    }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Stage: POWER
# ---------------------------------------------------------------------------

function ConvertTo-POPowerStageRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Change,
        [string]$Bucket = ''
    )
    # Maps a Power-module ledger entry onto the engine result vocabulary.
    # Statuses are mapped one-to-one so a failed write can never be counted
    # as an applied change.
    $changeStatus = [string]$Change.Status
    $mapped = if ($Bucket -eq 'Failed') { 'FAILED' }
    elseif ($Bucket -eq 'Unverified') { 'UNVERIFIED' }
    else {
        switch -Wildcard ($changeStatus) {
            'APPLIED_VERIFIED*' { 'APPLIED_VERIFIED' }
            'ALREADY_OPTIMIZED*' { 'ALREADY_OPTIMIZED' }
            'REUSED_VERIFIED*' { 'ALREADY_OPTIMIZED' }
            'SKIPPED*' { 'SKIPPED' }
            'FAILED*' { 'FAILED' }
            'UNVERIFIED*' { 'UNVERIFIED' }
            'PARTIAL*' { 'FAILED' }
            'APPLIED_UNVERIFIED*' { 'UNVERIFIED' }
            default { 'DIAGNOSTIC' }
        }
    }
    $reason = if ($Change.PSObject.Properties['Reason']) { [string]$Change.Reason } else { '' }
    $name = if ($Change.PSObject.Properties['Name']) { [string]$Change.Name } else { [string]$Change.Id }
    return (New-POResultRecord -Stage 'POWER' -Id ([string]$Change.Id) -Status $mapped `
        -Message ("$name : " + $(if ($reason) { $reason } else { $mapped })) `
        -BeforeValue $(if ($Change.PSObject.Properties['PreviousValue']) { $Change.PreviousValue } else { $null }) `
        -AfterValue $(if ($Change.PSObject.Properties['TargetValue']) { $Change.TargetValue } else { $null }) `
        -Attempted ([bool]$Change.Attempted) -Reversible $true `
        -RequiresReboot $(if ($Change.PSObject.Properties['RequiresReboot']) { [bool]$Change.RequiresReboot } else { $false }))
}

function Invoke-POPowerStage {
    [CmdletBinding()]
    param(
        [AllowNull()][psobject]$Snapshot = $null,
        [AllowNull()][string]$BackupPath = $null
    )
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'POWER' -Title 'POWER PLAN CONFIGURATION'

    Write-POConsole -Level 'INFO' -Message 'Inspecting active power plan...'
    $activeGuid = Get-POActivePowerPlanGuid
    $activeName = 'unknown'
    try {
        $entry = @(Get-POPowerPlans | Where-Object { [string]$_.Guid -eq [string]$activeGuid } | Select-Object -First 1)
        if ($entry.Count -gt 0) { $activeName = [string]$entry[0].Name }
    }
    catch { }
    Write-POConsole -Level 'INFO' -Message "Active plan: $activeName ($activeGuid)"

    Write-POConsole -Level 'INFO' -Message "Verifying the '$(Get-POPlatinumPlanName)' power plan..."
    $platinumInfo = $null
    try {
        $platinumInfo = Get-POPlatinumPlanInfo
        Write-POConsole -Level 'INFO' -Message ("Plan state: {0}" -f $(if ($platinumInfo.Exists) { "present ($($platinumInfo.PlanGuid))" } else { 'not created yet' }))
    }
    catch { Write-POConsole -Level 'WARN' -Message "Platinum plan query failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Checking supported power settings...'
    try {
        $catalog = Get-POPowerSettingCatalog
        Write-POConsole -Level 'INFO' -Message "$($catalog.settings.Count) documented power setting(s) in the catalog across $($catalog.subgroups.PSObject.Properties.Name.Count) subgroup(s)."
    }
    catch { Write-POConsole -Level 'WARN' -Message "Power setting catalog could not be read: $($_.Exception.Message)" }

    $presetDecision = Select-POAutoPowerPreset -Snapshot $Snapshot
    if ($presetDecision.Action -eq 'skip') {
        $rec = New-POResultRecord -Stage 'POWER' -Id 'platinum-power-plan' -Status 'SKIPPED' -Message $presetDecision.Reason -Attempted $false -Reason $presetDecision.Reason
        $results.Add($rec); Write-POResultToConsole -Result $rec
        return [pscustomobject]@{ Results = $results.ToArray(); PlanResult = $null }
    }

    Write-POConsole -Level 'INFO' -Message "Applying eligible changes (preset: $($presetDecision.PresetId)) - $($presetDecision.Reason)"
    $planResult = $null
    try {
        $planResult = Invoke-POPlatinumPlanWorkflow -PresetId $presetDecision.PresetId -Activate -Confirm:$false
        if ($planResult.Changes) {
            foreach ($change in @($planResult.Changes)) {
                $rec = ConvertTo-POPowerStageRecord -Change $change
                $results.Add($rec); Write-POResultToConsole -Result $rec
            }
        }
        # Per-setting results from the preset application. These are the
        # individual processor/cooling values written to the Platinum plan,
        # each with its captured previous value, target value and read-back.
        foreach ($bucket in @('Applied', 'AlreadyOptimized', 'Skipped', 'Failed', 'Unverified')) {
            if (-not $planResult.PSObject.Properties[$bucket]) { continue }
            foreach ($change in @($planResult.$bucket)) {
                $rec = ConvertTo-POPowerStageRecord -Change $change -Bucket $bucket
                $results.Add($rec); Write-POResultToConsole -Result $rec
            }
        }
        # A plan with the right name but default settings is not "optimized".
        $verifiedSettings = @($planResult.Applied).Count + @($planResult.AlreadyOptimized).Count
        if ($verifiedSettings -eq 0 -and $planResult.Status -like 'APPLIED_VERIFIED*') {
            Write-POConsole -Level 'WARN' -Message "The '$(Get-POPlatinumPlanName)' plan exists and is active, but no preset setting could be verified on this system. A correctly named plan is not reported as fully optimized." -Stage 'POWER'
            $results.Add((New-POResultRecord -Stage 'POWER' -Id 'platinum-settings-verified' -Status 'UNVERIFIED' -Attempted -Message 'No Platinum preset setting could be verified; the plan is named and active but not proven configured.'))
        }
        else {
            Write-POConsole -Level 'PASS' -Message "$verifiedSettings power setting(s) verified at their target values on the Platinum plan." -Stage 'POWER'
        }
        if ($planResult.Status -like 'APPLIED_VERIFIED*') {
            $actionText = if ($planResult.PlanCreated) { "Created '$($planResult.PlanName)'" } else { "Reused '$($planResult.PlanName)'" }
            Write-POConsole -Level 'PASS' -Message "$actionText ($($planResult.PlanGuid)); activation: $($planResult.Activated)."
        }
        else {
            Write-POConsole -Level 'FAIL' -Message "Power plan workflow did not complete: $($planResult.Message)"
            if (@($planResult.Changes).Count -eq 0) {
                $results.Add((New-POResultRecord -Stage 'POWER' -Id 'platinum-power-plan' -Status 'FAILED' -Attempted -Message $planResult.Message))
            }
        }
    }
    catch {
        Write-POConsole -Level 'FAIL' -Message "Power plan workflow raised an error: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'POWER' -Id 'platinum-power-plan' -Status 'FAILED' -Attempted -Message "Power plan workflow failed: $($_.Exception.Message)"))
    }

    Write-POConsole -Level 'INFO' -Message 'Reading settings back to verify changes...'
    try {
        $verifyStatus = Get-POCpuParkingStatus
        $activeNow = Get-POActivePowerPlanGuid
        if ($platinumInfo -and $platinumInfo.Exists -and $activeNow -eq ([string]$platinumInfo.PlanGuid).ToLowerInvariant()) {
            Write-POConsole -Level 'PASS' -Message "Windows reports the Platinum plan as active ($activeNow)."
            $results.Add((New-POResultRecord -Stage 'POWER' -Id 'active-plan-verify' -Status 'APPLIED_VERIFIED' -Attempted -Message "Active plan verified as '$($platinumInfo.PlanGuid)'." -AfterValue $activeNow))
        }
        elseif ($planResult -and $planResult.PlanGuid -and $activeNow -eq ([string]$planResult.PlanGuid).ToLowerInvariant()) {
            Write-POConsole -Level 'PASS' -Message "Windows reports the newly configured plan as active ($activeNow)."
            $results.Add((New-POResultRecord -Stage 'POWER' -Id 'active-plan-verify' -Status 'APPLIED_VERIFIED' -Attempted -Message "Active plan verified as '$($planResult.PlanGuid)'." -AfterValue $activeNow))
        }
        else {
            Write-POConsole -Level 'WARN' -Message "The active plan reads as '$activeNow'; activation could not be confirmed."
            $results.Add((New-POResultRecord -Stage 'POWER' -Id 'active-plan-verify' -Status 'UNVERIFIED' -Attempted -Message "Active plan is '$activeNow'; Platinum activation was not confirmed." -AfterValue $activeNow))
        }
        foreach ($setting in @($verifyStatus.ProcessorSettings | Where-Object { $_.Supported })) {
            Write-POConsole -Level 'INFO' -Message ("Read-back '{0}': AC={1} DC={2}" -f $setting.Name, $(if ($null -ne $setting.AcValue) { $setting.AcValue } else { 'n/a' }), $(if ($null -ne $setting.DcValue) { $setting.DcValue } else { 'n/a' }))
        }
    }
    catch { Write-POConsole -Level 'WARN' -Message "Power setting read-back failed: $($_.Exception.Message)" }

    return [pscustomobject]@{ Results = $results.ToArray(); PlanResult = $planResult }
}

# ---------------------------------------------------------------------------
# Stage: GAMING
# ---------------------------------------------------------------------------

function Invoke-POGamingRegistrySetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Target,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    # One gaming registry value driven through Invoke-POConfigOperation.
    # The before-state is captured as a full registry state object so a failed
    # verification restores exactly what was there, including "value absent".
    $hive = [string]$Target.Hive
    $subKey = [string]$Target.SubKey
    $valueName = [string]$Target.ValueName
    $desired = [int]$Target.DesiredValue
    $targetId = [string]$Target.Id
    $label = [string]$Target.DesiredText

    $detect = { (Get-Command Set-PORegValueState -ErrorAction SilentlyContinue) -ne $null }
    $read = {
        $state = Get-PORegValueState -Hive $hive -SubKey $subKey -ValueName $valueName
        if (-not $state.Readable) { throw "the current value could not be read ($($state.ReadError))" }
        $script:POGamingBeforeState = $state
        if ($state.Exists) { [int]$state.Data } else { $null }
    }.GetNewClosure()
    $evaluate = {
        param($current)
        if ($null -ne $current -and [int]$current -eq $desired) {
            return [pscustomobject]@{ Action = 'noop'; Target = $desired; Justification = "already at the gaming policy value ($desired)" }
        }
        [pscustomobject]@{
            Action = 'apply'
            Target = $desired
            Justification = [string]$Target.Purpose
            Tradeoffs = if ($Target.RequiresSignOut) { 'Takes full effect after a Windows sign-out or restart.' } else { '' }
        }
    }.GetNewClosure()
    $apply = {
        param($wanted)
        $beforeState = $script:POGamingBeforeState
        $beforeText = if ($beforeState -and $beforeState.Exists) { "$valueName=$([int]$beforeState.Data)" } else { "$valueName not present" }
        Add-POBackupChange -BackupPath $BackupPath -Section registry -Change ([pscustomobject][ordered]@{
            section = 'registry'; id = $targetId; name = $label
            hive = $hive; subKey = $subKey; valueName = $valueName
            before = $beforeText; after = "$valueName=$([int]$wanted)"
            purpose = [string]$Target.Purpose; status = 'APPLYING'; timestampUtc = [DateTime]::UtcNow.ToString('o')
        })
        Set-PORegValueState -State ([pscustomobject][ordered]@{
            Hive = $hive; SubKey = $subKey; ValueName = $valueName
            Exists = $true; Kind = 'DWord'; Data = [int]$wanted; Readable = $true
        })
    }.GetNewClosure()
    $verify = {
        param($wanted)
        $after = Get-PORegValueState -Hive $hive -SubKey $subKey -ValueName $valueName
        $ok = ($after.Readable -and $after.Exists -and [int]$after.Data -eq [int]$wanted)
        try {
            if ($ok) {
                Update-POBackupChangeStatus -BackupPath $BackupPath -Section registry -ChangeId $targetId -Status 'APPLIED_VERIFIED' -Message "Written and verified: $valueName=$([int]$wanted)."
            }
            else {
                Update-POBackupChangeStatus -BackupPath $BackupPath -Section registry -ChangeId $targetId -Status 'UNVERIFIED' -Message 'The write was not confirmed by reading the value back.'
            }
        }
        catch { }
        [pscustomobject]@{
            Verified = $ok
            Observed = if ($after.Exists) { [int]$after.Data } else { 'absent' }
            Detail = $null
        }
    }.GetNewClosure()
    $rollback = {
        param($current)
        if ($null -ne $script:POGamingBeforeState) {
            try { Set-PORegValueState -State $script:POGamingBeforeState } catch { }
        }
        try { Update-POBackupChangeStatus -BackupPath $BackupPath -Section registry -ChangeId $targetId -Status 'FAILED' -Message 'Verification failed after the write; the original value was restored.' } catch { }
    }.GetNewClosure()

    return (Invoke-POConfigOperation -Stage 'GAMING' -Id $targetId -Name $label `
        -Detect $detect -Read $read -Evaluate $evaluate -Apply $apply -Verify $verify -Rollback $rollback `
        -BackupPath $BackupPath -RequiresBackup -AllowRollback -RequiresReboot ([bool]$Target.RequiresSignOut))
}

function Invoke-POGamingStage {
    [CmdletBinding()]
    param([AllowNull()][string]$BackupPath = $null)
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'GAMING' -Title 'WINDOWS GAMING AND BACKGROUND CONFIGURATION'

    if (-not (Get-Command Invoke-POGamingOptimization -ErrorAction SilentlyContinue)) {
        $rec = New-POResultRecord -Stage 'GAMING' -Id 'gaming-module' -Status 'SKIPPED' -Message 'Gaming module not loaded; no gaming setting was inspected.' -Inspected $false -Reason 'PlatinumOptimizer.Gaming is not imported.'
        $results.Add($rec); Write-POResultToConsole -Result $rec
        return $results.ToArray()
    }

    Write-POConsole -Level 'INFO' -Message 'Reading Windows Game Mode configuration...'
    Write-POConsole -Level 'INFO' -Message 'Reading Game Bar and background capture settings...'
    try {
        $state = @(Get-POGamingSettingsState)
        foreach ($row in $state) {
            $currentText = if ($row.Exists) { [string]$row.CurrentValue } else { 'not set' }
            Write-POConsole -Level 'INFO' -Message "$($row.Name) : current $currentText (policy target: $($row.DesiredText))"
        }
    }
    catch { Write-POConsole -Level 'WARN' -Message "Gaming settings read failed: $($_.Exception.Message)" }

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $rec = New-POResultRecord -Stage 'GAMING' -Id 'gaming-settings' -Status 'SKIPPED' -Message 'No verified backup exists; gaming registry changes are skipped (backup-first policy).' -Inspected $false -Reason 'The run backup is required before any registry write.'
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }
    else {
        # Division of responsibility: PlatinumOptimizer.Gaming owns the POLICY
        # table (which values, why, whether a sign-out is needed); this engine
        # owns the uniform execution contract, so every write in the run is
        # detected, read, justified, explained, backed up, applied, read back,
        # recorded and rolled back the same way.
        Write-POConsole -Level 'INFO' -Message 'Applying justified gaming settings through the standard operation contract...'
        try {
            foreach ($target in @(Get-POGamingSettingTargets)) {
                $rec = Invoke-POGamingRegistrySetting -Target $target -BackupPath $BackupPath
                $results.Add($rec); Write-POResultToConsole -Result $rec
            }
        }
        catch {
            $rec = New-POResultRecord -Stage 'GAMING' -Id 'gaming-settings' -Status 'FAILED' -Attempted -Message "Gaming settings stage failed: $($_.Exception.Message)"
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
    }

    Write-POConsole -Level 'INFO' -Message 'Inspecting hardware-accelerated GPU scheduling (read-only)...'
    try {
        $hags = Get-POGraphicsSchedulingStatus
        Write-POConsole -Level 'INFO' -Message "HAGS: $($hags.StatusText). $($hags.Note)"
        $results.Add((New-POResultRecord -Stage 'GAMING' -Id 'hags' -Status 'DIAGNOSTIC' -Message "HAGS inspected: $($hags.StatusText). Not changed." -AfterValue $hags.StatusText -Reason $hags.Note))
    }
    catch { Write-POConsole -Level 'WARN' -Message "HAGS status could not be read: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Inspecting startup applications (read-only impact report)...'
    try {
        $startup = @(Get-POStartupAudit)
        $enabled = @($startup | Where-Object { [string]$_.Name -ne 'No startup entries reported' })
        Write-POConsole -Level 'INFO' -Message "$($enabled.Count) startup entr(ies) registered. Nothing is disabled automatically: impact is workload specific."
        foreach ($item in @($enabled | Select-Object -First 8)) {
            Write-POConsole -Level 'INFO' -Message ("     {0} [{1}]" -f $item.Name, $(if ($item.PSObject.Properties['Location']) { $item.Location } else { 'unknown location' }))
        }
        $results.Add((New-POResultRecord -Stage 'GAMING' -Id 'startup-apps' -Status 'DIAGNOSTIC' -Message "$($enabled.Count) startup entr(ies) reported; none changed." -AfterValue $enabled.Count -Reason 'Startup impact is user and workload specific; disabling entries automatically is not justified.'))
    }
    catch { Write-POConsole -Level 'WARN' -Message "Startup audit failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Inspecting relevant scheduled tasks (read-only)...'
    try {
        $tasks = @(Get-POScheduledTaskAudit -MaximumTasks 300)
        $ready = @($tasks | Where-Object { [string]$_.State -eq 'Ready' })
        Write-POConsole -Level 'INFO' -Message "$($tasks.Count) scheduled task(s) inspected, $($ready.Count) in Ready state. No task is disabled or deleted."
        $results.Add((New-POResultRecord -Stage 'GAMING' -Id 'scheduled-tasks' -Status 'DIAGNOSTIC' -Message "$($tasks.Count) scheduled task(s) inspected; none changed." -AfterValue $tasks.Count -Reason 'Disabling system or vendor tasks by name alone is not safe or justified.'))
    }
    catch { Write-POConsole -Level 'WARN' -Message "Scheduled task audit failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Security posture: Windows Update, Microsoft Defender and the firewall are never disabled by this optimizer.'
    $results.Add((New-POResultRecord -Stage 'GAMING' -Id 'security-policy' -Status 'DIAGNOSTIC' -Message 'Defender, firewall, Windows Update and all security services were left untouched.' -Reason 'Disabling security components is explicitly out of scope.'))
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Stage: NETWORK
# ---------------------------------------------------------------------------

function Invoke-PONetworkStage {
    [CmdletBinding()]
    param(
        [AllowNull()][psobject]$Snapshot = $null,
        [AllowNull()][string]$BackupPath = $null
    )
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'NETWORK' -Title 'TCP, ETHERNET AND WI-FI DIAGNOSTICS'

    if (-not (Get-Command Get-PONetworkAdapterInventory -ErrorAction SilentlyContinue)) {
        $rec = New-POResultRecord -Stage 'NETWORK' -Id 'network-module' -Status 'SKIPPED' -Message 'Network module not loaded; no network diagnostic was run.' -Inspected $false -Reason 'PlatinumOptimizer.Network is not imported.'
        $results.Add($rec); Write-POResultToConsole -Result $rec
        return $results.ToArray()
    }

    Write-POConsole -Level 'INFO' -Message 'Detecting active network interface...'
    try {
        $adapters = @(Get-PONetworkAdapterInventory)
        foreach ($adapter in $adapters) {
            Write-POConsole -Level 'INFO' -Message ("Adapter '{0}': type {1} | status {2} | link {3} | physical {4}" -f $adapter.Name, $adapter.Kind, $adapter.Status, $adapter.LinkSpeed, $adapter.HardwareInterface)
            if ($adapter.PowerManagement) {
                Write-POConsole -Level 'INFO' -Message ("     power management: allow-turn-off={0} | WoL magic={1} | WoL pattern={2}" -f $adapter.PowerManagement.AllowComputerToTurnOffDevice, $adapter.PowerManagement.WakeOnMagicPacket, $adapter.PowerManagement.WakeOnPattern)
            }
            elseif ($adapter.PowerManagementError) { Write-POConsole -Level 'INFO' -Message "     power management: not reported ($($adapter.PowerManagementError))" }
        }
        $upAdapters = @($adapters | Where-Object { $_.Status -eq 'Up' })
        Write-POConsole -Level 'INFO' -Message "$($upAdapters.Count) adapter(s) currently connected."
        $results.Add((New-POResultRecord -Stage 'NETWORK' -Id 'adapter-inventory' -Status 'DIAGNOSTIC' -Message "$($adapters.Count) adapter(s) enumerated, $($upAdapters.Count) connected." -AfterValue $adapters.Count))
    }
    catch {
        Write-POConsole -Level 'WARN' -Message "Adapter inventory failed: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'NETWORK' -Id 'adapter-inventory' -Status 'SKIPPED' -Message 'Adapter inventory failed.' -Inspected $false -Reason $_.Exception.Message))
    }

    Write-POConsole -Level 'INFO' -Message 'Reading current IP configuration...'
    $ipConfigured = 0
    try {
        if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
            foreach ($config in @(Get-NetIPConfiguration -ErrorAction Stop)) {
                $v4 = if (@($config.IPv4Address).Count -gt 0) { [string]$config.IPv4Address[0].IPAddress } else { 'none' }
                $gw = if ($null -ne $config.IPv4DefaultGateway -and $config.IPv4DefaultGateway.NextHop) { [string]$config.IPv4DefaultGateway.NextHop } else { 'none' }
                $dnsServers = @($config.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { [string]$_.ServerAddresses }) -join ', '
                Write-POConsole -Level 'INFO' -Message ("Interface '{0}': IPv4 {1} | gateway {2} | DNS {3}" -f $config.InterfaceAlias, $v4, $gw, $(if ($dnsServers) { $dnsServers } else { 'none reported' }))
                $ipConfigured++
            }
            $results.Add((New-POResultRecord -Stage 'NETWORK' -Id 'ip-configuration' -Status 'DIAGNOSTIC' -Message "$ipConfigured interface configuration(s) read. DNS servers are reported, never changed automatically." -AfterValue $ipConfigured -Reason 'Changing DNS or IP configuration automatically is not a gaming optimization and can break connectivity.'))
        }
        else { Write-POConsole -Level 'WARN' -Message 'Get-NetIPConfiguration is unavailable; IP configuration was not read.' }
    }
    catch { Write-POConsole -Level 'WARN' -Message "IP configuration read failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Inspecting default route...'
    try {
        if (Get-Command Get-NetRoute -ErrorAction SilentlyContinue) {
            $defaultRoutes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object -Property RouteMetric | Select-Object -First 3)
            foreach ($route in $defaultRoutes) {
                Write-POConsole -Level 'INFO' -Message ("Default route: {0} via {1} (metric {2}, interface {3})" -f $route.DestinationPrefix, $route.NextHop, $route.RouteMetric, $route.InterfaceAlias)
            }
            if ($defaultRoutes.Count -eq 0) { Write-POConsole -Level 'INFO' -Message 'No IPv4 default route is configured (this machine may be offline).' }
            $results.Add((New-POResultRecord -Stage 'NETWORK' -Id 'default-route' -Status 'DIAGNOSTIC' -Message "$($defaultRoutes.Count) IPv4 default route(s) inspected." -AfterValue $defaultRoutes.Count))
        }
        else { Write-POConsole -Level 'WARN' -Message 'Get-NetRoute is unavailable; the default route was not read.' }
    }
    catch { Write-POConsole -Level 'WARN' -Message "Default route read failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Checking relevant TCP global settings...'
    try {
        $tcp = Get-POTcpGlobalState
        if ($tcp.Available) {
            Write-POConsole -Level 'INFO' -Message "TCP state source: $($tcp.Source)"
            foreach ($pair in @(
                @('Receive-window autotuning', $tcp.AutotuningLevelEffective),
                @('Autotuning (local)', $tcp.AutotuningLevel),
                @('Receive Side Scaling', $tcp.RssState),
                @('ECN capability', $tcp.EcnCapability),
                @('TCP timestamps', $tcp.Timestamps),
                @('Congestion provider', $tcp.CongestionProvider),
                @('Receive Segment Coalescing', $tcp.RscState),
                @('Initial RTO', $tcp.InitialRtoMilliseconds),
                @('Max SYN retransmissions', $tcp.MaxSynRetransmissions)
            )) {
                Write-POConsole -Level 'INFO' -Message ("     {0}: {1}" -f $pair[0], $(if ($pair[1]) { $pair[1] } else { 'not reported' }))
            }
            $results.Add((New-POResultRecord -Stage 'NETWORK' -Id 'tcp-global-read' -Status 'DIAGNOSTIC' -Message 'TCP global settings read from Windows.' -AfterValue $tcp.Source))
        }
        else {
            Write-POConsole -Level 'WARN' -Message "TCP global state could not be read: $($tcp.Error)"
            $results.Add((New-POResultRecord -Stage 'NETWORK' -Id 'tcp-global-read' -Status 'SKIPPED' -Message 'TCP global state unavailable.' -Inspected $false -Reason ([string]$tcp.Error)))
        }
    }
    catch { Write-POConsole -Level 'WARN' -Message "TCP state read failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Evaluating supported gaming-network settings...'
    try {
        $logicalProcessors = 0
        if ($Snapshot -and $Snapshot.CPU -and $Snapshot.CPU.LogicalProcessors) { $logicalProcessors = [int]$Snapshot.CPU.LogicalProcessors }
        $tcpState = Get-POTcpGlobalState
        $plan = Get-PONetworkOptimizationPlan -TcpState $tcpState -LogicalProcessors $logicalProcessors
        foreach ($item in @($plan.ReportOnly)) {
            $rec = New-POResultRecord -Stage 'NETWORK' -Id $item.Id -Status 'DIAGNOSTIC' -Message $item.Message
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
        Write-POConsole -Level 'INFO' -Message "$($plan.Actions.Count) justified correction(s), $($plan.ReportOnly.Count) report-only setting(s), $($plan.Skipped.Count) unreadable setting(s)."
    }
    catch { Write-POConsole -Level 'WARN' -Message "Network optimization plan failed: $($_.Exception.Message)" }

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $rec = New-POResultRecord -Stage 'NETWORK' -Id 'network-optimization' -Status 'SKIPPED' -Message 'No verified backup exists; network changes are skipped (backup-first policy).' -Inspected $false -Reason 'The run backup is required before any network write.'
        $results.Add($rec); Write-POResultToConsole -Result $rec
    }
    else {
        Write-POConsole -Level 'INFO' -Message 'Applying only justified and reversible changes...'
        try {
            foreach ($rec in @(Invoke-PONetworkOptimization -BackupPath $BackupPath -Snapshot $Snapshot)) {
                $stageRec = New-POResultRecord -Stage 'NETWORK' -Id $rec.Id -Status $rec.Status -Message $rec.Message `
                    -Details $rec.Details -RequiresReboot ([bool]$rec.RequiresReboot) -Reversible ([bool]$rec.Reversible) `
                    -Attempted (@('APPLIED_VERIFIED', 'FAILED', 'UNVERIFIED') -contains $rec.Status)
                $results.Add($stageRec); Write-POResultToConsole -Result $stageRec
            }
        }
        catch {
            $rec = New-POResultRecord -Stage 'NETWORK' -Id 'network-optimization' -Status 'FAILED' -Attempted -Message "Network stage failed: $($_.Exception.Message)"
            $results.Add($rec); Write-POResultToConsole -Result $rec
        }
    }

    Write-POConsole -Level 'INFO' -Message 'Running a real connectivity and latency diagnostic...'
    try {
        $latency = Get-PONetworkLatencyDiagnostic -Count 4
        if ($latency.ProbeCount -gt 0) {
            Write-POConsole -Level 'INFO' -Message "Probe target: $($latency.Target) (default gateway or first reachable hop)"
            Write-POConsole -Level 'INFO' -Message ("Result: {0} of {1} reply/replies, average {2} ms, minimum {3} ms, maximum {4} ms, loss {5}%" -f $latency.Replies, $latency.ProbeCount, $latency.AverageMs, $latency.MinimumMs, $latency.MaximumMs, $latency.LossPercent)
            Write-POConsole -Level 'WARN' -Message 'This measures the local path (gateway/first hop) only. It is NOT a game-server ping and is not a performance improvement claim.'
            $results.Add((New-POResultRecord -Stage 'NETWORK' -Id 'latency-diagnostic' -Status 'DIAGNOSTIC' -Message ("Local-path latency probe to {0}: average {1} ms, loss {2}%. Not a game-server measurement." -f $latency.Target, $latency.AverageMs, $latency.LossPercent) -AfterValue $latency.AverageMs -Reason 'Measured locally; route quality to a game server depends on the ISP, peering, distance and the server itself.'))
        }
        else {
            Write-POConsole -Level 'WARN' -Message "Latency diagnostic produced no result: $($latency.Note)"
            $results.Add((New-POResultRecord -Stage 'NETWORK' -Id 'latency-diagnostic' -Status 'SKIPPED' -Message 'No reachable probe target was found; no latency value is reported.' -Inspected $false -Reason ([string]$latency.Note)))
        }
    }
    catch { Write-POConsole -Level 'WARN' -Message "Latency diagnostic failed: $($_.Exception.Message)" }

    foreach ($note in @(Get-PONetworkReportNotes)) { Write-POConsole -Level 'INFO' -Message "Note: $note" }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Stage: GPU / DISPLAY / AUDIO
# ---------------------------------------------------------------------------

function Invoke-POGpuStage {
    [CmdletBinding()]
    param([AllowNull()][psobject]$Snapshot = $null)
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'GPU' -Title 'GRAPHICS DIAGNOSTICS'

    Write-POConsole -Level 'INFO' -Message 'Detecting graphics vendors and driver versions...'
    foreach ($gpu in @($Snapshot.GPUs)) {
        Write-POConsole -Level 'INFO' -Message ("Controller: {0}" -f $gpu.Name)
        Write-POConsole -Level 'INFO' -Message ("     vendor {0} | driver version {1} | WDDM driver date {2}" -f $gpu.Vendor, $gpu.DriverVersion, $(if ($gpu.PSObject.Properties['DriverDate'] -and $gpu.DriverDate) { $gpu.DriverDate } else { 'not reported' }))
        Write-POConsole -Level 'INFO' -Message ("     PnP device id {0}" -f $gpu.PnpDeviceId)
    }
    $results.Add((New-POResultRecord -Stage 'GPU' -Id 'gpu-inventory' -Status 'DIAGNOSTIC' -Message ("{0} graphics controller(s) inspected. Vendor driver settings are left to the vendor control panel." -f @($Snapshot.GPUs).Count) -AfterValue @($Snapshot.GPUs).Count))

    Write-POConsole -Level 'INFO' -Message 'Checking Windows graphics preferences...'
    try {
        $prefState = Get-PORegValueState -Hive CurrentUser -SubKey 'Software\Microsoft\DirectX\UserGpuPreferences' -ValueName 'DirectXUserGlobalSettings'
        if ($prefState.Readable -and $prefState.Exists) { Write-POConsole -Level 'INFO' -Message "DirectX user GPU preference string present: $($prefState.Data)" }
        elseif ($prefState.Readable) { Write-POConsole -Level 'INFO' -Message 'No per-user DirectX GPU preference override is set.' }
        else { Write-POConsole -Level 'INFO' -Message "Graphics preference key could not be read: $($prefState.ReadError)" }
        $results.Add((New-POResultRecord -Stage 'GPU' -Id 'graphics-preferences' -Status 'DIAGNOSTIC' -Message 'Windows graphics preferences inspected; nothing was changed.' -Reason 'Per-app GPU preference is a user choice in Settings > System > Display > Graphics.'))
    }
    catch { Write-POConsole -Level 'WARN' -Message "Graphics preference read failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Inspecting available GPU configuration capabilities...'
    try {
        $controls = @(Get-POGpuColorControlStatus)
        foreach ($control in $controls) { Write-POConsole -Level 'INFO' -Message "Color control: $control" }
        Write-POConsole -Level 'INFO' -Message 'No vendor saturation/vibrance value is written: those controls have no documented generic API, and existing color software is never modified.'
        $results.Add((New-POResultRecord -Stage 'GPU' -Id 'gpu-color-control' -Status 'DIAGNOSTIC' -Message "$($controls.Count) color-control capability line(s) reported. No color value was changed." -AfterValue $controls.Count -Reason 'Vendor color controls are not universally programmable; existing ICC profiles and third-party color tools are preserved.'))
    }
    catch {
        Write-POConsole -Level 'INFO' -Message 'GPU color-control detection unavailable; no color change is attempted.'
        $results.Add((New-POResultRecord -Stage 'GPU' -Id 'gpu-color-control' -Status 'SKIPPED' -Message 'Color-control detection unavailable.' -Inspected $false -Reason $_.Exception.Message))
    }
    return $results.ToArray()
}

function Invoke-PODisplayStage {
    [CmdletBinding()]
    param()
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'DISPLAY' -Title 'DISPLAY AND COLOR DIAGNOSTICS'

    Write-POConsole -Level 'INFO' -Message 'Detecting monitor refresh rates...'
    try {
        $inventory = Get-PODisplayInventory
        foreach ($display in @($inventory.Displays)) {
            $currentHz = if ($null -ne $display.RefreshRateHz) { [int]$display.RefreshRateHz } else { $null }
            $maxHz = if ($null -ne $display.HighestAvailableRefreshAtCurrentResolution) { [int]$display.HighestAvailableRefreshAtCurrentResolution } else { $null }
            Write-POConsole -Level 'INFO' -Message ("Display '{0}': {1} @ {2} Hz" -f $display.DeviceName, $display.Resolution, $(if ($currentHz) { $currentHz } else { 'unknown' }))
            if ($currentHz -and $maxHz -and $maxHz -gt $currentHz) {
                Write-POConsole -Level 'WARN' -Message ("     this display enumerates {0} Hz at the current resolution but runs at {1} Hz. Changing refresh rate is a user decision (Settings > System > Display > Advanced display); an unsupported rate can blank the screen." -f $maxHz, $currentHz)
                $script:PODisplayRefreshAdvice = "Display '$($display.DeviceName)' runs at $currentHz Hz but enumerates $maxHz Hz at the same resolution."
            }
            elseif ($currentHz) { Write-POConsole -Level 'PASS' -Message "     already at the highest refresh rate enumerated for this resolution ($currentHz Hz)." }
        }
        $results.Add((New-POResultRecord -Stage 'DISPLAY' -Id 'display-modes' -Status 'DIAGNOSTIC' -Message ("{0} display mode set(s) inspected; no mode was changed." -f @($inventory.Displays).Count) -AfterValue @($inventory.Displays).Count -Reason 'Changing display modes automatically risks a blank screen and depends on cable/monitor support.'))
    }
    catch {
        Write-POConsole -Level 'WARN' -Message "Display inventory failed: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'DISPLAY' -Id 'display-modes' -Status 'SKIPPED' -Message 'Display inventory failed.' -Inspected $false -Reason $_.Exception.Message))
    }

    Write-POConsole -Level 'INFO' -Message 'Checking the active display configuration...'
    try {
        $live = Get-PODisplayLiveStateSnapshot
        if ($live) {
            foreach ($property in @($live.PSObject.Properties)) {
                if ($property.Name -in @('CapturedAtUtc')) { continue }
                Write-POConsole -Level 'INFO' -Message ("     {0}: {1}" -f $property.Name, $(if ($null -ne $property.Value) { $property.Value } else { 'not reported' }))
            }
        }
        $results.Add((New-POResultRecord -Stage 'DISPLAY' -Id 'display-live-state' -Status 'DIAGNOSTIC' -Message 'Live display state read (gamma ramp and device state are observed, not modified).'))
    }
    catch { Write-POConsole -Level 'WARN' -Message "Live display state read failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Inspecting supported color-management capabilities...'
    try {
        $ddc = Test-PODdcCiAvailability
        foreach ($line in @($ddc)) { Write-POConsole -Level 'INFO' -Message "     $line" }
        $results.Add((New-POResultRecord -Stage 'DISPLAY' -Id 'color-management' -Status 'DIAGNOSTIC' -Message 'Color-management capability inspected. No ICC profile, gamma ramp or saturation value was changed.' -Reason 'Monitor hardware vibrance cannot be controlled universally; existing profiles and tools (e.g. PlexusX) are preserved.'))
    }
    catch {
        Write-POConsole -Level 'INFO' -Message "Color-management capability detection unavailable: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'DISPLAY' -Id 'color-management' -Status 'SKIPPED' -Message 'Color-management capability detection unavailable.' -Inspected $false -Reason $_.Exception.Message))
    }
    return $results.ToArray()
}

function Invoke-POAudioStage {
    [CmdletBinding()]
    param()
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'AUDIO' -Title 'AUDIO DEVICE DIAGNOSTICS'

    Write-POConsole -Level 'INFO' -Message 'Enumerating audio devices and driver information...'
    try {
        $inventory = Get-POAudioInventory
        foreach ($device in @($inventory.SoundDevices)) {
            Write-POConsole -Level 'INFO' -Message ("Audio device: {0} | manufacturer {1} | status {2}" -f $device.Name, $(if ($device.PSObject.Properties['Manufacturer']) { $device.Manufacturer } else { 'unknown' }), $(if ($device.PSObject.Properties['Status']) { $device.Status } else { 'unknown' }))
        }
        foreach ($endpoint in @($inventory.Endpoints)) {
            $endpointName = if ($endpoint.PSObject.Properties['FriendlyName']) { [string]$endpoint.FriendlyName } else { 'unnamed endpoint' }
            $endpointType = if ($endpoint.PSObject.Properties['ConnectionType']) { [string]$endpoint.ConnectionType } else { 'unknown' }
            $endpointStatus = if ($endpoint.PSObject.Properties['Status']) { [string]$endpoint.Status } else { 'unknown' }
            Write-POConsole -Level 'INFO' -Message ("Audio endpoint: {0} | connection {1} | status {2}" -f $endpointName, $endpointType, $endpointStatus)
        }
        if (@($inventory.SoundDevices).Count -eq 0 -and @($inventory.Endpoints).Count -eq 0) { Write-POConsole -Level 'INFO' -Message 'Windows reported no audio device.' }
        $results.Add((New-POResultRecord -Stage 'AUDIO' -Id 'audio-inventory' -Status 'DIAGNOSTIC' -Message ("{0} audio device(s) and {1} endpoint(s) inspected; no audio setting was changed." -f @($inventory.SoundDevices).Count, @($inventory.Endpoints).Count) -AfterValue @($inventory.SoundDevices).Count -Reason 'Audio latency cannot be meaningfully reduced without a measurement and a compatible exclusive-mode configuration.'))
    }
    catch {
        Write-POConsole -Level 'WARN' -Message "Audio inventory failed: $($_.Exception.Message)"
        $results.Add((New-POResultRecord -Stage 'AUDIO' -Id 'audio-inventory' -Status 'SKIPPED' -Message 'Audio inventory failed.' -Inspected $false -Reason $_.Exception.Message))
    }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Stage: MEMORY and STORAGE
# ---------------------------------------------------------------------------

function Invoke-POMemoryStorageStage {
    [CmdletBinding()]
    param([AllowNull()][psobject]$Snapshot = $null)
    $results = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'MEMORY' -Title 'MEMORY AND STORAGE DIAGNOSTICS'

    Write-POConsole -Level 'INFO' -Message 'Reading physical memory configuration...'
    if ($Snapshot -and $Snapshot.Memory) {
        Write-POConsole -Level 'INFO' -Message ("Installed: {0} GB | available: {1} GB | modules: {2}" -f $Snapshot.Memory.TotalGB, $Snapshot.Memory.AvailableGB, @($Snapshot.Memory.Modules).Count)
        $results.Add((New-POResultRecord -Stage 'MEMORY' -Id 'memory-read' -Status 'DIAGNOSTIC' -Message ("Memory inspected: {0} GB installed, {1} GB available. No memory-management value is changed." -f $Snapshot.Memory.TotalGB, $Snapshot.Memory.AvailableGB) -AfterValue $Snapshot.Memory.TotalGB -Reason 'Disabling the pagefile, memory compression or working-set trimming is not a safe or evidence-based gaming optimization.'))
    }

    Write-POConsole -Level 'INFO' -Message 'Reading pagefile configuration...'
    try {
        $pageFiles = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop)
        foreach ($pageFile in $pageFiles) {
            Write-POConsole -Level 'INFO' -Message ("Pagefile: {0} | allocated {1} MB | peak usage {2} MB" -f $pageFile.Name, $pageFile.AllocatedBaseSize, $pageFile.PeakUsage)
        }
        if ($pageFiles.Count -eq 0) { Write-POConsole -Level 'INFO' -Message 'No page file is configured (system-managed or disabled by the user).' }
        $results.Add((New-POResultRecord -Stage 'MEMORY' -Id 'pagefile' -Status 'DIAGNOSTIC' -Message "$($pageFiles.Count) page file(s) inspected; the pagefile is never disabled or resized by this optimizer." -AfterValue $pageFiles.Count))
    }
    catch { Write-POConsole -Level 'WARN' -Message "Pagefile query failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Inspecting storage devices and volumes...'
    foreach ($disk in @($Snapshot.Storage)) {
        $model = if ($disk.PSObject.Properties['Model']) { [string]$disk.Model } else { 'Unknown' }
        $size = if ($disk.PSObject.Properties['SizeGB']) { [string]$disk.SizeGB } else { 'unknown' }
        $media = if ($disk.PSObject.Properties['MediaType'] -and $disk.MediaType) { [string]$disk.MediaType } else { 'not reported' }
        $health = if ($disk.PSObject.Properties['StatusReportedByWMI'] -and $disk.StatusReportedByWMI) { [string]$disk.StatusReportedByWMI } else { 'not reported' }
        Write-POConsole -Level 'INFO' -Message ("Disk '{0}': {1} GB | media {2} | health {3}" -f $model, $size, $media, $health)
    }
    try {
        $volumes = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop | Where-Object { $_.DriveType -eq 3 })
        foreach ($volume in $volumes) {
            $freeGB = [math]::Round(([double]$volume.FreeSpace / 1GB), 2)
            $sizeGB = [math]::Round(([double]$volume.Size / 1GB), 2)
            $percent = if ($sizeGB -gt 0) { [math]::Round(($freeGB / $sizeGB) * 100, 1) } else { 0 }
            Write-POConsole -Level 'INFO' -Message ("Volume {0} ({1}): {2} GB free of {3} GB ({4}% free)" -f $volume.DeviceID, $volume.VolumeName, $freeGB, $sizeGB, $percent)
            if ($percent -lt 10) {
                Write-POConsole -Level 'WARN' -Message "     low free space degrades storage performance. Nothing is deleted automatically."
            }
        }
        $results.Add((New-POResultRecord -Stage 'MEMORY' -Id 'storage-volumes' -Status 'DIAGNOSTIC' -Message "$($volumes.Count) fixed volume(s) inspected. No file, cache or storage policy is changed." -AfterValue $volumes.Count -Reason 'Deleting caches or files is irreversible and application-specific; cleanup is left to the user.'))
    }
    catch { Write-POConsole -Level 'WARN' -Message "Volume query failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Previewing user temporary files (no deletion)...'
    try {
        $preview = Get-POUserTempPreview -MinimumAgeDays 7
        Write-POConsole -Level 'INFO' -Message ("User TEMP: {0} file(s) older than 7 days ({1} MB). Nothing is deleted: deletion is irreversible." -f $preview.FileCount, [math]::Round($preview.TotalBytes / 1MB, 1))
        $results.Add((New-POResultRecord -Stage 'MEMORY' -Id 'temp-preview' -Status 'DIAGNOSTIC' -Message "$($preview.FileCount) older TEMP file(s) previewed ($([math]::Round($preview.TotalBytes / 1MB, 1)) MB); none deleted." -AfterValue $preview.FileCount))
    }
    catch { Write-POConsole -Level 'WARN' -Message "TEMP preview failed: $($_.Exception.Message)" }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Stage: VERIFY
# ---------------------------------------------------------------------------

function Invoke-POVerifyStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][psobject[]]$Results,
        [AllowNull()][psobject]$PlanResult = $null
    )
    $verifyResults = New-Object System.Collections.Generic.List[psobject]
    Write-POStageHeader -Name 'VERIFY' -Title 'FINAL VERIFICATION'

    Write-POConsole -Level 'INFO' -Message 'Re-reading changed settings...'
    $applied = @($Results | Where-Object { $_.Status -eq 'APPLIED_VERIFIED' })
    Write-POConsole -Level 'INFO' -Message "$($applied.Count) change(s) were reported as applied and verified by their own stage re-read."

    Write-POConsole -Level 'INFO' -Message 'Comparing before-and-after values...'
    foreach ($record in $applied) {
        if ($null -ne $record.BeforeValue -and $null -ne $record.AfterValue) {
            Write-POConsole -Level 'PASS' -Message ("{0}/{1}: {2} -> {3}" -f $record.Stage, $record.Id, $record.BeforeValue, $record.AfterValue)
        }
    }

    Write-POConsole -Level 'INFO' -Message 'Verifying the active power plan independently...'
    try {
        $activeNow = Get-POActivePowerPlanGuid
        $platinumInfo = Get-POPlatinumPlanInfo
        $expected = $null
        if ($PlanResult -and $PlanResult.PlanGuid) { $expected = ([string]$PlanResult.PlanGuid).ToLowerInvariant() }
        elseif ($platinumInfo -and $platinumInfo.Exists) { $expected = ([string]$platinumInfo.PlanGuid).ToLowerInvariant() }
        if ($expected -and $activeNow -eq $expected) {
            Write-POConsole -Level 'PASS' -Message "Windows reports the Platinum plan as active ($activeNow)."
            $verifyResults.Add((New-POResultRecord -Stage 'VERIFY' -Id 'active-plan' -Status 'APPLIED_VERIFIED' -Attempted -Message "Independent read-back: active power plan is $activeNow." -AfterValue $activeNow))
        }
        elseif ($expected) {
            Write-POConsole -Level 'WARN' -Message "Independent read-back: active plan is '$activeNow', expected '$expected'."
            $verifyResults.Add((New-POResultRecord -Stage 'VERIFY' -Id 'active-plan' -Status 'UNVERIFIED' -Attempted -Message "Active plan reads as '$activeNow' rather than '$expected'." -AfterValue $activeNow))
        }
        else {
            Write-POConsole -Level 'INFO' -Message "No Platinum plan target exists for this run; active plan is '$activeNow'."
            $verifyResults.Add((New-POResultRecord -Stage 'VERIFY' -Id 'active-plan' -Status 'DIAGNOSTIC' -Message "Active plan at end of run: $activeNow" -AfterValue $activeNow))
        }

        # A plan with the correct name but default settings must not be
        # reported as optimized, so re-read the configured values too.
        if ($platinumInfo -and $platinumInfo.Exists) {
            $settings = Get-POPlatinumPowerSettingsSnapshot -PlanGuid ([string]$platinumInfo.PlanGuid)
            if ($settings) {
                foreach ($property in @($settings.PSObject.Properties)) {
                    Write-POConsole -Level 'INFO' -Message ("Platinum plan setting '{0}': {1}" -f $property.Name, $(if ($null -ne $property.Value) { $property.Value } else { 'not reported' }))
                }
                $verifyResults.Add((New-POResultRecord -Stage 'VERIFY' -Id 'platinum-settings' -Status 'DIAGNOSTIC' -Message "Platinum plan settings re-read from powercfg (name alone is not treated as proof)."))
            }
        }
    }
    catch { Write-POConsole -Level 'WARN' -Message "Power verification failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Verifying gaming registry values independently...'
    try {
        if (Get-Command Get-POGamingSettingsState -ErrorAction SilentlyContinue) {
            $gamingNow = @(Get-POGamingSettingsState)
            $appliedGaming = @($Results | Where-Object { $_.Stage -eq 'GAMING' -and $_.Status -eq 'APPLIED_VERIFIED' })
            if ($appliedGaming.Count -gt 0) {
                $mismatched = @($gamingNow | Where-Object { $_.Readable -and -not $_.MatchesDesired })
                if ($mismatched.Count -eq 0) {
                    Write-POConsole -Level 'PASS' -Message "All $($gamingNow.Count) gaming registry targets read back at their desired values."
                    $verifyResults.Add((New-POResultRecord -Stage 'VERIFY' -Id 'gaming-settings' -Status 'APPLIED_VERIFIED' -Attempted -Message "Independent re-read: all $($gamingNow.Count) gaming targets match the policy."))
                }
                else {
                    Write-POConsole -Level 'WARN' -Message "$($mismatched.Count) gaming setting(s) did not read back at the desired value."
                    $verifyResults.Add((New-POResultRecord -Stage 'VERIFY' -Id 'gaming-settings' -Status 'UNVERIFIED' -Attempted -Message "$($mismatched.Count) gaming setting(s) did not verify on independent re-read."))
                }
            }
            else { Write-POConsole -Level 'INFO' -Message 'No gaming change was applied in this run; nothing to re-verify.' }
        }
    }
    catch { Write-POConsole -Level 'WARN' -Message "Gaming verification failed: $($_.Exception.Message)" }

    Write-POConsole -Level 'INFO' -Message 'Checking for failed operations...'
    $failed = @($Results | Where-Object { $_.Status -eq 'FAILED' })
    $unverified = @($Results | Where-Object { $_.Status -eq 'UNVERIFIED' })
    if ($failed.Count -eq 0) { Write-POConsole -Level 'PASS' -Message 'No operation reported a hard failure.' }
    else { foreach ($item in $failed) { Write-POConsole -Level 'FAIL' -Message "Failed: $($item.Stage)/$($item.Id) - $($item.Message)" } }
    if ($unverified.Count -gt 0) { foreach ($item in $unverified) { Write-POConsole -Level 'WARN' -Message "Unverified: $($item.Stage)/$($item.Id) - $($item.Message)" } }

    Write-POConsole -Level 'INFO' -Message 'Generating a final evidence-based report...'
    return $verifyResults.ToArray()
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

function Show-POFinalReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Summary,
        [AllowNull()][string]$BackupPath,
        [AllowNull()][string]$LogDir,
        [AllowNull()][string]$ReportPath,
        [AllowNull()][psobject]$MachineInfo,
        [string[]]$NextSteps = @(),
        [string[]]$Notes = @(),
        [AllowEmptyCollection()][psobject[]]$Measurements = @(),
        [AllowNull()][psobject]$ModuleReport = $null
    )
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor White
    Write-Host '                     FINAL OPTIMIZATION REPORT' -ForegroundColor White
    Write-Host '============================================================' -ForegroundColor White
    Write-Host ''
    Write-Host '--- Detected system -------------------------------------------------' -ForegroundColor DarkGray
    if ($MachineInfo) {
        Write-Host ("  Windows : {0}" -f $MachineInfo.OS)
        Write-Host ("  Device  : {0}" -f $MachineInfo.Device)
        Write-Host ("  CPU     : {0}" -f $MachineInfo.CPU)
        Write-Host ("  Memory  : {0} GB" -f $MachineInfo.MemoryGB)
        foreach ($gpu in @($MachineInfo.GPUs)) { Write-Host ("  GPU     : {0}" -f $gpu) }
    }
    Write-Host ''
    Write-Host '--- Modules ---------------------------------------------------------' -ForegroundColor DarkGray
    if ($ModuleReport) {
        Write-Host ("  Discovered : {0}" -f $ModuleReport.Discovered)
        Write-Host ("  Executed   : {0}" -f ($ModuleReport.Executed -join ', '))
        if (@($ModuleReport.NotExecuted).Count -gt 0) { Write-Host ("  Not run    : {0}" -f ($ModuleReport.NotExecuted -join ', ')) -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host '--- Results ---------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ("  Settings inspected                 : {0}" -f $Summary.Inspected)
    Write-Host ("  Changes attempted                  : {0}" -f $Summary.Attempted)
    Write-Host ("  Applied and verified               : {0}" -f $Summary.Applied) -ForegroundColor Green
    Write-Host ("  Already matched the gaming policy  : {0}" -f $Summary.AlreadyOptimized) -ForegroundColor Green
    Write-Host ("  Diagnostic only (no change)        : {0}" -f $Summary.DiagnosticOnly) -ForegroundColor Gray
    Write-Host ("  Skipped                            : {0}" -f $Summary.Skipped) -ForegroundColor Cyan
    Write-Host ("  Failed                             : {0}" -f $Summary.Failed) -ForegroundColor $(if ($Summary.Failed -gt 0) { 'Red' } else { 'Green' })
    Write-Host ("  Unverified (NOT counted as success): {0}" -f $Summary.Unverified) -ForegroundColor $(if ($Summary.Unverified -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host ("  Rolled back                        : {0}" -f $Summary.RolledBack) -ForegroundColor $(if ($Summary.RolledBack -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host ("  Informational                      : {0}" -f $Summary.Informational) -ForegroundColor Gray
    if ($Summary.Skipped -gt 0) {
        Write-Host ''
        Write-Host '  Skip reasons:' -ForegroundColor Cyan
        foreach ($item in @($Summary.SkippedWithReasons | Select-Object -First 20)) {
            Write-Host ("    - {0}: {1}" -f $item.Id, $item.Reason) -ForegroundColor DarkGray
        }
    }
    if ($Summary.Failed -gt 0) { Write-Host ("  Failed operations: {0}" -f ($Summary.FailedIds -join ', ')) -ForegroundColor Red }
    if ($Summary.Unverified -gt 0) { Write-Host ("  Unverified operations: {0}" -f ($Summary.UnverifiedIds -join ', ')) -ForegroundColor Yellow }

    Write-Host ''
    Write-Host '--- Measured values (genuinely collected) ----------------------------' -ForegroundColor DarkGray
    $measured = @($Measurements)
    if ($measured.Count -eq 0) {
        Write-Host '  No before/after measurement pair was collected in this run.' -ForegroundColor DarkGray
    }
    else {
        foreach ($item in $measured) {
            Write-Host ("  {0}: {1} -> {2} {3}" -f $item.Name, $(if ($null -ne $item.Before) { $item.Before } else { 'n/a' }), $(if ($null -ne $item.After) { $item.After } else { 'n/a' }), $item.Unit)
            if ($item.Note) { Write-Host ("      {0}" -f $item.Note) -ForegroundColor DarkGray }
        }
    }
    Write-Host '  These are operating-system counters, not FPS, frame time or ping.' -ForegroundColor DarkGray

    Write-Host ''
    Write-Host '--- Locations --------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ("  Backup     : {0}" -f $(if ($BackupPath) { $BackupPath } else { 'None created (no change stage ran)' }))
    Write-Host ("  Log        : {0}" -f $(if ($LogDir) { $LogDir } else { 'JSONL log only (run log unavailable)' }))
    Write-Host ("  JSON report: {0}" -f $(if ($ReportPath) { $ReportPath } else { 'not written' }))
    Write-Host ("  Restart    : {0}" -f $(if ($Summary.RebootRecommended) { 'Recommended - some settings need a restart or sign-out to fully apply.' } else { 'Not required for the changes that were verified.' }))

    if (@($NextSteps).Count -gt 0) {
        Write-Host ''
        Write-Host 'Recommended next steps:' -ForegroundColor White
        foreach ($step in $NextSteps) { Write-Host ("  - {0}" -f $step) }
    }
    if (@($Notes).Count -gt 0) {
        Write-Host ''
        Write-Host 'Known limitations and honest notes:' -ForegroundColor White
        foreach ($note in $Notes) { Write-Host ("  - {0}" -f $note) }
    }
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor White
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
        [string[]]$NextSteps = @(),
        [AllowEmptyCollection()][psobject[]]$Measurements = @(),
        [AllowNull()][psobject]$ModuleReport = $null
    )
    $report = [pscustomobject][ordered]@{
        schemaVersion = 2
        application = 'Platinum Optimizer On Steroids'
        applicationVersion = Get-POEngineVersion
        mode = $Mode
        startedUtc = [string]$script:PORunStartedUtc
        finishedUtc = [DateTime]::UtcNow.ToString('o')
        administrator = (Test-POIsAdministrator)
        machine = $MachineInfo
        modules = $ModuleReport
        backupPath = $BackupPath
        runLogDir = $LogDir
        measurements = @($Measurements)
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

# ---------------------------------------------------------------------------
# Preset selection (pure, hardware aware)
# ---------------------------------------------------------------------------

function Select-POAutoPowerPreset {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Snapshot)
    if ($null -eq $Snapshot) {
        return [pscustomobject]@{ Action = 'skip'; PresetId = $null; Reason = 'No hardware snapshot is available; the power-plan change is blocked.' }
    }
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

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Invoke-POFullOptimization {
    [CmdletBinding()]
    param()
    $script:PORunStartedUtc = [DateTime]::UtcNow.ToString('o')
    $script:POStageIndex = 0
    $script:POOperationIndex = 0
    $script:POMeasurements = New-Object System.Collections.ArrayList
    $runLog = Start-PORunLog -Mode 'optimize'
    $results = New-Object System.Collections.Generic.List[psobject]
    $runBackupPath = $null
    $machineInfo = $null
    $planResult = $null
    $stageNames = New-Object System.Collections.ArrayList

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '        PLATINUM OPTIMIZER ON STEROIDS  v' -NoNewline -ForegroundColor White
    Write-Host (Get-POEngineVersion) -ForegroundColor Gray
    Write-Host '           AUTOMATIC GAMING OPTIMIZATION ENGINE' -ForegroundColor White
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ("Started: {0}" -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host ("Log:     {0}" -f $(if ($runLog.RunLogPath) { $runLog.RunLogPath } else { 'unavailable' })) -ForegroundColor DarkGray

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # --- BOOT ---------------------------------------------------------------
    foreach ($rec in @(Invoke-POBootStage)) { $results.Add($rec) }
    [void]$stageNames.Add('BOOT')

    $adminFailed = @($results | Where-Object { $_.Id -eq 'administrator-token' -and $_.Status -eq 'FAILED' })
    if ($adminFailed.Count -gt 0) {
        Write-POConsole -Level 'FAIL' -Message 'Administrator privileges are required. No system change was attempted.' -Stage 'BOOT'
        $summary = Get-POReportSummary -Results $results.ToArray()
        Show-POFinalReport -Summary $summary -BackupPath $null -LogDir $runLog.LogDir -ReportPath $null -MachineInfo $null `
            -NextSteps @('Right-click PlatinumOptimizer.bat and choose "Run as administrator", or accept the Windows UAC prompt.') `
            -Notes @('No system setting was inspected or changed because the session was not elevated.')
        return [pscustomobject]@{ ExitCode = 5; Results = $results.ToArray(); Summary = $summary; BackupPath = $null; LogDir = $runLog.LogDir; NextSteps = @() }
    }

    # --- SCAN ---------------------------------------------------------------
    $scan = Invoke-POScanStage
    foreach ($rec in @($scan.Results)) { $results.Add($rec) }
    [void]$stageNames.Add('SCAN')
    $snapshot = $scan.Snapshot
    if ($null -eq $snapshot -or -not $snapshot.OS.Supported) {
        Write-POConsole -Level 'FAIL' -Message 'System detection failed or Windows is unsupported; stopping before any change.' -Stage 'SCAN'
        $summary = Get-POReportSummary -Results $results.ToArray()
        [void](Save-PORunReport -LogDir $runLog.LogDir -Mode 'optimize' -Summary $summary -Results $results.ToArray())
        Show-POFinalReport -Summary $summary -BackupPath $null -LogDir $runLog.LogDir -ReportPath (Join-Path $runLog.LogDir 'report.json') -MachineInfo $null
        return [pscustomobject]@{ ExitCode = 2; Results = $results.ToArray(); Summary = $summary; BackupPath = $null; LogDir = $runLog.LogDir; NextSteps = @() }
    }

    $machineInfo = [pscustomobject][ordered]@{
        OS = "$($snapshot.OS.Name) | Build $($snapshot.OS.Build) | $($snapshot.OS.Architecture)"
        Device = "$($snapshot.Device.Manufacturer) $($snapshot.Device.Model) | $($snapshot.Device.FormFactor) | Power: $($snapshot.Device.PowerSource)"
        CPU = if ($snapshot.CPU) { "$($snapshot.CPU.Model) | cores $($snapshot.CPU.PhysicalCores) | logical $($snapshot.CPU.LogicalProcessors)" } else { 'Unknown' }
        MemoryGB = if ($snapshot.Memory) { $snapshot.Memory.TotalGB } else { $null }
        GPUs = @($snapshot.GPUs | ForEach-Object { "$($_.Name) [$($_.Vendor)] driver $($_.DriverVersion)" })
    }

    # Genuine before-sample of OS counters.
    $beforeSample = $null
    try { $beforeSample = Get-POResourceSample } catch { }
    if ($beforeSample) {
        Write-POConsole -Level 'INFO' -Message ("Baseline OS counters: CPU {0}% | available RAM {1} GB | disk active {2}%" -f $(if ($null -ne $beforeSample.CpuPercent) { $beforeSample.CpuPercent } else { 'n/a' }), $(if ($null -ne $beforeSample.AvailableMemoryGB) { $beforeSample.AvailableMemoryGB } else { 'n/a' }), $(if ($null -ne $beforeSample.DiskActivePercent) { $beforeSample.DiskActivePercent } else { 'n/a' })) -Stage 'SCAN'
    }

    # --- BACKUP -------------------------------------------------------------
    $backupStage = Invoke-POBackupStage -Snapshot $snapshot
    foreach ($rec in @($backupStage.Results)) { $results.Add($rec) }
    [void]$stageNames.Add('BACKUP')
    if ($backupStage.Backup) { $runBackupPath = [string]$backupStage.Backup.Path }

    # --- CPU ----------------------------------------------------------------
    foreach ($rec in @(Invoke-POCpuStage -Snapshot $snapshot)) { $results.Add($rec) }
    [void]$stageNames.Add('CPU')

    # --- POWER --------------------------------------------------------------
    $powerStage = Invoke-POPowerStage -Snapshot $snapshot -BackupPath $runBackupPath
    foreach ($rec in @($powerStage.Results)) { $results.Add($rec) }
    [void]$stageNames.Add('POWER')
    $planResult = $powerStage.PlanResult

    # --- GAMING -------------------------------------------------------------
    foreach ($rec in @(Invoke-POGamingStage -BackupPath $runBackupPath)) { $results.Add($rec) }
    [void]$stageNames.Add('GAMING')

    # --- NETWORK ------------------------------------------------------------
    foreach ($rec in @(Invoke-PONetworkStage -Snapshot $snapshot -BackupPath $runBackupPath)) { $results.Add($rec) }
    [void]$stageNames.Add('NETWORK')

    # --- GPU / DISPLAY / AUDIO ----------------------------------------------
    foreach ($rec in @(Invoke-POGpuStage -Snapshot $snapshot)) { $results.Add($rec) }
    [void]$stageNames.Add('GPU')
    foreach ($rec in @(Invoke-PODisplayStage)) { $results.Add($rec) }
    [void]$stageNames.Add('DISPLAY')
    foreach ($rec in @(Invoke-POAudioStage)) { $results.Add($rec) }
    [void]$stageNames.Add('AUDIO')

    # --- MEMORY / STORAGE ---------------------------------------------------
    foreach ($rec in @(Invoke-POMemoryStorageStage -Snapshot $snapshot)) { $results.Add($rec) }
    [void]$stageNames.Add('MEMORY')

    # --- VERIFY -------------------------------------------------------------
    foreach ($rec in @(Invoke-POVerifyStage -Results $results.ToArray() -PlanResult $planResult)) { $results.Add($rec) }
    [void]$stageNames.Add('VERIFY')

    # --- After measurement --------------------------------------------------
    try {
        $afterSample = Get-POResourceSample
        if ($beforeSample -and $afterSample) {
            if ($null -ne $beforeSample.CpuPercent -and $null -ne $afterSample.CpuPercent) {
                [void](Add-POMeasurement -Name 'CPU utilisation' -Before $beforeSample.CpuPercent -After $afterSample.CpuPercent -Unit '%' -Note 'Short OS counter sample taken at the start and end of this run. It is not a benchmark and not a gaming measurement.')
            }
            if ($null -ne $beforeSample.AvailableMemoryGB -and $null -ne $afterSample.AvailableMemoryGB) {
                [void](Add-POMeasurement -Name 'Available physical memory' -Before $beforeSample.AvailableMemoryGB -After $afterSample.AvailableMemoryGB -Unit 'GB' -Note 'Free RAM at the start and end of the run.')
            }
            if ($null -ne $beforeSample.DiskActivePercent -and $null -ne $afterSample.DiskActivePercent) {
                [void](Add-POMeasurement -Name 'Disk active time' -Before $beforeSample.DiskActivePercent -After $afterSample.DiskActivePercent -Unit '%' -Note 'Short OS counter sample.')
            }
        }
    }
    catch { }

    # --- Configuration before/after pairs that were genuinely observed -------
    foreach ($record in @($results | Where-Object { $_.Status -eq 'APPLIED_VERIFIED' -and $null -ne $_.BeforeValue -and $null -ne $_.AfterValue })) {
        [void](Add-POMeasurement -Name "$($record.Stage)/$($record.Id)" -Before $record.BeforeValue -After $record.AfterValue -Unit '' -Note 'Configuration value read before the write and re-read after it.')
    }

    $sw.Stop()
    $summary = Get-POReportSummary -Results $results.ToArray()

    # Report which categories actually ran. A module that failed to load in
    # the BOOT stage is listed as not executed rather than silently omitted.
    $notLoaded = @($results | Where-Object { $_.Id -like 'module-*' -and $_.Status -eq 'FAILED' } |
        ForEach-Object { ([string]$_.Id) -replace '^module-', '' })
    $moduleReport = [pscustomobject][ordered]@{
        Discovered = $script:PORequiredModules.Count
        Expected = @($script:PORequiredModules)
        Executed = @($stageNames.ToArray())
        ExecutedCount = $stageNames.Count
        NotExecuted = @($notLoaded)
        AllLoaded = ($notLoaded.Count -eq 0)
    }

    $nextSteps = @()
    if ($script:PODisplayRefreshAdvice) { $nextSteps += "$($script:PODisplayRefreshAdvice) Change it in Settings > System > Display > Advanced display only if your monitor and cable support it." }
    if ($summary.RebootRecommended) { $nextSteps += 'Restart Windows (or sign out and back in) so capture-related settings fully apply.' }
    if ($runBackupPath) { $nextSteps += 'Undo every recorded change with "PlatinumOptimizer.bat --restore".' }
    $nextSteps += 'Measure honestly: FPS, frame time and ping must come from a real in-game benchmark; this optimizer does not claim them.'

    $notes = @()
    if (Get-Command Get-PONetworkReportNotes -ErrorAction SilentlyContinue) { $notes += @(Get-PONetworkReportNotes) }
    $notes += 'No FPS, frame-time, latency or ping improvement is claimed. Results depend on hardware, drivers, the game and the server.'
    $notes += 'Core parking, processor boost policy, GPU driver values, memory-management policy, services, startup entries and display modes are inspected but deliberately not forced.'
    $notes += 'Windows Update, Microsoft Defender, the firewall and all security services are never disabled.'
    $notes += "Run duration: $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s. Every line above corresponds to an operation that was actually executed."

    $reportPath = Save-PORunReport -LogDir $runLog.LogDir -Mode 'optimize' -Summary $summary -Results $results.ToArray() `
        -BackupPath $runBackupPath -MachineInfo $machineInfo -NextSteps $nextSteps -Measurements @($script:POMeasurements.ToArray()) -ModuleReport $moduleReport

    Show-POFinalReport -Summary $summary -BackupPath $runBackupPath -LogDir $runLog.LogDir -ReportPath $reportPath `
        -MachineInfo $machineInfo -NextSteps $nextSteps -Notes $notes -Measurements @($script:POMeasurements.ToArray()) -ModuleReport $moduleReport

    try { Write-POLog -Category 'Engine' -Status 'RUN_COMPLETE' -Message ("Automatic run finished: inspected {0}, attempted {1}, applied {2}, already {3}, diagnostic {4}, skipped {5}, failed {6}, unverified {7}, rolled back {8}." -f $summary.Inspected, $summary.Attempted, $summary.Applied, $summary.AlreadyOptimized, $summary.DiagnosticOnly, $summary.Skipped, $summary.Failed, $summary.Unverified, $summary.RolledBack) } catch { }

    $exitCode = 0
    if ($summary.Failed -gt 0 -or $summary.Unverified -gt 0) { $exitCode = 1 }
    return [pscustomobject]@{ ExitCode = $exitCode; Results = $results.ToArray(); Summary = $summary; BackupPath = $runBackupPath; LogDir = $runLog.LogDir; ReportPath = $reportPath; NextSteps = $nextSteps }
}

# ---------------------------------------------------------------------------
# Restore and benchmark modes
# ---------------------------------------------------------------------------

function Select-PORestoreBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][psobject[]]$Backups,
        [AllowNull()][string]$BackupId
    )
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
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor White
    Write-Host '      PLATINUM OPTIMIZER ON STEROIDS - RESTORE MODE' -ForegroundColor White
    Write-Host '============================================================' -ForegroundColor White
    Write-Host ''
    if (-not (Test-POIsWindows)) {
        Write-POConsole -Level 'FAIL' -Message 'Restore is available only on Windows.' -Stage 'RESTORE'
        return [pscustomobject]@{ ExitCode = 2 }
    }
    $backups = @(Get-POBackups)
    foreach ($backup in $backups) {
        Write-POConsole -Level 'INFO' -Message "Found backup $($backup.Id) [$($backup.Status)] changes: $(if ($backup.ChangeCount -gt 0) { $backup.Changes } else { 'none recorded' }) at $($backup.Path)" -Stage 'RESTORE'
    }
    $selection = Select-PORestoreBackup -Backups $backups -BackupId $BackupId
    if ($null -eq $selection.Selected) {
        Write-POConsole -Level 'WARN' -Message $selection.Reason -Stage 'RESTORE'
        return [pscustomobject]@{ ExitCode = 1 }
    }
    $chosen = $selection.Selected
    Write-POConsole -Level 'INFO' -Message "Restoring recorded changes from $($chosen.Id) (only sections this application changed; the manifest is validated first)..." -Stage 'RESTORE'
    try {
        $result = Restore-POBackup -BackupPath $chosen.Path -Confirm:$false
        if ($result.Status -eq 'RESTORED') {
            Write-POConsole -Level 'PASS' -Message "Restored and verified section(s): $(@($result.Restored) -join ', ')." -Stage 'RESTORE'
            try { Write-POLog -Category 'Engine' -Status 'RESTORE_COMPLETE' -Message "Restored backup $($chosen.Id): $(@($result.Restored) -join ', ')." } catch { }
            return [pscustomobject]@{ ExitCode = 0 }
        }
        if ($result.Status -eq 'NO_CHANGES') {
            Write-POConsole -Level 'INFO' -Message $result.Message -Stage 'RESTORE'
            return [pscustomobject]@{ ExitCode = 0 }
        }
        Write-POConsole -Level 'FAIL' -Message "Restore stopped: $($result.Message)" -Stage 'RESTORE'
        foreach ($failure in @($result.Failures)) { Write-POConsole -Level 'FAIL' -Message $failure -Stage 'RESTORE' }
        return [pscustomobject]@{ ExitCode = 1 }
    }
    catch {
        Write-POConsole -Level 'FAIL' -Message "Restore failed: $($_.Exception.Message)" -Stage 'RESTORE'
        return [pscustomobject]@{ ExitCode = 1 }
    }
}

function Invoke-POBenchmarkMode {
    [CmdletBinding()]
    param([AllowNull()][string]$Target, [ValidateRange(1, 30)][int]$SampleSeconds = 8)
    $script:PORunStartedUtc = [DateTime]::UtcNow.ToString('o')
    $runLog = Start-PORunLog -Mode 'benchmark'
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor White
    Write-Host '     PLATINUM OPTIMIZER ON STEROIDS - BENCHMARK MODE' -ForegroundColor White
    Write-Host '============================================================' -ForegroundColor White
    Write-Host ''
    Write-POConsole -Level 'INFO' -Message "Sampling system counters for $SampleSeconds second(s). No system setting is changed in this mode." -Stage 'BENCHMARK'
    if (-not (Test-POIsWindows)) {
        Write-POConsole -Level 'FAIL' -Message 'Benchmark mode is available only on Windows.' -Stage 'BENCHMARK'
        return [pscustomobject]@{ ExitCode = 2 }
    }
    try {
        $usePing = -not [string]::IsNullOrWhiteSpace($Target)
        $benchParams = @{ SampleSeconds = $SampleSeconds }
        if ($usePing) { $benchParams['IncludeNetworkPing'] = $true; $benchParams['NetworkHost'] = [string]$Target }
        $snapshot = Get-POBenchmarkSnapshot @benchParams
        $path = Save-POBenchmarkSnapshot -Label 'standalone' -Snapshot $snapshot
        $m = $snapshot.Metrics
        Write-POConsole -Level 'INFO' -Message ("CPU usage: {0}% | RAM available: {1} GB | commit: {2} GB" -f $(if ($null -ne $m.CpuUsagePercent) { $m.CpuUsagePercent } else { 'unavailable' }), $(if ($null -ne $m.RamAvailableGB) { $m.RamAvailableGB } else { 'unavailable' }), $(if ($null -ne $m.MemoryCommitGB) { $m.MemoryCommitGB } else { 'unavailable' })) -Stage 'BENCHMARK'
        Write-POConsole -Level 'INFO' -Message ("Disk active: {0}% | DPC time: {1}% | interrupt time: {2}%" -f $(if ($null -ne $m.DiskPercentTime) { $m.DiskPercentTime } else { 'unavailable' }), $(if ($null -ne $m.DpcTimePercent) { $m.DpcTimePercent } else { 'unavailable' }), $(if ($null -ne $m.InterruptTimePercent) { $m.InterruptTimePercent } else { 'unavailable' })) -Stage 'BENCHMARK'
        Write-POConsole -Level 'INFO' -Message 'GPU usage: not measured by the generic CIM path | FPS/frame time: not measured (no game injection)' -Stage 'BENCHMARK'
        if ($usePing -and $m.NetworkPing) {
            Write-POConsole -Level 'INFO' -Message ("ICMP to {0}: avg {1} ms, loss {2}%. ICMP is not a game-server route measurement." -f $m.NetworkPing.Target, $(if ($null -ne $m.NetworkPing.AverageMs) { $m.NetworkPing.AverageMs } else { 'n/a' }), $(if ($null -ne $m.NetworkPing.PacketLossPercent) { $m.NetworkPing.PacketLossPercent } else { 'n/a' })) -Stage 'BENCHMARK'
        }
        Write-POConsole -Level 'PASS' -Message "Snapshot saved: $path" -Stage 'BENCHMARK'
        Write-POConsole -Level 'INFO' -Message 'These are short system observations, not a controlled gameplay benchmark.' -Stage 'BENCHMARK'
        return [pscustomobject]@{ ExitCode = 0 }
    }
    catch {
        Write-POConsole -Level 'FAIL' -Message "Benchmark sampling failed: $($_.Exception.Message)" -Stage 'BENCHMARK'
        return [pscustomobject]@{ ExitCode = 1 }
    }
}

Export-ModuleMember -Function @(
    'Get-POEngineVersion', 'Get-POConsoleTimestamp', 'Set-POConsoleStage', 'Get-POConsoleStage',
    'Write-POStageHeader', 'Write-PORawLog', 'Write-POConsole', 'Write-POCommand', 'Add-POMeasurement',
    'Get-PORunLogRoot', 'Start-PORunLog', 'New-POResultRecord', 'Write-POResultToConsole',
    'Get-POReportSummary', 'Invoke-POConfigOperation',
    'Invoke-POBootStage', 'Invoke-POScanStage', 'Invoke-POBackupStage', 'Invoke-POSystemRestorePointAttempt',
    'ConvertTo-POPowerStageRecord',
    'Invoke-POGamingRegistrySetting',
    'Invoke-POCpuStage', 'Invoke-POPowerStage', 'Invoke-POGamingStage', 'Invoke-PONetworkStage',
    'Invoke-POGpuStage', 'Invoke-PODisplayStage', 'Invoke-POAudioStage', 'Invoke-POMemoryStorageStage',
    'Invoke-POVerifyStage', 'Select-POAutoPowerPreset', 'Show-POFinalReport', 'Save-PORunReport',
    'Invoke-POFullOptimization', 'Select-PORestoreBackup', 'Invoke-PORestoreMode', 'Invoke-POBenchmarkMode'
)
