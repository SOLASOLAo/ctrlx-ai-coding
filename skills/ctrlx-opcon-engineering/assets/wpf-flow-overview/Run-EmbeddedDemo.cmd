@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-FlowOverview.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%
start "" "%~dp0bin\ST60.FlowOverview.exe" --embedded
