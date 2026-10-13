@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-LanClient.ps1"
set "result=%errorlevel%"
if not "%result%"=="0" echo Client setup failed. Error code: %result%
pause
exit /b %result%
