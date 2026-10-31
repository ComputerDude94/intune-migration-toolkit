@echo off
rem Double-click launcher. The script elevates itself (UAC prompt) and opens the GUI.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0MigrationToolkit.ps1"
