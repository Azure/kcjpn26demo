@description('Azure region for the health model resource.')
param location string

@description('Name of the health model resource (3-44 chars, alphanumeric + hyphen).')
param healthModelName string

@description('Resource ID of the AKS cluster to model.')
param aksResourceId string

@description('Resource ID of the Log Analytics workspace (KQL signals).')
param logAnalyticsWorkspaceId string

@description('Resource ID of the Azure Monitor workspace (PromQL signals).')
param azureMonitorWorkspaceId string

@description('Resource ID of the action group notified when a service entity becomes degraded or unhealthy.')
param actionGroupId string

// Action group list applied to entity alerts; empty when no action group is supplied.
var alertActionGroupIds = empty(actionGroupId) ? [] : [actionGroupId]

// ---- Simulated services (each maps to a Deployment in the `loadgen` namespace) --------------
// Modeled as child entities of the root node. See sampleworkload.yaml for the workloads.
var services = [
  {
    name: 'controlplane'
    displayName: 'Control plane'
    x: 875
  }
  {
    name: 'rulesexecution'
    displayName: 'Rules execution'
    x: 375
  }
  {
    name: 'backgroundprocessor'
    displayName: 'Background processor'
    x: 625
  }
  {
    name: 'alertshandler'
    displayName: 'Alerts handler'
    x: 1125
  }
]

// ---- Logical grouping entities (pure roll-up nodes between the root and the services) --------
var logicalGroups = [
  {
    name: 'crud'
    displayName: 'CRUD'
    x: 875
  }
  {
    name: 'signal-evaluation'
    displayName: 'Signal evaluation'
    x: 500
  }
  {
    name: 'alerting'
    displayName: 'Alerting'
    x: 1125
  }
]

// ---- Explicit parent -> child edges for the health model graph -------------------------------
var relationships = [
  {
    parent: healthModelName
    child: 'crud'
    kind: 'DependsOn'
  }
  {
    parent: healthModelName
    child: 'signal-evaluation'
    kind: 'DependsOn'
  }
  {
    parent: healthModelName
    child: 'alerting'
    kind: 'DependsOn'
  }
  {
    parent: 'crud'
    child: 'controlplane'
  }
  {
    parent: 'signal-evaluation'
    child: 'rulesexecution'
  }
  {
    parent: 'signal-evaluation'
    child: 'backgroundprocessor'
  }
  {
    parent: 'alerting'
    child: 'alertshandler'
  }
  {
    parent: 'controlplane'
    child: 'aks-cluster'
    kind: 'IsHostedOn'
  }
  {
    parent: 'rulesexecution'
    child: 'aks-cluster'
    kind: 'IsHostedOn'
  }
  {
    parent: 'backgroundprocessor'
    child: 'aks-cluster'
    kind: 'IsHostedOn'
  }
  {
    parent: 'alertshandler'
    child: 'aks-cluster'
    kind: 'IsHostedOn'
  }
  {
    parent: 'aks-cluster'
    child: 'law'
    kind: 'SendsLogsTo'
  }
  {
    parent: 'aks-cluster'
    child: 'amw'
    kind: 'SendsMetricsTo'
  }
  {
    parent: 'aks-cluster'
    child: 'subscription'
    kind: 'DependsOn'
  }
  {
    parent: 'aks-cluster'
    child: 'api-server'
    kind: 'DependsOn'
  }
  {
    parent: 'aks-cluster'
    child: 'kubelet'
    kind: 'DependsOn'
  }
  {
    parent: 'aks-cluster'
    child: 'etcd'
    kind: 'DependsOn'
  }
]

