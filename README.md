# AKS + NAP sample-workload demo with an Azure Health Model

Deploys an AKS cluster in a dedicated VNet with **Node Auto Provisioning (NAP / Karpenter)** and
**Entra-only authentication** (managed Microsoft Entra ID + Azure RBAC, local accounts disabled),
wires **logs → Log Analytics (LAW)** and **metrics → Azure Monitor workspace (AMW / managed
Prometheus)**, runs four self-scaling **sample workloads**, and creates an **Azure Health Model**
(`Microsoft.CloudHealth/healthmodels`) that models those services across Azure resource metrics,
logs and Prometheus metrics.

## What gets deployed

| Component | Resource |
|-----------|----------|
| Dedicated network | `Microsoft.Network/virtualNetworks` (`10.10.0.0/16`, `aks` subnet `10.10.0.0/22`) |
| Logs | `Microsoft.OperationalInsights/workspaces` (LAW) + Container Insights (omsagent) |
| Metrics | `Microsoft.Monitor/accounts` (AMW) + managed Prometheus DCE/DCR/DCRA |
| Cluster | `Microsoft.ContainerService/managedClusters` — Kubernetes 1.36, NAP `Auto`, Azure CNI **overlay + Cilium**, managed Entra ID + Azure RBAC, local accounts disabled |
| Health model | `Microsoft.CloudHealth/healthmodels` — a root entity, three logical groups, four service entities, plus `aks-cluster`, `law` and `amw` entities |

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

every service → aks-cluster → law   (SendsLogsTo)
                            → amw   (SendsMetricsTo)
```

- **Service entities** (`controlplane`, `rulesexecution`, `backgroundprocessor`, `alertshandler`) each carry three signal groups:
  - Azure resource metric from the AKS cluster (`node_cpu_usage_percentage`, degraded 80 / unhealthy 95) + Azure Resource Health.
  - KQL over LAW — running pods for the matching Deployment (`KubePodInventory`).
  - PromQL over AMW — available replicas (`kube_deployment_status_replicas_available`).
- **`aks-cluster`** — `node_cpu_usage_percentage` (80/95) + Azure Resource Health.
- **`law`** — Azure Resource Health + KQL `Heartbeat` freshness (degraded > 15 min / unhealthy > 30 min).
- **`amw`** — Azure Resource Health + PromQL healthy scrape targets (`count(up == 1)`).

The logical groups (`CRUD`, `Signal evaluation`, `Alerting`) are roll-up nodes with no signals of
their own; health propagates upward to the root.

## Deploy

Prerequisites: `az` CLI logged in, a target resource group, and NAP available in `eastasia`.

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
kubectl apply -f sampleworkload.yaml
```

This creates the `loadgen` namespace with four Deployments — `controlplane`, `rulesexecution`,
`backgroundprocessor` and `alertshandler` — each running a busybox CPU load loop. The pods
alternate between random busy and idle periods; each Deployment's HPA (`min 1`, `max 10`,
target 50% CPU) scales it in and out, and NAP provisions/removes nodes to match. Watch it:

```powershell
kubectl get hpa,pods -n loadgen -w
kubectl get nodes -w
```

## Notes

- **Cluster access is Entra-only.** Local accounts are disabled and authorization uses Azure RBAC,
  so `az aks get-credentials` (without `--admin`) requires your identity to hold a cluster RBAC role
  such as **Azure Kubernetes Service RBAC Cluster Admin** on the cluster.
- Container Insights tables (`KubePodInventory`, `KubeNodeInventory`) and Prometheus metrics
  take a few minutes to appear after the cluster is up before the health model turns green.
- `main.bicep` targets **resource group** scope.
