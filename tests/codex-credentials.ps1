$ErrorActionPreference = "Stop"

function Assert-True {
  param(
    [bool] $Condition,
    [string] $Message
  )

  if (-not $Condition) {
    throw "Assertion failed: $Message"
  }
}

function Assert-Equal {
  param(
    [string] $Expected,
    [string] $Actual,
    [string] $Message
  )

  if ($Expected -cne $Actual) {
    throw "Assertion failed: $Message"
  }
}

function Read-ProfileKey {
  param(
    [string] $Path,
    [string] $Profile
  )

  $section = ""
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^\[([^\[\]]+)\]$') {
      $section = $Matches[1].Trim()
      continue
    }
    if ($section -eq $Profile -and $trimmed -match '^api_key\s*=\s*(.*)$') {
      return $Matches[1].Trim()
    }
  }
  return $null
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$install = Join-Path $repoRoot "codex\install.ps1"
$uninstall = Join-Path $repoRoot "codex\uninstall.ps1"
. (Join-Path $repoRoot "shared\credential-store.ps1")
$testRoot = Join-Path $repoRoot (".credential-test-{0}" -f [Guid]::NewGuid().ToString("N"))
$defaultKey = "test-key-default-000000"
$workKey = "test-key-work-000000"
$overrideKey = "test-key-override-000000"
$legacyKey = "test-key-legacy-000000"

$savedCodexHome = $env:CODEX_HOME
$savedAlgomimHome = $env:ALGOMIM_HOME
$savedApiKey = $env:ALGOMIM_API_KEY
$savedProfile = $env:ALGOMIM_PROFILE

