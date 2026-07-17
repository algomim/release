param(
  [string] $BaseUrl = "",
  [string] $ApiKey = "",
  [string] $ReleaseRef = "",
  [string] $ReleaseVersion = "0.3.7",
  [string] $CredentialProfile = "",
  [string] $AlgomimHome = "",
  [switch] $SkipKey,
  [switch] $SkipCliInstall,
  [ValidateSet("User", "Process")]
  [string] $CliPathTarget = "User",
  [switch] $RunDoctor
)

$ErrorActionPreference = "Stop"

function Write-Step {
  param([string] $Message)
  Write-Host "[algomim] $Message"
}

function Normalize-BaseUrl {
  param([string] $Value)

  $trimmed = $Value.Trim().TrimEnd("/")
  if ($trimmed.Length -eq 0) {
    throw "Base URL is required."
  }

  if ($trimmed -notmatch "^https?://") {
    throw "Base URL must start with http:// or https://."
  }

  if ($trimmed -notmatch "/v1$") {
    return "$trimmed/v1"
  }

  return $trimmed
}

function Escape-TomlString {
  param([string] $Value)
  return $Value.Replace("\", "\\").Replace('"', '\"')
}

function Escape-PowerShellSingleQuotedString {
  param([string] $Value)
  return $Value.Replace("'", "''")
}

function Write-Utf8TextFileAtomically {
  param(
    [string] $Path,
    [string] $Content,
    [switch] $Private
  )

  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  if ($Private) {
    Protect-AlgomimCredentialDirectory $directory
  }

  if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Refusing to replace a symbolic link or reparse point: $Path"
  }

  $temporaryPath = Join-Path $directory (".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString("N"))
  $backupPath = Join-Path $directory (".{0}.{1}.bak" -f ([System.IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString("N"))
  try {
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporaryPath, $Content, $utf8WithoutBom)
    if ($Private) {
      Protect-AlgomimCredentialFile $temporaryPath
    }

    if (Test-Path -LiteralPath $Path) {
      [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
      Remove-Item -LiteralPath $backupPath -Force
    }
    else {
      [System.IO.File]::Move($temporaryPath, $Path)
    }

    if ($Private) {
      Protect-AlgomimCredentialFile $Path
    }
  }
  finally {
    foreach ($candidate in @($temporaryPath, $backupPath)) {
      if (Test-Path -LiteralPath $candidate) {
        Remove-Item -LiteralPath $candidate -Force
      }
    }
  }
}

function Copy-FileAtomically {
  param(
    [string] $Source,
    [string] $Destination,
    [switch] $Private
  )

  $directory = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  if ($Private) {
    Protect-AlgomimCredentialDirectory $directory
  }
  if ((Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Refusing to replace a symbolic link or reparse point: $Destination"
  }

  $temporaryPath = Join-Path $directory (".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($Destination)), [Guid]::NewGuid().ToString("N"))
  $backupPath = Join-Path $directory (".{0}.{1}.bak" -f ([System.IO.Path]::GetFileName($Destination)), [Guid]::NewGuid().ToString("N"))
  try {
    [System.IO.File]::WriteAllBytes($temporaryPath, [System.IO.File]::ReadAllBytes($Source))
    if ($Private) {
      Protect-AlgomimCredentialFile $temporaryPath
    }

    if (Test-Path -LiteralPath $Destination) {
      [System.IO.File]::Replace($temporaryPath, $Destination, $backupPath)
      Remove-Item -LiteralPath $backupPath -Force
    }
    else {
      [System.IO.File]::Move($temporaryPath, $Destination)
    }
    if ($Private) {
      Protect-AlgomimCredentialFile $Destination
    }
  }
  finally {
    foreach ($candidate in @($temporaryPath, $backupPath)) {
      if (Test-Path -LiteralPath $candidate) {
        Remove-Item -LiteralPath $candidate -Force
      }
    }
  }
}

function Install-ReleaseFile {
  param(
    [string] $Name,
    [string] $Destination,
    [string] $Ref
  )

  $localPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot $Name } else { "" }
  if ($localPath -and (Test-Path -LiteralPath $localPath -PathType Leaf)) {
    Copy-FileAtomically -Source $localPath -Destination $Destination
    return
  }

  $downloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-{0}-{1}" -f [Guid]::NewGuid().ToString("N"), $Name)
  try {
    $url = "https://raw.githubusercontent.com/algomim/release/$Ref/codex/$Name"
    Invoke-WebRequest -Uri $url -OutFile $downloadPath -UseBasicParsing
    Copy-FileAtomically -Source $downloadPath -Destination $Destination
  }
  finally {
    if (Test-Path -LiteralPath $downloadPath) {
      Remove-Item -LiteralPath $downloadPath -Force
    }
  }
}

function Install-SharedReleaseFile {
  param(
    [string] $Name,
    [string] $Destination,
    [string] $Ref
  )

  $localCandidates = @()
  if ($PSScriptRoot) {
    $localCandidates += (Join-Path $PSScriptRoot $Name)
    $localCandidates += (Join-Path (Split-Path -Parent $PSScriptRoot) "shared\$Name")
  }
  foreach ($candidate in $localCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      Copy-FileAtomically -Source $candidate -Destination $Destination
      return
    }
  }

  $downloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-shared-{0}-{1}" -f [Guid]::NewGuid().ToString("N"), $Name)
  try {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/algomim/release/$Ref/shared/$Name" -OutFile $downloadPath -UseBasicParsing
    Copy-FileAtomically -Source $downloadPath -Destination $Destination
  }
  finally {
    if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force }
  }
}

function Resolve-CredentialStoreSource {
  param([string] $Ref)

  $script:credentialStoreSourceIsTemporary = $false
  if ($PSScriptRoot) {
    foreach ($candidate in @(
        (Join-Path $PSScriptRoot "credential-store.ps1"),
        (Join-Path (Split-Path -Parent $PSScriptRoot) "shared\credential-store.ps1")
      )) {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
  }
  $downloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-credential-store-{0}.ps1" -f [Guid]::NewGuid().ToString("N"))
  try {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/algomim/release/$Ref/shared/credential-store.ps1" -OutFile $downloadPath -UseBasicParsing
    $script:credentialStoreSourceIsTemporary = $true
    return $downloadPath
  }
  catch {
    if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force }
    throw
  }
}

function Invoke-AlgomimCliInstaller {
  param(
    [string] $Ref,
    [string] $Version,
    [string] $TargetHome,
    [string] $PathTarget
  )

  $installerPath = ""
  if ($PSScriptRoot) {
    $candidate = Join-Path (Split-Path -Parent $PSScriptRoot) "cli\install.ps1"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $installerPath = $candidate
    }
  }
  $downloadPath = ""
  try {
    if ([string]::IsNullOrWhiteSpace($installerPath)) {
      $downloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-cli-install-{0}.ps1" -f [Guid]::NewGuid().ToString("N"))
      Invoke-WebRequest -Uri "https://raw.githubusercontent.com/algomim/release/$Ref/cli/install.ps1" -OutFile $downloadPath -UseBasicParsing
      $installerPath = $downloadPath
    }
    & $installerPath -AlgomimHome $TargetHome -ReleaseRef $Ref -ReleaseVersion $Version -PathTarget $PathTarget
  }
  finally {
    if ($downloadPath -and (Test-Path -LiteralPath $downloadPath)) {
      Remove-Item -LiteralPath $downloadPath -Force
    }
  }
}

function Install-ModelCatalog {
  param(
    [string] $CatalogDestination,
    [string] $LockDestination,
    [string] $Ref
  )

  $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-catalog-{0}" -f [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
  try {
    $catalogSource = Join-Path $temporaryRoot "algomim-models.json"
    $lockSource = Join-Path $temporaryRoot "algomim-models.lock.json"
    Install-ReleaseFile -Name "algomim-models.json" -Destination $catalogSource -Ref $Ref
    Install-ReleaseFile -Name "algomim-models.lock.json" -Destination $lockSource -Ref $Ref

    $lock = Get-Content -Raw -LiteralPath $lockSource | ConvertFrom-Json
    $actualHash = (Get-FileHash -LiteralPath $catalogSource -Algorithm SHA256).Hash.ToLowerInvariant()
    if (
      $lock.schemaVersion -ne 1 -or
      $lock.generator -ne "@algomim/inference/codex-model-catalog" -or
      $lock.generatorVersion -ne 1 -or
      $lock.catalogSha256 -cne $actualHash
    ) {
      throw "Model catalog SHA-256 verification failed."
    }

    Copy-FileAtomically -Source $lockSource -Destination $LockDestination
    Copy-FileAtomically -Source $catalogSource -Destination $CatalogDestination
  }
  finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
      Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
  }
}

