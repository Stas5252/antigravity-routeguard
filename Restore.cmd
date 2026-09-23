@echo off
set "RG=%LOCALAPPDATA%\AGRouteGuard\AGRouteGuard.ps1"
if not exist "%RG%" set "RG=%~dp0AGRouteGuard.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%RG%" -Action Restore
echo.
pause
