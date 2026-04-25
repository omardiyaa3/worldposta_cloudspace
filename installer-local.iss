[Setup]
AppName=CloudSpace
AppVersion=1.0.0
AppPublisher=WorldPosta
DefaultDirName={autopf}\CloudSpace
DefaultGroupName=CloudSpace
OutputDir=.
OutputBaseFilename=CloudSpace-Setup
Compression=lzma2
SolidCompression=yes
SetupIconFile=app_icon.ico
UninstallDisplayIcon={app}\CloudSpace.exe
UninstallDisplayName=CloudSpace
CloseApplications=force
CloseApplicationsFilter=CloudSpace.exe
RestartApplications=no
SignTool=signtool
SignedUninstaller=yes

[Files]
Source: "Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion sign

[Icons]
Name: "{group}\CloudSpace"; Filename: "{app}\CloudSpace.exe"
Name: "{autodesktop}\CloudSpace"; Filename: "{app}\CloudSpace.exe"
Name: "{userstartup}\CloudSpace"; Filename: "{app}\CloudSpace.exe"; Parameters: "--minimized"

[Run]
Filename: "{app}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing Visual C++ Runtime..."; Flags: waituntilterminated skipifsilent; Check: not VCRedistInstalled
Filename: "{app}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing WebView2 Runtime..."; Flags: waituntilterminated skipifsilent; Check: not WebView2Installed
Filename: "{app}\CloudSpace.exe"; Description: "Launch CloudSpace"; Flags: nowait postinstall skipifsilent

[Code]
function VCRedistInstalled: Boolean;
begin
  Result := FileExists(ExpandConstant('{sys}\msvcp140.dll'));
end;

function WebView2Installed: Boolean;
var
  Version: String;
begin
  Result := RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Version) or
            RegQueryStringValue(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Version);
end;
