# No param block: PowerShell 5.1's -File binder swallows a literal "--"
# (needed by "algomim run <client> -- <args>") when a parameter block is
# present. $args receives every token verbatim, including "--".
$ErrorActionPreference = "Stop"
$CliArguments = @($args | ForEach-Object { [string] $_ })

function Write-Usage {
  Write-Output @"
Algomim CLI

Usage:
  algomim login [--profile <name>] [--api-key-stdin]
  algomim logout [--profile <name>] [--yes]
  algomim version
  algomim help

  algomim install <codex|claude> [--profile <name>]
  algomim run <codex|claude> [-- <client arguments>]
  algomim doctor [codex|claude] [--offline]
  algomim update [codex|claude] [--check]
  algomim uninstall <codex|claude>
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

$script:IntegrationIds = @("codex", "claude-code")

function Resolve-IntegrationName {
  param([string] $Token)
  switch ($Token) {
    "codex" { return "codex" }
    "claude" { return "claude-code" }
    "claude-code" { return "claude-code" }
    default { Fail-Usage "Unknown integration: $Token. Valid integrations: codex, claude." }
  }
}

function Get-IntegrationToken {
  param([string] $Integration)
  if ($Integration -eq "claude-code") { return "claude" }
  return $Integration
}

function Get-IntegrationDisplayName {
  param([string] $Integration)
  if ($Integration -eq "claude-code") { return "Claude Code" }
  return "Codex"
}

function Get-IntegrationLifecyclePath {
  param([string] $Integration, [string] $Name)
  $path = Join-Path $script:AlgomimHome "integrations\$Integration\$Name"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    $token = Get-IntegrationToken $Integration
    throw "$(Get-IntegrationDisplayName $Integration) integration is not installed. Run 'algomim install $token'."
  }
  return $path
}

function Get-InstalledIntegrations {
  $installed = @()
  foreach ($integration in $script:IntegrationIds) {
    $statePath = Join-Path $script:AlgomimHome "integrations\$integration\state.json"
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
      $installed += $integration
    }
  }
  return , $installed
}

function Invoke-InstallCommand {
  param([string] $Integration, [string[]] $Options)
  $profile = ""
  for ($index = 0; $index -lt $Options.Count; $index++) {
    if ($Options[$index] -ne "--profile") {
      Fail-Usage "Unknown install option: $($Options[$index])"
    }
    $profile = Get-OptionValue $Options ([ref] $index) "--profile"
  }
  $profile = Get-SelectedProfile $profile
  $state = Read-CliState
  $installer = Join-Path $script:AlgomimHome "cli\integrations\$Integration\install.ps1"
  if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "The bundled $(Get-IntegrationDisplayName $Integration) installer is missing. Re-run the versioned Algomim installer."
  }
  & $installer -AlgomimHome $script:AlgomimHome -CredentialProfile $profile -ReleaseRef ([string] $state.releaseTag) -ReleaseVersion ([string] $state.version) -SkipCliInstall
  & (Get-IntegrationLifecyclePath $Integration "doctor.ps1") -AlgomimHome $script:AlgomimHome -CredentialProfile $profile -SkipApiCheck -ThrowOnFailure
}

function Invoke-UpdateCommand {
  param([string] $Integration, [bool] $CheckOnly)
  $script = Get-IntegrationLifecyclePath $Integration "update.ps1"
  if ($CheckOnly) { & $script -AlgomimHome $script:AlgomimHome -CheckOnly }
  else { & $script -AlgomimHome $script:AlgomimHome }
}

function Invoke-DoctorCommand {
  param([string] $Integration, [bool] $Offline)
  $script = Get-IntegrationLifecyclePath $Integration "doctor.ps1"
  if ($Offline) { & $script -AlgomimHome $script:AlgomimHome -SkipApiCheck -ThrowOnFailure }
  else { & $script -AlgomimHome $script:AlgomimHome -ThrowOnFailure }
}

function Invoke-UninstallCommand {
  param([string] $Integration, [string[]] $Options)
  if ($Options.Count -gt 0) { Fail-Usage "uninstall does not accept options." }
  & (Get-IntegrationLifecyclePath $Integration "uninstall.ps1") -AlgomimHome $script:AlgomimHome
  Write-Host "[algomim] Algomim CLI and shared credentials were preserved."
}

