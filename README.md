# AI Workshop — Infrastructure

This project provisions everything the **workshop** needs in Azure,
then loads its data and grants participants the right access. The same
infrastructure is reused for the Data and Data Science workshops.

Provisioning is run manually with the Azure Developer CLI (`azd`) and the
PowerShell scripts in [scripts/](scripts). The steps below cover installing the
tools and running each of the four parts.

---

## What gets created

The workshop uses exactly these shared services (nothing else):

| Service | Why the workshop needs it |
| ------- | ------------------------- |
| Azure AI Foundry account + project (**in two regions**) | Hosts the agents and model deployments. A primary stack feeds the workshop; a secondary stack in another region is there for model-quota overflow. |
| Model deployments (`gpt-5.4-mini`, `gpt-5.4-nano`, `gpt-4.1-mini`, `text-embedding-3-small`) | Chat models + embeddings for long-term memory. Created in both Foundry regions. |
| Azure Cosmos DB for NoSQL | Sales, inventory, and marketing data the agents query. |
| Azure AI Search | Backs the marketing Foundry IQ knowledge base. |
| Azure Container Apps environment + Container Registry | Host the MCP servers and chat app later in the workshop. |
| Log Analytics + Application Insights | Observability for the deployed apps. |

> **Regions.** Azure AI Foundry is deployed in **two** regions (configurable in
> `aiFoundry.locations`); the **first** is primary and feeds the workshop `.env`.
> Every other resource lives in the single `primaryLocation`. To use just one
> Foundry region, leave a single entry in `aiFoundry.locations`.

> **No key-based authentication.** Every service is Entra-only (Microsoft Entra
> ID / `DefaultAzureCredential`). Account keys, admin users, API keys, and
> instrumentation-key ingestion are all disabled. Access is granted purely
> through Azure RBAC role assignments.

---

## The four parts

Provisioning is split into four independent steps so each can be reviewed,
re-run, or handed to a different team:

```
A. Infrastructure    ->  ./scripts/deploy.ps1
B. Data load         ->  ./scripts/load-data.ps1 -WorkshopPath <repo>
C. Resource access   ->  ./scripts/grant-resource-access.ps1
D. User access       ->  ./scripts/grant-user-access.ps1
```

| Part | Script | Outcome |
| ---- | ------ | ------- |
| **A. Infrastructure** | `deploy.ps1` | All Azure resources exist and are empty. |
| **B. Data load** | `load-data.ps1` | Cosmos containers are seeded, the marketing knowledge base is built, and a ready-to-use `.env` is written into the workshop repo. |
| **C. Resource access** | `grant-resource-access.ps1` | The workshop's own services get the service-to-service permissions they need (see below). |
| **D. User access** | `grant-user-access.ps1` | Participants get exactly the permissions below. |

### Resource access (Part C — service-to-service)

The workshop services call each other at runtime via managed identities (no
keys). Each grant and its role level is configurable in
[infra/resource-access.parameters.json](infra/resource-access.parameters.json):

| From | To | Default access | Why |
| ---- | -- | -------------- | --- |
| Foundry project | AI Search | Search Index Data Contributor | Foundry IQ indexes the data into AI Search and the marketing agent queries it (MCP). |
| Foundry account | Container Registry | AcrPull | Hosted agents pull their images. |
| Container Apps workload | Container Registry | AcrPull | The MCP servers and chat app pull their images. |
| Container Apps workload | Cosmos DB | Data Contributor (read/write data) | The MCP servers query and update the workshop data. |

> **Container Apps identity.** Part A creates a shared **user-assigned managed
> identity** for the Container Apps workload so its Cosmos and ACR access can be
> granted here, before the apps exist. The workshop apps attach this identity
> when they are deployed (its client/resource id is in the deployment outputs).

### Participant permissions (Part D)

| Service | Participants can | Participants cannot |
| ------- | ---------------- | ------------------- |
| **Cosmos DB** | Read and write documents (items) in the containers. | Create, delete, or scale containers. |
| **Foundry** | Run agents and create agents. | Create or delete model deployments. |
| **Search** | Read (query). | Write, manage, or delete. |

These levels are configurable in
[infra/user-access.parameters.json](infra/user-access.parameters.json) and are
enforced with a **custom Cosmos data role** (items only), the built-in
**Foundry User** role on the Foundry project, and the built-in **Search Index
Data Reader** role on Search.