resource healthModel 'Microsoft.CloudHealth/healthmodels@2026-05-01-preview' = {
  name: healthModelName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

resource authSetting 'Microsoft.CloudHealth/healthmodels/authenticationsettings@2026-05-01-preview' = {
  parent: healthModel
  name: 'default'
  properties: {
    authenticationKind: 'ManagedIdentity'
    displayName: 'Health model system-assigned identity'
    managedIdentityName: 'SystemAssigned'
  }
}

// ---- Discovery rule: auto-discover NAP/Karpenter workload node VMs ----------------------------
// NAP (Karpenter) provisions node VMs for the `workload` NodePool with names like
// `aks-workload-<hash>`. This rule finds them via Azure Resource Graph and adds each as an
// entity with the recommended signals + Azure Resource Health signal attached. The query must
// return an `id` column containing the resource IDs of the discovered resources.
resource workloadVmDiscovery 'Microsoft.CloudHealth/healthmodels/discoveryrules@2026-05-01-preview' = {
  parent: healthModel
  name: 'workload-node-vms'
  properties: {
    displayName: 'Workload node VMs (NAP)'
    authenticationSetting: authSetting.name
    discoverRelationships: 'Enabled'
    addRecommendedSignals: 'Enabled'
    addResourceHealthSignal: 'Enabled'
    specification: {
      kind: 'ResourceGraphQuery'
      resourceGraphQuery: 'Resources | where type =~ "microsoft.compute/virtualmachines" | where name startswith "aks-workload-" | project id'
    }
  }
}

// ---- Root entity: the overall system (name matches the health model) -------------------------
resource rootEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = {
  parent: healthModel
  name: healthModelName
  properties: {
    displayName: 'Alerting Platform'
    impact: 'Standard'
    healthObjective: 99
    canvasPosition: {
      x: 875
      y: 0
    }
    // Fire an Azure Monitor alert (optionally to an action group) when overall system health drops.
    alerts: {
      degraded: {
        severity: 'Sev2'
        description: 'Overall system health is degraded — one or more subsystems are not fully healthy.'
        actionGroupIds: alertActionGroupIds
      }
      unhealthy: {
        severity: 'Sev1'
        description: 'Overall system health is unhealthy — a critical subsystem is down.'
        actionGroupIds: alertActionGroupIds
      }
    }
  }
}

// ---- Shared signal definition: node CPU usage % --------------------------------------------
// Reusable AzureResourceMetric definition referenced by every service entity. The metric +
// thresholds live here once; each entity's signal group supplies the target resource. Tune the
// thresholds in one place and all referencing entities pick it up.
resource nodeCpuUsageSignalDef 'Microsoft.CloudHealth/healthmodels/signaldefinitions@2026-05-01-preview' = {
  parent: healthModel
  name: 'node-cpu-usage'
  properties: {
    signalKind: 'AzureResourceMetric'
    displayName: 'Node CPU usage %'
    refreshInterval: 'PT5M'
    dataUnit: 'Percent'
    metricNamespace: 'microsoft.containerservice/managedclusters'
    metricName: 'node_cpu_usage_percentage'
    timeGrain: 'PT5M'
    aggregationType: 'Average'
    evaluationRules: {
      degradedRule: {
        operator: 'GreaterThan'
        threshold: 80
      }
      unhealthyRule: {
        operator: 'GreaterThan'
        threshold: 95
      }
    }
  }
}

// ---- Service entities: children of the root, each attached to AKS + LAW + AMW ----------------
resource serviceEntities 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = [
  for svc in services: {
    parent: healthModel
    name: svc.name
    properties: {
      displayName: svc.displayName
      impact: 'Standard'
      healthObjective: 99
      canvasPosition: {
        x: svc.x
        y: 386
      }
      alerts: {
        degraded: {
          actionGroupIds: [
            actionGroupId
          ]
          description: '${svc.displayName} health has degraded.'
          severity: 'Sev3'
        }
        unhealthy: {
          actionGroupIds: [
            actionGroupId
          ]
          description: '${svc.displayName} is unhealthy.'
          severity: 'Sev2'
        }
      }
      signalGroups: {
        // Azure resource (AKS cluster) metrics + Azure Resource Health.
        azureResource: {
          authenticationSetting: authSetting.name
          azureResourceId: aksResourceId
          resourceHealth: {
            enabled: 'Enabled'
          }
          signals: [
            {
              // References the shared `node-cpu-usage` signal definition; the target resource
              // (this cluster) comes from the azureResourceId on the signal group above.
              signalKind: 'AzureResourceMetric'
              name: 'node-cpu-usage'
              signalDefinitionName: nodeCpuUsageSignalDef.name
            }
          ]
        }
        // Container Insights (Log Analytics): running pods + restart count for this Deployment.
        azureLogAnalytics: {
          authenticationSetting: authSetting.name
          logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceId
          signals: [
            {
              signalKind: 'LogAnalyticsQuery'
              name: 'running-pods'
              displayName: 'Running pods'
              refreshInterval: 'PT5M'
              dataUnit: 'Count'
              queryText: 'KubePodInventory | where Namespace == "loadgen" | where ControllerName startswith "${svc.name}" | summarize arg_max(TimeGenerated, PodStatus) by Name | summarize RunningPods = countif(PodStatus == "Running")'
              timeGrain: 'PT10M'
              valueColumnName: 'RunningPods'
              evaluationRules: {
                degradedRule: {
                  operator: 'LessThan'
                  threshold: 2
                }
                unhealthyRule: {
                  operator: 'LessThan'
                  threshold: 1
                }
              }
            }
            {
              signalKind: 'LogAnalyticsQuery'
              name: 'container-restarts'
              displayName: 'Max container restarts'
              refreshInterval: 'PT5M'
              dataUnit: 'Count'
              queryText: 'KubePodInventory | where Namespace == "loadgen" | where ControllerName startswith "${svc.name}" | summarize Restarts = max(ContainerRestartCount) by Name | summarize MaxRestarts = max(Restarts) | extend MaxRestarts = coalesce(MaxRestarts, 0)'
              timeGrain: 'PT15M'
              valueColumnName: 'MaxRestarts'
              evaluationRules: {
                degradedRule: {
                  operator: 'GreaterThan'
                  threshold: 3
                }
                unhealthyRule: {
                  operator: 'GreaterThan'
                  threshold: 5
                }
              }
            }
            {
              // Counterpart to `running-pods`: surfaces pods stuck in Failed/Pending state.
              signalKind: 'LogAnalyticsQuery'
              name: 'non-running-pods'
              displayName: 'Non-running pods (Failed/Pending)'
              refreshInterval: 'PT5M'
              dataUnit: 'Count'
              queryText: 'KubePodInventory | where Namespace == "loadgen" | where ControllerName startswith "${svc.name}" | summarize arg_max(TimeGenerated, PodStatus) by Name | summarize NotRunningPods = countif(PodStatus in ("Failed", "Pending"))'
              timeGrain: 'PT10M'
              valueColumnName: 'NotRunningPods'
              evaluationRules: {
                degradedRule: {
                  operator: 'GreaterThan'
                  threshold: 0
                }
                unhealthyRule: {
                  operator: 'GreaterThan'
                  threshold: 4
                }
              }
            }
          ]
        }
        // Managed Prometheus (Azure Monitor workspace): available replicas + HPA saturation.
        azureMonitorWorkspace: {
          authenticationSetting: authSetting.name
          azureMonitorWorkspaceResourceId: azureMonitorWorkspaceId
          signals: [
            {
              signalKind: 'PrometheusMetricsQuery'
              name: 'available-replicas'
              displayName: 'Available replicas (Prometheus)'
              refreshInterval: 'PT5M'
              dataUnit: 'Count'
              queryText: 'sum(kube_deployment_status_replicas_available{deployment="${svc.name}"})'
              timeGrain: 'PT5M'
              evaluationRules: {
                degradedRule: {
                  operator: 'LessThan'
                  threshold: 2
                }
                unhealthyRule: {
                  operator: 'LessThan'
                  threshold: 1
                }
              }
            }
            {
              signalKind: 'PrometheusMetricsQuery'
              name: 'hpa-saturation'
              displayName: 'HPA saturation %'
              refreshInterval: 'PT5M'
              dataUnit: 'Percent'
              queryText: 'max(kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler="${svc.name}",namespace="loadgen"}) / max(kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler="${svc.name}",namespace="loadgen"}) * 100'
              timeGrain: 'PT5M'
              evaluationRules: {
                degradedRule: {
                  operator: 'GreaterThan'
                  threshold: 80
                }
                unhealthyRule: {
                  operator: 'GreaterThan'
                  threshold: 99
                }
              }
            }
            {
              // Golden signal - Saturation: pod CPU usage as a percentage of the configured CPU limit.
              signalKind: 'PrometheusMetricsQuery'
              name: 'cpu-saturation'
              displayName: 'CPU saturation % (vs limit)'
              refreshInterval: 'PT5M'
              dataUnit: 'Percent'
              queryText: 'sum(rate(container_cpu_usage_seconds_total{namespace="loadgen",pod=~"${svc.name}-.*",container!="",container!="POD"}[5m])) / sum(kube_pod_container_resource_limits{namespace="loadgen",pod=~"${svc.name}-.*",resource="cpu"}) * 100 or vector(0)'
              timeGrain: 'PT5M'
              evaluationRules: {
                degradedRule: {
                  operator: 'GreaterThan'
                  threshold: 80
                }
                unhealthyRule: {
                  operator: 'GreaterThan'
                  threshold: 95
                }
              }
            }
            {
              // Golden signal - Saturation: pod working-set memory as a percentage of the memory limit.
              signalKind: 'PrometheusMetricsQuery'
              name: 'memory-saturation'
              displayName: 'Memory saturation % (vs limit)'
              refreshInterval: 'PT5M'
              dataUnit: 'Percent'
              queryText: 'sum(container_memory_working_set_bytes{namespace="loadgen",pod=~"${svc.name}-.*",container!="",container!="POD"}) / sum(kube_pod_container_resource_limits{namespace="loadgen",pod=~"${svc.name}-.*",resource="memory"}) * 100 or vector(0)'
              timeGrain: 'PT5M'
              evaluationRules: {
                degradedRule: {
                  operator: 'GreaterThan'
                  threshold: 80
                }
                unhealthyRule: {
                  operator: 'GreaterThan'
                  threshold: 95
                }
              }
            }
            {
              // Golden signal - Availability (SLO): percentage of desired replicas that are available.
              signalKind: 'PrometheusMetricsQuery'
              name: 'slo-availability'
              displayName: 'SLO availability % (available/desired replicas)'
              refreshInterval: 'PT5M'
              dataUnit: 'Percent'
              queryText: 'sum(kube_deployment_status_replicas_available{deployment="${svc.name}",namespace="loadgen"}) / sum(kube_deployment_spec_replicas{deployment="${svc.name}",namespace="loadgen"}) * 100 or vector(0)'
              timeGrain: 'PT5M'
              evaluationRules: {
                degradedRule: {
                  operator: 'LessThan'
                  threshold: 100
                }
                unhealthyRule: {
                  operator: 'LessThan'
                  threshold: 67
                }
              }
            }
          ]
        }
      }
    }
  }
]

// ---- Logical grouping entities: children of the root, parents of the services ----------------
resource logicalEntities 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = [
  for grp in logicalGroups: {
    parent: healthModel
    name: grp.name
    properties: {
      displayName: grp.displayName
      impact: 'Standard'
      healthObjective: 99
      canvasPosition: {
        x: grp.x
        y: 193
      }
    }
  }
]

// ---- Data-source entity: Log Analytics workspace ---------------------------------------------
// Attached to the LAW Azure resource (Resource Health) + a Heartbeat-freshness KQL signal.
resource lawEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = {
  parent: healthModel
  name: 'law'
  properties: {
    displayName: 'Log Analytics workspace'
    impact: 'Suppressed'
    healthObjective: 99
    canvasPosition: {
      x: 250
      y: 772
    }
    signalGroups: {
      azureResource: {
        authenticationSetting: authSetting.name
        azureResourceId: logAnalyticsWorkspaceId
        resourceHealth: {
          enabled: 'Enabled'
        }
        signals: []
      }
      azureLogAnalytics: {
        authenticationSetting: authSetting.name
        logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceId
        signals: [
          {
            signalKind: 'LogAnalyticsQuery'
            name: 'ingestion-heartbeat'
            displayName: 'Minutes since last heartbeat'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'Heartbeat | summarize MinutesSinceLastHeartbeat = datetime_diff("minute", now(), max(TimeGenerated)) | extend MinutesSinceLastHeartbeat = coalesce(MinutesSinceLastHeartbeat, 999)'
            timeGrain: 'PT15M'
            valueColumnName: 'MinutesSinceLastHeartbeat'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 15
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 30
              }
            }
          }
          {
            signalKind: 'LogAnalyticsQuery'
            name: 'ingestion-volume'
            displayName: 'Container Insights records (15m)'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'union isfuzzy=true KubePodInventory, KubeNodeInventory | where TimeGenerated > ago(15m) | count'
            timeGrain: 'PT15M'
            valueColumnName: 'Count'
            evaluationRules: {
              unhealthyRule: {
                operator: 'LessThan'
                threshold: 1
              }
            }
          }
        ]
      }
    }
  }
}

