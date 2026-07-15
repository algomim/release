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
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-published-{0}" -f [Guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $testRoot "codex-home"
$algomimHome = Join-Path $testRoot "algomim-home"
$fakeBin = Join-Path $testRoot "bin"
$installerPath = Join-Path $testRoot "install.ps1"
$key = "sk-published-lifecycle-000000"
$savedPath = $env:PATH
$savedCodexHome = $env:CODEX_HOME
$savedAlgomimHome = $env:ALGOMIM_HOME
$savedApiKey = $env:ALGOMIM_API_KEY
$savedProfile = $env:ALGOMIM_PROFILE

try {
  New-Item -ItemType Directory -Path $testRoot, $fakeBin -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $fakeBin "codex.cmd") -Value "@echo off`r`nexit /b 0" -Encoding ascii
  $env:PATH = "$fakeBin;$savedPath"
  $env:CODEX_HOME = $codexHome
  $env:ALGOMIM_HOME = $algomimHome
  Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:ALGOMIM_PROFILE -ErrorAction SilentlyContinue

  $installerUrl = "https://raw.githubusercontent.com/algomim/release/$Tag/codex/install.ps1"
  Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
  $installOutput = (& $installerPath `
      -ApiKey $key `
      -ReleaseRef $Tag `
      -ReleaseVersion $version `
      -AlgomimHome $algomimHome `
      -CliPathTarget Process *>&1 | Out-String)

  $integrationHome = Join-Path $algomimHome "integrations\codex"
  $credentialsPath = Join-Path $algomimHome "credentials"
  $profilePath = Join-Path $codexHome "algomim.config.toml"
  $catalogPath = Join-Path $codexHome "algomim-models.json"
  Assert-True (Test-Path -LiteralPath $profilePath -PathType Leaf) "install writes the profile"
  Assert-True (Test-Path -LiteralPath $catalogPath -PathType Leaf) "install writes the catalog"
  Assert-True (-not $installOutput.Contains($key)) "install output does not expose the credential"
  $cliPath = Join-Path $algomimHome "bin\algomim.ps1"
  $cliStatePath = Join-Path $algomimHome "cli\state.json"
  Assert-True (Test-Path -LiteralPath $cliPath -PathType Leaf) "install writes the Algomim CLI"
  Assert-True (Test-Path -LiteralPath $cliStatePath -PathType Leaf) "install writes CLI state"
  $versionOutput = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath version 2>&1 | Out-String)
  Assert-True ($versionOutput.Contains("Algomim CLI $version ($Tag)")) "published CLI reports its immutable version"

  $manifestPath = Join-Path $testRoot "manifest.json"
  Invoke-WebRequest -Uri "https://github.com/algomim/release/releases/download/$Tag/manifest.json" -OutFile $manifestPath -UseBasicParsing
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  $cliArtifact = $manifest.cliArtifacts.windows
  Assert-True ($null -ne $cliArtifact -and $cliArtifact.format -eq "zip") "manifest advertises the Windows CLI artifact"
  $cliArchive = Join-Path $testRoot ([string] $cliArtifact.file)
  Invoke-WebRequest -Uri "https://github.com/algomim/release/releases/download/$Tag/$($cliArtifact.file)" -OutFile $cliArchive -UseBasicParsing
  Assert-Equal ([string] $cliArtifact.sha256) ((Get-FileHash -LiteralPath $cliArchive -Algorithm SHA256).Hash.ToLowerInvariant()) "published CLI artifact matches its SHA-256"
  $cliArchiveRoot = Join-Path $testRoot "cli-archive"
  Expand-Archive -LiteralPath $cliArchive -DestinationPath $cliArchiveRoot
  Assert-True (Test-Path -LiteralPath (Join-Path $cliArchiveRoot "cli\algomim.ps1") -PathType Leaf) "published CLI artifact contains the Windows implementation"
  Assert-True (Test-Path -LiteralPath (Join-Path $cliArchiveRoot "cli\algomim.cmd") -PathType Leaf) "published CLI artifact contains the Windows dispatcher"

  & (Join-Path $integrationHome "doctor.ps1") `
    -CodexHome $codexHome `
    -AlgomimHome $algomimHome `
    -CredentialProfile default `
    -SkipApiCheck `
    -ThrowOnFailure

  & $cliPath codex update --check

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

  & $cliPath codex doctor --offline

  & $cliPath codex uninstall *> $null
  Assert-True (-not (Test-Path -LiteralPath $profilePath)) "normal uninstall removes the profile"
  Assert-True (Test-Path -LiteralPath $credentialsPath -PathType Leaf) "normal uninstall preserves credentials"
  Assert-True (Test-Path -LiteralPath $cliPath -PathType Leaf) "normal uninstall preserves the CLI"

  $reinstallOutput = (& $cliPath codex install --profile default *>&1 | Out-String)
  Assert-True (Test-Path -LiteralPath $profilePath -PathType Leaf) "reinstall restores the profile"
  Assert-True (-not $reinstallOutput.Contains($key)) "reinstall output does not expose the credential"

  & $cliPath codex uninstall *> $null
  & $cliPath logout --profile default --yes *> $null
  Assert-True (-not (Test-Path -LiteralPath $credentialsPath)) "explicit removal deletes the final credential profile"
  Assert-True (Test-Path -LiteralPath $cliPath -PathType Leaf) "logout preserves the CLI"

  Write-Host "[ok] Published $Tag Windows lifecycle passed."
}
finally {
  $env:PATH = $savedPath
  if ($null -eq $savedCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $savedCodexHome }
  if ($null -eq $savedAlgomimHome) { Remove-Item Env:ALGOMIM_HOME -ErrorAction SilentlyContinue } else { $env:ALGOMIM_HOME = $savedAlgomimHome }
  if ($null -eq $savedApiKey) { Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue } else { $env:ALGOMIM_API_KEY = $savedApiKey }
  if ($null -eq $savedProfile) { Remove-Item Env:ALGOMIM_PROFILE -ErrorAction SilentlyContinue } else { $env:ALGOMIM_PROFILE = $savedProfile }
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
