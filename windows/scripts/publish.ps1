<#
  Baut Redefluss für Windows (x64, eigenständig – auf dem Ziel-PC muss kein .NET installiert sein)
  und legt ZIP und (falls Inno Setup vorhanden) Setup.exe in windows/dist ab.

  pwsh windows/scripts/publish.ps1 [-Version 0.3.0]
  Läuft auch auf macOS/Linux mit pwsh (dann ohne Setup.exe).
#>
param(
    [string]$Version = "0.0.0-dev",
    [string]$Runtime = "win-x64"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "publish/$Runtime"
$dist = Join-Path $root "dist"

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# Versionsnummer für Assembly: nur der numerische Teil (0.3.0-probe → 0.3.0).
$numeric = ($Version -split '-')[0]
dotnet publish (Join-Path $root "src/Redefluss.App/Redefluss.App.csproj") `
    -c Release -r $Runtime --self-contained true `
    -p:Version=$numeric -p:InformationalVersion=$Version -p:DebugType=none `
    -o $out
if ($LASTEXITCODE -ne 0) { throw "dotnet publish fehlgeschlagen" }

# Whisper.net legt Bibliotheken für alle Plattformen bei – nur die für dieses Ziel behalten.
Get-ChildItem (Join-Path $out "runtimes") -Directory | Where-Object { $_.Name -notin @($Runtime, "vulkan") } | Remove-Item -Recurse -Force
$vulkan = Join-Path $out "runtimes/vulkan"
if (Test-Path $vulkan) {
    Get-ChildItem $vulkan -Directory | Where-Object { $_.Name -ne $Runtime } | Remove-Item -Recurse -Force
}

$zip = Join-Path $dist "Redefluss-$Version-windows-x64.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $out "*") -DestinationPath $zip
Write-Host "ZIP: $zip"

$iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($iscc) {
    & $iscc "/DAppVersion=$Version" "/DSourceDir=$out" "/DOutputDir=$dist" (Join-Path $root "installer/Redefluss.iss")
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup fehlgeschlagen" }
} else {
    Write-Host "Inno Setup nicht gefunden – nur ZIP gebaut."
}
