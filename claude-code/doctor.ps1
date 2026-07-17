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
$claudeConfigDir = Join-Path $integrationHome "config"
$credentialsPath = Join-Path $AlgomimHome "credentials"
$minimumAlgomimCliVersion = $null

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
      if (([string] $releaseContract.minimumAlgomimCliVersion) -match '^\d+\.\d+\.\d+$') {
        $minimumAlgomimCliVersion = [version] ([string] $releaseContract.minimumAlgomimCliVersion)
      }
      else {
        Check-Fail "Installed release contract does not declare a valid minimum Algomim CLI version."
      }
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

if ($null -ne $minimumAlgomimCliVersion) {
  $cliStatePath = Join-Path $AlgomimHome "cli\state.json"
  try {
    $cliState = Get-Content -Raw -LiteralPath $cliStatePath | ConvertFrom-Json
    $installedCliVersion = [version] ([string] $cliState.version)
    if ($cliState.product -eq "algomim-cli" -and $installedCliVersion -ge $minimumAlgomimCliVersion) {
      Check-Ok "Algomim CLI $installedCliVersion supports isolated Claude Code sessions."
    }
    else {
      Check-Fail "Algomim CLI $minimumAlgomimCliVersion or newer is required. Run the current tag-pinned Claude Code installer once."
    }
  }
  catch {
    Check-Fail "Algomim CLI $minimumAlgomimCliVersion or newer is required. Run the current tag-pinned Claude Code installer once."
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
      Check-Ok "Settings select the Algomim model."
    }
    else {
      Check-Fail "Settings do not select algomim."
    }

    $availableModels = @($settings.availableModels)
    if ($availableModels.Count -eq 1 -and $availableModels[0] -eq "algomim") {
      Check-Ok "Settings expose only the Algomim model."
    }
    else {
      Check-Fail "Settings must allow only algomim."
    }

    if ($null -ne $settings.env) {
      foreach ($required in @(
          @{ Name = "ANTHROPIC_MODEL"; Expected = "algomim" },
          @{ Name = "ANTHROPIC_CUSTOM_MODEL_OPTION"; Expected = "algomim" },
          @{ Name = "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"; Expected = "Algomim" },
          @{ Name = "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"; Expected = "Algomim Model API" },
          @{ Name = "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"; Expected = "0" },
          @{ Name = "CLAUDE_CODE_DISABLE_1M_CONTEXT"; Expected = "1" },
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

      $defaultMappingsValid = $true
      foreach ($family in @("FABLE", "OPUS", "SONNET", "HAIKU")) {
        foreach ($mapping in @(
            @{ Suffix = "MODEL"; Expected = "algomim" },
            @{ Suffix = "MODEL_NAME"; Expected = "Algomim" },
            @{ Suffix = "MODEL_DESCRIPTION"; Expected = "Algomim Model API" }
          )) {
          $mappingName = "ANTHROPIC_DEFAULT_$($family)_$($mapping.Suffix)"
          if ([string] $settings.env.($mappingName) -cne $mapping.Expected) {
            Check-Fail "Settings do not set $mappingName to $($mapping.Expected)."
            $defaultMappingsValid = $false
          }
        }
      }
      if ($defaultMappingsValid) {
        Check-Ok "Settings map every Claude default family to Algomim."
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

if (Test-Path -LiteralPath $claudeConfigDir) {
  $configDirectory = Get-Item -LiteralPath $claudeConfigDir -Force
  if (-not $configDirectory.PSIsContainer) {
    Check-Fail "Isolated Claude Code config path is not a directory: $claudeConfigDir"
  }
  elseif ($configDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    Check-Fail "Isolated Claude Code config directory must not be a symbolic link or reparse point: $claudeConfigDir"
  }
  elseif (-not (Test-CredentialFileAcl $claudeConfigDir)) {
    Check-Fail "Isolated Claude Code config directory permissions are too broad: $claudeConfigDir"
  }
  else {
    Check-Ok "Claude Code user state is isolated at $claudeConfigDir"
  }
}
else {
  Check-Fail "Isolated Claude Code config directory is missing: $claudeConfigDir"
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

$normalClaudeConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
$normalClaudeSettingsPath = Join-Path $normalClaudeConfigDir "settings.json"
if (Test-Path -LiteralPath $normalClaudeSettingsPath -PathType Leaf) {
  try {
    $normalClaudeSettings = Get-Content -Raw -LiteralPath $normalClaudeSettingsPath | ConvertFrom-Json
    $normalClaudeModel = [string] $normalClaudeSettings.model
    if (@("algomim", "claude-algomim") -ccontains $normalClaudeModel) {
      Check-Warn "Normal Claude settings still select $normalClaudeModel from an earlier session: $normalClaudeSettingsPath. Remove the top-level model field to restore Claude's own default."
    }
  }
  catch {
    Check-Warn "Normal Claude settings are not valid JSON and were not modified: $normalClaudeSettingsPath"
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
