param(
  [string] $AlgomimHome = "",
  [string] $CredentialProfile = "",
  [switch] $SkipApiCheck,
  [switch] $ThrowOnFailure
)

$ErrorActionPreference = "Stop"
$failed = $false

function Check-Ok {
  param([string] $Message)
  Write-Host "[ok] $Message"
}

function Check-Warn {
  param([string] $Message)
  Write-Host "[warn] $Message" -ForegroundColor Yellow
}

function Check-Fail {
  param([string] $Message)
  Write-Host "[fail] $Message" -ForegroundColor Red
  $script:failed = $true
}

function Test-CredentialFileAcl {
  param([string] $Path)

  $acl = Get-Acl -LiteralPath $Path
  if (-not $acl.AreAccessRulesProtected) {
    return $false
  }

  $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $allowedSids = @($currentUserSid, "S-1-5-18", "S-1-5-32-544")
  foreach ($rule in $acl.Access) {
    if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
      continue
    }

    try {
      $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
      return $false
    }

    if ($allowedSids -notcontains $sid) {
      return $false
    }
  }

  return $true
}

if ([string]::IsNullOrWhiteSpace($AlgomimHome)) {
  $AlgomimHome = if ($env:ALGOMIM_HOME) { $env:ALGOMIM_HOME } else { Join-Path $HOME ".algomim" }
}
$AlgomimHome = [System.IO.Path]::GetFullPath($AlgomimHome)
$integrationHome = Join-Path $AlgomimHome "integrations\claude-code"
$credentialHelperCandidates = @(
  (Join-Path $integrationHome "credential-store.ps1"),
  (Join-Path $AlgomimHome "cli\credential-store.ps1")
)
if ($PSScriptRoot) {
  $credentialHelperCandidates += (Join-Path (Split-Path -Parent $PSScriptRoot) "shared\credential-store.ps1")
}
$credentialHelper = $credentialHelperCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($credentialHelper)) {
  throw "Algomim credential helper is missing. Run the installer again."
}
. $credentialHelper
$statePath = Join-Path $integrationHome "state.json"
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  try {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  }
  catch {
    Check-Fail "Claude Code installation state is not valid JSON."
  }
}
else {
  Check-Fail "Claude Code installation state is missing: $statePath"
}

if ([string]::IsNullOrWhiteSpace($CredentialProfile)) {
  $CredentialProfile = if ($env:ALGOMIM_PROFILE) {
    $env:ALGOMIM_PROFILE
  }
  elseif ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.credentialProfile)) {
    [string] $state.credentialProfile
  }
  else {
    "default"
  }
}

$CredentialProfile = $CredentialProfile.Trim()
try {
  Assert-AlgomimCredentialProfileName $CredentialProfile
}
catch {
  Check-Fail "Credential profile name is invalid."
}

$settingsPath = Join-Path $integrationHome "settings.json"
$credentialsPath = Join-Path $AlgomimHome "credentials"

if ($null -ne $state) {
  if ($state.schemaVersion -eq 1 -and $state.integration -eq "claude-code" -and ([string] $state.version) -match '^\d+\.\d+\.\d+$') {
    Check-Ok "Installation state reports Claude Code integration version $($state.version)."
  }
  else {
    Check-Fail "Claude Code installation state has an unsupported contract."
  }

  $releaseContractPath = Join-Path $integrationHome "release.json"
  try {
    $releaseContract = Get-Content -Raw -LiteralPath $releaseContractPath | ConvertFrom-Json
    if ($releaseContract.integration -eq "claude-code" -and $releaseContract.version -eq $state.version) {
      Check-Ok "Installed release contract matches the recorded version."
    }
    else {
      Check-Fail "Installed release contract does not match the recorded version."
    }
  }
  catch {
    Check-Fail "Installed release contract is missing or invalid."
  }

  foreach ($lifecycleFile in @("install.ps1", "update.ps1", "doctor.ps1", "uninstall.ps1")) {
    if (-not (Test-Path -LiteralPath (Join-Path $integrationHome $lifecycleFile) -PathType Leaf)) {
      Check-Fail "Installed lifecycle file is missing: $lifecycleFile"
    }
  }
}

if (Get-Command claude -ErrorAction SilentlyContinue) {
  $claudeVersionOutput = (& claude --version 2>$null | Out-String).Trim()
  if ($claudeVersionOutput -match '(\d+\.\d+\.\d+)' -and ([version] $Matches[1]) -ge ([version] "2.1.200")) {
    Check-Ok "Claude Code CLI $($Matches[1]) is supported."
  }
  else {
    Check-Fail "Claude Code CLI 2.1.200 or newer is required."
  }
}
else {
  Check-Fail "Claude Code CLI is not available on PATH."
}

