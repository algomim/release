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
$baselineVersion = "0.3.1"
$baselineTag = "v$baselineVersion"
$candidateVersion = "0.3.2"
$candidateTag = "v$candidateVersion"
$invalidVersion = if ($candidateVersion -ceq "9999.9999.9999") { "9999.9999.9998" } else { "9999.9999.9999" }
$invalidTag = "v$invalidVersion"

$testRoot = Join-Path $repoRoot (".claude-update-test-{0}" -f [Guid]::NewGuid().ToString("N"))
$artifacts = Join-Path $testRoot "artifacts"
$baselineArchive = Join-Path $testRoot "claude-v0.3.1.zip"
$baselineSource = Join-Path $testRoot "baseline"
$candidateStage = Join-Path $testRoot "candidate"
$algomimHome = Join-Path $testRoot "algomim"
$key = "test-claude-update-key-000000"

$savedAlgomimHome = $env:ALGOMIM_HOME
$savedApiKey = $env:ALGOMIM_API_KEY

try {
  New-Item -ItemType Directory -Path $testRoot, $artifacts, $candidateStage -Force | Out-Null
  $env:ALGOMIM_HOME = $algomimHome
  Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue

  & git -C $repoRoot archive --format=zip "--output=$baselineArchive" $baselineTag claude-code shared
  if ($LASTEXITCODE -ne 0) {
    throw "Could not archive immutable Claude Code baseline $baselineTag."
  }
  Expand-Archive -LiteralPath $baselineArchive -DestinationPath $baselineSource
  $baselineContract = Get-Content -Raw -LiteralPath (Join-Path $baselineSource "claude-code\release.json") | ConvertFrom-Json
  Assert-Equal $baselineVersion ([string] $baselineContract.version) "baseline contract records v0.3.1"
  Assert-Equal $baselineTag ([string] $baselineContract.releaseTag) "baseline contract matches the immutable tag"

  & (Join-Path $baselineSource "claude-code\install.ps1") `
    -ApiKey $key `
    -ReleaseVersion $baselineVersion `
    -ReleaseRef $baselineTag `
    -SkipCliInstall *> $null

  $integrationHome = Join-Path $algomimHome "integrations\claude-code"
  $statePath = Join-Path $integrationHome "state.json"
  $settingsPath = Join-Path $integrationHome "settings.json"
  $credentialsPath = Join-Path $algomimHome "credentials"

  $baselineState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  $baselineCredential = Get-Content -Raw -LiteralPath $credentialsPath
  Assert-Equal $baselineVersion ([string] $baselineState.version) "test starts from immutable v0.3.1"
  Assert-Equal $baselineTag ([string] $baselineState.releaseTag) "baseline state records the immutable tag"
  Assert-Equal "https://api.algomim.com" ([string] $baselineState.baseUrl) "baseline records the service-root base URL"

  Copy-Item -LiteralPath (Join-Path $repoRoot "claude-code") -Destination (Join-Path $candidateStage "claude-code") -Recurse
  Copy-Item -LiteralPath (Join-Path $repoRoot "shared") -Destination (Join-Path $candidateStage "shared") -Recurse
  $candidateContractPath = Join-Path $candidateStage "claude-code\release.json"
  $candidateContract = Get-Content -Raw -LiteralPath $candidateContractPath | ConvertFrom-Json
  $candidateContract.version = $candidateVersion
  $candidateContract.releaseTag = $candidateTag
  Write-JsonFile -Path $candidateContractPath -Value $candidateContract

  $candidateArtifactName = "algomim-claude-code-windows-$candidateTag.zip"
  $candidateArtifactPath = Join-Path $artifacts $candidateArtifactName
  Compress-Archive -Path @(
    (Join-Path $candidateStage "claude-code"),
    (Join-Path $candidateStage "shared")
  ) -DestinationPath $candidateArtifactPath
  $candidateHash = (Get-FileHash -LiteralPath $candidateArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $candidateManifest = [ordered] @{
    schemaVersion = 1
    integration = "codex"
    version = $candidateVersion
    releaseTag = $candidateTag
    channel = "pilot"
    claudeCodeArtifacts = [ordered] @{
      windows = [ordered] @{ file = $candidateArtifactName; format = "zip"; sha256 = $candidateHash }
    }
  }
  $candidateManifestPath = Join-Path $artifacts "manifest.json"
  Write-JsonFile -Path $candidateManifestPath -Value $candidateManifest

  $updateOutput = (& (Join-Path $integrationHome "update.ps1") `
      -ManifestUrl $candidateManifestPath `
      -ArtifactBaseUrl $artifacts *>&1 | Out-String)
  $updatedState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  $updatedSettings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
  Assert-Equal $candidateVersion ([string] $updatedState.version) "v0.3.1 updater installs candidate v0.3.2"
  Assert-Equal $candidateTag ([string] $updatedState.releaseTag) "updated state records the candidate tag"
  Assert-Equal ([string] $baselineState.installedAt) ([string] $updatedState.installedAt) "update preserves installation timestamp"
  Assert-Equal $baselineCredential (Get-Content -Raw -LiteralPath $credentialsPath) "update preserves the exact credential store"
  Assert-True (-not $updateOutput.Contains($key)) "update output never exposes the credential"
  Assert-Equal "algomim" ([string] $updatedSettings.model) "updated settings select the algomim model"
  Assert-Equal "https://api.algomim.com" ([string] $updatedSettings.env.ANTHROPIC_BASE_URL) "updated settings preserve the service-root base URL"
  Assert-Equal "algomim" ([string] $updatedSettings.env.ANTHROPIC_MODEL) "updated settings select algomim for the main session"
  Assert-Equal "algomim" ([string] $updatedSettings.env.ANTHROPIC_CUSTOM_MODEL_OPTION) "updated settings add the Algomim custom model option"
  Assert-Equal "Algomim" ([string] $updatedSettings.env.ANTHROPIC_CUSTOM_MODEL_OPTION_NAME) "updated settings label the custom model option"
  Assert-Equal "Algomim Model API" ([string] $updatedSettings.env.ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION) "updated settings describe the custom model option"
  Assert-Equal "algomim" ([string] $updatedSettings.env.CLAUDE_CODE_SUBAGENT_MODEL) "updated settings redirect subagents"
  Assert-Equal "1" ([string] $updatedSettings.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB) "updated settings scrub the credential from child processes"
  Assert-True ($null -eq $updatedSettings.PSObject.Properties["availableModels"]) "updated settings do not add an availableModels allowlist"
  Assert-True ($null -eq $updatedSettings.PSObject.Properties["enforceAvailableModels"]) "updated settings do not enforce an availableModels allowlist"
  foreach ($familyPin in @("ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL")) {
    Assert-True ($null -eq $updatedSettings.env.PSObject.Properties[$familyPin]) "updated settings do not define $familyPin"
  }

  $upToDateOutput = (& (Join-Path $integrationHome "update.ps1") `
      -ManifestUrl $candidateManifestPath `
      -ArtifactBaseUrl $artifacts *>&1 | Out-String)
  Assert-True ($upToDateOutput.Contains("already up to date")) "same-version candidate update reports up to date"
  Assert-Equal $candidateVersion ([string] (Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json).version) "same-version candidate update leaves state unchanged"

  $settingsHashBefore = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
  $stateBeforeRollback = Get-Content -Raw -LiteralPath $statePath
  $credentialBeforeRollback = Get-Content -Raw -LiteralPath $credentialsPath

  $badStage = Join-Path $testRoot "bad-stage"
  Expand-Archive -LiteralPath $candidateArtifactPath -DestinationPath $badStage
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
