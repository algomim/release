$ErrorActionPreference = "Stop"

function Assert-AlgomimCredentialProfileName {
  param([Parameter(Mandatory = $true)][string] $Value)

  if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw "Credential profile must start with a letter or number and contain at most 64 letters, numbers, dots, underscores, or hyphens."
  }
}

function Normalize-AlgomimApiKey {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value)

  $normalized = $Value.Trim()
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    throw "API key cannot be empty."
  }
  if ($normalized -match '[\x00-\x1F\x7F]') {
    throw "API key cannot contain control characters."
  }

  return $normalized
}

function Read-AlgomimSecretPlainText {
  param([Parameter(Mandatory = $true)][string] $Prompt)

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

function Read-AlgomimRequiredSecretPlainText {
  param([Parameter(Mandatory = $true)][string] $Prompt)

  while ($true) {
    try {
      return Normalize-AlgomimApiKey (Read-AlgomimSecretPlainText $Prompt)
    }
    catch {
      Write-Warning "API key cannot be empty or contain control characters. Press Ctrl+C to cancel."
    }
  }
}

function Get-AlgomimCredentialApiKey {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string] $Profile
  )

  Assert-AlgomimCredentialProfileName $Profile
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  if ((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    throw "Credential file cannot be a symbolic link or reparse point: $Path"
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
      $value = Normalize-AlgomimApiKey $Matches[1]
    }
  }

  return $value
}

function Protect-AlgomimCredentialDirectory {
  param([Parameter(Mandatory = $true)][string] $Path)

  $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & icacls.exe $Path /inheritance:r /grant:r "*$currentUserSid`:(OI)(CI)(F)" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Could not secure Algomim credential directory: $Path"
  }
}

function Protect-AlgomimCredentialFile {
  param([Parameter(Mandatory = $true)][string] $Path)

  $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & icacls.exe $Path /inheritance:r /grant:r "*$currentUserSid`:(F)" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Could not secure Algomim credentials file: $Path"
  }
}

function Write-AlgomimSecureTextFileAtomically {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Content
  )

  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  Protect-AlgomimCredentialDirectory $directory
  if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Credential file cannot be a symbolic link or reparse point: $Path"
  }

  $temporaryPath = Join-Path $directory (".credentials.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
  $backupPath = Join-Path $directory (".credentials.{0}.bak" -f [Guid]::NewGuid().ToString("N"))
  try {
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporaryPath, $Content, $utf8WithoutBom)
    Protect-AlgomimCredentialFile $temporaryPath
    if (Test-Path -LiteralPath $Path) {
      [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
      Remove-Item -LiteralPath $backupPath -Force
    }
    else {
      [System.IO.File]::Move($temporaryPath, $Path)
    }
    Protect-AlgomimCredentialFile $Path
  }
  finally {
    foreach ($candidate in @($temporaryPath, $backupPath)) {
      if (Test-Path -LiteralPath $candidate) {
        Remove-Item -LiteralPath $candidate -Force
      }
    }
  }
}

function Set-AlgomimCredentialApiKey {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string] $Profile,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value
  )

  Assert-AlgomimCredentialProfileName $Profile
  $normalized = Normalize-AlgomimApiKey $Value
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
      $inTargetSection = $Matches[1].Trim() -eq $Profile
      $targetSectionFound = $targetSectionFound -or $inTargetSection
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
  }
  if (-not $targetSectionFound) {
    if ($output.Count -gt 0 -and $output[$output.Count - 1].Length -gt 0) {
      $output.Add("")
    }
    $output.Add("[$Profile]")
    $output.Add("api_key = $normalized")
  }

  Write-AlgomimSecureTextFileAtomically -Path $Path -Content ([string]::Join([Environment]::NewLine, $output) + [Environment]::NewLine)
  if ((Get-AlgomimCredentialApiKey -Path $Path -Profile $Profile) -cne $normalized) {
    throw "Credential verification failed after writing profile '$Profile'."
  }
}

function Remove-AlgomimCredentialProfile {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string] $Profile
  )

  Assert-AlgomimCredentialProfileName $Profile
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return "missing"
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
      $inTargetSection = $Matches[1].Trim() -eq $Profile
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
    return "missing"
  }

  $meaningfulLines = @($output | Where-Object {
      $line = $_.Trim()
      $line.Length -gt 0 -and -not $line.StartsWith("#") -and -not $line.StartsWith(";")
    })
  if ($meaningfulLines.Count -eq 0) {
    Remove-Item -LiteralPath $Path -Force
    return "removed-empty"
  }
  while ($output.Count -gt 0 -and $output[$output.Count - 1].Trim().Length -eq 0) {
    $output.RemoveAt($output.Count - 1)
  }
  Write-AlgomimSecureTextFileAtomically -Path $Path -Content ([string]::Join([Environment]::NewLine, $output) + [Environment]::NewLine)
  return "removed"
}