try {
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $rejectedMultilineKey = $false
  try {
    Normalize-AlgomimApiKey "sk-safe`n[injected]`napi_key = sk-injected" | Out-Null
  }
  catch {
    $rejectedMultilineKey = $true
  }
  Assert-True $rejectedMultilineKey "credential normalization rejects embedded newlines"

  $codexHome = Join-Path $testRoot "codex"
  $algomimHome = Join-Path $testRoot "algomim"
  $env:CODEX_HOME = $codexHome
  $env:ALGOMIM_HOME = $algomimHome
  Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:ALGOMIM_PROFILE -ErrorAction SilentlyContinue

  $installOutput = (& $install -ApiKey $defaultKey -CredentialProfile default -CliPathTarget Process *>&1 | Out-String)
  $credentialsPath = Join-Path $algomimHome "credentials"
  Assert-True (Test-Path -LiteralPath $credentialsPath -PathType Leaf) "fresh install creates shared credentials"
  Assert-Equal $defaultKey (Read-ProfileKey $credentialsPath "default") "default profile is written"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexHome "algomim.key"))) "fresh install does not create a Codex-owned key"
  Assert-True (-not $installOutput.Contains($defaultKey)) "install output never contains the credential"
  $installedProfile = Get-Content -Raw -LiteralPath (Join-Path $codexHome "algomim.config.toml")
  $featuresSection = [regex]::Match(
    $installedProfile,
    '(?ms)^\[features\][^\S\r\n]*\r?\n(?<body>.*?)(?=^\[|\z)'
  )
  Assert-True (
    $featuresSection.Success -and
    $featuresSection.Groups["body"].Value -match '(?m)^personality\s*=\s*false\s*$'
  ) "installed profile disables unsupported personality injection"
  $codexArtifacts = (Get-ChildItem -LiteralPath $codexHome -File | ForEach-Object {
      Get-Content -Raw -LiteralPath $_.FullName
    }) -join "`n"
  Assert-True (-not $codexArtifacts.Contains($defaultKey)) "Codex artifacts never embed the credential"
  $statePath = Join-Path $algomimHome "integrations\codex\state.json"
  $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  Assert-Equal "0.2.0" ([string] $state.version) "installer records its release version"
  Assert-Equal "default" ([string] $state.credentialProfile) "installer records the selected credential profile"
  Assert-True (-not (Get-Content -Raw -LiteralPath $statePath).Contains($defaultKey)) "installation state never contains the credential"
  foreach ($name in @("install.ps1", "update.ps1", "doctor.ps1", "uninstall.ps1", "release.json", "credential-store.ps1")) {
    Assert-True (Test-Path -LiteralPath (Join-Path $algomimHome "integrations\codex\$name")) "installer writes lifecycle file $name"
  }

  $acl = Get-Acl -LiteralPath $credentialsPath
  Assert-True $acl.AreAccessRulesProtected "credential file disables inherited ACL entries"
  $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $unexpectedReaders = @($acl.Access | Where-Object {
      $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
      $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -ne $currentUserSid
    })
  Assert-True ($unexpectedReaders.Count -eq 0) "only the current user has an allow rule"

  $authScript = Join-Path $codexHome "algomim-auth.ps1"
  Assert-Equal $defaultKey ((& $authScript | Out-String).Trim()) "auth helper resolves the stored default profile"
  $env:ALGOMIM_API_KEY = $overrideKey
  Assert-Equal $overrideKey ((& $authScript | Out-String).Trim()) "environment key overrides the credential file"
  Remove-Item Env:ALGOMIM_API_KEY

  $rerunOutput = (& $install -CredentialProfile default -CliPathTarget Process *>&1 | Out-String)
  Assert-Equal $defaultKey (Read-ProfileKey $credentialsPath "default") "idempotent install preserves the existing key"
  Assert-True (-not $rerunOutput.Contains($defaultKey)) "idempotent install does not print the key"

  & $install -ApiKey $workKey -CredentialProfile work -CliPathTarget Process *> $null
  Assert-Equal $defaultKey (Read-ProfileKey $credentialsPath "default") "adding a profile preserves default"
  Assert-Equal $workKey (Read-ProfileKey $credentialsPath "work") "named profile is written"
  $env:ALGOMIM_PROFILE = "default"
  Assert-Equal $defaultKey ((& $authScript | Out-String).Trim()) "ALGOMIM_PROFILE selects another stored profile"
  Remove-Item Env:ALGOMIM_PROFILE

  & $uninstall -CodexHome $codexHome -AlgomimHome $algomimHome -CredentialProfile default *> $null
  Assert-True (Test-Path -LiteralPath $credentialsPath) "uninstall preserves shared credentials by default"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexHome "algomim.config.toml"))) "uninstall removes the Codex profile"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $algomimHome "integrations\codex"))) "uninstall removes lifecycle state"

  & $uninstall -CodexHome $codexHome -AlgomimHome $algomimHome -CredentialProfile default -RemoveCredential *> $null
  Assert-True ($null -eq (Read-ProfileKey $credentialsPath "default")) "explicit removal deletes only the selected profile"
  Assert-Equal $workKey (Read-ProfileKey $credentialsPath "work") "explicit removal preserves other profiles"

  $legacyRoot = Join-Path $testRoot "legacy"
  $legacyCodexHome = Join-Path $legacyRoot "codex"
  $legacyAlgomimHome = Join-Path $legacyRoot "algomim"
  New-Item -ItemType Directory -Force -Path $legacyCodexHome | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $legacyCodexHome "algomim.key"), $legacyKey)
  $env:CODEX_HOME = $legacyCodexHome
  $env:ALGOMIM_HOME = $legacyAlgomimHome

  $migrationOutput = (& $install -CredentialProfile default -CliPathTarget Process *>&1 | Out-String)
  $legacyCredentials = Join-Path $legacyAlgomimHome "credentials"
  Assert-Equal $legacyKey (Read-ProfileKey $legacyCredentials "default") "legacy key migrates to shared credentials"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $legacyCodexHome "algomim.key"))) "legacy key is removed after verified migration"
  Assert-True (-not $migrationOutput.Contains($legacyKey)) "migration output never contains the credential"

  $environmentRoot = Join-Path $testRoot "environment-only"
  $environmentCodexHome = Join-Path $environmentRoot "codex"
  $environmentAlgomimHome = Join-Path $environmentRoot "algomim"
  $env:CODEX_HOME = $environmentCodexHome
  $env:ALGOMIM_HOME = $environmentAlgomimHome
  $env:ALGOMIM_API_KEY = $overrideKey
  $environmentOutput = (& $install -CredentialProfile default -CliPathTarget Process *>&1 | Out-String)
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $environmentAlgomimHome "credentials"))) "environment override is not persisted"
  Assert-Equal $overrideKey ((& (Join-Path $environmentCodexHome "algomim-auth.ps1") | Out-String).Trim()) "environment-only auth resolves"
  Assert-True (-not $environmentOutput.Contains($overrideKey)) "environment credential is not printed"
  Assert-True (-not (Get-Content -Raw -LiteralPath (Join-Path $environmentAlgomimHome "integrations\codex\state.json")).Contains($overrideKey)) "environment credential is not written to state"
  Remove-Item Env:ALGOMIM_API_KEY

  $leftovers = @(Get-ChildItem -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -match '^\.credentials\..*\.(tmp|bak)$'
    })
  Assert-True ($leftovers.Count -eq 0) "atomic credential updates leave no temporary files"

  Write-Host "[ok] PowerShell credential contract tests passed."
}
finally {
  if ($null -eq $savedCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $savedCodexHome }
  if ($null -eq $savedAlgomimHome) { Remove-Item Env:ALGOMIM_HOME -ErrorAction SilentlyContinue } else { $env:ALGOMIM_HOME = $savedAlgomimHome }
  if ($null -eq $savedApiKey) { Remove-Item Env:ALGOMIM_API_KEY -ErrorAction SilentlyContinue } else { $env:ALGOMIM_API_KEY = $savedApiKey }
  if ($null -eq $savedProfile) { Remove-Item Env:ALGOMIM_PROFILE -ErrorAction SilentlyContinue } else { $env:ALGOMIM_PROFILE = $savedProfile }
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}
