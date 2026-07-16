param(
  [string] $AlgomimHome = "",
  [string] $Version = "",
  [string] $ManifestUrl = "",
  [string] $ArtifactBaseUrl = "",
  [switch] $Force,
  [switch] $CheckOnly
)

$ErrorActionPreference = "Stop"

function Write-Step {
  param([string] $Message)
  Write-Host "[algomim] $Message"
}

function Copy-SourceToFile {
  param(
    [string] $Source,
    [string] $Destination
  )

  if (Test-Path -LiteralPath $Source -PathType Leaf) {
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return
  }

  if ($Source -notmatch '^https://') {
    throw "Release source must be a local file or an HTTPS URL: $Source"
  }
  Invoke-WebRequest -Uri $Source -OutFile $Destination -UseBasicParsing
}

function Assert-SemanticVersion {
  param([string] $Value)
  if ($Value -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must use MAJOR.MINOR.PATCH format: $Value"
  }
}

function Restore-Installation {
  param(
    [string] $IntegrationHome,
    [string] $BackupRoot
  )

  if (Test-Path -LiteralPath $IntegrationHome) {
    Get-ChildItem -LiteralPath $IntegrationHome -Force | Remove-Item -Recurse -Force
  }
  else {
    New-Item -ItemType Directory -Path $IntegrationHome -Force | Out-Null
  }

  $integrationBackup = Join-Path $BackupRoot "integration"
  if (Test-Path -LiteralPath $integrationBackup -PathType Container) {
    Get-ChildItem -LiteralPath $integrationBackup -Force | Copy-Item -Destination $IntegrationHome -Recurse -Force
  }
}

if ([string]::IsNullOrWhiteSpace($AlgomimHome)) {
  $AlgomimHome = if ($env:ALGOMIM_HOME) { $env:ALGOMIM_HOME } else { Join-Path $HOME ".algomim" }
}
$AlgomimHome = [System.IO.Path]::GetFullPath($AlgomimHome)
$integrationHome = [System.IO.Path]::GetFullPath((Join-Path $AlgomimHome "integrations\claude-code"))
$expectedPrefix = $AlgomimHome.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $integrationHome.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Claude Code integration path is outside ALGOMIM_HOME."
}

$statePath = Join-Path $integrationHome "state.json"
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
  throw "Claude Code installation state is missing. Run the versioned installer first: $statePath"
}

try {
  $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
}
catch {
  throw "Claude Code installation state is invalid: $statePath"
}
if ($state.schemaVersion -ne 1 -or $state.integration -ne "claude-code") {
  throw "Unsupported Claude Code installation state."
}

$installedVersion = [string] $state.version
Assert-SemanticVersion $installedVersion
$repository = [string] $state.releaseRepository
if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
  throw "Installation state contains an invalid release repository."
}