$baseUrl = $null
if (Test-Path -LiteralPath $settingsPath) {
  try {
    $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    Check-Ok "Settings exist: $settingsPath"

    if ($settings.model -eq "algomim") {
      Check-Ok "Settings select the algomim model."
    }
    else {
      Check-Fail "Settings do not select the algomim model."
    }

    if ($null -ne $settings.env) {
      foreach ($required in @(
          @{ Name = "ANTHROPIC_MODEL"; Expected = "algomim" },
          @{ Name = "ANTHROPIC_CUSTOM_MODEL_OPTION"; Expected = "algomim" },
          @{ Name = "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"; Expected = "Algomim" },
          @{ Name = "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"; Expected = "Algomim Model API" },
          @{ Name = "CLAUDE_CODE_SUBAGENT_MODEL"; Expected = "algomim" },
          @{ Name = "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"; Expected = "1" }
        )) {
        $value = [string] $settings.env.($required.Name)
        if ($value -eq $required.Expected) {
          Check-Ok "Settings set $($required.Name)."
        }
        else {
          Check-Fail "Settings do not set $($required.Name) to $($required.Expected)."
        }
      }

      $familyOverrides = @(
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL"
      )
      $presentFamilyOverrides = @($familyOverrides | Where-Object {
          $null -ne $settings.env.PSObject.Properties[$_]
        })
      if ($presentFamilyOverrides.Count -eq 0) {
        Check-Ok "Settings do not override Claude model families."
      }
      else {
        foreach ($familyOverride in $presentFamilyOverrides) {
          Check-Fail "Settings must not set $familyOverride; use the Algomim custom model option instead."
        }
      }

      $baseUrl = [string] $settings.env.ANTHROPIC_BASE_URL
      if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
        Check-Ok "Settings base URL is set to $baseUrl"
        if ($baseUrl.TrimEnd('/') -match '/v1$') {
          Check-Fail "Settings base URL must be the service root and must not end in /v1."
        }
        if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.baseUrl) -and ([string] $state.baseUrl) -ne $baseUrl) {
          Check-Fail "Settings base URL does not match the recorded installation state."
        }
      }
      else {
        Check-Fail "Settings do not set ANTHROPIC_BASE_URL."
        $baseUrl = $null
      }

      if (-not [string]::IsNullOrWhiteSpace([string] $settings.env.ANTHROPIC_AUTH_TOKEN)) {
        Check-Fail "Settings must not embed ANTHROPIC_AUTH_TOKEN. Remove it and rely on algomim run claude."
      }
    }
    else {
      Check-Fail "Settings do not contain an env block."
    }
  }
  catch {
    Check-Fail "Settings are not valid JSON."
  }
}
else {
  Check-Fail "Settings are missing: $settingsPath"
}

$token = $null
if (-not [string]::IsNullOrWhiteSpace($env:ALGOMIM_API_KEY)) {
  $token = $env:ALGOMIM_API_KEY.Trim()
  if ($token -match '[\x00-\x1F\x7F]') {
    Check-Fail "ALGOMIM_API_KEY contains control characters."
    $token = $null
  }
  else {
    Check-Ok "Credential resolves from ALGOMIM_API_KEY."
  }
}
elseif (Test-Path -LiteralPath $credentialsPath -PathType Leaf) {
  try {
    $token = Get-AlgomimCredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
    if ($null -eq $token) {
      Check-Fail "Credential profile '$CredentialProfile' is missing or empty in $credentialsPath"
    }
    else {
      Check-Ok "Credential profile '$CredentialProfile' exists in shared Algomim credentials."
    }

    if (Test-CredentialFileAcl $credentialsPath) {
      Check-Ok "Credential file ACL is restricted."
    }
    else {
      Check-Fail "Credential file ACL is too broad. Run the installer again to repair it."
    }
  }
  catch {
    Check-Fail $_.Exception.Message
  }
}
else {
  Check-Fail "No credential is available through ALGOMIM_API_KEY or $credentialsPath"
}

$claudeConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
$userSettingsPath = Join-Path $claudeConfigDir "settings.json"
if (Test-Path -LiteralPath $userSettingsPath -PathType Leaf) {
  try {
    $userSettings = Get-Content -Raw -LiteralPath $userSettingsPath | ConvertFrom-Json
    if ($null -ne $userSettings.env) {
      foreach ($conflicting in @("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL")) {
        if (-not [string]::IsNullOrWhiteSpace([string] $userSettings.env.$conflicting)) {
          Check-Warn "Your Claude Code settings ($userSettingsPath) set env.$conflicting. It can conflict with Algomim sessions."
        }
      }
    }
  }
  catch {
    Check-Warn "Your Claude Code settings ($userSettingsPath) are not valid JSON. Claude Code may fail to start."
  }
}

if ($SkipApiCheck) {
  Check-Ok "Skipped live Model API check."
}
elseif ($null -ne $baseUrl -and $null -ne $token) {
  try {
    $headers = @{ Authorization = "Bearer $token" }
    $modelsUrl = "$($baseUrl.TrimEnd('/'))/v1/models"
    $response = Invoke-RestMethod -Method Get -Uri $modelsUrl -Headers $headers -TimeoutSec 20
    $modelIds = @($response.data | ForEach-Object { $_.id })
    if ($modelIds -contains "algomim") {
      Check-Ok "Model API responded and exposes algomim."
    }
    else {
      Check-Fail "Model API responded but does not expose algomim."
    }
  }
  catch {
    $statusCode = if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      [int] $_.Exception.Response.StatusCode
    }
    else {
      0
    }

    if ($statusCode -eq 401) {
      Check-Fail "Model API rejected the API key (HTTP 401)."
    }
    elseif ($statusCode -gt 0) {
      Check-Fail "Model API check failed (HTTP $statusCode)."
    }
    else {
      Check-Fail "Could not reach the Model API. Check network and the recorded base URL."
    }
  }
}

if ($failed) {
  if ($ThrowOnFailure) {
    throw "Algomim Claude Code doctor found one or more failures."
  }
  exit 1
}

exit 0
