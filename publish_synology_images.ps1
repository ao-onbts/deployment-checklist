[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RegistryRepoPrefix,

    [string]$ImageTag = "latest",

    [switch]$Push = $true,

    [switch]$AlsoTagLatest
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$apiDockerfile = Join-Path $repoRoot "infra/docker/api.Dockerfile"
$uiDockerfile = Join-Path $repoRoot "infra/docker/ui.Dockerfile"
$migratorDockerfile = Join-Path $repoRoot "infra/docker/migrator.Dockerfile"

$apiImage = "$RegistryRepoPrefix/versiontrack-api:$ImageTag"
$uiImage = "$RegistryRepoPrefix/versiontrack-ui:$ImageTag"
$migratorImage = "$RegistryRepoPrefix/versiontrack-migrator:$ImageTag"
$apiLatestImage = "$RegistryRepoPrefix/versiontrack-api:latest"
$uiLatestImage = "$RegistryRepoPrefix/versiontrack-ui:latest"
$migratorLatestImage = "$RegistryRepoPrefix/versiontrack-migrator:latest"

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-Host "==> $Label" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

Invoke-Step "Build API image $apiImage" {
    docker build -f $apiDockerfile -t $apiImage $repoRoot
}

Invoke-Step "Build UI image $uiImage" {
    docker build -f $uiDockerfile -t $uiImage $repoRoot
}

Invoke-Step "Build migrator image $migratorImage" {
    docker build -f $migratorDockerfile -t $migratorImage $repoRoot
}

if ($AlsoTagLatest -and $ImageTag -ne "latest") {
    Invoke-Step "Tag API latest alias" {
        docker tag $apiImage $apiLatestImage
    }
    Invoke-Step "Tag UI latest alias" {
        docker tag $uiImage $uiLatestImage
    }
    Invoke-Step "Tag migrator latest alias" {
        docker tag $migratorImage $migratorLatestImage
    }
}

if ($Push) {
    Invoke-Step "Push API image" {
        docker push $apiImage
    }
    Invoke-Step "Push UI image" {
        docker push $uiImage
    }
    Invoke-Step "Push migrator image" {
        docker push $migratorImage
    }

    if ($AlsoTagLatest -and $ImageTag -ne "latest") {
        Invoke-Step "Push API latest alias" {
            docker push $apiLatestImage
        }
        Invoke-Step "Push UI latest alias" {
            docker push $uiLatestImage
        }
        Invoke-Step "Push migrator latest alias" {
            docker push $migratorLatestImage
        }
    }
}

Write-Host ""
Write-Host "Images ready:" -ForegroundColor Green
Write-Host "  API     : $apiImage"
Write-Host "  UI      : $uiImage"
Write-Host "  Migrator: $migratorImage"
if ($AlsoTagLatest -and $ImageTag -ne "latest") {
    Write-Host "  API latest     : $apiLatestImage"
    Write-Host "  UI latest      : $uiLatestImage"
    Write-Host "  Migrator latest: $migratorLatestImage"
}