// ---- Infra entity: AKS cluster (hosts the services, feeds LAW + AMW) -------------------------
resource aksEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = {
  parent: healthModel
  name: 'aks-cluster'
  properties: {
    displayName: 'AKS cluster'
    impact: 'Standard'
    healthObjective: 99
    canvasPosition: {
      x: 750
      y: 579
    }
    alerts: {
      degraded: {
        severity: 'Sev2'
        description: 'AKS cluster is degraded — node pressure, scheduling failures, or NAP capacity issues.'
        actionGroupIds: alertActionGroupIds
      }
      unhealthy: {
        severity: 'Sev1'
        description: 'AKS cluster is unhealthy — nodes not ready or the cluster cannot schedule workloads.'
        actionGroupIds: alertActionGroupIds
      }
    }
    signalGroups: {
      azureResource: {
        authenticationSetting: authSetting.name
        azureResourceId: aksResourceId
        resourceHealth: {
          enabled: 'Enabled'
        }
        signals: [
          {
            signalKind: 'AzureResourceMetric'
            name: 'node-cpu-usage'
            displayName: 'Node CPU usage %'
            refreshInterval: 'PT5M'
            dataUnit: 'Percent'
            metricNamespace: 'microsoft.containerservice/managedclusters'
            metricName: 'node_cpu_usage_percentage'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            dimensionFilter: 'nodepool eq \'*\''
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 85
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 95
              }
            }
          }
          {
            signalKind: 'AzureResourceMetric'
            name: 'node-memory-working-set'
            displayName: 'Node memory working set %'
            refreshInterval: 'PT5M'
            dataUnit: 'Percent'
            metricNamespace: 'microsoft.containerservice/managedclusters'
            metricName: 'node_memory_working_set_percentage'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            dimensionFilter: 'nodepool eq \'*\''
            evaluationRules: {
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 100
              }
            }
          }
          {
            signalKind: 'AzureResourceMetric'
            name: 'node-memory-rss'
            displayName: 'Node memory RSS %'
            refreshInterval: 'PT5M'
            dataUnit: 'Percent'
            metricNamespace: 'microsoft.containerservice/managedclusters'
            metricName: 'node_memory_rss_percentage'
            timeGrain: 'PT15M'
            aggregationType: 'Average'
            dimensionFilter: 'nodepool eq \'*\''
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 75
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 90
              }
            }
          }
          {
            signalKind: 'AzureResourceMetric'
            name: 'node-disk-usage'
            displayName: 'Node disk usage %'
            refreshInterval: 'PT5M'
            dataUnit: 'Percent'
            metricNamespace: 'microsoft.containerservice/managedclusters'
            metricName: 'node_disk_usage_percentage'
            timeGrain: 'PT15M'
            aggregationType: 'Average'
            dimensionFilter: 'nodepool eq \'*\''
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 75
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 90
              }
            }
          }
        ]
      }
      // Container Insights (Log Analytics): NAP/Karpenter provisioning health from KubeEvents.
      azureLogAnalytics: {
        authenticationSetting: authSetting.name
        logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceId
        signals: [
          {
            // When NAP/Karpenter can't satisfy pending pods (quota, SKU availability, zone
            // constraints), kube-scheduler emits a `FailedScheduling` Warning event per pod.
            // A sustained stream means NAP isn't provisioning the capacity the pods need.
            signalKind: 'LogAnalyticsQuery'
            name: 'nap-scheduling-failures'
            displayName: 'Pod scheduling failures (15m)'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'KubeEvents | where TimeGenerated > ago(15m) | where KubeEventType == "Warning" | where Reason == "FailedScheduling" | where Namespace == "loadgen" | count'
            timeGrain: 'PT15M'
            valueColumnName: 'Count'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 50
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 200
              }
            }
          }
        ]
      }
      // Managed Prometheus: node memory pressure, unready nodes and pending pods.
      azureMonitorWorkspace: {
        authenticationSetting: authSetting.name
        azureMonitorWorkspaceResourceId: azureMonitorWorkspaceId
        signals: [
          {
            signalKind: 'PrometheusMetricsQuery'
            name: 'node-memory-util'
            displayName: 'Node memory utilisation %'
            refreshInterval: 'PT5M'
            dataUnit: 'Percent'
            queryText: 'max(instance:node_memory_utilisation:ratio) * 100'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 80
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 90
              }
            }
          }
          {
            signalKind: 'PrometheusMetricsQuery'
            name: 'nodes-not-ready'
            displayName: 'Not-ready nodes'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'count(kube_node_status_condition{condition="Ready",status="true"} == 0) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 0
              }
            }
          }
          {
            signalKind: 'PrometheusMetricsQuery'
            name: 'pending-pods'
            displayName: 'Pending pods'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'count(kube_pod_status_phase{phase="Pending"} == 1) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 3
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 10
              }
            }
          }
          {
            // NAP/Karpenter monitoring. Requires AKS control plane metrics (preview): the
            // `controlplane-kube-scheduler` default target scrapes `scheduler_unschedulable_pods`.
            // Pods the scheduler can't place are what drive NAP to add nodes; a sustained
            // non-zero count means NAP is failing to keep up with demand.
            signalKind: 'PrometheusMetricsQuery'
            name: 'nap-unschedulable-pods'
            displayName: 'Unschedulable pods (scheduler)'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'sum(scheduler_unschedulable_pods) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 3
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 10
              }
            }
          }
          {
            // NAP/Karpenter monitoring. Requires AKS control plane metrics (preview): the
            // `controlplane-node-auto-provisioning` target scrapes `karpenter_nodes_created_total`.
            // High sustained node-creation churn can indicate provisioning/consolidation thrashing.
            signalKind: 'PrometheusMetricsQuery'
            name: 'nap-node-churn'
            displayName: 'NAP nodes created (1h)'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            // `or vector(0)` yields scalar 0 when the metric isn't collected yet (NAP control
            // plane metrics preview / scrape target not enabled), so the signal returns a numeric
            // 0 instead of erroring on an empty result. Caveat: this masks a missing metric as 0.
            queryText: 'sum(increase(karpenter_nodes_created_total[1h])) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 20
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 50
              }
            }
          }
        ]
      }
    }
  }
}

