param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $CliArguments
)

$ErrorActionPreference = "Stop"

function Write-Usage {
  Write-Output @"
Algomim CLI

Usage:
  algomim login [--profile <name>] [--api-key-stdin]
  algomim logout [--profile <name>] [--yes]
  algomim version
  algomim help

  algomim codex install [--profile <name>]
  algomim codex update [--check]
  algomim codex doctor [--offline]
  algomim codex uninstall
"@
}

function Fail-Usage {
  param([string] $Message)
  [Console]::Error.WriteLine("$Message`nRun 'algomim help' for usage.")
  exit 2
}

function Get-OptionValue {
  param([string[]] $Values, [ref] $Index, [string] $Option)
  if ($Index.Value + 1 -ge $Values.Count) {
    Fail-Usage "$Option requires a value."
  }
  $Index.Value++
  return $Values[$Index.Value]
}

function Read-CliState {
  if (-not (Test-Path -LiteralPath $script:CliStatePath -PathType Leaf)) {
    throw "Algomim CLI state is missing. Re-run the versioned installer."
  }
  try {
    $state = Get-Content -Raw -LiteralPath $script:CliStatePath | ConvertFrom-Json
  }
  catch {
    throw "Algomim CLI state is invalid. Re-run the versioned installer."
  }
  if ($state.schemaVersion -ne 1 -or $state.product -ne "algomim-cli" -or [string]::IsNullOrWhiteSpace($state.version)) {
    throw "Algomim CLI state has an unsupported contract."
  }
  return $state
}

function Get-SelectedProfile {
  param([string] $ExplicitProfile)
  $profile = if (-not [string]::IsNullOrWhiteSpace($ExplicitProfile)) {
    $ExplicitProfile
  }
  elseif (-not [string]::IsNullOrWhiteSpace($env:ALGOMIM_PROFILE)) {
    $env:ALGOMIM_PROFILE
  }
  else {
    "default"
  }
  $profile = $profile.Trim()
  Assert-AlgomimCredentialProfileName $profile
  return $profile
}

function Invoke-Login {
  param([string[]] $Arguments)
  $profile = ""
  $readFromStdin = $false
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    switch ($Arguments[$index]) {
      "--profile" { $profile = Get-OptionValue $Arguments ([ref] $index) "--profile" }
      "--api-key-stdin" { $readFromStdin = $true }
      default { Fail-Usage "Unknown login option: $($Arguments[$index])" }
    }
  }
  $profile = Get-SelectedProfile $profile
  $apiKey = if ($readFromStdin) {
    Normalize-AlgomimApiKey ([Console]::In.ReadToEnd())
  }
  else {
    Read-AlgomimRequiredSecretPlainText "Algomim API key"
  }
  try {
    Set-AlgomimCredentialApiKey -Path $script:CredentialsPath -Profile $profile -Value $apiKey
  }
  finally {
    $apiKey = $null
  }
  Write-Host "[algomim] Credential profile '$profile' is ready."
}

function Invoke-Logout {
  param([string[]] $Arguments)
  $profile = ""
  $confirmed = $false
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    switch ($Arguments[$index]) {
      "--profile" { $profile = Get-OptionValue $Arguments ([ref] $index) "--profile" }
      "--yes" { $confirmed = $true }
      default { Fail-Usage "Unknown logout option: $($Arguments[$index])" }
    }
  }
  $profile = Get-SelectedProfile $profile
  if (-not $confirmed) {
    $answer = Read-Host "Remove Algomim credential profile '$profile'? [y/N]"
    $confirmed = $answer -match '^(?i:y|yes)$'
  }
  if (-not $confirmed) {
    Write-Host "[algomim] Logout cancelled."
    return
  }
  $result = Remove-AlgomimCredentialProfile -Path $script:CredentialsPath -Profile $profile
  switch ($result) {
    "missing" { Write-Host "[algomim] Credential profile '$profile' was not present." }
    "removed-empty" { Write-Host "[algomim] Removed credential profile '$profile' and the empty credentials file." }
    default { Write-Host "[algomim] Removed credential profile '$profile'." }
  }
}

function Get-CodexLifecyclePath {
  param([string] $Name)
  $path = Join-Path $script:AlgomimHome "integrations\codex\$Name"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Codex integration is not installed. Run 'algomim codex install'."
  }
  return $path
}

