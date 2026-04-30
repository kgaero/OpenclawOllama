[CmdletBinding()]
param(
  [string]$Distro = "Ubuntu",
  [string]$ProjectDir = "/home/kgaer/code/OpenclawOllama",
  [string]$Agent = "main",
  [string]$Session = "main",
  [switch]$SkipCleanup
)

$ErrorActionPreference = "Stop"

$cleanupValue = if ($SkipCleanup) { "1" } else { "0" }
$bashCommand = "cd '$ProjectDir' && chmod +x scripts/*.sh scripts/lib/*.sh && OPENCLAW_SKIP_STARTUP_CLEANUP=$cleanupValue ./scripts/12-start-openclaw.sh"

Write-Host "Starting OpenClaw in WSL distro '$Distro'..."
& wsl.exe -d $Distro -- bash -lc $bashCommand

if ($LASTEXITCODE -ne 0) {
  throw "OpenClaw startup failed in WSL distro '$Distro'."
}

$encodedSession = [System.Uri]::EscapeDataString("agent:${Agent}:${Session}")
$chatUrl = "http://127.0.0.1:18789/chat?session=$encodedSession"

Write-Host "Opening $chatUrl"
Start-Process $chatUrl