// ---- Data-source entity: Azure Monitor workspace (managed Prometheus) ------------------------
resource amwEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = {
  parent: healthModel
  name: 'amw'
  properties: {
    displayName: 'Azure Monitor workspace'
    impact: 'Suppressed'
    healthObjective: 99
    canvasPosition: {
      x: 1250
      y: 772
    }
    signalGroups: {
      azureResource: {
        authenticationSetting: authSetting.name
        azureResourceId: azureMonitorWorkspaceId
        resourceHealth: {
          enabled: 'Enabled'
        }
        signals: [
          {
            // Recommended AMW metric (ahm-signal-manifest): ingestion rate vs. limit.
            signalKind: 'AzureResourceMetric'
            name: 'events-ingested-utilization'
            displayName: 'Events/min ingested utilization %'
            refreshInterval: 'PT5M'
            dataUnit: 'Percent'
            metricNamespace: 'microsoft.monitor/accounts'
            metricName: 'EventsPerMinuteIngestedPercentUtilization'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            evaluationRules: {
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 75
              }
            }
          }
          {
            // Recommended AMW metric (ahm-signal-manifest): active time series vs. limit.
            signalKind: 'AzureResourceMetric'
            name: 'active-timeseries-utilization'
            displayName: 'Active time series utilization %'
            refreshInterval: 'PT5M'
            dataUnit: 'Percent'
            metricNamespace: 'microsoft.monitor/accounts'
            metricName: 'ActiveTimeSeriesPercentUtilization'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            evaluationRules: {
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 85
              }
            }
          }
        ]
      }
      azureMonitorWorkspace: {
        authenticationSetting: authSetting.name
        azureMonitorWorkspaceResourceId: azureMonitorWorkspaceId
        signals: [
          {
            signalKind: 'PrometheusMetricsQuery'
            name: 'scrape-targets-up'
            displayName: 'Healthy scrape targets'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'count(up == 1)'
            timeGrain: 'PT5M'
            evaluationRules: {
              unhealthyRule: {
                operator: 'LessThan'
                threshold: 1
              }
            }
          }
          {
            signalKind: 'PrometheusMetricsQuery'
            name: 'scrape-targets-down'
            displayName: 'Unhealthy scrape targets'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'count(up == 0) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 0
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 2
              }
            }
          }
        ]
      }
    }
  }
}

