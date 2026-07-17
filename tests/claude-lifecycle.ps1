$ErrorActionPreference = "Stop"

function Assert-True {
  param([bool] $Condition, [string] $Message)
  if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
  param([string] $Expected, [string] $Actual, [string] $Message)
  if ($Expected -cne $Actual) { throw "Assertion failed: $Message`nExpected: $Expected`nActual: $Actual" }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot "claude-code\install.ps1"
$testRoot = Join-Path $repoRoot (".claude-test-{0}" -f [Guid]::NewGuid().ToString("N"))
$savedAlgomimHome = $env:ALGOMIM_HOME
$savedApiKey = $env:ALGOMIM_API_KEY
$savedProfile = $env:ALGOMIM_PROFILE
$savedClaudeConfigDir = $env:CLAUDE_CONFIG_DIR
$savedStubCapture = $env:CLAUDE_STUB_CAPTURE
$savedPath = $env:PATH

try {
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $algomimHome = Join-Path $testRoot "algomim"
  $fakeBin = Join-Path $testRoot "bin"
  $claudeConfigDir = Join-Path $testRoot "claude-user"
  $capturePath = Join-Path $testRoot "claude-capture.txt"
  New-Item -ItemType Directory -Path $fakeBin | Out-Null
  Set-Content -LiteralPath (Join-Path $fakeBin "claude.cmd") -Encoding ascii -Value @"
@echo off
if "%~1"=="--version" echo 2.1.211
if "%~1"=="--version" exit /b 0
echo ARGS=%*> "%CLAUDE_STUB_CAPTURE%"
echo TOKEN=%ANTHROPIC_AUTH_TOKEN%>> "%CLAUDE_STUB_CAPTURE%"
exit /b 0
"@
  $env:ALGOMIM_HOME = $algomimHome
  $env:CLAUDE_CONFIG_DIR = $claudeConfigDir
  $env:PATH = "$fakeBin;$savedPath"
  Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:ALGOMIM_PROFILE -ErrorAction SilentlyContinue

  $key = "sk-claude-lifecycle-000000"
  $installOutput = (& $installer -ApiKey $key -CredentialProfile default -BaseUrl "https://pilot.example.com" -CliPathTarget Process *>&1 | Out-String)
  Assert-True (-not $installOutput.Contains($key)) "installer output never exposes the API key"

  $integrationHome = Join-Path $algomimHome "integrations\claude-code"
  $settingsPath = Join-Path $integrationHome "settings.json"
  $statePath = Join-Path $integrationHome "state.json"
  $credentialsPath = Join-Path $algomimHome "credentials"
  $cli = Join-Path $algomimHome "bin\algomim.ps1"
  Assert-True (Test-Path -LiteralPath $settingsPath -PathType Leaf) "installer writes the session settings"
  Assert-True (Test-Path -LiteralPath $statePath -PathType Leaf) "installer writes the integration state"
  Assert-True (Test-Path -LiteralPath $cli -PathType Leaf) "installer installs the Algomim CLI"

  $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
  Assert-Equal "algomim" ([string] $settings.model) "settings select the Algomim model"
  Assert-Equal "1" ([string] @($settings.availableModels).Count) "settings expose one named model"
  Assert-Equal "algomim" ([string] @($settings.availableModels)[0]) "settings allow only the Algomim model"
  Assert-Equal "https://pilot.example.com" ([string] $settings.env.ANTHROPIC_BASE_URL) "settings record the service-root base URL"
  Assert-Equal "algomim" ([string] $settings.env.ANTHROPIC_MODEL) "settings select the Algomim model for the main session"
  Assert-Equal "algomim" ([string] $settings.env.ANTHROPIC_CUSTOM_MODEL_OPTION) "settings add the Algomim custom model option"
  Assert-Equal "Algomim" ([string] $settings.env.ANTHROPIC_CUSTOM_MODEL_OPTION_NAME) "settings label the custom model option"
  Assert-Equal "Algomim Model API" ([string] $settings.env.ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION) "settings describe the custom model option"
  Assert-Equal "0" ([string] $settings.env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY) "settings disable gateway model discovery"
  Assert-Equal "algomim" ([string] $settings.env.CLAUDE_CODE_SUBAGENT_MODEL) "settings redirect subagents"
  Assert-Equal "1" ([string] $settings.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB) "settings scrub the credential from child processes"
  foreach ($familyPin in @("ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL")) {
    Assert-True ($null -eq $settings.env.PSObject.Properties[$familyPin]) "settings do not define $familyPin"
  }
  Assert-True (-not (Get-Content -Raw -LiteralPath $settingsPath).Contains($key)) "settings never contain the API key"

  $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  Assert-Equal "claude-code" ([string] $state.integration) "state records the integration id"
  Assert-Equal "0.3.4" ([string] $state.version) "state records the release version"
  Assert-Equal "https://pilot.example.com" ([string] $state.baseUrl) "state records the service-root base URL"

  Assert-True (-not (Test-Path -LiteralPath $claudeConfigDir)) "install never creates or touches the Claude Code config directory"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli doctor claude --offline *> $null
  Assert-Equal "0" ([string] $LASTEXITCODE) "doctor claude --offline passes after install"

  New-Item -ItemType Directory -Path $claudeConfigDir | Out-Null
  Set-Content -LiteralPath (Join-Path $claudeConfigDir "settings.json") -Encoding utf8 -Value '{"availableModels":["opus"],"env":{"ANTHROPIC_BASE_URL":"https://user.example.com"}}'
  $conflictOutput = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli doctor claude --offline 2>&1 | Out-String)
  Assert-True ($conflictOutput.Contains("can conflict")) "doctor warns about conflicting user settings"
  Assert-True ($conflictOutput.Contains("can expose additional models")) "doctor warns about a merged user model allowlist"
  Assert-Equal "0" ([string] $LASTEXITCODE) "conflicting user settings warn without failing"
  Remove-Item -LiteralPath $claudeConfigDir -Recurse -Force

  $env:CLAUDE_STUB_CAPTURE = $capturePath
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli run claude -- --version *> $null
  Assert-Equal "0" ([string] $LASTEXITCODE) "run claude exits with the client exit code"
  $capture = Get-Content -Raw -LiteralPath $capturePath
  Assert-True ($capture.Contains("--settings")) "run claude passes the settings file"
  Assert-True ($capture.Contains($settingsPath)) "run claude points at the installed settings"
  Assert-True ($capture.Contains("--version")) "run claude forwards passthrough arguments"
  Assert-True ($capture.Contains("TOKEN=$key")) "run claude injects the token into the process environment"
  $argsLine = ($capture -split "`r?`n" | Where-Object { $_.StartsWith("ARGS=") }) -join ""
  Assert-True (-not $argsLine.Contains($key)) "run claude never places the token on the command line"
  Assert-True (-not (Test-Path -LiteralPath $claudeConfigDir)) "run never creates the Claude Code config directory"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli uninstall claude *> $null
  Assert-True (-not (Test-Path -LiteralPath $integrationHome)) "uninstall claude removes only the integration"
  Assert-True (Test-Path -LiteralPath $cli -PathType Leaf) "uninstall claude preserves the CLI"
  Assert-True (Test-Path -LiteralPath $credentialsPath -PathType Leaf) "uninstall claude preserves credentials"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli install claude --profile default *> $null
  Assert-True (Test-Path -LiteralPath $statePath -PathType Leaf) "install claude repairs a removed integration"

  $publicFiles = @(Get-ChildItem -LiteralPath $algomimHome -Recurse -File | Where-Object { $_.FullName -cne $credentialsPath })
  $publicText = ($publicFiles | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
  Assert-True (-not $publicText.Contains($key)) "non-credential files never contain the API key"

  Write-Host "[ok] PowerShell Claude Code lifecycle tests passed."
}
finally {
  $env:PATH = $savedPath
  if ($null -eq $savedAlgomimHome) { Remove-Item Env:ALGOMIM_HOME -ErrorAction SilentlyContinue } else { $env:ALGOMIM_HOME = $savedAlgomimHome }
  if ($null -eq $savedApiKey) { Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue } else { $env:ALGOMIM_API_KEY = $savedApiKey }
  if ($null -eq $savedProfile) { Remove-Item Env:ALGOMIM_PROFILE -ErrorAction SilentlyContinue } else { $env:ALGOMIM_PROFILE = $savedProfile }
  if ($null -eq $savedClaudeConfigDir) { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_CONFIG_DIR = $savedClaudeConfigDir }
  if ($null -eq $savedStubCapture) { Remove-Item Env:CLAUDE_STUB_CAPTURE -ErrorAction SilentlyContinue } else { $env:CLAUDE_STUB_CAPTURE = $savedStubCapture }
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