$requestedVersion = $Version.Trim().TrimStart("v")
if ($requestedVersion.Length -gt 0) {
  Assert-SemanticVersion $requestedVersion
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-update-{0}" -f [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
  $manifestPath = Join-Path $temporaryRoot "manifest.json"
  if ([string]::IsNullOrWhiteSpace($ManifestUrl)) {
    $ManifestUrl = if ($requestedVersion.Length -gt 0) {
      "https://github.com/$repository/releases/download/v$requestedVersion/manifest.json"
    }
    else {
      "https://github.com/$repository/releases/latest/download/manifest.json"
    }
  }
  Copy-SourceToFile -Source $ManifestUrl -Destination $manifestPath

  try {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  }
  catch {
    throw "Release manifest is not valid JSON."
  }
  if ($manifest.schemaVersion -ne 1 -or $manifest.integration -ne "codex") {
    throw "Release manifest has an unsupported contract."
  }
  if ($null -eq $manifest.claudeCodeArtifacts) {
    throw "Release manifest does not contain Claude Code artifacts."
  }

  $targetVersion = [string] $manifest.version
  Assert-SemanticVersion $targetVersion
  if ($requestedVersion.Length -gt 0 -and $targetVersion -ne $requestedVersion) {
    throw "Release manifest version does not match the requested version."
  }
  $releaseTag = [string] $manifest.releaseTag
  if ($releaseTag -ne "v$targetVersion") {
    throw "Release manifest tag does not match its version."
  }

  $installed = [Version] $installedVersion
  $target = [Version] $targetVersion
  if (-not $Force -and $target -lt $installed) {
    throw "Refusing to downgrade from $installedVersion to $targetVersion without -Force."
  }
  if (-not $Force -and $target -eq $installed) {
    Write-Step "Claude Code integration is already up to date at $installedVersion."
    return
  }
  if ($CheckOnly) {
    Write-Step "Claude Code integration update available: $installedVersion -> $targetVersion"
    return
  }

  $artifact = $manifest.claudeCodeArtifacts.windows
  if ($null -eq $artifact -or $artifact.format -ne "zip") {
    throw "Release manifest must contain one ZIP Windows Claude Code artifact."
  }
  $artifactName = [string] $artifact.file
  if ([System.IO.Path]::GetFileName($artifactName) -ne $artifactName -or $artifactName -notmatch '\.zip$') {
    throw "Windows artifact name is invalid."
  }
  $expectedHash = ([string] $artifact.sha256).ToLowerInvariant()
  if ($expectedHash -notmatch '^[a-f0-9]{64}$') {
    throw "Windows artifact checksum is invalid."
  }

  $artifactPath = Join-Path $temporaryRoot $artifactName
  $artifactSource = if ([string]::IsNullOrWhiteSpace($ArtifactBaseUrl)) {
    "https://github.com/$repository/releases/download/$releaseTag/$artifactName"
  }
  elseif (Test-Path -LiteralPath $ArtifactBaseUrl -PathType Container) {
    Join-Path $ArtifactBaseUrl $artifactName
  }
  else {
    "$($ArtifactBaseUrl.TrimEnd('/'))/$artifactName"
  }
  Copy-SourceToFile -Source $artifactSource -Destination $artifactPath

  $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -cne $expectedHash) {
    throw "Release artifact checksum verification failed."
  }
  Write-Step "Verified $artifactName (SHA-256)."

  $stageRoot = Join-Path $temporaryRoot "stage"
  Expand-Archive -LiteralPath $artifactPath -DestinationPath $stageRoot -Force
  $stagedClaudeCode = Join-Path $stageRoot "claude-code"
  $stagedInstaller = Join-Path $stagedClaudeCode "install.ps1"
  $stagedDoctor = Join-Path $stagedClaudeCode "doctor.ps1"
  foreach ($requiredPath in @($stagedInstaller, $stagedDoctor, (Join-Path $stagedClaudeCode "update.ps1"), (Join-Path $stagedClaudeCode "release.json"))) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "Release artifact is missing a required Claude Code file."
    }
  }

  $releaseContract = Get-Content -Raw -LiteralPath (Join-Path $stagedClaudeCode "release.json") | ConvertFrom-Json
  if ($releaseContract.integration -ne "claude-code" -or $releaseContract.version -ne $targetVersion -or $releaseContract.releaseTag -ne $releaseTag) {
    throw "Release artifact contract does not match the manifest."
  }

  $backupRoot = Join-Path $temporaryRoot "backup"
  $integrationBackup = Join-Path $backupRoot "integration"
  New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
  Copy-Item -LiteralPath $integrationHome -Destination $integrationBackup -Recurse -Force

  $savedAlgomimHome = $env:ALGOMIM_HOME
  try {
    $env:ALGOMIM_HOME = $AlgomimHome
    & $stagedInstaller `
      -BaseUrl ([string] $state.baseUrl) `
      -CredentialProfile ([string] $state.credentialProfile) `
      -AlgomimHome $AlgomimHome `
      -ReleaseRef $releaseTag `
      -ReleaseVersion $targetVersion `
      -SkipKey `
      -SkipCliInstall

    & $stagedDoctor `
      -AlgomimHome $AlgomimHome `
      -CredentialProfile ([string] $state.credentialProfile) `
      -SkipApiCheck `
      -ThrowOnFailure

    $updatedState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($updatedState.version -ne $targetVersion) {
      throw "Updated installation state does not match the target version."
    }
  }
  catch {
    $updateError = $_
    Write-Warning "Update failed; restoring Claude Code integration $installedVersion."
    Restore-Installation -IntegrationHome $integrationHome -BackupRoot $backupRoot
    throw "Claude Code update rolled back: $($updateError.Exception.Message)"
  }
  finally {
    if ($null -eq $savedAlgomimHome) { Remove-Item Env:ALGOMIM_HOME -ErrorAction SilentlyContinue } else { $env:ALGOMIM_HOME = $savedAlgomimHome }
  }

  Write-Step "Updated Claude Code integration from $installedVersion to $targetVersion."
}
finally {
  if (Test-Path -LiteralPath $temporaryRoot) {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
  }
}
