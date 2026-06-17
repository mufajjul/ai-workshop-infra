<#
.SYNOPSIS
    Create multiple isolated Azure AI Foundry projects in the existing Foundry
    account and grant one Entra group Azure AI User on every project.

.DESCRIPTION
    Reads infra/foundry-projects.txt (one PROJECT NAME per line — this controls
    how many projects are created; it is NOT a list of users), then deploys
    infra/user-projects.bicep which:
      - creates one Foundry project per name under the existing account, and
      - grants the supplied Entra group Azure AI User on EVERY project.

    All projects share the account's model deployments, so every project exposes
    the same models.

    Run this AFTER scripts/deploy.ps1. After a successful deployment the projects
    file is rewritten as:  project | foundryEndpoint

.PARAMETER GroupObjectId
    Entra group object id granted Azure AI User on every project. If omitted,
    the first Group entry in infra/user-access.parameters.json is used.

.PARAMETER ResourceGroup
    Target resource group. Defaults to the azd environment value.

.EXAMPLE
    ./scripts/deploy-user-projects.ps1 -GroupObjectId 00000000-0000-0000-0000-000000000000
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$GroupObjectId,

    [Parameter(Mandatory = $false)]
    [string]$GroupPrincipalType = 'Group',

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$MainOutputsFile = '.azure/main-outputs.json',

    [Parameter(Mandatory = $false)]
    [string]$ProjectsFile = 'infra/foundry-projects.txt',

    [Parameter(Mandatory = $false)]
    [string]$UserAccessParametersFile = 'infra/user-access.parameters.json',

    [Parameter(Mandatory = $false)]
    [string]$DeploymentName = 'workshop-user-projects'
)

$ErrorActionPreference = 'Stop'

function Get-ProjectRoot {
    Split-Path -Parent $PSScriptRoot
}

function Get-AzdEnvValues {
    $values = @{}
    $lines = azd env get-values 2>$null
    foreach ($line in $lines) {
        if ($line -match '^([^=]+)=(.*)$') {
            $values[$matches[1]] = $matches[2].Trim('"')
        }
    }
    return $values
}

