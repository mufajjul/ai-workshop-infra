<#
.SYNOPSIS
    Part D - Grant workshop participants their access (RBAC).

.DESCRIPTION
    Deploys infra/user-access.bicep, which grants every principal listed in
    infra/user-access.parameters.json:
      - Cosmos DB : read + write items (custom role, no create/delete/scale).
      - Foundry   : run + create agents (Foundry User), no deployment changes.
      - Search    : read only (Search Index Data Reader).

    Run this AFTER scripts/deploy.ps1. Edit infra/user-access.parameters.json
    first to list the real Entra users or groups and adjust access levels.

.PARAMETER ResourceGroup
    Target resource group. Defaults to the azd environment value.

.EXAMPLE
    ./scripts/grant-user-access.ps1
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$MainOutputsFile = '.azure/main-outputs.json',

    [Parameter(Mandatory = $false)]
    [string]$UserAccessParametersFile = 'infra/user-access.parameters.json',

    [Parameter(Mandatory = $false)]
    [string]$DeploymentName = 'workshop-user-access'
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
    if ($SubscriptionId) {
        az account set --subscription $SubscriptionId | Out-Null
    }

    $names = (Get-Content $MainOutputsFile -Raw | ConvertFrom-Json -Depth 50).resourceNames.value

    Write-Host '== Part D: granting participant access (RBAC) =='
    az deployment group create `
        --resource-group $ResourceGroup `
        --name $DeploymentName `
        --template-file 'infra/user-access.bicep' `
        --parameters ('@' + $UserAccessParametersFile) `
        --parameters "aiFoundryName=$($names.aiFoundry)" `
        --parameters "aiProjectName=$($names.aiProject)" `
        --parameters "aiFoundrySecondaryName=$($names.aiFoundrySecondary)" `
        --parameters "aiProjectSecondaryName=$($names.aiProjectSecondary)" `
        --parameters "searchServiceName=$($names.aiSearch)" `
        --parameters "cosmosAccountName=$($names.cosmosDb)" `
        --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Participant access deployment failed with exit code $LASTEXITCODE. Check that every objectId in $UserAccessParametersFile is a real Entra user/group id (not the 00000000... placeholder)."
    }

    Write-Host 'Participant access granted.'
}
finally {
    Pop-Location
}
