# Build Tacx Desktop Setup.exe with Inno Setup (ISCC).
# Usage (from repo root, after flutter build windows --release):
#   pwsh ./scripts/package_windows_installer.ps1 [-Version 0.2.1] [-ReleaseDir path] [-OutDir path]
param(
  [string]$Version = "",
  [string]$ReleaseDir = "",
  [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
if (-not $ReleaseDir) {
  $ReleaseDir = Join-Path $Root "build\windows\x64\runner\Release"
}
if (-not $OutDir) {
  $OutDir = Join-Path $Root "dist"
}
if (-not $Version) {
  if ($env:GITHUB_REF_TYPE -eq "tag") {
    $Version = $env:GITHUB_REF_NAME
  } elseif ($env:GITHUB_SHA) {
    $Version = "main-" + $env:GITHUB_SHA.Substring(0, 7)
  } else {
    $Version = "0.2.1-local"
  }
}
# Sanitize for filename
$SafeVer = ($Version -replace '[^\w\.\-]+', '-')

$Exe = Join-Path $ReleaseDir "tacx_desktop.exe"
if (-not (Test-Path $Exe)) {
  throw "Missing $Exe — run flutter build windows --release first"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$Iscc = $null
foreach ($c in @(
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
)) {
  if (Test-Path $c) { $Iscc = $c; break }
}
if (-not $Iscc) {
  $cmd = Get-Command iscc -ErrorAction SilentlyContinue
  if ($cmd) { $Iscc = $cmd.Source }
}
if (-not $Iscc) {
  throw "ISCC.exe not found. Install Inno Setup 6 (choco install innosetup)."
}

$Iss = Join-Path $Root "packaging\windows\tacx-desktop.iss"
$OutFile = "TacxDesktop-Setup-$SafeVer"
& $Iscc `
  "/DMyAppVersion=$SafeVer" `
  "/DMyReleaseDir=$ReleaseDir" `
  "/DMyOutDir=$OutDir" `
  "/DMyOutFile=$OutFile" `
  $Iss

$Setup = Join-Path $OutDir "$OutFile.exe"
if (-not (Test-Path $Setup)) {
  throw "Installer not produced: $Setup"
}
Write-Host "INSTALLER=$Setup"
Get-Item $Setup | Format-List FullName, Length
