@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "POWERSHELL7=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined ProgramW6432 set "POWERSHELL7=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not exist "%POWERSHELL7%" exit /b 9009
"%POWERSHELL7%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%write_export_request.ps1" %*
exit /b %ERRORLEVEL%
