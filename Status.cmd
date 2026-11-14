@echo off
rem Shows registry settings and live priorities. Changes nothing.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0backblaze-throttle.ps1" -Status -Pause
