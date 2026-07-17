$ErrorActionPreference = "Stop"

function Assert-True {
  param([bool] $Condition, [string] $Message)
  if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
  param([string] $Expected, [string] $Actual, [string] $Message)
  if ($Expected -cne $Actual) { throw "Assertion failed: $Message`nExpected: $Expected`nActual: $Actual" }
}

function Read-ProfileKey {
  param([string] $Path, [string] $Profile)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $section = ""
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^\[([^\[\]]+)\]$') { $section = $Matches[1].Trim(); continue }
    if ($section -eq $Profile -and $trimmed -match '^api_key\s*=\s*(.*)$') { return $Matches[1].Trim() }
  }
  return $null
}

function Invoke-CliLogin {
  param([string] $CliPath, [string] $Profile, [string] $Key)
  return ($Key | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CliPath login --profile $Profile --api-key-stdin 2>&1 | Out-String)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot "codex\install.ps1"
$testRoot = Join-Path $repoRoot (".cli-test-{0}" -f [Guid]::NewGuid().ToString("N"))
$savedCodexHome = $env:CODEX_HOME
$savedAlgomimHome = $env:ALGOMIM_HOME
$savedApiKey = $env:ALGOMIM_API_KEY
$savedProfile = $env:ALGOMIM_PROFILE
$savedPath = $env:PATH

try {
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $codexHome = Join-Path $testRoot "codex"
  $algomimHome = Join-Path $testRoot "algomim"
  $fakeBin = Join-Path $testRoot "bin"
  New-Item -ItemType Directory -Path $fakeBin | Out-Null
  Set-Content -LiteralPath (Join-Path $fakeBin "codex.cmd") -Value "@echo off`r`nexit /b 0" -Encoding ascii
  $env:CODEX_HOME = $codexHome
  $env:ALGOMIM_HOME = $algomimHome
  $env:PATH = "$fakeBin;$savedPath"
  Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:ALGOMIM_PROFILE -ErrorAction SilentlyContinue

  $defaultKey = "sk-cli-default-000000"
  $workKey = "sk-cli-work-000000"
  $rotatedKey = "sk-cli-rotated-000000"
  $installOutput = (& $installer -ApiKey $defaultKey -CredentialProfile default -CliPathTarget Process *>&1 | Out-String)
  Assert-True (-not $installOutput.Contains($defaultKey)) "installer output never exposes the API key"

  $cli = Join-Path $algomimHome "bin\algomim.ps1"
  $cmdShim = Join-Path $algomimHome "bin\algomim.cmd"
  $cliStatePath = Join-Path $algomimHome "cli\state.json"
  $credentialsPath = Join-Path $algomimHome "credentials"
  Assert-True (Test-Path -LiteralPath $cli -PathType Leaf) "installer writes the PowerShell CLI"
  Assert-True (Test-Path -LiteralPath $cmdShim -PathType Leaf) "installer writes the CMD shim"
  Assert-True (Test-Path -LiteralPath $cliStatePath -PathType Leaf) "installer writes CLI state"
  $cliState = Get-Content -Raw -LiteralPath $cliStatePath | ConvertFrom-Json
  Assert-Equal "0.3.6" ([string] $cliState.version) "CLI state records the release version"
  Assert-Equal "v0.3.6" ([string] $cliState.releaseTag) "CLI state records the immutable tag"
  Assert-True (-not (Get-Content -Raw -LiteralPath $cliStatePath).Contains($defaultKey)) "CLI state contains no credential"

  $binPath = (Join-Path $algomimHome "bin").TrimEnd('\')
  $pathMatches = @($env:PATH -split ';' | Where-Object { $_.Trim().TrimEnd('\') -ieq $binPath })
  Assert-Equal "1" ([string] $pathMatches.Count) "installer adds the CLI path once"
  $installedAt = [string] $cliState.installedAt
  & $installer -CredentialProfile default -CliPathTarget Process *> $null
  $pathMatches = @($env:PATH -split ';' | Where-Object { $_.Trim().TrimEnd('\') -ieq $binPath })
  Assert-Equal "1" ([string] $pathMatches.Count) "reinstall does not duplicate PATH"
  $reinstalledState = Get-Content -Raw -LiteralPath $cliStatePath | ConvertFrom-Json
  Assert-Equal $installedAt ([string] $reinstalledState.installedAt) "reinstall preserves the initial install time"

  $versionOutput = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli version 2>&1 | Out-String)
  Assert-True ($versionOutput.Contains("Algomim CLI 0.3.6 (v0.3.6)")) "version reports CLI version"
  $helpOutput = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli help 2>&1 | Out-String)
  Assert-True ($helpOutput.Contains("algomim doctor [codex|claude] [--offline]")) "help lists lifecycle commands"
  Assert-True ($helpOutput.Contains("algomim run <codex|claude>")) "help lists the run command"

  $loginOutput = Invoke-CliLogin -CliPath $cli -Profile work -Key $workKey
  Assert-Equal $workKey (Read-ProfileKey $credentialsPath "work") "login creates a named profile"
  Assert-True (-not $loginOutput.Contains($workKey)) "login output never exposes the API key"
  $rotationOutput = Invoke-CliLogin -CliPath $cli -Profile work -Key $rotatedKey
  Assert-Equal $rotatedKey (Read-ProfileKey $credentialsPath "work") "login rotates an existing profile"
  Assert-True (-not $rotationOutput.Contains($rotatedKey)) "rotation output never exposes the API key"
  & $cli logout --profile work --yes *> $null
  Assert-True ($null -eq (Read-ProfileKey $credentialsPath "work")) "logout removes only the selected profile"
  Assert-Equal $defaultKey (Read-ProfileKey $credentialsPath "default") "logout preserves unrelated profiles"

  & $cli doctor codex --offline *> $null
  $legacyDoctorOutput = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli codex doctor --offline 2>&1 | Out-String)
  Assert-Equal "0" ([string] $LASTEXITCODE) "legacy noun-first grammar still works"
  Assert-True (-not ($legacyDoctorOutput -imatch "deprecat")) "legacy grammar prints no deprecation notice"
  $integrationHome = Join-Path $algomimHome "integrations\codex"
  $updatePath = Join-Path $integrationHome "update.ps1"
  $updateBackup = Get-Content -Raw -LiteralPath $updatePath
  $markerPath = Join-Path $testRoot "update-marker.txt"
  $env:ALGOMIM_CLI_TEST_MARKER = $markerPath
  try {
    Set-Content -LiteralPath $updatePath -Encoding utf8 -Value @'
param([string] $AlgomimHome = "", [switch] $CheckOnly)
[System.IO.File]::WriteAllText($env:ALGOMIM_CLI_TEST_MARKER, "$AlgomimHome|$CheckOnly")
'@
    & $cli update codex --check
    Assert-Equal "$algomimHome|True" (Get-Content -Raw -LiteralPath $markerPath) "update --check delegates to the lifecycle updater"
    Remove-Item -LiteralPath $markerPath -Force
    & $cli update --check
    Assert-Equal "$algomimHome|True" (Get-Content -Raw -LiteralPath $markerPath) "bare update targets every installed integration"
  }
  finally {
    Set-Content -LiteralPath $updatePath -Encoding utf8 -Value $updateBackup
    Remove-Item Env:ALGOMIM_CLI_TEST_MARKER -ErrorAction SilentlyContinue
  }

  & $cli uninstall codex *> $null
  Assert-True (-not (Test-Path -LiteralPath $integrationHome)) "uninstall codex removes only the integration"
  Assert-True (Test-Path -LiteralPath $cli -PathType Leaf) "uninstall codex preserves the CLI"
  Assert-Equal $defaultKey (Read-ProfileKey $credentialsPath "default") "uninstall codex preserves credentials"
  & $cli install codex --profile default *> $null
  Assert-True (Test-Path -LiteralPath (Join-Path $integrationHome "state.json") -PathType Leaf) "install codex repairs a removed integration"

  $publicFiles = @(Get-ChildItem -LiteralPath $algomimHome -Recurse -File | Where-Object { $_.FullName -cne $credentialsPath })
  $publicText = ($publicFiles | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
  Assert-True (-not $publicText.Contains($defaultKey)) "non-credential files never contain the API key"

  $migrationRoot = Join-Path $testRoot "migration"
  $previousArchive = Join-Path $migrationRoot "v0.1.2.zip"
  $previousSource = Join-Path $migrationRoot "source"
  New-Item -ItemType Directory -Path $migrationRoot, $previousSource | Out-Null
  & git -C $repoRoot archive --format=zip "--output=$previousArchive" v0.1.2 codex
  if ($LASTEXITCODE -ne 0) { throw "Could not archive v0.1.2 for migration test." }
  Expand-Archive -LiteralPath $previousArchive -DestinationPath $previousSource
  $env:CODEX_HOME = Join-Path $migrationRoot "codex"
  $env:ALGOMIM_HOME = Join-Path $migrationRoot "algomim"
  & (Join-Path $previousSource "codex\install.ps1") -ApiKey $defaultKey -ReleaseVersion "0.1.2" -ReleaseRef "v0.1.2" *> $null
  $migrationCredentials = Join-Path $env:ALGOMIM_HOME "credentials"
  $credentialBefore = Get-Content -Raw -LiteralPath $migrationCredentials
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:ALGOMIM_HOME "bin\algomim.cmd"))) "v0.1.2 starts without the shell CLI"
  $migrationOutput = (& $installer -CredentialProfile default -CliPathTarget Process *>&1 | Out-String)
  Assert-Equal $credentialBefore (Get-Content -Raw -LiteralPath $migrationCredentials) "v0.1.2 migration preserves credential bytes"
  Assert-True (Test-Path -LiteralPath (Join-Path $env:ALGOMIM_HOME "bin\algomim.cmd") -PathType Leaf) "v0.2.0 migration installs the shell CLI"
  Assert-True (-not $migrationOutput.Contains($defaultKey)) "migration output never exposes the API key"

  Write-Host "[ok] PowerShell Algomim CLI tests passed."
}
finally {
  $env:PATH = $savedPath
  if ($null -eq $savedCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $savedCodexHome }
  if ($null -eq $savedAlgomimHome) { Remove-Item Env:ALGOMIM_HOME -ErrorAction SilentlyContinue } else { $env:ALGOMIM_HOME = $savedAlgomimHome }
  if ($null -eq $savedApiKey) { Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue } else { $env:ALGOMIM_API_KEY = $savedApiKey }
  if ($null -eq $savedProfile) { Remove-Item Env:ALGOMIM_PROFILE -ErrorAction SilentlyContinue } else { $env:ALGOMIM_PROFILE = $savedProfile }
  Remove-Item Env:ALGOMIM_CLI_TEST_MARKER -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
