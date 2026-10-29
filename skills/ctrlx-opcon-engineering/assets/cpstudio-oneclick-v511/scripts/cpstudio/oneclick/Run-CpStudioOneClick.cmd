@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Invoke-CpStudioOneClick.ps1" -Run
set "ONECLICK_RC=%ERRORLEVEL%"
echo.
echo Exit code: %ONECLICK_RC%
pause
exit /b %ONECLICK_RC%
