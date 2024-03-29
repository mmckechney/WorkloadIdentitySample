param
(
    [string] $prefix,
    [string] $resourceGroupName,
    [string] $location,
    [bool] $includeContainerRegistry
)
Write-Host "Create AKS cluster and associated services for sample..."  -ForegroundColor Cyan
if("" -eq  $resourceGroupName)
{
    $resourceGroupName = "$($prefix)-rg"
}
$aksClusterName = $prefix + "aks"
$keyVaultName = $prefix + "keyvault"
$userAssignedIdentity = $prefix + "identity"
$aksVnet = $prefix + "vnet"
$aksSubnet = "akssubnet"
$containerRegistryName = $prefix + "containerregistry"
$nsgName = $prefix + "nsg"
$SERVICE_ACCOUNT_NAMESPACE="default"
$SERVICE_ACCOUNT_NAME="workload-identity-sa"
$federatedIdName="federated-name"
$k8sNamespace=$SERVICE_ACCOUNT_NAMESPACE

# Install the aks-preview extension
Write-Host "Adding AKS preview extension" -ForegroundColor DarkGreen
az extension add --name aks-preview
az extension update --name aks-preview

# Register the preview feature
Write-Host "Registering AKS preview features" -ForegroundColor DarkGreen
az feature register --namespace "Microsoft.ContainerService" --name "EnableWorkloadIdentityPreview" -o table
az feature register --namespace "Microsoft.ContainerService" --name "EnableOIDCIssuerPreview" -o table
while(( az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnableWorkloadIdentityPreview')].properties.state" -o tsv) -eq "Registering")
{
    Write-Host "Waiting for 'EnableWorkloadIdentityPreview' feature registration to complete..."
    Start-Sleep -s 10
}
while(( az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnableOIDCIssuerPreview')].properties.state" -o tsv) -eq "Registering")
{
    Write-Host "Waiting for 'EnableWorkloadIdentityPreview' feature registration to complete..."
    Start-Sleep -s 10
}
az provider register --namespace Microsoft.ContainerService


 
Write-Host "Creating Resource  Group $resourceGroupName" -ForegroundColor DarkGreen
az group create --name "$resourceGroupName"  --location $location -o table

Write-Host "Creating KeyVault  $keyVaultName and adding sample secret 'MySecret'" -ForegroundColor DarkGreen
az keyvault create --resource-group "$resourceGroupName" --name $keyVaultName  -o table  
az keyvault secret set --vault-name "$keyVaultName" --name "MySecret" --value "My Super Secret Secret from Key Vault" -o table

Write-Host "Creating user assigned identity to be used with Kubernetes Service Principal: $userAssignedIdentity" -ForegroundColor DarkGreen
$userAssignedClientId = az identity create -g $resourceGroupName -n $userAssignedIdentity -o tsv --query "clientId"

if($includeContainerRegistry)
{
    Write-Host "Creating Container Registry $containerRegistryName" -ForegroundColor DarkGreen
    az acr create --resource-group "$resourceGroupName" --name $containerRegistryName.ToLower() --sku Standard  --admin-enabled true -o table     
}

Write-Host "Creating Network Security Group $nsgName" -ForegroundColor DarkGreen
az network nsg create  --resource-group $resourceGroupName --name $nsgName -o table

Write-Host "Creating VNET $aksVnet and AKS subnet: $aksSubnet, for the AKS cluster $aksClusterName" -ForegroundColor DarkGreen
az network vnet create --resource-group $resourceGroupName --name $aksVnet  --address-prefixes 10.180.0.0/20 --subnet-name $aksSubnet --subnet-prefix 10.180.0.0/22 --network-security-group  $nsgName -o table

$aksVnetId = az network vnet show --resource-group $resourceGroupName --name $aksVnet --query id -o tsv
$aksSubnetId = az network vnet subnet show --resource-group $resourceGroupName --vnet-name $aksVnet --name $aksSubnet --query id -o tsv

Write-Host "Creating AKS Cluster $aksClusterName with Workload Identity and OIDC issuer enabled" -ForegroundColor DarkGreen
az aks create --name $aksClusterName --resource-group $resourceGroupName --enable-oidc-issuer --enable-workload-identity --network-plugin azure --vnet-subnet-id $aksSubnetId  --generate-ssh-keys --yes -o table

if($includeContainerRegistry)
{
    Write-Host "Attaching Azure Container Registry '$containerRegistryName' to AKS Cluster: $aksClusterName" -ForegroundColor DarkGreen
    az aks update --name $aksClusterName --resource-group $resourceGroupName --attach-acr $containerRegistryName -o table
}

Write-Host "Adding Windows nodepool 'win' for sample containers" -ForegroundColor DarkGreen
az aks nodepool add --cluster-name $aksClusterName --resource-group $resourceGroupName --name win --os-type windows --node-count 2 --vnet-subnet-id $aksSubnetId -o table

Write-Host "Retrieving kubectl credentials for: $aksClusterName" -ForegroundColor DarkGreen
az aks get-credentials --name $aksClusterName --resource-group $resourceGroupName --overwrite-existing -o table


# https://docs.microsoft.com/en-us/azure/key-vault/general/key-vault-integrate-kubernetes
##Get cluster information
Write-Host "Collecting cluster information for: $aksClusterName" -ForegroundColor DarkGreen
$clusterInfo = (az aks show --name  $aksClusterName --resource-group $resourceGroupName)  | ConvertFrom-Json -AsHashtable
$clientId = $clusterInfo.identityProfile.kubeletidentity.clientId
$nodeResourceGroup = $clusterInfo.nodeResourceGroup
$vaultResourceGroup = $resourceGroupName
$context = (az account show)  | ConvertFrom-Json -AsHashtable
$subscriptionId = $context.id


##Add role assignments
Write-Host "Adding Role Assignments" -ForegroundColor DarkGreen
az role assignment create --role "Managed Identity Operator" --assignee $clientId --scope /subscriptions/$subscriptionId/resourcegroups/$vaultResourceGroup  -o table
az role assignment create --role "Managed Identity Operator" --assignee $clientId --scope /subscriptions/$subscriptionId/resourcegroups/$nodeResourceGroup  -o table
az role assignment create --role "Virtual Machine Contributor" --assignee $clientId --scope /subscriptions/$subscriptionId/resourcegroups/$nodeResourceGroup  -o table
az role assignment create --role "Contributor" --assignee $clientId --scope $aksVnetId -o table

# Set Key Vault Policy
Write-Host "Setting Key Vault policy for Identity $userAssignedIdentity for $keyVaultName" -ForegroundColor DarkGreen
az keyvault set-policy -n $keyVaultName --secret-permissions get --spn $userAssignedClientId -o table
az keyvault set-policy -n $keyVaultName --key-permissions get --spn $userAssignedClientId -o table
az keyvault set-policy -n $keyVaultName --certificate-permissions get --spn $userAssignedClientId -o table

##############################################################
# Configure the Service Account and Identity
##############################################################

# Get OIDC issuer URl 
$AKS_OIDC_ISSUER= az aks show -n $aksClusterName -g $resourceGroupName --query "oidcIssuerProfile.issuerUrl" -o tsv


#create Kubernetes service principal
Write-Host "Creating Kubernetes Service Principal $SERVICE_ACCOUNT_NAME associated with $userAssignedIdentity" -ForegroundColor DarkGreen

$svcAcctYml = "
 apiVersion: v1
 kind: ServiceAccount
 metadata:
   annotations:
     azure.workload.identity/client-id: $userAssignedClientId 
   labels:
     azure.workload.identity/use: 'true'
   name: $SERVICE_ACCOUNT_NAME
   namespace: $SERVICE_ACCOUNT_NAMESPACE"

$svcAcctYml | kubectl apply -f -

Write-Host "Setting OIDC issuer associated with $SERVICE_ACCOUNT_NAME and identity $userAssignedIdentity" -ForegroundColor DarkGreen
az identity federated-credential create --name $federatedIdName --identity-name $userAssignedIdentity --resource-group $resourceGroupName --issuer $AKS_OIDC_ISSUER --subject system:serviceaccount:$($k8sNamespace):$($SERVICE_ACCOUNT_NAME)


##############################################################
# Deploy sample images with and without identity associated
##############################################################

Write-Host "Deploying sample Pod 'samplewithidentity' with Service Account assigment - to test successful use case " -ForegroundColor DarkGreen
$withIdentity=
@"
apiVersion: v1
kind: Pod
metadata:
   name: samplewithidentity
   namespace: $($SERVICE_ACCOUNT_NAMESPACE)
spec:
   serviceAccountName: $($SERVICE_ACCOUNT_NAME)
   containers:
     - image: ghcr.io/mmckechney/workloadidentitysample/workloadidentitysample:latest
       name: samplewithidentity
       env:
       - name: KeyVaultName
         value: $keyVaultName
   nodeSelector:
     kubernetes.io/os: windows
"@

$withIdentity | kubectl apply -f -

#Port forward this pod to see that the secret is successfully retrieved
# kubectl port-forward pod/samplewithidentity 8080:80



#Deploy pod without identity assigned to demonstate identity isolation within the same cluster
Write-Host "Deploying sample Pod 'samplewithidentity' without Service Account assigment - to test negative case" -ForegroundColor DarkGreen
$noIdentity=
@"
apiVersion: v1
kind: Pod
metadata:
   name: samplenoidentity
   namespace: $($SERVICE_ACCOUNT_NAMESPACE)
spec:
   containers:
     - image: ghcr.io/mmckechney/workloadidentitysample/workloadidentitysample:latest
       name: samplenoidentity
       env:
       - name: KeyVaultName
         value: $keyVaultName
   nodeSelector:
     kubernetes.io/os: windows
"@
$noIdentity | kubectl apply -f -


kubectl get pods -o wide
#Port forward this pod to see that the secret is not retrieved and permission is denied
# kubectl port-forward pod/samplenoidentity 8081:80

#kubectl port-forward pod/samplewithidentity 8081:80





