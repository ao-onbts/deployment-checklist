[CmdletBinding()]
param(
    [string]$ImageTag = "latest",

    [switch]$AlsoTagLatest,

    [string]$EnvFile = ".env.synology"
)

$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot
$image    = "ghcr.io/ao-onbts/deployment-checklist"
$taggedImage = "${image}:${ImageTag}"
$latestImage = "${image}:latest"
$dockerfile  = Join-Path $repoRoot "Dockerfile"

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)] [string]$Label,
        [Parameter(Mandatory = $true)] [scriptblock]$Action
    )
    Write-Host "==> $Label" -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE" }
}

# ── Load GHCR credentials from env file ────────────────────────────────────────
$envPath = Join-Path $repoRoot $EnvFile
if (Test-Path $envPath) {
    Get-Content $envPath | Where-Object { $_ -match '^\s*GHCR_(USER|PAT)\s*=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        [System.Environment]::SetEnvironmentVariable($kv[0].Trim(), $kv[1].Trim())
    }
} else {
    Write-Warning "Env file not found: $envPath — skipping docker login (assuming pre-authenticated)."
}

if ($env:GHCR_PAT -and $env:GHCR_USER) {
    Invoke-Step "Log in to ghcr.io as $($env:GHCR_USER)" {
        $env:GHCR_PAT | docker login ghcr.io -u $env:GHCR_USER --password-stdin
    }
}

# ── Build ───────────────────────────────────────────────────────────────────────
Invoke-Step "Build $taggedImage" {
    docker build -f $dockerfile -t $taggedImage $repoRoot
}

if ($AlsoTagLatest -and $ImageTag -ne "latest") {
    Invoke-Step "Tag as latest" {
        docker tag $taggedImage $latestImage
    }
}

# ── Push ────────────────────────────────────────────────────────────────────────
Invoke-Step "Push $taggedImage" {
    docker push $taggedImage
}

if ($AlsoTagLatest -and $ImageTag -ne "latest") {
    Invoke-Step "Push latest" {
        docker push $latestImage
    }
}

Write-Host ""
Write-Host "Published successfully:" -ForegroundColor Green
Write-Host "  $taggedImage"
if ($AlsoTagLatest -and $ImageTag -ne "latest") {
    Write-Host "  $latestImage"
}
