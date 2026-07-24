# Health model signal queries — demo reference

Copy-paste reference for the signals defined in [`modules/health-model.bicep`](modules/health-model.bicep).
Queries are grouped by **language / signal type**:

- [KQL — Log Analytics (LAW)](#kql--log-analytics-law) — paste into the LAW **Logs** blade.
- [PromQL — Managed Prometheus (AMW)](#promql--managed-prometheus-amw) — paste into the AMW **Prometheus explorer** / Grafana.
- [Azure resource metrics](#azure-resource-metrics) — selected in Metrics explorer (no query text).
- [Azure Resource Health](#azure-resource-health) — platform signal, no query.
- [Disabled signals](#disabled-signals) — currently turned off in the Bicep.

> **Per-service queries:** the four service entities (`controlplane`, `rulesexecution`,
> `backgroundprocessor`, `alertshandler`) share the same query shape. Examples below use
> `controlplane` — swap the name to target another service.

---

## KQL — Log Analytics (LAW)

### `running-pods` (service) — count of Running pods for the Deployment
```kusto
KubePodInventory | where Namespace == "loadgen" | where ControllerName startswith "controlplane" | summarize arg_max(TimeGenerated, PodStatus) by Name | summarize RunningPods = countif(PodStatus == "Running")
```

### `container-restarts` (service) — max container restarts across the Deployment's pods
`coalesce(..., 0)` keeps the result numeric when no pods match.
```kusto
KubePodInventory | where Namespace == "loadgen" | where ControllerName startswith "controlplane" | summarize Restarts = max(ContainerRestartCount) by Name | summarize MaxRestarts = max(Restarts) | extend MaxRestarts = coalesce(MaxRestarts, 0)
```

### `non-running-pods` (service) — pods stuck in Failed/Pending
```kusto
KubePodInventory | where Namespace == "loadgen" | where ControllerName startswith "controlplane" | summarize arg_max(TimeGenerated, PodStatus) by Name | summarize NotRunningPods = countif(PodStatus in ("Failed", "Pending"))
```

### `ingestion-heartbeat` (law) — minutes since the last agent heartbeat
`coalesce(..., 999)` returns a large sentinel when the workspace is silent, so freshness rules still trip.
```kusto
Heartbeat | summarize MinutesSinceLastHeartbeat = datetime_diff("minute", now(), max(TimeGenerated)) | extend MinutesSinceLastHeartbeat = coalesce(MinutesSinceLastHeartbeat, 999)
```

### `ingestion-volume` (law) — Container Insights records in the last 15 min
```kusto
union isfuzzy=true KubePodInventory, KubeNodeInventory | where TimeGenerated > ago(15m) | count
```

### `nap-scheduling-failures` (aks-cluster) — `FailedScheduling` warnings (NAP can't place pods)
```kusto
KubeEvents | where TimeGenerated > ago(15m) | where KubeEventType == "Warning" | where Reason == "FailedScheduling" | where Namespace == "loadgen" | count
```

---

## PromQL — Managed Prometheus (AMW)

### `available-replicas` (service) — available Deployment replicas
```promql
sum(kube_deployment_status_replicas_available{deployment="controlplane"})
```

### `hpa-saturation` (service) — HPA current vs. max replicas (%)
```promql
max(kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler="controlplane",namespace="loadgen"}) / max(kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler="controlplane",namespace="loadgen"}) * 100
```

### `cpu-saturation` (service) — pod CPU usage vs. CPU limit (%)
Golden signal (saturation). `or vector(0)` keeps the result numeric when no pods match.
```promql
sum(rate(container_cpu_usage_seconds_total{namespace="loadgen",pod=~"controlplane-.*",container!="",container!="POD"}[5m])) / sum(kube_pod_container_resource_limits{namespace="loadgen",pod=~"controlplane-.*",resource="cpu"}) * 100 or vector(0)
```

### `memory-saturation` (service) — pod working-set memory vs. memory limit (%)
Golden signal (saturation). `backgroundprocessor` drives this to its limit and OOM-kills at each load peak.
```promql
sum(container_memory_working_set_bytes{namespace="loadgen",pod=~"controlplane-.*",container!="",container!="POD"}) / sum(kube_pod_container_resource_limits{namespace="loadgen",pod=~"controlplane-.*",resource="memory"}) * 100 or vector(0)
```

### `slo-availability` (service) — available vs. desired replicas (%)
Golden signal (availability / SLO).
```promql
sum(kube_deployment_status_replicas_available{deployment="controlplane",namespace="loadgen"}) / sum(kube_deployment_spec_replicas{deployment="controlplane",namespace="loadgen"}) * 100 or vector(0)
```

### `node-memory-util` (aks-cluster) — cluster node memory utilisation (%)
```promql
max(instance:node_memory_utilisation:ratio) * 100
```

### `nodes-not-ready` (aks-cluster) — nodes not in Ready state
`or vector(0)` returns 0 instead of an empty result when all nodes are Ready.
```promql
count(kube_node_status_condition{condition="Ready",status="true"} == 0) or vector(0)
```

### `pending-pods` (aks-cluster) — pods in Pending phase
```promql
count(kube_pod_status_phase{phase="Pending"} == 1) or vector(0)
```

### `nap-unschedulable-pods` (aks-cluster) — pods the scheduler can't place
Requires control plane metrics (preview) + the `kube-scheduler` scrape target.
```promql
sum(scheduler_unschedulable_pods) or vector(0)
```

### `nap-node-churn` (aks-cluster) — NAP nodes created in the last hour
Requires control plane metrics (preview) + the `node-auto-provisioning` scrape target.
```promql
sum(increase(karpenter_nodes_created_total[1h])) or vector(0)
```

### `scrape-targets-up` (amw) — healthy Prometheus scrape targets
```promql
count(up == 1)
```

### `scrape-targets-down` (amw) — unhealthy Prometheus scrape targets
```promql
count(up == 0) or vector(0)
```

---

## Azure resource metrics

Selected in **Metrics explorer** (metric namespace + name), not pasted as a query.

| Signal | Entity | Metric namespace | Metric | Degraded / Unhealthy |
|--------|--------|------------------|--------|----------------------|
| `node-cpu-usage` | service + aks-cluster | `microsoft.containerservice/managedclusters` | `node_cpu_usage_percentage` | 80 / 95 (service), 85 / 95 (cluster) |
| `node-memory-working-set` | aks-cluster | `microsoft.containerservice/managedclusters` | `node_memory_working_set_percentage` | — / 100 |
| `node-memory-rss` | aks-cluster | `microsoft.containerservice/managedclusters` | `node_memory_rss_percentage` | 75 / 90 |
| `node-disk-usage` | aks-cluster | `microsoft.containerservice/managedclusters` | `node_disk_usage_percentage` | 75 / 90 |
| `events-ingested-utilization` | amw | `microsoft.monitor/accounts` | `EventsPerMinuteIngestedPercentUtilization` | — / 75 |
| `active-timeseries-utilization` | amw | `microsoft.monitor/accounts` | `ActiveTimeSeriesPercentUtilization` | — / 85 |

> The cluster `node-*` metrics carry a `nodepool eq '*'` dimension filter (per-nodepool split).

---

## Azure Resource Health

Platform signal (`resourceHealth.enabled`), no query text. Enabled on: each **service** entity
(AKS cluster resource), **law**, **aks-cluster**, and **amw**.

---

## Disabled signals

### `subscription-vcpu-quota` (subscription) — **currently disabled** in the Bicep
Regional vCPU quota usage via Azure Resource Graph (`arg("")`). Commented out because the
cross-service query isn't returning data. Kept here for reference:
```kusto
arg("").QuotaResources
| where subscriptionId =~ '<subscriptionId>'
| where type =~ 'microsoft.compute/locations/usages'
| where location in~ ('<region>')
| mv-expand quota = properties.value limit 2000
| extend currentValue = tolong(quota.currentValue)
| extend quotaLimit = tolong(quota['limit'])
| where quotaLimit > 0
| where currentValue > 0
| extend usagePercent = todouble(currentValue) * 100.0 / todouble(quotaLimit)
| summarize usagePercent = max(usagePercent)
```
