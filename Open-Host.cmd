@echo off
set "app=%ProgramFiles%\LanFileSharing\LanShare.ps1"
if not exist "%app%" (
  echo Host is not installed. Run Setup-Host.cmd first.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%app%" -HostMode
