# AKS sample-workload demo with an Azure Health Model

A demo of an **Azure Health Model** (`Microsoft.CloudHealth/healthmodels`) on AKS. The repo has three parts:

- **Health model** — models four services plus the AKS cluster, Log Analytics workspace (LAW), Azure Monitor workspace (AMW) and the subscription, using Azure resource metrics, KQL (Container Insights) and PromQL (managed Prometheus) signals.
- **Supporting infrastructure** — an AKS cluster (NAP/Karpenter, Cilium, managed Entra ID + RBAC) in a dedicated VNet, wired to LAW (logs) and AMW (metrics), plus Prometheus rule groups and an email action group.
- **Sample workload** — four busybox Deployments that do no real work; they generate a synchronized, varying CPU/memory load so the health model visibly shifts between healthy and unhealthy.

## Health model

Rooted at a single entity (display name **Alerting Platform**), with logical roll-up groups over the four services, which depend on the cluster and its data sources:

```
Alerting Platform
├── CRUD              → controlplane
├── Signal evaluation → rulesexecution, backgroundprocessor
└── Alerting          → alertshandler

every service → aks-cluster → law / amw / subscription
```

Signals span Azure Resource Health, node/pod metrics, running-pod and restart counts, replica
availability, HPA saturation, and CPU/memory golden signals. See [`demo-queries.md`](demo-queries.md)
for every query.

## Deploy the health model + infrastructure

Prerequisites: `az` CLI logged in, and NAP available in the target region (`eastasia`). Set
`alertEmailAddress` in [`main.bicepparam`](main.bicepparam).

```powershell
az group create --name kcjpn-rg --location eastasia

az deployment group create `
  --resource-group kcjpn-rg `
  --template-file main.bicep `
  --parameters main.bicepparam
```

## Deploy the sample workload

```powershell
az aks get-credentials --resource-group kcjpn-rg --name kcjpn-aks
kubectl apply -f nodepools.yaml
kubectl apply -f sampleworkload.yaml
```

This creates the `loadgen` namespace with four Deployments (`controlplane`, `rulesexecution`,
`backgroundprocessor`, `alertshandler`). Each cycles a steady "green" period then a staggered CPU
load peak (HPA `min 2`, `max 15`, 75% CPU target); `backgroundprocessor` also balloons memory past
its limit at each peak, gets OOM-killed, and briefly goes red before recovering. Watch it:

```powershell
kubectl get hpa,pods -n loadgen -o wide -w
```

## Notes

- Container Insights and Prometheus data take a few minutes to appear before the model turns green.
- Some NAP/Karpenter PromQL signals need [AKS control plane metrics (preview)](https://learn.microsoft.com/azure/aks/control-plane-metrics-monitor);
  the KQL scheduling-failure signal works without it.
- `main.bicep` targets **resource group** scope.
