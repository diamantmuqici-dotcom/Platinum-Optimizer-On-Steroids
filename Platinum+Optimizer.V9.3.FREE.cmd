@echo off
setlocal DisableDelayedExpansion
title Platinum Optimizer - Compatibility Launcher
rem Compatibility entry point retained for old shortcuts. The archived V9.3
rem tweak list is non-executable; all supported runs delegate to the current
rem automatic CMD launcher.
set "PO_OPTION="
if "%~1"=="" goto run
if /I "%~1"=="--scan" (
    set "PO_OPTION=--scan"
    goto one_argument
)
if /I "%~1"=="--benchmark" (
    set "PO_OPTION=--benchmark"
    goto one_argument
)
if /I "%~1"=="--restore" (
    set "PO_OPTION=--restore"
    goto one_argument
)
if /I "%~1"=="--self-test" (
    set "PO_OPTION=--self-test"
    goto one_argument
)
echo [FAIL] Unknown or malformed option.
echo Supported options: --scan, --benchmark, --restore, --self-test
pause
exit /b 64
:one_argument
if not "%~2"=="" (
    echo [FAIL] This launcher accepts one documented option at a time.
    pause
    exit /b 64
)
:run
if defined PO_OPTION (
    call "%~dp0PlatinumOptimizer.bat" "%PO_OPTION%"
) else (
    call "%~dp0PlatinumOptimizer.bat"
)
set "PO_RESULT=%ERRORLEVEL%"
exit /b %PO_RESULT%
