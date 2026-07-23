# AKS + NAP sample-workload demo with an Azure Health Model

Deploys an AKS cluster in a dedicated VNet with **Node Auto Provisioning (NAP / Karpenter)** and
managed **Microsoft Entra ID + Azure RBAC**, wires **logs → Log Analytics (LAW)** via Container
Insights and **metrics → Azure Monitor workspace (AMW / managed Prometheus)**, runs four
self-scaling **sample workloads** pinned to a dedicated Karpenter node pool, and creates an
**Azure Health Model** (`Microsoft.CloudHealth/healthmodels`) that models those services (plus the
AKS cluster, LAW, AMW and the Azure subscription) across Azure resource metrics, logs and
Prometheus metrics.

## What gets deployed

| Component | Resource |
|-----------|----------|
| Dedicated network | `Microsoft.Network/virtualNetworks` (`10.10.0.0/16`, `aks` subnet `10.10.0.0/22`, `defaultOutboundAccess: false`) |
| Logs | `Microsoft.OperationalInsights/workspaces` (LAW) + Container Insights (omsagent) with a dedicated Container Insights **DCR + DCRA** |
| Metrics | `Microsoft.Monitor/accounts` (AMW) + managed Prometheus DCE/DCR/DCRA + default & custom **Prometheus rule groups** |
| Cluster | `Microsoft.ContainerService/managedClusters` — Kubernetes 1.36, NAP `Auto` (default pools `None`), Azure CNI **overlay + Cilium**, managed Entra ID + Azure RBAC |
| Node pools | Bicep `systempool` (System baseline) + a custom `workload` Karpenter `NodePool` + `AKSNodeClass` (`nodepools.yaml`); NAP's built-in `default` / `system-surge` pools are **disabled** |
| Health model | `Microsoft.CloudHealth/healthmodels` — a root entity, three logical groups, four service entities, plus `aks-cluster`, `law`, `amw` and `subscription` entities |
| Alerts | `Microsoft.Insights/actionGroups` — an email action group that notifies `alertEmailAddress` when an alert fires |

The health model's system-assigned identity is granted **Monitoring Reader**, **Reader**,
**Log Analytics Reader** and **Monitoring Data Reader** on the resource group so it can query
each data source.

### Health model entities & signals

The model is a hierarchy rooted at a single entity named after the health model. Relationships
carry a `kind` (`DependsOn`, `IsHostedOn`, `SendsTelemetryTo`, `SendsLogsTo`, `SendsMetricsTo`):

```
root (kcjpn-health)
├── CRUD              → controlplane
├── Signal evaluation → rulesexecution, backgroundprocessor
└── Alerting          → alertshandler          (backgroundprocessor → alertshandler)

every service → aks-cluster → law          (SendsLogsTo)
                            → amw          (SendsMetricsTo)
                            → subscription (DependsOn)
```

- **Service entities** (`controlplane`, `rulesexecution`, `backgroundprocessor`, `alertshandler`) each carry three signal groups:
  - Azure resource metric from the AKS cluster (`node_cpu_usage_percentage`, 80 / 95) + Azure Resource Health.
  - KQL over LAW (`KubePodInventory`) — running pods, max container restarts, and non-running (Failed/Pending) pods.
  - PromQL over AMW — available replicas (`kube_deployment_status_replicas_available`) and HPA saturation.
- **`aks-cluster`** — Azure Resource Health + node metrics (`node_cpu_usage_percentage`, `node_memory_working_set_percentage`, `node_memory_rss_percentage`, `node_disk_usage_percentage`); PromQL node memory utilisation, not-ready nodes and pending pods; **NAP/Karpenter signals** (see below).
- **`law`** — Azure Resource Health + `Heartbeat` count metric + KQL `Heartbeat` freshness (degraded > 15 min / unhealthy > 30 min) + Container Insights ingestion volume.
- **`amw`** — Azure Resource Health + ingestion (`EventsPerMinuteIngestedPercentUtilization`) and active-time-series (`ActiveTimeSeriesPercentUtilization`) utilization metrics + PromQL healthy/unhealthy scrape targets (`up`).
- **`subscription`** — KQL over Azure Resource Graph (via the `arg("")` operator) for regional vCPU **quota usage %** (degraded ≥ 70 / unhealthy ≥ 90).

The logical groups (`CRUD`, `Signal evaluation`, `Alerting`) are roll-up nodes with no signals of
their own; health propagates upward to the root.

### NAP / Karpenter monitoring signals

The `aks-cluster` entity carries dedicated signals for Node Auto Provisioning health:

