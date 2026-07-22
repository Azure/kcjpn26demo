targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = 'eastasia'

@description('Short prefix applied to every resource name.')
@minLength(3)
@maxLength(12)
param namePrefix string = 'kcjpn'

// ---- Names ------------------------------------------------------------------------------------
var vnetName = '${namePrefix}-vnet'
var lawName = '${namePrefix}-law'
var amwName = '${namePrefix}-amw'
var aksName = '${namePrefix}-aks'
var dnsPrefix = '${namePrefix}aks'
var healthModelName = '${namePrefix}-health'

// ---- Built-in role definition IDs -------------------------------------------------------------
var roleIds = {
  monitoringReader: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  logAnalyticsReader: '73c42c96-874c-492b-b04d-ab87d138a893'
  monitoringDataReader: 'b0d8363b-8ddd-447d-831f-62ca05bff136'
}

// ---- Infrastructure ---------------------------------------------------------------------------
module network './modules/network.bicep' = {
  params: {
    location: location
    vnetName: vnetName
  }
}

module monitoring './modules/monitoring.bicep' = {
  params: {
    location: location
    logAnalyticsWorkspaceName: lawName
    azureMonitorWorkspaceName: amwName
    namePrefix: namePrefix
  }
}

module aks './modules/aks.bicep' = {
  params: {
    location: location
    aksName: aksName
    dnsPrefix: dnsPrefix
    aksSubnetId: network.outputs.aksSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    prometheusDcrId: monitoring.outputs.prometheusDcrId
  }
}

// ---- Health model -----------------------------------------------------------------------------
module healthModel './modules/health-model.bicep' = {
  params: {
    location: location
    healthModelName: healthModelName
    aksResourceId: aks.outputs.aksId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    azureMonitorWorkspaceId: monitoring.outputs.azureMonitorWorkspaceId
  }
}

// ---- Grant the health model identity read access to the data sources --------------------------
// Scoped to the resource group so the identity can query AKS metrics/resource health, LAW logs
// and the Azure Monitor workspace (Prometheus) for every resource in this deployment.
resource dataReaderRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for role in items(roleIds): {
    name: guid(resourceGroup().id, healthModelName, role.value)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.value)
      principalId: healthModel.outputs.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

output aksClusterName string = aks.outputs.aksName
output healthModelResourceName string = healthModel.outputs.healthModelName
