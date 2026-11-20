@echo off
rem Double-click this after the PC has restarted, or whenever the translation
rem page doesn't answer. It opens Docker Desktop and Ollama if they aren't
rem running, waits for them, and opens the translation page. Windows blocks
rem PowerShell scripts by default; this runs start-translation.ps1 past that
rem block for this one run and changes no setting on the PC.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-translation.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
rem Opened by double-click, the window would close and take the result with it.
pause
exit /b %RC%
