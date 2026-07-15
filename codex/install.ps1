param(
  [string] $BaseUrl = "",
  [string] $ApiKey = "",
  [string] $ReleaseRef = "",
  [string] $ReleaseVersion = "0.1.0",
  [string] $CredentialProfile = "",
  [string] $AlgomimHome = "",
  [switch] $SkipKey,
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

function Assert-CredentialProfileName {
  param([string] $Value)

  if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw "Credential profile must start with a letter or number and contain at most 64 letters, numbers, dots, underscores, or hyphens."
  }
}

function Normalize-ApiKey {
  param([string] $Value)

  $normalized = $Value.Trim()
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    throw "API key cannot be empty."
  }

  if ($normalized -match '[\x00-\x1F\x7F]') {
    throw "API key cannot contain control characters."
  }

  return $normalized
}

function Escape-TomlString {
  param([string] $Value)
  return $Value.Replace("\", "\\").Replace('"', '\"')
}

function Escape-PowerShellSingleQuotedString {
  param([string] $Value)
  return $Value.Replace("'", "''")
}

function Read-SecretPlainText {
  param([string] $Prompt)

  $secure = Read-Host $Prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    if ($bstr -ne [IntPtr]::Zero) {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }
}

function Read-RequiredSecretPlainText {
  param([string] $Prompt)

  while ($true) {
    $value = Read-SecretPlainText $Prompt
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return Normalize-ApiKey $value
    }

    Write-Warning "API key cannot be empty. Press Ctrl+C to cancel."
  }
}

function Get-CredentialApiKey {
  param(
    [string] $Path,
    [string] $Profile
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $section = ""
  $value = $null
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";")) {
      continue
    }

    if ($trimmed -match '^\[([^\[\]]+)\]$') {
      $section = $Matches[1].Trim()
      continue
    }

    if ($section -eq $Profile -and $trimmed -match '^api_key\s*=\s*(.*)$') {
      if ($null -ne $value) {
        throw "Credential profile '$Profile' contains more than one api_key entry."
      }

      $value = Normalize-ApiKey $Matches[1]
    }
  }

  return $value
}

function Protect-CredentialDirectory {
  param([string] $Path)

  $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & icacls.exe $Path /inheritance:r /grant:r "*$currentUserSid`:(OI)(CI)(F)" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Could not secure Algomim credential directory: $Path"
  }
}

function Protect-CredentialFile {
  param([string] $Path)

  $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & icacls.exe $Path /inheritance:r /grant:r "*$currentUserSid`:(F)" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Could not secure Algomim credentials file: $Path"
  }
}

