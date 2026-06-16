<#
.SYNOPSIS
    Teardown - delete and purge all workshop infrastructure.

.DESCRIPTION
    Runs `azd down --force --purge` to remove every resource (and its role
    assignments) created by this project.

    Azure AI Foundry (Cognitive Services) accounts support SOFT DELETE, and
    `azd down --purge` does not always purge them. Because this template uses
    deterministic account names, any leftover soft-deleted account blocks the
    next `azd up` with FlagMustBeSetForRestore. To keep redeploys reliable, this
    script captures the resource group first and explicitly purges any
    soft-deleted Foundry accounts that belonged to it after the teardown.

.EXAMPLE
    ./scripts/destroy.ps1
#>
param(
    [switch]$Force = $true,
    [switch]$Purge = $true
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

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

# Purge any soft-deleted Foundry (Cognitive Services) accounts that belonged to
# the resource group, so their deterministic names are free for the next deploy.
function Clear-SoftDeletedFoundryAccounts {
    param([string]$ResourceGroup)

    if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
        return
    }

    $deletedJson = az cognitiveservices account list-deleted -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($deletedJson)) {
        return
    }

    $rgPattern = "/resourceGroups/$([regex]::Escape($ResourceGroup))/"
    $toPurge = @(($deletedJson | ConvertFrom-Json) | Where-Object { $_.id -match $rgPattern })
    if ($toPurge.Count -eq 0) {
        return
    }

    foreach ($acct in $toPurge) {
        Write-Host "Purging soft-deleted Foundry account '$($acct.name)' in '$($acct.location)'..."
        az cognitiveservices account purge `
            --name $acct.name `
            --resource-group $ResourceGroup `
            --location $acct.location `
            --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not purge '$($acct.name)'. Purge it manually in the Azure portal."
        }
    }
}

Push-Location $projectRoot
try {
    # Capture the resource group BEFORE teardown; azd clears env state on down.
    $envValues = Get-AzdEnvValues
    $resourceGroup = $envValues['AZURE_RESOURCE_GROUP']
    if ([string]::IsNullOrWhiteSpace($resourceGroup) -and -not [string]::IsNullOrWhiteSpace($envValues['AZURE_ENV_NAME'])) {
        $resourceGroup = "rg-$($envValues['AZURE_ENV_NAME'])"
    }

    $arguments = @('down')
    if ($Force) {
        $arguments += '--force'
    }
    if ($Purge) {
        $arguments += '--purge'
    }

    azd @arguments

    # Belt-and-suspenders: ensure no soft-deleted Foundry account lingers.
    Clear-SoftDeletedFoundryAccounts -ResourceGroup $resourceGroup
}
finally {
    Pop-Location
}