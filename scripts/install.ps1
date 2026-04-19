param(
  [string]$Repo = "loongphy/codex-auth",
  [string]$Version = "latest",
  [string]$InstallDir = "$env:LOCALAPPDATA\codex-auth\bin",
  [switch]$AddToPath,
  [switch]$NoAddToPath
)

$ErrorActionPreference = "Stop"

if ($AddToPath -and $NoAddToPath) {
  throw "Cannot use -AddToPath and -NoAddToPath together."
}

function Write-Info {
  param([string]$Message)
  Write-Host $Message -ForegroundColor Cyan
}

function Write-Success {
  param([string]$Message)
  Write-Host $Message -ForegroundColor Green
}

function Write-Warn {
  param([string]$Message)
  Write-Host $Message -ForegroundColor Yellow
}

function Normalize-PathEntry {
  param([string]$PathEntry)
  if ([string]::IsNullOrWhiteSpace($PathEntry)) {
    return ""
  }
  $normalized = $PathEntry.Trim()
  if ($normalized.Length -gt 3) {
    $normalized = $normalized.TrimEnd('\')
  }
  return $normalized
}

function Get-PathSegments {
  param([string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return @()
  }
  return @(
    $PathValue -split ';' |
      ForEach-Object { Normalize-PathEntry $_ } |
      Where-Object { $_ -ne "" }
  )
}

function Detect-Asset {
  $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  $archText = switch ($arch) {
    "X64" { "X64" }
    "Arm64" { "ARM64" }
    default { throw "Unsupported architecture: $arch" }
  }
  return "codex-auth-Windows-$archText.zip"
}

if (-not (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue)) {
  throw "Invoke-WebRequest is required."
}

$Asset = Detect-Asset

$DownloadUrl = if ($Version -eq "latest") {
  "https://github.com/$Repo/releases/latest/download/$Asset"
} else {
  "https://github.com/$Repo/releases/download/$Version/$Asset"
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-auth-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
try {
  $ArchivePath = Join-Path $TempDir $Asset
  Write-Info "Downloading $DownloadUrl"
  Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath

  Expand-Archive -Path $ArchivePath -DestinationPath $TempDir -Force
  $SourceBin = Join-Path $TempDir "codex-auth.exe"
  if (-not (Test-Path $SourceBin)) {
    throw "Downloaded archive does not contain codex-auth.exe"
  }

  New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
  $DestBin = Join-Path $InstallDir "codex-auth.exe"
  Copy-Item -Path $SourceBin -Destination $DestBin -Force

  $SourceAutoBin = Join-Path $TempDir "codex-auth-auto.exe"
  if (Test-Path $SourceAutoBin) {
    $DestAutoBin = Join-Path $InstallDir "codex-auth-auto.exe"
    Copy-Item -Path $SourceAutoBin -Destination $DestAutoBin -Force
  }

  Write-Success "codex-auth installed successfully!"
  Write-Info "Path : $DestBin"
} finally {
  Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}

$normalizedInstallDir = Normalize-PathEntry $InstallDir
$currentSegments = Get-PathSegments $env:Path
$currentReady = $false

if ($currentSegments -notcontains $normalizedInstallDir) {
  $env:Path = if ([string]::IsNullOrWhiteSpace($env:Path)) { $InstallDir } else { "$InstallDir;$env:Path" }
  $currentReady = $true
} else {
  $currentReady = $true
}

$persistPath = -not $NoAddToPath
if ($persistPath) {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $userSegments = Get-PathSegments $userPath
  if ($userSegments -notcontains $normalizedInstallDir) {
    $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $InstallDir } else { "$userPath;$InstallDir" }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  }
  Write-Success "Ready for PowerShell (loaded via user PATH)."
} else {
  if ($currentReady) {
    Write-Success "Ready in this terminal."
  }
  Write-Info "Run without -NoAddToPath to load it automatically in future PowerShell sessions."
}
