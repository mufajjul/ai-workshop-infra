// ---------------------------------------------------------------------------
// Multiple isolated Azure AI Foundry PROJECTS under the SAME existing Foundry
// account. The list of projects to create comes from infra/foundry-projects.txt
// (one project name per line) — it is NOT tied to individual users.
//
// A single Entra GROUP is granted Azure AI User (data plane) on EVERY project,
// so the whole group can use all projects.
//
// Model deployments live on the parent ACCOUNT and are automatically shared by
// every project, so all projects expose the same models without duplication.
//
// Deployed by scripts/deploy-user-projects.ps1 AFTER scripts/deploy.ps1.
// ---------------------------------------------------------------------------
targetScope = 'resourceGroup'

@description('Name of the existing AI Foundry (Cognitive Services AIServices) account that hosts every project.')
param aiFoundryName string

@description('Azure region of the Foundry account (projects must be co-located with the parent account).')
param location string

@description('Azure AI User role definition id (data plane: run + create agents, no deployment management).')
param foundryRoleDefinitionId string = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

@description('Names of the Foundry projects to create (one per line in foundry-projects.txt).')
param projectNames array

@description('Entra group object id granted Azure AI User on EVERY project. Empty = create projects without granting access.')
param groupObjectId string = ''

@description('Principal type of groupObjectId (Group, User, or ServicePrincipal).')
param groupPrincipalType string = 'Group'

resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' existing = {
  name: aiFoundryName
}

// One project per name. The Cognitive Services control plane serializes
// operations on the parent account, so create them sequentially (@batchSize(1))
// to avoid RequestConflict errors.
@batchSize(1)
resource projects 'Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview' = [for name in projectNames: {
  name: name
  parent: aiFoundry
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}]

var foundryRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryRoleDefinitionId)

// Grant the group Azure AI User on EVERY project.
resource projectAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (name, i) in projectNames: if (!empty(groupObjectId)) {
  name: guid(projects[i].id, groupObjectId, 'workshop-group-project-azure-ai-user')
  scope: projects[i]
  properties: {
    roleDefinitionId: foundryRoleId
    principalId: groupObjectId
    principalType: groupPrincipalType
  }
}]

// Consumed by deploy-user-projects.ps1 to write each project's endpoint back
// into infra/foundry-projects.txt.
output projects array = [for (name, i) in projectNames: {
  projectName: name
  projectEndpoint: 'https://${aiFoundryName}.services.ai.azure.com/api/projects/${name}'
}]
