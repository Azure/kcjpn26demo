@description('Azure region for all resources.')
param location string

@description('Name of the AKS managed cluster.')
param aksName string

@description('DNS prefix for the AKS cluster.')
param dnsPrefix string

@description('Resource ID of the AKS node subnet in the dedicated VNet.')
param aksSubnetId string

@description('Resource ID of the Log Analytics workspace for Container Insights + control-plane logs.')
param logAnalyticsWorkspaceId string

@description('Resource ID of the managed-Prometheus data collection rule (routes metrics to the AMW).')
param prometheusDcrId string

@description('Kubernetes version for the cluster.')
param kubernetesVersion string = '1.36'

// Node Auto Provisioning (NAP / Karpenter) requires Azure CNI Overlay powered by Cilium.
resource aks 'Microsoft.ContainerService/managedClusters@2026-04-02-preview' = {
  name: aksName
  location: location
  sku: {
    name: 'Base'
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: kubernetesVersion
    // Kubernetes RBAC + managed Entra ID (AAD) authentication (required by CloudGov policy).
    enableRBAC: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
    }
    // SFI (Safe Secrets): disable local admin accounts so cluster access is Entra-only.
    disableLocalAccounts: false
    // Enable NAP: node pools are provisioned on demand by Karpenter.
    nodeProvisioningProfile: {
      mode: 'Auto'
    }
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: 2
        vmSize: 'Standard_D4s_v5'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: aksSubnetId
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'cilium'
      networkDataplane: 'cilium'
      loadBalancerSku: 'standard'
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
    }
    // Container Insights (logs, KubePodInventory, KubeNodeInventory) into LAW.
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
          useAADAuth: 'true'
        }
      }
    }
    // Managed Prometheus scraping (node-exporter, kube-state-metrics, cAdvisor) into AMW.
    azureMonitorProfile: {
      metrics: {
        enabled: true
        kubeStateMetrics: {
          metricLabelsAllowlist: ''
          metricAnnotationsAllowList: ''
        }
      }
    }
  }
}

// Associate the managed-Prometheus DCR with the cluster so scraped metrics reach the AMW.
resource prometheusDcra 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  name: 'MSProm-${aksName}'
  scope: aks
  properties: {
    dataCollectionRuleId: prometheusDcrId
    description: 'Managed Prometheus metrics from AKS to the Azure Monitor workspace.'
  }
}

// Send AKS control-plane logs and platform metrics to LAW.
resource aksDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'aks-to-law'
  scope: aks
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output aksId string = aks.id
output aksName string = aks.name