function Get-LegacyApiKey {
  param([string] $Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $value = (Get-Content -Raw -LiteralPath $Path).Trim()
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $null
  }

  return Normalize-AlgomimApiKey $value
}

$defaultBaseUrl = "https://api.algomim.com/v1"
if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
  $BaseUrl = $defaultBaseUrl
}
$BaseUrl = Normalize-BaseUrl $BaseUrl

if ($ReleaseVersion -notmatch '^\d+\.\d+\.\d+$') {
  throw "ReleaseVersion must use MAJOR.MINOR.PATCH format."
}
if ([string]::IsNullOrWhiteSpace($ReleaseRef)) {
  $ReleaseRef = "v$ReleaseVersion"
}
if ($ReleaseRef -notmatch '^[A-Za-z0-9._/-]+$') {
  throw "ReleaseRef contains unsupported characters."
}

$credentialStoreSource = Resolve-CredentialStoreSource $ReleaseRef
try {
  . $credentialStoreSource
}
finally {
  if ($script:credentialStoreSourceIsTemporary) {
    Remove-Item -LiteralPath $credentialStoreSource -Force -ErrorAction SilentlyContinue
  }
}

if ([string]::IsNullOrWhiteSpace($CredentialProfile)) {
  $CredentialProfile = if ($env:ALGOMIM_PROFILE) { $env:ALGOMIM_PROFILE } else { "default" }
}
$CredentialProfile = $CredentialProfile.Trim()
Assert-AlgomimCredentialProfileName $CredentialProfile

