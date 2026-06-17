
#az login --tenant 16b3c013-d300-468d-ac64-7eda0820b6d3 

# Create a resource group
az group create \
  --name rg-dbx-hybrid-rs \
  --location eastus2

az deployment group create \
  --resource-group rg-dbx-hybrid-rs \
  --template-file databricks-hybrid.json \
  --parameters @databricks-hybrid.parameters.json


#az deployment group create --resource-group rg-dbx-serverless-dev --template-file databricks-hybrid.json \
 # --parameters @databricks-hybrid.parameters.json


