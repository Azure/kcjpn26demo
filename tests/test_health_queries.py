"""Evaluate the deployed PromQL expressions with promtool (no Python packages needed)."""

import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[1]
source = (root / "modules" / "health-model.bicep").read_text(encoding="utf-8")
reference = (root / "demo-queries.md").read_text(encoding="utf-8")
config = (root / "ama-metrics-settings-configmap.yaml").read_text(encoding="utf-8")
assert 'etcd = "etcd_server_quota_backend_bytes"' in config.split("controlplane-metrics:", 1)[1]
tests = []


def check(signal, series, expected):
    block = source.split(f"name: '{signal}'", 1)[1]
    query = re.search(r"queryText: '([^'\n]+)'", block)[1]
    query = query.replace("${svc.name}", "controlplane")
    assert query in reference, f"{signal}: query reference differs from deployment"
    tests.append({
        "name": signal,
        "interval": "1m",
        "input_series": [{"series": name, "values": values} for name, values in series],
        "promql_expr_test": [{
            "expr": query,
            "eval_time": "10m",
            "exp_samples": [] if expected is None else [{"labels": "{}", "value": expected}],
        }],
    })


check("available-replicas", [
    ('kube_deployment_status_replicas_available{deployment="controlplane",namespace="loadgen"}', "2+0x10"),
    ('kube_deployment_status_replicas_available{deployment="controlplane",namespace="other"}', "20+0x10"),
], 2)

latencies = []
for verb, scope, duration in [("LIST", "cluster", 120), ("GET", "resource", 30), ("WATCH", "resource", 6000), ("WATCHLIST", "resource", 6000)]:
    labels = f'job="controlplane-apiserver",verb="{verb}",scope="{scope}",resource="pods"'
    latencies.extend([
        (f"apiserver_request_duration_seconds_sum{{{labels}}}", f"10000+{duration}x10"),
        (f"apiserver_request_duration_seconds_count{{{labels}}}", "10000+60x10"),
    ])
check("apiserver-list-latency", latencies, 2)
check("apiserver-nonlist-latency", latencies, 0.5)

check("etcd-db-utilization", [
    ('etcd_mvcc_db_total_size_in_bytes{job="controlplane-etcd",instance="a"}', "500+0x10"),
    ('etcd_server_quota_backend_bytes{job="controlplane-etcd",instance="a"}', "2000+0x10"),
    ('etcd_mvcc_db_total_size_in_bytes{job="controlplane-etcd",instance="b"}', "1500+0x10"),
    ('etcd_server_quota_backend_bytes{job="controlplane-etcd",instance="b"}', "2000+0x10"),
    ('etcd_mvcc_db_total_size_in_use_in_bytes{job="controlplane-etcd",instance="b"}', "1490+0x10"),
], 75)

for signal in ["apiserver-list-latency", "apiserver-nonlist-latency", "etcd-db-utilization"]:
    check(signal, [], None)

with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory) / "queries.json"
    fixture.write_text(json.dumps({"tests": tests}), encoding="utf-8")
    subprocess.run(
        [sys.argv[1] if len(sys.argv) > 1 else "promtool", "test", "rules", str(fixture)],
        check=True,
    )