if ([string]::IsNullOrWhiteSpace($AlgomimHome)) {
  $AlgomimHome = if ($env:ALGOMIM_HOME) { $env:ALGOMIM_HOME } else { Join-Path $HOME ".algomim" }
}
$AlgomimHome = [System.IO.Path]::GetFullPath($AlgomimHome)

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$codexHome = [System.IO.Path]::GetFullPath($codexHome)
$profilePath = Join-Path $codexHome "algomim.config.toml"
$catalogPath = Join-Path $codexHome "algomim-models.json"
$catalogLockPath = Join-Path $codexHome "algomim-models.lock.json"
$legacyKeyPath = Join-Path $codexHome "algomim.key"
$authScriptPath = Join-Path $codexHome "algomim-auth.ps1"
$credentialsPath = Join-Path $AlgomimHome "credentials"
$integrationHome = Join-Path $AlgomimHome "integrations\codex"
$statePath = Join-Path $integrationHome "state.json"

Write-Step "Using API base URL $BaseUrl"
Write-Step "Using credential profile '$CredentialProfile' in $credentialsPath"
New-Item -ItemType Directory -Force -Path $codexHome | Out-Null

$explicitApiKey = -not [string]::IsNullOrWhiteSpace($ApiKey)
$storedApiKey = Get-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
$legacyApiKey = Get-LegacyApiKey -Path $legacyKeyPath