function Write-SecureTextFileAtomically {
  param(
    [string] $Path,
    [string] $Content
  )

  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  Protect-CredentialDirectory $directory

  if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Credential file cannot be a symbolic link or reparse point: $Path"
  }

  $temporaryPath = Join-Path $directory (".credentials.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
  $backupPath = Join-Path $directory (".credentials.{0}.bak" -f [Guid]::NewGuid().ToString("N"))
  try {
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporaryPath, $Content, $utf8WithoutBom)
    Protect-CredentialFile $temporaryPath

    if (Test-Path -LiteralPath $Path) {
      [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
      Remove-Item -LiteralPath $backupPath -Force
    }
    else {
      [System.IO.File]::Move($temporaryPath, $Path)
    }

    Protect-CredentialFile $Path
  }
  finally {
    if (Test-Path -LiteralPath $temporaryPath) {
      Remove-Item -LiteralPath $temporaryPath -Force
    }
    if (Test-Path -LiteralPath $backupPath) {
      Remove-Item -LiteralPath $backupPath -Force
    }
  }
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
    Protect-CredentialDirectory $directory
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
      Protect-CredentialFile $temporaryPath
    }

    if (Test-Path -LiteralPath $Path) {
      [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
      Remove-Item -LiteralPath $backupPath -Force
    }
    else {
      [System.IO.File]::Move($temporaryPath, $Path)
    }

    if ($Private) {
      Protect-CredentialFile $Path
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
    Protect-CredentialDirectory $directory
  }
  if ((Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Refusing to replace a symbolic link or reparse point: $Destination"
  }

  $temporaryPath = Join-Path $directory (".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($Destination)), [Guid]::NewGuid().ToString("N"))
  $backupPath = Join-Path $directory (".{0}.{1}.bak" -f ([System.IO.Path]::GetFileName($Destination)), [Guid]::NewGuid().ToString("N"))
  try {
    [System.IO.File]::WriteAllBytes($temporaryPath, [System.IO.File]::ReadAllBytes($Source))
    if ($Private) {
      Protect-CredentialFile $temporaryPath
    }

    if (Test-Path -LiteralPath $Destination) {
      [System.IO.File]::Replace($temporaryPath, $Destination, $backupPath)
      Remove-Item -LiteralPath $backupPath -Force
    }
    else {
      [System.IO.File]::Move($temporaryPath, $Destination)
    }
    if ($Private) {
      Protect-CredentialFile $Destination
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

function Set-CredentialApiKey {
  param(
    [string] $Path,
    [string] $Profile,
    [string] $Value
  )

  $normalized = Normalize-ApiKey $Value
  $sourceLines = if (Test-Path -LiteralPath $Path -PathType Leaf) {
    [System.IO.File]::ReadAllLines($Path)
  }
  else {
    @()
  }

  $output = New-Object 'System.Collections.Generic.List[string]'
  $inTargetSection = $false
  $targetSectionFound = $false
  $keyWritten = $false

  foreach ($line in $sourceLines) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^\[([^\[\]]+)\]$') {
      if ($inTargetSection -and -not $keyWritten) {
        $output.Add("api_key = $normalized")
        $keyWritten = $true
      }

      $section = $Matches[1].Trim()
      $inTargetSection = $section -eq $Profile
      if ($inTargetSection) {
        $targetSectionFound = $true
      }

      $output.Add($line)
      continue
    }

    if ($inTargetSection -and $trimmed -match '^api_key\s*=') {
      if (-not $keyWritten) {
        $output.Add("api_key = $normalized")
        $keyWritten = $true
      }
      continue
    }

    $output.Add($line)
  }

  if ($inTargetSection -and -not $keyWritten) {
    $output.Add("api_key = $normalized")
    $keyWritten = $true
  }

  if (-not $targetSectionFound) {
    if ($output.Count -gt 0 -and $output[$output.Count - 1].Length -gt 0) {
      $output.Add("")
    }
    $output.Add("[$Profile]")
    $output.Add("api_key = $normalized")
  }

  $content = [string]::Join([Environment]::NewLine, $output) + [Environment]::NewLine
  Write-SecureTextFileAtomically -Path $Path -Content $content

  $stored = Get-CredentialApiKey -Path $Path -Profile $Profile
  if ($stored -cne $normalized) {
    throw "Credential verification failed after writing profile '$Profile'."
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

  return Normalize-ApiKey $value
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

if ([string]::IsNullOrWhiteSpace($CredentialProfile)) {
  $CredentialProfile = if ($env:ALGOMIM_PROFILE) { $env:ALGOMIM_PROFILE } else { "default" }
}
$CredentialProfile = $CredentialProfile.Trim()
Assert-CredentialProfileName $CredentialProfile

if ([string]::IsNullOrWhiteSpace($AlgomimHome)) {
  $AlgomimHome = if ($env:ALGOMIM_HOME) { $env:ALGOMIM_HOME } else { Join-Path $HOME ".algomim" }
}
$AlgomimHome = [System.IO.Path]::GetFullPath($AlgomimHome)

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$codexHome = [System.IO.Path]::GetFullPath($codexHome)
$profilePath = Join-Path $codexHome "algomim.config.toml"
$catalogPath = Join-Path $codexHome "algomim-models.json"
$legacyKeyPath = Join-Path $codexHome "algomim.key"
$authScriptPath = Join-Path $codexHome "algomim-auth.ps1"
$credentialsPath = Join-Path $AlgomimHome "credentials"
$integrationHome = Join-Path $AlgomimHome "integrations\codex"
$statePath = Join-Path $integrationHome "state.json"

Write-Step "Using API base URL $BaseUrl"
Write-Step "Using credential profile '$CredentialProfile' in $credentialsPath"
New-Item -ItemType Directory -Force -Path $codexHome | Out-Null

$explicitApiKey = -not [string]::IsNullOrWhiteSpace($ApiKey)
$storedApiKey = Get-CredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
$legacyApiKey = Get-LegacyApiKey -Path $legacyKeyPath

if (-not $SkipKey) {
  if ($explicitApiKey) {
    Set-CredentialApiKey -Path $credentialsPath -Profile $CredentialProfile -Value $ApiKey
    $storedApiKey = Get-CredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
    Write-Step "Stored credential profile '$CredentialProfile' at $credentialsPath"
  }
  elseif ($null -ne $storedApiKey) {
    Protect-CredentialDirectory $AlgomimHome
    Protect-CredentialFile $credentialsPath
    Write-Step "Reusing credential profile '$CredentialProfile'."
  }
  elseif ($null -ne $legacyApiKey) {
    Set-CredentialApiKey -Path $credentialsPath -Profile $CredentialProfile -Value $legacyApiKey
    $storedApiKey = Get-CredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
    Remove-Item -LiteralPath $legacyKeyPath -Force
    $legacyApiKey = $null
    Write-Step "Migrated the legacy Codex key to shared Algomim credentials."
  }
  elseif (-not [string]::IsNullOrWhiteSpace($env:ALGOMIM_API_KEY)) {
    [void] (Normalize-ApiKey $env:ALGOMIM_API_KEY)
    Write-Step "Using ALGOMIM_API_KEY from the environment without persisting it."
  }
  else {
    $ApiKey = Read-RequiredSecretPlainText "Algomim API key"
    Set-CredentialApiKey -Path $credentialsPath -Profile $CredentialProfile -Value $ApiKey
    $storedApiKey = Get-CredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
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
$storedApiKey = Get-CredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
if (-not $hasEnvironmentCredential -and $null -eq $storedApiKey) {
  Write-Warning "No Algomim credential is available. Set ALGOMIM_API_KEY or run this installer again without -SkipKey."
}

Install-ReleaseFile -Name "algomim-models.json" -Destination $catalogPath -Ref $ReleaseRef
Write-Step "Installed model catalog at $catalogPath"

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
personality = "none"
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
"@
Write-Utf8TextFileAtomically -Path $profilePath -Content ($profile + [Environment]::NewLine)
Write-Step "Installed Codex profile at $profilePath"

New-Item -ItemType Directory -Force -Path $integrationHome | Out-Null
Protect-CredentialDirectory $integrationHome
foreach ($releaseFile in @("install.ps1", "update.ps1", "doctor.ps1", "uninstall.ps1", "release.json")) {
  Install-ReleaseFile -Name $releaseFile -Destination (Join-Path $integrationHome $releaseFile) -Ref $ReleaseRef
}

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