| Signal | Source | Meaning |
|--------|--------|---------|
| `nap-scheduling-failures` | KQL / `KubeEvents` | Count of `FailedScheduling` warning events in `loadgen` (15 min). Works out of the box via Container Insights. |
| `nap-unschedulable-pods` | PromQL / `scheduler_unschedulable_pods` | Pods the scheduler can't place — the demand that should trigger NAP. **Requires AKS control plane metrics (preview).** |
| `nap-node-churn` | PromQL / `karpenter_nodes_created_total` | NAP nodes created per hour; high sustained churn hints at provisioning/consolidation thrashing. **Requires AKS control plane metrics (preview).** |

The two PromQL signals are scraped by the managed-Prometheus `controlplane-kube-scheduler` and
`controlplane-node-auto-provisioning` default targets, which are only active when
[AKS control plane metrics (preview)](https://learn.microsoft.com/azure/aks/control-plane-metrics-monitor)
is enabled on the cluster. The KQL signal needs no preview.

## Deploy

Prerequisites: `az` CLI logged in, a target resource group, and NAP available in `eastasia`.

Set the alertEmailAddress parameter to your email address in [`main.bicepparam`](main.bicepparam).

```powershell
az group create --name kcjpn-rg --location eastasia

az deployment group create `
  --resource-group kcjpn-rg `
  --template-file main.bicep `
  --parameters main.bicepparam
```

## Apply the sample workloads

```powershell
az aks get-credentials --resource-group kcjpn-rg --name kcjpn-aks
kubectl apply -f nodepools.yaml
kubectl apply -f sampleworkload.yaml
```

This creates the `loadgen` namespace with four Deployments — `controlplane`, `rulesexecution`,
`backgroundprocessor` and `alertshandler` — each running a busybox CPU load loop. The pods
alternate between random busy and idle periods; each Deployment's HPA (`min 1`, `max 10`,
target 50% CPU) scales it in and out, and NAP provisions/removes nodes to match. Watch it:

```powershell
kubectl get hpa,pods -n loadgen -o wide -w
kubectl get nodepools,nodeclaims,nodes -w
```

## Node pools (NAP / Karpenter)

With NAP enabled, node pools are Karpenter `NodePool` CRDs (in-cluster YAML), not Bicep
`agentPoolProfiles`. The layout:

- **`systempool`** — the only Bicep `agentPoolProfile` (mode `System`, 2 nodes); the fixed baseline.
- **`workload`** — a custom `NodePool` + `AKSNodeClass` in [`nodepools.yaml`](nodepools.yaml). Its
  nodes run Azure Linux (`imageFamily: AzureLinux`, encryption-at-host off), carry the label
  `workload: apps` and a `workload=apps:NoSchedule` taint, and (because this cluster uses the
  Cilium dataplane) the `kubernetes.azure.com/ebpf-dataplane: cilium` label plus the
  `node.cilium.io/agent-not-ready` startup taint.

NAP's built-in `default` / `system-surge` pools are **disabled**
(`nodeProvisioningProfile.defaultNodePools: 'None'` in [`modules/aks.bicep`](modules/aks.bicep)), so
the cluster runs only the `systempool` baseline plus the custom `workload` pool. Note this also
means the System pool no longer surges beyond its 2 nodes via NAP; add a self-managed system
NodePool (as the production AHM setup does) if you need that.

The four sample Deployments set `nodeSelector: { workload: apps }` and a matching toleration, so
they **only** run on the `workload` pool — isolated from the System pool. Apply
`nodepools.yaml` before the workloads.

## Notes

- **Authentication** uses managed Microsoft Entra ID + Azure RBAC, so `az aks get-credentials`
  (without `--admin`) requires your identity to hold a cluster RBAC role such as **Azure Kubernetes
  Service RBAC Cluster Admin** on the cluster. (Local accounts are currently left enabled —
  `disableLocalAccounts: false` in [`modules/aks.bicep`](modules/aks.bicep).)
- **NAP/Karpenter PromQL signals** (`nap-unschedulable-pods`, `nap-node-churn`) only report data
  when [AKS control plane metrics (preview)](https://learn.microsoft.com/azure/aks/control-plane-metrics-monitor)
  is enabled; the `nap-scheduling-failures` KQL signal works without it.
- Container Insights tables (`KubePodInventory`, `KubeNodeInventory`, `KubeEvents`) and Prometheus
  metrics take a few minutes to appear after the cluster is up before the health model turns green.
- `main.bicep` targets **resource group** scope.
