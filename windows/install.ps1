<#
  Redefluss auf diesem Windows-PC aus dem Quellcode bauen und installieren.

    powershell -ExecutionPolicy Bypass -File windows\install.ps1 [-WithModel]

  Prüft Windows 10/11 und das .NET-SDK (installiert es bei Bedarf per winget), baut für x64,
  installiert nach %LOCALAPPDATA%\Programs\Redefluss (ohne Adminrechte), legt eine Startmenü-
  Verknüpfung an, lädt mit -WithModel das empfohlene Modell (574 MB; übersprungen, wenn in
  %USERPROFILE%\.cache\whisper-cpp schon ein Turbo-Modell liegt) und startet die App.
#>
param([switch]$WithModel)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

if ([Environment]::OSVersion.Version.Major -lt 10) { throw "Redefluss braucht Windows 10 oder 11." }
if (-not [Environment]::Is64BitOperatingSystem) { throw "Redefluss braucht ein 64-Bit-Windows." }

function Has-DotnetSdk {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { return $false }
    return [bool](dotnet --list-sdks | Where-Object { $_ -match '^(10|1[1-9])\.' })
}
if (-not (Has-DotnetSdk)) {
    Write-Host ".NET-SDK 10 fehlt – wird per winget installiert …"
    winget install --id Microsoft.DotNet.SDK.10 --source winget --accept-package-agreements --accept-source-agreements
    $env:PATH = [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not (Has-DotnetSdk)) { throw ".NET-SDK 10 nicht gefunden. Bitte https://dot.net/download installieren und neu starten." }
}

Write-Host "Tests …"
dotnet test (Join-Path $root "tests\Redefluss.Core.Tests") --nologo -v q
if ($LASTEXITCODE -ne 0) { throw "Tests fehlgeschlagen." }

Write-Host "Bauen …"
& (Join-Path $root "scripts\publish.ps1") -Version "0.3.0-lokal"
$built = Join-Path $root "publish\win-x64"

$target = Join-Path $env:LOCALAPPDATA "Programs\Redefluss"
Get-Process Redefluss -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
if (Test-Path $target) { Remove-Item $target -Recurse -Force }
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item (Join-Path $built "*") $target -Recurse -Force
$exe = Join-Path $target "Redefluss.exe"

$shortcut = Join-Path ([Environment]::GetFolderPath("Programs")) "Redefluss.lnk"
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = $exe
$link.WorkingDirectory = $target
$link.Save()
Write-Host "Installiert: $exe"

if ($WithModel) {
    $cache = Join-Path $env:USERPROFILE ".cache\whisper-cpp"
    $models = Join-Path $env:LOCALAPPDATA "Redefluss\Models"
    $existing = @($cache, $models) | Where-Object { Test-Path $_ } |
        ForEach-Object { Get-ChildItem $_ -Filter "ggml-large-v3-turbo*.bin" } |
        Where-Object { $_.Length -gt 20MB }
    if ($existing) {
        Write-Host "Turbo-Modell schon vorhanden: $($existing[0].FullName)"
    } else {
        New-Item -ItemType Directory -Force -Path $models | Out-Null
        $file = Join-Path $models "ggml-large-v3-turbo-q5_0.bin"
        Write-Host "Lade Sprachmodell (574 MB) …"
        $ProgressPreference = "SilentlyContinue"   # sonst ist Invoke-WebRequest extrem langsam
        Invoke-WebRequest "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin" -OutFile "$file.part"
        if ((Get-Item "$file.part").Length -lt 500MB) { Remove-Item "$file.part"; throw "Modell-Download unvollständig." }
        Move-Item "$file.part" $file -Force
    }
}

Start-Process $exe
Write-Host ""
Write-Host "Redefluss läuft (Symbol im Infobereich der Taskleiste)."
Write-Host "Bitte jetzt: Einführung durchklicken; falls Diktate stumm bleiben:"
Write-Host "  Einstellungen → Datenschutz und Sicherheit → Mikrofon → 'Desktop-Apps Zugriff erlauben' einschalten."
