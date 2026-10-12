@echo off
rem ============================================================
rem  Platinum Optimizer On Steroids v2.0 - repository launcher
rem  Compatibility frontend for the original .cmd filename.
rem  Runs the automatic CMD engine from the repository layout.
rem  It does NOT run the retired V9.3 command list (archived as
rem  plain text under legacy\) and it does NOT start any
rem  graphical interface - the graphical UI was removed in v2.0.
rem ============================================================
setlocal EnableExtensions
title Platinum Optimizer On Steroids - Automatic Mode
cd /d "%~dp0"
set "ENGINE=%~dp0src\PlatinumOptimizer.ps1"
if exist "%ENGINE%" goto po_have_engine
echo [FAIL] Platinum Optimizer engine was not found:
echo        "%ENGINE%"
echo Press any key to exit...
pause >nul
exit /b 2
:po_have_engine
where powershell.exe >nul 2>&1
if not errorlevel 1 goto po_have_powershell
echo [FAIL] Windows PowerShell 5.1 is required.
echo Press any key to exit...
pause >nul
exit /b 3
:po_have_powershell
rem Administrator check: "net session" succeeds only in an elevated session.
net session >nul 2>&1
if not errorlevel 1 goto po_elevated
echo [INFO] Administrator privileges are required.
echo [INFO] Windows will now show a UAC confirmation prompt. This is a
echo [INFO] normal Windows security mechanism. Select Yes to continue.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs -ErrorAction Stop } catch { exit 123 }"
if not errorlevel 1 goto po_relaunched
echo [WARN] Elevation was declined or failed. No privileged changes were made.
echo Press any key to exit...
pause >nul
exit /b 4
:po_relaunched
echo [INFO] The elevated optimizer was started in a new window.
timeout /t 3 >nul
exit /b 0
:po_elevated
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ENGINE%" %*
set "RESULT=%ERRORLEVEL%"
echo.
if "%RESULT%"=="0" goto po_done
echo Platinum Optimizer exited with code %RESULT%.
:po_done
echo Press any key to exit...
pause >nul
exit /b %RESULT%
