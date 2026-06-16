<#
.SYNOPSIS
    Part B - Load the workshop data foundation (Cosmos seed + Foundry IQ KB).

.DESCRIPTION
    Uses the deployment outputs from Part A (scripts/deploy.ps1) to:
      1. Grant the operator running this script the temporary data-plane roles
         needed to seed Cosmos DB and build the Azure AI Search index.
      2. Write a ready-to-use `.env` file into the ai-agents-workshop repo.
      3. Run the workshop seed commands and build the marketing knowledge base.

    The data-plane grants in step 1 are for the OPERATOR (you), not the
    workshop participants. Participant access is handled by
    grant-user-access.ps1 (Part D).

.PARAMETER WorkshopPath
    Path to a local clone of the ai-agents-workshop repository.

.PARAMETER OperatorObjectId
    Entra object id to receive the temporary data-load roles. Defaults to the
    signed-in user. Pass this when running as a service principal.

.PARAMETER SkipSeed
    Skip the Cosmos DB seed commands.

.PARAMETER SkipKnowledgeBase
    Skip building the marketing Foundry IQ knowledge base.

.EXAMPLE
    ./scripts/load-data.ps1 -WorkshopPath C:\dev\ai-agents-workshop
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkshopPath,

    [Parameter(Mandatory = $false)]
    [string]$OperatorObjectId,

    [Parameter(Mandatory = $false)]
    [string]$MainOutputsFile = '.azure/main-outputs.json',

    [switch]$SkipSeed,
    [switch]$SkipKnowledgeBase
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
    if (-not (Test-Path $WorkshopPath)) {
        throw "WorkshopPath '$WorkshopPath' does not exist. Clone ai-agents-workshop first."
    }
    if (-not (Test-Path $MainOutputsFile)) {
        throw "Deployment outputs '$MainOutputsFile' not found. Run ./scripts/deploy.ps1 first."
    }

    $outputs = Get-Content $MainOutputsFile -Raw | ConvertFrom-Json -Depth 50
    $names = $outputs.resourceNames.value
    $endpoints = $outputs.endpoints.value
    $settings = $outputs.workshopSettings.value

    $envValues = Get-AzdEnvValues
    $resourceGroup = $envValues['AZURE_RESOURCE_GROUP']
    $subscriptionId = (az account show --query id -o tsv)
    $tenantId = (az account show --query tenantId -o tsv)

    if ([string]::IsNullOrWhiteSpace($OperatorObjectId)) {
        $OperatorObjectId = az ad signed-in-user show --query id -o tsv 2>$null
    }
    if ([string]::IsNullOrWhiteSpace($OperatorObjectId)) {
        throw 'Could not resolve an operator object id. Pass -OperatorObjectId explicitly.'
    }

    # --- Step 1: temporary operator data-plane grants ----------------------
    Write-Host '== Granting operator the data-load roles =='

    # Cosmos DB Built-in Data Contributor (data plane: read/write/seed).
    if ($names.cosmosDb) {
        az cosmosdb sql role assignment create `
            --resource-group $resourceGroup `
            --account-name $names.cosmosDb `
            --role-definition-id '00000000-0000-0000-0000-000000000002' `
            --principal-id $OperatorObjectId `
            --scope '/' `
            --only-show-errors | Out-Null
        Write-Host "  Cosmos DB Built-in Data Contributor -> $($names.cosmosDb)"
    }

    # AI Search: create the index/KB (Service Contributor) + write docs (Index Data Contributor).
    if ($names.aiSearch) {
        $searchScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Search/searchServices/$($names.aiSearch)"
        az role assignment create --assignee-object-id $OperatorObjectId --assignee-principal-type User --role '7ca78c08-252a-4471-8644-bb5ff32d4ba0' --scope $searchScope --only-show-errors | Out-Null
        az role assignment create --assignee-object-id $OperatorObjectId --assignee-principal-type User --role '8ebe5a00-799e-43f5-93ac-243d3dce84a7' --scope $searchScope --only-show-errors | Out-Null
        Write-Host "  Search Service Contributor + Index Data Contributor -> $($names.aiSearch)"
    }

    # Foundry project: create the KB connection (Azure AI Developer).
    if ($names.aiProject) {
        $projectScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.CognitiveServices/accounts/$($names.aiFoundry)/projects/$($names.aiProject)"
        az role assignment create --assignee-object-id $OperatorObjectId --assignee-principal-type User --role '64702f94-c441-49e6-a78b-ef80e0188fee' --scope $projectScope --only-show-errors | Out-Null
        Write-Host "  Azure AI Developer -> $($names.aiProject)"
    }

    Write-Host 'Waiting 60s for role assignments to propagate...'
    Start-Sleep -Seconds 60

    # --- Step 2: update the workshop .env (upsert resource values) ---------
    Write-Host '== Updating workshop .env with provisioned resource values =='
    $envPath = Join-Path $WorkshopPath '.env'

    # Resource-derived settings this script owns. Everything else already in
    # .env (agent names, memory demo users, orchestrator flags, comments) is
    # left untouched. The MCP URLs stay empty here — they are filled in later
    # when the workshop deploys its Container Apps.
    $managed = [ordered]@{
        AZURE_SUBSCRIPTION_ID                 = $subscriptionId
        AZURE_TENANT_ID                       = $tenantId
        AZURE_RESOURCE_GROUP                  = $resourceGroup
        AZURE_AI_PROJECT_ENDPOINT             = $endpoints.aiProjectEndpoint
        AZURE_AI_PROJECT_NAME                 = $names.aiProject
        AZURE_AI_PROJECT_RESOURCE_ID          = $endpoints.aiProjectResourceId
        AZURE_AI_MODEL_DEPLOYMENT             = $settings.modelDeployment
        AZURE_AI_EMBEDDING_DEPLOYMENT         = $settings.embeddingDeployment
        AZURE_SEARCH_ENDPOINT                 = $endpoints.searchEndpoint
        COSMOS_ENDPOINT                       = $endpoints.cosmosEndpoint
        COSMOS_DATABASE                       = $settings.cosmosDatabase
        COSMOS_SALES_CONTAINER                = $settings.cosmosSalesContainer
        COSMOS_INVENTORY_CONTAINER            = $settings.cosmosInventoryContainer
        COSMOS_MARKETING_CONTAINER            = $settings.cosmosMarketingContainer
        ACA_ENVIRONMENT                       = $settings.acaEnvironment
        ACA_LOCATION                          = $envValues['AZURE_LOCATION']
        ACR_NAME                              = $settings.acrName
        APP_IDENTITY_RESOURCE_ID              = $settings.workloadIdentityResourceId
        APP_IDENTITY_CLIENT_ID                = $settings.workloadIdentityClientId
        APPLICATIONINSIGHTS_CONNECTION_STRING = $endpoints.appInsightsConnectionString
    }

    if (Test-Path $envPath) {
        $lines = [System.Collections.Generic.List[string]](Get-Content -Path $envPath)
    }
    else {
        $lines = [System.Collections.Generic.List[string]]::new()
    }

    # Replace existing keys in place; track which ones we found.
    $applied = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $key = $matches[1]
            if ($managed.Contains($key)) {
                $lines[$i] = "$key=$($managed[$key])"
                $applied[$key] = $true
            }
        }
    }

    # Append any managed keys that were not already present.
    $missing = @($managed.Keys | Where-Object { -not $applied.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') {
            $lines.Add('')
        }
        $lines.Add('# Added by ai-workshop-infra/scripts/load-data.ps1')
        foreach ($key in $missing) {
            $lines.Add("$key=$($managed[$key])")
        }
    }

    Set-Content -Path $envPath -Value $lines -Encoding utf8
    Write-Host "  .env updated at $envPath ($($applied.Count) replaced, $($missing.Count) added)"

    # --- Step 3: run the workshop seed + KB build --------------------------
    Push-Location $WorkshopPath
    try {
        if (-not $SkipSeed) {
            Write-Host '== Seeding Cosmos DB containers =='
            python -m src.mcp_servers.sales.seed.seed_cosmos
            python -m src.mcp_servers.inventory.seed.seed_cosmos
            python -m src.mcp_servers.marketing.seed.seed_cosmos
        }

        if (-not $SkipKnowledgeBase) {
            Write-Host '== Building marketing Foundry IQ knowledge base =='
            python -m src.foundry_agents.setup_marketing_knowledge_base
        }
    }
    finally {
        Pop-Location
    }

    Write-Host ''
    Write-Host 'Data load complete.'
    Write-Host 'Next steps:'
    Write-Host '  Part C - resource access:  ./scripts/grant-resource-access.ps1'
    Write-Host '  Part D - user access:      ./scripts/grant-user-access.ps1'
}
finally {
    Pop-Location
}
