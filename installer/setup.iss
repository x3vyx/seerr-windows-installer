; Inno Setup script for Seerr Windows installer.
; Builds a self-contained installer that registers Seerr as a Windows service
; via NSSM, with SQLite as the database backend.

#define MyAppName       "Seerr"
#define MyAppPublisher  "Community Build (unofficial)"
#define MyAppURL        "https://github.com/x3vyx/seerr-windows-installer"
#define MyUpstreamURL   "https://github.com/seerr-team/seerr"

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

#ifndef StagingDir
  #define StagingDir "..\dist"
#endif

[Setup]
; A stable AppId — DO NOT change between releases or upgrades will create
; a separate install instead of replacing the existing one.
AppId={{B5F0A1C2-4D9E-4A2A-9A3F-2C4F5E8B7A11}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppVerName={#MyAppName} {#AppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\Seerr
DefaultGroupName=Seerr
AllowNoIcons=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=Output
OutputBaseFilename=Seerr-{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#MyAppName} {#AppVersion}
DisableProgramGroupPage=yes
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autoupdate"; Description: "Keep Seerr updated automatically (checks daily at 04:00)"

[InstallDelete]
; Upgrades must not leave the previous build's chunks and modules behind.
Type: filesandordirs; Name: "{app}\app"

[Files]
Source: "{#StagingDir}\app\*";              DestDir: "{app}\app";     Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StagingDir}\node\*";             DestDir: "{app}\node";    Flags: ignoreversion
Source: "{#StagingDir}\service\*";          DestDir: "{app}\service"; Flags: ignoreversion
Source: "install-service.cmd";              DestDir: "{app}";         Flags: ignoreversion
Source: "uninstall-service.cmd";            DestDir: "{app}";         Flags: ignoreversion
Source: "updater\*.ps1";                    DestDir: "{app}\updater"; Flags: ignoreversion

[Dirs]
Name: "{code:GetDataDir}";       Permissions: users-modify
Name: "{code:GetDataDir}\db";    Permissions: users-modify
Name: "{code:GetDataDir}\logs";  Permissions: users-modify

[Icons]
Name: "{group}\Open Seerr";     Filename: "http://localhost:{code:GetPort}/"
Name: "{group}\View Logs";      Filename: "{code:GetDataDir}\logs"
Name: "{group}\View Data Dir";  Filename: "{code:GetDataDir}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Registry]
; Remember the chosen data dir so re-running the installer defaults to it
; instead of silently orphaning the existing database.
Root: HKLM; Subkey: "SOFTWARE\Seerr"; Flags: uninsdeletekeyifempty
Root: HKLM; Subkey: "SOFTWARE\Seerr"; ValueType: string; ValueName: "DataDir"; \
  ValueData: "{code:GetDataDir}"; Flags: uninsdeletevalue

[Run]
; install-service.cmd is run from CurStepChanged (Pascal) so we can surface
; failures via MsgBox instead of swallowing them with `runhidden`.

Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\updater\Register-UpdateTask.ps1"""; \
  Flags: runhidden waituntilterminated; Tasks: autoupdate

Filename: "http://localhost:{code:GetPort}/"; \
  Description: "Open Seerr in your browser"; \
  Flags: postinstall shellexec skipifsilent nowait

[UninstallRun]
Filename: "{app}\uninstall-service.cmd"; \
  Parameters: """{app}"""; \
  Flags: runhidden waituntilterminated; \
  RunOnceId: "RemoveSeerrService"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

; ---------------------------------------------------------------------------
; Wizard pages: 1) data directory (DB + logs + settings.json), 2) HTTP port.
; Data dir defaults to {commonappdata}\Seerr but is user-selectable so the
; SQLite database can live on a different drive (capacity, SSD, etc.).
; UNC/network paths are rejected — SQLite WAL is unsafe over SMB.
; ---------------------------------------------------------------------------

[Code]
var
  DataDirPage: TInputDirWizardPage;
  PortPage: TInputQueryWizardPage;

// The port the service is already configured with, so upgrades (silent ones
// included) keep it. NSSM stores the environment as a REG_MULTI_SZ.
function GetInstalledPort: string;
var
  Environment, Digits: string;
  Start, I: Integer;
begin
  Result := '5055';
  if not RegQueryMultiString(HKEY_LOCAL_MACHINE,
      'SYSTEM\CurrentControlSet\Services\Seerr\Parameters',
      'AppEnvironmentExtra', Environment) then Exit;

  Environment := #0 + Environment;
  Start := Pos(#0 + 'PORT=', Environment);
  if Start = 0 then Exit;

  Digits := '';
  I := Start + Length(#0 + 'PORT=');
  while (I <= Length(Environment)) and (Environment[I] >= '0') and (Environment[I] <= '9') do begin
    Digits := Digits + Environment[I];
    I := I + 1;
  end;
  if Digits <> '' then Result := Digits;
end;

procedure InitializeWizard;
var
  ExistingDataDir: string;
begin
  DataDirPage := CreateInputDirPage(
    wpSelectDir,
    'Data directory',
    'Where should Seerr store its database, logs, and settings?',
    'The SQLite database (db.sqlite3), log files, and settings.json will ' +
    'live under the folder you choose. This folder is preserved when you ' +
    'uninstall Seerr.' + #13#10 + #13#10 +
    'Tip: pick a path on a fast local drive. Network shares (UNC) are not ' +
    'supported because SQLite WAL mode is unsafe over SMB.',
    False,
    ''
  );
  DataDirPage.Add('Data directory:');

  if RegQueryStringValue(HKEY_LOCAL_MACHINE, 'SOFTWARE\Seerr', 'DataDir',
                         ExistingDataDir) and (ExistingDataDir <> '') then
    DataDirPage.Values[0] := ExistingDataDir
  else
    DataDirPage.Values[0] := ExpandConstant('{commonappdata}\Seerr');

  PortPage := CreateInputQueryPage(
    DataDirPage.ID,
    'Network configuration',
    'Choose the HTTP port Seerr will listen on',
    'The default is 5055. Pick another port if 5055 is already in use.'
  );
  PortPage.Add('HTTP port:', False);
  PortPage.Values[0] := GetInstalledPort();
end;

function IsValidPort(const S: string): Boolean;
var
  N, I: Integer;
begin
  Result := False;
  if (Length(S) = 0) or (Length(S) > 5) then Exit;
  for I := 1 to Length(S) do
    if (S[I] < '0') or (S[I] > '9') then Exit;
  N := StrToIntDef(S, -1);
  Result := (N >= 1) and (N <= 65535);
end;

function IsValidLocalPath(const Path: string): Boolean;
begin
  Result := False;
  // Reject UNC: \\server\share
  if (Length(Path) >= 2) and (Path[1] = '\') and (Path[2] = '\') then Exit;
  // Require a drive letter root: X:\
  if (Length(Path) < 3) or (Path[2] <> ':') or (Path[3] <> '\') then Exit;
  Result := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  if CurPageID = DataDirPage.ID then begin
    if not IsValidLocalPath(DataDirPage.Values[0]) then begin
      MsgBox('Please choose a local path with a drive letter ' +
             '(for example C:\Seerr or D:\Apps\Seerr).' + #13#10 +
             'Network shares (UNC paths) are not supported.',
             mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;

  if CurPageID = PortPage.ID then begin
    if not IsValidPort(PortPage.Values[0]) then begin
      MsgBox('Please enter a valid TCP port number (1-65535).', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function GetDataDir(Param: string): string;
begin
  Result := DataDirPage.Values[0];
end;

function GetPort(Param: string): string;
begin
  Result := PortPage.Values[0];
end;

// Stop the service before any file is touched. Otherwise node.exe holds its
// files open, and NSSM would restart it 5 seconds after Setup closed it.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Nssm: string;
  ResultCode: Integer;
begin
  Result := '';
  Nssm := ExpandConstant('{app}\service\nssm.exe');
  if FileExists(Nssm) then
    Exec(Nssm, 'stop Seerr', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

// SuppressibleMsgBox below, never MsgBox: /SUPPRESSMSGBOXES does not silence
// MsgBox, and the auto-updater runs Setup in session 0, where nobody could
// ever dismiss it.
procedure CurStepChanged(CurStep: TSetupStep);
var
  CmdExe, Args, AppDir, DataDir, Port, CmdPath: string;
  ResultCode: Integer;
begin
  if CurStep <> ssPostInstall then Exit;

  AppDir := ExpandConstant('{app}');
  DataDir := DataDirPage.Values[0];
  Port := PortPage.Values[0];
  CmdExe := ExpandConstant('{cmd}');
  CmdPath := AppDir + '\install-service.cmd';

  // cmd /c "" "..install-service.cmd" "appdir" "datadir" "port" "" -- the
  // outer pair of quotes is required by cmd /c when the command contains
  // additional quoted args. Built via concatenation rather than Format() so
  // there's no array-literal continuation line that confuses ISCC's parser.
  Args := '/c "' +
          '"' + CmdPath + '" ' +
          '"' + AppDir  + '" ' +
          '"' + DataDir + '" ' +
          '"' + Port    + '"' +
          '"';

  WizardForm.StatusLabel.Caption := 'Registering and starting Seerr service...';
  if not Exec(CmdExe, Args, AppDir, SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
    SuppressibleMsgBox(
      'Failed to launch install-service.cmd:' + #13#10 +
      SysErrorMessage(ResultCode) + #13#10 + #13#10 +
      'You can re-run service registration manually from an elevated ' +
      'PowerShell:' + #13#10 +
      '  & "' + CmdPath + '"',
      mbError, MB_OK, IDOK);
    Exit;
  end;

  if ResultCode = 99 then begin
    // Service is registered and configured for auto-start, but didn't
    // reach RUNNING within the install-time poll window. Surface as a
    // non-fatal notice -- it'll likely come up on its own or at next boot.
    SuppressibleMsgBox(
      'Seerr was installed and the Windows service is registered with ' +
      'automatic startup, but it did not finish initialising within ' +
      '30 seconds during install.' + #13#10 + #13#10 +
      'First-run database initialisation can be slow. Wait a minute, ' +
      'then check the service state from PowerShell:' + #13#10 +
      '  sc query Seerr' + #13#10 + #13#10 +
      'If it stays STOPPED, inspect:' + #13#10 +
      '  ' + DataDir + '\logs\service-stderr.log',
      mbInformation, MB_OK, IDOK);
  end else if ResultCode <> 0 then begin
    SuppressibleMsgBox(
      'Service registration failed (exit code ' + IntToStr(ResultCode) + ').' + #13#10 + #13#10 +
      'Check the script output by re-running it from an elevated PowerShell:' + #13#10 +
      '  & "' + CmdPath + '"' + #13#10 + #13#10 +
      'Logs (after the service starts at least once):' + #13#10 +
      '  ' + DataDir + '\logs\',
      mbError, MB_OK, IDOK);
  end;
end;
