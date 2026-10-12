@echo off
setlocal DisableDelayedExpansion
title Platinum Optimizer On Steroids - Automatic CMD Launcher
set "PO_LAUNCHER=%~dp0src\Launcher.ps1"
if not exist "%PO_LAUNCHER%" (
    echo [FAIL] The Platinum Optimizer launcher was not found:
    echo        "%PO_LAUNCHER%"
    pause
    exit /b 2
)
where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo [FAIL] Windows PowerShell 5.1 is required but was not found on PATH.
    pause
    exit /b 3
)
set "PO_MODE=Auto"
if "%~1"=="" goto run
if /I "%~1"=="--benchmark" goto benchmark
if /I "%~1"=="--scan" goto scan
if /I "%~1"=="--restore" goto restore
if /I "%~1"=="--self-test" goto self_test
echo [FAIL] Unknown or malformed option.
echo Supported options: --scan, --benchmark, --restore, --self-test
pause
exit /b 64
:benchmark
set "PO_MODE=Benchmark"
goto one_argument
:scan
set "PO_MODE=Scan"
goto one_argument
:restore
set "PO_MODE=Restore"
goto one_argument
:self_test
set "PO_MODE=SelfTest"
goto one_argument
:one_argument
if not "%~2"=="" (
    echo [FAIL] This launcher accepts one documented option at a time.
    pause
    exit /b 64
)
:run
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PO_LAUNCHER%" -Mode "%PO_MODE%"
set "PO_RESULT=%ERRORLEVEL%"
exit /b %PO_RESULT%