### Multiple isolated projects (optional)

For isolation you can create **several Foundry projects** inside the same
Foundry account and give one Entra **group** access to all of them. Every
project shares the account's model deployments, so all projects expose the
**same models** with no duplication.

1. List the projects to create in
   **[infra/foundry-projects.txt](infra/foundry-projects.txt)** — one project
   name per line (this controls **how many** projects are created; it is not a
   list of users):

   ```
   project-01
   project-02
   ```

2. After Part A, run it with the Entra group that should access every project:

   ```powershell
   ./scripts/deploy-user-projects.ps1 -GroupObjectId <entra-group-object-id>
   ```

   > If you omit `-GroupObjectId`, the first **Group** entry in
   > [infra/user-access.parameters.json](infra/user-access.parameters.json) is
   > used.

The script creates one project per name
(via [infra/user-projects.bicep](infra/user-projects.bicep)), grants the group
**Azure AI User** on **every** project, then rewrites the projects file with
each project's Foundry endpoint:

```
# project | foundryEndpoint
project-01 | https://<account>.services.ai.azure.com/api/projects/project-01
project-02 | https://<account>.services.ai.azure.com/api/projects/project-02
```

Hand out the `foundryEndpoint` for whichever project each user should use.

---

## Step 0 — Install the tools (one time)

You need four tools. Open **PowerShell** and install any that are missing.

1. **Azure CLI** (`az`)

   ```powershell
   winget install --exact --id Microsoft.AzureCLI
   ```

2. **Azure Developer CLI** (`azd`)

   ```powershell
   winget install --exact --id Microsoft.Azd
   ```

3. **Python 3.11+** (only needed for Part B, the data load)

   ```powershell
   winget install --exact --id Python.Python.3.12
   ```

4. **Git** (to clone the workshop repo)

   ```powershell
   winget install --exact --id Git.Git
   ```

Close and reopen PowerShell after installing, then verify:

```powershell
az version
azd version
python --version
git --version
```

### Sign in

```powershell
az login
azd auth login
az account set --subscription "<your-subscription-name-or-id>"
```

> **What permissions do *you* (the operator) need?**
> To run all three parts you need **Owner** (or **Contributor** + **User Access
> Administrator**) on the target subscription or resource group, plus quota for
> the Azure AI models in your chosen region.

> **Tokens expire.** `azd` and `az` sign-in tokens lapse after a period of
> inactivity (about 90 days). If a script stops with `ERROR: Login expired` or
> `AADSTS700082`, sign in again with `azd auth login` (add
> `--tenant-id <your-tenant-id>` if prompted) and `az login`, then re-run the
> script.

---

## Step 1 — Configure (change anything you like)

Everything is configurable in **[infra/main.parameters.json](infra/main.parameters.json)**.
Open it and adjust as needed — the most common changes:

| Setting | What it controls |
| ------- | ---------------- |
| `workshopName`, `environmentName` | Prefix used in every resource name. |
| `primaryLocation` | Region for Cosmos, Search, Container Apps, App Insights. |
| `aiFoundry.locations` | The one or two regions for Foundry + models. First = primary (feeds `.env`), second = quota-overflow stack. |
| `aiFoundry.deployments` | The models and capacities to deploy (created in every Foundry region). |
| `aiFoundry.chatDeploymentName` / `embeddingDeploymentName` | Which deployments become the chat and embedding models in `.env`. |
| `aiSearch`, `containerRegistry`, `containerApps` | SKUs and sizes. |
| `cosmosDb` | Database name, container names, and throughput. |

You do **not** need to pick resource names — they are generated automatically
from `workshopName` + `environmentName` and are globally unique.

Create an `azd` environment (this also sets the region and resource group):

```powershell
azd env new zava-sandbox
azd env set AZURE_LOCATION northcentralus
```

> `azd up` creates a resource group named after the environment unless you set
> `AZURE_RESOURCE_GROUP` yourself with `azd env set AZURE_RESOURCE_GROUP <name>`.

---

## Step 2 — Part A: provision the infrastructure

```powershell
./scripts/deploy.ps1
```

This runs `azd up` and then saves the deployment outputs to
`.azure/main-outputs.json` (used by the next two steps). When it finishes, all
resources exist but contain no data.

