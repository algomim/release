param(
  [string] $AlgomimHome = "",
  [string] $ReleaseRef = "",
  [string] $ReleaseVersion = "0.3.5",
  [ValidateSet("User", "Process")]
  [string] $PathTarget = "User"
)

$ErrorActionPreference = "Stop"

function Write-Step {
  param([string] $Message)
  Write-Host "[algomim] $Message"
}

function Copy-FileAtomically {
  param([string] $Source, [string] $Destination)

  $directory = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  if ((Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Refusing to replace a symbolic link or reparse point: $Destination"
  }
  $temporaryPath = Join-Path $directory (".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($Destination)), [Guid]::NewGuid().ToString("N"))
  $backupPath = Join-Path $directory (".{0}.{1}.bak" -f ([System.IO.Path]::GetFileName($Destination)), [Guid]::NewGuid().ToString("N"))
  try {
    [System.IO.File]::WriteAllBytes($temporaryPath, [System.IO.File]::ReadAllBytes($Source))
    if (Test-Path -LiteralPath $Destination) {
      [System.IO.File]::Replace($temporaryPath, $Destination, $backupPath)
      Remove-Item -LiteralPath $backupPath -Force
    }
    else {
      [System.IO.File]::Move($temporaryPath, $Destination)
    }
  }
  finally {
    foreach ($candidate in @($temporaryPath, $backupPath)) {
      if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force }
    }
  }
}

function Install-RepositoryFile {
  param([string] $RepositoryPath, [string] $Destination)

  $localPath = if ($PSScriptRoot) { Join-Path (Split-Path -Parent $PSScriptRoot) $RepositoryPath } else { "" }
  if ($localPath -and (Test-Path -LiteralPath $localPath -PathType Leaf)) {
    Copy-FileAtomically -Source $localPath -Destination $Destination
    return
  }
  $downloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-cli-{0}" -f [Guid]::NewGuid().ToString("N"))
  try {
    $normalizedPath = $RepositoryPath.Replace("\", "/")
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/algomim/release/$ReleaseRef/$normalizedPath" -OutFile $downloadPath -UseBasicParsing
    Copy-FileAtomically -Source $downloadPath -Destination $Destination
  }
  finally {
    if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force }
  }
}

function Add-PathEntry {
  param([AllowEmptyString()][string] $Value, [string] $Entry)

  $parts = @($Value -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $normalizedEntry = $Entry.Trim().TrimEnd('\', '/')
  foreach ($part in $parts) {
    if ($part.Trim().Trim('"').TrimEnd('\', '/') -ieq $normalizedEntry) {
      return ($parts -join ';')
    }
  }
  return (@($parts) + $Entry) -join ';'
}

if ($ReleaseVersion -notmatch '^\d+\.\d+\.\d+$') {
  throw "ReleaseVersion must use MAJOR.MINOR.PATCH format."
}
if ([string]::IsNullOrWhiteSpace($ReleaseRef)) { $ReleaseRef = "v$ReleaseVersion" }
if ($ReleaseRef -notmatch '^[A-Za-z0-9._/-]+$') { throw "ReleaseRef contains unsupported characters." }
if ([string]::IsNullOrWhiteSpace($AlgomimHome)) {
  $AlgomimHome = if ($env:ALGOMIM_HOME) { $env:ALGOMIM_HOME } else { Join-Path $HOME ".algomim" }
}
$AlgomimHome = [System.IO.Path]::GetFullPath($AlgomimHome)
$binDirectory = Join-Path $AlgomimHome "bin"
$cliDirectory = Join-Path $AlgomimHome "cli"
$codexSupportDirectory = Join-Path $cliDirectory "integrations\codex"
$claudeCodeSupportDirectory = Join-Path $cliDirectory "integrations\claude-code"
$statePath = Join-Path $cliDirectory "state.json"

New-Item -ItemType Directory -Force -Path $binDirectory, $cliDirectory, $codexSupportDirectory, $claudeCodeSupportDirectory | Out-Null
Install-RepositoryFile "cli\algomim.ps1" (Join-Path $binDirectory "algomim.ps1")
Install-RepositoryFile "cli\algomim.cmd" (Join-Path $binDirectory "algomim.cmd")
Install-RepositoryFile "shared\credential-store.ps1" (Join-Path $cliDirectory "credential-store.ps1")
Install-RepositoryFile "cli\release.json" (Join-Path $cliDirectory "release.json")
foreach ($name in @("algomim-models.json", "algomim-models.lock.json", "install.ps1", "update.ps1", "doctor.ps1", "uninstall.ps1", "release.json")) {
  Install-RepositoryFile "codex\$name" (Join-Path $codexSupportDirectory $name)
}
Install-RepositoryFile "shared\credential-store.ps1" (Join-Path $codexSupportDirectory "credential-store.ps1")
foreach ($name in @("install.ps1", "update.ps1", "doctor.ps1", "uninstall.ps1", "release.json")) {
  Install-RepositoryFile "claude-code\$name" (Join-Path $claudeCodeSupportDirectory $name)
}
Install-RepositoryFile "shared\credential-store.ps1" (Join-Path $claudeCodeSupportDirectory "credential-store.ps1")

$now = [DateTimeOffset]::UtcNow.ToString("o")
$installedAt = $now
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  try {
    $existing = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($existing.schemaVersion -eq 1 -and $existing.product -eq "algomim-cli" -and -not [string]::IsNullOrWhiteSpace($existing.installedAt)) {
      $installedAt = [string] $existing.installedAt
    }
  }
  catch {
    throw "Existing Algomim CLI state is invalid: $statePath"
  }
}
$state = [ordered] @{
  schemaVersion = 1
  product = "algomim-cli"
  version = $ReleaseVersion
  releaseTag = $ReleaseRef
  releaseRepository = "algomim/release"
  installedAt = $installedAt
  updatedAt = $now
}
$stateTemporary = Join-Path $cliDirectory (".state.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
try {
  $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($stateTemporary, (($state | ConvertTo-Json) + [Environment]::NewLine), $utf8WithoutBom)
  Copy-FileAtomically -Source $stateTemporary -Destination $statePath
}
finally {
  if (Test-Path -LiteralPath $stateTemporary) { Remove-Item -LiteralPath $stateTemporary -Force }
}

$env:PATH = Add-PathEntry -Value $env:PATH -Entry $binDirectory
if ($PathTarget -eq "User") {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $updatedUserPath = Add-PathEntry -Value $userPath -Entry $binDirectory
  if ($updatedUserPath -cne $userPath) {
    [Environment]::SetEnvironmentVariable("Path", $updatedUserPath, "User")
    Write-Step "Added $binDirectory to the user PATH."
  }
  else {
    Write-Step "Algomim CLI is already on the user PATH."
  }
}
else {
  Write-Step "Added $binDirectory to the current process PATH."
}

Write-Step "Installed Algomim CLI $ReleaseVersion."
