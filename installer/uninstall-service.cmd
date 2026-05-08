@echo off
setlocal EnableExtensions

set "APP_DIR=%~1"
set "NSSM=%APP_DIR%\service\nssm.exe"
set "SERVICE=Seerr"

if exist "%NSSM%" (
  "%NSSM%" stop %SERVICE% >nul 2>&1
  "%NSSM%" remove %SERVICE% confirm >nul 2>&1
)

netsh advfirewall firewall delete rule name="Seerr" >nul 2>&1

endlocal
exit /b 0
