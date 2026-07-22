@description('Azure region for all resources.')
param location string

@description('Name of the Log Analytics workspace (LAW) for logs/Container Insights.')
param logAnalyticsWorkspaceName string

@description('Name of the Azure Monitor workspace (AMW) for Prometheus metrics.')
param azureMonitorWorkspaceName string

@description('Name prefix used for the data collection endpoint / rule.')
param namePrefix string

resource law 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource amw 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: azureMonitorWorkspaceName
  location: location
}

// Data collection endpoint required by the managed-Prometheus data collection rule.
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2024-03-11' = {
  name: '${namePrefix}-dce'
  location: location
  kind: 'Linux'
  properties: {}
}

// Routes scraped Prometheus metrics from the AKS cluster into the Azure Monitor workspace.
resource prometheusDcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: '${namePrefix}-prom-dcr'
  location: location
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: dce.id
    dataSources: {
      prometheusForwarder: [
        {
          name: 'PrometheusDataSource'
          streams: [
            'Microsoft-PrometheusMetrics'
          ]
          labelIncludeFilter: {}
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          accountResourceId: amw.id
          name: 'MonitoringAccount1'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-PrometheusMetrics'
        ]
        destinations: [
          'MonitoringAccount1'
        ]
      }
    ]
  }
}

// Container Insights data collection rule. Enabling the `omsagent` addon with AAD auth does NOT
// auto-create this DCR (only the CLI/portal onboarding does); without it the ama-logs agent has
// no collection config and NOTHING lands in the LAW (no Heartbeat, KubePodInventory, etc.).
// The `Microsoft-ContainerInsights-Group-Default` stream group expands to the standard tables
// (KubePodInventory, KubeNodeInventory, KubeEvents, ContainerLogV2, InsightsMetrics, ...).
resource containerInsightsDcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: '${namePrefix}-ci-dcr'
  location: location
  kind: 'Linux'
  properties: {
    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          extensionName: 'ContainerInsights'
          streams: [
            'Microsoft-ContainerInsights-Group-Default'
          ]
          extensionSettings: {
            dataCollectionSettings: {
              interval: '1m'
              namespaceFilteringMode: 'Off'
              namespaces: []
              enableContainerLogV2: true
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'ciworkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-ContainerInsights-Group-Default'
        ]
        destinations: [
          'ciworkspace'
        ]
      }
    ]
  }
}

output logAnalyticsWorkspaceId string = law.id
output azureMonitorWorkspaceId string = amw.id
output prometheusDcrId string = prometheusDcr.id
output containerInsightsDcrId string = containerInsightsDcr.id