if (-not $SkipKey) {
  if ($explicitApiKey) {
    Set-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile -Value $ApiKey
    $storedApiKey = Get-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
    Write-Step "Stored credential profile '$CredentialProfile' at $credentialsPath"
  }
  elseif ($null -ne $storedApiKey) {
    Protect-AlgomimCredentialDirectory $AlgomimHome
    Protect-AlgomimCredentialFile $credentialsPath
    Write-Step "Reusing credential profile '$CredentialProfile'."
  }
  elseif ($null -ne $legacyApiKey) {
    Set-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile -Value $legacyApiKey
    $storedApiKey = Get-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
    Remove-Item -LiteralPath $legacyKeyPath -Force
    $legacyApiKey = $null
    Write-Step "Migrated the legacy Codex key to shared Algomim credentials."
  }
  elseif (-not [string]::IsNullOrWhiteSpace($env:ALGOMIM_API_KEY)) {
    [void] (Normalize-AlgomimApiKey $env:ALGOMIM_API_KEY)
    Write-Step "Using ALGOMIM_API_KEY from the environment without persisting it."
  }
  else {
    $ApiKey = Read-AlgomimRequiredSecretPlainText "Algomim API key"
    Set-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile -Value $ApiKey
    $storedApiKey = Get-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
    Write-Step "Stored credential profile '$CredentialProfile' at $credentialsPath"
  }

  if ($null -ne $legacyApiKey -and $null -ne $storedApiKey) {
    if ($explicitApiKey -or $legacyApiKey -ceq $storedApiKey) {
      Remove-Item -LiteralPath $legacyKeyPath -Force
      Write-Step "Removed the obsolete legacy Codex key file."
    }
    else {
      Write-Warning "A different legacy key remains at $legacyKeyPath. The shared credential profile takes precedence."
    }
  }
}

$hasEnvironmentCredential = -not [string]::IsNullOrWhiteSpace($env:ALGOMIM_API_KEY)
$storedApiKey = Get-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
if (-not $hasEnvironmentCredential -and $null -eq $storedApiKey) {
  Write-Warning "No Algomim credential is available. Set ALGOMIM_API_KEY or run this installer again without -SkipKey."
}

Install-ModelCatalog -CatalogDestination $catalogPath -LockDestination $catalogLockPath -Ref $ReleaseRef
Write-Step "Installed and verified model catalog at $catalogPath"

