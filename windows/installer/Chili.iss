; Chili for Windows installer (Inno Setup 6).
; Build: ISCC /DAppVersion=1.0.0 /DArch=x64 /DSourceDir=<publish folder> /DOutputDir=<dist> Chili.iss
;
; Installs per user by default (no administrator rights needed; "for all users" is offered),
; registers .vv files (application/x-virt-viewer) and the spice:// and spice+tls:// links.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\publish\" + Arch
#endif
#ifndef OutputDir
  #define OutputDir "..\build\dist"
#endif

[Setup]
AppId={{6B3E9C1E-4C8A-4B7E-9E61-3F0C2D7A5C11}
AppName=Chili
AppVersion={#AppVersion}
AppVerName=Chili {#AppVersion}
AppPublisher=edgarfraus
AppPublisherURL=https://github.com/edgarfraus/Chili
AppSupportURL=https://github.com/edgarfraus/Chili/issues
AppUpdatesURL=https://github.com/edgarfraus/Chili/releases
DefaultDirName={autopf}\Chili
DefaultGroupName=Chili
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed={#Arch}compatible
ArchitecturesInstallIn64BitMode={#Arch}compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=Chili-{#AppVersion}-{#Arch}-setup
SetupIconFile=..\src\Chili\Assets\Chili.ico
UninstallDisplayIcon={app}\Chili.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "it"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "assocvv"; Description: "{cm:AssocVV}"; GroupDescription: "{cm:Associations}"
Name: "assocspice"; Description: "{cm:AssocSpice}"; GroupDescription: "{cm:Associations}"

[CustomMessages]
en.AssocVV=Open SPICE connection files (.vv) with Chili
it.AssocVV=Apri i file di connessione SPICE (.vv) con Chili
en.AssocSpice=Open spice:// links with Chili
it.AssocSpice=Apri i link spice:// con Chili
en.Associations=Associations:
it.Associations=Associazioni:
en.VVFile=SPICE connection file
it.VVFile=File di connessione SPICE

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Chili"; Filename: "{app}\Chili.exe"
Name: "{autodesktop}\Chili"; Filename: "{app}\Chili.exe"; Tasks: desktopicon

[Registry]
; .vv files (what Proxmox downloads for Console → SPICE)
Root: HKA; Subkey: "Software\Classes\.vv"; ValueType: string; ValueName: ""; ValueData: "Chili.vv"; Flags: uninsdeletevalue; Tasks: assocvv
Root: HKA; Subkey: "Software\Classes\.vv"; ValueType: string; ValueName: "Content Type"; ValueData: "application/x-virt-viewer"; Flags: uninsdeletevalue uninsdeletekeyifempty; Tasks: assocvv
Root: HKA; Subkey: "Software\Classes\.vv\OpenWithProgids"; ValueType: string; ValueName: "Chili.vv"; ValueData: ""; Flags: uninsdeletevalue uninsdeletekeyifempty; Tasks: assocvv
Root: HKA; Subkey: "Software\Classes\Chili.vv"; ValueType: string; ValueName: ""; ValueData: "{cm:VVFile}"; Flags: uninsdeletekey; Tasks: assocvv
Root: HKA; Subkey: "Software\Classes\Chili.vv\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\Chili.exe,0"; Tasks: assocvv
Root: HKA; Subkey: "Software\Classes\Chili.vv\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Chili.exe"" ""%1"""; Tasks: assocvv
Root: HKA; Subkey: "Software\Classes\MIME\Database\Content Type\application/x-virt-viewer"; ValueType: string; ValueName: "Extension"; ValueData: ".vv"; Flags: uninsdeletekey; Tasks: assocvv
; spice:// and spice+tls:// links
Root: HKA; Subkey: "Software\Classes\spice"; ValueType: string; ValueName: ""; ValueData: "URL:SPICE"; Flags: uninsdeletekey; Tasks: assocspice
Root: HKA; Subkey: "Software\Classes\spice"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: assocspice
Root: HKA; Subkey: "Software\Classes\spice\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\Chili.exe,0"; Tasks: assocspice
Root: HKA; Subkey: "Software\Classes\spice\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Chili.exe"" ""%1"""; Tasks: assocspice
Root: HKA; Subkey: "Software\Classes\spice+tls"; ValueType: string; ValueName: ""; ValueData: "URL:SPICE (TLS)"; Flags: uninsdeletekey; Tasks: assocspice
Root: HKA; Subkey: "Software\Classes\spice+tls"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: assocspice
Root: HKA; Subkey: "Software\Classes\spice+tls\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\Chili.exe,0"; Tasks: assocspice
Root: HKA; Subkey: "Software\Classes\spice+tls\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Chili.exe"" ""%1"""; Tasks: assocspice

[Run]
Filename: "{app}\Chili.exe"; Description: "{cm:LaunchProgram,Chili}"; Flags: nowait postinstall skipifsilent
; Updates started by Chili (silent, /CHILIRESTART=1): start it again afterwards.
Filename: "{app}\Chili.exe"; Flags: nowait; Check: StartedByUpdater

[UninstallDelete]
; Caches only (GStreamer registry, logs); settings and saved servers stay in %APPDATA%\Chili.
Type: filesandordirs; Name: "{localappdata}\Chili\Cache"
Type: filesandordirs; Name: "{localappdata}\Chili\Logs"

[Code]
// Chili's updater runs the setup silently with /CHILIRESTART=1 and exits; reopen it then.
function StartedByUpdater: Boolean;
begin
  Result := ExpandConstant('{param:CHILIRESTART|0}') = '1';
end;
