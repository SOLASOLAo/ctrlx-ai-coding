@echo off
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Invoke-OfflinePostExportCheck.ps1" -Interactive
set "CHECK_RC=%ERRORLEVEL%"

echo.
echo Offline check exit code: %CHECK_RC%
echo Press any key to close this window.
pause >nul
exit /b %CHECK_RC%
