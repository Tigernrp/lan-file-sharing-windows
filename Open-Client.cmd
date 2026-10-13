@echo off
set "app=%LOCALAPPDATA%\Programs\LanFileSharingClient\Start-LanShare.cmd"
if not exist "%app%" (
  echo Client is not installed. Run Setup-Client.cmd first.
  pause
  exit /b 1
)
call "%app%"
