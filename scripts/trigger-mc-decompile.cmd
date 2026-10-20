@echo off
rem Double-click launcher for trigger-mc-decompile.ps1.
rem It only exists to run the script with execution policy bypassed.
rem Extra arguments are passed through, e.g.:
rem   trigger-mc-decompile.cmd -Force -Wait
setlocal
set "SCRIPT=%~dp0trigger-mc-decompile.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] trigger-mc-decompile.ps1 not found next to this file.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "CODE=%ERRORLEVEL%"
echo.
echo [exit code] %CODE%
pause
exit /b %CODE%