$algomimHomePowerShell = Escape-PowerShellSingleQuotedString $AlgomimHome
$credentialProfilePowerShell = Escape-PowerShellSingleQuotedString $CredentialProfile
$authScript = @"
`$ErrorActionPreference = "Stop"

function Get-AlgomimCredential {
  param([string] `$Path, [string] `$Profile)

  if (-not (Test-Path -LiteralPath `$Path -PathType Leaf)) {
    throw "Algomim credentials file not found: `$Path"
  }

  `$section = ""
  `$value = `$null
  foreach (`$line in [System.IO.File]::ReadAllLines(`$Path)) {
    `$trimmed = `$line.Trim()
    if (`$trimmed.Length -eq 0 -or `$trimmed.StartsWith("#") -or `$trimmed.StartsWith(";")) {
      continue
    }
    if (`$trimmed -match '^\[([^\[\]]+)\]$') {
      `$section = `$Matches[1].Trim()
      continue
    }
    if (`$section -eq `$Profile -and `$trimmed -match '^api_key\s*=\s*(.*)$') {
      if (`$null -ne `$value) {
        throw "Credential profile '`$Profile' contains more than one api_key entry."
      }
      `$value = `$Matches[1].Trim()
    }
  }

  if ([string]::IsNullOrWhiteSpace(`$value)) {
    throw "Credential profile '`$Profile' was not found or has no api_key."
  }
  if (`$value -match '[\x00-\x1F\x7F]') {
    throw "Credential profile '`$Profile' contains an invalid api_key."
  }
  return `$value
}

if (-not [string]::IsNullOrWhiteSpace(`$env:ALGOMIM_API_KEY)) {
  `$token = `$env:ALGOMIM_API_KEY.Trim()
  if (`$token -match '[\x00-\x1F\x7F]') {
    throw "ALGOMIM_API_KEY contains control characters."
  }
  Write-Output `$token
  exit 0
}

`$profile = if (`$env:ALGOMIM_PROFILE) { `$env:ALGOMIM_PROFILE.Trim() } else { '$credentialProfilePowerShell' }
if (`$profile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
  throw "ALGOMIM_PROFILE is invalid."
}
`$algomimHome = if (`$env:ALGOMIM_HOME) { `$env:ALGOMIM_HOME } else { '$algomimHomePowerShell' }
`$credentialsPath = Join-Path ([System.IO.Path]::GetFullPath(`$algomimHome)) "credentials"
Write-Output (Get-AlgomimCredential -Path `$credentialsPath -Profile `$profile)
"@
Write-Utf8TextFileAtomically -Path $authScriptPath -Content ($authScript + [Environment]::NewLine)
Write-Step "Installed auth helper at $authScriptPath"

$catalogToml = Escape-TomlString $catalogPath
$baseUrlToml = Escape-TomlString $BaseUrl
$authScriptToml = Escape-TomlString $authScriptPath
$profile = @"
model = "algomim"
model_provider = "algomim"
model_catalog_json = "$catalogToml"
web_search = "disabled"
service_tier = "default"
model_reasoning_effort = "medium"

[model_providers.algomim]
name = "Algomim"
base_url = "$baseUrlToml"
wire_api = "responses"

[model_providers.algomim.auth]
command = "powershell"
args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$authScriptToml"]
timeout_ms = 5000
refresh_interval_ms = 300000

[features]
personality = false
"@
Write-Utf8TextFileAtomically -Path $profilePath -Content ($profile + [Environment]::NewLine)
Write-Step "Installed Codex profile at $profilePath"

New-Item -ItemType Directory -Force -Path $integrationHome | Out-Null
Protect-AlgomimCredentialDirectory $integrationHome
foreach ($releaseFile in @("install.ps1", "update.ps1", "doctor.ps1", "uninstall.ps1", "release.json")) {
  Install-ReleaseFile -Name $releaseFile -Destination (Join-Path $integrationHome $releaseFile) -Ref $ReleaseRef
}
Install-SharedReleaseFile -Name "credential-store.ps1" -Destination (Join-Path $integrationHome "credential-store.ps1") -Ref $ReleaseRef

$now = [DateTimeOffset]::UtcNow.ToString("o")
$installedAt = $now
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  try {
    $existingState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($existingState.integration -eq "codex" -and -not [string]::IsNullOrWhiteSpace($existingState.installedAt)) {
      $installedAt = [string] $existingState.installedAt
    }
  }
  catch {
    throw "Existing Codex installation state is invalid: $statePath"
  }
}

$state = [ordered] @{
  schemaVersion = 1
  integration = "codex"
  version = $ReleaseVersion
  channel = "pilot"
  releaseRepository = "algomim/release"
  releaseTag = $ReleaseRef
  baseUrl = $BaseUrl
  credentialProfile = $CredentialProfile
  codexHome = $codexHome
  installedAt = $installedAt
  updatedAt = $now
}
$stateJson = $state | ConvertTo-Json
Write-Utf8TextFileAtomically -Path $statePath -Content ($stateJson + [Environment]::NewLine) -Private
Write-Step "Recorded Codex integration version $ReleaseVersion at $statePath"

if (-not $SkipKey -and -not $SkipCliInstall) {
  Invoke-AlgomimCliInstaller -Ref $ReleaseRef -Version $ReleaseVersion -TargetHome $AlgomimHome -PathTarget $CliPathTarget
}

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
  Write-Warning "Codex CLI was not found on PATH. Install Codex before running codex --profile algomim."
}
else {
  Write-Step "Codex CLI found."
}

Write-Host ""
Write-Host "Algomim Codex profile is ready."
Write-Host "Start it with:"
Write-Host "  codex --profile algomim"
Write-Host ""
Write-Host "Normal 'codex' still uses your existing default provider."

if ($RunDoctor) {
  $doctor = if ($PSScriptRoot) { Join-Path $PSScriptRoot "doctor.ps1" } else { "" }
  if ($doctor -and (Test-Path -LiteralPath $doctor)) {
    & $doctor -CodexHome $codexHome -AlgomimHome $AlgomimHome -CredentialProfile $CredentialProfile
  }
}
