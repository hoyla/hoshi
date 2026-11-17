@echo off
rem Runs translate.ps1 past the Windows default that blocks PowerShell scripts.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0translate.ps1" %*
exit /b %ERRORLEVEL%
