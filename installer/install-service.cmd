@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM Args (all optional — sensible defaults derived from script location and
REM the registry key written by the installer):
REM   %1 = app dir   (default: directory of this script)
REM   %2 = data dir  (default: HKLM\SOFTWARE\Seerr\DataDir, else %ProgramData%\Seerr)
REM   %3 = http port (default: 5055)

set "APP_DIR=%~1"
if "!APP_DIR!"=="" (
  set "APP_DIR=%~dp0"
  if "!APP_DIR:~-1!"=="\" set "APP_DIR=!APP_DIR:~0,-1!"
)

set "DATA_DIR=%~2"
if "!DATA_DIR!"=="" (
  for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Seerr" /v DataDir 2^>nul ^| findstr /i "DataDir"') do set "DATA_DIR=%%b"
)
if "!DATA_DIR!"=="" set "DATA_DIR=%ProgramData%\Seerr"

set "PORT=%~3"
if "!PORT!"=="" set "PORT=5055"

set "NSSM=!APP_DIR!\service\nssm.exe"
set "NODE=!APP_DIR!\node\node.exe"
set "SERVICE=Seerr"

echo === Seerr service install ===
echo APP_DIR  : !APP_DIR!
echo DATA_DIR : !DATA_DIR!
echo PORT     : !PORT!
echo NSSM     : !NSSM!
echo NODE     : !NODE!
echo.

if not exist "!NSSM!" (
  echo ERROR: nssm.exe not found at "!NSSM!"
  endlocal & exit /b 2
)
if not exist "!NODE!" (
  echo ERROR: node.exe not found at "!NODE!"
  endlocal & exit /b 2
)
if not exist "!APP_DIR!\app\dist\index.js" (
  echo ERROR: Seerr entry point not found at "!APP_DIR!\app\dist\index.js"
  endlocal & exit /b 2
)

if not exist "!DATA_DIR!\db"   mkdir "!DATA_DIR!\db"
if not exist "!DATA_DIR!\logs" mkdir "!DATA_DIR!\logs"

REM Idempotent: stop+remove any existing service before reinstalling
"!NSSM!" stop %SERVICE% >nul 2>&1
"!NSSM!" remove %SERVICE% confirm >nul 2>&1

"!NSSM!" install %SERVICE% "!NODE!" "dist\index.js" || goto :fail
"!NSSM!" set %SERVICE% AppDirectory "!APP_DIR!\app" || goto :fail
"!NSSM!" set %SERVICE% DisplayName "Seerr" || goto :fail
"!NSSM!" set %SERVICE% Description "Seerr media request manager (Jellyfin/Plex/Emby)" || goto :fail
"!NSSM!" set %SERVICE% Start SERVICE_AUTO_START || goto :fail
"!NSSM!" set %SERVICE% AppNoConsole 1 || goto :fail

"!NSSM!" set %SERVICE% AppEnvironmentExtra ^
  "NODE_ENV=production" ^
  "CONFIG_DIRECTORY=!DATA_DIR!" ^
  "PORT=!PORT!" || goto :fail

"!NSSM!" set %SERVICE% AppStdout "!DATA_DIR!\logs\service-stdout.log" || goto :fail
"!NSSM!" set %SERVICE% AppStderr "!DATA_DIR!\logs\service-stderr.log" || goto :fail
"!NSSM!" set %SERVICE% AppRotateFiles 1 || goto :fail
"!NSSM!" set %SERVICE% AppRotateOnline 1 || goto :fail
"!NSSM!" set %SERVICE% AppRotateBytes 10485760 || goto :fail

"!NSSM!" set %SERVICE% AppExit Default Restart || goto :fail
"!NSSM!" set %SERVICE% AppRestartDelay 5000 || goto :fail

netsh advfirewall firewall delete rule name="Seerr" >nul 2>&1
netsh advfirewall firewall add rule name="Seerr" dir=in action=allow protocol=TCP localport=!PORT! >nul

"!NSSM!" start %SERVICE% || goto :fail

echo.
echo Seerr service installed and started on port !PORT!.
endlocal
exit /b 0

:fail
echo.
echo Service installation failed. See output above.
endlocal
exit /b 1
