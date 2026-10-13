@echo off
cd /d "%TEMP%"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-LanHost.ps1"
set "result=%errorlevel%"
if not "%result%"=="0" echo Host setup failed. Error code: %result%
pause
exit /b %result%