function Get-RunCredential {
  param([string] $Profile)
  if (-not [string]::IsNullOrWhiteSpace($env:ALGOMIM_API_KEY)) {
    $token = $env:ALGOMIM_API_KEY.Trim()
    if ($token -match '[\x00-\x1F\x7F]') {
      throw "ALGOMIM_API_KEY contains control characters."
    }
    return $token
  }
  $token = Get-AlgomimCredentialApiKey -Path $script:CredentialsPath -Profile $Profile
  if ($null -eq $token) {
    throw "No Algomim credential is available for profile '$Profile'. Run 'algomim login'."
  }
  return $token
}

function Invoke-RunCommand {
  param([string] $Integration, [string[]] $Passthrough)
  if ($Integration -eq "codex") {
    [void] (Get-IntegrationLifecyclePath "codex" "state.json")
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
      throw "Codex CLI is not available on PATH. Install Codex first."
    }
    & codex --profile algomim @Passthrough
    exit $LASTEXITCODE
  }

  $statePath = Get-IntegrationLifecyclePath "claude-code" "state.json"
  $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  $settingsPath = Get-IntegrationLifecyclePath "claude-code" "settings.json"
  $claudeConfigDir = Join-Path (Split-Path -Parent $settingsPath) "config"
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    throw "Claude Code CLI is not available on PATH. Install Claude Code first."
  }
  if (Test-Path -LiteralPath $claudeConfigDir) {
    $configDirectory = Get-Item -LiteralPath $claudeConfigDir -Force
    if (-not $configDirectory.PSIsContainer -or ($configDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
      throw "Claude Code integration config path must be a real directory: $claudeConfigDir"
    }
  }
  else {
    New-Item -ItemType Directory -Path $claudeConfigDir | Out-Null
  }
  Protect-AlgomimCredentialDirectory $claudeConfigDir
  $profile = if ($env:ALGOMIM_PROFILE) { $env:ALGOMIM_PROFILE.Trim() } else { [string] $state.credentialProfile }
  if ([string]::IsNullOrWhiteSpace($profile)) { $profile = "default" }
  Assert-AlgomimCredentialProfileName $profile
  $token = Get-RunCredential $profile

  $savedAuthToken = $env:ANTHROPIC_AUTH_TOKEN
  $savedClaudeConfigDir = $env:CLAUDE_CONFIG_DIR
  try {
    $env:ANTHROPIC_AUTH_TOKEN = $token
    $env:CLAUDE_CONFIG_DIR = $claudeConfigDir
    & claude --settings $settingsPath @Passthrough
    $exitCode = $LASTEXITCODE
  }
  finally {
    if ($null -eq $savedAuthToken) { Remove-Item Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue } else { $env:ANTHROPIC_AUTH_TOKEN = $savedAuthToken }
    if ($null -eq $savedClaudeConfigDir) { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_CONFIG_DIR = $savedClaudeConfigDir }
  }
  exit $exitCode
}

function Split-IntegrationArguments {
  param([string[]] $Arguments, [string] $Verb, [bool] $IntegrationRequired)
  $integration = ""
  $options = @()
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    $argument = $Arguments[$index]
    if (-not $argument.StartsWith("-") -and [string]::IsNullOrEmpty($integration)) {
      $integration = Resolve-IntegrationName $argument
      continue
    }
    $options += $argument
  }
  if ($IntegrationRequired -and [string]::IsNullOrEmpty($integration)) {
    Fail-Usage "$Verb requires an integration: codex or claude."
  }
  return @{ Integration = $integration; Options = @($options) }
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

if ($CliArguments.Count -eq 0) {
  Write-Usage
  exit 0
}

