param(
  [string] $Version = "",
  [string] $OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$contractPath = Join-Path $repoRoot "codex\release.json"
$contract = Get-Content -Raw -LiteralPath $contractPath | ConvertFrom-Json
$cliContractPath = Join-Path $repoRoot "cli\release.json"
$cliContract = Get-Content -Raw -LiteralPath $cliContractPath | ConvertFrom-Json
$claudeCodeContractPath = Join-Path $repoRoot "claude-code\release.json"
$claudeCodeContract = Get-Content -Raw -LiteralPath $claudeCodeContractPath | ConvertFrom-Json
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
if ($cliContract.schemaVersion -ne 1 -or $cliContract.product -ne "algomim-cli" -or $cliContract.version -ne $Version -or $cliContract.releaseTag -ne "v$Version") {
  throw "cli/release.json does not match version $Version."
}
if ($claudeCodeContract.schemaVersion -ne 1 -or $claudeCodeContract.integration -ne "claude-code" -or $claudeCodeContract.version -ne $Version -or $claudeCodeContract.releaseTag -ne "v$Version") {
  throw "claude-code/release.json does not match version $Version."
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
  $windowsClaudeCode = Join-Path $temporaryRoot "windows\claude-code"
  $windowsCli = Join-Path $temporaryRoot "windows\cli"
  $windowsShared = Join-Path $temporaryRoot "windows\shared"
  $posixCodex = Join-Path $temporaryRoot "posix\codex"
  $posixClaudeCode = Join-Path $temporaryRoot "posix\claude-code"
  $posixCli = Join-Path $temporaryRoot "posix\cli"
  $posixShared = Join-Path $temporaryRoot "posix\shared"
  New-Item -ItemType Directory -Path $windowsCodex -Force | Out-Null
  New-Item -ItemType Directory -Path $windowsClaudeCode, $windowsCli, $windowsShared -Force | Out-Null
  New-Item -ItemType Directory -Path $posixCodex -Force | Out-Null
  New-Item -ItemType Directory -Path $posixClaudeCode, $posixCli, $posixShared -Force | Out-Null

  foreach ($name in @("algomim-models.json", "algomim-models.lock.json", "install.ps1", "update.ps1", "doctor.ps1", "uninstall.ps1", "release.json")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "codex\$name") -Destination (Join-Path $windowsCodex $name)
  }
  foreach ($name in @("algomim-models.json", "algomim-models.lock.json", "install.sh", "update.sh", "doctor.sh", "uninstall.sh", "release.json")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "codex\$name") -Destination (Join-Path $posixCodex $name)
  }
  foreach ($name in @("install.ps1", "update.ps1", "doctor.ps1", "uninstall.ps1", "release.json")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "claude-code\$name") -Destination (Join-Path $windowsClaudeCode $name)
  }
  foreach ($name in @("install.sh", "update.sh", "doctor.sh", "uninstall.sh", "release.json")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "claude-code\$name") -Destination (Join-Path $posixClaudeCode $name)
  }
  foreach ($name in @("algomim.ps1", "algomim.cmd", "install.ps1", "release.json")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "cli\$name") -Destination (Join-Path $windowsCli $name)
  }
  foreach ($name in @("algomim.sh", "install.sh", "release.json")) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "cli\$name") -Destination (Join-Path $posixCli $name)
  }
  Copy-Item -LiteralPath (Join-Path $repoRoot "shared\credential-store.ps1") -Destination (Join-Path $windowsShared "credential-store.ps1")
  Copy-Item -LiteralPath (Join-Path $repoRoot "shared\credential-store.sh") -Destination (Join-Path $posixShared "credential-store.sh")

  $windowsName = "algomim-codex-windows-v$Version.zip"
  $posixName = "algomim-codex-posix-v$Version.tar.gz"
  $windowsClaudeCodeName = "algomim-claude-code-windows-v$Version.zip"
  $posixClaudeCodeName = "algomim-claude-code-posix-v$Version.tar.gz"
  $windowsCliName = "algomim-cli-windows-v$Version.zip"
  $posixCliName = "algomim-cli-posix-v$Version.tar.gz"
  $windowsPath = Join-Path $OutputDirectory $windowsName
  $posixPath = Join-Path $OutputDirectory $posixName
  $windowsClaudeCodePath = Join-Path $OutputDirectory $windowsClaudeCodeName
  $posixClaudeCodePath = Join-Path $OutputDirectory $posixClaudeCodeName
  $windowsCliPath = Join-Path $OutputDirectory $windowsCliName
  $posixCliPath = Join-Path $OutputDirectory $posixCliName
  foreach ($path in @($windowsPath, $posixPath, $windowsClaudeCodePath, $posixClaudeCodePath, $windowsCliPath, $posixCliPath)) {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force
    }
  }

  Compress-Archive -Path @(
    (Join-Path $temporaryRoot "windows\codex"),
    (Join-Path $temporaryRoot "windows\shared")
  ) -DestinationPath $windowsPath -CompressionLevel Optimal
  Compress-Archive -Path @(
    (Join-Path $temporaryRoot "windows\claude-code"),
    (Join-Path $temporaryRoot "windows\shared")
  ) -DestinationPath $windowsClaudeCodePath -CompressionLevel Optimal
  Compress-Archive -Path (Join-Path $temporaryRoot "windows\*") -DestinationPath $windowsCliPath -CompressionLevel Optimal
  & tar.exe -czf $posixPath -C (Join-Path $temporaryRoot "posix") codex shared
  if ($LASTEXITCODE -ne 0) {
    throw "Could not create the POSIX release archive."
  }
  & tar.exe -czf $posixClaudeCodePath -C (Join-Path $temporaryRoot "posix") claude-code shared
  if ($LASTEXITCODE -ne 0) {
    throw "Could not create the POSIX Claude Code release archive."
  }
  & tar.exe -czf $posixCliPath -C (Join-Path $temporaryRoot "posix") codex claude-code cli shared
  if ($LASTEXITCODE -ne 0) {
    throw "Could not create the POSIX CLI release archive."
  }

  $windowsHash = (Get-FileHash -LiteralPath $windowsPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $posixHash = (Get-FileHash -LiteralPath $posixPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $windowsClaudeCodeHash = (Get-FileHash -LiteralPath $windowsClaudeCodePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $posixClaudeCodeHash = (Get-FileHash -LiteralPath $posixClaudeCodePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $windowsCliHash = (Get-FileHash -LiteralPath $windowsCliPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $posixCliHash = (Get-FileHash -LiteralPath $posixCliPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $manifest = [ordered] @{
    schemaVersion = 1
    integration = "codex"
    version = $Version
    releaseTag = "v$Version"
    channel = [string] $contract.channel
    minimumCodexVersion = "0.144.1"
    minimumClaudeCodeVersion = "2.1.200"
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
    claudeCodeArtifacts = [ordered] @{
      windows = [ordered] @{
        file = $windowsClaudeCodeName
        format = "zip"
        sha256 = $windowsClaudeCodeHash
      }
      posix = [ordered] @{
        file = $posixClaudeCodeName
        format = "tar.gz"
        sha256 = $posixClaudeCodeHash
      }
    }
    cliArtifacts = [ordered] @{
      windows = [ordered] @{
        file = $windowsCliName
        format = "zip"
        sha256 = $windowsCliHash
      }
      posix = [ordered] @{
        file = $posixCliName
        format = "tar.gz"
        sha256 = $posixCliHash
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
    "$windowsClaudeCodeHash  $windowsClaudeCodeName",
    "$posixClaudeCodeHash  $posixClaudeCodeName",
    "$windowsCliHash  $windowsCliName",
    "$posixCliHash  $posixCliName",
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
