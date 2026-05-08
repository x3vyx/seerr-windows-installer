@echo off
setlocal EnableExtensions

REM Args:
REM   %1 = app dir   (e.g. C:\Program Files\Seerr)
REM   %2 = data dir  (e.g. C:\ProgramData\Seerr)
REM   %3 = http port (e.g. 5055)

set "APP_DIR=%~1"
set "DATA_DIR=%~2"
set "PORT=%~3"

set "NSSM=%APP_DIR%\service\nssm.exe"
set "NODE=%APP_DIR%\node\node.exe"
set "SERVICE=Seerr"

if not exist "%DATA_DIR%\db" mkdir "%DATA_DIR%\db"
if not exist "%DATA_DIR%\logs" mkdir "%DATA_DIR%\logs"

REM Idempotent: stop+remove any existing service before reinstalling
"%NSSM%" stop %SERVICE% >nul 2>&1
"%NSSM%" remove %SERVICE% confirm >nul 2>&1

"%NSSM%" install %SERVICE% "%NODE%" "dist\index.js" || goto :fail
"%NSSM%" set %SERVICE% AppDirectory "%APP_DIR%\app" || goto :fail
"%NSSM%" set %SERVICE% DisplayName "Seerr" || goto :fail
"%NSSM%" set %SERVICE% Description "Seerr media request manager (Jellyfin/Plex/Emby)" || goto :fail
"%NSSM%" set %SERVICE% Start SERVICE_AUTO_START || goto :fail
"%NSSM%" set %SERVICE% AppNoConsole 1 || goto :fail

REM Environment variables. NSSM accepts repeated KEY=VALUE pairs.
"%NSSM%" set %SERVICE% AppEnvironmentExtra ^
  "NODE_ENV=production" ^
  "CONFIG_DIRECTORY=%DATA_DIR%" ^
  "PORT=%PORT%" || goto :fail

REM Log rotation: 10MB per file, online rotation
"%NSSM%" set %SERVICE% AppStdout "%DATA_DIR%\logs\service-stdout.log" || goto :fail
"%NSSM%" set %SERVICE% AppStderr "%DATA_DIR%\logs\service-stderr.log" || goto :fail
"%NSSM%" set %SERVICE% AppRotateFiles 1 || goto :fail
"%NSSM%" set %SERVICE% AppRotateOnline 1 || goto :fail
"%NSSM%" set %SERVICE% AppRotateBytes 10485760 || goto :fail

REM Restart on failure with 5s delay
"%NSSM%" set %SERVICE% AppExit Default Restart || goto :fail
"%NSSM%" set %SERVICE% AppRestartDelay 5000 || goto :fail

REM Firewall (idempotent: delete then add)
netsh advfirewall firewall delete rule name="Seerr" >nul 2>&1
netsh advfirewall firewall add rule name="Seerr" dir=in action=allow protocol=TCP localport=%PORT% >nul

"%NSSM%" start %SERVICE% || goto :fail

echo Seerr service installed and started on port %PORT%.
endlocal
exit /b 0

:fail
echo Service installation failed. See output above.
endlocal
exit /b 1
