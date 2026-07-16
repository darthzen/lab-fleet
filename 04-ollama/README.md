# 04 — Ollama (otwld/ollama-helm)

    helm repo add ollama-helm https://helm.otwld.com/
    helm upgrade --install ollama ollama-helm/ollama --version 1.67.0 -n ai --create-namespace -f values.yaml

Key choices: V100 pinned by GPU UUID; flash attention + q8_0 KV cache to fit
larger contexts in 16 GB VRAM; `OLLAMA_NUM_PARALLEL=2` (2 concurrent requests per loaded model); LoadBalancer at
`192.168.7.153:11434` so LAN clients (Claude Code via ollama-code-mcp, the
Xcode instance) reach it directly. 100Gi Longhorn PV for models.