$projectRoot = Get-ProjectRoot
Push-Location $projectRoot
try {
    if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
        $ResourceGroup = (Get-AzdEnvValues)['AZURE_RESOURCE_GROUP']
    }
    if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
        throw 'AZURE_RESOURCE_GROUP not found. Pass -ResourceGroup or run inside an azd environment.'
    }
    if (-not (Test-Path $MainOutputsFile)) {
        throw "Deployment outputs '$MainOutputsFile' not found. Run ./scripts/deploy.ps1 first."
    }
    if (-not (Test-Path $ProjectsFile)) {
        throw "Projects file '$ProjectsFile' not found."
    }
    if ($SubscriptionId) {
        az account set --subscription $SubscriptionId | Out-Null
    }

    $names = (Get-Content $MainOutputsFile -Raw | ConvertFrom-Json -Depth 50).resourceNames.value
    $aiFoundryName = $names.aiFoundry
    if ([string]::IsNullOrWhiteSpace($aiFoundryName)) {
        throw "No AI Foundry account name found in '$MainOutputsFile'. Was Foundry enabled in the deployment?"
    }

    $foundryLocation = az cognitiveservices account show --name $aiFoundryName --resource-group $ResourceGroup --query location -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($foundryLocation)) {
        throw "Could not resolve the location of Foundry account '$aiFoundryName' in resource group '$ResourceGroup'."
    }
    $foundryLocation = $foundryLocation.Trim()

    # Group that gets Azure AI User on EVERY project. Default to the first Group
    # entry in user-access.parameters.json when -GroupObjectId is not passed.
    if ([string]::IsNullOrWhiteSpace($GroupObjectId) -and (Test-Path $UserAccessParametersFile)) {
        $uaParams = Get-Content $UserAccessParametersFile -Raw | ConvertFrom-Json -Depth 50
        $firstGroup = $uaParams.parameters.workshopUsers.value |
            Where-Object { $_.principalType -eq 'Group' } |
            Select-Object -First 1
        if ($firstGroup) {
            $GroupObjectId = $firstGroup.objectId
            Write-Host "Using group '$($firstGroup.displayName)' ($GroupObjectId) from $UserAccessParametersFile."
        }
    }
    if ([string]::IsNullOrWhiteSpace($GroupObjectId)) {
        Write-Warning 'No -GroupObjectId provided and no Group found in user-access.parameters.json. Projects will be created WITHOUT granting access.'
    }

    # Parse the projects file: first whitespace/pipe-separated token on each
    # non-comment, non-empty line is the project NAME.
    $projectNames = @()
    foreach ($line in Get-Content $ProjectsFile) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
        $name = ($trimmed -split '[\s|]+')[0].ToLower()
        if ($name -and ($projectNames -notcontains $name)) { $projectNames += $name }
    }
    if ($projectNames.Count -eq 0) {
        throw "No projects found in '$ProjectsFile'. Add one project name per line."
    }

    Write-Host "== Foundry projects on account '$aiFoundryName' =="
    Write-Host "Creating $($projectNames.Count) project(s):"
    foreach ($name in $projectNames) { Write-Host "  $name" }

    # Pass the array via a temporary deployment parameters file (robust for
    # complex array parameters across shells).
    $paramsFile = Join-Path ([System.IO.Path]::GetTempPath()) "user-projects-params-$([guid]::NewGuid().ToString('N')).json"
    $paramsObject = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{
            aiFoundryName     = @{ value = $aiFoundryName }
            location          = @{ value = $foundryLocation }
            projectNames      = @{ value = $projectNames }
            groupObjectId     = @{ value = ($GroupObjectId ?? '') }
            groupPrincipalType = @{ value = $GroupPrincipalType }
        }
    }
    $paramsObject | ConvertTo-Json -Depth 10 | Set-Content -Path $paramsFile -Encoding utf8

    try {
        Write-Host 'Deploying projects and group access...'
        $outputsJson = az deployment group create `
            --resource-group $ResourceGroup `
            --name $DeploymentName `
            --template-file 'infra/user-projects.bicep' `
            --parameters ('@' + $paramsFile) `
            --query properties.outputs -o json `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Project deployment failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Remove-Item $paramsFile -ErrorAction SilentlyContinue
    }

    $projectOutputs = ($outputsJson | ConvertFrom-Json -Depth 50).projects.value

    # Rewrite the projects file: keep a comment header, then write one
    # "project | foundryEndpoint" row per project.
    $accessNote = [string]::IsNullOrWhiteSpace($GroupObjectId) ? 'no group access granted' : "group $GroupObjectId granted Azure AI User on all projects"
    $header = @(
        '# Foundry projects to create — one project name per line.'
        '#'
        '# This file controls HOW MANY isolated Azure AI Foundry projects are created'
        '# in the SAME Foundry account (it is NOT a list of users). A single Entra'
        '# group is granted Azure AI User on EVERY project. All projects share the'
        "# account's model deployments, so every project exposes the same models."
        '#'
        "# Last deployed: $(Get-Date -Format 'u')  (account: $aiFoundryName; $accessNote)"
        '#'
        '# Edit the project names below and re-run ./scripts/deploy-user-projects.ps1'
        '# (the first token on each row is used; the endpoint is informational).'
        '#'
        '# project | foundryEndpoint'
        '# --- projects below ---'
    )
    $rows = foreach ($p in $projectOutputs) {
        "$($p.projectName) | $($p.projectEndpoint)"
    }
    ($header + $rows) | Set-Content -Path $ProjectsFile -Encoding utf8

    Write-Host ''
    Write-Host "Done. Created/updated $($projectOutputs.Count) project(s)."
    Write-Host "Each project + endpoint written to $ProjectsFile."
}
finally {
    Pop-Location
}