// ---- Infra entity: Azure subscription (hosts the AKS cluster; capacity/quota source) --------
// The vCPU-quota signal runs an Azure Resource Graph query via the KQL `arg("")` operator, so it
// lives in the Log Analytics signal group (there is no native Resource Graph signal kind).
resource subscriptionEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = {
  parent: healthModel
  name: 'subscription'
  properties: {
    displayName: 'Azure subscription'
    impact: 'Standard'
    healthObjective: 99
    canvasPosition: {
      x: 0
      y: 772
    }
    signalGroups: {
      azureLogAnalytics: {
        authenticationSetting: authSetting.name
        logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceId
        // TEMPORARILY DISABLED: the subscription-vcpu-quota signal is not working. The KQL
        // `arg("")` cross-service query against Azure Resource Graph is not returning data.
        // Re-enable once the query/permissions are fixed.
        signals: []
        // signals: [
        //   {
        //     signalKind: 'LogAnalyticsQuery'
        //     name: 'subscription-vcpu-quota'
        //     displayName: 'Subscription vCPU quota usage'
        //     refreshInterval: 'PT5M'
        //     dataUnit: 'Percent'
        //     queryText: 'arg("").QuotaResources\n| where subscriptionId =~ \'${subscription().subscriptionId}\'\n| where type =~ \'microsoft.compute/locations/usages\'\n| where location in~ (\'${resourceGroup().location}\')\n| mv-expand quota = properties.value limit 2000\n| extend currentValue = tolong(quota.currentValue)\n| extend quotaLimit = tolong(quota[\'limit\'])\n| where quotaLimit > 0\n| where currentValue > 0\n| extend usagePercent = todouble(currentValue) * 100.0 / todouble(quotaLimit)\n| summarize usagePercent = max(usagePercent)'
        //     valueColumnName: 'usagePercent'
        //     evaluationRules: {
        //       degradedRule: {
        //         operator: 'GreaterThanOrEqual'
        //         threshold: 70
        //       }
        //       unhealthyRule: {
        //         operator: 'GreaterThanOrEqual'
        //         threshold: 90
        //       }
        //     }
        //   }
        // ]
      }
    }
  }
}

