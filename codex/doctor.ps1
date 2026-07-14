param(
  [string] $CodexHome = ""
)

$ErrorActionPreference = "Stop"
$failed = $false

function Check-Ok {
  param([string] $Message)
  Write-Host "[ok] $Message"
}

function Check-Fail {
  param([string] $Message)
  Write-Host "[fail] $Message" -ForegroundColor Red
  $script:failed = $true
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
  $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
}

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$profilePath = Join-Path $CodexHome "algomim.config.toml"
$catalogPath = Join-Path $CodexHome "algomim-models.json"
$keyPath = Join-Path $CodexHome "algomim.key"
$authScriptPath = Join-Path $CodexHome "algomim-auth.ps1"

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

if (Test-Path -LiteralPath $authScriptPath) {
  Check-Ok "Auth helper exists."
}
else {
  Check-Fail "Auth helper is missing: $authScriptPath"
}

if (Test-Path -LiteralPath $keyPath) {
  $token = (Get-Content -Raw -LiteralPath $keyPath).Trim()
  if ([string]::IsNullOrWhiteSpace($token)) {
    Check-Fail "API key file is empty."
  }
  else {
    Check-Ok "API key file exists."
  }
}
else {
  Check-Fail "API key file is missing: $keyPath"
}

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

  $baseUrlMatch = [regex]::Match($profile, 'base_url\s*=\s*"([^"]+)"')
  if ($baseUrlMatch.Success) {
    $baseUrl = $baseUrlMatch.Groups[1].Value
    Check-Ok "Profile base_url is set to $baseUrl"

    if ((Test-Path -LiteralPath $keyPath) -and -not [string]::IsNullOrWhiteSpace((Get-Content -Raw -LiteralPath $keyPath).Trim())) {
      try {
        $headers = @{ Authorization = "Bearer $((Get-Content -Raw -LiteralPath $keyPath).Trim())" }
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
  }
  else {
    Check-Fail "Profile base_url is missing."
  }
}

if ($failed) {
  exit 1
}

exit 0
