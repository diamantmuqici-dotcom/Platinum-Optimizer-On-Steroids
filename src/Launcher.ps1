#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Scan', 'Benchmark', 'Restore', 'SelfTest')]
    [string]$Mode = 'Auto'
)

$ErrorActionPreference = 'Stop'
$launcherPath = [System.IO.Path]::GetFullPath($PSCommandPath)
$repoRoot = Split-Path -Parent (Split-Path -Parent $launcherPath)
$enginePath = Join-Path $repoRoot 'src\PlatinumOptimizer.ps1'

function Wait-POConsoleKey {
    param([string]$Message = 'Press any key to close this window...')
    Write-Host $Message -ForegroundColor DarkGray
    try {
        if ([Console]::IsInputRedirected) { [void][Console]::ReadLine() }
        else { [void][Console]::ReadKey($true) }
    }
    catch { [void][Console]::ReadLine() }
}

function Test-POLauncherAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    Write-Host '[FAIL] Optimizer engine was not found:' -ForegroundColor Red
    Write-Host "       $enginePath" -ForegroundColor Red
    Wait-POConsoleKey
    exit 2
}

$requiresAdministrator = $Mode -in @('Auto', 'Restore')
if ($requiresAdministrator -and -not (Test-POLauncherAdministrator)) {
    Write-Host '[INFO] Administrator privileges are required; requesting the standard Windows UAC confirmation...' -ForegroundColor Yellow
    $powershellPath = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
        Write-Host '[FAIL] Windows PowerShell 5.1 was not found at the expected system location.' -ForegroundColor Red
        Wait-POConsoleKey
        exit 3
    }
    # Mode is constrained by ValidateSet, and Windows paths cannot contain a quote.
    # Use one fully quoted -ArgumentList string so installation paths with spaces work.
    $quotedLauncherPath = '"' + $launcherPath + '"'
    $argumentLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' + $quotedLauncherPath + ' -Mode ' + $Mode
    try {
        $child = Start-Process -FilePath $powershellPath -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
        exit ([int]$child.ExitCode)
    }
    catch {
        $nativeCode = $null
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception -is [System.ComponentModel.Win32Exception]) { $nativeCode = $exception.NativeErrorCode }
            if (($exception.HResult -band 0xFFFF) -eq 1223) { $nativeCode = 1223 }
            if ($nativeCode -eq 1223) { break }
            $exception = $exception.InnerException
        }
        if ($nativeCode -eq 1223) {
            Write-Host '[WARN] Administrator approval was declined. No optimization changes were made.' -ForegroundColor Yellow
            Wait-POConsoleKey
            exit 5
        }
        Write-Host "[FAIL] Could not start the elevated optimizer: $($_.Exception.Message)" -ForegroundColor Red
        Wait-POConsoleKey
        exit 6
    }
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

& $enginePath -Mode $Mode
exit $LASTEXITCODE
