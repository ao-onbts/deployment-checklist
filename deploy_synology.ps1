[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$NasHost,

    [Parameter(Mandatory = $true)]
    [string]$NasUser,

    [int]$NasSshPort = 22,

    [ValidateSet("Registry", "Archive")]
    [string]$Mode = "Registry",

    [string]$NasProjectPath = "/volume1/docker/versiontrack",

    [string]$LocalComposeFile = "docker-compose.synology.images.yml",

    [string]$LocalEnvFile = ".env.synology.images",

    [string]$RemoteComposeFile = "docker-compose.synology.images.yml",

    [string]$RemoteEnvFile = ".env.synology.images",

    [string]$RegistryRepoPrefix = "ghcr.io/example",

    [string]$ImageTag = "latest",

    [ValidateSet("ensure-schema", "bootstrap-local", "seed-sample-data", "seed-baselines", "status")]
    [string]$MigratorCommand = "ensure-schema",

    [switch]$RemoveOrphans,

    [switch]$UseSudo,

    [string]$NasDockerBinary = "/usr/local/bin/docker",

    [string]$ArtifactDirectory = ".artifacts/synology"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$composePath = Join-Path $repoRoot $LocalComposeFile
$envPath = Join-Path $repoRoot $LocalEnvFile
$artifactPath = Join-Path $repoRoot $ArtifactDirectory
$apiImage = "$RegistryRepoPrefix/versiontrack-api:$ImageTag"
$uiImage = "$RegistryRepoPrefix/versiontrack-ui:$ImageTag"
$migratorImage = "$RegistryRepoPrefix/versiontrack-migrator:$ImageTag"
$apiArchive = "versiontrack-api-$ImageTag.tar"
$uiArchive = "versiontrack-ui-$ImageTag.tar"
$migratorArchive = "versiontrack-migrator-$ImageTag.tar"
$remoteTarget = "$NasUser@$NasHost"
$sshArgs = @('-p', $NasSshPort, $remoteTarget)
$scpArgs = @('-O', '-P', $NasSshPort)
$dockerCommand = if ($UseSudo) { "sudo -n $NasDockerBinary" } else { $NasDockerBinary }
$removeOrphansFlag = if ($RemoveOrphans) { " --remove-orphans" } else { "" }

function Assert-PathExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-Host "==> $Label" -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Copy-ToNas {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Items
    )

    foreach ($item in $Items) {
        Invoke-Step "Upload $(Split-Path -Leaf $item)" {
            scp @scpArgs $item "$remoteTarget`:$NasProjectPath/"
        }
    }
}

Assert-PathExists -Path $composePath -Label "Compose file"
Assert-PathExists -Path $envPath -Label "Environment file"

Invoke-Step "Ensure NAS project folder exists" {
    ssh @sshArgs "mkdir -p '$NasProjectPath'"
}

Copy-ToNas -Items @($composePath, $envPath)

$remoteLines = @(
    "set -e",
    "cd '$NasProjectPath'"
)

if ($Mode -eq "Archive") {
    New-Item -ItemType Directory -Force -Path $artifactPath | Out-Null
    $apiArchivePath = Join-Path $artifactPath $apiArchive
    $uiArchivePath = Join-Path $artifactPath $uiArchive
    $migratorArchivePath = Join-Path $artifactPath $migratorArchive

    Invoke-Step "Export API archive $apiArchivePath" {
        docker image save -o $apiArchivePath $apiImage
    }
    Invoke-Step "Export UI archive $uiArchivePath" {
        docker image save -o $uiArchivePath $uiImage
    }
    Invoke-Step "Export migrator archive $migratorArchivePath" {
        docker image save -o $migratorArchivePath $migratorImage
    }

    Copy-ToNas -Items @($apiArchivePath, $uiArchivePath, $migratorArchivePath)

    $remoteLines += "$dockerCommand image load -i '$NasProjectPath/$apiArchive'"
    $remoteLines += "$dockerCommand image load -i '$NasProjectPath/$uiArchive'"
    $remoteLines += "$dockerCommand image load -i '$NasProjectPath/$migratorArchive'"
    $remoteLines += "$dockerCommand compose --env-file '$RemoteEnvFile' -f '$RemoteComposeFile' pull versiontrack-db"
}
else {
    $remoteLines += "$dockerCommand compose --env-file '$RemoteEnvFile' -f '$RemoteComposeFile' pull versiontrack-db versiontrack-migrator versiontrack-api versiontrack-ui"
}

$remoteLines += "$dockerCommand compose --env-file '$RemoteEnvFile' -f '$RemoteComposeFile' up -d$removeOrphansFlag versiontrack-db"
$remoteLines += "$dockerCommand compose --env-file '$RemoteEnvFile' -f '$RemoteComposeFile' run --rm versiontrack-migrator $MigratorCommand"
$remoteLines += "$dockerCommand compose --env-file '$RemoteEnvFile' -f '$RemoteComposeFile' up -d$removeOrphansFlag versiontrack-api versiontrack-ui"
$remoteCommand = $remoteLines -join "; "

Invoke-Step "Deploy on Synology via SSH" {
    ssh @sshArgs $remoteCommand
}

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host "  Mode            : $Mode"
Write-Host "  NAS host        : $NasHost"
Write-Host "  SSH port        : $NasSshPort"
Write-Host "  Project         : $NasProjectPath"
Write-Host "  API image       : $apiImage"
Write-Host "  UI image        : $uiImage"
Write-Host "  Migrator image  : $migratorImage"
Write-Host "  Migrator command: $MigratorCommand"
Write-Host "  Remove orphans  : $RemoveOrphans"
Write-Host "  Use sudo        : $UseSudo"
Write-Host "  Docker bin      : $NasDockerBinary"