> **Multiple isolated Foundry projects (optional).** Part A creates a single
> shared Foundry project. If you instead want **several isolated projects** in
> the same Foundry account — all sharing the same account-level models — list
> the project names (one per line) in
> [infra/foundry-projects.txt](infra/foundry-projects.txt) and, after this step,
> run:
>
> ```powershell
> ./scripts/deploy-user-projects.ps1 -GroupObjectId <entra-group-object-id>
> ```
>
> This creates one project per name and grants the Entra **group** Azure AI User
> on **every** project, then writes each project's endpoint back into the file.
> See [Multiple isolated projects (optional)](#multiple-isolated-projects-optional)
> for details.

---

## Step 3 — Part B: load the data

First clone the workshop repo and install its Python dependencies:

```powershell
git clone https://github.com/SinglaSandeep/ai-agents-workshop.git C:\dev\ai-agents-workshop
cd C:\dev\ai-agents-workshop
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .
cd ..\ai-workshop-infra
```

Then run the data load (point it at that clone):

```powershell
./scripts/load-data.ps1 -WorkshopPath C:\dev\ai-agents-workshop
```

This will:

1. Grant **you** (the operator) the temporary data-plane roles needed to seed
   Cosmos and build the Search index.
2. Write a ready-to-use `.env` into the workshop repo.
3. Seed the `sales`, `inventory`, and `marketing_campaigns` Cosmos containers.
4. Build the `zava-marketing-kb` Foundry IQ knowledge base.

> Run it from the **activated** Python virtual environment so the `python -m ...`
> seed commands resolve. Use `-SkipSeed` or `-SkipKnowledgeBase` to run only
> part of the load.

---

## Step 4 — Part C: grant resource (service-to-service) access

This lets the workshop's own services call each other (Foundry → Search,
Foundry → Container Registry) using managed identities. Adjust the levels in
[infra/resource-access.parameters.json](infra/resource-access.parameters.json)
if you need to, then run:

```powershell
./scripts/grant-resource-access.ps1
```

---

## Step 5 — Part D: grant participant access

Edit **[infra/user-access.parameters.json](infra/user-access.parameters.json)**
and replace the placeholder with your real Entra users or groups (the access
levels are configurable in the same file):

```jsonc
{
  "objectId": "<entra-user-or-group-object-id>",
  "principalType": "Group",          // or "User"
  "displayName": "workshop-participants"
}
```

Find an object id:

```powershell
# a group
az ad group show --group "workshop-participants" --query id -o tsv
# a single user
az ad user show --id alias@contoso.com --query id -o tsv
```

Then apply the grants:

```powershell
./scripts/grant-user-access.ps1
```

---

## Teardown

When the workshop is over:

```powershell
./scripts/destroy.ps1
```

This runs `azd down --force --purge` and deletes every resource (and their role
assignments) created by this project.

To remove only the access grants but keep the infrastructure:

```powershell
./scripts/revoke-user-access.ps1       # Part D — participant access
./scripts/revoke-resource-access.ps1   # Part C — service-to-service access
```

---

## Project structure

```
azure.yaml                          azd project definition
infra/
  main.bicep                        entry point (Part A)
  main.parameters.json              central, fully configurable workshop settings
  modules/
    core-resources.bicep            shared resources
    foundry.bicep                   one Foundry stack (account + project + models)
    tags.bicep                      standard resource tags
  resource-access.bicep             service-to-service access (Part C)
  resource-access.parameters.json   which service grants + levels
  user-access.bicep                 participant access (Part D)
  user-access.parameters.json       the users/groups to grant + access levels
  user-projects.bicep               optional: multiple isolated Foundry projects + group access
  foundry-projects.txt              optional: project names to create (how many projects)
scripts/
  deploy.ps1                        Part A - provision
  load-data.ps1                     Part B - seed data + build KB + write .env
  grant-resource-access.ps1         Part C - grant service-to-service access
  revoke-resource-access.ps1        remove service-to-service access
  grant-user-access.ps1             Part D - grant participant access
  revoke-user-access.ps1            remove participant access
  deploy-user-projects.ps1          optional - multiple isolated Foundry projects + group access
  destroy.ps1                       teardown
```