try {
  $command = $CliArguments[0]
  $remaining = @($CliArguments | Select-Object -Skip 1)

  if ($command -eq "codex" -or $command -eq "claude") {
    # Legacy noun-first grammar (algomim codex install) rewrites silently to verb-first.
    if ($remaining.Count -eq 0) {
      Fail-Usage "An integration action is required: install, run, doctor, update, or uninstall."
    }
    $legacyNoun = $command
    $command = $remaining[0]
    $remaining = @($legacyNoun) + @($remaining | Select-Object -Skip 1)
  }

  switch ($command) {
    "login" { Invoke-Login $remaining }
    "logout" { Invoke-Logout $remaining }
    "version" {
      if ($remaining.Count -gt 0) { Fail-Usage "version does not accept options." }
      $state = Read-CliState
      Write-Output "Algomim CLI $($state.version) ($($state.releaseTag))"
      foreach ($integration in $script:IntegrationIds) {
        $integrationStatePath = Join-Path $script:AlgomimHome "integrations\$integration\state.json"
        if (Test-Path -LiteralPath $integrationStatePath -PathType Leaf) {
          $integrationState = Get-Content -Raw -LiteralPath $integrationStatePath | ConvertFrom-Json
          Write-Output "$(Get-IntegrationDisplayName $integration) integration $($integrationState.version)"
        }
      }
    }
    "help" {
      if ($remaining.Count -gt 0) { Fail-Usage "help does not accept options." }
      Write-Usage
    }
    "install" {
      $parsed = Split-IntegrationArguments $remaining "install" $true
      Invoke-InstallCommand $parsed.Integration $parsed.Options
    }
    "run" {
      if ($remaining.Count -eq 0 -or $remaining[0].StartsWith("-")) {
        Fail-Usage "run requires an integration: codex or claude."
      }
      $integration = Resolve-IntegrationName $remaining[0]
      $passthrough = @($remaining | Select-Object -Skip 1)
      if ($passthrough.Count -gt 0 -and $passthrough[0] -eq "--") {
        $passthrough = @($passthrough | Select-Object -Skip 1)
      }
      Invoke-RunCommand $integration $passthrough
    }
    "doctor" {
      $parsed = Split-IntegrationArguments $remaining "doctor" $false
      $offline = $false
      foreach ($option in $parsed.Options) {
        if ($option -ne "--offline") { Fail-Usage "Unknown doctor option: $option" }
        $offline = $true
      }
      if (-not [string]::IsNullOrEmpty($parsed.Integration)) {
        Invoke-DoctorCommand $parsed.Integration $offline
      }
      else {
        $installed = Get-InstalledIntegrations
        if ($installed.Count -eq 0) {
          throw "No Algomim integrations are installed. Run 'algomim install codex' or 'algomim install claude'."
        }
        $anyFailed = $false
        foreach ($integration in $installed) {
          Write-Host "[algomim] Doctor: $(Get-IntegrationDisplayName $integration)"
          try {
            Invoke-DoctorCommand $integration $offline
          }
          catch {
            [Console]::Error.WriteLine("[algomim] $($_.Exception.Message)")
            $anyFailed = $true
          }
        }
        if ($anyFailed) { exit 1 }
      }
    }
    "update" {
      $parsed = Split-IntegrationArguments $remaining "update" $false
      $check = $false
      foreach ($option in $parsed.Options) {
        if ($option -ne "--check") { Fail-Usage "Unknown update option: $option" }
        $check = $true
      }
      if (-not [string]::IsNullOrEmpty($parsed.Integration)) {
        Invoke-UpdateCommand $parsed.Integration $check
      }
      else {
        $installed = Get-InstalledIntegrations
        if ($installed.Count -eq 0) {
          throw "No Algomim integrations are installed. Run 'algomim install codex' or 'algomim install claude'."
        }
        foreach ($integration in $installed) {
          Write-Host "[algomim] Update: $(Get-IntegrationDisplayName $integration)"
          Invoke-UpdateCommand $integration $check
        }
      }
    }
    "uninstall" {
      $parsed = Split-IntegrationArguments $remaining "uninstall" $true
      Invoke-UninstallCommand $parsed.Integration $parsed.Options
    }
    default { Fail-Usage "Unknown command: $command" }
  }
}
catch {
  [Console]::Error.WriteLine("[algomim] $($_.Exception.Message)")
  exit 1
}
