# 09 — MCP Layer

    kubectl apply -f k8s-mcp-server.yaml
    kubectl create secret generic github-mcp-token -n ai --from-literal=token=<PAT>   # see .example file
    kubectl apply -f github-mcp-server.yaml
    kubectl apply -f retrieval-tool/retrieval-tool.yaml   # see retrieval-tool/README.md
    kubectl apply -f mcpo.yaml

mcpo bridges MCP servers into Open WebUI as OpenAPI tools. Config points at
the in-cluster k8s MCP server and a systemd MCP on the host. The mcpo
`--api-key` in the manifest is a placeholder — rotate it if the service ever
leaves the trusted LAN. Companion repo: darthzen/ollama-code-mcp (Claude Code
→ Ollama delegation; runs stdio on the client, no cluster deployment needed).
