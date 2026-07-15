param(
  [string] $CodexHome = "",
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
        throw "Credential profile '$Profile' contains duplicate api_key entries."
      }
      $value = $Matches[1].Trim()
    }
  }

  if ([string]::IsNullOrWhiteSpace($value)) {
    return $null
  }
  if ($value -match '[\x00-\x1F\x7F]') {
    throw "Credential profile '$Profile' contains an invalid api_key."
  }
  return $value
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
$integrationHome = Join-Path $AlgomimHome "integrations\codex"
$statePath = Join-Path $integrationHome "state.json"
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  try {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
  }
  catch {
    Check-Fail "Codex installation state is not valid JSON."
  }
}
else {
  Check-Fail "Codex installation state is missing: $statePath"
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
  $CodexHome = if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.codexHome)) {
    [string] $state.codexHome
  }
  elseif ($env:CODEX_HOME) {
    $env:CODEX_HOME
  }
  else {
    Join-Path $HOME ".codex"
  }
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

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$CredentialProfile = $CredentialProfile.Trim()
if ($CredentialProfile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
  Check-Fail "Credential profile name is invalid."
}

$profilePath = Join-Path $CodexHome "algomim.config.toml"
$catalogPath = Join-Path $CodexHome "algomim-models.json"
$catalogLockPath = Join-Path $CodexHome "algomim-models.lock.json"
$legacyKeyPath = Join-Path $CodexHome "algomim.key"
$authScriptPath = Join-Path $CodexHome "algomim-auth.ps1"
$credentialsPath = Join-Path $AlgomimHome "credentials"

if ($null -ne $state) {
  if ($state.schemaVersion -eq 1 -and $state.integration -eq "codex" -and ([string] $state.version) -match '^\d+\.\d+\.\d+$') {
    Check-Ok "Installation state reports Codex integration version $($state.version)."
  }
  else {
    Check-Fail "Codex installation state has an unsupported contract."
  }

  if ([string]::IsNullOrWhiteSpace($state.codexHome)) {
    Check-Fail "Installation state does not contain CODEX_HOME."
  }
  elseif ([System.IO.Path]::GetFullPath([string] $state.codexHome) -ne $CodexHome) {
    Check-Fail "Installation state points to a different CODEX_HOME."
  }

  $releaseContractPath = Join-Path $integrationHome "release.json"
  try {
    $releaseContract = Get-Content -Raw -LiteralPath $releaseContractPath | ConvertFrom-Json
    if ($releaseContract.integration -eq "codex" -and $releaseContract.version -eq $state.version) {
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

if (Get-Command codex -ErrorAction SilentlyContinue) {
  Check-Ok "Codex CLI is available."
}
else {
  Check-Fail "Codex CLI is not available on PATH."
}

if (Test-Path -LiteralPath $profilePath) {
  Check-Ok "Profile exists: $profilePath"
}
else {
  Check-Fail "Profile is missing: $profilePath"
}

if (Test-Path -LiteralPath $catalogPath) {
  try {
    $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
    $modelIds = @($catalog.models | ForEach-Object { $_.slug })
    if ($modelIds -contains "algomim") {
      Check-Ok "Model catalog contains algomim."
    }
    else {
      Check-Fail "Model catalog does not contain algomim."
    }
  }
  catch {
    Check-Fail "Model catalog is not valid JSON."
  }
}
else {
  Check-Fail "Model catalog is missing: $catalogPath"
}

if (
  (Test-Path -LiteralPath $catalogLockPath -PathType Leaf) -and
  (Test-Path -LiteralPath $catalogPath -PathType Leaf)
) {
  try {
    $catalogLock = Get-Content -Raw -LiteralPath $catalogLockPath | ConvertFrom-Json
    $catalogHash = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (
      $catalogLock.schemaVersion -eq 1 -and
      $catalogLock.generator -eq "@algomim/inference/codex-model-catalog" -and
      $catalogLock.generatorVersion -eq 1 -and
      $catalogLock.catalogSha256 -ceq $catalogHash
    ) {
      Check-Ok "Model catalog checksum is valid."
    }
    else {
      Check-Fail "Model catalog checksum does not match its lock file."
    }
  }
  catch {
    Check-Fail "Model catalog lock is not valid JSON."
  }
}
else {
  Check-Fail "Model catalog lock is missing: $catalogLockPath"
}

if (Test-Path -LiteralPath $authScriptPath) {
  Check-Ok "Auth helper exists."
}
else {
  Check-Fail "Auth helper is missing: $authScriptPath"
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
    $token = Get-CredentialApiKey -Path $credentialsPath -Profile $CredentialProfile
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

if (Test-Path -LiteralPath $legacyKeyPath) {
  Check-Warn "Legacy credential remains at $legacyKeyPath. Run the installer to migrate it."
}

if ((Test-Path -LiteralPath $authScriptPath) -and $null -ne $token) {
  try {
    $resolved = (& $authScriptPath | Out-String).Trim()
    if ($resolved -ceq $token) {
      Check-Ok "Auth helper resolves the selected credential."
    }
    else {
      Check-Fail "Auth helper resolved a different credential source than doctor."
    }
  }
  catch {
    Check-Fail "Auth helper could not resolve a credential."
  }
}

$baseUrl = $null
if (Test-Path -LiteralPath $profilePath) {
  $profile = Get-Content -Raw -LiteralPath $profilePath

  if ($profile -match '(?m)^model\s*=\s*"algomim"\s*$') {
    Check-Ok "Profile selects the algomim model."
  }
  else {
    Check-Fail "Profile does not select the algomim model."
  }

  if ($profile -match '(?m)^model_provider\s*=\s*"algomim"\s*$') {
    Check-Ok "Profile selects the Algomim provider."
  }
  else {
    Check-Fail "Profile does not select the Algomim provider."
  }

  if ($profile -match '(?m)^wire_api\s*=\s*"responses"\s*$') {
    Check-Ok "Profile uses the Responses wire API."
  }
  else {
    Check-Fail "Profile does not use the Responses wire API."
  }

  $featuresSection = [regex]::Match(
    $profile,
    '(?ms)^\[features\][^\S\r\n]*\r?\n(?<body>.*?)(?=^\[|\z)'
  )
  if (
    $featuresSection.Success -and
    $featuresSection.Groups["body"].Value -match '(?m)^personality\s*=\s*false\s*$'
  ) {
    Check-Ok "Profile disables unsupported Codex personality injection."
  }
  else {
    Check-Fail "Profile does not disable unsupported Codex personality injection."
  }

  $baseUrlMatch = [regex]::Match($profile, 'base_url\s*=\s*"([^"]+)"')
  if ($baseUrlMatch.Success) {
    $baseUrl = $baseUrlMatch.Groups[1].Value
    Check-Ok "Profile base_url is set to $baseUrl"
  }
  else {
    Check-Fail "Profile base_url is missing."
  }
}

if ($SkipApiCheck) {
  Check-Ok "Skipped live Model API check."
}
elseif ($null -ne $baseUrl -and $null -ne $token) {
  try {
    $headers = @{ Authorization = "Bearer $token" }
    $modelsUrl = "$($baseUrl.TrimEnd('/'))/models"
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
      Check-Fail "Could not reach the Model API. Check network and base_url."
    }
  }
}

if ($failed) {
  if ($ThrowOnFailure) {
    throw "Algomim Codex doctor found one or more failures."
  }
  exit 1
}

exit 0