// ---- Control-plane entity: AKS API server (child of the cluster) -----------------------------
// Health derived from AKS control plane metrics (preview) in the Azure Monitor workspace, scraped
// from the `controlplane-apiserver` job. Requires the AzureMonitorMetricsControlPlanePreview
// feature + the `controlplane-apiserver` default scrape target (enabled in
// ama-metrics-settings-configmap.yaml). Signals mirror the Kubernetes / API Server dashboard.
resource apiServerEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = {
  parent: healthModel
  name: 'api-server'
  properties: {
    displayName: 'API server'
    impact: 'Limited'
    healthObjective: 99
    canvasPosition: {
      x: 1000
      y: 772
    }
    alerts: {
      degraded: {
        severity: 'Sev2'
        description: 'API server is degraded — elevated latency, error rate, or inflight-request pressure.'
        actionGroupIds: alertActionGroupIds
      }
      unhealthy: {
        severity: 'Sev1'
        description: 'API server is unhealthy — control-plane availability is impacted.'
        actionGroupIds: alertActionGroupIds
      }
    }
    signalGroups: {
      azureMonitorWorkspace: {
        authenticationSetting: authSetting.name
        azureMonitorWorkspaceResourceId: azureMonitorWorkspaceId
        signals: [
          {
            // "API Server - Health Status" panel: 1 when at least one apiserver instance is up.
            signalKind: 'PrometheusMetricsQuery'
            name: 'apiserver-availability'
            displayName: 'API server availability'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'max(up{job="controlplane-apiserver"})'
            timeGrain: 'PT5M'
            evaluationRules: {
              unhealthyRule: {
                operator: 'LessThan'
                threshold: 1
              }
            }
          }
          {
            // Derived from "API Server HTTP Request by code": rate of 5xx server errors (req/s).
            signalKind: 'PrometheusMetricsQuery'
            name: 'apiserver-error-rate'
            displayName: 'API server 5xx error rate (req/s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'sum(rate(apiserver_request_total{job="controlplane-apiserver",code=~"5.."}[5m])) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 1
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 5
              }
            }
          }
          {
            // "Inflight Requests" panel: concurrent read+write requests in flight (capacity ~600).
            signalKind: 'PrometheusMetricsQuery'
            name: 'apiserver-inflight-requests'
            displayName: 'API server inflight requests'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'sum(max_over_time(apiserver_current_inflight_requests{job="controlplane-apiserver"}[5m]))'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 400
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 550
              }
            }
          }
          {
            // "API server latency for LIST queries" panel: avg duration for LIST (excl. watch).
            signalKind: 'PrometheusMetricsQuery'
            name: 'apiserver-list-latency'
            displayName: 'API server LIST latency (s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Seconds'
            queryText: 'sum(apiserver_request_duration_seconds_sum{job="controlplane-apiserver",resource=~"cluster|namespaces",verb="list",operation!="watch"}) / sum(apiserver_request_duration_seconds_count{job="controlplane-apiserver",resource=~"cluster|namespaces",verb="list",operation!="watch"}) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 1
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 5
              }
            }
          }
          {
            // "API Server latency for NON-LIST queries" panel: avg duration for non-LIST (excl. watch).
            signalKind: 'PrometheusMetricsQuery'
            name: 'apiserver-nonlist-latency'
            displayName: 'API server non-LIST latency (s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Seconds'
            queryText: 'sum(apiserver_request_duration_seconds_sum{job="controlplane-apiserver",verb!="list",operation!="watch",scope=~"resource|^$"}) / sum(apiserver_request_duration_seconds_count{job="controlplane-apiserver",verb!="list",operation!="watch",scope=~"resource|^$"}) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 1
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 3
              }
            }
          }
        ]
      }
    }
  }
}

