# 14 — Cluster Management Plane (Rancher)

This cluster runs as a Rancher downstream: `cattle-cluster-agent` (Rancher
v2.14.2) connects out to the Rancher server, which installed and manages
`rancher-webhook`, `system-upgrade-controller`, Fleet (`fleet-agent` v0.15.2),
and the `rancher-monitoring` stack (kube-prometheus 109.0.2 + Grafana
dashboards + DCGM GPU metrics). These components are lifecycle-managed by
Rancher, so no recreation manifests live here — re-registering the cluster in
Rancher reinstalls all of them. Monitoring values are captured in the
state dump (`helm/cattle-monitoring-system__*.values.yaml`).
