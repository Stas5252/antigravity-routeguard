@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AccountSwap.ps1"
set "ec=%ERRORLEVEL%"
if not "%ec%"=="0" pause
exit /b %ec%
