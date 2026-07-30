# 09 — MCP Layer

    kubectl apply -f k8s-mcp-server.yaml            # includes its read-only RBAC
    kubectl create secret generic github-mcp-token -n ai --from-literal=token=<PAT>   # see .example file
    kubectl apply -f github-mcp-server.yaml
    kubectl apply -f docs-rag/docs-rag-mcp.yaml     # see docs-rag/README.md
    kubectl apply -f mcpo.yaml

mcpo bridges MCP servers into Open WebUI as OpenAPI tools. Config points at the
in-cluster k8s MCP server, the docs-rag MCP server, and a systemd MCP on the host
(a raw IP — it runs on the node, not in the cluster). The mcpo `--api-key` in the
manifest is a placeholder — rotate it if the service ever leaves the trusted LAN.

`k8s-mcp-server.yaml` ships the ServiceAccount plus a cluster-scoped
ClusterRole/Binding limited to `get`/`list`/`watch`. That RBAC — not the
container's `--read-only` flag — is what actually makes the server read-only, so
keep the verbs as they are.

`docs-rag/` replaces the old `retrieval-tool` FastAPI service, which is gone from
the cluster: same Milvus-backed retrieval, but streamable-HTTP MCP instead of
OpenAPI, so external Claude/Cowork sessions can use it directly as well as
through mcpo. Companion repo: darthzen/ollama-code-mcp (Claude Code
→ Ollama delegation; runs stdio on the client, no cluster deployment needed).
