# Scripts

Run these from the repository root in PowerShell, in order. Each maps to one
part of the workshop provisioning flow.

| Order | Script | Part | What it does |
| ----- | ------ | ---- | ------------ |
| 1 | `deploy.ps1` | A - Infra | `azd up` to create all shared resources, then exports outputs to `.azure/main-outputs.json`. |
| 2 | `load-data.ps1` | B - Data | Seeds Cosmos DB and builds the marketing knowledge base, and writes the workshop `.env`. |
| 3 | `grant-resource-access.ps1` | C - Resource access | Grants service-to-service access (Foundry → Search, Foundry → ACR). |
| 4 | `grant-user-access.ps1` | D - User access | Grants participants their Cosmos / Foundry / Search roles. |
| - | `deploy-user-projects.ps1` | D - User access (isolation) | **Optional.** Creates multiple isolated Foundry **projects** (listed in `infra/foundry-projects.txt`) in the same account and grants one Entra group Azure AI User on every project. |
| - | `revoke-resource-access.ps1` | C - Resource access | Removes the service-to-service grants (optional). |
| - | `revoke-user-access.ps1` | D - User access | Removes the participant grants (optional). |
| - | `destroy.ps1` | Teardown | `azd down --force --purge` to delete everything. |

See the top-level [README.md](../README.md) for full, beginner-friendly
instructions including tool installation.
