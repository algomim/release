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
$testRoot = Join-Path $repoRoot (".update-test-{0}" -f [Guid]::NewGuid().ToString("N"))
$artifacts = Join-Path $testRoot "artifacts"
$codexHome = Join-Path $testRoot "codex"
$algomimHome = Join-Path $testRoot "algomim"
$fakeBin = Join-Path $testRoot "bin"
$key = "test-update-key-000000"

$savedCodexHome = $env:CODEX_HOME
$savedAlgomimHome = $env:ALGOMIM_HOME
$savedApiKey = $env:ALGOMIM_API_KEY
$savedPath = $env:PATH

try {
  New-Item -ItemType Directory -Path $testRoot, $fakeBin -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $fakeBin "codex.cmd") -Value "@echo off`r`nexit /b 0" -Encoding ascii
  $env:PATH = "$fakeBin;$savedPath"
  $env:CODEX_HOME = $codexHome
  $env:ALGOMIM_HOME = $algomimHome
  Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue

  & (Join-Path $repoRoot "tools\build-release.ps1") -Version v0.1.0 -OutputDirectory $artifacts *> $null
  & (Join-Path $repoRoot "codex\install.ps1") `
    -ApiKey $key `
    -ReleaseVersion 0.0.9 `
    -ReleaseRef v0.0.9 *> $null

  $statePath = Join-Path $algomimHome "integrations\codex\state.json"
  $credentialsPath = Join-Path $algomimHome "credentials"
  $initialState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  $updateOutput = (& (Join-Path $repoRoot "codex\update.ps1") `
      -ManifestUrl (Join-Path $artifacts "manifest.json") `
      -ArtifactBaseUrl $artifacts *>&1 | Out-String)

  $updatedState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  Assert-Equal "0.1.0" ([string] $updatedState.version) "verified release updates state"
  Assert-Equal ([string] $initialState.installedAt) ([string] $updatedState.installedAt) "update preserves installation timestamp"
  Assert-True ((Get-Content -Raw -LiteralPath $credentialsPath).Contains($key)) "update preserves shared credential"
  Assert-True (-not $updateOutput.Contains($key)) "update output never contains the credential"

  $profilePath = Join-Path $codexHome "algomim.config.toml"
  $profileHashBeforeRollback = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
  $stateBeforeRollback = Get-Content -Raw -LiteralPath $statePath
  $credentialBeforeRollback = Get-Content -Raw -LiteralPath $credentialsPath

  $badStage = Join-Path $testRoot "bad-stage"
  Expand-Archive -LiteralPath (Join-Path $artifacts "algomim-codex-windows-v0.1.0.zip") -DestinationPath $badStage
  $badContractPath = Join-Path $badStage "codex\release.json"
  $badContract = Get-Content -Raw -LiteralPath $badContractPath | ConvertFrom-Json
  $badContract.version = "0.2.0"
  $badContract.releaseTag = "v0.2.0"
  Write-JsonFile -Path $badContractPath -Value $badContract
  Write-JsonFile -Path (Join-Path $badStage "codex\algomim-models.json") -Value ([ordered] @{ models = @() })

  $badArtifactName = "algomim-codex-windows-v0.2.0.zip"
  $badArtifactPath = Join-Path $artifacts $badArtifactName
  Compress-Archive -Path (Join-Path $badStage "codex") -DestinationPath $badArtifactPath
  $badHash = (Get-FileHash -LiteralPath $badArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $badManifest = [ordered] @{
    schemaVersion = 1
    integration = "codex"
    version = "0.2.0"
    releaseTag = "v0.2.0"
    channel = "pilot"
    artifacts = [ordered] @{
      windows = [ordered] @{ file = $badArtifactName; format = "zip"; sha256 = $badHash }
    }
  }
  $badManifestPath = Join-Path $artifacts "bad-manifest.json"
  Write-JsonFile -Path $badManifestPath -Value $badManifest

  $rolledBack = $false
  try {
    & (Join-Path $algomimHome "integrations\codex\update.ps1") `
      -ManifestUrl $badManifestPath `
      -ArtifactBaseUrl $artifacts *> $null
  }
  catch {
    $rolledBack = $_.Exception.Message -match 'rolled back'
  }
  Assert-True $rolledBack "failed post-install doctor triggers rollback"
  Assert-Equal $stateBeforeRollback (Get-Content -Raw -LiteralPath $statePath) "rollback restores exact state"
  Assert-Equal $profileHashBeforeRollback (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash "rollback restores Codex profile"
  Assert-Equal $credentialBeforeRollback (Get-Content -Raw -LiteralPath $credentialsPath) "rollback never changes credential"
  Assert-True (Test-Path -LiteralPath (Join-Path $algomimHome "integrations\codex\update.ps1")) "rollback restores lifecycle files"

  $checksumManifest = Get-Content -Raw -LiteralPath $badManifestPath | ConvertFrom-Json
  $checksumManifest.artifacts.windows.sha256 = "0" * 64
  $checksumManifestPath = Join-Path $artifacts "checksum-manifest.json"
  Write-JsonFile -Path $checksumManifestPath -Value $checksumManifest
  $checksumRejected = $false
  try {
    & (Join-Path $algomimHome "integrations\codex\update.ps1") `
      -ManifestUrl $checksumManifestPath `
      -ArtifactBaseUrl $artifacts *> $null
  }
  catch {
    $checksumRejected = $_.Exception.Message -match 'checksum verification failed'
  }
  Assert-True $checksumRejected "checksum mismatch is rejected before installation"
  Assert-Equal $stateBeforeRollback (Get-Content -Raw -LiteralPath $statePath) "checksum rejection leaves state unchanged"

  Write-Host "[ok] PowerShell update and rollback tests passed."
}
finally {
  if ($null -eq $savedCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $savedCodexHome }
  if ($null -eq $savedAlgomimHome) { Remove-Item Env:ALGOMIM_HOME -ErrorAction SilentlyContinue } else { $env:ALGOMIM_HOME = $savedAlgomimHome }
  if ($null -eq $savedApiKey) { Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue } else { $env:ALGOMIM_API_KEY = $savedApiKey }
  $env:PATH = $savedPath
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}
