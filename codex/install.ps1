param(
  [string] $BaseUrl = "",
  [string] $ApiKey = "",
  [string] $ReleaseRef = "main",
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
      return $value.Trim()
    }

    Write-Warning "API key cannot be empty. Press Ctrl+C to cancel."
  }
}

function Test-UsableKeyFile {
  param([string] $Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $false
  }

  return -not [string]::IsNullOrWhiteSpace((Get-Content -Raw -LiteralPath $Path))
}

$defaultBaseUrl = "https://api.algomim.com/v1"
if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
  $BaseUrl = $defaultBaseUrl
}

$BaseUrl = Normalize-BaseUrl $BaseUrl
Write-Step "Using API base URL $BaseUrl"

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$codexHome = [System.IO.Path]::GetFullPath($codexHome)
$profilePath = Join-Path $codexHome "algomim.config.toml"
$catalogPath = Join-Path $codexHome "algomim-models.json"
$keyPath = Join-Path $codexHome "algomim.key"
$authScriptPath = Join-Path $codexHome "algomim-auth.ps1"

New-Item -ItemType Directory -Force -Path $codexHome | Out-Null

if (-not $SkipKey) {
  if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    if (Test-UsableKeyFile $keyPath) {
      $reuse = Read-Host "Existing Algomim key found. Reuse it? [Y/n]"
      if ($reuse -match "^[nN]") {
        $ApiKey = Read-RequiredSecretPlainText "New Algomim API key"
      }
      else {
        Write-Step "Reusing existing API key."
      }
    }
    else {
      $ApiKey = Read-RequiredSecretPlainText "Algomim API key"
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    Set-Content -LiteralPath $keyPath -Value $ApiKey.Trim() -NoNewline -Encoding utf8
    Write-Step "Stored API key at $keyPath"
  }
}

if (-not (Test-UsableKeyFile $keyPath)) {
  Write-Warning "No Algomim API key file found. Run this installer again without -SkipKey before starting Codex."
}

$localCatalog = if ($PSScriptRoot) { Join-Path $PSScriptRoot "algomim-models.json" } else { "" }
if ($localCatalog -and (Test-Path -LiteralPath $localCatalog)) {
  Copy-Item -LiteralPath $localCatalog -Destination $catalogPath -Force
}
else {
  $catalogUrl = "https://raw.githubusercontent.com/algomim/release/$ReleaseRef/codex/algomim-models.json"
  Invoke-WebRequest -Uri $catalogUrl -OutFile $catalogPath -UseBasicParsing
}
Write-Step "Installed model catalog at $catalogPath"

$keyPathPowerShell = Escape-PowerShellSingleQuotedString $keyPath
$authScript = @"
`$ErrorActionPreference = "Stop"
`$keyPath = '$keyPathPowerShell'
if (-not (Test-Path -LiteralPath `$keyPath)) {
  throw "Algomim key file not found: `$keyPath"
}
`$token = (Get-Content -Raw -LiteralPath `$keyPath).Trim()
if ([string]::IsNullOrWhiteSpace(`$token)) {
  throw "Algomim key file is empty: `$keyPath"
}
Write-Output `$token
"@
Set-Content -LiteralPath $authScriptPath -Value $authScript -Encoding utf8
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

Set-Content -LiteralPath $profilePath -Value $profile -Encoding utf8
Write-Step "Installed Codex profile at $profilePath"

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
    & $doctor -CodexHome $codexHome
  }
}