// ---- Node entity: Kubelet (child of the cluster) --------------------------------------------
// Health derived from the `kubelet` scrape job in the Azure Monitor workspace (kubelet + cadvisor
// default targets, enabled in ama-metrics-settings-configmap.yaml). Signals mirror the
// Kubernetes / Kubelet dashboard. These are per-node metrics, so they follow NAP-provisioned
// nodes automatically.
resource kubeletEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = {
  parent: healthModel
  name: 'kubelet'
  properties: {
    displayName: 'Kubelet'
    impact: 'Limited'
    healthObjective: 99
    canvasPosition: {
      x: 500
      y: 772
    }
    alerts: {
      degraded: {
        severity: 'Sev3'
        description: 'Kubelet is degraded — elevated runtime/storage operation latency or errors.'
        actionGroupIds: alertActionGroupIds
      }
      unhealthy: {
        severity: 'Sev2'
        description: 'Kubelet is unhealthy — one or more kubelets are down or failing operations.'
        actionGroupIds: alertActionGroupIds
      }
    }
    signalGroups: {
      azureMonitorWorkspace: {
        authenticationSetting: authSetting.name
        azureMonitorWorkspaceResourceId: azureMonitorWorkspaceId
        signals: [
          {
            // Derived from the "Running Kubelets" panel / `up`: kubelet scrape targets that are down.
            signalKind: 'PrometheusMetricsQuery'
            name: 'kubelet-down'
            displayName: 'Kubelets down'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'count(up{job="kubelet"} == 0) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 0
              }
            }
          }
          {
            // "Operation Error Rate" panel: rate of failed container-runtime operations (ops/s).
            signalKind: 'PrometheusMetricsQuery'
            name: 'kubelet-runtime-op-errors'
            displayName: 'Runtime operation error rate (ops/s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'sum(rate(kubelet_runtime_operations_errors_total{job="kubelet"}[5m])) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 1
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 5
              }
            }
          }
          {
            // "Operation Duration 99th quantile" panel: P99 container-runtime operation latency.
            signalKind: 'PrometheusMetricsQuery'
            name: 'kubelet-runtime-op-latency'
            displayName: 'Runtime operation P99 latency (s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Seconds'
            queryText: 'histogram_quantile(0.99, sum(rate(kubelet_runtime_operations_duration_seconds_bucket{job="kubelet"}[5m])) by (le)) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 1
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 5
              }
            }
          }
          {
            // "Pod Start Duration" panel: P99 end-to-end pod start latency (image pulls included).
            signalKind: 'PrometheusMetricsQuery'
            name: 'kubelet-pod-start-latency'
            displayName: 'Pod start P99 latency (s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Seconds'
            queryText: 'histogram_quantile(0.99, sum(rate(kubelet_pod_start_duration_seconds_bucket{job="kubelet"}[5m])) by (le)) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 60
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 120
              }
            }
          }
          {
            // "PLEG relist duration" panel: P99 PLEG relist latency; a classic kubelet health
            // indicator (sustained high values signal node/runtime pressure).
            signalKind: 'PrometheusMetricsQuery'
            name: 'kubelet-pleg-relist-latency'
            displayName: 'PLEG relist P99 latency (s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Seconds'
            queryText: 'histogram_quantile(0.99, sum(rate(kubelet_pleg_relist_duration_seconds_bucket{job="kubelet"}[5m])) by (le)) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 3
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 10
              }
            }
          }
          {
            // "Storage Operation Error Rate" panel: rate of failed volume operations (ops/s).
            signalKind: 'PrometheusMetricsQuery'
            name: 'kubelet-storage-op-errors'
            displayName: 'Storage operation error rate (ops/s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'sum(rate(storage_operation_errors_total{job="kubelet"}[5m])) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 0
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 1
              }
            }
          }
        ]
      }
    }
  }
}

