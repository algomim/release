param(
  [string] $BaseUrl = "",
  [string] $ApiKey = "",
  [string] $ReleaseRef = "",
  [string] $ReleaseVersion = "0.3.0",
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

function Escape-JsonString {
  param([string] $Value)
  return $Value.Replace("\", "\\").Replace('"', '\"')
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

  $downloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-{0}-{1}" -f [Guid]::NewGuid().ToString("N"), ($Name -replace '[\\/]', '-'))
  try {
    $url = "https://raw.githubusercontent.com/algomim/release/$Ref/claude-code/$Name"
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

$credentialsPath = Join-Path $AlgomimHome "credentials"
$integrationHome = Join-Path $AlgomimHome "integrations\claude-code"
$settingsPath = Join-Path $integrationHome "settings.json"
$statePath = Join-Path $integrationHome "state.json"

Write-Step "Using API base URL $BaseUrl"
Write-Step "Using credential profile '$CredentialProfile' in $credentialsPath"

$explicitApiKey = -not [string]::IsNullOrWhiteSpace($ApiKey)
$storedApiKey = Get-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile

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
}

$hasEnvironmentCredential = -not [string]::IsNullOrWhiteSpace($env:ALGOMIM_API_KEY)
$storedApiKey = Get-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
if (-not $hasEnvironmentCredential -and $null -eq $storedApiKey) {
  Write-Warning "No Algomim credential is available. Set ALGOMIM_API_KEY or run this installer again without -SkipKey."
}

$baseUrlJson = Escape-JsonString $BaseUrl
$settings = @"
{
  "model": "algomim",
  "env": {
    "ANTHROPIC_BASE_URL": "$baseUrlJson",
    "ANTHROPIC_MODEL": "algomim",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "algomim",
    "ANTHROPIC_CUSTOM_MODEL_OPTION": "algomim",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Algomim"
  }
}
"@
New-Item -ItemType Directory -Force -Path $integrationHome | Out-Null
Protect-AlgomimCredentialDirectory $integrationHome
Write-Utf8TextFileAtomically -Path $settingsPath -Content ($settings + [Environment]::NewLine)
Write-Step "Installed Claude Code settings at $settingsPath"

foreach ($releaseFile in @("install.ps1", "update.ps1", "doctor.ps1", "uninstall.ps1", "release.json")) {
  Install-ReleaseFile -Name $releaseFile -Destination (Join-Path $integrationHome $releaseFile) -Ref $ReleaseRef
}
Install-SharedReleaseFile -Name "credential-store.ps1" -Destination (Join-Path $integrationHome "credential-store.ps1") -Ref $ReleaseRef

$now = [DateTimeOffset]::UtcNow.ToString("o")
$installedAt = $now
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  try {
    $existingState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($existingState.integration -eq "claude-code" -and -not [string]::IsNullOrWhiteSpace($existingState.installedAt)) {
      $installedAt = [string] $existingState.installedAt
    }
  }
  catch {
    throw "Existing Claude Code installation state is invalid: $statePath"
  }
}

$state = [ordered] @{
  schemaVersion = 1
  integration = "claude-code"
  version = $ReleaseVersion
  channel = "pilot"
  releaseRepository = "algomim/release"
  releaseTag = $ReleaseRef
  baseUrl = $BaseUrl
  credentialProfile = $CredentialProfile
  installedAt = $installedAt
  updatedAt = $now
}
$stateJson = $state | ConvertTo-Json
Write-Utf8TextFileAtomically -Path $statePath -Content ($stateJson + [Environment]::NewLine) -Private
Write-Step "Recorded Claude Code integration version $ReleaseVersion at $statePath"

if (-not $SkipKey -and -not $SkipCliInstall) {
  Invoke-AlgomimCliInstaller -Ref $ReleaseRef -Version $ReleaseVersion -TargetHome $AlgomimHome -PathTarget $CliPathTarget
}

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Warning "Claude Code CLI was not found on PATH. Install Claude Code before running algomim run claude."
}
else {
  Write-Step "Claude Code CLI found."
}

Write-Host ""
Write-Host "Algomim Claude Code integration is ready."
Write-Host "Start it with:"
Write-Host "  algomim run claude"
Write-Host ""
Write-Host "Normal 'claude' still uses your existing Anthropic account. Nothing was written to ~/.claude."

if ($RunDoctor) {
  $doctor = if ($PSScriptRoot) { Join-Path $PSScriptRoot "doctor.ps1" } else { "" }
  if ($doctor -and (Test-Path -LiteralPath $doctor)) {
    & $doctor -AlgomimHome $AlgomimHome -CredentialProfile $CredentialProfile
  }
}