function Invoke-CodexCommand {
  param([string[]] $Arguments)
  if ($Arguments.Count -eq 0) {
    Fail-Usage "A Codex command is required."
  }
  $subcommand = $Arguments[0]
  $options = @($Arguments | Select-Object -Skip 1)
  switch ($subcommand) {
    "install" {
      $profile = ""
      for ($index = 0; $index -lt $options.Count; $index++) {
        if ($options[$index] -ne "--profile") {
          Fail-Usage "Unknown codex install option: $($options[$index])"
        }
        $profile = Get-OptionValue $options ([ref] $index) "--profile"
      }
      $profile = Get-SelectedProfile $profile
      $state = Read-CliState
      $installer = Join-Path $script:AlgomimHome "cli\integrations\codex\install.ps1"
      if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "The bundled Codex installer is missing. Re-run the versioned Algomim installer."
      }
      & $installer -AlgomimHome $script:AlgomimHome -CredentialProfile $profile -ReleaseRef ([string] $state.releaseTag) -ReleaseVersion ([string] $state.version) -SkipCliInstall
      & (Get-CodexLifecyclePath "doctor.ps1") -AlgomimHome $script:AlgomimHome -CredentialProfile $profile -SkipApiCheck -ThrowOnFailure
    }
    "update" {
      $check = $false
      foreach ($option in $options) {
        if ($option -ne "--check") { Fail-Usage "Unknown codex update option: $option" }
        $check = $true
      }
      $script = Get-CodexLifecyclePath "update.ps1"
      if ($check) { & $script -AlgomimHome $script:AlgomimHome -CheckOnly }
      else { & $script -AlgomimHome $script:AlgomimHome }
    }
    "doctor" {
      $offline = $false
      foreach ($option in $options) {
        if ($option -ne "--offline") { Fail-Usage "Unknown codex doctor option: $option" }
        $offline = $true
      }
      $script = Get-CodexLifecyclePath "doctor.ps1"
      if ($offline) { & $script -AlgomimHome $script:AlgomimHome -SkipApiCheck -ThrowOnFailure }
      else { & $script -AlgomimHome $script:AlgomimHome -ThrowOnFailure }
    }
    "uninstall" {
      if ($options.Count -gt 0) { Fail-Usage "codex uninstall does not accept options." }
      & (Get-CodexLifecyclePath "uninstall.ps1") -AlgomimHome $script:AlgomimHome
      Write-Host "[algomim] Algomim CLI and shared credentials were preserved."
    }
    default { Fail-Usage "Unknown Codex command: $subcommand" }
  }
}

$script:AlgomimHome = if ($env:ALGOMIM_HOME) { $env:ALGOMIM_HOME } else { Join-Path $HOME ".algomim" }
$script:AlgomimHome = [System.IO.Path]::GetFullPath($script:AlgomimHome)
$script:CliStatePath = Join-Path $script:AlgomimHome "cli\state.json"
$script:CredentialsPath = Join-Path $script:AlgomimHome "credentials"
$credentialHelper = Join-Path $script:AlgomimHome "cli\credential-store.ps1"
if (-not (Test-Path -LiteralPath $credentialHelper -PathType Leaf)) {
  $credentialHelper = Join-Path (Split-Path -Parent $PSScriptRoot) "shared\credential-store.ps1"
}
if (-not (Test-Path -LiteralPath $credentialHelper -PathType Leaf)) {
  throw "Algomim credential helper is missing. Re-run the versioned installer."
}
. $credentialHelper

if ($null -eq $CliArguments) { $CliArguments = @() }
if ($CliArguments.Count -eq 0) {
  Write-Usage
  exit 0
}

try {
  $command = $CliArguments[0]
  $remaining = @($CliArguments | Select-Object -Skip 1)
  switch ($command) {
    "login" { Invoke-Login $remaining }
    "logout" { Invoke-Logout $remaining }
    "version" {
      if ($remaining.Count -gt 0) { Fail-Usage "version does not accept options." }
      $state = Read-CliState
      Write-Output "Algomim CLI $($state.version) ($($state.releaseTag))"
      $codexStatePath = Join-Path $script:AlgomimHome "integrations\codex\state.json"
      if (Test-Path -LiteralPath $codexStatePath -PathType Leaf) {
        $codexState = Get-Content -Raw -LiteralPath $codexStatePath | ConvertFrom-Json
        Write-Output "Codex integration $($codexState.version)"
      }
    }
    "help" {
      if ($remaining.Count -gt 0) { Fail-Usage "help does not accept options." }
      Write-Usage
    }
    "codex" { Invoke-CodexCommand $remaining }
    default { Fail-Usage "Unknown command: $command" }
  }
}
catch {
  [Console]::Error.WriteLine("[algomim] $($_.Exception.Message)")
  exit 1
}
