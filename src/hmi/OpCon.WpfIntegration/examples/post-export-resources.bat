@echo off
rem Configure this native Post-export step alongside the owner's existing hook.
rem Only hmi-resources.json paths are project-specific. Never start PLE or HMI here.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Sync-HmiResources.ps1" -ConfigFile "%~dp0hmi-resources.json"
exit /b %ERRORLEVEL%
