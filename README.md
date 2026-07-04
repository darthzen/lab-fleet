# Lab Cluster — Config & Recreation Runbook

Captured from the live cluster on 2026-07-04 (`dump-lab-state.sh`), curated for
re-application. Directories are numbered in installation order. Node: single
openSUSE Leap 16.0 host (`sdf1`), k3s v1.35.5+k3s1, 2× NVIDIA GPU.

| Step | Component | Chart / Source | Version |
|---|---|---|---|
| 00 | Host prep (NVIDIA G06, CDI, k3s) | zypper / get.k3s.io | k3s v1.35.5+k3s1 |
| 01 | MetalLB + Traefik | metallb/metallb; k3s-bundled traefik | 0.16.1 / 39.0.7 (v3.6.12) |
| 02 | Longhorn | longhorn/longhorn | 1.12.0 |
| 03 | GPU (RuntimeClass, device plugin, DCGM) | nvdp/nvidia-device-plugin | 0.19.2 / dcgm 4.8.2 |
| 04 | Ollama | otwld ollama-helm | chart 1.60.0 (app 0.30.6) |
| 05 | Open WebUI | open-webui/open-webui | chart 14.8.0 (app 0.9.6) |
| 06 | Milvus (+ Attu UI) | zilliztech/milvus | chart 5.0.22 (app 2.6.18) |
| 07 | ComfyUI (+ filebrowser) | mmartial/comfyui-nvidia-docker | latest |
| 08 | k8s-docs-indexer | local image (see README) | v1 |
| 09 | MCP layer (mcpo, k8s/github MCP, retrieval-tool) | manifests | — |
| 10 | Hermes agent (Slack AI agent) | nousresearch/hermes-agent | latest |
| 11 | Emby media server (GPU transcode) | emby/embyserver | latest |
| 12 | Node-RED home automation | nodered/node-red | latest |
| 13 | Resilio Sync (P2P file sync) | resilio/sync | latest |
| 14 | Cluster mgmt plane (Rancher downstream) | README only | v2.14.2 |

Install pattern for helm components:

    helm upgrade --install <release> <chart> -n <ns> --create-namespace -f <dir>/values.yaml

Everything persists on Longhorn storage classes; LoadBalancer services draw
from the MetalLB pool `192.168.7.150-169`. Rancher + rancher-monitoring manage
observability and are documented in `docs/infrastructure.md` rather than here.
