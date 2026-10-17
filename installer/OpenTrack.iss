; OpenTrack agent installer (Inno Setup 6)
; Build:  ISCC installer\OpenTrack.iss   (after: cargo build --release in agent-rs)
; Per-user install, no admin rights needed.

#define AppName "OpenTrack Agent"
#ifndef AppVersion
  #define AppVersion "0.3.0"
#endif
#define AgentExe "OpenTrackAgent.exe"

[Setup]
AppId={{B6C1D1B4-6E0C-4B7B-9F3E-0A1B2C3D4E5F}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=OpenTrack contributors
DefaultDirName={localappdata}\OpenTrack
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=OpenTrackSetup-{#AppVersion}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}
LicenseFile=..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"

[Files]
Source: "..\agent-rs\target\release\opentrack-agent.exe"; DestDir: "{app}"; DestName: "{#AgentExe}"; Flags: ignoreversion

[Registry]
; start automatically when the user logs on
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "OpenTrackAgent"; ValueData: """{app}\{#AgentExe}"""; \
    Flags: uninsdeletevalue

[Run]
; start it right away (no console window; the agent is a background app)
Filename: "{app}\{#AgentExe}"; Flags: nowait runhidden

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AgentExe}"; Flags: runhidden; RunOnceId: "KillAgent"

[UninstallDelete]
Type: files; Name: "{app}\config.json"
Type: files; Name: "{app}\agent.log"

[Code]
var
  CfgPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  CfgPage := CreateInputQueryPage(wpSelectDir,
    'Connect to your dashboard',
    'Paste the values from your OpenTrack dashboard and Supabase project.',
    'Supabase URL / anon key: Project Settings > API.' + #13#10 +
    'device_id / agent_key: shown when you click your device in the dashboard.' + #13#10 +
    '(On upgrade you can leave all fields empty to keep the current settings.)');
  CfgPage.Add('Supabase URL (https://xxxx.supabase.co):', False);
  CfgPage.Add('Supabase anon key:', False);
  CfgPage.Add('device_id:', False);
  CfgPage.Add('agent_key:', False);
end;

function AnyFieldFilled: Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to 3 do
    if Trim(CfgPage.Values[i]) <> '' then Result := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var i: Integer;
begin
  Result := True;
  if CurPageID = CfgPage.ID then
  begin
    if FileExists(ExpandConstant('{app}\config.json')) and not AnyFieldFilled then Exit;
    for i := 0 to 3 do
      if Trim(CfgPage.Values[i]) = '' then
      begin
        MsgBox('Please fill in all four fields.', mbError, MB_OK);
        Result := False;
        Exit;
      end;
    if Pos('https://', Lowercase(Trim(CfgPage.Values[0]))) <> 1 then
    begin
      MsgBox('The Supabase URL must start with https://', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function JsonEscape(const S: String): String;
begin
  Result := S;
  StringChangeEx(Result, '\', '\\', True);
  StringChangeEx(Result, '"', '\"', True);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var ResultCode: Integer;
begin
  { stop a running agent so the exe can be replaced on upgrade }
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#AgentExe}', '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var Json: String;
begin
  if (CurStep = ssPostInstall) and AnyFieldFilled then
  begin
    Json := '{' + #13#10 +
      '  "supabase_url": "'      + JsonEscape(Trim(CfgPage.Values[0])) + '",' + #13#10 +
      '  "supabase_anon_key": "' + JsonEscape(Trim(CfgPage.Values[1])) + '",' + #13#10 +
      '  "device_id": "'         + JsonEscape(Trim(CfgPage.Values[2])) + '",' + #13#10 +
      '  "agent_key": "'         + JsonEscape(Trim(CfgPage.Values[3])) + '",' + #13#10 +
      '  "interval_seconds": 900,' + #13#10 +
      '  "use_windows_location": true,' + #13#10 +
      '  "enable_photo": true' + #13#10 +
      '}' + #13#10;
    SaveStringToFile(ExpandConstant('{app}\config.json'), Json, False);
  end;
end;
