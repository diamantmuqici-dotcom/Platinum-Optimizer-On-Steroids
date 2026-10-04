@echo off
setlocal EnableExtensions
title Platinum Optimizer - Safe Launcher
set "ENGINE=%~dp0src\PlatinumOptimizer.ps1"
if not exist "%ENGINE%" (
    echo [ERROR] Platinum Optimizer engine was not found:
    echo         "%ENGINE%"
    pause
    exit /b 2
)
where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Windows PowerShell 5.1 is required.
    pause
    exit /b 3
)
rem This compatibility launcher runs only the checked-in local PowerShell UI.
rem It does not run the retired V9.3 command list archived under legacy\.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%ENGINE%" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
    echo.
    echo Platinum Optimizer exited with code %RESULT%.
    pause
)
exit /b %RESULT%
