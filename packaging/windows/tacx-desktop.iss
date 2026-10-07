; Inno Setup script for Tacx Desktop (Windows x64)
; Compile on windows-latest after: flutter build windows --release
;   iscc packaging\windows\tacx-desktop.iss
;
; Defines (optional):
;   MyAppVersion   e.g. 0.2.1 or v0.2.1 or main-abc1234
;   MyReleaseDir   path to Flutter Release folder
;   MyOutDir       where Setup.exe is written
;   MyOutFile      base name without .exe

#ifndef MyAppVersion
  #define MyAppVersion "0.2.1"
#endif
#ifndef MyReleaseDir
  #define MyReleaseDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef MyOutDir
  #define MyOutDir "..\..\dist"
#endif
#ifndef MyOutFile
  #define MyOutFile "TacxDesktop-Setup-" + MyAppVersion
#endif

#define MyAppName "Tacx Desktop"
#define MyAppPublisher "Niels Vervoort"
#define MyAppURL "https://github.com/nielsver/tacx-desktop"
#define MyAppExeName "tacx_desktop.exe"

[Setup]
AppId={{A7C3E9F1-4B2D-4E8A-9C1F-6D5E8A2B3C4D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir={#MyOutDir}
OutputBaseFilename={#MyOutFile}
; No custom icon required — Inno uses default setup icon if absent
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#MyAppName}
VersionInfoVersion=0.2.1.0
VersionInfoProductName={#MyAppName}
DisableProgramGroupPage=yes
InfoBeforeFile=windows-first-run.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MyReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
begin
  Result := True;
end;
