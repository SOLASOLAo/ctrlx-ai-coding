@echo off
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
set "POWERSHELL7=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined ProgramW6432 set "POWERSHELL7=%ProgramW6432%\PowerShell\7\pwsh.exe"

if not exist "%POWERSHELL7%" (
  echo PowerShell 7 is required but was not found: "%POWERSHELL7%"
  set "CHECK_RC=9009"
  goto :result
)

"%POWERSHELL7%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Invoke-OfflinePostExportCheck.ps1" -Interactive
set "CHECK_RC=%ERRORLEVEL%"

:result
echo.
echo Offline check exit code: %CHECK_RC%
echo Press any key to close this window.
pause >nul
exit /b %CHECK_RC%
