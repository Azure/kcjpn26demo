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

@description('Resource ID of the Container Insights data collection rule (routes logs/inventory to the LAW).')
param containerInsightsDcrId string

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
    // `defaultNodePools: 'Auto'` makes NAP create its two standard Karpenter NodePools:
    //   - `default`      : general on-demand capacity for user workloads.
    //   - `system-surge` : lets the System pool scale out beyond `systempool` when
    //                      system/critical add-on pods can't be scheduled.
    nodeProvisioningProfile: {
      mode: 'Auto'
      defaultNodePools: 'Auto'
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
          // Surface pod/deployment labels (e.g. `app`) as Prometheus labels so signals and
          // recording rules can filter workloads by label instead of name prefixes only.
          metricLabelsAllowlist: 'pods=[app,kubernetes.io/name],deployments=[app,kubernetes.io/name]'
          metricAnnotationsAllowList: ''
        }
      }
    }
  }
}

// Associate the managed-Prometheus DCR with the cluster so scraped metrics reach the AMW.
resource prometheusDcra 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  name: 'MSProm-${location}-${aksName}'
  scope: aks
  properties: {
    dataCollectionRuleId: prometheusDcrId
    description: 'Managed Prometheus metrics from AKS to the Azure Monitor workspace.'
  }
}

// Associate the Container Insights DCR with the cluster so the ama-logs agent collects logs and
// inventory (KubePodInventory, ContainerLogV2, ...) into the Log Analytics workspace.
resource containerInsightsDcra 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  name: 'ContainerInsightsExtension'
  scope: aks
  properties: {
    dataCollectionRuleId: containerInsightsDcrId
    description: 'Container Insights logs and inventory from AKS to the Log Analytics workspace.'
  }
}

// Send AKS control-plane logs and platform metrics to LAW.
// `Dedicated` routes control-plane logs into resource-specific tables (AKSAudit,
// AKSAuditAdmin, AKSControlPlane) instead of the shared AzureDiagnostics table,
// which is cheaper to query and lets the health model target richer KQL signals.
resource aksDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'aks-to-law'
  scope: aks
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
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

@description('Principal ID of the AKS cluster (control-plane) system-assigned identity. NAP uses it to provision nodes into the subnet, so it needs Network Contributor on a custom VNet.')
output aksIdentityPrincipalId string = aks.identity.principalId