// ---- Control-plane entity: etcd (child of the cluster) --------------------------------------
// Health derived from the `controlplane-etcd` scrape job in the Azure Monitor workspace (AKS
// control plane metrics, preview). Requires the AzureMonitorMetricsControlPlanePreview feature +
// the `controlplane-etcd` default scrape target (enabled in ama-metrics-settings-configmap.yaml).
// Signals mirror the Kubernetes / ETCD dashboard panels.
resource etcdEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-05-01-preview' = {
  parent: healthModel
  name: 'etcd'
  properties: {
    displayName: 'etcd'
    impact: 'Limited'
    healthObjective: 99
    canvasPosition: {
      x: 750
      y: 772
    }
    alerts: {
      degraded: {
        severity: 'Sev2'
        description: 'etcd is degraded — slow applies/reads, heartbeat failures, or DB approaching quota.'
        actionGroupIds: alertActionGroupIds
      }
      unhealthy: {
        severity: 'Sev1'
        description: 'etcd is unhealthy — no leader, members down, or DB at quota. Control-plane writes are impacted.'
        actionGroupIds: alertActionGroupIds
      }
    }
    signalGroups: {
      azureMonitorWorkspace: {
        authenticationSetting: authSetting.name
        azureMonitorWorkspaceResourceId: azureMonitorWorkspaceId
        signals: [
          {
            // "ETCD - Health Status" panel: 1 when at least one etcd instance is up.
            signalKind: 'PrometheusMetricsQuery'
            name: 'etcd-availability'
            displayName: 'etcd availability'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'max(up{job="controlplane-etcd"})'
            timeGrain: 'PT5M'
            evaluationRules: {
              unhealthyRule: {
                operator: 'LessThan'
                threshold: 1
              }
            }
          }
          {
            // "ETCD has leader" panel: 0 for any member without a leader means quorum/leadership loss.
            signalKind: 'PrometheusMetricsQuery'
            name: 'etcd-no-leader'
            displayName: 'etcd members with a leader'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'min(etcd_server_has_leader)'
            timeGrain: 'PT5M'
            evaluationRules: {
              unhealthyRule: {
                operator: 'LessThan'
                threshold: 1
              }
            }
          }
          {
            // "ETCD heartbeat send failures" panel: rate of leader heartbeat send failures (per s).
            // Sustained failures indicate leader/network instability that risks leader elections.
            signalKind: 'PrometheusMetricsQuery'
            name: 'etcd-heartbeat-failures'
            displayName: 'etcd heartbeat send failure rate (per s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'sum(rate(etcd_server_heartbeat_send_failures_total[5m])) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 0
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 1
              }
            }
          }
          {
            // "ETCD Slow Apply total" panel: rate of slow raft proposal applies (per s). A rising
            // rate signals disk/CPU pressure on etcd and precedes write latency problems.
            signalKind: 'PrometheusMetricsQuery'
            name: 'etcd-slow-applies'
            displayName: 'etcd slow apply rate (per s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'sum(rate(etcd_server_slow_apply_total[5m])) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 1
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 10
              }
            }
          }
          {
            // "ETCD Slow Read Indexes total" panel: rate of slow linearizable read-index requests (per s).
            signalKind: 'PrometheusMetricsQuery'
            name: 'etcd-slow-read-indexes'
            displayName: 'etcd slow read-index rate (per s)'
            refreshInterval: 'PT5M'
            dataUnit: 'Count'
            queryText: 'sum(rate(etcd_server_slow_read_indexes_total[5m])) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 1
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 10
              }
            }
          }
          {
            // "Percentage Utilization of ETCD database" panel: DB space in use vs. allocated. As the
            // backend fills toward its quota, etcd risks going read-only (NOSPACE alarm), so a high
            // utilization percentage is a leading indicator of a control-plane outage.
            signalKind: 'PrometheusMetricsQuery'
            name: 'etcd-db-utilization'
            displayName: 'etcd DB utilization %'
            refreshInterval: 'PT5M'
            dataUnit: 'Percent'
            queryText: 'max(100 * etcd_mvcc_db_total_size_in_use_in_bytes / etcd_mvcc_db_total_size_in_bytes) or vector(0)'
            timeGrain: 'PT5M'
            evaluationRules: {
              degradedRule: {
                operator: 'GreaterThan'
                threshold: 80
              }
              unhealthyRule: {
                operator: 'GreaterThan'
                threshold: 95
              }
            }
          }
        ]
      }
    }
  }
}

// ---- Relationships: root -> groups -> services -> AKS -> LAW/AMW -----------------------------
resource entityRelationships 'Microsoft.CloudHealth/healthmodels/relationships@2026-05-01-preview' = [
  for rel in relationships: {
    parent: healthModel
    name: '${rel.parent}-${rel.child}'
    properties: {
      displayName: rel.?kind ?? null
      parentEntityName: rel.parent
      childEntityName: rel.child
    }
    dependsOn: [
      rootEntity
      serviceEntities
      logicalEntities
      lawEntity
      aksEntity
      amwEntity
      subscriptionEntity
      apiServerEntity
      kubeletEntity
      etcdEntity
    ]
  }
]

output healthModelName string = healthModel.name
@description('Principal ID of the health model system-assigned identity (needs reader roles to query data sources).')
output principalId string = healthModel.identity.principalId
