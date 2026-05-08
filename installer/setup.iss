; Inno Setup script for Seerr Windows installer.
; Builds a self-contained installer that registers Seerr as a Windows service
; via NSSM, with SQLite as the database backend.

#define MyAppName       "Seerr"
#define MyAppPublisher  "Community Build (unofficial)"
#define MyAppURL        "https://github.com/kraikov/seerr-windows-installer"
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

[Files]
Source: "{#StagingDir}\app\*";              DestDir: "{app}\app";     Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StagingDir}\node\*";             DestDir: "{app}\node";    Flags: ignoreversion
Source: "{#StagingDir}\service\*";          DestDir: "{app}\service"; Flags: ignoreversion
Source: "install-service.cmd";              DestDir: "{app}";         Flags: ignoreversion
Source: "uninstall-service.cmd";            DestDir: "{app}";         Flags: ignoreversion

[Dirs]
Name: "{commonappdata}\Seerr";       Permissions: users-modify
Name: "{commonappdata}\Seerr\db";    Permissions: users-modify
Name: "{commonappdata}\Seerr\logs";  Permissions: users-modify

[Icons]
Name: "{group}\Open Seerr";     Filename: "http://localhost:{code:GetPort}/"
Name: "{group}\View Logs";      Filename: "{commonappdata}\Seerr\logs"
Name: "{group}\View Data Dir";  Filename: "{commonappdata}\Seerr"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\install-service.cmd"; \
  Parameters: """{app}"" ""{commonappdata}\Seerr"" ""{code:GetPort}"""; \
  Flags: runhidden waituntilterminated; \
  StatusMsg: "Registering and starting Seerr service..."

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
; Wizard pages: ask for HTTP port. Data dir is fixed to {commonappdata}\Seerr
; — putting the SQLite DB anywhere under Program Files would hit UAC
; virtualization issues.
; ---------------------------------------------------------------------------

[Code]
var
  PortPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  PortPage := CreateInputQueryPage(
    wpSelectDir,
    'Network configuration',
    'Choose the HTTP port Seerr will listen on',
    'The default is 5055. Pick another port if 5055 is already in use.' + #13#10 +
    'Data, including the SQLite database, will be stored in:' + #13#10 +
    ExpandConstant('{commonappdata}\Seerr')
  );
  PortPage.Add('HTTP port:', False);
  PortPage.Values[0] := '5055';
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

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = PortPage.ID then begin
    if not IsValidPort(PortPage.Values[0]) then begin
      MsgBox('Please enter a valid TCP port number (1-65535).', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function GetPort(Param: string): string;
begin
  Result := PortPage.Values[0];
end;
