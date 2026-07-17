param(
  [Parameter(Mandatory = $true)]
  [string] $Tag
)

$ErrorActionPreference = "Stop"

function Assert-True {
  param([bool] $Condition, [string] $Message)
  if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
  param([string] $Expected, [string] $Actual, [string] $Message)
  if ($Expected -cne $Actual) { throw "Assertion failed: $Message" }
}

if ($Tag -notmatch '^v(\d+\.\d+\.\d+)$') {
  throw "Tag must use vMAJOR.MINOR.PATCH format."
}
$version = $Matches[1]
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-claude-published-{0}" -f [Guid]::NewGuid().ToString("N"))
$algomimHome = Join-Path $testRoot "algomim-home"
$fakeBin = Join-Path $testRoot "bin"
$installerPath = Join-Path $testRoot "install.ps1"
$key = "sk-published-claude-000000"
$savedPath = $env:PATH
$savedAlgomimHome = $env:ALGOMIM_HOME
$savedApiKey = $env:ALGOMIM_API_KEY
$savedProfile = $env:ALGOMIM_PROFILE

try {
  New-Item -ItemType Directory -Path $testRoot, $fakeBin -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $fakeBin "claude.cmd") -Value "@echo off`r`necho 2.1.211`r`nexit /b 0" -Encoding ascii
  $env:PATH = "$fakeBin;$savedPath"
  $env:ALGOMIM_HOME = $algomimHome
  Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:ALGOMIM_PROFILE -ErrorAction SilentlyContinue

  $installerUrl = "https://raw.githubusercontent.com/algomim/release/$Tag/claude-code/install.ps1"
  Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
  $installOutput = (& $installerPath `
      -ApiKey $key `
      -ReleaseRef $Tag `
      -ReleaseVersion $version `
      -AlgomimHome $algomimHome `
      -CliPathTarget Process *>&1 | Out-String)

  $integrationHome = Join-Path $algomimHome "integrations\claude-code"
  $credentialsPath = Join-Path $algomimHome "credentials"
  $settingsPath = Join-Path $integrationHome "settings.json"
  Assert-True (Test-Path -LiteralPath $settingsPath -PathType Leaf) "install writes the session settings"
  Assert-True (-not $installOutput.Contains($key)) "install output does not expose the credential"
  $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
  Assert-Equal "algomim" ([string] $settings.model) "published install selects the algomim model"
  Assert-Equal "https://api.algomim.com" ([string] $settings.env.ANTHROPIC_BASE_URL) "published install records the service-root base URL"
  Assert-Equal "algomim" ([string] $settings.env.ANTHROPIC_MODEL) "published install selects algomim for the main session"
  Assert-Equal "algomim" ([string] $settings.env.ANTHROPIC_CUSTOM_MODEL_OPTION) "published install adds the Algomim custom model option"
  Assert-Equal "Algomim" ([string] $settings.env.ANTHROPIC_CUSTOM_MODEL_OPTION_NAME) "published install labels the custom model option"
  Assert-Equal "Algomim Model API" ([string] $settings.env.ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION) "published install describes the custom model option"
  Assert-Equal "algomim" ([string] $settings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL) "published install redirects background haiku traffic"
  Assert-Equal "algomim" ([string] $settings.env.CLAUDE_CODE_SUBAGENT_MODEL) "published install redirects subagents"
  Assert-Equal "1" ([string] $settings.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB) "published install scrubs the credential from child processes"
  Assert-True ($null -eq $settings.PSObject.Properties["availableModels"]) "published install does not add an availableModels allowlist"
  Assert-True ($null -eq $settings.PSObject.Properties["enforceAvailableModels"]) "published install does not enforce an availableModels allowlist"
  foreach ($familyPin in @("ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL")) {
    Assert-True ([string]::IsNullOrWhiteSpace([string] $settings.env.$familyPin)) "published install does not pin $familyPin"
  }
  $cliPath = Join-Path $algomimHome "bin\algomim.ps1"
  Assert-True (Test-Path -LiteralPath $cliPath -PathType Leaf) "install writes the Algomim CLI"

  $manifestPath = Join-Path $testRoot "manifest.json"
  Invoke-WebRequest -Uri "https://github.com/algomim/release/releases/download/$Tag/manifest.json" -OutFile $manifestPath -UseBasicParsing
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $claudeArtifact = $manifest.claudeCodeArtifacts.windows
  Assert-True ($null -ne $claudeArtifact -and $claudeArtifact.format -eq "zip") "manifest advertises the Windows Claude Code artifact"
  $claudeArchive = Join-Path $testRoot ([string] $claudeArtifact.file)
  Invoke-WebRequest -Uri "https://github.com/algomim/release/releases/download/$Tag/$($claudeArtifact.file)" -OutFile $claudeArchive -UseBasicParsing
  Assert-Equal ([string] $claudeArtifact.sha256) ((Get-FileHash -LiteralPath $claudeArchive -Algorithm SHA256).Hash.ToLowerInvariant()) "published Claude Code artifact matches its SHA-256"
  $claudeArchiveRoot = Join-Path $testRoot "claude-archive"
  Expand-Archive -LiteralPath $claudeArchive -DestinationPath $claudeArchiveRoot
  Assert-True (Test-Path -LiteralPath (Join-Path $claudeArchiveRoot "claude-code\install.ps1") -PathType Leaf) "published Claude Code artifact contains the installer"

  & (Join-Path $integrationHome "doctor.ps1") `
    -AlgomimHome $algomimHome `
    -CredentialProfile default `
    -SkipApiCheck `
    -ThrowOnFailure

  & $cliPath update claude --check

  $credentialHash = (Get-FileHash -LiteralPath $credentialsPath -Algorithm SHA256).Hash
  $updateOutput = (& (Join-Path $integrationHome "update.ps1") `
      -AlgomimHome $algomimHome `
      -Version $version `
      -Force *>&1 | Out-String)
  Assert-True ($updateOutput -match 'Verified .*SHA-256') "update verifies the published artifact"
  Assert-True (-not $updateOutput.Contains($key)) "update output does not expose the credential"
  Assert-True (
    (Get-FileHash -LiteralPath $credentialsPath -Algorithm SHA256).Hash -eq $credentialHash
  ) "update preserves the credential"

  & $cliPath doctor claude --offline

  & $cliPath uninstall claude *> $null
  Assert-True (-not (Test-Path -LiteralPath $integrationHome)) "normal uninstall removes the integration"
  Assert-True (Test-Path -LiteralPath $credentialsPath -PathType Leaf) "normal uninstall preserves credentials"
  Assert-True (Test-Path -LiteralPath $cliPath -PathType Leaf) "normal uninstall preserves the CLI"

  $reinstallOutput = (& $cliPath install claude --profile default *>&1 | Out-String)
  Assert-True (Test-Path -LiteralPath $settingsPath -PathType Leaf) "reinstall restores the session settings"
  Assert-True (-not $reinstallOutput.Contains($key)) "reinstall output does not expose the credential"

  & $cliPath uninstall claude *> $null
  & $cliPath logout --profile default --yes *> $null
  Assert-True (-not (Test-Path -LiteralPath $credentialsPath)) "explicit removal deletes the final credential profile"
  Assert-True (Test-Path -LiteralPath $cliPath -PathType Leaf) "logout preserves the CLI"

  Write-Host "[ok] Published $Tag Windows Claude Code lifecycle passed."
}
finally {
  $env:PATH = $savedPath
  if ($null -eq $savedAlgomimHome) { Remove-Item Env:ALGOMIM_HOME -ErrorAction SilentlyContinue } else { $env:ALGOMIM_HOME = $savedAlgomimHome }
  if ($null -eq $savedApiKey) { Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue } else { $env:ALGOMIM_API_KEY = $savedApiKey }
  if ($null -eq $savedProfile) { Remove-Item Env:ALGOMIM_PROFILE -ErrorAction SilentlyContinue } else { $env:ALGOMIM_PROFILE = $savedProfile }
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
