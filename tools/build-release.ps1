param(
  [string] $Version = "",
  [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$contractPath = Join-Path $repoRoot "codex\release.json"
$contract = Get-Content -Raw -LiteralPath $contractPath | ConvertFrom-Json
$catalogPath = Join-Path $repoRoot "codex\algomim-models.json"
$catalogLockPath = Join-Path $repoRoot "codex\algomim-models.lock.json"

if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf) -or -not (Test-Path -LiteralPath $catalogLockPath -PathType Leaf)) {
  throw "Generated Codex catalog or lock file is missing."
}
$catalogLock = Get-Content -Raw -LiteralPath $catalogLockPath | ConvertFrom-Json
$catalogHash = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (
  $catalogLock.schemaVersion -ne 1 -or
  $catalogLock.generator -ne "@algomim/inference/codex-model-catalog" -or
  $catalogLock.generatorVersion -ne 1 -or
  $catalogLock.catalogSha256 -ne $catalogHash
) {
  throw "Generated Codex catalog lock does not match algomim-models.json."
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = [string] $contract.version
}
$Version = $Version.Trim().TrimStart("v")
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "Version must use MAJOR.MINOR.PATCH format."
}
if ($contract.schemaVersion -ne 1 -or $contract.integration -ne "codex" -or $contract.version -ne $Version -or $contract.releaseTag -ne "v$Version") {
  throw "codex/release.json does not match version $Version."
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $repoRoot "dist"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("algomim-package-{0}" -f [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
  $windowsCodex = Join-Path $temporaryRoot "windows\codex"
  $posixCodex = Join-Path $temporaryRoot "posix\codex"
  New-Item -ItemType Directory -Path $windowsCodex -Force | Out-Null
  New-Item -ItemType Directory -Path $posixCodex -Force | Out-Null

  foreach ($name in @("algomim-models.json", "algomim-models.lock.json", "install.ps1", "update.ps1", "doctor.ps1", "uninstall.ps1", "release.json")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "codex\$name") -Destination (Join-Path $windowsCodex $name)
  }
  foreach ($name in @("algomim-models.json", "algomim-models.lock.json", "install.sh", "update.sh", "doctor.sh", "uninstall.sh", "release.json")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "codex\$name") -Destination (Join-Path $posixCodex $name)
  }

  $windowsName = "algomim-codex-windows-v$Version.zip"
  $posixName = "algomim-codex-posix-v$Version.tar.gz"
  $windowsPath = Join-Path $OutputDirectory $windowsName
  $posixPath = Join-Path $OutputDirectory $posixName
  foreach ($path in @($windowsPath, $posixPath)) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }

  Compress-Archive -Path (Join-Path $temporaryRoot "windows\codex") -DestinationPath $windowsPath -CompressionLevel Optimal
  & tar.exe -czf $posixPath -C (Join-Path $temporaryRoot "posix") codex
  if ($LASTEXITCODE -ne 0) {
    throw "Could not create the POSIX release archive."
  }

  $windowsHash = (Get-FileHash -LiteralPath $windowsPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $posixHash = (Get-FileHash -LiteralPath $posixPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $manifest = [ordered] @{
    schemaVersion = 1
    integration = "codex"
    version = $Version
    releaseTag = "v$Version"
    channel = [string] $contract.channel
    minimumCodexVersion = "0.144.1"
    artifacts = [ordered] @{
      windows = [ordered] @{
        file = $windowsName
        format = "zip"
        sha256 = $windowsHash
      }
      posix = [ordered] @{
        file = $posixName
        format = "tar.gz"
        sha256 = $posixHash
      }
    }
  }

  $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
  $manifestPath = Join-Path $OutputDirectory "manifest.json"
  [System.IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine), $utf8WithoutBom)
  $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $checksums = @(
    "$windowsHash  $windowsName",
    "$posixHash  $posixName",
    "$manifestHash  manifest.json"
  ) -join [Environment]::NewLine
  [System.IO.File]::WriteAllText((Join-Path $OutputDirectory "SHA256SUMS"), ($checksums + [Environment]::NewLine), $utf8WithoutBom)

  Write-Host "[algomim] Built release artifacts for v$Version in $OutputDirectory"
}
finally {
  if (Test-Path -LiteralPath $temporaryRoot) {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
  }
}
