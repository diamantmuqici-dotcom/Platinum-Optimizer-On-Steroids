#requires -Version 5.1
# Platinum Optimizer On Steroids - automatic CMD engine entry point (v2.0).
# There is no graphical interface: the Command Prompt console is the entire
# user interface. Default mode runs the complete optimization pipeline
# automatically without any category-selection menu.
[CmdletBinding()]
param(
    [switch]$Scan,
    [switch]$SelfTest,
    [switch]$Restore,
    [AllowNull()][string]$RestoreId,
    [switch]$Benchmark,
    [AllowNull()][string]$Target,
    [ValidateRange(1, 30)][int]$SampleSeconds = 8,
    [switch]$ShowVersion,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Core.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Power.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Audio.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Display.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Network.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Gaming.psm1') -Global -Force -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'core\PlatinumOptimizer.Engine.psm1') -Global -Force -ErrorAction Stop

if ($ShowVersion) {
    Write-Host ("Platinum Optimizer On Steroids v{0} (CMD engine)" -f (Get-POEngineVersion))
    exit 0
}

if ($SelfTest) {
    & (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\Run-Tests.ps1')
    exit $LASTEXITCODE
}

if ($Scan) {
    # Read-only hardware/Windows snapshot as JSON. No elevation required.
    $snapshot = Get-POSystemSnapshot
    $snapshot | ConvertTo-Json -Depth 10
    exit 0
}

if ($Benchmark) {
    # Diagnostic mode: measures, changes nothing. No elevation required.
    $benchmark = Invoke-POBenchmarkMode -Target $Target -SampleSeconds $SampleSeconds
    exit [int]$benchmark.ExitCode
}

if (-not (Test-POIsWindows)) {
    Write-Host '[FAIL] Platinum Optimizer requires Windows 10/11 and Windows PowerShell 5.1.' -ForegroundColor Red
    exit 2
}

if (-not (Test-POIsAdministrator)) {
    if ($NoElevate) {
        Write-Host '[FAIL] Administrator privileges are required and elevation is disabled (-NoElevate).' -ForegroundColor Red
        exit 4
    }
    Write-Host '[INFO] Administrator privileges are required.' -ForegroundColor Gray
    Write-Host '[INFO] Windows will now show a UAC confirmation prompt. This is a normal' -ForegroundColor Gray
    Write-Host '[INFO] Windows security mechanism. Select Yes to continue.' -ForegroundColor Gray
    $childArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-NoElevate')
    if ($Restore) {
        $childArgs += '-Restore'
        if (-not [string]::IsNullOrWhiteSpace($RestoreId)) { $childArgs += @('-RestoreId', ('"{0}"' -f $RestoreId)) }
    }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $childArgs -Verb RunAs -ErrorAction Stop
        # The elevated child runs the full console experience in its own window.
        exit 0
    }
    catch {
        Write-Host '[WARN] Elevation was declined or failed. No privileged changes were made.' -ForegroundColor Yellow
        exit 4
    }
}

if ($Restore) {
    $restoreResult = Invoke-PORestoreMode -BackupId $RestoreId
    exit [int]$restoreResult.ExitCode
}

$runResult = Invoke-POAutomaticOptimization
exit [int]$runResult.ExitCode
