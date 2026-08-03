@echo off
title Hard Disk Refresh Tool
cd /d "%~dp0"

echo ================================================
echo   Hard Disk Data Refresh Tool
echo ================================================
echo.
echo Usage: choose a drive letter, script will rewrite
echo every file (read - write - verify). You can press
echo Ctrl+C anytime to pause, resume next time.
echo.
echo Note: BitLocker drives must be unlocked first.
echo       Do NOT shutdown or unplug during refresh!
echo.

set /p DRV=Enter drive letter (e.g. G or E) then Enter: 
if "%DRV%"=="" (
  echo No drive entered, exit.
  pause
  exit /b
)
set DRV=%DRV:~0,1%
if not exist %DRV%:\ (
  echo.
  echo [ERROR] Drive %DRV%: does not exist!
  pause
  exit /b
)

dir %DRV%:\ >nul 2>&1
if errorlevel 1 (
  echo.
  echo [ERROR] Cannot access %DRV%:\ - maybe BitLocker locked!
  echo Unlock the drive first, then run again.
  pause
  exit /b
)

set ROOT=%DRV%:\
echo.
echo [START] Refreshing drive %DRV%: ...
echo Do NOT shutdown. Press Ctrl+C to pause, run again to resume.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh_drive.ps1" -Root %ROOT%
echo.
echo [DONE] Log file: %~dp0refresh_log_%DRV%.txt
pause
