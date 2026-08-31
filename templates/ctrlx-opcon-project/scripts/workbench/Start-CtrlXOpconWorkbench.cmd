@echo off
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
set "POWERSHELL7=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined ProgramW6432 set "POWERSHELL7=%ProgramW6432%\PowerShell\7\pwsh.exe"

if not exist "%POWERSHELL7%" (
  echo PowerShell 7 is required but was not found: "%POWERSHELL7%"
  pause
  exit /b 9009
)

"%POWERSHELL7%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Start-CtrlXOpconWorkbench.ps1"
set "WORKBENCH_RC=%ERRORLEVEL%"
if not "%WORKBENCH_RC%"=="0" (
  echo.
  echo Engineering Console failed with exit code %WORKBENCH_RC%.
  pause
)
exit /b %WORKBENCH_RC%
