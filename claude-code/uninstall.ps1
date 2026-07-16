param(
  [string] $AlgomimHome = "",
  [string] $CredentialProfile = "",
  [switch] $RemoveCredential
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
$integrationHome = [System.IO.Path]::GetFullPath((Join-Path $AlgomimHome "integrations\claude-code"))
$statePath = Join-Path $integrationHome "state.json"
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  try {
    $candidateState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($candidateState.schemaVersion -eq 1 -and $candidateState.integration -eq "claude-code") {
      $state = $candidateState
    }
    else {
      Write-Warning "Ignoring unsupported Claude Code installation state."
    }
  }
  catch {
    Write-Warning "Ignoring invalid Claude Code installation state."
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

$CredentialProfile = $CredentialProfile.Trim()
if ($CredentialProfile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
  throw "Credential profile name is invalid."
}

$credentialsPath = Join-Path $AlgomimHome "credentials"
if ($RemoveCredential) {
  $credentialResult = Remove-AlgomimCredentialProfile -Path $credentialsPath -Profile $CredentialProfile
  switch ($credentialResult) {
    "missing" { Write-Host "[algomim] Credential profile '$CredentialProfile' was not present." }
    "removed-empty" { Write-Host "[algomim] Removed credential profile '$CredentialProfile' and the empty credentials file." }
    default { Write-Host "[algomim] Removed credential profile '$CredentialProfile'." }
  }
}
else {
  Write-Host "[algomim] Kept shared Algomim credential profile '$CredentialProfile'."
}

$expectedPrefix = $AlgomimHome.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $integrationHome.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Claude Code integration path is outside ALGOMIM_HOME."
}
if (Test-Path -LiteralPath $integrationHome -PathType Container) {
  Remove-Item -LiteralPath $integrationHome -Recurse -Force
  Write-Host "[algomim] Removed Claude Code integration settings, lifecycle, and state files."
}

Write-Host "[algomim] Normal Claude Code configuration was not modified. Nothing was ever written to ~/.claude."
