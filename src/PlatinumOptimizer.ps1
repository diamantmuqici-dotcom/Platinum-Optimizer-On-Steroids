#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Scan', 'Benchmark', 'Restore', 'SelfTest')]
    [string]$Mode = 'Auto',
    [switch]$Scan,
    [switch]$Benchmark,
    [switch]$Restore,
    [switch]$SelfTest,
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:POApplicationVersion = '2.1.0'
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

$legacyModeSwitches = @()
if ($Scan) { $legacyModeSwitches += 'Scan' }
if ($Benchmark) { $legacyModeSwitches += 'Benchmark' }
if ($Restore) { $legacyModeSwitches += 'Restore' }
if ($SelfTest) { $legacyModeSwitches += 'SelfTest' }
if ($legacyModeSwitches.Count -gt 1) {
    Write-Error 'Choose only one of -Scan, -Benchmark, -Restore, or -SelfTest.'
    exit 64
}
if ($legacyModeSwitches.Count -eq 1) {
    if ($Mode -ne 'Auto' -and $Mode -ne $legacyModeSwitches[0]) {
        Write-Error "-Mode $Mode conflicts with -$($legacyModeSwitches[0])."
        exit 64
    }
    $Mode = [string]$legacyModeSwitches[0]
}

# Every module the automatic pipeline can reach. The Network, Gaming and
# Engine modules were dropped from this list in v2.0.1, which silently
# disconnected those categories from the run: the modules were still present
# in the repository but never imported, so the automatic engine could only
# act on the power plan. All eight are imported here, and the BOOT stage
# verifies each one is actually loaded before any change is attempted.
$moduleFiles = @(
    'src\core\PlatinumOptimizer.Core.psm1',
    'src\core\PlatinumOptimizer.Power.psm1',
    'src\core\PlatinumOptimizer.Audio.psm1',
    'src\core\PlatinumOptimizer.Display.psm1',
    'src\core\PlatinumOptimizer.Network.psm1',
    'src\core\PlatinumOptimizer.Gaming.psm1',
    'src\core\PlatinumOptimizer.Engine.psm1',
    'src\core\PlatinumOptimizer.Automatic.psm1'
)
try {
    foreach ($relativePath in $moduleFiles) {
        $modulePath = Join-Path $repoRoot $relativePath
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw "Required module was not found: $modulePath"
        }
        # No -DisableNameChecking: v2.0.2 added it to silence the
        # "unapproved verbs" warning from PlatinumOptimizer.Display. The cause
        # was exported function Compute-POGammaRamp; "Compute" is not an
        # approved verb. It is now New-POGammaRamp, so every exported name
        # uses an approved verb and the warning no longer occurs. Suppressing
        # it here would also hide genuine naming problems in future modules,
        # and tools/ps_contract_check.py fails the build if one is introduced.
        Import-Module -Name $modulePath -Global -Force -ErrorAction Stop
    }
}
catch {
    Write-Host "[FAIL] A required component could not be loaded: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

if ($Mode -eq 'SelfTest') {
    $testPath = Join-Path $repoRoot 'tests\Run-Tests.ps1'
    if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
        Write-Host '[FAIL] Test harness was not found.' -ForegroundColor Red
        exit 7
    }
    & $testPath
    exit $LASTEXITCODE
}

function Write-POConsoleBanner {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '       PLATINUM OPTIMIZER ON STEROIDS' -ForegroundColor Cyan
    Write-Host '         AUTOMATIC GAMING OPTIMIZATION ENGINE' -ForegroundColor Cyan
    Write-Host ('                    VERSION {0}' -f $script:POApplicationVersion) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Wait-POExitKey {
    Write-Host ''
    Write-Host 'Press any key to exit...' -ForegroundColor DarkGray
    try {
        if ([Console]::IsInputRedirected) { [void][Console]::ReadLine() }
        else { [void][Console]::ReadKey($true) }
    }
    catch { [void][Console]::ReadLine() }
}

Write-POConsoleBanner
try {
    if (-not (Test-POIsWindows)) {
        Write-Host '[FAIL] This optimizer requires Windows 10/11 and Windows PowerShell 5.1 or later.' -ForegroundColor Red
        Wait-POExitKey
        exit 2
    }
    if ($Mode -in @('Auto', 'Restore') -and -not (Test-POIsAdministrator)) {
        Write-Host '[FAIL] Administrator privileges are required for this operation.' -ForegroundColor Red
        Write-Host '[INFO] Run PlatinumOptimizer.bat and accept the standard Windows UAC prompt.' -ForegroundColor Yellow
        Write-Host '[INFO] No system changes were made.' -ForegroundColor Yellow
        Wait-POExitKey
        exit 5
    }
    Set-Location -LiteralPath $repoRoot
    $runResult = Invoke-POAutomaticMode -Mode $Mode -BackupPath $BackupPath -ApplicationVersion $script:POApplicationVersion
    Wait-POExitKey
    exit ([int]$runResult.ExitCode)
}
catch {
    Write-Host "[FAIL] The optimizer stopped safely: $($_.Exception.Message)" -ForegroundColor Red
    Wait-POExitKey
    exit 10
}
