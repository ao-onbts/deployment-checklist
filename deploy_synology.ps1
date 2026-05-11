[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$NasHost,

    [Parameter(Mandatory = $true)]
    [string]$NasUser,

    [int]$NasSshPort = 22,

    [string]$NasProjectPath = "/volume1/docker/deployment-checklist",

    [string]$LocalComposeFile = "docker-compose.synology.yml",

    [string]$LocalEnvFile = ".env.synology",

    [switch]$RemoveOrphans,

    [switch]$UseSudo,

    [string]$NasDockerBinary = "/usr/local/bin/docker"
)

$ErrorActionPreference = "Stop"

$repoRoot       = $PSScriptRoot
$composePath    = Join-Path $repoRoot $LocalComposeFile
$envPath        = Join-Path $repoRoot $LocalEnvFile
$remoteTarget   = "$NasUser@$NasHost"
$sshArgs        = @('-p', $NasSshPort, $remoteTarget)
$scpArgs        = @('-O', '-P', $NasSshPort)
$dockerCmd      = if ($UseSudo) { "sudo -n $NasDockerBinary" } else { $NasDockerBinary }
$orphansFlag    = if ($RemoveOrphans) { " --remove-orphans" } else { "" }

# -- Read env file for display and NAS docker-login -----------------------------
$envVars = @{}
if (Test-Path $envPath) {
    Get-Content $envPath | Where-Object { $_ -match '^\s*\w+\s*=' -and $_ -notmatch '^\s*#' } | ForEach-Object {
        $kv = $_ -split '=', 2
        $envVars[$kv[0].Trim()] = $kv[1].Trim()
    }
}
$ghcrUser = $envVars['GHCR_USER']
$ghcrPat  = $envVars['GHCR_PAT']
$appImage = if ($envVars['APP_IMAGE']) { $envVars['APP_IMAGE'] } else { 'ghcr.io/ao-onbts/deployment-checklist' }
$imageTag = if ($envVars['IMAGE_TAG'])  { $envVars['IMAGE_TAG']  } else { 'latest' }
$appPort  = if ($envVars['APP_PORT'])   { $envVars['APP_PORT']   } else { '8090' }

function Assert-PathExists {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }
}

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

# -- Pre-flight ------------------------------------------------------------------
Assert-PathExists -Path $composePath -Label "Compose file ($LocalComposeFile)"
Assert-PathExists -Path $envPath     -Label "Environment file ($LocalEnvFile)"

# -- Prepare NAS folder ---------------------------------------------------------
Invoke-Step "Ensure NAS project folder exists" {
    ssh @sshArgs "mkdir -p '$NasProjectPath'"
}

# -- Upload config files --------------------------------------------------------
foreach ($item in @($composePath, $envPath)) {
    $leaf = Split-Path -Leaf $item
    Invoke-Step "Upload $leaf" {
        scp @scpArgs $item "${remoteTarget}:${NasProjectPath}/"
    }
}

# -- Build remote shell script --------------------------------------------------
$remoteLines = @("set -e", "cd '$NasProjectPath'")

if ($ghcrUser -and $ghcrPat) {
    # Password is passed via stdin of the login command, not as a shell argument,
    # so it does not appear in the process list.
    $remoteLines += "printf '%s' '$ghcrPat' | $dockerCmd login ghcr.io -u '$ghcrUser' --password-stdin"
}

$remoteLines += "$dockerCmd compose --env-file '.env.synology' -f 'docker-compose.synology.yml' pull"
$remoteLines += "$dockerCmd compose --env-file '.env.synology' -f 'docker-compose.synology.yml' up -d$orphansFlag"

Invoke-Step "Deploy on Synology via SSH" {
    ssh @sshArgs ($remoteLines -join "; ")
}

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host "  NAS host       : $NasHost"
Write-Host "  SSH port       : $NasSshPort"
Write-Host "  Project path   : $NasProjectPath"
Write-Host "  Image          : ${appImage}:${imageTag}"
Write-Host "  Exposed port   : $appPort  (reverse proxy target)"
Write-Host "  Remove orphans : $RemoveOrphans"
Write-Host "  Use sudo       : $UseSudo"
