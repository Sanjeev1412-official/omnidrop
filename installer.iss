; ─────────────────────────────────────────────────────────────────────────────
; OmniDrop Windows Installer Script — Inno Setup 6
; ─────────────────────────────────────────────────────────────────────────────
; To build the installer:
;   1. Run `flutter build windows --release` first
;   2. Open this file in Inno Setup Compiler and press Ctrl+F9
;   OR run from command line:
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
; ─────────────────────────────────────────────────────────────────────────────

#define AppName       "OmniDrop"
#define AppVersion    "1.0.0"
#define AppPublisher  "Sanjeev1412-official"
#define AppURL        "https://github.com/Sanjeev1412-official/omnidrop"
#define AppExeName    "omnidrop.exe"
#define BuildDir      "build\windows\x64\runner\Release"
#define OutputDir     "installer_output"

[Setup]
; Basic metadata
AppId={{A3D2F1E4-7B8C-4D9A-B2E6-1F3A5C7D9E01}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases

; Install location
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes

; Output
OutputDir={#OutputDir}
OutputBaseFilename=OmniDrop-Setup-{#AppVersion}-x64

; Require 64-bit Windows
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Installer appearance
WizardStyle=modern
WizardSizePercent=120
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}

; Compression
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes

; Misc
AllowNoIcons=yes
ChangesAssociations=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

; Minimum Windows version: Windows 10
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon";    Description: "Create a &Desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked
Name: "startupicon";   Description: "Launch {#AppName} when Windows starts"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
; Main executable
Source: "{#BuildDir}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion

; Flutter DLLs
Source: "{#BuildDir}\flutter_windows.dll";                         DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\dartjni.dll";                                 DestDir: "{app}"; Flags: ignoreversion

; Plugin DLLs
Source: "{#BuildDir}\app_links_plugin.dll";                        DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\flutter_local_notifications_windows.dll";     DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\flutter_webrtc_plugin.dll";                   DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\gal_plugin.dll";                              DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\libwebrtc.dll";                               DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\permission_handler_windows_plugin.dll";       DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\screen_retriever_windows_plugin.dll";         DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\tray_manager_plugin.dll";                     DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\url_launcher_windows_plugin.dll";             DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\window_manager_plugin.dll";                   DestDir: "{app}"; Flags: ignoreversion

; Data folder (Flutter assets, fonts, shaders, etc.) — recursive
Source: "{#BuildDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Start Menu shortcut (user-level, no admin needed)
Name: "{userprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"
Name: "{userprograms}\Uninstall {#AppName}"; Filename: "{uninstallexe}"

; Desktop shortcut (optional task — user desktop, no admin needed)
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon; IconFilename: "{app}\{#AppExeName}"

; Startup shortcut (optional task)
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: startupicon

[Run]
; Launch app after install
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Clean up the entire app folder on uninstall
Type: filesandordirs; Name: "{app}"

[Code]
// Close OmniDrop before updating so the installer can replace DLLs
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  // If omnidrop.exe is running, kill it gracefully
  Exec('taskkill.exe', '/IM omnidrop.exe /F', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;
