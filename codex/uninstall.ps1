param(
  [string] $CodexHome = "",
  [switch] $KeepKey
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
  $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
}

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)

$paths = @(
  (Join-Path $CodexHome "algomim.config.toml"),
  (Join-Path $CodexHome "algomim-models.json"),
  (Join-Path $CodexHome "algomim-auth.ps1")
)

if (-not $KeepKey) {
  $paths += (Join-Path $CodexHome "algomim.key")
}

foreach ($path in $paths) {
  if (Test-Path -LiteralPath $path) {
    Remove-Item -LiteralPath $path -Force
    Write-Host "[algomim] Removed $path"
  }
}

if ($KeepKey) {
  Write-Host "[algomim] Kept API key file."
}
else {
  Write-Host "[algomim] Removed API key file."
}

Write-Host "[algomim] Normal Codex configuration was not modified."

