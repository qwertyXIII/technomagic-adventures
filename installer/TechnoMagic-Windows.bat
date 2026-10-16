@echo off
title TechnoMagic Adventures
rem Downloads the latest installer script and runs it. Run again any time to update the pack.
set "PS1=%TEMP%\technomagic-install.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/qwertyXIII/technomagic-adventures/main/installer/install.ps1' -OutFile $env:TEMP\technomagic-install.ps1 -ErrorAction Stop"
if errorlevel 1 (
  echo.
  echo Failed to download the installer. Check your internet connection.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
echo.
pause
