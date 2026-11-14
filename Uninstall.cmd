@echo off
rem Removes the priority settings. Backblaze goes back to stock on next restart.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backblaze-throttle.ps1" -Uninstall -Pause
