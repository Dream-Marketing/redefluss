; Installer für Redefluss (Windows). Wird von scripts/publish.ps1 mit /DAppVersion, /DSourceDir, /DOutputDir aufgerufen.
; Installiert ohne Adminrechte nach %LOCALAPPDATA%\Programs\Redefluss.

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

[Setup]
AppId={{6A4E3F2B-9C1D-4B8E-A7F0-5D2C3B1E9A44}
AppName=Redefluss
AppVersion={#AppVersion}
AppPublisher=Dream Marketing
DefaultDirName={localappdata}\Programs\Redefluss
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=Redefluss-{#AppVersion}-windows-x64-setup
SetupIconFile=..\src\Redefluss.App\Assets\Redefluss.ico
UninstallDisplayIcon={app}\Redefluss.exe
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
CloseApplications=force
WizardStyle=modern

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "autostart"; Description: "Beim Anmelden starten"; GroupDescription: "Zusätzlich:"
Name: "desktopicon"; Description: "Verknüpfung auf dem Desktop"; GroupDescription: "Zusätzlich:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Redefluss"; Filename: "{app}\Redefluss.exe"
Name: "{userdesktop}\Redefluss"; Filename: "{app}\Redefluss.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Redefluss"; \
  ValueData: """{app}\Redefluss.exe"" --autostart"; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\Redefluss.exe"; Description: "Redefluss jetzt starten"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM Redefluss.exe /F"; Flags: runhidden; RunOnceId: "StopRedefluss"

[UninstallDelete]
; Einstellungen und Verlauf (%APPDATA%\Redefluss) und Modelle (%LOCALAPPDATA%\Redefluss) bleiben bewusst erhalten.
Type: filesandordirs; Name: "{app}"