---

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `azd up` fails with `ERROR: Login expired` / `AADSTS700082` | The sign-in token lapsed. Run `azd auth login --tenant-id <your-tenant-id>` (and `az login` if needed), then re-run the script. |
| `azd up` fails on a model deployment with a quota error | Lower `capacity` in `aiFoundry.deployments`, or change a region in `aiFoundry.locations` to one with quota. |
| Seed commands fail with a 403 from Cosmos | Wait a minute for the operator role grant to propagate, then re-run `load-data.ps1` (it is idempotent). |
| `python -m src...` not found | Activate the workshop venv and `pip install -e .` inside the workshop repo. |
| KB build fails with `ModuleNotFoundError: No module named 'azure.search'` | The workshop's `pip install -e .` doesn't pull in the Search SDK. Install it into the workshop venv: `pip install "azure-search-documents==11.7.0b2"`, then re-run `load-data.ps1 -SkipSeed`. |
| `grant-user-access.ps1` says outputs not found | Run `./scripts/deploy.ps1` first — it creates `.azure/main-outputs.json`. |
| Participants get 401 from Search/Foundry right after Part D | Azure RBAC can take a few minutes to propagate. |

---

## How it works (design notes)

### Participant permission model

| Requirement | Implementation |
| ----------- | -------------- |
| Cosmos: read/write items, no create/delete/scale | A **custom** Cosmos SQL role granting only `containers/items/*`, `executeQuery`, `readChangeFeed`, and `readMetadata` — it deliberately omits container management actions. |
| Foundry: run + create agents, no deployment changes | Built-in **Foundry User** on each project scope (data plane). No control-plane role on the account, so deployments can't be created or deleted. Granted on the primary project and, when present, the secondary one. |
| Search: read only | Built-in **Search Index Data Reader** on the service. |

### Service-to-service RBAC (Part C)

Each Foundry **project managed identity** is granted **Search Index Data
Contributor** on the Search service so the Foundry IQ knowledge base can index
the data into AI Search and the hosted marketing agent can query it over MCP,
and each Foundry **account managed identity** is granted **AcrPull** on the
Container Registry so hosted agents can pull their images. A shared **Container
Apps workload identity** (created in Part A) is granted **AcrPull** on the
registry and **Cosmos DB Data Contributor** so the MCP servers and chat app can
pull images and read/write the workshop data. These are deployed by
`resource-access.bicep` (Part C), separate from participant access, and every
grant + role level is toggled in `resource-access.parameters.json`.

### Auth posture — no key-based authentication anywhere

| Service | Keyless enforcement |
| ------- | ------------------- |
| Cosmos DB | `disableLocalAuth: true` — account keys cannot be used. |
| Azure AI Foundry | `disableLocalAuth: true` — API keys rejected. |
| Azure AI Search | `disableLocalAuth: true`, no `authOptions` — admin/query keys disabled. |
| Container Registry | `adminUserEnabled: false` — no admin user/password; pull/push via AAD (AcrPull/AcrPush) or managed identity. |
| Application Insights | `DisableLocalAuth: true` — instrumentation-key ingestion rejected. |
| Container Apps env | Logs use the Azure Monitor destination + a diagnostic setting (workspace resource id), so no Log Analytics shared key is ever read. |

Because everything is AAD-only:

- The data-load operator gets temporary **data-plane roles** (Cosmos Data
  Contributor, Search Service + Index Data Contributor, Azure AI Developer) in
  `load-data.ps1`. The marketing KB builder authenticates to Search with AAD —
  the generated `.env` never sets a Search API key.
- Telemetry to Application Insights must use an AAD credential. With local auth
  disabled, the OpenTelemetry exporter needs a `DefaultAzureCredential`. The app
  degrades gracefully (no crash) if this is not configured — only telemetry
  ingestion is affected, which is an optional observability module.

### Why the four-part split

| Part | Mechanism | Reason |
| ---- | --------- | ------ |
| A. Infra | `azd up` / `main.bicep` | Repeatable, declarative provisioning. |
| B. Data | `load-data.ps1` + workshop Python | Seeding is a data-plane operation that needs the workshop code; kept out of Bicep. |
| C. Resource access | `resource-access.bicep` / `grant-resource-access.ps1` | Service-to-service grants, reviewable and configurable on their own. |
| D. User access | `user-access.bicep` / `grant-user-access.ps1` | Participant access, reviewed and changed without touching infrastructure. |
