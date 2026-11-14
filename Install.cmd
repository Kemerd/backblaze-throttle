@echo off
rem Pins every Backblaze process to Idle CPU and Very Low disk priority.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backblaze-throttle.ps1" -Pause
