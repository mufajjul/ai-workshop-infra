<#
.SYNOPSIS
    Part A - Provision the shared workshop infrastructure with azd.

.DESCRIPTION
    Runs `azd up` against infra/main.bicep and then writes the deployment
    outputs to .azure/main-outputs.json so the later steps
    (load-data.ps1, grant-resource-access.ps1, grant-user-access.ps1) can read
    resource names and endpoints.

    This script ONLY creates infrastructure. It does not load data and does not
    grant any access. See README.md for the full four-part flow.

.EXAMPLE
    ./scripts/deploy.ps1
#>
param()

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

# Azure AI Foundry (Cognitive Services) accounts support SOFT DELETE. When the
# stack is torn down, the account name lingers in a soft-deleted state for days.
# Because this template generates deterministic account names from the resource
# group, a fresh `azd up` then fails with FlagMustBeSetForRestore. Purging any
# soft-deleted accounts that belong to the target resource group first makes the
# deployment idempotent and repeatable.
function Clear-SoftDeletedFoundryAccounts {
    param([string]$ResourceGroup)

    if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
        Write-Warning 'Resource group unknown; skipping soft-deleted Foundry cleanup.'
        return
    }

    Write-Host "Checking for soft-deleted Foundry (Cognitive Services) accounts in '$ResourceGroup'..."
    $deletedJson = az cognitiveservices account list-deleted -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($deletedJson)) {
        return
    }

    $rgPattern = "/resourceGroups/$([regex]::Escape($ResourceGroup))/"
    $toPurge = @(($deletedJson | ConvertFrom-Json) | Where-Object { $_.id -match $rgPattern })
    if ($toPurge.Count -eq 0) {
        Write-Host '  None found.'
        return
    }

    foreach ($acct in $toPurge) {
        Write-Host "  Purging soft-deleted account '$($acct.name)' in '$($acct.location)'..."
        az cognitiveservices account purge `
            --name $acct.name `
            --resource-group $ResourceGroup `
            --location $acct.location `
            --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Could not purge '$($acct.name)'. Purge it manually in the Azure portal, then re-run this script."
        }
    }
}

function Export-DeploymentOutputs {
    param(
        [string]$ResourceGroup,
        [string]$OutputPath
    )

    $deploymentsJson = az deployment group list --resource-group $ResourceGroup -o json
    if ([string]::IsNullOrWhiteSpace($deploymentsJson)) {
        throw "Could not list deployments in resource group '$ResourceGroup'. Did 'azd up' succeed?"
    }

    $deploymentName = $deploymentsJson |
        ConvertFrom-Json |
        Sort-Object { $_.properties.timestamp } |
        Select-Object -Last 1 -ExpandProperty name

    if ([string]::IsNullOrWhiteSpace($deploymentName)) {
        throw "Could not find a deployment in resource group '$ResourceGroup'. Did 'azd up' succeed?"
    }

    $outputsDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $outputsDir)) {
        New-Item -ItemType Directory -Path $outputsDir -Force | Out-Null
    }

    az deployment group show --resource-group $ResourceGroup --name $deploymentName --query properties.outputs -o json |
        Set-Content -Path $OutputPath -Encoding utf8

    Write-Host "Deployment outputs written to $OutputPath"
}

$projectRoot = Get-ProjectRoot
Push-Location $projectRoot
try {
    Write-Host '== Part A: provisioning shared workshop infrastructure (azd up) =='

    # Purge any soft-deleted Foundry accounts left over from a previous teardown
    # so the deterministic account names are free to be (re)created.
    $preEnv = Get-AzdEnvValues
    $preResourceGroup = $preEnv['AZURE_RESOURCE_GROUP']
    if ([string]::IsNullOrWhiteSpace($preResourceGroup) -and -not [string]::IsNullOrWhiteSpace($preEnv['AZURE_ENV_NAME'])) {
        # azd's default resource group name is rg-<environment-name>.
        $preResourceGroup = "rg-$($preEnv['AZURE_ENV_NAME'])"
    }
    Clear-SoftDeletedFoundryAccounts -ResourceGroup $preResourceGroup

    azd up
    if ($LASTEXITCODE -ne 0) {
        throw "azd up failed with exit code $LASTEXITCODE."
    }

    $envValues = Get-AzdEnvValues
    $resourceGroup = $envValues['AZURE_RESOURCE_GROUP']
    if ([string]::IsNullOrWhiteSpace($resourceGroup)) {
        throw 'AZURE_RESOURCE_GROUP was not found in the azd environment.'
    }

    Export-DeploymentOutputs -ResourceGroup $resourceGroup -OutputPath (Join-Path $projectRoot '.azure/main-outputs.json')

    Write-Host ''
    Write-Host 'Infrastructure ready.'
    Write-Host 'Next steps:'
    Write-Host '  Part B - load data:        ./scripts/load-data.ps1 -WorkshopPath <path-to-ai-agents-workshop>'
    Write-Host '  Part C - resource access:  ./scripts/grant-resource-access.ps1'
    Write-Host '  Part D - user access:      ./scripts/grant-user-access.ps1'
}
finally {
    Pop-Location
}
