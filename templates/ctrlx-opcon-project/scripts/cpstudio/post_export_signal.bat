@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%write_export_request.ps1" %*
exit /b %ERRORLEVEL%
