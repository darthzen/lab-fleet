# 03 — GPU: RuntimeClass + Device Plugin + DCGM

    kubectl apply -f runtimeclass/nvidia-runtimeclass.yaml
    helm upgrade --install nvdp nvdp/nvidia-device-plugin -n nvidia-device-plugin --create-namespace -f nvdp-values.yaml
    helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter -n cattle-monitoring-system -f dcgm-exporter/dcgm-exporter-values.yaml

Node exposes `nvidia.com/gpu: 2`. Allocation strategy: Ollama pins the V100
by UUID via `NVIDIA_VISIBLE_DEVICES`, Emby pins the second GPU by UUID for
transcoding, and ComfyUI requests `nvidia.com/gpu: 1` through the device
plugin. GPU workloads use `runtimeClassName: nvidia`.

For Fleet, each Helm chart owns its own bundle path: nvdp at the dir root,
`dcgm-exporter/` and the cluster-scoped `runtimeclass/` as sibling bundles
(each with a `fleet.yaml`).
