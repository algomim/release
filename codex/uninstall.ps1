param(
  [string] $CodexHome = "",
  [string] $AlgomimHome = "",
  [string] $CredentialProfile = "",
  [switch] $RemoveCredential,
  [switch] $KeepKey
)

$ErrorActionPreference = "Stop"

function Remove-CredentialProfile {
  param(
    [string] $Path,
    [string] $Profile
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-Host "[algomim] Shared credentials file does not exist."
    return
  }

  if ((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Credential file cannot be a symbolic link or reparse point: $Path"
  }

  $output = New-Object 'System.Collections.Generic.List[string]'
  $inTargetSection = $false
  $targetFound = $false
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^\[([^\[\]]+)\]$') {
      $section = $Matches[1].Trim()
      $inTargetSection = $section -eq $Profile
      if ($inTargetSection) {
        $targetFound = $true
        continue
      }
    }

    if (-not $inTargetSection) {
      $output.Add($line)
    }
  }

  if (-not $targetFound) {
    Write-Host "[algomim] Credential profile '$Profile' was not present."
    return
  }

  $meaningfulLines = @($output | Where-Object {
      $value = $_.Trim()
      $value.Length -gt 0 -and -not $value.StartsWith("#") -and -not $value.StartsWith(";")
    })
  if ($meaningfulLines.Count -eq 0) {
    Remove-Item -LiteralPath $Path -Force
    Write-Host "[algomim] Removed credential profile '$Profile' and the empty credentials file."
    return
  }

  while ($output.Count -gt 0 -and $output[$output.Count - 1].Trim().Length -eq 0) {
    $output.RemoveAt($output.Count - 1)
  }

  $content = [string]::Join([Environment]::NewLine, $output) + [Environment]::NewLine
  $directory = Split-Path -Parent $Path
  $temporaryPath = Join-Path $directory (".credentials.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
  $backupPath = Join-Path $directory (".credentials.{0}.bak" -f [Guid]::NewGuid().ToString("N"))
  try {
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporaryPath, $content, $utf8WithoutBom)
    $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $temporaryPath /inheritance:r /grant:r "*$currentUserSid`:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Could not secure the updated credentials file."
    }
    [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
    Remove-Item -LiteralPath $backupPath -Force
    & icacls.exe $Path /inheritance:r /grant:r "*$currentUserSid`:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Could not secure the updated credentials file."
    }
  }
  finally {
    if (Test-Path -LiteralPath $temporaryPath) {
      Remove-Item -LiteralPath $temporaryPath -Force
    }
    if (Test-Path -LiteralPath $backupPath) {
      Remove-Item -LiteralPath $backupPath -Force
    }
  }

  Write-Host "[algomim] Removed credential profile '$Profile'."
}

if ([string]::IsNullOrWhiteSpace($AlgomimHome)) {
  $AlgomimHome = if ($env:ALGOMIM_HOME) { $env:ALGOMIM_HOME } else { Join-Path $HOME ".algomim" }
}
$AlgomimHome = [System.IO.Path]::GetFullPath($AlgomimHome)
$integrationHome = [System.IO.Path]::GetFullPath((Join-Path $AlgomimHome "integrations\codex"))
$statePath = Join-Path $integrationHome "state.json"
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
  try {
    $candidateState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($candidateState.schemaVersion -eq 1 -and $candidateState.integration -eq "codex") {
      $state = $candidateState
    }
    else {
      Write-Warning "Ignoring unsupported Codex installation state."
    }
  }
  catch {
    Write-Warning "Ignoring invalid Codex installation state."
  }
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
  throw "Credential profile name is invalid."
}

$paths = @(
  (Join-Path $CodexHome "algomim.config.toml"),
  (Join-Path $CodexHome "algomim-models.json"),
  (Join-Path $CodexHome "algomim-models.lock.json"),
  (Join-Path $CodexHome "algomim-auth.ps1")
)
foreach ($path in $paths) {
  if (Test-Path -LiteralPath $path) {
    Remove-Item -LiteralPath $path -Force
    Write-Host "[algomim] Removed $path"
  }
}

if ($KeepKey) {
  Write-Warning "-KeepKey is no longer required; credentials are preserved by default."
}

$legacyKeyPath = Join-Path $CodexHome "algomim.key"
$credentialsPath = Join-Path $AlgomimHome "credentials"
if ($RemoveCredential) {
  Remove-CredentialProfile -Path $credentialsPath -Profile $CredentialProfile
  if (Test-Path -LiteralPath $legacyKeyPath) {
    Remove-Item -LiteralPath $legacyKeyPath -Force
    Write-Host "[algomim] Removed the legacy Codex key file."
  }
}
else {
  Write-Host "[algomim] Kept shared Algomim credential profile '$CredentialProfile'."
  if (Test-Path -LiteralPath $legacyKeyPath) {
    Write-Warning "A legacy Codex key remains. Re-run the installer to migrate it."
  }
}

$expectedPrefix = $AlgomimHome.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $integrationHome.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Codex integration path is outside ALGOMIM_HOME."
}
if (Test-Path -LiteralPath $integrationHome -PathType Container) {
  Remove-Item -LiteralPath $integrationHome -Recurse -Force
  Write-Host "[algomim] Removed Codex integration lifecycle and state files."
}

Write-Host "[algomim] Normal Codex configuration was not modified."
