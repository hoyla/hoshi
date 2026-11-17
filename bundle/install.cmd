@echo off
rem Double-click this, or run it from a Command Prompt, to install the bundle.
rem Windows blocks PowerShell scripts by default; this runs install.ps1 past
rem that block for this one run and changes no setting on the PC.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
rem Opened by double-click, the window would close and take the result with it.
pause
exit /b %RC%
