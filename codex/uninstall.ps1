param(
  [string] $CodexHome = "",
  [string] $AlgomimHome = "",
  [string] $CredentialProfile = "",
  [switch] $RemoveCredential,
  [switch] $KeepKey
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($AlgomimHome)) {
  $AlgomimHome = if ($env:ALGOMIM_HOME) { $env:ALGOMIM_HOME } else { Join-Path $HOME ".algomim" }
}
$AlgomimHome = [System.IO.Path]::GetFullPath($AlgomimHome)
$credentialHelper = if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot "credential-store.ps1") -PathType Leaf)) {
  Join-Path $PSScriptRoot "credential-store.ps1"
}
else {
  Join-Path $AlgomimHome "cli\credential-store.ps1"
}
if (-not (Test-Path -LiteralPath $credentialHelper -PathType Leaf)) {
  throw "Algomim credential helper is missing: $credentialHelper"
}
. $credentialHelper
$integrationHome = [System.IO.Path]::GetFullPath((Join-Path $AlgomimHome "integrations\codex"))
$statePath = Join-Path $integrationHome "state.json"
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  try {
    $candidateState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($candidateState.schemaVersion -eq 1 -and $candidateState.integration -eq "codex") {
      $state = $candidateState
    }
    else {
      Write-Warning "Ignoring unsupported Codex installation state."
    }
  }
  catch {
    Write-Warning "Ignoring invalid Codex installation state."
  }
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
  $CodexHome = if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.codexHome)) {
    [string] $state.codexHome
  }
  elseif ($env:CODEX_HOME) {
    $env:CODEX_HOME
  }
  else {
    Join-Path $HOME ".codex"
  }
}
if ([string]::IsNullOrWhiteSpace($CredentialProfile)) {
  $CredentialProfile = if ($env:ALGOMIM_PROFILE) {
    $env:ALGOMIM_PROFILE
  }
  elseif ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.credentialProfile)) {
    [string] $state.credentialProfile
  }
  else {
    "default"
  }
}

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$CredentialProfile = $CredentialProfile.Trim()
if ($CredentialProfile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
  throw "Credential profile name is invalid."
}

$paths = @(
  (Join-Path $CodexHome "algomim.config.toml"),
  (Join-Path $CodexHome "algomim-models.json"),
  (Join-Path $CodexHome "algomim-models.lock.json"),
  (Join-Path $CodexHome "algomim-auth.ps1")
)
foreach ($path in $paths) {
  if (Test-Path -LiteralPath $path) {
    Remove-Item -LiteralPath $path -Force
    Write-Host "[algomim] Removed $path"
  }
}

if ($KeepKey) {
  Write-Warning "-KeepKey is no longer required; credentials are preserved by default."
}

$legacyKeyPath = Join-Path $CodexHome "algomim.key"
$credentialsPath = Join-Path $AlgomimHome "credentials"
if ($RemoveCredential) {
  $credentialResult = Remove-AlgomimCredentialProfile -Path $credentialsPath -Profile $CredentialProfile
  switch ($credentialResult) {
    "missing" { Write-Host "[algomim] Credential profile '$CredentialProfile' was not present." }
    "removed-empty" { Write-Host "[algomim] Removed credential profile '$CredentialProfile' and the empty credentials file." }
    default { Write-Host "[algomim] Removed credential profile '$CredentialProfile'." }
  }
  if (Test-Path -LiteralPath $legacyKeyPath) {
    Remove-Item -LiteralPath $legacyKeyPath -Force
    Write-Host "[algomim] Removed the legacy Codex key file."
  }
}
else {
  Write-Host "[algomim] Kept shared Algomim credential profile '$CredentialProfile'."
  if (Test-Path -LiteralPath $legacyKeyPath) {
    Write-Warning "A legacy Codex key remains. Re-run the installer to migrate it."
  }
}

$expectedPrefix = $AlgomimHome.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $integrationHome.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Codex integration path is outside ALGOMIM_HOME."
}
if (Test-Path -LiteralPath $integrationHome -PathType Container) {
  Remove-Item -LiteralPath $integrationHome -Recurse -Force
  Write-Host "[algomim] Removed Codex integration lifecycle and state files."
}

Write-Host "[algomim] Normal Codex configuration was not modified."
