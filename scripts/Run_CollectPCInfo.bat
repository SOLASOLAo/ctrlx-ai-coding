@echo off
net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator privileges, click YES on the UAC prompt...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
if not exist "%~dp0CollectPCInfo.ps1" (
  echo ERROR: CollectPCInfo.ps1 not found. Keep both files in the SAME folder.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CollectPCInfo.ps1"
pause
