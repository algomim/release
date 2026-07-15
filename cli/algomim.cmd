@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0algomim.ps1" %*
exit /b %ERRORLEVEL%
