
az login 
#--tenant 16b3c013-d300-468d-ac64-7eda0820b6d3 

# Create a resource group
#az group create \
#  --name pep-azr-aisp-msft-training-lab-sbx-eus-01-rg \
#  --location swedencentral

az deployment group create \
  --resource-group pep-azr-aisp-msft-training-lab-sbx-eus-01-rg \
  --template-file databricks-hybrid.json \
  --parameters @databricks-hybrid.parameters.json


#az deployment group create --resource-group rg-dbx-serverless-dev --template-file databricks-hybrid.json \
 # --parameters @databricks-hybrid.parameters.json


