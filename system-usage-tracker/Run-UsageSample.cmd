@echo off
REM One CSV row per run — used by Scheduled Task (low overhead: -SingleRow -Light).
set "LOG=%LOCALAPPDATA%\system-usage-tracker\usage.csv"
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Track-SystemUsage.ps1" -LogFile "%LOG%" -SingleRow -Light
