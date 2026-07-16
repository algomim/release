$ErrorActionPreference = "Stop"

function Assert-True {
  param([bool] $Condition, [string] $Message)
  if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
  param([string] $Expected, [string] $Actual, [string] $Message)
  if ($Expected -cne $Actual) { throw "Assertion failed: $Message" }
}

function Write-JsonFile {
  param([string] $Path, [object] $Value)
  $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8WithoutBom)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseContract = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "claude-code\release.json") | ConvertFrom-Json
$currentVersion = [string] $releaseContract.version
$currentTag = [string] $releaseContract.releaseTag
$invalidVersion = if ($currentVersion -ceq "9999.9999.9999") { "9999.9999.9998" } else { "9999.9999.9999" }
$invalidTag = "v$invalidVersion"

$testRoot = Join-Path $repoRoot (".claude-update-test-{0}" -f [Guid]::NewGuid().ToString("N"))
$artifacts = Join-Path $testRoot "artifacts"
$algomimHome = Join-Path $testRoot "algomim"
$key = "test-claude-update-key-000000"

$savedAlgomimHome = $env:ALGOMIM_HOME
$savedApiKey = $env:ALGOMIM_API_KEY

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  $env:ALGOMIM_HOME = $algomimHome
  Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue

  & (Join-Path $repoRoot "tools\build-release.ps1") -Version $currentTag -OutputDirectory $artifacts *> $null

  & (Join-Path $repoRoot "claude-code\install.ps1") `
    -ApiKey $key `
    -ReleaseVersion $currentVersion `
    -ReleaseRef $currentTag `
    -SkipCliInstall *> $null

  $integrationHome = Join-Path $algomimHome "integrations\claude-code"
  $statePath = Join-Path $integrationHome "state.json"
  $settingsPath = Join-Path $integrationHome "settings.json"
  $credentialsPath = Join-Path $algomimHome "credentials"

  $upToDateOutput = (& (Join-Path $integrationHome "update.ps1") `
      -ManifestUrl (Join-Path $artifacts "manifest.json") `
      -ArtifactBaseUrl $artifacts *>&1 | Out-String)
  Assert-True ($upToDateOutput.Contains("already up to date")) "same-version update reports up to date"
  Assert-Equal $currentVersion ([string] (Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json).version) "same-version update leaves state unchanged"

  $settingsHashBefore = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
  $stateBeforeRollback = Get-Content -Raw -LiteralPath $statePath
  $credentialBeforeRollback = Get-Content -Raw -LiteralPath $credentialsPath

  $badStage = Join-Path $testRoot "bad-stage"
  Expand-Archive -LiteralPath (Join-Path $artifacts "algomim-claude-code-windows-$currentTag.zip") -DestinationPath $badStage
  $badContractPath = Join-Path $badStage "claude-code\release.json"
  $badContract = Get-Content -Raw -LiteralPath $badContractPath | ConvertFrom-Json
  $badContract.version = $invalidVersion
  $badContract.releaseTag = $invalidTag
  Write-JsonFile -Path $badContractPath -Value $badContract
  Set-Content -LiteralPath (Join-Path $badStage "claude-code\doctor.ps1") -Encoding utf8 -Value 'throw "staged doctor failure"'

  $badArtifactName = "algomim-claude-code-windows-$invalidTag.zip"
  $badArtifactPath = Join-Path $artifacts $badArtifactName
  Compress-Archive -Path @(
    (Join-Path $badStage "claude-code"),
    (Join-Path $badStage "shared")
  ) -DestinationPath $badArtifactPath
  $badHash = (Get-FileHash -LiteralPath $badArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $badManifest = [ordered] @{
    schemaVersion = 1
    integration = "codex"
    version = $invalidVersion
    releaseTag = $invalidTag
    channel = "pilot"
    claudeCodeArtifacts = [ordered] @{
      windows = [ordered] @{ file = $badArtifactName; format = "zip"; sha256 = $badHash }
    }
  }
  $badManifestPath = Join-Path $artifacts "bad-manifest.json"
  Write-JsonFile -Path $badManifestPath -Value $badManifest

  $rolledBack = $false
  try {
    & (Join-Path $integrationHome "update.ps1") `
      -ManifestUrl $badManifestPath `
      -ArtifactBaseUrl $artifacts *> $null
  }
  catch {
    $rolledBack = $_.Exception.Message -match 'rolled back'
  }
  Assert-True $rolledBack "failed staged doctor triggers rollback"
  Assert-Equal $stateBeforeRollback (Get-Content -Raw -LiteralPath $statePath) "rollback restores exact state"
  Assert-Equal $settingsHashBefore (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash "rollback restores the session settings"
  Assert-Equal $credentialBeforeRollback (Get-Content -Raw -LiteralPath $credentialsPath) "rollback never changes credential"
  Assert-True (Test-Path -LiteralPath (Join-Path $integrationHome "update.ps1")) "rollback restores lifecycle files"

  $checksumManifest = Get-Content -Raw -LiteralPath $badManifestPath | ConvertFrom-Json
  $checksumManifest.claudeCodeArtifacts.windows.sha256 = "0" * 64
  $checksumManifestPath = Join-Path $artifacts "checksum-manifest.json"
  Write-JsonFile -Path $checksumManifestPath -Value $checksumManifest
  $checksumRejected = $false
  try {
    & (Join-Path $integrationHome "update.ps1") `
      -ManifestUrl $checksumManifestPath `
      -ArtifactBaseUrl $artifacts *> $null
  }
  catch {
    $checksumRejected = $_.Exception.Message -match 'checksum verification failed'
  }
  Assert-True $checksumRejected "checksum mismatch is rejected before installation"
  Assert-Equal $stateBeforeRollback (Get-Content -Raw -LiteralPath $statePath) "checksum rejection leaves state unchanged"

  Write-Host "[ok] PowerShell Claude Code update and rollback tests passed."
}
finally {
  if ($null -eq $savedAlgomimHome) { Remove-Item Env:ALGOMIM_HOME -ErrorAction SilentlyContinue } else { $env:ALGOMIM_HOME = $savedAlgomimHome }
  if ($null -eq $savedApiKey) { Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue } else { $env:ALGOMIM_API_KEY = $savedApiKey }
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}
